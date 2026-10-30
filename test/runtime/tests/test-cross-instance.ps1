# Two moves from DIFFERENT runs on the same cover must not false-suspend (superseded run drops its marker silently).
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
T-Prep; T-Place "cover.vslow" 100
$c = "cover.vslow"
HA-Move @{ $c = 0 } "instA"
Start-Sleep 5
$twoMarkers = $null
HA-Move @{ $c = 100 } "instB"
Start-Sleep 2
$names = @(HA-KeyNames "shared")
$both = ($names -contains "$c::moving_instA") -or ($names -contains "$c::moving_instB")
T-Settle $c 60
Start-Sleep 8
$names = @(HA-KeyNames "shared")
T-Check "cross-instance: no suspension written" (-not ($names | ? { $_ -like "$c::suspension" })) "final=$(T-Cover $c) keys=$($names -join ',')"
T-Check "cross-instance: cover ends at the newer run's target (100)" ((T-Pos $c) -ge 95) "final=$(T-Cover $c)"
T-Check "cross-instance: both markers cleaned up" (-not ($names | ? { $_ -like "$c::moving_*" })) "keys=$($names -join ',')"
T-Prep
