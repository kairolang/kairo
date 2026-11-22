// F256 and F512 parse through FromStr: `from_str` gives the correctly
// rounded value or null, `try_from_str` the value or a ParseError at the
// byte the parse stopped at (Empty for empty text), and `parse<T>()` /
// `try_parse<T>()` reach both.

import std::io::*

static FAILS: i32 = 0

fn ck(ok: bool, what: string) {
    if !ok {
        println(f"FAIL {what}")
        FAILS += 1
    }
}

fn why256(const t: string) -> string {
    try {
        var v = F256::try_from_str(t)
        return "ok"
    } catch e: ParseError {
        return f"{e.kind as u8}@{e.at}"
    }
}

fn why512(const t: string) -> string {
    try {
        var v = t.try_parse<F512>()
        return "ok"
    } catch e: ParseError {
        return f"{e.kind as u8}@{e.at}"
    }
}

fn main() -> i32 {
    var one = 1.5f256
    var a? = F256::from_str("1.5")
    ck(a? && a.to_bits() == __builtin_bitcast<u256, f256>(one), "F256::from_str(1.5)")
    var b? = "0x1.8p0".parse<F256>()
    ck(b? && b.to_bits() == __builtin_bitcast<u256, f256>(one), "parse<F256> of hex")
    ck(!F256::from_str("1.5x")?, "F256::from_str rejects 1.5x")
    ck(!F256::from_str("")?, "F256::from_str rejects empty text")

    var c = try F256::try_from_str("-inf") catch e: ParseError => F256()
    ck(c.to_bits() == __builtin_bitcast<u256, f256>(-f256::INFINITY), "F256::try_from_str(-inf)")
    ck(why256("1.5x") == f"{ParseErrorKind::InvalidChar as u8}@3", f"1.5x: {why256("1.5x")}")
    ck(why256("") == f"{ParseErrorKind::Empty as u8}@0", f"empty: {why256("")}")
    ck(why256("1..2") == f"{ParseErrorKind::InvalidChar as u8}@2", f"1..2: {why256("1..2")}")
    ck(why256("2.25") == "ok", "2.25 parses")

    var half = 0.5f512
    var d? = F512::from_str("0.5")
    ck(d? && d.to_bits() == __builtin_bitcast<u512, f512>(half), "F512::from_str(0.5)")
    ck(!"nope".parse<F512>()?, "parse<F512> rejects nope")
    var e = try "0.5".try_parse<F512>() catch err: ParseError => F512()
    ck(e.to_bits() == __builtin_bitcast<u512, f512>(half), "try_parse<F512>")
    ck(why512("12e") == f"{ParseErrorKind::InvalidChar as u8}@3", f"12e: {why512("12e")}")
    ck(why512("-") == f"{ParseErrorKind::InvalidChar as u8}@1", f"-: {why512("-")}")

    println(f"done, {FAILS} failures")
    return FAILS
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: done, 0 failures
