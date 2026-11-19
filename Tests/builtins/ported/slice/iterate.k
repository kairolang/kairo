// The pointer-pair iterators SliceIter (iter) and SliceIterMut (iter_mut):
// front-to-back by next and by a for loop, back-to-front by next_back,
// alternating ends until they meet, remaining after every step, as_slice of
// what is left, keep_first / keep_last, copying an iterator (the copy and the
// original advance independently), writing through iter_mut, and the empty,
// one-element and many-element cases. Elements are i32, string and a
// move-only instrumented class whose live count returns to zero.
//
// Cases from libc++ test/std/containers/views/views.span/span.iterators/
// Cases from Rust library/coretests/tests/slice.rs (iterators from both ends)

import self::inputs::inst::*
import std::io

fn forward_and_backward() {
    var v: [i32] = [1, 2, 3, 4, 5]
    const s: [const i32;] = v

    var it = s.iter()
    check(it.remaining() == 5, "remaining of a fresh iterator", 1)
    var sum = 0
    var steps = 0
    loop {
        var *p? = it.next()
        if !p? {
            break
        }

        steps += 1
        sum = sum * 10 + *p
        check(it.remaining() == 5 - steps as usize, "remaining after each next", 2)
    }

    check(sum == 12345 && steps == 5, "next visits front to back", 3)
    check(it.next() == null && it.next() == null, "next stays null at the end", 4)
    check(it.next_back() == null && it.remaining() == 0, "next_back is null once exhausted", 5)

    var back = s.iter()
    var rsum = 0
    loop {
        var *p? = back.next_back()
        if !p? {
            break
        }

        rsum = rsum * 10 + *p
    }

    check(rsum == 54321, "next_back visits back to front", 6)
    check(back.next() == null, "next is null after next_back exhausted the slice", 7)

    var both = s.iter()
    var order = ""
    var turn = 0
    loop {
        var *p? = (if turn % 2 == 0 => both.next() else => both.next_back())
        if !p? {
            break
        }

        order += f"{*p}"
        turn += 1
    }

    check(order == "15243", "alternating ends meet in the middle", 8)
    check(both.remaining() == 0 && both.next() == null && both.next_back() == null, "both ends exhausted together", 9)

    var loopsum = 0
    for p in s.iter() {
        loopsum += *p
    }

    check(loopsum == 15, "for over iter()", 10)
}

fn sizes() {
    var none: [i32]
    const e: [const i32;] = none
    var ie = e.iter()
    check(ie.remaining() == 0 && ie.next() == null && ie.next_back() == null, "empty slice iterator", 20)
    check(ie.as_slice().size() == 0, "as_slice of an empty iterator", 21)
    for p in e.iter() {
        fail("a for over an empty iter() runs no body", 22)
    }

    var one: [i32] = [8]
    const o: [const i32;] = one
    var io1 = o.iter()
    check(io1.remaining() == 1, "one-element iterator remaining", 23)
    var *p? = io1.next_back()
    check(p? && *p == 8 && io1.remaining() == 0 && io1.next() == null, "one element taken from the back", 24)
    var io2 = o.iter()
    var *q? = io2.next()
    check(q? && *q == 8 && io2.next_back() == null, "one element taken from the front", 25)
}

fn as_slice_and_keep() {
    var v: [i32] = [1, 2, 3, 4, 5, 6]
    const s: [const i32;] = v

    var it = s.iter()
    check(it.as_slice().size() == 6 && it.as_slice()[0] == 1, "as_slice of a fresh iterator", 30)
    it.next()
    it.next_back()
    var rest = it.as_slice()
    check(rest.size() == 4 && rest[0] == 2 && rest[3] == 5, "as_slice is what is left", 31)
    check(it.remaining() == rest.size(), "remaining agrees with as_slice", 32)

    var a = s.iter()
    a.keep_first(2)
    check(a.remaining() == 2 && a.as_slice()[1] == 2, "keep_first(2)", 33)
    var sa = 0
    for p in a {
        sa = sa * 10 + *p
    }

    check(sa == 12, "a for over a kept prefix", 34)

    var b = s.iter()
    b.keep_last(2)
    check(b.remaining() == 2 && b.as_slice()[0] == 5, "keep_last(2)", 35)
    check(b.next_back() != null && b.next() != null && b.next() == null, "a kept suffix has two elements", 36)

    var c = s.iter()
    c.keep_first(6)
    c.keep_last(100)
    check(c.remaining() == 6, "keep with n >= remaining keeps everything", 37)
    c.keep_first(usize::MAX)
    check(c.remaining() == 6, "keep_first(usize::MAX) keeps everything", 38)
    c.keep_last(usize::MAX)
    check(c.remaining() == 6, "keep_last(usize::MAX) keeps everything", 39)

    var d = s.iter()
    d.keep_first(0)
    check(d.remaining() == 0 && d.next() == null && d.next_back() == null, "keep_first(0) empties it", 40)
    var f = s.iter()
    f.keep_last(0)
    check(f.remaining() == 0 && f.next() == null, "keep_last(0) empties it", 41)

    var g = s.iter()
    g.keep_first(4)
    g.keep_last(2)
    check(g.remaining() == 2 && g.as_slice()[0] == 3 && g.as_slice()[1] == 4, "keep_first then keep_last cut a middle window", 42)
    g.next()
    g.keep_first(1)
    check(g.remaining() == 1 && g.as_slice()[0] == 4, "keep after a step", 43)

    var none: [i32]
    const e: [const i32;] = none
    var h = e.iter()
    h.keep_first(3)
    h.keep_last(3)
    check(h.remaining() == 0, "keep on an empty iterator", 44)
}

