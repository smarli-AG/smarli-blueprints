# 4a  settings fingerprint (cover_DayNight 3.1.2, "fp1:" version prefix). Time-method instance on cover.vfast.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"; $id = "cover_time_test"
function Reload { HA-Call "automation" "reload"; Start-Sleep 5 }
function Close-At($m) { @{ time_close_workday_tomorrow = $m; time_close_non_workday_tomorrow = $m } }
function IntentTs { $i = T-Intent $id; if ($null -eq $i) { $null } else { [double]$i.ts } }
function Wait-Newer($old, $sec = 20) { HA-Wait { $t = IntentTs; ($null -ne $t) -and ($null -eq $old -or $t -gt $old) } $sec 1 }

T-Prep
$C1 = (HA-At -60).Str; $C2 = (HA-At -120).Str; $C3 = (HA-At -180).Str
T-Place $c 100
HA-Apply -Time (Close-At $C1)
HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_time" }
Reload
Wait-Newer $null | Out-Null
HA-Wait { (T-Target $id $c) -eq 0 } 20 | Out-Null; T-Settle $c 30
$i = T-Intent $id; $F1 = $i.fingerprint
T-Check "4a-1 published intent carries fingerprint fp1:<md5>" (($F1 -match '^fp1:[0-9a-f]{32}$') -and ($i.targets.$c -eq 0)) "fingerprint=$F1 target=$($i.targets.$c) cover=$(T-Cover $c)"

# 4a-2: stored intent targets 0, something else opens the cover (stub contributor, resolved=100), then a schedule edit
HA-StubDay @{ $c = 100 }
HA-Wait { (HA-Shared "$c::resolved") -eq 100 } 15 | Out-Null; T-Settle $c 30
$pre = "before edit: instance intent target=$(T-Target $id $c) resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c)"
$ts0 = IntentTs
HA-Apply -Time (Close-At $C2); Reload
$re = Wait-Newer $ts0 25
HA-Wait { (T-Pos $c) -le 5 } 25 | Out-Null; T-Settle $c 30
$i = T-Intent $id; $F2 = $i.fingerprint
T-Check "4a-2 schedule edit (same fp1 version) re-publishes and the cover is commanded to 0" ($re -and ($F2 -ne $F1) -and ((T-Pos $c) -le 5) -and ((HA-Shared "$c::resolved") -eq 0)) "$pre | after: republished=$re ts+$([math]::Round($i.ts-$ts0,1))s fp $F1 -> $F2 resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c)"

# 4a-3: cover moved by a person-path outside smarli (suspension cleared), resolved stays 0, then a schedule edit
HA-DelKey "shared" "stub_day::intent"
HA-HandMove $c 100
$pre = "before edit: resolved=$(HA-Shared "$c::resolved") cover=$(T-Cover $c) susp=$(HA-Shared "$c::suspension")"
$ts0 = IntentTs
HA-Apply -Time (Close-At $C3); Reload
$re = Wait-Newer $ts0 25
HA-Wait { (T-Pos $c) -le 5 } 25 | Out-Null; T-Settle $c 30
$i = T-Intent $id; $F3 = $i.fingerprint
T-Check "4a-3 hand-opened cover (resolved 0) + schedule edit -> republished and commanded closed" ($re -and ($F3 -ne $F2) -and ((T-Pos $c) -le 5)) "$pre | after: republished=$re fp $F2 -> $F3 cover=$(T-Cover $c) resolved=$(HA-Shared "$c::resolved")"

# 4a-4: non-schedule edit must not change the fingerprint or republish
$ts0 = IntentTs
HA-Apply -Time ((Close-At $C3) + @{ suspension_duration = "00:10:00" }); Reload
Start-Sleep 3
$i = T-Intent $id
T-Check "4a-4 non-schedule edit (suspension_duration) keeps fingerprint, no republish" (($i.fingerprint -eq $F3) -and ([double]$i.ts -eq $ts0)) "fingerprint $F3 -> $($i.fingerprint); ts unchanged=$([double]$i.ts -eq $ts0); intent.suspension_duration=$($i.suspension_duration) (setting is now 600 s)"
Start-Sleep 20     # >= 3 heartbeats (5 s)
$i = T-Intent $id
T-Check "4a-4b ...and still no republish after a natural heartbeat (observation: intent.suspension_duration stays stale)" ([double]$i.ts -eq $ts0) "intent.suspension_duration=$($i.suspension_duration) after heartbeat; ts unchanged=$([double]$i.ts -eq $ts0)"
HA-Apply -Time (Close-At $C3); Reload     # back to 00:30:00

function Seed($fp, $target) {
  $v = @{ targets = @{ $c = $target }; bounds = @{}; priority = 10; ts = ((HA-Now) - 3600); suspension_duration = 1800.0 }
  if ($null -ne $fp) { $v.fingerprint = $fp }
  HA-SetKey "shared" "$id::intent" $v; Start-Sleep 2
  [double]$v.ts
}
# 4a-5: legacy intent without fingerprint, schedule wants 0 and intent says 0 -> NO reset
$old = Seed $null 0; Reload; Start-Sleep 2
$i = T-Intent $id
T-Check "4a-5 legacy intent (no fingerprint, target = schedule) -> no re-publish" ([double]$i.ts -eq $old) "ts unchanged=$([double]$i.ts -eq $old) fingerprint=$($i.fingerprint)"
# 4a-6: fp0: prefix (other version) -> NO reset
$old = Seed "fp0:00000000000000000000000000000000" 0; Reload; Start-Sleep 2
$i = T-Intent $id
T-Check "4a-6 fp0: intent (other version, target = schedule) -> no re-publish" ([double]$i.ts -eq $old) "ts unchanged=$([double]$i.ts -eq $old) fingerprint=$($i.fingerprint)"
# 4a-7: same version, other hash -> reset: exactly one republish
$old = Seed "fp1:00000000000000000000000000000000" 0; Reload
$re = Wait-Newer $old 15
$i = T-Intent $id; $ts1 = [double]$i.ts
T-Check "4a-7 fp1: with a different hash -> one re-publish with the current fingerprint" ($re -and ($i.fingerprint -eq $F3)) "republished=$re fingerprint=$($i.fingerprint) (expected $F3)"
Reload; Start-Sleep 20     # >= 3 heartbeats (5 s)
$i = T-Intent $id
T-Check "4a-7b ...and no second re-publish (reload + natural heartbeat)" ([double]$i.ts -eq $ts1) "ts unchanged=$([double]$i.ts -eq $ts1)"
# 4a-8: legacy intent whose target differs from the schedule -> ordinary transition, fingerprint adopted
$old = Seed $null 100; Reload
$re = Wait-Newer $old 15
$i = T-Intent $id
T-Check "4a-8 legacy intent with a stale target -> normal transition, publishes 0 with fingerprint" ($re -and ($i.targets.$c -eq 0) -and ($i.fingerprint -eq $F3)) "republished=$re target=$($i.targets.$c) fingerprint=$($i.fingerprint)"
HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_time" }
T-Prep
