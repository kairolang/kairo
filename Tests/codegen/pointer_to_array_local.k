// A local `*[i32; 3]` spells as a C++ pointer-to-array declarator with the
// name inside the parentheses (`signed int(* c)[3]`), initialised and
// reassigned, and `(*c)[i]` indexes through it: the program builds at -O0
// and -O2 and exits 2 (a[1] + b[2] - 9).

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    var b: [i32; 3] = [7, 8, 9]
    var c: *[i32; 3] = &a
    var r = (*c)[1]
    c = &b
    return r + (*c)[2] - 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK: signed int(* c)[3] =(& a);
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
// RUN: rm -rf %t.d2 %t2.exe
// RUN: %kairo %s -O2 -o %t2.exe --cache-dir %t.d2
// RUN: %t2.exe; test $? -eq 2
