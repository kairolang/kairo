import lib::*

fn main() -> i32 {
    var s = Scale(3)
    return s.k + s.first(4, 9)        // 3 + 4 == 7
}

// --- lit wiring -----------------------------------------------------------
// main.k instantiates Scale::first<i32>, a member template of a class that
// is not itself a template. Its definition must be visible here (CODEGEN.md
// §7): lib.k's object holds no first<int>, because lib.k never calls it.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
