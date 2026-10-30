# Two overlapping moves from the SAME run token (same marker key) must not false-suspend.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
T-Prep; T-Place "cover.vslow" 100
$c = "cover.vslow"
HA-Move @{ $c = 0 } "same"
Start-Sleep 5
$mid = T-Cover $c
HA-Move @{ $c = 100 } "same"          # reverses mid-travel, same marker key
Start-Sleep 3
T-Settle $c 60
# The marker lives until stable_seconds after the last position change, noticed at the mover's 2 s
# poll — up to ~7 s after the cover stopped. Wait for it instead of a fixed sleep.
HA-Wait { -not (@(HA-KeyNames "shared") -like "$c::moving_*") } 20 1 | Out-Null
$names = @(HA-KeyNames "shared")
T-Check "overlap: no suspension written" (-not ($names | ? { $_ -like "$c::suspension" })) "mid=$mid final=$(T-Cover $c) keys=$($names -join ',')"
T-Check "overlap: cover ends at the second target (100)" ((T-Pos $c) -ge 95) "final=$(T-Cover $c)"
# Only this cover's markers: the sun instance may legitimately be moving the garage door (T-Prep drops its intent).
T-Check "overlap: marker cleaned up" (-not ($names | ? { $_ -like "$c::moving_*" })) "keys=$($names -join ',')"
T-Prep
