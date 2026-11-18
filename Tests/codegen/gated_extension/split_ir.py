#!/usr/bin/env python3
"""Split a `--print-ir` dump into one file per translation unit.

    split_ir.py <dump> <out-dir>

Each `// ===... CODEGEN C++: <path> ===...` section is written to
<out-dir>/<file name>.cc, so a test can assert on one unit's C++ alone.
"""
import os
import re
import sys


def main():
    dump, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    cur = None
    seen = set()
    head = re.compile(r"^// =+ CODEGEN C\+\+: (.*?) =+$")
    with open(dump, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = head.match(line.rstrip("\n"))
            if m:
                if cur:
                    cur.close()
                name = os.path.basename(m.group(1)) + ".cc"
                # A unit dumped twice in one run (preamble, then bodies) is
                # appended to; a file left by an earlier run is replaced.
                cur = open(os.path.join(out, name), "a" if name in seen else "w", encoding="utf-8")
                seen.add(name)
                continue
            if cur:
                cur.write(line)
    if cur:
        cur.close()


if __name__ == "__main__":
    main()
