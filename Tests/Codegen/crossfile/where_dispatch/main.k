import lib::*

fn main() -> i32 {
    var g = Gate(true)
    var shut = Gate(false)
    // 4 + 3 + 0 + 5 + 0 == 12
    return grade(95) + grade(85) + grade(10) + g.pass(5) + shut.pass(5)
}

// --- lit wiring -----------------------------------------------------------
// The calls bind to lib's dispatchers, which test the guards in lib's
// object.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
