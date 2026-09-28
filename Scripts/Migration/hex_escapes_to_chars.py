#!/usr/bin/env python3
# Stage 0 hex-escape workarounds -> the characters they stand for.
#
#     "name '{x}\x27"          ->  "name '{x}'"
#     "say \x22hi\x22"         ->  "say \"hi\""
#     r"extern \"C\" \x7B\n"   ->  "extern \"C\" {\n"
#
# Stage 0 compiles Compiler/, and its lexer has traps the source works around
# with hex escapes (CLAUDE.md, "Writing Kairo in this tree"):
#
#   \x27  a `'` right before a closing `"` reads as an unterminated char
#         literal, so every such quote is spelled \x27.
#   \x22  the same family, for a `"` inside a string.
#   \x7B  a bare `{` or `}` inside an r"" string does not survive Stage 0,
#   \x7D  so HeaderSet.k spells them \x7B / \x7D.
#
# Stage 1 has none of those traps, so the corpus gets the plain characters.
#
# What each literal kind can hold, per Stage 1's lexer:
#
#   "..."   \x27 -> '        \x22 -> \"   (a bare " would END the string)
#           \x7B -> {        \x7D -> }
#   f"..."  \x27 -> '        \x22 -> \"   in the literal parts. {...} holes
#           are code: rewritten recursively, strings inside them included.
#           \x7B / \x7D are left alone -- a literal brace in an f-string is
#           \{ / \}, a different spelling decision than this rule makes.
#   r"..."  Stage 0's r"" is NOT raw: it keeps C escapes (`r"...\n"` in
#           Driver/Kairo.k means a newline; `r"extern \"C\""` in HeaderSet.k
#           needs \" to be an escape). Stage 1's r"" IS raw -- \n is two
#           bytes and \" ENDS the string. So an r"" holding any backslash is
#           ported to the plain string it always meant: the `r` is dropped,
#           the braces become bare, and every other escape is kept as Stage 0
#           read it. An r"" with no backslash reads the same either way and
#           is left alone.
#
# Never touched: comments, char literals ('"', '\x27'), inline "c++" bodies,
# and an escaped backslash (`\\x27` is a backslash then text, not an escape).
#
#   python3 Scripts/Migration/hex_escapes_to_chars.py <corpus-root>
#   python3 Scripts/Migration/hex_escapes_to_chars.py <corpus-root> --apply
#   python3 Scripts/Migration/hex_escapes_to_chars.py --selftest
#
# Meant for a COPY of the tree: Compiler/ stays Stage 0 syntax because Stage 0
# compiles it, and every one of these escapes is there on purpose.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import run

IDENT = re.compile(r"[A-Za-z0-9_]")
HEX = "0123456789abcdefABCDEF"


def _escape_len(src, i):
    """Length of the escape starting at the backslash at i (at least 2)."""
    n = len(src)
    if i + 1 >= n:
        return 1
    c = src[i + 1]
    width = {"x": 2, "u": 4, "U": 8}.get(c)
    if width is None:
        return 2
    j = i + 2
    while j < n and j < i + 2 + width and src[j] in HEX:
        j += 1
    return j - i


def _string(src, i, raw, fmt, counts):
    """Port the string whose opening quote is at i. Returns (text, end, raw_kept).

    `text` is the literal from its opening quote to its closing quote,
    rewritten; the caller writes the prefix, since a ported r"" drops its `r`.
    """
    n = len(src)
    triple = src.startswith('"""', i)
    q = 3 if triple else 1
    j = i + q
    body = []
    has_backslash = False
    while j < n:
        if triple and src.startswith('"""', j):
            break
        if (not triple) and src[j] == '"':
            break
        c = src[j]
        if c == "\\":
            has_backslash = True
            k = _escape_len(src, j)
            esc = src[j:j + k]
            low = esc.lower()
            if low == "\\x27":
                body.append("'"); counts[0] += 1
            elif low == "\\x22":
                body.append('\\"'); counts[0] += 1
            elif low in ("\\x7b", "\\x7d") and not fmt:
                body.append("{" if low == "\\x7b" else "}"); counts[0] += 1
            else:
                body.append(esc)
            j += k
            continue
        if fmt and c == "{":
            # a hole: code up to the matching brace, strings inside included.
            depth, k = 0, j
            while k < n:
                if src[k] == "{":
                    depth += 1
                elif src[k] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                elif src[k] == '"':
                    # step over a string inside the hole so its braces do not count.
                    _, e, _ = _string(src, k, False, False, [0])
                    k = e
                    continue
                k += 1
            inner, c2 = _rewrite(src[j + 1:k])
            counts[0] += c2
            body.append("{" + inner + "}")
            j = k + 1
            continue
        body.append(c)
        j += 1
    end = min(j + q, n)
    text = src[i:i + q] + "".join(body) + src[j:end]
    return text, end, (raw and not has_backslash)


