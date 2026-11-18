// Two blocks of one module are one scope, so what is an error within one
// block is the same error across two: two definitions of a record, and a
// forward declaration whose keyword disagrees with the definition.

module m { struct Twice { var a: i32 } }
module m { struct Twice { var a: i32 } }

module m { struct Kw }
module m { class Kw { var a: i32 } }

fn main() -> i32 { return 0 }

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:6:12: error [R029E]: redefinition of 'Twice'
// DIAG-NEXT: {{.*}}:5:12: note [R029N]: previous definition of 'Twice' is here
// DIAG: {{.*}}:8:12: error [R063E]: 'Kw' is forward-declared as a struct but defined as a class
// DIAG-NEXT: fix-it:"{{.*}}":{8:12-8:18}:"class"
// DIAG-NEXT: {{.*}}:9:12: note [R063N]: 'Kw' is defined here as a class
// END-GENERATED-CHECKS(DIAG)
