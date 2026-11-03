#!/usr/bin/env python3
"""Lists every inline-C++ site in the compiler's own Kairo sources.

Stage 1 does not emit `inline "c++"` blocks or `__inline_cpp(...)`
expressions, so the compiler cannot carry any once it compiles itself. C++
the compiler needs lives in Compiler/Native/*.hh instead.

A site is either spelling on a line that is not a comment. Comment lines are
skipped because the parser and AST document the construct they handle. A
string literal holding the spelling would be reported too; none exists.

Usage: scan.py ROOT [ROOT...]   prints `path:line: text` per site, then
`N site(s)`.
"""
import pathlib
import re
import sys

SITE = re.compile(r'inline\s+"c\+\+"|__inline_cpp\s*\(')

count = 0
for root in sys.argv[1:]:
    for path in sorted(pathlib.Path(root).rglob('*.k')):
        for no, line in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
            code = line.split('//', 1)[0]
            if SITE.search(code):
                count += 1
                print(f'{path.as_posix()}:{no}: {line.strip()}')
print(f'{count} site(s)')
