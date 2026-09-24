#!/usr/bin/env python3
"""Run every *.k under Tests/Sema/Scenarios through kairo with --print-sema and
dump stdout/stderr/exit per case into one file you can paste back.

    python3 Tests/Sema/Scenarios/run_sema_tests.py [--kairo PATH] [--flags "..."] [--only NAME]

Default flags assume: --print-sema and a stop-after-sema flag. Fix the two
names below if yours differ.
"""
import argparse, os, subprocess, sys, textwrap, time

HERE   = os.path.dirname(os.path.abspath(__file__))
CASES  = HERE
OUT    = os.path.join(HERE, "out")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kairo", default=os.environ.get("KAIRO", "kairo"))
    ap.add_argument("--flags", default="--print-sema --type-check-only --no-color")
    ap.add_argument("--only", default=None)
    ap.add_argument("--timeout", type=int, default=60)
    a = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    cases = sorted(f for f in os.listdir(CASES) if f.endswith(".k") and not f.startswith("_"))
    if a.only:
        cases = [c for c in cases if a.only in c]

    dump = []
    for c in cases:
        path = os.path.join(CASES, c)
        cmd  = [a.kairo, path] + a.flags.split()
        t0   = time.time()
        try:
            p = subprocess.run(cmd, cwd=CASES, capture_output=True, text=True, timeout=a.timeout)
            code, out, err = p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired as e:
            code, out, err = "TIMEOUT", e.stdout or "", e.stderr or ""
        except FileNotFoundError:
            print(f"kairo not found: {a.kairo}", file=sys.stderr); sys.exit(2)
        dt = time.time() - t0

        expect = ""
        with open(path) as f:
            head = [l for l in f.read().splitlines()[:40] if l.startswith("// EXPECT")]
            expect = "\n".join(head)

        block = textwrap.dedent(f"""
        ################################################################
        # CASE {c}   exit={code}   {dt:.2f}s
        # cmd: {' '.join(cmd)}
        {expect}
        ---------------------------------------------------------------- stdout
        {out}
        ---------------------------------------------------------------- stderr
        {err}
        """)
        dump.append(block)
        with open(os.path.join(OUT, c + ".txt"), "w") as f:
            f.write(block)
        print(f"{c:40s} exit={code}")

    with open(os.path.join(OUT, "ALL.txt"), "w") as f:
        f.write("\n".join(dump))
    print(f"\nwrote {os.path.join(OUT, 'ALL.txt')}  -- paste that back")

if __name__ == "__main__":
    main()