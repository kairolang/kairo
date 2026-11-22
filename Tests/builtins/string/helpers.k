// The allocating helpers (concat, replace, repeat, case conversion,
// padding), comparison, parse with a user FromStr and the text of a
// ParseError. Each result owns its bytes and is counted.

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

// A parser for a decimal digit string, to drive `parse` and its failures.
struct Small {
    var v: u32
}

extend Small impl FromStr {
    static fn from_str(const s: string) -> Small? {
        var err = ParseError { at: 0, kind: ParseErrorKind::None }
        return Small::from_str_reason(s, &err)
    }

    static fn from_str_reason(const s: string, @inout err: ParseError) -> Small? {
        if s.is_empty() {
            err.kind = ParseErrorKind::Empty
            return null
        }

        var v: u32   = 0
        var i: usize = 0
        for c in s {
            if c < '0' || c > '9' {
                err.kind = ParseErrorKind::InvalidChar
                err.at   = i as u32
                return null
            }

            var d: u32 = c
            v = v * 10 + (d - 48)
            if v > 999 {
                err.kind = ParseErrorKind::Overflow
                err.at   = i as u32
                return null
            }

            i += 1
        }

        return Small { v: v }
    }
}

fn parse_or(const s: string, fallback: u32) -> u32 {
    var r = try s.try_parse<Small>() catch => Small { v: fallback }
    return r.v
}

fn parse_message(const s: string) -> string {
    try {
        var r = s.try_parse<Small>()
        return "no panic"
    } catch e: ParseError {
        return e.op panic()
    }
}

