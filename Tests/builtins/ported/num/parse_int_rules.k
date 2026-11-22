// Text to integer for i8, i16, i32, i64, isize, u8, u16, u32, u64 and usize (the last four are 64 bits
// wide): the maximum and minimum, the value one past each, a plus and a minus sign, zeros before the
// digits (past 19 characters too), digits beyond any range, lone and doubled signs, empty text, spaces,
// trailing letters, and non-ASCII text; and the panicking `string::parse`.
//
// The rule (documented on parse_unsigned and parse_signed, int_overflow and ParseErrorKind):
// `[+]digits`, or `[+-]digits` for a signed type; empty text is Empty at offset 0; a sign with nothing
// after it is InvalidChar at 0; no digit where the first belongs is InvalidChar at that byte (a minus
// sign is one for an unsigned type); bytes after the digits are Trailing at the first of them, even
// when the digits are out of range; digits out of range with nothing after them are Overflow at the
// digit that first takes the value above the limit.
//
// Where Kairo differs from Rust: the error is one of four kinds with the offset of the byte at
// fault (Rust's PosOverflow and NegOverflow are both Overflow here, InvalidDigit is InvalidChar or
// Trailing by position). Rust's from_str_radix has no counterpart: i128 and u128 have no text
// conversions, and no radix parse exists (prim.k: "u128 and i128 have no text conversions here").
// Cases from Rust library/coretests/tests/num/mod.rs (test_int_from_str_overflow, the plus-sign,
// invalid-input and empty-input tests, from_str_issue7588)
// Cases from Rust library/coretests/tests/num/{i8,i16,i32,i64,u8,u16,u32,u64}.rs (from_str)

import std::io

// The reason `t.parse<T>()` raises: kind None at 0 when it accepts `t`.
fn <T impl FromStr> reason_of(const t: string) -> ParseError {
    try {
        var v = t.parse<T>()
        return ParseError { at: 0, kind: ParseErrorKind::None }
    } catch e: ParseError {
        return e
    }
}

static CODE: i32 = 0
static NO:   i32 = 0

fn fail(const what: string) {
    io::println(f"FAIL case {NO}: {what}")
    if CODE == 0 {
        CODE = if NO > 250 => 250 else => NO
    }
}

