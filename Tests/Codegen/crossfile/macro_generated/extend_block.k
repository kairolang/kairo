import self::ext_a::*
import self::ext_b::*

// Generic extension members from one invocation.
fn main() -> i32 {
    return if use_a() + use_b() == 23 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
