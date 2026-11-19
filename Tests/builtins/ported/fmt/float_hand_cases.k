// Float cases written out by hand, one expected text each (the generated float files take theirs from an oracle).
// They are the Rust and {fmt} cases whose Kairo spelling and Kairo's documented layout give the same digits, and the
// ones where the layouts differ, with Kairo's text: the default layout writes the shortest digits (`1`, not `1.0`),
// a precision counts significant digits (`{x:.2}` of 1.2345 is `1.2`, as in {fmt} and unlike Rust), and an exponent
// is written `e+06` (at least two digits and a sign), not `e6`.
// Rules asserted: Lib/rt/fmt.h (contract of kairo_rt_fmt_f64: `e` is d[.ddd]e+XX with a signed exponent of at least
// two digits; a precision is C printf's, the last digit rounded to even); website library/core/formatting.mdx,
// FmtBuf.put_f64 (shortest round-trip digits with no spec; `e` and `E`; the sign bit of -0.0 and NaN is honoured).
// Cases from Rust library/coretests/tests/fmt/float.rs (test_format_f64, test_format_f64_rounds_ties_to_even, test_format_f32)
// Cases from Rust library/coretests/tests/fmt/mod.rs (the float cases of test_format_macro_interface)
// Cases from the {fmt} library test/format-test.cc (precision, exponent_range, format_double, precision_rounding, format_nan, format_infinity)

import std::io::*

var CODE: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn from_fmt() {
    ck(f"{1.2345:.2}", "1.2", 1, "{0:.2} 1.2345")
    ck(f"{1.234e56:.2}", "1.2e+56", 1, "{:.2} 1.234e56")
    ck(f"{1.1:.3}", "1.1", 1, "{0:.3} 1.1")
    ck(f"{1.0:.0e}", "1e+00", 1, "{:.0e} 1.0")
    ck(f"{0.0:9.1e}", "  0.0e+00", 1, "{:9.1e} 0.0")
    ck(f"{0.001:.1}", "0.001", 1, "{:.1} 0.001")
    ck(f"{9.5:.0e}", "1e+01", 1, "{:.0e} 9.5")
    ck(f"{1e-34:.1e}", "1.0e-34", 1, "{:.1e} 1e-34")
    ck(f"{1.234:.02}", "1.2", 1, "precision with a leading zero")
    ck(f"{1.0}", "1", 1, "{} 1.0")
    ck(f"{-0.0}", "-0", 1, "{} -0.0")
    ck(f"{0.001}", "0.001", 1, "{} 0.001")
    ck(f"{1e100}", "1e+100", 1, "{} 1e100")
}

fn from_rust() {
    ck(f"{1.0:.0}", "1", 2, "{:.0} 1.0")
    ck(f"{9.4:.0}", "9", 2, "{:.0} 9.4")
    ck(f"{9.9:.0}", "1e+01", 2, "{:.0} 9.9 reads as one significant digit")
    ck(f"{9.849:.2}", "9.8", 2, "{:.2} 9.849")
    ck(f"{9.851:.2}", "9.9", 2, "{:.2} 9.851")
    ck(f"{1234567.89:e}", "1.23456789e+06", 2, "{:e} 1234567.89")
    ck(f"{1234.56789:e}", "1.23456789e+03", 2, "{:e} 1234.56789")
    ck(f"{1234567.89:E}", "1.23456789E+06", 2, "{:E} 1234567.89")
    ck(f"{1.2345e6:e}", "1.2345e+06", 2, "{:e} 1.2345e6")
    ck(f"{1.2345e6:.3e}", "1.234e+06", 2, "{:.3e} 1.2345e6 is a tie, rounded to even")
    ck(f"{1.2345e6:10.3e}", " 1.234e+06", 2, "{:10.3e}")
    ck(f"{1.2345e6:+10.3e}", "+1.234e+06", 2, "{:+10.3e}")
    ck(f"{-1.2345e6:+10.3e}", "-1.234e+06", 2, "{:+10.3e} negative")
    ck(f"{1.0:10.3}", "         1", 2, "{:10.3} 1.0")
    ck(f"{1.0:+10.3}", "        +1", 2, "{:+10.3} 1.0")
    ck(f"{-1.0:+10.3}", "        -1", 2, "{:+10.3} -1.0")
    ck(f"{1.0:.3}", "1", 2, "{:.3} 1.0 drops trailing zeros")
}

