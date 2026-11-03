#!/usr/bin/env python3
# Identifiers that are Stage 1 keywords -> `#name`.
#
# Stage 0 lets `test` and `loop` name parameters, locals and fields
# (`fn _abort_unless(..., test: *Expr)`, `var loop = ...`, `opd.test`);
# both are keywords in Stage 1 (Compiler/Token/TokenText.k), where such a
# name is S047E / S046E / S048E. Stage 1 writes a keyword-spelled name with a
# leading `#` (Tests/Sema/FFI/keyword_escape_cxx_names.k: `var #in = 3`;
# `#test` / `.#test` / `#loop` checked with --syntax-only, 2026-11-02).
#
# Every code occurrence is escaped -- the declaration, its uses, and member
# accesses whose field is declared in another file -- except the keyword's
# own statement uses: `loop {` and `test "name" {`. The word list
# is what a scan of Compiler/, Linker/ and Extras/KaTAR found used as a name
# (test 12 declarations, loop 3); the rest of TokenText.k's keywords never
# are.
#
#     python3 Scripts/Migration/keyword_idents.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/keyword_idents.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

WORDS = ("test", "loop")
TOK = re.compile(r"(?<![\w#$])(%s)(?!\w)" % "|".join(WORDS))


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in TOK.finditer(src):
        if not all(mask[k] for k in range(m.start(), m.end())):
            continue
        rest = src[m.end():m.end() + 40].lstrip(" \t")
        if (m.group(1) == "loop" and rest.startswith("{")) or (m.group(1) == "test" and rest.startswith('"')):
            continue                       # the keyword itself
        edits.append(m.start())
    for k in reversed(edits):
        src = src[:k] + "#" + src[k:]
    return src, len(edits)


CASES = [
    ("priv fn _absent(self, at: SourceRange, test: unsafe *Expr) -> unsafe *Expr {",
     "priv fn _absent(self, at: SourceRange, #test: unsafe *Expr) -> unsafe *Expr {"),
    ("var loop = self._lower(n, &pre);", "var #loop = self._lower(n, &pre);"),
    ("var ie = self._select(n->range, opd.test, opd.value);",
     "var ie = self._select(n->range, opd.#test, opd.value);"),
    ("if test { return loop }", "if #test { return #loop }"),
    ("loop {", "loop {"),
    ("    loop{ break }", "    loop{ break }"),
    ('test "adds" {', 'test "adds" {'),
    ("// a test of the loop", "// a test of the loop"),
    ('var s = "test"', 'var s = "test"'),
    ("var tests = testing + loops", "var tests = testing + loops"),
    ("var #test = 1", "var #test = 1"),
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
    sys.exit(run(rewrite, "Stage 1 keywords used as names -> #name"))
