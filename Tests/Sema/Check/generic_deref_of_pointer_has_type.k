// `var m = *a` with a: unsafe *T in a generic body had no type (the
// dereference of a dependent pointer deferred), so codegen reported I011W.
fn <T> first(a: unsafe *T) -> T {
    unsafe {
        var m = *a
        return m
    }
}

fn main() -> i32 {
    var x: i32 = 4
    return unsafe first(unsafe &x)
}

// --- lit wiring ---
// RUN: { %kairo %s -o %t.out --error-format=basic 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: %t.out; test $? -eq 4
// CHECK-NOT: I011W
