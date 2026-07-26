# smarli. Blueprints — Docker Home Assistant test environment

A local, disposable Home Assistant instance used to test the cover blueprints and packages at
**runtime**, because `check_config` catches almost none of what actually breaks: Jinja errors,
wrong filter arity, non-boolean template conditions and event-ordering races all pass config
validation and fail only when a template renders.

The environment lives **outside this repo** at `C:\Users\Pascal\smarli-ha-test\` and is therefore
tied to one machine. This document exists so it can be rebuilt, and so the hard-won facts about it
survive the machine.

---

## Layout

```text
C:\Users\Pascal\smarli-ha-test\
  docker-compose.yml     one service, container `smarli-ha-test`, port 8123
  .token                 long-lived access token (~1 year), used by every helper
  ha.ps1                 PowerShell helpers — dot-source before use
  test-*.ps1             the runtime test suite (see below)
  config/                the HA config directory, bind-mounted to /config
    configuration.yaml
    automations.yaml     test rig + blueprint instances + resolver stubs
    virtual.yaml         hass-virtual cover definitions
    packages/            smarli_core.yaml + smarli_cover.yaml (copied from the repo)
    blueprints/automation/smarli/coversDayNight.yaml   (copied from the repo)
    custom_components/   virtual, swissweather
    listen.py, mint.py   run inside the container via `docker exec` (they use HA's bundled aiohttp)
```

## Daily use

Every shell that touches Docker or the API needs the PATH fixed first — `docker` is not on the
PATH the tool starts with:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
```

`ha.ps1` provides `$HA_BASE`, `HA-Token`, `HA-Headers`, `HA-Call`, `HA-State`, `HA-Tracker`,
`HA-Shared`, `HA-Move`.

Two caveats about the helpers:

- **`HA-Event` is not defined there**, although most test scripts need it. Every script defines it
  inline; copy that pattern:
  ```powershell
  function HA-Event { param($t,$d=@{}) Invoke-RestMethod -Uri "$HA_BASE/api/events/$t" -Method Post -Headers (HA-Headers) -Body ($d|ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null }
  ```
- **`HA-Move` is stale.** It still passes `instance_id` and `suspension_duration` to
  `script.smarli_cover_move`, both of which were removed when the resolver became the only caller.
  The call still works (the run token falls back to `context.id`), but those two arguments are
  ignored. Prefer driving moves through the resolver, or through the `test_mover` rig.

Start, stop, pin a version:

```powershell
cd C:\Users\Pascal\smarli-ha-test
docker compose up -d                      # default image tag is 2025.4
docker compose down
$env:HA_VERSION="2024.10"; docker compose up -d    # pin to the declared floor
docker inspect smarli-ha-test --format '{{.Config.Image}}'
```

After any restart, wait for the API before testing — HA answers the port long before it is ready:

```powershell
$deadline = (Get-Date).AddMinutes(4)
while ((Get-Date) -lt $deadline) {
  try { if ((Invoke-WebRequest -Uri "http://localhost:8123/api/onboarding" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { break } } catch {}
  Start-Sleep 5
}
Start-Sleep 15   # entities finish registering after the API responds
```

## Deploying repo changes

Edit files **in the repo**, then copy them in. Package changes need a full restart; changes to
`automations.yaml` alone can use `HA-Call automation reload @{}`.

```powershell
$D = "C:\Users\Pascal\smarli-ha-test\config"
copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_core.yaml  "$D\packages\"
copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_cover.yaml "$D\packages\"
copy C:\Users\Pascal\GIT\smarli-blueprints\automation\coversDayNight.yaml "$D\blueprints\automation\smarli\coversDayNight.yaml"
docker restart smarli-ha-test
```

## Config check on both floors

The declared floor is **2024.10.0**; everything must also pass on 2025.4.

```powershell
$cfg = "C:\Users\Pascal\smarli-ha-test\config"
foreach ($v in @("2024.10","2025.4")) {
  $out = docker run --rm -v "${cfg}:/config" "ghcr.io/home-assistant/home-assistant:$v" python -m homeassistant --script check_config -c /config --info all
  $clean = $out -replace "`e\[[0-9;]*m",""
  "$v exit=$LASTEXITCODE : $(($clean | Select-String 'Successful config') -join '')"
  $clean | Select-String -Pattern "^ERROR|Invalid config|Failed"
}
```

Two traps: **without `--info all` it prints nothing but the header**, so a naive grep finds no
"Successful config" and looks like a failure; and the output carries **ANSI colour codes**, so
strip them (or check the exit code plus the absence of ERROR lines) before matching.

## What is installed

| Component                                                                       | Why it is there                                                                                                      |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `default_config`                                                                | full stack — API, websocket, recorder, frontend                                                                      |
| `demo`                                                                          | position and binary covers, but they **never report `opening`/`closing`**                                            |
| **hass-virtual** (twrecked, vendored into `custom_components/virtual/`)         | the only covers that simulate travel _with_ `opening`/`closing` states, which is what makes the settle loop testable |
| **hass-swissweather** (izacus, vendored into `custom_components/swissweather/`) | a real MeteoSwiss weather entity with hourly forecasts, for the weather-block path                                   |

**hass-virtual needs a patch.** v0.9.4 calls `verify_domain_control(COMPONENT_DOMAIN)` in two
places in `__init__.py`; the correct signature is `verify_domain_control(hass, COMPONENT_DOMAIN)`.
Without it, setup fails. Covers are declared new-style in `virtual.yaml` under the group
`imported`, with a bare `virtual:` in `configuration.yaml`.

**hass-swissweather** is configured headlessly by posting to `/api/config/config_entries/flow`
with postcode `8001`; the station is optional because `condition` comes from the forecast rather
than the station. It reports `supported_features: 3` (daily + hourly), so the blueprint's
FORECAST_HOURLY bit-2 guard passes and `weather.get_forecasts` returns real data.

## Entities

| Entity                                      | Notes                                                                                                                                                                                            |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `cover.vfast`                               | virtual, **6 s** travel, reports `opening`/`closing`, contextless                                                                                                                                |
| `cover.vslow`                               | virtual, **16 s** travel — the pair tests per-cover release (fast cover freed without waiting for the slow one)                                                                                  |
| `cover.vbright`                             | virtual, **8 s** travel — dedicated to `cover_brightness_test` so it doesn't contend with vfast/vslow                                                                                            |
| `cover.garage_door`                         | demo, binary (`supported_features` 3), no `current_position` — tests the position-less code paths                                                                                                |
| `weather.weather_at_8001`                   | real MeteoSwiss, hourly forecasts                                                                                                                                                                |
| `input_number.test_lux` / `sensor.test_lux` | TEST-ONLY controllable lux (`configuration.yaml`): the template sensor (`device_class: illuminance`) mirrors the input_number so brightness-method tests can force threshold crossings on demand |

## Automations

| Entity                                             | id                      | Purpose                                                                                                                                                                                                                                                                                                  |
| -------------------------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `automation.test_tick`                             | `test_tick`             | heartbeat used by other rig automations                                                                                                                                                                                                                                                                  |
| `automation.test_mover_contextless`                | `test_mover`            | fires `script.smarli_cover_move` from a `time_pattern` when armed via tracker key `test.fire`, so the move is **contextless** like a real heartbeat                                                                                                                                                      |
| `automation.test_manual_check_watcher_vfast_vslow` | `test_manual_watch`     | calls `smarli_cover_manual_check` for the virtual covers; **turn this off** to isolate the mover's layer-3 audit                                                                                                                                                                                         |
| `automation.covers_day_night_sun`                  | `cover_sun_test`        | blueprint instance, sun method, drives `cover.garage_door`, wired to the real weather entity, plus a `force_close` custom trigger                                                                                                                                                                        |
| `automation.covers_day_night_time`                 | `cover_time_test`       | blueprint instance, time method, drives `cover.vfast`, wired to `weather.weather_at_8001`. Close/open times are pinned to the past/future (`00:01:00`/`23:59:00`) so the heartbeat always genuinely wants it closed, for weather-block testing. **Left `off`** after use (see gaps) — turn on to re-test |
| `automation.covers_day_night_brightness`           | `cover_brightness_test` | blueprint instance, brightness method, drives `cover.vbright` from `sensor.test_lux`; `lux_sensor_delay` shortened to `00:00:20` for fast stabilizer testing. **Left `off`** after use (see gaps) — turn on to re-test                                                                                   |
| `automation.stub_day_target`                       | `stub_day`              | resolver stub: publishes a `targets`-only intent, armed via tracker key `stub.day`                                                                                                                                                                                                                       |
| `automation.stub_shade_bound`                      | `stub_shade`            | resolver stub: publishes bounds and/or a retract target, armed via `stub.shade`                                                                                                                                                                                                                          |
| `automation.smarli_tracker_garbage_collection`     | `smarli_tracker_gc`     | shipped by `smarli_core.yaml`, not a test fixture                                                                                                                                                                                                                                                        |

Note the id and the entity_id differ: HA derives the entity_id from the **alias** slug, while
`attributes.id` is the config-level `id`. Anything matching intents to automations uses
`attributes.id`; test scripts that call `automation.turn_off` need the entity_id.

## Known gaps in the environment

- ~~The time and brightness instances are inert~~ **Fixed 2026-07-26.** Both now point at real
  entities (see Automations table) and are left `off` so they don't perpetually hold a competing
  resolver intent on `cover.vfast`/`cover.vbright` between sessions — `automation.turn_on` them to
  test again. `sensor.test_lux` is backed by `input_number.test_lux`
  (`HA-Call input_number set_value @{entity_id="input_number.test_lux"; value=<lux>}`), not a real
  sensor, so thresholds are hit on demand instead of waiting for real light.
- **Two ghost automations** (`automation.v3_probe`, `automation.a8_gc_victim`) linger at state
  `unavailable` from earlier test runs. Deleting an automation leaves a permanent entity-registry
  entry whose `attributes.id` still resolves — which is exactly why the tracker GC filters out
  `unavailable` automations. They are harmless; they also make useful fixtures for GC tests.

## Gotchas that have each cost a debugging session

- **Any REST or WebSocket service call carries a `user_id`**, so manual detection reads it as a
  human acting and the cover self-suspends. To drive an _automated_ (contextless) move, arm the
  `test_mover` rig via the tracker key `test.fire`, or publish an intent through a stub. After any
  bare `cover.*` call, clear the resulting `*::suspension` keys before asserting anything.
- **Demo covers cannot test the settle loop.** Position covers ramp with the state stuck on `open`;
  binary covers jump instantly. Neither ever reports `opening`/`closing`, so the settle loop audits
  mid-ramp and false-suspends. Use the virtual covers.
- **`check_config` does not catch runtime Jinja errors.** Debug templates live instead:
  ```powershell
  Invoke-RestMethod -Uri "$HA_BASE/api/template" -Method Post -Headers (HA-Headers) -Body (@{template='{{ ... }}'} | ConvertTo-Json -Compress) -ContentType "application/json"
  ```
- **`last_changed` is the _latest_ transition, not the start of a move.** Measuring when covers
  began moving needs the history API: `/api/history/period/<iso8601>?filter_entity_id=cover.vfast,cover.vslow`,
  then take each entity's first `closing`/`opening` entry.
- **The tracker cannot delete a namespace.** `smarli_tracker_remove` removes a key and always
  re-inserts the (possibly empty) namespace bucket. Emptied namespaces persist; assert on keys.
  They can be purged out-of-band by POSTing a cleaned `data` attribute to
  `/api/states/sensor.smarli_automation_tracker`.
- **The tracker survives restarts via `.storage/core.restore_state`, not the recorder**, so
  excluding it from the recorder is safe and does not lose state across a restart.
- **PowerShell here is 5.1**: no `&&`/`||` chaining, no ternary, no `if(){}` as an expression.
  Chain with `;`, precompute into variables, and use `-join`.
- **`Get-Date -UFormat %s` returns a local-time epoch**, off by the UTC offset (7200 s in CEST).
  Use `([datetimeoffset](Get-Date)).ToUnixTimeSeconds()` when comparing against tracker timestamps.
- **A bare REST `cover.*` call only proves layer 1, never layer 2.** Every REST/WS call carries the
  token's `user_id`, so the _first_ state write it causes is always tainted — that write can never
  land in the "neither `user_id` nor `parent_id`" ambiguous case layer 2 exists for. To get a
  genuinely contextless write without real hardware, use HA's own context-recency rule instead:
  `homeassistant.helpers.entity.CONTEXT_RECENT_TIME_SECONDS` (confirmed **5s** on this image via
  `docker exec smarli-ha-test python3 -c "import homeassistant.helpers.entity as e; print(e.CONTEXT_RECENT_TIME_SECONDS)"`)
  nulls an entity's stored service-call context once it's older than that, so any subsequent
  internal `async_write_ha_state()` (e.g. a virtual cover's travel-simulation tick) is written with
  a **brand-new, contextless** `Context()`. Command a REST move on a **slow** cover (`vslow`, 16 s
  travel — comfortably past the 5 s cutoff), clear whatever suspension the tainted first tick
  produces, then wait past t+5s with no marker present: any later tick is the real ambiguous case,
  and there is nothing else that can have written the resulting suspension. See
  `test-r2-layer2-contextless.ps1`.
- **Forcing a schedule with `weather_events` values outside the blueprint's `select` selector list
  works at `use_blueprint:` scope** (config-check and runtime both accept it — selector `options`
  aren't enforced outside the UI dropdown), but don't rely on it: real weather rarely reports the
  _exact_ option string you'd need to test the "currently matches" branch, and a technician can
  only ever pick from the 9 listed options anyway. Prefer a real listed option (`rainy`, `windy`,
  …) when the live condition happens to allow it.

## Test suite

| Script                                                        | Covers                                                                                                                                                         |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test-resolver.ps1`                                           | A1–A3: day target + shade bound → 20, night → 0, bound withdrawn → 100                                                                                         |
| `test-markers.ps1`                                            | per-cover moving markers appear and are cleaned up; no legacy keys                                                                                             |
| `test-overlap.ps1`                                            | two overlapping moves from the **same** instance must not false-suspend                                                                                        |
| `test-cross-instance.ps1`                                     | two moves from **different** instances must not false-suspend                                                                                                  |
| `test-gc.ps1`                                                 | tracker GC removes orphaned keys, keeps live ones                                                                                                              |
| `test-daynight.ps1`                                           | the blueprint publishes an intent and no longer writes a legacy record                                                                                         |
| `test-a4.ps1`, `test-a4-fresh.ps1`                            | coincident conflicting intents; the `-fresh` variant resets both intents each rep, which the plain one does not                                                |
| `test-a7.ps1`                                                 | a suspension spanning a transition cancels it                                                                                                                  |
| `verify-assumptions.ps1`                                      | the V1–V6 design assumptions                                                                                                                                   |
| `test-r2-layer2-contextless.ps1`                              | R2 redone correctly: a genuinely contextless tick (context-staleness, not a tainted REST call) with no live marker suspends the cover                          |
| `test-brightness-stabilizer.ps1`                              | `bright_since`/`dark_since` written only on threshold crossings, never rewritten while steady; `schedule_wants_*` waits for `stabilizer_seconds` before acting |
| `test-part1.ps1`, `test-part1-regression.ps1`, `racetest.ps1` | Phase 1 era; kept for reference                                                                                                                                |

## Rebuilding from scratch

1. Install Docker Desktop (WSL2 backend; no sign-in needed for local containers).
2. Recreate `docker-compose.yml` as above and `docker compose up -d`.
3. Onboard: `POST /api/onboarding/users`, then `/auth/token`. Access tokens expire in 30 minutes,
   so mint a long-lived one over the WebSocket API (`auth/long_lived_access_token`) and save it to
   `.token`. `config/mint.py` does this from inside the container.
4. Vendor `custom_components/virtual/` and apply the `verify_domain_control(hass, …)` patch;
   write `virtual.yaml`; add `virtual:` to `configuration.yaml`.
5. Vendor `custom_components/swissweather/` (needs only `requests`) and drive its config flow
   headlessly with postcode 8001.
6. Copy the repo's `packages/` and the blueprint in, recreate `automations.yaml`, restart.
