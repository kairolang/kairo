import self::ovl_a::*
import self::ovl_b::*

// One macro invoked once per family: each invocation makes overloads of the
// same names. The instances of one invocation's functions at one type
// argument are separate entities with separate homes.
fn main() -> i32 {
    // 1 + 22, 11 + 100 + 1000
    return if use_a() + use_b() == 1134 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
