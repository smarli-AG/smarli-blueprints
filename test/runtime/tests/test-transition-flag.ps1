# 4c  resolver `transition` flag (cover_DayNight 3.1.2 + smarli_cover.yaml from fix/resolver-transition-flag).
# (i)-(iv),(vi) on cover.vfast with the time-method instance; (v) on cover.assumed_rts (template cover, optimistic).
param([string[]]$Only = @())
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"; $id = "cover_time_test"
function Both($a, $b, $v) { @{ $a = $v; $b = $v } }
function Close-Cfg($Tstr, $cover = @("cover.vfast")) { (Both "time_close_workday_tomorrow" "time_close_non_workday_tomorrow" $Tstr) + @{ cover_entity = $cover } }
function Show($w) { $w.Log | % { Write-Host "    $_" } }

# resolved 0 (written by a real smarli close), cover physically open (moved outside smarli), instance intent 100
function Make-Stale {
  HA-StubDay @{ $c = 0 }; Start-Sleep 4; T-Settle $c 30
  HA-DelKey "shared" "stub_day::intent"; HA-ClearSuspensions
  HA-HandMove $c 100
}

function Timed-Close($name, [scriptblock]$prep, [scriptblock]$act, [scriptblock]$judge, [string]$closeAt = "", [int]$initTarget = 100) {
  Write-Host "`n=== $name"
  T-Prep
  T-Place $c 100
  $tA = HA-At 60; $Tstr = $tA.Str; $T = $tA.Time
  if ($closeAt -eq "") { $closeAt = $Tstr }
  HA-Apply -Time (Close-Cfg $closeAt)
  HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_time" }
  HA-Call "automation" "reload"; Start-Sleep 5
  HA-Wait { (T-Target $id $c) -eq $initTarget } 20 | Out-Null; T-Settle $c 30
  & $prep
  $pre = Sample-Cover $c $id
  $preTxt = "before T=${Tstr}: cover=$($pre.State)/$($pre.Pos) resolved=$($pre.Resolved) intent=$($pre.Target) susp=$($pre.Susp)"
  Write-Host "  $preTxt"
  $w = & $act $T
  Show $w
  & $judge $w $preTxt
  HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_time" }
  T-Prep
}

