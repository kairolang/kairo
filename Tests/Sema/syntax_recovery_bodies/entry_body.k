// --check-past-syntax-errors on the entry itself: its error is inside a
// body that kept it, so the entry is checked without that body. The
// healthy function below it is checked (its type error is reported), and
// nothing is said about the broken one or its callers.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --implicit-check-not=error
// RUN: { %kairo %s --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --check-prefix=ON --implicit-check-not=error
//
// OFF: entry_body.k:16:17: error [S052E]: expected expression, found ';'
// ON-DAG: entry_body.k:16:17: error [S052E]: expected expression, found ';'
// ON-DAG: entry_body.k:22:18: error [SC028E]: cannot convert 'string' to 'i32'

fn broken(v: i32) -> i32 {
    var a = v * 2
    var b: string = a
    var w = v + ;
    return w
}

fn main() -> i32 {
    var n = broken(1)
    var z: i32 = "checked"
    return n
}
