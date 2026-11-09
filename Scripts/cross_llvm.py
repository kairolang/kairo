#!/usr/bin/env python3
"""Build the SHIPPING LLVM (clang + lld, our patched fork) for one target with kcc.

    python3 Scripts/cross_llvm.py x86_64-linux-musl
    python3 Scripts/cross_llvm.py x86_64-linux-musl --step llvm     # deps already built

Everything is compiled by our own kcc against our own vendored sysroot, so a shipped
tree depends on nothing from the build host: no host glibc floor, no Visual Studio, no
Homebrew. One Linux machine produces every target.

Output: build/cross-llvm/<triple>/
    deps/prefix/        zlib, zstd (static) and mimalloc (override object), built first
    llvm/               the LLVM build tree (static .a, ThinLTO bitcode)

Shipping profile (decided 2026-11-06: max optimization, generic CPU, mimalloc):
    -O3, ThinLTO, -march=<floor> (x86-64-v2 by default: every x86-64 CPU since ~2009),
    --gc-sections + --icf=safe, static, mimalloc replacing the libc allocator in every
    executable (musl's own malloc is the slow part of a static musl compiler).

Host tools: tablegen comes from the native build (build/llvm/bin), so no native sub-build
runs. Archives use llvm-ar from PATH (any LLVM >= ours reads our bitcode).

Every compile, C, C++ and assembly, goes through kcc (decided 2026-11-06: LLVM is always
built by kcc; kcc assembles in-process). The default kcc is the one beside the
compiler build.py uses (build/<host>/release/bin, else PATH): build.py --release never
rewrites that tree until its replacement has fully built (N-1 holds the backup).
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# One backend list for every LLVM we build: the host build and each cross host must
# agree, or a tree for one host refuses a --target another accepts.
from build_llvm import EXPERIMENTAL_TARGETS, TARGETS  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
HOST_TRIPLE = "x86_64-linux-gnu"
NATIVE_BIN = ROOT / "build" / "llvm" / "bin"

def find_kcc() -> Path:
    """The kcc that builds LLVM: the SEED's (build.py find_seed: build/<host>/N-1, else
    build/<host>/release, else PATH). Never a tree a running build rewrites:
    build.py --release keeps the last good compiler until the new one has fully built."""
    sys.path.insert(0, str(ROOT))
    import build
    kairo = build.find_seed(build.host_triple())
    kcc = kairo.parent / ("kcc" + build.EXE)
    if not kcc.exists():
        found = shutil.which("kcc")
        if not found:
            die(f"no kcc beside {kairo} and none on PATH; build one: python3 build.py kcc")
        kcc = Path(found)
    return kcc

# triple -> (CMAKE_SYSTEM_NAME, CMAKE_SYSTEM_PROCESSOR, CPU floor flags, unused)
#
# The floors are what a shipped binary may assume (decided 2026-11-06: generic, max
# optimized): x86-64-v2 (every x86-64 since ~2009), pentium4 for 32-bit x86 (SSE2),
# armv8-a, rv64gc, the sysroot's own armv7 hard-float default, apple-m1 for Apple
# silicon (every arm64 Mac).
#
# mimalloc needs nothing here: kcc links the Kairo runtime (Lib/rt, mimalloc inside) into
# every program it links, and on ELF that replaces malloc itself, so clang and lld get it
# like any kcc-built program; Windows keeps the CRT heap and Apple its malloc zones, the
# runtime's own policy (Lib/rt/mimalloc.c). A separate override object was a duplicate.
FAMILIES = {
    "x86_64-linux-musl":        ("Linux",   "x86_64",  ["-march=x86-64-v2"], True),
    "i686-linux-musl":          ("Linux",   "i686",    ["-march=pentium4", "-mtune=generic"], True),
    "aarch64-linux-musl":       ("Linux",   "aarch64", ["-march=armv8-a"], True),
    "armv7-linux-musl":         ("Linux",   "armv7",   [], True),
    "riscv64-linux-musl":       ("Linux",   "riscv64", ["-march=rv64gc"], True),
    "x86_64-windows-gnu":       ("Windows", "AMD64",   ["-march=x86-64-v2"], False),
    "i686-windows-gnu":         ("Windows", "X86",     ["-march=pentium4", "-mtune=generic"], False),
    "aarch64-windows-gnu":      ("Windows", "ARM64",   ["-march=armv8-a"], False),
    "armv7-windows-gnu":        ("Windows", "ARM",     [], False),
    "x86_64-unknown-freebsd":   ("FreeBSD", "amd64",   ["-march=x86-64-v2"], True),
    "aarch64-unknown-freebsd":  ("FreeBSD", "aarch64", ["-march=armv8-a"], True),
    "x86_64-unknown-netbsd":    ("NetBSD",  "x86_64",  ["-march=x86-64-v2"], True),
    "arm64-apple-macosx11.0":   ("Darwin",  "arm64",   ["-mcpu=apple-m1"], False),
    "x86_64-apple-macosx10.15": ("Darwin",  "x86_64",  ["-march=x86-64-v2"], False),
}


MUSL_THREAD_STACK = 8 << 20   # glibc's default; see write_toolchain


def log(msg: str) -> None:
    print(f"[cross-llvm] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[cross-llvm] error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(argv, cwd=None, logfile=None) -> None:
    log(" ".join(map(str, argv)) if len(argv) < 12 else f"{argv[0]} ... ({len(argv)} args)")
    if logfile:
        with open(logfile, "a") as f:
            r = subprocess.run(list(map(str, argv)), cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    else:
        r = subprocess.run(list(map(str, argv)), cwd=cwd)
    if r.returncode != 0:
        die(f"command failed ({r.returncode}){f'; log {logfile}' if logfile else ''}")


def write_toolchain(path: Path, triple: str, kcc: Path, cpu_flags: list, extra_exe_ld: str) -> None:
    system, proc, _, _ = FAMILIES[triple]
    ar = shutil.which("llvm-ar") or die("llvm-ar not on PATH")
    ranlib = shutil.which("llvm-ranlib") or die("llvm-ranlib not on PATH")
    cpu = " ".join(cpu_flags)
    flags = f"{cpu} -ffunction-sections -fdata-sections".strip()
    ld = "-Wl,--gc-sections -Wl,--icf=safe" if system != "Darwin" else "-Wl,-dead_strip"
    if system in ("Linux", "FreeBSD", "NetBSD"):
        ld += " -static"
    if system == "Linux":
        # musl gives a new thread 128 KiB of stack (glibc: 8 MiB), and LLVM runs its
        # ThinLTO backend and pass pipelines on pool threads that recurse deep (BasicAA's
        # aliasCheck/aliasPHI/aliasGEP chain): a static musl kcc SIGSEGVed linking lld.
        # musl takes its default thread stack size from PT_GNU_STACK, which this sets.
        ld += f" -Wl,-z,stack-size={MUSL_THREAD_STACK}"
    # ASM gets --target spelled out: CMake does not identify kcc as an assembler ("ASM
    # compiler identification is unknown"), so it never applies CMAKE_ASM_COMPILER_TARGET,
    # and the BLAKE3 .S files came out as the host's ELF in a Windows build.
    path.write_text(f"""# generated by Scripts/cross_llvm.py; do not edit
