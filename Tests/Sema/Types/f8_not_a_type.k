// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// `f8` is a reserved primitive keyword, but no 8-bit float format is
// spelled by it (the docs name f8e4m3 and f8e5m2). It was an internal error
// ("unresolved type reached codegen"); it is an unknown type name with
// the format spelled in a fix-it.
// CHECK: f8_not_a_type.k:12:12: error [R021E]: unknown type name 'f8'
// CHECK: fix-it:{{.*}}:{12:12-12:14}:"f8e4m3"
// CHECK: f8_not_a_type.k:13:18: error [R021E]: unknown type name 'f8'
// CHECK-NOT: I003E

fn main() -> i32 {
    var a: f8 = 3
    var b = 1 as f8
    return 0
}
