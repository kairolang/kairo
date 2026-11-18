// Iteration order of `{K: V}` / `{T}` is insertion order (Lib/builtin/
// containers/hash_map.k): a function of the operations, never of hash
// values, addresses or the run. Checked three ways: against the insertion
// order itself, through growth; erase's documented effect (swap-remove
// moves the last entry into the hole, erase_ordered keeps the order); and
// the printed order of a map built from 2000 keys is byte-identical across
// two runs of the program.
ffi "c" import "stdio.h"

fn put_num(n: u64) {
    if n >= 10 { put_num(n / 10) }
    putchar((48 + (n % 10)) as i32)
}

fn main() -> i32 {
    // Insertion order through several growths.
    var m: {u64: u64}
    var i: u64 = 0
    while i < 1000 { m[(i * 7919) % 1000] = i; i += 1 }
    var k: u64 = 0
    for (key, v) in m {
        if (key != (k * 7919) % 1000) || (v != k) { return 1 }
        k += 1
    }
    // Re-inserting a present key keeps its place.
    m[0] = 5
    if m.begin()->key != 0 { return 2 }

    // Swap-remove: the last entry takes the erased one's place.
    var s: {i32} = {1, 2, 3, 4, 5}
    s.erase(2)
    var o = 0
    for x in s { o = o * 10 + x }
    if o != 1534 { return 3 }
    // erase_ordered: the rest keep their order.
    s.erase_ordered(5)
    o = 0
    for x in s { o = o * 10 + x }
    if o != 134 { return 4 }
    // Erasing while walking: walk the indices backwards, erase_ordered.
    var w: {i32} = {1, 2, 3, 4, 5, 6}
    var j = w.size()
    while j > 0 {
        j -= 1
        var x = w.items()[j]
        if (x % 2) == 0 { w.erase_ordered(x) }
    }
    o = 0
    for x in w { o = o * 10 + x }
    if o != 135 { return 5 }

    // Printed order, for the run-to-run comparison.
    var p: {u64: u64}
    i = 0
    while i < 2000 { p[(i * 104729) % 2000] = i; i += 1 }
    i = 0
    while i < 2000 { p.erase((i * 31) % 2000); i += 3 }
    for (key, v) in p { put_num(key); putchar(32) }
    putchar(10)
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out1; test $? -eq 100
// RUN: %t.exe > %t.out2; test $? -eq 100
// RUN: cmp %t.out1 %t.out2
