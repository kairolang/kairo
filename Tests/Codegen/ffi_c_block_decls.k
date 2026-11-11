// An `ffi "c" { ... }` block groups top-level declarations, each stamped
// with the block's linkage (imports.mdx, FFI Linkage Declarations). Codegen
// does not emit the block itself (no body of its own); its functions are
// declared as if each
// had been written with its own `ffi "c"`, and calls reach libc.

ffi "c" {
    fn abs(x: i32) -> i32
    fn labs(x: i64) -> i64
}

fn main() -> i32 {
    return abs(-3) + (labs(-4) as i32)   // exit 7
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: %t.exe; test $? -eq 7
