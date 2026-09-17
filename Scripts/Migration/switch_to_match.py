#!/usr/bin/env python3
# switch -> match, STATEMENT keyword only.
#
# Statement position means nothing but whitespace (or `eval`) before it on the
# line, so a `switch` used as an identifier, a field name or inside an
# expression is left alone.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run


def rewrite(src, path, report):
    mask = code_mask(src)
    hits = []
    for m in re.finditer(r"\bswitch\b", src):
        p = m.start()
        if not all(mask[k] for k in range(p, m.end())):
            continue
        ls = src.rfind("\n", 0, p) + 1
        if src[ls:p].strip() not in ("", "eval"):
            continue
        hits.append((p, m.end()))

    # apply right-to-left: "switch" and "match" differ in length, so
    # left-to-right index mutation shifts every subsequent offset
    out = src
    for p, e in reversed(hits):
        out = out[:p] + "match" + out[e:]
    return out, len(hits)


if __name__ == "__main__":
    sys.exit(run(rewrite, "switch -> match (statement keyword only)"))
