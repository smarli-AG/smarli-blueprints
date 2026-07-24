# Cover Constraint Resolver (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace "every cover automation commands covers directly" with "contributors publish intent, one central resolver commands", so competing automations arbitrate correctly instead of fighting.

**Architecture:** Contributors write `shared.<automation_id>::intent` (targets and/or bounds) into the central tracker and call `script.smarli_cover_resolve`. The resolver — single-flight (`mode: queued`) — computes one position per cover (`clamp(newest_target, bounds)`) and fires the existing `script.smarli_cover_move` for covers whose resolved value changed. All tracker keys move to a `<owner>::<name>` grammar so one family-agnostic GC script in `smarli_core.yaml` can collect keys whose owning automation or entity no longer exists.

**Design spec:** `docs/superpowers/specs/2026-07-24-cover-constraint-resolver-design.md`. Read §2–§9 before starting. This plan implements it; where they disagree, the spec is right and the plan is a bug.

**Tech Stack:** Home Assistant (YAML packages + blueprints, Jinja templates), Docker Desktop (WSL2), PowerShell driving the HA REST API.

## Global Constraints

- HA floor is **2024.10.0**; every change must config-check clean on **both** `2024.10` and `2025.4`.
- Cover targets are **always numeric positions 0–100**, never `'open'`/`'closed'`.
- `bitwise_and` is a **filter**: `x | bitwise_and(4)`, never `bitwise_and(x, 4)`.
- Tracker writes are atomic **per key**. A dict/list value is safe only if **one** writer replaces it wholesale.
- Template **conditions** must render a clean boolean — a dict/non-bool reads as _false_ via `result_as_boolean`.
- There is no `zip` filter in HA Jinja; build dicts with `dict(d.items() | list + [(k, v)])`.
- Script `fields:` defaults are **not** reliably injected as variables — always write `x | default(y)` in templates.
- A package fix rolls out fleet-wide; a blueprint change needs a re-import. Prefer package changes.
- Any German user-facing copy: Swiss-German Du-Form, capital "Du/Dein/Dir".
- **Every commit must leave the test env working.** Where a task would break a caller, keep a compatibility alias and remove it in the task that updates the caller (Task 3 → Task 5).

## Orientation — the test env already exists

Do **not** rebuild it. Location: `C:\Users\Pascal\smarli-ha-test\` (`docker-compose.yml`, `config/`, `ha.ps1`, `.token`). Container `smarli-ha-test`, port 8123.

```powershell
# every session, before anything else
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"     # HA-Call, HA-State, HA-Tracker, HA-Shared, HA-Move, HA-Token
```

```powershell
# deploy repo -> test config (packages need a full restart; automations.yaml alone can be reloaded)
$D="C:\Users\Pascal\smarli-ha-test\config"
copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_core.yaml  "$D\packages\"
copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_cover.yaml "$D\packages\"
copy C:\Users\Pascal\GIT\smarli-blueprints\automation\coversDayNight.yaml "$D\config\blueprints\automation\smarli\coversDayNight.yaml"
docker restart smarli-ha-test
```

```powershell
# config check both floors (no run needed)
$cfg = "C:\Users\Pascal\smarli-ha-test\config"
foreach ($v in @("2024.10","2025.4")) {
  docker run --rm -v "${cfg}:/config" "ghcr.io/home-assistant/home-assistant:$v" python -m homeassistant --script check_config -c /config
}
```

Env facts that shape the tests:

- **Virtual covers** `cover.vfast` (6 s travel) and `cover.vslow` (16 s) do report `opening`/`closing` and are **contextless** — use these. Demo covers never report `opening`/`closing` and cannot exercise the settle loop.
- **Any REST/WS service call carries `user_id`** → looks manual → self-suspends. Drive automated moves through an automation armed via a tracker key and fired by a `time_pattern` trigger (the existing `test_mover` pattern), never by calling the service directly.
- PowerShell 5.1: no `if(){}` as an expression; precompute into variables and use `-join`.

---

## Task 1: Verify the six design assumptions

These are assumptions, not knowledge. A failure changes the **design**, not just the code, so nothing else starts until this task is done and its findings are written down.

**Files:**

- Create: `C:\Users\Pascal\smarli-ha-test\verify-assumptions.ps1`
- Modify: `docs/superpowers/specs/2026-07-24-cover-constraint-resolver-design.md` (§13 — record each result)

**Interfaces:**

- Produces: a decision for each of V1–V6 recorded in §13 of the spec. Later tasks read V1 (owner-liveness is viable), V2 (`wait_template` ordering is viable), V6 (coalescing is viable).

- [ ] **Step 1: Write the verification script**

Create `C:\Users\Pascal\smarli-ha-test\verify-assumptions.ps1`:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"

function HA-Template { param($tpl)
  $body = @{ template = $tpl } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri "$HA_BASE/api/template" -Method Post -Headers (HA-Headers) -Body $body -ContentType "application/json"
}

"=== V1: automation attributes.id ==="
HA-Template "{{ states.automation | map(attribute='attributes.id') | list }}"
"(expect a list of automation ids, not a list of Undefined/empty)"

"=== V1b: same check on 2024.10 ==="
"Run the config-check container interactively? No — instead pin the running container to 2024.10 once:"
"  `$env:HA_VERSION='2024.10'; docker compose up -d` in C:\Users\Pascal\smarli-ha-test, re-run this block, then restore."

"=== V5: tracker attribute size right now ==="
$t = HA-State 'sensor.smarli_automation_tracker'
"tracker data bytes: $((($t.attributes.data | ConvertTo-Json -Depth 10 -Compress)).Length)"

"=== V6: script 'current' attribute exposure ==="
(HA-State 'script.smarli_cover_move') | Select-Object -ExpandProperty attributes
"(expect a 'current' key; note whether it exists at all)"
```

- [ ] **Step 2: Run V1 on both floors**

Run: `powershell -File C:\Users\Pascal\smarli-ha-test\verify-assumptions.ps1`, then repeat with the container pinned to `2024.10`.

Expected: a JSON list of automation ids on both. **If 2024.10 returns empties**, find the HA release that added the attribute (`git log` on `homeassistant/components/automation/__init__.py` upstream, or the release notes) and record it — the user wants the number so they can decide whether to raise `min_version`. Fall back to `until`-stamped intents (spec §3) and note that Task 2's GC must use it.

- [ ] **Step 3: Verify V2 — template-sensor trigger ordering under burst**

Fire 20 tracker writes back-to-back and confirm the sensor's `data` ends up containing all 20 keys in the order written (no lost or reordered writes):

```powershell
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
function HA-Event { param($t,$d=@{}) Invoke-RestMethod -Uri "$HA_BASE/api/events/$t" -Method Post -Headers (HA-Headers) -Body ($d|ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null }
1..20 | ForEach-Object { HA-Event 'smarli_tracker_set' @{ namespace='v2'; key="k$_"; value=$_ } }
Start-Sleep 3
$v2 = (HA-Tracker).v2
"keys: $((($v2.PSObject.Properties.Name) | Measure-Object).Count) (expect 20)"
1..20 | ForEach-Object { HA-Event 'smarli_tracker_remove' @{ namespace='v2'; key="k$_" } }
```

Expected: 20 keys. Fewer means writes are being dropped under burst → the `wait_template` ordering trick is unsound; switch to the spec's fallback (contributors pass intent through the resolve call, the resolver performs the tracker write).

- [ ] **Step 4: Verify V3 — `automation_reloaded` fires after entities exist**

Add a temporary automation to `C:\Users\Pascal\smarli-ha-test\config\automations.yaml`:

```yaml
- id: v3_probe
  alias: "V3 probe"
  triggers:
    - trigger: event
      event_type: automation_reloaded
  actions:
    - event: smarli_tracker_set
      event_data:
        namespace: v3
        key: "count_at_reload"
        value: "{{ states.automation | list | count }}"
```

Run `HA-Call automation reload @{}`, wait 3 s, then `(HA-Tracker).v3`. Expected: the count equals the real number of automations. A count of 0 or a clearly truncated number means GC must wait longer than 10 s or use a different trigger.

- [ ] **Step 5: Verify V4 — recorder exclusion vs. restore**

Add to `C:\Users\Pascal\smarli-ha-test\config\configuration.yaml`:

```yaml
recorder:
  exclude:
    entities:
      - sensor.smarli_automation_tracker
```

Write a key, `docker restart smarli-ha-test`, wait for `/api/onboarding` to answer, then read the tracker. Expected: `data` still contains the key (trigger-based template sensors restore via `.storage/core.restore_state`, not the recorder). If it is empty, remove the exclusion and rely on GC alone to bound growth.

- [ ] **Step 6: Record every result in the spec**

