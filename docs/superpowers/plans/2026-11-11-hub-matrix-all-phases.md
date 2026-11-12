# Hub matrix across all phases (2026-11-11)

Design: `docs/superpowers/specs/2026-11-04-cost-budget-architecture-design.md`, sections 1, 8 and 9.
Hub: Raspberry Pi 4 (`mogy-dev`, Frigate with one camera). Runner: branch `claude/hub-load-test-de6f21`,
`test/hub-load/` (`chain.sh`, `matrix.sh`, `run.mjs`, `kpi.mjs`).

## Method

- 8 code versions: baseline (cover_DayNight 3.1.3, package from `main`), step 1, step 2, step 3, fence
  (block 1), dicts (3.2.0 settings in three dicts), step 4 (batched suspend and mover), step 5 (`cover`
  namespace, max 200 with warnings).
- Sizes 20 / 15, 40 / 30, 60 / 40 (automations / covers), quiet hub; 60 / 40 also busy (`burn.mjs`,
  host CPU 100 %). 2 repetitions per cell. 0 invalid runs; 11 of 224 runs had 2 websocket reconnects,
  which the runner recovers.
- Every value is the worse repetition. `kpi.mjs` first took the median, which with 2 repetitions is the
  lower value and understated the stalls. Changed: costs show the highest value, completeness counts the
  lowest; CPU and tracker size keep the median.
- Stall: the longest delay of a websocket ping sent every 125 ms. Cover times: HA's own state timestamps,
  moved to the PC clock.
- Stall values move by up to about 1 s between repetitions. A single change below 1 s is not a clear effect.

## Result per phase (60 / 40, busy hub)

| Phase | Phase stall | Hand stall | Reload stall | Idle stall | Last cover | Peak runs | Dropped (phase / hand) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Baseline | 9.5 s | 4.8 s | 3.0 s | 541 ms | 4.3 s | 50 | 10 / 106 |
| Step 1 | 5.1 s | 1.6 s | 4.7 s | 489 ms | 5.2 s | 50 | 10 / 0 |
| Step 2 | 6.0 s | 2.3 s | 6.4 s | 518 ms | 7.6 s | 60 | 0 / 0 |
| Step 3 | 4.6 s | 1.5 s | 4.9 s | 439 ms | 5.7 s | 60 | 0 / 0 |
| Fence | 3.6 s | 2.9 s | 4.2 s | 569 ms | 4.7 s | 3 | 0 / 0 |
| Dicts | 2.3 s | 1.4 s | 2.8 s | 67 ms | 3.4 s | 3 | 0 / 0 |
| Step 4 | 2.3 s | 1.3 s | 3.0 s | 90 ms | 3.3 s | 3 | 0 / 0 |
| Step 5 | 2.4 s | 1.3 s | 2.7 s | 57 ms | 3.3 s | 3 | 0 / 0 |

- **Step 1** removes the hand-command fan-out: 106 dropped runs → 0, hand stall −67 %, phase stall −46 %.
- **Step 2** ends the dropped phase runs (queue limit 200), but every caller waited for its own write: stall
  and delay went up.
- **Step 3** batches tracker writes: 17 → at most 8 per resolver and mover cycle for 4 covers.
- **Fence** removes the wait per caller: peak runs 60 → 3.
- **Dicts** makes each publish run cheaper (20 → 8 ms before the request call): phase stall −36 %, reload
  stall −34 %, idle stall 569 → 67 ms.
- **Step 4** lowers counts, not the stall (as expected after spike S7): one suspend run per command, one
  service call per target.
- **Step 5** is a structure change. No KPI change, as expected.

Total, baseline → step 5: phase stall −75 %, hand stall −73 %, idle stall −89 %, last cover 4.3 → 3.3 s,
no dropped runs, peak runs 50 → 3. Reload stall not better: 3.0 → 2.7 s busy, but 3.2 → 4.3 s quiet
(the quiet values of the steps range from 2.4 to 4.3 s, so the noise is large). Tracker 14.6 → 20.1 KB.

