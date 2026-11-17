#!/usr/bin/env python3
"""Emits the C++ headers of every file of a library and compiles each one
as the first and only include of its own C++ translation unit.

    check_emitted_headers.py --headers DIR --root PREFIX=SRC [--root ...]
                             [--no-header REL ...] -- KAIRO ARGS... -- CLANG ARGS...

`KAIRO ARGS... --type-check-only --emit-headers DIR <every .k file>` writes
the headers, the files in sorted order, each root's in turn. Every `.k`
file under each SRC maps to `DIR/PREFIX/<path>.hh` (`module.k`
to `DIR/PREFIX.hh`). A file with no header fails the check unless it is
named by --no-header (as `PREFIX/<path>.k`): a file that declares nothing
C++ can name gets none, and the list keeps that visible. A named file that
does get a header fails too, so the list stays exact. Each header is then
compiled with `CLANG ARGS... -fsyntax-only -I DIR <tu>`, where the TU is
`#include "<header>"` alone, so a header that compiles only after another
one fails here. Exit status 0 when every check passes.
"""

import argparse
import concurrent.futures
import os
import subprocess
import sys
import tempfile


def main():
    if sys.argv.count("--") != 2:
        sys.exit("check_emitted_headers.py: want -- KAIRO ARGS... -- CLANG ARGS...")
    cut = sys.argv.index("--")
    cut2 = sys.argv.index("--", cut + 1)
    kairo = sys.argv[cut + 1:cut2]
    clang = sys.argv[cut2 + 1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--headers", required=True)
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--no-header", action="append", default=[])
    args = ap.parse_args(sys.argv[1:cut])

    sources = []
    for spec in args.root:
        src = spec.split("=", 1)[1]
        for dirpath, _, files in sorted(os.walk(src)):
            sources += [os.path.join(dirpath, f) for f in sorted(files) if f.endswith(".k")]
    r = subprocess.run(kairo + ["--type-check-only", "--emit-headers", args.headers] + sources,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True)
    if r.returncode != 0:
        print(r.stdout)
        print("FAIL kairo --emit-headers exited %d" % r.returncode)
        return 1

    problems = []
    headers = []
    for spec in args.root:
        prefix, src = spec.split("=", 1)
        for dirpath, _, files in os.walk(src):
            for f in sorted(files):
                if not f.endswith(".k"):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, f), src).replace(os.sep, "/")
                name = prefix + "/" + rel
                stem = prefix if rel == "module.k" else prefix + "/" + rel[:-2]
                hh = stem + ".hh"
                have = os.path.isfile(os.path.join(args.headers, hh))
                if name in args.no_header:
                    if have:
                        problems.append("%s: has a header (%s) but is listed by --no-header" % (name, hh))
                elif not have:
                    problems.append("%s: no header %s" % (name, hh))
                else:
                    headers.append(hh)

    work = tempfile.mkdtemp(prefix="hdrcheck", dir=args.headers)

    def check(hh):
        tu = os.path.join(work, hh.replace("/", "__") + ".cc")
        with open(tu, "w", encoding="utf-8") as out:
            out.write('#include "%s"\n' % hh)
        r = subprocess.run(clang + ["-fsyntax-only", "-I", args.headers, tu],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True)
        if r.returncode == 0:
            return None
        errs = [l for l in r.stdout.splitlines() if "error:" in l]
        return "%s: %d error(s)\n    %s" % (hh, len(errs), "\n    ".join(errs[:5]))

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for res in pool.map(check, headers):
            if res:
                problems.append(res)

    for p in problems:
        print("FAIL " + p)
    print("checked %d header(s), %d problem(s)" % (len(headers), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
