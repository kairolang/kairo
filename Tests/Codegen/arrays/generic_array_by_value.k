// An array passed BY VALUE to a generic parameter. Arrays are not
// copyable and a parameter does not take one by value (collections.mdx;
// SC045E on a declared `[T; N]`), but with `fn <T> f(a: T)` the array type
// arrives only at the call. C++ then decayed it to a pointer, so the callee
// read and wrote the caller's array. It is SC045E at the argument, with
// the parameter in the note. A generic extension of a fixed array cannot be
// matched by the extension index yet: SC116E at the block, not "no member"
// at every use alone (generic_array_extension_unsupported.k).

interface Sum {
    fn sum(const self) -> i32
}

extend [i32; 2] impl Sum {
    fn sum(const self) -> i32 { return self[0] + self[1] }
}

fn <T impl Sum> get(a: T) -> i32 { return a.sum() }

fn <T> keep(a: T) -> i32 { return 0 }

// A const one is fine: no copy.
fn <T> peek(const a: T) -> i32 { return 0 }

fn main() -> i32 {
    var a: [i32; 2] = [1, 2]
    return get(a) + keep(a) + peek(a)
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK-DAG: generic_array_by_value.k:27:16: error [SC045E]: parameter 'a' takes '[i32; 2]' by value here, and an array is not copyable; make it 'const', '@inout', or pass a slice
// CHECK-DAG: generic_array_by_value.k:18:21: note [I900N]: 'a' is declared here, by value
// CHECK-DAG: generic_array_by_value.k:27:26: error [SC045E]: parameter 'a' takes '[i32; 2]' by value here, and an array is not copyable; make it 'const', '@inout', or pass a slice
// CHECK-DAG: generic_array_by_value.k:20:13: note [I900N]: 'a' is declared here, by value