Replace the "If it fails" column entries in §13 of the spec with the observed outcome, e.g. `V1 ✅ 2024.10 + 2025.4 both expose attributes.id`. Any failure gets its consequence spelled out as a sentence, because later tasks reference it.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-07-24-cover-constraint-resolver-design.md
git commit -m "docs(cover): record Phase 2 design assumption verification (V1-V6)"
```

---

## Task 2: Tracker garbage collection

**Files:**

- Modify: `packages/smarli_core.yaml` (append a `script:` block and an `automation:` block)
- Test: `C:\Users\Pascal\smarli-ha-test\test-gc.ps1`

**Interfaces:**

- Produces: `script.smarli_tracker_gc` (no fields) and `automation.smarli_tracker_gc`. Removes any key containing `::` whose owner is neither `global`, nor a live automation id, nor a live entity.
- Consumes: nothing. Old-style keys (no `::`) are ignored, so this is safe to land before the rename.

- [ ] **Step 1: Write the failing test**

Create `C:\Users\Pascal\smarli-ha-test\test-gc.ps1`:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
function HA-Event { param($t,$d=@{}) Invoke-RestMethod -Uri "$HA_BASE/api/events/$t" -Method Post -Headers (HA-Headers) -Body ($d|ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null }

# 1 orphan (no such automation), 1 live entity key, 1 global key, 1 live automation key
$liveId = (HA-State 'automation.v3_probe').attributes.id
if (-not $liveId) { $liveId = ((Invoke-RestMethod -Uri "$HA_BASE/api/states" -Headers (HA-Headers)) | Where-Object { $_.entity_id -like 'automation.*' } | Select-Object -First 1).attributes.id }
HA-Event 'smarli_tracker_set' @{ namespace='gc'; key='9999999999999::intent';        value=@{ dead=$true } }
HA-Event 'smarli_tracker_set' @{ namespace='gc'; key='cover.vfast::resolved';        value=42 }
HA-Event 'smarli_tracker_set' @{ namespace='gc'; key='global::whatever';             value=1 }
HA-Event 'smarli_tracker_set' @{ namespace='gc'; key="${liveId}::intent";            value=@{ alive=$true } }
HA-Event 'smarli_tracker_set' @{ namespace='gc'; key='cover.does_not_exist::resolved'; value=7 }
Start-Sleep 2

HA-Call script turn_on @{ entity_id='script.smarli_tracker_gc' } | Out-Null
Start-Sleep 5

$gc = (HA-Tracker).gc
$names = @($gc.PSObject.Properties.Name)
$dead    = $names -contains '9999999999999::intent'
$deadEnt = $names -contains 'cover.does_not_exist::resolved'
$liveEnt = $names -contains 'cover.vfast::resolved'
$glob    = $names -contains 'global::whatever'
$liveAut = $names -contains "${liveId}::intent"
"remaining: $($names -join ', ')"
if (-not $dead -and -not $deadEnt -and $liveEnt -and $glob -and $liveAut) { "RESULT: PASS" } else { "RESULT: FAIL" }
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `powershell -File C:\Users\Pascal\smarli-ha-test\test-gc.ps1`
Expected: FAIL — `script.smarli_tracker_gc` does not exist yet, so nothing is removed (the call errors and all five keys remain).

- [ ] **Step 3: Add the GC script to `packages/smarli_core.yaml`**

Append at the end of the file (the `template:` block stays untouched):

```yaml
# ---------------------------------------------------------------------------
# Tracker garbage collection.
# ---------------------------------------------------------------------------
# Every instance-scoped or entity-scoped tracker key is named `<owner>::<name>`.
# `::` cannot appear in an entity_id and is not generated in automation ids, so
# the owner can always be recovered from the key without knowing which blueprint
# family wrote it. A key whose owner no longer exists is unreachable garbage:
# automation ids are regenerated on every create, so delete-and-recreate would
# otherwise leak a key per cycle, and every tracker write snapshots the whole
# `data` attribute into the recorder.
#
# Owner forms:  <automation id> | <entity_id> | the literal `global`
script:
  smarli_tracker_gc:
    alias: "smarli. Tracker Garbage Collection"
    description: >-
      Removes tracker keys whose owner (the part before `::`) is neither a live
      automation, nor a live entity, nor the reserved literal `global`. Keys
      without `::` are left alone.
    mode: single
    max_exceeded: silent
    sequence:
      - alias: Never sweep while the automation registry looks empty (mid-reload)
        condition: template
        value_template: "{{ states.automation | list | count > 0 }}"
      - variables:
          data: "{{ state_attr('sensor.smarli_automation_tracker', 'data') or {} }}"
          live_ids: "{{ states.automation | map(attribute='attributes.id') | select('string') | list }}"
          orphans: >
            {% set ns = namespace(dead=[]) %}
            {% for bucket_name, bucket in data.items() %}
              {% for key in bucket.keys() %}
                {% if '::' in key %}
                  {% set owner = key.split('::')[0] %}
                  {% set is_entity = owner is match('^[a-z_][a-z0-9_]*\.[a-z0-9_]+$') %}
                  {% set alive = owner == 'global'
                                 or owner in live_ids
                                 or (is_entity and states[owner] is not none) %}
                  {% if not alive %}
                    {% set ns.dead = ns.dead + [[bucket_name, key]] %}
                  {% endif %}
                {% endif %}
              {% endfor %}
            {% endfor %}
            {{ ns.dead }}
      - alias: Remove every orphaned key
        repeat:
          for_each: "{{ orphans }}"
          sequence:
            - event: smarli_tracker_remove
              event_data:
                namespace: "{{ repeat.item[0] }}"
                key: "{{ repeat.item[1] }}"

automation:
  - id: smarli_tracker_gc
    alias: "smarli. Tracker Garbage Collection"
    description: >-
      Sweeps orphaned tracker keys. Deleting an automation fires
      `automation_reloaded`, so this runs exactly when ownership can have
      changed and costs nothing in steady state.
    mode: single
    max_exceeded: silent
    triggers:
      - trigger: event
        event_type: automation_reloaded
      - trigger: homeassistant
        event: start
    actions:
      - alias: Let the reload finish before deciding who is alive
        delay:
          seconds: 10
      - action: script.smarli_tracker_gc
```

If V1 failed in Task 1, additionally treat an intent whose `until` has passed as garbage — add `or (bucket[key].get('until', 0) | float(0) > 0 and bucket[key].get('until') | float(0) < as_timestamp(now()))` to the `not alive` condition.

- [ ] **Step 4: Config-check both floors**

```powershell
$cfg = "C:\Users\Pascal\smarli-ha-test\config"
copy C:\Users\Pascal\GIT\smarli-blueprints\packages\smarli_core.yaml "$cfg\packages\"
foreach ($v in @("2024.10","2025.4")) { docker run --rm -v "${cfg}:/config" "ghcr.io/home-assistant/home-assistant:$v" python -m homeassistant --script check_config -c /config }
```

Expected: `Successful config`, no ERROR lines, on both.

- [ ] **Step 5: Restart and run the test — expect PASS**

Run: `docker restart smarli-ha-test`, wait for `/api/onboarding` to return 200, then `powershell -File C:\Users\Pascal\smarli-ha-test\test-gc.ps1`
Expected: `RESULT: PASS` — the two orphans gone, the live-entity, `global` and live-automation keys still present.

- [ ] **Step 6: Verify the reload path (A8)**

Add a throwaway automation to `automations.yaml` with `id: gc_victim`, reload, write `gc_victim::intent` into `shared`, then delete the automation from the file and reload again. After ~15 s the key must be gone while `cover.vfast::resolved` survives.

```powershell
HA-Event 'smarli_tracker_set' @{ namespace='shared'; key='gc_victim::intent'; value=@{ targets=@{} } }
# ...remove the automation block from automations.yaml...
HA-Call automation reload @{}
Start-Sleep 15
@((HA-Shared).PSObject.Properties.Name) -contains 'gc_victim::intent'   # expect False
```

- [ ] **Step 7: Clean up the probe and commit**

Remove the `v3_probe` automation and the `gc` namespace keys from the test env, then:

```bash
git add packages/smarli_core.yaml
git commit -m "feat(smarli_core): family-agnostic tracker garbage collection

