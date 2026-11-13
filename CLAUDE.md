# smarli. Blueprints — Project Conventions

## Scope of this file

This repository will span many blueprint families — cover automation, camera notifications, battery warnings, and more. This file holds only what applies **across every family**: cross-cutting engineering conventions, shared infrastructure (the tracker), and the package/blueprint delivery model. It does not cover:

- **How to write a blueprint file itself** — the Partner Engine metadata block, per-input `translation`/`optional`/`display_if` annotations, release notes format, versioning consistency, the Danger Zone boilerplate. That is `Readme.md`'s job. A compact cheat-sheet is below for quick recall, but it is **not** the authoritative version — before writing or editing any blueprint file, make sure `Readme.md` is already in context for this conversation; if it isn't, read it first. This file being auto-loaded does not mean those rules are known without reading it at least once.
- **Deep architecture for one specific family** — once a family accumulates shared package logic, its own tracker namespace, or a non-obvious detection/arbitration contract, that detail moves into its own doc under `docs/`, not into this file. See the index below.

This split exists so this file stays cheap to load regardless of how many families the repo grows to: a task on a battery-warning blueprint should never have to pay the token cost of the cover family's arbitration algorithm.

### Blueprint file cheat-sheet (quick recall only — `Readme.md` is authoritative)

> **Maintenance note:** this cheat-sheet duplicates a slice of `Readme.md` on purpose, as a fast path for the common case. That means it can drift. Whenever `Readme.md`'s rules change — a field added/removed, the `optional`/`display_if` semantics change, the versioning rule changes — update **both** files, and `ci/check-blueprints.js`, in the same edit. If they ever disagree, `Readme.md` wins and this section is wrong.
>
> **Run `./ci/checks.sh` after editing any blueprint**, and `./ci/check-release.sh` before proposing a merge into `main`. See `Readme.md` → Checks.

- Partner Engine header fields: `icon`, `name_en`/`de`, `subtitle_en`/`de`, `short_description_en`/`de`, `long_description_en`/`de`, `purpose_en`/`de` (only `Comfort`/`Komfort`, `Energy`/`Energie`, `Security`/`Sicherheit` for now), `keywords_en`/`de`, `events_en`/`de`, `highlight`, `deploy`, and `is_smart_button` (only for a blueprint whose entire job is activating a scene from a button press — not for every button-triggered blueprint).
- Every real input needs `# optional: true|false` and `# display_if: <expr>` set explicitly, never omitted. `optional` judges the Partner Engine's own requiredness at the moment the input is visible — independent of Home Assistant's own `(optional)` suffix in `name:`, which can disagree (e.g. a field with `default: []` is HA-optional but Partner-Engine-required once its `display_if` makes it visible).
- An input with `optional: true`, or with any `display_if` other than the literal `true`, needs a `default:` — otherwise HA rejects the automation when the input stays empty or hidden.
- A `name:` ending in `(optional)` needs a `default:`. The reverse does not hold: a default alone (a preset select, a prefilled text) does not make an input optional, so don't add the suffix.
- `display_if` may reference only inputs declared above it, written bare (no quotes around the whole expression), using only the Readme's operators/functions. Strings take `'` or `"`.
- Every `!input` names a declared input, and every declared input is used via `!input` (fixtures excepted via `# checks: allow input-unused`).
- `translation` text may differ from HA's `name`/`description` on purpose — it is not checked for sync.
- The version number of the newest `RELEASE NOTES` entry must match, exactly, in `blueprint.description` and in both `long_description_en`/`de` — but the date stays in `RELEASE NOTES` only; the other three carry the version number alone, no date.
- `blueprint.description` is always English; `author` is the actual person, followed by `[smarli. AG]`.

## Blueprint families

All blueprint files live in one flat location, `automation/` — they are **not** split into per-family subfolders. Instead, every blueprint's filename starts with its family's prefix, so families stay identifiable and sort together without a folder move:

| Family | Filename prefix | Status | Shared package | Architecture doc |
| --- | --- | --- | --- | --- |
| Cover automation | `cover` | Built (`cover_DayNight.yaml`); `shade` planned | `smarli_cover.yaml` (in `ha-packages`) | `docs/cover-architecture.md` |
| Scene activation via smart button | `scene` | Built (4 hardware variants) | — (self-contained) | — |
| All off | `allOff` | Built | — (self-contained) | — |
| Weather warning | `weather` | Built | — (self-contained) | — |
| Camera notifications | `camera` | Planned | — | — |
| Battery warnings | `battery` | Planned | — | — |
| Partner Engine test fixtures (not for customers) | `peTestFixture_` | Built (`inputs`, `minimal`) | — | `Readme.md` → Checks |

