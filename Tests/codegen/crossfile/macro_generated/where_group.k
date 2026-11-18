import self::where_lib::*

// A `where` group from one macro invocation: its members are at one source
// position, and each still has its own candidate function.
fn main() -> i32 {
    return if grade(95) + grade(85) + grade(10) == 7 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
