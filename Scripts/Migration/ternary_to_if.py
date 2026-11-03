#!/usr/bin/env python3
# Python-style ternary -> Stage 1 expression-if, chain-aware.
#
#     A if C else B                 ->  if C => A else => B
#     A if C else B if C2 else D    ->  if C => A else if C2 => B else => D
#
# The VALUE form of `if` (Spec/Docs control-flow, "if expression"): each arm
# is `=> expr` and the final `else` is mandatory. The braced form this used to
# emit (`if C { A } else { B }`) is statement-only in Stage 1 (S073E, 1988
# sites on 2026-11-02). An arm or condition that is itself an `if` is
# parenthesized (S077E: only the last arm may hold a bare nested `if`), and
# so is the whole expression when an operator precedes it, where the bare
# form's greedy `else =>` arm would swallow what follows.
#
# The riskiest of the six: it has to find where operand A STARTS by scanning
# left from the `if`, with no parser. Anything it cannot parse confidently is
# left alone and reported, so the residual list stays meaningful.
#
#   python3 Scripts/Migration/ternary_to_if.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import (IDENT, OPEN, CLOSE, code_mask, interp_spans, clamp,
                       kw_at, scan_to, run)

LEFT_STOP = set("([{},;=&|!<>+-*/%?:")
LEFT_STOP_WORDS = ("return", "else", "case", "yield", "in", "default", "break")


def scan_left(src, mask, ifpos):
    """Find start of operand A, scanning left from the `if` keyword."""
    i = ifpos - 1
    depth = 0
    while i >= 0:
        c = src[i]
        if not mask[i]:
            i -= 1
            continue
        # `Kind::A if c else B`: a path separator is part of operand A.
        if c == ":" and depth == 0 and i > 0 and src[i - 1] == ":":
            i -= 2
            continue
        if c in CLOSE:
            depth += 1
        elif c in OPEN:
            if depth == 0:
                return i + 1
            depth -= 1
        elif depth == 0:
            if c in LEFT_STOP:
                return i + 1
            # A newline bounds the operand. Crossing it would need bracket-depth
            # tracking to stay sound -- in a newline-terminated language
            # `foo()\nif x {` is a statement, not a ternary, and only unbalanced
            # brackets make the difference. Not worth the risk for ~8 sites:
            # find them with  rg '^\s+else\s+[^{]*$'  and do them by hand.
            if c == "\n":
                return i + 1
            # keyword boundary: `return X if C else Y` -- A is X, not `return X`
            if IDENT.match(c):
                s = i
                while s > 0 and IDENT.match(src[s - 1]):
                    s -= 1
                if src[s : i + 1] in LEFT_STOP_WORDS:
                    return i + 1
                i = s - 1
                continue
        i -= 1
    return 0


def is_ternary_if(src, mask, pos):
    """Distinguish `A if C else B` from a statement `if`."""
    i = pos - 1
    while i >= 0 and src[i] in " \t":
        i -= 1
    if i < 0:
        return False
    c = src[i]
    if c in ")]\"'" or IDENT.match(c):
        # guard: `else if`, `eval if`, `const eval if` -- statement forms whose
        # preceding token is an identifier and so looks like an operand
        for w in ("else", "eval"):
            s = i - len(w) + 1
            if s >= 0 and kw_at(src, mask, s, w):
                return False
        return True
    return False


def parse_chain(src, mask, ifpos, spans=()):
    """Parse `A if C else B [if C2 else B2 ...]` starting at the first `if`.

    Returns (start, end, [(cond, val), ...], default) or None."""
    lo, hi = clamp(spans, ifpos)
    a_start = scan_left(src, mask, ifpos)
    if lo is not None:
        a_start = max(a_start, lo)
    # keep leading whitespace/indent in place; A begins at the first real char
    while a_start < ifpos and src[a_start] in " \t":
        a_start += 1
    a = src[a_start:ifpos].strip()
    if not a:
        return None

    arms = []
    cursor = ifpos
    while True:
        e = scan_to(src, mask, cursor + 2, ";,", ("else",))
        if e >= len(src) or not kw_at(src, mask, e, "else"):
            return None
        cond = src[cursor + 2 : e].strip()
        arms.append((cond, a))
        after = e + 4
        nxt = scan_to(src, mask, after, ";,", ("if",))
        if hi is not None:
            nxt = min(nxt, hi)
        if nxt < len(src) and kw_at(src, mask, nxt, "if"):
            a = src[after:nxt].strip()
            cursor = nxt
            continue
        return a_start, nxt, arms, src[after:nxt].strip()


