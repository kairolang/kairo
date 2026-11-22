// Iteration and conversion: `for c in s`, Chars forward / backward / from both
// ends, char_indices, every code point boundary value pushed and read back,
// and the text conversions that have a counterpart in either library: a number
// to text (`as string`, append, f-strings) and text to a number (`parse`) with
// its error kinds and the byte offset it reports.
// Cases from libc++ test/std/strings/string.conversions/ (to_string, stoi, stol, stoul)
// Cases from Rust library/alloctests/tests/str.rs (chars, char_indices, rev chars, from_str)
// Cases from Rust library/coretests/tests/char.rs (len_utf8, encode_utf8, from_u32 boundary values)

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

fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

fn for_loop_over_chars() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "aé€😀z")
        var sum: u32 = 0
        var n        = 0
        for c in s {
            var v: u32 = c
            sum += v
            n   += 1
        }

        ck(n == 5 && sum == 97 + 0xe9 + 0x20ac + 0x1f600 + 122, b + 1, "for over chars")
        n = 0
        var e = mk(k, "")
        for c in e {
            n += 1
        }

        ck(n == 0, b + 2, "for over empty")
        var order = string()
        for c in mk(k, "héllo") {
            order.push(c)
        }

        ck(order == "héllo", b + 3, "for rebuilds the text")
    }
}

fn chars_forward_and_back() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s  = mk(k, "aé€😀z")
        var it = s.chars()
        var c1? = it.next()
        var c2? = it.next()
        var c3? = it.next()
        var c4? = it.next()
        var c5? = it.next()
        var c6? = it.next()
        ck(c1? && c1 == 'a' && c2? && c2 == ch(0xe9) && c3? && c3 == ch(0x20ac), b + 1, "next, first three")
        ck(c4? && c4 == ch(0x1f600) && c5? && c5 == 'z' && !c6?, b + 2, "next, the rest then null")
        var c7? = it.next()
        ck(!c7?, b + 3, "next stays null")
        var back = s.chars()
        var d1? = back.next_back()
        var d2? = back.next_back()
        var d3? = back.next_back()
        var d4? = back.next_back()
        var d5? = back.next_back()
        var d6? = back.next_back()
        ck(d1? && d1 == 'z' && d2? && d2 == ch(0x1f600) && d3? && d3 == ch(0x20ac), b + 4, "next_back, first three")
        ck(d4? && d4 == ch(0xe9) && d5? && d5 == 'a' && !d6?, b + 5, "next_back, the rest then null")
        var both = s.chars()
        var e1? = both.next()
        var e2? = both.next_back()
        var e3? = both.next()
        var e4? = both.next_back()
        var e5? = both.next()
        var e6? = both.next()
        var e7? = both.next_back()
        ck(e1? && e1 == 'a' && e2? && e2 == 'z' && e3? && e3 == ch(0xe9) && e4? && e4 == ch(0x1f600), b + 6, "both ends")
        ck(e5? && e5 == ch(0x20ac) && !e6? && !e7?, b + 7, "ends meet, each char once")
        var empty = mk(k, "").chars()
        var f1? = empty.next()
        var f2? = empty.next_back()
        ck(!f1? && !f2?, b + 8, "chars of empty")
        var one = mk(k, "😀").chars()
        var g1? = one.next_back()
        var g2? = one.next()
        ck(g1? && g1 == ch(0x1f600) && !g2?, b + 9, "one char from the back")
    }
}

fn chars_by_the_iterator_adapters() {
    var s = "aé€😀z"
    var n: usize = 0
    var it = s.chars()
    loop {
        var c? = it.next()
        if !c? {
            break
        }

        n += 1
    }

    ck(n == 5, 10, "counting with next")
    var rev = string()
    var back = s.chars()
    loop {
        var c? = back.next_back()
        if !c? {
            break
        }

        rev.push(c)
    }

    ck(rev == "z😀€éa" && rev.codepoints() == 5, 11, "reversing with next_back")
    var moved = "ab".chars()
    var m1? = moved.next()
    var taken = moved
    var m2? = taken.next()
    ck(m1? && m1 == 'a' && m2? && m2 == 'b', 12, "a moved Chars continues")
}

