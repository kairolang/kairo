#!/usr/bin/env python3
# const fn f(self, ...)  ->  fn f(const self, ...)
#
# Stage 0's leading `const` on a method is C++'s trailing `const` (the method
# does not change its object). Stage 1 says that with the receiver,
# `fn f(const self)` (Spec/Docs functions-declarations, "const"); a leading
# `const fn` is S047E there ("a method cannot be const; 'const self' is how a
# method promises not to change its object"). 134 sites in Compiler/ on
# 2026-11-02, every one a method: operators (`const fn op == (self, ...)`)
# and generic methods (`const fn <T> f(self)`) included.
#
# A `const fn` whose first parameter is not `self` would be Stage 1's free
# const function, `fn f(...) const` -- a different promise. None exist; such
# a site is reported, never guessed.
#
#     python3 Scripts/Migration/const_fn_receiver.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/const_fn_receiver.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

HEAD = re.compile(r"\bconst(\s+)fn\b")


def _skip_angle(src, k):
    depth = 0
    while k < len(src):
        c = src[k]
        if c == "<":
            depth += 1
        elif c == ">" and src[k - 1] != "-":
            depth -= 1
            if depth == 0:
                return k + 1
        elif c in "{;":
            return -1
        k += 1
    return -1


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in HEAD.finditer(src):
        if not all(mask[k] for k in range(m.start(), m.end())):
            continue
        k = m.end()
        # optional generics, then the name (an identifier or `op <symbol>`),
        # then the parameter list
        while k < len(src) and src[k] in " \t":
            k += 1
        if k < len(src) and src[k] == "<":
            k = _skip_angle(src, k)
            if k < 0:
                continue
        p = src.find("(", k)
        if p < 0 or "\n" in src[k:p] or "{" in src[k:p]:
            continue
        q = p + 1
        while q < len(src) and src[q] in " \t\r\n":
            q += 1
        if re.match(r"self\b", src[q:]):
            edits.append((m.start(), m.end() - 2, ""))           # drop `const` + blanks
            edits.append((q, q, "const "))
        else:
            line = src.count("\n", 0, m.start()) + 1
            report.append(f"{path}:{line}: `const fn` without a `self` receiver; left as is")
    for a, b, t in sorted(edits, reverse=True):
        src = src[:a] + t + src[b:]
    return src, sum(1 for e in edits if e[2])


CASES = [
    ("const fn end_offset(self) -> usize {", "fn end_offset(const self) -> usize {"),
    ("pub const fn op == (self, other: Token) -> bool {",
     "pub fn op == (const self, other: Token) -> bool {"),
    ("inline const fn <T> get(self, i: usize) -> T",
     "inline fn <T> get(const self, i: usize) -> T"),
    ("const fn f(\n        self,\n        a: i32)", "fn f(\n        const self,\n        a: i32)"),
    ("const fn free(a: i32) -> i32", "const fn free(a: i32) -> i32"),
    ("fn g(const self) {", "fn g(const self) {"),
    ("// const fn h(self)", "// const fn h(self)"),
    ("const fn_table: i32 = 3", "const fn_table: i32 = 3"),
]


def selftest():
    bad = 0
    for src, want in CASES:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        ok = got == want and n2 == 0 and again == got
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src.replace("\n", "\\n") + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "const fn f(self) -> fn f(const self)"))
