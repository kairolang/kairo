// Construction and the three states of a two-word string: what each
// constructor builds, which state it is in, and how copy(), to_owned(),
// view(), c_str() and the capacity members move between states.

import std::io

static FAILS: i32 = 0

fn ck(ok: bool, id: i32) {
    if !ok {
        io::println(f"FAIL {id}")
        FAILS += 1
    }
}

// A char above U+007F: its literal form does not reach clang intact.
fn ch(v: u32) -> char {
    var c: char = v
    return c
}

fn main() -> i32 {
    // The empty string is a literal and owns nothing.
    var e = string()
    ck(e.size() == 0 && e.is_empty() && e.codepoints() == 0, 1)
    ck(e.is_static() && !e.is_owned() && !e.is_view(), 2)
    ck(e.capacity() == 0 && e.is_ascii(), 3)
    ck(e == "", 4)

    // A literal: static, NUL-terminated, counted by the compiler.
    var lit = "héllo"
    ck(lit.is_static() && !lit.is_owned() && !lit.is_view(), 10)
    ck(lit.size() == 6 && lit.codepoints() == 5 && !lit.is_ascii(), 11)
    var ascii = "hello"
    ck(ascii.is_ascii() && ascii.codepoints() == 5, 12)

    // From a pointer and a length: a heap copy, exact capacity.
    var h = string(lit.data(), lit.size())
    ck(h.is_owned() && !h.is_static() && !h.is_view(), 20)
    ck(h.size() == 6 && h.codepoints() == 5 && h.capacity() == 6, 21)
    ck(h == lit && h.data() != lit.data(), 22)
    var h0 = string(lit.data(), 0)
    ck(h0.is_empty() && h0.is_static(), 23)

    // From a byte slice, a NUL-terminated pointer and a C string.
    var bytes: [u8; 4] = [107, 97, 105, 0]
    var sl = string(b"kai")
    ck(sl == "kai" && sl.is_owned() && sl.is_ascii(), 30)
    var nt = string(&bytes[0])
    ck(nt == "kai" && nt.size() == 3, 31)
    var cs = string(ascii.c_str())
    ck(cs == "hello" && cs.is_owned(), 32)

    // A char repeated.
    var rep = string('x', 5)
    ck(rep == "xxxxx" && rep.is_ascii() && rep.is_owned(), 40)
    var rep2 = string(ch(0xe9), 3)
    ck(rep2 == "ééé" && rep2.size() == 6 && rep2.codepoints() == 3 && !rep2.is_ascii(), 41)
    var rep0 = string('x', 0)
    ck(rep0.is_empty() && !rep0.is_owned(), 42)
    var rep4 = string(ch(0x1f600), 2)
    ck(rep4.size() == 8 && rep4.codepoints() == 2, 43)

    // with_capacity: owned and empty; zero stays the literal.
    var wc = string::with_capacity(100)
    ck(wc.is_owned() && wc.is_empty() && wc.capacity() == 100, 50)
    var wc0 = string::with_capacity(0)
    ck(!wc0.is_owned() && wc0.capacity() == 0, 51)

    // view(): borrows, same bytes, keeps the ASCII bit, never NUL-terminated.
    var v = h.view()
    ck(v.is_view() && !v.is_owned() && !v.is_static(), 60)
    ck(v.data() == h.data() && v.size() == 6 && v.codepoints() == 5, 61)
    ck(v.try_c_str() == null, 62)
    var vv = v.view()
    ck(vv.is_view() && vv.data() == h.data(), 63)
    var va = ascii.view()
    ck(va.is_ascii() && va.codepoints() == 5, 64)

    // copy(): keeps the state. Only a heap string allocates.
    var c1 = lit.copy()
    ck(c1.is_static() && c1.data() == lit.data(), 70)
    var c2 = v.copy()
    ck(c2.is_view() && c2.data() == v.data(), 71)
    var c3 = h.copy()
    ck(c3.is_owned() && c3.data() != h.data() && c3 == h && c3.codepoints() == 5, 72)

    // to_owned(): a heap copy; the empty string owns nothing.
    var o1 = lit.to_owned()
    ck(o1.is_owned() && o1 == lit && o1.capacity() == 6 && o1.codepoints() == 5, 80)
    var o2 = v.to_owned()
    ck(o2.is_owned() && o2 == lit && o2.codepoints() == 5 && !o2.is_ascii(), 81)
    var o3 = e.to_owned()
    ck(!o3.is_owned() && o3.is_empty(), 82)
    var o4 = va.to_owned()
    ck(o4.is_owned() && o4.is_ascii(), 83)

    // c_str(): free on a literal and a heap string; a view is promoted.
    ck(lit.try_c_str() != null && h.try_c_str() != null, 90)
    var pv = h.view()
    var *before = pv.data()
    unsafe {
        var unsafe *z = pv.c_str() as unsafe *const u8
        ck(pv.is_owned() && pv.data() != before && z[6] == 0 && z[0] == 104, 91)
    }

    unsafe {
        var unsafe *z = lit.c_str() as unsafe *const u8
        ck(lit.is_static() && z[6] == 0, 92)
    }

    // A slice of a NUL-terminated string is a view even when it reaches the end.
    var tail = ascii[2..]
    ck(tail.is_view() && tail == "llo", 93)

    // reserve and shrink_to_fit.
    var r = "ab"
    r.reserve(64)
    ck(r.is_owned() && r.capacity() >= 64 && r == "ab", 100)
    var cap = r.capacity()
    r.reserve(10)
    ck(r.capacity() == cap, 101)
    r.shrink_to_fit()
    ck(r.capacity() == 2 && r == "ab", 102)
    r.clear()
    r.shrink_to_fit()
    ck(!r.is_owned() && r.is_empty(), 103)
    var lv = "abc"
    lv.shrink_to_fit()
    ck(lv.is_static(), 104)

    // from_utf8: null on bytes that are not UTF-8.
    var g? = string::from_utf8(b"h\xc3\xa9!")
    if g? {
        ck(g == "hé!" && g.codepoints() == 3 && g.is_owned(), 110)
    } else {
        ck(false, 111)
    }

    var b? = string::from_utf8(b"h\xc3(")
    ck(!b?, 112)
    var trunc? = string::from_utf8(b"h\xc3")
    ck(!trunc?, 113)
    var none? = string::from_utf8(b"")
    if none? {
        ck(none.is_empty(), 114)
    } else {
        ck(false, 115)
    }

    // Moving leaves both words in the destination.
    var src = "moved".to_owned()
    var *p0 = src.data()
    var dst = src
    ck(dst.data() == p0 && dst == "moved" && dst.is_owned(), 120)

    // Default.
    var d = string::make_default()
    ck(d.is_empty() && d.is_static(), 130)

    if FAILS == 0 {
        io::println("ok")
    }

    return FAILS
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: ok
