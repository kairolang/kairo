// What `typeof` cannot do yet is an error, never a crash. In an
// expression position it is a TypeInfo value (type-system.mdx), and
// TypeInfo does not exist; in a type position only a variable's whole
// declared type is resolved, so a typeof nested in another type or in a
// parameter type is reported instead of reaching codegen unresolved. A
// file-scope variable whose typeof names itself is a cycle (SC043E).

var g: typeof g = 1

fn f(a: i32, b: typeof a) {}

fn main() -> i32 {
    var x = 42
    var info = typeof x
    var p: *typeof x = &x
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-DAG: typeof_unsupported.k:8:8: error [SC043E]: cannot take 'typeof' of an expression whose type depends on this declaration's own type
// DIAG-DAG: typeof_unsupported.k:10:17: error [SC270E]: 'typeof' is supported only as the whole declared type of a variable ('var y: typeof x'); write this type out
// DIAG-DAG: typeof_unsupported.k:14:16: error [SC271E]: 'typeof' as a value is a 'TypeInfo', which is not implemented yet; as a type ('var y: typeof x') it is supported
// DIAG-DAG: typeof_unsupported.k:15:13: error [SC270E]: 'typeof' is supported only as the whole declared type of a variable ('var y: typeof x'); write this type out
// DIAG-NOT: {{I0[0-9]+}}
