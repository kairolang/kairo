// Iteration and the view-returning members: `for c in s`, Chars forward,
// backward and meeting in the middle, char_indices, lines, fields, the split
// family, trimming and stripping. Every piece is a view into the source.
// A loop over a generator of strings binds each piece's address (`for *p`):
// a string cannot be copied into the binder. A generator borrows the string
// it walks and its pattern, so both are named variables here.

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

fn is_digit(c: char) -> bool {
    return c >= '0' && c <= '9'
}

// The pieces of a generator, joined with '|' so one comparison checks them all.
fn join_split(const s: string, const sep: string, max: usize) -> string {
    var out = string()
    for *piece in s.split(sep, max) {
        out += *piece
        out.push('|')
    }

    return out
}

fn join_lines(const s: string) -> string {
    var out = string()
    for *l in s.lines() {
        out += *l
        out.push('|')
    }

    return out
}

fn join_fields(const s: string) -> string {
    var out = string()
    for *f in s.fields() {
        out += *f
        out.push('|')
    }

    return out
}

fn join_rsplit(const s: string, const sep: string, max: usize) -> string {
    var out = string()
    for *piece in s.rsplit(sep, max) {
        out += *piece
        out.push('|')
    }

    return out
}

fn main() -> i32 {
    var mixed = "aé€😀z"

    // `for c in s`: the chars in order.
    var sum: u32 = 0
    var n        = 0
    for c in mixed {
        var v: u32 = c
        sum += v
        n   += 1
    }

    ck(n == 5 && sum == 97 + 0xe9 + 0x20ac + 0x1f600 + 122, 1)
    n = 0
    var none = ""
    for c in none {
        n += 1
    }

    ck(n == 0, 2)

    // Chars: forward.
    var it = mixed.chars()
    ck(it.next() === 'a' && it.next() === ch(0xe9) && it.next() === ch(0x20ac), 10)
    ck(it.next() === ch(0x1f600) && it.next() === 'z', 11)
    var end? = it.next()
    ck(!end?, 12)
    var again? = it.next()
    ck(!again?, 13)

    // Backward.
    var back = mixed.chars()
    ck(back.next_back() === 'z' && back.next_back() === ch(0x1f600), 20)
    ck(back.next_back() === ch(0x20ac) && back.next_back() === ch(0xe9) && back.next_back() === 'a', 21)
    var bend? = back.next_back()
    ck(!bend?, 22)

    // Meeting in the middle: each char is yielded once.
    var both = mixed.chars()
    ck(both.next() === 'a' && both.next_back() === 'z', 30)
    ck(both.next() === ch(0xe9) && both.next_back() === ch(0x1f600), 31)
    ck(both.next() === ch(0x20ac), 32)
    var m1? = both.next()
    var m2? = both.next_back()
    ck(!m1? && !m2?, 33)
    var empty = "".chars()
    var e1? = empty.next()
    var e2? = empty.next_back()
    ck(!e1? && !e2?, 34)

    // char_indices: byte offsets with the chars.
    var offs: usize = 0
    var cnt         = 0
    for (i, c) in mixed.char_indices() {
        offs = offs * 16 + i
        cnt += 1
        ck(mixed[i] == c, 40)
    }

    ck(cnt == 5 && offs == 0x0136a, 41)

    // lines: `\n` ends a line and takes one `\r` before it with it; the
    // last line needs no terminator.
    ck(join_lines("one\ntwo\r\n\nfour") == "one|two||four|", 50)
    ck(join_lines("a\n") == "a|", 51)
    ck(join_lines("") == "", 52)
    ck(join_lines("\n\r\n\r") == "||\r|", 53)
    ck(join_lines("no newline") == "no newline|", 54)

    // fields: runs between white space, ASCII and not; never empty.
    ck(join_fields("  alpha\tbeta\u00a0gamma \u3000 é\n") == "alpha|beta|gamma|é|", 60)
    ck(join_fields(" \t\n") == "", 61)
    ck(join_fields("one") == "one|", 62)
    ck(join_fields("") == "", 63)

    // split: every piece, empty ones included.
    ck(join_split("a,b,c", ",", usize::MAX) == "a|b|c|", 70)
    ck(join_split(",a,,b,", ",", usize::MAX) == "|a||b||", 71)
    ck(join_split("abc", ",", usize::MAX) == "abc|", 72)
    ck(join_split("", ",", usize::MAX) == "|", 73)
    ck(join_split("a--b--c", "--", usize::MAX) == "a|b|c|", 74)
    // At most `max` pieces: the last keeps the rest.
    ck(join_split("a,b,c", ",", 2) == "a|b,c|", 75)
    ck(join_split("a,b,c", ",", 1) == "a,b,c|", 76)
    ck(join_split("a,b,c", ",", 0) == "", 77)
    // An empty pattern splits before every char and at the end.
    ck(join_split("aé", "", usize::MAX) == "|a|é||", 78)

    // rsplit: the same pieces, last first; the rest stays at the start.
    ck(join_rsplit("a,b,c", ",", usize::MAX) == "c|b|a|", 80)
    ck(join_rsplit(",a,,b,", ",", usize::MAX) == "|b||a||", 81)
    ck(join_rsplit("a,b,c", ",", 2) == "c|a,b|", 82)
    ck(join_rsplit("abc", ",", usize::MAX) == "abc|", 83)
    ck(join_rsplit("aé", "", usize::MAX) == "|é|a||", 84)

    // split with a char and with a predicate; the pieces are views of the source.
    var src   = "k=v1;x=v22"
    var semi  = ';'
    var digit = Pred { f: is_digit }
    var parts = string()
    for *p in src.split(semi) {
        ck(p->is_view() && p->data() >= src.data(), 90)
        parts += *p
        parts.push('|')
    }

    ck(parts == "k=v1|x=v22|", 91)
    parts.clear()
    for *p in src.split(digit) {
        parts += *p
        parts.push('|')
    }

    ck(parts == "k=v|;x=v|||", 92)
    parts.clear()
    for *p in src.rsplit(semi, 2) {
        parts += *p
        parts.push('|')
    }

    ck(parts == "x=v22|k=v1|", 93)

    // split_once / rsplit_once.
    var so? = "key=val=more".split_once("=")
    if so? {
        ck(so.0 == "key" && so.1 == "val=more", 100)
    } else {
        ck(false, 101)
    }

    var rso? = "key=val=more".rsplit_once('=')
    if rso? {
        ck(rso.0 == "key=val" && rso.1 == "more", 102)
    } else {
        ck(false, 103)
    }

    var miss? = "abc".split_once("=")
    ck(!miss?, 104)

    // trim: Unicode white space at either end.
    ck("  x y \t\n".trim() == "x y", 110)
    ck(" 　é ".trim() == "é", 111)
    ck("  x ".trim_start() == "x " && "  x ".trim_end() == "  x", 112)
    ck("   ".trim() == "" && "".trim() == "" && "x".trim() == "x", 113)
    ck("  x ".trim().is_view(), 114)

    // trim_matches: every match at either end.
    ck("xxhixx".trim_matches('x') == "hi", 120)
    ck("ababhiab".trim_matches("ab") == "hi", 121)
    ck("123hi45".trim_matches(Pred { f: is_digit }) == "hi", 122)
    ck("xxxx".trim_matches('x') == "" && "hi".trim_matches('x') == "hi", 123)
    ck("ééhé".trim_matches(ch(0xe9)) == "h", 124)

    // strip_prefix / strip_suffix: once, or null.
    var sp? = "prefix-body".strip_prefix("prefix-")
    if sp? {
        ck(sp == "body", 130)
    } else {
        ck(false, 131)
    }

    var ss? = "body.k".strip_suffix(".k")
    if ss? {
        ck(ss == "body", 132)
    } else {
        ck(false, 133)
    }

    var no1? = "body".strip_prefix("x")
    var no2? = "body".strip_suffix('x')
    ck(!no1? && !no2?, 134)
    var sc? = "éa".strip_prefix(ch(0xe9))
    if sc? {
        ck(sc == "a", 135)
    } else {
        ck(false, 136)
    }

    // A view keeps the ASCII bit of what it was cut from.
    var av = "hello world"[0..5]
    ck(av.is_ascii() && av.codepoints() == 5, 140)
    var nv = "héllo wörld"[0..6]
    ck(nv.codepoints() == 5 && !nv.is_ascii(), 141)
    var pa = "héllo wörld"[7..8]
    ck(pa == "w" && pa.is_ascii() && pa.codepoints() == 1, 142)

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
