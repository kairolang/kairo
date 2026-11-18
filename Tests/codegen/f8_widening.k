// `f8e4m3` and `f8e5m2` widen implicitly into `f16`, `bf16`, `f32` and `f64`
// (conversion-lattice.mdx R4), and the value survives: every finite encoding
// of both formats, built from its sign, exponent and mantissa fields,
// reads back exactly through each of the eight conversions, an `f8e5m2`
// infinity stays an infinity and a NaN stays a NaN. The conversion is the
// same in every place a value is converted: an initializer, an assignment,
// an argument, a return, an operand beside a wider float (arithmetic,
// comparison, `<=>`, compound assignment), the arms of an `if` and a
// `match`, an array element, a field, a tuple element and a nullable.

import std::io

struct P {
    var x: f32 = 0.0
    var y: f64 = 0.0
}

fn pow2(k: i32) -> f64 {
    var r: f64 = 1.0
    for var i: i32 = 0; i < k; ++i { r *= 2.0 }
    for var i: i32 = 0; i > k; --i { r /= 2.0 }
    return r
}

fn take32(x: f32) -> f32 { return x }
fn take64(x: f64) -> f64 { return x }
fn ret16(x: f8e5m2) -> f16 { return x }
fn retb(x: f8e4m3) -> bf16 { return x }
fn maybe(x: f8e5m2) -> f32? { return x }

// The count of encodings one of the four conversions changes.
fn sweep_e4m3() -> i32 {
    var bad = 0
    for var e: i32 = 0; e < 16; ++e {
        for var m: i32 = 0; m < 8; ++m {
            if e == 15 && m == 7 { continue }                   // the NaN
            var v: f64 = if e == 0 => ((m as f64) / 8.0 * pow2(-6)) else => (1.0 + (m as f64) / 8.0) * pow2(e - 7)
            for var sg: i32 = 0; sg < 2; ++sg {
                var sv = if sg == 0 => (v) else => -v
                var x: f8e4m3 = sv as f8e4m3
                var x16: f16 = x
                var xb: bf16 = x
                var x32: f32 = x
                var x64: f64 = x
                if x64 != sv || (x32 as f64) != sv || (x16 as f64) != sv || (xb as f64) != sv { bad += 1 }
            }
        }
    }

    return bad
}

fn sweep_e5m2() -> i32 {
    var bad = 0
    for var e: i32 = 0; e < 31; ++e {
        for var m: i32 = 0; m < 4; ++m {
            var v: f64 = if e == 0 => ((m as f64) / 4.0 * pow2(-14)) else => (1.0 + (m as f64) / 4.0) * pow2(e - 15)
            for var sg: i32 = 0; sg < 2; ++sg {
                var sv = if sg == 0 => (v) else => -v
                var y: f8e5m2 = sv as f8e5m2
                var y16: f16 = y
                var yb: bf16 = y
                var y32: f32 = y
                var y64: f64 = y
                if y64 != sv || (y32 as f64) != sv || (y16 as f64) != sv || (yb as f64) != sv { bad += 1 }
            }
        }
    }

    return bad
}

fn main() -> i32 {
    io::println(f"sweep {sweep_e4m3()} {sweep_e5m2()}")

    var top: f8e4m3 = f8e4m3::MAX
    var low: f8e5m2 = f8e5m2::MIN_POSITIVE
    var t16: f16 = top
    var l64: f64 = low
    io::println(f"limits {t16} {l64 == pow2(-14)}")

    var inf: f8e5m2 = f8e5m2::INFINITY
    var ninf: f8e5m2 = f8e5m2::NEG_INFINITY
    var v16: f16 = inf
    var vb: bf16 = ninf
    var v32: f32 = inf
    var v64: f64 = ninf
    io::println(f"inf {v16 == f16::INFINITY} {vb == bf16::NEG_INFINITY} {v32 == f32::INFINITY} {v64 == f64::NEG_INFINITY}")

    var n4: f8e4m3 = f8e4m3::NAN
    var n5: f8e5m2 = f8e5m2::NAN
    var n32: f32 = n4
    var n64: f64 = n5
    var n16: f16 = n5
    var nb: bf16 = n4
    io::println(f"nan {n32 != n32} {n64 != n64} {n16 != n16} {nb != nb}")

    var a: f8e4m3 = 1.5
    var b: f8e5m2 = 3.0
    var w: f32 = 2.0
    var d: f64 = 0.25
    var h: f16 = 4.0
    var s: f64 = 0.0
    s = a
    io::println(f"assign {s} args {take32(a)} {take64(b)} returns {ret16(b)} {retb(a)}")
    io::println(f"arith {a + w} {w - a} {a * d} {b / h} {d + b}")
    io::println(f"compare {a < w} {w == a} {b > d} {h >= b} {a != d}")
    io::println(f"order {(a <=> w) == (1.5f32 <=> 2.0f32)} {(d <=> b) == (0.25 <=> 3.0)}")
    w += a
    d -= b
    io::println(f"compound {w} {d}")

    var c = true
    var p = if c => (a) else => w
    var q = if !c => (d) else => b
    var m = match 2 { case 1 => (w) default => a }
    io::println(f"arms {p} {q} {m}")

    var arr = [w, a]
    var st = P { x: a, y: b }
    var tup: (f32, f64) = (a, b)
    var nul? = maybe(b)
    io::println(f"parts {arr[1]} {st.x} {st.y} {tup.0} {tup.1} {nul ?? 0.0}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      sweep 0 0
// CHECK-NEXT: limits 448 true
// CHECK-NEXT: inf true true true true
// CHECK-NEXT: nan true true true true
// CHECK-NEXT: assign 1.5 args 1.5 3 returns 3 1.5
// CHECK-NEXT: arith 3.5 0.5 0.375 0.75 3.25
// CHECK-NEXT: compare true false true true true
// CHECK-NEXT: order true true
// CHECK-NEXT: compound 3.5 -2.75
// CHECK-NEXT: arms 1.5 3 1.5
// CHECK-NEXT: parts 1.5 1.5 3 1.5 3 3
