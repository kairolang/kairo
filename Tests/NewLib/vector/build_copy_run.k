// append (into empty, from empty, between non-empty, into an empty vector
// that has a block), extend_from (including from a view of the vector
// itself, across a growth), copy, filled, from_slice, resize with a value
// (including one of the vector's own elements, across a growth) and from_iter
// (with an exact, a short and a long hint). The body is a macro: a generic
// function cannot call the vector's extend-block members on a `[E]`.

import self::Inputs::elems::*
import std::io

macro builds!(FN, CK, FILL, E) {
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

fn FILL(lo: i64, hi: i64) -> [E] {
    var v: [E]
    for var i = lo; i < hi; ++i {
        v.push(E::make(i))
    }

    return v
}

fn FN(const name: string) -> i32 {
    var bad: i64 = 0
    {
        // append: into empty, from empty, both non-empty.
        var a: [E]
        a.append(FILL(0, 3))
        bad += CK(a, [0, 1, 2])
        a.append(FILL(0, 0))
        bad += CK(a, [0, 1, 2])
        a.append(FILL(3, 40))
        if a.size() != 40 {
            bad += 1
        }

        for var i: usize = 0; i < 40; ++i {
            if a[i].key() != E::make(i as i64).key() {
                bad += 1
            }
        }

        var b = FILL(0, 5)
        b.clear()
        b.append(FILL(7, 9))
        bad += CK(b, [7, 8])

        // extend_from a view of the vector itself, growing on the way.
        var s = FILL(0, 4)
        s.shrink_to_fit()
        s.extend_from(s)
        bad += CK(s, [0, 1, 2, 3, 0, 1, 2, 3])
        s.extend_from(s[(1 as usize)..(3 as usize)])
        bad += CK(s, [0, 1, 2, 3, 0, 1, 2, 3, 1, 2])
        var other = FILL(20, 22)
        s.extend_from(other)
        s.extend_from(FILL(0, 0))
        bad += CK(s, [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 20, 21])

        // copy: exact capacity, independent of the source.
        var c = s.copy()
        if c.capacity() != c.size() {
            bad += 1
        }

        s.clear()
        bad += CK(c, [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 20, 21])
        var ce = s.copy()
        if ce.size() != 0 || ce.capacity() != 0 {
            bad += 1
        }

        // filled, from_slice.
        var seven = E::make(7)
        var f = Vector<E>::filled(5, seven)
        bad += CK(f, [7, 7, 7, 7, 7])
        var f0 = Vector<E>::filled(0, seven)
        if f0.size() != 0 || f0.capacity() != 0 {
            bad += 1
        }

        var fs = Vector<E>::from_slice(c[(2 as usize)..(5 as usize)])
        bad += CK(fs, [2, 3, 0])
        var fse = Vector<E>::from_slice(ce)
        if fse.size() != 0 {
            bad += 1
        }

        // resize with a value: grow, shrink, same.
        var r = FILL(0, 2)
        var nine = E::make(9)
        r.resize(5, nine)
        bad += CK(r, [0, 1, 9, 9, 9])
        r.resize(1, nine)
        bad += CK(r, [0])

        // resize from one of the vector's own elements, across a growth.
        var al = FILL(0, 4)
        al.shrink_to_fit()
        al.resize(9, al[1])
        bad += CK(al, [0, 1, 2, 3, 1, 1, 1, 1, 1])
        r.resize(1, nine)
        bad += CK(r, [0])
    }

    return report(name, bad)
}
}

builds!(builds_i32, ck_i32, fill_i32, i32)
builds!(builds_u8, ck_u8, fill_u8, u8)
builds!(builds_p3, ck_p3, fill_p3, P3)
builds!(builds_b64, ck_b64, fill_b64, B64)
builds!(builds_a128, ck_a128, fill_a128, A128)
builds!(builds_string, ck_string, fill_string, string)
builds!(builds_tracked, ck_tracked, fill_tracked, Tracked)
builds!(builds_rtracked, ck_rtracked, fill_rtracked, RTracked)

/// An iterator over [lo, hi) of Tracked, for from_iter.
class Counting {
    var at: i64
    var hi: i64

    pub fn Counting(self, lo: i64, hi: i64) {
        self.at = lo
        self.hi = hi
    }
}

extend Counting impl Iterator {
    type Item = Tracked
    fn next(self) -> Tracked? {
        if self.at == self.hi {
            return null
        }

        self.at += 1
        return Tracked(self.at - 1)
    }
}

fn from_iters() -> i32 {
    var bad: i64 = 0
    {
        var exact = Vector<Tracked>::from_iter(Counting(0, 50), 50)
        if exact.size() != 50 || exact.capacity() != 50 || exact[49].get() != 49 {
            bad += 1
        }

        var under = Vector<Tracked>::from_iter(Counting(0, 50), 3)
        if under.size() != 50 || under[0].get() != 0 || under[49].get() != 49 {
            bad += 1
        }

        var over = Vector<Tracked>::from_iter(Counting(5, 7), 1000)
        if over.size() != 2 || over.capacity() < 1000 || over[1].get() != 6 {
            bad += 1
        }

        var none = Vector<Tracked>::from_iter(Counting(0, 0), 0)
        if none.size() != 0 || none.capacity() != 0 {
            bad += 1
        }
    }

    return report("from_iter", bad)
}

fn strings() -> i32 {
    var bad: i64 = 0
    {
        var a: [string] = ["a", "bb"]
        a.append(["ccc"])
        var b: [string]
        b.append(a)
        if b.size() != 3 || b[2].size() != 3 {
            bad += 1
        }
    }

    return report("string append", bad)
}

fn main() -> i32 {
    var fails = 0
    fails += builds_i32("i32")
    fails += builds_u8("u8")
    fails += builds_p3("P3")
    fails += builds_b64("B64")
    fails += builds_a128("A128")
    fails += builds_string("string")
    fails += builds_tracked("Tracked")
    fails += builds_rtracked("RTracked")
    fails += from_iters()
    fails += strings()
    return fails
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      i32: ok
// CHECK-NEXT: u8: ok
// CHECK-NEXT: P3: ok
// CHECK-NEXT: B64: ok
// CHECK-NEXT: A128: ok
// CHECK-NEXT: string: ok
// CHECK-NEXT: Tracked: ok
// CHECK-NEXT: RTracked: ok
// CHECK-NEXT: from_iter: ok
// CHECK-NEXT: string append: ok
