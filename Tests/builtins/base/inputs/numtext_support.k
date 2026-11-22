/// The number-text tests' support: a seeded generator, byte-string access,
/// failure reporting, and the conversions under test spelled as functions on
/// byte buffers. Each of those goes through the public members only
/// (`append_to`, `op as string`, `from_str`, `parse`), so the tests
/// exercise exactly what a program calls. A test's exit status is 0 or the
/// number of its first failing case (capped at 250).

import std::io::*

static NO_BYTES: [u8; 1] = [0]

/// The first failing case, 0 while every case passes.
pub var first_failure: i32 = 0

/// The bytes of `s`; valid even when `s` is empty.
pub fn bytes_of(s: [const u8;]) -> unsafe *const u8 {
    if s.size() == 0 {
        return unsafe &NO_BYTES[0]
    }

    return unsafe &s[0]
}

/// `p[0 .. n)` as printable text: bytes outside 0x20..0x7E as `\xNN`.
pub fn show(p: unsafe *const u8, n: usize) -> string {
    var s = ""
    for var i: usize = 0; i < n; ++i {
        var b = p[i]
        if b >= 32 && b < 127 {
            s = f"{s}{b as char}"
        } else {
            s = f"{s}\\x{b:02x}"
        }
    }

    return s
}

/// Records a failure of case `no` and prints what was being checked.
pub fn fail(no: i32, const what: string) {
    if first_failure == 0 {
        first_failure = if no > 250 => 250 else => (if no < 1 => 1 else => no)
    }

    println(f"FAIL case {no}: {what}")
}

/// xorshift64*: the same sequence on every target.
pub struct Rng {
    pub var s: u64
}

pub fn rng_next(r: *Rng) -> u64 {
    var x = r->s
    x = x ^ (x >> 12)
    x = x ^ (x << 25)
    x = x ^ (x >> 27)
    r->s = x
    return x * 0x2545F4914F6CDD1D
}

/// A value below `bound` (nonzero).
pub fn rng_below(r: *Rng, bound: u64) -> u64 {
    return rng_next(r) % bound
}

pub eval U8_TEXT_MAX:  usize = 3
pub eval U16_TEXT_MAX: usize = 5
pub eval U32_TEXT_MAX: usize = 10
pub eval U64_TEXT_MAX: usize = 20
pub eval I8_TEXT_MAX:  usize = 4
pub eval I16_TEXT_MAX: usize = 6
pub eval I32_TEXT_MAX: usize = 11
pub eval I64_TEXT_MAX: usize = 20
pub eval F64_TEXT_MAX: usize = 24
pub eval F32_TEXT_MAX: usize = 15

/// The text occupies `buf[start .. start + len)`.
pub struct TextRange {
    pub var start: usize
    pub var len:   usize
}

/// Copies the bytes of `s` to `buf[at ..)`.
fn put(const s: string, buf: unsafe *u8, at: usize) {
    var d = s.data()
    for var i: usize = 0; i < s.size(); ++i {
        unsafe { buf[at + i] = d[i] }
    }
}

/// The text `append_to` writes for a value, checked against `op as string`.
fn text_check(const a: string, const b: string) {
    var same = a.size() == b.size()
    if same {
        var x = a.data()
        var y = b.data()
        for var i: usize = 0; i < a.size(); ++i {
            if x[i] != y[i] { same = false }
        }
    }
    if !same { fail(0, f"append_to wrote '{a}' but op as gave '{b}'") }
}

/// `p[0 .. n)` as a borrowed string, whatever the bytes are. The cases feed
/// the parsers bytes that are not UTF-8, which no constructor of `string`
/// accepts, so the view is written by layout: the pointer word, then the
/// byte count above the three flag bits (all clear: a view, not known ASCII).
/// The parsers read only the first n bytes.
fn text(p: unsafe *const u8, n: usize) -> string {
    var s = string()
    unsafe {
        var unsafe *w = &s as unsafe *string as unsafe *usize
        w[0] = p as usize
        w[1] = n << 3
    }

    return s
}

/// `T::from_str(t)`, with `err` set to the reason `t.parse<T>()` raises
/// (kind None at 0 when it accepts): the two forms of the public parser,
/// whose agreement each case's checks of value and kind together hold.
fn <T impl FromStr> parse_reported(const t: string, @inout err: ParseError) -> T? {
    var r = T::from_str(t)
    try {
        var v = t.parse<T>()
        err = ParseError { at: 0, kind: ParseErrorKind::None }
    } catch e: ParseError {
        err = e
    }

    return r
}

