"""Instruction-count parity of the wrap and sequencing forms (parity.cpp).

Usage: parity.py <clang> <parity.cpp>

Each ref_X / k_X pair is compiled at -O1, -O2 and -O3 for x86_64 and
aarch64 (-S, no unwind tables), and the instructions between `name:` and
its `.Lfunc_end` are counted. Every pair must match except ALLOW, the
pairs whose difference is the semantics, not overhead.
"""
import re
import subprocess
import sys

# name -> the C++ UB (or semantic) the plain operator was exploiting.
ALLOW = {
    "div": "a runtime divisor's zero and -1 checks are the semantics",
}
TARGETS = ["x86_64-linux-gnu", "aarch64-linux-gnu"]
LEVELS = ["-O1", "-O2", "-O3"]


def counts(clang, src, target, level):
    r = subprocess.run(
        [clang, "--driver-mode=g++", "-std=c++2c", "--target=" + target, level, "-S",
         "-fno-asynchronous-unwind-tables", "-o", "-", src],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"parity: {target} {level}: clang failed\n{r.stderr}")
    asm = r.stdout
    out = {}
    name = None
    for line in asm.splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
        if m and (m.group(1).startswith("ref_") or m.group(1).startswith("k_")):
            name = m.group(1)
            out[name] = 0
            continue
        if name is not None and line.startswith(".Lfunc_end"):
            name = None
            continue
        if name is not None and re.match(r"^\t[a-z]", line):
            out[name] += 1
    return out


def main():
    clang, src = sys.argv[1], sys.argv[2]
    bad = 0
    for target in TARGETS:
        for level in LEVELS:
            c = counts(clang, src, target, level)
            for ref in sorted(n for n in c if n.startswith("ref_")):
                pair = ref[4:]
                k = "k_" + pair
                if k not in c:
                    print(f"{target} {level} {pair}: no {k}")
                    bad += 1
                    continue
                if c[ref] != c[k] and pair not in ALLOW:
                    print(f"{target} {level} {pair}: ref {c[ref]} vs k {c[k]}")
                    bad += 1
    print("parity: OK" if bad == 0 else f"parity: {bad} mismatch(es)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