Adds script.smarli_tracker_gc plus a reload/start-triggered automation.
Every instance- or entity-scoped tracker key is named <owner>::<name>, so
the owner can be recovered without per-family knowledge; keys whose owner
is neither a live automation, a live entity, nor `global` are removed.
Fixes unbounded growth across automation delete/recreate cycles."
```

---

## Task 3: Per-cover moving markers, central suspension, resolved-aware audit

Rewrites the two cover scripts onto the new key grammar and adds the shared suspend helper. The blueprint still calls `smarli_cover_move` with `instance_id`, so the mover keeps accepting it as an alias for `run` until Task 5.

**Files:**

- Modify: `packages/smarli_cover.yaml` (header comment, `smarli_cover_manual_check`, `smarli_cover_move`; add `smarli_cover_suspend`)
- Test: `C:\Users\Pascal\smarli-ha-test\test-markers.ps1`

**Interfaces:**

- Produces:
  - `script.smarli_cover_suspend(entity_id, fallback_duration)` — writes `shared.<entity_id>::suspension = now + max(suspension_duration of active intents naming this cover, else fallback_duration)`; writes nothing when that maximum is 0.
  - `script.smarli_cover_move(run | instance_id, targets, binary_threshold?, settle_timeout?, position_tolerance?)` — writes `shared.<cover>::moving_<run> = {target, until}` per cover, commands them, audits, removes its own marker keys.
  - Key renames: `suspension_<entity>` → `<entity>::suspension`; `moving_<instance>` → `<cover>::moving_<run>`; `commanded_<entity>` **deleted**.
- Consumes: `shared.<cover>::resolved` if present (written by the resolver in Task 4); absent is normal until then.

- [ ] **Step 1: Write the failing test**

Create `C:\Users\Pascal\smarli-ha-test\test-markers.ps1`. It drives an automated move through the existing `test_mover` (untainted context) and asserts the new key shapes:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
function HA-Event { param($t,$d=@{}) Invoke-RestMethod -Uri "$HA_BASE/api/events/$t" -Method Post -Headers (HA-Headers) -Body ($d|ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null }
function SharedNames { @((HA-Shared).PSObject.Properties.Name) }

# reset
HA-Call cover set_cover_position @{ entity_id='cover.vfast'; position=100 } | Out-Null
HA-Call cover set_cover_position @{ entity_id='cover.vslow'; position=100 } | Out-Null
Start-Sleep 18
foreach ($k in (SharedNames | Where-Object { $_ -like '*::suspension' -or $_ -like 'suspension_*' })) {
  HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key=$k }
}
Start-Sleep 2

# arm an untainted move of BOTH covers, then sample markers while they travel
HA-Event 'smarli_tracker_set' @{ namespace='test'; key='fire'; value=@{ targets=@{ 'cover.vfast'=0; 'cover.vslow'=0 } } }
Start-Sleep 8
$mid = SharedNames
$perCover = @($mid | Where-Object { $_ -like 'cover.*::moving_*' }).Count
$oldStyle = @($mid | Where-Object { $_ -like 'moving_*' }).Count

Start-Sleep 20
$end = SharedNames
$leftovers = @($end | Where-Object { $_ -like '*::moving_*' }).Count
$susp      = @($end | Where-Object { $_ -like '*::suspension' }).Count
$commanded = @($end | Where-Object { $_ -like 'commanded_*' }).Count

"mid-move per-cover markers: $perCover (expect 2)"
"mid-move old-style markers: $oldStyle (expect 0)"
"after: leftover markers: $leftovers (expect 0), suspensions: $susp (expect 0), commanded_* keys: $commanded (expect 0)"
if ($perCover -eq 2 -and $oldStyle -eq 0 -and $leftovers -eq 0 -and $susp -eq 0 -and $commanded -eq 0) { "RESULT: PASS" } else { "RESULT: FAIL" }
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `powershell -File C:\Users\Pascal\smarli-ha-test\test-markers.ps1`
Expected: FAIL — current code writes one `moving_<instance_id>` marker and a `commanded_<entity>` key per cover.

- [ ] **Step 3: Update the package header comment**

In `packages/smarli_cover.yaml`, replace the key inventory in the header comment (the block listing `suspension_<cover_entity_id>`, `moving_<instance_id>`, `commanded_<cover_entity_id>`) with:

```yaml
# Uses the tracker's `shared` namespace. Every key is `<owner>::<name>`, so the
# core GC can collect keys whose owner no longer exists (see smarli_core.yaml):
#   - <cover>::suspension      unix ts until which the cover is suspended
#   - <cover>::moving_<run>    {target, until} while mover run <run> drives it
#   - <cover>::resolved        last position the resolver decided for this cover
#   - <automation_id>::intent  a contributor's declared targets/bounds
```

- [ ] **Step 4: Add `script.smarli_cover_suspend`**

Insert as the **first** script in the `script:` block of `packages/smarli_cover.yaml`:

```yaml
smarli_cover_suspend:
  alias: "smarli. Cover Suspend"
  description: >-
    Suspends one cover. The duration is a cover-level fact, not an
    automation-level one: several automations may watch the same cover and
    each fires its own manual-detection path on the same wall-switch press.
    So the duration is the MAXIMUM `suspension_duration` across active
    intents naming this cover; an automation that opted out of suspension
    contributes 0. Falls back to the caller's value while no intent exists
    yet (e.g. a manual move in the first minute after setup).
  mode: parallel
  max: 50
  fields:
    entity_id:
      name: Cover Entity
      description: The cover to suspend.
      required: true
      selector:
        entity:
          filter:
            - domain: cover
    fallback_duration:
      name: Fallback Duration
      description: Seconds to use when no active intent names this cover.
      required: false
      default: 0
      selector:
        number:
          min: 0
          max: 86400
          unit_of_measurement: s
  sequence:
    - variables:
        now_ts: "{{ as_timestamp(now()) }}"
        shared: "{{ (state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('shared', {}) }}"
        live_ids: >
          {{ states.automation | selectattr('state', 'eq', 'on')
             | map(attribute='attributes.id') | select('string') | list }}
        duration: >
          {% set ns = namespace(max=-1) %}
          {% for key, value in shared.items() if key.endswith('::intent') %}
            {% if key.split('::')[0] in live_ids
                  and (entity_id in value.get('targets', {}) or entity_id in value.get('bounds', {})) %}
              {% set d = value.get('suspension_duration', 0) | float(0) %}
              {% if d > ns.max %}{% set ns.max = d %}{% endif %}
            {% endif %}
          {% endfor %}
          {{ ns.max if ns.max >= 0 else (fallback_duration | default(0) | float(0)) }}
    - alias: Skip when every contributor opted out of suspension
      condition: template
      value_template: "{{ duration | float(0) > 0 }}"
    - alias: Suspend this cover
      event: smarli_tracker_set
      event_data:
        namespace: shared
        key: "{{ entity_id }}::suspension"
        value: "{{ now_ts | float(0) + duration | float(0) }}"
```

- [ ] **Step 5: Rewire `smarli_cover_manual_check`**

Two edits inside its `sequence:`. Replace the `driven_by_automation` variable:

```yaml
# True if any smarli. mover is currently driving THIS cover (an
# unexpired per-cover marker). One key lookup per cover instead of a
# scan of every shared key; during a supersede two marker keys
# coexist, which is correct — two movers really are driving it.
driven_by_automation: >
  {% set ns = namespace(found=false) %}
  {% for key, marker in shared.items() if key.startswith(entity_id ~ '::moving_') %}
    {% if (marker.get('until', 0) | float(0)) > now_ts | float(0) %}
      {% set ns.found = true %}
    {% endif %}
  {% endfor %}
  {{ ns.found }}
```

and replace the final `Suspend this cover` step with a call to the helper:

```yaml
- alias: Suspend this cover (duration resolved centrally)
  action: script.smarli_cover_suspend
  data:
    entity_id: "{{ entity_id }}"
    fallback_duration: "{{ duration_seconds | float(0) }}"
