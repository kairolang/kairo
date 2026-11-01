// OperatorSemantics: an integer division or remainder by zero is a crash
// (the crash family, never a panic): the runtime's message and the crash
// exit, whatever the type.

fn zero() -> u64 { return 0 }

fn main() -> i32 {
    var a: u64 = 10
    a %= zero()
    return a as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe 2> %t.err; test $? -eq 134
// RUN: grep -q 'kairo: division by zero' %t.err
