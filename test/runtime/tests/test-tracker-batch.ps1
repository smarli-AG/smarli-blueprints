# 6  Tracker batch events (smarli_core.yaml 2026-11-09): smarli_tracker_set_many / smarli_tracker_remove_many.
# - set_many upserts every key in one write, skips null values and empty keys, leaves other keys alone
# - remove_many removes exactly the listed keys; a missing key is no error
# - malformed payloads change nothing; the single events still work
# - a resolver + mover cycle for 4 covers writes the tracker a few times, not once per key and cover
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$ns = "test_batch"
$covers = @("cover.vfast", "cover.vslow", "cover.living_room_window", "cover.hall_window")

# Counts tracker writes: every write changes the `data` attribute, so it fires state_changed.
$extra = @"

- id: count_tracker_writes
  alias: count_tracker_writes
  mode: parallel
  max: 500
  trace:
    stored_traces: 200
  triggers:
    - trigger: event
      event_type: state_changed
      event_data:
        entity_id: sensor.smarli_automation_tracker
  actions:
    - stop: counted
# Counts cover service calls sent by a script (the mover); a person's calls have no parent.
- id: count_cover_calls
  alias: count_cover_calls
  mode: parallel
  max: 500
  trace:
    stored_traces: 200
  triggers:
    - trigger: event
      event_type: call_service
      event_data:
        domain: cover
  conditions:
    - condition: template
      value_template: "{{ trigger.event.context.parent_id is not none }}"
  actions:
    - stop: counted
"@
function Calls([datetimeoffset]$since) {
  @((HA-WS @{ type = "trace/list"; domain = "automation"; item_id = "count_cover_calls" }).result |
    Where-Object { [datetimeoffset]$_.timestamp.start -gt $since -and $_.script_execution -ne "failed_conditions" }).Count
}
function Writes([datetimeoffset]$since) {
  @((HA-WS @{ type = "trace/list"; domain = "automation"; item_id = "count_tracker_writes" }).result |
    Where-Object { [datetimeoffset]$_.timestamp.start -gt $since }).Count
}
function Keys { @(HA-KeyNames $ns) }

T-Prep
HA-Apply -Extra $extra
Start-Sleep 14   # the tracker GC runs 10 s after the reload; let it pass before seeding

Write-Host "`n=== 6-1 set_many"
HA-SetKey $ns "keep::k" 1
HA-Event "smarli_tracker_set_many" @{ namespace = $ns; items = @{ "a::x" = 1; "b::y" = @{ n = 2 }; "c::z" = $null; "" = 5 } }
Start-Sleep 1
$k = Keys
T-Check "6-1 set_many writes every key with a value" (($k -contains "a::x") -and ([int](HA-Key $ns "b::y").n -eq 2)) "keys: $($k -join ',')"
T-Check "6-1 set_many skips a null value and an empty key" ((-not ($k -contains "c::z")) -and (-not ($k -contains ""))) "keys: $($k -join ',')"
T-Check "6-1 set_many leaves other keys alone" ([int](HA-Key $ns "keep::k") -eq 1) "keep::k = $(HA-Key $ns 'keep::k')"
HA-Event "smarli_tracker_set_many" @{ namespace = $ns; items = @{ "a::x" = 7 } }
Start-Sleep 1
T-Check "6-1 set_many overwrites an existing key" ([int](HA-Key $ns "a::x") -eq 7) "a::x = $(HA-Key $ns 'a::x')"

Write-Host "`n=== 6-2 remove_many"
HA-Event "smarli_tracker_remove_many" @{ namespace = $ns; keys = @("a::x", "missing::k") }
Start-Sleep 1
$k = Keys
T-Check "6-2 remove_many removes exactly the listed keys" ((-not ($k -contains "a::x")) -and ($k -contains "b::y") -and ($k -contains "keep::k")) "keys: $($k -join ',')"

