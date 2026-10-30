# Helpers for the smarli. HA runtime test environment (docs/test-environment.md). Dot-source before use:
#   . "<repo>\test\runtime\lib\ha.ps1"
# PowerShell 5.1. NOTE: variable names are case-insensitive ($R and $r are the same variable).
#
# Environment overrides (defaults in brackets): HA_PORT [8123], HA_CONTAINER [smarli-ha-test],
# HA_PACKAGES_DIR [<repo>\..\ha-packages\packages]. bootstrap.ps1 and docker-compose.yml read the same.

# docker is not on the PATH the tool shells start with.
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

$HA_ROOT  = Split-Path -Parent $PSScriptRoot          # test\runtime
$HA_REPO  = Split-Path -Parent (Split-Path -Parent $HA_ROOT)
$HA_STATE = Join-Path $HA_ROOT ".state"               # git-ignored: HA config, token, results
$HA_PORT  = if ($env:HA_PORT) { $env:HA_PORT } else { "8123" }
$HA_BASE  = "http://localhost:$HA_PORT"
$HA_CONTAINER = if ($env:HA_CONTAINER) { $env:HA_CONTAINER } else { "smarli-ha-test" }
$HA_PACKAGES_DIR = if ($env:HA_PACKAGES_DIR) { $env:HA_PACKAGES_DIR } else { Join-Path (Split-Path -Parent $HA_REPO) "ha-packages\packages" }

function HA-Token   { (Get-Content "$HA_STATE\.token" -Raw).Trim() }
function HA-Headers { @{ Authorization = "Bearer $(HA-Token)" } }

