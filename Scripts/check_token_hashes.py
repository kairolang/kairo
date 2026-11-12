#!/usr/bin/env python3
# Pins the three things that must agree for a keyword or operator to lex:
#
#   1. every hash-valued TokenKind is compute_hash() of its spelling, and that
#      spelling is what token_kind_to_readable_string() returns (TokenText
#      and the diagnostic highlighter take spellings from that table, and the
#      lexer finds a word's kind by hashing it, so a value written wrong is a
#      keyword that silently lexes as an identifier);
#   2. Support/EvalHash.k's constants are Scripts/Migration/eval_hash.py's,
#      which computed the written values (and the DiagID values gen_diag.py
#      writes into Diagnostic/Registry.k);
#   3. every hash-valued member has a row in the spelling table (the
#      special kinds are spelled by TokenText itself).
#
#     python3 Scripts/check_token_hashes.py [TokenKind.k] [EvalHash.k]
#
# Exit status 0 when all agree; 1 with one line per disagreement otherwise.
# Run by Tests/Lexer/token_kind_hashes.k.
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "Migration"))
import eval_hash  # noqa: E402

ROOT = os.path.dirname(HERE)
TOKEN_KIND = os.path.join(ROOT, "Compiler", "Token", "TokenKind.k")
EVAL_HASH = os.path.join(ROOT, "Compiler", "Support", "EvalHash.k")

# Values at or below this are the hand-numbered special kinds (TkEof,
# LitIdentifier, ...); everything above is a spelling hash (EvalHash.k's
# RESERVED_LOW is added to every hash, so no hash lands this low).
SPECIAL_MAX = 0xFF

ESC = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def unescape(s):
    return re.sub(r"\\(.)", lambda m: ESC.get(m.group(1), m.group(1)), s)


def enum_members(src):
    body = src[src.index("pub enum TokenKind"):src.index("pub fn is_valid_token_kind")]
    out = []
    for m in re.finditer(r"^\s*(\w+)\s*=\s*\(?\s*(0x[0-9a-fA-F]+|\d+)\s*\)?", body, re.M):
        out.append((m.group(1), int(m.group(2), 0)))
    return out


def spelling_table(src):
    i = src.index("pub fn token_kind_to_readable_string")
    j = src.index("\n}\n", i)
    rows = {}
    for m in re.finditer(r'case ((?:TokenKind::\w+[,\s]*)+)\{\s*return "((?:[^"\\]|\\.)*)"', src[i:j]):
        for k in re.findall(r"TokenKind::(\w+)", m.group(1)):
            rows[k] = unescape(m.group(2))
    return rows


def hashed_spelling(name, readable):
    # The builtins read as their macro form (`__file__!`) but lex, and hash,
    # without the bang.
    if name.startswith("Bi") and readable.endswith("!"):
        return readable[:-1]
    return readable


def check_eval_constants(path, errors):
    src = open(path, encoding="utf-8").read()
    for name in ("FNV_OFFSET_BASIS", "FNV_PRIME", "GOLDEN_RATIO_MIX", "RESERVED_LOW"):
        m = re.search(r"(?:const|eval)\s+%s\s*:\s*u64\s*=\s*(0x[0-9a-fA-F]+|\d+)" % name, src)
        if not m:
            errors.append(f"EvalHash.k: {name} not found")
            continue
        if int(m.group(1), 0) != getattr(eval_hash, name):
            errors.append(f"EvalHash.k: {name} = {m.group(1)}, eval_hash.py has "
                          f"{getattr(eval_hash, name):#x}")


def main(argv):
    token_kind = argv[1] if len(argv) > 1 else TOKEN_KIND
    evalh = argv[2] if len(argv) > 2 else EVAL_HASH
    src = open(token_kind, encoding="utf-8").read()
    members = enum_members(src)
    table = spelling_table(src)
    errors = []
    hashed = 0
    for name, value in members:
        if value <= SPECIAL_MAX:
            continue
        if name not in table:
            errors.append(f"{name}: no row in token_kind_to_readable_string")
            continue
        hashed += 1
        spelling = hashed_spelling(name, table[name])
        want = eval_hash.compute_hash(spelling)
        if want != value:
            errors.append(f"{name} = {value}, but compute_hash({spelling!r}) = {want}")
    check_eval_constants(evalh, errors)
    for e in errors:
        print("error: " + e)
    print(f"{len(members)} kinds, {hashed} hash-valued, {len(errors)} disagreements")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