fn ok_i8(const text: string, want: i8) {
    NO += 1
    var r?  = i8::from_str(text)
    var err = reason_of<i8>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"i8 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"i8 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_i8(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = i8::from_str(text)
    var err = reason_of<i8>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"i8 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_i16(const text: string, want: i16) {
    NO += 1
    var r?  = i16::from_str(text)
    var err = reason_of<i16>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"i16 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"i16 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_i16(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = i16::from_str(text)
    var err = reason_of<i16>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"i16 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_i32(const text: string, want: i32) {
    NO += 1
    var r?  = i32::from_str(text)
    var err = reason_of<i32>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"i32 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"i32 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_i32(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = i32::from_str(text)
    var err = reason_of<i32>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"i32 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_i64(const text: string, want: i64) {
    NO += 1
    var r?  = i64::from_str(text)
    var err = reason_of<i64>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"i64 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"i64 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_i64(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = i64::from_str(text)
    var err = reason_of<i64>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"i64 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_isize(const text: string, want: isize) {
    NO += 1
    var r?  = isize::from_str(text)
    var err = reason_of<isize>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"isize '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"isize '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_isize(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = isize::from_str(text)
    var err = reason_of<isize>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"isize '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_u8(const text: string, want: u8) {
    NO += 1
    var r?  = u8::from_str(text)
    var err = reason_of<u8>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"u8 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"u8 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_u8(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = u8::from_str(text)
    var err = reason_of<u8>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"u8 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_u16(const text: string, want: u16) {
    NO += 1
    var r?  = u16::from_str(text)
    var err = reason_of<u16>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"u16 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"u16 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_u16(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = u16::from_str(text)
    var err = reason_of<u16>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"u16 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_u32(const text: string, want: u32) {
    NO += 1
    var r?  = u32::from_str(text)
    var err = reason_of<u32>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"u32 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"u32 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_u32(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = u32::from_str(text)
    var err = reason_of<u32>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"u32 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_u64(const text: string, want: u64) {
    NO += 1
    var r?  = u64::from_str(text)
    var err = reason_of<u64>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"u64 '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"u64 '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_u64(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = u64::from_str(text)
    var err = reason_of<u64>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"u64 '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn ok_usize(const text: string, want: usize) {
    NO += 1
    var r?  = usize::from_str(text)
    var err = reason_of<usize>(text)
    if r? {
        if err.kind != ParseErrorKind::None || err.at != 0 || r != want {
            fail(f"usize '{text}' gave {r} kind {err.kind as u8}, want {want}")
        }
    } else {
        fail(f"usize '{text}' was rejected (kind {err.kind as u8} at {err.at}), want {want}")
    }
}

fn bad_usize(const text: string, kind: ParseErrorKind, at: u32) {
    NO += 1
    var r?  = usize::from_str(text)
    var err = reason_of<usize>(text)
    if r? || err.kind != kind || err.at != at {
        fail(f"usize '{text}' gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn limits_and_zeros() {
    // i8
    ok_i8("127", 127)
    ok_i8("+127", 127)
    bad_i8("128", ParseErrorKind::Overflow, 2)
    bad_i8("+128", ParseErrorKind::Overflow, 3)
    bad_i8("1270", ParseErrorKind::Overflow, 3)
    bad_i8("+1270", ParseErrorKind::Overflow, 4)
    ok_i8("-128", -128)
    bad_i8("-129", ParseErrorKind::Overflow, 3)
    ok_i8("-127", -127)
    ok_i8("126", 126)
    ok_i8("+126", 126)
    ok_i8("0", 0)
    ok_i8("+0", 0)
    ok_i8("1", 1)
    ok_i8("+1", 1)
    ok_i8("-1", -1)
    bad_i8("-1280", ParseErrorKind::Overflow, 4)
    ok_i8("00000000000000000000000000000000000000007", 7)
    ok_i8("+0000000000000000000000000000001", 1)
    bad_i8("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 3)
    bad_i8("9999999999999999999999999", ParseErrorKind::Overflow, 2)
    ok_i8("0000000000000000000127", 127)
    bad_i8("00000000000000000000128", ParseErrorKind::Overflow, 22)
    bad_i8("1270", ParseErrorKind::Overflow, 3)
    ok_i8("-00000000000000000000000000000000000000007", -7)
    ok_i8("-128", -128)
    ok_i8("-0000000000000000000000000128", -128)
    bad_i8("-129", ParseErrorKind::Overflow, 3)
    ok_i8("-0", 0)
    ok_i8("-00", 0)
    // i16
    ok_i16("32767", 32767)
    ok_i16("+32767", 32767)
    bad_i16("32768", ParseErrorKind::Overflow, 4)
    bad_i16("+32768", ParseErrorKind::Overflow, 5)
    bad_i16("327670", ParseErrorKind::Overflow, 5)
    bad_i16("+327670", ParseErrorKind::Overflow, 6)
    ok_i16("-32768", -32768)
    bad_i16("-32769", ParseErrorKind::Overflow, 5)
    ok_i16("-32767", -32767)
    ok_i16("32766", 32766)
    ok_i16("+32766", 32766)
    ok_i16("0", 0)
    ok_i16("+0", 0)
    ok_i16("1", 1)
    ok_i16("+1", 1)
    ok_i16("-1", -1)
    bad_i16("-327680", ParseErrorKind::Overflow, 6)
    ok_i16("00000000000000000000000000000000000000007", 7)
    ok_i16("+0000000000000000000000000000001", 1)
    bad_i16("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 5)
    bad_i16("9999999999999999999999999", ParseErrorKind::Overflow, 4)
    ok_i16("000000000000000000032767", 32767)
    bad_i16("0000000000000000000032768", ParseErrorKind::Overflow, 24)
    bad_i16("327670", ParseErrorKind::Overflow, 5)
    ok_i16("-00000000000000000000000000000000000000007", -7)
    ok_i16("-32768", -32768)
    ok_i16("-000000000000000000000000032768", -32768)
    bad_i16("-32769", ParseErrorKind::Overflow, 5)
    ok_i16("-0", 0)
    ok_i16("-00", 0)
    // i32
    ok_i32("2147483647", 2147483647)
    ok_i32("+2147483647", 2147483647)
    bad_i32("2147483648", ParseErrorKind::Overflow, 9)
    bad_i32("+2147483648", ParseErrorKind::Overflow, 10)
    bad_i32("21474836470", ParseErrorKind::Overflow, 10)
    bad_i32("+21474836470", ParseErrorKind::Overflow, 11)
    ok_i32("-2147483648", -2147483648)
    bad_i32("-2147483649", ParseErrorKind::Overflow, 10)
    ok_i32("-2147483647", -2147483647)
    ok_i32("2147483646", 2147483646)
    ok_i32("+2147483646", 2147483646)
    ok_i32("0", 0)
    ok_i32("+0", 0)
    ok_i32("1", 1)
    ok_i32("+1", 1)
    ok_i32("-1", -1)
    bad_i32("-21474836480", ParseErrorKind::Overflow, 11)
    ok_i32("00000000000000000000000000000000000000007", 7)
    ok_i32("+0000000000000000000000000000001", 1)
    bad_i32("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 10)
    bad_i32("9999999999999999999999999", ParseErrorKind::Overflow, 9)
    ok_i32("00000000000000000002147483647", 2147483647)
    bad_i32("000000000000000000002147483648", ParseErrorKind::Overflow, 29)
    bad_i32("21474836470", ParseErrorKind::Overflow, 10)
    ok_i32("-00000000000000000000000000000000000000007", -7)
    ok_i32("-2147483648", -2147483648)
    ok_i32("-00000000000000000000000002147483648", -2147483648)
    bad_i32("-2147483649", ParseErrorKind::Overflow, 10)
    ok_i32("-0", 0)
    ok_i32("-00", 0)
    // i64
    ok_i64("9223372036854775807", 9223372036854775807)
    ok_i64("+9223372036854775807", 9223372036854775807)
    bad_i64("9223372036854775808", ParseErrorKind::Overflow, 18)
    bad_i64("+9223372036854775808", ParseErrorKind::Overflow, 19)
    bad_i64("92233720368547758070", ParseErrorKind::Overflow, 19)
    bad_i64("+92233720368547758070", ParseErrorKind::Overflow, 20)
    ok_i64("-9223372036854775808", -9223372036854775808)
    bad_i64("-9223372036854775809", ParseErrorKind::Overflow, 19)
    ok_i64("-9223372036854775807", -9223372036854775807)
    ok_i64("9223372036854775806", 9223372036854775806)
    ok_i64("+9223372036854775806", 9223372036854775806)
    ok_i64("0", 0)
    ok_i64("+0", 0)
    ok_i64("1", 1)
    ok_i64("+1", 1)
    ok_i64("-1", -1)
    bad_i64("-92233720368547758080", ParseErrorKind::Overflow, 20)
    ok_i64("00000000000000000000000000000000000000007", 7)
    ok_i64("+0000000000000000000000000000001", 1)
    bad_i64("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 19)
    bad_i64("9999999999999999999999999", ParseErrorKind::Overflow, 18)
    ok_i64("00000000000000000009223372036854775807", 9223372036854775807)
    bad_i64("000000000000000000009223372036854775808", ParseErrorKind::Overflow, 38)
    bad_i64("92233720368547758070", ParseErrorKind::Overflow, 19)
    ok_i64("-00000000000000000000000000000000000000007", -7)
    ok_i64("-9223372036854775808", -9223372036854775808)
    ok_i64("-00000000000000000000000009223372036854775808", -9223372036854775808)
    bad_i64("-9223372036854775809", ParseErrorKind::Overflow, 19)
    ok_i64("-0", 0)
    ok_i64("-00", 0)
    // isize
    ok_isize("9223372036854775807", 9223372036854775807)
    ok_isize("+9223372036854775807", 9223372036854775807)
    bad_isize("9223372036854775808", ParseErrorKind::Overflow, 18)
    bad_isize("+9223372036854775808", ParseErrorKind::Overflow, 19)
    bad_isize("92233720368547758070", ParseErrorKind::Overflow, 19)
    bad_isize("+92233720368547758070", ParseErrorKind::Overflow, 20)
    ok_isize("-9223372036854775808", -9223372036854775808)
    bad_isize("-9223372036854775809", ParseErrorKind::Overflow, 19)
    ok_isize("-9223372036854775807", -9223372036854775807)
    ok_isize("9223372036854775806", 9223372036854775806)
    ok_isize("+9223372036854775806", 9223372036854775806)
    ok_isize("0", 0)
    ok_isize("+0", 0)
    ok_isize("1", 1)
    ok_isize("+1", 1)
    ok_isize("-1", -1)
    bad_isize("-92233720368547758080", ParseErrorKind::Overflow, 20)
    ok_isize("00000000000000000000000000000000000000007", 7)
    ok_isize("+0000000000000000000000000000001", 1)
    bad_isize("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 19)
    bad_isize("9999999999999999999999999", ParseErrorKind::Overflow, 18)
    ok_isize("00000000000000000009223372036854775807", 9223372036854775807)
    bad_isize("000000000000000000009223372036854775808", ParseErrorKind::Overflow, 38)
    bad_isize("92233720368547758070", ParseErrorKind::Overflow, 19)
    ok_isize("-00000000000000000000000000000000000000007", -7)
    ok_isize("-9223372036854775808", -9223372036854775808)
    ok_isize("-00000000000000000000000009223372036854775808", -9223372036854775808)
    bad_isize("-9223372036854775809", ParseErrorKind::Overflow, 19)
    ok_isize("-0", 0)
    ok_isize("-00", 0)
    // u8
    ok_u8("255", 255)
    ok_u8("+255", 255)
    bad_u8("256", ParseErrorKind::Overflow, 2)
    bad_u8("+256", ParseErrorKind::Overflow, 3)
    bad_u8("2550", ParseErrorKind::Overflow, 3)
    bad_u8("+2550", ParseErrorKind::Overflow, 4)
    ok_u8("0", 0)
    ok_u8("+0", 0)
    bad_u8("-1", ParseErrorKind::InvalidChar, 0)
    ok_u8("1", 1)
    ok_u8("+1", 1)
    ok_u8("254", 254)
    ok_u8("+254", 254)
    ok_u8("0", 0)
    ok_u8("+0", 0)
    ok_u8("1", 1)
    ok_u8("+1", 1)
    ok_u8("00000000000000000000000000000000000000007", 7)
    ok_u8("+0000000000000000000000000000001", 1)
    bad_u8("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 3)
    bad_u8("9999999999999999999999999", ParseErrorKind::Overflow, 2)
    ok_u8("0000000000000000000255", 255)
    bad_u8("00000000000000000000256", ParseErrorKind::Overflow, 22)
    bad_u8("2550", ParseErrorKind::Overflow, 3)
    bad_u8("-1", ParseErrorKind::InvalidChar, 0)
    bad_u8("-0", ParseErrorKind::InvalidChar, 0)
    bad_u8("-", ParseErrorKind::InvalidChar, 0)
    bad_u8("+-1", ParseErrorKind::InvalidChar, 1)
    bad_u8("-+1", ParseErrorKind::InvalidChar, 0)
    // u16
    ok_u16("65535", 65535)
    ok_u16("+65535", 65535)
    bad_u16("65536", ParseErrorKind::Overflow, 4)
    bad_u16("+65536", ParseErrorKind::Overflow, 5)
    bad_u16("655350", ParseErrorKind::Overflow, 5)
    bad_u16("+655350", ParseErrorKind::Overflow, 6)
    ok_u16("0", 0)
    ok_u16("+0", 0)
    bad_u16("-1", ParseErrorKind::InvalidChar, 0)
    ok_u16("1", 1)
    ok_u16("+1", 1)
    ok_u16("65534", 65534)
    ok_u16("+65534", 65534)
    ok_u16("0", 0)
    ok_u16("+0", 0)
    ok_u16("1", 1)
    ok_u16("+1", 1)
    ok_u16("00000000000000000000000000000000000000007", 7)
    ok_u16("+0000000000000000000000000000001", 1)
    bad_u16("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 5)
    bad_u16("9999999999999999999999999", ParseErrorKind::Overflow, 4)
    ok_u16("000000000000000000065535", 65535)
    bad_u16("0000000000000000000065536", ParseErrorKind::Overflow, 24)
    bad_u16("655350", ParseErrorKind::Overflow, 5)
    bad_u16("-1", ParseErrorKind::InvalidChar, 0)
    bad_u16("-0", ParseErrorKind::InvalidChar, 0)
    bad_u16("-", ParseErrorKind::InvalidChar, 0)
    bad_u16("+-1", ParseErrorKind::InvalidChar, 1)
    bad_u16("-+1", ParseErrorKind::InvalidChar, 0)
    // u32
    ok_u32("4294967295", 4294967295)
    ok_u32("+4294967295", 4294967295)
    bad_u32("4294967296", ParseErrorKind::Overflow, 9)
    bad_u32("+4294967296", ParseErrorKind::Overflow, 10)
    bad_u32("42949672950", ParseErrorKind::Overflow, 10)
    bad_u32("+42949672950", ParseErrorKind::Overflow, 11)
    ok_u32("0", 0)
    ok_u32("+0", 0)
    bad_u32("-1", ParseErrorKind::InvalidChar, 0)
    ok_u32("1", 1)
    ok_u32("+1", 1)
    ok_u32("4294967294", 4294967294)
    ok_u32("+4294967294", 4294967294)
    ok_u32("0", 0)
    ok_u32("+0", 0)
    ok_u32("1", 1)
    ok_u32("+1", 1)
    ok_u32("00000000000000000000000000000000000000007", 7)
    ok_u32("+0000000000000000000000000000001", 1)
    bad_u32("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 10)
    bad_u32("9999999999999999999999999", ParseErrorKind::Overflow, 9)
    ok_u32("00000000000000000004294967295", 4294967295)
    bad_u32("000000000000000000004294967296", ParseErrorKind::Overflow, 29)
    bad_u32("42949672950", ParseErrorKind::Overflow, 10)
    bad_u32("-1", ParseErrorKind::InvalidChar, 0)
    bad_u32("-0", ParseErrorKind::InvalidChar, 0)
    bad_u32("-", ParseErrorKind::InvalidChar, 0)
    bad_u32("+-1", ParseErrorKind::InvalidChar, 1)
    bad_u32("-+1", ParseErrorKind::InvalidChar, 0)
    // u64
    ok_u64("18446744073709551615", 18446744073709551615)
    ok_u64("+18446744073709551615", 18446744073709551615)
    bad_u64("18446744073709551616", ParseErrorKind::Overflow, 19)
    bad_u64("+18446744073709551616", ParseErrorKind::Overflow, 20)
    bad_u64("184467440737095516150", ParseErrorKind::Overflow, 20)
    bad_u64("+184467440737095516150", ParseErrorKind::Overflow, 21)
    ok_u64("0", 0)
    ok_u64("+0", 0)
    bad_u64("-1", ParseErrorKind::InvalidChar, 0)
    ok_u64("1", 1)
    ok_u64("+1", 1)
    ok_u64("18446744073709551614", 18446744073709551614)
    ok_u64("+18446744073709551614", 18446744073709551614)
    ok_u64("0", 0)
    ok_u64("+0", 0)
    ok_u64("1", 1)
    ok_u64("+1", 1)
    ok_u64("00000000000000000000000000000000000000007", 7)
    ok_u64("+0000000000000000000000000000001", 1)
    bad_u64("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 20)
    bad_u64("9999999999999999999999999", ParseErrorKind::Overflow, 19)
    ok_u64("000000000000000000018446744073709551615", 18446744073709551615)
    bad_u64("0000000000000000000018446744073709551616", ParseErrorKind::Overflow, 39)
    bad_u64("184467440737095516150", ParseErrorKind::Overflow, 20)
    bad_u64("-1", ParseErrorKind::InvalidChar, 0)
    bad_u64("-0", ParseErrorKind::InvalidChar, 0)
    bad_u64("-", ParseErrorKind::InvalidChar, 0)
    bad_u64("+-1", ParseErrorKind::InvalidChar, 1)
    bad_u64("-+1", ParseErrorKind::InvalidChar, 0)
    // usize
    ok_usize("18446744073709551615", 18446744073709551615)
    ok_usize("+18446744073709551615", 18446744073709551615)
    bad_usize("18446744073709551616", ParseErrorKind::Overflow, 19)
    bad_usize("+18446744073709551616", ParseErrorKind::Overflow, 20)
    bad_usize("184467440737095516150", ParseErrorKind::Overflow, 20)
    bad_usize("+184467440737095516150", ParseErrorKind::Overflow, 21)
    ok_usize("0", 0)
    ok_usize("+0", 0)
    bad_usize("-1", ParseErrorKind::InvalidChar, 0)
    ok_usize("1", 1)
    ok_usize("+1", 1)
    ok_usize("18446744073709551614", 18446744073709551614)
    ok_usize("+18446744073709551614", 18446744073709551614)
    ok_usize("0", 0)
    ok_usize("+0", 0)
    ok_usize("1", 1)
    ok_usize("+1", 1)
    ok_usize("00000000000000000000000000000000000000007", 7)
    ok_usize("+0000000000000000000000000000001", 1)
    bad_usize("10000000000000000000000000000000000000000", ParseErrorKind::Overflow, 20)
    bad_usize("9999999999999999999999999", ParseErrorKind::Overflow, 19)
    ok_usize("000000000000000000018446744073709551615", 18446744073709551615)
    bad_usize("0000000000000000000018446744073709551616", ParseErrorKind::Overflow, 39)
    bad_usize("184467440737095516150", ParseErrorKind::Overflow, 20)
    bad_usize("-1", ParseErrorKind::InvalidChar, 0)
    bad_usize("-0", ParseErrorKind::InvalidChar, 0)
    bad_usize("-", ParseErrorKind::InvalidChar, 0)
    bad_usize("+-1", ParseErrorKind::InvalidChar, 1)
    bad_usize("-+1", ParseErrorKind::InvalidChar, 0)
}

fn rust_invalid_inputs() {
    bad_i8("--129", ParseErrorKind::InvalidChar, 1)
    bad_i8("++129", ParseErrorKind::InvalidChar, 1)
    bad_u8("\u0421\u044a\u0435\u0448\u044c", ParseErrorKind::InvalidChar, 0)
    bad_u8("123Hello", ParseErrorKind::Trailing, 3)
    bad_i8("--", ParseErrorKind::InvalidChar, 1)
    bad_i8("-", ParseErrorKind::InvalidChar, 0)
    bad_i8("+", ParseErrorKind::InvalidChar, 0)
    bad_u8("-1", ParseErrorKind::InvalidChar, 0)
    bad_u8("", ParseErrorKind::Empty, 0)
    bad_i8("", ParseErrorKind::Empty, 0)
    bad_u64("", ParseErrorKind::Empty, 0)
    // The 7588 cases: a value a type cannot hold.
    bad_u8("1000", ParseErrorKind::Overflow, 3)
    bad_i16("80000", ParseErrorKind::Overflow, 4)
    // Spaces, signs and letters in every place.
    bad_i32(" 1", ParseErrorKind::InvalidChar, 0)
    bad_i32("1 ", ParseErrorKind::Trailing, 1)
    bad_i32("1 2", ParseErrorKind::Trailing, 1)
    bad_i32("- 1", ParseErrorKind::InvalidChar, 1)
    bad_i32("+ 1", ParseErrorKind::InvalidChar, 1)
    bad_i32("1-", ParseErrorKind::Trailing, 1)
    bad_i32("1+1", ParseErrorKind::Trailing, 1)
    bad_i32("+-1", ParseErrorKind::InvalidChar, 1)
    bad_i32("-+1", ParseErrorKind::InvalidChar, 1)
    bad_i32("1_000", ParseErrorKind::Trailing, 1)
    bad_i32("0x10", ParseErrorKind::Trailing, 1)
    bad_i32("1e3", ParseErrorKind::Trailing, 1)
    bad_i32("1.5", ParseErrorKind::Trailing, 1)
    bad_i32(".5", ParseErrorKind::InvalidChar, 0)
    bad_i32("\n1", ParseErrorKind::InvalidChar, 0)
    bad_i32("1\n", ParseErrorKind::Trailing, 1)
    bad_i32("12abc", ParseErrorKind::Trailing, 2)
    bad_i32("abc", ParseErrorKind::InvalidChar, 0)
    bad_i32("\u0663", ParseErrorKind::InvalidChar, 0)
    bad_i32("1\u0663", ParseErrorKind::Trailing, 1)
    // Out of range and also followed by a byte: Trailing, at that byte.
    bad_i8("128x", ParseErrorKind::Trailing, 3)
    bad_u64("18446744073709551616 ", ParseErrorKind::Trailing, 20)
    bad_i32("-2147483649x", ParseErrorKind::Trailing, 11)
}

fn kind_of(const s: string) -> ParseErrorKind {
    try {
        var r = s.parse<i32>()
        return ParseErrorKind::None
    } catch e: ParseError {
        return e.kind
    }
}

fn at_of(const s: string) -> u32 {
    try {
        var r = s.parse<u8>()
        return 9999
    } catch e: ParseError {
        return e.at
    }
}

fn parse_method() panic(ParseError) {
    var a = "42".parse<i32>()
    var b = "-17".parse<i64>()
    var c = "255".parse<u8>()
    var d = "18446744073709551615".parse<u64>()
    var e = "+0".parse<isize>()
    var f = "-9223372036854775808".parse<isize>()
    NO += 1
    if a != 42 || b != -17 || c != 255 || d != 18446744073709551615 || e != 0 || f != -9223372036854775807 - 1 {
        fail("parse<T> of in-range values")
    }

    NO += 1
    if kind_of("") != ParseErrorKind::Empty || kind_of("2147483648") != ParseErrorKind::Overflow || kind_of("1a") != ParseErrorKind::Trailing || kind_of("a") != ParseErrorKind::InvalidChar {
        fail("parse<i32> error kinds")
    }

    NO += 1
    if at_of("256") != 2 || at_of("-5") != 0 || at_of("25x") != 2 || at_of("") != 0 {
        fail("parse<u8> error offsets")
    }
}

fn main() -> i32 {
    limits_and_zeros()
    rust_invalid_inputs()
    try {
        parse_method()
    } catch e: ParseError {
        NO += 1
        fail("parse_method panicked")
    }

    if CODE == 0 {
        io::println(f"ok {NO} cases")
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: ok {{[0-9]+}} cases
