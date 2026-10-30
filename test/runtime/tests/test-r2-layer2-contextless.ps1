# R2: a genuinely contextless state write (context older than 5 s is nulled by HA) with no live marker suspends the
# cover (layer 2); with a live marker it is ignored. vslow, 16 s travel.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$c = "cover.vslow"
T-Prep; T-Place $c 100
HA-StubDay @{ $c = 100 }                      # an intent must name the cover (duration comes from it)
Start-Sleep 8; T-Settle $c 30; HA-ClearSuspensions

function Run-R2([bool]$withMarker) {
  T-Place $c 100
  HA-StubDay @{ $c = 100 }; Start-Sleep 3; HA-ClearSuspensions
  $t0 = Get-Date
  HA-Call "cover" "close_cover" @{ entity_id = $c }
  $first = HA-Wait { $null -ne (HA-Shared "$c::suspension") } 10 0.5
  $tFirst = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  Start-Sleep ([math]::Max(0, 7 - ((Get-Date) - $t0).TotalSeconds))      # past the 5 s context-recency cutoff
  HA-DelKey "shared" "$c::suspension"
  if ($withMarker) { HA-SetKey "shared" "$c::moving_ctl" @{ target = 0; until = ((HA-Now) + 60); started_ts = (HA-Now) } }
  Start-Sleep 1
  $back = HA-Wait { $null -ne (HA-Shared "$c::suspension") } 30 0.5
  $tBack = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  T-Settle $c 30
  [pscustomobject]@{ First = $first; TFirst = $tFirst; Back = $back; TBack = $tBack; Final = (T-Cover $c) }
}
$a = Run-R2 $false
T-Check "R2 layer1: REST move is tainted -> suspension written first" $a.First "suspension appeared at t+$($a.TFirst)s"
T-Check "R2 layer2: contextless write, no marker -> suspension written again" $a.Back "reappeared=$($a.Back) at t+$($a.TBack)s, cover=$($a.Final)"
HA-ClearSuspensions
$b = Run-R2 $true
T-Check "R2 control: contextless write WITH live marker is ignored" (-not $b.Back) "reappeared=$($b.Back) (waited 30 s), cover=$($b.Final)"
T-Prep
