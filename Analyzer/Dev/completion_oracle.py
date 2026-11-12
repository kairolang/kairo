#!/usr/bin/env python3
"""Compares completion answered from the index with the compiler's own list.

  completion_oracle.py <kals> <workspace> --entry REL --file REL [--file REL ...]
                       [--sites N] [--seed S] [--no-stale] [--json OUT] [--show K]

Two servers are started on the workspace: one answers completion from the
index (the default), the other is told `indexCompletion: false`, so every
list is the marked buffer's compile (the live worker's copy, or a run): the
compiler's own answer, the oracle. --entry is opened first in both, then per
--file up to N sites of each kind are sampled (seeded) and asked of both:

  member   the cursor right after a `.`, `->` or `::` that follows a chain of
           names, each possibly called (`a.b(x).`), in a function body
  name     the cursor at the start of a name used in a body: not a keyword,
           not a member, not a name being declared or a field's label

Each site is asked twice. "fresh": the buffer as it is on disk, so the index
is of this text. "stale" (unless --no-stale): a new line is inserted above
the site's line that ends where the cursor is put (the receiver and its
operator for a member site, the indentation alone for a name site), and the
request follows the change at once: the index is then of the text before the
edit, the line is one it has no rows for, and the buffer does not parse. The
text is put back after each.

What is compared is the set of item labels that are declarations: keywords
(kind 14) and macros (a label ending in `!`) are left out, since the index
path offers the keywords of the position and the oracle all of them, and the
oracle offers no macros. A site the index path did not answer (`how` is not
`index`) is counted as a fallback and not compared. A site the ORACLE did
not answer (no item, or the file's outline: its marked copy was not checked,
or the compiler's walk does not visit the place as a name) is listed at the
end with what the index path offered there, for reading.

A local the oracle offers and the index list lacks is looked up in the text
by this script: when the block it is declared in has closed before the site
it is counted as "closed block" (the compiler's walk knows the function a
local is in, not the block, and offers it; the index path does not), and it
is not a miss.

Prints, per kind and variant: sites, fallbacks, sites the oracle could not
answer (its marked copy was not checked), exact matches, and every
difference classified by direction (missing from the index list / extra in
it), the item's kind and its sort group. Exits 1 when any label is missing.
"""

import argparse
import json
import os
import random
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client

KINDS = {1: "text", 2: "method", 3: "function", 5: "field", 6: "variable", 7: "class", 8: "interface", 9: "module",
         13: "enum", 14: "keyword", 15: "snippet", 20: "enumMember", 21: "constant", 22: "struct", 25: "typeParam"}
GROUPS = {"0": "local", "1": "enclosing type", "2": "file", "3": "import", "4": "prelude"}

WORDS = set("""fn var const static eval if else unless while for loop match case default return break continue class
struct enum union interface extend impl derives module import ffi pub priv prot unsafe inline virtual override final
async await spawn yield try catch finally panic true false null self Self as in is where requires type macro test
delete sizeof alignof typeof assert op thread and or not xor bitand bitor compl i8 i16 i32 i64 i128 isize u8 u16 u32
u64 u128 usize f32 f64 bool char byte void string""".split())
NAME = re.compile(r"(?<![\w.>:@!])([A-Za-z_]\w*)(?![\w!]|\s*:(?!:))")
DECLARES = re.compile(r"\b(fn|class|struct|enum|union|interface|module|macro|type|var|const|for|catch|test|eval|static|unsafe|case)\s+(\*\s*|&\s*)?$")
MEMBER = re.compile(r"((?:[A-Za-z_]\w*(?:\([^()\n]*\))?)(?:(?:\.|->|::)[A-Za-z_]\w*(?:\([^()\n]*\))?)*)(\.|->|::)(?=[A-Za-z_])")


def code_part(line):
    """The line without a trailing // comment; None when it is no code."""
    s = line.strip()
    if not s or s.startswith("//") or s.startswith("import ") or s.startswith("ffi ") or s.startswith("*") or s.startswith("/*"):
        return None
    k = line.find("//")
    return line if k < 0 else line[:k]


def in_string(line, col):
    return line[:col].count('"') % 2 == 1


def sites_of(text):
    """(members, names): each a list of (line, col, inserted_line)."""
    members, names = [], []
    depth_fn = False
    for ln, line in enumerate(text.split("\n")):
        code = code_part(line)
        if code is None:
            continue
        indent = len(line) - len(line.lstrip(" "))
        if re.match(r"\s*(pub |priv |prot |static |inline |unsafe |override |virtual |final )*fn\b", line):
            depth_fn = True
            continue
        if indent == 0:
            depth_fn = False
        if not depth_fn or indent < 4:
            continue
        for m in MEMBER.finditer(code):
            if in_string(code, m.start()) or (m.start() > 0 and (code[m.start() - 1].isalnum() or code[m.start() - 1] in "_.>:")):
                continue
            members.append((ln, m.end(), " " * indent + m.group(1) + m.group(2)))
        for m in NAME.finditer(code):
            w = m.group(1)
            if w in WORDS or in_string(code, m.start()) or DECLARES.search(code[:m.start()]):
                continue
            names.append((ln, m.start(), " " * indent))
    return members, names


