# Cost budget and target architecture for shared blueprint logic

Status: **draft for review**, 2026-11-04. Nothing in here is built yet. Revised once after a
review by the session that ran the hub load test.

This design applies to the cover family first. Its rules (sections 1, 4 and 7) apply to every
blueprint family that follows.

## Why

A load test on a Raspberry Pi 4 hub (`mogy-dev`, Frigate with one camera) measured the cover
family with 20, 40 and 60 automations. Results: `test/hub-load/RESULTS.md` on branch
`claude/hub-load-test-de6f21` (commit `08124ac`).

| Size (automations / covers) | Highest run count (limit 50) | Longest HA stall | Last cover starts after the phase change |
| --- | --- | --- | --- |
| 20 / 15 | 21 | 2.3 s | about 4 s |
| 40 / 30 | 41 | 5.3 s | about 11 s |
| 60 / 40 | 50, runs dropped | 10.6 s | about 20 s |

During a stall, HA does nothing else: no UI, no other automations, no Zigbee handling.
All covers still reached their targets. A busy hub (host CPU at 100 %) changed stalls by
−5 % to +25 %.

Where the time goes (**M** = measured on the hub, **I** = inferred from the data):

| Cost | 40 / 30 | 60 / 40 | Source |
| --- | --- | --- | --- |
| Manual-detection fan-out after the covers reach `closed`: about 120 runs of about 37 ms (10 ms variables block, the rest the `manual_check` call) | 4.4 s | — | M |
| Second-0 block: every automation decides in the same second; a transitioning run costs about 52 ms (gated: 10 ms), mostly tracker write, resolver call and a merged resolver run | 2.1 s | 3.6 s | M |
| The one full resolver run, one long render | about 1.0 s | about 2.0 s | I |
| Mover: covers are commanded one after the other, about 8 ms per cover (S7). The earlier "spread about 3 s" and "first cover at 7.7 / 13.3 s" were measurement errors: they came from HA's push messages reaching the test PC after the backlog | 0.23 s for 30 | 0.32 s for 40 | M |
| A person's command to all covers: 270 `suspend` runs for 30 covers | — | — | M |
| A tracker write: about 8 ms + 0.7 ms per KB of `data` (S5) | 15 ms at 10 KB | 20 ms at 16 KB | M |

**Root causes:**

- HA renders an automation's top-level `variables:` before its conditions, on every run, for
  every trigger.
- HA renders templates on its single event loop. One long render blocks everything.
- Work that should happen once happens once per automation: resolver calls, suspensions.

## 1. The rule: a cost budget

- **Frequent events must be cheap.** A run caused by a state change, a heartbeat with nothing
  to do, or a command must not render decision logic.
- **Expensive logic runs only when a decision is due**, and only once, not once per automation.
- **No long single render.** Expensive work is split into steps, so HA can do other work in
  between.
- **Batch what belongs together**: one tracker write for many keys, one service call for many
  covers.

Budget targets on a Pi 4 hub. They hold on a busy hub (load test with `burn.mjs`), so the
quiet-hub values must stay about 25 % below them.

| Measure | Target at 40 / 30 | Target at 60 / 40 | Measured today (40 / 30) |
| --- | --- | --- | --- |
| Longest stall in any burst | 1 s | 1.5 s | 5.3 s |
| Highest run count of any script | 25 % of the automations or covers, whichever is larger | same | 41 |
| Spread of start times of covers that move together | 0.5 s, aim near 0 | 0.5 s | 0.23 s (S7; first figure of about 3 s was a measurement error) |
| First cover command after the phase change | 2 s | 3 s | about 3 s (S7; first figure of 7.7 s was a measurement error) |

These targets are a goal for the design. Whether each one is reachable is part of the spikes.
A target that turns out to be unreachable needs a written decision, not a silent change.

### Decision on the missed targets (2026-11-11, after step 5)

Measured: `docs/superpowers/plans/2026-11-11-hub-matrix-all-phases.md` (worse of 2 repetitions).

| Target | 40 / 30 quiet | 60 / 40 quiet | 60 / 40 busy | Proposed decision |
| --- | --- | --- | --- | --- |
| Longest stall, phase change (1 s / 1.5 s) | 1.3 s | 2.4 s | 2.4 s | Missed. Accepted for the merge. Target stays. |
| Longest stall, reload (1 s / 1.5 s) | 1.9 s | 4.3 s | 2.7 s | Missed. Open, see below. |
| First cover command (2 s / 3 s) | 2.1 s | 3.4 s | 3.3 s | Missed by 0.1–0.4 s. Accepted. Target stays. |

