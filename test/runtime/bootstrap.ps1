# Builds the runtime test instance from scratch: config skeleton, custom components, first boot,
# onboarding, long-lived token, swissweather config flow, virtual covers, second boot.
# Everything it creates lives in .state\ (git-ignored). See docs/test-environment.md.
#
#   .\bootstrap.ps1                              # default port 8123, container smarli-ha-test
#   $env:HA_PORT = "8124"; $env:HA_CONTAINER = "smarli-ha-check"; .\bootstrap.ps1
#   .\bootstrap.ps1 -ComponentsFrom <dir>        # copy virtual/ and swissweather/ from <dir> instead of downloading
#   .\bootstrap.ps1 -Force                       # stop this instance and delete .state first
param([string]$ComponentsFrom = "", [switch]$Force)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\ha.ps1"

# Pinned versions. hass-virtual is GPL-3.0 and swissweather Apache-2.0; they are downloaded, not
# vendored, so no third-party code lives in this repo. swissweather 1.3.2 has no tag, hence a commit.
$COMPONENTS = @(
  @{ name = "virtual";      repo = "twrecked/hass-virtual";    ref = "v0.9.4" },
  @{ name = "swissweather"; repo = "izacus/hass-swissweather"; ref = "41279cc6fc00f6e5d3e90fc579e7f0a6af4cbc10" }
)

function Step($t) { Write-Host "`n== $t" }
function Compose { param([string[]]$a) docker compose -f "$HA_ROOT\docker-compose.yml" -p $HA_CONTAINER @a; if ($LASTEXITCODE) { throw "docker compose $a failed" } }

# --- preconditions -----------------------------------------------------------------------------
# Any .state counts, also a half-built one: onboarding cannot run twice on the same config.
if (Test-Path "$HA_STATE\config") {
  if (-not $Force) { throw "An instance already exists ($HA_STATE). Use it, or rebuild with -Force (stops it and deletes .state)." }
  Step "Removing the existing instance"
  docker compose -f "$HA_ROOT\docker-compose.yml" -p $HA_CONTAINER down | Out-Null
  Remove-Item -Recurse -Force $HA_STATE
}
if (-not (Test-Path "$HA_PACKAGES_DIR\smarli_cover.yaml")) {
  throw "No ha-packages checkout at $HA_PACKAGES_DIR. Clone smarli-AG/ha-packages next to this repo, or set HA_PACKAGES_DIR."
}
if (Get-NetTCPConnection -LocalPort ([int]$HA_PORT) -State Listen -ErrorAction SilentlyContinue) {
  throw "Port $HA_PORT is in use. Pick another one with `$env:HA_PORT."
}
$env:HA_PORT = $HA_PORT; $env:HA_CONTAINER = $HA_CONTAINER; $env:HA_PACKAGES_DIR = $HA_PACKAGES_DIR

# --- config skeleton and components ------------------------------------------------------------
Step "Config skeleton"
$cfg = "$HA_STATE\config"
New-Item -ItemType Directory -Force -Path "$cfg\custom_components" | Out-Null
Copy-Item "$HA_ROOT\skeleton\configuration.yaml", "$HA_ROOT\skeleton\mint.py", "$HA_ROOT\skeleton\ws.py" $cfg
# virtual.yaml is written only after the first boot: hass-virtual's import flow overwrites an
# existing file with "devices: {}" when it creates its config entry.
$yaml = Build-Automations
[IO.File]::WriteAllText("$cfg\automations.yaml", $yaml.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))

