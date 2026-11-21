// A pack element given away by value (`for a in args { one(a) }`, `one`
// taking its parameter by value) is copied at every instance. At an instance
// whose element cannot be copied (a string) that is SC182E at the instance,
// not a deleted copy constructor in clang; an instance of copyable elements
// is accepted, and a `const` parameter borrows the element at any instance.

fn <T> one(x: T) -> i32 { return 1 }
fn <T> peek(const x: T) -> i32 { return 1 }

fn <...T> count(...args: T) -> i32 {
    var n = 0
    for arg in args {
        n += one(arg)
    }
    return n
}

fn <...T> count_const(...args: T) -> i32 {
    var n = 0
    for arg in args {
        n += peek(arg)
    }
    return n
}

fn main() -> i32 {
    var a = count(1, true, 2.5)
    var b = count_const(1, "hello", true)
    var c = count(1, "hello", true)
    return a + b + c
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      pack_element_copy_instance.k:29:13: error [SC182E]: cannot copy a value of type 'string' in 'count<i32, string, bool>': 'arg' is an element of a pack, which a transfer copies
// CHECK-NEXT: pack_element_copy_instance.k:13:18: note [I900N]: 'arg' is copied here, as a 'string'
