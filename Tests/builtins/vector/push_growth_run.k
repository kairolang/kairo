// push across every growth boundary from 0 to 2^16 + 1, checking every
// element each time the capacity changes, for each element type: the
// relocatable byte grower, the element-by-element grower (Tracked), an
// element aligned above the shared empty header (A128, which starts from
// null), and owning elements (string, a vector of strings). The body is a
// macro, not a generic: a generic function cannot call the vector's
// extend-block members on a `[E]` ("could not deduce the extension's generic
// parameters").

import self::inputs::elems::*
import std::io

eval N: i64 = 65537

macro growth!(FN, E) {
fn FN(const name: string) -> i32 {
    var bad: i64 = 0
    {
        var v: [E]
        if v.capacity() != 0 || v.size() != 0 || !v.is_empty() {
            bad += 1
        }

        var cap: usize = 0
        for var i: i64 = 0; i < N; ++i {
            v.push(E::make(i))
            if v.size() > v.capacity() {
                bad += 1
            }

            if v.capacity() != cap {
                cap = v.capacity()
                for var j: usize = 0; j < v.size(); ++j {
                    if v[j].key() != E::make(j as i64).key() {
                        bad += 1
                    }
                }
            }
        }

        if v.size() != N as usize {
            bad += 1
        }

        var j: i64 = 0
        for *x in v {
            if x->key() != E::make(j).key() {
                bad += 1
            }

            j += 1
        }
    }

    return report(name, bad)
}
}

growth!(growth_i32, i32)
growth!(growth_u8, u8)
growth!(growth_p3, P3)
growth!(growth_b64, B64)
growth!(growth_a128, A128)
growth!(growth_string, string)
growth!(growth_tracked, Tracked)
growth!(growth_rtracked, RTracked)

// A vector of vectors: the outer one relocates inner vectors by their bytes.
fn nested() -> i32 {
    var bad: i64 = 0
    {
        var vv: [[string]]
        for var i: i64 = 0; i < 300; ++i {
            var inner: [string]
            for var k: i64 = 0; k < i % 7; ++k {
                inner.push(f"e{i * 10 + k}")
            }

            vv.push(inner)
        }

        for var i: usize = 0; i < vv.size(); ++i {
            if vv[i].size() != i % 7 {
                bad += 1
            }

            for var k: usize = 0; k < vv[i].size(); ++k {
                if vv[i][k].key() != (i * 10 + k) as i64 {
                    bad += 1
                }
            }
        }
    }

    return report("nested", bad)
}

fn main() -> i32 {
    var fails = 0
    fails += growth_i32("i32")
    fails += growth_u8("u8")
    fails += growth_p3("P3")
    fails += growth_b64("B64")
    fails += growth_a128("A128")
    fails += growth_string("string")
    fails += growth_tracked("Tracked")
    fails += growth_rtracked("RTracked")
    fails += nested()
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
// CHECK-NEXT: nested: ok
