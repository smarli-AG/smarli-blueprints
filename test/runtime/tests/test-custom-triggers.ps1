# Custom retract/extend triggers (cover_DayNight 3.1.2): a custom trigger moves the covers against the
# schedule and holds until the schedule's next phase change; it obeys suspensions.
# Time-method instance on cover.vfast. CT4 restarts the container.
param([string[]]$Only = @())
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"; $id = "cover_time_test"; $auto = "automation.covers_day_night_time"
$openTrig = @(@{ trigger = "event"; event_type = "test_force_open"; id = "custom_open" })
function Run($k) { $Only.Count -eq 0 -or $Only -contains $k }
function Phase { $i = T-Intent $id; if ($null -eq $i) { $null } else { $i.phase } }
function Ts { $i = T-Intent $id; if ($null -eq $i) { $null } else { [double]$i.ts } }
function Both($v) { @{ time_close_workday_tomorrow = $v; time_close_non_workday_tomorrow = $v } }
function Start-Instance($cfg, [int]$expect) {
  T-Prep
  HA-Apply -Time $cfg
  HA-Call "automation" "turn_on" @{ entity_id = $auto }
  HA-Call "automation" "reload"; Start-Sleep 5
  $ok = HA-Wait { (T-Target $id $c) -eq $expect } 90
  T-Settle $c 30
  $ok
}
function Stop-Instance { HA-Call "automation" "turn_off" @{ entity_id = $auto }; T-Prep }

if ((Run "1") -or (Run "4")) {
  Write-Host "`n=== CT1 custom close during the day phase"
  T-Place $c 100
  $ok = Start-Instance @{} 100          # defaults: open 00:01, close 23:59 -> the schedule wants open now
  T-Check "CT0 heartbeat intent records phase = schedule position" ($ok -and ((Phase) -eq 100)) "target=$(T-Target $id $c) phase=$(Phase)"
  HA-Event "test_force_close" @{}
  $ok = HA-Wait { (T-Target $id $c) -eq 0 } 20; Start-Sleep 3; T-Settle $c 30
  $pos = T-Pos $c; $ts1 = Ts
  T-Check "CT1 custom close closes the cover against the day schedule" ($ok -and ($pos -le 5) -and ((Phase) -eq 100)) "pos=$pos target=$(T-Target $id $c) phase=$(Phase)"
  Start-Sleep 20
  $pos2 = T-Pos $c; $ts2 = Ts
  T-Check "CT1b the next heartbeats do not undo it (no re-publish, still closed)" (($pos2 -le 5) -and ($ts2 -eq $ts1) -and ((T-Target $id $c) -eq 0)) "pos=$pos2 ts unchanged=$($ts2 -eq $ts1) target=$(T-Target $id $c)"
  if (Run "4") {
    Write-Host "`n=== CT4 the custom hold survives a restart"
    docker restart $HA_CONTAINER | Out-Null; Start-Sleep 10; Wait-HA; Start-Sleep 20
    $pos3 = T-Pos $c; $ts3 = Ts
    T-Check "CT4 after a restart the cover stays closed, no re-publish" (($pos3 -le 5) -and ($ts3 -eq $ts1) -and ((Phase) -eq 100)) "pos=$pos3 ts unchanged=$($ts3 -eq $ts1) phase=$(Phase)"
  }
  Stop-Instance
}

if (Run "2") {
  Write-Host "`n=== CT2 custom open during the night phase"
  T-Place $c 0
  $past = (HA-At -120).Str
  $cfg = (Both $past) + @{ custom_opening_triggers = $openTrig }
  $ok = Start-Instance $cfg 0           # close time passed -> closing wins -> the schedule wants closed now
  HA-Event "test_force_open" @{}
  $ok2 = HA-Wait { (T-Target $id $c) -eq 100 } 20; Start-Sleep 3; T-Settle $c 30
  $pos = T-Pos $c; $ts1 = Ts
  T-Check "CT2 custom open opens the cover against the night schedule" ($ok -and $ok2 -and ($pos -ge 95) -and ((Phase) -eq 0)) "pos=$pos target=$(T-Target $id $c) phase=$(Phase)"
  Start-Sleep 20
  $pos2 = T-Pos $c; $ts2 = Ts
  T-Check "CT2b the next heartbeats do not undo it" (($pos2 -ge 95) -and ($ts2 -eq $ts1)) "pos=$pos2 ts unchanged=$($ts2 -eq $ts1)"
  Stop-Instance
}

if (Run "3") {
  Write-Host "`n=== CT3 the schedule's next phase change takes over"
  T-Place $c 100
  $T = (HA-At 45).Str; $Tts = [double](HA-Template "{{ as_timestamp(today_at('$T')) }}")
  $cfg = (Both $T) + @{ custom_opening_triggers = $openTrig }
  $ok = Start-Instance $cfg 100
  HA-Event "test_force_close" @{}
  HA-Wait { (T-Target $id $c) -eq 0 } 20 | Out-Null; Start-Sleep 3; T-Settle $c 30
  HA-Event "test_force_open" @{}
  HA-Wait { (T-Target $id $c) -eq 100 } 20 | Out-Null; Start-Sleep 3; T-Settle $c 30
  $ts1 = Ts; $p1 = Phase
  T-Note "CT3 setup: custom close then custom open before T=$T" "INFO" "pos=$(T-Pos $c) target=$(T-Target $id $c) phase=$p1"
  HA-Wait { (HA-Now) -ge ($Tts + 10) } 120 2 | Out-Null; T-Settle $c 30
  $pos = T-Pos $c; $ts2 = Ts
  T-Check "CT3 at the scheduled close the schedule takes over again and closes" ($ok -and ($p1 -eq 100) -and ($ts2 -gt $ts1) -and ((Phase) -eq 0) -and ($pos -le 5)) "pos=$pos target=$(T-Target $id $c) phase=$(Phase) republished=$($ts2 -gt $ts1)"
  Stop-Instance
}

if (Run "5") {
  Write-Host "`n=== CT5 a custom trigger does not override a suspension"
  T-Place $c 100
  $ok = Start-Instance @{} 100
  HA-SetKey "shared" "$c::suspension" ((HA-Now) + 900); Start-Sleep 2
  HA-Event "test_force_close" @{}
  HA-Wait { (T-Target $id $c) -eq 0 } 20 | Out-Null; Start-Sleep 10
  $pos = T-Pos $c
  T-Check "CT5 suspended cover is not commanded by a custom close" ($ok -and ($pos -ge 95) -and ((T-Target $id $c) -eq 0)) "pos=$pos target=$(T-Target $id $c)"
  HA-DelKey "shared" "$c::suspension"; Start-Sleep 20
  $pos2 = T-Pos $c
  T-Check "CT5b after the suspension the cancelled custom close is not executed later" ($pos2 -ge 95) "pos=$pos2 target=$(T-Target $id $c)"
  Stop-Instance
}
