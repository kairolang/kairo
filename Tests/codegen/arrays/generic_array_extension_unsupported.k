// `extend <T> [T; 2]` and `extend <T, eval N: usize> [T; N]` passed
// Sema with members no array could reach: the extension index keys a
// non-record target by its exact canonical, so each use was R025E "no
// member named" with nothing pointing at the block. The block is SC116E
// (extends.mdx: a generic `[T; N]` extension is not supported yet).

extend <T> [T; 2] {
    fn head(const self) -> T { return self[0] }
}

extend <T, eval N: usize> [T; N] {
    fn count(const self) -> usize { return N }
}

// A concrete array target is unaffected.
extend [i32; 2] {
    fn total(const self) -> i32 { return self[0] + self[1] }
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK-DAG: generic_array_extension_unsupported.k:7:12: error [SC116E]: a generic extension of a fixed array is not supported yet; extend each array type it is for, such as 'extend [i32; 2]'
// CHECK-DAG: generic_array_extension_unsupported.k:11:27: error [SC116E]: a generic extension of a fixed array is not supported yet; extend each array type it is for, such as 'extend [i32; 2]'
