# 4d  decision log (cover_DayNight 3.1.3 + smarli_cover.yaml with logbook.log).
# Every outcome that used to be silent leaves a "smarli." line in the cover's logbook: who paused it, a move
# the resolver skipped, a move it started, an unchanged decision, and a retract time not before the extend time.
# Cases 1-4 on cover.vfast through the stub contributor; case 5 on the time-method instance.
param([string[]]$Only = @())
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"

# The "smarli." lines of one entity since $since. The logbook REST call needs UTC.
function Log-Lines($since, $entity) {
  $u = "$HA_BASE/api/logbook/$($since.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))?entity=$entity"
  @(Invoke-RestMethod -Uri $u -Headers (HA-Headers) | Where-Object { $_.name -eq "smarli." } | ForEach-Object { $_.message })
}
# The recorder writes the entry a moment after the event, so poll for it.
function Wait-Log($since, $entity, $pattern, [int]$timeout = 20) {
  $script:hit = $null
  HA-Wait { $script:hit = Log-Lines $since $entity | Where-Object { $_ -like $pattern } | Select-Object -First 1; $null -ne $script:hit } $timeout 1 | Out-Null
  $script:hit
}

if ($Only.Count -eq 0 -or $Only -contains "pause") {
  Write-Host "`n=== 4d-1 a person's command pauses the cover and says who"
  T-Prep; T-Place $c 100
  HA-StubDay @{ $c = 100 }; Start-Sleep 4; T-Settle $c 30; HA-ClearSuspensions
  $t0 = Get-Date
  HA-Call "cover" "set_cover_position" @{ entity_id = $c; position = 60 }
  $m = Wait-Log $t0 $c "paused until *(set_cover_position sent by *)*"
  T-Check "4d-1 pause is logged with the service and the login" ($null -ne $m) "line: $m"
  T-Settle $c 30; Start-Sleep 3
  $n = @(Log-Lines $t0 $c | Where-Object { $_ -like "paused until *" }).Count
  T-Check "4d-1 one press gives one pause line, not one per detection path" ($n -eq 1) "pause lines: $n"
}

if ($Only.Count -eq 0 -or $Only -contains "pause-many") {
  # One command to several covers: the command check suspends them in ONE suspend run (one batch
  # write, so both covers carry the same suspended_at), and each cover still gets one line.
  Write-Host "`n=== 4d-1c one command to two covers pauses both in one run"
  $c2 = "cover.vslow"
  T-Prep; T-Place $c 100; T-Place $c2 100
  HA-StubDay @{ $c = 100; $c2 = 100 }; Start-Sleep 4; T-Settle $c 30; T-Settle $c2 60; HA-ClearSuspensions
  $t0 = Get-Date
  HA-Call "cover" "set_cover_position" @{ entity_id = @($c, $c2); position = 60 }
  $m1 = Wait-Log $t0 $c "paused until *(set_cover_position sent by *)*"
  $m2 = Wait-Log $t0 $c2 "paused until *(set_cover_position sent by *)*"
  $a1 = HA-Shared "$c::suspended_at"; $a2 = HA-Shared "$c2::suspended_at"
  T-Check "4d-1c both covers are paused and logged" (($null -ne $m1) -and ($null -ne $m2)) "lines: [$m1] [$m2]"
  T-Check "4d-1c both pauses come from one batch write" (($null -ne $a1) -and ($a1 -eq $a2)) "suspended_at: $a1 / $a2"
  T-Settle $c 30; T-Settle $c2 60; Start-Sleep 3
  $n1 = @(Log-Lines $t0 $c | Where-Object { $_ -like "paused until *" }).Count
  $n2 = @(Log-Lines $t0 $c2 | Where-Object { $_ -like "paused until *" }).Count
  T-Check "4d-1c one pause line per cover" (($n1 -eq 1) -and ($n2 -eq 1)) "pause lines: $n1 / $n2"
}

