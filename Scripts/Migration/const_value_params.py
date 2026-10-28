#!/usr/bin/env python3
# Generic value parameters: <const N: T> -> <eval N: T>.
#
# Stage 1 spells a value parameter `eval N: T` (EVAL.md 3); `const N: T` is
# S001E there, with a fix-it that replaces the `const` keyword with `eval` and
# nothing else (DeclParse.k, _parse_one_generic_param). This is that fix-it,
# applied to a tree: only the keyword token changes, spacing and everything
# around it are kept, so the result is what accepting every fix-it would give.
#
# Only a generic PARAMETER list is rewritten: a `<` whose previous token is a
# declaration keyword (`class <const N: usize> Buf`, `fn <const N: usize> f`,
# `eval fn <...>`, `struct`/`union`/`enum`/`interface`/`type`/`extend`). An
# ARGUMENT list keeps its `const` -- `static_cast::<const *T>(p)` is a const
# pointer type, not a parameter -- and so does a function parameter
# (`fn f(self, const other: T)`): neither is in such a list. Inside the list
# a `const` is a value parameter only at the head of a parameter (just after
# `<` or a top-level `,`) and followed by `NAME :`; a bound's own generic
# arguments (`<T impl Foo<const *U>, const N: usize>`) are one level deeper and
# never touched. Comments and string literals are masked (kairo_lex).
#
# Idempotent: the output has no `const` left in a parameter head.
#
#     python3 Scripts/Migration/const_value_params.py <copy-of-tree>
#     python3 Scripts/Migration/const_value_params.py <copy-of-tree> --apply
#     python3 Scripts/Migration/const_value_params.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

DECL_KW = ("class", "struct", "union", "enum", "interface", "fn", "type", "extend")
IDENT_RE = re.compile(r"[A-Za-z_]\w*")


def _prev_word(src, mask, i):
    """The identifier ending just before offset i, skipping blanks and
    masked bytes (comments), or None."""
    j = i - 1
    while j >= 0 and (src[j] in " \t\r\n" or not mask[j]):
        j -= 1
    end = j + 1
    while j >= 0 and mask[j] and (src[j].isalnum() or src[j] == "_"):
        j -= 1
    w = src[j + 1:end]
    return w if w and IDENT_RE.fullmatch(w) else None


def _param_list_end(src, mask, i):
    """i is at a `<`. Index of its matching `>`, or -1. `->` inside (a
    function type in a bound or default) is not a closer, and `>>` closes
    two levels."""
    depth = 0
    n = len(src)
    k = i
    while k < n:
        if mask[k]:
            c = src[k]
            if c == "<":
                depth += 1
            elif c == ">" and not (k > 0 and src[k - 1] == "-"):
                depth -= 1
                if depth == 0:
                    return k
            elif c in "{;":
                return -1      # ran into a body: not a parameter list
        k += 1
    return -1


def _heads(src, mask, lo, hi):
    """Offsets of each parameter head in the list spanning (lo, hi): just
    past `<` and every `,` at the list's own depth."""
    out = [lo + 1]
    depth = 0
    for k in range(lo + 1, hi):
        if not mask[k]:
            continue
        c = src[k]
        if c in "<([{":
            depth += 1
        elif c == ">" and src[k - 1] == "-":
            continue
        elif c in ">)]}":
            depth -= 1
        elif c == "," and depth == 0:
            out.append(k + 1)
    return out


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []      # (start, end) of each `const` keyword to become `eval`
    n = len(src)
    for i in range(n):
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
            if not src.startswith("const", k) or not all(mask[x] for x in range(k, k + 5)):
                continue
            if k + 5 < n and (src[k + 5].isalnum() or src[k + 5] == "_"):
                continue    # `constant`, not the keyword
            m = re.match(r"\s+([A-Za-z_]\w*)\s*:", src[k + 5:hi])
            if not m:
                line = src.count("\n", 0, k) + 1
                report.append(f"{path}:{line}: 'const' heads a generic parameter but is not 'const NAME:'; left as is")
                continue
            edits.append((k, k + 5))
    for s, e in reversed(edits):
        src = src[:s] + "eval" + src[e:]
    return src, len(edits)


# --------------------------------------------------------------------------
# --selftest: (input, expected). Every row is also checked for idempotence.
# --------------------------------------------------------------------------
CASES = [
    ("class <const N: usize> Buf { }", "class <eval N: usize> Buf { }"),
    ("fn <const N: usize> f() { }", "fn <eval N: usize> f() { }"),
    ("eval fn <const N: usize> h(const s: *char) -> u64",
     "eval fn <eval N: usize> h(const s: *char) -> u64"),
    # several, mixed with type parameters, a default, a bound with arguments
    ("class <T, const N: usize, U impl Foo<T>, const M: i32 = 4> X",
     "class <T, eval N: usize, U impl Foo<T>, eval M: i32 = 4> X"),
    # a bound's own arguments are one level down: their `const` is a type
    ("struct <T impl Into<const *T>, const N: u8> S",
     "struct <T impl Into<const *T>, eval N: u8> S"),
    # nesting: a member template inside a generic class
    ("class <const A: usize> O {\n    fn <const B: usize> m(self) -> [i32; B]\n}",
     "class <eval A: usize> O {\n    fn <eval B: usize> m(self) -> [i32; B]\n}"),
    # generic arguments and function parameters are not parameter lists
    ("return static_cast::<const *T>(p)", "return static_cast::<const *T>(p)"),
    ("fn f(self, const other: Box::<T>) { }", "fn f(self, const other: Box::<T>) { }"),
    ("var b: TokenBuffer::<N> = x", "var b: TokenBuffer::<N> = x"),
    # comments and strings are masked
    ("/// `<const N: i32>` is old\nclass <const N: i32> Z",
     "/// `<const N: i32>` is old\nclass <eval N: i32> Z"),
    ('var s = "class <const N: usize> Q"', 'var s = "class <const N: usize> Q"'),
    ("/* fn <const N: usize> g */ fn <const N: usize> g()",
     "/* fn <const N: usize> g */ fn <eval N: usize> g()"),
    # already migrated: untouched
    ("class <eval N: usize> Buf { }", "class <eval N: usize> Buf { }"),
    # spacing is the fix-it's: only the keyword changes
    ("class <  const   N :usize> W", "class <  eval   N :usize> W"),
    # a function type in a bound does not close the list
    ("fn <F impl Fn<fn(i32) -> i32>, const N: usize> k()",
     "fn <F impl Fn<fn(i32) -> i32>, eval N: usize> k()"),
    # an identifier that merely starts with `const`
    ("class <constant, T> Odd", "class <constant, T> Odd"),
]


def selftest():
    bad = 0
    for src, want in CASES:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        if got != want or n2 != 0 or again != got:
            bad += 1
            print(f"FAIL\n  in:   {src!r}\n  want: {want!r}\n  got:  {got!r}\n  rerun rewrites: {n2}")
    print(f"{len(CASES) - bad}/{len(CASES)} ok")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "generic value parameters: <const N: T> -> <eval N: T>"))
