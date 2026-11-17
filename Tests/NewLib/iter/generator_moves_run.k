// A generator is a handle to its frame, so it moves at any time: resumed,
// then moved into an adapter, then moved again inside a chain that is
// itself moved, it yields the items that were left. Adapters over
// generators need no pinning.

import std::iter::*
import std::io

fn upto(n: i64) -> yield i64 {
    var kept: [i64]
    for var i: i64 = 0; i < n; i += 1 {
        kept.push(i)
        yield kept[i as usize] * 10
    }
}

fn twice(x: i64) -> i64 = x * 2

fn <I impl Iterator> rest(it: I) -> i64 requires __builtin_is_same<I::Item, i64>() {
    var moved = move(it)
    var t: i64 = 0
    loop {
        var x = moved.next()
        if !x? {
            return t
        }

        t += unwrap!(x)
    }
}

fn main() -> i32 {
    var g = upto(5)
    var first = g.next() ?? -1
    var second = g.next() ?? -1
    var chain = iter(move(g)).map<i64>(twice)
    var third = chain.next() ?? -1
    var later = move(chain).skip(1)
    var total = rest(move(later))
    io::println(f"{first} {second} {third} {total}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: 0 10 40 80
