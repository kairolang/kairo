#!/usr/bin/env python3
"""Scratch environment for the ksys runtimes tests: ksys_env_rt.py KSYS SHARE OUT

As ksys_env.py (OUT/tc/ a toolchain prefix with no sysroot/, OUT/share/ SHARE's entries
symlinked), except that OUT/share/runtimes/ is a real runtimes source, staged by
Scripts/package_release.py stage_runtimes() exactly as a release ships it: the builtins
and runtimes stages compile it with the runtimes-recipe/ tables. Its REVISION is the one
this ksys wants and registry.toml carries the staged tree's hash, so the test is about
ksys, not about whether build/sysroot-share was regenerated after the last checkout.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "Scripts"))
import ksys_env  # noqa: E402


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
    sha = ksys_env.tree_sha256(str(rt))
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
