# A1-A3: day target + shade bound -> 20, night -> 0, bound withdrawn -> 100   (cover.vslow, 16 s travel)
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
T-Prep; T-Place "cover.vslow" 100
$c = "cover.vslow"

# A1: day target 100 + shade bound max 20 -> resolved 20, cover moves to 20
HA-StubShade @{ $c = @{ min = 0; max = 20 } }          # bound only; no target yet (cover sits at 100 -> seed 100 -> clamp 20)
Start-Sleep 2
HA-StubDay @{ $c = 100 }
HA-Wait { (HA-Shared "$c::resolved") -eq 20 } 15 | Out-Null
T-Settle $c 40
T-Check "A1 day target 100 + bound max20 -> 20" (((HA-Shared "$c::resolved") -eq 20) -and ([math]::Abs((T-Pos $c) - 20) -le 5)) "resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c)"

# A2: night target 0 (newer) -> clamp(0, 0..20) = 0
HA-StubDay @{ $c = 0 }
HA-Wait { (HA-Shared "$c::resolved") -eq 0 } 15 | Out-Null
T-Settle $c 40
T-Check "A2 night target 0 -> 0" (((HA-Shared "$c::resolved") -eq 0) -and ((T-Pos $c) -le 5)) "resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c)"

# A3: day target again (bound still holds -> 20), then bound withdrawn -> 100
HA-StubDay @{ $c = 100 }
HA-Wait { (HA-Shared "$c::resolved") -eq 20 } 15 | Out-Null
T-Settle $c 40
$mid = "resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c)"
HA-StubShade @{} @{}                                    # withdraw: empty bounds, no target
HA-Wait { (HA-Shared "$c::resolved") -eq 100 } 15 | Out-Null
T-Settle $c 40
T-Check "A3 day target again -> 20 while bound holds" ($mid -like "resolved=20 *") $mid
T-Check "A3 bound withdrawn -> 100" (((HA-Shared "$c::resolved") -eq 100) -and ((T-Pos $c) -ge 95)) "resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c)"
$susp = HA-Shared "$c::suspension"
T-Check "A1-A3 no false suspension on vslow" ($null -eq $susp) "suspension=$susp"
T-Prep
