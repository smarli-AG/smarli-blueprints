# Button latency on the hub (2026-11-11)

Measured on mogy-dev (Pi 4, HA 2025.4.1), code of step 5 (cover_DayNight 3.2.0, `smarli_cover.yaml`
77cb953). Probe: `test/hub-load/button.mjs` in the hub-load worktree. One house per row, steady state
after a reload, then 6 presses × (close, open) of a custom trigger (event). Times from HA's clock:
event `time_fired` → first `closing`/`opening` of a cover on the button. 11 valid presses per row
(the first close of each row moved nothing: the covers were already closed, see the last section).

| House (automations / covers) | On the button | Tracker | First cover, median | Max | Requests after the event |
| --- | --- | --- | --- | --- | --- |
| 1 / 12 | 1 | 2 KB | 323 ms | 335 ms | 18–43 ms |
| 8 / 27 | 1 | 6 KB | 398 ms | 418 ms | 20–28 ms |
| 8 / 27 | 2 (share a cover) | 6 KB | 607 ms | 624 ms | 2nd request 19–31 ms after the 1st |
| 22 / 132 | 1 | 38 KB | 1047 ms | 1144 ms | 21–28 ms |
| 22 / 132 | 2 (share a cover) | 18 KB | 1262 ms | 1358 ms | 2nd request 18–27 ms after the 1st |
| 22 / 132 | 8 | 21 KB | 1394 ms | 1438 ms | about 21 ms apart, last at 170–214 ms |

No cover started twice or reversed. The 38 KB row probably holds pause keys from the setup's hand
command to all covers (not verified); the later rows have intents 7 KB, watchers 6 KB, `::applied`
4 KB, `::resolved` 3 KB.

## Where the time goes (resolver trace, one press)

| Step | 1 / 12 | 8 / 27 | 22 / 132 (38 KB) |
| --- | --- | --- | --- |
| Event → request (blueprint custom path) | 24 ms | 24 ms | 25 ms |
| Collect window | 203 ms | 203 ms | 202 ms |
| Fence wait | 12 ms | 14 ms | 43 ms |
| Resolve render (all covers) | 21 ms | 62 ms | 436 ms |
| Writes and log lines before the mover | ~40 ms | ~45 ms | 275 ms |
| Mover start → cover command | 27 ms | 25 ms | 89 ms |

With two automations on the button, the first resolver run skips for the fresher one, which waits its
own 200 ms window: about +210 ms.

## What follows

- **Requests of several automations on one button arrive one after the other, about 21 ms apart.**
  HA runs them on one loop, and each automation renders its decision before its request. So the gap
  between two requests is one decision, and with N automations the last request comes about
  N × 21 ms after the event. A 30 ms window covers two automations only barely (gaps up to 31 ms).
- **This is also the decision cost per run that holistic 4.3 needed (g + p): about 21 ms on the custom
  path.** 22 × 21 ms ≈ 0.46 s, above the 0.3 s of the decision rule: the blueprint decision must get
  cheaper before the slot wait alone can give the targets. (The heartbeat path renders the same
  templates in trigger variables; not measured separately.)
- **The window prevents no reversal in practice.** A second resolve commands a cover only if the result
  differs. Two automations on one button with the same direction give the same result. Only two
  automations with opposite targets on one button would start and reverse a cover, and that is a
  configuration conflict.
- **Estimate after holistic 4.2 with window 0** (from the measured parts): 1 / 12 about 110 ms;
  22 / 132 about 250 ms (scoped render ~50 ms, one batch write at that tracker size ~65 ms, mover
  ~90 ms). The 0.2 s target at 22 / 132 also needs the mover's marker write moved into the batch write,
  and a smaller cover tracker.

## Why the first close of each row moved nothing (not a bug)

A first reading suspected a bug ("a button press can do nothing"). The cover history disproves it.
The test house was in its night phase (the close helper still held a time from an earlier phase test),
so the probe's reload closed every cover (`cover.vload01`: closing 21:06:01, closed 21:06:22 UTC). The
first close press at about 21:07:15 found the covers already closed, and "already decided as 0 %,
nothing changed" was correct. The probe should set the house to its day phase before the presses.

