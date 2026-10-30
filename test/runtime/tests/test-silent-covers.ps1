# Covers that never report opening/closing (cover.silent, shaped after a Zigbee S-ZB-COV1 via Z2M):
# an automated move must finish without a suspension in every report pattern (normal with gaps up
# to 3.5 s, tilt-first, jump-type, slow first report), and a stop mid-travel must still suspend.
# The move goes through a stub intent and the resolver: a bare mover call has no intent behind it,
# and smarli_cover_suspend treats "no intent" as "suspension opted out".
param([string[]]$Only = @())
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.silent"
function Run($k) { $Only.Count -eq 0 -or $Only -contains $k }

function Start-At([int]$pos) {
  T-Prep
  HA-Call "script" "turn_off" @{ entity_id = "script.silent_motor" }
  HA-Call "input_select" "select_option" @{ entity_id = "input_select.silent_mode"; option = "normal" }
  HA-Call "input_number" "set_value" @{ entity_id = "input_number.silent_pos"; value = $pos }
  HA-Call "input_number" "set_value" @{ entity_id = "input_number.silent_tilt"; value = 0 }
  Start-Sleep 2; HA-ClearSuspensions
}
function Mode($m) { HA-Call "input_select" "select_option" @{ entity_id = "input_select.silent_mode"; option = $m } }
# Poll every second until the mover released the cover and the motor stopped (or $timeout).
# -Churn bumps input_number.silent_churn on every poll: the cover's icon attribute keeps changing.
function Watch-Silent([int]$timeout = 60, [switch]$Churn) {
  $t0 = Get-Date; $r = @{ Susp = $false; MarkerSeen = $false; ReleasedAt = $null }; $n = 0
  while (((Get-Date) - $t0).TotalSeconds -lt $timeout) {
    if ($Churn) { $n++; HA-Call "input_number" "set_value" @{ entity_id = "input_number.silent_churn"; value = $n } }
    $names = @(HA-KeyNames "shared")
    $marker = [bool]($names -like "$c::moving_*")
    if ($marker) { $r.MarkerSeen = $true }
    if ($names -contains "$c::suspension") { $r.Susp = $true }
    if ($r.MarkerSeen -and -not $marker -and $null -eq $r.ReleasedAt) { $r.ReleasedAt = [math]::Round(((Get-Date) - $t0).TotalSeconds) }
    if ($null -ne $r.ReleasedAt -and (HA-StateStr "script.silent_motor") -eq "off") { break }
    Start-Sleep 1
  }
  Start-Sleep 3
  if (@(HA-KeyNames "shared") -contains "$c::suspension") { $r.Susp = $true }
  $r.Pos = T-Pos $c; $r.Tilt = (HA-State $c).attributes.current_tilt_position; $r.State = HA-StateStr $c
  $r
}
function Clean-Move($name, $mode, [int]$from, [int]$to, [switch]$Churn, [int]$releasedBy = 60) {
  Write-Host "`n=== $name"
  Start-At $from; Mode $mode
  HA-StubDay @{ $c = $to }
  $w = Watch-Silent 60 -Churn:$Churn
  $ok = (-not $w.Susp) -and $w.MarkerSeen -and ($null -ne $w.ReleasedAt) -and ($w.ReleasedAt -le $releasedBy) -and ([math]::Abs($w.Pos - $to) -le 5)
  T-Check "silent: $name finishes without suspension" $ok "released at +$($w.ReleasedAt)s (limit ${releasedBy}s); susp=$($w.Susp) final=$($w.State)/$($w.Pos) tilt=$($w.Tilt)"
}
# A person taps the wall switch right after an automated close: position 0 -> 2. Simulated by
# setting the position directly; cover.silent is not watched by manual_check, so any suspension
# here comes from the settle loop alone.
function Tap-After-Close($name, [int]$waitAfterArrival) {
  Write-Host "`n=== $name"
  Start-At 100; Mode "normal"
  HA-StubDay @{ $c = 0 }
  HA-Wait { (T-Pos $c) -eq 0 } 40 0.5 | Out-Null
  $tArr = Get-Date
  Start-Sleep $waitAfterArrival
  $markerAtTap = [bool](@(HA-KeyNames "shared") -like "$c::moving_*")
  HA-Call "input_number" "set_value" @{ entity_id = "input_number.silent_pos"; value = 2 }
  $susp = HA-Wait { @(HA-KeyNames "shared") -contains "$c::suspension" } 15 1
  $markerLeft = [bool](@(HA-KeyNames "shared") -like "$c::moving_*")
  [pscustomobject]@{ MarkerAtTap = $markerAtTap; Susp = $susp; MarkerLeft = $markerLeft; Pos = (T-Pos $c); After = [math]::Round(((Get-Date) - $tArr).TotalSeconds) }
}

