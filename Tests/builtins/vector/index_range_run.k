// Indexing, the range subscripts (exclusive, inclusive, from, to, empty,
// full), both `op in` forms, the implicit slice conversion (a view of the
// vector's storage; spelled `as` at a free function's argument, see
// conversion_xfail.k), and the traps: an
// index or a range outside the vector ends the program, in every build.
//
// The trap cases are chosen by the argument count, so one binary covers them.

import self::inputs::elems::*
import std::io

fn take_view(const s: [const i32;]) -> i64 {
    var t: i64 = 0
    for x in s {
        t += x
    }

    return t
}

// `.size()` on a range subscript's `[const T;]` fails in clang when called
// directly on the subscript; counting through a parameter avoids it.
fn len_of(const s: [const i32;]) -> usize {
    var n: usize = 0
    for x in s {
        n += 1
    }

    return n
}

fn bump(s: [i32;]) {
    for var i: usize = 0; i < s.size(); ++i {
        s[i] += 100
    }
}

fn checks() -> i32 {
    var bad: i64 = 0
    {
        var v: [i32]
        for var i: i32 = 0; i < 10; ++i {
            v.push(i)
        }

        v[3] = 33
        if v[3] != 33 || v[9] != 9 {
            bad += 1
        }

        const mid = v[(2 as usize)..(5 as usize)]
        if len_of(mid) != 3 || mid[0] != 2 || mid[1] != 33 || mid[2] != 4 {
            bad += 1
        }

        const incl = v[(2 as usize)..=(5 as usize)]
        if len_of(incl) != 4 || incl[3] != 5 {
            bad += 1
        }

        const last = v[(9 as usize)..=(9 as usize)]
        if len_of(last) != 1 || last[0] != 9 {
            bad += 1
        }

        const from = v[(7 as usize)..]
        if len_of(from) != 3 || from[0] != 7 {
            bad += 1
        }

        const to = v[..(2 as usize)]
        const to_incl = v[..=(2 as usize)]
        if len_of(to) != 2 || len_of(to_incl) != 3 || to_incl[2] != 2 {
            bad += 1
        }

        const all = v[(0 as usize)..(10 as usize)]
        const none = v[(10 as usize)..(10 as usize)]
        const none_from = v[(10 as usize)..]
        if len_of(all) != 10 || len_of(none) != 0 || len_of(none_from) != 0 {
            bad += 1
        }

        // The mutable range form writes through to the vector.
        var w = v[(0 as usize)..(2 as usize)]
        w[1] = 11
        if v[1] != 11 {
            bad += 1
        }

        // The conversions are views of the same storage.
        if take_view(v as [const i32;]) != 0 + 11 + 2 + 33 + 4 + 5 + 6 + 7 + 8 + 9 {
            bad += 1
        }

        var whole = v[(0 as usize)..]
        bump(whole)
        if v[0] != 100 || v[9] != 109 {
            bad += 1
        }

        // op in: by pointer, mutable and const.
        for *p in v {
            *p -= 100
        }

        var sum: i64 = 0
        for x in v {
            sum += x
        }

        if sum != 85 {
            bad += 1
        }

        // Empty vector: no element is read.
        var e: [i32]
        var n = 0
        for x in e {
            n += 1
        }

        if n != 0 || take_view(e as [const i32;]) != 0 || len_of(e[(0 as usize)..(0 as usize)]) != 0 {
            bad += 1
        }

        // Elements that own memory, by pointer.
        var ws: [string] = ["a", "bb", "ccc"]
        var bytes: usize = 0
        for *s in ws {
            bytes += s->size()
        }

        if bytes != 6 {
            bad += 1
        }
    }

    return report("index", bad)
}

fn main(argc: i32) -> i32 {
    var v: [i32] = [1, 2, 3]
    if argc == 2 {
        return v[3]
    }

    if argc == 3 {
        return len_of(v[(1 as usize)..(4 as usize)]) as i32
    }

    if argc == 4 {
        return len_of(v[(2 as usize)..=(3 as usize)]) as i32
    }

    if argc == 5 {
        return len_of(v[(4 as usize)..]) as i32
    }

    if argc == 6 {
        var t = v.remove(3)
        return t
    }

    if argc == 7 {
        v.insert(4, 0)
        return 0
    }

    if argc == 8 {
        var d = v.drain((2 as usize)..(1 as usize))
        return 0
    }

    if argc == 9 {
        var t = v.swap_remove(5)
        return t
    }

    return checks()
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: not --crash %t.exe 1
// RUN: not --crash %t.exe 1 2
// RUN: not --crash %t.exe 1 2 3
// RUN: not --crash %t.exe 1 2 3 4
// RUN: not --crash %t.exe 1 2 3 4 5
// RUN: not --crash %t.exe 1 2 3 4 5 6
// RUN: not --crash %t.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// RUN: not --crash %t.o2.exe 1
// RUN: not --crash %t.o2.exe 1 2
// RUN: not --crash %t.o2.exe 1 2 3
// RUN: not --crash %t.o2.exe 1 2 3 4
// RUN: not --crash %t.o2.exe 1 2 3 4 5
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8
// CHECK: index: ok
