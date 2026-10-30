# A7: a suspension spanning a transition CANCELS it (no deferral, no catch-up on expiry); the next transition runs.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"
T-Prep; T-Place $c 100

# 1. suspended for 2 min, transition to 0 arrives inside it
HA-SetKey "shared" "$c::suspension" ((HA-Now) + 120)
HA-StubDay @{ $c = 0 }
$rec = HA-Wait { (HA-Shared "$c::resolved") -eq 0 } 15
Start-Sleep 8
$names = @(HA-KeyNames "shared")
T-Check "A7 transition inside suspension: recorded in ::resolved but cover not commanded" ($rec -and ((T-Pos $c) -ge 95) -and -not ($names | ? { $_ -like "$c::moving_*" })) "resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c) markers=$(($names | ? { $_ -like '*::moving_*' }) -join ',')"

# 2. suspension expires; the same intent is published again (unchanged) -> still no catch-up
HA-SetKey "shared" "$c::suspension" ((HA-Now) - 5)
HA-StubDay @{ $c = 0 }
Start-Sleep 10
T-Check "A7 after expiry: cancelled transition is not deferred / re-asserted" ((T-Pos $c) -ge 95) "cover=$(T-Cover $c) resolved=$(HA-Shared "$c::resolved")"

# 3. next transition (open) then close runs normally
HA-StubDay @{ $c = 100 }
Start-Sleep 5; T-Settle $c 20
HA-StubDay @{ $c = 0 }
HA-Wait { (T-Pos $c) -le 5 } 25 | Out-Null
T-Settle $c 20
T-Check "A7 next transition after expiry executes" (((T-Pos $c) -le 5) -and ((HA-Shared "$c::resolved") -eq 0)) "cover=$(T-Cover $c) resolved=$(HA-Shared "$c::resolved")"
T-Check "A7 no new suspension from own moves" ($null -eq (HA-Shared "$c::suspension") -or (HA-Shared "$c::suspension") -lt (HA-Now)) "suspension=$(HA-Shared "$c::suspension")"
T-Prep
