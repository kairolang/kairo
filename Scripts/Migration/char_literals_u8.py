#!/usr/bin/env python3
# Char literals in byte contexts:
#
#   c == 'a'           ->  c == ('a' as u8)
#   case 'a', 'b' {    ->  case 0x61 /* 'a' */, 0x62 /* 'b' */ {
#   s[0] != r'\x00'    ->  s[0] != 0x00 /* r'\x00' */
#
# Stage 0's `char` is a byte (unsigned char) and char_to_u8 already made
# every such type u8; its char LITERALS stayed, and in Stage 1 `'a'` is a
# char32 (Spec/Docs primitives, "Char"). char -> u8 is no implicit
# conversion (conversion-lattice: char -> any int is E, explicit), so every
# `c == 'a'` on a u8 is SC033E "operands 'u8' and 'char' do not unify" and
# every `var b: u8 = 'a'` SC028E. Stage 1 has no byte-literal spelling
# (`b'a'` lexes as the name `b` and a char), so:
#
#   - in an expression, the explicit cast `('a' as u8)`. Always
#     parenthesized: `if c == 'a' as u8 {` is selfhost gap G2 (a cast right
#     before an if head's `{`), and redundant_parens keeps a pair around
#     `as` (it treats `as` as uncertain), so the parens survive;
#   - in a match pattern, the integer: a pattern takes a literal, not a cast
#     (`case 'a' as u8` and `case ('a' as u8)` are both S062E/S074E), and a
#     u8 scrutinee takes `0x61`. The literal it was stays as a comment;
#   - an `r'...'` (Stage 0's C `char` literal, compared against C strings:
#     argv, LLVM's `const char*`) becomes the integer in both positions, which
#     a u8 and a std::c_char (0 through 127, primitives "C's char") both take.
#
# Every literal in code is taken to be in a byte context: after char_to_u8
# the tree has no char32 for one to be compared with. The literals that meet
# Stage 1's builtin string API (`string(' ', n)`, `.view().find('=')`) are
# u8 only if that API's char-ish parameters are -- the user owns it; the
# rewrite is uniform and 5.2 will say. A literal above 0x7F (not a byte) or
# with an escape this pass does not know is reported and left.
#
# Runs after octal_escapes (so '\0' is already '\x00') and switch_to_match
# (so case arms have their final shape), before redundant_parens. A literal
# already followed by `as` is left: that is this pass's own output, or an
# explicit cast that already says what it means.
#
#     python3 Scripts/Migration/char_literals_u8.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/char_literals_u8.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

LIT = re.compile(r"(?<![\w$#'])(r?)'(\\x[0-9A-Fa-f]{1,8}|\\u\{?[0-9A-Fa-f]{1,8}\}?|\\.|[^'\\\n])'")
SIMPLE = {"n": 10, "t": 9, "r": 13, "0": 0, "\\": 92, "'": 39, '"': 34,
          "a": 7, "b": 8, "f": 12, "v": 11, "e": 27}
CASE = re.compile(r"\bcase\b")


def value(body):
    if not body.startswith("\\"):
        return ord(body)
    if body[1] in "xX":
        return int(body[2:], 16)
    if body[1] == "u":
        return int(body[2:].strip("{}"), 16)
    return SIMPLE.get(body[1])


def pattern_spans(src, mask):
    """[start, end) of every `case` head: from the keyword to the arm's `{`
    or `=>` at bracket depth 0. Char literals are stepped over whole, so
    `case '{', '}' {` ends at the third brace."""
    spans = []
    n = len(src)
    for m in CASE.finditer(src):
        if not mask[m.start()]:
            continue
        i, depth = m.end(), 0
        while i < n:
            if not mask[i]:
                i += 1
                continue
            lm = LIT.match(src, i) if src[i] in "r'" else None
            if lm and (src[i] == "'" or lm.group(1)):
                i = lm.end()
                continue
            c = src[i]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            elif depth == 0 and (c == "{" or src.startswith("=>", i)):
                break
            elif c == "}" or c == ";":
                break
            i += 1
        spans.append((m.end(), i))
    return spans


def rewrite(src, path, report):
    mask = code_mask(src)
    pats = pattern_spans(src, mask)
    edits = []
    for m in LIT.finditer(src):
        if not mask[m.start()]:
            continue
        if re.match(r"\s*as\b", src[m.end():]):
            continue
        v = value(m.group(2))
        line = src.count("\n", 0, m.start()) + 1
        if v is None or v > 0x7F:
            report.append(f"{path}:{line}: char literal {m.group(0)} is no ASCII byte; left as is")
            continue
        in_pat = any(a <= m.start() < b for a, b in pats)
        if in_pat or m.group(1):
            text = f"0x{v:02x} /* {m.group(0)} */"
        else:
            text = f"({m.group(0)} as u8)"
        edits.append((m.start(), m.end(), text))
    for a, b, t in reversed(edits):
        src = src[:a] + t + src[b:]
    return src, len(edits)


CASES = [
    ("if c == 'a' {", "if c == ('a' as u8) {"),
    ("return c >= '0' && c <= '9'", "return c >= ('0' as u8) && c <= ('9' as u8)"),
    ("v = v * 10 + ((c - '0') as u32);", "v = v * 10 + ((c - ('0' as u8)) as u32);"),
    ("x == '\\n' || x == '\\\\' || x == '\\x41' || x == '\\x00' || x == '\\''",
     "x == ('\\n' as u8) || x == ('\\\\' as u8) || x == ('\\x41' as u8) || x == ('\\x00' as u8) || x == ('\\'' as u8)"),
    ("case 'a', 'b' { return 1 }", "case 0x61 /* 'a' */, 0x62 /* 'b' */ { return 1 }"),
    ("case '{', '}' { // both", "case 0x7b /* '{' */, 0x7d /* '}' */ { // both"),
    ("case '\\x22' => 1,", "case 0x22 /* '\\x22' */ => 1,"),
    ("case 'a'..='z' { }", "case 0x61 /* 'a' */..=0x7a /* 'z' */ { }"),
    ("case 'x' { out.push_back('y'); }", "case 0x78 /* 'x' */ { out.push_back(('y' as u8)); }"),
    ("return s[0] != r'\\x00' && s[0] == r'0'", "return s[0] != 0x00 /* r'\\x00' */ && s[0] == 0x30 /* r'0' */"),
    ("var w = '0' as u32", "var w = '0' as u32"),
    ("// c == 'a'", "// c == 'a'"),
    ("var s = \"it's\"", "var s = \"it's\""),
    ("var e = 'é'", "var e = 'é'"),
    ("f(sep: u8 = ',')", "f(sep: u8 = (',' as u8))"),
    ("var t = f\"{a == 'x'}\"", "var t = f\"{a == ('x' as u8)}\""),
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
    sys.exit(run(rewrite, "'a' -> ('a' as u8); in a case pattern -> 0x61"))
