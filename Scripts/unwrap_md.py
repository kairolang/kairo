#!/usr/bin/env python3
"""Unwrap hard-wrapped Markdown: each paragraph, list item and block-quote
paragraph becomes one line.

    python3 Scripts/unwrap_md.py FILE.md ...          # rewrite in place
    python3 Scripts/unwrap_md.py --check FILE.md ...  # list files that would change

Left verbatim: fenced code (``` / ~~~), indented code blocks, tables, headings,
HTML lines, horizontal rules, link reference definitions, and hard line breaks
(a line ending in two spaces or a backslash). A continuation line is joined to
the line above with one space; a line that starts a new block (list marker,
heading, quote, table row, fence) is never joined.
"""
import re
import sys
from pathlib import Path

FENCE = re.compile(r"^\s*(```|~~~)")
LIST = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+")
HEADING = re.compile(r"^\s{0,3}#{1,6}(\s|$)")
RULE = re.compile(r"^\s{0,3}([-*_])(\s*\1){2,}\s*$")
SETEXT = re.compile(r"^\s{0,3}(=+|-+)\s*$")
LINKDEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s")
QUOTE = re.compile(r"^(\s*>\s?)")


def starts_block(line: str) -> bool:
    s = line.lstrip()
    return (not s or HEADING.match(line) is not None or FENCE.match(line) is not None
            or LIST.match(line) is not None or s.startswith("|") or s.startswith("<")
            or RULE.match(line) is not None or LINKDEF.match(line) is not None
            or QUOTE.match(line) is not None)


def hard_break(line: str) -> bool:
    return line.endswith("  ") or line.endswith("\\")


def unwrap(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    joinable = False     # out[-1] is paragraph / list-item / quote text another line may join
    in_list = False      # inside a list (so indented lines are continuations, not code)
    fence = None
    prev_blank = True
    for line in lines:
        if fence is not None:
            out.append(line)
            if line.lstrip().startswith(fence):
                fence = None
            continue
        m = FENCE.match(line)
        if m:
            fence = m.group(1)
            out.append(line)
            joinable = False
            prev_blank = False
            continue
        if not line.strip():
            out.append(line)
            joinable = False
            prev_blank = True
            continue
        indent = len(line) - len(line.lstrip(" "))
        # An indented code block: 4+ spaces after a blank line, outside a list.
        if indent >= 4 and not in_list and (prev_blank or not joinable):
            out.append(line)
            joinable = False
            prev_blank = False
            continue
        if indent == 0 and not LIST.match(line):
            in_list = False if prev_blank else in_list
        if LIST.match(line):
            in_list = True
        q = QUOTE.match(line)
        if q and joinable and out and QUOTE.match(out[-1]):
            rest = line[q.end():]
            if rest.strip() and not starts_block(rest) and not hard_break(out[-1]):
                out[-1] = out[-1].rstrip() + " " + rest.strip()
                prev_blank = False
                continue
        if (joinable and not starts_block(line) and not SETEXT.match(line)
                and not hard_break(out[-1])):
            out[-1] = out[-1].rstrip() + " " + line.strip()
            prev_blank = False
            continue
        out.append(line)
        s = line.lstrip()
        joinable = not (HEADING.match(line) or s.startswith("|") or s.startswith("<")
                        or RULE.match(line) or LINKDEF.match(line))
        prev_blank = False
    return "\n".join(out)


def main() -> int:
    args = sys.argv[1:]
    check = "--check" in args
    files = [Path(a) for a in args if a != "--check"]
    changed = 0
    for f in files:
        old = f.read_text()
        new = unwrap(old)
        if new != old:
            changed += 1
            if check:
                print(f)
            else:
                f.write_text(new)
    print(f"{changed}/{len(files)} file(s) {'would change' if check else 'rewritten'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
