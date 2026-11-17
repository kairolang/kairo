// with_len and resize(n).
//
// XFAIL: *
// Waiting on the compiler: a member of an `extend <T impl Default>` block is
// rejected by clang for `i32`, `u8` and a class with its own
// `extend X impl Default`, and for string ("'int' does not satisfy
// 'Default_c'"), while a function with a `<T impl Default>` bound is
// accepted for the same types.

import self::Inputs::elems::*
import std::io

macro defaults!(FN, CK, E) {
fn CK(const v: [E], const want: [i64]) -> i64 {
    if v.size() != want.size() {
        return 1000
    }

    var bad: i64 = 0
    for var i: usize = 0; i < v.size(); ++i {
        if v[i].key() != E::make(want[i]).key() {
            bad += 1
        }
    }

    return bad
}

fn FN(const name: string) -> i32 {
    var bad: i64 = 0
    {
        var z = Vector<E>::with_len(6)
        bad += CK(z, [0, 0, 0, 0, 0, 0])
        var z0 = Vector<E>::with_len(0)
        if z0.size() != 0 {
            bad += 1
        }

        z.clear()
        z.push(E::make(4))
        z.resize(3)
        bad += CK(z, [4, 0, 0])
        z.resize(1)
        bad += CK(z, [4])
        z.resize(70)
        if z.size() != 70 || z[69].key() != E::make(0).key() {
            bad += 1
        }
    }

    return report(name, bad)
}
}

defaults!(defaults_i32, ck_i32, i32)
defaults!(defaults_u8, ck_u8, u8)
defaults!(defaults_tracked, ck_tracked, Tracked)
defaults!(defaults_rtracked, ck_rtracked, RTracked)

fn strings() -> i32 {
    var bad: i64 = 0
    {
        var w: [string] = ["x"]
        w.resize(4)
        if w.size() != 4 || w[3].size() != 0 || w[0].size() != 1 {
            bad += 1
        }

        var z = Vector<string>::with_len(3)
        if z.size() != 3 || z[2].size() != 0 {
            bad += 1
        }
    }

    return report("default string", bad)
}

fn main() -> i32 {
    var fails = 0
    fails += defaults_i32("default i32")
    fails += defaults_u8("default u8")
    fails += defaults_tracked("default Tracked")
    fails += defaults_rtracked("default RTracked")
    fails += strings()
    return fails
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      default i32: ok
// CHECK-NEXT: default u8: ok
// CHECK-NEXT: default Tracked: ok
// CHECK-NEXT: default RTracked: ok
// CHECK-NEXT: default string: ok
