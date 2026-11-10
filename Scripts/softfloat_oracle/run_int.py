"""Integer and x87 conversion vectors. usage: run_int.py DRIVER count seed"""
import random, subprocess, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from wfo import *
from gen import rand_val
drv, cnt, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rng = random.Random(seed)
lines, exp, kinds = [], [], []
W = [8, 16, 32, 64, 128, 256, 512]
for (nb, eb) in [(256, 19), (512, 23), (64, 11)]:
    f = Fmt(nb, eb)
    for i in range(cnt):
        w = rng.choice(W)
        signed = rng.random() < .5
        # from int
        k = rng.random()
        if k < .2:
            mag = (1 << rng.randrange(w)) + rng.choice([-1, 0, 1])
        elif k < .4:
            mag = rng.getrandbits(w) | (1 << (w - 1))
        else:
            mag = rng.getrandbits(rng.randint(1, w))
        mag = max(0, min(mag, (1 << w) - 1))
        neg = signed and rng.random() < .5
        n = -mag if neg else mag
        lines.append(f'I {nb} {eb} {1 if neg else 0} {mag:x}'); exp.append(from_int(f, n)); kinds.append('from_int')
        # to int
        a = rand_val(f, rng)
        if rng.random() < .6:   # near integers in range
            v = rng.getrandbits(rng.randint(1, w + 2))
            a = from_int(f, -v if rng.random() < .5 else v)
            if rng.random() < .5:
                a ^= rng.getrandbits(3)
        r = to_int(f, a, w, signed) & ((1 << w) - 1)
        lines.append(f'J {nb} {eb} {w} {1 if signed else 0} {a:x}'); exp.append(r); kinds.append('to_int')
# x87 <-> 79-bit
x87 = Fmt(80, 15, True)
i79 = Fmt(79, 15)
for i in range(cnt):
    s = rng.getrandbits(1)
    e = rng.choice([0, 0x7FFF, 1, 2, 0x7FFE, rng.randint(1, 0x7FFE)])
    m = rng.getrandbits(64)
    if rng.random() < .3:
        m |= 1 << 63
    if rng.random() < .1:
        m = 1 << 63
    if rng.random() < .1:
        m = 0
    b = (s << 79) | (e << 64) | m
    lines.append(f'X 0 0 {b:x}'); exp.append(convert(x87, i79, b)); kinds.append('from_x87')
    a = rand_val(i79, rng)
    lines.append(f'Y 0 0 {a:x}'); exp.append(convert(i79, x87, a)); kinds.append('to_x87')
out = subprocess.run([drv], input='\n'.join(lines) + '\n', capture_output=True, text=True).stdout.split()
bad, tot = {}, {}
for l, e, g, k in zip(lines, exp, out, kinds):
    tot[k] = tot.get(k, 0) + 1
    gv = int(g, 16)
    if k == 'to_int':
        gv &= (1 << int(l.split()[3])) - 1
    if k == 'from_x87' and Fmt(79, 15).decode(e)[0] == 'nan':
        ok = Fmt(79, 15).decode(gv)[0] == 'nan'
    elif k == 'to_x87' and Fmt(80, 15, True).decode(e)[0] == 'nan':
        # a raw re-layout: sf_cvt has already made any NaN canonical
        ok = Fmt(80, 15, True).decode(gv)[0] == 'nan'
    else:
        ok = gv == e
    if not ok:
        bad[k] = bad.get(k, 0) + 1
        if bad[k] <= 4:
            print('MISMATCH', k, l, g, f'{e:x}')
print('int/x87:', tot, 'results', len(out), 'bad', bad)