Step "Custom components"
foreach ($c in $COMPONENTS) {
  $dest = "$cfg\custom_components\$($c.name)"
  if ($ComponentsFrom) {
    Copy-Item -Recurse "$ComponentsFrom\$($c.name)" $dest
    Write-Host "  $($c.name): copied from $ComponentsFrom"
  } else {
    $tmp = Join-Path $env:TEMP ("smarli-cc-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Invoke-WebRequest -UseBasicParsing "https://codeload.github.com/$($c.repo)/tar.gz/$($c.ref)" -OutFile "$tmp\src.tgz"
    tar -xzf "$tmp\src.tgz" -C $tmp
    $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
    Copy-Item -Recurse "$($src.FullName)\custom_components\$($c.name)" $dest
    Remove-Item -Recurse -Force $tmp
    Write-Host "  $($c.name): $($c.repo) @ $($c.ref)"
  }
}
# hass-virtual 0.9.4 calls verify_domain_control(COMPONENT_DOMAIN); the HA signature needs hass first.
$init = "$cfg\custom_components\virtual\__init__.py"
$src = [IO.File]::ReadAllText($init)
$fixed = $src.Replace("verify_domain_control(COMPONENT_DOMAIN)", "verify_domain_control(hass, COMPONENT_DOMAIN)")
if ($fixed -ne $src) { [IO.File]::WriteAllText($init, $fixed); Write-Host "  virtual: verify_domain_control patch applied" }

# --- first boot and onboarding -----------------------------------------------------------------
Step "First boot ($HA_BASE, container $HA_CONTAINER)"
Compose @("up", "-d")
Wait-HA

Step "Onboarding"
$client = "$HA_BASE/"
$user = "smarli"
$pass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
$r = Invoke-RestMethod -Method Post "$HA_BASE/api/onboarding/users" -ContentType "application/json" `
  -Body (@{ client_id = $client; name = "smarli test"; username = $user; password = $pass; language = "en" } | ConvertTo-Json)
$tok = Invoke-RestMethod -Method Post "$HA_BASE/auth/token" -ContentType "application/x-www-form-urlencoded" `
  -Body "grant_type=authorization_code&code=$($r.auth_code)&client_id=$([uri]::EscapeDataString($client))"
$auth = @{ Authorization = "Bearer $($tok.access_token)" }
Invoke-RestMethod -Method Post "$HA_BASE/api/onboarding/core_config" -Headers $auth -ContentType "application/json" -Body "{}" | Out-Null
Invoke-RestMethod -Method Post "$HA_BASE/api/onboarding/analytics" -Headers $auth -ContentType "application/json" -Body "{}" | Out-Null
Invoke-RestMethod -Method Post "$HA_BASE/api/onboarding/integration" -Headers $auth -ContentType "application/json" `
  -Body (@{ client_id = $client; redirect_uri = "$($client)?auth_callback=1" } | ConvertTo-Json) | Out-Null
[IO.File]::WriteAllText("$HA_STATE\.onboarding", "${user}:$pass")

# Access tokens expire after 30 minutes; the tests use a long-lived one, minted inside the container.
$long = (docker exec $HA_CONTAINER python3 /config/mint.py $tok.access_token ("smarli-test-" + (Get-Date -Format yyyyMMddHHmmss)) | Out-String).Trim()
if (-not $long -or $long.StartsWith("ERR")) { throw "Minting the long-lived token failed: $long" }
[IO.File]::WriteAllText("$HA_STATE\.token", $long)
Write-Host "  user and token saved in .state (not printed)"

Step "Core settings (Zurich)"
# Stored, not in configuration.yaml, so the test fixtures' time zone and location survive a restart.
HA-WS @{ type = "config/core/update"; location_name = "smarli test"; latitude = 47.3769; longitude = 8.5417
         elevation = 408; unit_system = "metric"; time_zone = "Europe/Zurich"; country = "CH" } | Out-Null

Step "swissweather (postcode 8001)"
$flow = Invoke-RestMethod -Method Post "$HA_BASE/api/config/config_entries/flow" -Headers (HA-Headers) -ContentType "application/json" `
  -Body '{"handler":"swissweather","show_advanced_options":false}'
$done = Invoke-RestMethod -Method Post "$HA_BASE/api/config/config_entries/flow/$($flow.flow_id)" -Headers (HA-Headers) -ContentType "application/json" `
  -Body '{"postCode":"8001"}'
Write-Host "  flow result: $($done.type)"

# --- virtual covers and second boot -------------------------------------------------------------
Step "Virtual covers and second boot"
Copy-Item "$HA_ROOT\skeleton\virtual.yaml" $cfg -Force
docker restart $HA_CONTAINER | Out-Null
Wait-HA
# Instances the doc leaves off between sessions; the tests turn them on when they need them.
HA-Call "automation" "turn_off" @{ entity_id = @("automation.covers_day_night_time", "automation.covers_day_night_brightness") }

Step "Check"
$want = "cover.vfast","cover.vslow","cover.vbright","cover.assumed_rts","cover.garage_door","weather.weather_at_8001",
        "sensor.smarli_automation_tracker","script.smarli_cover_resolve","automation.covers_day_night_sun"
$missing = @($want | Where-Object { (HA-StateStr $_) -in @("missing", "unavailable") })
. "$PSScriptRoot\lib\lib-test.ps1"   # logs the repo refs
if ($missing.Count) { throw "Missing or unavailable after bootstrap: $($missing -join ', ')" }
Write-Host "Ready: $HA_BASE  (container $HA_CONTAINER, state in $HA_STATE)"
