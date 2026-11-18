// Text to f64 and f32: the named groups of cases for ordinary, special-path, large, subnormal,
// zero and infinity-range values, the forms of infinity and NaN, a massive exponent, very long
// digit strings, signed zero and infinity through a print and parse round trip, and the
// panicking `string::parse`. The expected bit patterns come from exact rational arithmetic on
// the decimal text, rounded to nearest with ties to even.
//
// Where Kairo differs from Rust: a finite text that rounds to infinity is the error Overflow,
// not an infinity (documented on parse_f64: "A finite number too large for the type is
// `Overflow`"; one too small rounds to zero). The text "inf" is the way to get an infinity.
// A NaN's sign and payload are not asserted, only that it is a NaN.
// Cases from Rust library/coretests/tests/num/dec2flt/mod.rs (ordinary, special_code_paths, large,
// subnormals, infinity, zero, fast_path_correct, nan, inf, massive_exponent)
// Cases from Rust library/coretests/tests/num/dec2flt/parse.rs (issue31109, issue31407 and the long inputs)
// Cases from Rust library/coretests/tests/num/float_ieee754_flt2dec_dec2flt.rs (signed zero and infinity
// round trips, infinity_from_str, qnan_from_str)

import std::io

static const OVF32: u32 = 0xFFFFFFFF

static CODE: i32 = 0
static NO:   i32 = 0

fn fail(const what: string) {
    io::println(f"FAIL case {NO}: {what}")
    if CODE == 0 {
        CODE = if NO > 250 => 250 else => NO
    }
}

fn shown(const t: string) -> string {
    if t.size() > 60 {
        return f"{t[0..60]}...({t.size()} bytes)"
    }

    return t.copy()
}

/// The text must parse as an f64 with exactly these bits.
fn bits64(const t: string, want: u64) {
    NO += 1
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var r?  = f64::from_str(t, &err)
    if r? {
        if err.kind != ParseErrorKind::None || r.to_bits() != want {
            fail(f"f64 '{shown(t)}' gave {r.to_bits():#x}, want {want:#x}")
        }
    } else {
        fail(f"f64 '{shown(t)}' was rejected (kind {err.kind as u8}), want {want:#x}")
    }
}

/// The text must parse as an f32 with exactly these bits, or be Overflow when `want` is OVF32.
fn bits32(const t: string, want: u32) {
    NO += 1
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var r?  = f32::from_str(t, &err)
    if want == OVF32 {
        if r? || err.kind != ParseErrorKind::Overflow {
            fail(f"f32 '{shown(t)}' should be Overflow, got kind {err.kind as u8}")
        }
    } else if r? {
        if err.kind != ParseErrorKind::None || r.to_bits() != want {
            fail(f"f32 '{shown(t)}' gave {r.to_bits():#x}, want {want:#x}")
        }
    } else {
        fail(f"f32 '{shown(t)}' was rejected (kind {err.kind as u8}), want {want:#x}")
    }
}

/// Both types, the text as given, with a minus sign and with a plus sign.
fn both(const t: string, want64: u64, want32: u32) {
    bits64(t, want64)
    bits32(t, want32)
    var neg = f"-{t}"
    var pos = f"+{t}"
    bits64(neg, want64 | 0x8000000000000000)
    bits64(pos, want64)
    if want32 == OVF32 {
        bits32(neg, OVF32)
        bits32(pos, OVF32)
    } else {
        bits32(neg, want32 | 0x80000000)
        bits32(pos, want32)
    }
}

/// A literal in its source spelling and in the scientific spelling of its shortest digits.
fn lit(const t: string, const sci: string, want64: u64, want32: u32) {
    both(t, want64, want32)
    both(sci, want64, want32)
}

