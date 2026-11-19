// Size, capacity growth and shrinking, and element access: get, char_at,
// byte_offset, first, last, is_char_boundary, indexing, ranges (views) and the
// bytes slice, on ASCII text and on text with 2, 3 and 4 byte chars. Indexing
// is by byte offset; an offset inside a char or past the end traps; so does a length past the largest a string can hold (the trap
// programs are at the bottom, selected by argument count; 03-string.md, Growth).
// Cases from libc++ test/std/strings/basic.string/string.capacity/
// Cases from libc++ test/std/strings/basic.string/string.access/
// Cases from libc++ test/std/strings/string.view/string.view.access/
// Cases from Rust library/alloctests/tests/str.rs (slicing, is_char_boundary, char_at)

import std::io

static CODE: i32 = 0

fn ck(ok: bool, id: i32, const name: string) {
    if !ok {
        io::println(f"FAIL {name}")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn ch(v: u32) -> char {
    var c: char = v
    return c
}

// The same text in each state: 0 literal, 1 view, 2 heap.
fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

fn size_and_emptiness() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var e = mk(k, "")
        ck(e.size() == 0 && e.is_empty() && e.codepoints() == 0, b + 1, "empty")
        var a = mk(k, "abc")
        ck(a.size() == 3 && !a.is_empty() && a.codepoints() == 3, b + 2, "ascii size")
        var m = mk(k, "aé€😀")
        ck(m.size() == 10 && m.codepoints() == 4 && !m.is_ascii(), b + 3, "mixed size")
        ck(m.is_ascii() == false && a.is_ascii() && e.is_ascii(), b + 4, "is_ascii")
        var w = mk(k, "éé")
        ck(w.size() == 4 && w.codepoints() == 2, b + 5, "two byte chars")
    }
}

fn capacity_growth() {
    var s = string()
    ck(s.capacity() == 0, 10, "empty capacity 0")
    s.push('a')
    ck(s.capacity() >= 1 && s.size() == 1, 11, "first push allocates")
    // The capacity never falls below the size while the string grows.
    for var i = 0; i < 300; i += 1 {
        s.push('b')
        if s.capacity() < s.size() {
            ck(false, 12, "capacity below size")
            break
        }
    }

    ck(s.size() == 301, 13, "size after pushes")
    var lit = "abc"
    ck(lit.capacity() == 0, 14, "literal capacity 0")
    var v = lit.view()
    ck(v.capacity() == 0, 15, "view capacity 0")
}

fn reserve_member() {
    var s = string()
    s.reserve(0)
    ck(s.capacity() == 0, 20, "reserve 0 on empty")
    s.reserve(50)
    ck(s.capacity() >= 50 && s.is_empty() && s.is_owned(), 21, "reserve 50")
    var cap = s.capacity()
    s.reserve(10)
    ck(s.capacity() == cap, 22, "reserve less keeps capacity")
    s.reserve(cap)
    ck(s.capacity() == cap, 23, "reserve equal keeps capacity")
    for var i = 0; i < 50; i += 1 {
        s.push('x')
    }

    ck(s.capacity() == cap, 24, "no reallocation within reserve")
    s.reserve(500)
    ck(s.capacity() >= 500 && s.size() == 50, 25, "reserve more grows")
    ck(s[0] == 'x' && s[49] == 'x' && s.size() == 50, 26, "contents survive growth")
    // A literal and a view become heap strings when room is asked for.
    var l = "héllo"
    l.reserve(40)
    ck(l.is_owned() && l.capacity() >= 40 && l == "héllo" && l.codepoints() == 5, 27, "reserve on a literal")
    var v = "wörld".view()
    v.reserve(40)
    ck(v.is_owned() && v.capacity() >= 40 && v == "wörld", 28, "reserve on a view")
    var z = "abc"
    z.reserve(0)
    ck(z.is_static(), 29, "reserve 0 leaves a literal alone")
    var big = "abcdef".to_owned()
    big.reserve(2)
    ck(big.capacity() >= 6 && big == "abcdef", 30, "reserve below size")
}

