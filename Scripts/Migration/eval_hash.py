#!/usr/bin/env python3
# compute_hash::<r"X">() -> its value as an integer literal, `/* "X" */` beside it.
#
# Stage 0 hashed spellings at compile time through a string-literal generic
# argument (Support/EvalHash.k: `eval fn <str: const EvalStrBuffer>
# compute_hash() -> u64`): every DiagID variant in the generated
# Diagnostic/Registry.k (`C0001W = compute_hash::<r"C0001W">()`, ~5,000) and
# 173 TokenKind variants. Stage 1's ConstEval does not call functions, so an
# enum discriminant written as a call does not evaluate (SC128E).
# The values are fixed by the spelling, so the migration writes them out:
#
#   C0001W = compute_hash::<r"C0001W">(),  ->  C0001W = 3595980705 /* "C0001W" */,
#
# The function below is EvalHash.k's algorithm (FNV-1a variant: offset
# 0x14650FB0739D0383, prime 0x100000001b3, the index xored in after each
# byte, length * golden-ratio mix, + 0xFF, folded to 32 bits; an empty
# string is fold(u64 max)). Scripts/gen_diag.py has no Python copy of it --
# it emits the compute_hash calls and Stage 0 evaluates them -- so this is
# the one Python implementation. Checked against Stage 0 itself
# (2026-11-03: a Stage 0 program printing compute_hash::<r"...">() for
# "C0001W", "null", "S048E", "a" gave 3595980705, 609591432, 707373511,
# 3591181695, the selftest's values). The C++ registry.o is built by Stage 0
# from the same calls, so the Kairo and C++ sides still agree.
#
#     python3 Scripts/Migration/eval_hash.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/eval_hash.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

M64 = (1 << 64) - 1
FNV_OFFSET_BASIS = 0x14650FB0739D0383
FNV_PRIME = 0x00000100000001b3
GOLDEN_RATIO_MIX = 0x9e3779b97f4a7c15
RESERVED_LOW = 0x00000000000000FF


def fold_hash(h):
    return ((h >> 32) ^ h) & 0xFFFFFFFF


def compute_hash(text):
    """EvalHash.k's `compute_hash::<str>()` of the literal's bytes."""
    data = text.encode("utf-8")
    if not data:
        return fold_hash(M64)
    h = FNV_OFFSET_BASIS
    for i, c in enumerate(data):
        h = ((h ^ c) * FNV_PRIME) & M64
        h ^= i
    return fold_hash(((h ^ ((len(data) * GOLDEN_RATIO_MIX) & M64)) + RESERVED_LOW) & M64)


CALL = re.compile(r'(?<![\w$#:.])compute_hash\s*(?:::)?\s*<\s*(r?)"((?:[^"\\\n]|\\.)*)"\s*>\s*\(\s*\)')
ESC = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def _unescape(raw, s):
    if raw:
        return s
    return re.sub(r"\\(.)", lambda m: ESC.get(m.group(1), m.group(1)), s)


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in CALL.finditer(src):
        if not mask[m.start()]:
            continue
        text = _unescape(m.group(1) == "r", m.group(2))
        # Block comments nest in Kairo: a spelling holding `/*` or `*/` (the
        # comment tokens' own TokenKind values) would open or close one, so
        # it is written with a space inside the pair.
        shown = m.group(2).replace("/*", "/ *").replace("*/", "* /")
        edits.append((m.start(), m.end(), f'{compute_hash(text)} /* "{shown}" */'))
    for a, b, t in reversed(edits):
        src = src[:a] + t + src[b:]
    return src, len(edits)


CASES = [
    ('enum DiagID derives u32 {\n  Invalid = 0,\n  C0001W = compute_hash::<r"C0001W">(),\n}\n',
     'enum DiagID derives u32 {\n  Invalid = 0,\n  C0001W = 3595980705 /* "C0001W" */,\n}\n'),
    ('    LitNull          = compute_hash<r"null">(),', '    LitNull          = 609591432 /* "null" */,'),
    ('hash: ((compute_hash<r"S048E">()) as u32),', 'hash: ((707373511 /* "S048E" */) as u32),'),
    ('case compute_hash::<r"a">() {', 'case 3591181695 /* "a" */ {'),
    ('// compute_hash<r"x">()', '// compute_hash<r"x">()'),
    ('if h2 == compute_hash<r"/*">() {', 'if h2 == 2645686962 /* "/ *" */ {'),
    ('var h = compute_hash(&code_str);', 'var h = compute_hash(&code_str);'),
]


def selftest():
    bad = 0
    for src, want in CASES:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        ok = got == want and n2 == 0 and again == got
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src.replace("\n", "\\n")[:80]
              + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, 'compute_hash::<r"X">() -> its integer value /* "X" */'))