Status: proposed, not approved. A first version of this section (same day) took the reload value from
the busy run only (2.7 s) and claimed that no target got worse; the quiet run says otherwise.

Why the merge can go ahead:

- Phase stall and first cover got much better than the baseline at 60 / 40 busy: phase stall
  9.5 → 2.4 s, first cover 4.1 → 3.3 s. The steps fix the dropped runs, which lost decisions and pauses.
- Reload did not get better: 3.0 → 2.7 s busy, but 3.2 → 4.3 s quiet (worse of 2 repetitions; the
  steps between them range from 2.4 to 4.3 s, so the noise is large). How much of it is HA re-creating
  the automations and how much is the setup run of each automation is not measured.
- The phase stall happens a few times per day per instance, at a phase change. At 20 / 15 it is 0.4 s.
- Installation sizes (entity registers of 94 instances, 2026-10-29): 76 have covers; median 12, 90 %
  have 30 or fewer. The largest have 81 and 109 covers (109 is a production facility). A 109-cover
  instance is not tested; extrapolated from about 40 ms per transitioning automation, its phase stall
  is about 5 s or more. No dropped runs are expected there (peak 3 runs against `max: 200`).
- What is left in the phase stall and the first cover command is the second-0 block: every automation
  decides in the same second and writes its intent into the full tracker. Known levers, none measured:
  spread the decisions over the first seconds of the minute (covers then start in waves, a product
  choice); make each intent write cheaper (smaller store for intents, or no tracker write when the
  request carries the fresh intent); one central evaluator for all instances (largest gain, breaks
  "trigger distributed"). Each needs its own design and its own hub test.

Reload: it happens on "Reload automations", on HA start, and probably every time a technician saves any
automation in the UI (HA fires `automation_reloaded` then too; not verified). Nobody waits for a cover
at that moment, but the rest of the house freezes for its duration. Options: accept up to about 4.5 s at
60 / 40, or measure the split first.

Owner of this decision: Pascal. It can be changed with new measurements.

### Decisions after the second-0 analysis (2026-11-11)

Source: `docs/superpowers/analysis/2026-11-11-second-0-block-holistic.md` (sections 4.1–4.7), then
a discussion with Pascal. Approved by Pascal unless marked open.

**Sizes and targets.** The test sizes 20 / 15, 40 / 30 and 60 / 40 (automations / covers) stress
the wrong dimension: the largest real installation has few automations and many covers (22 / 132).
New budget, replacing the table above:

