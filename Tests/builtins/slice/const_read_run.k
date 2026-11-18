// Every read member is declared once, in `extend <T> Slice<T>` and its
// bounded siblings, and reaches a `[const T;]`: size, get, at, first, last,
// begin / end, split_at, iter, windows, chunks, partition_point, the
// searches, equality, prefix tests, is_sorted, binary_search, and the range
// forms of the const specialization itself.

import std::io

fn lt4(a: *const i32) -> bool {
    return *a < 4
}

fn main() -> i32 {
    var v: [i32]        = [1, 3, 4, 4, 7, 9]
    var s: [const i32;] = v
    var *f? = s.first()
    var *l? = s.last()
    var *g? = s.get(2)
    var *a? = s.at(-2)
    if f? && l? && g? && a? {
        io::println(f"size {s.size()} first {*f} last {*l} get {*g} at {*a}")
    }

    var (x, y) = s.split_at(2)
    var sum    = 0
    for p in s.iter() {
        sum += *p
    }

    var w = 0
    for q in s.windows(4) {
        w += 1
    }

    var c = 0
    for q in s.chunks(4) {
        c += q.size() as i32
    }

    io::println(f"split {x.size()}/{y.size()} sum {sum} windows {w} chunks {c}")
    var i? = s.index_of(4)
    var j? = s.last_index_of(4)
    var b  = s.binary_search(7)
    io::println(f"pp {s.partition_point(lt4)} has {s.contains(9)} idx {i ?? 99} last {j ?? 99} bs {b.0} {b.1} sorted {s.is_sorted()}")
    io::println(f"eq {s == s[0..6]} pre {s.starts_with(s[..2])} suf {s.ends_with(s[4..])} sub {s[1..=2].size()}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      size 6 first 1 last 9 get 4 at 7
// CHECK-NEXT: split 2/4 sum 28 windows 3 chunks 6
// CHECK-NEXT: pp 2 has true idx 2 last 3 bs true 4 sorted true
// CHECK-NEXT: eq true pre true suf true sub 2
