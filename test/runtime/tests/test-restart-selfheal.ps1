# Restart self-heal: (1) a stale-but-consistent published intent (current fingerprint, target no longer matching the
# schedule) and (2) the first-run -1 sentinel (never-published intent + a persisted stabilizer timestamp) are both caught
# up on `homeassistant: start`.  Restarts the container.
# Real per-minute heartbeat only (-RealHeartbeat): a 5 s heartbeat would heal the stale state before the restart.
# The sun is moved to "night" so the brightness close is armed; time zone and location survive the restart.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$f = "cover.vfast"; $b = "cover.vbright"

try {
T-SunPhase "night"
T-Prep; HA-Apply -RealHeartbeat
HA-Call "input_number" "set_value" @{ entity_id = "input_number.test_lux"; value = 10 }
HA-Call "automation" "turn_on" @{ entity_id = @("automation.covers_day_night_time", "automation.covers_day_night_brightness") }
HA-Call "automation" "reload"
HA-Wait { $null -ne (T-Intent "cover_time_test") } 20 | Out-Null
$fp = (T-Intent "cover_time_test").fingerprint
T-Place $f 0; T-Place $b 100
# align to :05 of the minute so no heartbeat can heal the stale state before the shutdown snapshot is taken
$sec = [int](HA-Template "{{ now().second }}"); if ($sec -gt 40 -or $sec -lt 3) { Start-Sleep ((65 - $sec) % 60 + 3) }

# (1) stale-but-consistent: current fingerprint, target 0, while the schedule wants 100
$oldTs = (HA-Now) - 3600
HA-SetKey "shared" "cover_time_test::intent" @{ targets = @{ $f = 0 }; bounds = @{}; priority = 10; ts = $oldTs; suspension_duration = 1800.0; fingerprint = $fp }
HA-SetKey "shared" "$f::resolved" 0
# (2) sentinel: no intent for the brightness instance, but a persisted dark_since older than the 20 s stabilizer
HA-DelKey "shared" "cover_brightness_test::intent"
HA-DelKey "shared" "$b::resolved"
HA-SetKey "cover_day_night" "cover_brightness_test::dark_since" ((HA-Now) - 100)
Start-Sleep 2
$pre = "pre-restart: time intent target=$(T-Target 'cover_time_test' $f) ts=$([math]::Round($oldTs)) vfast=$(T-Cover $f); brightness intent=$(if ($null -eq (T-Intent 'cover_brightness_test')) {'none'} else {'present'}) vbright=$(T-Cover $b) lux=$(HA-StateStr 'sensor.test_lux')"
Write-Host $pre
$t0 = Get-Date
docker restart $HA_CONTAINER | Out-Null
Wait-HA
$tUp = [math]::Round(((Get-Date) - $t0).TotalSeconds)
HA-Wait { ((T-Target "cover_time_test" $f) -eq 100) -and ($null -ne (T-Intent "cover_brightness_test")) } 90 2 | Out-Null
HA-Wait { ((T-Pos $f) -ge 95) -and ((T-Pos $b) -le 5) } 60 2 | Out-Null
T-Settle $f 30; T-Settle $b 30
$ti = T-Intent "cover_time_test"; $bi = T-Intent "cover_brightness_test"
T-Check "restart: stale intent (target 0, current fp) re-published to the schedule's 100 and cover moved" (((T-Target "cover_time_test" $f) -eq 100) -and ($ti.ts -gt $oldTs) -and ((HA-Shared "$f::resolved") -eq 100) -and ((T-Pos $f) -ge 95)) "api up after ${tUp}s; intent target=$(T-Target 'cover_time_test' $f) ts+$([math]::Round($ti.ts - $oldTs))s resolved=$(HA-Shared "$f::resolved") vfast=$(T-Cover $f) | $pre"
T-Check "restart: -1 sentinel (no intent + persisted dark_since) publishes the close and moves the cover" (($null -ne $bi) -and ((T-Target "cover_brightness_test" $b) -eq 0) -and ((T-Pos $b) -le 5)) "intent target=$(T-Target 'cover_brightness_test' $b) resolved=$(HA-Shared "$b::resolved") vbright=$(T-Cover $b) dark_since kept=$(HA-Key 'cover_day_night' 'cover_brightness_test::dark_since')"
T-Check "restart: no false suspension from the heal moves" (-not (@(HA-KeyNames "shared") | ? { $_ -like "*::suspension" })) "keys=$((@(HA-KeyNames 'shared')) -join ',')"
} finally {
  # leave instances off, lux back to 100, the fast heartbeat back in, the sun at home
  HA-Call "automation" "turn_off" @{ entity_id = @("automation.covers_day_night_time", "automation.covers_day_night_brightness") }
  HA-Call "input_number" "set_value" @{ entity_id = "input_number.test_lux"; value = 100 }
  HA-DelKey "cover_day_night" "cover_brightness_test::dark_since"
  HA-Apply
  T-Prep
  T-SunHome
}
