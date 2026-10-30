# Shared test helpers. Dot-source after ha.ps1.
$RESULTS = "$HA_STATE\results.log"

# Which code is under test: the blueprints come from this checkout and the packages from the
# mounted ha-packages checkout, so record both refs once per PowerShell process and warn about
# uncommitted changes (a dirty tree tests code that no commit contains).
function T-RepoRef {
  param([string]$label, [string]$dir, [string]$pathspec = ".")
  if (-not (Test-Path $dir)) { return "$label missing at $dir" }
  $branch = (git -C $dir rev-parse --abbrev-ref HEAD 2>$null)
  $commit = (git -C $dir rev-parse --short HEAD 2>$null)
  $dirty = (git -C $dir status --porcelain -- $pathspec 2>$null)
  $flag = if ($dirty) { " UNCOMMITTED CHANGES" } else { "" }
  "$label $branch @ $commit$flag"
}
if (-not $global:SMARLI_REFS_LOGGED) {
  $global:SMARLI_REFS_LOGGED = $true
  New-Item -ItemType Directory -Force -Path $HA_STATE | Out-Null
  $refs = "{0} | {1} | {2}" -f (T-RepoRef "blueprints" $HA_REPO "automation"), (T-RepoRef "ha-packages" (Split-Path -Parent $HA_PACKAGES_DIR) "packages"), "HA $HA_BASE ($HA_CONTAINER)"
  if ($refs -match "UNCOMMITTED|missing") { Write-Warning $refs } else { Write-Host $refs }
  Add-Content $RESULTS ("{0:yyyy-MM-dd HH:mm:ss} | REFS | {1}" -f (Get-Date), $refs)
}

function T-Check {
  param([string]$name, [bool]$ok, [string]$evidence = "")
  $status = if ($ok) { "PASS" } else { "FAIL" }
  $line = "{0} | {1} | {2}" -f $status, $name, $evidence
  Write-Host $line
  Add-Content $RESULTS ("{0:yyyy-MM-dd HH:mm:ss} | {1}" -f (Get-Date), $line)
}
function T-Note {
  param([string]$name, [string]$status, [string]$evidence = "")
  $line = "{0} | {1} | {2}" -f $status, $name, $evidence
  Write-Host $line
  Add-Content $RESULTS ("{0:yyyy-MM-dd HH:mm:ss} | {1}" -f (Get-Date), $line)
}
function T-Cover {
  param($id)
  $s = HA-State $id
  "{0}/{1}" -f $s.state, $s.attributes.current_position
}
function T-Pos { param($id) $p = (HA-State $id).attributes.current_position; if ($null -eq $p) { $null } else { [double]$p } }
function T-Settle {
  param($id, [int]$timeout = 45)
  Start-Sleep 1
  HA-Wait { $s = HA-StateStr $id; ($s -ne "opening") -and ($s -ne "closing") } $timeout 1 | Out-Null
  Start-Sleep 1
}
# The brightness method's arming windows, computed like the blueprint (todays_sunrise/sunset,
# 60 min offset): Close from sunset - 60 min, Open from sunrise - 60 min until sunset - 60 min.
function T-BrightnessArmed {
  $t = HA-Template @"
{% set n = as_timestamp(now()) %}
{% set r = as_timestamp(state_attr('sun.sun', 'next_rising'), 0) %}{% set s = as_timestamp(state_attr('sun.sun', 'next_setting'), 0) %}
{% set r = r if r | timestamp_custom('%j') == n | timestamp_custom('%j') else r - 86400 %}
{% set s = s if s | timestamp_custom('%j') == n | timestamp_custom('%j') else s - 86400 %}
{{ n >= s - 3600 }}|{{ n >= r - 3600 and n < s - 3600 }}
"@
  $p = $t.Trim().Split('|'); @{ Close = ($p[0] -eq 'True'); Open = ($p[1] -eq 'True') }
}

