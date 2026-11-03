#!/usr/bin/env python3
# typename!(T::X)  ->  T::X
#
# Stage 0's `typename!` is C++'s `typename` disambiguator for a dependent
# name (`typename T::PendingQuals`). Stage 1 has no such macro (R013E
# "unknown macro 'typename!'", 17 sites in Parser/ on 2026-11-03) and needs
# none: a generic body is checked per instantiation under -fduck-generics
# (Scripts/Migration/README), where `T::X` is resolved against the actual T,
# so the bare path means what `typename T::X` meant. No marker: the meaning
# is unchanged.
#
#     python3 Scripts/Migration/typename_macro.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/typename_macro.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

HEAD = re.compile(r"\btypename!\s*\(")


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in HEAD.finditer(src):
        if not mask[m.start()]:
            continue
        i, depth = m.end() - 1, 0
        while i < len(src):
            if mask[i]:
                if src[i] == "(":
                    depth += 1
                elif src[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
            i += 1
        if i >= len(src):
            continue
        edits.append((m.start(), i + 1, src[m.end():i].strip()))
    for a, b, t in reversed(edits):
        src = src[:a] + t + src[b:]
    return src, len(edits)


CASES = [
    ("var annot: typename!(T::PendingAnnotations);", "var annot: T::PendingAnnotations;"),
    ("fn f(q: typename!(T::Q<U>)) -> typename!(T::R)", "fn f(q: T::Q<U>) -> T::R"),
    ("// typename!(T::X)", "// typename!(T::X)"),
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
    sys.exit(run(rewrite, "typename!(T::X) -> T::X"))
