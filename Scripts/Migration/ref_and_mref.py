#!/usr/bin/env python3
# ref!(T) / mref(T) in PARAMETER position -> @inout x: T / @move x: T.
# Paren-balanced, so nested generics survive. Everything else untouched.
import re, sys, pathlib

HEAD = re.compile(r'(?P<lead>(?:const\s+)?)(?P<name>[A-Za-z_]\w*)\s*:\s*(?P<mac>ref!|mref!?)\(')

def rewrite(src: str) -> tuple[str, int]:
    out, i, n = [], 0, 0
    while True:
        m = HEAD.search(src, i)
        if not m:
            out.append(src[i:]); break
        depth, j = 1, m.end()
        while j < len(src) and depth:
            depth += {'(': 1, ')': -1}.get(src[j], 0); j += 1
        if depth:
            out.append(src[i:m.end()]); i = m.end(); continue
        inner = src[m.end():j - 1]
        mode = '@inout ' if m.group('mac') == 'ref!' else '@move '
        out.append(src[i:m.start()])
        out.append(f"{mode}{m.group('lead')}{m.group('name')}: {inner}")
        i = j; n += 1
    return ''.join(out), n

total = 0
for p in pathlib.Path(sys.argv[1]).rglob('*.k'):
    s = p.read_text(); r, n = rewrite(s)
    if n: p.write_text(r); total += n; print(f"{n:4d} {p}")
print(f"{total} declaration sites rewritten")