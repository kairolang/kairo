// Construction: the empty string, a literal, a copy of bytes, a char repeated,
// with_capacity, from_utf8, copy / to_owned / view and the move constructor,
// on ASCII and on text with 2, 3 and 4 byte chars. A byte sequence that is not
// UTF-8 is rejected by from_utf8 (null) and traps in a constructor.
// Cases from libc++ test/std/strings/basic.string/string.cons/
// Cases from Rust library/alloctests/tests/string.rs (from_utf8, from_utf8_lossy inputs)

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

// The code points by their definition: bytes that are not continuation bytes.
fn naive_cps(const s: string) -> usize {
    var n: usize = 0
    var b        = s.bytes()
    for var i: usize = 0; i < b.size(); i += 1 {
        if (b[i] & 0xc0) != 0x80 {
            n += 1
        }
    }

    return n
}

// The invariants every string keeps: the count, the ASCII flag and, when the
// state has one, the NUL after the last byte.
fn sound(const s: string) -> bool {
    if s.codepoints() != naive_cps(s) || s.is_ascii() != (naive_cps(s) == s.size()) {
        return false
    }

    if s.is_empty() != (s.size() == 0) {
        return false
    }

    var z? = s.try_c_str()
    if z? {
        unsafe {
            var unsafe *q = z as unsafe *const u8
            return q[s.size()] == 0
        }
    }

    return s.is_view()
}

fn default_construct() {
    var s = string()
    ck(s.size() == 0 && s.is_empty() && s.codepoints() == 0, 1, "default empty")
    ck(sound(s) && s == "", 2, "default sound")
    ck(!s.is_owned() && s.capacity() == 0, 3, "default owns nothing")
    ck(s.is_ascii(), 4, "default ascii")
    var d: string = string::make_default()
    ck(d.is_empty(), 5, "make_default")
    ck(s.first() == null && s.last() == null, 6, "default has no first or last")
}

fn literal_construct() {
    var a = "hello"
    ck(a.size() == 5 && a.codepoints() == 5 && a.is_static(), 10, "ascii literal")
    ck(sound(a), 11, "ascii literal sound")
    var m = "aé€😀"
    ck(m.size() == 10 && m.codepoints() == 4 && !m.is_ascii(), 12, "mixed literal")
    ck(sound(m) && m.is_static(), 13, "mixed literal sound")
    var e = ""
    ck(e.is_empty() && e.is_static() && e == string(), 14, "empty literal")
    var embedded = "a\x00b"
    ck(embedded.size() == 3 && embedded.bytes()[1] == 0, 15, "NUL inside a literal")
    ck(embedded.codepoints() == 3 && sound(embedded), 16, "NUL inside is a char")
}

fn construct_from_bytes() {
    var src = "abcdef"
    var p   = string(src.data(), 3)
    ck(p == "abc" && p.is_owned() && sound(p), 20, "pointer and length")
    var z = string(src.data(), 0)
    ck(z.is_empty() && z == "", 21, "pointer with length 0")
    var b = string(b"h\xc3\xa9llo")
    ck(b == "héllo" && b.codepoints() == 5 && sound(b), 22, "byte slice")
    var all = string(b"")
    ck(all.is_empty(), 23, "empty byte slice")
    var four = string(b"\xf0\x9f\x98\x80")
    ck(four.size() == 4 && four.codepoints() == 1 && four[0] == ch(0x1f600), 24, "4 byte char")
    var from_view = string(src[1..4].bytes())
    ck(from_view == "bcd" && from_view.is_owned(), 25, "from the bytes of a view")
    var from_str = string("é€")
    ck(from_str == "é€" && from_str.codepoints() == 2 && sound(from_str), 26, "from a literal")
}

fn construct_from_c_string() {
    var s = "héllo"
    unsafe {
        var c = string(s.c_str())
        ck(c == "héllo" && c.is_owned() && sound(c), 30, "from a C string")
    }

    var bytes: [u8; 4] = [0x61, 0x62, 0x63, 0]
    unsafe {
        var c = string(&bytes[0] as unsafe *__builtin_c_char)
        ck(c == "abc" && c.size() == 3, 31, "C string stops at NUL")
    }

    var empty: [u8; 1] = [0]
    unsafe {
        var c = string(&empty[0] as unsafe *__builtin_c_char)
        ck(c.is_empty(), 32, "empty C string")
    }
}

