// insert, remove, swap_remove, pop, truncate, clear, reserve, shrink_to_fit
// and with_capacity on every element type, on empty, one and many elements:
// insert at 0, in the middle, at len and at exact capacity; remove at both
// ends and in the middle. The body is a macro: a generic function cannot
// call the vector's extend-block members on a `[E]`.

import self::inputs::elems::*
import std::io

macro mods!(FN, CK, E) {
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
        var v: [E]
        v.insert(0, E::make(1))
        bad += CK(v, [1])
        v.insert(0, E::make(0))
        v.insert(2, E::make(3))
        v.insert(2, E::make(2))
        bad += CK(v, [0, 1, 2, 3])

        var k: i64 = 4
        while v.size() < v.capacity() {
            v.push(E::make(k))
            k += 1
        }

        var c = v.capacity()
        v.insert(0, E::make(-1))
        if v.capacity() <= c {
            bad += 1
        }

        if v[0].key() != E::make(-1).key() || v.size() != (k + 1) as usize {
            bad += 1
        }

        for var i: usize = 1; i < v.size(); ++i {
            if v[i].key() != E::make((i - 1) as i64).key() {
                bad += 1
            }
        }

        // At exact capacity again, in the middle and at len.
        while v.size() < v.capacity() {
            v.push(E::make(k))
            k += 1
        }

        v.insert(v.size() / 2, E::make(-2))
        while v.size() < v.capacity() {
            v.push(E::make(k))
            k += 1
        }

        v.insert(v.size(), E::make(-3))
        if v[v.size() - 1].key() != E::make(-3).key() {
            bad += 1
        }

        v.truncate(0)
        if v.size() != 0 || v.capacity() == 0 {
            bad += 1
        }

        for var i: i64 = 0; i < 10; ++i {
            v.push(E::make(i))
        }

        var r = v.remove(0)
        if r.key() != E::make(0).key() {
            bad += 1
        }

        var r2 = v.remove(v.size() - 1)
        if r2.key() != E::make(9).key() {
            bad += 1
        }

        var r3 = v.remove(3)
        if r3.key() != E::make(4).key() {
            bad += 1
        }

        bad += CK(v, [1, 2, 3, 5, 6, 7, 8])

        var s = v.swap_remove(0)
        if s.key() != E::make(1).key() {
            bad += 1
        }

        bad += CK(v, [8, 2, 3, 5, 6, 7])
        var s2 = v.swap_remove(v.size() - 1)
        if s2.key() != E::make(7).key() {
            bad += 1
        }

        var s3 = v.swap_remove(2)
        if s3.key() != E::make(3).key() {
            bad += 1
        }

        bad += CK(v, [8, 2, 6, 5])

        var popped: i64 = 0
        loop {
            var p = v.pop()
            if p? {
                popped += 1
            } else {
                break
            }
        }

        if popped != 4 || v.size() != 0 {
            bad += 1
        }

        var none = v.pop()
        if none? {
            bad += 1
        }

        // One element.
        v.push(E::make(42))
        var one = v.swap_remove(0)
        if one.key() != E::make(42).key() || !v.is_empty() {
            bad += 1
        }

        v.push(E::make(43))
        var one2 = v.remove(0)
        if one2.key() != E::make(43).key() || !v.is_empty() {
            bad += 1
        }

        // truncate and clear keep the block.
        for var i: i64 = 0; i < 100; ++i {
            v.push(E::make(i))
        }

        var c2 = v.capacity()
        v.truncate(200)
        v.truncate(100)
        if v.size() != 100 {
            bad += 1
        }

        v.truncate(50)
        if v.size() != 50 || v.capacity() != c2 || v[49].key() != E::make(49).key() {
            bad += 1
        }

        v.clear()
        if v.size() != 0 || v.capacity() != c2 {
            bad += 1
        }

        // shrink_to_fit: to the length, then back to the shared empty block.
        for var i: i64 = 0; i < 10; ++i {
            v.push(E::make(i))
        }

        v.shrink_to_fit()
        if v.capacity() != 10 {
            bad += 1
        }

        bad += CK(v, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        v.push(E::make(10))
        if v.capacity() < 11 {
            bad += 1
        }

        v.clear()
        v.shrink_to_fit()
        if v.capacity() != 0 {
            bad += 1
        }

        v.shrink_to_fit()
        v.push(E::make(5))
        bad += CK(v, [5])

        // reserve grows to at least n and never shrinks.
        v.reserve(1000)
        if v.capacity() < 1000 {
            bad += 1
        }

        var c3 = v.capacity()
        v.reserve(5)
        v.reserve(0)
        if v.capacity() != c3 {
            bad += 1
        }

        bad += CK(v, [5])

        var w0 = Vector<E>::with_capacity(0)
        if w0.capacity() != 0 || w0.size() != 0 {
            bad += 1
        }

        var w7 = Vector<E>::with_capacity(7)
        if w7.capacity() != 7 || w7.size() != 0 {
            bad += 1
        }

        for var i: i64 = 0; i < 7; ++i {
            w7.push(E::make(i))
        }

        if w7.capacity() != 7 {
            bad += 1
        }

        w7.push(E::make(7))
        bad += CK(w7, [0, 1, 2, 3, 4, 5, 6, 7])

        // Move construction leaves the source empty and usable.
        var moved = w7
        bad += CK(moved, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    return report(name, bad)
}
}

mods!(mods_i32, ck_i32, i32)
mods!(mods_u8, ck_u8, u8)
mods!(mods_p3, ck_p3, P3)
mods!(mods_b64, ck_b64, B64)
mods!(mods_a128, ck_a128, A128)
mods!(mods_string, ck_string, string)
mods!(mods_tracked, ck_tracked, Tracked)
mods!(mods_rtracked, ck_rtracked, RTracked)

fn main() -> i32 {
    var fails = 0
    fails += mods_i32("i32")
    fails += mods_u8("u8")
    fails += mods_p3("P3")
    fails += mods_b64("B64")
    fails += mods_a128("A128")
    fails += mods_string("string")
    fails += mods_tracked("Tracked")
    fails += mods_rtracked("RTracked")
    return fails
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      i32: ok
// CHECK-NEXT: u8: ok
// CHECK-NEXT: P3: ok
// CHECK-NEXT: B64: ok
// CHECK-NEXT: A128: ok
// CHECK-NEXT: string: ok
// CHECK-NEXT: Tracked: ok
// CHECK-NEXT: RTracked: ok
