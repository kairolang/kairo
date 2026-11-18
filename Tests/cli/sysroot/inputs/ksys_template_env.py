#!/usr/bin/env python3
"""The runtimes-template tests' helpers (template.k).

    ksys_template_env.py view SHARE TMPL OUT   OUT: SHARE's entries symlinked, registry.toml
        listing runtimes-template (TMPL, hashed) and NOT runtimes-recipe, so every builtins /
        runtimes compile comes from the template; licenses/runtimes-template beside the rest.
    ksys_template_env.py cmp GOT REF NAME...   each NAME's tables in GOT (`ksys tables` output)
        against REF (a runtimes-recipe/ dir): the compile set (member -> source + full flag
        list), every archive's root path and member order, every object; IDENTICAL or DIFF.
"""
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "Scripts"))
import ksys_env  # noqa: E402
import runtimes_template as rtt  # noqa: E402


def view(share: Path, tmpl: Path, out: Path):
    out.mkdir(parents=True)
    for n in os.listdir(share):
        if n not in ("registry.toml", "runtimes-recipe", "runtimes-template", "licenses"):
            os.symlink(share / n, out / n)
    (out / "licenses").mkdir()
    for n in os.listdir(share / "licenses"):
        os.symlink(share / "licenses" / n, out / "licenses" / n)
    if not (out / "licenses" / "runtimes-template").exists():
        os.symlink(share / "licenses" / "runtimes-recipe", out / "licenses" / "runtimes-template")
    os.symlink(tmpl, out / "runtimes-template")
    sha = ksys_env.tree_sha256(str(tmpl))
    lines = []
    for line in (share / "registry.toml").read_text().splitlines(True):
        if line.startswith('"runtimes-recipe"') or line.startswith('"runtimes-template"'):
            continue
        if line.startswith("[licenses]"):
            lines.append(f'"runtimes-template" = "{sha}"\n\n')
        lines.append(line)
    lines.append('"runtimes-template" = "Apache-2.0 WITH LLVM-exception"\n')
    (out / "registry.toml").write_text("".join(lines).replace('"\n\n\n[licenses]', '"\n\n[licenses]'))


def cmp(got: Path, ref: Path, names: list) -> int:
    bad = 0
    for n in names:
        a, b = rtt.Target(got, n), rtt.Target(ref, n)
        d = rtt.compare(rtt.from_tables(a), rtt.from_tables(b))
        for k in ("archives", "objects"):
            if sorted(a.t.get(k, {})) != sorted(b.t.get(k, {})):
                d.append(f"{k} paths differ")
        print(f"{n}: {'IDENTICAL' if not d else 'DIFF'}")
        for x in d[:4]:
            print("    " + x[:300])
        bad += bool(d)
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1] == "view":
        view(*(Path(os.path.abspath(a)) for a in sys.argv[2:5]))
    elif sys.argv[1] == "cmp":
        sys.exit(cmp(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:]))
    else:
        sys.exit(f"unknown mode {sys.argv[1]}")
