// --no-unsafe makes every `unsafe { }` block a compile error in the program's
// own files. Without the flag the same file is accepted. The error is
// reported at the block, with the flag named in a note.

fn f() -> i32 {
    unsafe { }
    return 0
}

fn main() -> i32 { return f() }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-unsafe %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_unsafe.k:6:{{[0-9]+}}: error [SC001E]: an unsafe block is not allowed when unsafe code is disabled
