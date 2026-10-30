# More test helpers (timeline sampling). Dot-sourced by lib-test.ps1.
function Sample-Cover {
  param($cover, $id)
  $sh = (HA-Tracker).shared; $cs = HA-State $cover
  $int = if ($id) { $sh.PSObject.Properties["$id::intent"].Value } else { $null }
  [pscustomobject]@{
    Now = Get-Date; State = $cs.state; Pos = $cs.attributes.current_position; Assumed = $cs.attributes.assumed_state
    Target = $(if ($int) { $int.targets.PSObject.Properties[$cover].Value } else { $null })
    IntentTs = $(if ($int) { [double]$int.ts } else { $null })
    Resolved = $sh.PSObject.Properties["$cover::resolved"].Value
    Susp = ($null -ne $sh.PSObject.Properties["$cover::suspension"])
    Marker = [bool](@($sh.PSObject.Properties.Name) -like "$cover::moving_*")
  }
}
# Poll until $end. Returns Log lines, Moved (opening/closing seen), MovedAt, Susp (any suspension seen), Marker
function Watch-Cover {
  param($cover, $id, [datetime]$end, [datetime]$ref, [int]$every = 2)
  $log = New-Object System.Collections.ArrayList; $last = ""; $r = @{ Moved = $false; MovedAt = $null; Susp = $false; Marker = $false }
  while ((Get-Date) -lt $end) {
    $s = Sample-Cover $cover $id
    $key = "$($s.State)|$($s.Target)|$($s.Resolved)|$($s.Susp)|$($s.Marker)|$([math]::Round($s.IntentTs))"
    if ($key -ne $last) {
      [void]$log.Add(("{0:+0;-0}s cover={1}/{2} intent={3} resolved={4} susp={5} marker={6}" -f [math]::Round(($s.Now - $ref).TotalSeconds), $s.State, $s.Pos, $s.Target, $s.Resolved, $s.Susp, $s.Marker)); $last = $key
    }
    if (($s.State -eq "opening" -or $s.State -eq "closing") -and -not $r.Moved) { $r.Moved = $true; $r.MovedAt = $s.Now }
    if ($s.Susp) { $r.Susp = $true }
    if ($s.Marker) { $r.Marker = $true }
    Start-Sleep $every
  }
  $r.Log = $log
  $r
}
