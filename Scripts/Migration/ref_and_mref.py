#!/usr/bin/env python3
# Pass 1: ref!(T) / mref(T) in PARAMETER position -> @inout x: T / @move x: T.
# Pass 2: -> ref!(C) / -> mref!(C) inside type C -> -> ref!(Self) / -> mref!(Self).
# Paren/brace balanced. Everything else untouched.
import re, sys, pathlib

HEAD   = re.compile(r'(?P<lead>(?:const\s+)?)(?P<name>[A-Za-z_]\w*)\s*:\s*(?P<mac>ref!|mref!?)\(')
TYPE   = re.compile(r'\b(?:class|struct)\s+(?P<name>[A-Za-z_]\w*)\s*(?P<gen><[^{;]*?>)?[^{;]*?\{')
RETREF = re.compile(r'->\s*(?P<mac>ref!|mref!?)\(')

def balance(src: str, j: int, open_: str, close: str) -> int:
    """j is just past an opener; returns index just past its matching closer, or -1."""
    depth = 1
    while j < len(src) and depth:
        c = src[j]
        if c == open_: depth += 1
        elif c == close: depth -= 1
        j += 1
    return j if depth == 0 else -1

def rewrite_params(src: str) -> tuple[str, int]:
    out, i, n = [], 0, 0
    while True:
        m = HEAD.search(src, i)
        if not m:
            out.append(src[i:]); break
        j = balance(src, m.end(), '(', ')')
        if j < 0:
            out.append(src[i:m.end()]); i = m.end(); continue
        inner = src[m.end():j - 1]
        # A range-for binding is not a parameter: `for var q: ref!(T) in` has
        # no mode in Stage 1 (S069E). Left for the gap list.
        if re.search(r'\bfor\s+(?:var\s+)?$', src[max(0, m.start() - 12):m.start()]):
            out.append(src[i:m.end()]); i = m.end(); continue
        if m.group('lead') and m.group('mac') == 'ref!':
            # `const x: ref!(T)` is C++ `const T&`, a read-only borrow, which
            # Stage 1 spells `const x: T`; `@inout const` is S070E there.
            mode = ''
        else:
            mode = '@inout ' if m.group('mac') == 'ref!' else '@move '
        out.append(src[i:m.start()])
        out.append(f"{mode}{m.group('lead')}{m.group('name')}: {inner}")
        i = j; n += 1
    return ''.join(out), n

def type_spans(src: str):
    """(body_start, body_end, self_type_text) for every class/struct body."""
    spans = []
    for m in TYPE.finditer(src):
        end = balance(src, m.end(), '{', '}')
        if end < 0:
            continue
        self_ty = m.group('name') + (m.group('gen') or '')
        spans.append((m.end(), end, re.sub(r'\s+', '', self_ty)))
    return spans

def innermost(spans, pos):
    best = None
    for s, e, ty in spans:
        if s <= pos < e and (best is None or s > best[0]):
            best = (s, e, ty)
    return best[2] if best else None

def rewrite_returns(src: str) -> tuple[str, int]:
    spans = type_spans(src)
    out, i, n = [], 0, 0
    for m in RETREF.finditer(src):
        j = balance(src, m.end(), '(', ')')
        if j < 0:
            continue
        inner = src[m.end():j - 1]
        owner = innermost(spans, m.start())
        if owner is None or re.sub(r'\s+', '', inner) != owner:
            continue
        out.append(src[i:m.start()])
        out.append('-> Self')
        i = j; n += 1
    out.append(src[i:])
    return ''.join(out), n

SELFTEST = [
    ("fn f(a: ref!(T), b: mref!(U)) {", "fn f(@inout a: T, @move b: U) {"),
    ("fn f(const s: ref!(string)) {", "fn f(const s: string) {"),
    ("fn f(const p: ref!(cxx::std::pair<A, B>)) {", "fn f(const p: cxx::std::pair<A, B>) {"),
    ("for var q: ref!(Queue) in qs {", "for var q: ref!(Queue) in qs {"),
    ("for q: ref!(Queue) in qs {", "for q: ref!(Queue) in qs {"),
    ("class C { fn me(self) -> ref!(C) { } }", "class C { fn me(self) -> Self { } }"),
]


def selftest():
    bad = 0
    for src, want in SELFTEST:
        s1, _ = rewrite_params(src)
        got, _ = rewrite_returns(s1)
        ok = got == want
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(SELFTEST) - bad}/{len(SELFTEST)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    total_p = total_r = 0
    for p in pathlib.Path(sys.argv[1]).rglob('*.k'):
        s = p.read_text()
        s1, np_ = rewrite_params(s)
        s2, nr  = rewrite_returns(s1)
        if np_ or nr:
            p.write_text(s2)
            total_p += np_; total_r += nr
            print(f"{np_:4d} params  {nr:4d} returns  {p}")
    print(f"\n{total_p} params, {total_r} returns")
