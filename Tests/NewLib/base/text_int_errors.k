// Text to integer: every ParseErrorKind, with the offset it reports, and
// the forms that are accepted.
//
// The rules under test:
//   - empty text is Empty at 0;
//   - a sign with nothing after it is InvalidChar at 0;
//   - a byte that is not a digit where the first digit belongs is
//     InvalidChar at that byte ('-' is one for an unsigned type);
//   - bytes after the digits are Trailing at the first of them, whether or
//     not the digits are in range;
//   - digits out of range are Overflow at the digit that first takes the
//     value past the limit.

import std::io::*
import self::Inputs::numtext_support::*

var case_no: i32 = 0

fn expect(got_kind: ParseErrorKind, got_at: u32, kind: ParseErrorKind, at: u32, const what: string, text: [const u8;]) {
    case_no += 1
    if got_kind != kind || got_at != at {
        fail(case_no, f"{what}('{show(bytes_of(text), text.size())}') gave kind {got_kind as u8} at {got_at}, want kind {kind as u8} at {at}")
    }
}

fn e_u8(text: [const u8;], kind: ParseErrorKind, at: u32) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_u8(bytes_of(text), text.size(), &err)
    expect(err.kind, err.at, kind, at, "parse_u8", text)
}

fn e_i8(text: [const u8;], kind: ParseErrorKind, at: u32) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_i8(bytes_of(text), text.size(), &err)
    expect(err.kind, err.at, kind, at, "parse_i8", text)
}

fn e_u32(text: [const u8;], kind: ParseErrorKind, at: u32) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_u32(bytes_of(text), text.size(), &err)
    expect(err.kind, err.at, kind, at, "parse_u32", text)
}

fn e_i32(text: [const u8;], kind: ParseErrorKind, at: u32) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_i32(bytes_of(text), text.size(), &err)
    expect(err.kind, err.at, kind, at, "parse_i32", text)
}

fn e_u64(text: [const u8;], kind: ParseErrorKind, at: u32) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_u64(bytes_of(text), text.size(), &err)
    expect(err.kind, err.at, kind, at, "parse_u64", text)
}

fn e_i64(text: [const u8;], kind: ParseErrorKind, at: u32) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_i64(bytes_of(text), text.size(), &err)
    expect(err.kind, err.at, kind, at, "parse_i64", text)
}



/// A case every type must answer alike.
fn e_all(text: [const u8;], kind: ParseErrorKind, at: u32) {
    e_u8(text, kind, at)
    e_i8(text, kind, at)
    e_u32(text, kind, at)
    e_i32(text, kind, at)
    e_u64(text, kind, at)
    e_i64(text, kind, at)
}

fn v_u64(text: [const u8;], want: u64) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var got = parse_u64(bytes_of(text), text.size(), &err)
    case_no += 1
    if got != want || err.kind != ParseErrorKind::None || err.at != 0 {
        fail(case_no, f"parse_u64('{show(bytes_of(text), text.size())}') gave {got} kind {err.kind as u8}, want {want}")
    }
}

fn v_i64(text: [const u8;], want: i64) {
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var got = parse_i64(bytes_of(text), text.size(), &err)
    case_no += 1
    if got != want || err.kind != ParseErrorKind::None || err.at != 0 {
        fail(case_no, f"parse_i64('{show(bytes_of(text), text.size())}') gave {got} kind {err.kind as u8}, want {want}")
    }
}

