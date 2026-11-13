# Second-0 block: one holistic recommendation

Status: **analysis only**, 2026-11-11. No code changed. No hub test was run for this report.
This report replaces the recommendation of `2026-11-11-second-0-block-options.md`. That file stays as it is.
Every value marked "estimate" comes from the model in section 3, not from a measurement.

## 1. Summary

- **At real installation sizes the block is small.** The largest installation has about 22 cover automations.
  Estimate for it: phase stall about 1 s. At 8 automations (90th percentile): about 0.15 s. At 1 automation: no block.
- The 60 / 40 test is about 3 times the largest real installation. The targets at 40 / 30 and 60 / 40 are not field cases.
- So the work shifts. The block is one of five points, and not the largest one:
  1. **Leave second 0.** One line per blueprint. Certain gain, no risk.
  2. **Make the button path fast.** Estimate: 285–640 ms today, 90–160 ms after the change.
  3. **Give transition publishes a slot**, with a shared slot script in `smarli_core.yaml`. Self-organised, no wait for small houses.
  4. **Remove the 3.1.3 compatibility code** now, while no instance is in the field.
  5. **Decide the tracker layout** (one sensor per family) before the second family is built.
- Three statements of my first report were wrong or not proven. Section 2 lists them.

## 2. Assumptions: confirmed, rejected, open

| # | Assumption | From | Result | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Largest real installation has about 22 cover automations; median 1 | Lead | **Confirmed in size.** My count with a wider name pattern: 22 at installation 21, 13 at installation 68, 8 at four others. Median 0–1. | `hubents/*-entities.json`, own count |
| 2 | 76 installations have covers; installation 21 has 109 covers | Lead | **Differs with the filter.** My count: 92 files have a `cover.*` entity that is not disabled; installation 21 has 132. Does not change a conclusion. | Same |
| 3 | Total automations per installation | Own | **New.** Median 13, 90th percentile 35, most 73. This is the size of a reload burst across all families. | Same |
| 4 | Only `cover_DayNight` uses the tracker | Lead | **Confirmed.** No other file in `automation/` and no other package fires a tracker event. | `grep` in both repositories |
| 5 | No `cover_DayNight` instance is in the field | Lead | **Open.** The entity registers do not show the blueprint of an automation. The spec names real Somfy covers on `mssw` with `manual_check` runs on 2026-11-02. So `mssw` ran the cover package then. | Spec, spike S2 |
| 6 | The test's reload stall is a cold start | Lead, own | **Confirmed, but incomplete.** See 7. | `run.mjs` lines 245, 288 |
| 7 | "The reload stall is mostly our publish runs" | Own, first report | **Rejected in part.** A full reload validates every automation config again, also when the automation is kept. In the profile of 2026-11-09 that was 3.3 s of 12.3 s profiled (72 items, 46 ms each, profiler overhead included). | `results/prof3.txt` |
| 8 | "A gated run costs about 1 ms" | Own, first report | **Rejected as proven.** The heartbeats are 7.5 ms apart at 60 automations. Any gated run below 7.5 ms gives the same idle stall. So: at most about 7 ms, not known. | Section 3 |
| 9 | "About 10 ms of a run come before the request" | Own, first report | **Open.** S5 measured 70 % before the write, but before the dicts step. The "20 → 8 ms" of the dicts step is not in any result file I found. The CLAUDE.md value (47 ms → 8 ms for 12 steps) is from a synthetic spike. | Section 3 |
| 10 | "The tracker write is about half of a run" | Own, first report | **Open.** In the profile before the dicts step the tracker update was 1.07 s of 12.3 s (18 ms per write, profiled). Its share now is not known. | `results/prof3.txt` |
| 11 | Listeners get a random offset of 0.05–0.5 s | Lead, own | **Confirmed.** Drawn once per registration, kept for every firing. Skipped only when hour, minute and second are all unset or `*`. | `helpers/event.py` |
| 12 | `time_pattern` uses that helper | Open in first report | **Confirmed.** It calls `async_track_time_change`. `seconds` defaults to 0 when only `minutes` is set. | `triggers/time_pattern.py` |
| 13 | A `time` trigger with a fixed `at:` fires at the exact second | Own | **Rejected.** It uses the same helper, so it fires 0.05–0.5 s after its second. An `input_datetime` with a date fires exactly. | `triggers/time.py` |
| 14 | A `time_pattern` field can be a template | Own | **Rejected.** Only `*`, `/N` or a number. So a per-instance second in the trigger is not possible. | `triggers/time_pattern.py` |
| 15 | A UI save fires `automation_reloaded` and reloads one automation | First report | **Confirmed.** | `config/automation.py`, `automation/services.py` |
| 16 | `script.turn_on` returns at once; a direct script call blocks | Lead | **Confirmed.** `turn_on` returns after the first state write of the run. | `script/services.py`, `script/entity.py` |
| 17 | The script attribute `current` is written at each run start and end | Own | **Open in the source** (the call sites are in a file I did not read). Indirectly confirmed: the skip rule of `smarli_cover_request` depends on it and passed 200 bursts on the hub (S6). | Spec, S6 |
| 18 | A trigger starts the run inside the listener, with no yield | Own | **Confirmed by the profile** (`create_eager_task` in the trigger path), not read in the source (`helpers/trigger.py` returned 404). | `results/prof3.txt` |
| 19 | The blueprint is `mode: queued`, `max: 35`, `max_exceeded: silent` | Lead | **Confirmed.** It does not follow the CLAUDE.md rule. See section 4.6. | `cover_DayNight.yaml` lines 2019–2021 |
| 20 | The custom actions run after the covers move | Lead | **Rejected as a guarantee.** The mover is started non-blocking. The actions run after the move is started, not after it ends. In a burst, N − 2 callers skip the resolver, so their actions already run before the resolver decides. | `docs/cover-architecture.md` line 252, `smarli_cover.yaml` line 394 |