fn construct_repeated_char() {
    var a = string('x', 5)
    ck(a == "xxxxx" && a.size() == 5 && sound(a), 40, "ascii char repeated")
    var z = string('x', 0)
    ck(z.is_empty(), 41, "zero repeats")
    var one = string('q', 1)
    ck(one == "q", 42, "one repeat")
    var w = string(ch(0xe9), 3)
    ck(w == "ééé" && w.size() == 6 && w.codepoints() == 3 && sound(w), 43, "2 byte char repeated")
    var t = string(ch(0x20ac), 4)
    ck(t.size() == 12 && t.codepoints() == 4 && sound(t), 44, "3 byte char repeated")
    var f = string(ch(0x1f600), 2)
    ck(f == "😀😀" && f.size() == 8 && f.codepoints() == 2, 45, "4 byte char repeated")
    var big = string('z', 1000)
    ck(big.size() == 1000 && big.is_ascii() && big[999] == 'z' && sound(big), 46, "lng repeat")
    var nul = string(ch(0), 3)
    ck(nul.size() == 3 && nul.codepoints() == 3 && sound(nul), 47, "NUL repeated")
}

fn with_capacity_construct() {
    var s = string::with_capacity(0)
    ck(s.is_empty() && s.capacity() == 0, 50, "capacity 0")
    var t = string::with_capacity(100)
    ck(t.is_empty() && t.capacity() >= 100 && t.is_owned(), 51, "capacity 100")
    ck(t.size() == 0 && t == "" && sound(t), 52, "with_capacity is empty")
    var cap = t.capacity()
    for var i = 0; i < 100; i += 1 {
        t.push('a')
    }

    ck(t.capacity() == cap && t.size() == 100, 53, "filling to capacity keeps the block")
    var one = string::with_capacity(1)
    ck(one.capacity() >= 1 && one.is_empty(), 54, "capacity 1")
}

fn from_utf8_valid() {
    var a? = string::from_utf8(b"hello")
    ck(a? && a == "hello" && a.is_owned() && sound(a), 60, "ascii")
    var e? = string::from_utf8(b"")
    ck(e? && e.is_empty(), 61, "empty")
    var m? = string::from_utf8(b"a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80")
    ck(m? && m == "aé€😀" && m.codepoints() == 4 && sound(m), 62, "every width")
    var edge1? = string::from_utf8(b"\xc2\x80")
    ck(edge1? && edge1.codepoints() == 1, 63, "U+0080")
    var edge2? = string::from_utf8(b"\xdf\xbf")
    ck(edge2? && edge2.size() == 2, 64, "U+07FF")
    var edge3? = string::from_utf8(b"\xe0\xa0\x80")
    ck(edge3? && edge3.size() == 3, 65, "U+0800")
    var edge4? = string::from_utf8(b"\xed\x9f\xbf")
    ck(edge4? && edge4.size() == 3, 66, "U+D7FF")
    var edge5? = string::from_utf8(b"\xee\x80\x80")
    ck(edge5? && edge5.size() == 3, 67, "U+E000")
    var edge6? = string::from_utf8(b"\xef\xbf\xbf")
    ck(edge6? && edge6.size() == 3, 68, "U+FFFF")
    var edge7? = string::from_utf8(b"\xf0\x90\x80\x80")
    ck(edge7? && edge7.size() == 4, 69, "U+10000")
    var edge8? = string::from_utf8(b"\xf4\x8f\xbf\xbf")
    ck(edge8? && edge8.size() == 4 && edge8[0] == ch(0x10ffff), 70, "U+10FFFF")
    var nul? = string::from_utf8(b"a\x00b")
    ck(nul? && nul.size() == 3, 71, "NUL byte is valid")
}

