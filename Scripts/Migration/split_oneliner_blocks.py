#!/usr/bin/env python3
# A block holding more than one statement gets one statement per line:
#
#     if self._pool != &null { std::destroy(self._pool); self._pool = &null; }
#
#  ->
#
#     if self._pool != &null {
#         std::destroy(self._pool);
#         self._pool = &null;
#     }
#
# The line's own indent is kept and the body goes one level (4 spaces, or a
# tab if the line is tab-indented) deeper. Padding INSIDE the header and the
# statements is kept verbatim -- only the run of alignment spaces before the
# `{` collapses to one, since it aligned nothing once the body moves down.
#
# By default only blocks with two or more statements split: single-statement
# one-liners (`case K { return "K"; }`) are the bulk of the tree and read fine
# as they are. --all splits those too.
#
# What counts as a block: a `{ ... }` with a `;` at its own top level. That is
# what tells a body apart from an initializer (`Foo{a, b}`), which never has
# one -- so a single statement with no `;` (`{ return }`) is not split even
# under --all.
#
# Whole-line rules:
#   - Sibling blocks split together: `if a { x; y; } else { z; }` becomes a
#     full if/else, never a half-split one.
#   - A nested one-liner splits only if it qualifies on its own, but when it
#     does, every block enclosing it on that line splits too.
#   - A leading `}` closing an earlier block (`} else { a; b; }`) and a
#     trailing unclosed `{` (`if a { x; y; } else {`) are header text.
#   - Not touched: blocks inside ( ) or [ ] (a lambda argument), lines that
#     continue an open ( or [ from an earlier line, and comments, strings and
#     inline "c++" bodies (kairo_lex).
#   - Reported, not rewritten: a `}` that closes an outer block AFTER a
#     one-liner on the same line (`case A { a; b; } }`) -- where the body
#     belongs is ambiguous.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask

# A block followed by one of these continues the same statement.
CONTINUES = {"else", "catch", "finally"}
IDENT_START = re.compile(r"[A-Za-z_]")
IDENT = re.compile(r"[A-Za-z_]\w*")


class Skip(Exception):
    pass


class Line:
    """A slice of the source with its code mask; offsets are slice-relative."""

    def __init__(self, s, m):
        self.s, self.m = s, m

    def sub(self, a, b):
        return Line(self.s[a:b], self.m[a:b])

    def strip(self):
        a, b = 0, len(self.s)
        while a < b and self.s[a].isspace():
            a += 1
        while b > a and self.s[b - 1].isspace():
            b -= 1
        return self.sub(a, b)


def has_top_semicolon(ln):
    depth = 0
    for c, code in zip(ln.s, ln.m):
        if not code:
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ";" and depth == 0:
            return True
    return False


def groups(ln, top_line):
    """(open, close) of every `{...}` at depth 0 of ln.

    For the line itself, an unmatched `}` before the first group and an
    unclosed `{` after the last are header text. Anything else unbalanced
    raises Skip.
    """
    out = []
    stack = []
    for i, (c, code) in enumerate(zip(ln.s, ln.m)):
        if not code:
            continue
        if c in "([{":
            stack.append((c, i))
        elif c in ")]}":
            if not stack:
                if top_line and c == "}" and not out:
                    continue
                raise Skip("unbalanced `}` after a one-liner")
            o, at = stack.pop()
            if o == "{" and c == "}" and not stack:
                out.append((at, i))
    if stack and not top_line:
        raise Skip("unbalanced bracket inside a block")
    # An unclosed `{`/`(`/`[` swallows everything after it; only groups
    # before it are really at the line's depth 0.
    if stack:
        first_open = stack[0][1]
        out = [g for g in out if g[1] < first_open]
    return out


