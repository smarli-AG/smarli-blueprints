# Step 1: cheap blueprint runs and early manual-detection checks

Design: `docs/superpowers/specs/2026-11-04-cost-budget-architecture-design.md`, sections 2
and 3. Branches: `feat/cost-budget-architecture` in `ha-packages` and in `smarli-blueprints`.

## Package (`ha-packages/packages/smarli_cover.yaml`)

1. `smarli_cover_suspend` writes `<cover>::suspended_at` (now) each time it writes a
   suspension. Single writer: the script is queued.
2. `smarli_cover_resolve` writes `<cover>::watcher`: the entity id of the automation that
   watches the cover and won its decision, else the lowest-id live automation whose intent
   names the cover and watches it. An intent without `watches` counts as watching (all
   intents published before this change come from `cover_DayNight`). Written only when the
   value changes; removed when no watcher is left. Single writer: the resolver is queued.
3. File header: document both keys and the intent field `watches`.

## Blueprint (`automation/cover_DayNight.yaml`, 3.1.3 → 3.2.0)

1. Top-level `variables:` shrink to an anchored base block (`&base`): instance id, covers,
   suspension settings. Every trigger needs only these.
2. The decision block moves into the heartbeat trigger's `variables:` (`&decide`, merging
   `*base`). The reload and start triggers reuse `*decide`. The cover state trigger and the
   custom triggers get none.
3. Custom triggers get their own `choose` branch. It renders `*decide` once as an action
   step, then runs the same open and close steps as the heartbeat (YAML anchors, so the
   steps exist once in the file).
4. A new condition for the cover state trigger, cheapest first, each ending the run in
   `conditions:`: no new state; a `parent_id` (caused by an automation, first 5 s); a live
   smarli. marker on this cover while no user is in the context; not the elected watcher;
   a pause on this cover written less than 60 s ago.
5. The manual-detection branch calls `manual_check` even when this automation's own
   suspension is off. It then passes a fallback duration of 0, so the pause length still
   comes only from the live intents.
6. The intent carries `watches: true`.

Deviation from the design: the "smarli. is moving this cover" check scans this cover's
per-run marker keys (`<cover>::moving_<run>`) instead of reading one key. One per-cover
key would need a read-modify-write across parallel mover runs, which the tracker does not
make atomic. The scan runs only on cover state changes and touches only this cover's keys.

## Changes found during the build

- `this` is not defined in trigger variables. The part of the decision that needs the
  automation's id moved to the top level, guarded by `decide_ready`, as the `instance`
  block. Custom triggers render `*decide` and then `*instance`.
- A watcher counts only while it is on and its own intent still names the cover and
  watches it; a stale key would otherwise leave the cover unwatched.
- A custom trigger with the id `heartbeat` takes the custom-trigger branch and is gated
  there.

## CI

`ci/check-fingerprint.js` finds `schedule_fingerprint` and its `!input` sources at any
indent. Today it looks only at 2 spaces and would pass silently after the move.

## Tests

New suite `tests/test-cheap-paths.ps1`:

- A cover state change run carries none of the decision variables (trace of the run).
- `suspend` writes `<cover>::suspended_at`.
- The resolver writes `<cover>::watcher` for the winning watching automation, and falls
  back past a winner with `watches: false`.
- A state change within 60 s of a pause calls no `manual_check`.
- A second automation on the same cover that is not the elected watcher calls no
  `manual_check`.
- A user's change during a smarli. move still reaches `manual_check` (layer 1).

Then all existing suites (`run-short.ps1`, `run-long.ps1`), `ci/checks.sh`,
`ci/check-release.sh` and `check-config.ps1` on 2024.10 and 2025.4.
