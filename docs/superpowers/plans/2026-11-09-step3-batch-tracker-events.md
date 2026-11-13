# Step 3: batch tracker events

Design: `docs/superpowers/specs/2026-11-04-cost-budget-architecture-design.md`, section 4.
Branches: `feat/cost-budget-architecture` in `ha-packages` and in `smarli-blueprints`.

## Why now

The hub load test of step 2 found the cause of the second block in the phase burst (see
the step 2 plan, "Hub load test"). The resolver and the mover wrote one tracker key per
cover, about 115 writes in one burst at 40 / 30. A script step does not yield, so HA
processed them as one block, and each write rendered and published the whole tracker
(14 KB). The mover alone, 30 covers: 1.9 s with a 14 KB tracker, 0.54 s with an empty one.

## Core (`ha-packages/packages/smarli_core.yaml`)

1. New events, handled by the same template as the single events:
   - `smarli_tracker_set_many`: `namespace`, `items` (dict key → value). One write for all
     keys. A null value and an empty key are skipped, as a single set without a value is.
   - `smarli_tracker_remove_many`: `namespace`, `keys` (list). Removes exactly these keys.
   - A missing or wrong-typed `items` / `keys` / `namespace` changes nothing.
2. The GC removes its orphans with one `remove_many` per namespace.
3. Header: the new events, and that an older core ignores them.

## Cover package (`ha-packages/packages/smarli_cover.yaml`)

1. Resolver: one `set_many` for watchers, resolved positions and applied transitions, and
   one `remove_many` for lost watchers and expired markers. Before: four loops with one
   write per cover.
2. Mover: one `set_many` for all moving markers, fired before the first command (so the
   markers are rendered before any state change a command causes), and one `remove_many`
   per settle pass for the covers it releases.
3. Suspend: one `set_many` for `::suspended_at` and `::suspension`.
4. Header: needs `smarli_core.yaml` from 2026-11-09. With an older core the markers are
   not written, and manual detection would misread smarli. moves as a person's moves.

The request script still writes one intent per caller (one key, one write).
`cover_DayNight` is unchanged: its two brightness writes stay single, so the blueprint also
works with an older core.

## Tests

New suite `tests/test-tracker-batch.ps1` (in `run-short.ps1`):

- `set_many` writes every key, skips null values and empty keys, overwrites, leaves other
  keys alone.
- `remove_many` removes exactly the listed keys.
- Malformed payloads change nothing; the single events still work.
- A resolver + mover cycle for 4 covers writes the tracker at most 8 times (17 before).
  Result on the rig: 6.

The GC suite (`test-gc`) covers `remove_many` across two namespaces. Then all suites,
`ci/checks.sh`, `ci/check-release.sh`, and the hub matrix (all sizes, quiet and busy).

## Delivery

`smarli_core.yaml` and `smarli_cover.yaml` must roll out together. Retrofit instances need
both files from the same date.

## Hub load test (2026-11-09, mogy-dev, Pi 4, HA 2025.4.1)

One repetition per cell; the 3.1.3 baseline is the median of 3. Steps 1, 2 and 3 ran in the same
session with the same method. Every run published all intents, closed every cover in the phase
test, and paused every cover in the hand test.

Phase burst (every automation extends in the same minute), quiet hub:

| Size | Code | Dropped runs | First cover moves | Last cover moves | Longest stall |
| --- | --- | --- | --- | --- | --- |
| 40 / 30 | 3.1.3 | 0 | 7.7 s | 10.4 s | 5.2 s |
| 40 / 30 | step 2 | 0 | 7.7 s | 7.4 s | 3.6 s |
| 40 / 30 | step 3 | 0 | 4.5 s | 4.5 s | 2.7 s |
| 60 / 40 | 3.1.3 | 10 | 13.3 s | 19.6 s | 9.2 s |
| 60 / 40 | step 2 | 0 | 10.3 s | 10.9 s | 5.5 s |
| 60 / 40 | step 3 | 0 | 7.6 s | 8.5 s | 4.7 s |

With `burn.mjs` (host CPU 100 %), step 3 at 40 / 30: first and last cover at 4.0 s, longest stall
2.0 s (step 2: 7.3 s, 7.1 s, 3.8 s).

Not improved by step 3: the reload burst at 60 / 40 still stalls HA for 4.3–4.8 s (3.1.3: 2.8–3.5 s).
That is block 1 (request runs and their waits), the open item before the merge.

