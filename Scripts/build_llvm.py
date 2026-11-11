#!/usr/bin/env python3
# TOOLCHAIN LINKAGE INVARIANT - do not violate:
#   Linux/macOS : shared (libLLVM.so/.dylib), one copy in lib/, thin bins
#   Windows     : static (.lib), forced - libLLVM.dll is unsupported on Windows
#   No system-LLVM fallback on any platform (patched fork required).
#
# Builds the patched llvm-project fork in Lib/llvm-runtimes and stages its
# libraries into build/<triple>/<mode>/lib. Written in Python because LLVM's
# own build already requires Python 3.8+, so it exists on every host.
from __future__ import annotations

import argparse
import hashlib
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import host_sysroot  # Scripts/, beside this file

HOST = platform.system()  # Linux | Darwin | Windows


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def log(msg: str = "") -> None:
    print(f"[llvm] {msg}" if msg else "", flush=True)


def die(msg: str, code: int = 1) -> "NoReturn":
    lines = msg.splitlines() or [""]
    print(f"[llvm] error: {lines[0]}", file=sys.stderr, flush=True)
    for line in lines[1:]:
        print(f"[llvm]   {line}", file=sys.stderr, flush=True)
    sys.exit(code)


def getenv(name: str, default: str) -> str:
    v = os.environ.get(name)
    return v if v else default


def env_get(env: dict, key: str) -> str | None:
    # Windows env var names are case-insensitive ("Path" vs "PATH").
    ku = key.upper()
    for k, v in env.items():
        if k.upper() == ku:
            return v
    return None


def which(name: str, env: dict) -> str | None:
    # subprocess resolves the executable against the *parent* PATH, not the
    # env= we pass, so resolve against the target env explicitly.
    return shutil.which(name, path=env_get(env, "PATH"))


def capture(cmd: list[str]) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"command failed ({r.returncode}): {' '.join(cmd)}\n{r.stderr.strip()}")
    return r.stdout


def run(cmd: list[str], env: dict, logfile: Path | None = None) -> None:
    if logfile is None:
        rc = subprocess.run(cmd, env=env).returncode
    else:
        with open(logfile, "ab") as lf, subprocess.Popen(
            cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        ) as p:
            assert p.stdout is not None
            for line in iter(p.stdout.readline, b""):
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                lf.write(line)
            rc = p.wait()
    if rc != 0:
        where = f" (see {logfile})" if logfile else ""
        die(f"'{Path(cmd[0]).name}' failed with exit code {rc}{where}", rc)


def fresh_copy(src: Path, dst: Path) -> None:
    # Unlink first: overwriting a file in place can corrupt a process that has
    # it mapped, and on macOS it trips the kernel's code-signing cache (SIGKILL).
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    shutil.copy2(src, dst)
    os.chmod(dst, os.stat(dst).st_mode | 0o200)  # brew ships some dylibs 0444


def host_arch() -> str:
    if HOST == "Windows":
        a = os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE", "")
    else:
        a = platform.machine()
    a = a.lower()
    if a in ("x86_64", "amd64"):
        return "x86_64"
    if a in ("aarch64", "arm64"):
        return "aarch64"
    die(f"unsupported host architecture '{a}'")


def cpu_count() -> int:
    if hasattr(os, "sched_getaffinity"):  # matches nproc (respects cpusets)
        return len(os.sched_getaffinity(0))
    return os.cpu_count() or 1


def ram_gb() -> float | None:
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30
    except (ValueError, OSError, AttributeError):
        return None


# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

ARCH      = host_arch()
ROOT      = Path(getenv("KBLD_ROOT", str(Path(__file__).resolve().parent.parent)))
BUILD_DIR = Path(getenv("KBLD_BUILD_DIR", str(ROOT / "build")))
MODE      = getenv("KBLD_MODE", "release")
JOBS      = cpu_count()
# The backends every LLVM we build carries: this host build and every cross host
# (Scripts/cross_llvm.py imports both values; build.py derives its static link list from
# the configured Targets.def). Covers every target a kcc user might name:
# the toolchain is one compiler for every target, so a missing backend is a refused
# --target, not a smaller download. Xtensa is still experimental in the fork (LLVM 22).
TARGETS   = getenv("LLVM_TARGETS", "X86;AArch64;ARM;RISCV;WebAssembly;PowerPC;SystemZ;Mips;"
                                   "LoongArch;Sparc;AVR;MSP430;BPF;NVPTX;AMDGPU;SPIRV")
EXPERIMENTAL_TARGETS = getenv("LLVM_EXPERIMENTAL_TARGETS", "Xtensa")

