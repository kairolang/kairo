// f32 with no precision: the shortest round-trip digits of the f32 value (not of a widened f64) in default, `e` and `E` layout; the layout threshold is 9 digits.
// Rules asserted: a float hole with no precision prints the shortest digits that read back as the same value, in the layout
// of C's `%g` with the format's round-trip digit count as P (17 for f64, 9 for f32): fixed notation unless the decimal
// exponent is below -4 or at least P, trailing zeros dropped; `e` / `E` print d[.ddd]e+XX with at least two exponent digits.
// A precision gives C printf semantics: that many significant digits for the default layout (0 reads as 1), that many digits
// after the point for `e`, every digit exact, the last rounded to even (Lib/rt/fmt.h, contract of kairo_rt_fmt_f64;
// Lib/builtin2/fmt/fmt_buf.k put_f64: "the `e` base selects exponent form, `E` with the upper flag"; website
// library/core/formatting.mdx FmtBuf.put_f64; language/primitives.mdx, Formatting under f256: "the last rounded to even").
// This differs from Rust and {fmt}, whose `.N` counts digits after the point: Kairo has no `f` presentation type and its
// `{x:.2}` is two significant digits.
// Expected texts come from a Python oracle: the `%` operator (C semantics, exact binary digits) and a shortest-digits search
// over `%.Ne` that round-trips through struct packing.
// Not asserted because the docs do not state them: zero padding of a float, `#` is an error, `+nan` spelling beyond "honours
// the sign bit of NaN", the split of an odd amount of padding by `^`.
// Cases from Rust library/coretests/tests/fmt/float.rs (rounds_ties_to_even, test_format_f64 / f32, extremes)
// Cases from Rust library/coretests/tests/fmt/mod.rs (float width, sign, precision cases)
// Cases from the {fmt} library test/format-test.cc (float, exponent and special-value cases)

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