fn shrink_to_fit_member() {
    var s = string::with_capacity(200)
    s.push_str("hello")
    s.shrink_to_fit()
    ck(s == "hello" && s.capacity() >= 5 && s.capacity() < 200, 40, "shrinks")
    ck(s.codepoints() == 5 && s.is_owned(), 41, "shrunk string is sound")
    s.push('!')
    ck(s == "hello!", 42, "push after shrink")
    var e = string::with_capacity(64)
    e.shrink_to_fit()
    ck(e.is_empty() && e.capacity() == 0, 43, "empty gives back its block")
    var m = string::with_capacity(100)
    m.push_str("aé€😀")
    m.shrink_to_fit()
    ck(m == "aé€😀" && m.codepoints() == 4 && m.capacity() < 100, 44, "mixed text shrinks")
    var l = "lit"
    l.shrink_to_fit()
    ck(l.is_static() && l == "lit", 45, "literal is untouched")
    var v = "view".view()
    v.shrink_to_fit()
    ck(v.is_view() && v == "view", 46, "view is untouched")
    var exact = "abc".to_owned()
    exact.shrink_to_fit()
    exact.shrink_to_fit()
    ck(exact == "abc", 47, "shrink twice")
}

fn clear_member() {
    var s = string::with_capacity(32)
    s.push_str("héllo")
    var cap = s.capacity()
    s.clear()
    ck(s.is_empty() && s.size() == 0 && s.codepoints() == 0, 50, "clear empties")
    ck(s.capacity() == cap && s.is_owned() && s.is_ascii(), 51, "clear keeps the block")
    s.push_str("again")
    ck(s == "again", 52, "usable after clear")
    var l = "lit"
    l.clear()
    ck(l.is_empty() && l == "", 53, "clear a literal")
    var v = "view".view()
    v.clear()
    ck(v.is_empty(), 54, "clear a view")
    s.clear()
    s.clear()
    ck(s.is_empty(), 55, "clear twice")
}

fn index_and_get() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "aé€😀z") // boundaries at 0 1 3 6 10 11
        ck(s[0] == 'a' && s[1] == ch(0xe9) && s[3] == ch(0x20ac), b + 60, "index at char starts")
        ck(s[6] == ch(0x1f600) && s[10] == 'z', b + 61, "index 4 byte and last")
        var g0? = s.get(0)
        ck(g0? && g0 == 'a', b + 62, "get first")
        var g1? = s.get(1)
        var g2? = s.get(2)
        var g3? = s.get(3)
        var g4? = s.get(4)
        var g5? = s.get(5)
        var g6? = s.get(6)
        var g7? = s.get(7)
        var g10? = s.get(10)
        var g11? = s.get(11)
        var g99? = s.get(99)
        ck(g1? && g1 == ch(0xe9), b + 63, "get 2 byte")
        ck(!g2?, b + 64, "get inside 2 byte")
        ck(g3? && g3 == ch(0x20ac) && !g4? && !g5?, b + 65, "get 3 byte and inside")
        ck(g6? && g6 == ch(0x1f600) && !g7?, b + 66, "get 4 byte and inside")
        ck(g10? && g10 == 'z', b + 67, "get last")
        ck(!g11? && !g99?, b + 68, "get at and past the end")
        var e = mk(k, "")
        var ge? = e.get(0)
        ck(!ge?, b + 69, "get on empty")
    }
}

fn first_last() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var m = mk(k, "aé€😀")
        var f? = m.first()
        var l? = m.last()
        ck(f? && f == 'a' && l? && l == ch(0x1f600), b + 1, "first and last")
        var w = mk(k, "€")
        var f2? = w.first()
        var l2? = w.last()
        ck(f2? && l2? && f2 == l2 && f2 == ch(0x20ac), b + 2, "single char")
        var e = mk(k, "")
        var f3? = e.first()
        var l3? = e.last()
        ck(!f3? && !l3?, b + 3, "empty has neither")
        var o = mk(k, "x")
        var f4? = o.first()
        var l4? = o.last()
        ck(f4? && l4? && f4 == 'x' && l4 == 'x', b + 4, "one ascii char")
    }
}

