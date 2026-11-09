# 5a  cheap runs and early manual-detection checks (cover_DayNight 3.2.0 + smarli_cover.yaml 2026-11-04).
# A cover state change must not render the schedule, and most such runs must end in conditions:
# - the run carries none of the decision variables (trace)
# - smarli_cover_suspend writes <cover>::suspended_at
# - the resolver elects one watcher per cover and skips a winner that does not watch
# - a state change within 60 s of a pause ends in conditions; after that, only the elected watcher goes on
# - a custom trigger still decides and moves; a person's command during that move still pauses the cover
# Two time-method instances on cover.vbright (same schedule, so they never disagree).
param([string[]]$Only = @())
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vbright"

# Runs of one automation (config id) that started after $since, oldest first.
function Runs($item, $since) {
  @((HA-WS @{ type = "trace/list"; domain = "automation"; item_id = $item }).result |
    Where-Object { [datetimeoffset]$_.timestamp.start -gt $since } | Sort-Object { $_.timestamp.start })
}
function Vars($item, $run) {
  $g = (HA-WS @{ type = "trace/get"; domain = "automation"; item_id = $item; run_id = $run.run_id }).result
  $first = $g.trace.PSObject.Properties.Name | Select-Object -First 1
  @($g.trace.$first[0].changed_variables.PSObject.Properties.Name)
}
function StateRun($item, $since, $state) {
  Runs $item $since | Where-Object { $_.trigger -like "state of $c*" } | Select-Object -Last 1
}

$second = @"

- id: cover_time_test2
  alias: covers_day_night_time2
  use_blueprint:
    path: smarli/cover_DayNight.yaml
    input:
      daynight_cycle_method: "time"
      cover_entity: ["$c"]
      time_open_workday: "00:01:00"
      time_open_non_workday: "00:01:00"
      time_close_workday_tomorrow: "23:59:00"
      time_close_non_workday_tomorrow: "23:59:00"
"@
T-Prep
# Real per-minute heartbeat only: the rig's 5 s heartbeat would push the state-change runs out of
# the 5 stored traces before they are read.
HA-Apply -RealHeartbeat -Time @{ cover_entity = @($c) } -Extra $second
T-Place $c 100
HA-Call "automation" "turn_on" @{ entity_id = @("automation.covers_day_night_time", "automation.covers_day_night_time2") }
$tReload = [datetimeoffset]::Now
HA-Call "automation" "reload"
Start-Sleep 6

if ($Only.Count -eq 0 -or $Only -contains "lean") {
  Write-Host "`n=== 5a-1 a cover state change carries no decision variables"
  $reload = Runs "cover_time_test" $tReload | Where-Object { $_.trigger -like "*automation_reloaded*" } | Select-Object -First 1
  $rv = if ($reload) { Vars "cover_time_test" $reload } else { @() }
  T-Check "5a-1 the reload run has the decision (todays_sunrise)" ($rv -contains "todays_sunrise") "vars: $($rv.Count)"
  $t0 = [datetimeoffset]::Now
  HA-Move @{ $c = 60 } "lean"; Start-Sleep 4
  $sr = StateRun "cover_time_test" $t0
  $sv = if ($sr) { Vars "cover_time_test" $sr } else { @() }
  T-Check "5a-1 a state-change run has no decision (no todays_sunrise)" ($null -ne $sr -and $sv -notcontains "todays_sunrise") "run: $($sr.trigger) -> $($sr.script_execution) | vars: $($sv.Count)"
  T-Check "5a-1 a state change caused by smarli. ends in conditions" ($sr.script_execution -eq "failed_conditions") "execution: $($sr.script_execution)"
  T-Settle $c 30; HA-ClearSuspensions
}

if ($Only.Count -eq 0 -or $Only -contains "stamp") {
  Write-Host "`n=== 5a-2 suspend records when it wrote the pause"
  HA-ClearSuspensions
  $now = HA-Now
  HA-Call "script" "smarli_cover_suspend" @{ entity_id = $c; fallback_duration = 300; reason = "test 5a-2" }
  $ok = HA-Wait { $null -ne (HA-Shared "$c::suspended_at") } 10 0.5
  $at = [double](HA-Shared "$c::suspended_at")
  T-Check "5a-2 suspended_at is written with the pause" ($ok -and [math]::Abs($at - $now) -lt 10 -and $null -ne (HA-Shared "$c::suspension")) "suspended_at - now = $([math]::Round($at - $now, 1)) s"
  HA-ClearSuspensions
}

if ($Only.Count -eq 0 -or $Only -contains "watcher") {
  Write-Host "`n=== 5a-3 one watcher per cover, never one that does not watch"
  $w0 = HA-Shared "$c::watcher"
  T-Check "5a-3 a watcher is elected after the reload" ($w0 -in @("automation.covers_day_night_time", "automation.covers_day_night_time2")) "watcher: $w0"
  $p = @{ targets = @{ $c = 100 }; bounds = @{}; priority = 10; ts = (HA-Now) + 5; suspension_duration = 1800; watches = $false }
  HA-SetKey "shared" "stub_day::intent" $p
  HA-Call "script" "smarli_cover_resolve" @{ owner = "stub_day"; intent = $p }; Start-Sleep 2
  $w1 = HA-Shared "$c::watcher"
  T-Check "5a-3 a newer winner that does not watch is not elected" ($w1 -in @("automation.covers_day_night_time", "automation.covers_day_night_time2")) "watcher: $w1"
  $p.watches = $true; $p.ts = (HA-Now) + 6
  HA-SetKey "shared" "stub_day::intent" $p
  HA-Call "script" "smarli_cover_resolve" @{ owner = "stub_day"; intent = $p }; Start-Sleep 2
  $w2 = HA-Shared "$c::watcher"
  T-Check "5a-3 a winner that watches is elected" ($w2 -eq "automation.stub_day_target") "watcher: $w2"
  HA-DelKey "shared" "stub_day::intent"; Start-Sleep 1
  # The key still names the stub until the resolver runs again. A resolver run elects a blueprint instance.
  HA-Call "script" "smarli_cover_resolve" @{}; Start-Sleep 2
  T-Check "5a-3 without the stub, the next resolver run elects a blueprint instance" ((HA-Shared "$c::watcher") -in @("automation.covers_day_night_time", "automation.covers_day_night_time2")) "watcher: $(HA-Shared "$c::watcher")"
}

