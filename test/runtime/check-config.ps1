# check_config on the floor versions, against a scratch copy of the live config with the same
# mounts as docker-compose.yml. A copy, because a read-only mount spews registry-write errors and a
# read-write mount of the live config would write next to the running instance.
# A rejected blueprint instance does NOT fail check_config: it logs "invalid automation" and exits 0.
param([string[]]$Versions = @("2024.10", "2025.4"))
. "$PSScriptRoot\lib\ha.ps1"
$scratch = Join-Path $env:TEMP "smarli-check-config"
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
robocopy "$HA_STATE\config" $scratch /E /XD .storage deps tts blueprints packages /XF "home-assistant_v2.db*" "*.log*" /NFL /NDL /NJH /NJS | Out-Null
foreach ($v in $Versions) {
  $out = docker run --rm -v "${scratch}:/config" -v "$HA_REPO\automation:/config/blueprints/automation/smarli:ro" -v "${HA_PACKAGES_DIR}:/config/packages:ro" "ghcr.io/home-assistant/home-assistant:$v" python -m homeassistant --script check_config -c /config --info all 2>&1
  $code = $LASTEXITCODE
  # [char]27, not `e: PowerShell 5.1 has no `e escape.
  $clean = ($out | Out-String) -replace "$([char]27)\[[0-9;]*m",""
  "=== $v exit=$code"
  ($clean -split "`n" | Select-String 'Successful config|^ERROR|Invalid config|Failed|invalid automation|Testing configuration').Line
}
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
