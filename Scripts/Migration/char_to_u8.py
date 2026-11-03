#!/usr/bin/env python3
# Stage 0 `char` -> u8.
#
# SILENT MISCOMPILE otherwise (P340): Stage 0's `char` is a byte -- lib-helix
# primitives.hh:73 makes it `unsigned char` -- and Stage 1's `char` is a
# 32-bit code point (char32_t, Spec/Docs primitives). Unchanged, every
# `vec<char>`, `[char; N]`, `c: char` parameter and `as char` /
# `static_cast<char>` in the tree would quietly become four bytes wide and
# compile. `u8` is exactly what Stage 0 meant, so the rewrite is semantics-
# preserving everywhere -- including `eval if sizeof(char) == 4`
# (SourceManager.k), whose Stage 0 answer was already "no".
#
# Every `char` token in code is a type (it is a keyword in both languages),
# so the rewrite is by token, with two exceptions that are NOT Stage 0's
# byte: a path segment (`std::Legacy::char` is C's plain char, whose Stage 1
# spelling is std::c_char -- a separate rename), and `char32`/`char16`/...,
# which are other words.
#
# Char LITERALS are left alone and reported per file: `'a'` is a char32 in
# Stage 1 and is compared against these u8s (`c >= 'a'`). Whether that needs
# `'a' as u8` or Stage 1 types the literal from its context is a type-check
# (5.2) question, not a spelling one.
#
# Runs after cpp_casts: clang's facts name the C++ type `unsigned char`, and
# cpp_casts reports a C char target rather than rewriting it, so a
# `static_cast<char>` reaches this pass intact and becomes `static_cast<u8>`.
#
#     python3 Scripts/Migration/char_to_u8.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/char_to_u8.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

CHAR = re.compile(r"(?<![\w$#])char(?!\w)")
LIT = re.compile(r"'(?:\\.|[^'\\\n])'")


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in CHAR.finditer(src):
        if not all(mask[k] for k in range(m.start(), m.end())):
            continue
        if src[max(0, m.start() - 2):m.start()] == "::":
            continue
        edits.append(m.start())
    lits = sum(1 for m in LIT.finditer(src) if mask[m.start()]) if edits else 0
    for k in reversed(edits):
        src = src[:k] + "u8" + src[k + 4:]
    if edits:
        if lits:
            report.append(f"{path}: {len(edits)} char -> u8; {lits} char literal(s) in the file are char32 in Stage 1 (check at 5.2)")
    return src, len(edits)


CASES = [
    ("var row_glyph: vec<char>;", "var row_glyph: vec<u8>;"),
    ("pub var value: array<char, N>;", "pub var value: array<u8, N>;"),
    ("out[i] = static_cast<char>(out[i] + 32);", "out[i] = static_cast<u8>(out[i] + 32);"),
    ("fn is_digit(self, c: char) -> bool {", "fn is_digit(self, c: u8) -> bool {"),
    ("eval fn compute_length(const str: unsafe *char) -> usize {",
     "eval fn compute_length(const str: unsafe *u8) -> usize {"),
    ("eval if sizeof(char) == 4 {", "eval if sizeof(u8) == 4 {"),
    ("var p: unsafe *std::Legacy::char;", "var p: unsafe *std::Legacy::char;"),
    ("var w: char32 = 0;", "var w: char32 = 0;"),
    ("fn get_char_at(self) -> char", "fn get_char_at(self) -> u8"),
    ('var s = "char"; // char', 'var s = "char"; // char'),
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
    sys.exit(run(rewrite, "Stage 0 char (a byte) -> u8"))
