"""Drive the engine driver with oracle-checked vectors.
usage: run_ops.py DRIVER nbits ebits count seed [ops]
"""
import random, subprocess, sys, time
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from wfo import *
from gen import rand_val

drv, nb, eb, cnt, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
ops = sys.argv[6] if len(sys.argv) > 6 else 'asmdqfc'
f = Fmt(nb, eb)
rng = random.Random(seed)
lines, exps = [], []
hw = (nb + 3) // 4
for op in ops:
    for i in range(cnt):
        a = rand_val(f, rng)
        b = rand_val(f, rng, near=a)
        if op == 'a': e = add(f, a, b); l = f'a {nb} {eb} {a:x} {b:x}'
        elif op == 's': e = add(f, a, b, True); l = f's {nb} {eb} {a:x} {b:x}'
        elif op == 'm': e = mul(f, a, b); l = f'm {nb} {eb} {a:x} {b:x}'
        elif op == 'd': e = div(f, a, b); l = f'd {nb} {eb} {a:x} {b:x}'
        elif op == 'q':
            if rng.random() < .8: a &= ~(1 << (nb - 1))
            e = sqrt(f, a); l = f'q {nb} {eb} {a:x}'
        elif op == 'f':
            c = rand_val(f, rng)
            if rng.random() < .3:   # c near -a*b
                p = mul(f, a, b)
                if f.decode(p)[0] == 'fin':
                    c = p ^ (1 << (nb - 1))
                    if rng.random() < .5: c ^= rng.getrandbits(4)
            e = fma(f, a, b, c); l = f'f {nb} {eb} {a:x} {b:x} {c:x}'
        elif op == 'c': e = cmp(f, a, b); l = f'c {nb} {eb} {a:x} {b:x}'
        lines.append(l); exps.append((op, e))
t = time.time()
out = subprocess.run([drv], input='\n'.join(lines) + '\n', capture_output=True, text=True).stdout.split()
dt = time.time() - t
bad = {}
for l, (op, e), g in zip(lines, exps, out):
    if int(g, 16) != e:
        bad[op] = bad.get(op, 0) + 1
        if bad[op] <= 3:
            print('MISMATCH', l, 'got', g, 'want', f'{e:x}')
print(f'fmt {nb}/{eb}: {len(lines)} vectors, {len(out)} results, bad={bad} ({dt:.1f}s driver)')
