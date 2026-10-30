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
Start-Sleep 5
$names = @(HA-KeyNames "shared")
T-Check "overlap: no suspension written" (-not ($names | ? { $_ -like "$c::suspension" })) "mid=$mid final=$(T-Cover $c) keys=$($names -join ',')"
T-Check "overlap: cover ends at the second target (100)" ((T-Pos $c) -ge 95) "final=$(T-Cover $c)"
# Only this cover's markers: the sun instance may legitimately be moving the garage door (T-Prep drops its intent).
T-Check "overlap: marker cleaned up" (-not ($names | ? { $_ -like "$c::moving_*" })) "keys=$($names -join ',')"
T-Prep
