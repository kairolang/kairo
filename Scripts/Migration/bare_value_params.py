#!/usr/bin/env python3
# Generic value parameters written bare: <N: usize> -> <eval N: usize>.
#
# Stage 0 takes `fn <N: usize> f()` and `fn <T: FlagKind> define()` as C++
# non-type template parameters. In Stage 1 a `:` after a generic parameter's
# name is a KIND bound and only `class`, `struct`, `enum`, `union` or `type`
# may follow it (S049E "expected 'class', 'struct', 'enum', 'union', or
# 'type' as a kind bound after ':'"); a value parameter is `eval N: T`
# (Spec/Docs generics, EVAL.md 3). So a head `NAME: X` whose X is not one of
# those five is a value parameter and gains the `eval`.
#
# Same list finder as const_value_params.py (a `<` right after a declaration
# keyword; argument lists and function parameters are never touched), and a
# separate script because that one is held to Stage 1's S001E fix-it by
# Tests/CLI/Migration/const_value_params.k and this rule is not a fix-it.
# Run after const_value_params, so a `const N:` head is already `eval N:`.
#
# Idempotent: an `eval N: T` head is skipped.
#
#     python3 Scripts/Migration/bare_value_params.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/bare_value_params.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run
from const_value_params import DECL_KW, _prev_word, _param_list_end, _heads

KINDS = {"class", "struct", "enum", "union", "type"}
HEAD = re.compile(r"([A-Za-z_]\w*)\s*:(?!:)\s*([A-Za-z_]\w*)")


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for i in range(len(src)):
        if src[i] != "<" or not mask[i]:
            continue
        if _prev_word(src, mask, i) not in DECL_KW:
            continue
        hi = _param_list_end(src, mask, i)
        if hi < 0:
            continue
        for h in _heads(src, mask, i, hi):
            k = h
            while k < hi and src[k] in " \t\r\n":
                k += 1
            m = HEAD.match(src, k, hi)
            if not m or not mask[k]:
                continue
            if m.group(1) in ("eval", "const") or m.group(2) in KINDS:
                continue
            edits.append(k)
    for k in reversed(edits):
        src = src[:k] + "eval " + src[k:]
    return src, len(edits)


CASES = [
    ("fn <N: usize> g() -> usize", "fn <eval N: usize> g() -> usize"),
    ("fn <T: FlagKind> define(self)", "fn <eval T: FlagKind> define(self)"),
    ("class <T, N: u32> Buf { }", "class <T, eval N: u32> Buf { }"),
    # kind bounds stay
    ("fn <T: class> f()", "fn <T: class> f()"),
    ("fn <T: type, U: struct> f()", "fn <T: type, U: struct> f()"),
    # already a value parameter, or an interface bound
    ("fn <eval N: usize> f()", "fn <eval N: usize> f()"),
    ("fn <T impl Foo> f()", "fn <T impl Foo> f()"),
    # a path type after the colon: still a value parameter's type
    ("fn <K: Kind::Sub> f()", "fn <eval K: Kind::Sub> f()"),
    # argument lists and parameters are not touched
    ("var x = f::<N: usize>()", "var x = f::<N: usize>()"),
    ("fn f(a: usize) { }", "fn f(a: usize) { }"),
    ('var s = "fn <N: usize>"', 'var s = "fn <N: usize>"'),
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
    sys.exit(run(rewrite, "bare generic value parameters: <N: T> -> <eval N: T>"))
