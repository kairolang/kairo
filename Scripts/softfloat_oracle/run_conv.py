"""Format-to-format conversion vectors. usage: run_conv.py DRIVER count seed"""
import random, subprocess, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from wfo import *
from gen import rand_val
drv, cnt, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rng = random.Random(seed)
F = [(16, 5), (16, 8), (32, 8), (64, 11), (79, 15), (128, 15), (256, 19), (512, 23)]
lines, exp = [], []
for (n1, e1) in F:
    for (n2, e2) in F:
        if (n1, e1) == (n2, e2):
            continue
        if n1 not in (256, 512) and n2 not in (256, 512):
            continue
        fs, ft = Fmt(n1, e1), Fmt(n2, e2)
        for i in range(cnt):
            a = rand_val(fs, rng)
            lines.append(f'v {n1} {e1} {n2} {e2} {a:x}')
            exp.append(convert(fs, ft, a))
out = subprocess.run([drv], input='\n'.join(lines) + '\n', capture_output=True, text=True).stdout.split()
bad = 0
for l, e, g in zip(lines, exp, out):
    if int(g, 16) != e:
        bad += 1
        if bad < 6:
            print('MISMATCH', l, g, f'{e:x}')
print(f'conv: {len(lines)} vectors, {len(out)} results, bad={bad}')
