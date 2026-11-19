// char <-> UTF-8 and bool from text: every scalar value encodes to the
// bytes a bit-by-bit reference gives and decodes back; every malformed
// first sequence, every ParseErrorKind and its offset.

import std::io::*
import self::inputs::numtext_support::*

var case_no: i32 = 0

fn expect_char(text: [const u8;], kind: ParseErrorKind, at: u32) {
    case_no += 1
    var unsafe *p = bytes_of(text)
    var err = ParseError { at: 99, kind: ParseErrorKind::Overflow }
    var c: u32 = parse_char(p, text.size(), &err)
    if err.kind != kind || err.at != at || c != 0 {
        fail(case_no, f"parse_char('{show(p, text.size())}') gave U+{c:04x} kind {err.kind as u8} at {err.at}, want kind {kind as u8} at {at}")
    }
}

fn value_char(text: [const u8;], want: u32) {
    case_no += 1
    var unsafe *p = bytes_of(text)
    var err = ParseError { at: 99, kind: ParseErrorKind::Overflow }
    var c: u32 = parse_char(p, text.size(), &err)
    if err.kind != ParseErrorKind::None || err.at != 0 || c != want {
        fail(case_no, f"parse_char('{show(p, text.size())}') gave U+{c:04x} kind {err.kind as u8}, want U+{want:04x}")
    }
}

fn expect_bool(text: [const u8;], kind: ParseErrorKind, at: u32, want: bool) {
    case_no += 1
    var unsafe *p = bytes_of(text)
    var err = ParseError { at: 99, kind: ParseErrorKind::Overflow }
    var v = parse_bool(p, text.size(), &err)
    if err.kind != kind || err.at != at || v != want {
        fail(case_no, f"parse_bool('{show(p, text.size())}') gave {v} kind {err.kind as u8} at {err.at}, want {want} kind {kind as u8} at {at}")
    }
}