def degraded(items):
    """The oracle's copy was not checked: the server answered with the
    file's outline (every item a variable with no sort group) or nothing."""
    real = [i for i in items or [] if i.get("kind") != 14]
    return not real or all(not i.get("sortText") for i in real)


def closed_block(text, name, site_off):
    """Whether the nearest declaration of local `name` before `site_off` is
    in a block that has closed by then (or opens one, as a `for` variable
    does, that has)."""
    best = None
    for m in re.finditer(r"\b(?:var|const|eval)\s+(?:unsafe\s+)?[*&]?\s*" + re.escape(name) + r"\b|\bfor\s+(?:unsafe\s+)?[*&]?\s*" + re.escape(name) + r"\s+in\b|\bcatch\s+" + re.escape(name) + r"\b", text[:site_off]):
        best = m
    if best is None:
        return None
    start = best.end()
    # Declared in a header: `for x in`, `catch e`, and the `var i` of
    # `for var i = 0; ..; .. {`, which are the block's that follows.
    ls = text.rfind("\n", 0, best.start()) + 1
    header = text[best.start():best.start() + 6].startswith(("for", "catch")) or text[ls:best.start()].strip() == "for"
    depth, opened = 0, not header
    k = start
    while k < site_off:
        ch = text[k]
        if ch == "/" and text[k:k + 2] == "//":
            k = text.find("\n", k)
            if k < 0:
                break
            continue
        if ch == '"':
            e = k + 1
            while e < site_off and text[e] != '"' and text[e] != "\n":
                e += 2 if text[e] == "\\" else 1
            k = e + 1
            continue
        # A character literal: `'{'`, `'\\n'`.
        if ch == "'" and (text[k + 2:k + 3] == "'" or (text[k + 1:k + 2] == "\\" and text[k + 3:k + 4] == "'")):
            k += 4 if text[k + 1] == "\\" else 3
            continue
        if ch == "{":
            depth += 1
            opened = True
        elif ch == "}":
            depth -= 1
            if depth < 0 or (header and opened and depth == 0):
                return True
        k += 1
    return False


def labels(items):
    out = {}
    for i in items or []:
        if i.get("kind") == 14 or i["label"].endswith("!"):
            continue
        out[i["label"]] = (KINDS.get(i.get("kind"), str(i.get("kind"))), (i.get("sortText") or "?")[:1])
    return out


