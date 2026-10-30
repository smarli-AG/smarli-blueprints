# 4b  time method with earliest close / earliest open. close time T, earliest close T+30 s (and the reverse for opening).
# Instance cover_time_test on cover.vfast, 5 s heartbeat, second-precision times (HA-At). Timeline sampled every 2 s.
# Tracker keys are NOT deleted between runs.
param([string[]]$Only = @())
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"; $id = "cover_time_test"

function Both($key1, $key2, $v) { @{ $key1 = $v; $key2 = $v } }

function Sample {
  $tr = HA-Tracker; $sh = $tr.shared; $cs = HA-State $c
  $int = $sh.PSObject.Properties["$id::intent"].Value
  [pscustomobject]@{
    Now = Get-Date; State = $cs.state; Pos = $cs.attributes.current_position
    Target = $(if ($int) { $int.targets.PSObject.Properties[$c].Value } else { $null })
    IntentTs = $(if ($int) { [double]$int.ts } else { $null }); Fp = $(if ($int) { $int.fingerprint } else { $null })
    Resolved = $sh.PSObject.Properties["$c::resolved"].Value
    Susp = ($null -ne $sh.PSObject.Properties["$c::suspension"])
    Marker = [bool](@($sh.PSObject.Properties.Name) -like "$c::moving_*")
  }
}

function Run-Scenario($name, $kind, $prep) {
  Write-Host "`n=== $name ($kind, prep=$prep)"
  HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_time" }
  # --- prep: put cover/records into the starting state, using only stub contributors / hand moves, no key deletion
  HA-ClearSuspensions
  $baseline = if ($kind -eq "close") { 100 } else { 0 }
  switch ($prep) {
    "stub" { HA-StubDay @{ $c = $baseline }; Start-Sleep 4; T-Settle $c 30; HA-DelKey "shared" "stub_day::intent"; HA-ClearSuspensions }
    "hand" { HA-HandMove $c (100 - (T-Pos $c)) }
    "handkeep" {
      HA-Call "cover" "set_cover_position" @{ entity_id = $c; position = [int](100 - (T-Pos $c)) }
      Start-Sleep 3; T-Settle $c 30; Start-Sleep 2
    }
  }
  $pre = Sample
  $preTxt = "start: cover=$($pre.State)/$($pre.Pos) intent=$($pre.Target) resolved=$($pre.Resolved) susp=$($pre.Susp) fp=$($pre.Fp)"
  Write-Host $preTxt
  # --- fresh times
  $tA = HA-At 40; $eA = HA-At 70
  $Tstr = $tA.Str; $T = $tA.Time; $Estr = $eA.Str; $E = $eA.Time
  if ($kind -eq "close") {
    $cfg = @{ should_use_earliest_close = $true; time_open_workday = "00:01:00"; time_open_non_workday = "00:01:00" }
    $cfg += Both "time_close_workday_tomorrow" "time_close_non_workday_tomorrow" $Tstr
    $cfg += Both "earliest_close_workday_tomorrow" "earliest_close_non_workday_tomorrow" $Estr
  } else {
    $cfg = @{ should_use_earliest_open = $true }
    $cfg += Both "time_open_workday" "time_open_non_workday" $Tstr
    $cfg += Both "earliest_open_workday" "earliest_open_non_workday" $Estr
    $cfg += Both "time_close_workday_tomorrow" "time_close_non_workday_tomorrow" "23:59:00"
  }
  $tApply = Get-Date
  HA-Apply -Time $cfg
  Write-Host "applied at $($tApply.ToString('HH:mm:ss'))  T=$Tstr  earliest=$Estr"
  # --- timeline
  $log = New-Object System.Collections.ArrayList
  $last = ""; $first = @{}
  $end = $E.AddSeconds(25)
  while ((Get-Date) -lt $end) {
    $s = Sample
    $key = "$($s.State)|$($s.Target)|$($s.Resolved)|$($s.Susp)|$($s.Marker)|$([math]::Round($s.IntentTs))"
    $rel = [math]::Round(($s.Now - $T).TotalSeconds)
    if ($key -ne $last) {
      [void]$log.Add(("T{0:+0;-0}s cover={1}/{2} intent={3} resolved={4} susp={5} marker={6}" -f $rel, $s.State, $s.Pos, $s.Target, $s.Resolved, $s.Susp, $s.Marker))
      $last = $key
    }
    $mv = if ($kind -eq "close") { "closing" } else { "opening" }
    if ($s.State -eq $mv -and -not $first.ContainsKey("move") -and $s.Now -gt $tApply.AddSeconds(12)) { $first.move = $s.Now }
    if ($s.State -eq $mv -and $s.Now -ge $T -and $s.Now -lt $E.AddSeconds(-1)) { $first.early = $s.Now }
    $want = if ($kind -eq "close") { 0 } else { 100 }
    if ($s.Resolved -eq $want -and $s.Now -gt $tApply.AddSeconds(12) -and -not $first.ContainsKey("res")) { $first.res = $s.Now }
    Start-Sleep 2
  }
  T-Settle $c 30
  $fin = Sample
  $log | % { Write-Host "  $_" }
  $want = if ($kind -eq "close") { 0 } else { 100 }
  $relMove = if ($first.move) { [math]::Round(($first.move - $E).TotalSeconds) } else { "none" }
  $relRes = if ($first.res) { [math]::Round(($first.res - $E).TotalSeconds) } else { "none" }
  $earlyBool = $first.ContainsKey("early")
  $evid = "$preTxt | T=$Tstr E=$Estr | motion in [T,E): $earlyBool | first $mv after E: $relMove s | resolved==$want first seen at E$(if ($relRes -ne 'none') {'+'+$relRes})s | final cover=$($fin.State)/$($fin.Pos) intent=$($fin.Target) resolved=$($fin.Resolved) susp=$($fin.Susp)"
  $mvTxt = if ($kind -eq "close") { "close" } else { "open" }
  T-Check "4b $name nothing moves at T (before earliest)" (-not $earlyBool) $evid
  if ($prep -eq "handkeep") {
    # The hand move left a live suspension: the transition is recorded in ::resolved but cancelled,
    # not executed (docs/cover-architecture.md, "cancel, not pause").
    $okCancel = ($relMove -eq "none") -and ($relRes -ne "none") -and ($fin.Pos -ne $want) -and $fin.Susp
    T-Check "4b $name $mvTxt is recorded but cancelled while suspended (cover stays put)" $okCancel $evid
  } else {
    $okAct = ($fin.Pos -eq $want) -and ($relMove -ne "none" -or $relRes -ne "none")
    T-Check "4b $name $mvTxt happens at the earliest time (final=$want)" $okAct $evid
  }
}

$plan = @(
  @("close-R1", "close", "stub"), @("close-R2", "close", "stub"),
  @("close-R3-handmoved-suspension-kept", "close", "handkeep"), @("close-R4-handmoved-suspension-cleared", "close", "hand"),
  @("open-R1", "open", "stub"), @("open-R2", "open", "stub"), @("open-R3-handmoved-suspension-cleared", "open", "hand")
)
T-Prep
foreach ($p in $plan) { if ($Only.Count -eq 0 -or $Only -contains $p[0]) { Run-Scenario $p[0] $p[1] $p[2] } }
HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_time" }