## 3. Cost model, reconciled

Measured after step 5 (quiet, worse of 2 repetitions): 21.5 / 33 / 40 ms per transitioning run at 7 / 13.9 / 20.1 KB.
Fit: **about 11.6 ms + 1.4 ms per KB of tracker.** First cover = stall + about 0.9 s.

What one run consists of, and what is known about each part:

| Part | Known | Not known |
| --- | --- | --- |
| g: trigger variables and conditions | At most about 7 ms after the dicts step (idle stall) | The real value |
| p: action steps up to the request call | S5, before dicts: 20–35 ms | The value after dicts |
| w: tracker write | S5: 8 ms + 0.7 ms per KB | Why the fit shows 1.4 ms per KB |
| t: rest of the request and end of the run | — | All of it |

- S5 (70 % before the write) and my first report (10 ms before the request) do not contradict each other. S5 is from before the dicts step. The dicts step removed 21 ms per run at 60 / 40 (stall 3.6 → 2.3 s). Where it removed them is not measured.
- Bounds at 60 / 40, where the run is 40 ms: w = 22 ms by S5, so g + p + t = 18 ms. If the slope of 1.4 ms per KB is all write, w = 36 ms and g + p + t = 4 ms.
- **So g + p is between 4 and 18 ms. The profile must give the value.** The design rule in section 4.3 uses it.

The tracker at real sizes (estimate): about 0.2 KB per intent, 0.035 KB per cover in an intent, 0.1–0.15 KB of per-cover keys.

| Installation | Tracker | Per run | Phase stall | First cover | Resolver render |
| --- | --- | --- | --- | --- | --- |
| 1 automation, 12 covers | 2 KB | 14 ms | no block | 0.6–1.1 s | about 11 ms |
| 8 automations, 27 covers | 5 KB | 19 ms | 0.15 s | 0.8–1.2 s | about 30 ms |
| 22 automations, 132 covers | 22–29 KB | 43–52 ms | 0.9–1.15 s | 1.8–2.1 s | about 300 ms |

