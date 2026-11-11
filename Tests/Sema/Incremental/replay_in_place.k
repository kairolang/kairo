// Incremental Sema, phase 4: re-checking in place
// (--incr-replay-in-place, Tooling::LiveCheck::in_place). On an edit the
// REFRESH SET (the file and every file that imports it, however far) is
// re-read, re-parsed and re-checked against the rest of the graph, which is
// kept as it stands: trees, types, diagnostics, the C header set. An edit
// that cannot be re-checked in place is a full check that says why.
//
// The oracle is Scripts/incr_replay_check.py: every step's stderr and
// --dump-interface equal a fresh run's, byte for byte.
//
// Inputs/plan.replay over Inputs/plan: the modes are pinned, so an edit
// cannot slide to the full path, or off it, without this test saying so.

// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/plan %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --script %S/Inputs/plan.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 1 body: refresh (3 of 38 files) {{.*}} ok
// CHECK: step 2 signature: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 3 private_field: refresh (3 of 38 files) {{.*}} ok
// CHECK: step 4 generic_body: refresh (3 of 38 files) {{.*}} ok
// CHECK: step 5 decl_added: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 6 decl_removed: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 7 line_shift: refresh (3 of 38 files) {{.*}} ok
// CHECK: step 8 header: full (a C or C++ header) {{.*}} ok
// CHECK: step 9 file_added: full (not a checked file of the graph) {{.*}} ok
// CHECK: step 10 error_introduced: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 11 reader_edited_while_broken: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 12 error_fixed: refresh (2 of 38 files) {{.*}} ok
// CHECK: step 13 private_made_public: refresh (3 of 38 files) {{.*}} ok
// CHECK: step 14 file_removed: full (not a checked file of the graph) {{.*}} ok
// CHECK: modes: full 4, refresh 11; 15 steps