By design (`test-custom-triggers.ps1`), a custom trigger does not command a cover that is paused after
a person's hand command.

## After the button path (2026-11-12)

Same probe and hub, package with immediate requests, scoped runs and markers in the resolver's batch
write (cover_DayNight 3.2.0 sends `immediate` for custom triggers). The probe now sets the day phase
first, so all 12 presses per row moved the covers. v2 = no window at all; v3 = a 1 ms yield (kept).

| House (automations / covers) | On the button | Before | v2 | v3 |
| --- | --- | --- | --- | --- |
| 1 / 12 | 1 | 323 ms | 120 ms | 190 ms (max 208) |
| 22 / 132 | 1 | 1047 ms | 193 ms | 200 ms (max 275) |
| 22 / 132 | 2 | 1262 ms | 382 ms | 306 ms (max 367) |
| 22 / 132 | 8 | 1394 ms | 2867 ms | 853 ms (max 2089, first press) |

No cover started twice or reversed. The tracker was 40 KB at 22 / 132.

- **v2 made 8 automations on one button worse.** Without any wait, the first resolver run blocks the
  event loop for about 370 ms. The other automations, triggered by the same event, publish only after
  it, one at a time, and each starts its own run: 8 × 370 ms. The movers started early, but their cover
  commands completed only when the chain was over (mover trace: command step from 13 ms to 2992 ms).
- **v3 yields 1 ms before the read.** The other automations publish in that time (requests 20–25 ms
  apart again), 7 runs skip, and one run decides for all 49 covers. The cost at 1 / 12 is 30–70 ms
  (the intent write renders during the yield).
- **0.2 s holds for one automation per button**, also at 22 / 132. It does not hold for several
  automations on one button. At 22 / 132 with 8 the time splits into about 200 ms of decisions, 8 intent
  writes that each render the 40 KB tracker (about 250 ms), and one scoped run of about 570 ms, of which
  about 200 ms read the tracker. The scope does not cut that read: the templates build lists with `+`
  in loops over every tracker key, which costs time with the square of the key count.
- **Next levers:** a tracker per family (holistic 4.7: smaller cover tracker, cheaper writes), and the
  resolver reading with filters (`selectattr`) instead of `+` loops.

## Cheap tracker reads (2026-11-12, evening)

Same probe and hub. Package change in `smarli_cover_resolve` and `smarli_cover_move`:

- No copy of the whole cover namespace in a variable (`tracked` in the resolver and the mover,
  `tracked_now` in the settle loop). HA renders each variable to text and parses it back, so the
  copy cost its size on every run. The templates read the tracker directly. The templates of one
  `variables` step render without a yield, so they all see the same tracker.
- Filters (`selectattr('0', 'search', ...)`) find the intent and marker keys, not a Jinja loop over
  every key (419 keys at 22 / 132).
- `resolved_map` takes each intent's targets and bounds once and groups them by cover (`groupby`).
  Before, `resolved_map` and `watcher_changes` looped over every intent for every cover. Each cover
  now carries its own records (`stored`, `applied`, `susp`, `watcher`) and its watcher candidates.
- Dicts in the mover are built once from a list of pairs, not rebuilt on every pass.

Before and after were measured on the same evening, old package first, then the new one, then the old
one again (the table shows the second old run; the first gave 832 ms for the 8-button row).

| House (automations / covers) | On the button | Before | After |
| --- | --- | --- | --- |
| 1 / 12 | 1 | 125 ms (max 140) | 120 ms (max 124) |
| 22 / 132 | 1 | 191 ms (max 252) | 155 ms (max 172) |
| 22 / 132 | 8 | 859 ms (max 2090, first press) | 720 ms (max 732) |

No cover started twice or reversed; every press moved all its covers. Medians of the deciding
resolver run, ms after the event:

| Step | 22 / 132, 8 before | after | 22 / 132, 1 before | after |
| --- | --- | --- | --- | --- |
| Run reads (after the fence) | 467 | 450 | 65 | 55 |
| Variables render | 191 | 84 | 63 | 37 |
| Mover started | 664 | 548 | 131 | 97 |
| First cover | 859 | 720 | 191 | 155 |

