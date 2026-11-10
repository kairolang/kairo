"""usage: run_text.py DRIVER nbits ebits count seed"""
import random, subprocess, sys, time
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from wfo import *
from gen import rand_val
from textor import parse, fmt, digits, layout, rt_digits

drv, nb, eb, cnt, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
f = Fmt(nb, eb)
rng = random.Random(seed)
lines, exp, kinds = [], [], []


def finite(rng):
    # Mostly moderate exponents (the exact oracle is big-integer arithmetic,
    # and at binary512's extremes one value is a 4M-bit number); a few at the
    # edges of the range, subnormals included.
    while True:
        if rng.random() < 0.85 and f.nbits >= 128:
            e = f.bias + rng.randint(-3000, 3000)
            a = (e << f.mbits) | rng.getrandbits(f.mbits)
            k = rng.random()
            if k < .1: a = (e << f.mbits)
            elif k < .2: a = (e << f.mbits) | f.fmask
            elif k < .3: a = (e << f.mbits) | (rng.getrandbits(20) << (f.mbits - 20))
        else:
            a = rand_val(f, rng)
        if ddecode(f, a)[0] in ('fin', 'zero'):
            return a


for i in range(cnt):
    a = finite(rng)
    r = rng.random()
    # format
    if r < .5:
        prec, conv = -1, 'g'
    elif r < .6:
        prec, conv = -1, rng.choice('eE')
    else:
        prec, conv = rng.choice([0, 1, 2, 5, 10, 20, 40, 70, 100, 150, 200]), rng.choice('geE')
    a &= ~(1 << (nb - 1))
    lines.append(f'F {nb} {eb} {prec} {conv} {a:x}'); exp.append(fmt(f, a, prec, conv)); kinds.append('fmt')
    # round trip via shortest text
    if ddecode(f, a)[0] == 'fin':
        ds, k = digits(f, a, 0)
        s = ds[0] + '.' + ds[1:] + f'e{k}' if len(ds) > 1 else ds + f'e{k}'
        lines.append(f'P {nb} {eb} {s}'); exp.append(f'{a:x}'.zfill((nb + 3) // 4)); kinds.append('roundtrip')
        # near-midpoint decimal: the exact midpoint above a, cut to some digits, +- one unit
        _, _, (m, e) = ddecode(f, a)
        mid = (Fraction(2 * m + 1) * Fraction(2) ** (e - 1))
        if abs(e) < 3000:
            # exact decimal of mid
            num, den = mid.numerator, mid.denominator
            # den is a power of two: mid = num * 5^t / 10^t
            t = den.bit_length() - 1
            dec = str(num * 5 ** t)
            if rng.random() < .5:
                s = dec + f'e-{t}'
            else:
                cut = rng.randint(1, len(dec))
                dd = int(dec[:cut]) + rng.choice([-1, 0, 1])
                s = f'{dd}e{len(dec) - cut - t}'
            sig = len(s.split('e')[0].lstrip('-').lstrip('0'))
            kind = 'midpoint' if sig <= 1000 else 'longmid(>1000 digits, documented limit)'
            lines.append(f'P {nb} {eb} {s}'); exp.append(f'{parse(f, s):x}'.zfill((nb + 3) // 4)); kinds.append(kind)
    # random decimal string
    nd = rng.choice([1, 2, 5, 17, 36, 40, 73, 80, 149, 160, 300])
    ds = str(rng.randint(1, 9)) + ''.join(rng.choice('0123456789') for _ in range(nd - 1))
    ex = rng.randint(-int((f.bias + f.mbits) * 0.302) - 20, int(f.bias * 0.302) + 5)
    if rng.random() < .9:
        ex = rng.randint(-60, 60) if rng.random() < .5 else rng.randint(-900, 900)
    s = f'{ds[0]}.{ds[1:]}e{ex}' if nd > 1 else f'{ds}e{ex}'
    if rng.random() < .1:
        s = '-' + s
    lines.append(f'P {nb} {eb} {s}'); exp.append(f'{parse(f, s):x}'.zfill((nb + 3) // 4)); kinds.append('random')
    if rng.random() < .1:
        h = '0x' + ''.join(rng.choice('0123456789abcdef') for _ in range(rng.randint(1, nb // 4 + 3))) + '.' + \
            ''.join(rng.choice('0123456789abcdef') for _ in range(rng.randint(0, 8))) + f'p{rng.randint(-f.bias - f.mbits - 10, f.bias)}'
        lines.append(f'P {nb} {eb} {h}'); exp.append(f'{parse(f, h):x}'.zfill((nb + 3) // 4)); kinds.append('hex')

t0 = time.time()
out = subprocess.run([drv], input='\n'.join(lines) + '\n', capture_output=True, text=True).stdout.split('\n')
dt = time.time() - t0
bad = {}
tot = {}
for l, e, g, k in zip(lines, exp, out, kinds):
    tot[k] = tot.get(k, 0) + 1
    if g.strip() != e:
        bad[k] = bad.get(k, 0) + 1
        if bad[k] <= 4 and not k.startswith('longmid'):
            print('MISMATCH', k, l[:200], '\n  got ', g[:200], '\n  want', e[:200])
print(f'text {nb}/{eb}: {tot} results={len(out)-1} bad={bad} driver {dt:.1f}s')
