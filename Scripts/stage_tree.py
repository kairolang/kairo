#!/usr/bin/env python3
# Stages a build tree, build/<triple>/<mode>, into a self-contained toolchain
# the compiler can run from with no root flags:
#
#   <tree>/bin/   clang-<ver>, lld, llvm-nm, llvm-objdump (copies) and the names
#                 LLVM ships as symlinks to them (clang, clang++, clang-cpp,
#                 clang-cl -> clang-<ver>; ld.lld, ld64.lld, lld-link, wasm-ld ->
#                 lld)
#   <tree>/lib/   clang/<ver>   the clang resource dir (builtin headers)
#                 builtin       Lib/builtin, the builtin module tree
#                 std           Lib/std, the standard library tree
#                 rt            Lib/rt, the runtime sources
#
# The compiler derives --resource-dir, --builtins-dir and --std-dir from
# <exe>/../lib when they are not given (CompilerInstance::_discover_roots),
# and the runtime root is the builtin root's parent, so lib/rt has to sit
# beside lib/builtin or every link misses crash.c and fmt.c. clang finds the
# same resource dir on its own: <clang>/../lib/clang/<ver>.
#
# release: everything is a COPY, so the tree is relocatable (Scripts/bundle.sh
#          then gates on that).
# debug:   builtin, std and rt are RELATIVE SYMLINKS into Lib/, so a debug
#          kairo run with no flags sees the edit loop's current Lib/, exactly
#          as lit does with its explicit roots; a copy would go stale until
#          the next build. The resource dir and the tools are copies in both.
#
# The tool list is what build_llvm.py builds: LLVM_BUILD_TOOLS=OFF leaves
# llvm-ar, llvm-strip, llvm-symbolizer, ... out of build/llvm/bin, and this
# script never starts an LLVM build to get them. OPTIONAL_TOOLS are staged
# when present, so adding one to build_llvm.py's TEST_TOOLS is all it takes.
#
# Idempotent: a file is copied only when missing or older than its source,
# and a mirrored directory loses entries its source no longer has.
#
# Runs as kbld's post-build hook for kairo and kcc (build.k); by hand:
#   python3 Scripts/stage_tree.py            # the KBLD_MODE tree (release)
#   python3 Scripts/stage_tree.py --all      # debug and release
#   python3 Scripts/stage_tree.py <tree>...  # explicit tree directories
from __future__ import annotations

import argparse
import os
import platform
import shutil
import sys
from pathlib import Path

HOST = platform.system()  # Linux | Darwin | Windows
EXE  = ".exe" if HOST == "Windows" else ""


def log(msg: str = "") -> None:
    print(f"[stage] {msg}" if msg else "", flush=True)