if ($Only.Count -eq 0 -or $Only -contains "i") {
  Timed-Close "4c-i heartbeat close, resolved already 0, cover hand-opened" { Make-Stale } `
    { param($T) Watch-Cover $c $id $T.AddSeconds(40) $T } `
    { param($w, $pre) $f = Sample-Cover $c $id
      T-Check "4c-i close transition commands a cover whose resolved already equals the target" ($w.Moved -and ($f.Pos -le 5)) "$pre | moved=$($w.Moved) final=$($f.State)/$($f.Pos) resolved=$($f.Resolved) susp=$($f.Susp)" }
}
if ($Only.Count -eq 0 -or $Only -contains "ii") {
  Timed-Close "4c-ii custom_close trigger (no flag), same stale state" { Make-Stale } `
    { param($T) HA-Event "test_force_close" @{}; Start-Sleep 1; $t1 = Get-Date; Watch-Cover $c $id $t1.AddSeconds(8) $t1 } `
    { param($w, $pre) $f = Sample-Cover $c $id
      T-Check "4c-ii custom_close does NOT re-command an unchanged resolved position" ((-not $w.Moved) -and ($f.Pos -ge 95) -and ($f.Target -eq 0)) "$pre | moved=$($w.Moved) final=$($f.State)/$($f.Pos) intent=$($f.Target) resolved=$($f.Resolved)" } ((HA-At -60).Str) 0
}
if ($Only.Count -eq 0 -or $Only -contains "iii") {
  Timed-Close "4c-iii other owner has the newer target on the same cover" `
    { HA-StubDay @{ $c = 100 } 10 1800 ((HA-Now) + 7200); Start-Sleep 4; T-Settle $c 20; HA-HandMove $c 0 } `
    { param($T) Watch-Cover $c $id $T.AddSeconds(40) $T } `
    { param($w, $pre) $f = Sample-Cover $c $id
      T-Check "4c-iii caller's transition does not force a cover another owner's newer target wins" ((-not $w.Moved) -and ($f.Pos -le 5) -and ($f.Resolved -eq 100)) "$pre | moved=$($w.Moved) final=$($f.State)/$($f.Pos) resolved=$($f.Resolved) intent=$($f.Target)"
      HA-DelKey "shared" "stub_day::intent" }
}
if ($Only.Count -eq 0 -or $Only -contains "iv") {
  Timed-Close "4c-iv suspended cover + transition" { Make-Stale; HA-SetKey "shared" "$c::suspension" ((HA-Now) + 900) } `
    { param($T) Watch-Cover $c $id $T.AddSeconds(40) $T } `
    { param($w, $pre) $f = Sample-Cover $c $id
      T-Check "4c-iv suspended cover is not commanded despite the transition flag" ((-not $w.Moved) -and ($f.Pos -ge 95) -and (-not $f.Marker)) "$pre | moved=$($w.Moved) final=$($f.State)/$($f.Pos) resolved=$($f.Resolved) susp=$($f.Susp)" }
}
if ($Only.Count -eq 0 -or $Only -contains "vi") {
  # forced re-command of a position cover already at the target (open phase): vfast open, resolved 100, instance opens at T
  Write-Host "`n=== 4c-vi position cover already at target, forced"
  T-Prep; T-Place $c 100
  HA-StubDay @{ $c = 100 }; Start-Sleep 5; T-Settle $c 20; HA-DelKey "shared" "stub_day::intent"; HA-ClearSuspensions
  $tA = HA-At 30; $Tstr = $tA.Str; $T = $tA.Time
  HA-Apply -Time ((Both "time_open_workday" "time_open_non_workday" $Tstr) + (Both "time_close_workday_tomorrow" "time_close_non_workday_tomorrow" "23:59:00"))
  HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_time" }
  Start-Sleep 1
  $lc0 = (HA-State $c).last_changed; $mv0 = (HA-State "script.smarli_cover_move").attributes.last_triggered
  $w = Watch-Cover $c $id $T.AddSeconds(30) $T
  Show $w
  $f = Sample-Cover $c $id; $lc1 = (HA-State $c).last_changed; $mv1 = (HA-State "script.smarli_cover_move").attributes.last_triggered
  T-Check "4c-vi forced re-command of a cover already at target: command sent, no movement, no suspension" (($mv1 -ne $mv0) -and (-not $w.Moved) -and ($lc0 -eq $lc1) -and (-not $w.Susp) -and (-not $f.Marker)) "move script last_triggered $mv0 -> $mv1; cover last_changed unchanged=$($lc0 -eq $lc1); moved=$($w.Moved) susp=$($w.Susp) marker-left=$($f.Marker) final=$($f.State)/$($f.Pos) intent=$($f.Target)"
  HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_time" }; T-Prep
}
if ($Only.Count -eq 0 -or $Only -contains "v") {
  Write-Host "`n=== 4c-v assumed-state cover (cover.assumed_rts), forced re-command to its current position"
  $a = "cover.assumed_rts"
  T-Prep
  $as = HA-State $a
  Write-Host "  $a state=$($as.state) assumed_state=$($as.attributes.assumed_state) pos=$($as.attributes.current_position) features=$($as.attributes.supported_features)"
  $tA = HA-At 45; $Tstr = $tA.Str; $T = $tA.Time
  HA-Apply -Time (Close-Cfg $Tstr @($a))
  HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_time" }
  HA-Call "automation" "reload"; Start-Sleep 5
  HA-Wait { (HA-Shared "$a::resolved") -eq 100 } 20 | Out-Null; Start-Sleep 5
  # a person/remote sets it to 0 in HA; resolved stays 100; clear what that writes
  HA-Call "cover" "set_cover_position" @{ entity_id = $a; position = 0 }; Start-Sleep 5; HA-ClearSuspensions; Start-Sleep 2; HA-ClearSuspensions
  $pre = Sample-Cover $a $id
  $preTxt = "before T=${Tstr}: cover=$($pre.State)/$($pre.Pos) assumed=$($pre.Assumed) resolved=$($pre.Resolved) intent=$($pre.Target)"
  Write-Host "  $preTxt"
  $w = Watch-Cover $a $id $T.AddSeconds(30) $T
  Show $w
  $mk = @(@(HA-KeyNames "shared") | ? { $_ -like "$a::moving_*" })
  $mval = if ($mk.Count -gt 0) { HA-Shared $mk[0] } else { $null }
  $untilIn = if ($mval) { [math]::Round($mval.until - (HA-Now)) } else { "n/a" }
  $f = Sample-Cover $a $id
  T-Check "4c-v assumed cover: forced re-command writes a marker (expires via until) and NO suspension" (($f.Resolved -eq 0) -and ($mk.Count -ge 1) -and (-not $w.Susp)) "$preTxt | marker=$($mk -join ',') until in ${untilIn}s; suspension seen=$($w.Susp); final=$($f.State)/$($f.Pos) resolved=$($f.Resolved)"
  # let the marker expire, then let the resolver prune it (any resolver run prunes expired markers)
  $waitS = if ($untilIn -eq "n/a") { 5 } else { [math]::Max(5, [int]$untilIn + 8) }
  Start-Sleep $waitS
  HA-StubDay @{ "cover.vslow" = [int](T-Pos "cover.vslow") }
  Start-Sleep 6
  $left = @(@(HA-KeyNames "shared") | ? { $_ -like "$a::moving_*" })
  $susp = @(@(HA-KeyNames "shared") | ? { $_ -like "$a::suspension" })
  T-Check "4c-v assumed cover: marker expired and pruned, still no suspension" (($left.Count -eq 0) -and ($susp.Count -eq 0)) "markers left=$($left -join ',') suspension=$($susp -join ',')"
  HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_time" }; T-Prep
  HA-Apply
}
