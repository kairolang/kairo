#!/usr/bin/env python3
# Comment out `ffi "c++" import "hdr";` lines.
#
# A dry-run aid, not a port step: it existed so a known Stage 1 parse gap could
# not swamp the residual parse-error list with noise that says nothing about
# the transforms under test. The marker is grep-able on purpose --
#
#     rg PORTDRY-FFI-STUB
#
# -- because every stub has to come back before the tree means anything. Do not
# run this on a tree you intend to keep.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import run

FFI = re.compile(r'^([ \t]*)(ffi\s+"c\+\+"\s+import\s+".*?";.*)$', re.M)


def rewrite(src, path, report):
    n = [0]

    def sub(m):
        n[0] += 1
        return f"{m.group(1)}// PORTDRY-FFI-STUB: {m.group(2)}"

    return FFI.sub(sub, src), n[0]


if __name__ == "__main__":
    sys.exit(run(rewrite, "stub out ffi \"c++\" imports (DRY-RUN AID -- reversible by grep)"))
