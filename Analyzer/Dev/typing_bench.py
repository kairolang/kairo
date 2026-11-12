#!/usr/bin/env python3
"""Times what typing costs on a real project: a half-typed line, its
fix, completion, and how many processes a typing session starts.

  typing_bench.py <kals> <workspace> --entry REL --file REL [--file REL ...]
                  [--live | --no-live] [--keys N] [--no-complete]

The workspace is opened as an editor would. --entry is opened first and its
first check waited for. Then, per --file (buffers only, nothing is written):

  broken   ms from the didChange that breaks a line (`var kalsBench = "abc" +`
           added before the last statement of a function body of the file)
           to the diagnostics for that file that hold the syntax error (the
           syntax pass's), and to the `$/kals/analysed` for that text (the
           live worker's aside check of it, or the run)
  fixed    ms from the didChange that completes the line to the first
           $/kals/analysed for that revision (the file's results installed)
  complete ms from a completion request after `kalsBench.` on a new line to
           its answer, and how many items came
  session  N keystrokes typed one at a time, 60 ms apart, into the same
           line (broken at nearly every one), then the line completed:
           how many analyses were a process per run (no `mode`), how many
           went to the live worker, how many were tried aside

Each didChange is the whole text. The server's debounce is set to 0, so the
times are the work, not the wait. CPU seconds of the server and its children
are printed at the end (the machine may be loaded: compare CPU, not only wall).
"""

import argparse
import os
import resource
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client


def analysed_after(c, start):
    return [n["params"] for n in c.notes[start:] if n["method"] == "$/kals/analysed"]


def diags_after(c, start, uri):
    return [n["params"]["diagnostics"] for n in c.notes[start:]
            if n["method"] == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri]


def split_at_body_end(text):
    """(head, tail): tail starts at the `}` that ends the first top-level
    function or method body closed by a line holding only `}` or `    }`."""
    lines = text.split("\n")
    for i, l in enumerate(lines):
        if l in ("}", "    }") and i > 0 and lines[i - 1].strip().startswith("return "):
            return "\n".join(lines[:i - 1]) + "\n", "\n".join(lines[i - 1:])
    return None, None


def index_runs(server_pid):
    """Pids of the server's children that are a process per run (an index
    or a completion job): `--worker <out>` without the persistent workers'
    flags. Sampled, so it sees a run that lasts longer than the sampling
    gap, which on a graph of hundreds of files every one does."""
    out = set()
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            stat = open(f"/proc/{p}/stat").read()
            if int(stat.rsplit(")", 1)[1].split()[1]) != server_pid:
                continue
            cmd = open(f"/proc/{p}/cmdline", "rb").read().decode(errors="replace").split("\0")
        except (OSError, ValueError, IndexError):
            continue
        if "--worker" in cmd and not any(w in ("--index-server", "--syntax-server", "--syntax-only") for w in cmd):
            out.add(int(p))
    return out


