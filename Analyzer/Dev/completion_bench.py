#!/usr/bin/env python3
"""Times completion on a real project, by kind, as a typing session.

  completion_bench.py <kals> <workspace> --entry REL --file REL [--file REL ...]
                      [--count N] [--fallback N] [--seed S] [--no-index]

The workspace is opened as an editor would. --entry is opened first and its
first check waited for; then the --files. Every request follows a didChange
of the whole text (one keystroke typed or deleted on a line inserted into a
function body, or at the top of the file for imports), so the index is of an
older text and the buffer as a rule does not parse: the situation while
typing. The server's own time is read from `$/kals/completed` (`us`: from the
request to the answer), with how it was answered.

Kinds, N requests each (--count, default 200):

  name       a word typed letter by letter at a statement's start, then
             deleted letter by letter (the words are names the file uses)
  keyword    the same with keywords (`return`, `while`, ...)
  macro      the same with builtin macro names (`stringify`, `embed_str`)
  member     `<receiver>.` then letters, the receiver taken from the file's
             own member accesses (a chain of names). Two rows: the ones
             answered from the index, and `member (compiler)`, the ones the
             index did not type, whose receivers are listed after the table
  attribute  `@` then letters
  import     `import ` and a path typed segment by segment
  header     `ffi "c++" import "` and a path typed letter by letter
  fallback   a member after an indexed receiver (`a.b[i].`), which the
             index does not type: the compiler answers (--fallback N,
             default 20: each is a re-check of the file)

Prints per kind: requests, how they were answered, items per answer, and
p50 / p95 / max of the server's microseconds, with the machine's load.
--no-index starts the server with `indexCompletion: false` (every list is
the compiler's), for the same table before this path existed.
"""

import argparse
import os
import random
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client
from completion_oracle import MEMBER, code_part, in_string, sites_of

INDEXED = re.compile(r"((?:[A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*\[[^\]\[]*\])(\.|->)(?=[A-Za-z_])")
KEYWORDS = ["return", "while", "match", "continue", "break", "const", "unsafe", "false", "sizeof", "finally"]
MACROS = ["stringify", "embed_str", "compile_error", "unreachable", "count", "paste", "unique_id", "todo"]
ATTRS = ["deprecated", "no_warn", "align", "hot_path", "preserve_most", "likely", "pure", "inout"]
HEADERS = ["vector", "cstdio", "llvm/ADT/StringRef.h", "llvm/Support/Program.h", "string", "optional", "chrono"]


