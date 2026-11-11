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
"""
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


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("edits", "rows"):
        sys.exit(__doc__)
    {"edits": edits, "rows": rows}[sys.argv[1]](os.path.abspath(sys.argv[2]))
