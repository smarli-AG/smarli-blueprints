# 7  Cover namespace (ha-packages 2026-11-10, cover_DayNight 3.2.0): the per-cover keys live in `cover`, not `shared`.
# - smarli_cover_namespace_migration moves old cover.* keys from `shared` to `cover` after a reload, drops the old
#   resolver fence, never overwrites a newer key in `cover`, and leaves intents in `shared`
# - before the migration ran, the resolver still reads an old `::resolved` in `shared`: no move after the update
# - smarli_cover_request removes the caller's old intent from `shared`
# - an automation updated from 3.1.3 reads its old intent from `shared`: the update does not re-publish or move
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"; $c2 = "cover.vslow"; $id = "cover_time_test"
function Log-Lines($since, $entity) {
  $u = "$HA_BASE/api/logbook/$($since.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))?entity=$entity"
  @(Invoke-RestMethod -Uri $u -Headers (HA-Headers) | Where-Object { $_.name -eq "smarli." } | ForEach-Object { $_.message })
}

T-Prep
HA-Apply
Start-Sleep 14   # the tracker GC runs 10 s after the reload; let it pass before seeding

Write-Host "`n=== 7-1 the migration moves cover keys, keeps intents, drops the fence"
$until = (HA-Now) + 600
HA-SetKey "shared" "$c::resolved" 37
HA-SetKey "shared" "$c::suspension" $until
HA-SetKey "shared" "$c2::resolved" 10
HA-SetKey "cover" "$c2::resolved" 90
HA-SetKey "shared" "global::resolve_fence" "old"
HA-SetKey "shared" "stub_day::intent" @{ targets = @{ $c = 37 }; bounds = @{}; priority = 10; ts = 1; suspension_duration = 0 }
HA-DelKey "cover" "$c::resolved"; HA-DelKey "cover" "$c::suspension"
Start-Sleep 1
HA-Call "automation" "reload"   # fires automation_reloaded
$moved = HA-Wait { -not (@(HA-KeyNames "shared") -like "cover.*") } 15 0.5
$sh = @(HA-KeyNames "shared")
T-Check "7-1 cover.* keys and the old fence are gone from shared" ($moved -and -not ($sh -contains "global::resolve_fence")) "shared: $($sh -join ',')"
T-Check "7-1 the keys arrive in cover with their values" (([int](HA-Key "cover" "$c::resolved") -eq 37) -and ([double](HA-Key "cover" "$c::suspension") -eq $until)) "resolved=$(HA-Key 'cover' "$c::resolved") suspension=$(HA-Key 'cover' "$c::suspension")"
T-Check "7-1 a key that already exists in cover is kept, not overwritten" ([int](HA-Key "cover" "$c2::resolved") -eq 90) "$c2 resolved=$(HA-Key 'cover' "$c2::resolved")"
T-Check "7-1 intents stay in shared" ($sh -contains "stub_day::intent") "shared: $($sh -join ',')"
HA-DelKey "shared" "stub_day::intent"; HA-DelKey "cover" "$c2::resolved"; HA-ClearSuspensions

Write-Host "`n=== 7-2 before the migration, an old ::resolved in shared still counts: no move"
T-Place $c 100
HA-DelKey "cover" "$c::resolved"; HA-SetKey "shared" "$c::resolved" 100
Start-Sleep 1
$t0 = Get-Date
HA-StubDay @{ $c = 100 }
$m = $null
HA-Wait { $script:m = Log-Lines $t0 $c | Where-Object { $_ -like "not moved*already decided as 100*" -or $_ -like "moving to*" } | Select-Object -First 1; $null -ne $script:m } 15 1 | Out-Null
T-Check "7-2 the resolver reads the old key and does not command the cover" ($m -like "not moved*") "line: $m"
HA-DelKey "shared" "$c::resolved"; HA-DelKey "shared" "stub_day::intent"; HA-ClearSuspensions

Write-Host "`n=== 7-3 smarli_cover_request removes the caller's old intent from shared"
$p = @{ targets = @{}; bounds = @{}; priority = 10; ts = (HA-Now); suspension_duration = 0; watches = $false }
HA-SetKey "shared" "ns_req::intent" $p
Start-Sleep 1
HA-Call "script" "smarli_cover_request" @{ owner = "ns_req"; intent = $p }
Start-Sleep 3
T-Check "7-3 the intent is in cover and no longer in shared" (($null -ne (HA-Key "cover" "ns_req::intent")) -and ($null -eq (HA-Key "shared" "ns_req::intent"))) "cover=$($null -ne (HA-Key 'cover' 'ns_req::intent')) shared=$($null -ne (HA-Key 'shared' 'ns_req::intent'))"
HA-DelKey "cover" "ns_req::intent"

Write-Host "`n=== 7-4 an automation updated from 3.1.3 reads its old intent from shared and does not move"
T-Prep
T-Place $c 100
HA-Apply -Time @{ time_close_workday_tomorrow = (HA-At -60).Str; time_close_non_workday_tomorrow = (HA-At -60).Str }
HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_time" }
HA-Call "automation" "reload"; Start-Sleep 5
HA-Wait { (T-Target $id $c) -eq 0 } 25 | Out-Null; T-Settle $c 30
$i = HA-Key "cover" "$id::intent"
# What 3.1.3 left behind: the same intent, in shared only.
HA-SetKey "shared" "$id::intent" $i; HA-DelKey "cover" "$id::intent"
Start-Sleep 70   # at least one heartbeat
$back = HA-Key "cover" "$id::intent"
T-Check "7-4 no re-publish: the intent is read from shared, the decision is unchanged" (($null -ne $i) -and ($null -eq $back) -and ((T-Pos $c) -le 5)) "intent before=$($null -ne $i) cover copy after=$($null -ne $back) cover=$(T-Cover $c)"
HA-DelKey "shared" "$id::intent"
T-Prep
