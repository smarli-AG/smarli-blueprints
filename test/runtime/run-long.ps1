# The schedule suites (5 s heartbeat, second-precision times; any time of day).
# Output: console, plus PASS/FAIL lines in .state\results.log.
. "$PSScriptRoot\lib\ha.ps1"; . "$PSScriptRoot\lib\lib-test.ps1"
foreach ($t in "test-daynight","test-fingerprint","test-transition-flag","test-custom-triggers","test-time-earliest") { "--- $t"; & "$PSScriptRoot\tests\$t.ps1" }
"ALLDONE"
