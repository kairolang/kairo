#!/usr/bin/env python3
# libcxx::get::<N>(expr)  ->  (expr).N
#
# Every libcxx::get in Compiler/ and Linker/ indexes a tuple (audited Oct
# 2026: positional, all of them). A nested call in `expr` is matched by
# paren depth, not by regex, so `libcxx::get::<0>(f(a, b))` is right.
#
# NOT run as part of landing tuples: this tree is built by Stage 0, and
# Stage 0's own `t.N` on a libcxx tuple is not the Stage 1 lowering. Run it
# once the tree builds with a compiler that renders `t.N` on a C++ tuple.
#
#   python3 Scripts/Migration/tuple_get.py <tree>        rewrite in place
#   python3 Scripts/Migration/tuple_get.py <tree> --dry  report only
import os, re, sys

HEAD = re.compile(r"libcxx::get::<(\d+)>\(")

def rewrite(text):
    out, i, changed = [], 0, 0
    while True:
        m = HEAD.search(text, i)
        if not m:
            out.append(text[i:])
            return "".join(out), changed
        out.append(text[i:m.start()])
        depth, j = 1, m.end()
        while j < len(text) and depth:
            c = text[j]
            if c == "(": depth += 1
            elif c == ")": depth -= 1
            j += 1
        inner = text[m.end():j - 1]
        # a bare identifier or field path needs no parens; anything else does
        wrap = not re.fullmatch(r"[\w.]+(->\w+)*(\[\w+\])?", inner)
        out.append(("(%s)" if wrap else "%s") % inner + "." + m.group(1))
        changed += 1
        i = j

def main():
    if len(sys.argv) < 2:
        print(__doc__ or "usage: tuple_get.py <tree> [--dry]"); sys.exit(2)
    root, dry = sys.argv[1], "--dry" in sys.argv
    total = 0
    for sub in ("Compiler", "Linker"):
        for dp, _, fs in os.walk(os.path.join(root, sub)):
            for f in fs:
                if not f.endswith(".k"): continue
                p = os.path.join(dp, f)
                with open(p, encoding="utf-8") as fh: src = fh.read()
                new, k = rewrite(src)
                if not k: continue
                total += k
                print("%5d  %s" % (k, p))
                if not dry:
                    with open(p, "w", encoding="utf-8") as fh: fh.write(new)
    print("%5d  TOTAL" % total)

main()
