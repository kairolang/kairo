"""Exact oracle for IEEE-style binary formats (binary16..binary512).

Every result is computed with fractions.Fraction (or exact integers) and then
rounded once, round-to-nearest-even, into the target encoding. NaN results are
the canonical quiet NaN (sign 0, top fraction bit only), which is what the
Kairo implementation produces for every computational operation.
"""
from fractions import Fraction
from math import isqrt


class Fmt:
    def __init__(self, nbits, ebits, x87=False):
        self.nbits, self.ebits = nbits, ebits
        self.mbits = nbits - 1 - ebits          # stored fraction bits
        self.P = self.mbits + 1                  # precision
        self.bias = (1 << (ebits - 1)) - 1
        self.emax = self.bias
        self.emin = 1 - self.bias
        self.emask = (1 << ebits) - 1
        self.fmask = (1 << self.mbits) - 1
        self.x87 = x87
        if x87:                                  # 1/15/64 with explicit int bit
            self.mbits = 63
            self.P = 64

    def qnan(self):
        if self.x87:
            return (0x7FFF << 64) | (3 << 62)
        return (self.emask << self.mbits) | (1 << (self.mbits - 1))

    def inf(self, s):
        if self.x87:
            return (s << 79) | (0x7FFF << 64) | (1 << 63)
        return (s << (self.nbits - 1)) | (self.emask << self.mbits)

    def zero(self, s):
        return s << (self.top() )

    def top(self):
        return 79 if self.x87 else self.nbits - 1

    def decode(self, b):
        """-> (kind, sign, Fraction) kind in nan/inf/zero/fin"""
        s = (b >> self.top()) & 1
        if self.x87:
            e = (b >> 64) & 0x7FFF
            m = b & ((1 << 64) - 1)
            if e == 0x7FFF:
                if (m << 1) & ((1 << 64) - 1) == 0:
                    return ('inf', s, None)
                return ('nan', s, None)
            if e == 0:
                v = Fraction(m) * Fraction(2) ** (1 - 16383 - 63)
            else:
                if not (m >> 63):          # unnormal: invalid -> nan
                    return ('nan', s, None)
                v = Fraction(m) * Fraction(2) ** (e - 16383 - 63)
            if m == 0:
                return ('zero', s, Fraction(0))
            return ('fin', s, -v if s else v)
        e = (b >> self.mbits) & self.emask
        m = b & self.fmask
        if e == self.emask:
            return ('nan' if m else 'inf', s, None)
        if e == 0:
            if m == 0:
                return ('zero', s, Fraction(0))
            v = Fraction(m) * Fraction(2) ** (self.emin - self.mbits)
        else:
            v = Fraction(m | (1 << self.mbits)) * Fraction(2) ** (e - self.bias - self.mbits)
        return ('fin', s, -v if s else v)

    # -- rounding --------------------------------------------------------
    def round_parts(self, s, r, e, sticky):
        """Round (r + d) * 2^e, 0 < d < 1 when sticky else d = 0, r >= 0."""
        if r == 0 and not sticky:
            return self.zero(s)
        if r == 0:
            # tiny positive: below any representable unit -> push it up so it
            # can still round: scale r up
            r, e = 1, e - 1   # unreachable in practice (callers keep bits)
        t = r.bit_length()
        E = e + t - 1                          # unbiased exponent of top bit
        keep = self.P if E >= self.emin else self.P - (self.emin - E)
        d = t - keep
        if d <= 0:
            m = r << (-d)
            rb = False
            st = sticky
            ebase = e + d
        else:
            m = r >> d
            rb = (r >> (d - 1)) & 1
            st = sticky or (r & ((1 << (d - 1)) - 1)) != 0
            ebase = e + d
        if keep <= 0:
            # everything is below the smallest subnormal's half... handle via
            # direct comparison with the min subnormal
            tiny = Fraction(2) ** (self.emin - self.mbits)
            val = Fraction(r) * Fraction(2) ** e
            if sticky:
                val += Fraction(1, 10 ** 9) * Fraction(2) ** e  # strictly above
            # keep<=0: value < 2^(emin-mbits) ... 0 or 1 ulp
            half = tiny / 2
            if val > half:
                m, ebase = 1, self.emin - self.mbits
            elif val == half and not sticky:
                m, ebase = 0, 0
            else:
                m, ebase = 0, 0
            rb, st = False, False
            if m == 0:
                return self.zero(s)
        if rb and (st or (m & 1)):
            m += 1
        # now value = m * 2^ebase; encode
        if m == 0:
            return self.zero(s)
        t2 = m.bit_length()
        E2 = ebase + t2 - 1
        if E2 > self.emax:
            return self.inf(s)
        if E2 < self.emin:
            # subnormal: m * 2^ebase with ebase == emin - mbits
            assert ebase + 0 >= self.emin - self.mbits - 0, (ebase,)
            frac = m << (ebase - (self.emin - self.mbits))
            if self.x87:
                return (s << 79) | frac
            return (s << (self.nbits - 1)) | frac
        # normal: shift m to P bits
        sh = self.P - t2
        mm = m << sh if sh >= 0 else m >> (-sh)
        if self.x87:
            return (s << 79) | ((E2 + 16383) << 64) | mm
        return (s << (self.nbits - 1)) | ((E2 + self.bias) << self.mbits) | (mm & self.fmask)

    def round_frac(self, v, s=None):
        if s is None:
            s = 1 if v < 0 else 0
        v = abs(v)
        if v == 0:
            return self.zero(s)
        # choose e so r = floor(v * 2^-e) has >= P + 3 bits, or is exact
        num, den = v.numerator, v.denominator
        # bit estimate
        lg = num.bit_length() - den.bit_length()
        e = lg - (self.P + 4)
        e = min(e, self.emin - self.mbits - 2)if False else e
        # do not go below what subnormal rounding needs; that is fine either way
        if e >= 0:
            q, rem = divmod(num, den << e)
        else:
            q, rem = divmod(num << (-e), den)
        return self.round_parts(s, q, e, rem != 0)


