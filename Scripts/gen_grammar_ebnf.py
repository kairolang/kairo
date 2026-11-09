#!/usr/bin/env python3
"""Regenerate Compiler/Spec/Grammar.ebnf from the tree-sitter grammar.

    python3 Scripts/gen_grammar_ebnf.py            # writes Compiler/Spec/Grammar.ebnf
    python3 Scripts/gen_grammar_ebnf.py --check    # exit 1 if the file is out of date

Input is tree-sitter's normalized grammar, Extras/LSPClients/tree-sitter-kairo/
src/grammar.json, which `tree-sitter generate` writes from grammar.js. Output is
W3C-style EBNF (`name ::= ...`, `|`, `?`, `*`, `+`, quoted literals, /regex/
tokens). Rule order follows grammar.js; the first rule is the start symbol.

tree-sitter constructs with no EBNF meaning are dropped, not translated:
precedence and associativity (prec, prec.left, prec.right, prec.dynamic),
field names, token()/token.immediate() wrappers, and aliases (the aliased
content is printed). Precedence lives in grammar.js and in the parser.
Standard library only.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Extras" / "LSPClients" / "tree-sitter-kairo" / "src" / "grammar.json"
OUT = ROOT / "Compiler" / "Spec" / "Grammar.ebnf"
WIDTH = 100

# Binding strength of a printed form: alternation < sequence < postfix/atom.
ALT, SEQ, ATOM = 0, 1, 2

WRAPPERS = {"FIELD", "ALIAS", "TOKEN", "IMMEDIATE_TOKEN", "PREC", "PREC_LEFT", "PREC_RIGHT",
            "PREC_DYNAMIC"}


def unwrap(n: dict) -> dict:
    while n["type"] in WRAPPERS:
        n = n["content"]
    return n


def literal(s: str) -> str:
    if '"' not in s:
        return '"' + s.replace("\\", "\\\\") + '"'
    if "'" not in s:
        return "'" + s.replace("\\", "\\\\") + "'"
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(n: dict) -> tuple[str, int]:
    """Returns (text, binding strength)."""
    n = unwrap(n)
    t = n["type"]
    if t == "STRING":
        return literal(n["value"]), ATOM
    if t == "PATTERN":
        return "/" + n["value"].replace("/", "\\/") + "/", ATOM
    if t == "SYMBOL":
        return n["name"], ATOM
    if t == "BLANK":
        return "ε", ATOM
    if t == "SEQ":
        parts = [group(m, SEQ) for m in n["members"] if unwrap(m)["type"] != "BLANK"]
        if not parts:
            return "ε", ATOM
        return (" ".join(parts), SEQ) if len(parts) > 1 else (parts[0], ATOM)
    if t in ("REPEAT", "REPEAT1"):
        return group(n["content"], ATOM) + ("*" if t == "REPEAT" else "+"), ATOM
    if t == "CHOICE":
        members = n["members"]
        optional = any(unwrap(m)["type"] == "BLANK" for m in members)
        alts = [m for m in members if unwrap(m)["type"] != "BLANK"]
        if not alts:
            return "ε", ATOM
        if optional:
            inner = alts[0] if len(alts) == 1 else {"type": "CHOICE", "members": alts}
            return group(inner, ATOM) + "?", ATOM
        if len(alts) == 1:
            return render(alts[0])
        return " | ".join(group(m, SEQ) for m in alts), ALT
    raise SystemExit(f"gen_grammar_ebnf: unhandled node type {t}")


def group(n: dict, need: int) -> str:
    text, strength = render(n)
    return text if strength >= need else f"( {text} )"


def rule(name: str, body: dict) -> str:
    head = f"{name} ::= "
    b = unwrap(body)
    # A top-level choice of several alternatives goes one alternative per line.
    if b["type"] == "CHOICE" and not any(unwrap(m)["type"] == "BLANK" for m in b["members"]) \
            and len(b["members"]) > 1:
        alts = [group(m, SEQ) for m in b["members"]]
        one = head + " | ".join(alts)
        if len(one) <= WIDTH:
            return one
        pad = " " * (len(head) - 2)
        return head + alts[0] + "".join(f"\n{pad}| {a}" for a in alts[1:])
    return head + render(body)[0]


def header(g: dict) -> str:
    externals = [e.get("name", "?") for e in g.get("externals", [])]
    extras = [render(e)[0] for e in g.get("extras", [])]
    lines = [
        "// Kairo grammar, W3C-style EBNF.",
        "//",
        "// Generated from the tree-sitter grammar (Extras/LSPClients/tree-sitter-kairo/grammar.js,",
        "// via its src/grammar.json) by Scripts/gen_grammar_ebnf.py. Do not edit by hand:",
        "// change grammar.js, run `tree-sitter generate`, then rerun the script.",
        "//",
        "// The parser in Compiler/Parser/ remains the authority for syntax (see",
        "// Compiler/Spec/Parsing.md), and the language reference for meaning. This grammar",
        "// describes the same language for tooling; where they disagree, the parser wins.",
        "//",
        "// Notation: `::=` defines, `|` separates alternatives, `?` `*` `+` are optional,",
        "// zero-or-more and one-or-more, `( )` groups, quoted text is literal, /.../ is a",
        "// regular expression over characters, and ε is the empty sequence.",
        "//",
        "// Not expressed here: operator precedence and associativity, which the tree-sitter",
        f"// grammar encodes with prec annotations; and its {len(g.get('conflicts', []))} declared GLR conflicts.",
        f"// The start symbol is `{next(iter(g['rules']))}`. Keywords are lexed as the word token",
        f"// `{g.get('word')}`.",
    ]
    if extras:
        lines.append("//")
        lines.append("// Allowed between any two tokens (tree-sitter extras): " + ", ".join(extras) + ".")
    if externals:
        lines.append("//")
        lines.append("// Produced by the external scanner (src/scanner.c), not defined below:")
        lines.append("//   " + ", ".join(externals) + ".")
    return "\n".join(lines) + "\n"


def generate() -> str:
    g = json.loads(SRC.read_text(encoding="utf-8"))
    body = "\n\n".join(rule(name, r) for name, r in g["rules"].items())
    return header(g) + "\n" + body + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if Grammar.ebnf is out of date")
    a = ap.parse_args()
    text = generate()
    if a.check:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == text
        print(f"{OUT.relative_to(ROOT)}: {'up to date' if ok else 'OUT OF DATE'}")
        return 0 if ok else 1
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({text.count(chr(10))} lines, from {SRC.relative_to(ROOT)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
