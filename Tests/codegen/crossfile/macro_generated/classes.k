import self::cls_a::*
import self::cls_b::*

// Two generic classes, each with a generic method, from one invocation.
fn main() -> i32 {
    return if use_a() + use_b() == 38 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