```

`duration_seconds` already exists in that script's `variables:` block; leave it.

- [ ] **Step 6: Rewrite `smarli_cover_move`**

Replace the whole `smarli_cover_move:` entry (fields **and** sequence) with:

```yaml
smarli_cover_move:
  alias: "smarli. Cover Move"
  description: >-
    Moves covers under the smarli. moving contract. Filters out suspended
    covers, announces each cover with a per-cover marker, commands them,
    waits until they settle, audits final positions (mid-move manual
    intervention suspends that cover — layer 3), and removes its markers.
    Targets are numeric positions 0-100; covers without position support fall
    back to open/close at the threshold. Normally called only by
    script.smarli_cover_resolve.
  mode: parallel
  max: 50
  fields:
    run:
      name: Run Token
      description: Unique token for this move run (the resolver passes its start timestamp).
      required: false
      selector:
        text:
    instance_id:
      name: Instance ID (deprecated)
      description: Legacy alias for `run`, kept until every caller passes `run`.
      required: false
      selector:
        text:
    targets:
      name: Targets
      description: "Dict of cover entity_id -> target position (number 0-100; 100 = open, 0 = closed)."
      required: true
      selector:
        object:
    binary_threshold:
      name: Binary Fallback Threshold
      description: For covers without position support, target >= this opens, below closes.
      required: false
      default: 50
      selector:
        number:
          min: 1
          max: 99
    settle_timeout:
      name: Settle Timeout
      description: >-
        Hard cap (seconds) for how long to keep tracking a move before giving
        up on a cover that never settles — NOT the expected move duration. Err
        large: too small is actively harmful, because once it fires while a
        cover is still moving, its marker expires and its own movement is
        misread as manual intervention.
      required: false
      default: 180
      selector:
        number:
          min: 10
          max: 600
          unit_of_measurement: s
    position_tolerance:
      name: Position Tolerance
      description: Allowed deviation between target and final position.
      required: false
      default: 5
      selector:
        number:
          min: 0
          max: 20
  sequence:
    - variables:
        run_token: "{{ run | default(instance_id) | default('run', true) }}"
        started_ts: "{{ as_timestamp(now()) }}"
        settle_timeout_s: "{{ settle_timeout | default(180) | float(180) }}"
        tolerance: "{{ position_tolerance | default(5) | float(5) }}"
        threshold: "{{ binary_threshold | default(50) | float(50) }}"
        marker_until: "{{ as_timestamp(now()) | float(0) + (settle_timeout | default(180) | float(180)) + 15 }}"
        shared: "{{ (state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('shared', {}) }}"
        # Drop covers that are currently suspended by a manual override.
        active_targets: >
          {% set ns = namespace(active={}) %}
          {% for cover, target in (targets | default({})).items() %}
            {% if shared.get(cover ~ '::suspension', 0) | float(0) <= as_timestamp(now()) %}
              {% set ns.active = dict(ns.active.items() | list + [(cover, target | int)]) %}
            {% endif %}
          {% endfor %}
          {{ ns.active }}
    - alias: Abort if every requested cover is suspended
      condition: template
      value_template: "{{ active_targets | count > 0 }}"
    - alias: Announce and command each cover
      repeat:
        for_each: "{{ active_targets | dictsort }}"
        sequence:
          - variables:
              cover: "{{ repeat.item[0] }}"
              target_position: "{{ repeat.item[1] | int }}"
              supports_position: "{{ state_attr(repeat.item[0], 'supported_features') | int(0) | bitwise_and(4) > 0 }}"
          - alias:
              Per-cover moving marker (layer 2). The run token is in the KEY, so
              this run is the only writer and there is nothing to race.
            event: smarli_tracker_set
            event_data:
              namespace: shared
              key: "{{ cover }}::moving_{{ run_token }}"
              value:
                target: "{{ target_position }}"
                until: "{{ marker_until }}"
          - choose:
              - alias: Cover supports positioning — set the exact position
                conditions: "{{ supports_position }}"
                sequence:
                  - action: cover.set_cover_position
                    target:
                      entity_id: "{{ cover }}"
                    data:
                      position: "{{ target_position }}"
              - alias: Binary cover, target at/above threshold — open fully
                conditions: "{{ target_position >= threshold }}"
                sequence:
                  - action: cover.open_cover
                    target:
                      entity_id: "{{ cover }}"
            default:
              - alias: Binary cover, target below threshold — close fully
                action: cover.close_cover
                target:
                  entity_id: "{{ cover }}"
    - alias: Give covers a moment to start moving
      delay:
        seconds: 3
    # ---------------------------------------------------------------------
    # Per-cover settle loop (incremental layer-3 audit). Each pass, for every
    # cover whose marker for THIS run still exists:
    #   - still opening/closing              -> leave it
    #   - a newer run now drives it          -> drop it, do NOT suspend
    #   - stopped at my target or at the
    #     currently resolved position        -> drop it (finished cleanly)
    #   - stopped anywhere else              -> drop it AND suspend it
    # Comparing against <cover>::resolved (system intent) rather than against
    # a "who commanded last" record is what makes a superseded move safe
    # without a race: it does not matter who wrote what first, only where the
    # system currently wants the cover.
    # ---------------------------------------------------------------------
    - alias: Release covers from the marker as they settle
      repeat:
        while:
          - condition: template
            value_template: >
              {% set shared = (state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('shared', {}) %}
              {% set mine = shared.keys() | select('search', '::moving_' ~ run_token ~ '$') | list %}
              {{ mine | count > 0
                 and as_timestamp(now()) < started_ts | float(0) + settle_timeout_s | float(0) }}
        sequence:
          - delay:
              seconds: 2
          - variables:
              shared_now: "{{ (state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('shared', {}) }}"
              pending: >
                {% set ns = namespace(d={}) %}
                {% for cover, target in active_targets.items() %}
                  {% if (cover ~ '::moving_' ~ run_token) in shared_now %}
                    {% set ns.d = dict(ns.d.items() | list + [(cover, target)]) %}
                  {% endif %}
                {% endfor %}
                {{ ns.d }}
              # Covers a newer run has taken over — release without suspending.
              superseded: >
                {% set ns = namespace(l=[]) %}
                {% for cover in pending.keys() %}
                  {% for key in shared_now.keys() %}
                    {% if key.startswith(cover ~ '::moving_')
                          and key != (cover ~ '::moving_' ~ run_token)
                          and (key.split('::moving_')[1] | float(0)) > (run_token | float(0)) %}
                      {% if cover not in ns.l %}{% set ns.l = ns.l + [cover] %}{% endif %}
                    {% endif %}
                  {% endfor %}
                {% endfor %}
                {{ ns.l }}
              # Covers still physically moving — keep their markers.
              still_moving: >
                {% set ns = namespace(l=[]) %}
                {% for cover in pending.keys() %}
                  {% if is_state(cover, 'opening') or is_state(cover, 'closing') %}
                    {% set ns.l = ns.l + [cover] %}
                  {% endif %}
                {% endfor %}
                {{ ns.l }}
              # Covers that stopped somewhere we did not ask for and the
              # system does not currently want — manual intervention.
              intervened: >
                {% set ns = namespace(bad=[]) %}
                {% for cover, target in pending.items() %}
                  {% if cover not in superseded and cover not in still_moving
                        and states(cover) not in ['unavailable', 'unknown'] %}
                    {% set resolved = shared_now.get(cover ~ '::resolved') %}
                    {% if state_attr(cover, 'supported_features') | int(0) | bitwise_and(4) > 0 %}
                      {% set pos = state_attr(cover, 'current_position') %}
                      {% set hits_target = pos is not none and (pos | float(0) - target | float(0)) | abs <= tolerance %}
                      {% set hits_resolved = pos is not none and resolved is not none
                           and (pos | float(0) - resolved | float(0)) | abs <= tolerance %}
                      {% if not hits_target and not hits_resolved %}
                        {% set ns.bad = ns.bad + [cover] %}
                      {% endif %}
                    {% else %}
                      {% set want = target if resolved is none else resolved %}
                      {% set expected = 'open' if want | float(0) >= threshold else 'closed' %}
                      {% if not is_state(cover, expected) %}
                        {% set ns.bad = ns.bad + [cover] %}
                      {% endif %}
                    {% endif %}
                  {% endif %}
                {% endfor %}
                {{ ns.bad }}
          - alias: Suspend covers that stopped short of their target
            repeat:
              for_each: "{{ intervened }}"
              sequence:
                - action: script.smarli_cover_suspend
                  data:
                    entity_id: "{{ repeat.item }}"
                    fallback_duration: 0
          - alias: Release every cover that is no longer moving for this run
            repeat:
              for_each: "{{ pending.keys() | reject('in', still_moving) | list }}"
              sequence:
                - event: smarli_tracker_remove
                  event_data:
                    namespace: shared
                    key: "{{ repeat.item }}::moving_{{ run_token }}"
```

Note the deleted step: the old `Record last-commander for this cover` block writing `commanded_<cover>` is gone entirely — the audit above replaces it.

- [ ] **Step 7: Config-check both floors**

Same command as Task 2 Step 4, copying `smarli_cover.yaml`.
Expected: `Successful config` on both.

- [ ] **Step 8: Restart and run the marker test — expect PASS**

Run: `docker restart smarli-ha-test`, then `powershell -File C:\Users\Pascal\smarli-ha-test\test-markers.ps1`
Expected: `RESULT: PASS` — two per-cover markers mid-move, no old-style keys, everything cleaned up, no suspensions, no `commanded_*`.

- [ ] **Step 9: Regression R1 — a genuine manual mid-move stop still suspends**

```powershell
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
HA-Event 'smarli_tracker_set' @{ namespace='test'; key='fire'; value=@{ targets=@{ 'cover.vslow'=0 } } }
Start-Sleep 8                                   # mid-travel
HA-Call cover stop_cover @{ entity_id='cover.vslow' } | Out-Null
Start-Sleep 8
@((HA-Shared).PSObject.Properties.Name) -contains 'cover.vslow::suspension'   # expect True
```

Expected: `True`. The cover stopped at neither the target nor any resolved value → suspended.

- [ ] **Step 10: Regression R2 — contextless wall-switch move with no marker suspends**

```powershell
# no marker present: change the cover's state via the virtual integration and
# confirm manual_check suspends it (cover.vfast must be watched by an instance)
HA-Call cover set_cover_position @{ entity_id='cover.vfast'; position=35 } | Out-Null
Start-Sleep 8
@((HA-Shared).PSObject.Properties.Name) -contains 'cover.vfast::suspension'   # expect True
```

Expected: `True`.

- [ ] **Step 11: A11 — covers start simultaneously**

Capture the `opening`/`closing` transition timestamps of both virtual covers during one batch move and assert the spread:

```powershell
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
foreach ($k in @('cover.vfast::suspension','cover.vslow::suspension')) { HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key=$k } }
HA-Call cover set_cover_position @{ entity_id='cover.vfast'; position=100 } | Out-Null
HA-Call cover set_cover_position @{ entity_id='cover.vslow'; position=100 } | Out-Null
Start-Sleep 20
foreach ($k in @('cover.vfast::suspension','cover.vslow::suspension')) { HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key=$k } }
HA-Event 'smarli_tracker_set' @{ namespace='test'; key='fire'; value=@{ targets=@{ 'cover.vfast'=0; 'cover.vslow'=0 } } }
Start-Sleep 7
$a = [datetime](HA-State 'cover.vfast').last_changed
$b = [datetime](HA-State 'cover.vslow').last_changed
$spread = [math]::Abs(($a - $b).TotalMilliseconds)
"spread: $spread ms (expect < 500)"
```

Expected: spread well under 500 ms.

- [ ] **Step 12: Commit**

```bash
git add packages/smarli_cover.yaml
git commit -m "refactor(smarli_cover): per-cover markers, central suspension, resolved-aware audit

