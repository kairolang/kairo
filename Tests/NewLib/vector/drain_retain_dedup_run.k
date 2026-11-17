// drain (dropped early, drained from both ends, empty range, full range,
// inclusive range, moved), retain (removing none, all, alternating) on every element type, and dedup
// on those with `==`. Integer-literal bounds are spelled `as usize`: a
// literal range is a `Range<i32>`, which does not convert to drain's
// `Range<usize>`. The body is a macro: a generic function cannot
// call the vector's extend-block members on a `[E]`.

import self::Inputs::elems::*
import std::io

macro drains!(FN, CK, FILL, E) {
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

fn FILL(n: i64) -> [E] {
    var v: [E]
    for var i: i64 = 0; i < n; ++i {
        v.push(E::make(i))
    }

    return v
}

fn FN(const name: string) -> i32 {
    var bad: i64 = 0
    {
        // Drained from the front, then dropped early: the rest is destroyed
        // and the tail closes the gap.
        var v = FILL(10)
        {
            var d = v.drain((2 as usize)..(7 as usize))
            if d.remaining() != 5 {
                bad += 1
            }

            var a = d.next()
            if a? {
                if a.key() != E::make(2).key() {
                    bad += 1
                }
            } else {
                bad += 1
            }

            var b = d.next()
            if !b? || d.remaining() != 3 {
                bad += 1
            }
        }

        bad += CK(v, [0, 1, 7, 8, 9])

        // From both ends, to exhaustion.
        var w = FILL(10)
        {
            var d = w.drain((3 as usize)..(8 as usize))
            var f1 = d.next()
            var b1 = d.next_back()
            var f2 = d.next()
            var b2 = d.next_back()
            if f1? && b1? && f2? && b2? {
                if f1.key() != E::make(3).key() || b1.key() != E::make(7).key() {
                    bad += 1
                }

                if f2.key() != E::make(4).key() || b2.key() != E::make(6).key() {
                    bad += 1
                }
            } else {
                bad += 1
            }

            var m = d.next_back()
            if m? {
                if m.key() != E::make(5).key() {
                    bad += 1
                }
            } else {
                bad += 1
            }

            var e1 = d.next()
            var e2 = d.next_back()
            if e1? || e2? || d.remaining() != 0 {
                bad += 1
            }
        }

        bad += CK(w, [0, 1, 2, 8, 9])

        // Empty range, full range, range to the end, inclusive range.
        var x = FILL(6)
        {
            var d = x.drain((3 as usize)..(3 as usize))
            var e = d.next()
            if e? || d.remaining() != 0 {
                bad += 1
            }
        }

        bad += CK(x, [0, 1, 2, 3, 4, 5])
        {
            var d = x.drain((4 as usize)..(6 as usize))
            var t = d.next_back()
            if !t? {
                bad += 1
            }
        }

        bad += CK(x, [0, 1, 2, 3])
        {
            var d = x.drain((1 as usize)..=(2 as usize))
            if d.remaining() != 2 {
                bad += 1
            }
        }

        bad += CK(x, [0, 3])
        {
            var d = x.drain((0 as usize)..(2 as usize))
            var n: i64 = 0
            loop {
                var t = d.next()
                if t? {
                    n += 1
                } else {
                    break
                }
            }

            if n != 2 {
                bad += 1
            }
        }

        if x.size() != 0 {
            bad += 1
        }

        var empty: [E]
        {
            var d = empty.drain((0 as usize)..(0 as usize))
            var t = d.next_back()
            if t? {
                bad += 1
            }
        }

        // A drain moved to another binding closes the gap once.
        var y = FILL(8)
        {
            var d = y.drain((1 as usize)..(4 as usize))
            var d2 = d
            var t = d2.next()
            if !t? || d2.remaining() != 2 {
                bad += 1
            }
        }

        bad += CK(y, [0, 4, 5, 6, 7])

        // retain: none, all, alternating.
        var r = FILL(9)
        r.retain(fn (p: *const E) -> bool { return true })
        bad += CK(r, [0, 1, 2, 3, 4, 5, 6, 7, 8])
        r.retain(fn (p: *const E) -> bool { return p->key() % 2 == 0 })
        bad += CK(r, [0, 2, 4, 6, 8])
        r.retain(fn (p: *const E) -> bool { return false })
        if r.size() != 0 || r.capacity() == 0 {
            bad += 1
        }

        r.retain(fn (p: *const E) -> bool { return true })
    }

    return report(name, bad)
}
}

macro dedups!(FN, CK, E) {
fn FN(const name: string) -> i32 {
    var bad: i64 = 0
    {
        // dedup: runs of equal keys collapse to their first element.
        var dd: [E]
        for k in [1, 1, 2, 3, 3, 3, 1, 4, 4] {
            dd.push(E::make(k))
        }

        dd.dedup()
        bad += CK(dd, [1, 2, 3, 1, 4])
        dd.dedup()
        bad += CK(dd, [1, 2, 3, 1, 4])
        var one: [E]
        one.dedup()
        one.push(E::make(7))
        one.dedup()
        bad += CK(one, [7])
    }

    return report(name, bad)
}
}

drains!(drains_i32, ck_i32, fill_i32, i32)
drains!(drains_u8, ck_u8, fill_u8, u8)
drains!(drains_a128, ck_a128, fill_a128, A128)
drains!(drains_string, ck_string, fill_string, string)
drains!(drains_tracked, ck_tracked, fill_tracked, Tracked)
drains!(drains_rtracked, ck_rtracked, fill_rtracked, RTracked)
dedups!(dedup_i32, ck_i32, i32)
dedups!(dedup_u8, ck_u8, u8)
dedups!(dedup_tracked, ck_tracked, Tracked)
dedups!(dedup_rtracked, ck_rtracked, RTracked)

fn main() -> i32 {
    var fails = 0
    fails += drains_i32("i32")
    fails += drains_u8("u8")
    fails += drains_a128("A128")
    fails += drains_string("string")
    fails += drains_tracked("Tracked")
    fails += drains_rtracked("RTracked")
    fails += dedup_i32("dedup i32")
    fails += dedup_u8("dedup u8")
    fails += dedup_tracked("dedup Tracked")
    fails += dedup_rtracked("dedup RTracked")
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
// CHECK-NEXT: A128: ok
// CHECK-NEXT: string: ok
// CHECK-NEXT: Tracked: ok
// CHECK-NEXT: RTracked: ok
// CHECK-NEXT: dedup i32: ok
// CHECK-NEXT: dedup u8: ok
// CHECK-NEXT: dedup Tracked: ok
// CHECK-NEXT: dedup RTracked: ok
