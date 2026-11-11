// Incremental Sema, phase 4, re-checking in place: Kairo records handed to
// a C++ template. `std::vector<Local>` makes clang instantiate over a
// STAND-IN for Local declared in the header set's AST, which is kept
// across a re-check. A record that is re-read adopts the stand-in declared
// for it (ForeignRegistry::adopt) and its instances are filled again; the
// stand-in keeps the layout clang was given, so an edit that changes the
// record's layout is a full check that says so. Every step equals a fresh
// run (Scripts/incr_replay_check.py).

// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/cxx %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --script %S/Inputs/cxx.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 1 entry_body: refresh (1 of {{[0-9]+}} files) {{.*}} ok
// CHECK: step 2 imported_body: refresh (2 of {{[0-9]+}} files) {{.*}} ok
// CHECK: step 3 entry_error: refresh {{.*}} ok
// CHECK: step 4 entry_fixed: refresh {{.*}} ok
// CHECK: step 5 own_layout: full (a record handed to a C++ template changed its layout: main#struct:Own) {{.*}} ok
// CHECK: step 6 entry_body_again: refresh {{.*}} ok
// CHECK: step 7 imported_layout: full (a record handed to a C++ template changed its layout: local#struct:Local) {{.*}} ok
// CHECK: step 8 imported_body_again: refresh {{.*}} ok
// CHECK: modes: full 3, refresh 6; 9 steps