## Budget check (step 5)

| Measure | Target 40 / 30 | 40 / 30 quiet | Target 60 / 40 | 60 / 40 busy |
| --- | --- | --- | --- | --- |
| Longest stall, phase change | 1 s | 1.3 s, missed | 1.5 s | 2.4 s, missed |
| Longest stall, person's command | 1 s | 0.7 s, met | 1.5 s | 1.3 s, met |
| Longest stall, reload | 1 s | 1.9 s, missed | 1.5 s | 2.7 s, missed (quiet: 4.3 s) |
| Most script runs at once | ≤ 10 | 3, met | ≤ 15 | 3, met |
| Spread of cover start times | 0.5 s | ≤ 0.1 s, met | 0.5 s | ≤ 0.1 s, met |
| First cover command | 2 s | 2.1 s, at target | 3 s | 3.3 s, 10 % over |

Decision on the missed targets: spec section 1, "Decision on the missed targets (2026-11-11)". What is
left in the phase stall is the second-0 block: every automation decides in the same second.

## Notes

- Baseline reload, repetition 2: the 3.1.3 automations did not publish. Only repetition 1 counts
  (3.2 s quiet, 3.0 s busy; an earlier hub run gave 2.8–3.5 s).
- Step 5, idle at 20 / 15: 3 of 4 repetitions (2 in the matrix, 2 in a re-run) had one
  stall of 0.25–1.1 s. The hub logbook has 0 entries in a 5 s window around each stall; the same query
  gives 79 entries (20 automations, 29 scripts, 30 covers) at a phase burst of the same run. The stalls are
  not at second 0, when the heartbeat runs. So no automation or script ran: the cause is outside the cover
  code. The larger sizes are clean (52–60 ms).
- All covers reached their targets in every run. No cover started twice.

## Full matrix

