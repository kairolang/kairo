// f64 with no precision: the shortest round-trip digits in default, `e` and `E` layout for 45 values (zero, negative zero, powers of ten around both layout thresholds, subnormals, the extremes).
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

fn shortest_f64() {
    var v0: f64 = 0.0
    var v1: f64 = -0.0
    var v2: f64 = 1.0
    var v3: f64 = -1.0
    var v4: f64 = 2.0
    var v5: f64 = 0.5
    var v6: f64 = 1.5
    var v7: f64 = 2.5
    var v8: f64 = 0.1
    var v9: f64 = 0.2
    var v10: f64 = 0.30000000000000004
    var v11: f64 = 0.3333333333333333
    var v12: f64 = 0.6666666666666666
    var v13: f64 = 3.14159
    var v14: f64 = 100.0
    var v15: f64 = 12345.678
    var v16: f64 = 123456789.0
    var v17: f64 = 1000000000000000.0
    var v18: f64 = 1e+16
    var v19: f64 = 9007199254740992.0
    var v20: f64 = 1e+17
    var v21: f64 = 1.2345678901234568e+17
    var v22: f64 = 1e+22
    var v23: f64 = 1e+100
    var v24: f64 = 1e+300
    var v25: f64 = 0.001
    var v26: f64 = 0.0001
    var v27: f64 = 1e-05
    var v28: f64 = 1.5e-05
    var v29: f64 = 1.23e-05
    var v30: f64 = 1e-100
    var v31: f64 = 1e-300
    var v32: f64 = 5e-324
    var v33: f64 = f64::MIN_POSITIVE
    var v34: f64 = f64::MAX
    var v35: f64 = 4.35
    var v36: f64 = 0.3
    var v37: f64 = 2.675
    var v38: f64 = 1e+21
    var v39: f64 = 1.2345678901234568e+17
    var v40: f64 = 5e-324
    var v41: f64 = -1234.5
    var v42: f64 = -1e-07
    var v43: f64 = -1e+30
    ck(f"{v0}", "0", 1, "f64 0.0 {}")
    ck(f"{v0:e}", "0e+00", 1, "f64 0.0 {e}")
    ck(f"{v0:E}", "0E+00", 1, "f64 0.0 {E}")
    ck(f"{v1}", "-0", 1, "f64 -0.0 {}")
    ck(f"{v1:e}", "-0e+00", 1, "f64 -0.0 {e}")
    ck(f"{v1:E}", "-0E+00", 1, "f64 -0.0 {E}")
    ck(f"{v2}", "1", 1, "f64 1.0 {}")
    ck(f"{v2:e}", "1e+00", 1, "f64 1.0 {e}")
    ck(f"{v2:E}", "1E+00", 1, "f64 1.0 {E}")
    ck(f"{v3}", "-1", 1, "f64 -1.0 {}")
    ck(f"{v3:e}", "-1e+00", 1, "f64 -1.0 {e}")
    ck(f"{v3:E}", "-1E+00", 1, "f64 -1.0 {E}")
    ck(f"{v4}", "2", 1, "f64 2.0 {}")
    ck(f"{v4:e}", "2e+00", 1, "f64 2.0 {e}")
    ck(f"{v4:E}", "2E+00", 1, "f64 2.0 {E}")
    ck(f"{v5}", "0.5", 1, "f64 0.5 {}")
    ck(f"{v5:e}", "5e-01", 1, "f64 0.5 {e}")
    ck(f"{v5:E}", "5E-01", 1, "f64 0.5 {E}")
    ck(f"{v6}", "1.5", 1, "f64 1.5 {}")
    ck(f"{v6:e}", "1.5e+00", 1, "f64 1.5 {e}")
    ck(f"{v6:E}", "1.5E+00", 1, "f64 1.5 {E}")
    ck(f"{v7}", "2.5", 1, "f64 2.5 {}")
    ck(f"{v7:e}", "2.5e+00", 1, "f64 2.5 {e}")
    ck(f"{v7:E}", "2.5E+00", 1, "f64 2.5 {E}")
    ck(f"{v8}", "0.1", 1, "f64 0.1 {}")
    ck(f"{v8:e}", "1e-01", 1, "f64 0.1 {e}")
    ck(f"{v8:E}", "1E-01", 1, "f64 0.1 {E}")
    ck(f"{v9}", "0.2", 1, "f64 0.2 {}")
    ck(f"{v9:e}", "2e-01", 1, "f64 0.2 {e}")
    ck(f"{v9:E}", "2E-01", 1, "f64 0.2 {E}")
    ck(f"{v10}", "0.30000000000000004", 1, "f64 0.30000000000000004 {}")
    ck(f"{v10:e}", "3.0000000000000004e-01", 1, "f64 0.30000000000000004 {e}")
    ck(f"{v10:E}", "3.0000000000000004E-01", 1, "f64 0.30000000000000004 {E}")
    ck(f"{v11}", "0.3333333333333333", 1, "f64 0.3333333333333333 {}")
    ck(f"{v11:e}", "3.333333333333333e-01", 1, "f64 0.3333333333333333 {e}")
    ck(f"{v11:E}", "3.333333333333333E-01", 1, "f64 0.3333333333333333 {E}")
    ck(f"{v12}", "0.6666666666666666", 1, "f64 0.6666666666666666 {}")
    ck(f"{v12:e}", "6.666666666666666e-01", 1, "f64 0.6666666666666666 {e}")
    ck(f"{v12:E}", "6.666666666666666E-01", 1, "f64 0.6666666666666666 {E}")
    ck(f"{v13}", "3.14159", 1, "f64 3.14159 {}")
    ck(f"{v13:e}", "3.14159e+00", 1, "f64 3.14159 {e}")
    ck(f"{v13:E}", "3.14159E+00", 1, "f64 3.14159 {E}")
    ck(f"{v14}", "100", 1, "f64 100.0 {}")
    ck(f"{v14:e}", "1e+02", 1, "f64 100.0 {e}")
    ck(f"{v14:E}", "1E+02", 1, "f64 100.0 {E}")
    ck(f"{v15}", "12345.678", 1, "f64 12345.678 {}")
    ck(f"{v15:e}", "1.2345678e+04", 1, "f64 12345.678 {e}")
    ck(f"{v15:E}", "1.2345678E+04", 1, "f64 12345.678 {E}")
    ck(f"{v16}", "123456789", 1, "f64 123456789.0 {}")
    ck(f"{v16:e}", "1.23456789e+08", 1, "f64 123456789.0 {e}")
    ck(f"{v16:E}", "1.23456789E+08", 1, "f64 123456789.0 {E}")
    ck(f"{v17}", "1000000000000000", 1, "f64 1000000000000000.0 {}")
    ck(f"{v17:e}", "1e+15", 1, "f64 1000000000000000.0 {e}")
    ck(f"{v17:E}", "1E+15", 1, "f64 1000000000000000.0 {E}")
    ck(f"{v18}", "10000000000000000", 1, "f64 1e+16 {}")
    ck(f"{v18:e}", "1e+16", 1, "f64 1e+16 {e}")
    ck(f"{v18:E}", "1E+16", 1, "f64 1e+16 {E}")
    ck(f"{v19}", "9007199254740992", 1, "f64 9007199254740992.0 {}")
    ck(f"{v19:e}", "9.007199254740992e+15", 1, "f64 9007199254740992.0 {e}")
    ck(f"{v19:E}", "9.007199254740992E+15", 1, "f64 9007199254740992.0 {E}")
    ck(f"{v20}", "1e+17", 1, "f64 1e+17 {}")
    ck(f"{v20:e}", "1e+17", 1, "f64 1e+17 {e}")
    ck(f"{v20:E}", "1E+17", 1, "f64 1e+17 {E}")
    ck(f"{v21}", "1.2345678901234568e+17", 1, "f64 1.2345678901234568e+17 {}")
    ck(f"{v21:e}", "1.2345678901234568e+17", 1, "f64 1.2345678901234568e+17 {e}")
    ck(f"{v21:E}", "1.2345678901234568E+17", 1, "f64 1.2345678901234568e+17 {E}")
    ck(f"{v22}", "1e+22", 1, "f64 1e+22 {}")
    ck(f"{v22:e}", "1e+22", 1, "f64 1e+22 {e}")
    ck(f"{v22:E}", "1E+22", 1, "f64 1e+22 {E}")
    ck(f"{v23}", "1e+100", 1, "f64 1e+100 {}")
    ck(f"{v23:e}", "1e+100", 1, "f64 1e+100 {e}")
    ck(f"{v23:E}", "1E+100", 1, "f64 1e+100 {E}")
    ck(f"{v24}", "1e+300", 1, "f64 1e+300 {}")
    ck(f"{v24:e}", "1e+300", 1, "f64 1e+300 {e}")
    ck(f"{v24:E}", "1E+300", 1, "f64 1e+300 {E}")
    ck(f"{v25}", "0.001", 1, "f64 0.001 {}")
    ck(f"{v25:e}", "1e-03", 1, "f64 0.001 {e}")
    ck(f"{v25:E}", "1E-03", 1, "f64 0.001 {E}")
    ck(f"{v26}", "0.0001", 1, "f64 0.0001 {}")
    ck(f"{v26:e}", "1e-04", 1, "f64 0.0001 {e}")
    ck(f"{v26:E}", "1E-04", 1, "f64 0.0001 {E}")
    ck(f"{v27}", "1e-05", 1, "f64 1e-05 {}")
    ck(f"{v27:e}", "1e-05", 1, "f64 1e-05 {e}")
    ck(f"{v27:E}", "1E-05", 1, "f64 1e-05 {E}")
    ck(f"{v28}", "1.5e-05", 1, "f64 1.5e-05 {}")
    ck(f"{v28:e}", "1.5e-05", 1, "f64 1.5e-05 {e}")
    ck(f"{v28:E}", "1.5E-05", 1, "f64 1.5e-05 {E}")
    ck(f"{v29}", "1.23e-05", 1, "f64 1.23e-05 {}")
    ck(f"{v29:e}", "1.23e-05", 1, "f64 1.23e-05 {e}")
    ck(f"{v29:E}", "1.23E-05", 1, "f64 1.23e-05 {E}")
    ck(f"{v30}", "1e-100", 1, "f64 1e-100 {}")
    ck(f"{v30:e}", "1e-100", 1, "f64 1e-100 {e}")
    ck(f"{v30:E}", "1E-100", 1, "f64 1e-100 {E}")
    ck(f"{v31}", "1e-300", 1, "f64 1e-300 {}")
    ck(f"{v31:e}", "1e-300", 1, "f64 1e-300 {e}")
    ck(f"{v31:E}", "1E-300", 1, "f64 1e-300 {E}")
    ck(f"{v32}", "5e-324", 1, "f64 5e-324 {}")
    ck(f"{v32:e}", "5e-324", 1, "f64 5e-324 {e}")
    ck(f"{v32:E}", "5E-324", 1, "f64 5e-324 {E}")
    ck(f"{v33}", "2.2250738585072014e-308", 1, "f64 2.2250738585072014e-308 {}")
    ck(f"{v33:e}", "2.2250738585072014e-308", 1, "f64 2.2250738585072014e-308 {e}")
    ck(f"{v33:E}", "2.2250738585072014E-308", 1, "f64 2.2250738585072014e-308 {E}")
    ck(f"{v34}", "1.7976931348623157e+308", 1, "f64 1.7976931348623157e+308 {}")
    ck(f"{v34:e}", "1.7976931348623157e+308", 1, "f64 1.7976931348623157e+308 {e}")
    ck(f"{v34:E}", "1.7976931348623157E+308", 1, "f64 1.7976931348623157e+308 {E}")
    ck(f"{v35}", "4.35", 1, "f64 4.35 {}")
    ck(f"{v35:e}", "4.35e+00", 1, "f64 4.35 {e}")
    ck(f"{v35:E}", "4.35E+00", 1, "f64 4.35 {E}")
    ck(f"{v36}", "0.3", 1, "f64 0.3 {}")
    ck(f"{v36:e}", "3e-01", 1, "f64 0.3 {e}")
    ck(f"{v36:E}", "3E-01", 1, "f64 0.3 {E}")
    ck(f"{v37}", "2.675", 1, "f64 2.675 {}")
    ck(f"{v37:e}", "2.675e+00", 1, "f64 2.675 {e}")
    ck(f"{v37:E}", "2.675E+00", 1, "f64 2.675 {E}")
    ck(f"{v38}", "1e+21", 1, "f64 1e+21 {}")
    ck(f"{v38:e}", "1e+21", 1, "f64 1e+21 {e}")
    ck(f"{v38:E}", "1E+21", 1, "f64 1e+21 {E}")
    ck(f"{v39}", "1.2345678901234568e+17", 1, "f64 1.2345678901234568e+17 {}")
    ck(f"{v39:e}", "1.2345678901234568e+17", 1, "f64 1.2345678901234568e+17 {e}")
    ck(f"{v39:E}", "1.2345678901234568E+17", 1, "f64 1.2345678901234568e+17 {E}")
    ck(f"{v40}", "5e-324", 1, "f64 5e-324 {}")
    ck(f"{v40:e}", "5e-324", 1, "f64 5e-324 {e}")
    ck(f"{v40:E}", "5E-324", 1, "f64 5e-324 {E}")
    ck(f"{v41}", "-1234.5", 1, "f64 -1234.5 {}")
    ck(f"{v41:e}", "-1.2345e+03", 1, "f64 -1234.5 {e}")
    ck(f"{v41:E}", "-1.2345E+03", 1, "f64 -1234.5 {E}")
    ck(f"{v42}", "-1e-07", 1, "f64 -1e-07 {}")
    ck(f"{v42:e}", "-1e-07", 1, "f64 -1e-07 {e}")
    ck(f"{v42:E}", "-1E-07", 1, "f64 -1e-07 {E}")
    ck(f"{v43}", "-1e+30", 1, "f64 -1e+30 {}")
    ck(f"{v43:e}", "-1e+30", 1, "f64 -1e+30 {e}")
    ck(f"{v43:E}", "-1E+30", 1, "f64 -1e+30 {E}")
}

fn main() -> i32 {
    shortest_f64()
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
