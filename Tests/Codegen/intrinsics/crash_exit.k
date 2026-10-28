// __builtin_crash: the message to stderr, then _Exit(exit_code).

fn main() -> i32 {
    var m = "boom"
    __builtin_crash(m.data, m.len, 42)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe 2> %t.err; test $? -eq 42
// RUN: grep -q boom %t.err
