ffi "c++" import "stray.k"

// An ffi import that names a .k itself: clang read the Kairo text as C++
// (CL001E inside stray.k). Now one error at the import, saying to use
// `import`.
fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      direct.k:1:18: error [R070E]: 'stray.k' is a Kairo source file, which `ffi import` cannot read as a C or C++ header
// CHECK-NEXT: note [R070N]: a Kairo file is imported with `import`, not `ffi import`; this one is `import self::stray`
// CHECK-NOT:  {{error|warning}} [
