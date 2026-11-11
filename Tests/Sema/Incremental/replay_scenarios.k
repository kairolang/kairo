// Incremental Sema, phase 4: the 44 scenarios of Inputs/proj as ONE live
// session (Scripts/incr_replay_check.py --from-scenarios): each scenario's
// edits, then their reversal, 89 checks in one process, each compared with
// a fresh run (diagnostics byte for byte, and --dump-interface). The
// project covers what a re-check in place has to get right: generic
// instantiation readers, extension methods and blocks, eval functions and
// constants folded through other files, macro-defining files, import
// cycles, re-exports, out-of-line definitions, and three errors that
// scenarios make go away and come back.

// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/proj %t.d/proj
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/proj --from-scenarios %t.d/proj/scenarios.json --flag=--threads=2 --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: body_plain: full {{.*}} ok
// CHECK: body_plain.revert: full {{.*}} ok
// CHECK: generic_body: full {{.*}} ok
// CHECK: extension_block_added: full {{.*}} ok
// CHECK: macro_body: full {{.*}} ok
// CHECK: const_transitive.revert: full {{.*}} ok
// CHECK: modes: full 89; 89 steps
