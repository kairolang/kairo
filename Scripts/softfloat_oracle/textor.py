"""Exact decimal oracle: parse (Fraction -> RNE) and format (shortest
closest digits, ties to even digit, anchored at floor(log10 v); fixed
digits RNE), laid out as rt/fmt_layout.c does."""
from fractions import Fraction
from wfo import Fmt, ddecode


def parse(f, s):
    t = s.replace('_', '')
    neg = t.startswith('-')
    if t[:1] in '+-':
        t = t[1:]
    low = t.lower()
    if low in ('inf', 'infinity'):
        return f.inf(1 if neg else 0)
    if low == 'nan':
        return f.qnan()
    if low.startswith('0x'):
        body = low[2:]
        mant, _, ex = body.partition('p')
        ip, _, fp = mant.partition('.')
        m = int((ip + fp) or '0', 16)
        e = (int(ex) if ex else 0) - 4 * len(fp)
        v = Fraction(m) * (Fraction(2) ** e)
    else:
        v = Fraction(low)
    if v == 0:
        return f.zero(1 if neg else 0)
    return f.round_frac(v, 1 if neg else 0)


def floor_log10(v):
    """v Fraction > 0"""
    n, d = v.numerator, v.denominator
    k = int((n.bit_length() - d.bit_length()) * 0.30102999566398) - 2
    while True:
        p = Fraction(10) ** (k + 1)
        if v >= p:
            k += 1
            continue
        if v < Fraction(10) ** k:
            k -= 1
            continue
        return k


def round_even(x):
    """nearest integer to Fraction x >= 0, ties even"""
    q, r = divmod(x.numerator, x.denominator)
    r2 = 2 * r
    if r2 > x.denominator or (r2 == x.denominator and q & 1):
        q += 1
    return q


def ceil_div(n, d):
    return -((-n) // d)


def digits(f, b, ndig):
    """-> (digit string, k) for finite nonzero b; ndig 0 = shortest"""
    k_, s, (m, e) = ddecode(f, b)
    m = abs(m)
    v = Fraction(m) * Fraction(2) ** e
    K = floor_log10(v)
    if ndig:
        d = round_even(v * Fraction(10) ** (ndig - 1 - K))
        if d >= 10 ** ndig:
            d //= 10
            K += 1
        return str(d), K
    asym = m == (1 << (f.P - 1)) and e > f.emin - f.mbits
    q = Fraction(2) ** (e - 2)
    lo = (4 * m - (1 if asym else 2)) * q
    hi = (4 * m + 2) * q
    incl = m % 2 == 0
    n = 1
    while True:
        u = Fraction(10) ** (K - n + 1)
        a, b2 = lo / u, hi / u
        if incl:
            dl = ceil_div(a.numerator, a.denominator)
            dh = b2.numerator // b2.denominator
        else:
            dl = a.numerator // a.denominator + 1
            dh = ceil_div(b2.numerator, b2.denominator) - 1
        if dl <= dh:
            d = round_even(v / u)
            d = max(dl, min(dh, d))
            ds = str(d)
            kk = len(ds) - 1 + (K - n + 1)
            return ds.rstrip('0') or '0', kk
        n += 1


def layout(ds, k, conv, p):
    n = len(ds)
    if conv != 'g' or k < -4 or k >= p:
        out = ds[0] + ('.' + ds[1:] if n > 1 else '')
        e = abs(k)
        out += ('E' if conv == 'E' else 'e') + ('-' if k < 0 else '+') + ('%02d' % e)
        return out
    if k < 0:
        return '0.' + '0' * (-k - 1) + ds
    if n <= k + 1:
        return ds + '0' * (k + 1 - n)
    return ds[:k + 1] + '.' + ds[k + 1:]


def rt_digits(f):
    return int(f.P * 0.30102999566398) + 2


def fmt(f, b, prec, conv):
    if conv not in ('e', 'E'):
        conv = 'g'
    kind, s, v = ddecode(f, b)
    up = conv == 'E'
    if kind == 'inf':
        return 'INF' if up else 'inf'
    if kind == 'nan':
        return 'NAN' if up else 'nan'
    if kind == 'zero':
        if conv == 'g':
            return '0'
        return '0' + ('.' + '0' * prec if prec > 0 else '') + ('E' if up else 'e') + '+00'
    if prec < 0:
        ds, k = digits(f, b, 0)
        return layout(ds, k, conv, rt_digits(f))
    ndig = (1 if prec == 0 else prec) if conv == 'g' else prec + 1
    ds, k = digits(f, b, ndig)
    if conv == 'g':
        ds = ds.rstrip('0') or '0'
    return layout(ds, k, conv, ndig)
