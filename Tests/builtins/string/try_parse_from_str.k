// The two forms of every fallible parse. `parse<T>()` and `T::from_str`
// return null for text that spells no T and say nothing else;
// `try_parse<T>()` and `T::try_from_str` return the T, or raise a
// ParseError naming the reason and the byte. Both forms accept the same
// texts: for primitives, for a user conformer, and through a bound.

import std::io

static FAILS: i32 = 0

fn ck(ok: bool, what: string) {
    if !ok {
        io::println(f"FAIL {what}")
        FAILS += 1
    }
}

// Digits only, at most 999: a user conformer.
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

// The raising form through a bound, and the null form through one.
fn <T impl FromStr> strict(const s: string) panic(ParseError) -> T = s.try_parse<T>()

fn <T impl FromStr> lenient(const s: string) -> T? = T::from_str(s)

// The reason `t.try_parse<i32>()` raises, as "kind@at"; "ok" when it accepts.
fn why_i32(const t: string) -> string {
    try {
        var v = t.try_parse<i32>()
        return "ok"
    } catch e: ParseError {
        return f"{e.kind as u8}@{e.at}"
    }
}

fn why_small(const t: string) -> string {
    try {
        var v = strict<Small>(t)
        return "ok"
    } catch e: ParseError {
        return f"{e.kind as u8}@{e.at}"
    }
}

fn main() -> i32 {
    // parse / from_str: the value, or null.
    var a? = "42".parse<i32>()
    ck(a? && a == 42, "parse<i32> accepts 42")
    var b? = "4x2".parse<i32>()
    ck(!b?, "parse<i32> rejects 4x2 with null")
    var c? = "".parse<u8>()
    ck(!c?, "parse<u8> rejects the empty text")
    var d? = "256".parse<u8>()
    ck(!d?, "parse<u8> rejects 256")
    var e? = i64::from_str("-9000000000")
    ck(e? && e == -9000000000, "i64::from_str")
    var f? = "2.5".parse<f64>()
    ck(f? && f == 2.5, "parse<f64>")
    var g? = "true".parse<bool>()
    ck(g? && g, "parse<bool>")
    var h? = "x".parse<char>()
    ck(h? && h == 'x', "parse<char>")

    // try_parse / try_from_str: the value, or the reason.
    var p = try "123".try_parse<i32>() catch e: ParseError => -1
    ck(p == 123, "try_parse<i32> accepts 123")
    var q = try i32::try_from_str("-7") catch e: ParseError => 0
    ck(q == -7, "i32::try_from_str")
    var q8 = try u8::try_from_str("300") catch e: ParseError => (e.kind as u8) + 100
    ck(q8 == (ParseErrorKind::Overflow as u8) + 100, f"u8::try_from_str raises Overflow: {q8}")
    var qf = try f64::try_from_str("1e3") catch e: ParseError => -1.0
    ck(qf == 1000.0, "f64::try_from_str")
    var qb = try bool::try_from_str("yes") catch e: ParseError => true
    ck(qb, "bool::try_from_str raises for yes")
    var qc = try char::try_from_str("ab") catch e: ParseError => '?'
    ck(qc == '?', "char::try_from_str raises for two chars")
    var r = try "1.25".try_parse<f32>() catch e: ParseError => 0.0f32
    ck(r == 1.25f32, "try_parse<f32>")
    ck(why_i32("12x") == f"{ParseErrorKind::Trailing as u8}@2", f"12x: {why_i32("12x")}")
    ck(why_i32("") == f"{ParseErrorKind::Empty as u8}@0", f"empty: {why_i32("")}")
    ck(why_i32("x") == f"{ParseErrorKind::InvalidChar as u8}@0", f"x: {why_i32("x")}")
    ck(why_i32("99999999999").starts_with(f"{ParseErrorKind::Overflow as u8}@"), "overflow is Overflow")
    var msg = ""
    try {
        var m = "".try_parse<u16>()
    } catch e: ParseError {
        msg = e.op panic()
    }

    ck(msg == "parse error: empty input", f"message: {msg}")

    // Both forms agree, for a primitive and for a user conformer.
    var texts: [string] = ["0", "7", "999", "1000", "", "12a", "a"]
    for t in texts {
        var n? = t.parse<u32>()
        var raised      = false
        var m:      u32 = 0
        try {
            m = t.try_parse<u32>()
        } catch e: ParseError {
            raised = true
        }

        ck(n? != raised, f"u32 forms agree on '{t}'")
        if n? {
            ck(n == m, f"u32 forms give one value for '{t}'")
        }

        var s? = t.parse<Small>()
        var sm = why_small(t)
        ck(s? == (sm == "ok"), f"Small forms agree on '{t}'")
        var l? = lenient<Small>(t)
        ck(l? == s?, f"Small through a bound agrees on '{t}'")
    }

    ck(why_small("12a") == f"{ParseErrorKind::InvalidChar as u8}@2", f"Small 12a: {why_small("12a")}")
    ck(why_small("1000") == f"{ParseErrorKind::Overflow as u8}@3", f"Small 1000: {why_small("1000")}")
    var k = try strict<i32>("55") catch e: ParseError => 0
    ck(k == 55, "strict<i32> through the bound")
    var z = try strict<i32>("5 5") catch e: ParseError => -(e.at as i32)
    ck(z == -1, "strict<i32> raises at byte 1")

    io::println(f"done, {FAILS} failures")
    return FAILS
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: done, 0 failures
