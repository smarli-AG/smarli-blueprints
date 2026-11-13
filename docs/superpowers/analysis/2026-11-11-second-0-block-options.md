# Second-0 block of the cover family: options and recommendation

Status: **analysis only**, 2026-11-11. No code changed. No hub test was run for this report.
Every number marked "estimate" comes from the model in section 2, not from a measurement.

Inputs: `docs/superpowers/specs/2026-11-04-cost-budget-architecture-design.md`,
`docs/superpowers/plans/2026-11-11-hub-matrix-all-phases.md`, `automation/cover_DayNight.yaml` 3.2.0,
`smarli_cover.yaml` and `smarli_core.yaml` (`ha-packages`, branch `feat/cost-budget-architecture`),
`test/hub-load/run.mjs`, and the Home Assistant core source (branch `dev`, read 2026-11-11).

## 1. Summary

- The block is N publish runs that start in the same half second. Each run costs 21–40 ms. No run yields.
- The cost per run grows with the tracker size. So the block grows with the square of the installation size.
- A cheaper write alone does not reach the targets. About 20 ms per run stay, also with a perfect store.
- A central evaluator reaches the targets. It cannot run custom conditions, custom actions or the forecast call.
- **Recommendation: slotted publish with one settle deadline, in the package only** (section 5).
  - `smarli_cover_request` gives each caller its own time slot before the intent write.
  - `smarli_cover_resolve` runs once, after the last slot. All covers still start together.
  - Estimated phase stall: 0.2 / 0.4 / 0.6 s at 20 / 40 / 60 automations (today 0.43 / 1.3 / 2.4 s).
  - Cost: the first cover command comes 0.3–0.5 s later than today. That needs a decision by Pascal.
  - It also removes the reload stall of the load test, because that stall is the same block.
- **First measurement:** one harness spike that sends the same 60 requests at once and then 35 ms apart (section 6).

## 2. What the block is

### 2.1 Facts from the Home Assistant source

| Fact | Source | Consequence |
| --- | --- | --- |
| A script run has no forced yield between steps. Only `repeat` with `while` or `until` yields between iterations. | `helpers/script.py` | A publish run is one block. A `repeat: while` loop is the only cheap way to split a long run. |
| Each `time_pattern` listener gets its own random offset of 0.05–0.5 s at registration. It keeps that offset. | `helpers/event.py` (`RANDOM_MICROSECOND_MIN` / `MAX`). Not confirmed: that `time_pattern` uses this helper. | The heartbeats are already spread over 0.45 s. At 60 automations that is 7.5 ms per automation, less than one run. So the runs still join into one block. |
| A save of one automation in the UI calls `automation.reload` with that automation's id. Only that automation is reloaded. The event `automation_reloaded` fires anyway. | `components/config/automation.py`, `components/automation/services.py` | Every save starts one run of every cover automation. With an intact tracker these runs are gated (about 1 ms each). |
| A full reload keeps every automation whose config did not change. | `components/automation/util.py` | "Reload automations" does not re-create 60 automations. It only fires the event. |

### 2.2 The reload stall of the load test is the same block

- `run.mjs` removes every test key from the tracker before it calls `automation.reload` (line 245, line 288).
- So every automation reads "never run" and publishes a first intent.
- The reload stall (1.9 s at 40 / 30, 2.7–4.3 s at 60 / 40) is N first publishes at one instant.
- Per automation that is 45–70 ms. The phase block costs 33–40 ms per automation. The values match.
- In the field, a reload with an intact tracker gives N gated runs: about 60 ms at 60 automations (the idle value).
- The full block at reload occurs in these cases only:
  - the first start after an installation;
  - a start or reload after a phase change that Home Assistant missed;
  - a tracker that was wiped.
- The split "Home Assistant re-creates automations" against "our setup runs" is therefore mostly answered. It is our runs.
- Not measured: the first repetition of each size creates the automations fresh. That part is real Home Assistant work.

### 2.3 Cost model

