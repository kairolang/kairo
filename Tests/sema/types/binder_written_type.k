// A type written on a loop or destructuring binder is checked as the type of
// `var y: T = elem`: the value the binder takes must convert to it, and a name
// that is no type is an error.

fn main() -> i32 {
    var xs = [1, 2, 3]
    for y: string in xs { }
    for y: i64 in xs {
        var q: i32 = y
    }
    var t = (1, 2)
    var (a: string, b) = t
    var m = {"a": 1}
    for (k: i32, v: i64) in m { }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: binder_written_type.k:7:9: error [SC041E]: cannot convert 'i32' to 'string', the type written on the binding
// CHECK: binder_written_type.k:9:22: error [SC028E]: cannot convert 'i64' to 'i32'
// CHECK: binder_written_type.k:12:10: error [SC041E]: cannot convert 'i32' to 'string', the type written on the binding
// CHECK: binder_written_type.k:14:10: error [SC041E]: cannot convert 'string' to 'i32', the type written on the binding
// CHECK-NOT: error
