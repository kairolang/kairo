"""Generates ../methods.k: the float-method checks and their expected
encodings, computed exactly here (fractions.Fraction, round to nearest even)
for f16, bf16, f32, f64, f80 (x87, explicit integer bit) and f128. The
output is formatted with kfmt, as Scripts/gen_softfloat.py does.

usage: python3 Tests/Codegen/FloatMethods/Inputs/gen_methods.py
"""
import math
import os
import sys
from fractions import Fraction as F

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(ROOT, 'Scripts'))
from gen_softfloat import kfmt  # noqa: E402


class o:  # the oracle, as a namespace
    pass

# name: (ebits, mbits(stored), explicit int bit)
FMT = {'f16': (5, 10, False), 'bf16': (8, 7, False), 'f32': (8, 23, False), 'f64': (11, 52, False),
       'f80': (15, 63, True), 'f128': (15, 112, False)}

def enc(name, x):
    e, m, xp = FMT[name]
    bias = (1 << (e - 1)) - 1
    p = m + 1
    s = 0
    if x < 0: s, x = 1, -x
    if x == 0: return s << (e + m + (1 if xp else 0))
    ex = x.numerator.bit_length() - x.denominator.bit_length()
    while F(2) ** ex > x: ex -= 1
    while F(2) ** (ex + 1) <= x: ex += 1
    emin = 1 - bias
    q = max(ex, emin) - (p - 1)  # quantum exponent
    v = x / F(2) ** q
    n = v.numerator // v.denominator
    r = v - n
    if r > F(1, 2) or (r == F(1, 2) and n % 2 == 1): n += 1
    if n >= (1 << p): n >>= 1; q += 1  # carry (exact since n even)
    if n < (1 << (p - 1)):  # subnormal
        be = 0
    else:
        be = q + (p - 1) + bias
    if be >= (1 << e) - 1: raise Exception('overflow')
    frac = n & ((1 << m) - 1)
    if xp:
        return (s << 79) | (be << 64) | n
    return (s << (e + m)) | (be << m) | frac