def _rewrite(src):
    out = []
    counts = [0]
    n = len(src)
    i = 0
    while i < n:
        c = src[i]

        # comments: verbatim.
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(src[i:j]); i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(src[i:j]); i = j; continue

        # inline "c++" { ... }: C++ wholesale, verbatim.
        m = re.match(r'inline\s+"c\+\+"\s*\{', src[i:]) if c == "i" else None
        if m and (i == 0 or not IDENT.match(src[i - 1])):
            j = i + m.end() - 1
            depth = 0
            while j < n:
                if src[j] == "{":
                    depth += 1
                elif src[j] == "}":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            out.append(src[i:j]); i = j; continue

        # char literal: verbatim ('"', '\x27' and '\\' included).
        if c == "'":
            j = i + 1
            if j < n and src[j] == "\\":
                j += _escape_len(src, j)
            else:
                j += 1
            if j < n and src[j] == "'":
                out.append(src[i:j + 1]); i = j + 1; continue
            out.append(c); i += 1; continue

        # string literal, with an optional r / f / rf / fr prefix.
        pm = re.match(r'(rf|fr|r|f)?"', src[i:])
        if pm and (i == 0 or not IDENT.match(src[i - 1])):
            prefix = pm.group(1) or ""
            q = i + len(prefix)
            text, end, raw_kept = _string(src, q, "r" in prefix, "f" in prefix, counts)
            if ("r" in prefix) and not raw_kept:
                prefix = prefix.replace("r", "")   # Stage 0's r"" was never raw.
            out.append(prefix + text)
            i = end
            continue

        out.append(c)
        i += 1
    return "".join(out), counts[0]


def rewrite(src, path, report):
    return _rewrite(src)


SELFTEST = [
    (r'var a = "x \x27y\x27"',              r'''var a = "x 'y'"'''),
    (r'var a = "say \x22hi\x22"',           r'var a = "say \"hi\""'),
    (r'var a = f"name {n}\x27"',            r'''var a = f"name {n}'"'''),
    (r'var a = f"{g("\x27")} \x7B"',        r'''var a = f"{g("'")} \x7B"'''),
    (r'x += r"extern \"C\" \x7B\n"',        r'x += "extern \"C\" {\n"'),
    (r'x += r"\x7D\n"',                     r'x += "}\n"'),
    (r'x += r"no escapes here"',            r'x += r"no escapes here"'),
    (r'var s = "a\\x27b"',                  r'var s = "a\\x27b"'),
    (r"var c = '\x27'",                     r"var c = '\x27'"),
    (r"var c = '" + '"' + r"'",             r"var c = '" + '"' + r"'"),
    (r'// comment "\x27"',                  r'// comment "\x27"'),
    (r'inline "c++" { f("\x27"); }',        r'inline "c++" { f("\x27"); }'),
    (r'var h = "\x22C"',                    r'var h = "\"C"'),
]


def selftest():
    bad = 0
    for src, want in SELFTEST:
        got, _ = _rewrite(src)
        ok = got == want
        bad += 0 if ok else 1
        print(("ok   " if ok else "FAIL ") + src + ("" if ok else f"\n       want {want}\n       got  {got}"))
    print(f"\n{len(SELFTEST) - bad}/{len(SELFTEST)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run(rewrite, "Stage 0 hex escapes -> characters (\\x27 \\x22, and \\x7B \\x7D outside f-strings)"))
