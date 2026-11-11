// Incremental Sema, phase 1 (Compiler/Spec/IncrementalSema.md): the
// dependency log is complete for every edit in Inputs/proj/scenarios.json.
//
// Scripts/incr_oracle.py applies each edit to a copy of Inputs/proj, predicts
// from the dumps taken BEFORE the edit and the interface diff which files
// must be re-checked, and compares every other file's --print-sema section
// and diagnostics before and after. A file predicted unaffected that differs
// is a hole in the log and fails the test by name.
//
// Each scenario also pins its re-check set (`expect`), so precision cannot
// slide either way without this test saying so: a body edit of a plain
// function re-checks its file alone, a signature edit its readers, an added
// overload every file that looked the name up, picked or not.
//
// The project has three deliberate errors (a missing member, a missing
// operator, a private name), each of which a scenario makes go away.

// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/proj %t.d/proj
// RUN: python3 %S/../../../Scripts/incr_oracle.py --kairo %kairo_bin --root %t.d/proj --scenarios %t.d/proj/scenarios.json --flag=--threads=2 --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=HOLE --implicit-check-not=UNEXPECTED

// CHECK: scenario predicted changed over verdict
// CHECK: body_plain 1 1 0 ok
// CHECK: signature {{.*}} ok
// CHECK: overload_picked 2 2 0 ok
// CHECK: overload_unpicked 2 2 0 ok
// CHECK: remove_decl {{.*}} ok
// CHECK: field_type {{.*}} ok
// CHECK: field_added {{.*}} ok
// CHECK: fields_reordered {{.*}} ok
// CHECK: private_method 1 1 0 ok
// CHECK: generic_body {{.*}} ok
// CHECK: eval_const_value {{.*}} ok
// CHECK: eval_fn_body {{.*}} ok
// CHECK: enum_discriminant {{.*}} ok
// CHECK: type_alias {{.*}} ok
// CHECK: reexport_chain {{.*}} ok
// CHECK: extension_method_added {{.*}} ok
// CHECK: extension_block_added {{.*}} ok
// CHECK: out_of_line_body 1 0 0 ok
// CHECK: default_argument {{.*}} ok
// CHECK: cycle_body 1 0 0 ok
// CHECK: cycle_signature_used {{.*}} ok
// CHECK: private_made_public {{.*}} ok
// CHECK: macro_body {{.*}} ok
// CHECK: generic_inferred_transitive {{.*}} ok
// CHECK: const_transitive {{.*}} ok
