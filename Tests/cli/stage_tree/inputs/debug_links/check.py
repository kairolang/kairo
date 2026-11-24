"""Drives Scripts/stage_tree.py's bundling (bundle_tree) on small trees.

    check.py <Scripts dir> <scratch dir> <clang>

A fake LLVM build holds libkfake.so.1 and a soname alias to it; each tree's
bin/prog needs libkfake.so.1. Prints, per case, what lib/ holds afterwards
and what the bundling logged; the LLVM build's library must not change.
"""
import hashlib
import os
import subprocess
import sys
from pathlib import Path

scripts, scratch, clang = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
llvm = scratch / "llvm"
(llvm / "lib").mkdir(parents=True)
src = scratch / "fake.c"
src.write_text("int fake(void) { return 7; }\n")
main = scratch / "main.c"
main.write_text("int fake(void);\nint main(void) { return fake() - 7; }\n")
real = llvm / "lib" / "libkfake.so.1"
subprocess.run([clang, "-fPIC", "-shared", "-Wl,-soname,libkfake.so.1", str(src), "-o", str(real)],
               check=True)
os.symlink("libkfake.so.1", llvm / "lib" / "libkfake.so")

os.environ["KAIRO_LLVM_BUILD"] = str(llvm)
os.environ.pop("KAIRO_TREE_OS", None)
sys.path.insert(0, str(scripts))
import stage_tree  # noqa: E402

logged = []
stage_tree.log = lambda msg="": logged.append(msg)


def tree(name):
    t = scratch / name
    (t / "bin").mkdir(parents=True)
    (t / "lib").mkdir()
    subprocess.run([clang, str(main), "-L", str(llvm / "lib"), "-lkfake",
                    "-Wl,-rpath," + str(llvm / "lib"), "-o", str(t / "bin" / "prog")], check=True)
    return t


def show(case, t, debug):
    logged.clear()
    ok = stage_tree.bundle_tree(t, debug)
    f = t / "lib" / "libkfake.so.1"
    if f.is_symlink():
        kind = "link " + os.readlink(f) + (" (to the build)" if f.resolve() == real.resolve() else " (ELSEWHERE)")
    elif f.is_file():
        kind = "copy"
    else:
        kind = "missing"
    acts = [m.split()[0] for m in logged if m.startswith(("linked", "bundled"))]
    print(f"{case}: {kind}; {'OK' if ok else 'NOT OK'}; acts {acts}")
    for m in logged:
        if m.startswith("FAIL"):
            print("  " + m)


before = hashlib.sha256(real.read_bytes()).hexdigest()

dbg = tree("dbg")
show("debug", dbg, True)
show("debug again", dbg, True)
# A debug tree staged before linking holds a copy: it becomes a link.
f = dbg / "lib" / "libkfake.so.1"
f.unlink()
f.write_bytes(real.read_bytes())
show("debug from copy", dbg, True)
# A soname alias inside lib/ is the tree's own and stays.
os.symlink("libkfake.so.1", dbg / "lib" / "libkfake.so")
show("debug alias", dbg, True)
print("alias:", os.readlink(dbg / "lib" / "libkfake.so"))

rel = tree("rel")
show("release", rel, False)
# A debug tree restaged as a release one (--copy) ships copies.
show("debug as release", dbg, False)
print("alias:", os.readlink(dbg / "lib" / "libkfake.so"))

print("llvm build unchanged:", hashlib.sha256(real.read_bytes()).hexdigest() == before)