- moving_<instance_id> -> <cover>::moving_<run>: the run token is in the
  key, so each mover run is the only writer and a superseded run can no
  longer delete a live marker out from under the run that replaced it.
- suspension_<entity> -> <entity>::suspension, written by the new shared
  script.smarli_cover_suspend, which takes the MAX suspension_duration
  across active intents naming the cover (several automations watch the
  same cover and all fire on one wall-switch press).
- The layer-3 audit compares the final position against <cover>::resolved
  as well as its own target, so a superseded move is never mistaken for
  manual intervention. commanded_<entity> is deleted: it was a write-order
  proxy for the same question and could still lose the race."
```

---

## Task 4: The resolver

**Files:**

- Modify: `packages/smarli_cover.yaml` (add `smarli_cover_resolve`)
- Create: test stubs in `C:\Users\Pascal\smarli-ha-test\config\automations.yaml`
- Test: `C:\Users\Pascal\smarli-ha-test\test-resolver.ps1`

**Interfaces:**

- Produces: `script.smarli_cover_resolve(owner?, intent?)`. Reads every `shared.*::intent` whose owner automation exists and is `on`, resolves each named cover, writes `shared.<cover>::resolved` for changed covers, and fires `script.smarli_cover_move(run, targets)` for the changed-and-unsuspended subset.
- Consumes: `script.smarli_cover_move` from Task 3 (via `run`), `script.smarli_cover_suspend` indirectly.
- Intent value shape (single writer, wholesale replace):
  `{targets: {<cover>: <int 0-100>}, bounds: {<cover>: {max?: int, min?: int}}, priority: int, ts: float, suspension_duration: float, until?: float}`

- [ ] **Step 1: Add the test stubs**

Append to `C:\Users\Pascal\smarli-ha-test\config\automations.yaml`. Both stubs are armed via tracker keys and fired by a shared `time_pattern`, so (a) their moves are contextless like a real heartbeat, and (b) arming both between ticks makes them publish in the **same** tick — which is how A4 reproduces coincidence.

```yaml
- id: stub_day
  alias: "STUB Day Target"
  mode: queued
  triggers:
    - trigger: time_pattern
      seconds: "/5"
  conditions:
    - condition: template
      value_template: "{{ (state_attr('sensor.smarli_automation_tracker','data') or {}).get('stub', {}).get('day') is not none }}"
  actions:
    - variables:
        arm: "{{ (state_attr('sensor.smarli_automation_tracker','data') or {}).get('stub', {}).get('day') }}"
        payload: >
          {{ {'targets': arm.targets, 'bounds': {}, 'priority': 10,
              'ts': as_timestamp(now()), 'suspension_duration': 1800} }}
    - event: smarli_tracker_remove
      event_data: { namespace: stub, key: day }
    - event: smarli_tracker_set
      event_data:
        namespace: shared
        key: "stub_day::intent"
        value: "{{ payload }}"
    - action: script.smarli_cover_resolve
      data:
        owner: stub_day
        intent: "{{ payload }}"

- id: stub_shade
  alias: "STUB Shade Bound"
  mode: queued
  triggers:
    - trigger: time_pattern
      seconds: "/5"
  conditions:
    - condition: template
      value_template: "{{ (state_attr('sensor.smarli_automation_tracker','data') or {}).get('stub', {}).get('shade') is not none }}"
  actions:
    - variables:
        arm: "{{ (state_attr('sensor.smarli_automation_tracker','data') or {}).get('stub', {}).get('shade') }}"
        payload: >
          {{ {'targets': arm.get('targets', {}), 'bounds': arm.get('bounds', {}), 'priority': 50,
              'ts': as_timestamp(now()), 'suspension_duration': 1800} }}
    - event: smarli_tracker_remove
      event_data: { namespace: stub, key: shade }
    - event: smarli_tracker_set
      event_data:
        namespace: shared
        key: "stub_shade::intent"
        value: "{{ payload }}"
    - action: script.smarli_cover_resolve
      data:
        owner: stub_shade
        intent: "{{ payload }}"
