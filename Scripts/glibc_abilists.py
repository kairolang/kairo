#!/usr/bin/env python3
"""glibc ABI lists for every release and every arch (Compiler/Spec/SysRoot.md section 4.6).

Maintainer tool, never shipped. It reads glibc's own `sysdeps/**/*.abilist` files at every
release tag from 2.17 to the newest, maps each sysdeps directory to an ABI of ours, and merges
them into one versioned dataset (build/sysroot-share/FORMAT.md, "glibc/abilists/"):

    <abi>/<stem>.abilist   `VERSION SYMBOL F|D|T [0x<size>] <releases>`  (glibc's abilist.awk
                           line plus the releases that export it: `2.17`, i.e. 2.17 to the
                           newest, `2.17-2.33`, or a comma list of those)
    <abi>/<stem>.nodes     `VERSION <first release>`: each version node and the release that
                           first defines it (a node is never removed)
    <abi>/<stem>.compat    `VERSION SYMBOL @|@@ <releases>`: where the newest-is-default rule is
                           wrong (Scripts/glibc_compat.py)
    targets.toml           per sysroot arch: abi dir, ld.so soname, floor release

The directory map (ABI_DIRS) is ours. The idea of collecting every tag's abilists and mapping
sysdeps paths to targets follows Zig's glibc-abi-tool (collect.zig / consolidate.zig); no code
or data of it is used. Pre-2.20 abilists use the nested format (a version line, then indented
entries) and live under ports/ and */nptl/: both are read, so library membership and object
sizes at 2.17 come from the 2.17 files themselves.

Library set: glibc's abilist stems for the libraries a link names (libc ld libm libpthread libdl
librt libutil libanl libresolv libmvec). From 2.34 libpthread, libdl, librt (not on every arch),
libutil and libanl are kept by glibc as placeholder libraries (one `__lib<x>_version_placeholder`
per node, or nothing at all on ports newer than 2.34): their abilists say exactly that, and the
provider stubs them as they are (an empty library where there is no abilist), so `-lpthread`
still links.

    python3 Scripts/glibc_abilists.py collect --git build/sysgen/glibc --out DIR [--cache DIR]
    python3 Scripts/glibc_abilists.py project DIR <abi> <version> <stem>   # abilist at one release

Python stdlib only.
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
import glibc_stubs  # noqa: E402

FIRST = "2.17"
STEMS = ["libc", "ld", "libm", "libpthread", "libdl", "librt", "libutil", "libanl", "libresolv",
         "libmvec"]
# Stems glibc 2.34 folded into libc: still installed (placeholders), so always stubbed.
FOLDED_2_34 = ["libpthread", "libdl", "librt", "libutil", "libanl"]
SONAMES = {"libc": "libc.so.6", "libm": "libm.so.6", "libpthread": "libpthread.so.0",
           "libdl": "libdl.so.2", "librt": "librt.so.1", "libutil": "libutil.so.1",
           "libanl": "libanl.so.1", "libresolv": "libresolv.so.2", "libmvec": "libmvec.so.1"}

# ABI dir id -> sysdeps/unix/sysv/linux subdirs, most specific first, and the file suffix used
# there (ppc64 before 2.30 kept LE and BE side by side as <stem>-le.abilist / <stem>.abilist).
# A stem is read from the first dir that has it; `nptl/` below each dir and the `ports/` tree
# (2.17-2.19) are tried too.
ABI_DIRS = {
    "x86_64":      [("x86_64/64", ""), ("x86_64", "")],
    "x32":         [("x86_64/x32", ""), ("x86_64", "")],
    "i386":        [("i386", "")],
    "aarch64":     [("aarch64", "")],
    "arm":         [("arm/le", ""), ("arm", "")],
    "riscv32":     [("riscv/rv32", "")],
    "riscv64":     [("riscv/rv64", "")],
    "powerpc":     [("powerpc/powerpc32/fpu", ""), ("powerpc/powerpc32", "")],
    "powerpc64":   [("powerpc/powerpc64/be", ""), ("powerpc/powerpc64", "")],
    "powerpc64le": [("powerpc/powerpc64/le", ""), ("powerpc/powerpc64", "-le")],
    "s390x":       [("s390/s390-64", ""), ("s390", "")],
    "mips":        [("mips/mips32/fpu", ""), ("mips/mips32", ""), ("mips", "")],
    "mips64":      [("mips/mips64/n64", ""), ("mips/mips64", ""), ("mips", "")],
    "mipsn32":     [("mips/mips64/n32", ""), ("mips/mips64", ""), ("mips", "")],
    "loongarch64": [("loongarch/lp64", "")],
    "sparc64":     [("sparc/sparc64", ""), ("sparc", "")],
}

# Sysroot arch (as the sysroot name spells it; x32 = x86_64-linux-gnux32) -> abi dir + ld.so
# soname (glibc's shlib-versions for that ABI variant). Floors: the first release with that
# abi's abilists, except where the variant itself came later.
TARGETS = {
    "x86_64":      ("x86_64", "ld-linux-x86-64.so.2", None),
    "x32":         ("x32", "ld-linux-x32.so.2", None),
    "i686":        ("i386", "ld-linux.so.2", None),
    "aarch64":     ("aarch64", "ld-linux-aarch64.so.1", None),
    "aarch64_be":  ("aarch64", "ld-linux-aarch64_be.so.1", None),
    "armv7":       ("arm", "ld-linux-armhf.so.3", None),
    "armv7-sf":    ("arm", "ld-linux.so.3", None),          # gnueabi: data only, no name for it
    "riscv32":     ("riscv32", "ld-linux-riscv32-ilp32d.so.1", None),
    "riscv64":     ("riscv64", "ld-linux-riscv64-lp64d.so.1", None),
    "powerpc":     ("powerpc", "ld.so.1", None),
    "powerpc64":   ("powerpc64", "ld64.so.1", None),
    "powerpc64le": ("powerpc64le", "ld64.so.2", None),
    "s390x":       ("s390x", "ld64.so.1", None),
    "mips":        ("mips", "ld.so.1", None),
    "mipsel":      ("mips", "ld.so.1", None),
    "mips64":      ("mips64", "ld.so.1", None),
    "mips64el":    ("mips64", "ld.so.1", None),
    "mips64-n32":  ("mipsn32", "ld.so.1", None),
    "mips64el-n32": ("mipsn32", "ld.so.1", None),
    "loongarch64": ("loongarch64", "ld-linux-loongarch-lp64d.so.1", None),
    "sparc64":     ("sparc64", "ld-linux.so.2", None),
}


def vkey(v: str):
    return tuple(int(x) for x in v.split("."))


def git(gitdir: Path, *args, binary=False):
    r = subprocess.run(["git", "-C", str(gitdir), *args], capture_output=True, check=True)
    return r.stdout if binary else r.stdout.decode()


def release_tags(gitdir: Path) -> list:
    tags = [t[6:] for t in git(gitdir, "tag").split() if re.fullmatch(r"glibc-2\.\d+", t)]
    return sorted((t for t in tags if vkey(t) >= vkey(FIRST)), key=vkey)


def parse_abilist_any(text: str) -> set:
    """Both formats -> {(version, name, kind, size)}; A lines kept (kind "A"), private dropped.
    Nested (pre-2.20): `VERSION` alone, then ` NAME KIND [SIZE]`; flat: `VERSION NAME KIND [SIZE]`."""
    out, cur = set(), None
    for line in text.splitlines():
        if not line.strip():
            continue
        p = line.split()
        if not line[0].isspace() and len(p) == 1:
            cur = p[0]
            continue
        if line[0].isspace():
            ver, rest = cur, p
        else:
            ver, rest = p[0], p[1:]
        if ver is None or ver in glibc_stubs.PRIVATE_VERSIONS or len(rest) < 2:
            continue
        name, kind = rest[0], rest[1]
        size = int(rest[2], 16) if len(rest) > 2 and kind in "DT" else 0
        if kind == "A":
            name = ver
        out.add((ver, name, kind, size))
    return out


def collect_tag(gitdir: Path, tag: str) -> dict:
    """{abi: {stem: set(entries)}} for one release."""
    files = {}
    data = git(gitdir, "archive", f"glibc-{tag}", "--", ":(glob)**/*.abilist", binary=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        for m in tf.getmembers():
            if m.isfile():
                files[m.name] = tf.extractfile(m).read().decode()
    out = {}
    for abi, dirs in ABI_DIRS.items():
        per = {}
        for stem in STEMS:
            fn = "ld" if stem == "ld" else stem
            for d, suf in dirs:
                hit = None
                for base in ("sysdeps/unix/sysv/linux", "ports/sysdeps/unix/sysv/linux"):
                    for sub in ("", "/nptl"):
                        p = f"{base}/{d}{sub}/{fn}{suf}.abilist"
                        if p in files:
                            hit = p
                            break
                    if hit:
                        break
                if hit:
                    per[stem] = parse_abilist_any(files[hit])
                    break
        if "libc" in per:
            out[abi] = per
    return out


def ranges(tags_present: list, all_tags: list) -> str:
    """Contiguous runs over all_tags: `2.17` (to the newest), `2.17-2.33`, comma separated."""
    idx = sorted(all_tags.index(t) for t in tags_present)
    runs, start, prev = [], idx[0], idx[0]
    for i in idx[1:]:
        if i != prev + 1:
            runs.append((start, prev))
            start = i
        prev = i
    runs.append((start, prev))
    last = len(all_tags) - 1
    return ",".join(all_tags[a] if b == last else f"{all_tags[a]}-{all_tags[b]}" for a, b in runs)


def in_ranges(spec: str, v: str) -> bool:
    for r in spec.split(","):
        a, _, b = r.partition("-")
        if vkey(a) <= vkey(v) and (not b or vkey(v) <= vkey(b)):
            return True
    return False


def collect(gitdir: Path, cache: Path) -> tuple:
    tags = release_tags(gitdir)
    cache.mkdir(parents=True, exist_ok=True)
    per_tag = {}
    for t in tags:
        cf = cache / f"abilists-{t}.json"
        if cf.is_file():
            raw = json.loads(cf.read_text())
        else:
            raw = {a: {s: sorted(e) for s, e in per.items()} for a, per in collect_tag(gitdir, t).items()}
            cf.write_text(json.dumps(raw))
        per_tag[t] = {a: {s: {tuple(x) for x in e} for s, e in per.items()} for a, per in raw.items()}
    return tags, per_tag


def merge(tags: list, per_tag: dict) -> dict:
    """{abi: {stem: {"entries": {entry: [tags]}, "nodes": {ver: first}}, "floor": tag}}."""
    out = {}
    for t in tags:
        for abi, per in per_tag[t].items():
            a = out.setdefault(abi, {"floor": t, "libs": {}})
            for stem, ents in per.items():
                lib = a["libs"].setdefault(stem, {"entries": {}, "nodes": {}})
                for e in ents:
                    lib["nodes"].setdefault(e[0], t)
                    if e[2] != "A":
                        lib["entries"].setdefault(e, []).append(t)
    return out


def entry_line(e) -> str:
    v, n, k, s = e
    return f"{v} {n} {k}" + (f" {s:#x}" if k in "DT" else "")


def write(out: Path, tags: list, merged: dict, compat: dict) -> None:
    for abi, a in sorted(merged.items()):
        d = out / abi
        d.mkdir(parents=True, exist_ok=True)
        for stem, lib in sorted(a["libs"].items()):
            rows = sorted((entry_line(e) + " " + ranges(ts, tags) for e, ts in lib["entries"].items()),
                          key=str.encode)
            (d / f"{stem}.abilist").write_text("".join(r + "\n" for r in rows))
            nodes = sorted(lib["nodes"].items(), key=lambda kv: glibc_stubs._ver_key(kv[0]))
            (d / f"{stem}.nodes").write_text("".join(f"{v} {t}\n" for v, t in nodes))
            rows = sorted(compat.get(abi, {}).get(stem, []), key=str.encode)
            (d / f"{stem}.compat").write_text("".join(r + "\n" for r in rows))
    lines = ["# generated by Scripts/glibc_abilists.py; do not edit. Format: FORMAT.md (glibc/abilists).",
             f'releases = [{", ".join(chr(34) + t + chr(34) for t in tags)}]', "",
             "[sonames]"] + [f'{k:<10} = "{v}"' for k, v in SONAMES.items()]
    for arch, (abi, ld, floor) in TARGETS.items():
        if abi not in merged:
            continue
        lines += ["", f'["{arch}"]' if not re.fullmatch(r"[A-Za-z0-9_]+", arch) else f"[{arch}]",
                  f'abi   = "{abi}"', f'ld    = "{ld}"', f'floor = "{floor or merged[abi]["floor"]}"']
    (out / "targets.toml").write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------- projection (the reader)

def project(d: Path, version: str, stem: str) -> tuple:
    """(entries as glibc_stubs.Entry with @/@@ decided, nodes in order) at one release: what
    the provider (Providers/Glibc.k) computes, here for the parity proof."""
    raw = []
    for line in (d / f"{stem}.abilist").read_text().splitlines():
        p = line.split()
        if in_ranges(p[-1], version):
            raw.append((p[0], p[1], p[2], int(p[3], 16) if len(p) > 4 else 0))
    nodes = []
    for line in (d / f"{stem}.nodes").read_text().splitlines():
        v, first = line.split()
        if vkey(first) <= vkey(version):
            nodes.append(v)
    over = {}
    cf = d / f"{stem}.compat"
    if cf.is_file():
        for line in cf.read_text().splitlines():
            p = line.split()
            if in_ranges(p[3], version):
                over[(p[0], p[1])] = p[2] == "@@"
    rule = glibc_stubs.default_rule([glibc_stubs.Entry(v, n, k, s, True) for v, n, k, s in raw])
    ents = [glibc_stubs.Entry(v, n, k, s, over.get((v, n), rule[n] == v)) for v, n, k, s in raw]
    ents += [glibc_stubs.Entry(v, v, "A", 0, True) for v in nodes]
    return sorted(ents), nodes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--git", type=Path, required=True)
    c.add_argument("--out", type=Path, required=True)
    c.add_argument("--cache", type=Path, required=True)
    p = sub.add_parser("project")
    p.add_argument("dir", type=Path)
    p.add_argument("abi")
    p.add_argument("version")
    p.add_argument("stem")
    a = ap.parse_args()
    if a.cmd == "collect":
        import glibc_compat
        tags, per_tag = collect(a.git, a.cache)
        merged = merge(tags, per_tag)
        compat = glibc_compat.compat_rows(a.git, a.cache, tags, merged)
        write(a.out, tags, merged, compat)
        return 0
    ents, _ = project(a.dir / a.abi, a.version, a.stem)
    for e in ents:
        if e.kind != "A":
            print(entry_line((e.version, e.name, e.kind, e.size)) + ("" if e.default else " @"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
