#!/usr/bin/env python3
"""Judge lit JSON results (`lit -o`).

FAIL, UNRESOLVED and TIMEOUT fail the gate. XPASS does not: it is reported as a
warning because the test's XFAIL line is stale and has to be dropped.

    gate.py [--expect-dirs] RESULTS... [--summary FILE]

Each RESULTS is a lit JSON file, or a directory searched for `*.json`.
With --expect N, fewer than N result files fail the gate (a shard that never
reported must not read as green).
"""
import argparse, json, os, sys

BAD = {"FAIL", "UNRESOLVED", "TIMEOUT"}


def collect(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                files += [os.path.join(root, n) for n in names if n.endswith(".json")]
        else:
            files.append(p)
    return sorted(files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--expect", type=int, default=0, help="minimum number of result files")
    ap.add_argument("--summary", help="append a markdown summary to this file")
    a = ap.parse_args()

    files = collect(a.paths)
    counts, bad, xpass = {}, [], []
    for f in files:
        for t in json.load(open(f)).get("tests", []):
            c = t["code"]
            counts[c] = counts.get(c, 0) + 1
            if c in BAD:
                bad.append((c, t["name"]))
            elif c == "XPASS":
                xpass.append(t["name"])

    short = max(0, a.expect - len(files))
    for c, n in sorted(bad, key=lambda x: x[1]):
        print(f"::error title={c}::{n}")
    for n in sorted(xpass):
        print(f"::warning title=XPASS::{n}: passes now, drop its XFAIL line")
    if short:
        print(f"::error title=missing results::{short} of {a.expect} result files absent")

    lines = [f"{len(files)} result file(s); " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))]
    if bad:
        lines += ["", "### Failing"] + [f"- `{c}` {n}" for c, n in sorted(bad, key=lambda x: x[1])]
    if xpass:
        lines += ["", "### XPASS: drop the XFAIL line"] + [f"- {n}" for n in sorted(xpass)]
    if short:
        lines += ["", f"**{short} of {a.expect} result files missing**"]
    text = "\n".join(lines)
    print(text)
    if a.summary:
        with open(a.summary, "a") as fh:
            fh.write(text + "\n")
    return 1 if bad or short else 0


sys.exit(main())