- **The Jinja loops cost passes, not list copies.** A `+` append copies the list only on a match,
  and few keys match. The time went to passes: `resolved_map` and `watcher_changes` ran covers ×
  intents passes each. Bench of the variables alone on the hub (`/api/template`, the 8 button intents
  in scope, 49 covers): 145 ms before, 59 ms after (`resolved_map` 70 → 39 ms, `watcher_changes`
  48 → 1 ms, `intents` 11 → 5 ms). A full run over 132 covers: 365 ms → 120 ms. The rest of the step
  time in the trace is HA parsing the rendered variables back.
- **0.2 s now holds for one automation per button at 22 / 132** (155 ms, max 172). With 8 automations
  it does not: 720 ms. Two parts did not change. The deciding run reads only about 450 ms after the
  event: in that time the 8 automations decide (about 25 ms each) and write 8 intents, and each write
  renders the whole tracker. From mover start to the first cover it is still about 170 ms. In that
  time the resolver writes its log lines (49 `logbook.log` calls). They probably delay the mover's
  command step (not measured: the probe stores no mover step times).
- **Bug found: the mover failed when 132 covers moved at once.** Its settle loop checked every tracker
  key for every pending cover (`superseded`). The whitespace of that loop alone exceeded HA's limit of
  262144 characters for a template output. The mover stopped with an error after its first pass: no
  settle audit (layer 3), and its 132 markers stayed in the tracker until they expired (195 s). It
  happens at every phase change that moves all covers of a large house. The new loop takes one pass
  over the markers (raw output of the largest resolver template now: 43 KB at 22 / 132).
- **The 40 KB tracker was these leftover markers**, not pause keys as guessed above: the probe's setup
  moves all 132 covers, and the old mover left 132 markers (14 KB). With the fix the tracker is 24.6 KB
  at 22 / 132. So part of "after" in the 22 / 132 rows comes from the smaller tracker (fewer keys to
  scan, smaller writes), not from the templates alone.
- **Next levers for several automations on one button:** a smaller cover tracker (holistic 4.7: every
  intent write renders it), cheaper blueprint decisions, and the resolver's log lines after the
  mover's first command.

## Skip rule and log lines (2026-11-13)

Two package changes on top of the cheap reads:

- **Immediate callers skip too** (`smarli_cover_request`): a caller skips when a resolver run waits in
  the queue, also when it is immediate. Per press with 8 automations, 2 resolver runs start instead
  of 8; the other 6 requests stop within 4 ms.
- **The mover writes the resolver's log lines after its commands** (`log_lines`). A hub test without
  any log lines first showed what they cost: 723 → 623 ms (8 on the button, 4 presses each).

| House (automations / covers) | On the button | Before (2026-11-12) | After |
| --- | --- | --- | --- |
| 1 / 12 | 1 | 120 ms (max 124) | 97 ms (max 114) |
| 22 / 132 | 1 | 155 ms (max 172) | 145 ms (max 165) |
| 22 / 132 | 8 | 720 ms (max 732) | 557 ms (max 2133) |

No cover started twice or reversed; every press moved all its covers. The tracker was 24.6 KB in the
8-button row and 28.3 KB in the 1-button row (not checked why).

- **One outlier, 2133 ms (press 5, close).** The deciding run waited 1.6 s for its fence (381 → 1966 ms),
  before any step these changes touch. Both runs of the old package had one outlier of the same size
  (2090 and 2200 ms). The cause is not known.
- **The log lines stay traceable.** All 49 lines are in the logbook with the same text and still
  name the automation that caused them. They appear 0.1–0.2 s after the cover's own state change
  (decision at about 470 ms, cover `closing` at 567 ms, lines at 665–768 ms), so a cover's logbook now
  shows the state change first, then the reason.
- **Where the 557 ms go** (median press): 8 decisions until about 200 ms, the intent writes until
  about 350 ms, the deciding run reads at about 385 ms, variables until about 470 ms, mover start at
  about 480 ms, first cover at about 557 ms.