fn char_indices_member() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "aé€😀z")
        var offs: usize = 0
        var cnt         = 0
        var all         = true
        for (i, c) in s.char_indices() {
            offs = offs * 16 + i
            cnt += 1
            if s[i] != c {
                all = false
            }
        }

        ck(cnt == 5 && offs == 0x0136a && all, b + 1, "offsets and chars")
        var e = mk(k, "")
        var n = 0
        for (i, c) in e.char_indices() {
            n += 1
        }

        ck(n == 0, b + 2, "char_indices of empty")
        var a = mk(k, "abc")
        var last: usize = 99
        for (i, c) in a.char_indices() {
            last = i
        }

        ck(last == 2, b + 3, "ascii offsets")
    }
}

// The first and last scalar value of each UTF-8 width, and the values around
// each boundary: pushed, read back by index and by Chars, and sized.
fn boundary_code_points() {
    var values: [u32] = [0x0, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff]
    var widths: [usize] = [1, 1, 2, 2, 3, 3, 3, 3, 4, 4]
    for var i: usize = 0; i < values.size(); i += 1 {
        var s = string()
        s.push('x')
        s.push(ch(values[i]))
        s.push('y')
        var w = widths[i]
        var ok = s.size() == 2 + w && s.codepoints() == 3 && s[1] == ch(values[i]) && s[1 + w] == 'y'
        var it = s.chars()
        var a? = it.next()
        var c? = it.next()
        var d? = it.next()
        ok = ok && a? && a == 'x' && c? && c == ch(values[i]) && d? && d == 'y'
        var lone = string()
        lone.push(ch(values[i]))
        ok = ok && lone.size() == w && lone.codepoints() == 1 && lone.is_ascii() == (w == 1)
        var g? = lone.get(0)
        var l? = lone.last()
        ok = ok && g? && g == ch(values[i]) && l? && l == ch(values[i])
        ck(ok, 20 + (i as i32), f"boundary value {values[i]}")
        // The same value spelled through a repeat constructor.
        var rep = string(ch(values[i]), 3)
        ck(rep.size() == 3 * w && rep.codepoints() == 3, 40 + (i as i32), f"repeat of value {values[i]}")
    }
}

fn number_to_text() {
    ck((0 as i32) as string == "0" && (-1 as i32) as string == "-1", 50, "small integers")
    ck((2147483647 as i32) as string == "2147483647", 51, "i32 max")
    ck((-2147483648 as i64) as string == "-2147483648", 52, "i32 min as i64")
    ck((9223372036854775807 as i64) as string == "9223372036854775807", 53, "i64 max")
    ck((-9223372036854775807 as i64 - 1) as string == "-9223372036854775808", 54, "i64 min")
    ck((18446744073709551615 as u64) as string == "18446744073709551615", 55, "u64 max")
    ck((255 as u8) as string == "255" && (0 as u8) as string == "0", 56, "u8")
    ck((-128 as i8) as string == "-128", 57, "i8 min")
    ck((65535 as u16) as string == "65535", 58, "u16 max")
    var t = (1234 as i32) as string
    ck(t.is_ascii() && t.size() == 4 && t.codepoints() == 4, 59, "the text is sound")
    var s = f"{7}-{-8}-{9 as u64}"
    ck(s == "7--8-9", 60, "f-string of integers")
    var u = f"é{1}€{2}😀"
    ck(u == "é1€2😀" && u.codepoints() == 5, 61, "f-string around wide chars")
    ck(f"{true}{false}" == "truefalse", 62, "f-string of bools")
    ck(f"{'x'}{ch(0x20ac)}" == "x€", 63, "f-string of chars")
    var big = string()
    for var i = 0; i < 100; i += 1 {
        big.append(i)
    }

    ck(big.size() == 10 + 90 * 2, 64, "append of a hundred numbers")
}

fn parse_kind(const s: string) -> ParseErrorKind {
    try {
        var r = s.try_parse<i32>()
        return ParseErrorKind::None
    } catch e: ParseError {
        return e.kind
    }
}

fn parse_at(const s: string) -> u32 {
    try {
        var r = s.try_parse<i32>()
        return 9999
    } catch e: ParseError {
        return e.at
    }
}

