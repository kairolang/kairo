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
# release: everything is a COPY, so the tree is relocatable (bundle_tree()
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
# After staging, bundle_tree() makes the tree relocatable: every non-system
# shared library the binaries load is copied into it, every search path is
# made relative to the binary, and gates fail the run if the tree still
# depends on where it was built. Per host:
#   Linux    ELF: deps from ldd (glibc and musl both ship one), RUNPATH via
#            patchelf -> $ORIGIN/../lib (bin/), $ORIGIN (lib/); reports the
#            glibc symbol-version floor.
#   macOS    Mach-O: deps from otool -L, install names -> @rpath/<name>,
#            rpaths -> @loader_path/../lib (bin/), @loader_path (lib/), then
#            an ad-hoc re-sign. build_llvm.stage_darwin() already did this for
#            the LLVM dylibs; this covers bin/ and whatever it pulls in.
#   Windows  PE: no rpath; every non-system DLL a bin/ exe imports is copied
#            beside it, where the loader looks first.
# Only Linux has been run (2026-10-28); the macOS and Windows paths are
# written against the tools' documented output and are untested.
#
# Runs as kbld's post-build hook for kairo and kcc (build.k), on every host;
# by hand:
#   python3 Scripts/stage_tree.py            # the KBLD_MODE tree (release)
#   python3 Scripts/stage_tree.py --all      # debug and release
#   python3 Scripts/stage_tree.py <tree>...  # explicit tree directories
#   --no-bundle                              # stage only
from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
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
# The staged copy is always there after stage_tools(); it reads ELF, Mach-O
# and PE alike, so the gates need no host binutils.
OBJDUMP    = LLVM_BUILD / "bin" / ("llvm-objdump" + EXE)

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
    # Newer-than, not equal-to: bundle_tree() patches the staged binaries'
    # search paths, which bumps their mtime past the source's; a staged copy
    # that is newer is ours and stays.
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


# ---------------------------------------------------------------------------
# bundling (relocatability)
# ---------------------------------------------------------------------------
#
# Rules carried over from the shell version, each for a tree it broke:
#   - a search path is rewritten only where it differs: rewriting a file in
#     place corrupts a process that has it mapped (a lit run holding
#     libLLVM), and every build would otherwise rewrite 250 MB for nothing.
#     It also means an already-bundled tree passes on a host with no
#     patchelf / install_name_tool.
#   - an ELF with no dynamic section (a static musl kairo) is skipped: it
#     has nothing to resolve and patchelf rejects it.
#   - lib/std may be a symlink into the source tree (a debug tree); the draft
#     strip skips it then, or it would delete the tracked Lib/std drafts.
#   - system libraries match by basename: ldd names the loader by path
#     (/lib64/ld-linux-x86-64.so.2), not by soname.
#   - dangling symlinks inside sysroot/ (vendored target filesystems, from
#     kairo-sysroots) are counted, not gated: the release sysroots ship 37
#     of them (musl libc.so -> ld-musl, SDK frameworks into Cryptexes).
#   - musl has no GLIBC_ symbol versions, so its floor reports "none".

# Libraries every host has. Never bundled. glibc's set, then musl's (libc.so
# is musl's libc and loader at once).
LINUX_SYSTEM = re.compile(
    r"^(linux-vdso\.so|linux-gate\.so|ld-linux.*|ld-musl.*|libc\.so|libc\.musl.*|libm\.so|"
    r"libdl\.so|libpthread\.so|librt\.so|libutil\.so|libresolv\.so|libgcc_s\.so|"
    r"libz\.so|libzstd\.so)")
# The dyld shared cache: these have no file on disk to copy anyway.
DARWIN_SYSTEM = ("/usr/lib/", "/System/")
# The OS and its API sets. vcruntime / msvcp are the /MD CRT: present on any
# host with the VC redistributable, and bundled only when found outside the
# system directory (a dev box with them on PATH).
WINDOWS_SYSTEM = re.compile(r"^(api-ms-win-.*|ext-ms-.*)$", re.I)


def run_out(cmd: list[str]) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    return r.stdout + r.stderr if r.returncode == 0 else ""