fn char_at_and_byte_offset() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "aé€😀z")
        var c0? = s.char_at(0)
        var c1? = s.char_at(1)
        var c2? = s.char_at(2)
        var c3? = s.char_at(3)
        var c4? = s.char_at(4)
        var c5? = s.char_at(5)
        ck(c0? && c0 == 'a' && c1? && c1 == ch(0xe9) && c2? && c2 == ch(0x20ac), b + 1, "char_at counts chars")
        ck(c3? && c3 == ch(0x1f600) && c4? && c4 == 'z' && !c5?, b + 2, "char_at last and past")
        var o0? = s.byte_offset(0)
        var o1? = s.byte_offset(1)
        var o2? = s.byte_offset(2)
        var o3? = s.byte_offset(3)
        var o4? = s.byte_offset(4)
        var o5? = s.byte_offset(5)
        var o6? = s.byte_offset(6)
        ck(o0? && o0 == 0 && o1? && o1 == 1 && o2? && o2 == 3, b + 3, "byte_offset first chars")
        ck(o3? && o3 == 6 && o4? && o4 == 10, b + 4, "byte_offset later chars")
        ck(o5? && o5 == 11 && !o6?, b + 5, "byte_offset at the end and past")
        var a = mk(k, "abc")
        var a3? = a.byte_offset(3)
        var a4? = a.byte_offset(4)
        var ac? = a.char_at(2)
        var ad? = a.char_at(3)
        ck(a3? && a3 == 3 && !a4? && ac? && ac == 'c' && !ad?, b + 6, "ascii offsets")
        var e = mk(k, "")
        var e0? = e.byte_offset(0)
        var ec? = e.char_at(0)
        ck(e0? && e0 == 0 && !ec?, b + 7, "empty offsets")
    }
}

// Rust's str::is_char_boundary cases: 0 and len are boundaries, a byte in the
// middle of a char is not, and past the end is not.
fn char_boundaries() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "aé€😀z")
        var want = [true, true, false, true, false, false, true, false, false, false, true, true, false, false]
        var ok = true
        for var i: usize = 0; i < 14; i += 1 {
            if s.is_char_boundary(i) != want[i] {
                ok = false
            }
        }

        ck(ok, b + 1, "is_char_boundary at every offset")
        var e = mk(k, "")
        ck(e.is_char_boundary(0) && !e.is_char_boundary(1), b + 2, "boundary on empty")
        var a = mk(k, "abc")
        ck(a.is_char_boundary(0) && a.is_char_boundary(2) && a.is_char_boundary(3) && !a.is_char_boundary(4), b + 3, "ascii boundaries")
    }
}

fn ranges_are_views() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "aé€😀z")
        var all = s[0..11]
        ck(all == s && all.is_view() && all.data() == s.data(), b + 1, "full range")
        var mid = s[1..6]
        ck(mid == "é€" && mid.is_view() && mid.codepoints() == 2, b + 2, "middle range")
        ck(mid.data() == s.data() + 1, b + 3, "a range points into the source")
        ck(s[..3] == "aé" && s[3..] == "€😀z" && s[6..] == "😀z", b + 4, "open ranges")
        ck(s[0..=0] == "a" && s[1..=2] == "é" && s[..=10] == "aé€😀z", b + 5, "inclusive ranges")
        ck(s[3..3].is_empty() && s[11..].is_empty() && s[0..0].is_empty(), b + 6, "empty ranges")
        ck(s[..] == s, b + 7, "unbounded")
        var inner = mid[0..2]
        ck(inner == "é" && inner.data() == s.data() + 1, b + 8, "a range of a range")
        ck(s[1..3].is_ascii() == false && s[0..1].is_ascii(), b + 9, "ascii flag of a range")
        ck(s[6..10].codepoints() == 1 && s[6..10].size() == 4, b + 10, "4 byte range")
    }
}

fn bytes_slice() {
    var s  = "aé"
    var by = s.bytes()
    ck(by.size() == 3 && by[0] == 0x61 && by[1] == 0xc3 && by[2] == 0xa9, 80, "bytes of aé")
    var e = string()
    ck(e.bytes().size() == 0, 81, "bytes of empty")
    var h = "héllo".to_owned()
    ck(h.bytes().size() == 6 && h.data() == &h.bytes()[0], 82, "bytes points at the data")
    var w = "😀"
    var wb = w.bytes()
    ck(wb[0] == 0xf0 && wb[1] == 0x9f && wb[2] == 0x98 && wb[3] == 0x80, 83, "bytes of a 4 byte char")
    var v = "abc".to_owned()
    var sub = v[1..].bytes()
    ck(sub.size() == 2 && sub[0] == 0x62, 84, "bytes of a range")
}