- All values in this table are estimates.
- At installation 21 the per-cover keys are most of the tracker, not the intents. Many covers make every write slow, also with few automations.
- The resolver render follows intents × covers. 22 × 132 is about the same as 60 × 40 (251 ms, S5).

## 4. The recommendation

One change set. Package first, then the blueprint. Points 4.1, 4.2, 4.5 and 4.6 do not depend on a measurement.

### 4.1 Never second 0

- Each family's heartbeat gets a fixed second that is not 0: `seconds: 2` for cover, then 4, 6, … for later families.
- A table in CLAUDE.md holds the second of each family.
- Why it helps although every listener has its own offset of 0.05–0.5 s:
  - every default `time_pattern` and every `time` trigger of a customer automation fires in second 0;
  - a template that uses `now()` is rendered again at the start of each minute;
  - our block then adds to that work, and their work waits behind our block.
- Cost: a phase change comes 2 s later. "Close at 20:00" starts at 20:00:02.
- The random offset stays. It spreads our N heartbeats over 0.45 s for free.
- `automation_reloaded` and `homeassistant: start` have no offset. Every blueprint of every family runs at the same instant. That case needs 4.3.
- The load test measures from the minute. `run.mjs` must add the family second.

### 4.2 The button path: near-immediate

A request is an **event request** when its intent has `transition: false` (custom trigger, button, later families).

Changes, all in `smarli_cover.yaml`:

- **Collect window 30 ms** for an event request, not 200 ms.
  - 30 ms is enough for a second automation on the same button to queue its run. Then one run resolves both, and no cover starts and reverses.
  - A window of 0 saves 30 ms more. Then two automations with one cover on one button can give that start-and-reverse. Not recommended.
- **No fence for a run that never waited in the queue.** The request passes `queued` (was `current` at least 1 at the call?).
  - A caller can skip only while a run waits in the queue. A run that started at once and has no run behind it had no skipped caller.
  - Its own caller's intent comes in the call field. So it needs no fence write and no wait.
- **Scoped resolve for that same run:** only the covers in the caller's intent, not every cover on the hub.
  - Other covers have no new input. The next transition run resolves all covers again and cleans expired markers.
  - A run that waited in the queue stays unscoped.
- **Log lines after the mover is started**, not before.
- **No legacy check** in the request (see 4.5).

Latency from the trigger to the cover command, one automation on the button (estimate):

| Step | 1 automation, 12 covers | 8 automations, 27 covers | 22 automations, 132 covers |
| --- | --- | --- | --- |
| Blueprint run up to the request | 15 ms | 15 ms | 20 ms |
| Intent write | 9 ms | 12 ms | 26 ms |
| Collect window | 200 → 30 ms | 200 → 30 ms | 200 → 30 ms |
| Fence write and wait | 9 → 0 ms | 12 → 0 ms | 26 → 0 ms |
| Resolver render | 11 ms | 32 → 13 ms | 300 → 23 ms |
| Batch write | 9 ms | 12 ms | 26 ms |
| Log lines before the command | 18 → 0 ms | 5 → 0 ms | 9 → 0 ms |
| Mover: marker write and command | 14 ms | 17 ms | 31 ms |
| **Total today** | **285 ms** | **305 ms** | **640 ms** |
| **Total after the change** | **88 ms** | **99 ms** | **156 ms** |

What else can be cut, not in the recommendation:

- The marker write of the mover can go into the resolver's batch write: 9–26 ms. Medium change, touches the marker contract.
- The intent write can go into the resolver's batch write for a run that never queued: 9–26 ms. Risk: a run that ends early loses the intent.
- One tracker sensor per family (4.7) makes every one of the three writes cheaper.

### 4.3 Transition publishes take a slot; the mechanism is shared

A request is a **transition request** when its intent has `transition: true` (heartbeat, reload, start).

