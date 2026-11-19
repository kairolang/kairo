// `for ... in` over a Kairo vector and over a string (control-flow.mdx, For:
// range and iterator; collections.mdx): a vector yields its elements, a
// string its characters.
//
//
// Both loops compile and run: a vector yields its elements by value, a
// string its characters (`char`). The exit code is the sum and the count.
//
//
//
//

fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    var s = 0
    for x in v { s += x }
    var n = 0
    for c in "abcd" { n += 1 }
    return s * 10 + n                           // 60 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 64
