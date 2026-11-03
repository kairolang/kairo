#!/usr/bin/env python3
# Octal escapes -> \xHH in strings and char literals.
#
# Stage 0 hands string bodies to C++ verbatim, so `'\0'` and `"\033[32m"` are
# C octal escapes. Stage 1 takes octal only in byte strings (b"...") and
# warns everywhere else (S025W "octal escape '\0' is only valid in byte
# strings"); the zero-diagnostic exit of SELFHOST.md 5.1 needs them gone.
# `\xHH` is the same byte: Stage 1's \x takes exactly two hex digits
# ("\x1b0" is two bytes, checked 2026-11-02), so a following digit is safe.
#
# Rewritten: plain and f-string literals, and char literals in code. Left:
# r"" (no escapes), b"" (octal is valid there), comments, inline "c++"
# bodies and __inline_cpp("...") arguments (real C++), and an octal value
# above 0xFF (not a byte; reported).
#
#     python3 Scripts/Migration/octal_escapes.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/octal_escapes.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

OCT = re.compile(r"[0-7]{1,3}")
CHAR_LIT = re.compile(r"'\\([0-7]{1,3})'")


def _fix_body(body, report, where):
    out, i, n, cnt = [], 0, len(body), 0
    while i < n:
        c = body[i]
        if c == "\\" and i + 1 < n:
            m = OCT.match(body, i + 1)
            if m:
                v = int(m.group(0), 8)
                if v <= 0xFF:
                    out.append("\\x%02x" % v)
                    cnt += 1
                    i = m.end()
                    continue
                report.append(f"{where}: octal escape \\{m.group(0)} is not a byte; left as is")
            out.append(body[i:i + 2])
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out), cnt


def rewrite(src, path, report):
    mask = code_mask(src)
    n = len(src)
    edits = []          # (start, end, text)
    total = 0
    i = 0
    while i < n:
        if mask[i] or (i > 0 and not mask[i - 1]):
            i += 1
            continue
        j = i
        while j < n and not mask[j]:
            j += 1
        span = src[i:j]
        prev = src[i - 1] if i > 0 else ""
        skip = (span.startswith(("/", "inline", 'r"')) or prev == "b"
                or re.search(r"__inline_cpp\s*\(\s*$", src[max(0, i - 40):i]))
        # A string span starts with `"` or `f"`; the tail of an f-string after
        # an interpolation starts with `}`.
        if not skip and span[:1] in ('"', "f", "}"):
            body, c = _fix_body(span, report, f"{path}:{src.count(chr(10), 0, i) + 1}")
            if c:
                edits.append((i, j, body))
                total += c
        i = j
    for m in CHAR_LIT.finditer(src):
        if mask[m.start()]:
            v = int(m.group(1), 8)
            if v <= 0xFF:
                edits.append((m.start(), m.end(), "'\\x%02x'" % v))
                total += 1
    for a, b, t in sorted(edits, reverse=True):
        src = src[:a] + t + src[b:]
    return src, total


CASES = [
    ("var c = '\\0'", "var c = '\\x00'"),
    ('print("\\033[32mok\\033[0m")', 'print("\\x1b[32mok\\x1b[0m")'),
    ('var f = f"  \\033[1m{x}\\033[0m"', 'var f = f"  \\x1b[1m{x}\\x1b[0m"'),
    ('var s = "a\\\\0b"', 'var s = "a\\\\0b"'),          # escaped backslash, then a digit
    ('var r = r"\\033"', 'var r = r"\\033"'),
    ('var b = b"\\033"', 'var b = b"\\033"'),
    ("// '\\0' in a comment", "// '\\0' in a comment"),
    ('__inline_cpp("\'\\\\0\'")', '__inline_cpp("\'\\\\0\'")'),
    ('inline "c++" { char c = \'\\0\'; }', 'inline "c++" { char c = \'\\0\'; }'),
    ("var n = '\\n'", "var n = '\\n'"),
    ('var z = "\\x00\\n"', 'var z = "\\x00\\n"'),
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
    sys.exit(run(rewrite, "octal escapes -> \\xHH"))
