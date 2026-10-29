# Cover blueprints — tests on real hardware

The Docker test environment (`docs/test-environment.md`) cannot reproduce real motors, one-way radio
(Somfy RTS) or a physical remote. Run these checks on a real instance before a cover release is
rolled out. Each entry says which change it checks.

## Before every test

- **Do not move the covers through the HA app, a dashboard or a wall switch right before a test.**
  smarli. reads that as a manual operation and pauses the automation for the suspension duration
  (30 min by default). A scheduled open or close inside the pause is cancelled, not delayed.
- **Do not use a Somfy remote to prepare the start position either**, unless the test asks for it.
  HA does not see remote moves, so smarli. still believes the cover is where it last sent it.
- Let the automation drive the covers to the start position itself: set a close time a few minutes
  ahead, let it close, then set the next time.
- Set every time at least 3 minutes ahead. The automation checks once per minute.
- **Closing wins when both are due.** For an opening test, keep the close time after the end of
  the test. Otherwise the automation closes again at once.
- Saving changed times can trigger a command right away. Example: the open time has passed and
  the new close time is still ahead, so the automation sends "open" within a minute.
- Note the exact clock times. The developer reads the traces afterwards (HA keeps only the last 5).

## Checklist

Needed versions: `cover_DayNight.yaml` 3.1.2 and the smarli. Cover package with the resolver
`transition` flag (`ha-packages` `main` since PR #3, 2026-10-29).

| # | Scenario | Steps | Expected |
| --- | --- | --- | --- |
| H1 | Close when already closed (RTS) | Covers are closed by the automation, and the close time has passed. Change a schedule setting that does not matter today, e.g. the non-workday open time, and save. | Within a minute the close command is sent again. The shutter does not move, nothing breaks, and the cover is **not** paused (no `<cover>::suspension` key appears). |
| H2 | Remote-raised shutter, scheduled close | Open time already passed. Covers closed by the automation. Raise them with the **Somfy remote**. Set close time 3 min ahead, earliest close 5 min ahead, and save. | An "open" may be sent within a minute after saving (the shutters are already up, so nothing visible). Nothing at the close time. The shutters close at the earliest-close time. |
| H3 | Remote-lowered shutter, scheduled open | Close time set after the end of the test. Covers opened by the automation, then lowered with the remote. Set open time 3 min ahead, earliest open 5 min ahead, and save. | Nothing at the open time. The shutters open at the earliest-open time. |
| H4 | Save without changes | Open the automation, save it without changing anything. | No cover moves. |
| H5 | Update to 3.1.2 | On an instance still on 3.1.1, import 3.1.2 and reload automations, during the day. | No cover moves at the update. The next scheduled open or close works normally. |
| H6 | App operation pauses | Move a cover with the HA app. Set a close time inside the next 30 minutes. | The close is skipped (cancelled). After the pause the cover stays where it is until the next scheduled transition. |
| H7 | Two automations, one shutter | Two automations on the same shutter, closing at T1 and T2 (T2 later). After T1, raise the shutter with the remote. | At T2 the shutter closes again. This is intended: T2 is a planned close. |

Report for each test: the clock times, what the shutter did, and whether a pause was reported.
