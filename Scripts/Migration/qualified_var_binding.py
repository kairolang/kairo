#!/usr/bin/env python3
# A storage qualifier is the binding keyword on its own:
#
#     static var x  ->  static x
#     const var x   ->  const x
#     eval var x    ->  eval x
#
# Stage 0 wanted `var` after the qualifier; Stage 1 treats the qualifier as the
# binding keyword, so the trailing `var` is dropped. A stacked run
# (`static const var`) keeps every qualifier and loses only the `var`.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import masked_hits, run

QUALIFIED_VAR = r"\b((?:static|const|eval)(?:\s+(?:static|const|eval))*)\s+var\b"


def rewrite(src, path, report):
    hits = masked_hits(src, QUALIFIED_VAR)
    for m in reversed(hits):
        src = src[: m.start()] + m.group(1) + src[m.end():]
    return src, len(hits)


if __name__ == "__main__":
    sys.exit(run(rewrite, "qualified binding: `static/const/eval var` -> `static/const/eval`"))
