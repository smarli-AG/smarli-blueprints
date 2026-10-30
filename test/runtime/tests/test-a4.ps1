# A4: coincident conflicting intents (identical ts). Tie order: newest ts, then priority, then owner id (descending).
# Both contributors are fired through the stub automations (automation context, like real blueprints) with the SAME ts.
# -Fresh resets both intents, the resolved key and the cover position at the start of every repetition.
param([switch]$Fresh, [int]$Reps = 3)
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vfast"
$tag = if ($Fresh) { "A4-fresh" } else { "A4" }
HA-Apply                                  # pick up the stub 'ts' override
T-Prep; T-Place $c 100

function Run-Case($label, $dayTarget, $dayPrio, $shadeTarget, $shadePrio, $expect) {
  if ($Fresh) {
    HA-DelKey "shared" "stub_day::intent"; HA-DelKey "shared" "stub_shade::intent"; HA-DelKey "shared" "$c::resolved"
    T-Place $c (100 - $expect)       # start at the opposite end so a missing command is visible
  }
  $ts = HA-Now
  HA-StubDay @{ $c = $dayTarget } $dayPrio 1800 $ts
  HA-StubShade @{} @{ $c = $shadeTarget } $shadePrio 1800 $ts
  HA-Wait { (HA-Shared "$c::resolved") -eq $expect } 10 | Out-Null
  Start-Sleep 3
  T-Settle $c 30
  $res = HA-Shared "$c::resolved"
  T-Check "$tag $label -> $expect" (($res -eq $expect) -and ([math]::Abs((T-Pos $c) - $expect) -le 5)) "resolved=$res cover=$(T-Cover $c)"
}
for ($n = 1; $n -le $Reps; $n++) {
  Run-Case "rep$n prio 10(0) vs 50(100)" 0 10 100 50 100
  Run-Case "rep$n prio 50(0) vs 10(100)" 0 50 100 10 0
  Run-Case "rep$n equal prio, owner id stub_shade > stub_day" 0 10 100 10 100
}
T-Check "$tag no false suspension" (-not (@(HA-KeyNames "shared") -contains "$c::suspension")) "suspension=$(HA-Shared "$c::suspension")"
T-Prep