function HA-Call {
  param($domain, $service, $data = @{})
  Invoke-RestMethod -Uri "$HA_BASE/api/services/$domain/$service" -Method Post -Headers (HA-Headers) `
    -Body ($data | ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null
}
function HA-Event {
  param($t, $d = @{})
  Invoke-RestMethod -Uri "$HA_BASE/api/events/$t" -Method Post -Headers (HA-Headers) `
    -Body ($d | ConvertTo-Json -Depth 8 -Compress) -ContentType "application/json" | Out-Null
}
function HA-State    { param($id) Invoke-RestMethod -Uri "$HA_BASE/api/states/$id" -Headers (HA-Headers) }
function HA-StateStr { param($id) try { (HA-State $id).state } catch { "missing" } }
function HA-Tracker  { (HA-State "sensor.smarli_automation_tracker").attributes.data }
# Value of one tracker key, or $null. Property names with '::' need the quoted form.
function HA-Key {
  param($ns, $key)
  $d = HA-Tracker
  if ($null -eq $d) { return $null }
  $b = $d.$ns
  if ($null -eq $b) { return $null }
  $b.PSObject.Properties[$key].Value
}
function HA-Shared { param($key) HA-Key "shared" $key }
function HA-KeyNames { param($ns) $b = (HA-Tracker).$ns; if ($null -ne $b) { $b.PSObject.Properties | ForEach-Object { $_.Name } } }
function HA-SetKey { param($ns, $key, $value) HA-Event "smarli_tracker_set" @{ namespace = $ns; key = $key; value = $value } }
function HA-DelKey { param($ns, $key) HA-Event "smarli_tracker_remove" @{ namespace = $ns; key = $key } }
function HA-Template {
  param($tpl)
  Invoke-RestMethod -Uri "$HA_BASE/api/template" -Method Post -Headers (HA-Headers) `
    -Body (@{ template = $tpl } | ConvertTo-Json -Compress) -ContentType "application/json"
}
function HA-Now   { [double](HA-Template "{{ as_timestamp(now()) }}") }
# A clock time for schedule inputs: HA's local HH:MM:SS at now + $addSeconds (.Str), and the same
# instant as a host DateTime (.Time). Always take times from HA: the tests move HA's time zone
# (T-LocalNoon), so the host's clock face differs from HA's.
function HA-At {
  param([int]$addSeconds = 0)
  $p = (HA-Template "{% set t = now() + timedelta(seconds=$addSeconds) %}{{ t.strftime('%H:%M:%S') }}|{{ as_timestamp(t) | int }}").Trim().Split('|')
  [pscustomobject]@{ Str = $p[0]; Time = [DateTimeOffset]::FromUnixTimeSeconds([long]$p[1]).LocalDateTime }
}
# One websocket command (e.g. config/core/update), sent from inside the container by ws.py.
# Returns the result message; throws when HA reports an error.
function HA-WS {
  param([hashtable]$msg)
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($msg | ConvertTo-Json -Compress -Depth 8)))
  $r = (docker exec $HA_CONTAINER python3 /config/ws.py (HA-Token) $b64 | Out-String) | ConvertFrom-Json
  if (-not $r.success) { throw "HA-WS $($msg.type) failed: $($r.error.message)" }
  $r
}
function HA-Wait {
  param([scriptblock]$cond, [int]$timeout = 60, [double]$every = 1)
  $end = (Get-Date).AddSeconds($timeout)
  while ((Get-Date) -lt $end) { if (& $cond) { return $true }; Start-Sleep -Milliseconds ([int]($every * 1000)) }
  return $false
}
function Wait-HA {
  $deadline = (Get-Date).AddMinutes(4)
  while ((Get-Date) -lt $deadline) {
    try { if ((Invoke-WebRequest -Uri "$HA_BASE/api/onboarding" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { break } } catch {}
    Start-Sleep 5
  }
  Start-Sleep 15
}

# Drive a move through the contextless rig automation (no user_id on the cover call)
function HA-Move { param($targets, $run = "rig") HA-Event "test_mover_fire" @{ targets = $targets; run = $run } }
# Publish an intent through a stub contributor (stub_day: targets, stub_shade: bounds/targets)
function HA-StubDay   { param($targets, [int]$priority = 10, [int]$susp = 1800, $ts = $null, [bool]$transition = $false) $d = @{ targets = $targets; priority = $priority; susp = $susp; transition = $transition }; if ($null -ne $ts) { $d.ts = $ts }; HA-Event "test_stub_day" $d }
function HA-StubShade { param($bounds, $targets = @{}, [int]$priority = 50, [int]$susp = 1800, $ts = $null) $d = @{ bounds = $bounds; targets = $targets; priority = $priority; susp = $susp }; if ($null -ne $ts) { $d.ts = $ts }; HA-Event "test_stub_shade" $d }

# Remove every *::suspension and *::moving_* key (after bare cover.* calls, which taint context)
function HA-ClearSuspensions {
  foreach ($k in (HA-KeyNames "shared")) {
    if ($k -like "*::suspension" -or $k -like "*::moving_*") { HA-DelKey "shared" $k }
  }
  Start-Sleep 1
}

# ---------------------------------------------------------------------------
# automations.yaml builder. Inputs are rendered as JSON (valid YAML flow style).
# ---------------------------------------------------------------------------
function Y-Input { param($h) ($h.GetEnumerator() | Sort-Object Name | ForEach-Object { "      $($_.Name): $(ConvertTo-Json -InputObject $_.Value -Compress -Depth 6)" }) -join "`n" }

function Get-TimeDefaults {
  @{
    daynight_cycle_method = "time"
    workday_tracker = ""; workday_tomorrow_tracker = ""
    time_open_workday = "00:01:00"; time_open_non_workday = "00:01:00"
    time_close_workday_tomorrow = "23:59:00"; time_close_non_workday_tomorrow = "23:59:00"
    should_use_earliest_open = $false; should_use_earliest_close = $false
    should_use_latest_open = $false; should_use_latest_close = $false
    should_suspend_after_manual_interaction = $true; suspension_duration = "00:30:00"
    cover_entity = @("cover.vfast")
    custom_closing_triggers = @(@{ trigger = "event"; event_type = "test_force_close"; id = "custom_close" })
  }
}

# Extra heartbeat for the time and brightness instances: the blueprint's heartbeat branch only
# checks trigger.id == 'heartbeat', so a custom trigger with that id evaluates every 5 s instead of
# every minute, and second-precision schedule times (HA-At) are acted on within seconds. The real
# per-minute trigger stays in place; the sun instance keeps only that one (test-daynight covers it).
# -RealHeartbeat leaves it out.
$FAST_HEARTBEAT = @{ trigger = "time_pattern"; seconds = "/5"; id = "heartbeat" }

function Build-Automations {
  param([hashtable]$Time = @{}, [hashtable]$Sun = @{}, [hashtable]$Bright = @{}, [switch]$NoWeather, [switch]$RealHeartbeat, [string]$Extra = "")
  $t = Get-TimeDefaults; foreach ($k in $Time.Keys) { $t[$k] = $Time[$k] }
  if (-not $RealHeartbeat) { $t.custom_closing_triggers = @($t.custom_closing_triggers) + $FAST_HEARTBEAT }
  $s = @{ daynight_cycle_method = "sun"; cover_entity = @("cover.garage_door")
          custom_closing_triggers = @(@{ trigger = "event"; event_type = "test_force_close"; id = "custom_close" }) }
  if (-not $NoWeather) { $s.weather_entity = "weather.weather_at_8001" }
  foreach ($k in $Sun.Keys) { $s[$k] = $Sun[$k] }
  $b = @{ daynight_cycle_method = "brightness"; brightness_sensor = "sensor.test_lux"; lux_sensor_delay = "00:00:20"
          cover_entity = @("cover.vbright") }
  foreach ($k in $Bright.Keys) { $b[$k] = $Bright[$k] }
  if (-not $RealHeartbeat) { $b.custom_closing_triggers = @($b.custom_closing_triggers | Where-Object { $_ }) + $FAST_HEARTBEAT }
@"
- id: test_mover
  alias: test_mover_contextless
  mode: queued
  triggers:
    - trigger: event
      event_type: test_mover_fire
  actions:
    - action: script.turn_on
      target:
        entity_id: script.smarli_cover_move
      data:
        variables:
          run: "{{ trigger.event.data.run | default('rig') }}"
          targets: "{{ trigger.event.data.targets }}"

- id: test_manual_watch
  alias: test_manual_check_watcher_vfast_vslow
  mode: queued
  triggers:
    - trigger: state
      entity_id: [cover.vfast, cover.vslow]
      not_from: [unavailable, unknown]
      not_to: [unavailable, unknown]
  actions:
    - action: script.smarli_cover_manual_check
      data:
        entity_id: "{{ trigger.entity_id }}"
        user_id: "{{ trigger.to_state.context.user_id | default('') }}"
        parent_id: "{{ trigger.to_state.context.parent_id | default('') }}"
        suspension_duration: "00:30:00"

- id: stub_day
  alias: stub_day_target
  mode: queued
  triggers:
    - trigger: event
      event_type: test_stub_day
  actions:
    - variables:
        payload: >
          {{ {'targets': trigger.event.data.targets, 'bounds': {}, 'priority': trigger.event.data.priority | default(10) | int,
              'ts': trigger.event.data.ts | default(as_timestamp(now())) | float(0), 'suspension_duration': trigger.event.data.susp | default(1800) | float(0)} }}
    - event: smarli_tracker_set
      event_data:
        namespace: shared
        key: stub_day::intent
        value: "{{ payload }}"
    - action: script.smarli_cover_resolve
      data:
        owner: stub_day
        intent: "{{ payload }}"
        transition: "{{ trigger.event.data.transition | default(false) | bool }}"

- id: stub_shade
  alias: stub_shade_bound
  mode: queued
  triggers:
    - trigger: event
      event_type: test_stub_shade
  actions:
    - variables:
        payload: >
          {{ {'targets': trigger.event.data.targets | default({}), 'bounds': trigger.event.data.bounds | default({}),
              'priority': trigger.event.data.priority | default(50) | int,
              'ts': trigger.event.data.ts | default(as_timestamp(now())) | float(0), 'suspension_duration': trigger.event.data.susp | default(1800) | float(0)} }}
    - event: smarli_tracker_set
      event_data:
        namespace: shared
        key: stub_shade::intent
        value: "{{ payload }}"
    - action: script.smarli_cover_resolve
      data:
        owner: stub_shade
        intent: "{{ payload }}"
        transition: "{{ trigger.event.data.transition | default(false) | bool }}"

- id: cover_sun_test
  alias: covers_day_night_sun
  use_blueprint:
    path: smarli/cover_DayNight.yaml
    input:
$(Y-Input $s)

- id: cover_time_test
  alias: covers_day_night_time
  use_blueprint:
    path: smarli/cover_DayNight.yaml
    input:
$(Y-Input $t)

- id: cover_brightness_test
  alias: covers_day_night_brightness
  use_blueprint:
    path: smarli/cover_DayNight.yaml
    input:
$(Y-Input $b)
$Extra
"@
}

# Write automations.yaml and reload. Keeps each automation's on/off state across the reload.
function HA-Apply {
  param([hashtable]$Time = @{}, [hashtable]$Sun = @{}, [hashtable]$Bright = @{}, [switch]$NoWeather, [switch]$RealHeartbeat, [string]$Extra = "")
  $yaml = Build-Automations -Time $Time -Sun $Sun -Bright $Bright -NoWeather:$NoWeather -RealHeartbeat:$RealHeartbeat -Extra $Extra
  [IO.File]::WriteAllText("$HA_STATE\config\automations.yaml", $yaml.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  HA-Call "automation" "reload"
  Start-Sleep 2
}

# A position change that does not go through smarli (REST call = a person), then forget the suspension it causes.
# The cover's final contextless state write lands after the travel, so clear once travel is over (twice, to be safe).
function HA-HandMove {
  param($cover, [int]$pos)
  HA-Call "cover" "set_cover_position" @{ entity_id = $cover; position = $pos }
  Start-Sleep 3
  HA-Wait { $s = HA-StateStr $cover; ($s -ne "opening") -and ($s -ne "closing") } 40 1 | Out-Null
  Start-Sleep 2; HA-ClearSuspensions; Start-Sleep 2; HA-ClearSuspensions
}
