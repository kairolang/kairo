#!/usr/bin/env python3
# default class X { ... }  ->  class X { ... }
#
# Stage 0's `default` on a type only made it emit the C++ rule of five
# (defaulted copy / move constructors and assignments, destructor). Stage 1
# has no such modifier -- `default` before `class` is S052E "expected
# expression, found 'default'" -- and derives a class's lifecycle by its own
# rules (Spec/Docs classes-lifecycle: the transfer constructor, the generated
# `op =`), so the modifier is dropped rather than translated (the user's
# call, 2026-11-03). One site on 2026-11-03: Compiler/Support/FileIO/Path.k:51.
#
# Only a `default` that directly precedes the type keyword (optionally with a
# visibility between) is touched; `default` as a match arm or as the
# `= default` suffix never is.
#
#     python3 Scripts/Migration/default_class.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/default_class.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

HEAD = re.compile(r"\bdefault[ \t]+(?=(?:(?:pub|priv|prot)[ \t]+)?(?:class|struct)\b)")


def rewrite(src, path, report):
    mask = code_mask(src)
    hits = [m for m in HEAD.finditer(src) if mask[m.start()]]
    for m in reversed(hits):
        src = src[:m.start()] + src[m.end():]
    return src, len(hits)


CASES = [
    ("default class Path {", "class Path {"),
    ("default pub struct P {", "pub struct P {"),
    ("    default { return 0 }", "    default { return 0 }"),
    ("fn P(self) = default", "fn P(self) = default"),
    ("// default class Path {", "// default class Path {"),
    ("var s = \"default class\"", "var s = \"default class\""),
]


def selftest():
    bad = 0
    for src, want in CASES:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        ok = got == want and n2 == 0 and again == got
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "default class X -> class X"))
