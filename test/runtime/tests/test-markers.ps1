# Per-cover moving markers appear and are cleaned up independently; no legacy keys; no false suspension.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
T-Prep; T-Place "cover.vfast" 100; T-Place "cover.vslow" 100

$t0 = Get-Date
HA-Move @{ "cover.vfast" = 0; "cover.vslow" = 0 } "mk1"
Start-Sleep 2
$names = @(HA-KeyNames "shared")
$mf = $names -contains "cover.vfast::moving_mk1"; $ms = $names -contains "cover.vslow::moving_mk1"
$val = HA-Shared "cover.vfast::moving_mk1"
T-Check "markers: both per-cover keys appear (t+2s)" ($mf -and $ms) "vfast=$mf vslow=$ms value=$($val | ConvertTo-Json -Compress)"
T-Check "markers: value has numeric target/until/started_ts" (($val.target -is [int] -or $val.target -is [long]) -and $val.until -gt 0 -and $val.started_ts -gt 0) "target=$($val.target) type=$($val.target.GetType().Name)"

# fast cover (6 s travel) is released while slow (16 s) still holds its marker
$ok = HA-Wait { -not (@(HA-KeyNames "shared") -contains "cover.vfast::moving_mk1") } 30 0.5
$names = @(HA-KeyNames "shared")
$el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
T-Check "markers: fast cover released before slow one" ($ok -and ($names -contains "cover.vslow::moving_mk1")) "vfast marker gone at t+${el}s, vslow marker still present=$($names -contains 'cover.vslow::moving_mk1'); vslow=$(T-Cover 'cover.vslow')"

$ok = HA-Wait { -not (@(HA-KeyNames "shared") -contains "cover.vslow::moving_mk1") } 40 1
$el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
T-Check "markers: slow marker cleaned up after settle" $ok "gone at t+${el}s"

$names = @(HA-KeyNames "shared")
T-Check "markers: no leftover moving_* keys" (-not ($names | ? { $_ -like "cover.vfast::moving_*" -or $_ -like "cover.vslow::moving_*" })) "keys=$($names -join ',')"
$legacy = @($names | ? { $_ -notlike "*::*" -or $_ -in @("automation_in_progress", "suspensions") -or $_ -like "*::moving_run" -or $_ -like "*::automation_in_progress" })
T-Check "markers: no legacy keys in shared" ($legacy.Count -eq 0) "legacy=$($legacy -join ',')"
$cdn = @(HA-KeyNames "cover_day_night")
$badcdn = @($cdn | ? { $_ -notmatch "::(bright_since|dark_since)$" })
T-Check "markers: cover_day_night namespace holds only stabilizer keys" ($badcdn.Count -eq 0) "keys=$($cdn -join ',')"
T-Check "markers: no suspension from own moves" (-not ($names | ? { $_ -like "*::suspension" })) "suspension keys=$(($names | ? { $_ -like '*::suspension' }) -join ',')"
T-Prep
