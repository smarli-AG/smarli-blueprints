# smarli. Blueprints — Project Conventions

## Context

- Blueprints are publicly importable, but only smarli.-managed instances matter. These are guaranteed to have: the smarli. "Grundinstanz" packages, Mosquitto (MQTT), and HACS.
- End users do **not** have admin access — they cannot edit automations or blueprints. Anything a user should adjust must be exposed as a frontend entity.
- Supporting entities ship as **package** files, split by blueprint family (`smarli_<family>.yaml`) over a shared `smarli_core.yaml` foundation (Grundinstanz includes them all; retrofits get the core plus the relevant feature package(s) to drop into `config/packages/`). A blueprint is a single YAML and cannot ship entities itself.

## State tracking (Phase 1): central tracker sensor, not predefined helpers

For hidden/internal state in blueprints, use the single central **trigger-based template sensor** `sensor.smarli_automation_tracker` (friendly name `smarli. Automation Tracker`) — a generic key-value store. Never require users/technicians to predefine helper entities (`input_boolean`, `input_number`, …) for tracking.

**Why:** requiring predefined helpers adds manual setup friction per automation. A trigger-based template sensor restores state across restarts, enables wall-switch/physical manual-operation detection (which `context` alone cannot catch), and consolidates all tracking into one debuggable entity — with core HA only.

**Design — generic KV store:**

- One attribute `data` holds everything, structured as `data[namespace][key] = value` (any JSON-serializable value: timestamps, numbers, lists, dicts).
- Two event types, so the intent is explicit at every call site: `smarli_tracker_set` (payload `namespace`, `key`, `value`) **upserts** the key; `smarli_tracker_remove` (payload `namespace`, `key`) **deletes** it. (A dedicated remove event is used rather than overloading "set with missing value" — a reader must be able to see a delete for what it is.)
- The attribute template reads `this.attributes.data`, switches on `trigger.event.event_type`, merges/removes only the addressed key, and re-emits the whole dict. A `set` with no `value` is a safe no-op (never stores `null`).

**Atomicity model (critical):**

- Writes are **atomic at the key level** — the merge happens inside the single serialized template render.
- Anything _below_ key level is writer-side read-modify-write and **not atomic**. Therefore: make the key the unit that changes independently. Example: per-cover keys `suspension_<entity_id>` — atomic; one fat `suspensions` dict under a single key — racy, don't.
- A value may be a list/dict only if exactly one writer replaces it wholesale (e.g. `automation_in_progress`).

**Namespaces:**

- One namespace per blueprint (e.g. `cover_day_night`) for blueprint-specific state.
- A dedicated **`shared`** namespace for state used by more than one blueprint (e.g. cover suspensions — a manual override must pause _every_ cover automation).
- Decision rule: read/written by more than one blueprint → `shared`; only one → the blueprint's own namespace.

**Rules:**

- Keep the sensor `state:` static (e.g. `"ok"`) — never compute live counts that go stale between events. Evaluate expiry at read-time (`suspension_end <= now`).
- Read with `(state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('<namespace>', {})` — safe before first render.
- Don't route high-frequency sensor data through the tracker (every write snapshots the full attribute into the recorder).
- For snapshot-and-restore of entity states within one runtime (e.g. lights before a scene), prefer core `scene.create` with `snapshot_entities` — the tracker is for state that must survive restarts or be read by other automations.

## Manual-intervention detection (cover blueprints — shared contract)

Every cover blueprint must detect manual operation (wall switch, UI, mid-move stop) to set suspensions. Three layers:

**Layer 1 — `context` (certain cases).** On a cover state change, inspect `trigger.to_state.context`:

- `user_id` set → human via UI/app → **manual, suspend**.
- `parent_id` set → some automation/script commanded it → **not manual, ignore**.
- Neither → ambiguous: wall switch **or** an integration reporting a commanded move asynchronously with a fresh context (Zigbee/RF/KNX do this) → layer 2.

**Layer 2 — shared moving markers (disambiguate the window).** Before commanding covers, an instance writes ONE marker (single writer, replaced wholesale — atomic):