Measured after step 5, quiet hub, worse of 2 repetitions:

| Size | Phase stall | Per transitioning run | Tracker | First cover | First cover minus stall |
| --- | --- | --- | --- | --- | --- |
| 20 / 15 | 0.43 s | 21.5 ms | 7 KB | 1.3 s | 0.9 s |
| 40 / 30 | 1.3 s | 33 ms | 13.9 KB | 2.1 s | 0.8 s |
| 60 / 40 | 2.4 s | 40 ms | 20.1 KB | 3.4 s | 1.0 s |

- **Per run: about 11.6 ms + 1.4 ms per KB of tracker** (fit of the three rows).
- Spike S5 measured the write alone: 8 ms + 0.7 ms per KB. The fit shows twice that slope.
- So one of these is true, and only a profile can tell which:
  - a write costs more than S5 found (state write and listeners, not only the render);
  - another part of the run also grows with the size.
- **The tracker is mostly intents.** It grows by about 0.33 KB per automation (7 → 13.9 → 20.1 KB).
  - A separate sensor for the intents would be almost as large as the tracker. It gains little.
- **First cover = stall + about 0.9 s** at every size. The 0.9 s are:
  - the heartbeat offset (up to 0.5 s);
  - the collect window of the second resolver run (200 ms), which starts after the block;
  - the fence write, the resolver render (151 ms at 40 intents, 251 ms at 60, spike S5), two batch writes, the log lines and the mover.
- A gated run costs about 1 ms (idle stall 57–60 ms at 60 automations). So almost all of the 21–40 ms comes after `conditions:`.

Extrapolation to about 110 automations and 109 covers (estimate):

- Tracker about 37–40 KB. Per run 54 ms (S5 slope) to 68 ms (fitted slope).
- Phase stall **6–7.5 s**. First cover **7–8.5 s**.
- The resolver render grows with intents × covers. At 110 × 109 it can reach 1 s or more as one block. Not measured.
- **The stall grows with the number of automations that change phase in the same minute, not with the number of covers.**
  The 109-cover facility may have 10 automations with 11 covers each. Then its block is about 0.3 s.
  The number of cover automations per installation is not in the fleet data. It is worth one query.

## 3. The options

Estimates for stall and first cover are in section 4.

### Option 1: spread the decisions

Two variants. Both add a delay between the decision and the publish.

**1a. Spread with waves.** Each automation waits its offset. The resolver runs when intents arrive.

- Covers start in waves. The design rejected this ("covers that should move together must decide together").
- Each wave is one full resolver run. At 110 automations that is many renders of 0.25–1 s each.
- Not recommended.

**1b. Spread with one settle deadline.** This is the recommendation. See section 5.

- The publish runs get slots. The resolver waits for the end of the last slot and runs once.
- Covers start together, later than today.
- Total work does not change. It is cut into slices of one run each, with a turn for Home Assistant in between.

### Option 2: make each write cheaper

**2a. A burst store ("inbox").** A second trigger-based template sensor in `smarli_cover.yaml`.

- `smarli_cover_request` fires `smarli_cover_intent` in place of `smarli_tracker_set`.
- The inbox holds only the intents of the current burst. It is empty at rest.
- The resolver reads tracker intents plus inbox intents. The inbox wins.
- The resolver adds the inbox intents to the `smarli_tracker_set_many` it already sends. No extra write.
- Then it removes them from the inbox, each only if its `ts` is still the one it read.
- Gain: a write renders half the intents on average, not the full tracker.
- Blueprints in the field need no change. Their own intent is in the tracker again 1–3 s later.
- Risk: a custom trigger of the same automation inside that 1–3 s reads its old `phase`. It then publishes with the old phase, and the next heartbeat publishes once more. No wrong move.
- Restart: the inbox is restored like the tracker. A lost inbox entry heals: the automation sees its old intent and publishes again at the next heartbeat.
- Atomicity: one key per owner in the inbox, merged in one render. The remove compares the `ts` inside the render. The rules hold.
- The fence must move to the inbox sensor, because the order of renders holds per sensor only.