**New in `smarli_core.yaml`: `script.smarli_slot`** (`mode: parallel`, `max: 200`, `max_exceeded: warning`).

- A caller calls it and gets its turn when the script returns.
- The wait is `(runs of smarli_slot that already wait − free) × slot`, never below 0.
  - This is a dense rank with no store: the k-th caller of a burst sees k − 1 waiting runs.
  - `free` = the callers that need no slot. Start value 3 (3 runs are about 0.1 s). One automation never waits.
  - `slot` = about one run. Start value 40 ms. The hub session gives the value.
- It is in the core because reload and start hit every family at the same instant. A slot per family would let two families collide.
- Rule for every family: a transition publish takes a slot. An event request never does.

**Where the wait goes: variant a, in the package.**

- `smarli_cover_request` starts a separate run with `script.turn_on` for a transition request and returns at once.
- That run takes its slot, writes the intent, and makes sure a resolver run exists (the skip rule as today).
- The automation run ends at once. A cover state change is classified without a wait.
- An event request stays as today: direct write, blocking resolver call.

**The resolver waits for the last slot, not for a clock.**

- For a transition request the 200 ms window becomes: wait until no `smarli_slot` run is left, with a timeout.
- No deadline to compute and no burst start to agree on. This removes the open point of my first report.
- The skip rule and the "fresher run" check stay. A burst still ends in at most 2 resolver runs, one of them full.
- All covers of the burst start together.

**Why not variant b (wait at the start of the blueprint run).**

- With `mode: queued`, a cover state change waits behind the waiting run. Scenario: the phase changes at 20:00:02. A person closes a cover by hand at 20:00:02.4. The automation waits for its slot until 20:00:02.8. The resolver opens the cover at 20:00:03.2. The manual check runs after that. The person's move is undone, and the pause comes too late.
- With `mode: parallel` that scenario is gone. But a technician's custom actions can then run two at a time, and a heartbeat run and a button run of one automation overlap. That changes the contract of every custom action.
- Manual detection cannot leave the blueprint. A package automation has no list of covers for its trigger. A trigger on the tracker or on every state change is rejected in CLAUDE.md.
- Variant a has the same hazard for nobody: no automation run waits.

**The decision rule for the profile:**

- Variant a leaves g + p of every run in one block. That block is N × (g + p).
- **If 22 × (g + p) is 0.3 s or less (g + p at most about 14 ms): variant a.**
- If it is more: first cut p (fewer `if` steps before the request). Variant b with `mode: parallel` only if that fails.
- From the bounds in section 3 (g + p between 4 and 18 ms) variant a is likely, not certain.

Expected values with 4.1–4.3 (estimates):

| Installation | Phase stall today | After | First cover today | After |
| --- | --- | --- | --- | --- |
| 1 automation, 12 covers | no block | no block | 0.6–1.1 s | 0.4–0.9 s |
| 8 automations, 27 covers | 0.15 s | 0.1 s | 0.8–1.2 s | 0.6–1.1 s |
| 22 automations, 132 covers | 0.9–1.15 s | 0.3–0.4 s | 1.8–2.1 s | 1.8–2.2 s |
| 60 / 40 (test only) | 2.4 s | 0.6–1.1 s | 3.4 s | 3.3–3.7 s |

- "After" is counted from the family second, not from second 0.
- At 22 / 132 the longest block after the change is the resolver render (about 0.3 s). A resolver in chunks (`repeat: while`, the one loop that yields) is the next step only if the hub session shows more than 0.5 s.

### 4.4 A guard so a delayed write never replaces a newer intent