### What a decision costs (button automation trace)

The run of `hubload_07` (it skipped the resolver) took about 18 ms to its request call: the decision
variables (`decide`) about 6 ms, the instance part about 3 ms, about 15 small steps (choose, gates,
stabilizer, `if`s) about 9 ms. The second-0 analysis found the same: the decision render is cheap,
the steps around it cost most.

- A light custom path (skip the schedule part of `decide` for a button) would save about 6 ms per
  automation, and only for custom triggers.
- `decide` also renders for every heartbeat of every automation, every minute, before the conditions
  (trigger variables). A cheaper `decide` (and fewer steps) helps the heartbeat, reloads and buttons
  alike. At 22 automations that is about 130 ms of loop time per minute for `decide` alone.

### Tracker split by kind: what a write costs (hub test)

A temporary second tracker sensor (same template as the core tracker, own event types) was filled
with parts of the real cover data. Eight writes back to back, as 8 automations on one button send
them, then a websocket ping; the time until the ping reply is the loop work the writes cause, all
included (render, state write, recorder, websocket subscribers). Medians of 12 bursts, two series:

| Tracker content | Size | 8 writes |
| --- | --- | --- |
| Real tracker, everything | 24.6 KB | 215 ms |
| Test tracker, everything | 24.6 KB | 244–252 ms |
| Test tracker, records only | 16.3 KB | 174–178 ms |
| Test tracker, intents only | 8.3 KB | 162–174 ms |
| Test tracker, empty | 0.1 KB | 91–114 ms |

- A write costs about 11–14 ms of fixed work (including the websocket call of the test) plus a part
  that grows with the size. From 24.6 KB to 8.3 KB saves about 6–10 ms per write.
- Measured from the trigger event to the state write alone, a write took only 3–5 ms at every size
  (one series showed 17–26 ms; not explained). Most of the size cost comes after the state write.
- **Real effect of a split by kind (intents in one sensor, per-cover records in another):** about
  50–80 ms less for 8 automations on one button, about 6–10 ms for one, about 0.13–0.22 s less loop
  work at a phase change at 22 / 132 (22 intent writes). Nothing at 1 / 12 (2 KB).

## Tracker split by kind (2026-11-13, afternoon)

One tracker sensor per namespace (`docs/superpowers/specs/2026-11-13-tracker-split-design.md`):
`cover_intents` (8.4 KB at 22 / 132), `cover_recorded_state` (16.3 KB), `cover_day_night`, `shared`.
Same probe, hub and house sizes; "before" is the previous section's package.

| House (automations / covers) | On the button | Before | After the split |
| --- | --- | --- | --- |
| 1 / 12 | 1 | 97 ms (max 114) | 88 ms (max 103) |
| 22 / 132 | 1 | 145 ms (max 165) | 119 ms (max 150) |
| 22 / 132 | 8 | 557 ms (max 2133) | 431 ms (max 740) |

No cover started twice or reversed; every press moved all its covers. Medians, ms after the event:

| Step | 22 / 132, 8 before | after | 22 / 132, 1 before | after |
| --- | --- | --- | --- | --- |
| Last of the requests | 197 | 190 | 20 | 21 |
| Deciding run reads (after the fence) | 394 | 292 | 60 | 46 |
| Variables render | 85 | 74 | 37 | 33 |
| Mover started | 494 | 378 | 102 | 84 |
| First cover | 557 | 431 | 145 | 119 |

- **The gain is larger than the write test predicted** (126 ms instead of 50–80 ms with 8 on the
  button). The intent writes and the fence now render 8 KB instead of 25 KB, and the resolver's batch
  write renders 16 KB. The decisions themselves did not change (last request at about 190 ms).
- **0.2 s holds for one automation per button at every size.** With 8 automations on one button it
  is 431 ms: about 190 ms of decisions (8 × about 24 ms), about 100 ms until the deciding run reads,
  about 85 ms of resolver work, about 55 ms from mover start to the first cover.
- The 2 s outlier of the earlier rows did not occur in these 12 presses (max 740 ms).