**2b. A sharded intent store.** 8 small sensors. The caller sends a shard number (hash of its id).

- A write costs about 9–10 ms at every size.
- 8 more entities, a reader that merges 8 attributes, and a migration of the intents out of the tracker.
- Blueprints up to 3.2.0 read their own intent from the tracker. So the tracker copy must stay, written by the resolver as in 2a.
- More mechanism than 2a for about 4–8 ms more gain per run. Only worth it at 100 automations or more.

**2c. No tracker write when the request carries the intent.**

- The resolver overlays only the intent of its own caller. In a burst, 2 of N callers start a run. The other N − 2 skip.
- A skipped caller has no other way to reach the resolver than a store. Home Assistant scripts share no memory.
- So this saves 2 writes per burst. Gain in a burst: none.
- For a single caller it saves one render (10–20 ms) if the resolver persists the intent in its batch write.
- Not worth a change alone. It comes free with 2a.

**2d. A smaller intent.** Shorter fingerprint, no empty `bounds`. About 270 → 180 bytes.

- Saves about 3–4 ms per write at 60 automations. Blueprint change. Minor. Take it with the next blueprint version.

### Option 3: one central evaluator

- A package automation renders every instance's decision in one run and writes all intents in one batch.
- The decision render is cheap (about 1 ms per instance). The block becomes about 0.1 s plus the resolver.
- What it breaks:
  - **Custom conditions, custom actions and the forecast call are blueprint inputs.** They can run only in the automation. A central run cannot use them.
  - An automation's settings are not readable from a template. Each instance must publish its settings to the tracker. That is about 85 values per instance in the store whose size is the problem.
  - About 400 lines of decision Jinja move to the package. The package then must match every blueprint version in the field.
  - "Trigger distributed, logic centralized" becomes "everything central" for this family.
- Change size: very large in both repositories. Two decision paths for as long as old blueprints are in the field.
- Not recommended now. It stays the end state if the targets must hold at 110 automations without a later first cover.

### Option 4: adaptive collect window and a resolver in chunks (new)

- **Deduct the queue time from the window.** The request passes `requested_at`. The resolver waits `200 ms − (now − requested_at)`.
  - Today the second resolver run waits 200 ms after a block that already lasted longer than 200 ms.
  - Gain: first cover about 0.2 s earlier at 40 / 30 and larger. No gain at 20 / 15, and no stall gain.
- **Split the resolver render with `repeat: while`** over chunks of covers. That loop is the one construct that yields.
  - It caps the resolver block at about 0.1 s. It matters above 60 automations and for option 1b.
  - Risk: a chunked resolver reads the tracker once at the start and must not read it again per chunk.
- Package only. Small (window) and medium (chunks).

### Option 5: publish before the minute (new)

- An automation with a `time` or `sun` schedule knows one minute early that it changes phase.
- It writes its next intent with an "effective at" time, spread over the minute before. One resolver run applies them at second 0.
- Stall about the resolver block. First cover about 0.6–1 s. Triggers stay distributed.
- What it breaks: brightness schedules, the weather block, the forecast call and custom conditions cannot be decided early. Those instances keep today's path. So there are two paths, and an intent gets a second meaning.
- Change size: large in both repositories. Not recommended as a first move.

## 4. Estimates per option

Phase stall, quiet hub. "110" means 110 automations that all change phase, with 109 covers. All values are estimates except "today" at 20–60.

