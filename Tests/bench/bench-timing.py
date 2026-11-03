"""Times the binaries bench-run.fish built, interleaved, and checks that
every implementation of a benchmark prints the same thing.

    python3 bench-timing.py [--smoke] RUNS BENCH...

Full sizes target 1-3 s per run on a desktop; --smoke uses sizes about 10x
smaller, to check everything builds and agrees. Report: median and best wall
time.
"""
import glob, os, statistics, subprocess, sys, time

# (label, binary prefix, full-size environment, smoke-size environment,
#  variants: None = every binary built for the prefix)
CASES = [
    ("nbody",      "nbody",    {"N": "30000000"},   {"N": "2000000"},   None),
    ("btree",      "btree",    {"N": "20"},         {"N": "16"},        None),
    ("fannkuch",   "fannkuch", {"N": "11"},         {"N": "9"},         None),
    ("gsort",      "gsort",    {"N": "10000000"},   {"N": "1000000"},   None),
    ("gsort-lib",  "gsort",    {"N": "10000000", "LIBSORT": "1"}, {"N": "1000000", "LIBSORT": "1"}, ["rust", "clang", "gcc", "kcc"]),
    ("gen",        "gen",      {"N": "1000000000"}, {"N": "100000000"}, None),
    ("errpath",    "errpath",  {"N": "500000000"},  {"N": "50000000"},  None),
    ("alloc",      "alloc",    {"N": "50000000"},   {"N": "5000000"},   None),
    ("interp",     "interp",   {"N": "250000000"},  {"N": "20000000"},  None),
    ("closures",   "closures", {"N": "1000000000"}, {"N": "100000000"}, None),
    ("dispatch",   "dispatch", {"N": "1500000"},    {"N": "100000"},    None),
    ("wideint",    "wideint",  {"N": "10000000"},   {"N": "500000"},    None),
    ("fmt",        "fmt",      {"N": "10000000"},   {"N": "1000000"},   None),
    ("spectral",   "spectral", {"N": "5500"},       {"N": "1000"},      None),
    ("slices",     "slices",   {"N": "1000"},       {"N": "50"},        None),
    ("nullable",   "nullable", {"N": "10000000"},   {"N": "1000000"},   None),
] + [
    (f"scopes d={d} {m}", "scopes",
     {"N": "50000000", "DEPTH": str(d), "MODE": str(i)},
     {"N": "5000000", "DEPTH": str(d), "MODE": str(i)}, None)
    for d in (1, 16, 64) for i, m in enumerate(("top-free", "global-free", "bottom-free", "open-close"))
]

def normalize(case, text):
    if case == "nbody":   # Kairo prints full precision, the others %.9f
        return "\n".join(f"{float(x):.9f}" for x in text.split())
    return " ".join(text.split())

def main():
    args = sys.argv[1:]
    smoke = "--smoke" in args
    args = [a for a in args if a != "--smoke"]
    runs = int(args[0])
    want = set(args[1:])
    for label, prefix, full, small, variants in CASES:
        extra = small if smoke else full
        if want and prefix not in want:
            continue
        bins = sorted(glob.glob(f"bin/{prefix}.*"))
        if variants is not None:
            bins = [b for b in bins if b.split(".", 1)[1] in variants]
        if not bins:
            continue
        env = dict(os.environ, **extra)
        times = {b: [] for b in bins}
        outs = {}
        for _ in range(runs):
            for b in bins:
                start = time.perf_counter()
                p = subprocess.run([b], env=env, capture_output=True, text=True)
                times[b].append(time.perf_counter() - start)
                outs[b] = normalize(prefix, p.stdout)
        agree = len(set(outs.values())) == 1
        print(f"== {label}  " + " ".join(f"{k}={v}" for k, v in extra.items()) + ("" if agree else "  OUTPUTS DIFFER"))
        for b in sorted(bins, key=lambda b: statistics.median(times[b])):
            t = sorted(times[b])
            print(f"  {b.split('.', 1)[1]:13s} median {statistics.median(t):7.3f}s  best {t[0]:7.3f}s")

if __name__ == "__main__":
    main()
