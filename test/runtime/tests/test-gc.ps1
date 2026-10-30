# Tracker GC removes orphaned keys (dead automation id, ghost automation, missing entity), keeps live ones.
. "$PSScriptRoot\..\lib\ha.ps1"; . "$PSScriptRoot\..\lib\lib-test.ps1"
T-Prep

# A real ghost: create an automation, reload, delete it, reload -> unavailable entity whose attributes.id lingers
$ghost = @"

- id: gc_ghost_victim
  alias: gc_ghost_victim
  triggers:
    - trigger: event
      event_type: gc_ghost_never
  actions:
    - delay: 1
"@
HA-Apply -Extra $ghost
Start-Sleep 3
$before = HA-StateStr "automation.gc_ghost_victim"
HA-Apply
Start-Sleep 12     # the GC automation itself runs 10 s after the reload; let it finish before seeding
$ghostState = HA-StateStr "automation.gc_ghost_victim"

# seed keys
HA-SetKey "shared" "gc_dead_auto::intent" @{ targets = @{ "cover.vfast" = 0 }; ts = 1 }
HA-SetKey "shared" "gc_ghost_victim::intent" @{ targets = @{ "cover.vfast" = 0 }; ts = 1 }
HA-SetKey "shared" "cover.does_not_exist::resolved" 50
HA-SetKey "shared" "cover.vfast::resolved" 100
HA-SetKey "shared" "global::keepme" 1
HA-SetKey "shared" "stub_day::intent" @{ targets = @{ "cover.vfast" = 100 }; ts = 1 }
HA-SetKey "cover_day_night" "gc_dead_auto::bright_since" 123
HA-SetKey "cover_day_night" "cover_time_test::dark_since" 456
HA-SetKey "test" "no_grammar_key" 1
Start-Sleep 2
HA-Call "script" "smarli_tracker_gc"
Start-Sleep 4
$sh = @(HA-KeyNames "shared"); $cd = @(HA-KeyNames "cover_day_night"); $ts = @(HA-KeyNames "test")
T-Check "gc: dead automation id removed (shared)" (-not ($sh -contains "gc_dead_auto::intent")) "present=$($sh -contains 'gc_dead_auto::intent')"
T-Check "gc: ghost (unavailable) automation key removed" (-not ($sh -contains "gc_ghost_victim::intent")) "ghost entity state before delete=$before after delete=$ghostState; key present=$($sh -contains 'gc_ghost_victim::intent')"
T-Check "gc: key of a missing entity removed" (-not ($sh -contains "cover.does_not_exist::resolved")) "present=$($sh -contains 'cover.does_not_exist::resolved')"
T-Check "gc: dead automation key removed in family namespace" (-not ($cd -contains "gc_dead_auto::bright_since")) "present=$($cd -contains 'gc_dead_auto::bright_since')"
T-Check "gc: live keys kept (entity, global, live automation, off automation)" (($sh -contains "cover.vfast::resolved") -and ($sh -contains "global::keepme") -and ($sh -contains "stub_day::intent") -and ($cd -contains "cover_time_test::dark_since")) "shared=$($sh -join ',') cdn=$($cd -join ',')"
T-Check "gc: key without '::' left alone" ($ts -contains "no_grammar_key") "test ns=$($ts -join ',')"
foreach ($k in "global::keepme", "cover.vfast::resolved", "stub_day::intent") { HA-DelKey "shared" $k }
HA-DelKey "cover_day_night" "cover_time_test::dark_since"; HA-DelKey "test" "no_grammar_key"
T-Prep