pub fn u8_to_text(v: u8, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_u8(p: unsafe *const u8, n: usize, @inout err: ParseError) -> u8 {
    return parse_reported<u8>(text(p, n), &err) ?? 0
}

pub fn u16_to_text(v: u16, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_u16(p: unsafe *const u8, n: usize, @inout err: ParseError) -> u16 {
    return parse_reported<u16>(text(p, n), &err) ?? 0
}

pub fn u32_to_text(v: u32, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_u32(p: unsafe *const u8, n: usize, @inout err: ParseError) -> u32 {
    return parse_reported<u32>(text(p, n), &err) ?? 0
}

pub fn u64_to_text(v: u64, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_u64(p: unsafe *const u8, n: usize, @inout err: ParseError) -> u64 {
    return parse_reported<u64>(text(p, n), &err) ?? 0
}

pub fn i8_to_text(v: i8, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_i8(p: unsafe *const u8, n: usize, @inout err: ParseError) -> i8 {
    return parse_reported<i8>(text(p, n), &err) ?? 0
}

pub fn i16_to_text(v: i16, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_i16(p: unsafe *const u8, n: usize, @inout err: ParseError) -> i16 {
    return parse_reported<i16>(text(p, n), &err) ?? 0
}

pub fn i32_to_text(v: i32, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_i32(p: unsafe *const u8, n: usize, @inout err: ParseError) -> i32 {
    return parse_reported<i32>(text(p, n), &err) ?? 0
}

pub fn i64_to_text(v: i64, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_i64(p: unsafe *const u8, n: usize, @inout err: ParseError) -> i64 {
    return parse_reported<i64>(text(p, n), &err) ?? 0
}

pub fn usize_to_text(v: usize, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_usize(p: unsafe *const u8, n: usize, @inout err: ParseError) -> usize {
    return parse_reported<usize>(text(p, n), &err) ?? 0
}

pub fn isize_to_text(v: isize, buf: unsafe *u8, cap: usize) -> TextRange {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    var n = s.size()
    put(s, buf, cap - n)
    return TextRange { start: cap - n, len: n }
}

pub fn parse_isize(p: unsafe *const u8, n: usize, @inout err: ParseError) -> isize {
    return parse_reported<isize>(text(p, n), &err) ?? 0
}

pub fn f64_to_text(v: f64, buf: unsafe *u8) -> usize {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    put(s, buf, 0)
    return s.size()
}

pub fn parse_f64(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f64 {
    return parse_reported<f64>(text(p, n), &err) ?? 0.0
}

pub fn f32_to_text(v: f32, buf: unsafe *u8) -> usize {
    var s = string()
    v.append_to(&s)
    var t = v as string
    text_check(s, t)
    put(s, buf, 0)
    return s.size()
}

pub fn parse_f32(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f32 {
    return parse_reported<f32>(text(p, n), &err) ?? 0.0
}

pub fn char_to_utf8(c: char, buf: unsafe *u8) -> usize {
    var s = string()
    c.append_to(&s)
    var t = c as string
    text_check(s, t)
    put(s, buf, 0)
    return s.size()
}

pub fn parse_char(p: unsafe *const u8, n: usize, @inout err: ParseError) -> char {
    return parse_reported<char>(text(p, n), &err) ?? '\x00'
}

pub fn parse_bool(p: unsafe *const u8, n: usize, @inout err: ParseError) -> bool {
    return parse_reported<bool>(text(p, n), &err) ?? false
}

/// The public parser has one path; the tests' "exact" calls take it too.
pub fn parse_f64_exact(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f64 = parse_f64(p, n, &err)
pub fn parse_f32_exact(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f32 = parse_f32(p, n, &err)

/// `sig * 10^exp`, `sig` without trailing zeros.
pub struct FloatDecimal {
    pub var sig: u64
    pub var exp: i32
}

/// The digits and exponent of the text `append_to` writes for a finite,
/// nonzero value, so the differential test compares the printed digits.
fn decimal_of_text(const s: string) -> FloatDecimal {
    var d = s.data()
    var n = s.size()
    var sig: u64 = 0
    var exp: i32 = 0
    var after_point = false
    var i: usize = 0
    while i < n && d[i] != 101 {
        if d[i] == 46 {
            after_point = true
        } else if d[i] >= 48 && d[i] <= 57 {
            sig = sig * 10 + ((d[i] - 48) as u64)
            if after_point { exp -= 1 }
        }
        i += 1
    }
    if i < n {
        var neg = d[i + 1] == 45
        var e: i32 = 0
        for var j = i + 2; j < n; ++j { e = e * 10 + ((d[j] - 48) as i32) }
        exp += if neg => 0 - e else => e
    }
    while sig % 10 == 0 {
        sig = sig / 10
        exp += 1
    }
    return FloatDecimal { sig: sig, exp: exp }
}

pub fn f64_to_decimal(bits: u64) -> FloatDecimal {
    var s = string()
    __builtin_bitcast<f64, u64>(bits).append_to(&s)
    return decimal_of_text(s)
}

pub fn f32_to_decimal(bits: u32) -> FloatDecimal {
    var s = string()
    __builtin_bitcast<f32, u32>(bits).append_to(&s)
    return decimal_of_text(s)
}

/// Iterations of the big random loops: 10^6 in the suite; `-DNUMTEXT_FULL`
/// gives the 10^7 of a long run.
eval if defined!(NUMTEXT_FULL) {
    pub eval ROUNDS: i32 = 10000000
} else {
    pub eval ROUNDS: i32 = 1000000
}
