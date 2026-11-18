"""Parallel links that all miss one empty Kairo library cache.

    race.py --links N --rounds R --cache DIR --obj main.o --out DIR -- <kairo...>

Each round empties DIR, then starts N `<kairo> main.o --kairo-lib` links at
once with KAIRO_CACHE_DIR=DIR, so every one builds the library and they
publish it together. A round passes when every link exits 0, none says
L007E, every executable runs and exits 7, and no `.lock` file is left in
DIR/lib. Prints one line per round and exits 1 on the first failure.
"""
import argparse
import os
import shutil
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--links", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--obj", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("kairo", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    kairo = a.kairo[1:] if a.kairo[:1] == ["--"] else a.kairo
    env = dict(os.environ, KAIRO_CACHE_DIR=a.cache)
    os.makedirs(a.out, exist_ok=True)
    for r in range(a.rounds):
        shutil.rmtree(a.cache, ignore_errors=True)
        os.makedirs(a.cache)
        procs = []
        for i in range(a.links):
            exe = os.path.join(a.out, f"link{i}.exe")
            p = subprocess.Popen(kairo + [a.obj, "--kairo-lib", "-o", exe],
                                 env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
            procs.append((p, exe))
        bad = []
        for i, (p, exe) in enumerate(procs):
            out, _ = p.communicate()
            if p.returncode != 0 or "L007E" in out:
                bad.append(f"link {i} exited {p.returncode}: {out.strip()[-400:]}")
                continue
            rc = subprocess.run([exe]).returncode
            if rc != 7:
                bad.append(f"link {i}: the executable exited {rc}")
        lib = os.path.join(a.cache, "lib")
        locks = [n for n in os.listdir(lib) if n.endswith(".lock")] if os.path.isdir(lib) else []
        if locks:
            bad.append(f"lock files left: {locks}")
        if bad:
            print(f"round {r}: FAIL")
            for b in bad:
                print("  " + b)
            return 1
        print(f"round {r}: ok, {a.links} links")
    return 0


if __name__ == "__main__":
    sys.exit(main())
