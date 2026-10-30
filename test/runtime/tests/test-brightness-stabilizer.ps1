# Brightness method: bright_since/dark_since written only on threshold crossings (never rewritten while steady);
# schedule_wants_* waits for the stabilizer (20 s in this instance) before acting. sensor.test_lux <- input_number.test_lux.
# Closing is only armed from (sunset - 60 min) on; opening only between (sunrise - 60 min) and (sunset - 60 min),
# so the test moves the sun to "night" first (T-SunPhase) and back at the end.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vbright"; $id = "cover_brightness_test"
function Set-Lux($v) { HA-Call "input_number" "set_value" @{ entity_id = "input_number.test_lux"; value = $v }; Start-Sleep 1 }
function Tick { HA-Call "automation" "reload"; Start-Sleep 4 }       # automation_reloaded = heartbeat trigger
function Ck($k) { HA-Key "cover_day_night" "$id::$k" }

try {
T-SunPhase "night"
T-Prep; HA-Apply
foreach ($k in "bright_since", "dark_since") { HA-DelKey "cover_day_night" "$id::$k" }
Set-Lux 100
T-Place $c 100
HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_brightness" }
Tick

T-Check "brightness: between thresholds -> no since-keys" (($null -eq (Ck "bright_since")) -and ($null -eq (Ck "dark_since"))) "bright_since=$(Ck 'bright_since') dark_since=$(Ck 'dark_since')"

Set-Lux 10; Tick
$d0 = Ck "dark_since"; $tDark = Get-Date
Start-Sleep 5; Tick
$d1 = Ck "dark_since"
T-Check "brightness: dark_since written on crossing, not rewritten while steady" (($null -ne $d0) -and ($d0 -eq $d1) -and ($null -eq (Ck "bright_since"))) "first=$d0 after-tick=$d1"
T-Check "brightness: before the stabilizer elapses nothing is published/commanded" (($null -eq (T-Intent $id)) -and ((T-Pos $c) -ge 95)) "intent=$(if ($null -eq (T-Intent $id)) {'none'} else {'present'}) cover=$(T-Cover $c) age=$([math]::Round(((Get-Date) - $tDark).TotalSeconds))s"

$wait = 24 - ((Get-Date) - $tDark).TotalSeconds; if ($wait -gt 0) { Start-Sleep $wait }
Tick
HA-Wait { (T-Target $id $c) -eq 0 } 15 | Out-Null
T-Settle $c 30
T-Check "brightness: after the stabilizer the close is published and executed" (((T-Target $id $c) -eq 0) -and ((HA-Shared "$c::resolved") -eq 0) -and ((T-Pos $c) -le 5)) "target=$(T-Target $id $c) resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c) fp=$((T-Intent $id).fingerprint)"
$ts0 = (T-Intent $id).ts

Set-Lux 1000; Tick
$b0 = Ck "bright_since"
T-Check "brightness: bright crossing writes bright_since and clears dark_since" (($null -ne $b0) -and ($null -eq (Ck "dark_since"))) "bright_since=$b0 dark_since=$(Ck 'dark_since')"
Start-Sleep 22; Tick
$ts1 = (T-Intent $id).ts
$armedNote = "intent ts unchanged=$($ts0 -eq $ts1) cover=$(T-Cover $c)"
T-Check "brightness: bright after the stabilizer does not retract at night (open window not armed)" (($ts0 -eq $ts1) -and ((T-Pos $c) -le 5)) $armedNote

Set-Lux 100; Tick
T-Check "brightness: back between thresholds clears the since-keys" (($null -eq (Ck "bright_since")) -and ($null -eq (Ck "dark_since"))) "bright_since=$(Ck 'bright_since') dark_since=$(Ck 'dark_since')"

} finally {
  HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_brightness" }
  T-Prep
  T-SunHome
}
