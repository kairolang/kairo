// An `eval` constant of slice type needs a compile-time Slice, and
// the library's has no constexpr constructor: a local one would reach clang
// ("constexpr variable cannot have non-literal type Slice<int>") and a
// file-scope one fail in ListLiteralLowering. It is SC116E at the
// declaration until the library has one. A fixed array is the
// compile-time form today; a vector, set or map is SC116E too, and a
// string has a compile-time form.

eval FILE_SCOPE: [i32;] = [1, 2]
eval ARR: [i32; 2] = [1, 2]
eval STR: string = "ab"

fn main() -> i32 {
    eval LOCAL: [i32;] = [3, 4]
    return ARR[1] + (STR.size() as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_slice_gate.k:9:6: error [SC116E]: an 'eval' constant of slice type '[i32;]' is not yet supported: a slice has no compile-time form; declare 'FILE_SCOPE' as a fixed array
// CHECK: eval_slice_gate.k:14:10: error [SC116E]: an 'eval' constant of slice type '[i32;]' is not yet supported: a slice has no compile-time form; declare 'LOCAL' as a fixed array