fn main() -> i32 {
    const None        = ParseErrorKind::None
    const Empty       = ParseErrorKind::Empty
    const InvalidChar = ParseErrorKind::InvalidChar
    const Overflow    = ParseErrorKind::Overflow
    const Trailing    = ParseErrorKind::Trailing

    // Empty.
    e_all(b"", Empty, 0)

    // InvalidChar: nothing that starts a number.
    e_all(b"+", InvalidChar, 0)
    e_all(b"x", InvalidChar, 0)
    e_all(b" 1", InvalidChar, 0)
    e_all(b".5", InvalidChar, 0)
    e_all(b"+x", InvalidChar, 1)
    e_all(b"+-1", InvalidChar, 1)
    e_all(b"++1", InvalidChar, 1)
    e_all(b"\x001", InvalidChar, 0)
    e_all(b"/", InvalidChar, 0)             // the byte below '0'
    e_all(b":", InvalidChar, 0)             // the byte above '9'
    e_i8(b"-", InvalidChar, 0)
    e_i32(b"-", InvalidChar, 0)
    e_i64(b"-", InvalidChar, 0)
    e_i64(b"-x", InvalidChar, 1)
    e_i64(b"--1", InvalidChar, 1)
    e_i64(b"-+1", InvalidChar, 1)
    // An unsigned type takes no '-', not even for zero.
    e_u8(b"-", InvalidChar, 0)
    e_u8(b"-0", InvalidChar, 0)
    e_u32(b"-1", InvalidChar, 0)
    e_u64(b"-1", InvalidChar, 0)

    // Trailing.
    e_all(b"1 ", Trailing, 1)
    e_all(b"12x", Trailing, 2)
    e_all(b"0x10", Trailing, 1)
    e_all(b"1.0", Trailing, 1)
    e_all(b"1e3", Trailing, 1)
    e_all(b"1_000", Trailing, 1)
    e_all(b"+7+", Trailing, 2)
    e_all(b"7\x00", Trailing, 1)
    e_all(b"1-", Trailing, 1)
    e_i64(b"-12-", Trailing, 3)
    // Trailing bytes are reported even when the digits are out of range,
    // and beyond the unchecked fast path.
    e_u8(b"999x", Trailing, 3)
    e_i8(b"-129 ", Trailing, 4)
    e_u64(b"123456789012345678x", Trailing, 18)
    e_u64(b"1234567890123456789x", Trailing, 19)
    e_u64(b"99999999999999999999999x", Trailing, 23)
    e_i64(b"-99999999999999999999999x", Trailing, 24)

    // Overflow: at the digit that first exceeds the limit.
    e_u8(b"256", Overflow, 2)
    e_u8(b"1000", Overflow, 3)
    e_u8(b"300", Overflow, 2)
    e_u8(b"+256", Overflow, 3)
    e_u8(b"0000256", Overflow, 6)
    e_u8(b"99999999999999999999999999", Overflow, 2)
    e_i8(b"128", Overflow, 2)
    e_i8(b"-129", Overflow, 3)
    e_i8(b"-1000", Overflow, 4)
    e_u32(b"4294967296", Overflow, 9)
    e_u32(b"42949672950", Overflow, 10)
    e_i32(b"2147483648", Overflow, 9)
    e_i32(b"-2147483649", Overflow, 10)
    e_u64(b"18446744073709551616", Overflow, 19)
    e_u64(b"18446744073709551620", Overflow, 19)
    e_u64(b"28446744073709551615", Overflow, 19)
    e_u64(b"184467440737095516150", Overflow, 20)
    e_u64(b"000018446744073709551616", Overflow, 23)
    e_i64(b"9223372036854775808", Overflow, 18)
    e_i64(b"-9223372036854775809", Overflow, 19)
    e_i64(b"+9223372036854775808", Overflow, 19)

    // None: the accepted forms and the limits.
    e_all(b"0", None, 0)
    e_all(b"+0", None, 0)
    e_all(b"7", None, 0)
    e_all(b"+127", None, 0)
    e_all(b"000000000000000000000000000000000000000000000000000000000127", None, 0)
    e_i8(b"-0", None, 0)
    e_i8(b"-128", None, 0)
    e_u8(b"255", None, 0)
    e_i32(b"-2147483648", None, 0)
    e_u32(b"4294967295", None, 0)
    v_u64(b"18446744073709551615", 18446744073709551615)
    v_u64(b"+18446744073709551615", 18446744073709551615)
    v_u64(b"00000000000000000000000000018446744073709551615", 18446744073709551615)
    v_u64(b"999999999999999999", 999999999999999999)        // 18 digits: the unchecked path alone
    v_u64(b"1000000000000000000", 1000000000000000000)      // 19: one checked step
    v_u64(b"00", 0)
    v_i64(b"-9223372036854775808", -9223372036854775807 - 1)
    v_i64(b"9223372036854775807", 9223372036854775807)
    v_i64(b"-0", 0)
    v_i64(b"-00000000000000000000000000000000000001", -1)

    if first_failure == 0 {
        println("ok")
    }

    return first_failure
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