- With a separate wait run, two writes of one automation can cross. Scenario: the heartbeat decides "close" at 20:00:02.3 and waits for its slot. A button opens the covers at 20:00:02.5 and writes at once. The delayed heartbeat write arrives at 20:00:02.9 with the older `ts`. Without a guard it replaces the button's intent and the covers close.
- A check in the script (read, compare, write) is not safe. The button's write can be fired and not yet rendered.
- **Recommendation: the compare goes into the tracker render.** `smarli_tracker_set` gets an optional field `newer_by` (the name of a field in the value, here `ts`). The render keeps the stored value when its `ts` is higher. About 3 lines in `smarli_core.yaml`.
- This keeps the atomicity rule: the key is still the unit, and the merge is still inside the one render.
- **The order of the custom actions changes** on the transition path: they run before the covers start, by up to the slot wait plus the resolver (estimate: at most 1.5 s at 22 automations).
  - This is already so for most callers of a burst (assumption 20). The Danger Zone text must say "after the request", not "after the move".
  - On the event path the order stays as today.

### 4.5 Remove the 3.1.3 compatibility code

What exists only for instances from before 3.2.0:

| Where | What |
| --- | --- |
| `smarli_cover.yaml` | Automation `smarli_cover_namespace_migration` (about 45 lines) |
| `smarli_cover.yaml` | The read of `shared` in the resolver (`tracked`, `intents`) and in three more intent readers |
| `smarli_cover.yaml` | The step "Remove the caller's intent from before 3.2.0" in `smarli_cover_request` |
| `smarli_cover.yaml` | The resolver field `transition` and `forced_owner` (the flag is in the intent since 3.2.0) |
| `cover_DayNight.yaml` | The `shared` fallback for the own intent and for the watcher's intent |
| `cover_DayNight.yaml` | The fallbacks for an intent without `phase` or without a fingerprint (before 3.1.2) |

- Gain: about 80 lines, one template per request, one loop over `shared` per resolver run. Mostly less to read and to test.
- What still needs it:
  - **`mssw`**, if it still runs 3.1.3 (assumption 5). It then needs a re-import and one clean tracker.
  - **The runtime suites** that test the migration and the old intent path. They go with the code.
  - **The load test baseline** (`m_baseline`). It runs 3.1.3 with the package from `main`, so it is not affected.
- A clean tracker has one effect: at its first decision every automation commands its covers once, and running pauses are lost.

### 4.6 Queue rule for blueprints

- `cover_DayNight` has `max: 35` and `max_exceeded: silent`. A dropped run is a missed manual detection, and nobody sees it.
- Conditions run before a run enters the queue. So gated runs do not fill it, and 35 is not a real risk today.
- Recommendation: `max_exceeded: warning`, and `max: 200` to match the package rule. Extend the CLAUDE.md rule to blueprints.
- `mode: queued` stays (variant a).

### 4.7 The tracker when more families come

- Every write renders the whole tracker: 8 ms + 0.7 ms per KB (S5). A write of family A pays for the keys of family B.
- At installation 21 the cover keys alone are 22–29 KB (estimate). Every write of a later family there costs about 25 ms, not 9 ms.
- **Recommendation: one tracker sensor per family, defined in the family's package**, with the same four events and an `event_data` filter on `namespace`. `smarli_core.yaml` keeps `shared` and the garbage collection, which then reads every `sensor.smarli_tracker_*`.
- The spec rejected this ("size was not the problem"). S5 came later and showed that size is a cost. The reason is out of date.
- Now is the cheap moment: no instance in the field, one reader family. The change touches every tracker read in the blueprint, the package and the tests.
- It also makes the three writes of a button press cheaper for every family except the largest.
- Rules that hold with either layout:
  - a family's steady size has a budget (proposal: 5 KB at a median house);
  - a heartbeat run that changes nothing writes nothing;
  - a reload or start run that changes nothing stays in `conditions:`.
- The burst store of my first report (option 2a) is not needed at real sizes. It stays an option for installation 21 only.

## 5. The hub session