# Resolved through symlinks: a worktree borrows the main checkout's fork and build
# tree by symlink, and cmake bakes these two paths into CMakeCache.txt, build.ninja and
# every compile command. Spelled through the worktree they were a "different" configure
# that re-pointed the shared tree and restarted the whole build.
LLVM_SRC   = Path(os.path.realpath(ROOT / "Lib" / "llvm-runtimes"))
LLVM_BUILD = Path(os.path.realpath(BUILD_DIR / "llvm"))
# True when build/llvm belongs to another checkout. A borrower may use it and stage
# from it, never configure or build it: its owner does that.
BORROWED   = (BUILD_DIR / "llvm").is_symlink()
STAMP      = LLVM_BUILD / ".kbld-configure.sha256"
# The fork commit the tree was last brought up to date with (clean checkouts only).
SRC_STAMP  = LLVM_BUILD / ".kbld-source.id"

if HOST == "Linux":
    TRIPLE = getenv("KBLD_TRIPLE", f"{ARCH}-linux-gnu")
    MARKER = LLVM_BUILD / "lib" / "libLLVM.so"
    _gb = ram_gb()
    # ThinLTO links of libLLVM/libclang-cpp are RAM-bound, not core-bound.
    _default_link = max(1, min(JOBS, int(_gb // 8))) if _gb else JOBS
    BUILD_TIME = "20-60 min"
elif HOST == "Darwin":
    TRIPLE = getenv("KBLD_TRIPLE", ("arm64" if ARCH == "aarch64" else "x86_64") + "-apple-macosx")
    MARKER = LLVM_BUILD / "lib" / "libLLVM.dylib"
    OSX_ARCH = "arm64" if ARCH == "aarch64" else "x86_64"
    MACOS_MIN = getenv("KBLD_MACOS_MIN", "13.0")
    _default_link = JOBS
    BUILD_TIME = "20-60 min"
elif HOST == "Windows":
    TRIPLE = getenv("KBLD_TRIPLE", f"{ARCH}-windows-msvc")
    MARKER = LLVM_BUILD / "lib" / "LLVMCore.lib"
    VS_ARCH = "x64" if ARCH == "x86_64" else "arm64"
    VCPKG_TRIPLET = f"{VS_ARCH}-windows-static-md"
    _default_link = JOBS
    BUILD_TIME = "30-90 min"
else:
    die(f"unsupported host '{HOST}'")

LINK_JOBS = int(getenv("LINK_JOBS", str(_default_link)))
OUT_LIB   = BUILD_DIR / TRIPLE / MODE / "lib"

COMMON_ARGS = [
    "-DCMAKE_BUILD_TYPE=Release",
    "-DLLVM_ENABLE_PROJECTS=clang;lld",
    f"-DLLVM_TARGETS_TO_BUILD={TARGETS}",
    f"-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD={EXPERIMENTAL_TARGETS}",
    "-DLLVM_ENABLE_RTTI=ON",
    "-DLLVM_ENABLE_EH=ON",
    "-DLLVM_INCLUDE_TESTS=OFF",
    "-DLLVM_INCLUDE_EXAMPLES=OFF",
    "-DLLVM_INCLUDE_BENCHMARKS=OFF",
    "-DLLVM_BUILD_TOOLS=OFF",
    "-DLLVM_OPTIMIZED_TABLEGEN=ON",
    "-DCLANG_BUILD_TOOLS=OFF",
    "-DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF",
    "-DLLVM_ENABLE_BINDINGS=OFF",
    "-DLLVM_ENABLE_ZLIB=FORCE_ON",
    "-DLLVM_ENABLE_ZSTD=FORCE_ON",
    "-DLLVM_ENABLE_LIBXML2=OFF",
    f"-DLLVM_PARALLEL_LINK_JOBS={LINK_JOBS}",
]

TEST_TOOLS = ["llvm-objdump", "llvm-nm"]  # see build_test_tools()

SHARED_ARGS = [  # Linux/macOS: one libLLVM dylib, everything links it
    "-DLLVM_BUILD_LLVM_DYLIB=ON",
    "-DLLVM_LINK_LLVM_DYLIB=ON",
    "-DLLVM_ENABLE_LIBCXX=ON",
]

TOOL_HINTS = {
    "Linux":   "Arch:   sudo pacman -S cmake ninja\nDebian: apt install cmake ninja-build",
    "Darwin":  "brew install cmake ninja",
    "Windows": "winget install Ninja-build.Ninja (cmake ships with the VS C++ workload)",
}


# ---------------------------------------------------------------------------
# Linux
# ---------------------------------------------------------------------------

# The compiler that builds the fork on Linux: a COPY of the fork's own clang, in
# build/llvm-host (outside build/llvm, which ninja would rewrite mid-build). With
# ThinLTO the static lld archives are bitcode, readable only by an lld of the same
# or a newer LLVM: built by the host clang they were LLVM 23.1.3 bitcode the moment
# the distro upgraded clang, and kairo (linked by the fork's lld 22) failed with
# "Not an int attribute (Producer: 'LLVM23.1.3' Reader: 'LLVM 22.1.0')".
# Seeded once from build/llvm; refresh by deleting build/llvm-host. A first build
# with no build/llvm uses the host clang, and only if its major is the fork's.
# Beside the build tree it was seeded from, so a checkout that borrows build/llvm by
# symlink names the shared copy (same configure, no second 280 MB seed).
HOST_TC = LLVM_BUILD.parent / "llvm-host"


def fork_major() -> str:
    m = re.search(r"set\(LLVM_VERSION_MAJOR (\d+)\)",
                  (LLVM_SRC / "cmake" / "Modules" / "LLVMVersion.cmake").read_text())
    if not m:
        die("cannot read LLVM_VERSION_MAJOR from the fork")
    return m.group(1)


def seed_host_toolchain(major: str) -> bool:
    src_bin, src_lib = LLVM_BUILD / "bin", LLVM_BUILD / "lib"
    clang = src_bin / f"clang-{major}"
    if not (clang.is_file() and (src_bin / "lld").is_file() and (src_lib / "clang" / major).is_dir()):
        return False
    log(f"seeding {HOST_TC} from {LLVM_BUILD} (clang-{major}, lld, resource dir, shared libs)")
    tmp = HOST_TC.with_name(HOST_TC.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    (tmp / "bin").mkdir(parents=True)
    (tmp / "lib").mkdir()
    shutil.copy2(clang, tmp / "bin" / clang.name)
    shutil.copy2(src_bin / "lld", tmp / "bin" / "lld")
    for l in ("clang", "clang++"):
        os.symlink(clang.name, tmp / "bin" / l)
    os.symlink("lld", tmp / "bin" / "ld.lld")
    # clang-<major> and lld load these through RUNPATH $ORIGIN/../lib.
    for so in src_lib.glob("lib*.so*"):
        if so.name.startswith(("libLLVM", "libclang-cpp")):
            shutil.copy2(so, tmp / "lib" / so.name, follow_symlinks=False)
    shutil.copytree(src_lib / "clang" / major, tmp / "lib" / "clang" / major)
    shutil.rmtree(HOST_TC, ignore_errors=True)
    tmp.rename(HOST_TC)
    return True


def host_compilers() -> tuple[str, str]:
    major = fork_major()
    if (HOST_TC / "bin" / "clang++").exists() or seed_host_toolchain(major):
        return str(HOST_TC / "bin" / "clang"), str(HOST_TC / "bin" / "clang++")
    r = subprocess.run(["clang", "-dumpversion"], capture_output=True, text=True)
    host = r.stdout.strip().split(".")[0] if r.returncode == 0 else "?"
    if host != major:
        die(f"no build/llvm to seed {HOST_TC} from, and the host clang is {host}, not {major}:\n"
            f"its ThinLTO bitcode would not load in the fork's lld. Install clang {major}, "
            f"or put a clang {major} at {HOST_TC}/bin.")
    return "clang", "clang++"


def linux_args() -> list[str]:
    cc, cxx = host_compilers()
    return [
        f"-DCMAKE_C_COMPILER={cc}",
        f"-DCMAKE_CXX_COMPILER={cxx}",
        *SHARED_ARGS,
        "-DLLVM_ENABLE_LTO=Thin",
        # ThinLTO objects are bitcode; GNU ld only links them if the LLVMgold
        # plugin happens to be installed. lld always can.
        "-DLLVM_USE_LINKER=lld",
    ]


def linux_preflight(env: dict) -> None:
    cxx = which("clang++", env)
    if not cxx:
        die("clang++ not found on PATH")
    if not which("ld.lld", env):
        die("ld.lld not found (required for the ThinLTO link)\n"
            "Arch:   sudo pacman -S lld\n"
            "Debian: apt install lld")
    with tempfile.TemporaryDirectory() as td:
        r = subprocess.run(
            [cxx, "-stdlib=libc++", "-x", "c++", "-", "-o", str(Path(td) / "t")],
            input=b"#include <vector>\nint main(){std::vector<int> v; return (int)v.size();}\n",
            capture_output=True,
        )
    if r.returncode != 0:
        die("clang++ cannot compile/link against libc++ (LLVM_ENABLE_LIBCXX=ON needs it)\n"
            "Arch:   sudo pacman -S libc++\n"
            "Debian: apt install libc++-dev libc++abi-dev")


def linux_sysroot_args(root: Path, dry: bool) -> list[str]:
    # Opt-in ($KAIRO_HOST_SYSROOT, see host_sysroot.py): configure against an
    # old-glibc sysroot so libLLVM / libclang-cpp / clang carry its floor, not
    # the build host's. Appended only when set: the default cmake_args, and
    # with them the configure hash, stay byte-identical, so an unset build
    # never reconfigures (or rebuilds) LLVM.
    gaps = host_sysroot.missing(root)
    for m in gaps:
        log(f"host sysroot missing: {m}")
    if gaps and not dry:
        die(f"host sysroot {root} cannot build the toolchain ({len(gaps)} missing, above)\n"
            f"unset {host_sysroot.ENV} to build against the host glibc")
    cxx = shlex.join(host_sysroot.cflags(root))
    # The C side wants the same isolation without the C++ flags.
    c = shlex.join(host_sysroot.cflags(root, cxx=False))
    ld = shlex.join(host_sysroot.ldflags(root))
    return [
        f"-DCMAKE_SYSROOT={root}",
        f"-DCMAKE_C_FLAGS={c}",
        f"-DCMAKE_CXX_FLAGS={cxx}",
        f"-DCMAKE_EXE_LINKER_FLAGS={ld}",
        f"-DCMAKE_SHARED_LINKER_FLAGS={ld}",
        f"-DCMAKE_MODULE_LINKER_FLAGS={ld}",
        # libedit drags in the host's libedit + libncursesw (glibc 2.42 here),
        # and the sysroot has neither. Only the line editor in llvm tools uses it.
        "-DLLVM_ENABLE_LIBEDIT=OFF",
    ]


# ---------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def brew_llvm(dry: bool) -> Path:
    p = os.environ.get("KBLD_BREW_LLVM")
    if not p:
        brew = shutil.which("brew")
        if not brew:
            if dry:
                return Path("<brew --prefix llvm>")
            die("Homebrew not found; Homebrew llvm is required on macOS (or set KBLD_BREW_LLVM)")
        p = capture([brew, "--prefix", "llvm"]).strip()  # stable opt/ path, not Cellar/<ver>
    pp = Path(p)
    if not dry and not (pp / "bin" / "clang++").exists():
        die(f"Homebrew llvm not installed at {pp}\nbrew install llvm")
    return pp


def darwin_args(brew: Path) -> list[str]:
    # Link against brew's libc++ (per `brew info llvm` caveats). The build-time
    # rpaths only exist so tablegen etc. run in the build tree; stage_darwin()
    # strips every absolute rpath and bundles libc++ next to libLLVM.
    ld = (f"-L{brew}/lib/c++ -L{brew}/lib/unwind -lunwind "
          f"-Wl,-rpath,{brew}/lib/c++ -Wl,-rpath,{brew}/lib/unwind")
    return [
        f"-DCMAKE_C_COMPILER={brew}/bin/clang",
        f"-DCMAKE_CXX_COMPILER={brew}/bin/clang++",
        f"-DCMAKE_OSX_ARCHITECTURES={OSX_ARCH}",
        f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MACOS_MIN}",
        f"-DCMAKE_SHARED_LINKER_FLAGS={ld}",
        f"-DCMAKE_MODULE_LINKER_FLAGS={ld}",
        f"-DCMAKE_EXE_LINKER_FLAGS={ld}",
        *SHARED_ARGS,
        "-DLLVM_ENABLE_LTO=OFF",
    ]


def otool_id(f: Path) -> str | None:
    lines = capture(["otool", "-D", str(f)]).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def otool_deps(f: Path) -> list[str]:
    own = otool_id(f)
    deps = []
    for line in capture(["otool", "-L", str(f)]).splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        dep = line.split(" (compatibility")[0].strip()
        if dep != own:
            deps.append(dep)
    return deps


def otool_rpaths(f: Path) -> list[str]:
    out = capture(["otool", "-l", str(f)])
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", out)


def otool_minos(f: Path) -> str | None:
    out = capture(["otool", "-l", str(f)])
    m = re.search(r"cmd LC_BUILD_VERSION\n\s+cmdsize \d+\n\s+platform \d+\n\s+minos (\S+)", out)
    return m.group(1) if m else None


def vtuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split(".") if x.isdigit())


def resolve_dep(dep: str, origin: Path, search: list[Path]) -> Path | None:
    if dep.startswith("@rpath/"):
        tail = dep[len("@rpath/"):]
        for d in search:
            c = d / tail
            if c.is_file():
                return c.resolve()
        return None
    if dep.startswith("@loader_path/"):
        c = origin / dep[len("@loader_path/"):]
        return c.resolve() if c.is_file() else None
    if dep.startswith("@"):
        return None
    p = Path(dep)
    return p.resolve() if p.is_file() else None


def fix_macho(f: Path) -> None:
    own = otool_id(f)
    cmd = ["install_name_tool"]
    if own:
        cmd += ["-id", f"@rpath/{Path(own).name}"]
    for dep in otool_deps(f):
        if dep.startswith(SYSTEM_PREFIXES):
            continue
        want = f"@rpath/{Path(dep).name}"
        if dep != want:
            cmd += ["-change", dep, want]
    rps = otool_rpaths(f)
    for r in rps:
        if not r.startswith("@"):
            cmd += ["-delete_rpath", r]
    if "@loader_path" not in rps:
        cmd += ["-add_rpath", "@loader_path"]
    cmd.append(str(f))
    capture(cmd)
    # install_name_tool invalidates the signature; unsigned arm64 code is
    # SIGKILLed on exec (only the debugger tolerates it).
    capture(["codesign", "--force", "--sign", "-", str(f)])


def stage_darwin() -> None:
    shipped = stage_posix(["libLLVM*.dylib", "libclang*.dylib", "liblld*.dylib"])
    llvm_lib = (LLVM_BUILD / "lib").resolve()
    real = [OUT_LIB / n for n in sorted(shipped) if not (OUT_LIB / n).is_symlink()]
    origin = {f: llvm_lib for f in real}

    # Walk the dependency closure. Anything outside the OS (brew libc++,
    # libc++abi, libunwind, zstd, ...) gets bundled into lib/ so the
    # toolchain is relocatable and survives `brew upgrade`.
    bundled: list[Path] = []
    search: list[Path] = []
    queue = list(real)
    while queue:
        f = queue.pop()
        odir = origin[f]
        for r in otool_rpaths(f):
            r = r.replace("@loader_path", str(odir))
            if not r.startswith("@") and Path(r) not in search:
                search.append(Path(r))
        for dep in otool_deps(f):
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            base = Path(dep).name
            if base in shipped:
                continue
            src = resolve_dep(dep, odir, search)
            if src is None:
                die(f"{f.name} depends on '{dep}', which could not be resolved for bundling")
            dst = OUT_LIB / base
            fresh_copy(src, dst)
            shipped.add(base)
            origin[dst] = src.parent
            bundled.append(dst)
            queue.append(dst)

    for f in real + bundled:
        fix_macho(f)

    # verify: no absolute non-system load paths or rpaths survive, and no
    # image loads two different libc++ copies (ODR/ABI split across the boundary)
    for f in real + bundled:
        deps = otool_deps(f)
        if "/usr/lib/libc++.1.dylib" in deps and "@rpath/libc++.1.dylib" in deps:
            die(f"{f.name} links both system and bundled libc++")
        for dep in deps:
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            if not dep.startswith("@rpath/") or Path(dep).name not in shipped:
                die(f"{f.name}: unrelocatable dependency '{dep}' after fixup")
        for r in otool_rpaths(f):
            if not r.startswith("@"):
                die(f"{f.name}: absolute rpath '{r}' survived fixup")

    # -lfoo needs libfoo.dylib; bundled copies only carry the versioned name.
    for f in bundled:
        m = re.fullmatch(r"(lib.+?)(?:\.\d+)+\.dylib", f.name)
        if m:
            link = OUT_LIB / f"{m.group(1)}.dylib"
            if link.exists() or link.is_symlink():
                link.unlink()
            os.symlink(f.name, link)

    tgt = vtuple(MACOS_MIN)
    for f in bundled:
        m = otool_minos(f)
        if m and vtuple(m) > tgt:
            log(f"warning: bundled {f.name} requires macOS {m} > deployment target {MACOS_MIN}; "
                f"effective minimum is {m}")

    if bundled:
        log("bundled: " + ", ".join(p.name for p in bundled))
    log(f"libs copied, install names fixed, re-signed in {OUT_LIB}")


# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------

def find_vsdevcmd() -> Path | None:
    vsi = os.environ.get("VSINSTALLDIR")
    if vsi:
        c = Path(vsi) / "Common7" / "Tools" / "VsDevCmd.bat"
        if c.is_file():
            return c
    vswhere = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe")
    if vswhere.is_file():
        comp = ("Microsoft.VisualStudio.Component.VC.Tools.x86.x64" if VS_ARCH == "x64"
                else "Microsoft.VisualStudio.Component.VC.Tools.ARM64")
        r = subprocess.run([str(vswhere), "-latest", "-products", "*", "-requires", comp,
                            "-property", "installationPath"], capture_output=True, text=True)
        paths = r.stdout.strip().splitlines()
        if paths:
            c = Path(paths[0]) / "Common7" / "Tools" / "VsDevCmd.bat"
            if c.is_file():
                return c
    for f in (
        r"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
        r"C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
        r"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        r"C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
        r"C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat",
    ):
        if Path(f).is_file():
            return Path(f)
    return None


def vs_env(vsdevcmd: Path) -> dict:
    cmd = f'call "{vsdevcmd}" -arch={VS_ARCH} -host_arch={VS_ARCH} >nul && set'
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, errors="replace")
    if r.returncode != 0:
        die(f"VsDevCmd.bat failed ({r.returncode})\n{r.stderr.strip()}")
    env = {}
    for line in r.stdout.splitlines():
        k, sep, v = line.partition("=")
        if sep and k:
            env[k] = v
    return env


def find_vcpkg(env: dict) -> Path | None:
    for key in ("VCPKG_ROOT", "VCPKG_INSTALLATION_ROOT"):
        v = env_get(env, key)
        if v:
            return Path(v)
    exe = which("vcpkg", env)
    return Path(exe).parent if exe else None


def windows_args(vs: dict, dry: bool) -> list[str]:
    # Parent env first (original resolution order), then the VS dev env.
    root = find_vcpkg(dict(os.environ)) or find_vcpkg(vs)
    if not root:
        if not dry:
            die("vcpkg not found. launch the VS dev prompt (sets VCPKG_ROOT) or set VCPKG_ROOT manually.")
        root = Path("<VCPKG_ROOT>")
    toolchain = root / "scripts" / "buildsystems" / "vcpkg.cmake"
    if not dry and not toolchain.is_file():
        die(f"vcpkg toolchain missing at {toolchain}")
    log(f"vcpkg root:  {root}")
    return [
        "-DCMAKE_C_COMPILER=clang",
        "-DCMAKE_CXX_COMPILER=clang++",
        "-DCMAKE_LINKER=lld-link",
        "-DLLVM_USE_CRT_RELEASE=MD",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL",
        "-DLLVM_ENABLE_LTO=OFF",
        f"-DVCPKG_MANIFEST_DIR={ROOT}",
        "-DVCPKG_MANIFEST_MODE=ON",
        f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
        f"-DVCPKG_TARGET_TRIPLET={VCPKG_TRIPLET}",
    ]


def stage_windows() -> None:
    OUT_LIB.mkdir(parents=True, exist_ok=True)
    for d, pats in ((LLVM_BUILD / "bin", ("LLVM*.dll", "clang*.dll", "lld*.dll")),
                    (LLVM_BUILD / "lib", ("LLVM*.lib", "clang*.lib", "lld*.lib"))):
        for pat in pats:
            for p in d.glob(pat):
                fresh_copy(p, OUT_LIB / p.name)
    # zstd/zlib: vcpkg-built static deps that LLVMSupport references.
    # Co-locate with LLVM libs so kairo's -L release\lib covers them and we
    # don't carry a brittle -L into vcpkg's internal tree.
    vlib = LLVM_BUILD / "vcpkg_installed" / VCPKG_TRIPLET / "lib"
    if vlib.is_dir():
        if (vlib / "zstd.lib").is_file():
            fresh_copy(vlib / "zstd.lib", OUT_LIB / "zstd.lib")
        if (vlib / "zs.lib").is_file():  # vcpkg's name on this triplet; normalize
            fresh_copy(vlib / "zs.lib", OUT_LIB / "zlib.lib")
        log("zstd/zlib copied from vcpkg tree")
    else:
        log(f"warning: vcpkg lib dir not found at {vlib}")
    log(f"libs copied to {OUT_LIB}")


# ---------------------------------------------------------------------------
# staging (POSIX)
# ---------------------------------------------------------------------------

def stage_posix(patterns: list[str]) -> set[str]:
    OUT_LIB.mkdir(parents=True, exist_ok=True)
    src = LLVM_BUILD / "lib"
    names: set[str] = set()
    for pat in patterns:
        for p in sorted(src.glob(pat)):
            dst = OUT_LIB / p.name
            if p.is_symlink():  # preserve SONAME symlink chains (cp -P)
                if dst.exists() or dst.is_symlink():
                    dst.unlink()
                os.symlink(os.readlink(p), dst)
            else:
                fresh_copy(p, dst)
            names.add(p.name)
    return names


def stage() -> None:
    if HOST == "Linux":
        stage_posix(["libLLVM*.so*", "libclang*.so*", "liblld*.so*"])
        log(f"libs copied to {OUT_LIB}")
    elif HOST == "Darwin":
        stage_darwin()
    else:
        stage_windows()


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def source_id() -> str | None:
    """The fork's commit when its checkout is clean, else None (unknown: let ninja
    decide). This is what makes "nothing changed" checkable without running ninja."""
    try:
        git = ["git", "-C", str(LLVM_SRC)]
        head = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True)
        dirty = subprocess.run([*git, "status", "--porcelain", "--untracked-files=no"],
                               capture_output=True, text=True)
    except OSError:
        return None
    if head.returncode != 0 or dirty.returncode != 0 or dirty.stdout.strip():
        return None
    return head.stdout.strip() or None


