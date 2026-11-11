// Incremental Sema, phase 5: a live check fed BUFFERS, as a language server
// with unsaved files feeds it (Tooling::LiveCheck::set_overlay,
// --incr-replay-overlay). Every edit of an existing .k file reaches the
// live process as a buffer and the disk keeps the old text, so a refresh
// that re-read the disk would print the old result. The oracle's clean side
// applies the edits to the disk and runs a fresh process:
// Scripts/incr_replay_check.py --overlay, stderr and --dump-interface byte
// for byte.
//
// The full path is in it too (a header edit, a file added and removed): a
// buffer is given to the file where the graph first loads it, so it has the
// file id the disk's text would have and diagnostics come in the same order.

// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/plan %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --overlay --script %S/Inputs/plan.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 1 body: refresh (3 of 38 files) {{.*}} ok
// CHECK: step 2 signature: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 8 header: full (a C or C++ header) {{.*}} ok
// CHECK: step 10 error_introduced: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 12 error_fixed: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 14 file_removed: full (not a checked file of the graph) {{.*}} ok
// CHECK: modes: full 4, refresh 11; 15 steps

// The 44 scenarios of Inputs/proj and their reversals the same way.
// RUN: rm -rf %t.e && mkdir -p %t.e && cp -r %S/Inputs/proj %t.e/proj
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.e/proj --from-scenarios %t.e/proj/scenarios.json --flag=--threads=2 --flag=--incr-replay-in-place --overlay --scratch %t.e/scratch | %FileCheck %s --check-prefix=PROJ --implicit-check-not=DIFFERS
// PROJ: step 0 initial: full (the first check) {{.*}} ok
// PROJ: modes: full {{[0-9]+}}, refresh {{[0-9]+}}; 89 steps
