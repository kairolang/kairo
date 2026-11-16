import self::fn_a::*
import self::fn_b::*
import self::fn_lib::*

// Generic functions made by one macro invocation, instantiated at the same
// type arguments from files that do not import each other. Each instance
// has one home object; an instance of `second` is never homed with the
// instance of `first` that has its arguments.
fn main() -> i32 {
    // 1 + 20 + 3, 2 + 200 + 4, 5
    var n = use_a() + use_b() + (third<u8>(0, 5) as i32)
    return if n == 235 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
