import random, struct, sys, math
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from wfo import *
from fractions import Fraction
f = Fmt(64, 11)
def bits(x): return struct.unpack('<Q', struct.pack('<d', x))[0]
def flt(b): return struct.unpack('<d', struct.pack('<Q', b))[0]
rng = random.Random(1)
def rnd():
    r = rng.random()
    if r < 0.1: return rng.getrandbits(64)
    if r < 0.3: return (rng.getrandbits(1) << 63) | rng.getrandbits(52) | (rng.choice([0,1,2,2046,2045,1023,1022]) << 52)
    return (rng.getrandbits(1) << 63) | (rng.randrange(900, 1150) << 52) | rng.getrandbits(52)
bad = 0
for i in range(200000):
    a, b = rnd(), rnd()
    x, y = flt(a), flt(b)
    for name, got, exp in (('add', add(f, a, b), x + y), ('sub', add(f, a, b, True), x - y),
                           ('mul', mul(f, a, b), x * y)):
        if math.isnan(exp):
            ok = flt(got) != flt(got)
        else:
            ok = got == bits(exp)
        if not ok:
            bad += 1
            if bad < 10: print(name, hex(a), hex(b), hex(got), hex(bits(exp)))
    if y != 0 or True:
        try: e = x / y
        except ZeroDivisionError: e = None
        if e is not None:
            got = div(f, a, b)
            if (got != bits(e)) and not (math.isnan(e) and flt(got) != flt(got)):
                bad += 1; print('div', hex(a), hex(b))
    if x >= 0 and not math.isnan(x):
        if sqrt(f, a) != bits(math.sqrt(x)):
            bad += 1; print('sqrt', hex(a))
    # fma via Fraction vs math.fma (py3.13)
    if hasattr(math, 'fma') and i % 4 == 0:
        c = rnd()
        try:
            e = math.fma(x, y, flt(c))
            got = fma(f, a, b, c)
            if got != bits(e) and not (math.isnan(e) and flt(got) != flt(got)): bad += 1; print('fma', hex(a), hex(b), hex(c))
        except (ValueError, OverflowError): pass
    # Fraction -> float
    if i % 4 == 0:
        q = Fraction(rng.getrandbits(80) + 1, rng.getrandbits(70) + 1) * Fraction(2) ** rng.randrange(-1100, 1000)
        if f.round_frac(q) != bits(float(q)) if abs(q) < 1e308 else False: bad += 1; print('frac', q)
# f32 conversion check
f32 = Fmt(32, 8)
for i in range(100000):
    a = rnd(); x = flt(a)
    if math.isnan(x): continue
    try: e = struct.unpack('<I', struct.pack('<f', x))[0]
    except OverflowError: e = f32.inf(1 if x < 0 else 0)
    if convert(f, f32, a) != e: bad += 1; print('cvt', hex(a)) if bad < 20 else None
print('bad', bad, 'fma' if hasattr(math, 'fma') else 'nofma')
