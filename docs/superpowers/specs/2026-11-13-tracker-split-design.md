# Tracker split: one sensor per kind of data (design, 2026-11-13)

Status: built 2026-11-13 (ha-packages, cover_DayNight 3.2.0). Hub result: docs/superpowers/analysis/2026-11-11-button-latency.md, section "Tracker split by kind".

## Why

Every tracker write renders the whole tracker sensor, and HA then hands the new state to the recorder
and to every websocket subscriber. Today one sensor (`sensor.smarli_automation_tracker`) holds all
data of all families. Hub test 2026-11-13 (22 automations / 132 covers, 8 writes back to back, all
work included, `docs/superpowers/analysis/2026-11-11-button-latency.md`):

| Sensor content | Size | 8 writes |
| --- | --- | --- |
| Everything (today) | 24.6 KB | 215 ms |
| Per-cover state only | 16.3 KB | about 175 ms |
| Intents only | 8.3 KB | about 165 ms |
| Empty | 0.1 KB | about 100 ms |

Expected effect at 22 / 132: 50–80 ms less for 8 automations on one button, 6–10 ms for one, and
0.13–0.22 s less loop work at a phase change (22 intent writes). Nothing at 1 / 12. Each later family
also stops paying for the cover data on every one of its writes (holistic analysis 4.7).

No blueprint is in the field (only test instances), so this is the cheap moment.

## What the cover family stores

| Kind | Keys | Written by | Read by |
| --- | --- | --- | --- |
| Intents | `<automation id>::intent` | `smarli_cover_request` | resolver, suspend, simulation release, blueprint (own intent, watcher's intent) |
| Resolver fence | `global::resolve_fence` | resolver | resolver |
| Per-cover state | `<cover>::resolved`, `::applied`, `::watcher`, `::suspension`, `::suspended_at` | resolver (one batch write), suspend | resolver, mover, manual check, command check, blueprint conditions |
| Moving markers | `<cover>::moving_<run>` | resolver batch write, mover | mover, manual check, blueprint conditions, resolver (expired ones) |
| Brightness timestamps | `<automation id>::bright_since`, `::dark_since` | blueprint | blueprint |

## Design

**One trigger-based template sensor per namespace.** Each sensor listens to the same four events as
today (`smarli_tracker_set`, `_remove`, `_set_many`, `_remove_many`), with an `event_data` filter on
`namespace`. So the writers stay as they are: they only name a different namespace. A write renders
only the sensor of its namespace.

| Namespace | Sensor | Holds | Defined in |
| --- | --- | --- | --- |
| `cover_intents` | `sensor.smarli_tracker_cover_intents` | intents, the resolver fence | `smarli_cover.yaml` |
| `cover_recorded_state` | `sensor.smarli_tracker_cover_recorded_state` | per-cover state, moving markers | `smarli_cover.yaml` |
| `cover_day_night` | `sensor.smarli_tracker_cover_day_night` | brightness timestamps | `smarli_cover.yaml` |
| `shared` | `sensor.smarli_tracker_shared` | state read by more than one family (empty today) | `smarli_core.yaml` |

- **The fence must stay with the intents.** It works because one sensor renders its writes in the
  order they were fired: once the fence is visible, every earlier intent is visible. This holds within
  one sensor only. Both live in `cover_intents`.
- **Each write touches one kind.** The intent write and the fence go to `cover_intents`. The
  resolver's batch write, the remove write, suspend and the mover's marker writes go to `cover_recorded_state`.
  No write needs two sensors at once.
- **Attribute shape.** Each sensor's `data` attribute holds its namespace's keys directly
  (`state_attr('sensor.smarli_tracker_cover_recorded_state', 'data').get('cover.x::resolved')`), not
  `{namespace: {...}}`. A static attribute `namespace` names the namespace, for the garbage collection.
- **Garbage collection** (`smarli_core.yaml`) reads every `sensor.smarli_tracker_*` and removes keys
  whose owner is gone, per sensor, with that sensor's `namespace`.
- **The template is the same for every sensor.** HA cannot share a template across package files: a
  `{% macro %}` exists only in its own template, imports read only from `custom_templates/`, and a
  YAML anchor works only inside one file. So each package file holds one copy (about 30 lines), and
  its sensors share it with an anchor: one copy in `smarli_core.yaml`, one in `smarli_cover.yaml`, one
  per later family. A check in `ci/` keeps the copies equal. A shared macro in
  `custom_templates/` was rejected: it would add a file outside `packages/` that every installation
  must have, and without it every tracker sensor fails.
- **Removed at the same time** (holistic 4.5, the compatibility with 3.1.3): the `shared` reads of
  intents and per-cover state, the migration automation `smarli_cover_namespace_migration`, the
  "remove the caller's intent from before 3.2.0" step, the resolver field `transition` and
  `forced_owner`, and the blueprint fallbacks for an intent without `phase` or fingerprint.
- **`sensor.smarli_automation_tracker` goes away.** There is no reader left.

## Rollout

The new sensors start empty. On an instance that updates:

- At the next heartbeat every automation finds no intent of its own, decides as on a first run, and
  commands its covers to the schedule's position once.
- A running pause after a hand move is lost; the cover can move at that heartbeat.
- The watchers are elected again at the first resolver run.

Accepted for this update, also on mssw (Pascal, 2026-11-13): no instance is in the field. Package
and blueprint must roll out together: an old blueprint would read the removed
`sensor.smarli_automation_tracker`, find no intent, and command its covers every minute.

## Work

1. `smarli_core.yaml`: `sensor.smarli_tracker_shared`, garbage collection over all tracker sensors.
2. `smarli_cover.yaml`: the three sensors, every read and write, removal of the 3.1.3 code.
3. `cover_DayNight.yaml`: reads (own intent, watcher, watcher's intent, markers, pause time,
   brightness timestamps), removal of the old fallbacks, release notes.
4. Tests: the helpers in `test/runtime/lib/ha.ps1` (`HA-Tracker`, `HA-Key`, `HA-Shared`) and the
   suites that read the tracker directly (`test-tracker-batch`, `test-request`, `test-resolver`,
   `test-cheap-paths`, `test-namespace` and about 15 more); the migration tests go.
5. `ci/`: the check that the sensor templates are equal.
6. Docs: `CLAUDE.md` (state tracking section), `Readme.md`, `docs/cover-architecture.md`,
   `docs/test-environment.md` (they name the sensor).
7. Measure on the hub: write cost per sensor, the three button rows, a phase change at 22 / 132.

## Decisions (Pascal, 2026-11-13)

1. Names: `cover_intents` and `cover_recorded_state` ("what smarli. has recorded about each cover", not the HA entity state).
2. No migration at the update: the covers are commanded once and running pauses are lost. Accepted, also on mssw.
3. Only this update counts: package and blueprint update together. No compatibility period for older blueprints.
4. Template sharing: one copy per package file, shared there with a YAML anchor, plus a CI check that
   the copies are equal. No macro file in `custom_templates/`.