if (Run "normal")    { Clean-Move "normal close, 1 s reports, 3.5 s start gap, 2.3 s interior gaps" "normal" 100 0 }
if (Run "tiltfirst") { Clean-Move "tilt-first open, 8 s of tilt-only reports before the position moves" "tiltfirst" 0 100 }
if (Run "jump")      { Clean-Move "jump-type close, position at target at once, then silence" "jump" 100 0 }
if (Run "slowstart") { Clean-Move "slow start, first report 7 s after the command" "slowstart" 0 100 }
if (Run "overshoot") { Clean-Move "overshoot at a mid target: 50 -> 47 -> 50 settles inside the tolerance" "overshoot" 100 50 }
# Only position and tilt count as movement: an icon attribute changing every second must not keep
# the cover "moving" until settle_timeout (180 s). A normal close takes ~22 s plus the 5 s window.
if (Run "churn")     { Clean-Move "idle attribute churn (icon changes every second)" "normal" 100 0 -Churn -releasedBy 40 }

if (Run "tapwithin") {
  $r = Tap-After-Close "wall-switch tap 0 -> 2 % within the quiet window after an automated close" 3
  T-Check "silent: a tap away from the end stop inside the window suspends (end-stop rule)" ($r.MarkerAtTap -and $r.Susp -and -not $r.MarkerLeft) "marker live at tap=$($r.MarkerAtTap); suspension=$($r.Susp); marker left=$($r.MarkerLeft); pos=$($r.Pos)"
}
if (Run "reopen") {
  # smarli. itself moves the cover away from the end stop: a newer run opens it right after the close
  # arrived. The older run must not read that as a tap, also after the newer run's marker is gone.
  Write-Host "`n=== smarli. reopens right after a close reached the end stop"
  Start-At 100; Mode "normal"
  HA-StubDay @{ $c = 0 }
  HA-Wait { (T-Pos $c) -eq 0 } 40 0.5 | Out-Null
  Start-Sleep 3
  HA-StubDay @{ $c = 100 }
  $w = Watch-Silent 90
  T-Check "silent: a newer smarli. run moving the cover off the end stop does not suspend" ((-not $w.Susp) -and ($w.Pos -ge 95)) "susp=$($w.Susp) final=$($w.State)/$($w.Pos)"
}
if (Run "tapafter") {
  $r = Tap-After-Close "wall-switch tap 0 -> 2 % after the mover released the cover" 10
  # The mover is done: the tap is layer 2's job in production (blueprint state trigger, closed -> open
  # without a marker); this rig does not watch cover.silent, so no suspension may come from the mover.
  T-Check "silent: after release the mover leaves a tap to layer 2 (no marker, no mover suspension)" ((-not $r.MarkerAtTap) -and (-not $r.Susp)) "marker live at tap=$($r.MarkerAtTap); suspension=$($r.Susp); pos=$($r.Pos)"
}

if (Run "stop") {
  Write-Host "`n=== stop mid-travel"
  Start-At 100; Mode "normal"
  HA-StubDay @{ $c = 0 }
  HA-Wait { (T-Pos $c) -le 70 } 30 1 | Out-Null
  HA-Call "script" "turn_off" @{ entity_id = "script.silent_motor" }     # the "wall switch" stops the motor
  $stopAt = T-Pos $c
  $susp = HA-Wait { @(HA-KeyNames "shared") -contains "$c::suspension" } 30 1
  T-Check "silent: a stop mid-travel still suspends (layer 3)" ($susp -and ((T-Pos $c) -gt 5)) "stopped at $stopAt; suspension=$susp final=$(T-Cover $c)"
}

HA-Call "script" "turn_off" @{ entity_id = "script.silent_motor" }
T-Prep
