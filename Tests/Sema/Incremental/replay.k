// Incremental Sema, phase 4 (Compiler/Spec/IncrementalSema.md): a live
// check. `kairo --incr-replay=<script>` type-checks the entry once and then
// applies the script's edits step by step in ONE process
// (Compiler/Tooling/LiveCheck.k), printing each step's diagnostics.
// Scripts/incr_replay_check.py is the oracle: after each step it runs a
// fresh `kairo --type-check-only` on the files as they then stand and
// requires the same stderr, byte for byte, and the same --dump-interface.
//
// Inputs/plan.replay over Inputs/plan: a body, a signature, a private
// field's type, a generic body, a declaration added and removed, a line
// shift under another file's note, a C header, a file added, an error
// introduced, another file edited while it stands, the error fixed, a
// private name made public, a file removed.
//
// Every step is `full` today: re-checking in place is not built, and a step
// is a full check in a new CompilerInstance inside the same process. The
// modes line is pinned so a step that starts re-checking in place has to
// say so here.

// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/plan %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --script %S/Inputs/plan.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 1 body: full {{.*}} ok
// CHECK: step 2 signature: full {{.*}} ok
// CHECK: step 7 line_shift: full {{.*}} ok
// CHECK: step 8 header: full {{.*}} ok
// CHECK: step 9 file_added: full {{.*}} ok
// CHECK: step 10 error_introduced: full {{.*}} ok
// CHECK: step 12 error_fixed: full {{.*}} ok
// CHECK: step 14 file_removed: full {{.*}} ok
// CHECK: modes: full 15; 15 steps