fn copies() {
    var v: [i32] = [1, 2, 3, 4]
    const s: [const i32;] = v
    var a = s.iter()
    a.next()
    var b = a
    b.next()
    b.next_back()
    check(a.remaining() == 3 && b.remaining() == 1, "a copy advances independently", 50)
    var *p? = a.next()
    check(p? && *p == 2, "the original still yields what the copy consumed", 51)
    var *q? = b.next()
    check(q? && *q == 3, "the copy yields the middle element", 52)
}

fn writing() {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [i32;] = v
    for p in s.iter_mut() {
        *p *= 2
    }

    check(v[0] == 2 && v[4] == 10, "a for over iter_mut writes the elements", 60)

    var it = s.iter_mut()
    check(it.remaining() == 5, "iter_mut remaining", 61)
    var *f? = it.next()
    var *l? = it.next_back()
    if !f? || !l? {
        fail("iter_mut yields both ends", 62)
    }

    *f = 100
    *l = 500
    check(v[0] == 100 && v[4] == 500, "writes through next / next_back", 63)
    check(it.remaining() == 3, "iter_mut remaining after both ends", 64)
    it.keep_first(2)
    var seen = 0
    loop {
        var *p? = it.next()
        if !p? {
            break
        }

        *p += 1
        seen += 1
    }

    check(seen == 2 && v[1] == 5 && v[2] == 7 && v[3] == 8, "keep_first on iter_mut limits the writes", 65)
    var jt = s.iter_mut()
    jt.keep_last(1)
    var *z? = jt.next()
    if !z? {
        fail("keep_last(1) leaves one element", 66)
    }

    *z = 0
    check(v[4] == 0 && v[3] == 8, "keep_last(1) writes only the last", 67)

    var none: [i32]
    var e: [i32;] = none
    var ie = e.iter_mut()
    check(ie.remaining() == 0 && ie.next() == null && ie.next_back() == null, "empty iter_mut", 68)
    for p in e.iter_mut() {
        fail("a for over an empty iter_mut() runs no body", 69)
    }

    var jc = s.iter_mut()
    var kc = jc
    jc.next()
    check(kc.remaining() == 5 && jc.remaining() == 4, "iter_mut copies advance independently", 70)
}

fn strings() {
    var v: [string] = ["x", "y", "z"]
    var s: [string;] = v
    var out = ""
    var it = s.iter()
    var *a? = it.next()
    var *b? = it.next_back()
    var *c? = it.next()
    if !a? || !b? || !c? {
        fail("string iterator yields three elements", 79)
    }

    out += *a
    out += *b
    out += *c
    check(out == "xzy" && it.next() == null, "string iterator from both ends", 80)
    for p in s.iter_mut() {
        *p += "!"
    }

    check(v[0] == "x!" && v[1] == "y!" && v[2] == "z!", "string writes through iter_mut", 81)
    var w = s.iter()
    w.keep_last(1)
    check(w.as_slice()[0] == "z!", "string keep_last", 82)
}

fn instrumented() {
    {
        var v = insts(6, 0, 1)
        var s: [Inst;] = v
        var moves0 = MOVES
        var it = s.iter()
        var sum: i64 = 0
        loop {
            var *a? = it.next()
            var *b? = it.next_back()
            if !a? || !b? {
                break
            }

            sum += a->key() * 10 + b->key()
        }

        check(sum == 5 + 14 + 23, "inst iterator pairs from both ends", 90)
        for p in s.iter_mut() {
            p->k += 100
        }

        check(v[0].key() == 100 && v[5].key() == 105, "inst writes through iter_mut", 91)
        var m = s.iter_mut()
        m.keep_first(3)
        m.keep_last(1)
        var *p? = m.next()
        if !p? {
            fail("inst keep_first then keep_last leaves one", 92)
        }

        p->k = -1
        check(v[2].key() == -1, "inst write through a kept window", 93)
        check(MOVES == moves0 && LIVE == 6, "iterating moves and creates nothing", 94)
    }

    check_clean("iterate: instrumented", 95)
}

fn main() -> i32 {
    forward_and_backward()
    sizes()
    as_slice_and_keep()
    copies()
    writing()
    strings()
    instrumented()
    io::println("iterate ok")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: iterate ok
