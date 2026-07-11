#!/usr/bin/env python3
"""
bad_pred_fix.py lints for Stage 0's unary-operator operand-scope bug.

CONFIRMED BUG (2026-07-09): Stage 0's transpiler parses a bare prefix unary
operator by having its operand-parse call recurse into the lowest-precedence
expression grammar rule, instead of binding to just the single atom/call-chain
immediately to its right. In practice this means the operator swallows the
ENTIRE REST of the enclosing expression -- not just what's after `&&`/`||`,
but any trailing binary operator at all.

Confirmed via isolated repro against emitted .cxx for FOUR structurally
different unary operators (so this is a shared-codepath bug, not specific
to any one operator):

    !a && b          -> !(a && b)                    [logical NOT]
    ~a && b          -> ~(a && b)                     [bitwise NOT]  -- SILENT, no type error
    *a && b          -> *(a && b)                     [dereference] -- usually caught by type checker
    -a == 0 && b     -> -(a == 0 && b)                [unary minus]  -- swallowed == AND &&

    (!a) && b        -> (!a) && b                     -- correct once parenthesized

Stage 1's own self-hosted parser handles all of these correctly -- this is a
Stage 0-only bootstrap hazard.

SCOPE NOTE: only `!` and `~` are linted here, even though `*` and `-` are
also confirmed broken. `*`, `-`, `+`, `&` are ambiguous under regex alone --
they're also valid BINARY infix operators (`a - b`, `a * b`, `a & b`), and a
plain-text scanner cannot reliably tell "unary `-` before an identifier"
apart from "binary `-` between two identifiers with a space before the next
token" without real tokenization. A first version of this linter false-
positived on exactly this ("if a - b && c" was flagged as unary `-`, and the
auto-fix would have silently turned real subtraction into unary negation --
a worse bug than the one being fixed). `!` and `~` have no binary-operator
meaning in this grammar, so they're unambiguous and safe to lint via regex.
For `*`/`-`/`+`/`&`, audit by hand or extend this tool with a real tokenizer
if it becomes worth the effort.

Usage:
    python3 Scripts/bad_pred_fix.py check          # lint, exit 1 if any found
    python3 Scripts/bad_pred_fix.py fix all         # rewrite every hit in place
    python3 Scripts/bad_pred_fix.py fix <file>      # rewrite just one file
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent if (Path(__file__).resolve().parent.name == "Scripts") else Path(".").resolve()
EXCLUDE_DIRS = {"build", ".git"}
GLOB_PATTERN = "*.k"

# Unary prefix operators safe to lint via plain regex: they have NO binary
# meaning in this grammar, so a bare `<op>ident` immediately before `&&`/`||`
# is unambiguously unary. `*`, `-`, `+`, `&` are excluded on purpose -- see
# the SCOPE NOTE above.
UNARY_OPS = ["!", "~"]
UNARY_OP_ALT = "|".join(UNARY_OPS)

# Matches a bare `<unary-op>ident(...)?(.ident(...)?)*` immediately followed
# (allowing whitespace) by `&&` or `||`, where the unary op is NOT already
# immediately followed by an opening paren (that shape is already safe --
# the paren makes the operand boundary explicit in the token stream).
PATTERN = re.compile(
    r"(?<![A-Za-z0-9_)])"                    # not preceded by an identifier/close-paren char
    rf"(?:{UNARY_OP_ALT})\s*"
    r"(?!\()"                                 # not already `<op>(` -- that form is safe
    r"[A-Za-z_][A-Za-z0-9_]*"                 # base identifier
    r"(?:\s*(?:\.|->)\s*[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)*"  # optional .foo()/->foo() chain
    r"(?:\([^)]*\))?"                         # optional trailing call parens on the base ident itself
    r"\s*(&&|\|\|)"                           # the boolean op that follows
)

# Captures just the `<op><operand>` portion so we can wrap it in parens.
OPERAND_PATTERN = re.compile(
    rf"(?:{UNARY_OP_ALT})\s*(?!\()"
    r"[A-Za-z_][A-Za-z0-9_]*"
    r"(?:\s*(?:\.|->)\s*[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)*"
    r"(?:\([^)]*\))?"
)


@dataclass
class Hit:
    file: Path
    line_no: int
    col: int          # 0-indexed column of the unary operator
    line_text: str
    match_start: int
    match_end: int
    op: str


def find_files() -> list[Path]:
    files: list[Path] = []
    for path in ROOT.rglob(GLOB_PATTERN):
        if any(part in EXCLUDE_DIRS for part in path.parts):
            continue
        files.append(path)
    return sorted(files)


def _op_at(line: str, start: int) -> str:
    for op in ("!", "~"):
        if line.startswith(op, start):
            return op
    return "?"


def scan_file(path: Path) -> list[Hit]:
    hits: list[Hit] = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return hits

    for line_no, line in enumerate(text.splitlines(), start=1):
        for m in PATTERN.finditer(line):
            op_start = m.start()
            op = _op_at(line, op_start)
            hits.append(
                Hit(
                    file=path,
                    line_no=line_no,
                    col=op_start,
                    line_text=line,
                    match_start=m.start(),
                    match_end=m.end(),
                    op=op,
                )
            )
    return hits


def scan_all() -> list[Hit]:
    all_hits: list[Hit] = []
    for f in find_files():
        all_hits.extend(scan_file(f))
    return all_hits


# ---------------------------------------------------------------------------
# diagnostic-style rendering (matches kairo's own error format)
# ---------------------------------------------------------------------------

BOLD = "\033[1m"
RED = "\033[31m"
YELLOW = "\033[33m"
GREEN = "\033[32m"
RESET = "\033[0m"

USE_COLOR = sys.stdout.isatty()


def c(code: str, s: str) -> str:
    if not USE_COLOR:
        return s
    return f"{code}{s}{RESET}"


def render_hit(hit: Hit, context: int = 1) -> str:
    lines = hit.file.read_text(encoding="utf-8", errors="replace").splitlines()

    start = max(1, hit.line_no - context)
    end = min(len(lines), hit.line_no + context)
    gutter_w = len(str(end))

    out: list[str] = []

    level = c(BOLD + YELLOW, "warn")
    out.append(f"{level}: unary `{hit.op}` operand will be mis-scoped by Stage 0 "
               f"(swallows entire `&&`/`||` expression, possibly more)")

    loc = f"{c(GREEN, str(hit.file))}:{c(YELLOW, str(hit.line_no))}:{c(YELLOW, str(hit.col + 1))}"
    out.append(f"{' ' * (gutter_w - 1)}-->  at {loc}")

    for ln in range(start, end + 1):
        text = lines[ln - 1]
        num = str(ln).rjust(gutter_w)
        if ln == hit.line_no:
            out.append(f" {num} | {text}")
            caret_pad = " " * hit.col
            caret_len = hit.match_end - hit.col
            carets = c(BOLD + RED, "^" * caret_len)
            out.append(f" {' ' * gutter_w} :  {caret_pad}{carets}")
        else:
            out.append(f" {num} | {text}")

    fixed_operand = OPERAND_PATTERN.sub(lambda m: f"({m.group(0)})", hit.line_text[hit.match_start:hit.match_end])
    out.append("")
    out.append(f"{' ' * gutter_w}  {c(BOLD + GREEN, 'fix')}: wrap the negation/operand in its own parens")
    out.append(f"{' ' * gutter_w}    {c(RED, hit.line_text[hit.match_start:hit.match_end])}")
    out.append(f"{' ' * gutter_w}    {c(GREEN, fixed_operand)}")
    out.append("")

    return "\n".join(out)


# ---------------------------------------------------------------------------
# fixing
# ---------------------------------------------------------------------------

def fix_line(line: str) -> tuple[str, int]:
    """Wrap every bare `<op>operand` (that precedes && / ||) in parens.
    Returns (new_line, number_of_fixes_applied)."""
    count = 0
    out = []
    pos = 0
    while True:
        m = PATTERN.search(line, pos)
        if not m:
            out.append(line[pos:])
            break
        op_match = OPERAND_PATTERN.match(line, m.start())
        if not op_match:
            out.append(line[pos : m.end()])
            pos = m.end()
            continue
        out.append(line[pos : op_match.start()])
        out.append(f"({op_match.group(0)})")
        count += 1
        pos = op_match.end()
    return "".join(out), count


def fix_file(path: Path) -> int:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.split("\n")
    total = 0
    for i, line in enumerate(lines):
        new_line, n = fix_line(line)
        if n:
            lines[i] = new_line
            total += n
    if total:
        path.write_text("\n".join(lines), encoding="utf-8")
    return total


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_check() -> int:
    hits = scan_all()
    if not hits:
        print(c(BOLD + GREEN, "ok") + ": no bare unary-op operands found before top-level `&&`/`||`")
        return 0

    for hit in hits:
        print(render_hit(hit))

    print(f"{c(BOLD + RED, 'error')}: {len(hits)} occurrence(s) across "
          f"{len({h.file for h in hits})} file(s) -- these will be mis-parsed by Stage 0")
    print()
    print(f"  run `python3 Scripts/bad_pred_fix.py fix all` to rewrite them in place")
    return 1


def cmd_fix(target: str) -> int:
    if target == "all":
        files = find_files()
    else:
        files = [Path(target)]

    total_fixes = 0
    total_files = 0
    for f in files:
        n = fix_file(f)
        if n:
            total_fixes += n
            total_files += 1
            print(f"  {c(GREEN, 'fixed')} {n:>2} occurrence(s) in {f}")

    if total_fixes == 0:
        print(c(BOLD + GREEN, "ok") + ": nothing to fix")
    else:
        print()
        print(f"{c(BOLD + GREEN, 'done')}: {total_fixes} fix(es) across {total_files} file(s)")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 1

    cmd = argv[1]
    if cmd == "check":
        return cmd_check()
    elif cmd == "fix":
        if len(argv) < 3:
            print("usage: bad_pred_fix.py fix <all|path/to/file.k>")
            return 1
        return cmd_fix(argv[2])
    else:
        print(__doc__)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))