def ask(c, rel, line, col, timeout=180):
    start = len(c.notes)
    r = c.request("textDocument/completion", c.at(rel, line, col), timeout=timeout)
    c.pump(0.05)
    done = [n["params"] for n in c.notes[start:] if n["method"] == "$/kals/completed"]
    items = r.get("items") if isinstance(r, dict) else r
    return items or [], (done[-1] if done else {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kals")
    ap.add_argument("workspace")
    ap.add_argument("--entry", required=True)
    ap.add_argument("--file", action="append", required=True)
    ap.add_argument("--sites", type=int, default=12)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--no-stale", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--show", type=int, default=6)
    a = ap.parse_args()

    root = os.path.abspath(a.workspace)
    rnd = random.Random(a.seed)
    idx = Client(os.path.abspath(a.kals), root)
    ora = Client(os.path.abspath(a.kals), root)
    idx.start()
    ora.start({"indexCompletion": False})
    for c in (idx, ora):
        c.open(a.entry)
    t0 = time.time()
    for c in (idx, ora):
        if not c.settle(1800):
            sys.exit("the first check did not land")
    print(f"first check of both servers: {time.time() - t0:.0f} s", flush=True)

    unanswered = []
    stats = {}   # (kind, variant) -> {"sites", "fallback", "exact", "diff": {class: count}}
    examples = {}
    rows = []
    version = 10

    def record(kind, variant, rel, text, line, col, a_items, a_done, b_items, b_done):
        st = stats.setdefault((kind, variant), {"sites": 0, "fallback": 0, "exact": 0, "empty_oracle": 0, "us": []})
        st["sites"] += 1
        if a_done.get("how") != "index":
            st["fallback"] += 1
            return
        st["us"].append(a_done.get("us", 0))
        la, lb = labels(a_items), labels(b_items)
        if degraded(b_items):
            # The oracle found nothing at the marker (its copy was not
            # checked, or its walk does not visit the place as a name):
            # nothing to compare with. Listed at the end, with what the
            # index path offered there.
            st["empty_oracle"] += 1
            src = text.split("\n")[line]
            unanswered.append({"kind": kind, "variant": variant, "file": rel, "line": line, "col": col,
                               "text": src[:col] + "|" + src[col:], "index": sorted(la)[:12], "count": len(la),
                               "oracle_how": b_done.get("how")})
            return
        offs = [0]
        for l in text.split("\n"):
            offs.append(offs[-1] + len(l) + 1)
        site_off = offs[line] + col
        # Not misses: a local of a block that has closed (see the docstring).
        closed = {n for n in set(lb) - set(la) if lb[n][1] == "0" and closed_block(text, n, site_off)}
        if closed:
            st["closed"] = st.get("closed", 0) + len(closed)
        if set(la) == set(lb) - closed:
            st["exact"] += 1
            return
        for name in sorted(set(lb) - set(la) - closed):
            k = ("missing", lb[name][0], GROUPS.get(lb[name][1], lb[name][1]))
            st.setdefault("diff", {}).setdefault(k, 0)
            st["diff"][k] += 1
            examples.setdefault((kind, variant) + k, []).append(f"{rel}:{line + 1}:{col + 1} {name}")
        for name in sorted(set(la) - set(lb)):
            k = ("extra", la[name][0], GROUPS.get(la[name][1], la[name][1]))
            st.setdefault("diff", {}).setdefault(k, 0)
            st["diff"][k] += 1
            examples.setdefault((kind, variant) + k, []).append(f"{rel}:{line + 1}:{col + 1} {name}")
        rows.append({"kind": kind, "variant": variant, "file": rel, "line": line, "col": col,
                     "missing": sorted(set(lb) - set(la) - closed), "closed": sorted(closed),
                     "extra": sorted(set(la) - set(lb))})

    for rel in a.file:
        text = open(os.path.join(root, rel)).read()
        for c in (idx, ora):
            c.open(rel, text)
        for c in (idx, ora):
            c.settle(40)
        members, names = sites_of(text)
        picked = [("member", s) for s in rnd.sample(members, min(a.sites, len(members)))]
        picked += [("name", s) for s in rnd.sample(names, min(a.sites, len(names)))]
        lines = text.split("\n")
        for kind, (line, col, inserted) in picked:
            ai, ad = ask(idx, rel, line, col)
            bi, bd = ask(ora, rel, line, col)
            record(kind, "fresh", rel, text, line, col, ai, ad, bi, bd)
            if a.no_stale:
                continue
            version += 1
            edited = "\n".join(lines[:line] + [inserted] + lines[line:])
            for c in (idx, ora):
                c.change(rel, version, edited)
            ai, ad = ask(idx, rel, line, len(inserted))
            bi, bd = ask(ora, rel, line, len(inserted))
            record(kind, "stale", rel, edited, line, len(inserted), ai, ad, bi, bd)
            version += 1
            for c in (idx, ora):
                c.change(rel, version, text)
            for c in (idx, ora):
                c.settle(40)
        print(f"{rel}: {len(picked)} sites", flush=True)

    missing = 0
    print()
    print(f"{'kind':8} {'variant':6} {'sites':>5} {'fallback':>8} {'no oracle':>9} {'compared':>8} {'exact':>6} {'closed-block locals':>19} {'p50 us':>7} {'max us':>7}")
    for (kind, variant), st in sorted(stats.items()):
        us = sorted(st["us"])
        compared = st["sites"] - st["fallback"] - st["empty_oracle"]
        print(f"{kind:8} {variant:6} {st['sites']:5} {st['fallback']:8} {st['empty_oracle']:9} {compared:8} {st['exact']:6} {st.get('closed', 0):19} "
              f"{(us[len(us) // 2] if us else 0):7} {(us[-1] if us else 0):7}")
    print()
    print("differences (labels, summed over sites):")
    for (kind, variant), st in sorted(stats.items()):
        for k, n in sorted(st.get("diff", {}).items()):
            if k[0] == "missing":
                missing += n
            ex = examples[(kind, variant) + k][:a.show]
            print(f"  {kind:7} {variant:6} {k[0]:8} {k[1]:10} {k[2]:15} {n:6}   e.g. " + "; ".join(ex))
    if unanswered:
        print()
        print("sites the oracle did not answer (what the index path offered there):")
        for u in unanswered:
            print(f"  {u['kind']:6} {u['variant']:5} {u['file']}:{u['line'] + 1}:{u['col'] + 1}  {u['text'].strip()[:90]}  -> {u['count']} items {u['index'][:6]}")
    if a.json:
        json.dump({"stats": {f"{k[0]}/{k[1]}": {kk: (vv if kk != "diff" else {"/".join(d): n for d, n in vv.items()})
                                             for kk, vv in v.items() if kk != "us"} for k, v in stats.items()},
                   "rows": rows, "unanswered": unanswered}, open(a.json, "w"), indent=1)
    for c in (idx, ora):
        c.stop()
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