def pct(v, p):
    if not v:
        return 0
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kals")
    ap.add_argument("workspace")
    ap.add_argument("--entry", required=True)
    ap.add_argument("--file", action="append", required=True)
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--fallback", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--no-index", action="store_true")
    a = ap.parse_args()

    root = os.path.abspath(a.workspace)
    rnd = random.Random(a.seed)
    c = Client(os.path.abspath(a.kals), root)
    c.start({"indexCompletion": False} if a.no_index else {})
    c.open(a.entry)
    t0 = time.time()
    if not c.settle(1800):
        sys.exit("the first check did not land")
    print(f"first check: {time.time() - t0:.0f} s; load {os.getloadavg()[0]:.1f}", flush=True)

    files = {}
    for rel in a.file:
        text = open(os.path.join(root, rel)).read()
        c.open(rel, text)
        members, names = sites_of(text)
        lines = text.split("\n")
        words = sorted({w for w in re.findall(r"[A-Za-z_]\w{3,}", text)})
        indexed = []
        for ln, line in enumerate(lines):
            code = code_part(line)
            if code is None:
                continue
            for m in INDEXED.finditer(code):
                if not in_string(code, m.start()):
                    indexed.append((ln, len(line) - len(line.lstrip(" ")), m.group(1) + m.group(2)))
        files[rel] = (text, lines, members, names, words, indexed)
    c.settle(900)

    version = [100]
    stats = {}

    def request(kind, rel, text, line, col, timeout=180):
        version[0] += 1
        c.change(rel, version[0], text)
        start = len(c.notes)
        wall = time.time()
        r = c.request("textDocument/completion", c.at(rel, line, col), timeout=timeout)
        wall = (time.time() - wall) * 1e6
        c.pump(0.01)
        done = [n["params"] for n in c.notes[start:] if n["method"] == "$/kals/completed"]
        d = done[-1] if done else {}
        items = r.get("items") if isinstance(r, dict) else (r or [])
        # A member is two rows: answered from the index, or by the compiler.
        if kind == "member" and d.get("how") != "index":
            fell = stats.setdefault("member", {"us": [], "wall": [], "how": {}, "items": []}).setdefault("fell", {})
            key = text.split("\n")[line].strip()
            fell[key] = fell.get(key, 0) + 1
            kind = "member (compiler)"
        st = stats.setdefault(kind, {"us": [], "wall": [], "how": {}, "items": []})
        st["us"].append(d.get("us", 0))
        st["wall"].append(wall)
        st["how"][d.get("how", "?")] = st["how"].get(d.get("how", "?"), 0) + 1
        st["items"].append(len(items or []))

    def typed(kind, rel, line, prefix, word, count, backspace=True):
        """Types `word` after `prefix` on a new line above `line`, a request
        per keystroke, then deletes it again; stops at `count` requests."""
        text, lines = files[rel][0], files[rel][1]
        n = 0
        steps = [word[:k] for k in range(1, len(word) + 1)]
        if backspace:
            steps += [word[:k] for k in range(len(word) - 1, 0, -1)]
        for s in steps:
            if n >= count:
                break
            new = prefix + s
            request(kind, rel, "\n".join(lines[:line] + [new] + lines[line:]), line, len(new))
            n += 1
        return n

    rels = list(files)

    def some_site(rel, which):
        pool = files[rel][which]
        return pool[rnd.randrange(len(pool))] if pool else None

    def run(kind, count, make):
        done, guard = 0, 0
        while done < count and guard < count * 4:
            guard += 1
            done += make(rels[guard % len(rels)], count - done)
        print(f"{kind}: {done} requests", flush=True)

    def name_kind(kind, pool):
        def make(rel, left):
            s = some_site(rel, 3)
            if not s:
                return 0
            word = pool(rel)
            return typed(kind, rel, s[0], " " * s[1], word, left)
        return make

    run("name", a.count, name_kind("name", lambda rel: rnd.choice(files[rel][4])))
    run("keyword", a.count, name_kind("keyword", lambda rel: rnd.choice(KEYWORDS)))
    run("macro", a.count, name_kind("macro", lambda rel: rnd.choice(MACROS)))

    def member(rel, left):
        s = some_site(rel, 2)
        if not s:
            return 0
        line, col, inserted = s
        after = files[rel][1][line][col:]
        word = re.match(r"\w*", after).group(0)[:4] or "a"
        text, lines = files[rel][0], files[rel][1]
        request("member", rel, "\n".join(lines[:line] + [inserted] + lines[line:]), line, len(inserted))
        return 1 + typed("member", rel, line, inserted, word, left - 1)
    run("member", a.count, member)

    def attribute(rel, left):
        s = some_site(rel, 3)
        if not s:
            return 0
        return typed("attribute", rel, s[0], " " * s[1] + "@", rnd.choice(ATTRS), left)
    run("attribute", a.count, attribute)

    def imports(rel, left):
        text, lines = files[rel][0], files[rel][1]
        imps = [l for l in lines if l.startswith("import ") and "{" not in l]
        if not imps:
            return 0
        path = rnd.choice(imps)[len("import "):].strip()
        return typed("import", rel, 0, "import ", path, left, backspace=False)
    run("import", a.count, imports)

    def header(rel, left):
        return typed("header", rel, 0, 'ffi "c++" import "', rnd.choice(HEADERS), left, backspace=False)
    run("header", a.count, header)

    def fallback(rel, left):
        pool = files[rel][5]
        if not pool:
            return 0
        line, indent, recv = pool[rnd.randrange(len(pool))]
        text, lines = files[rel][0], files[rel][1]
        new = " " * indent + recv
        request("fallback", rel, "\n".join(lines[:line] + [new] + lines[line:]), line, len(new), timeout=600)
        return 1
    if a.fallback:
        run("fallback", a.fallback, fallback)

    print()
    print(f"load {os.getloadavg()[0]:.1f} / {os.getloadavg()[1]:.1f} (1 / 5 min), {os.cpu_count()} CPUs")
    print(f"{'kind':18} {'n':>4} {'how':22} {'items p50':>9} {'us p50':>8} {'us p95':>8} {'us max':>9}   {'wall ms p50':>11} {'p95':>6}")
    for kind, st in stats.items():
        how = ",".join(f"{k}:{v}" for k, v in sorted(st["how"].items()))
        if not st["us"]:
            continue
        print(f"{kind:18} {len(st['us']):4} {how:22} {pct(st['items'], 0.5):9} {pct(st['us'], 0.5):8} {pct(st['us'], 0.95):8} {max(st['us']):9}   "
              f"{pct(st['wall'], 0.5) / 1000:11.1f} {pct(st['wall'], 0.95) / 1000:6.1f}")
    fell = stats.get("member", {}).get("fell", {})
    if fell:
        print()
        print("member receivers the index did not type (the compiler answered):")
        for key, n in sorted(fell.items(), key=lambda kv: -kv[1])[:25]:
            print(f"  {n:3}  {key}")
    for rel in rels:
        version[0] += 1
        c.change(rel, version[0], files[rel][0])
    c.stop()


if __name__ == "__main__":
    main()