def fmt_by_width(w):
    return {16: Fmt(16, 5), 32: Fmt(32, 8), 64: Fmt(64, 11), 128: Fmt(128, 15),
            256: Fmt(256, 19), 512: Fmt(512, 23), 'bf16': Fmt(16, 8), 80: Fmt(80, 15, True)}[w]


# -- operations -----------------------------------------------------------
def add(f, a, b, sub=False):
    ka, sa, va = f.decode(a)
    kb, sb, vb = f.decode(b)
    if sub:
        sb ^= 1
        if vb is not None:
            vb = -vb
    if ka == 'nan' or kb == 'nan':
        return f.qnan()
    if ka == 'inf' and kb == 'inf':
        return f.qnan() if sa != sb else f.inf(sa)
    if ka == 'inf':
        return f.inf(sa)
    if kb == 'inf':
        return f.inf(sb)
    r = va + vb
    if r == 0:
        if ka == 'zero' and kb == 'zero':
            return f.zero(sa & sb)
        return f.zero(0) if (sa != sb or True) and not (sa and sb) else f.zero(1)
    return f.round_frac(r)


def mul(f, a, b):
    ka, sa, va = f.decode(a)
    kb, sb, vb = f.decode(b)
    s = sa ^ sb
    if ka == 'nan' or kb == 'nan':
        return f.qnan()
    if ka == 'inf' or kb == 'inf':
        if ka == 'zero' or kb == 'zero':
            return f.qnan()
        return f.inf(s)
    if ka == 'zero' or kb == 'zero':
        return f.zero(s)
    return f.round_frac(abs(va * vb), s)


def div(f, a, b):
    ka, sa, va = f.decode(a)
    kb, sb, vb = f.decode(b)
    s = sa ^ sb
    if ka == 'nan' or kb == 'nan':
        return f.qnan()
    if ka == 'inf':
        return f.qnan() if kb == 'inf' else f.inf(s)
    if kb == 'inf':
        return f.zero(s)
    if kb == 'zero':
        return f.qnan() if ka == 'zero' else f.inf(s)
    if ka == 'zero':
        return f.zero(s)
    return f.round_frac(abs(va / vb), s)