```yaml
namespace: shared # MUST be shared: cover X may belong to several cover blueprints;
key: moving_<instance_id> # a private marker would make blueprint A misread blueprint B's
value: # contextless movement as a wall-switch press
  until: <now + ~300s> # crash backstop; blind window really ends at run end (step below)
  targets: # per-cover targets — other blueprints may set positions, not just open/close
    cover.wohnzimmer: 100 # number = target position
    cover.atelier: closed # string = target state (position-less covers)
```

Handler rule for ambiguous changes on cover C: **any** unexpired `shared.moving_*` marker whose `targets` contain C → a smarli. automation is moving C → ignore. None → wall switch → suspend C.

**Layer 3 — per-cover settle loop (catches mid-move intervention).** After commanding, `smarli_cover_move` polls (~2 s) and classifies each cover still listed in its marker: still `opening`/`closing` → leave it (exempt while genuinely moving); reached target (position within ±tolerance, or the threshold-mapped open/closed state for binary covers) → **drop it from the marker** (finished cleanly); stopped short of target → **drop it and suspend it** (mid-move intervention). The marker is rewritten with only the still-moving covers as the set shrinks and removed once empty, so each cover stays exempt from manual detection for _exactly_ as long as it actually moves — not until the slowest sibling finishes. The loop is bounded by `settle_timeout` (a backstop for stuck covers, sized above the slowest cover's travel); if it fires with covers still moving, the marker is left to expire via its refreshed `until` rather than false-suspending them. (This is "Option B" — chosen over a single whole-marker settle wait because the release is per-cover, which matters for instances mixing fast and slow covers; implemented once in the shared script so every cover blueprint inherits it.)

Known residual blind spot (accepted): a manual move _during_ our movement _in the same direction to the same end position_ is indistinguishable — and irrelevant, since the outcome equals the automation's intent. Sure-fire press detection exists only at device level (KNX telegrams, button events) — expose via optional custom triggers, not core mechanism.

**Suspension semantics (UX decision) — cancel, not pause:** when a suspension expires, the cover **stays in its manual position until the next scheduled transition** — the automation never "catches up" or re-asserts state on expiry. A suspension only matters if it spans a transition, and a transition falling inside one is **cancelled, not deferred**. Confirmed 2026-07-24 for every cover family (day-night today, shade when it is built).

_Flipping to "pause" (deferred catch-up) later — Phase 2 resolver:_ two edits. (1) The resolver stops writing `<cover>::resolved` for covers it skipped as suspended, so the missed transition stays pending. (2) The blueprint that wants catch-up ORs a `catchup_needed` clause into its heartbeat condition (_any of my covers not at my target and no longer suspended_), mirroring the existing weather-block retry. Safe for **targets** — a one-shot event applied late cannot loop, because the record updates once it lands. Never do it for **bounds**: a standing condition re-applied after every manual override is an endless user-vs-automation fight. The flip stays a one-liner only while all families agree; if one wants pause and another cancel, the resolver must record `<cover>::applied` (what was actually commanded) next to `<cover>::resolved` (what the system wants) and each family compares against its own.

## Cover arbitration: contributors publish, one resolver commands

Several cover automations can control one cover. They never command it themselves — they publish an intent and call `script.smarli_cover_resolve`, which is the single mover.

- **TARGET** = "move to position X now" — a one-shot **event**. The newest target wins; `priority` only breaks a same-tick tie.
- **BOUND** = "while I say so, stay within min…max" — a standing **condition** that clamps whatever target is current. Bounds intersect; if two cannot both hold, the higher-priority one wins outright and the other is dropped for that cover.
- `resolved = clamp(newest_target, bounds)`. With no target at all, the implicit target is the cover's own `current_position` (or the state-mapped open/closed seed for position-less covers), falling back to the stale `<cover>::resolved` only if the cover cannot report where it is at all — a bound is a statement about physical reality, so it must seed from where the cover actually sits, never from a stale memory of past intent (see the design spec §4 for why that distinction matters).
- An intent counts only while its owner automation **exists and is on**. Priorities: day-night 10, shade 50, safety/storm 90.

**Contributor rules.** Publish only on change (edge-based — an idle house writes nothing). Publish a **target** only when genuinely deciding "move now", inside your own operating window; withdrawing a constraint outside that window means dropping the bound **silently**, with no target — otherwise a shade family whose condition clears at 22:00 reopens covers that day-night closed at 21:00. Anything that must _hold_ against later events is a bound, not a target. Keep owning your own manual detection (scripts cannot see `trigger`).

**Key grammar.** Every tracker key is `<owner>::<name>`, owner being an automation id, an entity*id, or the literal `global`. This is what lets `script.smarli_tracker_gc` in `smarli_core.yaml` collect keys whose owner no longer exists without knowing any family's key names — automation ids are regenerated on every create, so delete-and-recreate would otherwise leak a key per cycle. (The garbage-collector \_script* is `script.smarli_tracker_gc`; the wrapping _automation_ that triggers it has config-level `id: smarli_tracker_gc` but HA slugifies its alias, so its real entity_id is `automation.smarli_tracker_garbage_collection` — don't assume the id and the entity_id match.)

