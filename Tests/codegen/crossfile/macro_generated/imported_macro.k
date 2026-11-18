import self::imp_a::*
import self::imp_b::*

// The macro is defined in one file and invoked in another: the generated
// generics belong to the invoking file, and each instance has a home.
fn main() -> i32 {
    return if use_a() + use_b() == 17 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
