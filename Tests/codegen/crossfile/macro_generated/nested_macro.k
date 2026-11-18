import self::nest_a::*
import self::nest_b::*

// A macro whose body invokes another macro twice: both generated generics
// are at the outer invocation.
fn main() -> i32 {
    return if use_a() + use_b() == 42 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
