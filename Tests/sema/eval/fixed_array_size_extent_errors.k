// Where `a.size()` is no constant, an array length that names it is an
// error: a receiver whose type phase T cannot read (an inferred local),
// and a `size` the array type declares itself (an extension, not eval).

extend [i32; 3] {
    fn size(const self) -> usize {
        return 30
    }
}

fn main() -> i32 {
    var a = [1, 2, 3, 4]
    var b: [u8; a.size()]
    var c: [i32; 3] = [1, 2, 3]
    var d: [u8; c.size()]
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: fixed_array_size_extent_errors.k:13:17: error [SC192E]: an array length must be computed at compile time: the function this calls is not known here
// CHECK: fixed_array_size_extent_errors.k:15:17: error [SC192E]: an array length must be computed at compile time: the function this calls is not known here