def cache_source_dir() -> str | None:
    """The source directory the existing build tree was configured from."""
    cache = LLVM_BUILD / "CMakeCache.txt"
    if not cache.is_file():
        return None
    for line in cache.read_text(errors="replace").splitlines():
        if line.startswith("CMAKE_HOME_DIRECTORY:INTERNAL="):
            return line.split("=", 1)[1]
    return None


def refuse_borrowed(why: str) -> None:
    if BORROWED:
        die(f"build/llvm is a symlink to another checkout's LLVM build ({LLVM_BUILD}) and {why}.\n"
            "a borrowed build is never configured or rebuilt from here; run\n"
            "Scripts/build_llvm.py in the checkout that owns it, or pass --no-prebuild.")


def banner() -> None:
    log()
    log("============================================================")
    log(" BUILDING PATCHED LLVM FROM SOURCE")
    log("------------------------------------------------------------")
    log(" Kairo links our llvm-project fork, which carries a custom")
    log(" Clang patch (preprocessor token injection) that the Kairo")
    log(" frontend depends on. System LLVM does NOT have this patch")
    log(" and would produce a silently broken compiler, so there is")
    log(" no system fallback path. This is a one-time build.")
    log(f" Expect {BUILD_TIME} depending on cores. Output streams below.")
    log("============================================================")
    log()


