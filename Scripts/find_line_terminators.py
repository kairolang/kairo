#!/usr/bin/env python3
r"""Report unusual line terminators in the tree's text files.

Editors and some tools treat these as line breaks while the compiler and
git do not (or the reverse), so a file holding one raw shows different line
numbers to different readers:

  U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR, U+0085 NEXT LINE,
  a CR not followed by LF, VT (U+000B), FF (U+000C).

Each hit is printed as `path:line:col: NAME` (line counted by LF only, as
git and the compiler count it), followed by `in literal` when it sits inside
a "..." or '...' literal on its line, where an escape (`\u{2028}`) says the
same thing without the raw character.

    python3 Scripts/find_line_terminators.py            # git-tracked files
    python3 Scripts/find_line_terminators.py Tests Lib  # these paths only
    python3 Scripts/find_line_terminators.py --summary

Exit status: 0 when nothing is found, 1 otherwise.
"""

import argparse
import os
import subprocess
import sys
from collections import Counter

NAMES = {
    chr(0x2028): "LS U+2028",
    chr(0x2029): "PS U+2029",
    "\u0085": "NEL U+0085",
    "\x0b": "VT U+000B",
    "\x0c": "FF U+000C",
}

SKIP_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".o", ".a", ".so",
    ".dylib", ".dll", ".exe", ".bin", ".zst", ".gz", ".xz", ".zip", ".tar",
    ".woff", ".woff2", ".ttf", ".otf", ".pch", ".pcm", ".bc",
}


def tracked_files(paths):
    cmd = ["git", "ls-files", "-z", "--"] + (paths or ["."])
    out = subprocess.run(cmd, capture_output=True, check=True).stdout
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def walk(paths):
    for root in paths:
        if os.path.isfile(root):
            yield root
            continue
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in (".git", "Output", "build")]
            for f in files:
                yield os.path.join(d, f)


def in_literal(line, col):
    """Whether column `col` (0-based) of `line` is inside a quoted literal."""
    quote = None
    i = 0
    while i < col:
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "/" and line[i:i + 2] == "//":
            return False
        i += 1
    return quote is not None


def scan(path):
    if os.path.splitext(path)[1].lower() in SKIP_EXT or os.path.islink(path):
        return []
    try:
        data = open(path, "rb").read()
    except OSError:
        return []
    if b"\0" in data[:8192]:
        return []
    text = data.decode("utf-8", "replace")
    hits = []
    for ln, line in enumerate(text.split("\n"), 1):
        for col, ch in enumerate(line):
            name = NAMES.get(ch)
            if name is None and ch == "\r" and col != len(line) - 1:
                name = "CR (not before LF)"
            if name:
                hits.append((path, ln, col + 1, name, in_literal(line, col)))
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", help="limit to these paths")
    ap.add_argument("--all-files", action="store_true",
                    help="walk the paths instead of asking git (untracked files too)")
    ap.add_argument("--summary", action="store_true",
                    help="print counts per file and per character only")
    args = ap.parse_args()

    files = list(walk(args.paths or ["."])) if args.all_files else tracked_files(args.paths)
    hits = []
    for f in files:
        hits.extend(scan(f))

    if args.summary:
        per_file = Counter(h[0] for h in hits)
        per_kind = Counter(h[3] for h in hits)
        for f, n in per_file.most_common():
            lit = sum(1 for h in hits if h[0] == f and h[4])
            print(f"{n:6}  {f}  ({lit} in literals)")
        print()
        for k, n in per_kind.most_common():
            print(f"{n:6}  {k}")
    else:
        for path, ln, col, name, lit in hits:
            print(f"{path}:{ln}:{col}: {name}" + ("  in literal" if lit else ""))

    print(f"\n{len(hits)} hit(s) in {len({h[0] for h in hits})} file(s)", file=sys.stderr)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
