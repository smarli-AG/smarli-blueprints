# The blueprint publishes an intent (targets/bounds/priority/ts/suspension_duration/fingerprint), no legacy record.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
T-Prep
T-Place "cover.vfast" 0                       # cover closed, so an open decision has to move it
HA-Apply                                      # time instance: open time long past, close 23:59 -> wants open
HA-Call "automation" "turn_on" @{ entity_id = "automation.covers_day_night_time" }
Start-Sleep 1
HA-Call "automation" "reload"                 # automation_reloaded -> heartbeat evaluation
$ok = HA-Wait { $null -ne (T-Intent "cover_time_test") } 20
$i = T-Intent "cover_time_test"
T-Check "daynight: intent published under <automation id>::intent" $ok "intent=$($i | ConvertTo-Json -Compress -Depth 5)"
T-Check "daynight: target is the numeric position 100 for the configured cover" (($i.targets.'cover.vfast' -eq 100) -and ($i.targets.'cover.vfast' -is [int])) "targets=$($i.targets | ConvertTo-Json -Compress)"
T-Check "daynight: no bound, priority 10, suspension 1800 s" ((@($i.bounds.PSObject.Properties).Count -eq 0) -and ($i.priority -eq 10) -and ($i.suspension_duration -eq 1800)) "bounds=$($i.bounds | ConvertTo-Json -Compress) priority=$($i.priority) susp=$($i.suspension_duration)"
T-Check "daynight: intent carries fingerprint fp1:<md5>" ($i.fingerprint -match '^fp1:[0-9a-f]{32}$') "fingerprint=$($i.fingerprint)"
HA-Wait { (HA-Shared "cover.vfast::resolved") -eq 100 } 15 | Out-Null
T-Settle "cover.vfast" 30
T-Check "daynight: resolver commanded the cover (closed -> open)" (((HA-Shared "cover.vfast::resolved") -eq 100) -and ((T-Pos "cover.vfast") -ge 95)) "resolved=$(HA-Shared 'cover.vfast::resolved') cover=$(T-Cover 'cover.vfast')"
$cdn = @(HA-KeyNames "cover_day_night")
$sh = @(HA-KeyNames "shared")
T-Check "daynight: no legacy per-instance record (last_commanded/last_position/automation_in_progress)" (-not (($cdn + $sh) | ? { $_ -match "last_commanded|last_position|automation_in_progress|suspensions$" })) "cover_day_night=$($cdn -join ',') shared=$($sh -join ',')"
T-Check "daynight: no suspension from own move" (-not ($sh | ? { $_ -like "*::suspension" })) "shared=$($sh -join ',')"
HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_time" }
