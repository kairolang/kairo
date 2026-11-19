// Text to float: every ParseErrorKind with the offset it reports, and the
// forms that are accepted.
//
// The rules under test:
//   - empty text is Empty at 0; a sign with nothing after it is InvalidChar
//     at 0;
//   - a byte that cannot start a number is InvalidChar at that byte, and so
//     is a '.' with no digit on either side;
//   - the number is the longest prefix that is one; bytes after it are
//     Trailing at the first of them (an 'e' with no exponent digits is such
//     a byte), whether or not the number is in range;
//   - a finite number that rounds to infinity is Overflow at the first byte
//     after the sign; one that rounds to zero is zero.

import std::io::*
import self::inputs::numtext_support::*

var case_no: i32 = 0

/// Both types, both parsers.
fn expect(text: [const u8;], kind: ParseErrorKind, at: u32) {
    case_no += 1
    var unsafe *p = bytes_of(text)
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_f64(p, text.size(), &err)
    if err.kind != kind || err.at != at {
        fail(case_no, f"parse_f64('{show(p, text.size())}') gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }

    err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_f64_exact(p, text.size(), &err)
    if err.kind != kind || err.at != at {
        fail(case_no, f"parse_f64_exact('{show(p, text.size())}') gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }

    err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_f32(p, text.size(), &err)
    if err.kind != kind || err.at != at {
        fail(case_no, f"parse_f32('{show(p, text.size())}') gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }

    err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_f32_exact(p, text.size(), &err)
    if err.kind != kind || err.at != at {
        fail(case_no, f"parse_f32_exact('{show(p, text.size())}') gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn expect64(text: [const u8;], kind: ParseErrorKind, at: u32) {
    case_no += 1
    var unsafe *p = bytes_of(text)
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_f64(p, text.size(), &err)
    if err.kind != kind || err.at != at {
        fail(case_no, f"parse_f64('{show(p, text.size())}') gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn expect32(text: [const u8;], kind: ParseErrorKind, at: u32) {
    case_no += 1
    var unsafe *p = bytes_of(text)
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    parse_f32(p, text.size(), &err)
    if err.kind != kind || err.at != at {
        fail(case_no, f"parse_f32('{show(p, text.size())}') gave kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

/// The exact bits of an accepted text, in both types.
fn value(text: [const u8;], want64: u64, want32: u32) {
    case_no += 1
    var unsafe *p = bytes_of(text)
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var g = parse_f64(p, text.size(), &err).to_bits()
    if err.kind != ParseErrorKind::None || err.at != 0 || g != want64 {
        fail(case_no, f"parse_f64('{show(p, text.size())}') gave {g:#x} kind {err.kind as u8}, want {want64:#x}")
    }

    err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var h = parse_f32(p, text.size(), &err).to_bits()
    if err.kind != ParseErrorKind::None || err.at != 0 || h != want32 {
        fail(case_no, f"parse_f32('{show(p, text.size())}') gave {h:#x} kind {err.kind as u8}, want {want32:#x}")
    }
}

/// What a value prints as.
fn prints(bits: u64, want: [const u8;]) {
    case_no += 1
    var buf: [u8; 32]
    var unsafe *b = unsafe &buf[0]
    var n = f64_to_text(__builtin_bitcast<f64, u64>(bits), b)
    var ok = n == want.size()
    for var i: usize = 0; ok && i < n; ++i {
        ok = buf[i] == want[i]
    }

    if !ok {
        fail(case_no, f"f64 {bits:#x} printed '{show(b, n)}', want '{show(bytes_of(want), want.size())}'")
    }
}

fn prints32(bits: u32, want: [const u8;]) {
    case_no += 1
    var buf: [u8; 32]
    var unsafe *b = unsafe &buf[0]
    var n = f32_to_text(__builtin_bitcast<f32, u32>(bits), b)
    var ok = n == want.size()
    for var i: usize = 0; ok && i < n; ++i {
        ok = buf[i] == want[i]
    }

    if !ok {
        fail(case_no, f"f32 {bits:#x} printed '{show(b, n)}', want '{show(bytes_of(want), want.size())}'")
    }
}

fn main() -> i32 {
    const None        = ParseErrorKind::None
    const Empty       = ParseErrorKind::Empty
    const InvalidChar = ParseErrorKind::InvalidChar
    const Overflow    = ParseErrorKind::Overflow
    const Trailing    = ParseErrorKind::Trailing

    // Empty.
    expect(b"", Empty, 0)

    // InvalidChar.
    expect(b"+", InvalidChar, 0)
    expect(b"-", InvalidChar, 0)
    expect(b".", InvalidChar, 0)
    expect(b"-.", InvalidChar, 1)
    expect(b"+.", InvalidChar, 1)
    expect(b".e5", InvalidChar, 0)
    expect(b"e5", InvalidChar, 0)
    expect(b"E5", InvalidChar, 0)
    expect(b"x", InvalidChar, 0)
    expect(b" 1", InvalidChar, 0)
    expect(b"--1", InvalidChar, 1)
    expect(b"+-1", InvalidChar, 1)
    expect(b"- 1", InvalidChar, 1)
    expect(b"in", InvalidChar, 0)
    expect(b"na", InvalidChar, 0)
    expect(b"-i", InvalidChar, 1)
    expect(b"-nan(", Trailing, 4)
    expect(b"\x00", InvalidChar, 0)
    expect(b"/", InvalidChar, 0)
    expect(b":", InvalidChar, 0)
    expect(b"$1", InvalidChar, 0)

    // Trailing.
    expect(b"1 ", Trailing, 1)
    expect(b"1x", Trailing, 1)
    expect(b"1e", Trailing, 1)
    expect(b"1E", Trailing, 1)
    expect(b"1e+", Trailing, 1)
    expect(b"1e-", Trailing, 1)
    expect(b"1ex", Trailing, 1)
    expect(b"1e+x", Trailing, 1)
    expect(b"1.5e", Trailing, 3)
    expect(b"1.e", Trailing, 2)
    expect(b"1..", Trailing, 2)
    expect(b"1.2.3", Trailing, 3)
    expect(b"1e5.", Trailing, 3)
    expect(b"1e5e5", Trailing, 3)
    expect(b"1e5 ", Trailing, 3)
    expect(b"1_000", Trailing, 1)
    expect(b"0x10", Trailing, 1)
    expect(b"1f", Trailing, 1)
    expect(b"1.0f32", Trailing, 3)
    expect(b"1-", Trailing, 1)
    expect(b"1+1", Trailing, 1)
    expect(b"-1.5e-3x", Trailing, 7)
    expect(b"infx", Trailing, 3)
    expect(b"infi", Trailing, 3)
    expect(b"infinit", Trailing, 3)
    expect(b"infinityx", Trailing, 8)
    expect(b"-infinity ", Trailing, 9)
    expect(b"nanx", Trailing, 3)
    expect(b"nan(0)", Trailing, 3)
    expect(b"+nan1", Trailing, 4)
    expect(b"1\x00", Trailing, 1)
    // Reported even when the number is out of range.
    expect(b"1e999x", Trailing, 5)
    expect(b"-1e999 ", Trailing, 6)

    // Overflow.
    expect(b"1e999", Overflow, 0)
    expect(b"-1e999", Overflow, 1)
    expect(b"+1e999", Overflow, 1)
    expect(b"1e99999999999999999999999999", Overflow, 0)
    expect64(b"1.7976931348623159e308", Overflow, 0)
    expect64(b"1e309", Overflow, 0)
    expect64(b"-0.00001e315", Overflow, 1)
    expect32(b"3.5e38", Overflow, 0)
    expect32(b"1e39", Overflow, 0)
    expect32(b"-340282356779733661637539395458142568448", Overflow, 1)
    expect64(b"1e39", None, 0)

    // None: the accepted forms.
    value(b"0", 0, 0)
    value(b"-0", 0x8000000000000000, 0x80000000)
    value(b"+0", 0, 0)
    value(b"0.0", 0, 0)
    value(b".0", 0, 0)
    value(b"0.", 0, 0)
    value(b"-0e0", 0x8000000000000000, 0x80000000)
    value(b"0e999999999999999999999", 0, 0)
    value(b"1", 0x3FF0000000000000, 0x3F800000)
    value(b"+1", 0x3FF0000000000000, 0x3F800000)
    value(b"1.", 0x3FF0000000000000, 0x3F800000)
    value(b"1.0", 0x3FF0000000000000, 0x3F800000)
    value(b"01", 0x3FF0000000000000, 0x3F800000)
    value(b"1e0", 0x3FF0000000000000, 0x3F800000)
    value(b"1E0", 0x3FF0000000000000, 0x3F800000)
    value(b"1e+0", 0x3FF0000000000000, 0x3F800000)
    value(b"1e-0", 0x3FF0000000000000, 0x3F800000)
    value(b"10e-1", 0x3FF0000000000000, 0x3F800000)
    value(b"0.1e1", 0x3FF0000000000000, 0x3F800000)
    value(b".1e1", 0x3FF0000000000000, 0x3F800000)
    value(b"1.e0", 0x3FF0000000000000, 0x3F800000)
    value(b"-1.5", 0xBFF8000000000000, 0xBFC00000)
    value(b".5", 0x3FE0000000000000, 0x3F000000)
    value(b"-.5", 0xBFE0000000000000, 0xBF000000)
    value(b"5.e-1", 0x3FE0000000000000, 0x3F000000)
    value(b"1e-999", 0, 0)                      // rounds to zero
    value(b"-1e-999", 0x8000000000000000, 0x80000000)
    value(b"1e-99999999999999999999999999", 0, 0)
    value(b"inf", 0x7FF0000000000000, 0x7F800000)
    value(b"+inf", 0x7FF0000000000000, 0x7F800000)
    value(b"-inf", 0xFFF0000000000000, 0xFF800000)
    value(b"INF", 0x7FF0000000000000, 0x7F800000)
    value(b"Inf", 0x7FF0000000000000, 0x7F800000)
    value(b"infinity", 0x7FF0000000000000, 0x7F800000)
    value(b"-Infinity", 0xFFF0000000000000, 0xFF800000)
    value(b"INFINITY", 0x7FF0000000000000, 0x7F800000)
    value(b"nan", 0x7FF8000000000000, 0x7FC00000)
    value(b"NaN", 0x7FF8000000000000, 0x7FC00000)
    value(b"NAN", 0x7FF8000000000000, 0x7FC00000)
    value(b"+nan", 0x7FF8000000000000, 0x7FC00000)
    value(b"-nan", 0xFFF8000000000000, 0xFFC00000)

    // The layout.
    prints(0x0000000000000000, b"0")
    prints(0x8000000000000000, b"-0")
    prints(0x7FF0000000000000, b"inf")
    prints(0xFFF0000000000000, b"-inf")
    prints(0x7FF8000000000000, b"nan")
    prints(0xFFF8000000000000, b"nan")          // a NaN's sign is not printed
    prints(0x7FF0000000000001, b"nan")
    prints(0xFFFFFFFFFFFFFFFF, b"nan")
    prints(0x3FF0000000000000, b"1")
    prints(0xBFF8000000000000, b"-1.5")
    prints(0x4059000000000000, b"100")
    prints(0x3FB999999999999A, b"0.1")
    prints(0x3F1A36E2EB1C432D, b"0.0001")       // exponent -4: the last plain one
    prints(0x3EE4F8B588E368F1, b"1e-05")
    prints(0x3EE92A737110E454, b"1.2e-05")
    prints(0x4341C37937E08000, b"10000000000000000")    // 1e16: the last plain one
    prints(0x436FFFFFFFFFFFFF, b"72057594037927930")
    prints(0x4376345785D8A000, b"1e+17")
    prints(0x4415AF1D78B58C40, b"1e+20")
    prints(0x40FE240C9FCB68CD, b"123456.78901234567")
    prints(0x7FEFFFFFFFFFFFFF, b"1.7976931348623157e+308")
    prints(0x0000000000000001, b"5e-324")
    prints(0x8010000000000000, b"-2.2250738585072014e-308")
    prints(0x7E37E43C8800759C, b"1e+300")
    prints(0x01A56E1FC2F8F359, b"1e-300")
    prints32(0x00000000, b"0")
    prints32(0x80000000, b"-0")
    prints32(0x7F800000, b"inf")
    prints32(0xFF800000, b"-inf")
    prints32(0xFFC00000, b"nan")
    prints32(0x3F800000, b"1")
    prints32(0x3DCCCCCD, b"0.1")
    prints32(0x4CBEBC20, b"100000000")          // 1e8: the last plain one
    prints32(0x4E6E6B28, b"1e+09")
    prints32(0x38D1B717, b"0.0001")
    prints32(0x3727C5AC, b"1e-05")
    prints32(0x7F7FFFFF, b"3.4028235e+38")
    prints32(0x00000001, b"1e-45")
    prints32(0x80800000, b"-1.1754944e-38")
    prints32(0x4B800000, b"16777216")

    if first_failure == 0 {
        println("ok")
    }

    return first_failure
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
