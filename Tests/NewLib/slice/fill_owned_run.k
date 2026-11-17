// fill writes a copy of the value into every element: one byte-sized
// element through a single memory set, a string through copy(), anything
// else by assignment; to_owned returns a vector holding a copy of every
// element, from a mutable and from a const-element slice, on empty and
// non-empty slices.

import std::io

fn main() -> i32 {
    var b: [u8] = [1, 2, 3, 4, 5]
    var bs: [u8;] = b
    bs.fill(9)
    bs[1..3].fill(7)
    var none: [u8;] = bs[0..0]
    none.fill(1)
    io::println(f"u8 {bs[0]} {bs[1]} {bs[2]} {bs[3]} {bs[4]}")

    var w: [i64] = [1, 2, 3]
    var ws: [i64;] = w
    ws.fill(0 - 5)
    io::println(f"i64 {ws[0]} {ws[1]} {ws[2]}")

    var s: [string] = ["a", "b", "c"]
    var ss: [string;] = s
    ss.fill("zz")
    io::println(f"string {ss[0]} {ss[2]} {ss[0].size()}")

    var o = ws.to_owned()
    o[0] = 42
    io::println(f"owned {o.size()} {o[0]} {ws[0]}")
    var cs: [const i64;] = w
    var co = cs.to_owned()
    var e = ws[0..0].to_owned()
    var so = ss.to_owned()
    io::println(f"const {co.size()} {co[2]} empty {e.size()} strings {so.size()} {so[1]}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      u8 9 7 7 9 9
// CHECK-NEXT: i64 -5 -5 -5
// CHECK-NEXT: string zz zz 2
// CHECK-NEXT: owned 3 42 -5
// CHECK-NEXT: const 3 -5 empty 0 strings 3 zz