| Option | 20 / 15 | 40 / 30 | 60 / 40 | 110 / 109 | Reasoning |
| --- | --- | --- | --- | --- | --- |
| Today | 0.43 s | 1.3 s | 2.4 s | 6–7.5 s | Measured; 110 from the fit |
| Target | — | 1 s | 1.5 s | — | Quiet value must be 25 % lower |
| 1a waves | 0.15 s | 0.3 s | 0.4 s | 1 s or more | One resolver render per wave |
| **1b slots, one deadline** | 0.2 s | 0.4 s | 0.6 s | 1.1–1.5 s | N × about 10 ms before the request; at 110 the resolver render |
| 2a inbox | 0.3–0.37 s | 0.85–1.1 s | 1.4–1.9 s | 3.3–5.2 s | Saves 3 / 6 / 8 / 18 ms per run (S5 slope), twice that with the fitted slope |
| 2b shards | 0.3–0.35 s | 0.65–1.0 s | 0.9–1.6 s | 1.7–4.4 s | Write about 9.5 ms at every size |
| 2c skip write | 0.43 s | 1.3 s | 2.4 s | 6–7.5 s | Saves 2 writes per burst |
| 3 central | 0.15 s | 0.3 s | 0.4 s | 1–1.5 s | One run; resolver render dominates |
| 4 window + chunks | 0.43 s | 1.3 s | 2.4 s | 6–7.5 s | Acts on first cover and on the resolver block only |
| 5 publish early | 0.15 s | 0.3 s | 0.4 s | 1–1.5 s | Resolver render only |

First cover command after the minute:

| Option | 20 / 15 | 40 / 30 | 60 / 40 | 110 / 109 |
| --- | --- | --- | --- | --- |
| Today | 1.3 s | 2.1 s | 3.4 s | 7–8.5 s |
| Target | — | 2 s | 3 s | — |
| 1a waves (first wave; last wave in brackets) | 0.8 s (1.4 s) | 0.8 s (2.6 s) | 0.8 s (3.9 s) | 1 s (9 s) |
| **1b slots, one deadline** | 1.6 s | 2.5 s | 3.7 s | about 9 s |
| 1b + 4 (window) | 1.5 s | 2.3 s | 3.5 s | about 9 s |
| 1b + 4 + 2a | 1.4 s | 2.0–2.2 s | 2.9–3.2 s | 6–7 s |
| 2a inbox | 1.2 s | 1.7–2.0 s | 2.3–2.8 s | 4.2–6 s |
| 2b shards | 1.2 s | 1.5–1.9 s | 1.8–2.5 s | 2.6–5.3 s |
| 3 central | 0.7 s | 0.8 s | 1.0 s | 2 s |
| 4 window + chunks | 1.3 s | 1.9 s | 3.2 s | 7–8 s |
| 5 publish early | 0.6 s | 0.7 s | 0.8 s | 1.5 s |

- Why 1b cannot be faster than today: the work is the same (N runs). Slots only let Home Assistant take turns between runs.
- Why 2a and 2b cannot reach the stall targets alone: about 20 ms per run stay (run start, action steps, script call, 8 ms base of a write).
  That floor is 0.4 / 0.8 / 1.2 / 2.2 s.

What each option breaks or risks:

| Option | Manual pause | Arbitration on one cover | Restart safety | Instances in the field | Tracker atomicity |
| --- | --- | --- | --- | --- | --- |
| 1a | No change | A cover with intents in two waves can start, then reverse | No change | Needs blueprint re-import | No change |
| **1b** | No change (see section 5 for one delay) | No change: one run reads all intents | A waiting run dies at a restart; the start trigger decides again | Package only; works for 3.2.0 as it is. 3.1.3 keeps today's path | No new key |
| 2a | No change | No change if the fence moves to the inbox | Inbox is restored; a lost entry heals at the next heartbeat | Package only | New sensor; one key per owner; compare-and-remove in the render |
| 2b | No change | Reader must merge 8 shards under one fence per shard | As 2a | Package only if the resolver mirrors intents to the tracker | 8 fences, or one ordered write per shard |
| 3 | No change | No change | No change | Two decision paths for years | Settings per instance in the tracker |
| 4 | No change | Chunks must use one tracker read | No change | Package only; new optional field | No change |
| 5 | A hand move between early publish and second 0 must cancel the early intent | Resolver must ignore intents that are not yet effective | Early intent is restored; safe | Needs blueprint re-import | Intent value gets a second part; still one writer per key |

Change size:

