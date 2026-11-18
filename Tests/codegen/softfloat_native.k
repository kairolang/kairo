// The software float engine behind f256 / f512 (num/softfloat.k) has no
// width of its own: instantiated at binary32, binary64 and binary128 it must
// agree bit for bit with the hardware (and compiler-rt's f128) on add, sub,
// mul, div and the comparisons, and on f64 <-> f32 conversion. A NaN result
// matches any NaN (the engine's NaN is canonical, hardware payloads vary).
// Operands are raw random encodings half the time and structured (exponents
// near each other, near the ends of the range, subnormals) the other half.

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

/// A random encoding of `nbits` total and `ebits` exponent bits.
fn gen_(r: *Rng, nbits: u32, ebits: u32) -> u512 {
    var lo        = next_(r) as u512
    var hi        = next_(r) as u512
    var v         = hi << 64 | lo
    var one: u512 = 1
    v = v & (one << nbits) - 1
    if (next_(r) & 1) == 0 {
        return v
    }

    var mb         = nbits - 1 - ebits
    var emask      = (one << ebits) - 1
    var k          = next_(r) % 6
    var e:    u512 = 0
    if k == 0 {
        e = 0
    } else if k == 1 {
        e = 1 + ((next_(r) % 3) as u512)
    } else if k == 2 {
        e = emask - 1 - ((next_(r) % 3) as u512)
    } else {
        e = (emask >> 1) - 20 + ((next_(r) % 40) as u512)
    }

    var s = v & one << nbits - 1
    return s | e << mb | v & (one << mb) - 1
}

fn nan64_(b: u64) -> bool {
    return (b & 0x7FFFFFFFFFFFFFFF) > 0x7FF0000000000000
}

fn nan32_(b: u32) -> bool {
    return (b & 0x7FFFFFFF) > 0x7F800000
}

fn same64_(a: u64, b: u64) -> bool {
    return a == b || nan64_(a) && nan64_(b)
}

fn same32_(a: u32, b: u32) -> bool {
    return a == b || nan32_(a) && nan32_(b)
}

fn main() -> i32 {
    var r        = Rng { s: 0x2545F4914F6CDD1D }
    var f64f     = sf_fmt(64, 11)
    var f32f     = sf_fmt(32, 8)
    var bad: i32 = 0
    var n:   i32 = 20000
    for var i: i32 = 0; i < n; ++i {
        var a = gen_(&r, 64, 11) as u64
        var b = gen_(&r, 64, 11) as u64
        var x = __builtin_bitcast<f64, u64>(a)
        var y = __builtin_bitcast<f64, u64>(b)
        if !same64_(
            sf_op(f64f, SF_OP_ADD, a as u512, b as u512, 0) as u64,
            __builtin_bitcast<u64, f64>(x + y),
        ) {
            bad += 1
        }

        if !same64_(
            sf_op(f64f, SF_OP_SUB, a as u512, b as u512, 0) as u64,
            __builtin_bitcast<u64, f64>(x - y),
        ) {
            bad += 1
        }

        if !same64_(
            sf_op(f64f, SF_OP_MUL, a as u512, b as u512, 0) as u64,
            __builtin_bitcast<u64, f64>(x * y),
        ) {
            bad += 1
        }

        if !same64_(
            sf_op(f64f, SF_OP_DIV, a as u512, b as u512, 0) as u64,
            __builtin_bitcast<u64, f64>(x / y),
        ) {
            bad += 1
        }

        var c         = sf_cmp_bits(f64f, a as u512, b as u512)
        var want: i32 = 2
        if x < y {
            want = -1
        } else if x == y {
            want = 0
        } else if x > y {
            want = 1
        }

        if c != want {
            bad += 1
        }

        if !same32_(sf_cvt(f32f, f64f, a as u512) as u32, __builtin_bitcast<u32, f32>(x as f32)) {
            bad += 1
        }

        var a32 = gen_(&r, 32, 8) as u32
        var b32 = gen_(&r, 32, 8) as u32
        var p   = __builtin_bitcast<f32, u32>(a32)
        var q   = __builtin_bitcast<f32, u32>(b32)
        if !same32_(
            sf_op(f32f, SF_OP_ADD, a32 as u512, b32 as u512, 0) as u32,
            __builtin_bitcast<u32, f32>(p + q),
        ) {
            bad += 1
        }

        if !same32_(
            sf_op(f32f, SF_OP_MUL, a32 as u512, b32 as u512, 0) as u32,
            __builtin_bitcast<u32, f32>(p * q),
        ) {
            bad += 1
        }

        if !same32_(
            sf_op(f32f, SF_OP_DIV, a32 as u512, b32 as u512, 0) as u32,
            __builtin_bitcast<u32, f32>(p / q),
        ) {
            bad += 1
        }

        if !same64_(sf_cvt(f64f, f32f, a32 as u512) as u64, __builtin_bitcast<u64, f64>(p as f64)) {
            bad += 1
        }
    }

    io::println(f"binary32/64: {n} rounds, {bad} mismatches")
    var bad128: i32 = 0
    eval if defined!(__SIZEOF_FLOAT128__) {
        var f128f = sf_fmt(128, 15)
        for var i: i32 = 0; i < n; ++i {
            var a             = gen_(&r, 128, 15) as u128
            var b             = gen_(&r, 128, 15) as u128
            var x             = __builtin_bitcast<f128, u128>(a)
            var y             = __builtin_bitcast<f128, u128>(b)
            var nanmask: u128 = 0x7FFF0000000000000000000000000000
            var ops: [u128; 4] = [
                __builtin_bitcast<u128, f128>(x + y),
                __builtin_bitcast<u128, f128>(x - y),
                __builtin_bitcast<u128, f128>(x * y),
                __builtin_bitcast<u128, f128>(x / y),
            ]

            for var k: i32 = 0; k < 4; ++k {
                var got = sf_op(f128f, k, a as u512, b as u512, 0) as u128
                var w   = ops[k]
                var gn  = (got & nanmask) == nanmask && got << 16 != 0
                var wn  = (w & nanmask) == nanmask && w << 16 != 0
                if got != w && !(gn && wn) {
                    bad128 += 1
                }
            }
        }

        io::println(f"binary128: {n} rounds, {bad128} mismatches")
    } else {
        io::println("binary128: skipped (no __float128 on this target)")
    }

    return bad + bad128
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: binary32/64: 20000 rounds, 0 mismatches
// CHECK: binary128: {{20000 rounds, 0 mismatches|skipped}}
