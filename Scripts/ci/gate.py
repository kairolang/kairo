#!/usr/bin/env python3
"""Judge lit JSON results (`lit -o`).

FAIL, UNRESOLVED and TIMEOUT fail the gate. XPASS does not: it is reported as a
warning because the test's XFAIL line is stale and has to be dropped.

    gate.py [--expect-dirs] RESULTS... [--summary FILE]

Each RESULTS is a lit JSON file, or a directory searched for `*.json`.
With --expect N, fewer than N result files fail the gate (a shard that never
reported must not read as green).

With --badges DIR --targets T:N,..., it also writes one shields.io endpoint
file per target, DIR/<target>.json, from the result files named
<target>-<shard>.json, and DIR/tests.json for all of them. A target with fewer
than N result files says so instead of showing a partial count as a result.
"""
import argparse, json, os, sys

BAD = {"FAIL", "UNRESOLVED", "TIMEOUT"}
LABELS = {"linux-x64": "linux x64", "linux-arm64": "linux arm64", "win-x64": "windows x64",
          "win-arm64": "windows arm64", "mac-arm64": "macOS arm64"}


def badge(label, counts, files, want):
    """A shields.io endpoint document for one set of results."""
    bad = sum(counts.get(c, 0) for c in BAD)
    passed = counts.get("PASS", 0) + counts.get("XFAIL", 0) + counts.get("XPASS", 0)
    if files == 0:
        msg, color = "no results", "lightgrey"
    elif files < want:
        msg, color = f"incomplete: {files}/{want} shards", "orange"
    elif bad:
        msg, color = f"{passed} passed, {bad} failed", "red"
    else:
        msg, color = f"{passed} passed", "brightgreen"
    return {"schemaVersion": 1, "label": label, "message": msg, "color": color}


def write_badges(out, files, targets):
    os.makedirs(out, exist_ok=True)
    per = {t: ({}, 0) for t in targets}
    total, nfiles = {}, 0
    for f in files:
        t = os.path.basename(f)[:-len(".json")].rsplit("-", 1)[0]
        counts, n = per.get(t, ({}, 0))
        for test in json.load(open(f)).get("tests", []):
            counts[test["code"]] = counts.get(test["code"], 0) + 1
            total[test["code"]] = total.get(test["code"], 0) + 1
        per[t] = (counts, n + 1)
        nfiles += 1
    for t, want in targets.items():
        counts, n = per[t]
        with open(os.path.join(out, t + ".json"), "w") as fh:
            json.dump(badge(LABELS.get(t, t), counts, n, want), fh)
    with open(os.path.join(out, "tests.json"), "w") as fh:
        json.dump(badge("tests", total, nfiles, sum(targets.values())), fh)


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
    ap.add_argument("--badges", help="write shields.io endpoint files to this directory")
    ap.add_argument("--targets", default="", help="target:shards,... for --badges")
    a = ap.parse_args()

    files = collect(a.paths)
    if a.badges:
        targets = {t: int(n) for t, n in (x.split(":") for x in a.targets.split(",") if x)}
        write_badges(a.badges, files, targets)
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
