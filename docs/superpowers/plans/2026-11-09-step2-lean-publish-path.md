# Step 2: leaner publish path

Design: `docs/superpowers/specs/2026-11-04-cost-budget-architecture-design.md`, sections 5
and 6. Branches: `feat/cost-budget-architecture` in `ha-packages` and in `smarli-blueprints`.

## Found before building (2026-11-09)

- **The skip rule loses the transition force.** `transition: true` is a field of the caller's
  resolver call. It makes the resolver command a cover that it believes is already at the
  target (a remote moved it unseen, the mssw case). A caller that skips the call has no run
  to pass the field to. In a burst, only the caller of the waiting run would force its
  covers. S6 checked lost intents, not lost forces. Fix: the flag moves into the intent
  (`transition: true|false`), and the resolver remembers per cover which transition it has
  applied (`<cover>::applied` = the `ts` of that intent). A cover is forced when its winning
  intent has `transition: true` and a `ts` newer than `<cover>::applied`. The resolver is the
  only writer of `<cover>::applied` and writes it only for the covers it forced this way, so
  a normal run costs no extra write. The `transition` field of the resolver call stays, so
  blueprints before 3.2.0 keep working while the package rolls out first.
- **Steps in one script do not let HA work in between.** HA 2025.4.4,
  `helpers/script.py`: the step loop awaits each step (line 456), and a step with only
  variables, events or conditions never suspends. `if`, `choose` and `repeat` with `for_each`
  or `count` start their sequence as an eager task, which does not suspend either. Only
  `repeat` with `while` or `until` yields (`asyncio.sleep(0)`, lines 884 and 931), and so do
  a `delay` above 0 and a wait that is not already true. Also, the "stall" in the load test is
  the wait behind all queued work, and splitting does not make that work smaller.
  **Decision:** the resolver is not split into steps. It is made cheaper instead (below).
  If the hub load test still shows a resolver block above 100 ms at 40 / 30, a `while` loop
  over batches of covers can add the yields later.

## Found while building (2026-11-09)

- **Without a suspension, the skip never happens.** A resolver run has no step that yields,
  so it finishes in about 15 ms before the next caller's check. No run ever waits in the
  queue, `current >= 2` is never true, and a burst of 20 callers gave 20 full runs, back to
  back (traces; counted with `script_started`). S6 passed only because its callers did not
  wait for their write to be visible. **Fix:** the resolver starts with a 200 ms collect
  window (`delay`). The next caller queues a second run, every later caller skips, the first
  run ends at the existing "fresher run queued" check, and the second run reads all intents.
  Result: 2 resolver runs per burst of 20, one of them full. Cost: a decision comes 0.2 to
  0.4 s later.
- **Load test on the local rig, 40 automations / 30 covers** (`load-test.ps1`, PC):
  resolver peak runs 36 → 2 at the reload burst and 12 → 2 at the phase change; all covers
  reached their targets; no "exceeded" warning. The full resolver run spends 20 ms in its
  variables step. `smarli_cover_request` peaks at one run per caller (40 at the reload): these
  runs only wait until their own write is visible. The budget target "highest run count of
  any script" (section 1) does not fit a parallel script whose runs wait and do no work. It
  needs a written decision before the merge, from the hub load test.
- **The tracker GC removes the keys of a cover without an entity** 10 s after a reload. The
  test's ghost covers wait for that sweep first.
- **The logbook does not count script runs.** It logs a script turning on, not every run of
  a parallel or queued script. The test counts `script_started` events instead.

## Package (`ha-packages/packages/smarli_cover.yaml`)

1. New script `smarli_cover_request` (fields `owner`, `intent`; `mode: parallel`,
   `max: 200`, `max_exceeded: warning`):
   1. Publish `<owner>::intent`.
   2. Wait until the tracker shows it (timeout 2 s).
   3. Call the resolver (blocking), unless the write is visible and
      `script.smarli_cover_resolve` has `current >= 2`. In queued mode that means a run has
      not started yet, and it reads the tracker after the write is visible.
2. Resolver:
   - The force rule above, plus `<cover>::applied` for the covers forced by it.
   - Cheaper render: one map of the live automations (id → entity id, name) instead of a
     `states.automation` scan per cover in `decisions` and `watcher_changes`; lists of pairs
     turned into a dict once, instead of rebuilding a dict on every loop pass.
3. File header: document `smarli_cover_request`, the intent field `transition` and
   `<cover>::applied`.

## Blueprint (`automation/cover_DayNight.yaml`, still 3.2.0)

1. The intent carries `transition` (true for the heartbeat, reload and start triggers,
   false for custom triggers).
2. The open and close steps call `script.smarli_cover_request` (one step) instead of the
   tracker event plus the resolver call (two steps).
3. 3.2.0 is not released yet (only on this branch), so step 2 joins its release notes
   instead of a 3.3.0 nobody would install on its own. Release note: needs the package
   with `smarli_cover_request`; with an older package the covers do not move.

Baseline and result: the step durations of one transitioning heartbeat run and of one
resolver run at 40 / 30, from traces on the local rig (`load-test.ps1`), before and after.
Further cuts in the blueprint's publish path follow these numbers, not a guess.

## Tests

New suite `tests/test-request.ps1`:

- A request publishes the intent and the cover moves (single caller).
- A burst of callers: every intent is applied, and the resolver runs fewer times than there
  are callers.
- Callers spread out in time (one every 0.2–1 s), the case S6 did not cover: no intent
  lost.
- The transition force survives a skip: in a burst, a cover that was moved unseen while its
  stored position is unchanged is commanded again, also when its caller skipped.
- A repeat publish without `transition` does not command an unchanged cover.
- An old-style call (`smarli_cover_resolve` with `transition: true`, no `transition` in the
  intent) still forces.

Then all existing suites, `ci/checks.sh`, `ci/check-release.sh` and `check-config.ps1`.