// Each byte string is rejected: from_utf8 answers null.
fn from_utf8_invalid() {
    ck(!string::from_utf8(b"\x80")?, 80, "lone continuation")
    ck(!string::from_utf8(b"\xbf")?, 81, "lone continuation bf")
    ck(!string::from_utf8(b"a\x80b")?, 82, "continuation after ascii")
    ck(!string::from_utf8(b"\xc3")?, 83, "truncated 2 byte")
    ck(!string::from_utf8(b"\xe2\x82")?, 84, "truncated 3 byte")
    ck(!string::from_utf8(b"\xf0\x9f\x98")?, 85, "truncated 4 byte")
    ck(!string::from_utf8(b"\xc3(")?, 86, "bad continuation")
    ck(!string::from_utf8(b"\xe2(\xa1")?, 87, "bad continuation 3 byte, second")
    ck(!string::from_utf8(b"\xe2\x82(")?, 88, "bad continuation 3 byte, third")
    ck(!string::from_utf8(b"\xf0\x9f\x98(")?, 89, "bad continuation 4 byte")
    ck(!string::from_utf8(b"\xc0\x80")?, 90, "overlong NUL")
    ck(!string::from_utf8(b"\xc1\xbf")?, 91, "overlong c1")
    ck(!string::from_utf8(b"\xe0\x80\x80")?, 92, "overlong 3 byte")
    ck(!string::from_utf8(b"\xe0\x9f\xbf")?, 93, "overlong 3 byte below 0x800")
    ck(!string::from_utf8(b"\xf0\x80\x80\x80")?, 94, "overlong 4 byte")
    ck(!string::from_utf8(b"\xf0\x8f\xbf\xbf")?, 95, "overlong 4 byte below 0x10000")
    ck(!string::from_utf8(b"\xed\xa0\x80")?, 96, "surrogate D800")
    ck(!string::from_utf8(b"\xed\xbf\xbf")?, 97, "surrogate DFFF")
    ck(!string::from_utf8(b"\xf4\x90\x80\x80")?, 98, "above 10FFFF")
    ck(!string::from_utf8(b"\xf5\x80\x80\x80")?, 99, "lead f5")
    ck(!string::from_utf8(b"\xf8\x88\x80\x80\x80")?, 100, "5 byte form")
    ck(!string::from_utf8(b"\xfc\x84\x80\x80\x80\x80")?, 101, "6 byte form")
    ck(!string::from_utf8(b"\xfe")?, 102, "fe")
    ck(!string::from_utf8(b"\xff")?, 103, "ff")
    ck(!string::from_utf8(b"ok\xffok")?, 104, "ff inside ascii")
    ck(!string::from_utf8(b"\xc3\xa9\xc3")?, 105, "valid then truncated")
    ck(!string::from_utf8(b"\xf0\x9f\x92\x96\x80")?, 106, "valid 4 byte then continuation")
    // A lng ASCII run before and after the bad byte (word-at-a-time scans).
    var lng = string('a', 64)
    lng += "é"
    var good? = string::from_utf8(lng.bytes())
    ck(good? && good.size() == 66, 107, "lng ascii then 2 byte")
    var bad_bytes = string('a', 64).concat("é")
    var raw = bad_bytes.bytes()
    ck(string::from_utf8(raw[0..65])? == false, 108, "lng ascii then half a char")
}

fn copy_to_owned_view() {
    var lit = "aé"
    var c   = lit.copy()
    ck(c == "aé" && c.is_static(), 110, "copy of a literal stays a literal")
    var o = lit.to_owned()
    ck(o == "aé" && o.is_owned() && sound(o), 111, "to_owned")
    var v = o.view()
    ck(v == "aé" && v.is_view() && v.data() == o.data(), 112, "view borrows")
    var cv = v.copy()
    ck(cv.is_view() && cv.data() == o.data(), 113, "copy of a view stays a view")
    var ov = v.to_owned()
    ck(ov.is_owned() && ov.data() != o.data() && ov == o, 114, "to_owned of a view allocates")
    var co = o.copy()
    ck(co.is_owned() && co.data() != o.data() && co == o, 115, "copy of a heap string allocates")
    var empty = string().to_owned()
    ck(empty.is_empty() && empty.is_static(), 116, "to_owned of empty is the empty literal")
    var e2 = o.view()[0..0].to_owned()
    ck(e2.is_empty(), 117, "to_owned of an empty view")
    // Changing the copy leaves the source alone.
    co.push('!')
    ck(o == "aé" && co == "aé!", 118, "a copy is independent")
}

