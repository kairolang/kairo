// Every mutator on each of the three starting states (literal, view, heap),
// on ASCII and on text that mixes 1, 2, 3 and 4 byte chars; appends that
// alias the string they extend; growth across a reallocation. After each
// step the bytes, the length, the codepoint count and the NUL are checked.

import std::io

static FAILS: i32 = 0

fn ck(ok: bool, id: i32) {
    if !ok {
        io::println(f"FAIL {id}")
        FAILS += 1
    }
}

fn ch(v: u32) -> char {
    var c: char = v
    return c
}

// `src` in state `kind`: 0 a literal, 1 a view, 2 a heap string.
fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

// The codepoints by the definition: bytes that are not continuation bytes.
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

// An owned string after a mutation: equal to `want`, counted right, terminated.
fn good(const s: string, const want: string) -> bool {
    if !(s == want) || s.size() != want.size() {
        return false
    }

    if s.codepoints() != naive_cps(want) || s.is_ascii() != (naive_cps(want) == want.size()) {
        return false
    }

    if !s.is_owned() {
        return false
    }

    unsafe {
        var unsafe *z = s.data() as unsafe *const u8
        return z[s.size()] == 0
    }
}

fn main() -> i32 {
    var mixed = "aé€😀z" // 1 + 2 + 3 + 4 + 1 bytes
    ck(mixed.size() == 11 && mixed.codepoints() == 5, 1)

    for var k = 0; k < 3; k += 1 {
        var base = 100 * (k + 1)

        // push: ASCII and every width.
        var s = mk(k, "ab")
        s.push('c')
        ck(good(s, "abc"), base + 1)
        s.push(ch(0xe9))
        ck(good(s, "abcé"), base + 2)
        s.push(ch(0x20ac))
        ck(good(s, "abcé€"), base + 3)
        s.push(ch(0x1f600))
        ck(good(s, "abcé€😀"), base + 4)
        s.push('!')
        ck(good(s, "abcé€😀!"), base + 5)

        // push_str and +=, ASCII onto ASCII, then non-ASCII.
        var t = mk(k, "ab")
        t.push_str("cd")
        ck(good(t, "abcd"), base + 10)
        t += "éé"
        ck(good(t, "abcdéé"), base + 11)
        t += "x"
        ck(good(t, "abcdééx"), base + 12)
        t += ""
        ck(good(t, "abcdééx"), base + 13)
        t.push_str(mixed.view())
        ck(good(t, "abcdééxaé€😀z"), base + 14)
        var heap_rhs = "é!".to_owned()
        t += heap_rhs
        ck(good(t, "abcdééxaé€😀zé!"), base + 15)

        // An empty append leaves a borrowed string borrowed.
        var u = mk(k, "ab")
        u += ""
        ck(u.is_owned() == (k == 2) && u == "ab", base + 16)

        // insert at the start, in the middle and at the end.
        var i = mk(k, mixed)
        i.insert(0, ">")
        ck(good(i, ">aé€😀z"), base + 20)
        i.insert(4, "é")
        ck(good(i, ">aéé€😀z"), base + 21)
        i.insert(i.size(), "<")
        ck(good(i, ">aéé€😀z<"), base + 22)
        i.insert(1, "")
        ck(good(i, ">aéé€😀z<"), base + 23)
        var ia = mk(k, "ad")
        ia.insert(1, "bc")
        ck(good(ia, "abcd"), base + 24)

        // remove_range: a middle span, a prefix, a suffix, an empty span.
        var r = mk(k, mixed)
        r.remove_range(1usize..3usize)
        ck(good(r, "a€😀z"), base + 30)
        r.remove_range(0usize..1usize)
        ck(good(r, "€😀z"), base + 31)
        r.remove_range(3usize..8usize)
        ck(good(r, "€"), base + 32)
        r.remove_range(3usize..3usize)
        ck(good(r, "€"), base + 33)
        r.remove_range(0usize..=2usize)
        ck(good(r, ""), base + 34)
        // Removing the only non-ASCII char leaves ASCII text.
        var r2 = mk(k, "aéb")
        r2.remove_range(1usize..3usize)
        ck(good(r2, "ab") && r2.is_ascii(), base + 35)
        var r3 = mk(k, "abc")
        r3.remove_range(2usize..2usize)
        ck(r3 == "abc" && r3.is_owned() == (k == 2), base + 36)

        // pop: each width comes back, then null.
        var p = mk(k, mixed)
        ck(p.pop() === 'z' && good(p, "aé€😀"), base + 40)
        ck(p.pop() === ch(0x1f600) && good(p, "aé€"), base + 41)
        ck(p.pop() === ch(0x20ac) && good(p, "aé"), base + 42)
        ck(p.pop() === ch(0xe9) && good(p, "a") && p.is_ascii(), base + 43)
        ck(p.pop() === 'a' && good(p, ""), base + 44)
        var gone? = p.pop()
        ck(!gone?, base + 45)
        var pe = mk(k, "")
        var none? = pe.pop()
        ck(!none? && !pe.is_owned(), base + 46)

        // truncate: to a boundary, past the end, to zero.
        var c = mk(k, mixed)
        c.truncate(100)
        ck(c == mixed && c.is_owned() == (k == 2), base + 50)
        c.truncate(11)
        ck(c == mixed, base + 51)
        c.truncate(6)
        ck(good(c, "aé€"), base + 52)
        c.truncate(1)
        ck(good(c, "a") && c.is_ascii(), base + 53)
        c.truncate(0)
        ck(good(c, ""), base + 54)
        var c2 = mk(k, mixed)
        c2.truncate(10)
        ck(good(c2, "aé€😀"), base + 55)

        // clear keeps an owned buffer and makes a borrowed string the empty literal.
        var z = mk(k, mixed)
        z.clear()
        ck(z.is_empty() && z.codepoints() == 0 && z.is_ascii(), base + 60)
        ck(z.is_owned() == (k == 2), base + 61)
        z += "again"
        ck(good(z, "again"), base + 62)
    }

    // Self-append through a view of the whole string and of a part, with and
    // without room, and by naming the string itself.
    var a = "abc".to_owned()
    a += a.view()
    ck(good(a, "abcabc"), 400)
    a.push_str(a)
    ck(good(a, "abcabcabcabc"), 401)
    a += a[3..6]
    ck(good(a, "abcabcabcabcabc"), 402)
    var b = "é€".to_owned()
    b += b.view()
    ck(good(b, "é€é€"), 403)
    b.reserve(64)
    b += b[2..5]
    ck(good(b, "é€é€€"), 404)
    var lit = "xy"
    lit += lit.view()
    ck(good(lit, "xyxy"), 405)
    // A long run of doubling appends crosses every reallocation.
    var d = "ab".to_owned()
    for var n = 0; n < 12; n += 1 {
        d += d.view()
    }

    ck(d.size() == 8192 && d.codepoints() == 8192 && d[8190..] == "ab" && d[..2] == "ab", 406)

    // insert of a view of the string itself.
    var s2 = "hello".to_owned()
    s2.insert(2, s2[1..4])
    ck(good(s2, "heellllo"), 410)
    var s3 = "aéb".to_owned()
    s3.insert(0, s3.view())
    ck(good(s3, "aébaéb"), 411)

    // Growth: one byte at a time from the empty literal.
    var g = string()
    for var n = 0; n < 5000; n += 1 {
        g.push(ch(97 + ((n % 26) as u32)))
    }

    ck(g.size() == 5000 && g.codepoints() == 5000 && g.capacity() >= 5000, 420)
    ck(g[0] == 'a' && g[25] == 'z' && g[4999] == ch(97 + 4999 % 26), 421)

    // A value that is not a Unicode scalar is stored as U+FFFD.
    var f = string()
    f.push(ch(0xd800))
    f.push(ch(0x110000))
    ck(f == "��" && f.codepoints() == 2, 430)

    // append: the formatting primitive; a string appends itself.
    var ap = "x=".to_owned()
    ap.append("42")
    ck(good(ap, "x=42"), 440)

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
