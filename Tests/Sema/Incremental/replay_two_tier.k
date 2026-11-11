// Incremental Sema, phase 5: two tiers (Tooling::LiveCheck::two_tier,
// --incr-replay-two-tier). An edit re-checks the EDITED file at once, with
// the queued files it imports, and queues the files that import it; they
// are re-checked afterwards, in slices, in the order Sema runs files. A
// later edit pre-empts: its first tier runs before the rest of the queue.
//
// The rule that makes the first tier's result the right one: a file is
// re-checked only when no file it imports, however far, is still queued.
//
// The oracle (Scripts/incr_replay_check.py --two-tier), per step:
//   - the last edit's first tier reported, for the edited file, what a
//     fresh run reports there;
//   - once the queue is empty, stderr and --dump-interface equal a fresh
//     run's, byte for byte.
// Buffers are overlays (--overlay): the disk keeps the old text.

// Inputs/tier.replay over Inputs/plan: a breaking signature and its fix, an
// edit pre-empting a half-drained queue, two files alternating, an edit of
// a file that is itself queued, an edit of the entry with everything queued.
// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/plan %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/tier.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 1 leaf_body: refresh (2 of 38 files, 0 pending) {{.*}} fg util.k refresh {{[0-9]+}} ms (1 of 38 files, 2 pending); ok
// CHECK: step 2 signature_breaks_importer: refresh (1 of 38 files, 0 pending) {{.*}} fg geo.k refresh {{[0-9]+}} ms (1 of 38 files, 1 pending); ok
// CHECK: step 3 signature_fixed: refresh {{.*}} ok
// CHECK: step 4 preempt_half_drained: refresh {{.*}} fg util.k refresh {{[0-9]+}} ms (1 of 38 files, 2 pending); fg counter.k refresh {{[0-9]+}} ms (1 of 38 files, 2 pending); ok
// CHECK: step 5 alternating: refresh {{.*}} fg hidden.k refresh {{[0-9]+}} ms (1 of 38 files, 3 pending); ok
// CHECK: step 6 edit_a_queued_file: refresh {{.*}} fg use_util.k refresh {{[0-9]+}} ms (1 of 38 files, 1 pending); ok
// The entry imports everything queued: its first tier is all of it.
// CHECK: step 7 edit_the_entry_while_everything_is_queued: refresh {{.*}} fg main.k refresh {{[0-9]+}} ms ({{[0-9]+}} of 38 files, 0 pending); ok
// CHECK: step 9 counter_back: refresh {{.*}} ok
// CHECK: modes: full 1, refresh 9; 10 steps

// The plan fixture's own script (a header edit, files added and removed).
// RUN: rm -rf %t.f && mkdir -p %t.f/p && cp -r %S/Inputs/plan %t.f/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.f/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/plan.replay --scratch %t.f/scratch | %FileCheck %s --check-prefix=PLAN --implicit-check-not=DIFFERS
// PLAN: modes: full 4, refresh 11; 15 steps

// Instances whose first use moves (Inputs/live): the check that one batch
// makes at its end is made when the queue empties, or at the slice that
// uses the instance too early.
// RUN: rm -rf %t.g && mkdir -p %t.g/p && cp -r %S/Inputs/live %t.g/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.g/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/live.replay --scratch %t.g/scratch | %FileCheck %s --check-prefix=INST --implicit-check-not=DIFFERS
// INST: step 3 a_stops_naming_it: full (an instance the edited files used first is now used first by a kept file) {{.*}} fg a.k refresh {{.*}} ok
// INST: step 5 a_names_it_again: full (the edited files now use an instance before the kept file that used it first) {{.*}} ok
// INST: modes: full 3, refresh 8; 11 steps

// Records handed to a C++ template (Inputs/cxx): a layout change is seen by
// the slice that re-reads the record, or by the one that hands it over.
// RUN: rm -rf %t.h && mkdir -p %t.h/p && cp -r %S/Inputs/cxx %t.h/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.h/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/cxx.replay --scratch %t.h/scratch | %FileCheck %s --check-prefix=CXX --implicit-check-not=DIFFERS
// CXX: step 7 imported_layout: full (a record handed to a C++ template changed its layout: local#struct:Local) {{.*}} fg local.k refresh {{.*}} ok
// CXX: modes: full 3, refresh 6; 9 steps

// The 44 scenarios of Inputs/proj and their reversals.
// RUN: rm -rf %t.e && mkdir -p %t.e && cp -r %S/Inputs/proj %t.e/proj
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.e/proj --from-scenarios %t.e/proj/scenarios.json --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --scratch %t.e/scratch | %FileCheck %s --check-prefix=PROJ --implicit-check-not=DIFFERS
// PROJ: step 0 initial: full (the first check) {{.*}} ok
// PROJ: modes: full {{[0-9]+}}, refresh {{[0-9]+}}; 89 steps
