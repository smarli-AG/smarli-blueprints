# Cover Arbitration Phase 2 — Constraint-Based Central Resolver (Design)

**Status:** design complete, ready for an implementation plan. Supersedes the "Open decisions" list in `docs/superpowers/plans/2026-07-22-cover-arbitration-and-false-suspension.md` § Phase 2 (items #1–#7 are all closed here).

**Context:** Phase 1 (settle-loop false-suspension fix) is merged (`origin/main`, PR #2). Nothing in this repo has shipped to a customer instance yet, so this design is free to rename keys and change value shapes without migration concerns — a fact several decisions below depend on.

---

## 1. Problem

Multiple smarli. cover automations can control the same cover: day-night today, a shade/Beschattung family next, later presence/privacy and storm protection. Today each automation commands covers directly through `script.smarli_cover_move`. Two consequences:

1. **No arbitration.** Two automations wanting different positions simply fight; the last writer wins physically, and neither knows the other exists.
2. **Coincident commands cause false suspensions.** Phase 1 stopped the common case (a shared `commanded_<entity>` record guards the settle-loop audit), but the guard trusts tracker-write order as a proxy for device-command order. Two instances racing the same cover in one tick can still self-suspend — Phase-1 residual #7.

**Goal:** one central resolver decides each cover's position from all declared intents; contributors never command covers themselves. This arbitrates correctly _and_ removes the coincidence that residual #7 depends on.

## 2. The model: targets and bounds

Rejected first, because the rejections explain the model (ported from the `cover-multi-automation-arbitration` memory so it survives in the repo):

- **Winner-takes-all priority** — killed by a concrete case: shade holds 20 (partial) while day-night wants 0 (night). Priority picks shade's 20, leaving the cover _more open_ than the loser wanted. Priority cannot express "shade blocks opening but must allow closing".
- **Shade writes a suspension to "protect" the cover** — a suspension is non-directional: it blocks closing as well as opening, so it would wrongly block day-night's legitimate night close.
- **Priority-ownership** (each automation checks a shared owner record, then acts itself) — cheaper than a resolver, but a yielded low-priority automation never reclaims after the winner releases without an explicit poke, and coincident commands remain possible.

**Chosen model.** A contributor publishes either kind of constraint, or both:

|            | Meaning                                                 | Semantics                                                           |
| ---------- | ------------------------------------------------------- | ------------------------------------------------------------------- |
| **Target** | "move to position X **now**"                            | A one-shot **event**. The newest target is the current instruction. |
| **Bound**  | "while I say so, this cover must stay within `min…max`" | A standing **condition**. Clamps whatever target is current.        |

Resolution is `clamp(newest_target, bounds)`. Checks:

- day target 100 + shade bound ≤20 → **20** (shaded)
- night target 0 + shade bound ≤20 → **0** (0 satisfies ≤20 — "blocks opening, allows closing" falls out of the arithmetic, no special rule)
- shade withdraws → **100** (day-night's target re-emerges)

**Corollary that keeps recency safe:** anything that must _hold_ against later events is a bound, not a target. A storm family publishes `max: 0` (must stay closed), not a target 0 — so it is not overridden by the next sunrise. Contributors that model themselves correctly never need priority to beat recency.

## 3. Tracker key grammar

Every tracker key becomes `<owner>::<name>`, where owner is an **automation id**, an **entity_id**, or the literal `global`. `::` cannot occur in an entity_id and will not occur in an id we generate, so the split is unambiguous. This exists so garbage collection needs zero per-family knowledge (§8).

| Namespace         | Key                                              | Value                                                                                               | Written by                                        |
| ----------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `shared`          | `<automation_id>::intent`                        | `{targets: {cover: pos}, bounds: {cover: {max?, min?}}, priority, ts, suspension_duration, until?}` | the owning contributor (single writer, wholesale) |
| `shared`          | `<cover>::resolved`                              | last resolved position (int) — the sticky record                                                    | the resolver only                                 |
| `shared`          | `<cover>::suspension`                            | suspended-until unix ts                                                                             | `manual_check`, settle audit                      |
| `shared`          | `<cover>::moving_<run>`                          | `{target, until}` while mover run `<run>` drives this cover                                         | that mover run only                               |
| `cover_day_night` | `<automation_id>::bright_since` / `::dark_since` | stabilizer edge timestamps                                                                          | the owning automation                             |

**Removed by this design:**

- `shared.commanded_<entity>` — the Phase-1 owner record. Its only consumer was the settle-loop guard, which is replaced by a comparison against `<cover>::resolved` (§6). This retires plan item #6 (its lifecycle) by deleting the key instead of managing it.
- `shared.moving_<instance_id>` — the whole-instance moving marker, replaced by per-cover, per-run markers.
- `cover_day_night.<id>_commanded` — day-night compares against its own published intent instead, so the same fact is stored once.

`priority` defaults per family: **day-night 10, shade 50, safety/storm 90.** Separated so that equal priorities on conflicting bounds — a configuration error, not something to resolve cleverly — do not arise in practice.

`until` is **optional** and honoured if present, but no shipped family sets it: orphan decay is handled by owner-liveness (§8). It exists for non-automation publishers and as the fallback if verification V1 fails.

## 4. Resolution algorithm

Per resolve run:

1. **Read** all `*::intent` keys in `shared`. An intent is **active** only if its owner automation **exists and is `on`** — disabling the shade automation releases its bound, which is the behaviour a technician expects. (GC deletes intents of automations that no longer exist; the `off` check is a separate, resolver-only rule.) Honour `until` if present.
2. **Scope** = every cover named in the `targets` or `bounds` of any active intent.
3. Per cover **C**:
   - **Target** = the active intent with the newest `ts` that names C in `targets`. Tie → higher `priority`; still tied → lexicographically by owner id, so the result is deterministic rather than dict-order luck. If no intent names C in `targets`, C has no intent behind it — only a bound, if any, can be standing on it — so the implicit seed must be **C's own physical reality**, not a memory of past intent: use `current_position`; if C is position-less, the state seed (`open`→100, `closed`→0); only if neither yields a number (C has never reported a position at all) fall back to the stale `<C>::resolved`; if that too is absent (the very first resolve for this cover) or C is `unavailable`/`unknown`, skip C this run rather than guessing. Reordering `<C>::resolved` to last place matters: a bound is a statement about physical state ("must not exceed X"), and seeding it from a stale intent record — rather than from where the cover actually sits — could move an already-compliant cover for no physical reason (e.g. the cover was hand-moved while nothing was watching after its last recorded intent).
   - **Bounds** = start from `lo=0, hi=100`; apply each bounding intent in order of descending `priority` (then owner id), **skipping any bound that would empty the range**. Two conflicting bounds → the higher-priority one wins outright; three or more terminate with a defined answer instead of a special case.
   - `resolved = clamp(target, lo, hi)`.
4. If `resolved != <C>::resolved`: **write `<C>::resolved` unconditionally**, and add C to the move batch **only if C is not suspended**. Writing even when suspended is what implements _cancel, not pause_ (§7). **Exception:** if C had no target this run (step 3's implicit-seed branch) and `resolved` equals that seed, C is **not** added to the batch even though the record changed — the bound didn't move anything because C already satisfied it, so there is nothing to command, only a stale record to correct. A cover that has a target is never filtered this way: it is commanded whenever `resolved` differs from the stored record, exactly as before this rule existed.
5. **Prune** inline: expired `<cover>::moving_*` keys only. `<cover>::resolved` is **not** pruned just because no active intent currently mentions the cover — it is entity-owned and survives until the core GC (§8) collects it when the cover entity itself disappears, consistent with the sticky-target semantics the rest of this design relies on.
6. Fire **one** `smarli_cover_move` run for the whole batch, non-blocking, with a `run` token.

### Coalescing

If another resolve run is already queued behind this one, **return immediately without writing or commanding**. The queued run has strictly fresher input and will compute the final answer — in principle removing the redundant intermediate command in the coincident case, and with it the visible "cover starts toward 100, reverses to 20" twitch.

**Measured (Task 5 A4, 10 coincident reps, confirmed again in the Task 6 acceptance sweep): it does not work reliably.** `state_attr('script.smarli_cover_resolve', 'current')` does not reflect a run that has been queued but not yet started — it only ever reported the caller's own single execution slot at the point each run checked it — so the earlier of two near-simultaneous runs almost never sees the later one as "queued" and almost never skips. Task 5 measured two commands in 9 of 10 genuinely-fresh coincident reps (1 coalesced); the Task 6 re-run measured two commands in 10 of 10. **Two commands — a visible intermediate position, then the corrected one — is the norm, not the rare fallback.** Correctness was unaffected in every rep measured across both sweeps (20 + 10 reps): correct final position, zero false suspensions. The step is kept because it is harmless, costs one cheap template check per run, and does help in the case a queue genuinely backs up (many resolves stacked, not just two near-simultaneous ones) — but do not describe it in contributor-facing docs as eliminating the twitch.

## 5. Contributor contract

A contributor (any cover blueprint) must:

1. **Publish, don't command.** Write `shared.<my_id>::intent` (wholesale replace) and then call `script.smarli_cover_resolve` **blocking**, passing the same intent as an overlay argument. Never call `smarli_cover_move`.
2. **Publish only on change** (edge-based). An idle house writes nothing.
3. **Publish a target only when genuinely deciding "move now", inside your own operating window.** Withdrawing a constraint outside that window means dropping the bound _silently_, with no target — otherwise a shade family whose condition clears at 22:00 would reopen covers that day-night closed at 21:00. Rule 3's implicit target then holds them where they are.
4. **Keep owning manual detection** for your own covers: the state trigger and the `manual_check` call stay in the blueprint (scripts cannot see `trigger`).

### `coversDayNight.yaml` changes

Small diff; the decision engine is untouched.

- `transition_needed` compares `desired_position` against **its own published target** (`shared.<id>::intent.targets.values() | first`, absent → `-1`; day-night gives every cover the same position, so any entry represents the instance). The `-1` first-run/restart catch-up sentinel is preserved exactly; `<id>_commanded` is deleted.
- The two move branches publish the intent and call resolve instead of `script.turn_on script.smarli_cover_move`.
- `binary_threshold` is no longer passed. The mover's own default becomes the single source of truth, retiring the "keep them in sync" comment in the blueprint. `settle_timeout` and `position_tolerance` likewise stay at the mover's defaults — the resolver passes only `run` and `targets`.
- Weather logic unchanged: a blocked close does **not** publish, so it retries every minute and closes as soon as the weather clears.
- Version → 3.0.0.

## 6. Manual detection under the resolver

The three-layer contract is unchanged in intent; two mechanics change.

- **Layer 1 (context)** — unchanged.
- **Layer 2 (moving markers)** — `manual_check` reads `<entity>::moving*` for the one cover instead of scanning every key in `shared` for `moving_*`. Cheaper and per-cover exact. During a supersede, two marker keys briefly coexist; that is correct, because two movers really are driving the cover.
- **Layer 3 (settle audit)** — suspend a stopped-short cover only if its position matches **neither the run's own target nor `<cover>::resolved`**. Genuine manual stop: commanded 0, user stops at 60, resolved 0 → matches neither → suspend. Superseded: run 1 wanted 100, run 2 resolved 20, cover rests at 20 → matches `::resolved` → no suspension.

That last change is what actually closes **Phase-1 residual #7**: the audit now compares against _system intent_ rather than a write-order proxy, so there is no race left to lose. Single-flight resolution (§9) removes the coincident commands that produced the race in the first place.

### Suspension duration is resolved centrally

Both blueprints watching a cover fire their state triggers on the same wall-switch press, both call `manual_check`, and both write `<cover>::suspension` — last writer wins arbitrarily. And a suspension is inherently a _cover-level_ fact, so configuring it per automation is a category error.

Fix without removing technician control: intents carry `suspension_duration`; **both** suspension writers use the **maximum across active intents naming that cover**, falling back to the value passed by the caller when no intent exists yet (e.g. a manual move in the first minute after setup). An automation with `should_suspend_after_manual_interaction: false` contributes `0`, so if any automation watching the cover wants suspension, the cover is suspended for the longest requested duration. Consequence: `smarli_cover_move` needs no per-cover duration argument — it derives the value the same way.

## 7. Suspension expiry: cancel, not pause

**Decision (2026-07-24):** when a suspension expires, nothing happens. A transition that fell inside the suspension is **cancelled, not deferred**. Implemented by writing `<cover>::resolved` even for covers skipped as suspended.

The trade-off, stated plainly: a 20:50 manual open with a 30-minute suspension cancels the 21:00 close, and the cover stays open all night. Accepted deliberately — the alternative re-asserts state after the user has acted.

Why bounds must never be re-asserted, while targets safely could be: a target is a one-shot event, so applying one late cannot loop (the record updates when it lands, and a further manual move produces no new transition). A bound is a standing condition — re-applying it after every manual override is an endless user-vs-automation fight, 30 minutes at a time.

The flip recipe to "pause" (deferred catch-up) is documented in `CLAUDE.md` § Suspension semantics: two edits, and a third only if two families ever want different policies.

## 8. Garbage collection

**Problem:** `instance_id` is `this.attributes.id`, regenerated whenever an automation is created. Delete-and-recreate leaves `<old_id>::intent`, `<old_id>::bright_since` and friends behind forever. Every tracker write snapshots the whole `data` attribute into the recorder, and HA refuses to record state attributes past a size limit — so unbounded growth eventually stops the tracker persisting across restarts. This bug predates Phase 2.

**Solution.** `script.smarli_tracker_gc` in `smarli_core.yaml`, family-agnostic by construction:

> For every key in every namespace, split on `::`. Keep it if the owner is the literal `global`, a live automation id (`states.automation | selectattr('attributes.id','eq', owner)`), or a live entity. Otherwise remove it.

The wrapping automation (config-level `id: smarli_tracker_gc`; HA slugifies its alias, so its real entity*id is `automation.smarli_tracker_garbage_collection`, not `automation.smarli_tracker_gc`) triggers on `automation_reloaded` + `homeassistant: start` — deleting an automation \_fires* `automation_reloaded`, so cleanup happens exactly when ownership can have changed and costs nothing in steady state. It waits 10 s for the reload to finish and **aborts if the automation list is empty**, guarding against sweeping mid-reload (verification V3).

Entity-owned keys survive automation churn by design — they describe the cover, not the automation — and are bounded by "covers ever automated", i.e. by hardware. They are collected only when the cover entity itself disappears; `<cover>::resolved` persists across intent churn (no active intent naming the cover does **not** prune it) precisely because it is entity-owned, not intent-owned, and because a stale-but-unchanged record must never read as a fresh transition on the next matching publish.

**Rejected:** a value-level `owner:` field on every entry. It would force `coversDayNight.yaml` value-shape changes, need a _second_ convention for entity-scoped keys (which have no owning automation), add Jinja at every read and write site, and make payloads larger — the opposite of the goal. Structural ownership in the key costs nothing.

## 9. Atomicity, ordering and concurrency

Tracker writes are atomic **per key** (the merge happens inside one template render). Everything below key level is writer-side read-modify-write and is not.

| Key                       | Writers                                 | Why it is safe                                                  |
| ------------------------- | --------------------------------------- | --------------------------------------------------------------- |
| `<automation_id>::intent` | its own automation (`mode: queued`)     | single writer, wholesale replace                                |
| `<cover>::resolved`       | the resolver only                       | single-flight → one writer at a time                            |
| `<cover>::suspension`     | `manual_check` **and** the settle audit | scalar; both write "now + duration"; a lost write costs nothing |
| `<cover>::moving_<run>`   | exactly one mover run                   | run token in the **key**, so there is nothing to race           |
| stabilizer keys           | own automation                          | single writer                                                   |

Note what carries the weight: a resolve run writes several `::resolved` keys as a _sequence_ of atomic writes, not a transaction. That is only safe because `mode: queued` prevents a second run interleaving. **Single-flight is the atomicity strategy for the resolved set**, not merely a way to avoid double commands.

**Hazard 1 (closed by design):** with a single `<cover>::moving` key, a superseded mover could read the marker as its own, then have run 2 overwrite it, then delete run 2's marker — leaving a mid-travel cover unmarked and exposed to a layer-2 false suspension. Putting the run token in the key gives one writer per key and removes the read-then-write entirely. (A compare-and-delete primitive in the tracker would also work and is a nice general tool, but exactly one key would use it — skipped as YAGNI.)

**Hazard 2 (ordering, which atomicity does not cover):** the tracker is an event-driven template sensor, so a write is not immediately visible. Passing the caller's own intent as an overlay fixes the caller's write but not a _sibling's_: if day-night and shade publish in the same event cycle, shade's resolve run could read a tracker without day-night's intent, resolve wrongly, and — being later — win. Fix: the resolve script opens with a `wait_template` for **its own** intent (matching `ts`) to be visible, with a **~1 s** timeout. Template renders are processed in event order, so once my write is visible every earlier write is too — one cheap wait buys ordering for all of them, and on timeout it degrades to the overlay rather than hanging. Depends on verification V2.

**Modes and numbers:**

| Script                      | Mode                  | Notes                                                     |
| --------------------------- | --------------------- | --------------------------------------------------------- |
| `smarli_cover_resolve`      | `queued`, `max: 50`   | milliseconds per run; never waits for travel              |
| `smarli_cover_move`         | `parallel`, `max: 50` | long-lived (settle loop); overlapping runs are legitimate |
| `smarli_cover_manual_check` | `parallel`, `max: 50` | covers change state simultaneously                        |

The resolver fires the mover **non-blocking**, so a queued resolve backlog drains at millisecond speed even with twenty contributors publishing in one tick. The `wait_template` timeout is the only tail risk, which is why it is kept short.

## 10. Movement behaviour

The resolver fires **one** mover run per batch. Inside it, covers are commanded back-to-back in a loop — microseconds apart, simultaneous to the naked eye — then audited and released **individually** by the Phase-1 per-cover settle loop, so a fast cover is freed in ~9 s without waiting for a slow sibling's ~19 s. Visible cascading on Zigbee/KNX installations is hardware serialisation, not our behaviour, and is unchanged from today.

Only covers whose resolved value **changed** are commanded, so a transition may move some covers of an instance and leave others (already correct, or suspended) alone.

## 11. Worked example

House: `cover.wohnzimmer` (position-capable). `…3123` = _Storen Tag/Nacht_ (sun method, priority 10, 30 min suspension); `…0456` = _Beschattung Süd_ (priority 50, 30 min).

| Time        | Event                                                                                                                                   | Result                                                                                                                                                                                                                         |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 06:32       | Sunrise+offset. Day-night: desired 100, no published target → `-1` → transition. Publishes `targets: {wohnzimmer: 100}`, calls resolve. | One active intent → resolved **100**. Recorded, mover run `r1` opens the cover. State change classified as automated via `wohnzimmer::moving_r1`.                                                                              |
| 11:15       | Sun reaches the façade. Shade publishes `bounds: {wohnzimmer: {max: 20}}`, no target.                                                   | Target still day-night's 100; `hi=20` → resolved **20** → cover shades.                                                                                                                                                        |
| 13:40       | Wall switch, cover to 100. Contextless, no live marker → layer 2 says manual.                                                           | `wohnzimmer::suspension = now + 1800` (max across intents). Resolver not called — no intent changed. Cover stays open in full sun: the price of "no fight", paid deliberately.                                                 |
| 14:10       | Suspension expires.                                                                                                                     | **Nothing happens.** Cancel, not pause.                                                                                                                                                                                        |
| 11:15–16:50 | Shade's bound never changes.                                                                                                            | No publishes, no resolve runs, no tracker writes.                                                                                                                                                                              |
| 16:50       | Sun leaves the façade. Shade drops its bound **and** publishes retract target 100 (inside its operating window).                        | Newest target = shade's 100; no bounds → resolved **100**. Cover already there → physical no-op, record updated. For a customer with _no_ day-night automation, this retract target is the only thing that reopens the window. |
| 21:00       | Sunset+offset, weather clear. Day-night publishes `targets: {wohnzimmer: 0}`.                                                           | Newest target → resolved **0** → cover closes.                                                                                                                                                                                 |
| 22:30       | Technician deletes the shade automation.                                                                                                | `automation_reloaded` → GC → `…0456::intent` removed. `wohnzimmer::resolved` / `::suspension` survive: their owner, the cover, still exists.                                                                                   |

**Coincident case (A4).** Both publish within the same second at 06:32. Resolve runs serialise. Run 1 (day-night) sees run 2 queued behind it → returns without writing or commanding (coalescing). Run 2 waits for its own intent to render — which, renders being ordered, means day-night's is visible too — resolves **20**, records it, commands once. No twitch, no redundant command, no false suspension. Under Phase-1 code this scenario suspended the cover and made both automations back off.

## 12. Files

| File                             | Change                                                                                                                                                                                                 |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `packages/smarli_core.yaml`      | + `script.smarli_tracker_gc`, + the wrapping automation `id: smarli_tracker_gc` (entity_id `automation.smarli_tracker_garbage_collection`); tracker semantics unchanged                                |
| `packages/smarli_cover.yaml`     | + `script.smarli_cover_resolve`; `smarli_cover_move` (per-cover/per-run markers, new audit guard, central suspension duration); `smarli_cover_manual_check` (marker read, central suspension duration) |
| `automation/coversDayNight.yaml` | publish intent + call resolve; drop `<id>_commanded`; version 3.0.0                                                                                                                                    |
| `CLAUDE.md`                      | arbitration model, `::` key grammar, contributor contract, GC rule, two decision-log entries (winner-takes-all, suspension-as-protection)                                                              |
| test env                         | shade **test stub** automation (publishes a bound / retract target on demand); test scripts                                                                                                            |

Key renames land everywhere at once (`suspension_<entity>` → `<entity>::suspension`, etc.). Nothing has shipped, so this is a rename, not a migration.

## 13. Verification before implementation

These are assumptions, not knowledge. A failure changes the **design**, not just the code, so they run first.

Verified 2026-07-24 against the Docker HA test env (`C:\Users\Pascal\smarli-ha-test\verify-assumptions.ps1`); full raw output in `.superpowers/sdd/task-1-report.md`.

|     | Check                                                                                                                                                                                                                     | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| V1  | Automation state objects expose `attributes.id`, on **both** 2024.10 and 2025.4                                                                                                                                           | ✅ Confirmed on both floors: `{{ states.automation \| map(attribute='attributes.id') \| list }}` returned the full, populated id list on 2024.10.4 and on 2025.4.4 (verified via `/api/config` version on each). Owner-liveness/GC can use `attributes.id` as designed; no `min_version` raise is needed on this basis.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| V2  | A trigger-based template sensor processes its triggers strictly in event order under burst load                                                                                                                           | ✅ 20 `smarli_tracker_set` events fired back-to-back; after a 3 s settle, all 20 keys (`k1`…`k20`) were present with correct values, in written order — no loss, no reordering. The `wait_template` ordering trick is sound as designed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| V3  | `automation_reloaded` fires after the reloaded entities exist                                                                                                                                                             | ✅ A probe automation on `automation_reloaded` wrote `states.automation \| list \| count` into the tracker; after `automation.reload` + 3 s, the recorded count (6) matched the actual live automation count (6). The default settling delay is sufficient; GC can rely on this trigger.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| V4  | Excluding `sensor.smarli_automation_tracker` from the recorder does not break its restore across restarts (trigger-based template sensors are expected to restore via `.storage/core.restore_state`, not the recorder DB) | ✅ With the recorder exclude active, a tracker key written pre-restart was still present, unchanged, after `docker restart`. Restore does not depend on the recorder DB; the exclusion is safe to ship.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| V5  | Behaviour at HA's state-attribute size limit (informational — quantifies the growth risk)                                                                                                                                 | ℹ️ Informational, not pass/fail. Current tracker `data` attribute is 311 bytes with the test env's real (sparse) usage — far from any practical HA state-attribute size ceiling. Confirms growth risk is low under normal load; GC still bounds long-run growth as designed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| V6  | `script.smarli_cover_resolve`'s `current` attribute reflects **queued** runs                                                                                                                                              | ⚠️ Not verifiable before implementation — `script.smarli_cover_resolve` does not exist yet. Proxy-read `script.smarli_cover_move` (`mode: parallel`, not the planned `mode: queued`) at rest: a `current` attribute exists and is readable, but no concurrent or queued run was observed, and `parallel` mode has no queue, so nothing about queued-behind semantics was established. Re-verify against the real script when it is built (the resolver task), before relying on `current` for coalescing. Consequence if it does not hold: drop the coalescing condition step; A4 then expects two commands and a visible twitch, never a suspension. **Re-verified against the real script in Task 5 (A4, 10 fresh reps) and again in Task 6's full sweep: it does not hold in practice.** `current` almost never reflects the second run as queued in time for the first run's check to see it, so the earlier run almost never skips — two commands measured in 9/10 reps (Task 5) and 10/10 reps (Task 6). Correctness was unaffected in every rep across both sweeps: correct final position, zero false suspensions. Only the "ideally one command" aspiration did not pan out; see §4 and §14 A4. |

Test-env scaffolding used for this pass (temporary `v3_probe` automation, temporary `recorder: exclude` block) was removed afterward; the container was restored to its prior image (`2025.4`) and confirmed back on `2025.4.4`. The temporary `v2`/`v3`/`v4` tracker namespaces could **not** be removed via the `smarli_tracker_remove` event — that event deletes a key within a namespace and always re-inserts the (possibly empty) namespace bucket, so it has no way to delete a namespace itself. They were instead purged directly via HA's core state API (reading `sensor.smarli_automation_tracker`, dropping the three keys from `data`, and POSTing the cleaned attributes back) — no change to `packages/smarli_core.yaml`. Verified removed both from the live state and from the persisted `.storage/core.restore_state`, and a follow-up probe write/remove cycle confirmed the trigger sensor renders from the cleaned baseline going forward rather than restoring the old namespaces.

## 14. Acceptance

Runtime, in the Docker HA test env; config-check clean on 2024.10 **and** 2025.4.

|     | Scenario                                                                 | Expected                                                                                                                                                                                                                                                                                                                                    |
| --- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | Day target 100 + shade bound ≤20                                         | Cover rests at **20**                                                                                                                                                                                                                                                                                                                       |
| A2  | Night target 0 + shade bound ≤20 still active                            | Cover closes to **0**                                                                                                                                                                                                                                                                                                                       |
| A3  | Shade withdraws its bound                                                | Cover returns to **100**                                                                                                                                                                                                                                                                                                                    |
| A4  | Both contributors publish conflicting intents in the same tick, repeated | Correct final position, **no false suspension**, every rep. **Two commands (a visible intermediate position, then the corrected one) is the norm** — coalescing to one command happened in only 1 of 10 fresh reps measured in Task 5, and 0 of 10 in Task 6's re-run; never a suspension in any of the 30 reps measured across both sweeps |
| A5  | Restart mid-shade                                                        | Cover returns to the resolved position; day-night does not stomp the live bound                                                                                                                                                                                                                                                             |
| A6  | Standalone shade, no day-night automation                                | Bound alone moves the cover; the retract target reopens it                                                                                                                                                                                                                                                                                  |
| A7  | Manual move whose suspension spans a transition                          | Transition cancelled; **nothing moves** when the suspension expires                                                                                                                                                                                                                                                                         |
| A8  | Create then delete a blueprint instance                                  | Its tracker keys vanish on reload; a live instance's keys survive                                                                                                                                                                                                                                                                           |
| A9  | Disable (not delete) the shade automation                                | Bound released; cover follows the remaining target                                                                                                                                                                                                                                                                                          |
| A10 | Infeasible bounds (`max 20` vs `min 50`)                                 | Higher-priority bound wins outright                                                                                                                                                                                                                                                                                                         |
| A11 | Batch of several covers commanded at once                                | All start moving **simultaneously to the naked eye** — measure the spread between first and last cover's `opening`/`closing` transition via the WS listener; assert the spread is **< 500 ms** (HA-side; hardware bus serialisation is out of scope)                                                                                        |
| R1  | Genuine manual mid-move stop                                             | Cover **is** suspended (Phase-1 regression)                                                                                                                                                                                                                                                                                                 |
| R2  | Contextless wall-switch move with no live marker                         | Cover **is** suspended (layer 2 regression)                                                                                                                                                                                                                                                                                                 |

## 15. Out of scope

A real shade/Beschattung blueprint (sun geometry, temperature gating, per-window azimuth — a family-sized design of its own; Phase 2 validates the contract with a test stub). The MQTT settings-entity work. Any change to weather logic.

## 16. Accepted residuals

- A manual move _during_ our movement, in the same direction to the same end position, remains indistinguishable — and irrelevant, since the outcome equals the automation's intent.
- Manual detection stays unreliable for cover _groups_, and position-only changes that do not change the cover state (40 % → 60 %) remain undetectable via state triggers.
- A contributor that publishes an intent but fails to call resolve leaves its intent unapplied until something else resolves. There is no heartbeat safety net: the case a heartbeat could actually repair (an orphaned bound with no remaining target) has nothing to command anyway.
- The settle loop's `superseded` check compares two mover runs' `started_ts` with a strict `>`. Two different-token runs whose timestamps render to the exact same float would both proceed to audit instead of the loser deferring to the winner, and the loser would false-suspend. Microsecond-resolution timestamps make an exact tie astronomically unlikely, and the resolver (single-flight, `mode: queued`) is now the only caller that can produce competing runs at all. One-line follow-up if ever wanted: tie-break on the marker key string when timestamps are equal.
- The tracker GC's "never sweep while the automation registry looks empty" guard only detects the registry being **completely** empty (a real mid-reload window); it cannot detect a _transient_ `unavailable` state on one otherwise-live automation, which would make GC misread that automation as dead and delete its live keys. Stress-tested across restart and reload cycles at 0.3–0.75 s polling intervals over roughly 7 automations and the transient was never observed; the 10 s settling delay before GC runs is the mitigation, not a proof it cannot happen.
- `smarli_tracker_remove` deletes a key but always re-inserts the (possibly empty) namespace bucket it lived in — there is no way to remove a namespace itself through the event contract, only its keys. Harmless in production, where namespaces are a fixed small set (`shared`, `cover_day_night`, …) that are expected to exist indefinitely.