fn ties_from_rust() {
    ck(f"{1.5:.0e}", "2e+00", 3, "1.5")
    ck(f"{2.5:.0e}", "2e+00", 3, "2.5")
    ck(f"{3.5:.0e}", "4e+00", 3, "3.5")
    ck(f"{4.5:.0e}", "4e+00", 3, "4.5")
    ck(f"{5.5:.0e}", "6e+00", 3, "5.5")
    ck(f"{127.5:.2e}", "1.28e+02", 3, "127.5")
    ck(f"{128.5:.2e}", "1.28e+02", 3, "128.5")
    ck(f"{-1.5:.0e}", "-2e+00", 3, "-1.5")
    ck(f"{-2.5:.0e}", "-2e+00", 3, "-2.5")
    ck(f"{-127.5:.2e}", "-1.28e+02", 3, "-127.5")
    ck(f"{1.5:.0E}", "2E+00", 3, "1.5 upper")
    ck(f"{-128.5:.2E}", "-1.28E+02", 3, "-128.5 upper")
    ck(f"{0.25:.1}", "0.2", 3, "0.25 to one digit")
    ck(f"{0.75:.1}", "0.8", 3, "0.75 to one digit")
    ck(f"{0.125:.2}", "0.12", 3, "0.125 to two digits")
    ck(f"{0.875:.2}", "0.88", 3, "0.875 to two digits")
    ck(f"{-0.125:.2}", "-0.12", 3, "-0.125 to two digits")
    ck(f"{-0.875:.2}", "-0.88", 3, "-0.875 to two digits")
    var f: f32 = 2.5
    ck(f"{f:.0e}", "2e+00", 3, "f32 2.5")
    var g: f32 = 127.5
    ck(f"{g:.2e}", "1.28e+02", 3, "f32 127.5")
    var h: f32 = 1234567.89
    ck(f"{h:e}", "1.2345679e+06", 3, "{:e} 1234567.89f32")
}

fn specials() {
    var nan = f64::NAN
    var inf = f64::INFINITY
    ck(f"{nan}", "nan", 4, "nan")
    ck(f"{-nan}", "-nan", 4, "negative nan")
    ck(f"{inf}", "inf", 4, "inf")
    ck(f"{-inf}", "-inf", 4, "-inf")
    ck(f"{inf:+}", "+inf", 4, "+inf")
    ck(f"{nan:+}", "+nan", 4, "+nan")
    ck(f"{inf:>6}", "   inf", 4, "inf right")
    ck(f"{inf:*^7}", "**inf**", 4, "inf centred")
    ck(f"{-inf:<6}|", "-inf  |", 4, "-inf left")
    ck(f"{nan:6}", "   nan", 4, "nan numbers default to the right")
    ck(f"{inf:E}", "INF", 4, "inf upper")
    ck(f"{nan:E}", "NAN", 4, "nan upper")
    ck(f"{inf:e}", "inf", 4, "inf exponent")
    ck(f"{inf:.2}", "inf", 4, "inf with a precision")
    ck(f"{1.0 / 0.0 * 0.0}", "nan", 4, "inf times zero")
    var f32inf = f32::INFINITY
    ck(f"{f32inf}", "inf", 4, "f32 inf")
    ck(f"{-f32::NAN}", "-nan", 4, "f32 negative nan")
}

fn main() -> i32 {
    from_fmt()
    from_rust()
    ties_from_rust()
    specials()
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