Write-Host "`n=== 6-3 malformed payloads and single events"
$before = (Keys | Sort-Object) -join ','
HA-Event "smarli_tracker_set_many" @{ namespace = $ns }
HA-Event "smarli_tracker_set_many" @{ namespace = $ns; items = "a::x" }
HA-Event "smarli_tracker_remove_many" @{ namespace = $ns; keys = "b::y" }
HA-Event "smarli_tracker_remove_many" @{ keys = @("b::y") }
Start-Sleep 1
$after = (Keys | Sort-Object) -join ','
T-Check "6-3 a missing or wrong-typed items/keys/namespace changes nothing" ($before -eq $after) "before: $before | after: $after"
HA-SetKey $ns "single::k" 3; HA-DelKey $ns "keep::k"
Start-Sleep 1
$k = Keys
T-Check "6-3 the single set and remove events still work" (($k -contains "single::k") -and (-not ($k -contains "keep::k"))) "keys: $($k -join ',')"
HA-Event "smarli_tracker_remove_many" @{ namespace = $ns; keys = @(Keys) }

Write-Host "`n=== 6-4 a resolver + mover cycle for 4 covers writes the tracker a few times"
$targets = @{}; foreach ($c in $covers) { $targets[$c] = if ((T-Pos $c) -ge 50) { 0 } else { 100 } }
HA-ClearSuspensions
$since = [datetimeoffset]::Now.AddSeconds(-1)
HA-StubDay $targets
$done = HA-Wait { @($covers | Where-Object { [int](HA-Shared "$_::resolved") -ne $targets[$_] }).Count -eq 0 } 20 0.5
foreach ($c in $covers) { T-Settle $c 60 }
HA-Wait { @(HA-KeyNames "cover" | Where-Object { $_ -like "*::moving_*" }).Count -eq 0 } 30 1 | Out-Null
Start-Sleep 3
$n = Writes $since
$left = @(HA-KeyNames "cover" | Where-Object { $_ -like "*::moving_*" })
$pos = ($covers | ForEach-Object { "$($_.Substring(6))=$(T-Pos $_)" }) -join ' '
T-Check "6-4 every cover is resolved and reaches its target" ($done -and @($covers | Where-Object { [math]::Abs((T-Pos $_) - $targets[$_]) -gt 5 }).Count -eq 0) "targets: $(($targets.GetEnumerator() | ForEach-Object { "$($_.Name.Substring(6))=$($_.Value)" }) -join ' ') | pos: $pos"
T-Check "6-4 every moving marker is released" ($left.Count -eq 0) "left: $($left -join ',')"
# Single writes: 1 intent + 4 watchers + 4 resolved + 4 markers + 4 releases = 17. Batched: 1 intent + 1 record
# + 1 markers + one release per settle pass in which a cover settled (up to 4).
T-Check "6-4 at most 8 tracker writes (17 with one write per key and cover)" ($n -ge 3 -and $n -le 8) "writes: $n"

Write-Host "`n=== 6-5 the mover commands covers with the same target in one service call"
HA-Move (@{} + ($covers | ForEach-Object -Begin { $h = @{} } -Process { $h[$_] = 0 } -End { $h })) "place"
Start-Sleep 4; foreach ($c in $covers) { T-Settle $c 60 }
HA-ClearSuspensions
$all = @{}; foreach ($c in $covers) { $all[$c] = 100 }
# One group per command kind: covers with positioning share set_cover_position 100, binary covers open_cover.
$groups = @($covers | ForEach-Object { if (([int](HA-State $_).attributes.supported_features -band 4) -gt 0) { "pos" } else { "bin" } } | Sort-Object -Unique).Count
$since = [datetimeoffset]::Now.AddSeconds(-1)
HA-StubDay $all -transition $true
HA-Wait { @($covers | Where-Object { [int](HA-Shared "$_::resolved") -ne 100 }).Count -eq 0 } 20 0.5 | Out-Null
foreach ($c in $covers) { T-Settle $c 60 }
Start-Sleep 2
$calls = Calls $since
$pos = ($covers | ForEach-Object { "$($_.Substring(6))=$(T-Pos $_)" }) -join ' '
T-Check "6-5 every cover reaches 100" (@($covers | Where-Object { [math]::Abs((T-Pos $_) - 100) -gt 5 }).Count -eq 0) "pos: $pos"
T-Check "6-5 one service call per command kind ($groups), not one per cover ($($covers.Count))" ($calls -eq $groups) "calls: $calls"

HA-DelKey "shared" "stub_day::intent"
HA-Apply
T-Prep