fn shortest_f32() {
    var v0: f32 = 0.0e0
    var v1: f32 = -0.0e0
    var v2: f32 = 1.0e0
    var v3: f32 = -1.0e0
    var v4: f32 = 5.0e-1
    var v5: f32 = 1.5e0
    var v6: f32 = 2.5e0
    var v7: f32 = 1.0e-1
    var v8: f32 = 2.0e-1
    var v9: f32 = 3.3333334e-1
    var v10: f32 = 6.666667e-1
    var v11: f32 = 3.14159e0
    var v12: f32 = 1.0e2
    var v13: f32 = 1.6777216e7
    var v14: f32 = 1.6777216e7
    var v15: f32 = 1.2345679e5
    var v16: f32 = 1.0e7
    var v17: f32 = 1.0e8
    var v18: f32 = 1.0e9
    var v19: f32 = 1.234568e9
    var v20: f32 = 1.0e10
    var v21: f32 = 1.0e30
    var v22: f32 = 1.0e-3
    var v23: f32 = 1.0e-4
    var v24: f32 = 1.0e-5
    var v25: f32 = 1.5e-5
    var v26: f32 = 1.0e-10
    var v27: f32 = 1.0e-45
    var v28: f32 = f32::MIN_POSITIVE
    var v29: f32 = f32::MAX
    var v30: f32 = 4.35e0
    var v31: f32 = 3.0e-1
    var v32: f32 = 2.675e0
    var v33: f32 = -1.2345e3
    var v34: f32 = -1.0e-7
    ck(f"{v0}", "0", 1, "f32 0.0 {}")
    ck(f"{v0:e}", "0e+00", 1, "f32 0.0 {e}")
    ck(f"{v0:E}", "0E+00", 1, "f32 0.0 {E}")
    ck(f"{v1}", "-0", 1, "f32 -0.0 {}")
    ck(f"{v1:e}", "-0e+00", 1, "f32 -0.0 {e}")
    ck(f"{v1:E}", "-0E+00", 1, "f32 -0.0 {E}")
    ck(f"{v2}", "1", 1, "f32 1.0 {}")
    ck(f"{v2:e}", "1e+00", 1, "f32 1.0 {e}")
    ck(f"{v2:E}", "1E+00", 1, "f32 1.0 {E}")
    ck(f"{v3}", "-1", 1, "f32 -1.0 {}")
    ck(f"{v3:e}", "-1e+00", 1, "f32 -1.0 {e}")
    ck(f"{v3:E}", "-1E+00", 1, "f32 -1.0 {E}")
    ck(f"{v4}", "0.5", 1, "f32 0.5 {}")
    ck(f"{v4:e}", "5e-01", 1, "f32 0.5 {e}")
    ck(f"{v4:E}", "5E-01", 1, "f32 0.5 {E}")
    ck(f"{v5}", "1.5", 1, "f32 1.5 {}")
    ck(f"{v5:e}", "1.5e+00", 1, "f32 1.5 {e}")
    ck(f"{v5:E}", "1.5E+00", 1, "f32 1.5 {E}")
    ck(f"{v6}", "2.5", 1, "f32 2.5 {}")
    ck(f"{v6:e}", "2.5e+00", 1, "f32 2.5 {e}")
    ck(f"{v6:E}", "2.5E+00", 1, "f32 2.5 {E}")
    ck(f"{v7}", "0.1", 1, "f32 0.10000000149011612 {}")
    ck(f"{v7:e}", "1e-01", 1, "f32 0.10000000149011612 {e}")
    ck(f"{v7:E}", "1E-01", 1, "f32 0.10000000149011612 {E}")
    ck(f"{v8}", "0.2", 1, "f32 0.20000000298023224 {}")
    ck(f"{v8:e}", "2e-01", 1, "f32 0.20000000298023224 {e}")
    ck(f"{v8:E}", "2E-01", 1, "f32 0.20000000298023224 {E}")
    ck(f"{v9}", "0.33333334", 1, "f32 0.3333333432674408 {}")
    ck(f"{v9:e}", "3.3333334e-01", 1, "f32 0.3333333432674408 {e}")
    ck(f"{v9:E}", "3.3333334E-01", 1, "f32 0.3333333432674408 {E}")
    ck(f"{v10}", "0.6666667", 1, "f32 0.6666666865348816 {}")
    ck(f"{v10:e}", "6.666667e-01", 1, "f32 0.6666666865348816 {e}")
    ck(f"{v10:E}", "6.666667E-01", 1, "f32 0.6666666865348816 {E}")
    ck(f"{v11}", "3.14159", 1, "f32 3.141590118408203 {}")
    ck(f"{v11:e}", "3.14159e+00", 1, "f32 3.141590118408203 {e}")
    ck(f"{v11:E}", "3.14159E+00", 1, "f32 3.141590118408203 {E}")
    ck(f"{v12}", "100", 1, "f32 100.0 {}")
    ck(f"{v12:e}", "1e+02", 1, "f32 100.0 {e}")
    ck(f"{v12:E}", "1E+02", 1, "f32 100.0 {E}")
    ck(f"{v13}", "16777216", 1, "f32 16777216.0 {}")
    ck(f"{v13:e}", "1.6777216e+07", 1, "f32 16777216.0 {e}")
    ck(f"{v13:E}", "1.6777216E+07", 1, "f32 16777216.0 {E}")
    ck(f"{v14}", "16777216", 1, "f32 16777216.0 {}")
    ck(f"{v14:e}", "1.6777216e+07", 1, "f32 16777216.0 {e}")
    ck(f"{v14:E}", "1.6777216E+07", 1, "f32 16777216.0 {E}")
    ck(f"{v15}", "123456.79", 1, "f32 123456.7890625 {}")
    ck(f"{v15:e}", "1.2345679e+05", 1, "f32 123456.7890625 {e}")
    ck(f"{v15:E}", "1.2345679E+05", 1, "f32 123456.7890625 {E}")
    ck(f"{v16}", "10000000", 1, "f32 10000000.0 {}")
    ck(f"{v16:e}", "1e+07", 1, "f32 10000000.0 {e}")
    ck(f"{v16:E}", "1E+07", 1, "f32 10000000.0 {E}")
    ck(f"{v17}", "100000000", 1, "f32 100000000.0 {}")
    ck(f"{v17:e}", "1e+08", 1, "f32 100000000.0 {e}")
    ck(f"{v17:E}", "1E+08", 1, "f32 100000000.0 {E}")
    ck(f"{v18}", "1e+09", 1, "f32 1000000000.0 {}")
    ck(f"{v18:e}", "1e+09", 1, "f32 1000000000.0 {e}")
    ck(f"{v18:E}", "1E+09", 1, "f32 1000000000.0 {E}")
    ck(f"{v19}", "1.234568e+09", 1, "f32 1234567936.0 {}")
    ck(f"{v19:e}", "1.234568e+09", 1, "f32 1234567936.0 {e}")
    ck(f"{v19:E}", "1.234568E+09", 1, "f32 1234567936.0 {E}")
    ck(f"{v20}", "1e+10", 1, "f32 10000000000.0 {}")
    ck(f"{v20:e}", "1e+10", 1, "f32 10000000000.0 {e}")
    ck(f"{v20:E}", "1E+10", 1, "f32 10000000000.0 {E}")
    ck(f"{v21}", "1e+30", 1, "f32 1.0000000150474662e+30 {}")
    ck(f"{v21:e}", "1e+30", 1, "f32 1.0000000150474662e+30 {e}")
    ck(f"{v21:E}", "1E+30", 1, "f32 1.0000000150474662e+30 {E}")
    ck(f"{v22}", "0.001", 1, "f32 0.0010000000474974513 {}")
    ck(f"{v22:e}", "1e-03", 1, "f32 0.0010000000474974513 {e}")
    ck(f"{v22:E}", "1E-03", 1, "f32 0.0010000000474974513 {E}")
    ck(f"{v23}", "0.0001", 1, "f32 9.999999747378752e-05 {}")
    ck(f"{v23:e}", "1e-04", 1, "f32 9.999999747378752e-05 {e}")
    ck(f"{v23:E}", "1E-04", 1, "f32 9.999999747378752e-05 {E}")
    ck(f"{v24}", "1e-05", 1, "f32 9.999999747378752e-06 {}")
    ck(f"{v24:e}", "1e-05", 1, "f32 9.999999747378752e-06 {e}")
    ck(f"{v24:E}", "1E-05", 1, "f32 9.999999747378752e-06 {E}")
    ck(f"{v25}", "1.5e-05", 1, "f32 1.4999999621068127e-05 {}")
    ck(f"{v25:e}", "1.5e-05", 1, "f32 1.4999999621068127e-05 {e}")
    ck(f"{v25:E}", "1.5E-05", 1, "f32 1.4999999621068127e-05 {E}")
    ck(f"{v26}", "1e-10", 1, "f32 1.000000013351432e-10 {}")
    ck(f"{v26:e}", "1e-10", 1, "f32 1.000000013351432e-10 {e}")
    ck(f"{v26:E}", "1E-10", 1, "f32 1.000000013351432e-10 {E}")
    ck(f"{v27}", "1e-45", 1, "f32 1.401298464324817e-45 {}")
    ck(f"{v27:e}", "1e-45", 1, "f32 1.401298464324817e-45 {e}")
    ck(f"{v27:E}", "1E-45", 1, "f32 1.401298464324817e-45 {E}")
    ck(f"{v28}", "1.1754944e-38", 1, "f32 1.1754943508222875e-38 {}")
    ck(f"{v28:e}", "1.1754944e-38", 1, "f32 1.1754943508222875e-38 {e}")
    ck(f"{v28:E}", "1.1754944E-38", 1, "f32 1.1754943508222875e-38 {E}")
    ck(f"{v29}", "3.4028235e+38", 1, "f32 3.4028234663852886e+38 {}")
    ck(f"{v29:e}", "3.4028235e+38", 1, "f32 3.4028234663852886e+38 {e}")
    ck(f"{v29:E}", "3.4028235E+38", 1, "f32 3.4028234663852886e+38 {E}")
    ck(f"{v30}", "4.35", 1, "f32 4.349999904632568 {}")
    ck(f"{v30:e}", "4.35e+00", 1, "f32 4.349999904632568 {e}")
    ck(f"{v30:E}", "4.35E+00", 1, "f32 4.349999904632568 {E}")
    ck(f"{v31}", "0.3", 1, "f32 0.30000001192092896 {}")
    ck(f"{v31:e}", "3e-01", 1, "f32 0.30000001192092896 {e}")
    ck(f"{v31:E}", "3E-01", 1, "f32 0.30000001192092896 {E}")
    ck(f"{v32}", "2.675", 1, "f32 2.674999952316284 {}")
    ck(f"{v32:e}", "2.675e+00", 1, "f32 2.674999952316284 {e}")
    ck(f"{v32:E}", "2.675E+00", 1, "f32 2.674999952316284 {E}")
    ck(f"{v33}", "-1234.5", 1, "f32 -1234.5 {}")
    ck(f"{v33:e}", "-1.2345e+03", 1, "f32 -1234.5 {e}")
    ck(f"{v33:E}", "-1.2345E+03", 1, "f32 -1234.5 {E}")
    ck(f"{v34}", "-1e-07", 1, "f32 -1.0000000116860974e-07 {}")
    ck(f"{v34:e}", "-1e-07", 1, "f32 -1.0000000116860974e-07 {e}")
    ck(f"{v34:E}", "-1E-07", 1, "f32 -1.0000000116860974e-07 {E}")
}

fn main() -> i32 {
    shortest_f32()
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