set(CMAKE_SYSTEM_NAME {system})
set(CMAKE_SYSTEM_PROCESSOR {proc})
set(CMAKE_C_COMPILER "{kcc}")
set(CMAKE_CXX_COMPILER "{kcc}")
set(CMAKE_ASM_COMPILER "{kcc}")
set(CMAKE_C_COMPILER_TARGET {triple})
set(CMAKE_CXX_COMPILER_TARGET {triple})
set(CMAKE_ASM_COMPILER_TARGET {triple})
set(CMAKE_ASM_FLAGS_INIT "--target={triple} {cpu}")
set(CMAKE_AR "{ar}")
set(CMAKE_RANLIB "{ranlib}")
set(CMAKE_C_FLAGS_INIT "{flags}")
set(CMAKE_CXX_FLAGS_INIT "{flags}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "{extra_exe_ld} {ld}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
""")


def cmake_build(src: Path, bld: Path, toolchain: Path, args: list, targets: list, jobs: int, logfile: Path) -> None:
    bld.mkdir(parents=True, exist_ok=True)
    # The compilers come from the toolchain file, which CMake reads only into an EMPTY
    # cache: a cache from an older toolchain (the native-clang assembler, a
    # different kcc) silently keeps its compilers. Reconfigure from scratch when the
    # toolchain or the args changed; objects stay, and ninja rebuilds what they touch.
    key = toolchain.read_text() + "\0" + "\0".join(map(str, args))
    stamp = bld / ".kairo-configure"
    cache = bld / "CMakeCache.txt"
    if cache.exists() and (not stamp.exists() or stamp.read_text() != key):
        log(f"{bld.name}: toolchain or args changed since the last configure: clearing the CMake cache")
        cache.unlink()
        shutil.rmtree(bld / "CMakeFiles", ignore_errors=True)
    run(["cmake", "-G", "Ninja", "-S", src, "-B", bld, f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
         "-DCMAKE_BUILD_TYPE=Release", *args], logfile=logfile)
    stamp.write_text(key)
    run(["ninja", "-C", bld, f"-j{jobs}", *targets], logfile=logfile)


def build_deps(triple: str, out: Path, kcc: Path, march: list, jobs: int) -> None:
    prefix = out / "deps" / "prefix"
    (prefix / "lib").mkdir(parents=True, exist_ok=True)
    (prefix / "include").mkdir(parents=True, exist_ok=True)
    tc = out / "deps" / "toolchain.cmake"
    write_toolchain(tc, triple, kcc, march, "")
    logf = out / "deps" / "deps.log"

    # zlib 1.3.1's CMake always adds a shared target, which a static-only sysroot (musl)
    # cannot link: build just the static archive and copy it out.
    z = out / "deps" / "zlib"
    cmake_build(ROOT / "Lib/third_party/zlib", z, tc, [], ["zlibstatic"], jobs, logf)
    # libz.a on Unix, libzlibstatic.a under MinGW (zlib names its static target per OS).
    built = [p for p in (z / "libz.a", z / "libzlibstatic.a") if p.exists()]
    if not built:
        die(f"zlib built no static archive in {z}")
    shutil.copy2(built[0], prefix / "lib" / "libz.a")
    for h in ("zlib.h",):
        shutil.copy2(ROOT / "Lib/third_party/zlib" / h, prefix / "include" / h)
    shutil.copy2(z / "zconf.h", prefix / "include" / "zconf.h")

    zs = out / "deps" / "zstd"
    cmake_build(ROOT / "Lib/third_party/zstd/build/cmake", zs, tc,
                [f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DZSTD_BUILD_SHARED=OFF", "-DZSTD_BUILD_STATIC=ON",
                 "-DZSTD_BUILD_PROGRAMS=OFF", "-DZSTD_BUILD_TESTS=OFF", "-DZSTD_BUILD_CONTRIB=OFF",
                 "-DZSTD_MULTITHREAD_SUPPORT=ON", "-DZSTD_LEGACY_SUPPORT=OFF"], ["install"], jobs, logf)

    log(f"deps ready in {prefix}")


def build_llvm(triple: str, out: Path, kcc: Path, march: list, jobs: int, link_jobs: int) -> None:
    system = FAMILIES[triple][0]
    prefix = out / "deps" / "prefix"
    if not (prefix / "lib" / "libzstd.a").exists():
        die("deps missing; run with --step deps first")
    bld = out / "llvm"
    tc = out / "llvm-toolchain.cmake"
    write_toolchain(tc, triple, kcc, march, "")
    lib = "lib"
    args = [
        "-DLLVM_ENABLE_PROJECTS=clang;lld",
        f"-DLLVM_TARGETS_TO_BUILD={TARGETS}",
        f"-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD={EXPERIMENTAL_TARGETS}",
        f"-DLLVM_HOST_TRIPLE={triple}",
        f"-DLLVM_DEFAULT_TARGET_TRIPLE={triple}",
        "-DLLVM_ENABLE_RTTI=ON", "-DLLVM_ENABLE_EH=ON",
        "-DLLVM_INCLUDE_TESTS=OFF", "-DLLVM_INCLUDE_EXAMPLES=OFF", "-DLLVM_INCLUDE_BENCHMARKS=OFF",
        "-DLLVM_BUILD_TOOLS=OFF", "-DCLANG_BUILD_TOOLS=OFF", "-DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF",
        "-DLLVM_ENABLE_BINDINGS=OFF",
        "-DLLVM_BUILD_LLVM_DYLIB=OFF", "-DLLVM_LINK_LLVM_DYLIB=OFF", "-DBUILD_SHARED_LIBS=OFF",
        "-DLIBCLANG_BUILD_STATIC=ON",
        "-DLLVM_ENABLE_LTO=Thin", "-DLLVM_USE_LINKER=lld",
        f"-DLLVM_PARALLEL_LINK_JOBS={link_jobs}",
        # host tools from the native build: no NATIVE sub-build
        f"-DLLVM_NATIVE_TOOL_DIR={NATIVE_BIN}",
        f"-DLLVM_TABLEGEN={NATIVE_BIN / 'llvm-tblgen'}",
        f"-DCLANG_TABLEGEN={NATIVE_BIN / 'clang-tblgen'}",
        "-DLLVM_ENABLE_ZLIB=FORCE_ON", "-DLLVM_ENABLE_ZSTD=FORCE_ON", "-DLLVM_USE_STATIC_ZSTD=ON",
        f"-DZLIB_INCLUDE_DIR={prefix / 'include'}", f"-DZLIB_LIBRARY={prefix / lib / 'libz.a'}",
        f"-Dzstd_INCLUDE_DIR={prefix / 'include'}", f"-Dzstd_LIBRARY={prefix / lib / 'libzstd.a'}",
        f"-Dzstd_STATIC_LIBRARY={prefix / lib / 'libzstd.a'}",
        f"-DCMAKE_FIND_ROOT_PATH={prefix}",
        "-DLLVM_ENABLE_LIBXML2=OFF", "-DLLVM_ENABLE_LIBEDIT=OFF", "-DLLVM_ENABLE_LIBPFM=OFF",
        "-DLLVM_ENABLE_FFI=OFF", "-DLLVM_ENABLE_CURL=OFF", "-DLLVM_ENABLE_HTTPLIB=OFF",
        "-DLLVM_ENABLE_TERMINFO=OFF",
    ]
    if system in ("Linux", "Windows", "FreeBSD", "NetBSD"):
        # Fully static executables; Apple has no static libSystem, and needs PIC.
        args += ["-DLLVM_BUILD_STATIC=ON", "-DLLVM_ENABLE_PIC=OFF"]
    if system == "Darwin":
        ver = triple.split("macosx", 1)[1]
        args += [f"-DCMAKE_OSX_DEPLOYMENT_TARGET={ver}", f"-DCMAKE_OSX_ARCHITECTURES={FAMILIES[triple][1]}"]
        # Plugin support exports the executables' symbols, which LLVM spells
        # --export-dynamic once it sees an lld linker; ld64.lld only knows -export_dynamic
        # ("unknown argument", the clang-22 link). A static LLVM loads no plugins anyway.
        args += ["-DLLVM_ENABLE_PLUGINS=OFF", "-DCLANG_PLUGIN_SUPPORT=OFF"]
        # lli's child target links with -rdynamic, which kcc still spells as ELF's
        # --export-dynamic for ld64; the toolchain ships no lli.
        args += ["-DLLVM_TOOL_LLI_BUILD=OFF"]
    if system in ("Darwin", "Windows"):
        # libLTO / libRemarks are shared libraries a static toolchain never loads, and kcc
        # does not yet take Apple's -dynamiclib: libLTO.dylib linked as an
        # executable ("undefined symbol: main").
        args += ["-DLLVM_TOOL_LTO_BUILD=OFF", "-DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF"]
    # CLANG_BUILD_TOOLS=OFF leaves the clang driver out of `all`; the staged tree ships it,
    # the two tools the tests use (build_llvm.py's TEST_TOOLS) and llvm-ar, so a tree can
    # archive with its own tools.
    cmake_build(ROOT / "Lib/llvm-runtimes/llvm", bld, tc, args,
                ["all", "clang", "llvm-nm", "llvm-objdump", "llvm-ar"], jobs, out / "llvm.log")
    log(f"llvm ready in {bld}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("triple", choices=sorted(FAMILIES))
    ap.add_argument("triples", nargs="*", help="more triples, built in order after the first")
    ap.add_argument("--kcc", help="the kcc that compiles everything (default: beside build.py's compiler, "
                                  "build/<host>/release/bin, else PATH)")
    ap.add_argument("--march", help="override the CPU floor flags, e.g. '-march=x86-64-v3'")
    ap.add_argument("--step", choices=["all", "deps", "llvm"], default="all")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 8,
                    help="the TOTAL job budget; with --parallel N each build gets jobs/N")
    ap.add_argument("--link-jobs", type=int, default=None,
                    help="concurrent links per build (default 2, or 1 with --parallel > 1); each "
                         "ThinLTO link is itself multi-threaded and large")
    ap.add_argument("--parallel", type=int, default=3, metavar="N",
                    help="build up to N triples at once, splitting -j between them (default 3); "
                         "1 builds them in order, as before")
    ap.add_argument("--log-dir", default=str(ROOT / "build" / "cross-llvm" / "logs"),
                    help="with --parallel > 1: one <triple>.log per build here")
    a = ap.parse_args()
    real = Path(os.path.abspath(a.kcc)) if a.kcc else Path(os.path.abspath(find_kcc()))
    if not real.exists():
        die(f"no kcc at {real}")
    # CMake bakes the compiler path into the configure (and cmake_build's stamp), so a
    # seed that moved (N-1 one run, release the next) would rebuild all of LLVM. Every
    # build goes through one fixed link instead, repointed at whichever kcc this run
    # uses; kcc finds its tree from the real binary, not the link.
    kcc = ROOT / "build" / "cross-llvm" / ".kcc"
    kcc.parent.mkdir(parents=True, exist_ok=True)
    if not (kcc.is_symlink() and os.readlink(kcc) == str(real)):
        if kcc.is_symlink() or kcc.exists():
            kcc.unlink()
        kcc.symlink_to(real)
    log(f"kcc: {real}")
    triples = list(dict.fromkeys([a.triple] + a.triples))
    for t in triples:
        if t not in FAMILIES:
            die(f"unknown triple {t} (known: {', '.join(FAMILIES)})")
    n = max(1, min(a.parallel, len(triples)))
    if n > 1:
        run_parallel(triples, n, a, real)
        return
    link_jobs = a.link_jobs if a.link_jobs is not None else 2
    for t in triples:
        march = a.march.split() if a.march else FAMILIES[t][2]
        out = ROOT / "build" / "cross-llvm" / t
        out.mkdir(parents=True, exist_ok=True)
        log(f"{t}: kcc {kcc}, floor {' '.join(march) or '(sysroot default)'}, -j{a.jobs}, link jobs {link_jobs}")
        if a.step in ("all", "deps"):
            build_deps(t, out, kcc, march, a.jobs)
        if a.step in ("all", "llvm"):
            build_llvm(t, out, kcc, march, a.jobs, link_jobs)


def run_parallel(triples: list, n: int, a, kcc: Path) -> None:
    """N builds at once, each a child run of this script for one triple with jobs/N
    compile jobs. The budget is split, not multiplied: three -j24 ninjas on 24 threads
    thrash, and three ThinLTO links at full width are what exhausts RAM. Links default
    to one per build here for the same reason. Each child writes its own log, so a
    failure names its triple and the others keep going; the run fails at the end if
    any did."""
    jobs = max(1, a.jobs // n)
    link_jobs = a.link_jobs if a.link_jobs is not None else 1
    logs = Path(a.log_dir)
    logs.mkdir(parents=True, exist_ok=True)
    log(f"{len(triples)} builds, {n} at a time, -j{jobs} and {link_jobs} link job(s) each; logs in {logs}")

    def one(t: str):
        argv = [sys.executable, str(Path(__file__).resolve()), t, "--parallel", "1", "--kcc", str(kcc),
                "--step", a.step, "-j", str(jobs), "--link-jobs", str(link_jobs)]
        if a.march:
            argv.append(f"--march={a.march}")
        logfile = logs / f"{t}.log"
        log(f"{t}: started (log {logfile})")
        t0 = time.monotonic()
        with open(logfile, "w") as f:
            rc = subprocess.run(argv, stdout=f, stderr=subprocess.STDOUT).returncode
        secs = time.monotonic() - t0
        log(f"{t}: {'done' if rc == 0 else f'FAILED ({rc})'} in {secs / 60:.1f} min")
        return t, rc, secs

    with ThreadPoolExecutor(max_workers=n) as pool:
        results = list(pool.map(one, triples))
    log("summary:")
    for t, rc, secs in results:
        log(f"  {t:28} {'ok' if rc == 0 else f'FAILED ({rc})':12} {secs / 60:6.1f} min")
    failed = [t for t, rc, _ in results if rc != 0]
    if failed:
        die(f"{len(failed)} build(s) failed: {', '.join(failed)} (logs in {logs})")


if __name__ == "__main__":
    main()