| Option | Blueprint | Package |
| --- | --- | --- |
| 1a | About 10 lines | None |
| **1b** | None | About 40 lines in `smarli_cover_request` and `smarli_cover_resolve`, one new optional field |
| 2a | None | About 60 lines: one sensor, request, resolver read, resolver write, fence |
| 2b | None | About 120 lines, 8 entities |
| 3 | About 400 lines removed, settings publish added | About 500 lines |
| 4 | None | 5 lines (window); about 80 lines (chunks) |
| 5 | About 80 lines | About 60 lines |

## 5. Recommendation: slotted publish with one settle deadline (1b), with the window deduction (4)

### What it is

- Applies to requests whose intent has `transition: true`. Those are the heartbeat, reload and start publishes.
- `smarli_cover_request`, before the intent write:
  - M = number of `::intent` keys in the `cover` namespace.
  - Rank = position of the caller's own key in the sorted key list. A caller without a key uses a hash of its id.
  - It waits `rank × slot`. The slot is about one run: a start value is `15 ms + 0.5 ms × M` (25 / 35 / 45 / 70 ms).
  - It passes `settle_at` = start of the burst + `M × slot` + a margin to the resolver.
- `smarli_cover_resolve`: the window becomes "until `settle_at`, at least 200 ms, minus the time the run waited in the queue".
- The existing queue logic then does the rest without a change:
  - the first caller's run waits until the deadline;
  - the second caller queues one run; every later caller skips;
  - at the deadline the first run ends at the "fresher run" check and the second run resolves everything.
- A caller that is late for the deadline starts a run of its own. That gives a small second wave, never a wrong decision.
- A request with `transition: false` (custom trigger, other families) keeps today's path with no slot.

### Why this one

- **It acts on the cause.** The block exists because N runs start together. A cheaper run makes the block shorter, not absent.
- **It holds at every size.** The stall no longer grows with the square of the size. What is left is N × about 10 ms before the request.
- **It does not depend on the open question** of where the 21–40 ms go. Options 2a and 2b do.
- **Package only.** It reaches every 3.2.0 instance with the Grundinstanz rollout. No blueprint re-import.
- **Covers that move together still start together.** That was the reason the design rejected staggering.
- **It fixes the reload case in the same move.** Reload and start publishes take the same path.
- **A person feels the stall, not the first cover time.** In a stall a wall switch does nothing for 2.4 s. Nobody watches the clock at a sun-based phase change.

### What it costs

- **First cover 0.3–0.5 s later than today** (2.3–2.5 s at 40 / 30, 3.5–3.7 s at 60 / 40). The targets of 2 s and 3 s are missed by more than today.
  - This needs a written decision: the first-cover target applies to a person's command, not to a scheduled phase change. Or 2a follows.
- **One automation alone also waits.** One automation of 60 that changes phase moves its covers up to about 3 s after the minute.
- **Peak runs of `smarli_cover_request` rise from 3 to N.** The runs only wait on a timer, but the KPI "most script runs at once" (10 / 15) is missed on paper.
  - Above 200 automations in one burst, runs would drop with a warning.
  - Alternative: the delay goes into the blueprint as the first action step. Then no script run waits, but it needs a re-import.
- **The automation's run stays open during its slot.** The automation is `mode: queued`. A cover state change in that time waits behind it.
  - A hand move in the first seconds of a phase change is then classified up to W late (W = 1.4 s at 40, 2.7 s at 60).
  - The classification itself stays correct: `conditions:` run at trigger time, and the context travels with the trigger.
  - To avoid it, the request can start the wait in a separate script run and return at once.
- **The burst start must be the same for every caller.** For the heartbeat it is the start of the minute. For reload and start it is not.
  This detail is open and belongs to the rig test.
- **At 110 automations the resolver render becomes the longest block** (1 s or more, estimate). The chunked resolver of option 4 is then the next step.

### When to add 2a

