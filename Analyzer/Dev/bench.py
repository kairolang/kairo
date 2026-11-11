#!/usr/bin/env python3
"""Micro-benchmarks for kals's cost rules (Compiler/Spec/LanguageServer.md
section 13). Run against any kals binary, so an older build gives the
"before" numbers:

    python3 Analyzer/Dev/bench.py edits path/to/kals   # ms per didChange on a 1 MB buffer
    python3 Analyzer/Dev/bench.py rows  path/to/kals   # ms per hover on a file with 20,000 refs

`edits` opens a 1 MB buffer (comment lines, so its analysis is cheap) and
sends 10,000 single-character edits: typing at a cursor in the middle, then
at random positions. Each run ends with a request the server answers in
order and without the text (`workspace/symbol`), so the time to its answer
is the time the edits took; the same request alone is subtracted.

`rows` writes a file with 20,000 name uses, waits for its index, and times
hovers at its last line (the end a linear scan reaches last).

    python3 Analyzer/Dev/bench.py syntax path/to/kals  # keystroke -> syntax diagnostics

`syntax` times keystroke-to-syntax-diagnostics through the server (section
11, the syntax row): a 3,000-line file and a one-line file, 200 edits each
that alternately break and repair the last line, each timed from the
didChange to the publishDiagnostics that reflects it. The Sema run is held
off (debounceMs 5000); the syntax debounce is the default.
"""
import queue, statistics
import os, random, shutil, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client


def barrier(c):
    t = time.time()
    c.request("workspace/symbol", {"query": "zzzz_none"}, timeout=600)
    return time.time() - t


def edits(exe):
    base = tempfile.mkdtemp(prefix="kals-bench-")
    try:
        line = "// " + "x" * 60 + "\n"
        text = line * (1024 * 1024 // len(line))
        path = os.path.join(base, "big.k")
        open(path, "w").write(text)
        c = Client(exe, base)
        c.start({"debounceMs": 5000, "syntaxDebounceMs": 5000})
        c.open("big.k", text)
        barrier(c)
        idle = min(barrier(c) for _ in range(5))
        lines = text.count("\n")
        out = {}
        for mode in ("typing", "random"):
            rnd = random.Random(7)
            l, ch = lines // 2, 3
            t = time.time()
            for k in range(10000):
                if mode == "random":
                    l, ch = rnd.randrange(0, lines), rnd.randrange(0, 60)
                c.notify("textDocument/didChange", {"textDocument": {"uri": c.uri("big.k"), "version": k + 2},
                                                    "contentChanges": [{"range": {"start": {"line": l, "character": ch}, "end": {"line": l, "character": ch}}, "text": "a"}]})
                if mode == "typing":
                    ch += 1
            took = (time.time() - t) + barrier(c) - idle
            out[mode] = took * 1000 / 10000
        c.stop()
        print(f"edits on a {len(text) // 1024} KB buffer: typing {out['typing']:.3f} ms/edit, random positions {out['random']:.3f} ms/edit")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def rows(exe):
    base = tempfile.mkdtemp(prefix="kals-bench-")
    try:
        body = ["fn main() -> i32 {", "    var v: i32 = 0"]
        body += ["    v = v + 1"] * 10000
        body += ["    return v", "}", ""]
        text = "\n".join(body)
        open(os.path.join(base, "refs.k"), "w").write(text)
        c = Client(exe, base)
        c.start()
        c.open("refs.k", text)
        last = len(body) - 4
        h = c.request("textDocument/hover", c.at("refs.k", last, 8), timeout=600)
        if not h:
            print("no hover: the index did not come", h)
            return
        n = 300
        t = time.time()
        for _ in range(n):
            c.request("textDocument/hover", c.at("refs.k", last, 8))
        per = (time.time() - t) * 1000 / n
        t = time.time()
        for _ in range(n):
            c.request("workspace/symbol", {"query": "zzzz_none"})
        floor = (time.time() - t) * 1000 / n
        c.stop()
        print(f"hover on the last of ~20,000 refs: {per:.3f} ms per request (a request answered without rows: {floor:.3f} ms)")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def syntax_latency(exe, lines, n=200):
    base = tempfile.mkdtemp(prefix="kals-bench-")
    try:
        body = []
        for k in range(lines - 1):
            body.append("pub fn g%d(a: i32) -> i32 { return a + %d }" % (k, k))
        tail = "pub fn tail() -> i32 { return 0 }"
        body.append(tail)
        text = "\n".join(body) + "\n"
        open(os.path.join(base, "s.k"), "w").write(text)
        c = Client(exe, base)
        c.start({"debounceMs": 5000})
        c.open("s.k", text)
        uri, last = c.uri("s.k"), len(body) - 1
        col = tail.index("(") + 1

        def wait_diag(broken, limit=10):
            end = time.time() + limit
            while time.time() < end:
                try:
                    m = c.q.get(timeout=limit)
                except queue.Empty:
                    break
                if m is None:
                    raise RuntimeError("server exited")
                if m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri:
                    if any(d.get("code", "").startswith("S") and not d["code"].startswith("SC") for d in m["params"]["diagnostics"]) == broken:
                        return True
            return False

        wait_diag(False, 30)
        times, lost = [], 0
        for k in range(n):
            broken = k % 2 == 0
            rng = {"start": {"line": last, "character": col}, "end": {"line": last, "character": col if broken else col + 1}}
            t = time.time()
            c.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": k + 2},
                                                "contentChanges": [{"range": rng, "text": "(" if broken else ""}]})
            if wait_diag(broken):
                times.append((time.time() - t) * 1000)
            else:
                lost += 1
        c.stop()
        times.sort()
        p95 = times[int(len(times) * 0.95) - 1] if times else 0
        print(f"syntax diagnostics, {lines}-line file, {len(times)} edits: median {statistics.median(times):.1f} ms, "
              f"p95 {p95:.1f} ms, range {times[0]:.1f}..{times[-1]:.1f} ms, missing {lost}")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def syntax(exe):
    syntax_latency(exe, 3000)
    syntax_latency(exe, 1)


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("edits", "rows", "syntax"):
        sys.exit(__doc__)
    {"edits": edits, "rows": rows, "syntax": syntax}[sys.argv[1]](os.path.abspath(sys.argv[2]))
