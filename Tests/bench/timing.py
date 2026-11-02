import subprocess, time, os, statistics, sys, glob, hashlib
runs = int(sys.argv[1])
cases = [("nbody", "30000000"), ("btree", "20"), ("fannkuch", "11")]
for name, n in cases:
    bins = sorted(glob.glob(f"bin/{name}_*"))
    env = dict(os.environ, N=n)
    outs, times = {}, {b: [] for b in bins}
    for r in range(runs):
        for b in bins:
            s = time.perf_counter()
            p = subprocess.run([b], env=env, capture_output=True, text=True)
            times[b].append(time.perf_counter() - s)
            # n-body prints at different precisions: compare to 9 digits
            outs[b] = "\n".join(l if name != "nbody" else f"{float(l):.9f}" for l in p.stdout.split())
    ok = len(set(outs.values())) == 1
    print(f"== {name} N={n}  outputs agree: {ok}")
    for b in sorted(bins, key=lambda b: statistics.median(times[b])):
        t = sorted(times[b])
        print(f"  {b.split('_', 1)[1]:7s} median {statistics.median(t):.3f}s  min {t[0]:.3f}s")