// A moved-from string cannot be named again (checked at compile time), so a
// move is observed through the block it keeps.
fn move_construct() {
    var a = "move me".to_owned()
    var p: *const u8 = a.data()
    var b = a
    ck(b == "move me" && b.data() == p && b.is_owned(), 120, "move keeps the block")
    var l = "lit"
    var m = l
    ck(m == "lit" && m.is_static(), 122, "move of a literal")
    var w = "aé€"
    var x = w.view()
    var y = x
    ck(y == "aé€" && y.is_view(), 123, "move of a view")
}

// Bytes that are not UTF-8 trap in every constructor that takes bytes; the
// number of arguments picks the program.
// Assigning over a string of each state, from a string of each state: the old
// bytes are released, the new ones are the source's, and the state follows.
fn move_assign() {
    for var d = 0; d < 3; d += 1 {
        for var k = 0; k < 3; k += 1 {
            var dst = mk_state(d, "old text that is long enough to need a block")
            var src = mk_state(k, "héllo €")
            dst = src
            ck(dst == "héllo €" && dst.codepoints() == 7 && sound(dst), 130 + d * 3 + k, "move assignment")
            ck(dst.is_owned() == (k == 2) && dst.is_view() == (k == 1), 140 + d * 3 + k, "assignment keeps the source state")
        }
    }

    var s = "abc".to_owned()
    s = string()
    ck(s.is_empty() && sound(s), 150, "assign the empty string")
    s = "é€".to_owned()
    s = s.concat("!")
    ck(s == "é€!" && sound(s), 151, "assign from an expression of itself")
}

// The same text in a state: 0 literal, 1 view, 2 heap.
fn mk_state(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

fn main(argc: i32) -> i32 {
    var kind = argc - 1
    var n: usize = 0
    var ok = "aé€😀"
    if kind == 0 {
        default_construct()
        literal_construct()
        construct_from_bytes()
        construct_from_c_string()
        construct_repeated_char()
        with_capacity_construct()
        from_utf8_valid()
        from_utf8_invalid()
        copy_to_owned_view()
        move_construct()
        move_assign()
        return CODE
    }

    if kind == 1 { n += string(b"\x80").size() }                    // lone continuation
    if kind == 2 { n += string(b"a\x80b").size() }                  // continuation after ascii
    if kind == 3 { n += string(b"\xc3").size() }                    // truncated 2 byte
    if kind == 4 { n += string(b"\xe2\x82").size() }               // truncated 3 byte
    if kind == 5 { n += string(b"\xf0\x9f\x98").size() }          // truncated 4 byte
    if kind == 6 { n += string(b"\xc0\x80").size() }               // overlong NUL
    if kind == 7 { n += string(b"\xe0\x80\x80").size() }          // overlong 3 byte
    if kind == 8 { n += string(b"\xf0\x80\x80\x80").size() }     // overlong 4 byte
    if kind == 9 { n += string(b"\xed\xa0\x80").size() }          // surrogate
    if kind == 10 { n += string(b"\xf4\x90\x80\x80").size() }    // above U+10FFFF
    if kind == 11 { n += string(b"\xff").size() }                   // never a UTF-8 byte
    if kind == 12 { n += string(ok.data(), 2).size() }               // ends inside a char
    if kind == 13 { n += string(ok.data() + 2, 2).size() }           // starts inside a char
    if kind == 14 { n += string(ok.data() + 1, 1).size() }           // half of a 2 byte char
    if kind == 15 { n += "ab".repeat(usize::MAX).size() }            // the length overflows
    return n as i32 & 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
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
