#!/usr/bin/env python3
# import Linker::API::X  ->  import API::X
#
# Module identity in Stage 1 is the path below the deepest -I root holding
# the file (Compiler/Sema/IMPORTS.md, "Module roots and paths"), and it
# depends on the -I SET: compiled without `-I .`, Linker/API/Text.k is
# `API::Text`, with it some TU may name it `Linker::API::Text` -- two
# namespaces for one file (SELFHOST.md 2.1, P344). The user's decision
# (option A, 2026-11-02): the self-host build line is `-I Compiler -I Linker`
# and nothing else, and the 62 imports that only resolved through the repo
# root (`.`) -- CompilerInstance.k, ClangJobs.k and 52 inside Linker/API --
# name the module through its own root.
#
# Only `import` lines are rewritten; the audit found no qualified
# `Linker::` use outside them.
#
#     python3 Scripts/Migration/linker_api_imports.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/linker_api_imports.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

IMPORT = re.compile(r"\bimport(\s+)Linker::(?=API::)")
STRAY = re.compile(r"\bLinker::API::")


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = [m for m in IMPORT.finditer(src) if mask[m.start()]]
    for m in reversed(edits):
        src = src[:m.start()] + "import" + m.group(1) + src[m.end():]
    mask = code_mask(src)
    for m in STRAY.finditer(src):
        if mask[m.start()]:
            report.append(f"{path}:{src.count(chr(10), 0, m.start()) + 1}: qualified Linker::API:: outside an import; left as is")
    return src, len(edits)


CASES = [
    ("import Linker::API::Text::*;", "import API::Text::*;"),
    ("import Linker::API::Flavor::ELF;", "import API::Flavor::ELF;"),
    ("import  Linker::API::Link as L;", "import  API::Link as L;"),
    ("import API::Text::*;", "import API::Text::*;"),
    ("// import Linker::API::Text", "// import Linker::API::Text"),
    ("import Linker::Driver::kld;", "import Linker::Driver::kld;"),
]


def selftest():
    bad = 0
    for src, want in CASES:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        ok = got == want and n2 == 0
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "import Linker::API::X -> import API::X"))