def sqrt_rn(name, a):
    e, m, xp = FMT[name]
    # sqrt(a) to 600 bits, then half a unit more: a's root is irrational
    # here, so the true value lies strictly inside, never on a tie.
    K = 600
    num = a.numerator << (2 * K); den = a.denominator
    r = math.isqrt(num // den)
    return enc(name, F(r, 1 << K) + F(1, 1 << (K + 1)))  # nudge: irrational, between r and r+1


o.FMT, o.enc, o.sqrt_rn = FMT, enc, sqrt_rn

U = {'f16': 'u16', 'bf16': 'u16', 'f32': 'u32', 'f64': 'u64', 'f80': 'u128', 'f128': 'u128'}
WIDE = {'f80', 'f128'}

def hx(t, v):
    if t in WIDE:
        return f'{v >> 64:x}:{v & ((1 << 64) - 1):x}'
    return f'{v:x}'

def fmt_bits(t, expr):
    if t in WIDE:
        return f'{{h_({expr})}}'
    return f'{{{expr}:x}}'

def special(t):
    e, m, xp = o.FMT[t]
    tot = e + m + 1 + (1 if xp else 0)
    sgn = 1 << (tot - 1)
    if xp:
        mx = ((1 << e) - 2) << 64 | ((1 << 64) - 1)
        inf = ((1 << e) - 1) << 64 | (1 << 63)
        nan = ((1 << e) - 1) << 64 | (3 << 62)
    else:
        mx = (((1 << e) - 2) << m) | ((1 << m) - 1)
        inf = ((1 << e) - 1) << m
        nan = inf | (1 << (m - 1))
    return sgn, mx, inf, nan

out_k = []
checks = []
for t in ['f16', 'bf16', 'f32', 'f64', 'f80', 'f128']:
    pfx = 'X87' if t == 'f80' else 'CHECK'
    sgn, mx, inf, nan = special(t)
    four = o.enc(t, F(4)); m225 = o.enc(t, F(-9, 4)); p225 = o.enc(t, F(9, 4))
    s2 = o.sqrt_rn(t, F(2)); s15 = o.enc(t, F(3, 2))
    p = o.FMT[t][1] + 1
    u = F(1, 2 ** (p - 1))
    fm = o.enc(t, (1 + u) * (1 - u) - 1)
    ten = o.enc(t, F(10))
    two = o.enc(t, F(2))
    body = f'''
fn run_{t}() {{
    var z:    {t} = 0.0
    var nz         = -z
    var one:  {t} = 1.0
    var two:  {t} = 2.0
    var four: {t} = 4.0
    var a:    {t} = 2.25
    var na         = -a
    var inf        = {t}::INFINITY
    var nan        = {t}::NAN
    io::println(f"{t} bits {fmt_bits(t, 'four.to_bits()')} {fmt_bits(t, 'nz.to_bits()')} {fmt_bits(t, t + '::MAX.to_bits()')} {fmt_bits(t, t + '::MIN_SUBNORMAL.to_bits()')} {fmt_bits(t, t + '::INFINITY.to_bits()')} {fmt_bits(t, t + '::NEG_INFINITY.to_bits()')} {fmt_bits(t, t + '::NAN.to_bits()')}")
    io::println(f"{t} sqrt {fmt_bits(t, 'two.sqrt().to_bits()')} {fmt_bits(t, 'a.sqrt().to_bits()')} {fmt_bits(t, 'nz.sqrt().to_bits()')} {fmt_bits(t, 'z.sqrt().to_bits()')} {fmt_bits(t, 'inf.sqrt().to_bits()')} {{b_(na.sqrt().is_nan())}}{{b_(nan.sqrt().is_nan())}}{{b_((-inf).sqrt().is_nan())}}")
    var e   = {t}::EPSILON
    var hi  = one + e
    var lo  = one - e
    var mo  = -one
    io::println(f"{t} fma {fmt_bits(t, 'hi.fma(lo, mo).to_bits()')} {fmt_bits(t, 'two.fma(four, two).to_bits()')} {{b_(inf.fma(z, one).is_nan())}}{{b_(nan.fma(one, one).is_nan())}}{{b_(inf.fma(one, -inf).is_nan())}} {fmt_bits(t, 'inf.fma(two, one).to_bits()')} {fmt_bits(t, 'nz.fma(one, nz).to_bits()')}")
    io::println(f"{t} abs {fmt_bits(t, 'na.abs().to_bits()')} {fmt_bits(t, 'nz.abs().to_bits()')} {fmt_bits(t, '(-inf).abs().to_bits()')} {fmt_bits(t, 'a.copysign(nz).to_bits()')} {fmt_bits(t, 'na.copysign(one).to_bits()')} {{b_(nan.copysign(mo).is_sign_negative())}}{{b_(nan.copysign(mo).abs().is_sign_negative())}}{{b_(nan.copysign(mo).is_nan())}}")
    var nn = nan.copysign(mo)
    cls_{t}("0", z)
    cls_{t}("-0", nz)
    cls_{t}("4", four)
    cls_{t}("-2.25", na)
    cls_{t}("sub", {t}::MIN_SUBNORMAL)
    cls_{t}("-sub", -{t}::MIN_SUBNORMAL)
    cls_{t}("minpos", {t}::MIN_POSITIVE)
    cls_{t}("max", {t}::MAX)
    cls_{t}("inf", inf)
    cls_{t}("-inf", -inf)
    cls_{t}("nan", nan)
    cls_{t}("-nan", nn)
    io::println(f"{t} unord {{b_(nan.is_unordered(one))}}{{b_(one.is_unordered(nan))}}{{b_(nan.is_unordered(nan))}}{{b_(one.is_unordered(two))}}{{b_(inf.is_unordered(-inf))}}")
    // P754: a limit at the head of a method chain.
    io::println(f"{t} chain {{b_({t}::NAN.is_nan())}}{{b_({t}::MAX.is_finite())}}{{b_({t}::INFINITY.is_infinite())}}{{b_({t}::MIN_SUBNORMAL.is_subnormal())}}{{b_({t}::MIN.is_sign_negative())}}{{b_({t}::MAX.abs().is_normal())}}")
}}

fn cls_{t}(const name: string, v: {t}) {{
    io::println(f"{t} cls {{name}} {{b_(v.is_nan())}}{{b_(v.is_infinite())}}{{b_(v.is_finite())}}{{b_(v.is_zero())}}{{b_(v.is_subnormal())}}{{b_(v.is_normal())}}{{b_(v.is_sign_negative())}}")
}}
'''
    if t == 'f80':
        # No f80 limits here: PrimitiveLimitDesugar runs before eval-if
        # folding, so `f80::MAX` is P003E on aarch64 even inside the guard
        # (P760). The values are built exactly instead.
        body = body.replace('    var z:    f80 = 0.0', '''    var L_EPS = f80_pow2_(-63)
    var L_MINPOS = f80_pow2_(-16382)
    var L_SUB = f80_pow2_(-16445)
    var L_MAX = (2.0 - L_EPS) * f80_pow2_(16383)
    var L_INF = f64::INFINITY as f80
    var L_NAN = f64::NAN as f80
    var z:    f80 = 0.0''', 1)
        for a, b in [('f80::MIN_SUBNORMAL', 'L_SUB'), ('f80::MIN_POSITIVE', 'L_MINPOS'), ('f80::MAX', 'L_MAX'),
                     ('f80::NEG_INFINITY', '(-L_INF)'), ('f80::INFINITY', 'L_INF'), ('f80::NAN', 'L_NAN'),
                     ('f80::EPSILON', 'L_EPS')]:
            body = body.replace(a, b)
        body = '\n'.join(l for l in body.split('\n') if 'chain' not in l and 'P754' not in l)
        body = body.replace('fn run_f80() {', '''fn f80_pow2_(k: i32) -> f80 {
    var r: f80 = 1.0
    var i      = k
    while i > 0 {
        r = r * 2.0
        i -= 1
    }

    while i < 0 {
        r = r * 0.5
        i += 1
    }

    return r
}

fn run_f80() {''', 1)
        body = 'eval if defined!(__x86_64__) || defined!(__i386__) {' + '\n'.join(('    ' + l) if l else l for l in body.split('\n')) + '}\n'
    out_k.append(body)
    c = []
    c.append(f'{t} bits {hx(t, four)} {hx(t, sgn)} {hx(t, mx)} {hx(t, 1)} {hx(t, inf)} {hx(t, sgn | inf)} {hx(t, nan)}')
    c.append(f'{t} sqrt {hx(t, s2)} {hx(t, s15)} {hx(t, sgn)} {hx(t, 0)} {hx(t, inf)} 111')
    c.append(f'{t} fma {hx(t, fm)} {hx(t, ten)} 111 {hx(t, inf)} {hx(t, sgn)}')
    c.append(f'{t} abs {hx(t, p225)} {hx(t, 0)} {hx(t, inf)} {hx(t, sgn | p225)} {hx(t, p225)} 101')
    # nan inf fin zero sub norm neg
    for name, flags in [('0', '0011000'), ('-0', '0011001'), ('4', '0010010'), ('-2.25', '0010011'),
                        ('sub', '0010100'), ('-sub', '0010101'), ('minpos', '0010010'), ('max', '0010010'),
                        ('inf', '0100000'), ('-inf', '0100001'), ('nan', '1000000'), ('-nan', '1000001')]:
        c.append(f'{t} cls {name} {flags}')
    c.append(f'{t} unord 11100')
    if t != 'f80':
        c.append(f'{t} chain 111111')
    checks += [f'// {pfx}-NEXT: {x}' if i else f'// {pfx}: {x}' for i, x in enumerate(c)]

head = '''// Every float method (num/float_ext.k, num/f128_ext.k) on every native float
// type: to_bits, sqrt, fma, abs, copysign, is_unordered, is_nan,
// is_infinite, is_finite, is_zero, is_subnormal, is_normal and
// is_sign_negative, on +-0, +-inf, NaN of both signs, the smallest
// subnormal, the smallest normal, MAX and ordinary values. Results are
// printed as encodings and checked against values computed exactly
// (fractions.Fraction, round to nearest even): sqrt(2), sqrt(2.25), and
// fma(1 + eps, 1 - eps, -1) = -eps^2, which only a single rounding gets
// (unfused, the product rounds to 1 and the sum to 0). The `chain` lines are
// P754: a limit at the head of a method chain, `f64::NAN.is_nan()` (not for
// f80, whose limits cannot sit in an eval-if branch yet, P760).
// Generated by Inputs/gen_methods.py (the oracle); regenerate, do not edit.
// f80 is x86 only; its lines are the X87 prefix. cross.k runs this file on
// i686 and aarch64.

import std::io

fn b_(x: bool) -> string {
    if x {
        return "1"
    }

    return "0"
}

fn h_(v: u128) -> string {
    return f"{(v >> 64) as u64:x}:{v as u64:x}"
}
'''
main = '''
fn main() -> i32 {
    run_f16()
    run_bf16()
    run_f32()
    run_f64()
    eval if defined!(__x86_64__) || defined!(__i386__) {
        run_f80()
    }

    run_f128()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefixes=CHECK,X87
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --check-prefixes=CHECK,X87
'''
text = head + ''.join(out_k) + main + '\n'.join(checks) + '\n'
out = os.path.join(os.path.dirname(HERE), 'methods.k')
open(out, 'w').write(kfmt(text, 'methods.k'))