def _nested(x):
    """An arm or condition that is itself a bare `if` must be parenthesized."""
    return f"({x})" if re.match(r"if\b", x) else x


def _after_operator(src, at):
    """True when the text before `at` ends in a binary/prefix operator."""
    k = at - 1
    while k >= 0 and src[k] in " \t":
        k -= 1
    if k < 0:
        return False
    c = src[k]
    if c in "+-*/%&|^<>!?~":
        return not (c == ">" and k > 0 and src[k - 1] == "-")   # `-> T` is not one
    return c == "=" and k > 0 and src[k - 1] in "=!<>"


def rewrite(src, path, report):
    # A ternary nested in another's operand -- `"&" if m else (("+") if p
    # else ("-"))` -- is inside text the outer rewrite copies through whole,
    # so one sweep leaves it and a second run of the pipeline converts it:
    # not idempotent. Sweep to a fixed point instead; each sweep only ever
    # removes `if ... else` ternaries, so it terminates. The report is kept
    # from the final sweep only, where an unparsed site really remains.
    total = 0
    for _ in range(16):
        rep = []
        src, n = _sweep(src, path, rep)
        total += n
        if not n:
            break
    report.extend(rep)
    return src, total


def _sweep(src, path, report):
    mask = code_mask(src)
    spans = interp_spans(src, mask)
    out = []
    i = 0
    n = len(src)
    count = 0
    while i < n:
        if kw_at(src, mask, i, "if") and is_ternary_if(src, mask, i):
            parsed = parse_chain(src, mask, i, spans)
            if parsed is None:
                report.append(f"{path}: SKIPPED ternary at offset {i} (unparsed)")
                out.append(src[i])
                i += 1
                continue
            a_start, end, arms, default = parsed
            if not default or any(not c or not v for c, v in arms):
                report.append(f"{path}: SKIPPED ternary at offset {i} (empty operand)")
                out.append(src[i])
                i += 1
                continue
            del out[len(out) - (i - a_start):]
            parts = []
            for k, (cond, val) in enumerate(arms):
                kw = "if" if k == 0 else "else if"
                parts.append(f"{kw} {_nested(cond)} => {_nested(val)}")
            parts.append(f"else => {default}")
            text = " ".join(parts)
            if _after_operator(src, a_start):
                text = f"({text})"
            out.append(text)
            # The default arm was stripped; give back the blanks after it
            # (`return a if c else b }` keeps its space before the `}`).
            while end > a_start and src[end - 1] in " \t":
                end -= 1
            i = end
            count += 1
            continue
        out.append(src[i])
        i += 1
    return "".join(out), count


SELFTEST = [
    ("var a = x if c else y",
     "var a = if c => x else => y"),
    ("var a = x if c else y if d else z",
     "var a = if c => x else if d => y else => z"),
    # Nested in the else operand's parens: converted in the SAME run.
    ('var k = "&" if m == 1 else (("+") if (p) else ("-"))',
     'var k = if m == 1 => "&" else => (if (p) => ("+") else => ("-"))'),
    # Nested in the value operand: that arm is parenthesized.
    ("var v = (a if p else b) if c else d",
     "var v = if c => (if p => a else => b) else => d"),
    ("f((a if p else b), c)",
     "f((if p => a else => b), c)"),
    # A path is one operand.
    ("tok = TokenKind::LitFloat if f else TokenKind::LitInt",
     "tok = if f => TokenKind::LitFloat else => TokenKind::LitInt"),
    # After an operator the whole expression is parenthesized.
    ("var w = base + 80 if wide else 40",
     "var w = base + (if wide => 80 else => 40)"),
    ("ok = x == a if c else b",
     "ok = x == (if c => a else => b)"),
    ("fn f() -> i32 { return a if c else b }",
     "fn f() -> i32 { return if c => a else => b }"),
    ("if c { x }", "if c { x }"),
    ("} else if c { x }", "} else if c { x }"),
]


def selftest():
    bad = 0
    for src, want in SELFTEST:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        ok = got == want and again == got and n2 == 0
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(SELFTEST) - bad}/{len(SELFTEST)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run(rewrite, "python ternary -> braced if/else (chain-aware)"))