fn ordinary_special_large_subnormal_zero() {
    lit("1.0", "1e0", 0x3FF0000000000000, 0x3F800000)
    lit("3e-5", "3e-5", 0x3EFF75104D551D69, 0x37FBA882)
    lit("0.1", "1e-1", 0x3FB999999999999A, 0x3DCCCCCD)
    lit("12345.", "1.2345e4", 0x40C81C8000000000, 0x4640E400)
    lit("0.9999999", "9.999999e-1", 0x3FEFFFFFCA501ACB, 0x3F7FFFFE)
    lit("2.2250738585072014e-308", "2.2250738585072014e-308", 0x10000000000000, 0x0)
    lit("36893488147419103229.0", "3.6893488147419103e19", 0x4400000000000000, 0x60000000)
    lit("101e-33", "1.01e-31", 0x398063603878DCBE, 0xC031B02)
    lit("1e23", "1e23", 0x44B52D02C7E14AF6, 0x65A96816)
    lit("2075e23", "2.075e26", 0x4565747AB143E353, 0x6B2BA3D6)
    lit("8713e-23", "8.713e-20", 0x3BF9B75B4E7DE2B9, 0x1FCDBADA)
    lit("1e300", "1e300", 0x7E37E43C8800759C, OVF32)
    lit("123456789.34567e250", "1.2345678934567e258", 0x75848E3735333CB6, OVF32)
    lit("943794359898089732078308743689303290943794359843568973207830874368930329.", "9.437943598980897e71", 0x4EE117E8E90A0FF7, OVF32)
    lit("5e-324", "5e-324", 0x1, 0x0)
    lit("91e-324", "9e-323", 0x12, 0x0)
    lit("1e-322", "1e-322", 0x14, 0x0)
    lit("13245643e-320", "1.3245643e-313", 0x63DF832D9, 0x0)
    lit("2.22507385851e-308", "2.22507385851e-308", 0x10000000001620, 0x0)
    lit("2.1e-308", "2.1e-308", 0xF19C2629CCF53, 0x0)
    lit("4.9406564584124654e-324", "5e-324", 0x1, 0x0)
    lit("1.448997445238699", "1.448997445238699e0", 0x3FF72F17F1F49AAD, 0x3FB978C0)
    lit("0.0", "0e0", 0x0, 0x0)
    lit("1e-325", "0e0", 0x0, 0x0)
    lit("1e-326", "0e0", 0x0, 0x0)
    lit("1e-500", "0e0", 0x0, 0x0)
}

/// A finite text beyond the range is Overflow in both types, whatever the sign.
fn ovf(const t: string) {
    NO += 1
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var r?  = f64::from_str(t, &err)
    if r? || err.kind != ParseErrorKind::Overflow {
        fail(f"f64 '{shown(t)}' should be Overflow, got kind {err.kind as u8}")
    }

    err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var s? = f32::from_str(t, &err)
    if s? || err.kind != ParseErrorKind::Overflow {
        fail(f"f32 '{shown(t)}' should be Overflow, got kind {err.kind as u8}")
    }
}

fn beyond_the_range() {
    ovf("1e400")
    ovf("1e309")
    ovf("2e308")
    ovf("1.7976931348624e308")
    ovf("-1e400")
    ovf("+2e308")
    ovf("-1.7976931348624e308")
    // The halfway point above the largest f64 rounds up to infinity (its significand is odd);
    // a hair below it rounds down.
    ovf("179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792")
    bits64("179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497791.9999999999999999999999999999999999999999999999999999999999999999999", 0x7FEFFFFFFFFFFFFF)
    bits32("340282356779733661637539395458142568447.99999", 0x7F7FFFFF)
    bits32("340282356779733661637539395458142568448", OVF32)
}

fn massive_exponent() {
    // 1e{max}000 for the maximum of a 16, 32 and 64 bit integer, and the negative exponents.
    ovf("1e32767000")
    ovf("1e2147483647000")
    ovf("1e9223372036854775807000")
    ovf("1e99999999999999999999999999999")
    bits64("1e-32767000", 0)
    bits64("1e-2147483647000", 0)
    bits64("1e-9223372036854775807000", 0)
    bits64("1e-99999999999999999999999999999", 0)
    bits32("1e-2147483647000", 0)
    bits32("1e-9223372036854775807000", 0)
    bits64("-1e-9223372036854775807000", 0x8000000000000000)
    bits32("-1e-9223372036854775807000", 0x80000000)
    // A zero significand is zero whatever the exponent.
    bits64("0e9223372036854775807000", 0)
    bits32("0.0e99999999999999999999", 0)
    bits64("-0e-9223372036854775807000", 0x8000000000000000)
}

fn repeated(const unit: string, n: usize) -> string {
    var s = ""
    for var i: usize = 0; i < n; ++i {
        s += unit
    }

    return s
}

fn long_digit_strings() {
    // 0.333...3 with 700 threes is the f64 nearest one third.
    bits64(f"0.{repeated("3", 700)}", 0x3FD5555555555555)
    bits32(f"0.{repeated("3", 700)}", 0x3EAAAAAB)
    // Many digits that are only a number written long.
    bits64(f"1{repeated("0", 799)}e-799", 0x3FF0000000000000)
    bits64(f"{repeated("0", 400)}1.5{repeated("0", 400)}", 0x3FF8000000000000)
    bits32(f"{repeated("0", 400)}1.5{repeated("0", 400)}", 0x3FC00000)
    bits64(f"0.{repeated("0", 400)}{repeated("0", 400)}1", 0)
    bits64(f"1234567890123456789012345678901234567890e-340", 0x01752A64E34BA0D3)
    // A long tail that decides the rounding: 2^53 + 1 is the tie between 2^53 and 2^53 + 2;
    // a nonzero digit anywhere after it, however far, breaks the tie upward.
    bits64("9007199254740993", 0x4340000000000000)
    bits64(f"9007199254740993.{repeated("0", 1000)}", 0x4340000000000000)
    bits64(f"9007199254740993.{repeated("0", 1000)}1", 0x4340000000000001)
    bits64(f"9007199254740992.{repeated("9", 1000)}", 0x4340000000000000)
    bits64(f"9007199254740993.{repeated("0", 770)}1e0", 0x4340000000000001)
    // The same at the f32 tie 2^24 + 1.
    bits32("16777217", 0x4B800000)
    bits32(f"16777217.{repeated("0", 1000)}1", 0x4B800001)
    bits32(f"16777217.{repeated("0", 1000)}", 0x4B800000)
    // Halfway between the largest subnormal and the smallest normal f64: the tie goes to the
    // even significand (the normal one); one more digit above it is also the normal one, one
    // below is the subnormal.
    bits64("2.225073858507201136057409796709131975934819546351645648023426109724822222021076945516529523908135087914149158913039621106870086438694594645527657207407820621743379988141063267329253552286881372149012981122451451889849057222307285255133155755015914397476397983411801999323962548289017107081850690630666655994938275772572015763062690663332647565300009245888316433037779791869612049497390377829704905051080609940730262937128958950003583799967207254304360284078895771796150945516748243471030702609144621572289880258182545180325707018860872113128079512233426288368622321503775666622503982534335974568884423900265498198385487948292206894721689831099698365846814022854243330660339850886445804001034933970427567186443383770486037861622771738545623065874679014086723327636718750e-308", 0x0010000000000000)
}

fn words() {
    // inf and infinity, any letter case, either sign: an infinity of that sign.
    both_special("inf", 0x7FF0000000000000, 0x7F800000)
    both_special("infinity", 0x7FF0000000000000, 0x7F800000)
    both_special("+inf", 0x7FF0000000000000, 0x7F800000)
    both_special("+infinity", 0x7FF0000000000000, 0x7F800000)
    both_special("+iNfInItY", 0x7FF0000000000000, 0x7F800000)
    both_special("-inf", 0xFFF0000000000000, 0xFF800000)
    both_special("-INF", 0xFFF0000000000000, 0xFF800000)
    both_special("-infinity", 0xFFF0000000000000, 0xFF800000)
    both_special("-INFinity", 0xFFF0000000000000, 0xFF800000)
    // nan: a NaN, any letter case, either sign.
    nan_text("nan")
    nan_text("NaN")
    nan_text("NAN")
    nan_text("+nan")
    nan_text("+NAN")
    nan_text("-nan")
    nan_text("-NaN")
    nan_text("-nAn")
}

fn nan_text(const t: string) {
    NO += 1
    var err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var r?  = f64::from_str(t, &err)
    if !(r?) || err.kind != ParseErrorKind::None || !r.is_nan() {
        fail(f"f64 '{t}' should be a NaN")
    }

    err = ParseError { at: 99, kind: ParseErrorKind::Trailing }
    var s? = f32::from_str(t, &err)
    if !(s?) || err.kind != ParseErrorKind::None || !s.is_nan() {
        fail(f"f32 '{t}' should be a NaN")
    }
}

fn both_special(const t: string, want64: u64, want32: u32) {
    bits64(t, want64)
    bits32(t, want32)
}

/// A value prints and reads back as the same bits, signed zero and infinities included.
fn round_trip() {
    var zeros64: [u64; 2] = [0x0000000000000000, 0x8000000000000000]
    for var i = 0; i < 2; ++i {
        var v  = __builtin_bitcast<f64, u64>(zeros64[i])
        var t  = v as string
        bits64(t, zeros64[i])
        var w  = __builtin_bitcast<f32, u32>((zeros64[i] >> 32) as u32)
        var t2 = w as string
        bits32(t2, (zeros64[i] >> 32) as u32)
    }

    var inf64: [u64; 2] = [0x7FF0000000000000, 0xFFF0000000000000]
    for var i = 0; i < 2; ++i {
        var v = __builtin_bitcast<f64, u64>(inf64[i])
        bits64(v as string, inf64[i])
        var w = __builtin_bitcast<f32, u32>((inf64[i] >> 32) as u32 & 0xFF800000)
        bits32(w as string, (inf64[i] >> 32) as u32 & 0xFF800000)
    }
}

fn kind_of(const s: string) -> ParseErrorKind {
    try {
        var r = s.parse<f64>()
        return ParseErrorKind::None
    } catch e: ParseError {
        return e.kind
    }
}

fn at_of(const s: string) -> u32 {
    try {
        var r = s.parse<f64>()
        return 9999
    } catch e: ParseError {
        return e.at
    }
}

fn parse_method() panic(ParseError) {
    var a = "2.5".parse<f64>()
    NO += 1
    if a.to_bits() != 0x4004000000000000 {
        fail("parse<f64> of 2.5")
    }

    var b = "-0.1".parse<f32>()
    NO += 1
    if b.to_bits() != 0xBDCCCCCD {
        fail("parse<f32> of -0.1")
    }

    var c = "inf".parse<f64>()
    NO += 1
    if c.to_bits() != 0x7FF0000000000000 {
        fail("parse<f64> of inf")
    }

    var view = "1e3 trailing"[0..3]
    var d    = view.parse<f64>()
    NO += 1
    if d.to_bits() != 0x408F400000000000 {
        fail("parse<f64> of a view that has bytes after it")
    }

    NO += 1
    if kind_of("") != ParseErrorKind::Empty || at_of("") != 0 {
        fail("parse<f64> of empty text")
    }

    NO += 1
    if kind_of("1e999") != ParseErrorKind::Overflow {
        fail("parse<f64> of 1e999")
    }

    NO += 1
    if kind_of("1.5x") != ParseErrorKind::Trailing || at_of("1.5x") != 3 {
        fail("parse<f64> of 1.5x")
    }

    NO += 1
    if kind_of("x") != ParseErrorKind::InvalidChar || at_of("x") != 0 {
        fail("parse<f64> of x")
    }

    NO += 1
    if kind_of(" 1.0") != ParseErrorKind::InvalidChar || at_of(" 1.0") != 0 {
        fail("parse<f64> of a leading space")
    }

    NO += 1
    if kind_of("1.0 ") != ParseErrorKind::Trailing || at_of("1.0 ") != 3 {
        fail("parse<f64> of a trailing space")
    }

    NO += 1
    if kind_of("+") != ParseErrorKind::InvalidChar || kind_of("-") != ParseErrorKind::InvalidChar || kind_of(".") != ParseErrorKind::InvalidChar {
        fail("parse<f64> of a lone sign or a lone dot")
    }
}

fn main() -> i32 {
    ordinary_special_large_subnormal_zero()
    beyond_the_range()
    massive_exponent()
    long_digit_strings()
    words()
    round_trip()
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
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: ok {{[0-9]+}} cases