def need_tool(name: str) -> str:
    t = shutil.which(name)
    if not t:
        hint = {"patchelf": " (pacman -S patchelf / apt install patchelf / apk add patchelf)",
                "install_name_tool": " (xcode-select --install)"}.get(name, "")
        die(f"{name} not found{hint}")
    return t


def magic(f: Path) -> bytes:
    try:
        with open(f, "rb") as fh:
            return fh.read(4)
    except OSError:
        return b""


def is_binary(f: Path) -> bool:
    m = magic(f)
    if HOST == "Linux":
        return m == b"\x7fELF"
    if HOST == "Darwin":
        return m in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")
    return m[:2] == b"MZ"


def binaries(tree: Path) -> list[Path]:
    # Real files only: a symlink (clang -> clang-22, libLLVM.so ->
    # libLLVM.so.22.1) is fixed through its target.
    out = []
    for d in (tree / "bin", tree / "lib"):
        if d.is_dir():
            for f in sorted(d.iterdir()):
                if f.is_file() and not f.is_symlink() and is_binary(f):
                    out.append(f)
    return out


def want_path(tree: Path, f: Path) -> str:
    in_bin = f.parent == tree / "bin"
    if HOST == "Darwin":
        return "@loader_path/../lib" if in_bin else "@loader_path"
    return "$ORIGIN/../lib" if in_bin else "$ORIGIN"


def copy_dep(src: Path, dst: Path) -> None:
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    shutil.copy2(src.resolve(), dst)
    os.chmod(dst, 0o755)
    log(f"bundled {dst.name} <- {src}")


# --- Linux ------------------------------------------------------------------

def elf_dynamic(f: Path) -> tuple[bool, list[str]]:
    """(has a dynamic section, its RUNPATH/RPATH entries)."""
    out = subprocess.run(["readelf", "-d", str(f)] if shutil.which("readelf") else
                         [str(OBJDUMP), "-p", str(f)], capture_output=True, text=True,
                         errors="replace").stdout
    dynamic, paths = False, []
    for line in out.splitlines():
        # readelf: "0x... (RUNPATH)  Library runpath: [$ORIGIN]";
        # llvm-objdump: "  RUNPATH  $ORIGIN".
        m = re.search(r"\((NEEDED|RUNPATH|RPATH)\)", line) or \
            re.match(r"\s+(NEEDED|RUNPATH|RPATH)\s", line)
        if not m:
            continue
        dynamic = True
        if m.group(1) != "NEEDED":
            v = re.search(r"\[(.*)\]", line)
            paths.append(v.group(1) if v else line.split(None, 1)[1].strip())
    return dynamic, paths


def ldd(f: Path) -> tuple[list[tuple[str, str]], list[str]]:
    """(resolved (name, path) pairs, unresolved names), as the host's real
    loader sees f with no LD_LIBRARY_PATH."""
    env = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}
    out = subprocess.run([need_tool("ldd"), str(f)], capture_output=True, text=True,
                         errors="replace", env=env).stdout
    found, missing = [], []
    for line in out.splitlines():
        m = re.match(r"\s*(\S+)\s+=>\s+(\S+)", line)
        if not m:
            continue
        name, path = Path(m.group(1)).name, m.group(2)
        if path == "not":
            missing.append(name)
        elif path.startswith("/"):
            found.append((name, path))
    return found, missing


def bundle_linux(tree: Path, lib: Path) -> list[str]:
    # 1. Copy non-system deps until nothing new resolves outside lib/.
    added = True
    while added:
        added = False
        for f in binaries(tree):
            for name, path in ldd(f)[0]:
                if LINUX_SYSTEM.match(name) or Path(path).parent.resolve() == lib.resolve():
                    continue
                if (lib / name).exists():
                    continue
                copy_dep(Path(path), lib / name)
                added = True

    # 2. Normalize search paths: one relative entry, no absolute or empty ones.
    for f in binaries(tree):
        dynamic, paths = elf_dynamic(f)
        if not dynamic:
            continue
        want = want_path(tree, f)
        if paths == [want]:
            continue
        subprocess.run([need_tool("patchelf"), "--set-rpath", want, str(f)], check=True)
        log(f"runpath {want}: {f.relative_to(tree)}")

    # 3. Gates.
    fails, versions = [], set()
    for f in binaries(tree):
        dynamic, paths = elf_dynamic(f)
        if not dynamic:
            continue
        missing = ldd(f)[1]
        if missing:
            fails.append(f"unresolved deps in {f.relative_to(tree)}: {', '.join(missing)}")
        for p in ":".join(paths).split(":"):
            if not p.startswith("$ORIGIN"):
                fails.append(f"bad RUNPATH '{':'.join(paths)}' in {f.relative_to(tree)}")
                break
        versions |= set(re.findall(r"GLIBC_([0-9.]+)", run_out([str(OBJDUMP), "-T", str(f)])))
    # Numeric, not lexical: 2.6 sorts above 2.44 as text.
    floor = max(versions, key=lambda v: tuple(int(x) for x in v.split(".") if x), default=None)
    log(f"glibc floor: {'GLIBC_' + floor if floor else 'none (no GLIBC_ symbol versions: musl or static)'}")
    return fails