fn text_to_number() panic(ParseError) {
    var a = "42".try_parse<i32>()
    ck(a == 42, 70, "parse 42")
    var b = "-17".try_parse<i32>()
    ck(b == -17, 71, "parse negative")
    var c = "+5".try_parse<i32>()
    ck(c == 5, 72, "parse with a plus sign")
    var d = "2147483647".try_parse<i32>()
    ck(d == 2147483647, 73, "i32 max")
    var e = "-2147483648".try_parse<i32>()
    ck(e == -2147483648, 74, "i32 min")
    var f = "255".try_parse<u8>()
    ck(f == 255, 75, "u8 max")
    var g = "18446744073709551615".try_parse<u64>()
    ck(g == 18446744073709551615, 76, "u64 max")
    var h = "007".try_parse<u32>()
    ck(h == 7, 77, "leading zeros")
    var i = "0".try_parse<i64>()
    ck(i == 0, 78, "zero")
    var view = "x 123 y"[2..5]
    var j = view.try_parse<i32>()
    ck(j == 123, 79, "parse a view that has no terminator")
    var k = "-0".try_parse<i32>()
    ck(k == 0, 80, "negative zero")
    var heap = "99".to_owned()
    var l = heap.try_parse<u16>()
    ck(l == 99, 81, "parse a heap string")
}

fn text_to_number_errors() panic(ParseError) {
    ck(parse_kind("") == ParseErrorKind::Empty && parse_at("") == 0, 90, "empty")
    ck(parse_kind("-") == ParseErrorKind::InvalidChar && parse_at("-") == 0, 91, "a sign alone")
    ck(parse_kind("+") == ParseErrorKind::InvalidChar, 92, "a plus alone")
    ck(parse_kind("abc") == ParseErrorKind::InvalidChar && parse_at("abc") == 0, 93, "letters")
    ck(parse_kind(" 1") == ParseErrorKind::InvalidChar && parse_at(" 1") == 0, 94, "leading space")
    ck(parse_kind("1 ") == ParseErrorKind::Trailing && parse_at("1 ") == 1, 95, "trailing space")
    ck(parse_kind("12x") == ParseErrorKind::Trailing && parse_at("12x") == 2, 96, "trailing letter")
    ck(parse_kind("1.5") == ParseErrorKind::Trailing && parse_at("1.5") == 1, 97, "a fraction")
    ck(parse_kind("2147483648") == ParseErrorKind::Overflow, 98, "i32 max plus one")
    ck(parse_kind("-2147483649") == ParseErrorKind::Overflow, 99, "i32 min minus one")
    ck(parse_kind("99999999999999999999") == ParseErrorKind::Overflow, 100, "far out of range")
    ck(parse_kind("--1") == ParseErrorKind::InvalidChar && parse_at("--1") == 1, 101, "double sign")
    ck(parse_kind("é") == ParseErrorKind::InvalidChar && parse_at("é") == 0, 102, "a wide char")
    ck(parse_kind("1é") == ParseErrorKind::Trailing && parse_at("1é") == 1, 103, "a wide char after digits")
    ck(parse_kind("1_000") == ParseErrorKind::Trailing, 104, "an underscore")
    ck(parse_kind("0x10") == ParseErrorKind::Trailing && parse_at("0x10") == 1, 105, "a hex prefix")
    var u = try "-1".try_parse<u32>() catch => 7
    ck(u == 7, 106, "negative into unsigned")
    var o = try "256".try_parse<u8>() catch => 7
    ck(o == 7, 107, "u8 overflow")
    var msg = string()
    try {
        var r = "12x".try_parse<i32>()
    } catch e: ParseError {
        msg = e.op panic()
    }

    ck(msg == "parse error: trailing characters at byte 2", 108, "the panic message")
    var msg2 = string()
    try {
        var r = "".try_parse<i32>()
    } catch e: ParseError {
        msg2 = e.op panic()
    }

    ck(msg2 == "parse error: empty input", 109, "the message for empty input")
}

fn round_trip() panic(ParseError) {
    var values: [i64] = [0, 1, -1, 9, 10, -10, 99, 100, 12345, -12345, 2147483647, -2147483648, 9223372036854775807]
    var ok = true
    for var i: usize = 0; i < values.size(); i += 1 {
        var text = values[i] as string
        var back = text.try_parse<i64>()
        if back != values[i] {
            ok = false
        }
    }

    ck(ok, 110, "integers survive text and back")
}

fn main() -> i32 {
    for_loop_over_chars()
    chars_forward_and_back()
    chars_by_the_iterator_adapters()
    char_indices_member()
    boundary_code_points()
    number_to_text()
    try {
        text_to_number()
        text_to_number_errors()
        round_trip()
    } catch e: ParseError {
        ck(false, 120, "a parse that must succeed panicked")
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe
