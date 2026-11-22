// f64 and f32 to text: the shortest round-trip digits for named values, the choice between plain and
// exponent notation, the forms of zero, infinity and NaN, and the three ways a number becomes text
// (`as string`, `append_to`, an f-string hole), which must agree.
//
// The rule (documented on f64_to_text and layout_decimal): the shortest decimal that reads back as
// the same value, closest to it among the shortest; plain notation when the first digit has decimal
// exponent e with -4 <= e < 17 (f64) or < 9 (f32), otherwise d[.ddd]e[+-]XX with at least two
// exponent digits; a whole number has no point; zero is `0` or `-0`, infinities are `inf` and
// `-inf`, every NaN is `nan` (an f-string hole keeps a NaN's sign: put_f64 honours the sign bit).
// Width, fill and alignment of a float hole come from its spec, right-aligned by default (put_f64).
// Precision and the `e` base of a hole go through the runtime formatter and are not asserted here.
//
// Where Kairo differs from Rust: where the exact value lies halfway between two shortest candidates
// the even digit is chosen (1.00000762939453125 prints as 1.0000076293945312; "the closer one, ties
// to even" in f64_to_decimal), where Rust's flt2dec test expects ...313.
// Cases from Rust library/coretests/tests/num/flt2dec/mod.rs (the check_shortest values for f32 and
// f64: 0.1, 100, 1/3, 3.141592, 3.141592e17, 2^64, 1e23, MAX, MIN_POSITIVE, the smallest subnormal)
// Cases from Rust library/coretests/tests/num/float_ieee754_flt2dec_dec2flt.rs (preserve_signed_zero,
// preserve_signed_infinity, infinity_to_str, nan_to_str)

import std::io

static CODE: i32 = 0
static NO:   i32 = 0

fn fail(const what: string) {
    io::println(f"FAIL case {NO}: {what}")
    if CODE == 0 {
        CODE = if NO > 250 => 250 else => NO
    }
}

fn p64(bits: u64, const want: string) {
    NO += 1
    var v   = __builtin_bitcast<f64, u64>(bits)
    var by  = v as string
    var fs  = f"{v}"
    var app = string()
    v.append_to(&app)
    if by != want || fs != want || app != want {
        fail(f"f64 {bits:#x} printed '{by}' / '{fs}' / '{app}', want '{want}'")
    }

    var r?  = f64::from_str(want)
    if !(r?) || r.to_bits() != bits {
        fail(f"f64 text '{want}' does not read back as {bits:#x}")
    }
}

fn p32(bits: u32, const want: string) {
    NO += 1
    var v   = __builtin_bitcast<f32, u32>(bits)
    var by  = v as string
    var fs  = f"{v}"
    var app = string()
    v.append_to(&app)
    if by != want || fs != want || app != want {
        fail(f"f32 {bits:#x} printed '{by}' / '{fs}' / '{app}', want '{want}'")
    }

    var r?  = f32::from_str(want)
    if !(r?) || r.to_bits() != bits {
        fail(f"f32 text '{want}' does not read back as {bits:#x}")
    }
}

fn shortest_and_layout() {
    // f64
    p64(0x0000000000000000, "0")
    p64(0x8000000000000000, "-0")
    p64(0x3FF0000000000000, "1")
    p64(0xBFF0000000000000, "-1")
    p64(0x3FE0000000000000, "0.5")
    p64(0x3FB999999999999A, "0.1")
    p64(0x405EDD2F1A9FBE77, "123.456")
    p64(0x430C6BF526340000, "1000000000000000")
    p64(0x4341C37937E08000, "10000000000000000")
    p64(0x4341C37937E07FFF, "9999999999999998")
    p64(0x4376345785D8A000, "1e+17")
    p64(0x4380A741A4627800, "1.5e+17")
    p64(0x441AC53A7E04BCDA, "1.2345678901234568e+20")
    p64(0x444B1AE4D6E2EF50, "1e+21")
    p64(0x4480F0CF064DD592, "1e+22")
    p64(0x54B249AD2594C37D, "1e+100")
    p64(0x7E41EB2D66005835, "1.5e+300")
    p64(0x3F50624DD2F1A9FC, "0.001")
    p64(0x3F1A36E2EB1C432D, "0.0001")
    p64(0x3F202E4B6CE5DC68, "0.00012345")
    p64(0x3EE4F8B588E368F1, "1e-05")
    p64(0x3F202E7EF70994DD, "0.000123456")
    p64(0x3F1A36371EA531A8, "9.999e-05")
    p64(0x3E8421F5F40D8376, "1.5e-07")
    p64(0x3DDB7CDFD9D7BDBB, "1e-10")
    p64(0x2B2BFF2EE48E0530, "1e-100")
    p64(0x01B01297D23AB683, "1.5e-300")
    p64(0x4340000000000000, "9007199254740992")
    p64(0x43E0000000000000, "9.223372036854776e+18")
    p64(0x43F0000000000000, "1.8446744073709552e+19")
    p64(0x0000000000000001, "5e-324")
    p64(0x0010000000000000, "2.2250738585072014e-308")
    p64(0x7FEFFFFFFFFFFFFF, "1.7976931348623157e+308")
    p64(0x0000000000000003, "1.5e-323")
    p64(0x3FD3333333333333, "0.3")
    p64(0x3FD5555555555555, "0.3333333333333333")
    p64(0x3FE5555555555555, "0.6666666666666666")
    p64(0x3FD3333333333334, "0.30000000000000004")
    p64(0x0000000000000002, "1e-323")
    p64(0x44B52D02C7E14AF6, "1e+23")
    p64(0x3EB0000000000000, "9.5367431640625e-07")
    p64(0x4059000000000000, "100")
    p64(0x400921FAFC8B007A, "3.141592")
    p64(0x4391707882FBAF00, "3.141592e+17")
    p64(0x4004000000000000, "2.5")
    p64(0x3EE4F8B588E368F1, "1e-05")
    p64(0x41678C29C0000000, "12345678")
    p64(0x3FBF972474538EF3, "0.1234")
    p64(0x3FF0000800000000, "1.0000076293945312")
    // f32
    p32(0x00000000, "0")
    p32(0x80000000, "-0")
    p32(0x3F800000, "1")
    p32(0xC0200000, "-2.5")
    p32(0x3DCCCCCD, "0.1")
    p32(0x4CBEBC20, "100000000")
    p32(0x4CEB79A3, "123456790")
    p32(0x4E6E6B28, "1e+09")
    p32(0x4B800000, "16777216")
    p32(0x505F8476, "1.5e+10")
    p32(0x38D1B717, "0.0001")
    p32(0x3727C5AC, "1e-05")
    p32(0x7F7FFFFF, "3.4028235e+38")
    p32(0x00800000, "1.1754944e-38")
    p32(0x00000001, "1e-45")
    p32(0x3E99999A, "0.3")
    p32(0x3EAAAAAB, "0.33333334")
    p32(0x4B800000, "16777216")
    p32(0x370E9B39, "8.5e-06")
    p32(0x656D2B52, "7e+22")
    p32(0x00000003, "4e-45")
    p32(0x2EDBE6FF, "1e-10")
    p32(0x4CBEBC20, "100000000")
    p32(0x3F7FFFFF, "0.99999994")
}

fn specials() {
    // infinity and NaN: every NaN is "nan" through `as string` and append_to.
    var inf64 = __builtin_bitcast<f64, u64>(0x7FF0000000000000)
    var ninf  = __builtin_bitcast<f64, u64>(0xFFF0000000000000)
    var inf32 = __builtin_bitcast<f32, u32>(0x7F800000)
    var ninf3 = __builtin_bitcast<f32, u32>(0xFF800000)
    NO += 1
    if (inf64 as string) != "inf" || (ninf as string) != "-inf" || (inf32 as string) != "inf" || (ninf3 as string) != "-inf" {
        fail("infinity text")
    }

    NO += 1
    if f"{inf64}" != "inf" || f"{ninf}" != "-inf" || f"{inf32}" != "inf" || f"{ninf3}" != "-inf" {
        fail("infinity in an f-string")
    }

    var nans64: [u64; 5] = [0x7FF8000000000000, 0xFFF8000000000000, 0x7FF0000000000001, 0xFFFFFFFFFFFFFFFF, 0x7FF8000000000123]
    for var i = 0; i < 5; ++i {
        NO += 1
        var v = __builtin_bitcast<f64, u64>(nans64[i])
        var app = string()
        v.append_to(&app)
        if (v as string) != "nan" || app != "nan" {
            fail(f"f64 NaN {nans64[i]:#x} printed '{v as string}'")
        }

        var fs = f"{v}"
        if fs != "nan" && fs != "-nan" {
            fail(f"f64 NaN {nans64[i]:#x} in an f-string printed '{fs}'")
        }
    }

    var nans32: [u32; 4] = [0x7FC00000, 0xFFC00000, 0x7F800001, 0xFFFFFFFF]
    for var i = 0; i < 4; ++i {
        NO += 1
        var v = __builtin_bitcast<f32, u32>(nans32[i])
        var app = string()
        v.append_to(&app)
        if (v as string) != "nan" || app != "nan" {
            fail(f"f32 NaN {nans32[i]:#x} printed '{v as string}'")
        }
    }
}

fn exact_integers() {
    // Every power of two up to 2^52 is an integer below 10^17 and prints in full, as does every
    // integer of that size; one digit string compared with the integer's own text.
    for var k: i32 = 0; k < 57; ++k {
        var n: u64 = 1u64 << (k as u64)
        NO += 1
        var v = n as f64
        if k < 54 {
            if (v as string) != (n as string) {
                fail(f"2^{k} printed '{v as string}', want '{n as string}'")
            }
        }
    }

    for var m: u64 = 0; m < 3000; ++m {
        NO += 1
        var v = (m * 7919) as f64
        if (v as string) != ((m * 7919) as string) {
            fail(f"{m * 7919} printed '{v as string}'")
        }
    }
}

fn appending_and_widths() {
    // append_to adds to the text already in the string.
    var s = "x="
    var a: f64 = 1.5
    a.append_to(&s)
    var b: f32 = -0.1
    s += ";"
    b.append_to(&s)
    NO += 1
    if s != "x=1.5;-0.1" {
        fail(f"append_to gave '{s}'")
    }

    NO += 1
    var h: f64 = 1.5
    var z: f64 = -0.0
    var q: f32 = 0.25
    if f"{h:6}" != "   1.5" || f"{h:<6}|" != "1.5   |" || f"{h:*^7}" != "**1.5**" || f"{z}" != "-0" || f"{q:>6}" != "  0.25" {
        fail(f"widths: '{h:6}' '{h:<6}' '{h:*^7}' '{z}' '{q:>6}'")
    }

    NO += 1
    if f"{h} and {q} and {1e21} and {2.5e-7}" != "1.5 and 0.25 and 1e+21 and 2.5e-07" {
        fail("several float holes in one f-string")
    }
}

fn main() -> i32 {
    appending_and_widths()
    shortest_and_layout()
    specials()
    exact_integers()
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