# --- macOS ------------------------------------------------------------------
# Same otool parsing as build_llvm.py's stage_darwin(); keep the two in step.

def otool_id(f: Path) -> str | None:
    lines = run_out(["otool", "-D", str(f)]).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def otool_deps(f: Path) -> list[str]:
    own = otool_id(f)
    deps = []
    for line in run_out(["otool", "-L", str(f)]).splitlines()[1:]:
        dep = line.strip().split(" (compatibility")[0].strip()
        if dep and dep != own:
            deps.append(dep)
    return deps


def otool_rpaths(f: Path) -> list[str]:
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset",
                      run_out(["otool", "-l", str(f)]))


def resolve_macho(dep: str, f: Path) -> Path | None:
    if dep.startswith("@rpath/"):
        tail = dep[len("@rpath/"):]
        for r in otool_rpaths(f):
            r = r.replace("@loader_path", str(f.parent)).replace("@executable_path", str(f.parent))
            if (Path(r) / tail).is_file():
                return Path(r) / tail
        return None
    if dep.startswith("@loader_path/"):
        c = f.parent / dep[len("@loader_path/"):]
        return c if c.is_file() else None
    p = Path(dep)
    return p if not dep.startswith("@") and p.is_file() else None


def bundle_darwin(tree: Path, lib: Path) -> list[str]:
    fails = []
    # 1. Copy non-system deps (brew libc++, zstd, ...) until closed. Resolved
    #    before any rewrite: an @rpath dep is found through the absolute
    #    rpaths step 2 deletes.
    added = True
    while added:
        added = False
        for f in binaries(tree):
            for dep in otool_deps(f):
                if dep.startswith(DARWIN_SYSTEM) or (lib / Path(dep).name).exists():
                    continue
                src = resolve_macho(dep, f)
                if src is None:
                    fails.append(f"{f.relative_to(tree)} depends on '{dep}', which could not be resolved")
                    continue
                copy_dep(src, lib / Path(dep).name)
                added = True

    # 2. Install names -> @rpath/<name>, one relative rpath, re-sign.
    for f in binaries(tree):
        cmd = []
        own = otool_id(f)
        if own and own != f"@rpath/{f.name}":
            cmd += ["-id", f"@rpath/{f.name}"]
        for dep in otool_deps(f):
            want = f"@rpath/{Path(dep).name}"
            if not dep.startswith(DARWIN_SYSTEM) and dep != want:
                cmd += ["-change", dep, want]
        want = want_path(tree, f)
        rps = otool_rpaths(f)
        cmd += [x for r in rps if r != want for x in ("-delete_rpath", r)]
        if want not in rps:
            cmd += ["-add_rpath", want]
        if not cmd:
            continue
        subprocess.run([need_tool("install_name_tool"), *cmd, str(f)], check=True)
        # install_name_tool invalidates the signature; unsigned arm64 code is
        # SIGKILLed on exec.
        subprocess.run(["codesign", "--force", "--sign", "-", str(f)], check=True,
                       capture_output=True)
        log(f"install names, rpath {want}: {f.relative_to(tree)}")

    # 3. Gates: nothing absolute outside the OS survives, every @rpath dep is
    #    in lib/.
    for f in binaries(tree):
        for dep in otool_deps(f):
            if dep.startswith(DARWIN_SYSTEM):
                continue
            if not dep.startswith("@rpath/") or not (lib / Path(dep).name).exists():
                fails.append(f"unrelocatable dependency '{dep}' in {f.relative_to(tree)}")
        for r in otool_rpaths(f):
            if not r.startswith("@"):
                fails.append(f"absolute rpath '{r}' in {f.relative_to(tree)}")
    return fails


