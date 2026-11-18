// A vector literal on the two-word library is the empty vector filled by
// reserve and push, whatever its elements: integers are copied in as
// arguments, strings (which cannot be copied) are moved in.

import std::io

fn main() -> i32 {
    var xs: [i32] = [1, 2, 3, 4]
    var sum = 0
    for x in xs { sum += x }
    io::println(f"sum = {sum}")

    var words: [string] = ["x", "yy", "zzz"]
    var bytes: usize = 0
    for *w in words { bytes += w->size() }
    io::println(f"{words.size()} words, {bytes} bytes")

    var none: [i32] = []
    io::println(f"empty = {none.size()}")
    return sum - 10
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      sum = 10
// CHECK-NEXT: 3 words, 6 bytes
// CHECK-NEXT: empty = 0

// The lowered literal names the calls.
// RUN: %kairo_new %s --print-ir 2>&1 | %FileCheck %s --check-prefix=IR
// IR: __kairo_ext_Vector::reserve<signed int>((& xs), static_cast<decltype(sizeof(0))>(4));
// IR: __kairo_ext_Vector::push<signed int>((& xs), 1);
