#!/usr/bin/env python3
# Ranged for needs a binding keyword:  for x: T in xs  ->  for var x: T in xs
#
# StmtParse._parse_binding_spec_opt (:508/:511) only accepts a spec that starts
# with `var` or `const`. Without one the spec fails, `in` is never tested, and
# the header falls through to the C-style path -> "expected ';' after
# for-loop initializer".
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import masked_hits, run

RANGED_FOR = r"\bfor\s+(?!var\b|const\b)([A-Za-z_]\w*)\s*:\s*([^=;{]+?)\s+in\b"


def rewrite(src, path, report):
    hits = masked_hits(src, RANGED_FOR)
    for m in reversed(hits):
        src = (src[: m.start()]
               + f"for var {m.group(1)}: {m.group(2).strip()} in"
               + src[m.end():])
    return src, len(hits)


if __name__ == "__main__":
    sys.exit(run(rewrite, "ranged for: `for x: T in` -> `for var x: T in`"))