if ($Only.Count -eq 0 -or $Only -contains "stale") {
  Write-Host "`n=== 5a-3b a stale watcher (on, but its intent no longer names the cover) is ignored"
  HA-ClearSuspensions; T-Place $c 100; HA-ClearSuspensions
  HA-SetKey "shared" "$c::watcher" "automation.stub_day_target"; Start-Sleep 1
  $t1 = [datetimeoffset]::Now
  HA-Call "cover" "close_cover" @{ entity_id = $c }
  Start-Sleep 3; HA-ClearSuspensions
  $back = HA-Wait { $null -ne (HA-Shared "$c::suspension") } 20 0.5
  Start-Sleep 2
  $r1 = Runs "cover_time_test" $t1 | Where-Object { $_.trigger -like "state of $c*" } | Select-Object -Last 1
  $r2 = Runs "cover_time_test2" $t1 | Where-Object { $_.trigger -like "state of $c*" } | Select-Object -Last 1
  T-Check "5a-3b with a stale watcher, both automations go on (no cover left unwatched)" ($back -and $r1.script_execution -eq "finished" -and $r2.script_execution -eq "finished") "suspension back: $back | runs: $($r1.script_execution) / $($r2.script_execution)"
  T-Settle $c 30; HA-ClearSuspensions
  HA-Call "script" "smarli_cover_resolve" @{}; Start-Sleep 2
}

if ($Only.Count -eq 0 -or $Only -contains "recent") {
  Write-Host "`n=== 5a-4 one hand action pauses once; later changes go to the elected watcher only"
  HA-ClearSuspensions; T-Place $c 100; HA-ClearSuspensions
  $w = HA-Shared "$c::watcher"
  $ids = @{ "automation.covers_day_night_time" = "cover_time_test"; "automation.covers_day_night_time2" = "cover_time_test2" }
  $me = $ids[$w]; $other = ($ids.Values | Where-Object { $_ -ne $me })
  if ($null -eq $me) { T-Check "5a-4 a blueprint instance is the watcher" $false "watcher: $w"; return }
  # A person's command: command_check pauses at once, the end state (no context, > 5 s later) is within 60 s.
  $t0 = [datetimeoffset]::Now
  HA-Call "cover" "close_cover" @{ entity_id = $c }
  Start-Sleep 12
  $end = Runs $me $t0 | Where-Object { $_.trigger -like "state of $c*" } | Select-Object -Last 1
  T-Check "5a-4 the end state of a paused hand move ends in conditions (pause < 60 s old)" ($end.script_execution -eq "failed_conditions") "watcher run: $($end.script_execution)"
  # Same move, but the pause is forgotten while the cover travels: the contextless end state must reach the watcher only.
  # Clear first: the mover in T-Place skips a paused cover.
  T-Settle $c 30; HA-ClearSuspensions; T-Place $c 100; HA-ClearSuspensions
  $t1 = [datetimeoffset]::Now
  HA-Call "cover" "close_cover" @{ entity_id = $c }
  Start-Sleep 3; HA-ClearSuspensions
  $back = HA-Wait { $null -ne (HA-Shared "$c::suspension") } 20 0.5
  Start-Sleep 2
  $mine = Runs $me $t1 | Where-Object { $_.trigger -like "state of $c*" } | Select-Object -Last 1
  $theirs = Runs $other $t1 | Where-Object { $_.trigger -like "state of $c*" } | Select-Object -Last 1
  T-Check "5a-4 the elected watcher detects the contextless end state (layer 2)" ($back -and $mine.script_execution -eq "finished") "suspension back: $back | watcher run: $($mine.script_execution)"
  T-Check "5a-4 the other automation on the same cover ends in conditions" ($theirs.script_execution -eq "failed_conditions") "other run: $($theirs.script_execution)"
  T-Settle $c 30; HA-ClearSuspensions
}

if ($Only.Count -eq 0 -or $Only -contains "custom") {
  Write-Host "`n=== 5a-5 a custom trigger decides and moves; a person's command during the move still pauses"
  HA-ClearSuspensions; T-Place $c 100; HA-ClearSuspensions
  HA-Event "test_force_close" @{}
  $moving = HA-Wait { (HA-StateStr $c) -eq "closing" } 15 0.5
  T-Check "5a-5 custom close trigger moves the cover" $moving "state: $(HA-StateStr $c) | intent targets: $(((T-Intent 'cover_time_test').targets | ConvertTo-Json -Compress))"
  HA-Call "cover" "stop_cover" @{ entity_id = $c }
  $paused = HA-Wait { $null -ne (HA-Shared "$c::suspension") } 10 0.5
  T-Check "5a-5 a person's command during the smarli. move pauses the cover" $paused "suspension: $(HA-Shared "$c::suspension")"
  T-Settle $c 30; HA-ClearSuspensions
}

HA-Apply
T-Prep