# The tests must not depend on the real time of day. Two fixtures move the instance instead of the
# clock (a faked clock would confuse HA's scheduler, which runs on the monotonic clock):
#
# T-LocalNoon — a whole-hour time zone (Etc/GMT±N) that puts HA's local time near midday, so a
#   schedule time "now + a few minutes" never crosses midnight (today_at() would read 00:01 as
#   this morning). Called on every load of this file, i.e. at the start of every test.
# T-SunPhase — moves the longitude until the sun is where a test needs it: "night" = solar midnight
#   now (sunset hours ago: the brightness close is armed, the open is not), "day" = solar noon now.
#   Moving east makes every sun event earlier by 4 min per degree. T-SunHome moves it back.
$HOME_LAT = 47.3769; $HOME_LON = 8.5417
function T-LocalNoon {
  $off = 12 - (Get-Date).ToUniversalTime().Hour          # -11 .. 12
  $tz = if ($off -eq 0) { "Etc/GMT" } elseif ($off -gt 0) { "Etc/GMT-$off" } else { "Etc/GMT+$(-$off)" }
  HA-WS @{ type = "config/core/update"; time_zone = $tz } | Out-Null
}
function T-SunPhase {
  param([ValidateSet("night", "day")][string]$phase)
  $attr = if ($phase -eq "night") { "next_midnight" } else { "next_noon" }
  for ($i = 0; $i -lt 3; $i++) {
    $p = (HA-Template "{{ as_timestamp(state_attr('sun.sun', '$attr')) - as_timestamp(now()) }}|{{ state_attr('zone.home', 'longitude') }}").Trim().Split('|')
    $d = [double]$p[0] % 86400; if ($d -gt 43200) { $d -= 86400 }
    $lon = [double]$p[1] + $d / 240
    while ($lon -gt 180) { $lon -= 360 }; while ($lon -lt -180) { $lon += 360 }
    HA-Call "homeassistant" "set_location" @{ latitude = $HOME_LAT; longitude = [math]::Round($lon, 4) }
    Start-Sleep 3
    $a = T-BrightnessArmed
    if (($phase -eq "night" -and $a.Close -and -not $a.Open) -or ($phase -eq "day" -and $a.Open -and -not $a.Close)) { return }
  }
  throw "T-SunPhase: could not put the sun at '$phase' (close=$($a.Close) open=$($a.Open))"
}
function T-SunHome { HA-Call "homeassistant" "set_location" @{ latitude = $HOME_LAT; longitude = $HOME_LON }; Start-Sleep 2 }
T-LocalNoon

function T-Intent { param($owner) HA-Shared "$owner::intent" }
function T-Target { param($owner, $cover) $i = T-Intent $owner; if ($null -eq $i) { $null } else { $i.targets.PSObject.Properties[$cover].Value } }

# Known-clean starting point. Time/brightness instances off, stub + marker + suspension + resolved keys removed.
function T-Prep {
  param([switch]$KeepInstances, [switch]$KeepIntents)
  if (-not $KeepInstances) {
    HA-Call "automation" "turn_off" @{ entity_id = @("automation.covers_day_night_time", "automation.covers_day_night_brightness") }
  }
  foreach ($k in (HA-KeyNames "shared")) {
    $drop = ($k -like "*::suspension") -or ($k -like "*::moving_*") -or ($k -like "cover.*::resolved") -or ($k -like "stub_*::intent")
    if (-not $KeepIntents -and ($k -like "cover_*_test::intent")) { $drop = $true }
    if ($drop) { HA-DelKey "shared" $k }
  }
  Start-Sleep 1
}
# Put the cover somewhere through the contextless rig, wait for it, then forget the marker/suspension side effects
function T-Place {
  param($cover, [int]$pos)
  HA-Move @{ $cover = $pos } "place"
  Start-Sleep 4
  T-Settle $cover 40
  HA-ClearSuspensions
}
. "$PSScriptRoot\lib-test2.ps1"
