#!/usr/bin/env python3
# Python-style ternary -> braced if/else, chain-aware.
#
#     A if C else B                 ->  if C { A } else { B }
#     A if C else B if C2 else D    ->  if C { A } else if C2 { B } else { D }
#
# The riskiest of the six: it has to find where operand A STARTS by scanning
# left from the `if`, with no parser. Anything it cannot parse confidently is
# left alone and reported, so the residual list stays meaningful.
import sys, os
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


def rewrite(src, path, report):
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
                parts.append(f"{kw} {cond} {{ {val} }}")
            parts.append(f"else {{ {default} }}")
            out.append(" ".join(parts))
            i = end
            count += 1
            continue
        out.append(src[i])
        i += 1
    return "".join(out), count


if __name__ == "__main__":
    sys.exit(run(rewrite, "python ternary -> braced if/else (chain-aware)"))