```
shared:  <automation_id>::intent   <cover>::resolved   <cover>::suspension   <cover>::moving_<run>
cover_day_night:  <automation_id>::bright_since | ::dark_since
```

**Suspension duration is cover-level, not automation-level.** Several automations watch one cover and all fire on the same wall-switch press, so `script.smarli_cover_suspend` takes the **maximum** `suspension_duration` across active intents naming that cover; an automation with suspension turned off contributes 0.

## Delivery split: Grundinstanz package vs. blueprint

**Trigger distributed, logic centralized.** Blueprints keep entity-scoped state triggers on their own covers (self-registering: the set of watched covers is derived from the set of automations), but all shared logic lives in **package files**, shipped with the Grundinstanz. Packages are split by blueprint family, `smarli_<family>.yaml`, over a single foundation file — HA merges same-domain sections (`script:`, `template:`, …) across all package files at load, so multiple files each carrying a `script:` block is expected, not a conflict (entity/object IDs must stay unique, which the `smarli_` prefix guarantees):

- `packages/smarli_core.yaml` — the **foundation every family reads**: `sensor.smarli_automation_tracker`, the KV store. Nothing family-specific goes here.
- `packages/smarli_cover.yaml` — cover-family shared machinery:
  - `script.smarli_cover_manual_check` — detection layers 1+2 and suspension writes. Called from each blueprint's `cover_state_changed` branch, which forwards `trigger.entity_id` and context fields (scripts cannot see `trigger`).
  - `script.smarli_cover_move` — the whole moving contract: filter suspended covers → marker → command → settle-wait → position audit (layer 3) → suspend on mismatch → remove marker. Blueprints call it with `instance_id` + `targets` and never touch markers/suspensions directly.
- Future families (lights, weather, notifications, …) each get their own `smarli_<family>.yaml`; genuinely cross-family state stays in the tracker's `shared` namespace, in `smarli_core.yaml`.

Retrofit ships `smarli_core.yaml` + the feature file(s) for the families in use. The Grundinstanz includes the whole `packages/` dir, so on managed instances the split is transparent.

Payoff: a detection/contract bug is fixed once in the package and rolls out fleet-wide — no blueprint re-imports, no automation edits. (A central watchdog automation triggering on all `state_changed` events was rejected: HA has no "all covers" trigger, so it would run for every state change in the house.)

