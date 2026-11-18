// The braces of an `ffi "lang" { }` block group declarations of the
// enclosing scope, so a macro defined inside one is visible after the
// block's closing brace, to the end of the enclosing scope. (In a function
// body: errors/macro_ffi_block_scope.k; `eval { }`:
// macro_eval_block_transparent.k.)

ffi "c" {
    macro from_ffi!() { 2 }
}

fn main() -> i32 {
    return from_ffi!() - 2
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
