# Load test: how the cover family behaves with many automations and covers on one instance.
# Not part of run-short/run-long: it adds covers, restarts the container twice and takes ~10 minutes.
#
#   .\load-test.ps1                  # 40 automations, 30 covers
#   .\load-test.ps1 -Autos 60        # past the queue limit of 50
#
# Each automation is a time-method cover_DayNight instance with the real per-minute heartbeat and 3
# covers; each cover is named by Autos*3/Covers automations. Four phases:
#   reload  all automations publish their first intent at once (automation_reloaded)
#   idle    heartbeats only, nothing to do: run time of a gated heartbeat, CPU at second 0
#   phase   all automations reach the extend time in the same minute
#   hand    one person's command to every cover at once: command check + one manual check per
#           cover and watching automation
# Measured: peak runs of the resolver / manual check / suspend scripts (queue limit 50), HA's
# "exceeded" warnings, logbook lines, tracker size, covers that did not reach their target.
param([int]$Autos = 40, [int]$Covers = 30, [switch]$KeepCovers)
. "$PSScriptRoot\lib\ha.ps1"; . "$PSScriptRoot\lib\lib-test.ps1"
$cfg = "$HA_STATE\config"
$names = 1..$Covers | ForEach-Object { "vload{0:D2}" -f $_ }
$coverIds = $names | ForEach-Object { "cover.$_" }

