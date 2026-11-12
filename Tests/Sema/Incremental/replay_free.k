// Incremental Sema, phase 5: a live check frees the trees its re-checks
// replaced (Tooling::LiveCheck::_release_retired), once every queued file is
// re-checked. Before the free, every address of theirs leaves the build-wide
// stores that are keyed by one or hold one: the canonical type table (a
// record type is keyed by its declaration), the conformance rows, the
// dropped instances. The next step's trees then land on those addresses.
//
// Inputs/free.replay over Inputs/free names the stores: Box<Point>, Point?
// and [Point] of a record that is re-read; `extend i32 impl Named`, whose
// row is found by (i32, Named) and held a witness of the old tree.
//
// witness_renamed is also a bug of the retraction, fixed with this: the row
// stayed in the table, so the re-check was answered from the old text and
// the client's `len_of(n)` kept conforming (no SC162E).
//
// The oracle (Scripts/incr_replay_check.py), per step: stderr and
// --dump-interface equal a fresh run's, byte for byte.

// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/free %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/free.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 6 witness_renamed: refresh {{.*}} ok
// CHECK: step 8 witness_back: refresh {{.*}} ok
// CHECK: step 15 record_body_last: refresh {{.*}} ok
// CHECK: modes: full 1, refresh 15; 16 steps

// One batch per edit instead of two tiers: the free comes at the end of
// each refresh.
// RUN: rm -rf %t.b && mkdir -p %t.b/p && cp -r %S/Inputs/free %t.b/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.b/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --overlay --script %S/Inputs/free.replay --scratch %t.b/scratch | %FileCheck %s --check-prefix=BATCH --implicit-check-not=DIFFERS
// BATCH: modes: full 1, refresh 15; 16 steps

// The use-after-free check: KAIRO_LIVE_POISON overwrites each replaced tree
// with 0xDD and keeps it, so anything that still reads one reads no address
// and no node of a new tree.
// RUN: rm -rf %t.p && mkdir -p %t.p/p && cp -r %S/Inputs/free %t.p/p/s
// RUN: env KAIRO_LIVE_POISON=1 python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.p/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/free.replay --scratch %t.p/scratch | %FileCheck %s --check-prefix=POISON --implicit-check-not=DIFFERS
// POISON: modes: full 1, refresh 15; 16 steps

// The same over the other fixtures' scripts.
// RUN: rm -rf %t.q && mkdir -p %t.q/p && cp -r %S/Inputs/plan %t.q/p/s
// RUN: env KAIRO_LIVE_POISON=1 python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.q/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/tier.replay --scratch %t.q/scratch | %FileCheck %s --check-prefix=PTIER --implicit-check-not=DIFFERS
// PTIER: modes: full 1, refresh 9; 10 steps
// RUN: rm -rf %t.r && mkdir -p %t.r && cp -r %S/Inputs/proj %t.r/proj
// RUN: env KAIRO_LIVE_POISON=1 python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.r/proj --from-scenarios %t.r/proj/scenarios.json --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --scratch %t.r/scratch | %FileCheck %s --check-prefix=PPROJ --implicit-check-not=DIFFERS
// PPROJ: modes: full {{[0-9]+}}, refresh {{[0-9]+}}; 89 steps