fn c_string_access() {
    var h = "héllo".to_owned()
    var t? = h.try_c_str()
    ck(t?, 90, "try_c_str of a heap string")
    var l = "lit"
    var tl? = l.try_c_str()
    ck(tl?, 91, "try_c_str of a literal")
    var v = "héllo".view()
    var tv? = v.try_c_str()
    ck(!tv?, 92, "try_c_str of a view is null")
    var sub = h[0..3].view()
    var ts? = sub.try_c_str()
    ck(!ts?, 93, "try_c_str of a range is null")
    // c_str makes a view heap first, so the terminator is there.
    var w = "wörld"
    var vv = w[0..3]
    unsafe {
        var unsafe *q = vv.c_str() as unsafe *const u8
        ck(vv.is_owned() && q[3] == 0 && q[0] == 0x77, 94, "c_str of a view promotes")
    }

    unsafe {
        var unsafe *q = h.c_str() as unsafe *const u8
        ck(h.is_owned() && q[h.size()] == 0, 95, "c_str of a heap string")
        var unsafe *r = l.c_str() as unsafe *const u8
        ck(l.is_static() && r[3] == 0, 96, "c_str of a literal keeps it")
    }
}

fn main(argc: i32) -> i32 {
    var kind = argc - 1
    var text = "aé€😀z" // boundaries at 0 1 3 6 10 11
    var s    = text.to_owned()
    var n: usize = 0
    if kind == 0 {
        size_and_emptiness()
        capacity_growth()
        reserve_member()
        shrink_to_fit_member()
        clear_member()
        index_and_get()
        first_last()
        char_at_and_byte_offset()
        char_boundaries()
        ranges_are_views()
        bytes_slice()
        c_string_access()
        n += s[1] as usize
        return CODE
    }

    if kind == 1 { n += s[2] as usize }               // inside é
    if kind == 2 { n += s[11] as usize }              // the end is not a char
    if kind == 3 { n += s[100] as usize }             // far past the end
    if kind == 4 { n += s[2..6].size() }              // start inside a char
    if kind == 5 { n += s[1..5].size() }              // end inside a char
    if kind == 6 { n += s[1..12].size() }             // end past the length
    if kind == 7 { n += s[12..].size() }              // from past the length
    if kind == 8 { n += s[..4].size() }               // to inside a char
    if kind == 9 { n += s[6..3].size() }              // start after end
    if kind == 10 { n += s[0..=11].size() }           // inclusive end past the length
    if kind == 11 { n += s[8..].size() }              // from inside a 4 byte char
    var e = string()
    if kind == 12 { n += e[0] as usize }              // index of an empty string
    if kind == 13 { n += e[0..1].size() }             // range of an empty string
    var lit = "é"
    if kind == 14 { n += lit[1] as usize }            // literal, inside a char
    var v = "aé".view()
    if kind == 15 { n += v[2] as usize }              // view, inside a char
    if kind == 16 { var w = string::with_capacity(usize::MAX); n += w.capacity() }   // past MAX_LEN
    if kind == 17 { var w = "a".to_owned(); w.reserve(usize::MAX) }
    if kind == 18 { var w = string('x', usize::MAX); n += w.size() }
    if kind == 19 { var w = "a".pad_start(usize::MAX); n += w.size() }
    if kind == 20 { var w = "ab".repeat(usize::MAX / 2); n += w.size() }
    if kind == 21 { var w = "a€".pad_end(usize::MAX / 4, 'x'); n += w.size() }
    return n as i32 & 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe
// RUN: not --crash %t.exe 1
// RUN: not --crash %t.exe 1 2
// RUN: not --crash %t.exe 1 2 3
// RUN: not --crash %t.exe 1 2 3 4
// RUN: not --crash %t.exe 1 2 3 4 5
// RUN: not --crash %t.exe 1 2 3 4 5 6
// RUN: not --crash %t.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21