def sqrt(f, a):
    ka, sa, va = f.decode(a)
    if ka == 'nan':
        return f.qnan()
    if ka == 'zero':
        return a
    if sa:
        return f.qnan()
    if ka == 'inf':
        return a
    num, den = va.numerator, va.denominator
    # find k: r = isqrt(v * 4^k) has >= P + 3 bits
    lg = (num.bit_length() - den.bit_length()) // 2
    k = (f.P + 4) - lg
    if k >= 0:
        N, rem = divmod(num << (2 * k), den)
    else:
        N, rem = divmod(num, den << (-2 * k))
    r = isqrt(N)
    sticky = rem != 0 or r * r != N
    return f.round_parts(0, r, -k, sticky)


def fma(f, a, b, c):
    ka, sa, va = f.decode(a)
    kb, sb, vb = f.decode(b)
    kc, sc, vc = f.decode(c)
    if 'nan' in (ka, kb, kc):
        return f.qnan()
    sp = sa ^ sb
    if ka == 'inf' or kb == 'inf':
        if ka == 'zero' or kb == 'zero':
            return f.qnan()
        if kc == 'inf' and sc != sp:
            return f.qnan()
        return f.inf(sp)
    if kc == 'inf':
        return f.inf(sc)
    p = va * vb
    r = p + vc
    if r == 0:
        pz = (ka == 'zero' or kb == 'zero')
        if pz and kc == 'zero':
            return f.zero(sp & sc)
        return f.zero(0)
    return f.round_frac(r)


def cmp(f, a, b):
    """-> 0 eq, 1 lt, 2 gt, 3 unordered"""
    ka, sa, va = f.decode(a)
    kb, sb, vb = f.decode(b)
    if ka == 'nan' or kb == 'nan':
        return 3
    def val(k, s, v):
        if k == 'inf':
            return (-1 if s else 1, 0)
        return (0, v)
    x, y = val(ka, sa, va), val(kb, sb, vb)
    if x == y:
        return 0
    return 1 if x < y else 2


def convert(fsrc, fdst, b):
    k, s, v = fsrc.decode(b)
    if k == 'nan':
        return fdst.qnan()
    if k == 'inf':
        return fdst.inf(s)
    if k == 'zero':
        return fdst.zero(s)
    return fdst.round_frac(abs(v), s)


def from_int(f, n):
    if n == 0:
        return f.zero(0)
    return f.round_frac(Fraction(abs(n)), 1 if n < 0 else 0)


def to_int(f, b, width, signed):
    """truncate toward zero, saturating; NaN -> 0"""
    k, s, v = f.decode(b)
    lo = -(1 << (width - 1)) if signed else 0
    hi = (1 << (width - 1)) - 1 if signed else (1 << width) - 1
    if k == 'nan':
        return 0
    if k == 'inf':
        return lo if s else hi
    if k == 'zero':
        return 0
    n = int(v)  # truncates toward zero
    return max(lo, min(hi, n))


# -- dyadic fast path ------------------------------------------------------
# Values as exact (m, e) pairs, value = m * 2^e with m a signed integer.
# Same exact semantics as the Fraction versions above, without gcd on
# multi-million-bit integers (binary512 exponents reach 2^22). These
# definitions replace the Fraction ones.

def ddecode(f, b):
    s = (b >> f.top()) & 1
    if f.x87:
        e = (b >> 64) & 0x7FFF
        m = b & ((1 << 64) - 1)
        if e == 0x7FFF:
            return ('inf' if (m << 1) & ((1 << 64) - 1) == 0 else 'nan', s, None)
        if e != 0 and not (m >> 63):
            return ('nan', s, None)
        if m == 0:
            return ('zero', s, (0, 0))
        ee = (1 if e == 0 else e) - 16383 - 63
        return ('fin', s, (-m if s else m, ee))
    e = (b >> f.mbits) & f.emask
    m = b & f.fmask
    if e == f.emask:
        return ('nan' if m else 'inf', s, None)
    if e == 0:
        if m == 0:
            return ('zero', s, (0, 0))
        return ('fin', s, (-m if s else m, f.emin - f.mbits))
    m |= 1 << f.mbits
    return ('fin', s, (-m if s else m, e - f.bias - f.mbits))


