// A generic body is typed once, over its parameters, so a copy of a
// `T` passes there; a call that binds T to a fixed array then copies an
// array, which is not copyable (collections.mdx; SC083E for a concrete one).
// clang said "array initializer must be an initializer list" or "array
// type is not assignable". It is SC083E at the argument T is deduced from,
// naming the generic, the parameter and the array, with a note at the copy.
// A body that only reads its `T` is fine. The same holds for a generic
// class's constructor, whose T the call binds, and for a callee defined
// after its caller (its body is not typed yet when the call is).

fn <T> init_copy(const a: T) -> i32 {
    var b: T = a
    return 1
}

fn <T> assign_copy(const a: T, @inout o: T) -> i32 {
    o = a
    return 1
}

fn <T> give(const a: T) -> T {
    return a
}

class <T> Box {
    var v: T
    fn Box(self, const a: T) { self.v = a }
}

fn <T> reads(const a: T) -> i32 {
    const p = &a
    return 0
}

fn main() -> i32 {
    var x: [i32; 2] = [1, 2]
    var y: [i32; 2] = [3, 4]
    var n = init_copy(x) + assign_copy(x, &y) + reads(x)
    give(x)
    var bx = Box<[i32; 2]>(x)
    // Not an array: fine.
    return n + init_copy(3) + later(x)
}

fn <T> later(const a: T) -> i32 {
    var b = a
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: generic_array_copy_body.k:38:23: error [SC083E]: 'init_copy' copies a 'T', which is '[i32; 2]' here, and an array is not copyable; pass a slice, or a pointer to the array
// CHECK: generic_array_copy_body.k:12:16: note [I900N]: this initializer copies a 'T'
// CHECK: generic_array_copy_body.k:38:40: error [SC083E]: 'assign_copy' copies a 'T', which is '[i32; 2]' here
// CHECK: generic_array_copy_body.k:17:5: note [I900N]: this assignment copies a 'T'
// CHECK: generic_array_copy_body.k:39:10: error [SC083E]: 'give' copies a 'T', which is '[i32; 2]' here
// CHECK: generic_array_copy_body.k:21:28: note [I900N]: 'give' returns its 'T' by value
// CHECK: generic_array_copy_body.k:40:28: error [SC083E]: 'Box' copies a 'T', which is '[i32; 2]' here
// CHECK: generic_array_copy_body.k:27:32: note [I900N]: this assignment copies a 'T'
// CHECK: generic_array_copy_body.k:42:37: error [SC083E]: 'later' copies a 'T', which is '[i32; 2]' here
// CHECK: generic_array_copy_body.k:46:13: note [I900N]: this initializer copies a 'T'
