// An array field is initialized from a list literal and nothing else
// (collections.mdx: an array is not copyable), at every level of an array
// of arrays, exactly as a `var` is: anything else is SC083E. An eval array
// field's initializer is still SC116E: its constexpr definition follows a
// single consteval thunk, and the element-wise lowering makes several.

eval K: [i32; 3] = [7, 8, 9]
eval K2: [i32; 2] = [7, 8]

class C {
    pub var h: [i32; 3] = K
// DIAG: array_field_initializer_errors.k:[[@LINE-1]]:27: error [SC083E]: an array is not copyable; initialize it from a list literal, or view the source through a slice or a pointer
    pub var p: [i32; 3] = (K)
// DIAG: array_field_initializer_errors.k:[[@LINE-1]]:28: error [SC083E]: an array is not copyable
    pub var n: [[i32; 2]; 2] = [K2, [3, 4]]
// DIAG: array_field_initializer_errors.k:[[@LINE-1]]:33: error [SC083E]: an array is not copyable
    pub static s: [[i32; 2]; 2] = [[1, 2], K2]
// DIAG: array_field_initializer_errors.k:[[@LINE-1]]:44: error [SC083E]: an array is not copyable
    pub eval e: [i32; 2] = [1, 2]
// DIAG: array_field_initializer_errors.k:[[@LINE-1]]:28: error [SC116E]: an initializer on an eval array-typed field is not yet supported
}

fn main() -> i32 {
    // The same rule for a list element of a local: an element of an array
    // of arrays is initialized from a list literal too.
    var y: [[i32; 2]; 2] = [K2, [3, 4]]
// DIAG: array_field_initializer_errors.k:[[@LINE-1]]:29: error [SC083E]: an array is not copyable
    return y[1][0]
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
