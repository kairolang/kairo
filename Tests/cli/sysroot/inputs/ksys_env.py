#!/usr/bin/env python3
"""Scratch environment for the ksys build tests: ksys_env.py KSYS SHARE OUT

OUT/tc/   a toolchain prefix with no sysroot/: the binaries beside KSYS hard-linked (a
          symlinked executable resolves back to its own prefix), every other dir
          symlinked. The driver takes a bundled <prefix>/sysroot/<name> over --sysroot,
          so validation run from KSYS's own prefix would test the bundled root instead.
OUT/share/ SHARE's entries symlinked, plus a real runtimes/ source staged by
          Scripts/package_release.py stage_runtimes() exactly as a release ships it (the
          builtins and runtimes stages compile it), its REVISION the one this ksys wants,
          and registry.toml carrying that tree's hash.
"""
import hashlib, os, shutil, subprocess, sys
from pathlib import Path


def tree_sha256(root):
    rels = []
    for d, _, files in os.walk(root, followlinks=True):
        for f in files:
            p = os.path.join(d, f)
            if os.path.isfile(p):
                rels.append(os.path.relpath(p, root).replace(os.sep, "/"))
    h = hashlib.sha256()
    for r in sorted(rels, key=lambda r: r.encode()):
        h.update(r.encode() + b"\n")
        with open(os.path.join(root, r), "rb") as f:
            h.update(hashlib.sha256(f.read()).hexdigest().encode() + b"\n")
    return h.hexdigest()


def main():
    ksys, share, out = (os.path.abspath(a) for a in sys.argv[1:4])
    bindir = os.path.dirname(ksys)
    prefix = os.path.dirname(bindir)
    tc = os.path.join(out, "tc")
    os.makedirs(os.path.join(tc, "bin"))
    for n in os.listdir(bindir):
        p, q = os.path.join(bindir, n), os.path.join(tc, "bin", n)
        if os.path.islink(p):
            os.symlink(os.readlink(p), q)
        elif os.path.isfile(p):
            try:
                os.link(p, q)
            except OSError:
                shutil.copy2(p, q)
    for d in os.listdir(prefix):
        if d not in ("bin", "sysroot"):
            os.symlink(os.path.join(prefix, d), os.path.join(tc, d))

    sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "Scripts"))
    import package_release
    stage = Path(out) / "rt"
    package_release.stage_runtimes(stage)
    rt = stage / "share" / "kairo" / "runtimes"
    rev = subprocess.run([ksys, "--print-runtimes-revision"], check=True, capture_output=True,
                         text=True).stdout.strip()
    (rt / "REVISION").write_text(rev + "\n")

    view = os.path.join(out, "share")
    os.makedirs(view)
    for n in os.listdir(share):
        if n not in ("registry.toml", "runtimes"):
            os.symlink(os.path.join(share, n), os.path.join(view, n))
    os.symlink(str(rt), os.path.join(view, "runtimes"))
    sha = tree_sha256(str(rt))
    lines = []
    with open(os.path.join(share, "registry.toml")) as f:
        for line in f:
            if line.startswith('"runtimes"') and len(line.split('"')) >= 4 and len(line.split('"')[3]) == 64:
                line = f'"runtimes" = "{sha}"\n'
            lines.append(line)
    with open(os.path.join(view, "registry.toml"), "w") as f:
        f.writelines(lines)


if __name__ == "__main__":
    main()
