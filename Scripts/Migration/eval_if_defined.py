#!/usr/bin/env python3
# const eval if defined(X)  ->  eval if defined!(X)
#
# Two Stage 0 spellings of a compile-time branch on a target macro:
#   * `const eval if` -- Stage 1's form is `eval if` (Spec/Docs eval, "eval
#     if"); `const eval if` is S046E there ("expected a name after the
#     binding keyword": `const` reads as a binding).
#   * `defined(X)` -- Stage 1's is the builtin macro `defined!(X)` (Spec/Docs
#     macros-builtin, "conditional"); a bare `defined(` is a call to a
#     function nobody declared. Stage 0 also writes it in the `else if` arms
#     of such a chain (ThreadPool.k), so every `defined(` in code is
#     rewritten, not only the ones in an `eval if` head -- except the
#     declaration `fn defined()` and member calls (`.defined(`, `::defined(`).
#
#     python3 Scripts/Migration/eval_if_defined.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/eval_if_defined.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

CONST_EVAL_IF = re.compile(r"\bconst\s+(eval\s+if\b)")
DEFINED = re.compile(r"(?<![\w.:>])defined(\s*)\(")


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in CONST_EVAL_IF.finditer(src):
        if mask[m.start()]:
            edits.append((m.start(), m.start(1), ""))
    for m in DEFINED.finditer(src):
        if not mask[m.start()]:
            continue
        if re.search(r"\bfn\s+$", src[max(0, m.start() - 20):m.start()]):
            continue
        edits.append((m.start() + len("defined"), m.start() + len("defined"), "!"))
    for a, b, t in sorted(edits, reverse=True):
        src = src[:a] + t + src[b:]
    return src, len(edits)


CASES = [
    ("const eval if defined(_WIN32) {", "eval if defined!(_WIN32) {"),
    ("const eval if defined(__APPLE__) || defined(__linux__) {",
     "eval if defined!(__APPLE__) || defined!(__linux__) {"),
    ("} else if defined(_WIN32) {", "} else if defined!(_WIN32) {"),
    ("eval if defined!(X) {", "eval if defined!(X) {"),
    ("static fn defined() -> string {", "static fn defined() -> string {"),
    ("x.defined(a); LangItems::defined()", "x.defined(a); LangItems::defined()"),
    ('// const eval if defined(X)', '// const eval if defined(X)'),
    ("eval if std::Meta::is_same_as::<T, U> {", "eval if std::Meta::is_same_as::<T, U> {"),
]


def selftest():
    bad = 0
    for src, want in CASES:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        ok = got == want and n2 == 0
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "const eval if / defined(X) -> eval if / defined!(X)"))