def wait(c, pred, seconds):
    end = time.time() + seconds
    while time.time() < end:
        r = pred()
        if r:
            return r
        c.pump(0.003)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kals")
    ap.add_argument("workspace")
    ap.add_argument("--entry", required=True)
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--live", dest="live", action="store_true", default=True)
    ap.add_argument("--no-live", dest="live", action="store_false")
    ap.add_argument("--keys", type=int, default=30)
    ap.add_argument("--no-complete", action="store_true")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()

    root = os.path.realpath(args.workspace)
    c = Client(os.path.realpath(args.kals), root, env={"KALS_LIVE_CHECK": "1" if args.live else "0"})
    c.start({"liveCheck": args.live, "debounceMs": 0, "syntaxDebounceMs": 0})
    t0 = time.time()
    c.open(args.entry)
    ok = c.settle(args.timeout)
    print(f"{'live' if args.live else 'per-run'}: first check of {args.entry}: {time.time() - t0:.1f} s, settled={ok}, load {os.getloadavg()[0]:.0f}")

    for rel in args.file:
        text = c.open(rel)
        uri = c.uri(rel)
        c.pump(1.0)
        c.request("textDocument/hover", c.at(rel, 0, 0), timeout=args.timeout)
        c.settle(30)
        c.pump(0.5)
        head, tail = split_at_body_end(text)
        top = head is None
        if top:
            # No function body (a file of constants): the line is typed at
            # the top level, which no check can take in part (`unchecked`).
            head, tail, indent = text + "\n", "", ""
            decl = lambda v: f"const kalsBench: i64 = {v}"
        else:
            indent = "    " if tail.startswith("    ") and not tail.startswith("        ") else "        "
            decl = lambda v: f"var kalsBench = {v}"
        seen = set()
        version = [1]

        def change(t):
            version[0] += 1
            mark = len(c.notes)
            c.change(rel, version[0], t)
            return mark, time.time()

        # A half-typed line.
        mark, t0 = change(head + indent + decl("1 +" if top else "\"abc\" +") + "\n" + tail)
        got = wait(c, lambda: [d for d in diags_after(c, mark, uri) if any(str(x.get("code", "")).startswith("S") for x in d)], 60)
        broken_ms = (time.time() - t0) * 1000 if got else -1
        got = wait(c, lambda: [a for a in analysed_after(c, mark) if a["revision"] >= a["current"]], args.timeout)
        checked_ms = (time.time() - t0) * 1000 if got else -1
        c.settle(args.timeout)
        runs = analysed_after(c, mark)
        how = ", ".join("run" if "mode" not in r else (r["mode"] + ("/aside " + r["aside"] if "aside" in r else "")) for r in runs)

        # The fix.
        good = head + indent + decl("1" if top else "\"abc\"") + "\n"
        mark, t0 = change(good + tail)
        got = wait(c, lambda: [a for a in analysed_after(c, mark) if a["revision"] >= a["current"]], args.timeout)
        fixed_ms = (time.time() - t0) * 1000 if got else -1
        fixed_how = ("run" if "mode" not in got[0] else got[0]["mode"]) if got else "none"
        c.settle(args.timeout)
        print(f"  {rel}: broken -> syntax diagnostics {broken_ms:.0f} ms, -> checked {checked_ms:.0f} ms ({how}); "
              f"fixed -> results {fixed_ms:.0f} ms ({fixed_how})")

        # Completion on a member of a fresh local.
        if not args.no_complete and not top:
            for recv, what in (("kalsBench.", "member of a new local"), ("kals", "a plain name")):
                body = good + indent + recv
                mark, _ = change(body + "\n" + tail)
                line = body.count("\n")
                t0 = time.time()
                r = c.request("textDocument/completion", {"textDocument": {"uri": uri},
                                                          "position": {"line": line, "character": len(indent + recv)}}, timeout=120)
                ms = (time.time() - t0) * 1000
                c.pump(0.2)
                done = [n["params"] for n in c.notes[mark:] if n["method"] == "$/kals/completed"]
                how = f"{done[-1]['how']}, server {done[-1]['us'] / 1000:.0f} ms" if done else "?"
                items = r.get("items", []) if isinstance(r, dict) else (r or [])
                c.settle(args.timeout)
                procs = [a for a in analysed_after(c, mark) if "mode" not in a]
                print(f"  {rel}: completion, {what}: {ms:.0f} ms ({how}), {len(items)} items, {len(procs)} process runs meanwhile")

        # A typing session.
        typed = "const kalsSession: i64 = kalsBench + 12345 * (67 - 8)" if top else "var kalsSession = kalsBench + \"12345\" + (\"67\" + \"8\")"
        typed = (typed * 4)[:args.keys] if len(typed) < args.keys else typed[:args.keys]
        mark = len(c.notes)
        t0 = time.time()
        for k in range(1, len(typed) + 1):
            change(good + indent + typed[:k] + "\n" + tail)
            for _ in range(3):
                c.pump(0.02)
                seen |= index_runs(c.p.pid)
        change(good + tail)
        end = time.time() + args.timeout
        while time.time() < end:
            seen |= index_runs(c.p.pid)
            a = analysed_after(c, mark)
            if a and a[-1]["revision"] >= a[-1]["current"] and a[-1].get("pending", 0) == 0:
                break
            c.pump(0.05)
        c.pump(0.5)
        seen |= index_runs(c.p.pid)
        runs = analysed_after(c, mark)
        procs = sum(1 for r in runs if "mode" not in r)
        aside = sum(1 for r in runs if "aside" in r)
        fulls = sum(1 for r in runs if r.get("mode") == "full")
        print(f"  {rel}: {len(typed)} keystrokes in {time.time() - t0:.1f} s: {len(seen)} per-run processes seen "
              f"(/proc, sampled every 20 ms), {procs} analyses without a mode, {fulls} whole checks in the worker (mode full), {len(runs) - procs} live answers ({aside} of them with an aside result that was still current)")
        change(text)
        c.settle(args.timeout)

    rc = c.stop()
    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    print(f"shutdown {rc}; server and workers: {ru.ru_utime + ru.ru_stime:.1f} CPU s; load {os.getloadavg()[0]:.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