| # | Measurement | What it must decide |
| --- | --- | --- |
| 1 | Matrix at 22 automations / 109 covers, quiet and busy (planned). Better: 22 / 132, the real count. | Is the estimate of about 1 s right? Above 0.5 s: build 4.3 for cover now. Below: 4.3 is still built in the core, for reload and later families, but not urgent. |
| 2 | One profile of a **phase** burst, not of a reload (planned). A reload adds the config validation. | g, p, w and t of section 3. Variant a or b (rule in 4.3). The slot length. Why the fit shows 1.4 ms per KB. |
| 3 | Button latency at 1, 8 and 22 automations, with step times from the trace (planned). | The table in 4.2: today's values, then each cut. Window 30 ms or 0. Is the scoped resolve worth it at 8? |
| 4 | **Added: spacing spike.** 22 request calls at once, then 30, 40 and 50 ms apart (`spikes.mjs`). | That a slot removes the block, and the slot length. Reject 4.3 if the ping delay stays above 0.3 s at 50 ms. |
| 5 | **Added: warm reload.** "Reload automations" with an intact tracker at 22 cover automations, and one UI save. | The share of Home Assistant's config validation. The cost of N gated runs at one instant (this gives g). It is the reload a technician really causes. |
| 6 | **Added: tracker write with a second namespace of 10 KB.** | 4.7: is one sensor per family worth the change? |
| 7 | **Added, on the local rig: a hand move during the slot wait.** | That the cover is paused and not moved (the scenario in 4.3), and that `current` of `smarli_slot` counts as section 4.3 needs. |
| 8 | **Added, on the local rig: a button press during a transition burst of the same automation.** | The guard of 4.4. |

Order: 2 and 5 first (they feed the design rules), then 1, 3, 4, 6.

## 6. Questions for Pascal

1. **The family second.** With `seconds: 2` a schedule of "close at 20:00" starts the covers at about 20:00:02.5. A customer who watches the clock sees 2 s. Is a small second (2, 4, 6) right, or do you want the families far apart (for example 10, 20, 40) so that a long block of one family never reaches the next?
2. **What "near-immediate" means in numbers.** The estimate after the change is about 90 ms at a normal house and about 160 ms at installation 21, from the button event to the cover command. The motor's own reaction comes on top. Is 0.2 s the target for the hub test, or do you want the 30 ms window removed too, with the risk that two automations with one cover on one button start it and reverse it?
3. **The custom actions on a scheduled phase change.** A technician adds "switch off the terrace light" as a custom closing action. Today it runs right after the close is requested. After the change it can run up to about 1.5 s before the covers start at a large installation. Is that acceptable, with a new sentence in the Danger Zone text? If an action must see the covers already commanded, the transition path would have to block again, and then a hand move in that second can be undone.
4. **`mssw` and any pilot.** Does `mssw` still run 3.1.3 with real covers? If yes: at the switch to a package without the migration, its covers are commanded once at the first decision and a running pause is lost. Is a re-import at a quiet time acceptable, or must the migration stay for one more release?
5. **One tracker sensor per family.** It is cheap now and costly after the second family is in the field. At a median house it saves a few milliseconds per write. At installation 21 it saves about 15 ms on every write of every other family. Do you want it in this change set, or do you want measurement 6 first?
6. **The peak-run KPI.** With slots, up to N runs of the wait script and N runs of `smarli_slot` wait on a timer. At 22 automations that is 44 waiting runs against a target of 33 (25 % of 132 covers). They do no work while they wait. Should the KPI count only runs that execute, or should the wait run read `current` itself so that only N runs wait?
7. **The targets.** The targets at 40 / 30 and 60 / 40 are above any real installation. Should the budget table move to real sizes (1 / 12, 8 / 27, 22 / 132) and keep 60 / 40 only as a stress test with no pass criterion?

## 7. What changes against the first report

- The 110-automation case is gone. The largest real case is 22.
- The slot uses the count of waiting runs, not a rank among all intents. So a lone automation never waits, and no deadline is computed.
- The resolver waits for the last slot run, not for a time.
- The wait run is separate, so no automation run stays open. The manual-detection delay of the first report is gone.
- The reload stall is not only our publish runs. Home Assistant validates every config on a full reload.
- The burst store is no longer part of the recommendation.