| Size | Hub | Code | Reps | Reload: intents | Reload: longest stall | Idle: longest stall | Idle: CPU median | Phase: covers closed | Phase: dropped runs | Phase: peak runs | Phase: first cover moves | Phase: last cover moves | Phase: covers started twice | Phase: longest stall | Hand: covers paused | Hand: dropped runs | Hand: first cover moves | Hand: longest stall | Tracker size |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 20/15 | quiet | m_baseline | 2 | 20/20 | 994 ms | 208 ms | 0.4 % | 15/15 | 0 | 20 | 1.5 s | 1.7 s | 0 | 2727 ms | 15/15 | 0 | 0.1 s | 1075 ms | 5 KB |
| 20/15 | quiet | m_step1 | 2 | 20/20 | 1370 ms | 190 ms | 0.4 % | 15/15 | 0 | 20 | 2.8 s | 2.9 s | 0 | 2298 ms | 15/15 | 0 | 0.1 s | 342 ms | 6 KB |
| 20/15 | quiet | m_step2 | 2 | 20/20 | 1348 ms | 61 ms | 0.4 % | 15/15 | 0 | 20 | 2 s | 2.1 s | 0 | 1325 ms | 15/15 | 0 | 0.1 s | 1124 ms | 7 KB |
| 20/15 | quiet | m_step3 | 2 | 20/20 | 1416 ms | 80 ms | 0.4 % | 15/15 | 0 | 20 | 1.9 s | 2 s | 0 | 1333 ms | 15/15 | 0 | 0.1 s | 339 ms | 7 KB |
| 20/15 | quiet | m_fence | 2 | 20/20 | 2347 ms | 64 ms | 0.4 % | 15/15 | 0 | 3 | 1.8 s | 1.9 s | 0 | 1208 ms | 15/15 | 0 | 0.1 s | 345 ms | 7 KB |
| 20/15 | quiet | m_dicts | 2 | 20/20 | 2008 ms | 306 ms | 0.4 % | 15/15 | 0 | 3 | 1.1 s | 1.2 s | 0 | 451 ms | 15/15 | 0 | 0.1 s | 270 ms | 7 KB |
| 20/15 | quiet | m_batch | 2 | 20/20 | 822 ms | 40 ms | 0.4 % | 15/15 | 0 | 4 | 2.4 s | 2.4 s | 0 | 1595 ms | 15/15 | 0 | 0.1 s | 216 ms | 7 KB |
| 20/15 | quiet | m_ns | 2 | 20/20 | 845 ms | 1115 ms | 0.4 % | 15/15 | 0 | 4 | 1.3 s | 1.3 s | 0 | 433 ms | 15/15 | 0 | 0.1 s | 219 ms | 7 KB |
| 40/30 | quiet | m_baseline | 2 | 40/40 | 2101 ms | 194 ms | 0.4 % | 30/30 | 0 | 40 | 2.7 s | 2.9 s | 0 | 4834 ms | 30/30 | 0 | 0.1 s | 2231 ms | 9.9 KB |
| 40/30 | quiet | m_step1 | 2 | 40/40 | 2797 ms | 197 ms | 0.3 % | 30/30 | 0 | 40 | 4.2 s | 4.4 s | 0 | 3730 ms | 30/30 | 0 | 0.1 s | 725 ms | 11.9 KB |
| 40/30 | quiet | m_step2 | 2 | 40/40 | 2922 ms | 142 ms | 0.5 % | 30/30 | 0 | 40 | 3.5 s | 3.8 s | 0 | 4628 ms | 30/30 | 0 | 0.1 s | 834 ms | 13.9 KB |
| 40/30 | quiet | m_step3 | 2 | 40/40 | 3009 ms | 207 ms | 0.4 % | 30/30 | 0 | 40 | 3.6 s | 3.7 s | 0 | 2645 ms | 30/30 | 0 | 0.1 s | 1214 ms | 13.9 KB |
| 40/30 | quiet | m_fence | 2 | 40/40 | 2764 ms | 178 ms | 0.4 % | 30/30 | 0 | 3 | 2.9 s | 3.1 s | 0 | 2198 ms | 30/30 | 0 | 0.1 s | 781 ms | 13.9 KB |
| 40/30 | quiet | m_dicts | 2 | 40/40 | 1895 ms | 62 ms | 0.4 % | 30/30 | 0 | 3 | 2.1 s | 2.2 s | 0 | 1302 ms | 30/30 | 0 | 0.1 s | 694 ms | 13.9 KB |
| 40/30 | quiet | m_batch | 2 | 40/40 | 1887 ms | 50 ms | 0.4 % | 30/30 | 0 | 3 | 2.1 s | 2.1 s | 0 | 1225 ms | 30/30 | 0 | 0.1 s | 703 ms | 13.9 KB |
| 40/30 | quiet | m_ns | 2 | 40/40 | 1864 ms | 58 ms | 0.4 % | 30/30 | 0 | 3 | 2.1 s | 2.1 s | 0 | 1322 ms | 30/30 | 0 | 0.1 s | 724 ms | 13.9 KB |
| 60/40 | quiet | m_baseline | 2 | 60/60 | 3235 ms | 490 ms | 0.4 % | 40/40 | 10 | 50 | 5.4 s | 5.7 s | 0 | 8196 ms | 40/40 | 106 | 0.1 s | 3990 ms | 14.6 KB |
| 60/40 | quiet | m_step1 | 2 | 60/60 | 4326 ms | 466 ms | 0.4 % | 40/40 | 10 | 50 | 4.7 s | 5 s | 0 | 4307 ms | 40/40 | 0 | 0.1 s | 1421 ms | 17.4 KB |
| 60/40 | quiet | m_step2 | 2 | 60/60 | 5430 ms | 632 ms | 0.3 % | 40/40 | 0 | 60 | 5.8 s | 6.2 s | 0 | 7136 ms | 40/40 | 0 | 0.1 s | 1491 ms | 20.1 KB |
| 60/40 | quiet | m_step3 | 2 | 60/60 | 6302 ms | 359 ms | 0.4 % | 40/40 | 0 | 60 | 5.5 s | 5.7 s | 0 | 4614 ms | 40/40 | 0 | 0.1 s | 1492 ms | 20.1 KB |
| 60/40 | quiet | m_fence | 2 | 60/60 | 4343 ms | 452 ms | 0.4 % | 40/40 | 0 | 3 | 4.6 s | 4.9 s | 0 | 3815 ms | 40/40 | 0 | 0.1 s | 1492 ms | 20.1 KB |
| 60/40 | quiet | m_dicts | 2 | 60/60 | 2945 ms | 77 ms | 0.4 % | 40/40 | 0 | 3 | 3.3 s | 3.6 s | 0 | 2365 ms | 40/40 | 0 | 0.1 s | 2578 ms | 20.1 KB |
| 60/40 | quiet | m_batch | 2 | 60/60 | 4208 ms | 153 ms | 0.4 % | 40/40 | 0 | 3 | 3.3 s | 3.4 s | 0 | 2484 ms | 40/40 | 0 | 0.2 s | 1255 ms | 20.1 KB |
| 60/40 | quiet | m_ns | 2 | 60/60 | 4279 ms | 60 ms | 0.4 % | 40/40 | 0 | 3 | 3.4 s | 3.4 s | 0 | 2362 ms | 40/40 | 0 | 0.2 s | 1263 ms | 20.1 KB |
| 60/40 | busy | m_baseline | 2 | 60/60 | 2999 ms | 541 ms | 0.2 % | 40/40 | 10 | 50 | 4.1 s | 4.3 s | 0 | 9454 ms | 40/40 | 106 | 0.1 s | 4780 ms | 14.6 KB |
| 60/40 | busy | m_step1 | 2 | 60/60 | 4732 ms | 489 ms | 0.2 % | 40/40 | 10 | 50 | 4.8 s | 5.2 s | 0 | 5147 ms | 40/40 | 0 | 0.1 s | 1589 ms | 17.4 KB |
| 60/40 | busy | m_step2 | 2 | 60/60 | 6370 ms | 518 ms | 0.2 % | 40/40 | 0 | 60 | 7.3 s | 7.6 s | 0 | 5995 ms | 40/40 | 0 | 0.1 s | 2307 ms | 20.1 KB |
| 60/40 | busy | m_step3 | 2 | 60/60 | 4928 ms | 439 ms | 0.2 % | 40/40 | 0 | 60 | 5.5 s | 5.7 s | 0 | 4561 ms | 40/40 | 0 | 0.1 s | 1455 ms | 20.1 KB |
| 60/40 | busy | m_fence | 2 | 60/60 | 4246 ms | 569 ms | 0.2 % | 40/40 | 0 | 3 | 4.4 s | 4.7 s | 0 | 3604 ms | 40/40 | 0 | 0.1 s | 2890 ms | 20.1 KB |
| 60/40 | busy | m_dicts | 2 | 60/60 | 2775 ms | 67 ms | 0.2 % | 40/40 | 0 | 3 | 3.2 s | 3.4 s | 0 | 2319 ms | 40/40 | 0 | 0.1 s | 1393 ms | 20.1 KB |
| 60/40 | busy | m_batch | 2 | 60/60 | 2958 ms | 90 ms | 0.2 % | 40/40 | 0 | 3 | 3.3 s | 3.3 s | 0 | 2299 ms | 40/40 | 0 | 0.2 s | 1345 ms | 20.1 KB |
| 60/40 | busy | m_ns | 2 | 60/60 | 2690 ms | 57 ms | 0.2 % | 40/40 | 0 | 3 | 3.3 s | 3.3 s | 0 | 2383 ms | 40/40 | 0 | 0.2 s | 1292 ms | 20.1 KB |