| Measure | Real sizes 1 / 12, 8 / 27, 22 / 132 | Stress test 30 / 160 | Every size |
| --- | --- | --- | --- |
| Longest stall, phase change | 1 s | 1.5 s | |
| First cover command after the phase change (from the family's heartbeat second) | 2 s | 3 s | |
| Spread of start times of covers that move together | 0.5 s | 0.5 s | |
| Button event to first cover command | | | 0.2 s |
| Highest run count of any script | | | at most 50 % of its `max` (replaces the 25 % rule) |

60 / 40 stays in the history, without a target. The hub test generator (`test/hub-load/gen.mjs`)
uses a round robin when there are more than 3 covers per automation, so every cover is in use.

**Heartbeat second per family: light 2, cover 4**, families that are not time-critical later (6, 8, …).
`smarli_slot` is shared, so families close together do not block each other. No `time_pattern` uses second 0: every
customer automation with a time trigger fires there. Each family gets one fixed second, written as a
literal at its heartbeat trigger, with a comment that points to a table in `CLAUDE.md` (family,
second, reason). `ci/check-blueprints.js` fails a `time_pattern` without `seconds`, with second 0,
or with a value that differs from the table. Constraints from Pascal: light comes before cover, and
the seconds stay close together, so a light and a cover that both react to sunset do not start far
apart. It applies only to the heartbeat: a button, a reload and HA start are events.

**Button path (holistic 4.2), approved 2026-11-12: window 0.** Source: the button measurement
(`docs/superpowers/analysis/2026-11-11-button-latency.md`, today 323 ms at 1 / 12 and 1047 ms at
22 / 132). The 200 ms window prevents no reversal: a second resolve commands a cover only if the
result differs. Design:

- The blueprint sends `immediate: true` for every trigger that is not the heartbeat.
- An immediate request never skips, and calls the resolver with no collect window. The run yields
  1 ms before it reads, so the other automations on the same button publish and queue behind it; the
  older runs then skip and the newest decides for all (without it, 8 automations on one button took
  2.9 s at 22 / 132; with it 0.85 s). The resolver
  takes no fence when no run was in the queue at the call (then no other caller can depend on it).
- **Scoped run.** An immediate run resolves only some covers: the caller's covers, plus the covers
  of every intent that arrived after the previous fence. `smarli_cover_request` stamps each intent
  with `seq` (the write time). The fence value holds its own time, and a run reads the previous
  fence before it writes its own. Every intent with `seq` before that fence was read by a run that
  finished, so it is handled. This keeps the skip rule safe: a heartbeat caller that skips for a
  queued scoped run is in that run's scope. An intent without `seq` (written before this change)
  is always in scope. Heartbeat runs (window 200 ms) stay full.
- The resolver writes the moving markers in its own batch write, and starts the mover before the
  remove write and the log lines. The mover writes markers only when the resolver did not (the
  release path calls it directly).
- Unchanged: a button does not command a cover that a person paused by hand (Pascal, 2026-11-12).

**Transition slots (holistic 4.3, variant a).** A shared `script.smarli_slot` in `smarli_core.yaml`
spreads the intent writes of a burst; the resolver waits until no slot run is left. Open: the decision
cost per run before the request (4–18 ms) decides whether the wait stays in the package or the
blueprint steps get cheaper first (rule: 22 × that cost ≤ 0.3 s).

**Newer `ts` wins inside the tracker render (holistic 4.4).**

**Remove the 3.1.3 compatibility code (holistic 4.5).** mssw is a test setup: re-import and a clean
tracker are fine.

**Blueprints: `max: 200`, `max_exceeded: warning` (holistic 4.6).** Extends the package rule.

**One tracker sensor per family, now (holistic 4.7).** Nothing is in the field, so this is the
cheap moment. Reverses section 4 and the rejected list.

**Custom actions run after the request, not after the covers move.** At a large installation they
can run up to about 1.5 s before the covers start. Accepted; the input descriptions and the Danger
Zone text say "after the request".

## 2. Blueprints: cheap by default

- **Top-level `variables:` hold only what every trigger needs:** the inputs as values and
  the resolved settings (helper → input default). No schedule, sun, brightness or transition
  logic.
- **Decision logic goes into per-trigger `variables:`** on the triggers that decide: the
  heartbeat, `automation_reloaded` and `homeassistant: start`. HA renders those only when that
  trigger fires (docs: "variables that are set when the trigger reacts").
- **One place for each piece of logic, in the source:** YAML anchors share a block between
  triggers. If trigger variables cannot see the top-level variables (see S1), the settings
  resolution also becomes an anchored block, used by every trigger that needs it. It is still
  written once.
- **The heartbeat gate stays in `conditions:`.** A run that passes `conditions:` writes a
  logbook entry, so a gate in the actions would log every automation every minute.
- **Custom triggers** (`- triggers: !input custom_..._triggers`) cannot carry our variables.
  Their path computes the decision in an action-level `variables:` step. They are rare.
- **The per-minute heartbeat stays.** It is restart-safe and proven.
- **Settings stay user-configurable as today:** blueprint inputs plus the optional
  `*_helper` overrides (CLAUDE.md, "User-facing settings"). This design moves no setting. A
  central settings entity (e.g. one suspension duration for all automations) is a separate
  product decision. It needs a user flow that does not exist yet.
- **Shared logic in packages, if needed later:** a package script that returns a value
  (`stop` with `response_variable`, HA 2023.7+). Jinja macros are not an option: HA loads
  them only from `config/custom_templates/`, which nothing in our rollout writes today.

## 3. Manual detection: stop early, once per cover

Manual detection stays distributed: each automation watches its own covers. A central
watcher would need a list of covers per installation (breaks plug and play) or a trigger on
every state change in the house (rejected in CLAUDE.md).

Condition order for the cover state trigger, cheapest first. Each check can end the run in
`conditions:`: no logbook entry, no script call.

1. **Context from a command:** a change with a `parent_id` was caused by an automation or a
   script. HA keeps a service call's context on the entity for 5 s
   (`CONTEXT_RECENT_TIME_SECONDS` in `helpers/entity.py`), for every integration. So this
   check catches the start of a move (most motors report within 1–2 s), not its end (after the
   travel time), and nothing from late reporters (cloud polling, Somfy RTS via Overkiz).
   On the hub, hass-virtual covers seemed to keep the context longer; not explained.
2. **smarli. is moving this cover:** one key read. Catches the end of a move and late reports.
   Needs a new per-cover key: today the markers are per run (`<cover>::moving_<run>`) and need
   a scan. The key must stay correct when two moves overlap on one cover.
3. **Elected watcher:** one automation per cover goes on. Candidate, not built:
   - The resolver writes `<cover>::watcher` = the entity id of one automation that **watches**
     the cover. The resolver is queued, so it is the only writer and the key stays atomic.
   - **The watcher must really watch the cover.** An automation that only sends requests (e.g.
     an "all off" light automation through `smarli_cover_request`) has no state trigger on the
     cover. If it became the watcher, nobody would detect a hand move. So an intent says
     whether its owner watches its covers (`watches: true` for `cover_DayNight`). The resolver
     elects the winner of the cover's decision if it watches, else another live automation
     whose intent names the cover and watches it.
   - Condition: `watcher == this.entity_id`, or the key is missing, or the watcher is not `on`
     (`is_state`, one lookup). A missing or switched-off watcher never leaves a cover unwatched.
   - The elected watcher goes on **even when its own `should_suspend_after_manual_interaction`
     is off.** Detection is per cover. The pause length is decided centrally from all live
     intents, with opt-outs counting as 0.
4. **Already paused by the same hand action:** skip when the cover's pause **was started less
   than 60 s ago** (the same window the decision log uses to merge pause lines). One key read.
   - Today one command produces many pauses: `smarli_cover_command_check` pauses each commanded
     cover, and every watcher pauses it again on each state change (270 `suspend` runs for one
     command to 30 covers in the load test).
   - Not "the pause ends late enough": the pause length is the **longest** setting of all
     automations on the cover, and a watcher only knows its own. Example: A pauses 30 min,
     B 10 min. A hand move at 10:00 pauses until 10:30. A second hand move at 10:10 must
     extend it to 10:40. B, comparing with its own 10 min, would see 20 min left and skip, so
     the extension would be lost. "Started less than 60 s ago" means the same hand action, so
     skipping is always safe; a hand move 10 min later always starts a new pause.
   - Needs the start time of a pause: a second key `<cover>::suspension_since`, or a value with
     both times. `smarli_cover_suspend` is queued and stays the only writer.
   - **Edge case, accepted:** a cover whose travel takes longer than 60 s reports its end state
     after the window, so that report pauses the cover once more. The new pause ends about one
     travel time later than the first. No harm: it only extends a pause the person caused.
5. `manual_check` as today (layers 1 and 2), then `suspend`.

## 4. Tracker contract (every family)

- ~~**One sensor**, `sensor.smarli_automation_tracker`.~~ Reversed on 2026-11-11: **one tracker
  sensor per family**, defined in the family's package. A write renders only its own family's keys.
  See "Decisions after the second-0 analysis" in section 1. (The old reason, "size was not the
  problem", came before S5, which measured about 0.7 ms per KB on every write.)
- **One namespace per family** (`cover`, later `light`, …). `shared` only for state that more
  than one family reads. Today nothing.
- **New batch events** `smarli_tracker_set_many` (namespace + dict of key → value) and
  `smarli_tracker_remove_many` (namespace + list of keys): one render for many keys. Each key
  stays atomic as before. They help where one run writes many keys (mover, resolver), not
  where many automations write one key each.
- **Read by single key** in anything that runs often. Never copy a whole namespace into a
  variable in a frequent path. A copied namespace also ends up in every trace of that run.
- **Never read the tracker in a template entity or a template trigger.** They would re-render
  on every write of every family.

## 5. Cover package

- **`smarli_cover_request`** is the only entry point for any automation that wants a cover
  moved, `cover_DayNight` included. It publishes the intent and calls the resolver. No
  blueprint calls `cover.*` itself or writes into the `cover` namespace.
- **One resolver run per burst, not one per automation.** `smarli_cover_request` skips the
  resolver call when a resolver run is already queued and not yet started: that run reads the
  tracker when it starts, so it sees the new intent. Candidate, needs proof (S6): the waiting
  run must see a write that lands while it waits. Today each run waits only for its own
  owner's write.
- **The resolver is split into steps.** One small step per cover (or per batch of covers)
  instead of one long render, so HA can work between steps. Its Jinja also loses the
  `dict(d.items() | list + …)` rebuild inside loops, which costs time with the square of the
  size.
- **The resolver logs only the covers in the caller's intent,** plus covers whose bound changed.
- **The mover commands all covers with the same target in one service call**, so HA sends to
  them together, and writes all markers in one batch write. The settle loop stays per cover.
  Open (S3): does one `cover.set_cover_position` with many entities reach the covers in
  parallel, also across integrations (Zigbee, Overkiz)? And why did `move` start at 4.6 s but
  the first cover move only at 13.3 s at 60 / 40 (S7)?
- **Queues:** `max: 200` for every queued or parallel script. The resolver logs a dropped run
  (`max_exceeded: warning`) instead of dropping it silently. This is a safety net only.
- `override_suspension` stays planned, not built (`docs/cover-architecture.md`, "Requirements
  for future cover families").

## 6. The second-0 block

Every automation decides in the same second, by design: covers that should move together must
decide together. What remains per automation after sections 2 and 5: render the decision,
write the intent, call `smarli_cover_request`.

- S5 measures the parts first: step timestamps of one transitioning heartbeat run, and the
  cost of one tracker write at 10–16 KB.
- Depending on S5: make the intent write cheaper (smaller value; only write when it changed),
  or let `smarli_cover_request` collect the intents of one burst and write them in one batch.
- No staggering of heartbeats: it would spread covers that should move together.

## 7. Rules for every new family

- Follows sections 1, 2 and 4.
- A family that moves covers calls `smarli_cover_request`. The same pattern applies to any
  later shared actuator: one package entry point per device type.
- Before release, the hub load test runs with the new family included.

## 8. The load test as a standard check

`test/hub-load/` (from branch `claude/hub-load-test-de6f21`) becomes a maintained benchmark:

- It runs before a release of shared package logic, on a throwaway Pi hub, quiet and with
  `burn.mjs`.
- The budget targets in section 1 are its pass criteria.
- A change that misses a target needs a written decision.

## 9. Delivery

- All changes from this design are built on **one feature branch** per repository
  (`ha-packages` first, then `smarli-blueprints`), never on `main`.
- Before the merge, every existing runtime test must pass on the local rig: `run-short.ps1`
  and `run-long.ps1` (all suites, including the mssw cases in `test-decision-log`, `test-a7`,
  `test-time-earliest`, `test-r2-layer2-contextless`, `test-transition-flag`), plus
  `ci/checks.sh` and `ci/check-release.sh`.
- Each new mechanism gets its own runtime test in the same branch: trigger variables and the
  settings anchor, each manual-detection check of section 3 (including the edge case above),
  batch tracker events, the request skip rule with callers spread out in time, the batched
  mover.
- The hub load test (section 8) runs on the branch before the merge, quiet and with
  `burn.mjs`. Results go into `test/hub-load/RESULTS.md`.

## Spikes (before building)

Each gives a yes or no, or a number. S1–S4 and S6 run on the local Docker rig, on HA 2024.10
and 2025.4. S5 and S7 need the Pi hub.

| Spike | Question | Pass |
| --- | --- | --- |
| S1 | Per-trigger `variables:`: rendered only for that trigger? Visible in `conditions:`? Rendered before or after the top-level `variables:`, and can they use them? Usable with YAML anchors in a blueprint? | A state-trigger run's trace shows none of the decision variables; the settings resolution stays in one place in the source |
| S2 | Does a cover change caused by `smarli_cover_move` carry `parent_id`, on the rig and on real hardware (Zigbee via Z2M, Overkiz)? | Known per integration |
| S3 | Does one `cover.set_cover_position` with N entities start all covers together? | Start spread at most 0.5 s for 30 covers; per-integration limits known |
| S4 | Batch tracker event: one render with 40 keys, each key correct afterwards | Correct, and faster than 40 single writes |
| S5 | Step timestamps of one transitioning heartbeat run; cost of one tracker write at 10–16 KB | Numbers per step |
| S6 | Can `smarli_cover_request` skip the resolver call safely when a run is waiting? | No lost intent in 100 bursts |
| S7 | Trace of `move` at 60 / 40: where do the 8.7 s between its start and the first cover command go? | Cause known |

### Spike results (2026-11-04, local rig, HA 2025.4.4, fast PC)

| Spike | Result |
| --- | --- |
| S1 | **Pass.** Trigger variables render only for their own trigger and are visible in `conditions:`. They render **before** the top-level `variables:`: they cannot see top-level variables, but top-level variables can see them. YAML anchors with `!input` work in a blueprint, shared by several triggers. YAML merge keys (`<<: *settings`) work too: one block resolved a helper override and was reused by two triggers. Not repeated on HA 2024.10. |
| S2 | **Mixed.** Virtual covers carry the automation's context (also seen on the hub). The Somfy covers on mssw (Overkiz, `assumed_state`) report later **without** context: on 2026-11-02, `manual_check` runs got past the context check right after an automation move. Zigbee via Z2M: not checked. So the early stop helps only where the integration keeps the context. For real motors, the cheap per-cover checks in section 3 carry the gain. |
| S3 | **Pass on the PC.** 30 covers: today's mover loop started them within 0.025 s, one service call within 0.001 s. The 3 s spread on the Pi comes from other runs taking turns between the loop's steps, not from the loop itself. One call dispatches all covers at once. Pi value: S7. Limits of each integration (Overkiz, radio): not measured. |
| S4 | **Pass.** Batch events kept every key correct and `remove_many` removed exactly the listed keys. 40 single writes took 7 / 13 / 18 / 22 ms at 0 / 7 / 17 / 24 KB of `data`; one batch of 40 took 1–3 ms. A single write gets slower as the tracker grows; a batch is about 10 times cheaper. Pi values: S5. |
| S6 | **Pass on the PC and on the busy Pi (see "Hub spike S6").** 30 automations, 100 bursts with the skip: no wrong decision for any cover. Peak resolver runs: 30 without the skip, 2 with it. The race (a waiting run reads the tracker before a skipped caller's write lands) is small on a fast PC. Repeat on the Pi with `burn.mjs` before building. A lost intent would stay lost until that automation's next phase change. |

### Hub spikes S5 and S7 (2026-11-04, Pi 4 hub, one burst each)

Details: `test/hub-load/RESULTS.md`, section "Spikes S5 and S7", branch
`claude/hub-load-test-de6f21` (commit `c4a597d`).

| Spike | Result |
| --- | --- |
| S5 tracker write | About **8 ms + 0.7 ms per KB** of `data`: 12 / 15 / 20 ms at 5 / 10 / 17 KB. |
| S5 transitioning heartbeat run | About 53 ms at 40 / 30 (61 ms at 60 / 40). The tracker write is about 30 %. The other 70 % are the top-level variables (10–25 ms) **and the templates in the action steps before the intent write** (5 `if` blocks, 20–35 ms). Moving the variables into trigger variables does not remove this cost from a decision run. The resolver's decision render takes 151 ms at 40 intents and 251 ms at 60. |
| S7 mover | **Not the problem.** At 60 / 40, `move` starts 4.45 s after the minute and has sent all 40 commands 0.35 s later (about 8 ms per cover, marker write included). After that, HA works through 9.5 s of backlog: about 180 watcher runs, 100 `manual_check` runs and 40 `command_check` runs, about 53 ms per watcher run. At 40 / 30, the commands are sent by 3.0 s. |

Consequences of S5 and S7:

- **The manual-detection backlog is the largest cost** (about 53 ms per watcher run). Sections 2 and 3 stay first.
- **The first command reaches the covers about 3 s (40 / 30) and 4.5 s (60 / 40) after the minute**, not 7.7 / 13.3 s. The time before it is the second-0 block plus the resolver render. To reach "first cover under 2 s at 40 / 30", a transitioning run must cost less than half of today's 53 ms. That means fewer templates in the publish path, not only cheaper variables.
- **Batching the mover still helps, but less:** it removes 0.23–0.32 s of spread, which already meets the 0.5 s target at 40 covers. It moves down the order of work. For real integrations, commands may also wait behind the backlog (not measured).
- **The resolver render (151–251 ms) is one block.** Splitting it into steps stays in the plan.
- Open: the resolver trace showed 20 `::resolved` write steps for 30 or 40 covers. Not checked yet. It may be a limit of what the trace stores.

### Found while building step 1 (2026-11-04)

- **`this` is not defined in trigger variables.** S1 did not test it. The decision needs the
  automation's own id (`this.attributes.id`) for its stored intent and brightness keys. So
  the decision is split: everything without the id (settings, sun and time windows,
  weather, fingerprint, about 300 lines) stays in the trigger variables; the part that needs
  the id (brightness timestamps, own intent, last decision, desired position, transition,
  intent payload) is at the top level, guarded by `decide_ready`, so a cover state change
  renders only cheap placeholders. It reads single tracker keys, no longer a whole
  namespace.
- **The elected watcher can go stale.** `<cover>::watcher` is rewritten only when the
  resolver runs. Deleting an intent, or changing an automation's covers, does not run it.
  A stale watcher that is still on would leave the cover unwatched. So a watcher counts
  only while it is on **and** its own intent still names the cover and watches it (one more
  key read). Otherwise every automation goes on, as before.
- **A custom trigger with the id `heartbeat`** (the rig's 5 s heartbeat) carries no
  decision variables either. It takes the custom-trigger branch, which renders the decision
  and applies the heartbeat gate there.

Consequences of the local spikes:

- **Section 2, settings in one place:** the settings resolution is an anchored block (`&settings`). The top-level `variables:` use it, so every trigger has the settings. The decision triggers merge it with the decision block (`<<: [*settings, *decide]`), because their variables render before the top level. The settings are then rendered twice on a decision run. That is cheap: the settings are a few lines, the decision is the 100 variables. The merge of a list of anchors is still to be checked when building.
- **Section 3:** because real motors often report without context, step 1 is not enough. A per-cover "a smarli. move is running" check that costs one key read belongs in `conditions:`. Today the moving markers are per run (`<cover>::moving_<run>`) and need a scan.
- **Section 5:** S6 goes to the hub session for a repeat under load before `smarli_cover_request` uses the skip.

### Hub spike S6 (2026-11-04, Pi 4 hub with `burn.mjs`, host CPU 100 %)

**Pass.** 200 bursts of 30 callers with the skip: no intent lost, none late. In every burst,
28 of 30 calls skipped and the resolver peaked at 2 runs (30 without the skip, 20 bursts).
Details: `test/hub-load/RESULTS.md`, section "Spike S6", commit `4eab7b6`.

The setup did not cover one window: a caller sees `current >= 2`, and the waiting run starts
and reads the tracker before that caller's write is rendered (12–20 ms, longer in a backlog).
**Rule for `smarli_cover_request`, which closes it:** write the intent, **wait until the
write is visible** (the resolver's own wait step does the same), and only then check
`current >= 2`. In queued mode, `current >= 2` means at least one run has not started yet,
and that run starts after the write is visible, so it reads it. The wait is asynchronous
and does not block HA. Callers that are spread out in time (manual detection, other
families) were not tested and need a test when the request script is built.

## Order of work

Updated after the spikes. Each step ends with its runtime tests and the hub load test.

1. **Blueprint shape and manual detection** (sections 2 and 3): settings anchor, decisions as
   trigger variables, the five checks of section 3 with the new per-cover keys (moving,
   watcher, suspension start). Largest gain.
2. **Leaner publish path** (sections 5 and 6): fewer templates before the intent write,
   `smarli_cover_request` with the skip rule (write, wait until visible, then check), the
   resolver split into steps.
3. **Batch tracker events** (section 4), used by the resolver and the mover.
4. **Mover batching** (section 5). Smaller gain since S7.
5. **`cover` namespace, queue limits (`max: 200`) and drop warnings** (sections 4 and 5).
6. Update `CLAUDE.md` and `docs/cover-architecture.md` with the rules that are built.

## Considered and rejected

- **Central watcher per cover:** breaks plug and play, or runs on every state change.
- ~~**One tracker sensor per family:** size was not the problem. More mechanism, no gain.~~
  Reversed on 2026-11-11: S5 showed that every write costs about 0.7 ms per KB of the whole
  tracker, so size is a cost. See "Decisions after the second-0 analysis" in section 1.
- **Exact triggers instead of the heartbeat** (time, sun, numeric_state per input): empty
  helper inputs cannot be used in a trigger, and the heartbeat is restart-safe. Kept the
  heartbeat and made it cheap instead.
- **Heartbeat gate in the actions:** every automation would write a logbook entry every minute.
- **Staggered heartbeats:** would spread covers that should move together.
- **Jinja macros in `custom_templates/`:** not loadable from packages, and nothing in the
  rollout writes that folder. Package scripts with a return value cover the same need.
