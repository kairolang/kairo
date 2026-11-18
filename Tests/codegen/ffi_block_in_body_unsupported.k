// An `ffi "c" { }` block inside a function body is SC116E; it used to reach
// EmitIR as an internal error.
fn main() -> i32 {
    ffi "c" { }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not=I003E --implicit-check-not=internal
// CHECK: ffi_block_in_body_unsupported.k:4:5: error [SC116E]: an 'ffi' block in a function body is not yet supported
