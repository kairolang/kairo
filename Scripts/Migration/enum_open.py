#!/usr/bin/env python3
# enum E derives U { ... }  ->  @open enum E derives U { ... }, for the enums
# in TABLE, each marked `// TODO(ENUM-OPEN): <category> -- <why>`.
#
# A Stage 1 plain enum is CLOSED unless declared @open (Spec/Docs
# enums-plain, "Closed and open enums"): `n as E` checks n against the
# variants and crashes on any other value. cpp_casts turns every Stage 0
# static_cast<E>(n) into exactly that checked `n as E` (the user's choice,
# 2026-11-03). That is right where n is always some variant -- a loop over
# 0..COUNT, a value read back from where an E was stored -- and wrong for
# the enums below, which hold values no variant names by design:
#
#   flags        a bit set: `A | B` is a value, and no variant is it
#   hash-probe   the values are hashes of spellings, and an arbitrary hash
#                is cast BEFORE it is known to be one (is_valid_token_kind
#                switches on the cast value; the lexer makes error tokens
#                from unknown hashes)
#
# Those become @open, which takes any value of U unchecked, as Stage 0's C++
# enum did. The table is by hand on purpose: whether a value can be a
# non-variant is a property of the code that makes it, not of the enum's
# spelling. It came from cpp_casts' 78 "int -> closed enum" sites on
# 2026-11-03 (20 enums); the 13 not listed were read and are always a
# variant (Precedence, BuiltinKind, VisibilityKind, ResolveState, TyperState,
# WellKnownType, PrimLimit, DeclNameKind, DiagID, ...). FnModifier is opened
# by selfhost patch 002 together with its operators.
#
# An entry whose enum is not found is reported; one already @open is left.
# Adds two lines above the enum, so it runs after cpp_casts (line-paired).
#
#     python3 Scripts/Migration/enum_open.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/enum_open.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

# file (path suffix) -> {enum name: (category, why)}
TABLE = {
    "Compiler/AST/Node/Base.k": {
        "ExprFlags": ("flags", "combined with | (dependent, has-error, ...)"),
        "TypeFlags": ("flags", "combined with | and stored as a u8 mask"),
    },
    "Compiler/AST/Node/Statements.k": {
        "BindingShorthand": ("flags", "Pointer | Unsafe | Nullable"),
    },
    "Compiler/AST/Node/PrimaryExpressions.k": {
        "StringKind": ("flags", "Raw | Format"),
    },
    "Compiler/Lexer/Immediate.k": {
        "TextPrefixKind": ("flags", "Raw | Format"),
    },
    "Compiler/Parser/ExprParse.k": {
        "ExprStopKind": ("flags", "stop sets are ORed (StopComma | StopParen | ...)"),
    },
    "Compiler/Token/TokenKind.k": {
        "TokenKind": ("hash-probe", "values are spelling hashes; is_valid_token_kind and the "
                                    "lexer cast an arbitrary hash before knowing it is a kind"),
    },
}

ENUM = re.compile(r"^([ \t]*)((?:(?:pub|priv|prot)\s+)?)enum\s+([A-Za-z_]\w*)\b", re.M)


def entries_for(path):
    p = path.replace("\\", "/")
    for suffix, ents in TABLE.items():
        if p == suffix or p.endswith("/" + suffix):
            return ents
    return None


def rewrite(src, path, report):
    ents = entries_for(path)
    if not ents:
        return src, 0
    mask = code_mask(src)
    seen, edits = set(), []
    for m in ENUM.finditer(src):
        name = m.group(3)
        if name not in ents or not mask[m.start(3)]:
            continue
        seen.add(name)
        # already open: `@open` on one of the three lines above, or inline
        k = m.start()
        for _ in range(3):
            k = src.rfind("\n", 0, max(0, k - 1)) if k > 0 else -1
        if re.search(r"@open\b", src[k + 1:m.end()]):
            continue
        ind = m.group(1)
        cat, why = ents[name]
        edits.append((m.start(), f"{ind}// TODO(ENUM-OPEN): {cat} -- {why}\n{ind}@open\n"))
    for name in sorted(set(ents) - seen):
        report.append(f"{path}: enum {name} not found (TABLE is stale?)")
    for at, text in sorted(edits, reverse=True):
        src = src[:at] + text + src[at:]
    return src, len(edits)


CASES = [
    ("Compiler/AST/Node/Statements.k",
     "/// doc\nenum BindingShorthand derives u8 {\n    None = 0,\n}\n",
     "/// doc\n// TODO(ENUM-OPEN): flags -- Pointer | Unsafe | Nullable\n@open\n"
     "enum BindingShorthand derives u8 {\n    None = 0,\n}\n"),
    ("Compiler/AST/Node/Base.k",
     "class Expr {\n    enum ExprFlags derives u8 {\n    }\n    enum TypeFlags derives u8 { }\n}\n",
     "class Expr {\n    // TODO(ENUM-OPEN): flags -- combined with | (dependent, has-error, ...)\n    @open\n"
     "    enum ExprFlags derives u8 {\n    }\n"
     "    // TODO(ENUM-OPEN): flags -- combined with | and stored as a u8 mask\n    @open\n"
     "    enum TypeFlags derives u8 { }\n}\n"),
    ("Compiler/AST/Node/Statements.k",
     "@open\nenum BindingShorthand derives u8 { }\n",
     "@open\nenum BindingShorthand derives u8 { }\n"),
    ("Compiler/AST/Node/Statements.k",
     "// enum BindingShorthand is below\nenum Other derives u8 { }\n",
     "// enum BindingShorthand is below\nenum Other derives u8 { }\n"),
    ("Compiler/Other.k",
     "enum TokenKind derives u32 { }\n",
     "enum TokenKind derives u32 { }\n"),
]


def selftest():
    bad = 0
    for path, src, want in CASES:
        got, _ = rewrite(src, path, [])
        again, n2 = rewrite(got, path, [])
        ok = got == want and n2 == 0 and again == got
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src.replace("\n", "\\n")[:70]
              + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "@open on the enums whose values are not always variants"))
