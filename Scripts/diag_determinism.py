#!/usr/bin/env python3
"""Run the compiler N times on one input and count the distinct outputs.

For a fixed input and fixed flags the compiler must print the same
diagnostics in the same order on every run, at any thread count.
A race in how per-file diagnostic batches reach the consumer, or in which
file wins a once-only report, shows up here as more than one distinct
output; a single lit run would pass by luck most of the time.

    python3 Scripts/diag_determinism.py --kairo build/.../bin/kairo \\
        -n 30 Tests/Sema/Types/partial_ambiguity_once/main.k \\
        -- --type-check-only --threads=8

Everything after `--` goes to the compiler as is. stdout and stderr are
compared together, as one stream each (not interleaved). Exit status: 0
when every input gave one output, 1 otherwise. --show prints a unified
diff of the first two distinct outputs.
"""

import argparse
import concurrent.futures
import difflib
import hashlib
import os
import subprocess
import sys


def run_once(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = b"== rc %d\n== stdout\n" % p.returncode + p.stdout + b"== stderr\n" + p.stderr
    return out


def main():
    argv = sys.argv[1:]
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]

    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--kairo", required=True, help="compiler binary")
    ap.add_argument("-n", type=int, default=30, help="runs per input (default 30)")
    ap.add_argument("-j", type=int, default=4,
                    help="runs at once (default 4); concurrency perturbs timing, which is the point")
    ap.add_argument("--show", action="store_true", help="diff the first two distinct outputs")
    ap.add_argument("--together", action="store_true",
                    help="pass every input on one command line (a batch) instead of one run each")
    ap.add_argument("inputs", nargs="+", help="input .k files (each run separately)")
    a = ap.parse_args(argv)

    worst = 1
    batches = [[os.path.abspath(i) for i in a.inputs]] if a.together else [[os.path.abspath(i)] for i in a.inputs]
    for files in batches:
        inp = files[0] if len(files) == 1 else f"{files[0]} (+{len(files) - 1} more)"
        cmd = [os.path.abspath(a.kairo), "--error-format=basic"] + files + extra
        seen = {}
        order = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=a.j) as ex:
            for out in ex.map(lambda _: run_once(cmd, os.path.dirname(files[0])), range(a.n)):
                h = hashlib.sha256(out).hexdigest()
                if h not in seen:
                    seen[h] = [0, out]
                    order.append(h)
                seen[h][0] += 1
        counts = ", ".join(str(seen[h][0]) for h in order)
        print(f"{len(seen)} distinct in {a.n} runs ({counts}): {inp} {' '.join(extra)}")
        worst = max(worst, len(seen))
        if a.show and len(order) > 1:
            x = seen[order[0]][1].decode(errors="replace").splitlines(keepends=True)
            y = seen[order[1]][1].decode(errors="replace").splitlines(keepends=True)
            sys.stdout.writelines(difflib.unified_diff(x, y, "output-1", "output-2"))
    return 0 if worst == 1 else 1


if __name__ == "__main__":
    sys.exit(main())
