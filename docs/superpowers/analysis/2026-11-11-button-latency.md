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