**When to add a row and a doc:** the moment a family grows shared package logic, its own tracker namespace, or a non-obvious detection/arbitration contract. A family that stays a single self-contained blueprint doesn't need one — its logic is fully visible in the one file.

## Context

- Blueprints are publicly importable, but only smarli.-managed instances matter. These are guaranteed to have: the smarli. "Grundinstanz" packages, Mosquitto (MQTT), and HACS.
- End users do **not** have admin access — they cannot edit automations or blueprints. Anything a user should adjust must be exposed as a frontend entity.
- Supporting entities ship as **package** files, split by blueprint family (`smarli_<family>.yaml`) over a shared `smarli_core.yaml` foundation (Grundinstanz includes them all; retrofits get the core plus the relevant feature package(s) to drop into `config/packages/`). A blueprint is a single YAML and cannot ship entities itself. **The packages do not live in this repo.** They live in [`smarli-AG/ha-packages`](https://github.com/smarli-AG/ha-packages) — see [Delivery split](#delivery-split-grundinstanz-package-vs-blueprint).

## General blueprint-engineering conventions

- **Keep the number of variables in scope small.** HA walks every variable in scope at every step of a run (trace snapshot, scope lookups) and renders each variable on its own. On a Pi 4, 12 steps took 47 ms with 100 template variables, 32 ms with 100 constants, and 8 ms with 3 (2026-11-10). Group raw inputs in one dict (`inputs: {name: !input name, ...}`) and derived values in one template that returns a dict; keep as named variables only what conditions and steps read often. Give each dict a name that says what it holds. `cover_DayNight` 3.2.0 shows the shape (`inputs`, `schedule`, `decision`).
- **Package scripts and automations: `max: 200` and `max_exceeded: warning`, one call for many entities.** A dropped run must show in the log, never vanish (`silent`); the limit is a safety net, not a throttle. A script that acts on many entities (suspend, move) takes a list and does one batch write and one service call per command, not one run per entity: on a Pi 4 a command to 40 covers was 40 queued runs (2026-11-10). A run that must see its own tracker write waits once, for the whole batch.
- **Prefer a `device` selector/trigger over an `entity` selector/state trigger whenever an input targets specific hardware.** A `device` selector's filter can constrain by `manufacturer`, `model`, and `model_id` — precise enough to scope a blueprint to one exact product (e.g. `model_id: "S-ZB-1RE1-R251"` for the smarli. relay). An `entity` selector's filter is limited to `domain`/`device_class`/`integration` — it cannot distinguish one hardware model from another on the same integration, so a blueprint built for one product could silently match unrelated hardware. Resolve the device down to its entities in `trigger_variables` (`device_entities()`) when the automation still needs entity IDs, rather than asking the user to pick entities directly.

### Smarli. relay button-press pattern

Used by `allOff_smarliRelay.yaml` and `scene_activateSmarliRelay.yaml` — reach for this whenever a future blueprint is triggered by a smarli. relay. A smarli. relay reports as a toggling `switch` entity, not a discrete button-press event the way Zigbee/Hue remotes do — pressing it just flips `on`/`off`. To fire on **any** press of **any** selected relay (the device selector allows `multiple: true`, e.g. several relays wired to trigger the same scene), resolve the device(s) to their switch entities in `trigger_variables`, then watch the **parity** of how many are currently on:

```yaml
trigger_variables:
  smart_buttons: !input smart_buttons
  smart_buttons_entities: >
    {{ smart_buttons | map('device_entities') | sum(start=[]) | select('match', '^switch\.') | list }}

triggers:
  - trigger: template
    value_template: >
      {% set count_on = smart_buttons_entities | select('is_state', 'on') | list | count %}
      {{ count_on % 2 == 0 }}
  - trigger: template
    value_template: >
      {% set count_on = smart_buttons_entities | select('is_state', 'on') | list | count %}
      {{ count_on % 2 == 1 }}

conditions:
  - condition: or
    conditions:
      - condition: template
        value_template: "{{ trigger.platform != 'template' }}"
      - condition: template
        value_template: >
          {{ trigger.from_state.state in ['on', 'off']
             and trigger.to_state.state in ['on', 'off']
             and trigger.from_state.state != trigger.to_state.state }}
```

Why this shape:

- **Any single toggle, by any watched relay, flips the total on-count's parity.** A template trigger fires on a false→true edge of its `value_template`. Pairing "count is even" and "count is odd" as two separate triggers means exactly one of them fires on every single toggle of every watched relay, regardless of direction (on→off or off→on) and regardless of which relay in the group changed — that is what lets one `multiple: true` input represent "any of these buttons was pressed."
- **The condition reimplements the `not_from`/`not_to: [unavailable, unknown]` guard for a template trigger.** A plain state trigger can filter unavailable/unknown transitions declaratively; a template trigger can't, so the condition does it by hand — it only lets the automation run when the specific entity that caused the re-evaluation (`trigger.from_state`/`to_state`, which a template trigger exposes the same as a state trigger) made a genuine `on`↔`off` transition, not e.g. `unavailable`→`on` after a Zigbee reconnect.
- **`trigger.platform != 'template'`** lets any custom trigger (a different platform) through unconditionally — the guard only needs to filter the two template triggers this pattern owns.
- **Known limit:** this only tells you *that* one of the watched relays toggled, not *which one* — with `multiple: true`, pressing relay A and pressing relay B are indistinguishable from this trigger alone. Fine for "any of these buttons does the same thing" (all-off, one shared scene); not suitable if different buttons in the same input must do different things — that needs separate inputs, one relay each.

## State tracking: tracker sensors, not predefined helpers

For hidden/internal state in any blueprint, use the **tracker**: trigger-based template sensors, one per namespace, `sensor.smarli_tracker_<namespace>` — a generic key-value store. Never require users/technicians to predefine helper entities (`input_boolean`, `input_number`, …) for tracking.

**Why:** requiring predefined helpers adds manual setup friction per automation. A trigger-based template sensor restores state across restarts, enables wall-switch/physical manual-operation detection (which `context` alone cannot catch), and keeps all tracking in a few debuggable entities — with core HA only.

**Why one sensor per namespace (2026-11-13):** every write renders the whole sensor and hands it to the recorder and the websocket clients. With one sensor for everything, a write paid for every key of every family: on a Pi 4, 8 writes took 215 ms on a 24.6 KB tracker and about 165 ms on an 8.3 KB one. Now a write renders only the sensor of its namespace. Design: `docs/superpowers/specs/2026-11-13-tracker-split-design.md`.

**Design — generic KV store:**

- Each tracker sensor has an attribute `data` = `{key: value}` (any JSON-serializable value: timestamps, numbers, lists, dicts) and a static attribute `namespace`. All of them listen to the same four events, with an `event_data: { namespace: ... }` filter on each trigger.
- **The `data` template is the same text for every tracker sensor.** HA cannot share a template across package files (a `{% macro %}` exists only in its own template, imports read only from `custom_templates/`, and a YAML anchor works only inside one file). So each package file holds one copy (`data: &tracker_data >`) and its other tracker sensors use `data: *tracker_data`. `ci/check-tracker-templates.js` in `ha-packages` keeps the copies equal and checks each sensor's namespace and triggers. A shared macro file was rejected: one more file outside `packages/` that every installation must have.
- **Writes that must be ordered must go to one sensor.** One sensor renders its writes in the order they were fired; two sensors give no order between them. Example: the resolver fence lives with the intents (`cover_intents`).
- Two event types, so the intent is explicit at every call site: `smarli_tracker_set` (payload `namespace`, `key`, `value`) **upserts** the key; `smarli_tracker_remove` (payload `namespace`, `key`) **deletes** it. (A dedicated remove event is used rather than overloading "set with missing value" — a reader must be able to see a delete for what it is.)
- Batch forms of both: `smarli_tracker_set_many` (payload `namespace`, `items` = dict key → value) and `smarli_tracker_remove_many` (payload `namespace`, `keys` = list). **A run that writes more than one key uses them.** Every write renders and publishes the whole tracker, and a script step does not yield, so one write per key and cover piles up into one long block (on a Pi 4 at 14 KB, 115 single writes in one burst blocked HA for about 3 s). Needs `smarli_core.yaml` from 2026-11-09 — an older core ignores the batch events, so a package that sends them must roll out together with the core.
- The attribute template reads `this.attributes.data`, switches on `trigger.event.event_type`, merges/removes only the addressed key, and re-emits the whole dict. A `set` with no `value` is a safe no-op (never stores `null`).

**Atomicity model (critical):**

- Writes are **atomic at the key level** — the merge happens inside the single serialized template render.
- Anything _below_ key level is writer-side read-modify-write and **not atomic**. Therefore: make the key the unit that changes independently. Example: per-cover keys `<cover_entity_id>::suspension` — atomic; one fat `suspensions` dict under a single key — racy, don't.
- A value may be a list/dict only if exactly one writer replaces it wholesale (e.g. `automation_in_progress`).

**Namespaces:**

- A family's namespaces are split by **kind of data**, so a write of one kind never pays for the other. The cover family: **`cover_intents`** (what the automations want, plus the resolver fence) and **`cover_memory`** (what smarli. has recorded about each cover: `::resolved`, `::applied`, `::watcher`, `::suspension`, `::suspended_at`, moving markers). A manual override must pause _every_ cover automation targeting that device, and every cover blueprint reads it there.
- State that one automation keeps for itself (no other automation reads it) goes to the family namespace **`<family>_automation_memory`**, e.g. `cover_automation_memory` for the brightness timestamps of cover_DayNight. Its keys start with the automation id, so blueprints of the family never collide, and a new blueprint of the family stores such state there with no package change. There is no namespace per blueprint: a new one would need a new sensor and a package rollout.
- **`shared`** (`sensor.smarli_tracker_shared`, in `smarli_core.yaml`) only for state more than one family reads. Empty today.
- Decision rule: read by more than one family → `shared`; read by other automations of one family → `<family>_intents` or `<family>_memory`; read only by the automation that wrote it → `<family>_automation_memory`.
- **A namespace without a tracker sensor stores nothing**, silently: the write event reaches no sensor. `ci/check-tracker-templates.js` in `ha-packages` fails when a package or a blueprint (in the sibling `smarli-blueprints` checkout) writes to such a namespace.
- **A family's tracker sensors live in the family's package** (`smarli_<family>.yaml`), with one copy of the template (see above). The recorder exclusion is a glob in `smarli_core.yaml` (`sensor.smarli_tracker_*`): HA cannot merge a `recorder:` block from two package files.
- **Moving state between namespaces or sensors:** when blueprints are in the field, the package must stay compatible with them, because packages roll out before technicians re-import blueprints: readers look in both places until a migration has run, and a migration never overwrites a newer key. The 2026-11-13 split had no field instances and no migration: at the update every automation commands its covers once and running pauses are lost.
- **Key grammar:** every tracker key is `<owner>::<name>`, owner being an automation id, an `entity_id`, or the literal `global`. This is what lets `script.smarli_tracker_gc` in `smarli_core.yaml` collect keys whose owner no longer exists without knowing any family's key names — automation ids are regenerated on every create, so delete-and-recreate would otherwise leak a key per cycle. The GC ships as two entities: the script is `script.smarli_tracker_gc`, while the automation that triggers it carries config-level `id: smarli_tracker_gc` but slugifies to `automation.smarli_tracker_garbage_collection` — don't assume the two names match.

**Rules:**

- Keep the sensor `state:` static (e.g. `"ok"`) — never compute live counts that go stale between events. Evaluate expiry at read-time (`expiry <= now`).
- Read with `state_attr('sensor.smarli_tracker_<namespace>', 'data') or {}` — safe before the first write (a new tracker sensor is `unknown` and has no attributes until then). Read it in the template that needs it; do not copy a whole sensor into a variable (HA renders every variable to text and parses it back).
- Don't route high-frequency sensor data through the tracker (every write renders and publishes the whole sensor).
- For snapshot-and-restore of entity states within one runtime (e.g. lights before a scene), prefer core `scene.create` with `snapshot_entities` — the tracker is for state that must survive restarts or be read by other automations.

## Delivery split: Grundinstanz package vs. blueprint

**Two repos.** Blueprints live here. Every package, and any other config shared by all customer instances, lives in [`smarli-AG/ha-packages`](https://github.com/smarli-AG/ha-packages) under its `packages/` directory. A blueprint that needs a new or changed package script or entity needs a matching change in `ha-packages`. Land the package side first: technicians import blueprints directly, while packages roll out with the Grundinstanz. See `docs/test-environment.md` for testing both repos together.

**Trigger distributed, logic centralized.** Blueprints keep entity-scoped state triggers on their own devices (self-registering: the set of watched entities is derived from the set of automations), but all shared logic lives in **package files**, shipped with the Grundinstanz. Packages are split by blueprint family, `smarli_<family>.yaml`, over a single foundation file — HA merges same-domain sections (`script:`, `template:`, …) across all package files at load, so multiple files each carrying a `script:` block is expected, not a conflict (entity/object IDs must stay unique, which the `smarli_` prefix guarantees):

- `packages/smarli_core.yaml` (in `ha-packages`) — the **foundation every family reads**: the tracker template, `sensor.smarli_tracker_shared`, the recorder exclusion of every tracker sensor, and the tracker garbage collection. Nothing family-specific goes here.
- Each family with shared logic gets its own `smarli_<family>.yaml` — see the [Blueprint families](#blueprint-families) table above for what exists and where its detail lives.
- Genuinely cross-family state goes to `sensor.smarli_tracker_shared`, in `smarli_core.yaml`.

Retrofit ships `smarli_core.yaml` + the feature file(s) for the families in use. The Grundinstanz includes the whole `packages/` dir, so on managed instances the split is transparent.

Payoff: a detection/contract bug is fixed once in the package and rolls out fleet-wide — no blueprint re-imports, no automation edits. (A central watchdog automation triggering on all `state_changed` events was rejected: HA has no "all entities" trigger, so it would run for every state change in the house.)

## User-facing settings

**Phase 1 (current):** blueprint value inputs + optional helper-entity overrides (the existing `*_helper` input pattern). Resolve each setting in **one variables-block template** (priority: helper → input default); triggers/actions must only use the resolved variable, never the raw source. This keeps the source swappable.

**Phase 2 (planned): MQTT-discovery settings entities.** Replaces manual helper creation with entities the blueprint provisions itself:

- Blueprint gets setup triggers `event: automation_reloaded` + `homeassistant: start`; the setup branch publishes **retained MQTT discovery configs**, so entities exist seconds after the technician saves the automation — no manual first run.
- Identity comes from the automation itself, **no technician-entered slug**: use `this.attributes.id` (stable, rename-proof) for topics and `unique_id`s; use the automation's friendly name for the device display name. (`this.entity_id` rejected: entity-ID renames would orphan provisioned entities.)
- Topic scheme: `smarli/<blueprint>/<instance_id>/<key>`. Each automation instance gets its own topic subtree and its own **device** (all its settings grouped on one page). Multiple instances of the same blueprint therefore coexist cleanly. Shared state stays in the tracker, never instance-scoped.
- Values: `command_topic` = `state_topic` with `retain: true` → user settings survive restarts. Publish the default value only when the entity doesn't exist yet (never on every reload — would overwrite user settings). Read-side fallback to the blueprint input default while unset.
- The MQTT/discovery/JSON machinery lives in **one shared provisioning script** in the Grundinstanz package (`script.smarli_provision_entity`); blueprints call it once per setting.
- Known gaps: no MQTT `time` platform (use validated `text` `"06:30"` or a minutes `number`); deleting an automation orphans its entities (decommission script/runbook needed — topics are only discoverable via the device, since instance IDs are opaque).
- Migration rule: when Phase 2 lands, **deprecate — don't delete — the `*_helper` inputs** (removing declared inputs breaks already-configured automations). New read priority: MQTT entity → helper → input default.

## Design pattern: heartbeat evaluator, not delayed triggers

HA constraint driving this: automation `variables:` are **not available in triggers** — template triggers referencing variables never fire. Also, `next_rising`/`next_setting` always point to the future (naive `sunrise <= now()` comparisons are broken), and long `delay:`s die on restart. This applies to any blueprint with time-based, windowed, or scheduled logic — not just covers:

- **Keep triggers static and dumb:** a `time_pattern` heartbeat (every minute, or coarser if the family doesn't need per-minute precision), `automation_reloaded` + `homeassistant: start` (same trigger id as the heartbeat — evaluate immediately on save/boot), plus any entity/device triggers the family needs, and custom triggers merged via the **nested-trigger-list syntax** `- triggers: !input custom_..._triggers` (NOT `- !input ...`) — this requires **HA ≥ 2024.10**, which every blueprint using it must declare as its floor.
- **Put all real logic in resolved `variables:`, computed fresh every run**, and act only on **transitions** — the freshly computed desired state differs from what was last committed. This is restart-safe by construction: a missed transition during downtime is caught up on the next heartbeat, and nothing depends on a `delay:` surviving a reboot.
- **Gate the heartbeat in `conditions:`** (e.g. `trigger.id != 'heartbeat' or transition_needed`) so condition-failed runs don't spam logbook/traces.
- **Compare against your own last-published intent, not the entity's live state**, when deciding whether a transition is needed — comparing against live state re-asserts the target and fights manual overrides.

See `docs/cover-architecture.md` for the fully worked implementation of this pattern (`cover_DayNight.yaml`).

## HA / Jinja traps (each one cost a runtime bug here)

None of these are caught by `check_config` — they fail only at runtime, often silently.

- **`bitwise_and` is a filter, not a function:** `x | bitwise_and(4)`, never `bitwise_and(x, 4)`. The function form raises `UndefinedError` at runtime and passes config check.
- **There is no `zip` filter** in HA Jinja. Build dicts with the `dict(d.items() | list + [(k, v)])` idiom used throughout `smarli_core.yaml`.
- **Template conditions must render a clean boolean.** A dict or other non-bool goes through `result_as_boolean` and reads as _false_. Beware: `automation.trigger` skips conditions, so manual testing can mask this entirely.
- **A service call's `entity_id` cannot be an empty `!input`** — schema validation rejects `''` even when the step is runtime-guarded. Template it instead (`entity_id: "{{ weather_entity }}"`).
- **Automation `variables:` are not available in triggers.** Template triggers referencing them never fire — see the heartbeat-evaluator pattern above.
- **Per-trigger `variables:` render before the top-level `variables:` and have no `this`.** They cannot use top-level variables (the top level can use them), and `this.attributes.id` raises `'this' is undefined`, so the run fails. Anything that needs the automation's own id belongs at the top level. `cover_DayNight` 3.2.0 shows the split (`evaluate_schedule` on the triggers, `instance` at the top level, guarded by `schedule_evaluated`).
- **`sun.sun`'s `next_rising`/`next_setting` always point to the future** — subtract 86400 s when they already refer to tomorrow to get today's event.
- **A bare `{{ ... }}` field that renders to a pure numeric string gets recast to `int`/`float` after rendering, no matter the source variable's type.** HA re-parses the final rendered _text_ (literal-eval), not the Jinja value — so a purely-numeric `this.attributes.id` (the normal shape for a UI-created automation, e.g. `1785765273339`) passed as `owner: "{{ instance_id }}"` arrives as `int` even if `instance_id` was forced `| string` upstream (that filter only affects Jinja's internal stringification, not HA's post-render reparse). Fix at the consuming end instead — e.g. `owner | string` wherever the value is used as a dict key or compared against another owner id.
- **Reloading Automations does not reload Scripts or Templates defined in package files.** A fix to a package's `script:`/`template:` block looks like it silently didn't work if only "Reload Automations" was run — use the matching YAML reload (Scripts / Template Entities) or restart HA after editing `packages/*.yaml`.

## Decision log (considered & rejected) — cross-family

- **`input_text` holding JSON** — 255-char state cap, too small.
- **`var` (HACS custom integration)** — entities still predefined in YAML, sparse maintenance = fleet risk on HA upgrades, no functional edge over the tracker.
- **MQTT retained JSON for hidden state** — no server-side merge: whole-blob last-writer-wins with a stale read window (broker round-trip); per-key topics would need a provisioned entity per ephemeral key to be template-readable. Tracker wins for contended, dynamic, machine-written state; MQTT wins for few, static, human-edited settings.
- **`context`-based manual detection, alone** — cannot distinguish physical wall-switch presses (contextless) from other contextless changes; tracker-based in-progress markers catch these (see `docs/cover-architecture.md` for the full layered contract).
- **Technician-entered slug for instance identity** — manual uniqueness bookkeeping; `this.attributes.id` is automatic and rename-proof.
- **`python_script` + `hass.states.set`** — state lost on restart.
- **A value-level `owner:` field on every tracker entry** (instead of `<owner>::<name>` keys) — needs a second convention for entity-scoped keys, adds Jinja at every read/write site, and grows the payload we are trying to shrink.

Family-specific rejected designs live in that family's architecture doc (e.g. cover-arbitration alternatives in `docs/cover-architecture.md`), not here.
