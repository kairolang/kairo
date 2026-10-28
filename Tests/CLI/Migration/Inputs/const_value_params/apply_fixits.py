#!/usr/bin/env python3
# Apply the fix-its of a `kairo --error-format=basic` run to the one file they
# name, in place, so a test can compare "every fix-it accepted" against a
# migration script's output.
#
#   apply_fixits.py <diagnostics.txt> <file.k>
#
# A fix-it line is  fix-it:"<path>":{L1:C1-L2:C2}:"<text>"  with 1-based
# columns and an exclusive end. Only lines whose path names <file.k> apply.
import os, re, sys

FIX = re.compile(r'^fix-it:"(?P<path>[^"]*)":\{(?P<l1>\d+):(?P<c1>\d+)-(?P<l2>\d+):(?P<c2>\d+)\}:"(?P<text>.*)"$')


def main():
    diags, target = sys.argv[1], sys.argv[2]
    with open(target, encoding="utf-8", newline="") as fh:
        src = fh.read()
    starts = [0]
    for i, ch in enumerate(src):
        if ch == "\n":
            starts.append(i + 1)

    def off(line, col):
        return starts[line - 1] + col - 1

    edits = []
    with open(diags, encoding="utf-8") as fh:
        for ln in fh:
            m = FIX.match(ln.rstrip("\r\n"))
            if not m or os.path.basename(m["path"]) != os.path.basename(target):
                continue
            edits.append((off(int(m["l1"]), int(m["c1"])), off(int(m["l2"]), int(m["c2"])), m["text"]))
    for s, e, t in sorted(edits, reverse=True):
        src = src[:s] + t + src[e:]
    with open(target, "w", encoding="utf-8", newline="") as fh:
        fh.write(src)
    print(f"{len(edits)} fix-it(s) applied")


if __name__ == "__main__":
    main()