def dround(f, m, e, s=None):
    if s is None:
        s = 1 if m < 0 else 0
    return f.round_parts(s, abs(m), e, False)


def dadd(ma, ea, mb, eb):
    if ea > eb:
        return (ma << (ea - eb)) + mb, eb
    return ma + (mb << (eb - ea)), ea


def add(f, a, b, sub=False):
    ka, sa, va = ddecode(f, a)
    kb, sb, vb = ddecode(f, b)
    if sub:
        sb ^= 1
        if vb is not None:
            vb = (-vb[0], vb[1])
    if ka == 'nan' or kb == 'nan':
        return f.qnan()
    if ka == 'inf' and kb == 'inf':
        return f.qnan() if sa != sb else f.inf(sa)
    if ka == 'inf':
        return f.inf(sa)
    if kb == 'inf':
        return f.inf(sb)
    if ka == 'zero' and kb == 'zero':
        return f.zero(sa & sb)
    m, e = dadd(va[0], va[1], vb[0], vb[1])
    if m == 0:
        return f.zero(0)
    return dround(f, m, e)


def mul(f, a, b):
    ka, sa, va = ddecode(f, a)
    kb, sb, vb = ddecode(f, b)
    s = sa ^ sb
    if ka == 'nan' or kb == 'nan':
        return f.qnan()
    if ka == 'inf' or kb == 'inf':
        if ka == 'zero' or kb == 'zero':
            return f.qnan()
        return f.inf(s)
    if ka == 'zero' or kb == 'zero':
        return f.zero(s)
    return dround(f, abs(va[0] * vb[0]), va[1] + vb[1], s)


def div(f, a, b):
    ka, sa, va = ddecode(f, a)
    kb, sb, vb = ddecode(f, b)
    s = sa ^ sb
    if ka == 'nan' or kb == 'nan':
        return f.qnan()
    if ka == 'inf':
        return f.qnan() if kb == 'inf' else f.inf(s)
    if kb == 'inf':
        return f.zero(s)
    if kb == 'zero':
        return f.qnan() if ka == 'zero' else f.inf(s)
    if ka == 'zero':
        return f.zero(s)
    x, y = abs(va[0]), abs(vb[0])
    k = f.P + 4 + max(0, y.bit_length() - x.bit_length())
    q, r = divmod(x << k, y)
    return f.round_parts(s, q, va[1] - vb[1] - k, r != 0)


def sqrt(f, a):
    ka, sa, va = ddecode(f, a)
    if ka == 'nan':
        return f.qnan()
    if ka == 'zero':
        return a
    if sa:
        return f.qnan()
    if ka == 'inf':
        return a
    m, e = va
    k = 2 * f.P + 8
    if (e - k) & 1:
        k += 1
    N = m << k
    r = isqrt(N)
    return f.round_parts(0, r, (e - k) // 2, r * r != N)


def fma(f, a, b, c):
    ka, sa, va = ddecode(f, a)
    kb, sb, vb = ddecode(f, b)
    kc, sc, vc = ddecode(f, c)
    if 'nan' in (ka, kb, kc):
        return f.qnan()
    sp = sa ^ sb
    if ka == 'inf' or kb == 'inf':
        if ka == 'zero' or kb == 'zero':
            return f.qnan()
        if kc == 'inf' and sc != sp:
            return f.qnan()
        return f.inf(sp)
    if kc == 'inf':
        return f.inf(sc)
    if (ka == 'zero' or kb == 'zero') and kc == 'zero':
        return f.zero(sp & sc)
    pm, pe = va[0] * vb[0], va[1] + vb[1]
    m, e = dadd(pm, pe, vc[0], vc[1])
    if m == 0:
        return f.zero(0)
    return dround(f, m, e)


def convert(fsrc, fdst, b):
    k, s, v = ddecode(fsrc, b)
    if k == 'nan':
        return fdst.qnan()
    if k == 'inf':
        return fdst.inf(s)
    if k == 'zero':
        return fdst.zero(s)
    return dround(fdst, abs(v[0]), v[1], s)
