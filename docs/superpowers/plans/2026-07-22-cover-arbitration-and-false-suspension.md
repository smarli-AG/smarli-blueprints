# Cover Multi-Automation Arbitration + False-Suspension Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop smarli. cover automations from false-suspending each other when they command the same cover (Phase 1), then give them a real arbitration model so competing intents resolve correctly (Phase 2), and re-run the runtime test checklist against the _new_ code (Phase 3).

**Architecture:** All shared cover logic lives in `packages/smarli_cover.yaml` (tracker itself in `packages/smarli_core.yaml`); blueprints stay thin and delegate. Phase 1 is a surgical fix to the `smarli_cover_move` settle-loop audit. Phase 2 replaces the "each automation commands directly" model with a **constraint-based central resolver** (automations publish intent; one resolver commands). Testing is done in a live Dockerized HA instance, not with unit tests.

**Tech Stack:** Home Assistant (YAML blueprints + packages, Jinja templates), Docker Desktop (WSL2), PowerShell driving the HA REST/WS API.

## Global Constraints

- HA floor is **2024.10.0**; every change must config-check clean on **both** `2024.10` and `2025.4`.
- Cover targets are **always numeric positions 0–100**, never `'open'`/`'closed'`. `smarli_cover_move` maps numbers to services (`set_cover_position` if `supported_features | bitwise_and(4) > 0`, else `open_cover`/`close_cover` at `binary_threshold`, default 50).
- `bitwise_and` is a **filter** in HA Jinja: `x | bitwise_and(4)`, never `bitwise_and(x, 4)`.
- Tracker writes are atomic **per key**. A dict/list value is only safe if **one** writer replaces it wholesale. Cross-blueprint state → `shared` namespace; per-blueprint state → its own namespace.
- Template **conditions** must render a clean boolean — a dict/non-bool reads as _false_ via `result_as_boolean`.
- A fix in a package rolls out fleet-wide (no blueprint re-import) — prefer package changes over blueprint changes.
- Any German user-facing copy: Swiss-German Du-Form, capital "Du/Dein/Dir".

---

## Orientation — read before starting (the test env already exists)

A working Dockerized HA test env is **already built and running**. Do **not** rebuild it from scratch.

- **Location (durable):** `C:\Users\Pascal\smarli-ha-test\` — `docker-compose.yml`, `config/`, `ha.ps1` (PowerShell helpers), `.token` (long-lived token, valid ~1 yr), `racetest.ps1`.
- **Container:** `smarli-ha-test` (port 8123). Bring up/down: `cd C:\Users\Pascal\smarli-ha-test; docker compose up -d` / `down`. Pin version with `$env:HA_VERSION="2024.10"` before `up`.
- **What's installed:** `default_config`, `demo` (covers `hall_window` sf=15 position, `garage_door` sf=3 binary, etc.), **hass-virtual** (`cover.vfast` 6s travel, `cover.vslow` 16s travel — these _do_ report `opening`/`closing`), **hass-swissweather** (`weather.weather_at_8001`, real MeteoSwiss, `sf=3` incl. hourly). Both custom components are patched/working (see memory).
- **Config-check (no run needed):**
  ```powershell
  $cfg = "C:\Users\Pascal\smarli-ha-test\config"
  foreach ($v in @("2024.10","2025.4")) {
    docker run --rm -v "${cfg}:/config" "ghcr.io/home-assistant/home-assistant:$v" python -m homeassistant --script check_config -c /config
  }
  ```
- **Runtime helpers:** `. C:\Users\Pascal\smarli-ha-test\ha.ps1` gives `HA-Call`, `HA-State`, `HA-Tracker`, `HA-Shared`, `HA-Move`, `HA-Token`. Note: the token belongs to a real user, so **any REST/WS service call carries `user_id`** → looks manual → self-suspends. To drive an _untainted_ (contextless / heartbeat-like) move, arm the `test_mover` helper automation via tracker key `test.fire = {targets:{...}}` (fires within 5s from a `time_pattern`, no `user_id`).
- **PowerShell 5.1 gotchas:** no inline `if(){}` as an expression; use `-join`, precompute into `$vars`. `docker` isn't on PATH in the tool's default shell — prefix every call with the PATH line the helpers use.
- **Repo edits vs test env:** edit the **repo** files, then copy into the test config and reload/restart:
  ```powershell
  $D="C:\Users\Pascal\smarli-ha-test\config"
  copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_core.yaml  "$D\packages\"
  copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_cover.yaml "$D\packages\"
  copy C:\Users\Pascal\GIT\smarli-blueprints\automation\coversDayNight.yaml "$D\config\blueprints\automation\smarli\coversDayNight.yaml"
  docker restart smarli-ha-test   # package changes need a full restart; automations.yaml alone can HA-Call automation reload
  ```
- **Design context (READ FIRST):** memory files `cover-multi-automation-arbitration.md` (the arbitration thread — settled + open decisions), `test-env-plan.md` (env details, all bugs found, runtime findings). These are the source of truth for _why_.

---

## Phase 1 — Stop the settle-loop false-suspension

**Problem (reproduced):** when two automations command the same cover to different targets, the "losing" automation's `smarli_cover_move` settle-loop audit (layer 3) sees the cover stopped at the _other's_ target, reads it as mid-move manual intervention, and suspends it. Since suspensions are shared, both back off.

**Fix:** add a shared per-cover last-command record `shared.commanded_<entity> = {instance_id, target, ts}`, written when `smarli_cover_move` commands a cover. The settle-loop audit only flags a stopped-short cover as manual intervention if that record **still points to my instance_id**; if another instance has since claimed it, it's a sibling override → the existing prune logic drops it from my marker and — with this guard — it is **not** suspended. Human moves never write this key, so genuine manual stops of _my_ move (record still = me) are still flagged.

### Task 1: Add per-cover last-command record + guard the intervention audit

**Files:**

- Modify: `packages/smarli_cover.yaml` — script `smarli_cover_move`, step `Command each cover to its target position` (the `repeat`), and the `intervened` variable inside `Release covers from the marker as they settle`.
- Test (runtime): `C:\Users\Pascal\smarli-ha-test\` collision scenario.

**Interfaces:**

- Produces: shared tracker key `commanded_<entity_id>` with value `{instance_id: <str>, target: <int>, ts: <float>}`, written by `smarli_cover_move` for every cover it commands.
- Consumes: existing `instance_id` and `started_ts` script variables.

- [ ] **Step 1: Write the failing runtime test**

Create `C:\Users\Pascal\smarli-ha-test\test-part1.ps1`. It fires two conflicting untainted-irrelevant moves (settle-loop audit is context-independent, so direct `HA-Move` is fine) on an **unwatched** cover to isolate layer 3 from `manual_check`:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
function HA-Event { param($t,$d=@{}) Invoke-RestMethod -Uri "$HA_BASE/api/events/$t" -Method Post -Headers (HA-Headers) -Body ($d|ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null }
function SuspList { $n=(HA-Shared).PSObject.Properties.Name; ($n | Where-Object { $_ -like 'suspension_*' }) -join ',' }
# Ensure cover.vfast is NOT in any blueprint instance's cover_entity (isolates layer 3).
HA-Call cover set_cover_position @{ entity_id="cover.vfast"; position=50 } | Out-Null
Start-Sleep 6
HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key='suspension_cover.vfast' }
Start-Sleep 2
"pre susp=[$(SuspList)]"
HA-Move -instanceId "auto_open"  -targets @{ 'cover.vfast'=100 }
HA-Move -instanceId "auto_shade" -targets @{ 'cover.vfast'=0 }
Start-Sleep 12
$s = SuspList
"FINAL vfast=$((HA-State 'cover.vfast').attributes.current_position) suspensions=[$s]"
if ($s -match 'cover\.vfast') { "RESULT: FAIL (false suspension)" } else { "RESULT: PASS (no false suspension)" }
```