function Restart-Rig {
  docker restart $HA_CONTAINER 2>&1 | Out-Null
  Start-Sleep 10; Wait-HA
}
# Peak of the scripts' `current` attribute (runs active or queued) while $seconds pass.
function Watch-Runs([int]$seconds) {
  $peak = @{ resolve = 0; manual_check = 0; suspend = 0 }
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $end) {
    foreach ($k in @($peak.Keys)) {
      try { $c = [int](HA-State "script.smarli_cover_$k").attributes.current } catch { $c = 0 }
      if ($c -gt $peak[$k]) { $peak[$k] = $c }
    }
  }
  $peak
}
function Exceeded-Since([datetime]$t) {
  $since = [int]((Get-Date) - $t).TotalSeconds + 5
  @(docker logs --since "${since}s" $HA_CONTAINER 2>&1 | Select-String -SimpleMatch "exceeded" | ForEach-Object { "$_" })
}
function Smarli-Lines([datetime]$t) {
  $u = "$HA_BASE/api/logbook/$($t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
  @(Invoke-RestMethod -Uri $u -Headers (HA-Headers) | Where-Object { $_.name -eq "smarli." })
}
function Tracker-Bytes {
  $a = (HA-State "sensor.smarli_automation_tracker").attributes
  [Text.Encoding]::UTF8.GetByteCount(($a | ConvertTo-Json -Depth 10 -Compress))
}
function Report($phase, $t0, $peak) {
  $lines = Smarli-Lines $t0
  $ex = Exceeded-Since $t0
  Write-Host ("  peak runs: resolve {0} | manual_check {1} | suspend {2}   (limit 50)" -f $peak.resolve, $peak.manual_check, $peak.suspend)
  Write-Host ("  smarli. logbook lines: {0}  ({1})" -f $lines.Count, (($lines | Group-Object { ($_.message -split ' ')[0..1] -join ' ' } | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '))
  Write-Host ("  'exceeded' warnings in the HA log: {0}" -f $ex.Count)
  $ex | Select-Object -First 3 | ForEach-Object { Write-Host "    $($_.Substring(0, [Math]::Min(200, $_.Length)))" }
  Write-Host ("  tracker attributes: {0} bytes" -f (Tracker-Bytes))
}

# --- setup ------------------------------------------------------------------------------------
Write-Host "== Setup: $Covers covers, $Autos automations"
$virtual = "$cfg\virtual.yaml"
if (-not (Test-Path "$virtual.load-backup")) { Copy-Item $virtual "$virtual.load-backup" }
$extra = ($names | ForEach-Object { "  ${_}:`n    - platform: cover`n      name: $_`n      class: shutter`n      initial_value: 'open'`n      open_close_duration: 6`n      open_close_tick: 1" }) -join "`n"
$base = (Get-Content "$virtual.load-backup" -Raw).TrimEnd()
[IO.File]::WriteAllText($virtual, ($base + "`n" + $extra + "`n").Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
Restart-Rig
$missing = @($coverIds | Where-Object { (HA-StateStr $_) -in @("missing", "unavailable") })
if ($missing.Count -gt 0) { throw "covers not created: $($missing -join ', ')" }

function Load-Yaml([string]$closeAt) {
  $sb = New-Object Text.StringBuilder
  for ($i = 0; $i -lt $Autos; $i++) {
    $mine = @($coverIds[$i % $Covers], $coverIds[($i + 10) % $Covers], $coverIds[($i + 20) % $Covers]) | Select-Object -Unique
    $in = Get-TimeDefaults
    $in.cover_entity = $mine
    $in.custom_closing_triggers = @()
    $in.time_close_workday_tomorrow = $closeAt; $in.time_close_non_workday_tomorrow = $closeAt
    [void]$sb.Append(("`n- id: load_{0:D2}`n  alias: load_{0:D2}`n  use_blueprint:`n    path: smarli/cover_DayNight.yaml`n    input:`n{1}`n" -f $i, (Y-Input $in)))
  }
  $sb.ToString()
}
T-Prep
HA-Call "automation" "turn_off" @{ entity_id = "automation.covers_day_night_sun" }

# --- reload: every automation publishes its first intent at once --------------------------------
Write-Host "`n== reload: $Autos automations publish their first intent together"
$t0 = Get-Date
# The burst starts with the reload, so the reload runs in a job while this thread already counts runs.
$yaml = Build-Automations -RealHeartbeat -Extra (Load-Yaml "23:59:00")
[IO.File]::WriteAllText("$cfg\automations.yaml", $yaml.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
$job = Start-Job { param($b, $t) Invoke-RestMethod -Method Post -Uri "$b/api/services/automation/reload" -Headers @{ Authorization = "Bearer $t" } } -ArgumentList $HA_BASE, (HA-Token)
$peak = Watch-Runs 40
Remove-Job $job -Force
Report "reload" $t0 $peak
$intents = @(HA-KeyNames "shared" | Where-Object { $_ -like "load_*::intent" }).Count
$open = @($coverIds | Where-Object { (HA-StateStr $_) -eq "open" }).Count
Write-Host "  intents written: $intents / $Autos | covers open: $open / $Covers"

# --- idle: gated heartbeats only ----------------------------------------------------------------
Write-Host "`n== idle: 2 minutes of heartbeats with nothing to do"
# docker stats streams one sample per ~2 s; each line is stamped with HA's second of the minute,
# because the heartbeat fires at HA's second 0 (HA's clock can run in another timezone than this PC).
$offset = (HA-Now) - [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000
$job = Start-Job { param($c, $o) docker stats --format "{{.CPUPerc}}" $c | ForEach-Object { "{0} {1}" -f [int](([DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000 + $o) % 60), $_ } } -ArgumentList $HA_CONTAINER, $offset
Start-Sleep 125
Stop-Job $job
$cpu = @(Receive-Job $job | ForEach-Object {
  $p = ($_ -replace '\x1b\[[0-9;]*[A-Za-z]', '' -replace '%', '').Trim() -split '\s+'
  if ($p.Count -ge 2 -and $p[1] -match '^[0-9.]+$') { [pscustomobject]@{ sec = [int]$p[0]; cpu = [double]$p[1] } }
})
Remove-Job $job -Force
$at0 = @($cpu | Where-Object { $_.sec -le 3 } | ForEach-Object { $_.cpu })
$rest = @($cpu | Where-Object { $_.sec -gt 8 } | ForEach-Object { $_.cpu })
Write-Host "  CPU samples: $($cpu.Count) ($($at0.Count) in seconds 0-3)"
Write-Host ("  HA CPU around second 0: max {0:N0} %   rest of the minute: median {1:N0} %   (100 % = one core)" -f ($at0 | Measure-Object -Maximum).Maximum, ($rest | Sort-Object)[[int]($rest.Count / 2)])
$env:RIG_TOKEN = HA-Token
node "$PSScriptRoot\lib\trace-durations.mjs" "automation.load_" | ForEach-Object { Write-Host "  $_" }

# --- phase: all automations extend in the same minute ---------------------------------------------
# Times come from HA's clock: the runtime tests move the instance's timezone.
$closeAt = HA-Template "{{ (now() + timedelta(minutes=2)).strftime('%H:%M:00') }}"
$tPhase = [double](HA-Template "{{ (now().replace(second=0, microsecond=0) + timedelta(minutes=2)).timestamp() }}")
Write-Host "`n== phase: all $Autos automations extend at $closeAt (HA time)"
HA-Apply -RealHeartbeat -Extra (Load-Yaml $closeAt)
Start-Sleep 5
while ((HA-Now) -lt $tPhase - 3) { Start-Sleep 1 }
$t0 = Get-Date
$peak = Watch-Runs 45
Report "phase" $t0 $peak
node "$PSScriptRoot\lib\trace-durations.mjs" "script.smarli_cover_resolve" | ForEach-Object { Write-Host "  $_" }
Start-Sleep 15
$closed = @($coverIds | Where-Object { (HA-StateStr $_) -eq "closed" }).Count
Write-Host "  covers closed: $closed / $Covers"

# --- hand: one command to every cover ------------------------------------------------------------
Write-Host "`n== hand: one person's command to all $Covers covers"
$t0 = Get-Date
HA-Call "cover" "open_cover" @{ entity_id = $coverIds }
$peak = Watch-Runs 40
Report "hand" $t0 $peak
$susp = @($coverIds | Where-Object { $null -ne (HA-Shared "$_::suspension") }).Count
Write-Host "  covers paused: $susp / $Covers"

# --- restore ------------------------------------------------------------------------------------
Write-Host "`n== Restore"
HA-Apply
T-Prep
foreach ($k in (HA-KeyNames "shared")) { if ($k -like "load_*" -or $k -like "cover.vload*") { HA-DelKey "shared" $k } }
if (-not $KeepCovers) {
  Move-Item "$virtual.load-backup" $virtual -Force
  Restart-Rig
}
Write-Host "Done."