```

Arming looks like this (bound), and shade's retraction is armed as `targets` with empty `bounds`:

```powershell
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ bounds=@{ 'cover.vfast'=@{ max=20 } } } }
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ targets=@{ 'cover.vfast'=100 } } }   # retract
```

- [ ] **Step 2: Write the failing test**

Create `C:\Users\Pascal\smarli-ha-test\test-resolver.ps1` covering A1–A3:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
function HA-Event { param($t,$d=@{}) Invoke-RestMethod -Uri "$HA_BASE/api/events/$t" -Method Post -Headers (HA-Headers) -Body ($d|ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null }
function Pos { (HA-State 'cover.vfast').attributes.current_position }
function Clear { foreach ($k in @('cover.vfast::suspension','cover.vfast::resolved','stub_day::intent','stub_shade::intent')) { HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key=$k } } }

Clear; Start-Sleep 2
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day'; value=@{ targets=@{ 'cover.vfast'=100 } } }
Start-Sleep 15
"A-pre  day only              -> $(Pos) (expect 100)"

HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ bounds=@{ 'cover.vfast'=@{ max=20 } } } }
Start-Sleep 15
$a1 = Pos; "A1  day 100 + bound <=20     -> $a1 (expect 20)"

HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day'; value=@{ targets=@{ 'cover.vfast'=0 } } }
Start-Sleep 15
$a2 = Pos; "A2  night 0 + bound <=20     -> $a2 (expect 0)"

HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day';   value=@{ targets=@{ 'cover.vfast'=100 } } }
Start-Sleep 15
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ bounds=@{} } }
Start-Sleep 15
$a3 = Pos; "A3  bound withdrawn          -> $a3 (expect 100)"

$susp = @((HA-Shared).PSObject.Properties.Name) -contains 'cover.vfast::suspension'
"suspension present: $susp (expect False)"
if ($a1 -le 25 -and $a2 -le 5 -and $a3 -ge 95 -and -not $susp) { "RESULT: PASS" } else { "RESULT: FAIL" }
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `powershell -File C:\Users\Pascal\smarli-ha-test\test-resolver.ps1`
Expected: FAIL — `script.smarli_cover_resolve` does not exist, so the stubs error and the cover never moves.

- [ ] **Step 4: Add `script.smarli_cover_resolve`**

Insert into the `script:` block of `packages/smarli_cover.yaml`, before `smarli_cover_move`:

```yaml
smarli_cover_resolve:
  alias: "smarli. Cover Resolve"
  description: >-
    The single mover for every smarli. cover automation. Reads all published
    intents, computes one position per cover (clamp(newest target, bounds)),
    records it, and commands the covers whose resolved position changed.
    Contributors publish intent and call this; they never command covers.

    `mode: queued` is load-bearing: a run writes several `<cover>::resolved`
    keys as a SEQUENCE of atomic single-key writes, so serialising runs is
    what makes the resolved set consistent.
  mode: queued
  max: 50
  max_exceeded: silent
  fields:
    owner:
      name: Owner
      description: The calling automation's id (this.attributes.id).
      required: false
      selector:
        text:
    intent:
      name: Fresh Intent
      description: >-
        The intent the caller just published. Overlaid on the tracker read so
        resolution never depends on the template sensor having re-rendered.
      required: false
      selector:
        object:
  sequence:
    - alias: Wait until my own write is visible — renders are ordered, so every earlier write is too
      if:
        - condition: template
          value_template: "{{ (owner | default('')) != '' and (intent | default({})) | count > 0 }}"
      then:
        - wait_template: >
            {{ ((state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('shared', {})
                 .get(owner ~ '::intent', {}).get('ts', 0) | float(0))
               >= ((intent | default({})).get('ts', 0) | float(0)) }}
          timeout:
            seconds: 1
          continue_on_timeout: true
    - alias: Skip if a fresher run is queued behind me — it has strictly better input
      # Avoids commanding an intermediate position that the next run immediately
      # overrides (the visible "starts to 100, reverses to 20" twitch).
      condition: template
      value_template: "{{ state_attr('script.smarli_cover_resolve', 'current') | int(1) <= 1 }}"
    - variables:
        now_ts: "{{ as_timestamp(now()) }}"
        shared: "{{ (state_attr('sensor.smarli_automation_tracker', 'data') or {}).get('shared', {}) }}"
        live_ids: >
          {{ states.automation | selectattr('state', 'eq', 'on')
             | map(attribute='attributes.id') | select('string') | list }}
        # Active intents: owner automation exists AND is on (disabling a shade
        # automation releases its bound), and not past its optional `until`.
        intents: >
          {% set ns = namespace(d={}) %}
          {% for key, value in shared.items() if key.endswith('::intent') %}
            {% set o = key.split('::')[0] %}
            {% if o in live_ids
                  and (value.get('until', 0) | float(0) == 0 or value.get('until') | float(0) > now_ts) %}
              {% set ns.d = dict(ns.d.items() | list + [(o, value)]) %}
            {% endif %}
          {% endfor %}
          {% if (owner | default('')) != '' and (intent | default({})) | count > 0 %}
            {% set ns.d = dict(ns.d.items() | list + [(owner, intent)]) %}
          {% endif %}
          {{ ns.d }}
        covers: >
          {% set ns = namespace(l=[]) %}
          {% for o, i in intents.items() %}
            {% for c in (i.get('targets', {}) | list) + (i.get('bounds', {}) | list) %}
              {% if c not in ns.l %}{% set ns.l = ns.l + [c] %}{% endif %}
            {% endfor %}
          {% endfor %}
          {{ ns.l }}
        resolved_map: >
          {% set ns = namespace(d={}) %}
          {% for c in covers %}
            {# newest target wins; ties by priority, then owner id (descending, for determinism) #}
            {% set tns = namespace(pos=none, key=none) %}
            {% for o, i in intents.items() if c in i.get('targets', {}) %}
              {% set k = [i.get('ts', 0) | float(0), i.get('priority', 0) | int(0), o] %}
              {% if tns.key is none or k > tns.key %}
                {% set tns.key = k %}
                {% set tns.pos = i.targets[c] | int %}
              {% endif %}
            {% endfor %}
            {# no target for this cover: hold what we last decided, else seed from reality #}
            {% set stored = shared.get(c ~ '::resolved') %}
            {% set current = state_attr(c, 'current_position') %}
            {% set target = tns.pos if tns.pos is not none
                            else (stored | int if stored is not none
                                  else (current | int if current is not none else none)) %}
            {% if target is not none %}
              {# intersect bounds, highest priority first, skipping any that would empty the range #}
              {% set bl = namespace(l=[]) %}
              {% for o, i in intents.items() if c in i.get('bounds', {}) %}
                {% set bl.l = bl.l + [[i.get('priority', 0) | int(0), o]] %}
              {% endfor %}
              {% set b = namespace(lo=0, hi=100) %}
              {% for pair in bl.l | sort(reverse=true) %}
                {% set bound = intents[pair[1]].bounds[c] %}
                {% set nlo = [b.lo, bound.get('min', 0) | int(0)] | max %}
                {% set nhi = [b.hi, bound.get('max', 100) | int(100)] | min %}
                {% if nlo <= nhi %}{% set b.lo = nlo %}{% set b.hi = nhi %}{% endif %}
              {% endfor %}
              {% set resolved = [[target | int, b.lo] | max, b.hi] | min %}
              {% set ns.d = dict(ns.d.items() | list + [(c, resolved)]) %}
            {% endif %}
          {% endfor %}
          {{ ns.d }}
        changed: >
          {% set ns = namespace(d={}) %}
          {% for c, pos in resolved_map.items() %}
            {% if shared.get(c ~ '::resolved') is none
                  or shared.get(c ~ '::resolved') | int(-1) != pos | int %}
              {% set ns.d = dict(ns.d.items() | list + [(c, pos)]) %}
            {% endif %}
          {% endfor %}
          {{ ns.d }}
        # Suspended covers are recorded but NOT commanded: a transition that
        # falls inside a suspension is CANCELLED, not deferred (see CLAUDE.md).
        batch: >
          {% set ns = namespace(d={}) %}
          {% for c, pos in changed.items() %}
            {% if shared.get(c ~ '::suspension', 0) | float(0) <= now_ts %}
              {% set ns.d = dict(ns.d.items() | list + [(c, pos)]) %}
            {% endif %}
          {% endfor %}
          {{ ns.d }}
        stale: >
          {% set ns = namespace(l=[]) %}
          {% for key, value in shared.items() %}
            {% if key.endswith('::resolved') and key.split('::')[0] not in covers %}
              {% set ns.l = ns.l + [key] %}
            {% elif '::moving_' in key and (value.get('until', 0) | float(0)) < now_ts %}
              {% set ns.l = ns.l + [key] %}
            {% endif %}
          {% endfor %}
          {{ ns.l }}
    - alias: Record the resolved position for every cover that changed
      repeat:
        for_each: "{{ changed | dictsort }}"
        sequence:
          - event: smarli_tracker_set
            event_data:
              namespace: shared
              key: "{{ repeat.item[0] }}::resolved"
              value: "{{ repeat.item[1] | int }}"
    - alias: Prune orphaned resolved records and expired markers
      repeat:
        for_each: "{{ stale }}"
        sequence:
          - event: smarli_tracker_remove
            event_data:
              namespace: shared
              key: "{{ repeat.item }}"
    - alias: Command the covers that changed and are not suspended
      if:
        - condition: template
          value_template: "{{ batch | count > 0 }}"
      then:
        - action: script.turn_on
          target:
            entity_id: script.smarli_cover_move
          data:
            variables:
              run: "{{ now_ts }}"
              targets: "{{ batch }}"
```

If V6 failed in Task 1, delete the `Skip if a fresher run is queued behind me` condition step; everything else is unchanged and A4 then expects two commands.

- [ ] **Step 5: Config-check both floors, restart, run the resolver test — expect PASS**

Deploy both package files and `automations.yaml`, restart, then:
Run: `powershell -File C:\Users\Pascal\smarli-ha-test\test-resolver.ps1`
Expected: `RESULT: PASS` — 20, then 0, then 100, no suspension.

- [ ] **Step 6: A6 — a bound alone moves a cover (standalone shade, no target contributor)**

```powershell
foreach ($k in @('stub_day::intent','cover.vfast::resolved','cover.vfast::suspension')) { HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key=$k } }
HA-Call cover set_cover_position @{ entity_id='cover.vfast'; position=100 } | Out-Null
Start-Sleep 10
HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key='cover.vfast::suspension' }
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ bounds=@{ 'cover.vfast'=@{ max=20 } } } }
Start-Sleep 15
(HA-State 'cover.vfast').attributes.current_position    # expect 20
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ targets=@{ 'cover.vfast'=100 } } }
Start-Sleep 15
(HA-State 'cover.vfast').attributes.current_position    # expect 100
```

Expected: 20, then 100 — the implicit target seeds from the cover's own position, and the retract target reopens it with no day-night present.

- [ ] **Step 7: A9 — disabling a contributor releases its bound**

With both stubs active and the cover at 20, disable the shade stub and re-poke the day stub:

```powershell
HA-Call automation turn_off @{ entity_id='automation.stub_shade_bound' } | Out-Null
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day'; value=@{ targets=@{ 'cover.vfast'=100 } } }
Start-Sleep 15
(HA-State 'cover.vfast').attributes.current_position    # expect 100
HA-Call automation turn_on @{ entity_id='automation.stub_shade_bound' } | Out-Null
```

Expected: 100. (Confirm the entity_id with `HA-State`; the alias slugifies to `automation.stub_shade_bound`.)

- [ ] **Step 8: A10 — infeasible bounds, higher priority wins**

Arm the shade stub with `max: 20` (priority 50) and hand-write a competing low-priority intent with `min: 50`:

```powershell
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ bounds=@{ 'cover.vfast'=@{ max=20 } } } }
Start-Sleep 8
# a live automation id is required for the intent to count — reuse stub_day's id
HA-Event 'smarli_tracker_set' @{ namespace='shared'; key='stub_day::intent'; value=@{ targets=@{ 'cover.vfast'=100 }; bounds=@{ 'cover.vfast'=@{ min=50 } }; priority=10; ts=1; suspension_duration=0 } }
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day'; value=@{ targets=@{ 'cover.vfast'=100 } } }
Start-Sleep 15
(HA-State 'cover.vfast').attributes.current_position    # expect 20 (priority 50 beats 10)
```

Expected: 20 — the `min: 50` bound would empty the range against `max: 20`, so it is skipped.

- [ ] **Step 9: Commit**

```bash
git add packages/smarli_cover.yaml
git commit -m "feat(smarli_cover): constraint-based central resolver

