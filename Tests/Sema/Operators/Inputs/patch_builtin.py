"""Add members to one declaration in a copy of a builtin root.

    patch_builtin.py ROOT HEAD MEMBERS

Finds the single line under ROOT (any *.k file, at any depth) whose text,
stripped, starts with HEAD and ends with `{`, and inserts MEMBERS' contents
after it. The declaration is found by what it says, not by the file it is in,
so the fixture survives Lib/builtin moving its declarations between files.
Fails when HEAD matches no line or more than one.
"""
import os
import sys


def main():
    root, head, members = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(members, encoding="utf-8") as f:
        text = f.read()
    hits = []
    for d, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".k"):
                continue
            path = os.path.join(d, name)
            with open(path, encoding="utf-8") as f:
                lines = f.readlines()
            for i, line in enumerate(lines):
                s = line.strip()
                if s.startswith(head) and s.endswith("{"):
                    hits.append((path, lines, i))
    if len(hits) != 1:
        sys.exit("patch_builtin.py: %d declarations start with %r under %s"
                 % (len(hits), head, root))
    path, lines, i = hits[0]
    lines.insert(i + 1, text if text.endswith("\n") else text + "\n")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)


if __name__ == "__main__":
    main()