def die(msg: str, code: int = 1) -> "NoReturn":
    print(f"[stage] error: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def getenv(name: str, default: str) -> str:
    v = os.environ.get(name)
    return v if v else default


def host_arch() -> str:
    a = platform.machine().lower()
    if a in ("x86_64", "amd64"):
        return "x86_64"
    if a in ("aarch64", "arm64"):
        return "aarch64"
    die(f"unsupported host architecture '{a}'")


# Same defaults as build_llvm.py, so the hook stages the tree kbld built.
ROOT      = Path(getenv("KBLD_ROOT", str(Path(__file__).resolve().parent.parent)))
BUILD_DIR = Path(getenv("KBLD_BUILD_DIR", str(ROOT / "build")))
MODE      = getenv("KBLD_MODE", "release")
if HOST == "Linux":
    TRIPLE = getenv("KBLD_TRIPLE", f"{host_arch()}-linux-gnu")
elif HOST == "Darwin":
    TRIPLE = getenv("KBLD_TRIPLE", ("arm64" if host_arch() == "aarch64" else "x86_64") + "-apple-macosx")
else:
    TRIPLE = getenv("KBLD_TRIPLE", f"{host_arch()}-windows-msvc")

LLVM_BUILD = BUILD_DIR / "llvm"
LIB_SRC    = ROOT / "Lib"

# (real binary, names that are symlinks to it). The real binaries are
# required: without them there is no clang beside the compiler. clang's is
# clang-<major>, the major being the resource dir's version.
def required_tools(ver: str) -> list[tuple[str, list[str]]]:
    return [
        (f"clang-{ver}", ["clang", "clang++", "clang-cpp", "clang-cl"]),
        ("lld",          ["ld.lld", "ld64.lld", "lld-link", "wasm-ld"]),
    ]
OPTIONAL_TOOLS = [
    "llvm-nm", "llvm-objdump", "llvm-ar", "llvm-ranlib", "llvm-strip",
    "llvm-objcopy", "llvm-readelf", "llvm-readobj", "llvm-symbolizer",
    "llvm-dwarfdump", "llvm-addr2line", "llvm-cxxfilt", "llvm-size",
    "llvm-strings", "clang-format", "clang-scan-deps",
]
OPTIONAL_LINKS = {"llvm-ar": ["llvm-ranlib", "llvm-lib", "llvm-dlltool"],
                  "llvm-objcopy": ["llvm-strip"],
                  "llvm-readobj": ["llvm-readelf"],
                  "llvm-symbolizer": ["llvm-addr2line"]}

LIB_TREES = ["builtin", "std", "rt"]


# ---------------------------------------------------------------------------
# primitives
# ---------------------------------------------------------------------------

def stale(src: Path, dst: Path) -> bool:
    # Newer-than, not equal-to: bundle.sh patchelfs the staged ELF files,
    # which bumps their mtime past the source's; a staged copy that is newer
    # is ours and stays.
    if dst.is_symlink() or not dst.exists():
        return True
    return src.stat().st_mtime > dst.stat().st_mtime


def copy_file(src: Path, dst: Path) -> bool:
    if not stale(src, dst):
        return False
    # Unlink first: overwriting in place corrupts a process that has the file
    # mapped (a lit run holding the old clang), as in build_llvm.fresh_copy.
    if dst.exists() or dst.is_symlink():
        if dst.is_dir() and not dst.is_symlink():
            shutil.rmtree(dst)
        else:
            dst.unlink()
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    os.chmod(dst, os.stat(dst).st_mode | 0o200)
    return True


def remove(p: Path) -> None:
    if p.is_symlink() or p.is_file():
        p.unlink()
    elif p.is_dir():
        shutil.rmtree(p)


def symlink(target: str, link: Path) -> bool:
    if link.is_symlink() and os.readlink(link) == target:
        return False
    if link.exists() or link.is_symlink():
        remove(link)
    link.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(target, link)
    return True


def mirror(src: Path, dst: Path) -> int:
    """Copies the tree src to dst; drops what src no longer has. A dst that
    is a symlink (a debug tree turned release) is replaced by a real copy."""
    if dst.is_symlink() or dst.is_file():
        dst.unlink()
    dst.mkdir(parents=True, exist_ok=True)
    n = 0
    want = set()
    for entry in sorted(src.iterdir()):
        want.add(entry.name)
        out = dst / entry.name
        if entry.is_dir() and not entry.is_symlink():
            if out.is_symlink() or out.is_file():
                out.unlink()
            n += mirror(entry, out)
        elif copy_file(entry, out):
            n += 1
    for extra in dst.iterdir():
        if extra.name not in want:
            remove(extra)
            n += 1
    return n


def resource_dir() -> Path:
    # The highest-numbered clang/<ver> holding the builtin headers -- the rule
    # lit.cfg.py's _find_resource_dir and the driver's discovery both use.
    base = LLVM_BUILD / "lib" / "clang"
    cands = [d for d in base.glob("*") if (d / "include" / "stddef.h").is_file()]
    if not cands:
        die(f"no clang resource dir under {base} (is build/llvm built?)")
    return max(cands, key=lambda d: (len(d.name), d.name))


# ---------------------------------------------------------------------------
# staging
# ---------------------------------------------------------------------------

def stage_tools(bin_dir: Path, ver: str) -> list[str]:
    src = LLVM_BUILD / "bin"
    staged: list[str] = []
    plan = required_tools(ver)
    for real, links in plan:
        if not (src / (real + EXE)).is_file():
            die(f"{src / (real + EXE)} is missing (is build/llvm built?)")
    for t in OPTIONAL_TOOLS:
        p = src / (t + EXE)
        # An optional tool LLVM ships as a symlink (llvm-ranlib -> llvm-ar)
        # is staged as one through its real binary's entry, not copied.
        if p.is_file() and not p.is_symlink():
            plan.append((t, [l for l in OPTIONAL_LINKS.get(t, []) if (src / (l + EXE)).exists()]))
    for real, links in plan:
        copy_file(src / (real + EXE), bin_dir / (real + EXE))
        staged.append(real)
        for l in links:
            if HOST == "Windows":
                copy_file(src / (real + EXE), bin_dir / (l + EXE))  # no symlinks without privilege
            else:
                symlink(real + EXE, bin_dir / (l + EXE))
            staged.append(f"{l} -> {real}")
    return staged


def stage_tree(tree: Path, link_lib: bool) -> None:
    if not (tree / "bin").is_dir():
        log(f"skip {tree}: no bin/ (not built)")
        return
    lib = tree / "lib"
    lib.mkdir(parents=True, exist_ok=True)

    rd = resource_dir()
    # Only the one version: a stale clang/<old> would be a second candidate
    # for the driver's highest-version pick.
    clang_lib = lib / "clang"
    if clang_lib.is_dir() and not clang_lib.is_symlink():
        for old in clang_lib.iterdir():
            if old.name != rd.name:
                remove(old)
    n = mirror(rd, clang_lib / rd.name)
    log(f"{tree.name}: lib/clang/{rd.name} ({n} updated)")

    for name in LIB_TREES:
        src = LIB_SRC / name
        if not src.is_dir():
            die(f"{src} is missing")
        dst = lib / name
        if link_lib:
            rel = os.path.relpath(src, lib)
            if not dst.is_symlink() and dst.exists():
                remove(dst)  # a release-style copy left from before
            symlink(rel, dst)
            log(f"{tree.name}: lib/{name} -> {rel}")
        else:
            n = mirror(src, dst)
            log(f"{tree.name}: lib/{name} ({n} updated)")

    tools = stage_tools(tree / "bin", rd.name)
    log(f"{tree.name}: bin/ {', '.join(tools)}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Stage clang, its resource dir and Lib/ into a build tree.")
    ap.add_argument("trees", nargs="*", help="tree directories (default: build/<triple>/$KBLD_MODE)")
    ap.add_argument("--all", action="store_true", help="stage both the debug and the release tree")
    ap.add_argument("--copy", action="store_true", help="copy Lib/ trees even into a debug tree")
    a = ap.parse_args()

    if a.trees:
        trees = [Path(t).resolve() for t in a.trees]
    elif a.all:
        trees = [BUILD_DIR / TRIPLE / m for m in ("debug", "release")]
    else:
        trees = [BUILD_DIR / TRIPLE / MODE]

    for t in trees:
        # Symlinks only where the tree is the edit loop's; a release tree is
        # the one that ships.
        link_lib = (t.name == "debug") and not a.copy and HOST != "Windows"
        stage_tree(t, link_lib)


if __name__ == "__main__":
    main()