**Cover targets are always numeric positions 0–100 — never `'open'`/`'closed'`.** There is no "just open it" in this system: every target a blueprint passes to `smarli_cover_move` (and stores in `_commanded` / the moving marker) is an explicit position — `100` = open, `0` = closed, anything between = partial. The move script translates the number per cover: `SET_POSITION`-capable covers (`supported_features` bit `4`) get `set_cover_position`; binary covers open if the target ≥ `binary_threshold` (default 50), else close. This keeps one code path for all cover hardware. **Future cover blueprints MUST pass numbers and rely on this fallback — do not reintroduce string-based open/close handling.** (Consequence: transition detection compares the numeric target, so `_commanded` must store the position value, never a coarse label — a string vocabulary can't distinguish 40 from 70.)

## Cover blueprint architecture: dumb triggers, smart evaluator

HA constraint driving this: automation `variables:` are **not available in triggers** — template triggers referencing variables never fire. Also, `next_rising`/`next_setting` always point to the future (naive `sunrise <= now()` comparisons are broken), and long `delay:`s die on restart. Therefore:

- **Triggers are static and dumb:** a `time_pattern` heartbeat (every minute), `automation_reloaded` + `homeassistant: start` (same id as heartbeat — evaluate immediately on save/boot), a state trigger on the covers for manual detection (use `not_from`/`not_to: [unavailable, unknown]` — this fires on real state transitions only, suppresses per-tick attribute noise, and skips availability flaps; a bare state trigger with no `from`/`to` fires on every attribute change, and `to: null` is not valid), and custom triggers merged via the **nested-trigger-list syntax** `- triggers: !input custom_..._triggers` (NOT `- !input ...`) — this requires **HA ≥ 2024.10**, which is the blueprint's declared floor.
- **All logic lives in resolved variables + a heartbeat evaluator:** compute `schedule_wants_open`/`schedule_wants_closed` per method, clamp with earliest/latest windows (window arithmetic instead of delayed actions — restart-safe), then `desired_position` (a numeric target; closed wins over open in the evening overlap; outside both phases → hold last commanded). Act only on **transitions**: `desired_position != last_commanded`, where `last_commanded` reads the tracker key `<instance_id>_commanded`, written _before_ calling the move script so queued runs dedupe.
- **`_commanded` is intent, not physical state.** It records the last position the automation _committed to commanding_ (a blocked close never writes it), never a cover's actual position. On first run it is unset and reads as a `-1` sentinel, which never equals a real position — so the first evaluation always transitions and drives covers to the correct phase rather than assuming their current state. Comparing intent-to-intent is what lets a manually repositioned cover keep its position (its `_commanded` still matches `desired_position`) while a transition missed during downtime is caught up on reboot (`_commanded` is stale). Never compare against `current_position` here — that would re-assert the target and fight manual overrides.
- **Gate the heartbeat in `conditions:`** (`trigger.id != 'heartbeat' or transition_needed or stabilizer_dirty`) — condition-failed runs don't spam logbook/traces.
- **Brightness stabilizer via tracker keys** (`<id>_lux_above_since`/`_below_since`) instead of trigger `for:` — writes only on threshold edges.
- **Weather blocks closing only**, checked at close time (current conditions + first hourly forecast entry via `weather.get_forecasts`). A blocked close does **not** write `_commanded`, so it retries every minute and closes as soon as weather clears.
- **Today's sun times:** `next_rising/next_setting`, minus 86400 s when they already point to tomorrow (±2 min accuracy — fine for covers).
- **The move is fired non-blocking** via `script.turn_on` (with `data: variables:`), not a direct `action: script.smarli_cover_move` call. This is load-bearing: a direct call _blocks_ the automation run for the whole settle-wait, and under `mode: queued` our own covers' state-change events queue behind it and get classified only _after_ the move removes its marker — so a contextless cover would be misread as manual and self-suspended. Firing non-blocking keeps the marker live while those state-changes are classified. Trade-off: custom open/close actions run right after the move is _initiated_, not after covers settle.
- `mode: queued` (not `single` — state changes arriving during a run would be silently dropped; not `parallel` — overlapping heartbeats could double-command and race on the shared marker key). With the non-blocking move, runs are short, so the queue does not build up.

Known limitations (documented in the blueprint): manual detection is unreliable for cover _groups_ (state triggers can't watch members; groups are still expanded for actions via `expand()`), and position-only changes that don't change the cover state (40 % → 60 %, stays `open`) are undetectable via state triggers.

## User-facing settings

**Phase 1 (current):** blueprint value inputs + optional helper-entity overrides (the existing `*_helper` input pattern). Resolve each setting in **one variables-block template** (priority: helper → input default); triggers/actions must only use the resolved variable, never the raw source. This keeps the source swappable.

**Phase 2 (planned): MQTT-discovery settings entities.** Replaces manual helper creation with entities the blueprint provisions itself:

- Blueprint gets setup triggers `event: automation_reloaded` + `homeassistant: start`; the setup branch publishes **retained MQTT discovery configs**, so entities exist seconds after the technician saves the automation — no manual first run.
- Identity comes from the automation itself, **no technician-entered slug**: use `this.attributes.id` (stable, rename-proof) for topics and `unique_id`s; use the automation's friendly name for the device display name.
- Topic scheme: `smarli/<blueprint>/<instance_id>/<key>`. Each automation instance gets its own topic subtree and its own **device** (all its settings grouped on one page). Multiple instances of the same blueprint therefore coexist cleanly. Shared state stays in the tracker, never instance-scoped.
- Values: `command_topic` = `state_topic` with `retain: true` → user settings survive restarts. Publish the default value only when the entity doesn't exist yet (never on every reload — would overwrite user settings). Read-side fallback to the blueprint input default while unset.
- The MQTT/discovery/JSON machinery lives in **one shared provisioning script** in the Grundinstanz package (`script.smarli_provision_entity`); blueprints call it once per setting.
- Known gaps: no MQTT `time` platform (use validated `text` `"06:30"` or a minutes `number`); deleting an automation orphans its entities (decommission script/runbook needed — topics are only discoverable via the device, since instance IDs are opaque).
- Migration rule: when Phase 2 lands, **deprecate — don't delete — the `*_helper` inputs** (removing declared inputs breaks already-configured automations). New read priority: MQTT entity → helper → input default.

## HA / Jinja traps (each one cost a runtime bug here)

None of these are caught by `check_config` — they fail only at runtime, often silently.

- **`bitwise_and` is a filter, not a function:** `x | bitwise_and(4)`, never `bitwise_and(x, 4)`. The function form raises `UndefinedError` at runtime and passes config check.
- **There is no `zip` filter** in HA Jinja. Build dicts with the `dict(d.items() | list + [(k, v)])` idiom used throughout `smarli_core.yaml`.
- **Template conditions must render a clean boolean.** A dict or other non-bool goes through `result_as_boolean` and reads as _false_. Beware: `automation.trigger` skips conditions, so manual testing can mask this entirely.
- **A service call's `entity_id` cannot be an empty `!input`** — schema validation rejects `''` even when the step is runtime-guarded. Template it instead (`entity_id: "{{ weather_entity }}"`), as the weather branch in `coversDayNight.yaml` does.
- **Automation `variables:` are not available in triggers.** Template triggers referencing them never fire.
- **`sun.sun`'s `next_rising`/`next_setting` always point to the future** — subtract 86400 s when they already refer to tomorrow to get today's event.

## Decision log (considered & rejected)

- **`input_text` holding JSON** — 255-char state cap, too small.
- **`var` (HACS custom integration)** — entities still predefined in YAML, sparse maintenance = fleet risk on HA upgrades, no functional edge over the tracker.
- **MQTT retained JSON for hidden state** — no server-side merge: whole-blob last-writer-wins with a stale read window (broker round-trip); per-key topics would need a provisioned entity per ephemeral key to be template-readable. Tracker wins for contended, dynamic, machine-written state; MQTT wins for few, static, human-edited settings.
- **`context`-based manual detection** — cannot distinguish physical wall-switch presses (contextless) from other contextless changes; tracker-based in-progress markers catch these.
- **Technician-entered slug for instance identity** — manual uniqueness bookkeeping; `this.attributes.id` is automatic and rename-proof. (`this.entity_id` rejected: entity-ID renames would orphan provisioned entities.)
- **`python_script` + `hass.states.set`** — state lost on restart.
- **Winner-takes-all priority for covers** — shade holding 20 (partial) vs. day-night wanting 0 (night): priority picks 20, leaving the cover _more open_ than the loser wanted. Priority cannot express "blocks opening, allows closing"; the target/bound split can.
- **A shade family writing a suspension to "protect" a cover** — a suspension is non-directional, so it would also block day-night's legitimate night close.
- **Priority-ownership** (each automation checks a shared owner record, then acts itself) — cheaper than a resolver, but a yielded low-priority automation never reclaims after the winner releases without an explicit poke, and coincident commands remain possible.
- **A value-level `owner:` field on every tracker entry** (instead of `<owner>::<name>` keys) — needs a second convention for entity-scoped keys, adds Jinja at every read/write site, and grows the payload we are trying to shrink.
- **A resolver heartbeat automation** — the one case it could repair (an orphaned bound whose contributor is gone) has no remaining target to command anyway, so it buys nothing for a per-minute run and a visible system automation.
