// f16 and bf16 sqrt and fma compute in f32 / f64 (num/float_ext.k), so they
// are checked bit for bit against an independent implementation: the
// softfloat engine (num/softfloat.k) at 16 bits, which is itself checked
// against the native f32 / f64 / f128 (Codegen/softfloat_native.k). 200000
// operand triples per type from a fixed xorshift stream, a quarter of them
// drawn from the special encodings (zeros, infinities, NaNs, the smallest
// subnormal and normal, MAX, values near 1). A NaN matches any NaN: the
// engine gives the canonical one, the hardware may keep a payload.
//
// `naive` counts the fma results that differ from rounding the f32 fma back
// to 16 bits (two roundings): it must be nonzero, or the stream never
// reaches the double-rounding cases the round-to-odd step exists for.

import builtin::num::softfloat::*
import std::io

struct Rng {
    var s: u64 = 0
}

fn next_(r: *Rng) -> u64 {
    var x = r->s
    x    = x ^ x >> 12
    x    = x ^ x << 25
    x    = x ^ x >> 27
    r->s = x
    return x * 2685821657736338717
}

// An operand: a special encoding a quarter of the time, else random bits.
// `ebits` picks the specials' layout (5: f16, 8: bf16).
fn operand_(r: *Rng, ebits: i32) -> u16 {
    var x = next_(r)
    if (x & 3) != 0 {
        return (x >> 16) as u16
    }

    var sign = (x >> 8 & 1) as u16 << 15
    var k    = ((x >> 9) % 8) as i32
    var m    = 15 - ebits
    var inf  = ((1 << ebits) - 1) as u16 << (m as u16)
    var one  = ((1 << ebits - 1) - 1) as u16 << (m as u16)
    if k == 0 {
        return sign
    } else if k == 1 {
        return sign | inf
    } else if k == 2 {
        return sign | inf | (x >> 20) as u16 & (1 << (m as u16)) - 1 | 1
    } else if k == 3 {
        return sign | 1
    } else if k == 4 {
        return sign | 1 << (m as u16)
    } else if k == 5 {
        return sign | inf - 1
    }

    // Near 1 (k 6, 7): the products and sums that cancel or sit on a tie.
    return sign | one + ((x >> 24) as u16 & 15) - 8
}

fn is_nan16_(b: u16, ebits: i32) -> bool {
    var m   = 15 - ebits
    var inf = ((1 << ebits) - 1) as u16 << (m as u16)
    return (b & 0x7fff) > inf
}

fn same_(a: u16, b: u16, ebits: i32) -> bool {
    if is_nan16_(a, ebits) || is_nan16_(b, ebits) {
        return is_nan16_(a, ebits) && is_nan16_(b, ebits)
    }

    return a == b
}

fn run_f16() {
    var r   = Rng { s: 0x9e3779b97f4a7c15 }
    var f   = sf_fmt(16, 5)
    var bad = 0
    var nv  = 0
    for var i: i32 = 0; i < 200000; ++i {
        var a  = operand_(&r, 5)
        var b  = operand_(&r, 5)
        var c  = operand_(&r, 5)
        var x  = __builtin_bitcast<f16, u16>(a)
        var y  = __builtin_bitcast<f16, u16>(b)
        var z  = __builtin_bitcast<f16, u16>(c)
        var gf = x.fma(y, z).to_bits()
        var wf = sf_op(f, SF_OP_FMA, a as u512, b as u512, c as u512) as u16
        var gs = x.sqrt().to_bits()
        var ws = sf_op(f, SF_OP_SQRT, a as u512, 0, 0) as u16
        if !same_(gf, wf, 5) || !same_(gs, ws, 5) {
            if bad < 5 {
                io::println(
                    f"f16 mismatch {a:x} {b:x} {c:x}: fma {gf:x} want {wf:x}, sqrt {gs:x} want {ws:x}",
                )
            }

            bad += 1
        }

        var two = ((x as f32).fma(y as f32, z as f32) as f16).to_bits()
        if !same_(two, wf, 5) {
            nv += 1
        }
    }

    io::println(f"f16 mismatches {bad} naive {nv > 0}")
}

fn run_bf16() {
    var r   = Rng { s: 0x2545f4914f6cdd1d }
    var f   = sf_fmt(16, 8)
    var bad = 0
    var nv  = 0
    for var i: i32 = 0; i < 200000; ++i {
        var a  = operand_(&r, 8)
        var b  = operand_(&r, 8)
        var c  = operand_(&r, 8)
        var x  = __builtin_bitcast<bf16, u16>(a)
        var y  = __builtin_bitcast<bf16, u16>(b)
        var z  = __builtin_bitcast<bf16, u16>(c)
        var gf = x.fma(y, z).to_bits()
        var wf = sf_op(f, SF_OP_FMA, a as u512, b as u512, c as u512) as u16
        var gs = x.sqrt().to_bits()
        var ws = sf_op(f, SF_OP_SQRT, a as u512, 0, 0) as u16
        if !same_(gf, wf, 8) || !same_(gs, ws, 8) {
            if bad < 5 {
                io::println(
                    f"bf16 mismatch {a:x} {b:x} {c:x}: fma {gf:x} want {wf:x}, sqrt {gs:x} want {ws:x}",
                )
            }

            bad += 1
        }

        var two = ((x as f32).fma(y as f32, z as f32) as bf16).to_bits()
        if !same_(two, wf, 8) {
            nv += 1
        }
    }

    io::println(f"bf16 mismatches {bad} naive {nv > 0}")
}

fn main() -> i32 {
    run_f16()
    run_bf16()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: f16 mismatches 0 naive true
// CHECK: bf16 mismatches 0 naive true
