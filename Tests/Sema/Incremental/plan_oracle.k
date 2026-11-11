// Incremental Sema: the compiler's own invalidation rules
// (Compiler/Sema/Incremental/Plan.k) give the re-check set that
// Scripts/incr_oracle.py predicts, for every scenario of Inputs/proj.
//
// The oracle works from the two dumps; the compiler from the records an
// --incremental-sema run of the unedited project stored (a run with three
// errors: records are written by a run that has them). Per scenario the
// edited project is run with --incr-verify --print-incr-plan against a copy
// of those records. `plan-agrees` is: the modules the compiler prints are
// exactly the predicted ones, and its own verification passed (every module
// it leaves out has the interface and diagnostics of its record).

// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/proj %t.d/proj
// RUN: python3 %S/../../../Scripts/incr_oracle.py --kairo %kairo_bin --root %t.d/proj --scenarios %t.d/proj/scenarios.json --flag=--threads=2 --scratch %t.d/scratch --compiler-plan | %FileCheck %s --implicit-check-not=HOLE --implicit-check-not=UNEXPECTED --implicit-check-not=DIFFERS

// CHECK: scenario predicted changed over verdict
// CHECK: body_plain 1 1 0 ok plan-agrees
// CHECK: signature {{.*}} ok plan-agrees
// CHECK: overload_unpicked 2 2 0 ok plan-agrees
// CHECK: field_type {{.*}} ok plan-agrees
// CHECK: private_field {{.*}} ok plan-agrees
// CHECK: generic_body {{.*}} ok plan-agrees
// CHECK: reexport_cut {{.*}} ok plan-agrees
// CHECK: extension_block_added {{.*}} ok plan-agrees
// CHECK: cycle_signature_used {{.*}} ok plan-agrees
// CHECK: import_collision {{.*}} ok plan-agrees
// CHECK: macro_body {{.*}} ok plan-agrees
// CHECK: const_transitive {{.*}} ok plan-agrees
