// An `ffi "c"` block with a single member, beside a block of a
// different shape and used from a nested function, compiles and runs
// without an internal error.

ffi "c" {
    fn abs(x: i32) -> i32
}

ffi "c" {
    fn labs(x: i64) -> i64
    fn toupper(c: i32) -> i32
}

fn helper(x: i32) -> i32 {
    return abs(x) + toupper(97) - 65
}

fn main() -> i32 {
    if helper(-2) != 2 { return 1 }
    if (labs(-5) as i32) != 5 { return 2 }
    return 0
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='I003E' --implicit-check-not='internal' --implicit-check-not='error ['
// RUN: %t.exe