if ($Only.Count -eq 0 -or $Only -contains "wall") {
  Write-Host "`n=== 4d-1b a contextless change (user_id null) still reaches the layer-2 check"
  # A wall switch has no user; the blueprint passes that as null, and a null user_id once failed the variables step.
  T-Prep; HA-ClearSuspensions
  $t0 = Get-Date
  HA-Call "script" "smarli_cover_manual_check" @{ entity_id = $c; user_id = $null; parent_id = ""; suspension_duration = "00:05:00" }
  $m = Wait-Log $t0 $c "paused until *(moved by hand, not by an automation*"
  T-Check "4d-1b null user_id: suspended and logged as a hand move" (($null -ne $m) -and ($null -ne (HA-Shared "$c::suspension"))) "line: $m"
  HA-ClearSuspensions
}

if ($Only.Count -eq 0 -or $Only -contains "skip") {
  Write-Host "`n=== 4d-2 a move inside a pause is skipped and says so"
  if ($null -eq (HA-Shared "$c::suspension")) { HA-SetKey "cover" "$c::suspension" ((HA-Now) + 900) }
  HA-StubDay @{ $c = 100 }; Start-Sleep 3
  $t0 = Get-Date
  HA-StubDay @{ $c = 0 } 10 1800 (HA-Now)
  $m = Wait-Log $t0 $c "not moved to 0 %: paused until *"
  $pos = T-Pos $c
  T-Check "4d-2 skipped move is logged, the cover stays put" (($null -ne $m) -and ($pos -ge 55)) "line: $m | position: $pos"
}

if ($Only.Count -eq 0 -or $Only -contains "move") {
  Write-Host "`n=== 4d-3 a move that is commanded says so"
  HA-ClearSuspensions
  $t0 = Get-Date
  HA-StubDay @{ $c = 100 } 10 1800 (HA-Now)
  $m = Wait-Log $t0 $c "moving to 100 %*"
  T-Check "4d-3 commanded move is logged" ($null -ne $m) "line: $m"
  T-Settle $c 40; HA-ClearSuspensions
}

if ($Only.Count -eq 0 -or $Only -contains "unchanged") {
  Write-Host "`n=== 4d-4 an unchanged decision says it did nothing"
  $t0 = Get-Date
  HA-StubDay @{ $c = 100 } 10 1800 (HA-Now)
  $m = Wait-Log $t0 $c "not moved: already decided as 100 %*"
  T-Check "4d-4 unchanged decision is logged" ($null -ne $m) "line: $m"
}

if ($Only.Count -eq 0 -or $Only -contains "order") {
  Write-Host "`n=== 4d-5 retract time not before extend time"
  T-Prep
  $auto = "automation.covers_day_night_time"
  $bad = @{ time_open_workday = "23:00:00"; time_open_non_workday = "23:00:00"; time_close_workday_tomorrow = "22:00:00"; time_close_non_workday_tomorrow = "22:00:00" }
  HA-Apply -Time $bad
  HA-Call "automation" "turn_on" @{ entity_id = $auto }
  $t0 = Get-Date
  HA-Call "automation" "reload"
  $m = Wait-Log $t0 $auto "Retract time 23:00 is not before extend time 22:00*"
  T-Check "4d-5 reload logs the warning on the automation" ($null -ne $m) "line: $m"
  HA-Call "automation" "turn_off" @{ entity_id = $auto }

  HA-Apply -Time @{ time_open_workday = "00:01:00"; time_open_non_workday = "00:01:00"; time_close_workday_tomorrow = "23:59:00"; time_close_non_workday_tomorrow = "23:59:00" }
  HA-Call "automation" "turn_on" @{ entity_id = $auto }
  $t1 = Get-Date
  HA-Call "automation" "reload"; Start-Sleep 12
  $n = @(Log-Lines $t1 $auto | Where-Object { $_ -like "Retract time*" }).Count
  T-Check "4d-5 correct order logs nothing" ($n -eq 0) "warning lines: $n"
  HA-Call "automation" "turn_off" @{ entity_id = $auto }
}

T-Prep
