fn total(const xs: [i32;]) -> i32 {
    var s: i32 = 0
    for x in xs { s += x }
    return s
}

fn bump(@inout a: [i32; 3]) {
    for var *p in a { *p += 1 }
}

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    bump(&a)
    var s: i32 = 0
    for x in a { s += x }               // 9
    for x in [10, 20] { s += x }        // 30: the array prvalue is bound first
    var sl: [i32;] = [4, 5]
    return s + total(sl)                // 9 + 30 + 9 == 48
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 48
