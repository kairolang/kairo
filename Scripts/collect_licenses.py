#!/usr/bin/env python3
"""License collector for release archives (called by package_release.py).

    python3 Scripts/collect_licenses.py <staged-tree> [--triple T]   # check + write in place

Writes <tree>/LICENSES/<component>/ (the real license texts, copied from the source
trees) and <tree>/THIRD-PARTY-NOTICES (an index: component, version or revision, SPDX
id, where it ships, files), and copies the repo's LICENSE and NOTICE to <tree>.

The rule (SysRoot.md section 15): what ships must have a license entry. It is enforced
two ways, and either one fails the run:
  1. COVERAGE: every top-level thing in the staged tree (bin/<tool>, lib/<dir>, scripts/<file>, share/<dir>,
     sysroot/<root>, and each sysroot root's family) must be CLAIMED by a component
     in the table below. A new tool, lib dir or sysroot family nobody wrote an entry
     for is an error, not a silent omission.
  2. TEXTS: every component that ships must have found every license file it lists.
     A moved submodule or a missing sysroots checkout is an error naming the path.

Sources are searched in this order: the repo (submodules under Lib/), the sysroots
project ($KAIRO_SYSROOTS_DIR, else a kairo-sysroots checkout beside this one), then
Scripts/license-texts/ (canonical texts for licenses no source tree here carries:
GPL-2.0, LGPL-2.1, the Linux syscall note, BSL-1.0, FreeBSD's COPYRIGHT).
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXTS = ROOT / "Scripts" / "license-texts"
SYSROOTS_PROJECT = Path(os.environ.get("KAIRO_SYSROOTS_DIR",
                                       Path.home() / "linux-dev" / "projects" / "kairo-sysroots"))
LLVM = ROOT / "Lib" / "llvm-runtimes"
# One Debian-packaged glibc sysroot extract carries the Debian copyright files the glibc
# and Linux UAPI headers in our sysroots came from.
DEB = SYSROOTS_PROJECT / "extract" / "x86_64-linux-gnu-glibc2.31" / "usr" / "share" / "doc"

KAIRO_LICENSE = "Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception"
LLVM_LICENSE = "Apache-2.0 WITH LLVM-exception"


def git_rev(path: Path) -> str:
    """Short revision (and tag, if any) of a checkout; '' when it is not a git tree."""
    try:
        r = subprocess.run(["git", "-C", str(path), "describe", "--tags", "--always", "--long"],
                           capture_output=True, text=True, timeout=30)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


@dataclass
class Component:
    id: str                       # LICENSES/<id>/
    name: str
    spdx: str
    version: str                  # fixed string, or "" to use git_rev(rev_of)
    ships: str                    # where it ends up (the notices index says this)
    files: list[tuple[str, list[Path]]]   # (name in LICENSES/<id>/, candidate source paths)
    claims: list[str] = field(default_factory=list)   # top-level archive paths it covers (fnmatch)
    rev_of: Path | None = None    # checkout whose revision is the version
    families: tuple[str, ...] = ()  # sysroot families that bring this component in


def C(*parts: str) -> Path:
    return ROOT.joinpath(*parts)


def S(*parts: str) -> Path:
    return SYSROOTS_PROJECT.joinpath(*parts)


def T(name: str) -> Path:
    return TEXTS / name


TABLE: list[Component] = [
    Component("kairo", "Kairo (kairo, kcc, kld, kfmt, builtin, std, rt, scripts)", KAIRO_LICENSE, "0.2.0",
              "bin/kairo, bin/kcc, bin/kld, bin/kfmt, lib/builtin, lib/std, lib/rt, "
              "scripts/darwin-sysroot.sh, scripts/msvc-sysroot.{sh,ps1}",
              [("LICENSE", [C("LICENSE")])],
              claims=["bin/kairo*", "bin/kcc*", "bin/kld*", "bin/kfmt*",
                      "lib/builtin", "lib/std", "lib/rt", "scripts/darwin-sysroot.sh",
                      "scripts/msvc-sysroot.sh", "scripts/msvc-sysroot.ps1"]),
    Component("llvm", "LLVM, clang, lld, compiler-rt, libc++, libc++abi, libunwind (Kairo fork)",
              LLVM_LICENSE + " (legacy NCSA / MIT sections for older files)", "22.1.0",
              "linked into bin/kairo, bin/kcc, bin/kld, bin/llvm-ar, bin/llvm-symbolizer; "
              "lib/clang/22 (resource dir); libc++/libc++abi/libunwind/compiler-rt in every sysroot "
              "(sysroot/*/{lib,compiler-rt,libcxx,include/c++}); share/kairo/runtimes (compiler-rt builtins, LLVM-libc headers, "
              "libunwind, libc++abi, libc++ source for scripts/*.sh); the .patches/ are under this license",
              [("LICENSE.TXT", [LLVM / "LICENSE.TXT"]),
               ("compiler-rt-LICENSE.TXT", [LLVM / "compiler-rt" / "LICENSE.TXT"]),
               ("compiler-rt-CREDITS.TXT", [LLVM / "compiler-rt" / "CREDITS.TXT"]),
               ("libcxx-LICENSE.TXT", [LLVM / "libcxx" / "LICENSE.TXT"]),
               ("libcxx-CREDITS.TXT", [LLVM / "libcxx" / "CREDITS.TXT"]),
               ("libcxxabi-LICENSE.TXT", [LLVM / "libcxxabi" / "LICENSE.TXT"]),
               ("libunwind-LICENSE.TXT", [LLVM / "libunwind" / "LICENSE.TXT"]),
               ("clang-LICENSE.TXT", [LLVM / "clang" / "LICENSE.TXT"]),
               ("lld-LICENSE.TXT", [LLVM / "lld" / "LICENSE.TXT"]),
               ("llvm-LICENSE.TXT", [LLVM / "llvm" / "LICENSE.TXT"]),
               ("patches-README", [C(".patches", "README")])],
              # trailing * so the Windows .exe names match too, as the kairo claims do
              claims=["bin/llvm-ar*", "bin/llvm-ranlib*", "bin/llvm-lib*", "bin/llvm-dlltool*",
                      "bin/llvm-symbolizer*", "lib/clang", "share/kairo"],
              rev_of=LLVM),
    Component("zlib", "zlib (statically linked into the toolchain binaries)", "Zlib", "",
              "linked into bin/kairo, bin/kcc, bin/kld",
              [("LICENSE", [C("Lib", "third_party", "zlib", "LICENSE")])],
              rev_of=C("Lib", "third_party", "zlib")),
    Component("zstd", "zstd (statically linked into the toolchain binaries)",
              "BSD-3-Clause OR GPL-2.0-only (used under BSD-3-Clause)", "",
              "linked into bin/kairo, bin/kcc, bin/kld",
              [("LICENSE", [C("Lib", "third_party", "zstd", "LICENSE")]),
               ("COPYING", [C("Lib", "third_party", "zstd", "COPYING")])],
              rev_of=C("Lib", "third_party", "zstd")),
    Component("mimalloc", "mimalloc (the Kairo runtime's allocator)", "MIT", "",
              "lib/rt/mimalloc (compiled into every Kairo program); linked into the toolchain binaries",
              [("LICENSE", [C("Lib", "rt", "mimalloc", "LICENSE")])],
              rev_of=C("Lib", "rt", "mimalloc")),
    Component("dragonbox", "Dragonbox (float formatting in lib/rt/fmt_dragonbox*.c)",
              "BSL-1.0 OR Apache-2.0 WITH LLVM-exception", "jk-jeon/dragonbox, 2020-2025",
              "lib/rt/fmt_dragonbox32.c, fmt_dragonbox64.c (compiled into every Kairo program)",
              [("BSL-1.0.txt", [T("BSL-1.0.txt")])]),
    Component("musl", "musl libc", "MIT", "1.2.6",
              "statically linked into the musl-hosted toolchain binaries; sysroot/*-linux-musl "
              "(headers, libc.a, crt objects)",
              [("COPYRIGHT", [C("Lib", "libc", "musl", "COPYRIGHT")])],
              rev_of=C("Lib", "libc", "musl"), families=("linux-musl",)),
    Component("linux-uapi", "Linux kernel UAPI headers", "GPL-2.0-only WITH Linux-syscall-note",
              "6.12 (musl roots), Ubuntu linux-libc-dev 5.4 (glibc roots)",
              "sysroot/*/include/{linux,asm,asm-generic}",
              [("COPYING-syscall-note", [T("Linux-syscall-note.txt")]),
               ("GPL-2.0-only.txt", [T("GPL-2.0-only.txt")]),
               ("ubuntu-linux-libc-dev-copyright", [DEB / "linux-libc-dev" / "copyright"])],
              families=("linux-musl", "linux-gnu")),
    Component("glibc", "GNU C Library headers, crt objects and link stubs (Ubuntu glibc 2.31)",
              "LGPL-2.1-or-later", "2.31",
              "sysroot/*-linux-gnu-glibc2.31 (headers, crt1.o, libc stubs)",
              [("COPYING.LIB", [T("LGPL-2.1-or-later.txt")]),
               ("GPL-2.0-only.txt", [T("GPL-2.0-only.txt")]),
               ("ubuntu-libc6-copyright", [DEB / "libc6-dev" / "copyright"])],
              families=("linux-gnu",)),
    Component("mingw-w64", "mingw-w64 (headers, CRT, import libs, winpthreads)",
              "ZPL-2.1 AND LicenseRef-mingw-w64-public-domain", "13.0.0",
              "sysroot/*-windows-gnu",
              [("COPYING", [C("Lib", "libc", "mingw", "COPYING")]),
               ("DISCLAIMER", [C("Lib", "libc", "mingw", "DISCLAIMER")]),
               ("DISCLAIMER.PD", [C("Lib", "libc", "mingw", "DISCLAIMER.PD")]),
               ("AUTHORS", [C("Lib", "libc", "mingw", "AUTHORS")]),
               ("winpthreads-COPYING", [C("Lib", "libc", "mingw", "mingw-w64-libraries", "winpthreads", "COPYING")])],
              rev_of=C("Lib", "libc", "mingw"), families=("windows-gnu",)),
    Component("freebsd", "FreeBSD base (headers, crt objects, libc.a and friends), 14.4",
              "BSD-2-Clause AND BSD-3-Clause (per file, see the FreeBSD COPYRIGHT)", "14.4",
              "sysroot/*-unknown-freebsd",
              [("COPYRIGHT", [T("FreeBSD-COPYRIGHT.txt")])],
              families=("freebsd",)),
    Component("netbsd", "NetBSD base (headers, crt objects, libc.a and friends), 10.1",
              "BSD-2-Clause AND BSD-3-Clause (per file; holders are named in each header)", "10.1",
              "sysroot/x86_64-unknown-netbsd",
              [("COPYRIGHT", [T("NetBSD-COPYRIGHT.txt")])],
              families=("netbsd",)),
    Component("wasi-libc", "wasi-libc (headers, libc.a, crt1)",
              "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT (plus the musl and CloudABI parts "
              "named in its LICENSE)", "",
              "sysroot/wasm32-wasi",
              [("LICENSE", [C("Lib", "libc", "wasi", "LICENSE")]),
               ("LICENSE-APACHE", [C("Lib", "libc", "wasi", "LICENSE-APACHE")]),
               ("LICENSE-APACHE-LLVM", [C("Lib", "libc", "wasi", "LICENSE-APACHE-LLVM")]),
               ("LICENSE-MIT", [C("Lib", "libc", "wasi", "LICENSE-MIT")]),
               ("musl-COPYRIGHT", [C("Lib", "libc", "wasi", "libc-top-half", "musl", "COPYRIGHT")])],
              rev_of=C("Lib", "libc", "wasi"), families=("wasi",)),
]

# Sysroot families a release may ship, and the components each brings in. A family not
# in this map is a hard error (darwin, msvc and anything new must be decided on).
FAMILY_COMPONENTS = {
    "linux-musl": ["musl", "linux-uapi", "llvm"],
    "linux-gnu": ["glibc", "linux-uapi", "llvm"],
    "windows-gnu": ["mingw-w64", "llvm"],
    "freebsd": ["freebsd", "llvm"],
    "netbsd": ["netbsd", "llvm"],
    "wasi": ["wasi-libc", "llvm"],
}
# The sysroot roots' own metadata: not a component, no license needed.
SYSROOT_META = {"manifest.json"}


def log(m: str) -> None:
    print(f"[licenses] {m}", flush=True)


def read_family(root: Path) -> str:
    import tomllib
    with open(root / "SYSROOT.toml", "rb") as f:
        return tomllib.load(f).get("family", "")


def installed(tree: Path, triple: str) -> tuple[set[str], list[str]]:
    """Component ids the staged tree brings in, and coverage errors (unclaimed things)."""
    import fnmatch
    errors: list[str] = []
    need: set[str] = {"kairo", "llvm"}
    # Everything linked into the toolchain binaries (see Scripts/cross_llvm.py: zlib, zstd,
    # mimalloc through the Kairo runtime) rides with the binaries.
    if (tree / "bin").is_dir():
        need |= {"zlib", "zstd", "mimalloc"}
    # lib/rt is compiled into every program.
    if (tree / "lib" / "rt").is_dir():
        need |= {"mimalloc", "dragonbox"}
    # musl is linked into the toolchain binaries when the tree's own triple is musl.
    if triple.endswith("linux-musl"):
        need.add("musl")
    claims = {pat: c.id for c in TABLE for pat in c.claims}

    def claimed(rel: str) -> bool:
        return any(fnmatch.fnmatch(rel, p) for p in claims)

    for top in ("bin", "lib", "scripts", "share"):
        d = tree / top
        if not d.is_dir():
            continue
        for e in sorted(d.iterdir()):
            rel = f"{top}/{e.name}"
            if e.name.endswith((".log", ".tmp")):
                continue
            if not claimed(rel):
                errors.append(f"{rel}: ships with no license entry (add it to a component's claims in "
                              f"Scripts/collect_licenses.py, or stop shipping it)")
    sr = tree / "sysroot"
    if sr.is_dir():
        for e in sorted(sr.iterdir()):
            if e.name in SYSROOT_META:
                continue
            if not (e / "SYSROOT.toml").is_file():
                errors.append(f"sysroot/{e.name}: no SYSROOT.toml, cannot tell its family")
                continue
            fam = read_family(e)
            if fam not in FAMILY_COMPONENTS:
                errors.append(f"sysroot/{e.name}: family '{fam}' has no license entry")
                continue
            need |= set(FAMILY_COMPONENTS[fam])
    if (tree / "sysroot").is_dir() or (tree / "lib" / "clang").is_dir():
        need.add("llvm")
    return need, errors


def copy_texts(c: Component, out: Path) -> list[str]:
    errors: list[str] = []
    dst = out / "LICENSES" / c.id
    dst.mkdir(parents=True, exist_ok=True)
    for name, cands in c.files:
        src = next((p for p in cands if p.is_file()), None)
        if src is None:
            errors.append(f"{c.id}: license file '{name}' not found (looked in "
                          + ", ".join(str(p) for p in cands) + ")")
            continue
        shutil.copyfile(src, dst / name)
    return errors


def version_of(c: Component) -> str:
    if c.version:
        return c.version
    if c.rev_of is not None:
        rev = git_rev(c.rev_of)
        if rev:
            return rev
    return "(revision not recorded)"


def collect(tree: Path, triple: str) -> list[str]:
    """Writes LICENSE, NOTICE, LICENSES/ and THIRD-PARTY-NOTICES into tree; returns errors."""
    shutil.rmtree(tree / "LICENSES", ignore_errors=True)
    need, errors = installed(tree, triple)
    by_id = {c.id: c for c in TABLE}
    shutil.copyfile(ROOT / "LICENSE", tree / "LICENSE")
    # Apache 4(d): a redistribution of the toolchain carries the NOTICE file.
    shutil.copyfile(ROOT / "NOTICE", tree / "NOTICE")
    rows = []
    for cid in [c.id for c in TABLE if c.id in need]:
        c = by_id[cid]
        errors += copy_texts(c, tree)
        got = sorted(p.name for p in (tree / "LICENSES" / cid).glob("*"))
        rows.append((c, version_of(c), got))
    lines = ["Kairo 0.2.0 third-party notices", "=" * 31, "",
             "Kairo itself is " + KAIRO_LICENSE + " (LICENSE). This archive also contains the",
             "components below; their license texts are in LICENSES/<component>/.", ""]
    for c, ver, got in rows:
        lines += [f"{c.name}", f"  component : {c.id}", f"  version   : {ver}", f"  SPDX      : {c.spdx}",
                  f"  ships in  : {c.ships}", f"  files     : " + ", ".join(f"LICENSES/{c.id}/{g}" for g in got), ""]
    (tree / "THIRD-PARTY-NOTICES").write_text("\n".join(lines))
    log(f"{len(rows)} components: " + ", ".join(c.id for c, _, _ in rows))
    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--triple", default="x86_64-linux-musl", help="the tree\x27s own target (decides what is linked into bin/)")
    ap.add_argument("tree", help="staged archive tree (the directory that becomes kairo-<ver>-<triple>/)")
    a = ap.parse_args()
    errs = collect(Path(a.tree).resolve(), a.triple)
    for e in errs:
        log(f"FAIL: {e}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
