# 5b  smarli_cover_request: one resolver run per burst, no lost intent, no lost transition force
#     (smarli_cover.yaml 2026-11-09, cover_DayNight 3.2.0).
# 20 request automations req_01..req_20, each the only caller for its own ghost cover cover.ghost_NN.
# A ghost cover has no entity and a pause, so the resolver records its decision (::resolved, ::applied)
# but commands nothing. A lost intent shows as a wrong ::resolved, a lost force as a missing ::applied.
# - burst: all 20 call at once; every decision lands; the resolver runs fewer times than there are callers
# - spread: callers one after another, 0.2-1 s apart (not covered by hub spike S6)
# - force: a transition intent forces its cover once, also when its caller skipped the resolver call
# - old: the resolver call field `transition` (blueprints before 3.2.0) still forces
param([string[]]$Only = @())
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
$n = 20
$owners = 1..$n | ForEach-Object { "req_{0:D2}" -f $_ }
$ghost = @{}; foreach ($o in $owners) { $ghost[$o] = "cover.ghost_" + $o.Substring(4) }
$c = "cover.vfast"

$extra = ($owners | ForEach-Object { @"

- id: $_
  alias: $_
  mode: queued
  triggers:
    - trigger: event
      event_type: test_req
  conditions:
    - condition: template
      value_template: "{{ '$_' in trigger.event.data.plan }}"
  actions:
    - action: script.smarli_cover_request
      data:
        owner: $_
        intent: >
          {% set p = trigger.event.data.plan['$_'] %}
          {{ {'targets': p.targets, 'bounds': {}, 'priority': 10, 'ts': as_timestamp(now()),
              'suspension_duration': 0, 'watches': false, 'transition': p.transition | default(false) | bool} }}
"@ }) -join ""
# Run counters: HA fires script_started on every script call (also for a queued run that ends early).
# Each counter keeps 200 traces, one per call; the logbook only logs the script turning on.
$extra += (@("resolve", "request") | ForEach-Object { @"

- id: count_$_
  alias: count_$_
  mode: parallel
  max: 500
  trace:
    stored_traces: 200
  triggers:
    - trigger: event
      event_type: script_started
      event_data:
        entity_id: script.smarli_cover_$_
  actions:
    - stop: counted
"@ }) -join ""

# Fire one test_req event; $plan: owner -> @{ targets = @{...}; transition = $bool }
function Req($plan) { HA-Event "test_req" @{ plan = $plan } }
function Pause-Ghosts { foreach ($g in $ghost.Values) { HA-SetKey "cover" "$g::suspension" ((HA-Now) + 3600) }; Start-Sleep 1 }
# Calls of smarli_cover_<name> since $since, from the counter automation's traces. Polling the script's
# `current` attribute misses a burst that is over within one poll.
function Started($name, [datetimeoffset]$since) {
  @((HA-WS @{ type = "trace/list"; domain = "automation"; item_id = "count_$name" }).result |
    Where-Object { [datetimeoffset]$_.timestamp.start -gt $since }).Count
}
# Owners whose ghost cover does not show the planned target yet.
function Missing($targets) { @($targets.Keys | Where-Object { [int](HA-Shared "$($ghost[$_])::resolved") -ne $targets[$_] }) }

T-Prep
HA-Apply -Extra $extra
HA-Call "automation" "turn_on" @{ entity_id = @($owners | ForEach-Object { "automation.$_" }) }
# The tracker GC sweeps 10 s after a reload and removes every key of a cover without an entity, so the
# ghost covers' pauses and decisions would vanish in the middle of a round. Wait for that sweep first.
Start-Sleep 14
Pause-Ghosts

if ($Only.Count -eq 0 -or $Only -contains "burst") {
  Write-Host "`n=== 5b-1 burst: $n callers at once"
  $worst = @(); $runs = @()
  foreach ($round in 1..5) {
    $targets = @{}; $plan = @{}
    foreach ($o in $owners) { $t = Get-Random -Minimum 1 -Maximum 100; $targets[$o] = $t; $plan[$o] = @{ targets = @{ $ghost[$o] = $t } } }
    $since = [datetimeoffset]::Now.AddSeconds(-1)
    Req $plan
    $ok = HA-Wait { (Missing $targets).Count -eq 0 } 15 0.5
    if (-not $ok) { $worst += "round ${round}: $((Missing $targets) -join ', ')" }
    Start-Sleep 2
    $runs += "{0}/{1}" -f (Started "resolve" $since), (Started "request" $since)
  }
  T-Check "5b-1 every caller's decision lands in every burst" ($worst.Count -eq 0) "missing: $($worst -join ' | ')"
  $maxRes = ($runs | ForEach-Object { [int]($_ -split '/')[0] } | Measure-Object -Maximum).Maximum
  T-Check "5b-1 the resolver runs fewer times than there are callers (at most n/2 per burst)" ($maxRes -le $n / 2) "resolver/request runs per burst: $($runs -join ', '), callers: $n"
}

if ($Only.Count -eq 0 -or $Only -contains "spread") {
  Write-Host "`n=== 5b-2 spread: callers 0.2-1 s apart"
  $lost = @()
  foreach ($round in 1..2) {
    $targets = @{}
    foreach ($o in $owners) {
      $t = Get-Random -Minimum 1 -Maximum 100; $targets[$o] = $t
      Req @{ $o = @{ targets = @{ $ghost[$o] = $t } } }
      Start-Sleep -Milliseconds (Get-Random -Minimum 200 -Maximum 1000)
    }
    $ok = HA-Wait { (Missing $targets).Count -eq 0 } 15 0.5
    if (-not $ok) { $lost += "round ${round}: $((Missing $targets) -join ', ')" }
  }
  T-Check "5b-2 no intent is lost when callers are spread out in time" ($lost.Count -eq 0) "missing: $($lost -join ' | ')"
}

if ($Only.Count -eq 0 -or $Only -contains "force") {
  Write-Host "`n=== 5b-3 a transition in the intent forces its cover once, even without its own resolver call"
  # Every caller in a burst carries a transition: every ghost cover must record the caller's ts as applied,
  # also the covers of callers that left the resolving to another run.
  $plan = @{}; foreach ($o in $owners) { $plan[$o] = @{ targets = @{ $ghost[$o] = 42 }; transition = $true } }
  Req $plan
  Start-Sleep 3
  $ok = HA-Wait { @($owners | Where-Object { [double](HA-Shared "$($ghost[$_])::applied") -ne [double](T-Intent $_).ts }).Count -eq 0 } 15 0.5
  $bad = @($owners | Where-Object { [double](HA-Shared "$($ghost[$_])::applied") -ne [double](T-Intent $_).ts })
  T-Check "5b-3 every caller's transition is applied to its cover" $ok "not applied: $($bad -join ', ')"

  # A real cover with a stale decision: resolved 0, but opened by hand. The intent carries a transition and
  # was published with no resolver call of its own (a skipped caller); another owner's call resolves it.
  T-Place $c 0; HA-DelKey "cover" "$c::applied"
  HA-SetKey "cover" "$c::resolved" 0
  HA-HandMove $c 100; HA-ClearSuspensions
  HA-SetKey "cover" "req_01::intent" @{ targets = @{ $c = 0 }; bounds = @{}; priority = 10; ts = (HA-Now); suspension_duration = 0; watches = $false; transition = $true }
  Start-Sleep 1
  Req @{ "req_02" = @{ targets = @{ $ghost["req_02"] = 7 } } }
  $closed = HA-Wait { (T-Pos $c) -le 5 } 30 0.5
  T-Check "5b-3 a skipped caller's transition still commands a cover whose decision did not change" $closed "pos: $(T-Pos $c) | resolved: $(HA-Shared "$c::resolved") | applied: $(HA-Shared "$c::applied")"
  T-Settle $c 30; HA-ClearSuspensions

  # Once per intent: the same intent seen by a later run (another caller) does not command the cover again.
  HA-HandMove $c 100; HA-ClearSuspensions
  Req @{ "req_03" = @{ targets = @{ $ghost["req_03"] = 8 } } }
  Start-Sleep 8
  T-Check "5b-3 an applied transition does not command the cover a second time" ((T-Pos $c) -ge 95) "pos: $(T-Pos $c) | applied: $(HA-Shared "$c::applied")"

  # A repeat publish without transition keeps "only if changed".
  Req @{ "req_01" = @{ targets = @{ $c = 0 } } }
  Start-Sleep 8
  T-Check "5b-3 a publish without transition does not command an unchanged decision" ((T-Pos $c) -ge 95) "pos: $(T-Pos $c) | resolved: $(HA-Shared "$c::resolved")"
  HA-DelKey "cover" "req_01::intent"; T-Settle $c 30; HA-ClearSuspensions
}

if ($Only.Count -eq 0 -or $Only -contains "old") {
  Write-Host "`n=== 5b-4 the resolver call field transition (blueprints before 3.2.0) still forces"
  T-Place $c 0
  HA-SetKey "cover" "$c::resolved" 0
  HA-HandMove $c 100; HA-ClearSuspensions
  HA-StubDay @{ $c = 0 } -transition $true
  $closed = HA-Wait { (T-Pos $c) -le 5 } 30 0.5
  T-Check "5b-4 an old-style transition call commands an unchanged decision" $closed "pos: $(T-Pos $c) | resolved: $(HA-Shared "$c::resolved")"
  HA-DelKey "shared" "stub_day::intent"; T-Settle $c 30; HA-ClearSuspensions
}

foreach ($o in $owners) { HA-DelKey "cover" "$o::intent" }
HA-Apply
T-Prep
