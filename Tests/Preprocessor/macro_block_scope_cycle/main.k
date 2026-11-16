import self::one::*
import self::two::*

// one.k and two.k import each other, so each file's macros are collected
// ahead of its walk. A block's macro is not collected: each function body
// still defines its own `arm!`, and a block's macro sees the module-level
// macro of the other file.
fn main() -> i32 {
    return if one_val() + one_other() + two_val() == 116 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