- If the profile (section 6) shows that the tracker write is 50 % or more of a run, add the inbox in the same package change.
- It shortens the slot, so the first cover comes back to about 2.0–2.2 s at 40 / 30 and 2.9–3.2 s at 60 / 40.

## 6. The cheapest first measurement

**A spacing spike on the hub, with no code change.** `spikes.mjs` already sends bursts of request calls (spike S6).

- Step 1: send 60 `smarli_cover_request` calls with `transition: true` at once, at 60 / 40. Record the longest ping delay and the time to the last intent.
- Step 2: send the same 60 calls 35 ms apart, then 45 ms, then 60 ms apart.
- Step 3: repeat with `burn.mjs`.
- **Confirmed** if the longest ping delay falls below 0.3 s at a spacing of 45 ms or less.
- **Rejected** if the delay stays above 0.5 s at 60 ms. Then the work is not in separate runs, and option 2 or 3 is next.
- The spike also gives the slot length, which the estimate above only guesses.
- Limit: the spike has no automation runs. It does not show the N × 10 ms before the request.

**In the same session: one profile of a phase burst.** `_prof.mjs` exists for the reload case (`profiler.start`).

- Wanted: the share of a run in four parts:
  - the tracker write (render, parse of the result, state write, listeners);
  - the automation before the request call (run start, logbook entry, trace, the `if` steps);
  - the script call itself;
  - the end of the run.
- It decides whether 2a is worth it, and it explains the slope of 1.4 ms per KB against 0.7 ms per KB.

## 7. How the hub test proves each option

The matrix in `test/hub-load/` (`matrix.sh`, `run.mjs`, `kpi.mjs`) runs unchanged for every option. Pass criteria, per option:

| Option | Extra check |
| --- | --- |
| 1b | Phase stall at or below 0.75 s (40 / 30) and 1.1 s (60 / 40), quiet. Spread of cover start times at or below 0.5 s. No cover started twice. Peak resolver runs at or below 3. New: one run where 5 of 60 automations change phase, to prove one wave. New: reload with a cleared tracker gives one wave. |
| 2a, 2b | Phase stall as above. New: 200 bursts with no lost intent (as S6). New: restart between publish and drain, then check that every intent is in the tracker one minute later. |
| 3 | Full matrix, plus every runtime suite, because the decision code moves. |
| 4 | First cover 0.2 s earlier at 40 / 30 and 60 / 40. Longest resolver block at or below 0.15 s (ping delay after the deadline). |
| 5 | Full matrix, plus a hand move in the minute before the phase change. |

Runtime tests on the local rig for 1b: `test-request.ps1` gets a case with callers in slots, a case with a late caller, and a case with one caller alone.

## 8. Two direct answers

**Does one button-triggered cover automation see a delay?**

- Yes, today. The resolver waits the 200 ms window, then the fence write (about 20 ms), then the render over every intent on the hub.
- That is about 0.3 s on a small installation and about 0.5 s at 60 automations.
- The recommendation does not change it: a custom trigger publishes with `transition: false` and gets no slot.
- It can be cut by about 0.15 s: a window of 50 ms for requests without `transition`. Risk: several automations on one button then start in two waves about 0.3 s apart. A product choice, not part of the recommendation.

**Can the reload stall be reduced in the same move?**

- Yes. The reload stall of the load test is N first publishes at one instant (section 2.2). Options 1b, 2a, 2b and 3 act on it as on the phase block.
- A save of one automation in the UI fires `automation_reloaded` for all. With an intact tracker that costs about 1 ms per cover automation. Nothing to fix there.
- What 1b does not fix: Home Assistant's own work when it creates automations for the first time. Not measured apart.

## 9. Open points

- The number of cover automations per installation. The fleet data has covers only. The stall follows the automations.
- The burst start for reload and start publishes (section 5).
- The resolver render at 110 intents and 109 covers. Not measured.
- `time_pattern` and the random offset: the helper has it; that the trigger uses this helper is not confirmed.
- The numbers of S5 (resolver render 151 / 251 ms) are from before the dicts step. They may be lower now.