- [ ] **Step 2: Run it against current code to confirm it FAILS**

First make sure `cover.vfast` is unwatched: in `C:\Users\Pascal\smarli-ha-test\config\automations.yaml` the `cover_sun_test` instance's `cover_entity` should be `[cover.garage_door]` only (it already is from the collision demo). Then:

Run: `powershell -File C:\Users\Pascal\smarli-ha-test\test-part1.ps1`
Expected: `RESULT: FAIL (false suspension)` — `suspension_cover.vfast` present. (This is the known-bad baseline.)

- [ ] **Step 3: Apply the fix — write the record when commanding**

In `packages/smarli_cover.yaml`, in `smarli_cover_move` → `Command each cover to its target position` → `repeat.sequence`, append a step **after** the `choose` (so a failed command isn't recorded as owned — record only follows an issued command):

```yaml
- alias: Record last-commander for this cover (cross-automation arbitration)
  event: smarli_tracker_set
  event_data:
    namespace: shared
    key: "commanded_{{ cover }}"
    value:
      instance_id: "{{ instance_id }}"
      target: "{{ target_position }}"
      ts: "{{ started_ts }}"
```

- [ ] **Step 4: Apply the fix — guard the `intervened` audit**

In the same script, in `Release covers from the marker as they settle` → `variables` → `intervened`, read the shared record and require the cover to still be owned by me before flagging it. Replace the current template:

```yaml
intervened: >
  {% set ns = namespace(bad=[]) %}
  {% for cover, target in pending.items() %}
    {% if states(cover) not in ['unavailable', 'unknown', 'opening', 'closing'] %}
```

with:

```yaml
intervened: >
  {% set shared = (state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('shared', {}) %}
  {% set ns = namespace(bad=[]) %}
  {% for cover, target in pending.items() %}
    {% set owner = shared.get('commanded_' ~ cover, {}).get('instance_id') %}
    {% if owner == instance_id and states(cover) not in ['unavailable', 'unknown', 'opening', 'closing'] %}
```

(The rest of the loop body — the `supports_position` / binary branches and `{{ ns.bad }}` — stays byte-for-byte identical. A sibling-overridden cover now has `owner != instance_id` → skipped → not suspended; the existing prune step still drops it from the marker because it isn't in `still_moving`.)

- [ ] **Step 5: Config-check both versions**

```powershell
$cfg = "C:\Users\Pascal\smarli-ha-test\config"
copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_cover.yaml "$cfg\packages\"
foreach ($v in @("2024.10","2025.4")) { docker run --rm -v "${cfg}:/config" "ghcr.io/home-assistant/home-assistant:$v" python -m homeassistant --script check_config -c /config }
```

Expected: `Successful config` / no ERROR lines on both.

- [ ] **Step 6: Restart and re-run the collision test — expect PASS**

Run: `docker restart smarli-ha-test` (wait for `/api/onboarding` to 200), then `powershell -File C:\Users\Pascal\smarli-ha-test\test-part1.ps1`
Expected: `RESULT: PASS (no false suspension)`.

- [ ] **Step 7: Regression — a genuine manual mid-move stop STILL suspends**

Add `cover.vfast` back to a watched instance temporarily, or test on a watched cover: drive an automated close on a watched virtual cover, then mid-travel issue `cover.stop_cover` with the user token (manual). The record still shows the automation as owner, cover stopped short → must be suspended.

```powershell
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
# vfast watched by an instance here; start an automated close via test_mover (untainted), then STOP it mid-travel (manual):
# 1) arm test.fire targets {cover.vfast:0}; 2) after ~2s: HA-Call cover stop_cover @{entity_id='cover.vfast'}
# EXPECT: suspension_cover.vfast appears (manual stop correctly detected).
```

Expected: `suspension_cover.vfast` present → manual detection intact.

- [ ] **Step 8: Commit**

```bash
git add packages/smarli_cover.yaml
git commit -m "fix(smarli_cover): don't false-suspend covers a sibling automation moved

Settle-loop layer-3 audit now records a shared per-cover last-command
(commanded_<entity>) and only flags a stopped-short cover as manual
intervention if it still owns that record. A cover moved by another
smarli. automation is dropped from the marker without suspension.
Reproduced + verified in the Docker HA test env."
```

---

## Phase 2 — Constraint-based arbitration

**Done.** Design: `docs/superpowers/specs/2026-07-24-cover-constraint-resolver-design.md`.
Implementation plan: `docs/superpowers/plans/2026-07-24-cover-constraint-resolver.md`.
All seven open decisions were closed in the design pass; open decisions #6 and #7
(the `commanded_<entity>` lifecycle and the settle-loop race) were resolved by
deleting that key and auditing against `<cover>::resolved` instead.

---

## Phase 3 — Resume the runtime test checklist against the NEW code

**Do this only after Phase 1 (and, if built, Phase 2) are merged and deployed into the test env.** These items were deferred and must be run against the _actual_ implementation, not the pre-fix state. Re-sync the env (copy repo → test config, restart) first.

- [ ] **Two-file package split** still config-checks clean on 2024.10 + 2025.4 (already true; re-confirm after edits).
- [ ] **Mid-move manual stop** → layer-3 suspend (Phase 1 Step 7, run as a standing regression on a watched virtual cover).
- [ ] **Wall-switch move** (contextless, no live marker) → `manual_check` layer 2 suspends. Simulate: change a virtual cover's state with no `moving_*` marker present and no `user_id`; expect suspension.
- [ ] **Physical weather-blocked close, cleanly staged** (the one weather case left unproven): configure a `time`-method instance that genuinely _wants closed_ (close_time in the past, open_time in the future) so the heartbeat agrees, `weather_entity: weather.weather_at_8001`. With `weather_events:[sunny]` (current) the cover must **stay open**; flip to `[rainy]` and it must **close**. Avoids the daytime sun-heartbeat fight documented in memory.
- [ ] **Restart mid-transition self-heal**: set `_commanded` stale vs desired, restart HA, confirm catch-up on the `homeassistant: start` heartbeat; and first-run `-1` sentinel drives covers to phase.
- [ ] **Brightness stabilizer edges**: `<id>_lux_above_since` / `_below_since` written only on threshold crossings; `schedule_wants_*` respects `stabilizer_seconds`.
- [ ] Native-bool parsing of `schedule_wants_open/closed` / `stabilizer_needs_update` in raw `{% if %}` (the `result_as_boolean` gotcha) — confirm they behave as real booleans at runtime.

---

## Self-Review notes

- **Spec coverage:** Phase 1 fully implements the false-suspension fix from the memory spec (record + guard). Phase 2 is intentionally a design-completion phase, not code — flagged as needing its own plan (open decisions listed). Phase 3 carries every deferred checklist item from `test-env-plan.md`, plus the clean weather-close staging.
- **No placeholders in Phase 1:** all edits show exact YAML; the guard change shows the exact before/after anchor lines.
- **Type consistency:** `commanded_<entity>.instance_id` (str) written in Step 3 is exactly what Step 4's guard reads; `instance_id` and `started_ts` are pre-existing script vars.
- **Env caveat:** the test env is durable at `C:\Users\Pascal\smarli-ha-test` (moved out of the session scratchpad). If the container is gone, `docker compose up -d` from that dir recreates it; the long-lived token in `.token` survives restarts.