Method error found and fixed: the block 2 probes of step 2 left `hubload_00..39` turned off, and HA
keeps that state across reload and restart. The first matrix of steps 1 and 2 was invalid. `run.mjs`
now turns every hubload automation on before a size and marks a run `INVALID` when intents are missing.

## Block 1: the reload burst (2026-11-09, profiler on mogy-dev)

Reload at 60 / 40, longest stall, split with `_rl.mjs` (automations off / intents kept / intents removed):
reload alone 1.3–2.1 s, reload with intents kept 1.9 s, reload with 60 first publishes 5.7–7.1 s.

The profiler (HA `profiler.start`, 12–14 s around the reload; it slows HA by 2–3 times, so only the
shares count) showed two causes:

1. **The request wait.** Each of the 60 callers waited until its own write was visible. Every
   tracker write re-rendered every waiting template: 3600 renders per burst. Fixed in ha-packages
   `9f1279f`: the request no longer waits; a resolver run writes a fence key
   (`global::resolve_fence`) and waits for it. The tracker renders writes in order, so every
   intent fired before the run is visible. The S6 rule still holds, with one wait per resolver run.
   The four tracker event types are also excluded from the recorder.
2. **The publish run itself.** Each automation that publishes holds HA for about 55 ms on the Pi
   (S5: 53–61 ms): top-level variables, the `if` steps before the intent write, and their trace.
   60 runs in one block are about 3.3 s. Open: the next change makes this run cheaper.

Hub matrix after the fence (one repetition): at most 3 script runs at once in every size (40–60
before); 60 / 40 phase burst, last cover at 6.2 s (step 3: 8.5 s), longest stall 3.8 s (4.7 s);
reload stall unchanged at about 4.3 s. Core suites: 117 PASS.

The suspend script still waits per call for its own write; the hand test can show the same pattern.

## Cheaper publish run: three dicts instead of about 100 variables (2026-11-10)

Hub spike: 12 `if` steps took 47 ms with 100 template variables, 32 ms with 100 constants, and 8 ms
with 3. HA walks every variable in scope at every step (trace snapshot, scope lookups). The publish
run of `cover_DayNight` had about 100 variables in scope.

Change: `cfg` (raw inputs), `d` (every derived value, one template), `inst` (instance part). Steps read
`d.*` / `inst.*`. The fingerprint hashes the same values; its prefix is now `fp2:`, and a stored `fp1:`
is accepted as matching (checked on the hub: same hash `84c7…`, no re-publish on reload).
`ci/check-fingerprint.js` now reads `cfg.<name>` as the input `<name>`, so a changed default of a
hashed input is still caught (checked with a changed `time_open_workday` default).

Single publish run on the hub: steps before the request call 7–8 ms (before: about 20 ms). Reload
with 60 first publishes: longest stall 2.9–3.2 s (fence: 4.5–5.6 s; before the fence 5.7–7.1 s).

Hub matrix (one repetition):

| Size, hub | Code | Idle stall | Phase: last cover moves | Phase stall | Reload stall |
| --- | --- | --- | --- | --- | --- |
| 40 / 30 quiet | step 3 | 264 ms | 4.5 s | 2.7 s | 2.8 s |
| 40 / 30 quiet | fence | 265 ms | 4.9 s | 3.4 s | 2.8 s |
| 40 / 30 quiet | dicts | 57 ms | 2.6 s | 1.3 s | 1.9 s |
| 60 / 40 quiet | step 3 | 459 ms | 8.5 s | 4.7 s | 4.3 s |
| 60 / 40 quiet | fence | 508 ms | 6.2 s | 3.8 s | 4.3 s |
| 60 / 40 quiet | dicts | 82 ms | 5.4 s | 2.5 s | 4.1 s |
| 60 / 40 busy | dicts | 72 ms | 4.9 s | 2.0 s | 2.7 s |

Tests: short and long suites 159 PASS; the 5 that expected `fp1:` or a `todays_sunrise` variable are
updated (4a-6 now tests the real upgrade path, a stored `fp1:`) and pass, 31 PASS.

Custom actions and conditions (Danger Zone) that read a decision variable by name must use the new
name, e.g. `inst.desired_position`. Noted in the 3.2.0 release notes.
