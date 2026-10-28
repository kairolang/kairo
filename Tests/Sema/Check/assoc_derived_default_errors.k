// What a derived interface may write about an inherited associated type
// (interfaces.md, "Associated types and inheritance"): only a default, and
// only where the declaring interface gives none. Restating it, adding
// bounds, or changing an existing default is an error at the
// redeclaration, with a note at the inherited declaration. The working
// side is Tests/Codegen/witness/assoc_type_derived_default.k.

interface Display { fn show(const self) -> i32 }

interface Graph {
    type Node
    type Weight = i32
    fn first(const self) -> Self::Node
}

interface Restates derives Graph {
    type Node
}

interface Bounds derives Graph {
    type Node impl Display = i64
}

interface Changes derives Graph {
    type Weight = i64
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:17:10: error [SC001E]: 'Node' is inherited; a derived interface may only give it a default ('type Node = ...')
// DIAG-NEXT: fix-it:"{{.*}}":{17:5-17:14}:""
// DIAG-NEXT: {{.*}}:11:5: note [I900N]: the inherited associated type is declared here
// DIAG: {{.*}}:21:10: error [SC001E]: 'Node' is inherited with its bounds; a derived interface may give it a default but not bounds of its own
// DIAG-NEXT: {{.*}}:11:5: note [I900N]: the inherited associated type is declared here
// DIAG: {{.*}}:25:10: error [SC001E]: 'Weight' already has a default where it is declared; a derived interface may not change it
// DIAG-NEXT: fix-it:"{{.*}}":{25:5-25:22}:""
// DIAG-NEXT: {{.*}}:12:5: note [I900N]: the inherited associated type is declared here
// END-GENERATED-CHECKS(DIAG)