# --- Windows ----------------------------------------------------------------

def pe_imports(f: Path) -> list[str]:
    return re.findall(r"DLL Name:\s*(\S+)", run_out([str(OBJDUMP), "-p", str(f)]))


def windows_system(name: str) -> bool:
    if WINDOWS_SYSTEM.match(name):
        return True
    sysdir = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"
    return (sysdir / name).is_file()


def bundle_windows(tree: Path, lib: Path) -> list[str]:
    bin_dir = tree / "bin"
    search = [LLVM_BUILD / "bin", *[Path(p) for p in os.environ.get("PATH", "").split(os.pathsep) if p]]
    fails = []
    # The loader searches the exe's own directory first, so a DLL beside it
    # is the whole fix; there is no rpath to rewrite.
    added = True
    while added:
        added = False
        for f in binaries(tree):
            for name in pe_imports(f):
                if windows_system(name) or (bin_dir / name).exists():
                    continue
                src = next((d / name for d in search if (d / name).is_file()), None)
                if src is None:
                    if f.parent == bin_dir:
                        fails.append(f"{f.relative_to(tree)} imports '{name}', found nowhere")
                    continue
                copy_dep(src, bin_dir / name)
                added = True
    return fails


# --- all hosts --------------------------------------------------------------

def dangling_links(root: Path, prune: str | None) -> list[Path]:
    out = []
    for d, dirs, files in os.walk(root):
        if prune and Path(d) == root and prune in dirs:
            dirs.remove(prune)
        for n in dirs + files:
            p = Path(d) / n
            if p.is_symlink() and not p.exists():
                out.append(p)
    return out


def bundle_tree(tree: Path) -> bool:
    if not (tree / "bin").is_dir():
        return True
    lib = tree / "lib"
    log(f"{tree.name}: bundle")
    if HOST == "Linux":
        fails = bundle_linux(tree, lib)
    elif HOST == "Darwin":
        fails = bundle_darwin(tree, lib)
    else:
        fails = bundle_windows(tree, lib)

    # Strip what shouldn't ship.
    for f in list((tree / "bin").glob("*.log")) + list(lib.glob("liblld*.a")):
        f.unlink()
    if not (lib / "std").is_symlink():
        for f in (lib / "std").glob("v*draft.k"):
            f.unlink()

    # A debug tree's sysroot is one symlink to the release one; os.walk does
    # not descend it, and its own link is checked like any other.
    fails += [f"dangling symlink {p.relative_to(tree)}" for p in dangling_links(tree, "sysroot")]
    sysroot = tree / "sysroot"
    if sysroot.is_dir() and not sysroot.is_symlink():
        n = len(dangling_links(sysroot, None))
        if n:
            log(f"note: {n} dangling symlinks inside sysroot/ (vendored target content, not gated)")

    for f in fails:
        log(f"FAIL: {f}")
    log(f"{tree.name}: {'OK' if not fails else 'NOT relocatable'}")
    return not fails


def main() -> None:
    ap = argparse.ArgumentParser(description="Stage clang, its resource dir and Lib/ into a build tree.")
    ap.add_argument("trees", nargs="*", help="tree directories (default: build/<triple>/$KBLD_MODE)")
    ap.add_argument("--all", action="store_true", help="stage both the debug and the release tree")
    ap.add_argument("--copy", action="store_true", help="copy Lib/ trees even into a debug tree")
    ap.add_argument("--no-bundle", action="store_true", help="stage only; skip bundling and its gates")
    a = ap.parse_args()

    if a.trees:
        trees = [Path(t).resolve() for t in a.trees]
    elif a.all:
        trees = [BUILD_DIR / TRIPLE / m for m in ("debug", "release")]
    else:
        trees = [BUILD_DIR / TRIPLE / MODE]

    ok = True
    for t in trees:
        # Symlinks only where the tree is the edit loop's; a release tree is
        # the one that ships.
        link_lib = (t.name == "debug") and not a.copy and HOST != "Windows"
        stage_tree(t, link_lib)
        if not a.no_bundle and not bundle_tree(t):
            ok = False
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