script.smarli_cover_resolve is now the single mover. Contributors publish
shared.<automation_id>::intent (targets and/or bounds) and call it; it
resolves clamp(newest target, bounds) per cover, records
<cover>::resolved, and fires smarli_cover_move for what changed.

- targets are one-shot events (newest wins, priority only breaks a
  same-tick tie); bounds are standing conditions that clamp, and an
  infeasible pair is resolved by dropping the lower-priority bound
- an intent counts only while its owner automation exists and is on
- suspended covers are recorded but not commanded: a transition inside a
  suspension is cancelled, not deferred
- mode: queued serialises the resolved-set writes and removes the
  coincident conflicting commands behind Phase-1 residual #7"
```

---

## Task 5: Rewire `coversDayNight.yaml`

**Files:**

- Modify: `automation/coversDayNight.yaml` (description/version, `variables:`, both move branches)
- Modify: `packages/smarli_cover.yaml` (drop the `instance_id` compatibility field)
- Test: `C:\Users\Pascal\smarli-ha-test\test-daynight.ps1`

**Interfaces:**

- Consumes: `script.smarli_cover_resolve(owner, intent)` from Task 4.
- Produces: `shared.<instance_id>::intent` with `priority: 10` and no bounds; `cover_day_night.<instance_id>::bright_since` / `::dark_since`.
- Removed: `cover_day_night.<instance_id>_commanded` (the intent is now the single record of what this instance last committed to).

- [ ] **Step 1: Write the failing test**

Create `C:\Users\Pascal\smarli-ha-test\test-daynight.ps1`. It asserts the blueprint publishes an intent instead of writing `_commanded`, using the existing `cover_sun_test` instance:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
$id = (HA-State 'automation.cover_sun_test').attributes.id
Start-Sleep 65        # let one heartbeat run
$shared = HA-Shared
$dn = (HA-Tracker).cover_day_night
$hasIntent    = @($shared.PSObject.Properties.Name) -contains "${id}::intent"
$hasCommanded = @($dn.PSObject.Properties.Name) -contains "${id}_commanded"
"intent key: $hasIntent (expect True); legacy _commanded: $hasCommanded (expect False)"
if ($hasIntent -and -not $hasCommanded) { "RESULT: PASS" } else { "RESULT: FAIL" }
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `powershell -File C:\Users\Pascal\smarli-ha-test\test-daynight.ps1`
Expected: FAIL — the blueprint still writes `<id>_commanded` and publishes no intent.

- [ ] **Step 3: Update the blueprint's variables**

In `automation/coversDayNight.yaml`, in the `variables:` block: replace the `last_commanded` definition and add the intent payload. Replace:

```yaml
last_commanded: "{{ stored_state.get(instance_id ~ '_commanded') | int(-1) }}"
```

with:

```yaml
# What this instance last committed to commanding — read back from its own
# published intent, so the intent is the single record instead of a second
# bookkeeping key. Absent (never run, or wiped) reads as -1, an impossible
# position, which forces a transition on the first evaluation and drives the
# covers to the correct phase instead of assuming where they are.
my_intent: >
  {{ (state_attr('sensor.smarli_automation_tracker', 'data') or {})
     .get('shared', {}).get(instance_id ~ '::intent', {}) }}
last_commanded: >
  {% set vals = my_intent.get('targets', {}).values() | list %}
  {{ vals[0] | int(-1) if vals | count > 0 else -1 }}
# Suspension length this instance asks for, in seconds; 0 when the technician
# turned suspension off. The resolver-side helper takes the MAX across all
# contributors naming a cover, so this is a request, not a decision.
suspension_seconds: >
  {{ 0 if not should_suspend_after_manual_interaction
     else (suspension_duration | as_timedelta).total_seconds() }}
```

Also change the two stabilizer keys and drop the now-unused `binary_threshold`:

```yaml
bright_since: "{{ stored_state.get(instance_id ~ '::bright_since') }}"
dark_since: "{{ stored_state.get(instance_id ~ '::dark_since') }}"
```

Delete these two lines entirely:

```yaml
# binary_threshold is separately set in smarli_cover.yaml script.smarli_cover_move - make sure to
# keep them in sync if you change it here!
binary_threshold: 50
```

Finally add the payload after `desired_targets`:

```yaml
# This instance's declaration to the resolver: a TARGET for every cover, never
# a bound. Day-night says "move to X now"; it never constrains other families.
intent_payload: >
  {{ {'targets': desired_targets, 'bounds': {}, 'priority': 10,
      'ts': now_ts | float(0), 'suspension_duration': suspension_seconds | float(0)} }}
```

- [ ] **Step 4: Rename the stabilizer keys in the actions**

In the `Brightness stabilizer bookkeeping` block, change all four event payloads from `key: "{{ instance_id }}_bright_since"` / `_dark_since` to `key: "{{ instance_id }}::bright_since"` / `::dark_since`. All four occurrences (two `smarli_tracker_set`, two `smarli_tracker_remove`).

- [ ] **Step 5: Replace both move branches**

In the `Open — reached the day phase` branch, replace the two steps `Remember the command before moving` and `Move covers open in the background` with:

```yaml
- alias: Publish this instance's intent (the resolver arbitrates it against every other contributor)
  event: smarli_tracker_set
  event_data:
    namespace: shared
    key: "{{ instance_id }}::intent"
    value: "{{ intent_payload }}"
- alias: Resolve and move whatever changed
  # Called blocking: resolution is milliseconds and never waits for
  # travel (it fires the mover non-blocking), and blocking keeps the
  # publish-then-resolve order deterministic.
  action: script.smarli_cover_resolve
  data:
    owner: "{{ instance_id }}"
    intent: "{{ intent_payload }}"
```

Apply the identical replacement in the `Close — reached the night phase` branch (`intent_payload` already carries the closed position, because `desired_targets` is built from `desired_position`).

- [ ] **Step 6: Bump the version in the blueprint description**

Change `*Version 2.0.0 | 2026-07-20*` to `*Version 3.0.0 | 2026-07-24*`, and add to the "How it works" section:

```text
      Several smarli. cover automations can control the same cover. Each one
      publishes what it wants to a central resolver, which combines all of them
      into one position per cover — so a shading automation and this one no
      longer fight over the same blind.
```

- [ ] **Step 7: Drop the mover's compatibility field**

In `packages/smarli_cover.yaml`, delete the `instance_id` field from `smarli_cover_move.fields` and simplify:

```yaml
run_token: "{{ run | default('run', true) }}"
```

Every caller now passes `run`.

- [ ] **Step 8: Config-check both floors, restart, run the test — expect PASS**

Deploy both packages **and** the blueprint, restart, then:
Run: `powershell -File C:\Users\Pascal\smarli-ha-test\test-daynight.ps1`
Expected: `RESULT: PASS`.

- [ ] **Step 9: A4 — coincident conflicting intents, no false suspension**

Arm both stubs between ticks so they fire in the same tick, ten times, watching for suspensions:

```powershell
. "C:\Users\Pascal\smarli-ha-test\ha.ps1"
$fails = 0
1..10 | ForEach-Object {
  foreach ($k in @('cover.vfast::suspension','cover.vfast::resolved')) { HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key=$k } }
  Start-Sleep 2
  HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day';   value=@{ targets=@{ 'cover.vfast'=100 } } }
  HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='shade'; value=@{ bounds=@{ 'cover.vfast'=@{ max=20 } } } }
  Start-Sleep 20
  $p = (HA-State 'cover.vfast').attributes.current_position
  $s = @((HA-Shared).PSObject.Properties.Name) -contains 'cover.vfast::suspension'
  "rep $_ : pos=$p susp=$s"
  if ($s -or $p -gt 25) { $fails++ }
}
"failures: $fails (expect 0)"
```

Expected: every repetition ends at ~20 with no suspension.

- [ ] **Step 10: A7 — a suspension spanning a transition cancels it**

```powershell
foreach ($k in @('cover.vfast::suspension','cover.vfast::resolved','stub_shade::intent')) { HA-Event 'smarli_tracker_remove' @{ namespace='shared'; key=$k } }
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day'; value=@{ targets=@{ 'cover.vfast'=100 } } }
Start-Sleep 15
# suspend for 60 s, then publish the opposite target while suspended
HA-Event 'smarli_tracker_set' @{ namespace='shared'; key='cover.vfast::suspension'; value=((Get-Date -UFormat %s) + 60) }
HA-Event 'smarli_tracker_set' @{ namespace='stub'; key='day'; value=@{ targets=@{ 'cover.vfast'=0 } } }
Start-Sleep 15
"during suspension: $((HA-State 'cover.vfast').attributes.current_position) (expect 100 — not moved)"
"resolved record: $((HA-Shared).'cover.vfast::resolved') (expect 0 — recorded anyway)"
Start-Sleep 60
"after expiry: $((HA-State 'cover.vfast').attributes.current_position) (expect 100 — cancelled, not deferred)"
```

Expected: the cover never moves, and nothing happens when the suspension expires.

- [ ] **Step 11: A5 — restart mid-shade**

With the day target 100 and the shade bound `≤20` active and the cover resting at 20, `docker restart smarli-ha-test`. After the restart heartbeat, the cover must still be at 20 — day-night's `homeassistant: start` evaluation must not stomp the bound.

```powershell
docker restart smarli-ha-test
Start-Sleep 90
"after restart: $((HA-State 'cover.vfast').attributes.current_position) (expect 20)"
```

- [ ] **Step 12: Commit**

```bash
git add automation/coversDayNight.yaml packages/smarli_cover.yaml
git commit -m "feat(coversDayNight)!: publish intent instead of commanding covers