def statements(body):
    """Split a block body into its top-level statements (each stripped)."""
    out = []
    depth = 0
    start = 0
    n = len(body.s)
    i = 0
    while i < n:
        c, code = body.s[i], body.m[i]
        if code:
            if c in "([{":
                if depth == 0 and c == "{":
                    brace_at = i
                depth += 1
            elif c in ")]}":
                depth -= 1
                # A block ends its statement unless else/catch/finally (or
                # punctuation, e.g. `Foo{...}.x`) carries on after it.
                if (depth == 0 and c == "}"
                        and has_top_semicolon(body.sub(brace_at + 1, i))):
                    j = i + 1
                    while j < n and body.s[j].isspace():
                        j += 1
                    w = IDENT.match(body.s, j)
                    if w and body.m[j] and w.group() not in CONTINUES:
                        out.append(body.sub(start, i + 1).strip())
                        start = i + 1
            elif c == ";" and depth == 0:
                out.append(body.sub(start, i + 1).strip())
                start = i + 1
        i += 1
    tail = body.sub(start, n).strip()
    if tail.s:
        out.append(tail)
    return [s for s in out if s.s]


def render(ln, indent, unit, min_stmts, top_line=False):
    """Lines for ln at indent, or None when nothing on it needs splitting."""
    blocks = []
    for a, b in groups(ln, top_line):
        body = ln.sub(a + 1, b)
        if not has_top_semicolon(body):
            continue  # an initializer, not a block
        stmts = statements(body)
        kids = [render(s, indent + unit, unit, min_stmts) for s in stmts]
        split = len(stmts) >= min_stmts or any(k is not None for k in kids)
        blocks.append((a, b, stmts, kids, split))

    if not any(blk[4] for blk in blocks):
        return None

    lines = []
    head = ln.s[:blocks[0][0]].strip()
    cur = indent + (head + " {" if head else "{")
    for idx, (a, b, stmts, kids, _) in enumerate(blocks):
        lines.append(cur)
        for s, k in zip(stmts, kids):
            lines.extend(k if k is not None else [indent + unit + s.s])
        if idx + 1 < len(blocks):
            between = ln.s[b + 1:blocks[idx + 1][0]].strip()
            cur = indent + "} " + between + " {" if between else indent + "} {"
        else:
            tail = ln.s[b + 1:].strip()
            if not tail:
                lines.append(indent + "}")
            elif IDENT_START.match(tail) or tail.startswith(("//", "/*")):
                lines.append(indent + "} " + tail)
            else:
                lines.append(indent + "}" + tail)
    return lines


def rewrite(src, path, report):
    min_stmts = 1 if "--all" in sys.argv else 2
    mask = code_mask(src)
    out = []
    count = 0
    paren = 0  # open ( and [ carried in from earlier lines
    pos = 0
    for raw in src.splitlines(keepends=True):
        end = pos + len(raw)
        body = raw.rstrip("\r\n")
        eol = raw[len(body):]
        m = mask[pos:pos + len(body)]
        start_paren = paren
        for c, code in zip(body, m):
            if code:
                if c in "([":
                    paren += 1
                elif c in ")]":
                    paren -= 1
        pos = end

        if start_paren > 0 or "{" not in body:
            out.append(raw)
            continue
        indent = body[:len(body) - len(body.lstrip())]
        unit = "\t" if "\t" in indent else "    "
        ln = Line(body, m).sub(len(indent), len(body))
        try:
            lines = render(ln, indent, unit, min_stmts, top_line=True)
        except Skip as e:
            line_no = src.count("\n", 0, end - len(raw)) + 1
            report.append(f"{path}:{line_no}: {e}")
            out.append(raw)
            continue
        if lines is None:
            out.append(raw)
            continue
        out.append("\n".join(lines) + (eol or ""))
        count += 1
    return "".join(out), count


if __name__ == "__main__":
    from kairo_lex import run
    sys.exit(run(rewrite, "one-line blocks: `{ a; b; }` -> one statement per line"
                          + (" (--all: single-statement too)" if "--all" in sys.argv else "")))
