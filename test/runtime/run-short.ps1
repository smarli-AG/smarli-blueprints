# The core suites, about 20 minutes. Output: console, plus PASS/FAIL lines in .state\results.log.
. "$PSScriptRoot\lib\ha.ps1"; . "$PSScriptRoot\lib\lib-test.ps1"
foreach ($t in "test-resolver","test-markers","test-overlap","test-cross-instance","test-gc","test-daynight","test-a4","test-a4-fresh","test-a7","test-r2-layer2-contextless","test-brightness-stabilizer","test-silent-covers","test-restart-selfheal") { "--- $t"; & "$PSScriptRoot\tests\$t.ps1" }
"ALLDONE"
