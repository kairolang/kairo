#!/usr/bin/env python3
"""Build a builtin tree with extra files, for a test of a builtin declaration
the library does not have.

Usage: overlay_builtins.py <Lib> <out> [<path/in/builtin.k>=<source file>]...

Writes <out>/builtin, a copy of <Lib>/builtin with each source file placed at
its path, and re-exports each added file from module.k (`base/copy.k` adds
`pub import base::copy::*`) unless module.k already does. <out>/rt is
<Lib>/rt: the driver takes the runtime from beside the builtin tree. A file
the library already has at that path is replaced, so a test keeps its own
copy of the declaration after the library gains one.

Exit: 0 = built, 2 = bad usage or a missing input.
"""
import os
import shutil
import sys


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    lib, out = argv[1], argv[2]
    src_builtin = os.path.join(lib, "builtin")
    if not os.path.isfile(os.path.join(src_builtin, "module.k")):
        sys.stderr.write("overlay_builtins: no builtin tree at %s\n" % src_builtin)
        return 2

    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    dst_builtin = os.path.join(out, "builtin")
    shutil.copytree(src_builtin, dst_builtin)
    rt = os.path.realpath(os.path.join(lib, "rt"))
    if os.path.isdir(rt):
        try:
            os.symlink(rt, os.path.join(out, "rt"), target_is_directory=True)
        except OSError:
            shutil.copytree(rt, os.path.join(out, "rt"))

    imports = []
    for spec in argv[3:]:
        rel, sep, src = spec.partition("=")
        if not sep or not rel.endswith(".k") or not os.path.isfile(src):
            sys.stderr.write("overlay_builtins: bad file spec '%s'\n" % spec)
            return 2
        dst = os.path.join(dst_builtin, *rel.split("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        imports.append("pub import %s::*" % "::".join(rel[:-2].split("/")))

    module = os.path.join(dst_builtin, "module.k")
    with open(module, encoding="utf-8") as f:
        lines = f.read().split("\n")
    have = set(l.strip() for l in lines)
    new = [i for i in imports if i not in have]
    at = next((k for k, l in enumerate(lines) if l.startswith("pub import ")), None)
    if new and at is None:
        sys.stderr.write("overlay_builtins: module.k has no 'pub import' to add beside\n")
        return 2
    if new:
        lines[at:at] = new
    with open(module, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