fn main() -> i32 {
    // concat: neither side changes; the result is owned and counted.
    var a = "héllo"
    var b = ", wörld"
    var c = a.concat(b)
    ck(c == "héllo, wörld" && c.is_owned() && c.codepoints() == 12 && c.size() == 14, 1)
    ck(a == "héllo" && a.is_static(), 2)
    ck("".concat("") == "" && "a".concat("") == "a" && "".concat("b") == "b", 3)
    ck("ab".concat("cd").is_ascii(), 4)

    // replace: with a string, a char and a predicate; a limit; an empty pattern.
    ck("a-b-c".replace("-", "+") == "a+b+c", 10)
    ck("a-b-c".replace("-", "") == "abc", 11)
    ck("a-b-c".replace("-", "--") == "a--b--c", 12)
    ck("a-b-c".replace("-", "+", 1) == "a+b-c", 13)
    ck("a-b-c".replace("-", "+", 0) == "a-b-c", 14)
    ck("abc".replace("x", "y") == "abc" && "abc".replace("x", "y").is_owned(), 15)
    ck("aXbXc".replace('X', "é") == "aébéc", 16)
    ck("a1b22c".replace(Pred { f: is_digit }, "#") == "a#b##c", 17)
    ck("abc".replace("", "-") == "-a-b-c-", 18)
    ck("aaaa".replace("aa", "b") == "bb" && "aaa".replace("aa", "b") == "ba", 19)
    ck("".replace("a", "b") == "" && "".replace("", "x") == "x", 20)
    var rr = "héé".replace("é", "e")
    ck(rr == "hee" && rr.codepoints() == 3, 21)

    // repeat.
    ck("ab".repeat(3) == "ababab" && "ab".repeat(0) == "" && "".repeat(5) == "", 30)
    var r3 = "é".repeat(4)
    ck(r3.size() == 8 && r3.codepoints() == 4 && r3.is_owned(), 31)
    ck("x".repeat(1) == "x", 32)
    // An empty string repeated any number of times is empty, at once.
    ck("".repeat(usize::MAX) == "" && !"".repeat(usize::MAX).is_owned(), 33)

    // ASCII case: only a..z and A..Z move.
    ck("Hello, World 123".to_ascii_upper() == "HELLO, WORLD 123", 40)
    ck("Hello, World 123".to_ascii_lower() == "hello, world 123", 41)
    ck("héLLo É".to_ascii_upper() == "HéLLO É" && "HÉllo".to_ascii_lower() == "hÉllo", 42)
    ck("".to_ascii_upper() == "" && "@[`{".to_ascii_upper() == "@[`{" && "@[`{".to_ascii_lower() == "@[`{", 43)
    var up = "abc".to_ascii_upper()
    ck(up.is_owned() && up.codepoints() == 3, 44)

    // Padding counts codepoints.
    ck("ab".pad_start(5) == "   ab" && "ab".pad_end(5) == "ab   ", 50)
    ck("ab".pad_start(5, '0') == "000ab" && "ab".pad_end(5, '.') == "ab...", 51)
    ck("abc".pad_start(3) == "abc" && "abc".pad_start(2) == "abc" && "abc".pad_end(0) == "abc", 52)
    ck("é".pad_start(3, '*') == "**é" && "é".pad_end(3, ch(0x20ac)) == "é€€", 53)
    var pe = "é".pad_end(3, ch(0x20ac))
    ck(pe.codepoints() == 3 && pe.size() == 8, 54)
    ck("".pad_start(2, 'x') == "xx", 55)

    // == and the order: bytes, then length. Byte order is codepoint order.
    ck("abc" == "abc" && !("abc" == "abd") && !("abc" == "ab") && "" == "", 60)
    ck("abc" != "abd", 61)
    ck("abc" < "abd" && "ab" < "abc" && "" < "a" && !("b" < "a"), 62)
    ck("abc" <= "abc" && "abd" > "abc" && "abc" >= "ab", 63)
    ck(("a" <=> "b") == Ordering::Less && ("b" <=> "a") == Ordering::Greater, 64)
    ck(("ab" <=> "ab") == Ordering::Equal, 65)
    ck("z" < "é" && "é" < "€" && "€" < "😀", 66)
    // Every length around the inline comparison's edges, differing in each position.
    var bad = 0
    for var len: usize = 0; len <= 40; len += 1 {
        var x = string('q', len)
        var y = x.to_owned()
        if !(x == y) || !(x.view() == y) {
            bad += 1
        }

        for var pos: usize = 0; pos < len; pos += 1 {
            var z = x[..pos].to_owned()
            z.push('r')
            z += x[(pos + 1)..]
            if x == z || !(x < z) || z.size() != len {
                bad += 1
            }
        }
    }

    ck(bad == 0, 67)

    // eq_ignore_ascii_case: ASCII letters only.
    ck("Hello".eq_ignore_ascii_case("hELLO") && !"Hello".eq_ignore_ascii_case("Hellp"), 70)
    ck(!"é".eq_ignore_ascii_case("É") && "é!".eq_ignore_ascii_case("é!"), 71)
    ck(!"ab".eq_ignore_ascii_case("abc") && "".eq_ignore_ascii_case(""), 72)
    ck(!"@".eq_ignore_ascii_case("`") && !"[".eq_ignore_ascii_case("{"), 73)

    // Access by byte and by codepoint.
    var m = "aé€😀z"
    ck(m[0] == 'a' && m[1] == ch(0xe9) && m[3] == ch(0x20ac) && m[6] == ch(0x1f600) && m[10] == 'z', 80)
    ck(m.get(0) === 'a' && m.get(6) === ch(0x1f600), 81)
    var g1? = m.get(2)
    var g2? = m.get(11)
    var g3? = m.get(7)
    ck(!g1? && !g2? && !g3?, 82)
    ck(m.char_at(0) === 'a' && m.char_at(1) === ch(0xe9) && m.char_at(3) === ch(0x1f600) && m.char_at(4) === 'z', 83)
    var c5? = m.char_at(5)
    ck(!c5?, 84)
    ck(m.byte_offset(0) === 0 && m.byte_offset(1) === 1 && m.byte_offset(2) === 3, 85)
    ck(m.byte_offset(3) === 6 && m.byte_offset(4) === 10 && m.byte_offset(5) === 11, 86)
    var b6? = m.byte_offset(6)
    ck(!b6?, 87)
    var hello = "hello"
    ck(hello.char_at(4) === 'o' && hello.byte_offset(5) === 5, 88)
    var a5? = hello.char_at(5)
    var a6? = hello.byte_offset(6)
    ck(!a5? && !a6?, 89)
    ck(m.first() === 'a' && m.last() === 'z' && "é".first() === ch(0xe9) && "a😀".last() === ch(0x1f600), 90)
    var f0? = "".first()
    var l0? = "".last()
    ck(!f0? && !l0?, 91)

    // bytes() and data().
    var by = m.bytes()
    ck(by.size() == 11 && by[0] == 97 && by[1] == 0xc3 && by[2] == 0xa9 && by[10] == 122, 95)

    // parse: the value, or a panic that carries where and why.
    ck(parse_or("123", 7) == 123 && parse_or("0", 7) == 0, 100)
    ck(parse_or("", 7) == 7 && parse_or("12x", 7) == 7 && parse_or("99999", 7) == 7, 101)
    ck(parse_message("12") == "no panic", 102)
    ck(parse_message("") == "parse error: empty input", 103)
    ck(parse_message("12x4") == "parse error: invalid character at byte 2", 104)
    ck(parse_message("12345") == "parse error: value out of range at byte 3", 105)
    var pe2 = ParseError {
        at:   4000000000,
        kind: ParseErrorKind::Trailing,
    }

    ck(pe2.op panic() == "parse error: trailing characters at byte 4000000000", 106)
    ck(sizeof(ParseError) == 8, 107)

    if FAILS == 0 {
        io::println("ok")
    }

    return FAILS
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: ok
