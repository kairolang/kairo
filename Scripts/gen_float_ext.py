"""Generates the float methods: one `extend` per native float type, the same
method set `extend f256` / `extend f512` have (Scripts/gen_softfloat.py).

  Lib/builtin/num/float_ext.k   f16, bf16, f32, f64, f80; re-exported by the
                                builtin root, so every program has them
                                (small: clang builtins, no engine);
  Lib/builtin/num/f128_ext.k    f128, whose sqrt and fma run the softfloat
                                engine at 128 bits, so the file is loaded
                                only for files that spell `f128`, as
                                f256_t.k is (Preprocessor::_add_wide_floats).

Each method is one line of C++ in the end: a clang builtin (`__builtin_sqrtf`,
`__builtin_fmal`, ...), a type-generic one through Lib/rt/intrinsics.h's
`kairo_rt_fp_*` templates (Kairo cannot call a builtin clang type-checks per
call, R057E), or `__builtin_bitcast`.

usage: python3 Scripts/gen_float_ext.py [--check]
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NUM = os.path.join(ROOT, 'Lib', 'builtin', 'num')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_softfloat import kfmt  # noqa: E402  (the repo's kfmt invocation)

# The guards: where clang (and Sema) give the type. The same conditions as
# Lib/builtin/fmt/fmt_buf.k's put_* and the f256 / f512 classes.
G_F16 = 'defined!(__FLT16_MAX__)'
G_BF16 = ('defined!(__x86_64__) || defined!(__i386__) || defined!(__aarch64__) || defined!(__arm__)'
          '\n     || defined!(__riscv) || defined!(__loongarch__) || defined!(__wasm__)')
G_F80 = '(defined!(__x86_64__) || defined!(__i386__)) && !defined!(_MSC_VER) && !defined!(__ANDROID__)'
G_F128 = 'defined!(__SIZEOF_FLOAT128__) || defined!(__wasm__)'

# name: (bits type, guard, sqrt body, fma body, to_bits body, guard comment)
TYPES = {
    'f16': dict(
        u='u16', guard=G_F16,
        why='clang defines __FLT16_MAX__ exactly where _Float16 exists.',
        sqrt='return __builtin_sqrtf(self) as f16',
        fma='return float_ext_fma_odd_(self, b, c) as f16',
        bits='return __builtin_bitcast<u16, f16>(self)',
        sqrt_doc='computed in f32 and rounded back: correctly rounded, as 24 >= 2 * 11 + 2',
        fma_doc='the exact sum rounded to odd at f32, then to nearest (float_ext_fma_odd_)',
    ),
    'bf16': dict(
        u='u16', guard=G_BF16,
        why=('bf16 where clang gives __bf16 arithmetic: x86 (SSE2), Arm, AArch64,\n'
             '// RISC-V, LoongArch, WebAssembly (fmt_buf.k\'s put_bf16 has the same list).'),
        sqrt='return __builtin_sqrtf(self) as bf16',
        fma='return float_ext_fma_odd_(self, b, c) as bf16',
        bits='return __builtin_bitcast<u16, bf16>(self)',
        sqrt_doc='computed in f32 and rounded back: correctly rounded, as 24 >= 2 * 8 + 2',
        fma_doc='the exact sum rounded to odd at f32, then to nearest (float_ext_fma_odd_)',
    ),
    'f32': dict(
        u='u32', guard=None, why=None,
        sqrt='return __builtin_sqrtf(self)',
        fma='return __builtin_fmaf(self, b, c)',
        bits='return __builtin_bitcast<u32, f32>(self)',
        sqrt_doc='correctly rounded: `__builtin_sqrtf`',
        fma_doc='`__builtin_fmaf`: the instruction, or libm\'s fmaf',
    ),
    'f64': dict(
        u='u64', guard=None, why=None,
        sqrt='return __builtin_sqrt(self)',
        fma='return __builtin_fma(self, b, c)',
        bits='return __builtin_bitcast<u64, f64>(self)',
        sqrt_doc='correctly rounded: `__builtin_sqrt`',
        fma_doc='`__builtin_fma`: the instruction, or libm\'s fma',
    ),
    'f80': dict(
        u='u128', guard=G_F80,
        why=('f80 is x87 extended, so x86 only, and not where long double is\n'
             '// binary64 (MSVC) or binary128 (Android x86_64): TypeResolve\'s f80 gate.'),
        sqrt='return __builtin_sqrtl(self)',
        fma='return __builtin_fmal(self, b, c)',
        bits=None,  # the 10 bytes, below
        sqrt_doc='`__builtin_sqrtl`, x87 `fsqrt`: correctly rounded at 64-bit precision control',
        fma_doc='`__builtin_fmal`: libm\'s fmal, as exact as it is',
    ),
    'f128': dict(
        u='u128', guard=G_F128,
        why=('__SIZEOF_FLOAT128__ marks __float128; wasm32 has the type (its long\n'
             '// double is binary128) without the macro.'),
        sqrt='return float_ext_soft_(SF_OP_SQRT, self, self, self)',
        fma='return float_ext_soft_(SF_OP_FMA, self, b, c)',
        bits='return __builtin_bitcast<u128, f128>(self)',
        sqrt_doc='correctly rounded: the softfloat engine at 128 bits',
        fma_doc='the softfloat engine at 128 bits',
    ),
}

F80_BITS = '''var v = self
        var r: u128 = 0
        unsafe {
            // x87 targets are little-endian: the significand, then the sign
            // and exponent in bytes 8 and 9; the rest is padding.
            var unsafe *p = (&v) as unsafe *const u8
            for var i: i32 = 0; i < 10; ++i {
                r = r | ((p[i] as u128) << ((8 * i) as u128))
            }
        }

        return r'''


def bits_doc(t, u):
    if t == 'f80':
        return ('The 80-bit x87 encoding in the low bits of a u128: bit 79 the sign, bits 78-64 the\n'
                '    /// exponent, bit 63 the explicit integer bit. The bits above 79 are 0.')
    n = {'u16': 15, 'u32': 31, 'u64': 63, 'u128': 127}[u]
    return f'The encoding (bit {n} the sign).'


def extend_block(t, d, indent):
    u = d['u']
    bits = d['bits'] if d['bits'] else F80_BITS
    nan_note = ''
    if t == 'f128':
        nan_note = '\n    /// A NaN result is the canonical quiet NaN.'
    else:
        nan_note = '\n    /// A NaN result is the one the hardware or libm gives.'
    body = f'''extend {t} {{
    /// {bits_doc(t, u)}
    pub inline fn to_bits(const self) -> {u} {{
        {bits}
    }}

    /// The square root; sqrt(-0) is -0, other negatives NaN.
    ///
    /// {d['sqrt_doc'][0].upper() + d['sqrt_doc'][1:]}.{nan_note}
    pub inline fn sqrt(const self) -> {t} {{
        {d['sqrt']}
    }}

    /// self * b + c, rounded once.
    ///
    /// {d['fma_doc'][0].upper() + d['fma_doc'][1:]}.
    pub inline fn fma(const self, b: {t}, c: {t}) -> {t} {{
        {d['fma']}
    }}

    /// |self|: the sign bit cleared.
    pub inline fn abs(const self) -> {t} {{
        return kairo_rt_fp_abs(self)
    }}

    /// self's magnitude with s's sign.
    pub inline fn copysign(const self, s: {t}) -> {t} {{
        return kairo_rt_fp_copysign(self, s)
    }}

    /// Whether either is a NaN (IEEE's unordered predicate).
    pub inline fn is_unordered(const self, o: {t}) -> bool {{
        return kairo_rt_fp_isunordered(self, o)
    }}

    /// Whether self is a NaN.
    pub inline fn is_nan(const self) -> bool {{
        return kairo_rt_fp_isnan(self)
    }}

    /// Whether self is an infinity.
    pub inline fn is_infinite(const self) -> bool {{
        return kairo_rt_fp_isinf(self)
    }}

    /// Whether self is neither infinite nor NaN.
    pub inline fn is_finite(const self) -> bool {{
        return kairo_rt_fp_isfinite(self)
    }}

    /// Whether self is +0 or -0.
    pub inline fn is_zero(const self) -> bool {{
        return kairo_rt_fp_class(self) == 4
    }}

    /// Whether self is subnormal (nonzero, below the smallest normal).
    pub inline fn is_subnormal(const self) -> bool {{
        return kairo_rt_fp_class(self) == 3
    }}

    /// Whether self is normal (finite, nonzero, not subnormal).
    pub inline fn is_normal(const self) -> bool {{
        return kairo_rt_fp_isnormal(self)
    }}

    /// Whether the sign bit is set (-0.0 and negative NaNs included).
    pub inline fn is_sign_negative(const self) -> bool {{
        return kairo_rt_fp_signbit(self)
    }}
}}'''
    if d['guard'] is None:
        return body
    lines = body.split('\n')
    inner = '\n'.join(('    ' + l) if l else l for l in lines)
    return f'// {d["why"]}\neval if {d["guard"]} {{\n{inner}\n}}'


HEADER = '''@BANNER@
///
///   \\brief @BRIEF@
///
///   \\detail
@DETAIL@
///
///     Generated by Scripts/gen_float_ext.py; change the generator, not this
///     file (`--check` says whether it is current).
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
'''


def header(name, brief, detail):
    # The banner is 80 columns, the dashes padding out the path.
    left, right = '/// --- The Kairo Project ', f' Lib/builtin/num/{name} --- ///'
    banner = left + '-' * (80 - len(left) - len(right)) + right
    return HEADER.replace('@BANNER@', banner).replace('@BRIEF@', brief).replace('@DETAIL@', detail)


FMA_ODD = '''/// a * b + c for f16 / bf16 operands (widened, exactly, to f64), rounded to
/// odd at f32 precision, which the caller rounds to nearest at its own.
///
/// One rounding, not two: rounding the exact sum to nearest at f32 and then
/// again at 11 or 8 bits can land on the wrong side of a midpoint. Rounding
/// to odd keeps "it was inexact" in the last bit, and with two or more spare
/// bits (24 >= 11 + 2) the second rounding to nearest is then the correctly
/// rounded result (Boldo and Melquiond, "Emulation of FMA and correctly
/// rounded sums: proved algorithms using rounding to odd", 2008). The steps:
///   - p = a * b is exact: at most 22 significant bits, and the exponents
///     of f16 / bf16 are far inside f64's range;
///   - s + lo = p + c exactly (Knuth's TwoSum), s rounded to nearest; when
///     lo is nonzero and s even, s moves one ulp toward lo: odd at 53 bits;
///   - f = s rounded to f32, moved the same way when inexact and even: odd
///     at 24 bits (rounding to odd twice is rounding to odd once). f32
///     shares bf16's exponent range and has 16 more bits at every
///     magnitude, subnormals included, so the margin holds everywhere.
/// A NaN or infinite operand makes s non-finite, and both adjustments are
/// skipped: the result is what IEEE says for those.
priv inline fn float_ext_fma_odd_(a: f64, b: f64, c: f64) -> f32 {
    var p = a * b
    var s = p + c
    if kairo_rt_fp_isfinite(s) {
        var bb = s - p
        var lo = (p - (s - bb)) + (c - bb)
        if lo != 0.0 {
            var sb = __builtin_bitcast<u64, f64>(s)
            if (sb & 1) == 0 {
                // s != 0 here: a sum that rounds to zero is exact.
                if (lo > 0.0) == (s > 0.0) {
                    sb = sb + 1
                } else {
                    sb = sb - 1
                }

                s = __builtin_bitcast<f64, u64>(sb)
            }
        }
    }

    var f = s as f32
    if kairo_rt_fp_isfinite(f) && (f as f64) != s {
        var fb = __builtin_bitcast<u32, f32>(f)
        if (fb & 1) == 0 {
            if kairo_rt_fp_abs(s) > (kairo_rt_fp_abs(f) as f64) {
                fb = fb + 1
            } else {
                fb = fb - 1
            }

            f = __builtin_bitcast<f32, u32>(fb)
        }
    }

    return f
}'''

SF128 = '''/// Operation `which` (SF_OP_SQRT, SF_OP_FMA) on binary128 encodings, through the
/// softfloat engine at 128 bits, the width at which it is checked bit for
/// bit against the native f128 (Tests/Codegen/softfloat_native.k). Not
/// libm: x86_64 and i686 musl have no sqrtf128 / fmaf128, and LLVM then
/// calls sqrtl / fmal, the x87 functions, on the binary128 bits.
priv inline fn float_ext_soft_(which: i32, a: f128, b: f128, c: f128) -> f128 {
    var r = sf_op(
        sf_fmt(128, 15),
        which,
        __builtin_bitcast<u128, f128>(a) as u512,
        __builtin_bitcast<u128, f128>(b) as u512,
        __builtin_bitcast<u128, f128>(c) as u512,
    )
    return __builtin_bitcast<f128, u128>(r as u128)
}'''


def gen_eager():
    detail = '''///     `extend` blocks giving f16, bf16, f32, f64 and f80 the methods f256
///     and f512 have (num/f256_t.k): to_bits, sqrt, fma, abs, copysign,
///     is_unordered, is_nan, is_infinite, is_finite, is_zero, is_subnormal,
///     is_normal and is_sign_negative, with the same meaning. f128's are in
///     num/f128_ext.k, loaded only where `f128` is spelled.
///
///     Each type's block exists where the type does (the `eval if` guards,
///     as fmt/fmt_buf.k's put_*). The bodies are clang builtins: sqrt and
///     fma by type (`__builtin_sqrtf`, `__builtin_fmal`, ...), the rest
///     through the type-generic `kairo_rt_fp_*` templates in
///     rt/intrinsics.h (`__builtin_isnan`, `__builtin_fpclassify`,
///     `__builtin_signbit`, `__builtin_elementwise_abs` / `_copysign`),
///     to_bits `__builtin_bitcast`. f16 and bf16 compute sqrt in f32 and
///     fma in f64 / f32, rounded once (float_ext_fma_odd_).
///
///     Every result is correctly rounded where the C library's is: f32 /
///     f64 fma without the instruction, and f80 fma, are libm's fmaf / fma
///     / fmal (glibc's and musl's are; checked on x86_64 and i686), and f80
///     sqrt is x87 `fsqrt`, exact at the default 64-bit precision control
///     (a CRT that sets 53 bits rounds it at f64 precision). NaN results
///     are the hardware's (payloads may propagate), not the canonical NaN
///     f256 gives.'''
    parts = [header('float_ext.k', 'The methods of the native float types: `extend f16` .. `extend f80`.',
                    detail)]
    parts.append('ffi "c++" import "rt/intrinsics.h"\n\nimport base::intrinsics::*\n')
    parts.append(FMA_ODD + '\n')
    for t in ('f16', 'bf16', 'f32', 'f64', 'f80'):
        parts.append(extend_block(t, TYPES[t], ''))
        parts.append('')
    return '\n'.join(parts).rstrip('\n') + '\n'


def gen_f128():
    detail = '''///     `extend f128`: the methods every float has (num/float_ext.k has the
///     others). abs, copysign and the is_* checks are clang builtins
///     through rt/intrinsics.h's `kairo_rt_fp_*`; sqrt and fma are the
///     softfloat engine (num/softfloat.k) at 128 bits, correctly rounded on
///     every target (float_ext_soft_ says why not libm), with the engine's
///     canonical quiet NaN for a NaN result.
///
///     The engine is a large file, so this one is not re-exported by the
///     builtin root: the compiler imports it into the files that spell
///     `f128` (Preprocessor::_add_wide_floats, as num/f256_t.k for
///     `f256`). A file that only receives an f128 from elsewhere and never
///     names the type has no methods on it; spelling the type anywhere in
///     the file (`var x: f128 = ...`) brings them in.'''
    parts = [header('f128_ext.k', 'The methods of `f128`: `extend f128`.', detail)]
    parts.append('ffi "c++" import "rt/intrinsics.h"\n\nimport base::intrinsics::*\nimport num::softfloat::*\n')
    # The helper sits inside the guard with the block: it names f128.
    d = TYPES['f128']
    lines = (SF128 + '\n\n' + extend_block('f128', dict(d, guard=None), '')).split('\n')
    inner = '\n'.join(('    ' + l) if l else l for l in lines)
    parts.append(f'// {d["why"]}\neval if {d["guard"]} {{\n{inner}\n}}')
    return '\n'.join(parts).rstrip('\n') + '\n'


def main():
    check = '--check' in sys.argv
    outs = {
        os.path.join(NUM, 'float_ext.k'): gen_eager(),
        os.path.join(NUM, 'f128_ext.k'): gen_f128(),
    }
    outs = {p: kfmt(s, os.path.basename(p)) for p, s in outs.items()}
    stale = []
    for p, s in outs.items():
        old = open(p).read() if os.path.exists(p) else None
        if old != s:
            stale.append(p)
            if not check:
                open(p, 'w').write(s)
    if check and stale:
        print('stale:', *stale)
        sys.exit(1)


if __name__ == '__main__':
    main()
