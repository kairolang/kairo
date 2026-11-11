#!/usr/bin/env python3
"""Times an edit on a real project, live worker against a process per run.

  live_bench.py <kals> <workspace> --entry REL --file REL [--file REL ...]
                [--edits N] [--live | --no-live] [--rss-edits N]
                [--preempt REL [--preempt-after S]]

The workspace is opened as an editor would (its kairo_compile.json decides the
entries). --entry is opened first, so its graph is the one analysed; then, per
--file, the file is opened and edited N times (a comment appended, the buffer
only: nothing is written to disk), and for each edit the script reports

  fg     ms from didChange to the first $/kals/analysed for that revision
         (the edited file's results are installed)
  drain  ms until one with pending == 0 (every importer re-checked)
  mode   what the live worker did (absent: a process ran), files re-checked

--rss-edits N then edits the first --file N more times and prints the index
worker's resident size before and after (Linux /proc).
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client


def children_rss_mb(pid, needle):
    """Resident MB of the processes started by `pid` whose command line
    holds `needle`."""
    total = 0
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            stat = open(f"/proc/{p}/stat").read()
            ppid = int(stat.rsplit(")", 1)[1].split()[1])
            if ppid != pid:
                continue
            cmd = open(f"/proc/{p}/cmdline", "rb").read().decode(errors="replace")
            if needle not in cmd:
                continue
            for line in open(f"/proc/{p}/status"):
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1]) // 1024
        except (OSError, ValueError, IndexError):
            pass
    return total


def analysed_after(c, start):
    return [n["params"] for n in c.notes[start:] if n["method"] == "$/kals/analysed"]


def edit(c, rel, version, text, timeout):
    """One change; (fg ms, drain ms, the foreground answer, the last)."""
    start = len(c.notes)
    t0 = time.time()
    c.change(rel, version, text)
    fg = drain = None
    first = last = {}
    end = t0 + timeout
    while time.time() < end and drain is None:
        c.pump(0.005)
        for a in analysed_after(c, start):
            if a["revision"] < a["current"]:
                continue
            if fg is None:
                fg, first = (time.time() - t0) * 1000, a
            if a.get("pending", 0) == 0:
                drain, last = (time.time() - t0) * 1000, a
    last = dict(last, answers=len(analysed_after(c, start)))
    return fg, drain, first, last


def preempt(c, core, leaf, version, wait, timeout):
    """An edit of `core`, and `wait` seconds into its drain one of `leaf`:
    ms from the second didChange to its file's results."""
    ctext = open(os.path.join(c.root, core)).read()
    ltext = open(os.path.join(c.root, leaf)).read()
    start = len(c.notes)
    c.change(core, version.setdefault(core, 1) + 1, ctext + "\n// preempt\n")
    version[core] += 1
    end = time.time() + timeout
    while time.time() < end and not analysed_after(c, start):
        c.pump(0.005)
    left = (analysed_after(c, start) or [{}])[-1].get("pending", 0)
    c.pump(wait)
    mid = (analysed_after(c, start) or [{}])[-1].get("pending", 0)
    mark = len(c.notes)
    t0 = time.time()
    c.change(leaf, version.setdefault(leaf, 1) + 1, ltext + "\n// preempt\n")
    version[leaf] += 1
    fg = None
    mine = {}
    while time.time() < end and fg is None:
        c.pump(0.005)
        for a in analysed_after(c, mark):
            if a["revision"] >= a["current"]:
                fg, mine = (time.time() - t0) * 1000, a
                break
    c.settle(timeout)
    print(f"  pre-empt: {core} queued {left}, {mid} left after {wait} s; then {leaf}: fg {fg:.0f} ms, "
          f"mode {mine.get('mode', 'run')}, pending {mine.get('pending', 0)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kals")
    ap.add_argument("workspace")
    ap.add_argument("--entry", required=True)
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--edits", type=int, default=3)
    ap.add_argument("--live", dest="live", action="store_true", default=True)
    ap.add_argument("--no-live", dest="live", action="store_false")
    ap.add_argument("--rss-edits", type=int, default=0)
    ap.add_argument("--preempt", help="after the edits: edit the last --file, and this file while its importers drain")
    ap.add_argument("--preempt-after", type=float, default=1.0, help="seconds into the drain")
    ap.add_argument("--debounce", type=int, default=0, help="debounceMs (0: the edit alone is timed)")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()

    root = os.path.realpath(args.workspace)
    c = Client(os.path.realpath(args.kals), root, env={"KALS_LIVE_CHECK": "1" if args.live else "0"})
    c.start({"liveCheck": args.live, "debounceMs": args.debounce, "syntaxDebounceMs": 0})
    t0 = time.time()
    c.open(args.entry)
    ok = c.settle(args.timeout)
    a = analysed_after(c, 0)
    needle = "--index-server" if args.live else "--worker"
    print(f"{'live' if args.live else 'per-run'}: first check of {args.entry}: {time.time() - t0:.1f} s, settled={ok}, "
          f"{a[-1] if a else None}, worker rss {children_rss_mb(c.p.pid, needle)} MB")

    version = {}
    for rel in args.file:
        text = c.open(rel)
        c.pump(1.0)
        # Opening may start a run (a file with no rows yet): let it land.
        # (a request on it is parked until its rows are there).
        c.request("textDocument/hover", c.at(rel, 0, 0), timeout=args.timeout)
        c.pump(0.5)
        for k in range(args.edits):
            version[rel] = version.get(rel, 1) + 1
            fg, drain, first, last = edit(c, rel, version[rel], text + f"\n// bench {k}\n", args.timeout)
            mode = first.get("mode", "run")
            print(f"  {rel} edit {k}: fg {fg:.0f} ms, drained {drain:.0f} ms, mode {mode}"
                  f" ({first.get('why', '')}), rechecked {first.get('rechecked', '-')}"
                  f"{'' if last is first else ' then ' + str(last.get('rechecked', '-'))}"
                  f", pending after fg {first.get('pending', 0)}, {last.get('answers', 0)} answers"
                  f", worker rss {children_rss_mb(c.p.pid, needle)} MB")
            c.pump(0.3)

    if args.preempt and args.file:
        c.open(args.preempt)
        c.request("textDocument/hover", c.at(args.preempt, 0, 0), timeout=args.timeout)
        preempt(c, args.file[-1], args.preempt, version, args.preempt_after, args.timeout)

    if args.rss_edits and args.file:
        rel = args.file[0]
        text = open(os.path.join(root, rel)).read()
        before = children_rss_mb(c.p.pid, needle)
        modes = {}
        for k in range(args.rss_edits):
            version[rel] = version.get(rel, 1) + 1
            fg, drain, first, last = edit(c, rel, version[rel], text + f"\n// rss {k}\n", args.timeout)
            modes[first.get("mode", "run")] = modes.get(first.get("mode", "run"), 0) + 1
            c.pump(0.05)
        after = children_rss_mb(c.p.pid, needle)
        print(f"  {rel}: {args.rss_edits} edits, worker rss {before} -> {after} MB, modes {modes}")

    rc = c.stop()
    print("shutdown", rc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