def main() -> None:
    ap = argparse.ArgumentParser(description="Build and stage the patched LLVM fork.")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the resolved config and cmake invocation, then exit")
    a = ap.parse_args()

    log(f"host:        {HOST} {ARCH}")
    log(f"root:        {ROOT}")
    log(f"triple:      {TRIPLE}")
    log(f"mode:        {MODE}")
    log(f"out_lib:     {OUT_LIB}")
    log(f"jobs:        {JOBS}")
    log(f"link_jobs:   {LINK_JOBS}")
    log(f"targets:     {TARGETS} (+ experimental {EXPERIMENTAL_TARGETS or 'none'})")

    if not a.dry_run and not (LLVM_SRC / "llvm" / "CMakeLists.txt").is_file():
        die("Lib/llvm-runtimes is not checked out.\n"
            "this is our PATCHED llvm-project fork (custom Clang PP-token\n"
            "injection). it is REQUIRED, there is no system-LLVM fallback.\n"
            "run: git submodule update --init --recursive Lib/llvm-runtimes")

    env = dict(os.environ)
    if HOST == "Windows":
        if not a.dry_run:
            vsdev = find_vsdevcmd()
            if not vsdev:
                die("could not locate VsDevCmd.bat\n"
                    "Install Visual Studio with the 'Desktop development with C++' workload")
            log(f"using VS env: {vsdev}")
            env = vs_env(vsdev)
        plat = windows_args(env, a.dry_run)
    elif HOST == "Darwin":
        brew = brew_llvm(a.dry_run)
        log(f"brew llvm:   {brew}")
        log(f"macos min:   {MACOS_MIN}")
        plat = darwin_args(brew)
    else:
        plat = linux_args()
        root = host_sysroot.sysroot()
        if root:
            log(f"host sysroot: {root} (glibc {host_sysroot.glibc_version(root)})")
            plat += linux_sysroot_args(root, a.dry_run)

    cmake_args = ["-S", str(LLVM_SRC / "llvm"), "-B", str(LLVM_BUILD), "-G", "Ninja",
                  *COMMON_ARGS, *plat]
    digest = hashlib.sha256("\0".join([HOST, *cmake_args]).encode()).hexdigest()

    if a.dry_run:
        join = subprocess.list2cmdline if HOST == "Windows" else shlex.join
        print(join(["cmake", *cmake_args]))
        print(f"configure hash: {digest}")
        return

    tools = {}
    for t in ("cmake", "ninja"):
        tools[t] = which(t, env)
        if not tools[t]:
            die(f"'{t}' not found.\n{TOOL_HINTS[HOST]}")
    cmake_args.append(f"-DCMAKE_MAKE_PROGRAM={tools['ninja']}")
    if HOST == "Darwin":
        for t in ("otool", "install_name_tool", "codesign"):
            if not which(t, env):
                die(f"'{t}' not found.\nxcode-select --install")

    # The test suite disassembles and lists symbols with llvm-objdump and
    # llvm-nm on every host (their flags are not GNU binutils'), and
    # LLVM_BUILD_TOOLS=OFF leaves them out of `all`; CLANG_BUILD_TOOLS=OFF does
    # the same to the clang driver the staged tree ships. Name them to ninja on
    # every run, not only when missing: they compile InitializeAllTargets() in
    # from Targets.def, so a "built once" check left them registering the old
    # backend list after a target was added. ninja makes an
    # up-to-date tool a no-op.
    def build_test_tools():
        want = ["clang", *TEST_TOOLS]
        log(f"building tools outside `all`: {' '.join(want)}")
        run([tools["ninja"], "-C", str(LLVM_BUILD), f"-j{JOBS}", *want], env, None)

    stamp = STAMP.read_text().strip() if STAMP.is_file() else None
    built = MARKER.is_file()
    src_id = source_id()
    src_stamp = SRC_STAMP.read_text().strip() if SRC_STAMP.is_file() else None

    # A tree configured from some other spelling of the source (a worktree's symlink)
    # has that path in every compile command: running ninja on it rebuilds everything.
    # Treat it as a changed configure so the paths are put back first.
    cached_src = cache_source_dir()
    if built and stamp == digest and cached_src and cached_src != str(LLVM_SRC / "llvm"):
        log(f"build tree was configured from {cached_src}; reconfiguring from {LLVM_SRC / 'llvm'}.")
        stamp = "stale-source-path"

    if built and stamp == digest:
        # The normal build path: same configure, same fork commit, tools present.
        # Nothing can be out of date, so ninja is not even started.
        exe = ".exe" if HOST == "Windows" else ""
        have_tools = all((LLVM_BUILD / "bin" / (t + exe)).is_file() for t in ("clang", *TEST_TOOLS))
        if src_id is not None and src_id == src_stamp and have_tools:
            log(f"llvm up to date (configure and fork commit {src_id[:12]} unchanged); using the cached build.")
            stage()
            return
        refuse_borrowed("the fork's sources changed or were never recorded for it"
                        if have_tools else "it lacks clang or the test tools")
        # The stamp covers the configure args only, not the fork's sources: a moved
        # submodule must still reach ninja. ninja itself knows what changed; on an
        # up-to-date tree it is a no-op in about a second.
        log("configure unchanged; incremental build of the fork's sources...")
        run([tools["ninja"], "-C", str(LLVM_BUILD), f"-j{JOBS}"], env, None)
        build_test_tools()
        if src_id is not None:
            SRC_STAMP.write_text(src_id + "\n")
        stage()
        return
    if built and stamp is None:
        if HOST == "Darwin":
            die("existing macOS LLVM build predates the toolchain fixes in this script\n"
                "(wrong compiler, non-relocatable libc++). wipe it and rebuild:\n"
                f"rm -rf '{LLVM_BUILD}'")
        # Build made by the old per-platform scripts: adopt it, don't rebuild.
        log("patched llvm already built (adopting existing build), skipping rebuild.")
        STAMP.write_text(digest + "\n")
        build_test_tools()
        stage()
        return

    refuse_borrowed("its configure differs from this checkout's")
    if HOST == "Linux":  # only when we're about to configure, never on the skip path
        linux_preflight(env)

    if built:
        # Drop the cache: a -D removed from the arg list would otherwise stay
        # set in CMakeCache.txt forever. Objects are kept; ninja only rebuilds
        # what the new flags actually touch.
        log("configure args changed since last build; reconfiguring from a clean cache.")
        cache = LLVM_BUILD / "CMakeCache.txt"
        if cache.is_file():
            cache.unlink()
    else:
        banner()

    logfile = None
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    if HOST == "Windows":
        logfile = BUILD_DIR / "llvm-build.log"
        logfile.write_bytes(b"")
        log(f"configuring and building (streaming, tee to {logfile})...")
    else:
        log("configuring...")

    run([tools["cmake"], *cmake_args], env, logfile)
    log(f"building with {JOBS} jobs...")
    run([tools["ninja"], "-C", str(LLVM_BUILD), f"-j{JOBS}"], env, logfile)
    build_test_tools()

    STAMP.write_text(digest + "\n")
    if src_id is not None:
        SRC_STAMP.write_text(src_id + "\n")
    stage()
    log("done.")


if __name__ == "__main__":
    main()