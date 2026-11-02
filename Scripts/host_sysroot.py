#!/usr/bin/env python3
# The host sysroot a Linux release toolchain is built against.
#
# A toolchain linked against the build host's glibc needs that glibc at run
# time: built on glibc 2.44, `kairo` and libLLVM.so refuse to load on Ubuntu
# 22.04 (2.35) and 24.04 (2.39). Building against an old-glibc sysroot from
# kairo-sysroots (x86_64-linux-gnu-glibc2.31, the same tree a cross link to
# that triple uses) pins the floor to that sysroot's glibc instead.
#
# Opt-in through one variable, read by three consumers so they cannot drift:
#   KAIRO_HOST_SYSROOT=<dir with SYSROOT.toml>
#     build_llvm.py  configures LLVM against it (a different configure hash,
#                    so it is a full LLVM rebuild, and only when set);
#     build.k        compiles and links the kbld targets against it;
#     stage_tree.py  gates the staged tree on its glibc_version.
# Unset, all three behave exactly as before: the host glibc, no gate.
#
#   python3 Scripts/host_sysroot.py --check    # what the sysroot lacks; exit 1 if anything
#   python3 Scripts/host_sysroot.py --cflags   # shell-quoted compile flags
#   python3 Scripts/host_sysroot.py --ldflags  # shell-quoted link flags
#   python3 Scripts/host_sysroot.py --glibc    # its glibc_version
from __future__ import annotations

import argparse
import os
import shlex
import sys
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python < 3.11: SYSROOT.toml is flat key = value, read it by hand
    tomllib = None

ENV = "KAIRO_HOST_SYSROOT"


def sysroot() -> Path | None:
    v = os.environ.get(ENV)
    return Path(v).resolve() if v else None


def _parse_flat_toml(text: str) -> dict:
    # Enough for SYSROOT.toml (strings, bools, string arrays); not general TOML.
    out = {}
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        k, v = (s.strip() for s in line.split("=", 1))
        if v.startswith("["):
            out[k] = [s.strip().strip('"') for s in v.strip("[]").split(",") if s.strip()]
        elif v in ("true", "false"):
            out[k] = v == "true"
        else:
            out[k] = v.strip('"')
    return out


def config(root: Path) -> dict:
    f = root / "SYSROOT.toml"
    if not f.is_file():
        return {}
    text = f.read_text()
    return tomllib.loads(text) if tomllib else _parse_flat_toml(text)


def glibc_version(root: Path) -> str | None:
    return config(root).get("glibc_version")


def cflags(root: Path, cxx: bool = True) -> list[str]:
    # -nostdlibinc / -nostdinc++ (the sysroot's cc_isolation): without them
    # clang still searches the host's /usr/include, and a host header that
    # redirects strtol to __isoc23_strtol (glibc 2.38) undoes the whole point.
    # cxx=False is the C compiler's set: no libc++ flags or headers.
    c = config(root)
    iso = c.get("cc_isolation", ["-nostdlibinc", "-nostdinc++"])
    flags = (["-stdlib=libc++"] if cxx else []) + [f"--sysroot={root}"]
    flags += [f for f in iso if cxx or f != "-nostdinc++"]
    for d in c.get("include_dirs", ["include/c++/v1", "include"]):
        if cxx or "c++" not in d:
            flags += ["-isystem", str(root / d)]
    return flags


def ldflags(root: Path) -> list[str]:
    # -B: crt1.o / crti.o live in lib/, not where clang's GCC-installation
    # probe looks. compiler-rt + libunwind: the sysroot has no libgcc.
    c = config(root)
    flags = [f"--sysroot={root}", "-fuse-ld=lld", "--rtlib=compiler-rt", "--unwindlib=libunwind"]
    for d in c.get("lib_dirs", ["lib"]):
        flags += [f"-L{root / d}", f"-B{root / d}"]
    rd = c.get("resource_dir")
    if rd:
        flags.append(f"-L{root / rd / 'lib'}")
    # clang adds -lc++ for -stdlib=libc++ and nothing else; a static libc++
    # leaves operator new and the unwinder unresolved without these.
    flags += [f for f in c.get("libcxx_link", []) if f != "-lc++"]
    return flags


def _has_lib(root: Path, c: dict, name: str, shared_only: bool = False) -> bool:
    for d in c.get("lib_dirs", ["lib"]):
        for f in (root / d).glob(f"lib{name}.so*"):
            return True
        if not shared_only and (root / d / f"lib{name}.a").is_file():
            return True
    return False


def _has_header(root: Path, c: dict, name: str) -> bool:
    return any((root / d / name).is_file() for d in c.get("include_dirs", ["include"]))


def missing(root: Path) -> list[str]:
    """What the toolchain build needs that this sysroot does not ship."""
    c = config(root)
    if not c:
        return [f"{root}/SYSROOT.toml (not a kairo-sysroots tree)"]
    out = []
    if not c.get("glibc_version"):
        out.append("glibc_version in SYSROOT.toml (not a glibc sysroot; a musl one needs the static path)")
    if not c.get("has_libcxx"):
        out.append("libc++ (has_libcxx = false)")
    # build_llvm.py configures LLVM_ENABLE_ZLIB / ZSTD = FORCE_ON and build.k
    # links -lz -lzstd; the curated target sysroots ship neither.
    for hdr, lib in (("zlib.h", "z"), ("zstd.h", "zstd")):
        if not _has_header(root, c, hdr):
            out.append(f"{hdr} (lib{lib} headers)")
        if not _has_lib(root, c, lib):
            out.append(f"lib{lib}.so or lib{lib}.a")
    # The tree ships ONE libc++.so.1 that kairo, libLLVM and libclang-cpp all
    # load (build.k's thin-bins invariant). A static-only libc++ would put a
    # private copy in each, and objects crossing the libLLVM boundary would
    # straddle two runtimes. The sysroot's libc++.a is PIC, so a libc++.so.1
    # can be linked from it (--whole-archive -lc++ -lc++abi).
    if not _has_lib(root, c, "c++", shared_only=True):
        out.append("libc++.so.1 (only libc++.a; link a shared one from the PIC archive)")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Flags and checks for the host sysroot in $" + ENV)
    ap.add_argument("--sysroot", help=f"sysroot directory (default: ${ENV})")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--cflags", action="store_true")
    g.add_argument("--ldflags", action="store_true")
    g.add_argument("--glibc", action="store_true")
    a = ap.parse_args()

    root = Path(a.sysroot).resolve() if a.sysroot else sysroot()
    if root is None:
        print(f"error: no sysroot: set {ENV} or pass --sysroot", file=sys.stderr)
        sys.exit(2)
    if a.check:
        gaps = missing(root)
        for m in gaps:
            print(f"missing: {m}", file=sys.stderr)
        print(f"host sysroot {root}: {'OK' if not gaps else f'{len(gaps)} missing'}", file=sys.stderr)
        sys.exit(1 if gaps else 0)
    if a.glibc:
        print(glibc_version(root) or "", end="")
        return
    # No trailing newline: build.k passes the output to one passthrough().
    print(shlex.join(cflags(root) if a.cflags else ldflags(root)), end="")


if __name__ == "__main__":
    main()