fn main() -> i32 {
    const None        = ParseErrorKind::None
    const Empty       = ParseErrorKind::Empty
    const InvalidChar = ParseErrorKind::InvalidChar
    const Trailing    = ParseErrorKind::Trailing

    // Case 1: every scalar value.
    var buf: [u8; 8]
    var unsafe *b = unsafe &buf[0]
    var err = ParseError { at: 0, kind: ParseErrorKind::None }
    for var v: u32 = 0; v <= 0x10FFFF; ++v {
        if v >= 0xD800 && v <= 0xDFFF {
            continue
        }

        // The reference: UTF-8 as the standard's table states it.
        var want: [u8; 4]
        var wn: usize = 0
        if v < 0x80 {
            want[0] = v as u8
            wn = 1
        } else if v < 0x800 {
            want[0] = (192 + v / 64) as u8
            want[1] = (128 + v % 64) as u8
            wn = 2
        } else if v < 0x10000 {
            want[0] = (224 + v / 4096) as u8
            want[1] = (128 + (v / 64) % 64) as u8
            want[2] = (128 + v % 64) as u8
            wn = 3
        } else {
            want[0] = (240 + v / 262144) as u8
            want[1] = (128 + (v / 4096) % 64) as u8
            want[2] = (128 + (v / 64) % 64) as u8
            want[3] = (128 + v % 64) as u8
            wn = 4
        }

        var n  = char_to_utf8(v, b)
        var ok = n == wn
        for var i: usize = 0; ok && i < n; ++i {
            ok = buf[i] == want[i]
        }

        var back: u32 = parse_char(b, n, &err)
        if !ok || back != v || err.kind != ParseErrorKind::None {
            fail(1, f"U+{v:04x} encoded as '{show(b, n)}', decoded as U+{back:04x} kind {err.kind as u8}")
            break
        }

        // One byte short is malformed; one byte more is trailing.
        if n > 1 {
            parse_char(b, n - 1, &err)
            if err.kind != ParseErrorKind::InvalidChar || err.at != 0 {
                fail(1, f"U+{v:04x} cut short gave kind {err.kind as u8} at {err.at}")
                break
            }
        }

        buf[n] = 65
        parse_char(b, n + 1, &err)
        if err.kind != ParseErrorKind::Trailing || err.at != (n as u32) {
            fail(1, f"U+{v:04x} plus a byte gave kind {err.kind as u8} at {err.at}")
            break
        }
    }

    // Case 2: every first byte that cannot start a sequence, alone and
    // followed by continuation bytes.
    for var lead: u32 = 0x80; lead <= 0xFF; ++lead {
        if (lead >= 0xC2 && lead <= 0xF4) {
            continue
        }

        buf[0] = lead as u8
        buf[1] = 0x80
        buf[2] = 0x80
        buf[3] = 0x80
        for var n: usize = 1; n <= 4; ++n {
            var c: u32 = parse_char(b, n, &err)
            if err.kind != ParseErrorKind::InvalidChar || err.at != 0 || c != 0 {
                fail(2, f"lead byte {lead:#x} with {n} bytes gave kind {err.kind as u8} at {err.at}")
            }
        }
    }

    case_no = 2
    expect_char(b"", Empty, 0)
    // Not shortest form.
    expect_char(b"\xc0\x80", InvalidChar, 0)
    expect_char(b"\xc1\xbf", InvalidChar, 0)
    expect_char(b"\xe0\x80\x80", InvalidChar, 0)
    expect_char(b"\xe0\x9f\xbf", InvalidChar, 0)
    expect_char(b"\xf0\x80\x80\x80", InvalidChar, 0)
    expect_char(b"\xf0\x8f\xbf\xbf", InvalidChar, 0)
    // Surrogates.
    expect_char(b"\xed\xa0\x80", InvalidChar, 0)
    expect_char(b"\xed\xbf\xbf", InvalidChar, 0)
    // Above U+10FFFF.
    expect_char(b"\xf4\x90\x80\x80", InvalidChar, 0)
    expect_char(b"\xf5\x80\x80\x80", InvalidChar, 0)
    expect_char(b"\xf8\x88\x80\x80\x80", InvalidChar, 0)
    // A continuation byte that is not one.
    expect_char(b"\xc3\x28", InvalidChar, 0)
    expect_char(b"\xc3\xc3", InvalidChar, 0)
    expect_char(b"\xe2\x28\xa1", InvalidChar, 0)
    expect_char(b"\xe2\x82\x28", InvalidChar, 0)
    expect_char(b"\xf0\x9f\x98\x28", InvalidChar, 0)
    expect_char(b"\xf0\x28\x98\x80", InvalidChar, 0)
    // Cut short.
    expect_char(b"\xc3", InvalidChar, 0)
    expect_char(b"\xe2\x82", InvalidChar, 0)
    expect_char(b"\xf0\x9f\x98", InvalidChar, 0)
    // A lone continuation byte.
    expect_char(b"\x80", InvalidChar, 0)
    expect_char(b"\xbf", InvalidChar, 0)
    // More than one scalar value.
    expect_char(b"ab", Trailing, 1)
    expect_char(b"a\x00", Trailing, 1)
    expect_char(b"\xc3\xa9x", Trailing, 2)
    expect_char(b"\xe2\x82\xac\xe2\x82\xac", Trailing, 3)
    expect_char(b"\xf0\x9f\x98\x80\x80", Trailing, 4)
    expect_char(b"a\xff", Trailing, 1)
    // The boundaries of each length.
    value_char(b"\x00", 0)
    value_char(b"A", 65)
    value_char(b"\x7f", 0x7F)
    value_char(b"\xc2\x80", 0x80)
    value_char(b"\xdf\xbf", 0x7FF)
    value_char(b"\xe0\xa0\x80", 0x800)
    value_char(b"\xed\x9f\xbf", 0xD7FF)
    value_char(b"\xee\x80\x80", 0xE000)
    value_char(b"\xef\xbf\xbf", 0xFFFF)
    value_char(b"\xf0\x90\x80\x80", 0x10000)
    value_char(b"\xf4\x8f\xbf\xbf", 0x10FFFF)

    // bool.
    expect_bool(b"true", None, 0, true)
    expect_bool(b"false", None, 0, false)
    expect_bool(b"", Empty, 0, false)
    expect_bool(b"t", InvalidChar, 0, false)
    expect_bool(b"tru", InvalidChar, 0, false)
    expect_bool(b"fals", InvalidChar, 0, false)
    expect_bool(b"True", InvalidChar, 0, false)
    expect_bool(b"TRUE", InvalidChar, 0, false)
    expect_bool(b"False", InvalidChar, 0, false)
    expect_bool(b"1", InvalidChar, 0, false)
    expect_bool(b"0", InvalidChar, 0, false)
    expect_bool(b"yes", InvalidChar, 0, false)
    expect_bool(b" true", InvalidChar, 0, false)
    expect_bool(b"trux", InvalidChar, 0, false)
    expect_bool(b"falsy", InvalidChar, 0, false)
    expect_bool(b"true ", Trailing, 4, false)
    expect_bool(b"truee", Trailing, 4, false)
    expect_bool(b"true\x00", Trailing, 4, false)
    expect_bool(b"false ", Trailing, 5, false)
    expect_bool(b"falsetrue", Trailing, 5, false)
    expect_bool(b"truefalse", Trailing, 4, false)

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
