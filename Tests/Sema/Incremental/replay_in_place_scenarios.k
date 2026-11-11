// Incremental Sema, phase 4: the 44 scenarios of Inputs/proj and their
// reversals as one live session that re-checks in place
// (--incr-replay-in-place): 89 checks, each compared with a fresh run
// (stderr byte for byte, and --dump-interface). The project has generic
// instantiation readers, extension methods and blocks, eval functions and
// constants folded through other files, a macro-defining file, an import
// cycle, re-exports, out-of-line definitions and three errors that
// scenarios make go away and come back.
//
// No step may differ; how many refresh in place is printed, not pinned
// here (it grows as fewer edits need the full path).

// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/proj %t.d/proj
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/proj --from-scenarios %t.d/proj/scenarios.json --flag=--threads=2 --flag=--incr-replay-in-place --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: body_plain: refresh ({{[0-9]+}} of {{[0-9]+}} files) {{.*}} ok
// CHECK: generic_body: refresh {{.*}} ok
// CHECK: macro_body: refresh {{.*}} ok
// CHECK: modes: full {{[0-9]+}}, refresh {{[0-9]+}}; 89 steps