The heartbeat now writes shared.<id>::intent (target only, priority 10)
and calls script.smarli_cover_resolve, which arbitrates against every
other contributor and moves what changed. The instance's own intent
replaces <id>_commanded as the record of what it last committed to, so
the -1 first-run sentinel and the weather-block retry are unchanged.
Stabilizer keys move to the <owner>::<name> grammar. Version 3.0.0.

BREAKING: requires the smarli. Core and Cover packages from this commit."
```

---

## Task 6: Documentation and a full sweep

**Files:**

- Modify: `CLAUDE.md` (arbitration section, key grammar, contributor contract, decision log)
- Modify: `docs/superpowers/plans/2026-07-22-cover-arbitration-and-false-suspension.md` (mark Phase 2 done, point at this plan)
- Test: full acceptance re-run

- [ ] **Step 1: Add the arbitration section to `CLAUDE.md`**

Insert after the "Manual-intervention detection" section:

````markdown
## Cover arbitration: contributors publish, one resolver commands

Several cover automations can control one cover. They never command it themselves — they publish an intent and call `script.smarli_cover_resolve`, which is the single mover.

- **TARGET** = "move to position X now" — a one-shot **event**. The newest target wins; `priority` only breaks a same-tick tie.
- **BOUND** = "while I say so, stay within min…max" — a standing **condition** that clamps whatever target is current. Bounds intersect; if two cannot both hold, the higher-priority one wins outright and the other is dropped for that cover.
- `resolved = clamp(newest_target, bounds)`. With no target at all, the implicit target is `<cover>::resolved`, or the cover's current position on the very first resolve.
- An intent counts only while its owner automation **exists and is on**. Priorities: day-night 10, shade 50, safety/storm 90.

**Contributor rules.** Publish only on change (edge-based — an idle house writes nothing). Publish a **target** only when genuinely deciding "move now", inside your own operating window; withdrawing a constraint outside that window means dropping the bound **silently**, with no target — otherwise a shade family whose condition clears at 22:00 reopens covers that day-night closed at 21:00. Anything that must _hold_ against later events is a bound, not a target. Keep owning your own manual detection (scripts cannot see `trigger`).

**Key grammar.** Every tracker key is `<owner>::<name>`, owner being an automation id, an entity_id, or the literal `global`. This is what lets `script.smarli_tracker_gc` in `smarli_core.yaml` collect keys whose owner no longer exists without knowing any family's key names — automation ids are regenerated on every create, so delete-and-recreate would otherwise leak a key per cycle.

```
shared:  <automation_id>::intent   <cover>::resolved   <cover>::suspension   <cover>::moving_<run>
cover_day_night:  <automation_id>::bright_since | ::dark_since
```

**Suspension duration is cover-level, not automation-level.** Several automations watch one cover and all fire on the same wall-switch press, so `script.smarli_cover_suspend` takes the **maximum** `suspension_duration` across active intents naming that cover; an automation with suspension turned off contributes 0.
````

- [ ] **Step 2: Add the rejected alternatives to the decision log**

Append to the `## Decision log (considered & rejected)` list in `CLAUDE.md`:

```markdown
- **Winner-takes-all priority for covers** — shade holding 20 (partial) vs. day-night wanting 0 (night): priority picks 20, leaving the cover _more open_ than the loser wanted. Priority cannot express "blocks opening, allows closing"; the target/bound split can.
- **A shade family writing a suspension to "protect" a cover** — a suspension is non-directional, so it would also block day-night's legitimate night close.
- **Priority-ownership** (each automation checks a shared owner record, then acts itself) — cheaper than a resolver, but a yielded low-priority automation never reclaims after the winner releases without an explicit poke, and coincident commands remain possible.
- **A value-level `owner:` field on every tracker entry** (instead of `<owner>::<name>` keys) — needs a second convention for entity-scoped keys, adds Jinja at every read/write site, and grows the payload we are trying to shrink.
- **A resolver heartbeat automation** — the one case it could repair (an orphaned bound whose contributor is gone) has no remaining target to command anyway, so it buys nothing for a per-minute run and a visible system automation.
```

- [ ] **Step 3: Update the old plan**

In `docs/superpowers/plans/2026-07-22-cover-arbitration-and-false-suspension.md`, replace the body of the "Phase 2" section with a pointer:

```markdown
## Phase 2 — Constraint-based arbitration

**Done.** Design: `docs/superpowers/specs/2026-07-24-cover-constraint-resolver-design.md`.
Implementation plan: `docs/superpowers/plans/2026-07-24-cover-constraint-resolver.md`.
All seven open decisions were closed in the design pass; open decisions #6 and #7
(the `commanded_<entity>` lifecycle and the settle-loop race) were resolved by
deleting that key and auditing against `<cover>::resolved` instead.
```

- [ ] **Step 4: Re-run every acceptance test end to end**

In one sitting, against the final code: A1–A3 (`test-resolver.ps1`), A4 (Task 5 Step 9), A5 (Task 5 Step 11), A6/A9/A10 (Task 4 Steps 6–8), A7 (Task 5 Step 10), A8 (Task 2 Step 6), A11 (Task 3 Step 11), R1/R2 (Task 3 Steps 9–10).

Record each as PASS/FAIL. **A FAIL here is a bug to fix, not a result to report** — return to the owning task.

- [ ] **Step 5: Final config check on both floors**

```powershell
$cfg = "C:\Users\Pascal\smarli-ha-test\config"
foreach ($v in @("2024.10","2025.4")) { docker run --rm -v "${cfg}:/config" "ghcr.io/home-assistant/home-assistant:$v" python -m homeassistant --script check_config -c /config }
```

Expected: `Successful config`, no ERROR lines, on both.

- [ ] **Step 6: Commit and open the PR**

```bash
git add CLAUDE.md docs/superpowers/plans/
git commit -m "docs(cover): document the constraint resolver conventions"
git push -u origin docs/cover-constraint-resolver
gh pr create --title "Cover arbitration Phase 2: constraint-based central resolver" --body "$(cat <<'EOF'
Contributors publish TARGET/BOUND intents to the tracker; one single-flight
resolver computes each cover's position and is the only mover.

- `script.smarli_cover_resolve` — clamp(newest target, bounds) per cover
- `script.smarli_tracker_gc` — family-agnostic cleanup via `<owner>::<name>` keys
- `script.smarli_cover_suspend` — suspension duration resolved per cover, not per automation
- `commanded_<entity>` deleted; the settle audit compares against `<cover>::resolved`,
  which closes Phase-1 residual #7 without a race
- `coversDayNight.yaml` 3.0.0 publishes intent instead of commanding

Design: docs/superpowers/specs/2026-07-24-cover-constraint-resolver-design.md
All acceptance tests (A1-A11, R1-R2) verified in the Docker HA test env;
config-checks clean on 2024.10 and 2025.4.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review notes

- **Spec coverage.** §3 grammar → Tasks 2/3/5; §4 algorithm → Task 4; §5 contract → Task 5 (+ CLAUDE.md in Task 6); §6 detection → Task 3; §6 central suspension → Task 3 (`smarli_cover_suspend`); §7 cancel → Task 4 (`changed` recorded, `batch` filtered) + A7; §8 GC → Task 2; §9 hazards → Task 3 (run token in the key) and Task 4 (`wait_template`, `mode: queued`); §10 → A11; §13 → Task 1; §14 → distributed across the tasks that make each test pass.
- **Compatibility across commits.** Task 3 keeps `instance_id` as an alias for `run` so the not-yet-rewired blueprint keeps working; Task 5 Step 7 removes it. No commit leaves the test env broken.
- **Type consistency.** `run` (str/float token) → `run_token` → key suffix `::moving_<run>`; `intent_payload` (dict) is what the blueprint writes **and** passes as `intent`; `suspension_duration` is **seconds as a float** everywhere (blueprint `suspension_seconds` → intent → `smarli_cover_suspend`), never an `HH:MM:SS` string; `<cover>::resolved` is an int 0–100 in both the resolver and the mover's audit.
- **Known conditional branches.** Task 2 Step 3 and Task 4 Step 4 each carry an explicit "if V1/V6 failed" variant, so Task 1's outcome never leaves an implementer guessing.
