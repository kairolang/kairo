#!/usr/bin/env python3
"""Stage 1 build of the Kairo toolchain, the stop-gap for kbld.

The repo is self-hosted: Compiler/ is Stage 1.5 source and the last good release
compiler builds it.

    python3 build.py --release kairo kcc   # N-1 -> staging -> release, then PATH (the gate)
    python3 build.py --debug kairo kcc     # debug profile (the edit/test loop)

    Source              Output                                Registry object
    the repo            build/<triple>/<mode>                 compiled here from build/registry, which
                                                              gen_diag.py writes (Stage 1) on every build

    python3 build.py --print-jobs          # show the clang jobs and the link, build nothing

This is build.k's logic restated for a Stage 1 compiler. kbld (Extras/BuildTool) drives
Stage 0 and is not ported to Stage 1 yet, and won't be for a while; until it is, this
script is the build of record once Stage 1 self-hosts. Keep it in step with build.k: same
targets, same prebuild/postbuild hooks, same toolchain linkage invariant.

TOOLCHAIN LINKAGE INVARIANT, as in build.k, do not violate:
  Linux/macOS : shared (libLLVM.so / .dylib), one copy in lib/, thin bins.
  Windows     : static (.lib), forced; libLLVM.dll is unsupported there.
  No system-LLVM fallback on any platform: we link the patched fork (custom Clang
  PP-token injection); system LLVM lacks the patch. Absence is a hard error.

Stage 0 and Stage 1 flags are NOT the same, and where a Stage 0 flag has no Stage 1
counterpart this script says so instead of guessing (see STAGE1_GAPS):
  - Stage 0 passed clang words for the WHOLE build (one transpiled TU). Stage 1's
    --cxx-flags reach only C/C++ inputs (here, the generated *_meta.cpp); Kairo's own
    codegen never sees them. So -fvisibility=hidden, the deterministic-FP set
    (-fno-fast-math, -ffp-contract=off, ...), -Xclang -vectorize-* and
    -gline-tables-only have no Stage 1 spelling yet.
  - -D defines a KAIRO macro only; a C++ macro (VERSION, DEBUG, NDEBUG, NOMINMAX) is
    --cxx-define. Debug builds pass DEBUG to both, as Compiler/Spec/BuildSystem.md#compile-line does.
  - Stage 1 always links with its bundled lld (-fuse-ld=lld is implied), has no -w
    (warnings stay on), and --lto is unimplemented (objects are not bitcode).
  - Include roots: Stage 1 module identity depends on the -I set, so every tool gets
    the SAME roots; `-I .` and the lib-helix core are gone (Compiler/Spec/SelfHosting.md#pre-migration-audits).

Portable: Linux, macOS, Windows. No shell; subprocess with argument lists only.
"""
import argparse, datetime, hashlib, os, platform, re, shlex, shutil, subprocess, sys, threading, time
from pathlib import Path

try:  # a pty for the compiler's stderr (POSIX); elsewhere its events are re-drawn
    import fcntl, pty, termios, tty
    _HAVE_PTY = True
except ImportError:
    _HAVE_PTY = False

ROOT = Path(__file__).resolve().parent
EXE = ".exe" if os.name == "nt" else ""
# The full registry source (declarations + bodies, one module), written by gen_diag.py on
# every build from Compiler/Diagnostic/TableGen; never committed.
REGISTRY_DIR = ROOT / "build" / "registry"
# The repo's own Compiler/ + Linker/ are the self-hosted (Stage 1 syntax) tree since the
# switch-over (2026-11-06); kbld (Stage 0) can no longer build it. This used to be read from
# a `.selfhosted` marker file, which was easy to lose and made a fresh clone refuse to build.
REPO_SELFHOSTED = True

# What Stage 1 cannot express yet, printed with --explain-gaps so nobody wonders
# why a build.k flag is missing below.
STAGE1_GAPS = [
    ("-fvisibility=hidden / -fvisibility-inlines-hidden", "no flag reaches Kairo codegen; --cxx-flags is C/C++ inputs only"),
    ("-fno-fast-math -fno-approx-func -ffp-contract=off -fno-associative-math -fno-rounding-math",
     "same: Kairo's own FP semantics apply; check they match before relying on bit-identical FP"),
    ("-Xclang -vectorize-loops / -vectorize-slp", "same"),
    ("-gline-tables-only (release)", "Stage 1 has -g (full DWARF) only"),
    ("-flto, --lto-partitions, /opt:lldlto*", "--lto is unimplemented in Stage 1"),
    ("-Wl,--no-export-dynamic", "Stage 1 does not pass -rdynamic, so there is nothing to undo"),
    ("--reproducible: prebuild's registry.o and the clang jobs' own -frandom-seed",
     "registry.o is shared (build/.kbld) and produced by gen_diag.py: not remapped or checked; "
     "kairo has no -frandom-seed spelling, so anonymous-namespace/local-symbol naming relies on clang's default (content-derived)"),
    ("-w", "dropped on purpose (Compiler/Spec/BuildSystem.md#compile-line): warnings stay on"),
    ("-fsanitize=undefined,bounds,function (debug)", "-fsanitize-ub is accepted but unimplemented (U005W); opt in with --sanitize-ub"),
]


def die(msg: str) -> "NoReturn":
    print(f"build.py: error: {msg}", file=sys.stderr)
    sys.exit(1)


def say(msg: str) -> None:
    print(f"[build] {msg}", flush=True)


# --- host -------------------------------------------------------------------

def host_os() -> str:
    s = platform.system()
    if s == "Linux":
        return "linux"
    if s == "Darwin":
        return "macos"
    if s == "Windows":
        return "windows"
    die(f"unsupported host OS '{s}'")


def host_arch() -> str:
    a = platform.machine().lower()
    if a in ("x86_64", "amd64"):
        return "x86_64"
    if a in ("aarch64", "arm64"):
        return "aarch64"
    die(f"unsupported host architecture '{a}'")


def host_triple() -> str:
    """The build/<triple> directory name, exactly as stage_tree.py / build_llvm.py
    spell it (KBLD_TRIPLE overrides, as there)."""
    t = os.environ.get("KBLD_TRIPLE")
    if t:
        return t
    os_ = host_os()
    if os_ == "linux":
        return f"{host_arch()}-linux-gnu"
    if os_ == "macos":
        return ("arm64" if host_arch() == "aarch64" else "x86_64") + "-apple-macosx"
    return f"{host_arch()}-windows-msvc"


# --- version / metadata ------------------------------------------------------

# The toolchain's version, one number for every binary (decided 2026-11-06: Stage 1.5 is
# v0.2.0). Builds carry +dev.<date>; a release build drops it.
KAIRO_VERSION = "0.2.1"
DEV = f"-{KAIRO_VERSION}+dev"


def version(target: str, suffix: str, epoch=None) -> str:
    """build.k version(): a +dev / +rc suffix gets the build date. Under --reproducible
    the date comes from the source epoch, never from today."""
    date = ""
    if "+rc" in suffix or "+dev" in suffix:
        day = datetime.date.today() if epoch is None else \
            datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).date()
        date = day.strftime(".%Y%m%d")
    return f"{target}{suffix}{date}"


PROJECT = {
    "name": "Kairo",
    "version": f"kairo-{KAIRO_VERSION}",
    "author": "Dhruvan, Ojas and Arnav",
    "license": "CC-BY-4.0",
}


_RUNTIMES_REV = None


def runtimes_revision() -> str:
    """The LLVM fork revision the runtimes come from, exactly as
    Scripts/package_release.py writes it to share/kairo/runtimes/REVISION (one
    function, imported, so the two can never spell it differently). Embedded in
    every tool (`kairo --print-runtimes-revision`, `ksys --print-runtimes-revision`):
    ksys refuses a share tree whose REVISION differs. "unknown" without the
    Lib/llvm-runtimes checkout or git."""
    global _RUNTIMES_REV
    if _RUNTIMES_REV is None:
        try:
            import package_release
            _RUNTIMES_REV = package_release.runtimes_revision()
        except Exception:
            _RUNTIMES_REV = "unknown"
    return _RUNTIMES_REV


def write_meta(gen_dir: Path, name: str, os_: str, epoch=None, ver: str = None) -> Path:
    """The *_meta.cpp kbld generates: one string in a named section, read back by
    tooling. Section syntax is per object format (ELF / Mach-O / COFF).

    With `ver` it also defines kairo_version_cstr(), the tool's version string, which
    Native/KShims.hh's version_string() returns under -D KAIRO_VERSION_EXTERN. The version
    used to be a `-D VERSION="kcc+dev.<date>"` on every TU: a cc1 word, so in every
    object key (Compiler/Spec/Incremental.md), and it differs per tool and per day, so
    no two tools (and no two days) could share a cached object. Here it is in the one
    per-tool object that is never cached."""
    when = datetime.datetime.now(datetime.timezone.utc) if epoch is None else \
        datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    built = when.strftime("%Y-%m-%dT%H:%M:%SZ")
    meta = "|".join(f"{k}={v}" for k, v in PROJECT.items()) + f"|built={built}"
    meta = meta.replace("\\", "\\\\").replace('"', '\\"')
    if os_ == "macos":
        attr = '__attribute__((section("__DATA,__build_meta"), used))'
    elif os_ == "windows":
        attr = '#pragma section(".build_meta", read)\n__declspec(allocate(".build_meta"))'
    else:
        attr = '__attribute__((section(".build_meta"), used))'
    gen_dir.mkdir(parents=True, exist_ok=True)
    p = gen_dir / f"{name}_meta.cpp"
    body = f'{attr}\nstatic const char kBuildMeta[] = "{meta}";\n'
    if os_ == "windows":
        # MSVC/clang-cl drops an unreferenced static; keep it like `used` does.
        body += "extern \"C\" const char* kairo_build_meta() { return kBuildMeta; }\n"
    if ver is not None:
        lit = ver.replace("\\", "\\\\").replace('"', '\\"')
        body += f'extern "C" const char *kairo_version_cstr() noexcept {{ return "{lit}"; }}\n'
        rev = runtimes_revision().replace("\\", "\\\\").replace('"', '\\"')
        body += f'extern "C" const char *kairo_runtimes_revision_cstr() noexcept {{ return "{rev}"; }}\n'
    if not p.exists() or p.read_text() != body:
        p.write_text(body)
    return p


# --- targets (build.k main()) -------------------------------------------------

# name -> (entry, version string target, version suffix, extra include roots).
# Every tool gets the same Stage 1 roots: Compiler and Linker. KaTAR and kfmt
# add their own root. Tools whose sources are outside the self-host scope
# (Extras/BuildTool, PackageManager, Analyzer) are listed so the table matches build.k,
# but refused until their trees are migrated.
STAGE1_ROOTS = ["Compiler", "Linker"]
TARGETS = {
    "kairo":               ("Compiler/Driver/Kairo.k",                "kairo",  DEV, []),
    "kcc":                 ("Compiler/Driver/Kcc.k",                  "kcc",    DEV, []),
    "kld":                 ("Linker/Driver/kld.k",                    "kld",    DEV, []),
    "kparse":              ("Compiler/Tooling/ParseOnceTest.k",       "kairo",  DEV, []),
    "katar":               ("Extras/KaTAR/KTCompress.k",              "kairo",  DEV, ["Extras/KaTAR"]),
    "kfmt":                ("Extras/Formatter/Driver/kfmt.k",         "kairo",  DEV, ["Extras/Formatter"]),
    "ksys":                ("Linker/Sysroot/Driver/ksys.k",           "ksys",   DEV, []),
    "clang-diag-identity": ("Compiler/Tooling/GenClangDiagIdentity.k", "kairo", DEV, []),
}
NOT_MIGRATED = {
    "kbld": "Extras/BuildTool",
    "kals": "Analyzer", "kpkg": "Extras/PackageManager",
}
# build.k stages the tree after these (post_build). kld, kfmt and ksys ship in the staged tree
# beside kairo and kcc, so a build of it alone stages too.
STAGED = {"kairo", "kcc", "kld", "kfmt", "ksys"}


# --- LLVM linkage (build.k llvm_static_components / clang_static_components) -

LLVM_STATIC_CORE = "Core Support Demangle Target TargetParser".split()
LLVM_STATIC = """
CodeGen CodeGenTypes AsmPrinter SelectionDAG GlobalISel MCA
ScalarOpts InstCombine AggressiveInstCombine TransformUtils Vectorize SandboxIR
Analysis ProfileData ipo Passes Plugins Linker CGData
IRReader IRPrinter AsmParser BitReader BitWriter BitstreamReader
MC MCParser MCDisassembler Object ObjectYAML BinaryFormat InterfaceStub
ExecutionEngine Interpreter MCJIT JITLink OrcJIT OrcDebugging OrcShared OrcTargetProcess RuntimeDyld
Remarks TextAPI TextAPIBinaryReader Option Coroutines Instrumentation WindowsDriver WindowsManifest
FrontendOpenMP FrontendOffloading FrontendOpenACC FrontendHLSL FrontendAtomic FrontendDirective FrontendDriver
LTO DTLTO CFGuard ObjCARCOpts HipStdPar Extensions
DebugInfoDWARF DebugInfoDWARFLowLevel DebugInfoCodeView DebugInfoMSF DebugInfoPDB DebugInfoGSYM
DebugInfoLogicalView DebugInfoBTF Debuginfod DWP DWARFLinker DWARFLinkerClassic DWARFLinkerParallel
DWARFCFIChecker Symbolize Coverage
ObjCopy XRay DlltoolDriver LibDriver CFIVerify Diff Exegesis ExegesisX86 ExegesisAArch64 ExegesisRISCV
OptDriver FuzzMutate FuzzerCLI FileCheck LineEditor Telemetry MIRParser ABI
""".split()
CLANG_STATIC = """
Basic Driver Options Frontend FrontendTool RewriteFrontend
CodeGen Sema Analysis AnalysisFlowSensitive AnalysisFlowSensitiveModels AnalysisLifetimeSafety AnalysisScalable
AST ASTMatchers DynamicASTMatchers Parse Lex Edit Rewrite APINotes
Serialization CrossTU Index IndexSerialization InstallAPI ExtractAPI
StaticAnalyzerCore StaticAnalyzerCheckers StaticAnalyzerFrontend
Format ToolingCore ToolingInclusions ToolingInclusionsStdlib ToolingRefactoring ToolingASTDiff
ToolingSyntax Transformer Tooling DependencyScanning DirectoryWatcher Support
""".split()
# Every component library a backend can have (lib/Target/<T>/**/CMakeLists.txt): not every
# backend has every one (NVPTX and SPIRV have no AsmParser or Disassembler; Utils,
# TargetMCA and SPIRV's Analysis are per target).
TARGET_COMPONENTS = ["CodeGen", "AsmParser", "Desc", "Disassembler", "Info", "Utils", "TargetMCA", "Analysis"]


def llvm_static_libs(llvm_build: Path) -> list:
    """The LLVM archives a static link names: the core, each built backend's components,
    then the rest. The backends are read from the build's own Targets.def, the list
    InitializeAllTargets() and friends expand at compile time, so a link names exactly the
    backends its headers register (Scripts/build_llvm.py TARGETS, or LLVM_TARGETS for a
    narrower build): a hardcoded list left every backend added to the build an undefined
    LLVMInitialize<T>* on the static (Windows, cross) links. A component the backend does
    not have is skipped by its absence from lib/."""
    defs = llvm_build / "include" / "llvm" / "Config" / "Targets.def"
    if not defs.is_file():
        die(f"{defs} is missing; is {llvm_build} a configured LLVM build?")
    lib = llvm_build / "lib"
    targets = re.findall(r"^LLVM_TARGET\((\w+)\)", defs.read_text(), re.M)
    have = {f.name for f in lib.iterdir()} if lib.is_dir() else set()
    out = []
    for t in targets:
        for c in TARGET_COMPONENTS:
            n = f"LLVM{t}{c}"
            if f"lib{n}.a" in have or f"{n}.lib" in have:
                out.append(f"{t}{c}")
    return LLVM_STATIC_CORE + out + LLVM_STATIC


WINDOWS_SYSTEM_LIBS = ["version", "advapi32", "shell32", "ole32", "uuid", "ntdll",
                       "ws2_32", "psapi", "onecore", "zstd", "zlib"]
# LLD is not in llvm-config: a fixed bundle (the lldCommon <-> flavor cycle is the
# driver's to group).
LLD_LIBS = ["lldCommon", "lldELF", "lldCOFF", "lldMinGW", "lldMachO", "lldWasm"]


def llvm_args(llvm_src: Path, llvm_build: Path, out_lib: Path, os_: str) -> list:
    if not (llvm_build / "include").is_dir():
        die(f"vendored LLVM not found at {llvm_build}. The patched llvm-project fork is "
            "REQUIRED; there is no system fallback. Run Scripts/build_llvm.py, or "
            "`git submodule update --init --recursive Lib/llvm-runtimes`.")
    a = []
    for inc in (llvm_build / "include", llvm_src / "llvm" / "include", llvm_src / "lld" / "include",
                llvm_src / "clang" / "include", llvm_build / "tools" / "clang" / "include"):
        a += ["--cxx-include", str(inc)]
    a += ["-L", str(llvm_build / "lib"), "-L", str(out_lib)]
    a += ["--cxx-flags=-Wno-parentheses-equality", "--cxx-flags=-Werror=return-type"]
    for l in LLD_LIBS:
        a += ["-l", l]
    if os_ == "windows":
        # STATIC: libLLVM.dll is unsupported on Windows (invariant).
        for d in ("NOMINMAX", "CLANG_BUILD_STATIC", "LLVM_BUILD_STATIC"):
            a += ["--cxx-define", d]
        for l in CLANG_STATIC:
            a += ["-l", f"static:clang{l}"]
        for l in llvm_static_libs(llvm_build):
            a += ["-l", f"static:LLVM{l}"]
        for l in WINDOWS_SYSTEM_LIBS:
            a += ["-l", l]
    else:
        # SHARED: one libLLVM, thin bins (invariant).
        a += ["-l", "clang-cpp", "-l", "LLVM", "-l", "zstd", "-l", "z"]
    return a


# --- cross targets (Scripts/cross_llvm.py) -------------------------------------
#
# A shipping tree for another target, built on this host: the target's LLVM comes from
# Scripts/cross_llvm.py (kcc + our sysroot, static, ThinLTO, mimalloc), never from
# build/llvm. Linkage is STATIC on every cross target: there is no libLLVM.so to ship
# beside a static musl binary, and Windows is static anyway (invariant above).
# Every cross target, with its CPU floor, is Scripts/cross_llvm.py's FAMILIES: one table,
# so the LLVM a tree links and the tree itself always agree on the floor.
sys.path.insert(0, str(ROOT / "Scripts"))
import cross_llvm  # noqa: E402

CROSS = {t: ({"Linux": "linux", "Windows": "windows", "Darwin": "macos", "FreeBSD": "freebsd", "NetBSD": "netbsd"}[f[0]], f[2])
         for t, f in cross_llvm.FAMILIES.items()}
# A MinGW link names the Win32 libraries LLVM uses itself (no MSVC autolink pragmas).
MINGW_SYSTEM_LIBS = ["version", "advapi32", "shell32", "ole32", "uuid", "ntdll", "ws2_32", "psapi"]


def floor_args(flags: list) -> list:
    """cross_llvm.py's clang-spelled CPU floor as kairo flags (it compiles C++ inputs and
    Kairo code alike with them)."""
    out = []
    for f in flags:
        for clang, kairo in (("-march=", "--march"), ("-mcpu=", "--mcpu"), ("-mtune=", "--mtune")):
            if f.startswith(clang):
                out += [kairo, f[len(clang):]]
    return out


def target_exe(target) -> str:
    if target:
        return ".exe" if CROSS[target][0] == "windows" else ""
    return EXE


def llvm_include_args(llvm_src: Path, llvm_build: Path) -> list:
    """The fork's headers. The registry needs them too (Native/Types.hh includes
    llvm/ADT/StringRef.h): without them a native build silently found the HOST's
    /usr/include/llvm (another LLVM version), and a cross build found none."""
    a = []
    for inc in (llvm_build / "include", llvm_src / "llvm" / "include", llvm_src / "lld" / "include",
                llvm_src / "clang" / "include", llvm_build / "tools" / "clang" / "include"):
        a += ["--cxx-include", str(inc)]
    return a


def cross_dir(target: str) -> Path:
    return ROOT / "build" / "cross-llvm" / target


def cross_llvm_args(llvm_src: Path, target: str) -> list:
    llvm_build = cross_dir(target) / "llvm"
    deps = cross_dir(target) / "deps" / "prefix"
    if not (llvm_build / "lib" / "libLLVMCore.a").exists():
        die(f"no cross LLVM for {target} at {llvm_build}; run python3 Scripts/cross_llvm.py {target}")
    tos, floor = CROSS[target]
    a = []
    for inc in (llvm_build / "include", llvm_src / "llvm" / "include", llvm_src / "lld" / "include",
                llvm_src / "clang" / "include", llvm_build / "tools" / "clang" / "include"):
        a += ["--cxx-include", str(inc)]
    a += ["-L", str(llvm_build / "lib"), "-L", str(deps / "lib")]
    a += ["--cxx-flags=-Wno-parentheses-equality", "--cxx-flags=-Werror=return-type"]
    for d in ("CLANG_BUILD_STATIC", "LLVM_BUILD_STATIC"):
        a += ["--cxx-define", d]
    for l in LLD_LIBS:
        a += ["-l", f"static:{l}"]
    for l in CLANG_STATIC:
        a += ["-l", f"static:clang{l}"]
    for l in llvm_static_libs(llvm_build):
        a += ["-l", f"static:LLVM{l}"]
    a += ["-l", "static:zstd", "-l", "static:z"]
    if tos == "linux":
        # musl's default thread stack is 128 KiB; the compiler's pools and the LLVM in
        # it recurse far deeper (cross_llvm.write_toolchain has the crash). PT_GNU_STACK
        # sets musl's default; this is glibc's 8 MiB.
        a += [f"--ld-flags=-zstack-size={cross_llvm.MUSL_THREAD_STACK}"]
    if tos == "windows":
        for l in MINGW_SYSTEM_LIBS:
            a += ["-l", l]
    # No mimalloc object here: the Kairo runtime (Lib/rt/mimalloc.c) already is mimalloc
    # and replaces malloc on ELF, so a Kairo binary has it; a second copy is duplicate
    # symbols. cross_llvm.py links one into the LLVM tools (clang, lld), which are not Kairo.
    a += ["--target", target, *floor_args(floor)]
    return a


def shared_libcxx_args(os_: str, native: bool) -> list:
    """Under --native the driver links the bundled libc++.a / libc++abi.a by path,
    but libLLVM.so / libclang-cpp.so need the shared libc++.so.1 (the one the vendored
    LLVM was linked against, which stage_tree.py bundles into lib/). Two copies in one
    process throw std::bad_cast from ios_base::Init before main. Naming the shared
    libraries first, as user libraries, resolves every libc++ symbol from them, so the
    linker pulls no member out of the archives that follow."""
    if os_ == "linux" and native:
        return ["-l", "c++", "-l", "c++abi"]
    return []


# --- platform glue (build.k platform_glue / windows_sdk_paths / host_sysroot_glue)

def windows_sdk_args() -> list:
    """Host-toolchain probing for the MSVC link (NOT LLVM linkage)."""
    a = ["--ld-flags=/nodefaultlib:libcmt"]
    sdk_root = None
    try:
        import winreg  # Windows only
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                            r"SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots") as k:
            sdk_root = Path(winreg.QueryValueEx(k, "KitsRoot10")[0]) / "Lib"
    except OSError:
        pass
    if sdk_root is None or not sdk_root.is_dir():
        sdk_root = Path("C:/Program Files (x86)/Windows Kits/10/Lib")
    sdks = sorted(p.name for p in sdk_root.iterdir() if p.is_dir() and p.name.startswith("10.")) \
        if sdk_root.is_dir() else []
    if not sdks:
        die(f"no Windows SDK found in {sdk_root}; install the Windows 10/11 SDK")
    base = sdk_root / sdks[-1]
    a += [f"--ld-flags=/libpath:{base / 'ucrt' / 'x64'}", f"--ld-flags=/libpath:{base / 'um' / 'x64'}"]
    vswhere = Path("C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe")
    if vswhere.exists():
        r = subprocess.run([str(vswhere), "-latest", "-products", "*", "-requires",
                            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                            "-property", "installationPath"], capture_output=True, text=True)
        vs = Path(r.stdout.strip()) if r.stdout.strip() else None
        tools = vs / "VC" / "Tools" / "MSVC" if vs else None
        if tools and tools.is_dir():
            vers = sorted(p.name for p in tools.iterdir() if p.is_dir())
            if vers:
                a.append(f"--ld-flags=/libpath:{tools / vers[-1] / 'lib' / 'x64'}")
    return a


def host_sysroot_args() -> list:
    """Opt-in: KAIRO_HOST_SYSROOT names an old-glibc sysroot (Scripts/host_sysroot.py)
    so the shipped binaries need that glibc, not the build host's. Only valid if LLVM
    was configured against the same sysroot (build_llvm.py reads the same variable)."""
    if not os.environ.get("KAIRO_HOST_SYSROOT"):
        return []
    script = str(ROOT / "Scripts" / "host_sysroot.py")
    run_or_die([sys.executable, script, "--check"])
    cflags = run_or_die([sys.executable, script, "--cflags"]).split()
    ldflags = run_or_die([sys.executable, script, "--ldflags"]).split()
    # Stage 0 passed both straight to clang. In Stage 1 the compile side reaches
    # C/C++ inputs and ffi headers through --cxx-flags; the link side is lld's.
    return [f"--cxx-flags={f}" for f in cflags] + [f"--ld-flags={f}" for f in ldflags]


def platform_args(os_: str) -> list:
    if os_ == "linux":
        return ["--rpath", "$ORIGIN/../lib"] + host_sysroot_args()
    if os_ == "macos":
        return ["--rpath", "@loader_path/../lib"]
    return windows_sdk_args()


# --- profile (build.k optimize) ---------------------------------------------

def profile_args(debug: bool, sanitize_ub: bool) -> list:
    if debug:
        # Compiler/Spec/BuildSystem.md#compile-line. DEBUG for Kairo source (-D) and for C++ (--cxx-define).
        # KAIRO_LLVM_DUMP_UNUSED: the merged codegen PCH drops `used` from clang's
        # LLVM_DUMP_METHOD functions, so no TU IRGens them unasked (CodegenPCH.k).
        a = ["--profile", "debug", "-O0", "-g", "--debug-macros",
             "-D", "DEBUG", "--cxx-define", "DEBUG", "--cxx-define", "KAIRO_LLVM_DUMP_UNUSED"]
        if sanitize_ub:
            a += ["-fsanitize-ub"]
        return a
    # -O3 as build.k; ICF is on by default above -O0 in Stage 1. --strip-debug: Kairo emits
    # no -g here, but the sysroot's prebuilt archives (musl libc.a, libc++/libc++abi) carry
    # DWARF, and without it every release binary shipped ~6 MB of their debug sections.
    # Symbols stay, so backtraces still name functions.
    return ["--profile", "release", "-O3", "--cxx-define", "NDEBUG", "--strip-debug"]


# --- hooks (build.k prebuild_script / postbuild_script) ------------------------

def run_or_die(argv: list, cwd: Path = ROOT, env=None) -> str:
    r = subprocess.run(argv, cwd=str(cwd), env=env, text=True, stdout=subprocess.PIPE)
    if r.returncode != 0:
        die(f"command failed ({r.returncode}): {' '.join(map(str, argv))}")
    return r.stdout


def gen_registry(src: Path) -> Path:
    """gen_diag.py: Compiler/Diagnostic/Registry.k (declarations; only when the source tree
    IS the repo) and build/registry/Compiler/Diagnostic/Registry.k (declarations + bodies),
    both Stage 1, both rewritten only when their text changes. ~0.3 s."""
    reg_k = REGISTRY_DIR / "Compiler" / "Diagnostic" / "Registry.k"
    decl = (src / "Compiler" / "Diagnostic" / "Registry.k") if src == ROOT \
        else (REGISTRY_DIR / "Unused" / "Registry.k")
    run_or_die([sys.executable, str(ROOT / "Scripts" / "gen_diag.py"),
                str(src / "Compiler" / "Diagnostic" / "TableGen"),
                f"--output={decl}", f"--full-output={reg_k}"])
    return reg_k


def postbuild(tree: Path, mode: str, triple: str, llvm_build: Path = None, target: str = None,
              src: Path = None) -> None:
    """Stage clang, lld, the resource dir and Lib/ into the tree and make it
    relocatable (stage_tree.py, every host). Idempotent. `llvm_build`: a cross
    target's LLVM, whose clang / lld are the ones the tree ships."""
    say(f"postbuild: Scripts/stage_tree.py {tree}")
    env = dict(os.environ, KBLD_MODE=mode, KBLD_TRIPLE=triple, KBLD_ROOT=str(ROOT))
    # The tree ships the Lib/ of the source it was built from: with --src, that
    # tree's Lib/, never the checkout's (which may hold unrelated uncommitted work).
    if src is not None:
        env["KBLD_LIB_SRC"] = str(src / "Lib")
    if llvm_build:
        env["KAIRO_LLVM_BUILD"] = str(llvm_build)
    if target:
        env["KAIRO_TREE_OS"] = {"linux": "Linux", "windows": "Windows", "macos": "Darwin",
                                "freebsd": "FreeBSD", "netbsd": "NetBSD"}[CROSS[target][0]]
    run_or_die([sys.executable, str(ROOT / "Scripts" / "stage_tree.py"), str(tree)], env=env)


def selfhost_registry(kairo: Path, src: Path, out: Path, prog, extra: list = [], cache_root: Path = None) -> Path:
    """The diagnostic registry for a self-host tree, compiled by the compiler doing the
    build. Its source, build/registry/Compiler/Diagnostic/Registry.k (gen_diag.py),
    is the declarations plus the bodies as ONE module; its root goes first so it shadows the tree's
    declarations-only Registry.k for this compile only. Rebuilt only when the source or
    the compiler changed (the file is 65k lines). Later: back to a normal import after the
    optimisation pass."""
    reg_k = gen_registry(src)
    obj_dir = (cache_root or (out / "obj")) / "registry"
    obj_dir.mkdir(parents=True, exist_ok=True)
    obj = obj_dir / "registry.o"
    argv = [str(kairo), str(reg_k), "-c", "--emit-scope=inputs", "-w", "-o", str(obj),
            "-I", str(REGISTRY_DIR / "Compiler"), "-I", str(src / "Compiler"), "-I", str(src / "Linker"),
            "--cache-dir", str(cache_root / "tu" if cache_root else obj_dir / "cache"), *extra]
    st = kairo.stat()
    # Plus the modules it imports: an inline body among them (EvalHash's compute_hash)
    # is compiled INTO registry.o, so an edit there must rebuild it.
    deps = b""
    # The module path of each import: `A::B::*;`, `A::B::name;` or `A::B::{` (gen_diag.py
    # names what it uses, rules 5.1-5.2 of Extras/Formatter/README).
    for m in re.findall(r"^import ([A-Za-z_][A-Za-z0-9_:]*)::(?:\*|\{|[A-Za-z_][A-Za-z0-9_]*;)", reg_k.read_text(), re.M):
        f = src / "Compiler" / (m.replace("::", "/") + ".k")
        deps += f.read_bytes() if f.exists() else m.encode()
    key = hashlib.sha256(reg_k.read_bytes() + deps
                         + repr((str(kairo), st.st_size, st.st_mtime_ns, argv)).encode()).hexdigest()
    stamp = obj_dir / "registry.stamp"
    if obj.exists() and stamp.exists() and stamp.read_text().strip() == key:
        prog.log(f"registry: up to date ({obj})")
        return obj
    stamp.unlink(missing_ok=True)
    rc, secs = prog.run("registry", argv, obj_dir / "registry.log", expect=None)
    if rc != 0 or not obj.exists():
        prog.fail(obj_dir / "registry.log")
        die(f"the registry did not compile (rc {rc}); see {obj_dir / 'registry.log'}")
    stamp.write_text(key)
    return obj


def _llvm_identity(lib_dir: Path) -> str:
    """The LLVM a cached native object was compiled against, as the build sees it:
    every LLVM / clang / lld library in lib_dir by name, size and mtime. A rebuild
    of the fork (build_llvm.py, cross_llvm.py) rewrites them, and that is the only way
    its headers or its clang change under a build."""
    rows = []
    if lib_dir.is_dir():
        for f in sorted(lib_dir.iterdir()):
            n = f.name
            if n.startswith(("libLLVM", "libclang", "liblld", "LLVM", "clang", "lld")) and f.is_file():
                st = f.stat()
                rows.append(f"{n}:{st.st_size}:{st.st_mtime_ns}")
    return "\n".join(rows)


def native_object(kairo: Path, src: Path, args: list, key_args: list, llvm_lib: Path,
                  cache: Path, prog) -> Path:
    """src (the fork's cc1as_main.cpp) compiled once, then taken from cache.

    It is one LLVM source file at -O3, ~2 s of every kairo/kcc link on the serial tail
    after codegen (NativeCompile), and it changes only with the fork. Compiled by the
    compiler doing the build, as `kairo -c` with the build's own flags (args), which
    gives the object the in-build compile writes byte for byte. Keyed on the source,
    the flags that can reach the object (key_args: the build's, minus the output
    tree's path map, which differs between staging and release and names no file this
    source includes) and the LLVM libraries (_llvm_identity), never on the compiler
    binary: staging and release are different binaries with the same clang inside, and
    keying on them would miss on every pipeline step. A miss compiles in place of the
    build's own compile, so it costs what the build used to."""
    # Plus how kairo turns those flags into the native cc1 line (FlagTranslator,
    # ClangBackend, CompilerInstance::_native_words): an edit there must not keep
    # linking an object compiled under the old translation. Staging and release
    # build the same tree, so they still share the key.
    xlate = b"".join((ROOT / "Compiler" / f).read_bytes() for f in
                     ("Command/FlagTranslator.k", "Interop/Clang/ClangBackend.k", "Driver/CompilerInstance.k")
                     if (ROOT / "Compiler" / f).exists())
    key = hashlib.sha256(src.read_bytes() + repr(key_args).encode() + _llvm_identity(llvm_lib).encode()
                         + xlate).hexdigest()[:24]
    cache.mkdir(parents=True, exist_ok=True)
    obj = cache / f"{src.stem}-{key}.o"
    if obj.exists():
        try:
            os.utime(obj)   # recency, for the bound below
        except OSError:
            pass
        prog.log(f"{src.name}: cached ({obj})")
        return obj
    # Per process: concurrent builds share this checkout and this cache.
    tmp = cache / f"{src.stem}-{key}.{os.getpid()}.tmp.o"
    argv = [str(kairo), str(src), "-c", "-o", str(tmp), *args]
    rc, secs = prog.run(src.name, argv, cache / f"{src.stem}.log", expect=None)
    if rc != 0 or not tmp.exists():
        prog.fail(cache / f"{src.stem}.log")
        die(f"{src.name} did not compile (rc {rc}); see {cache / (src.stem + '.log')}")
    os.replace(tmp, obj)
    # Bounded: the newest few keys per source stay (kairo and kcc differ in
    # VERSION, so a pipeline uses two), older ones go.
    olds = sorted((f for f in cache.glob(f"{src.stem}-*.o") if not f.name.endswith(".tmp.o")),
                  key=lambda f: f.stat().st_mtime_ns, reverse=True)
    for old in olds[4:]:
        old.unlink(missing_ok=True)
    return obj


# --- progress (a ninja-style pinned status line) -------------------------------

def tu_objects(obj_dir: Path):
    """The per-TU objects kairo writes under its --cache-dir, without its incremental
    store (kairo-cache-v<N>/, Compiler/Spec/Incremental.md), which holds a copy of each."""
    for f in obj_dir.rglob("*.o"):
        if not any(p.startswith("kairo-cache-v") for p in f.relative_to(obj_dir).parts):
            yield f


_PROGRESS_RE = re.compile(r"^@progress phase=(\w+) done=(\d+) total=(\d+)(?: reused=(\d+))?(?: file=(.*))?$")


def parse_progress(line: str):
    """One `@progress` event from the compiler (Compiler/Spec/Driver.md#progress), as a
    dict, or None for any other line (which belongs in the log)."""
    m = _PROGRESS_RE.match(line.rstrip("\r\n"))
    if not m:
        return None
    ev = {"phase": m.group(1), "done": int(m.group(2)), "total": int(m.group(3)),
          "reused": int(m.group(4) or 0)}
    if m.group(5):
        ev["file"] = m.group(5)  # only an event that names one replaces the last name
    return ev


def progress_text(label: str, ev: dict) -> str:
    text = f"{label}: {ev['phase']} {ev['done']}/{ev['total']}"
    if ev.get("reused"):
        text += f", {ev['reused']} reused"
    if ev.get("file"):
        text += "  " + "/".join(ev["file"].split("/")[-3:])
    return text


class Progress:
    """Log lines scroll above; one status line stays pinned at the bottom on a TTY:
        [3/6] kairo: objects 214/327  65% [#############.......] 1m42s
    The step count is build.py's own pipeline; the object count is the .o files the
    compiler has written into its --cache-dir during this step, against the count the
    previous build left there (or the number of .k files on a first build). Not a TTY:
    plain lines, no redraws."""

    def __init__(self, total: int):
        self.total = total
        self.step = 0
        self.tty = sys.stdout.isatty() and os.environ.get("TERM") != "dumb"
        self.started = time.monotonic()

    def _clear(self):
        if self.tty:
            sys.stdout.write("\r\x1b[2K")

    def log(self, msg: str):
        self._clear()
        print(f"[build] {msg}", flush=True)

    def next(self, what: str):
        self.step += 1
        self.what = what
        self.log(f"[{self.step}/{self.total}] {what}")

    def _bar(self, text: str, frac=None):
        if not self.tty:
            return
        cols = shutil.get_terminal_size((100, 20)).columns
        el = int(time.monotonic() - self.t0)
        tail = f" {el // 60}m{el % 60:02d}s"
        head = f"[{self.step}/{self.total}] {text}"
        if frac is not None:
            w = max(10, min(30, cols - len(head) - len(tail) - 8))
            fill = int(w * min(frac, 1.0))
            head += f" {int(frac * 100):3d}% [{'#' * fill}{'.' * (w - fill)}]"
        line = (head + tail)[:cols - 1]
        sys.stdout.write("\r\x1b[2K\x1b[1m" + line + "\x1b[0m")
        sys.stdout.flush()

    def run(self, label: str, argv: list, log_path: Path, expect=None, obj_dir=None, binary=None):
        """Run argv with its output in log_path; animate the pinned line meanwhile.
        A compiler that has --progress is run with --progress=lines and its `@progress`
        events (Compiler/Spec/Driver.md#progress) drive the line; one that does not
        keeps the old estimate from the .o files in its --cache-dir."""
        self.t0 = time.monotonic()
        log_path.parent.mkdir(parents=True, exist_ok=True)
        wall0 = time.time()
        events = kairo_has_flag(Path(argv[0]), "--progress") if Path(argv[0]).name.startswith("kairo") else False
        state = {}
        lock = threading.Lock()
        with open(log_path, "w", encoding="utf-8") as lf:
            if events and self.tty and _HAVE_PTY:
                # Kairo draws its own bar: give it a terminal for stderr and pass its
                # redraws through; everything else on stderr goes to the log.
                rc = self._run_passthrough(argv, lf)
                self._clear()
                return rc, time.monotonic() - self.t0
            if events:
                p = subprocess.Popen([*argv, "--progress=lines"], cwd=str(ROOT), stdout=lf,
                                     stderr=subprocess.PIPE)

                def pump():
                    # Every other line goes to the log as it always did; the log is
                    # shared with stdout, so write under the lock and flush.
                    for raw in p.stderr:
                        line = raw.decode("utf-8", errors="replace")
                        ev = parse_progress(line)
                        with lock:
                            if ev is not None:
                                if ev["phase"] != state.get("phase"):
                                    state.clear()  # the last phase's file is not this one's
                                state.update(ev)
                            else:
                                lf.write(line)
                                lf.flush()

                t = threading.Thread(target=pump, daemon=True)
                t.start()
            else:
                p = subprocess.Popen(argv, cwd=str(ROOT), stdout=lf, stderr=subprocess.STDOUT)
            while p.poll() is None:
                time.sleep(0.25)
                if events:
                    with lock:
                        ev = dict(state)
                    if ev:
                        self._bar(progress_text(label, ev), ev["done"] / ev["total"] if ev["total"] else None)
                    else:
                        self._bar(f"{label}")
                elif obj_dir is not None and expect:
                    done = sum(1 for f in tu_objects(obj_dir) if f.stat().st_mtime >= wall0)
                    if binary is not None and binary.exists() and binary.stat().st_mtime >= wall0:
                        self._bar(f"{label}: linking", 1.0)
                    elif done == 0:
                        self._bar(f"{label}: parse + sema")
                    elif done >= expect:
                        self._bar(f"{label}: objects {done}/{expect}, linking", 1.0)
                    else:
                        self._bar(f"{label}: objects {done}/{expect}", done / expect)
                else:
                    self._bar(f"{label}")
            if events:
                t.join()
        self._clear()
        secs = time.monotonic() - self.t0
        return p.returncode, secs

    def _run_passthrough(self, argv: list, lf) -> int:
        """Run a compiler with its stderr on a pty and --progress=always, so its own
        pinned line (`\\r\\x1b[2K` + text, no newline) reaches the terminal unchanged.
        Our pinned line stays off for the duration. A piece of stderr that ends in a
        newline is not a redraw (the compiler erases its line before diagnostics):
        it goes to the log, as does anything that is not preceded by an erase."""
        sys.stdout.flush()
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ,
                        fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\0" * 8))
        except OSError:
            pass
        tty.setraw(slave)  # no CRLF translation or echo: the bytes arrive as written
        p = subprocess.Popen([*argv, "--progress=always"], cwd=str(ROOT), stdout=lf, stderr=slave)
        os.close(slave)
        erase = b"\r\x1b[2K"

        def pump():
            out = sys.stdout.buffer
            while True:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break  # EIO: every writer closed the slave
                if not data:
                    break
                head, *rest = data.split(erase)
                if head:
                    lf.write(head.decode("utf-8", errors="replace"))
                for piece in rest:
                    out.write(erase)  # always: the compiler's own line is being replaced
                    if b"\n" in piece:
                        lf.write(piece.decode("utf-8", errors="replace"))  # a diagnostic
                    else:
                        out.write(piece)  # a redraw: a single write, never split
                lf.flush()
                out.flush()

        t = threading.Thread(target=pump, daemon=True)
        t.start()
        rc = p.wait()
        t.join(timeout=5)
        os.close(master)
        return rc

    def fail(self, log_path: Path, lines: int = 40):
        """Show the end of a failed step's log (errors only when there are any)."""
        try:
            text = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return
        errs = [l for l in text if " error" in l or "error:" in l or "error [" in l]
        shown = (errs or text)[-lines:]
        self._clear()
        for l in shown:
            print(l)
        sys.stdout.flush()

    def done(self):
        el = int(time.monotonic() - self.started)
        self.log(f"done in {el // 60}m{el % 60:02d}s")


# --- the compiler to build with -------------------------------------------------

def release_triple(host: str) -> str:
    """Where a host's RELEASE toolchain lives (decided 2026-11-06: every release build is
    static). On Linux that is the static musl tree, which also runs here, so the release
    pipeline still stages through it; --debug keeps the dynamic glibc tree for speed."""
    if host.endswith("-linux-gnu"):
        return host.split("-", 1)[0] + "-linux-musl"
    return host


def _release_triples(host: str) -> list:
    rt = release_triple(host)
    return [rt] if rt == host else [rt, host]


def find_seed(triple: str) -> Path:
    """The SEED (decided 2026-11-06): build/<host>/N-1/bin/kairo if there is one (the last
    release, backed up when the newest was built), else build/<host>/release, else
    `kairo` on PATH. Its kcc builds LLVM (cross_llvm.find_kcc) and its kairo starts a
    release's staging step."""
    for t in _release_triples(triple):
        for m in ("N-1", "release"):
            p = ROOT / "build" / t / m / "bin" / f"kairo{EXE}"
            if p.exists():
                return p
    onpath = shutil.which("kairo")
    if onpath:
        return Path(onpath)
    die(f"no seed: no build/<host>/{{N-1,release}}/bin/kairo and no kairo on PATH")


_FLAG_PROBE: dict = {}


def kairo_knows(kairo: Path, word: str) -> bool:
    """Whether compiler `kairo` lists `word` in --help-hidden. A flag added to the
    tree is unknown to the seed that builds it the first time (U002E would stop that
    build), so a flag the tree's own build passes is passed only once its compiler
    has it. Cached per compiler path."""
    key = str(kairo)
    if key not in _FLAG_PROBE:
        try:
            r = subprocess.run([str(kairo), "--help-hidden"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, timeout=60)
            _FLAG_PROBE[key] = r.stdout
        except (OSError, subprocess.SubprocessError):
            _FLAG_PROBE[key] = ""
    return word in _FLAG_PROBE[key]


_HELP_PROBE: dict = {}


def kairo_has_flag(kairo: Path, flag: str) -> bool:
    """Whether compiler `kairo` lists `flag` in --help (kairo_knows reads --help-hidden,
    which holds only the internal flags). Cached per compiler path."""
    key = str(kairo)
    if key not in _HELP_PROBE:
        try:
            r = subprocess.run([key, "--help"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, timeout=60)
            _HELP_PROBE[key] = r.stdout
        except (OSError, subprocess.SubprocessError):
            _HELP_PROBE[key] = ""
    return flag in _HELP_PROBE[key]


def tree_visibility_args(kairo: Path) -> list:
    """-fdefault-visibility=spec (2026-11-08): the tree builds under
    the language's own rule. An unmarked declaration is `prot` to its module (each
    top-level Compiler/ and Linker/ directory holds a comments-only module.k), and
    what another module uses is marked `pub`: that is the module's API. Before
    that the tree passed `pub` (the old everything-visible rule); the flag stays for
    users and tests. Passed explicitly rather than left to the default so the gate
    is visible in --print-jobs; empty for a seed that predates the flag, which has
    the old rule and needs nothing."""
    return ["-fdefault-visibility=spec"] if kairo_knows(kairo, "fdefault-visibility") else []


def find_kairo(arg, triple: str) -> Path:
    """The compiler a build uses (decided 2026-11-06): --kairo, else $KAIRO_SEED, else
    build/<host>/release/bin/kairo (the last good release), else whatever `kairo` is on
    PATH. The `kcc` beside it is what builds LLVM (Scripts/cross_llvm.py, find_kcc).
    Note PATH may still be Stage 0 (/usr/local/bin/kairo), which cannot build this tree;
    the first release run then needs --kairo."""
    for c in (arg, os.environ.get("KAIRO_SEED")):
        if c:
            p = Path(c)
            if not p.exists():
                die(f"no compiler at {p}")
            return p
    for t in _release_triples(triple):
        rel = ROOT / "build" / t / "release" / "bin" / f"kairo{EXE}"
        if rel.exists():
            return rel
    onpath = shutil.which("kairo")
    if onpath:
        return Path(onpath)
    die(f"no compiler: no build/<host>/release/bin/kairo and no kairo on PATH; pass --kairo or set KAIRO_SEED")


def link_sysroot(out: Path, triple: str, prog) -> None:
    """A tree outside build/<triple>/{release,debug} (stage1/, stage1.5/) has no bundled
    sysroot, so its compiler finds no C++ headers (P001W, then 'new' file not found).
    Point it at the release tree's, as kbld's debug tree does (sysroot -> ../release/sysroot)."""
    dst = out / "sysroot"
    src = ROOT / "build" / triple / "release" / "sysroot"
    if dst.exists() or dst.is_symlink() or not src.is_dir():
        return
    try:
        os.symlink(os.path.relpath(src, out), dst, target_is_directory=True)
        prog.log(f"sysroot: {dst} -> {os.path.relpath(src, out)}")
    except OSError as e:
        # Windows without symlink rights: a copy keeps the tree self-contained.
        shutil.copytree(src, dst, symlinks=True)
        prog.log(f"sysroot: copied {src} ({e.__class__.__name__} on symlink)")


# --- reproducible builds ---------------------------------------------------------

def source_epoch(src: Path, explicit):
    """SOURCE_DATE_EPOCH for the build: --source-date-epoch, else $SOURCE_DATE_EPOCH, else
    the commit time of the source tree's HEAD (a --src worktree pins one), else the
    repo's, else 0. Never the wall clock: that is exactly what must not leak in."""
    if explicit is not None:
        return explicit
    if os.environ.get("SOURCE_DATE_EPOCH", "").isdigit():
        return int(os.environ["SOURCE_DATE_EPOCH"])
    for d in (src, ROOT):
        try:
            r = subprocess.run(["git", "log", "-1", "--format=%ct"], cwd=str(d), text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if r.returncode == 0 and r.stdout.strip().isdigit():
                return int(r.stdout.strip())
        except OSError:
            pass
    return 0


def reproducible_args(os_: str, epoch: int, src: Path, out: Path) -> list:
    """Flags that make the bytes depend only on (source tree, compiler, flags).
    Path maps go ROOT, src, out in that order: the later, longer prefix wins in clang,
    and the output dir (which differs between the two builds being compared) maps to a
    fixed name. kairo's own --remap-path-prefix covers its codegen; the same maps go
    to --cxx-flags for the C/C++ inputs (the *_meta.cpp)."""
    maps = [(ROOT, "/kairo-root"), (src, "/kairo-src"), (out, "/kairo-out")]
    a = ["--source-date-epoch", str(epoch)]
    for old, new in maps:
        if old is None:   # native_object: no output tree to map
            continue
        a += ["--remap-path-prefix", f"{old}={new}",
              "--cxx-flags=-ffile-prefix-map=%s=%s" % (old, new)]
    if os_ == "linux":
        a += ["--build-id", "none"]
    elif os_ == "macos":
        # No -no_uuid: dyld refuses a Mach-O with no LC_UUID ("missing LC_UUID load
        # command", abort at launch), and ld64.lld already derives the UUID from a hash
        # of the output, so the binary stays reproducible with it.
        pass
    else:
        a += ["--ld-flags=/Brepro", "--ld-flags=/INCREMENTAL:NO"]
    return a


# --- main ------------------------------------------------------------------------

# --- the pipeline (decided 2026-11-06) -------------------------------------------
#
#   python3 build.py --debug [targets]   build/<triple>/debug: the toolchain, built by the release
#                                        compiler, permanent cache build/<triple>/cache/debug.
#   python3 build.py [--release]         the two-stage release:
#       1. clear the release caches
#       2. snapshot build/<triple>/release -> build/<triple>/N-1 (the backup, and the seed)
#       3. N-1 builds kairo alone          -> build/<triple>/staging
#       4. clear the release cache; staging builds the toolchain -> build/<triple>/release
#       5. point the toolchain on PATH at it (unless --no-path)
#     A failure at any step restores release/ from N-1 and exits nonzero with the step's
#     errors. On success N-1 stays as the backup; the next release run replaces it.
#   --target T: the same for another target's tree, build/T/{debug,release,N-1}. Its binaries
#     cannot run here, so there is no staging step: the host's release compiler builds it.
#
# The caches are passed as --cache-dir, which is also kairo's incremental object cache
# (phase 1, Compiler/Spec/Incremental.md): a TU whose object key is unchanged skips
# codegen and clang. The debug cache is permanent; the release pipeline clears its caches
# per run, so a release never reuses a staging compiler's objects.
#
# Any --out / --src / --print-jobs, or --single builds exactly one tree, as before.

TOOLCHAIN = ["kairo", "kcc", "kld", "kfmt", "ksys"]   # grows as NOT_MIGRATED tools (kbld, kals, kpkg) migrate


class PipelineError(Exception):
    pass


def _single(a, mode: str, out: Path, cache: Path, kairo: Path, targets: list, target=None) -> None:
    argv = [sys.executable, str(Path(__file__).resolve()), "--single", f"--{mode}",
            "--out", str(out), "--cache-dir", str(cache), "--kairo", str(kairo)]
    if target:
        argv += ["--target", target]
    if a.warnings:      argv.append("--warnings")
    if a.jobs:          argv += ["-j", str(a.jobs)]
    if a.no_native:     argv.append("--no-native")
    if a.mcpu:          argv += ["--mcpu", a.mcpu]
    if a.sanitize_ub:   argv.append("--sanitize-ub")
    if a.no_prebuild:   argv.append("--no-prebuild")
    if a.no_postbuild:  argv.append("--no-postbuild")
    if a.reproducible is not None:
        argv.append("--reproducible" if a.reproducible else "--no-reproducible")
    if a.source_date_epoch is not None:
        argv += ["--source-date-epoch", str(a.source_date_epoch)]
    for f in a.compiler_flag:
        argv.append(f"--compiler-flag={f}")
    argv += targets
    say(f"pipeline: {' '.join(argv[2:])}")
    if subprocess.run(argv, cwd=str(ROOT)).returncode != 0:
        raise PipelineError(f"{mode} build of {', '.join(targets)} into {out} failed (its errors are above)")


def _tree_files(tree: Path) -> list:
    return [d for d in ("bin", "lib") if (tree / d).exists()]


def _copy_tree(src: Path, dst: Path) -> None:
    """bin/ and lib/ (links kept); sysroot/ becomes a link to src's real one, never a
    5 GB copy."""
    shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True)
    for d in _tree_files(src):
        shutil.copytree(src / d, dst / d, symlinks=True)
    sr = src / "sysroot"
    if sr.exists():
        os.symlink(sr.resolve(), dst / "sysroot", target_is_directory=True)


def _restore(n1: Path, rel: Path) -> None:
    say(f"pipeline: restoring {rel} from {n1}")
    for d in ("bin", "lib"):
        shutil.rmtree(rel / d, ignore_errors=True)
        if (n1 / d).exists():
            shutil.copytree(n1 / d, rel / d, symlinks=True)


def _update_path(rel: Path, targets: list) -> None:
    """Point the toolchain's PATH entries at the new release: where `kairo` already
    resolves if that directory is writable, else ~/.local/bin."""
    cur = shutil.which("kairo")
    d = Path(cur).parent if cur else None
    if d is None or not os.access(d, os.W_OK):
        d = Path.home() / ".local" / "bin"
        d.mkdir(parents=True, exist_ok=True)
    cmds = []
    for t in targets:
        exe = rel / "bin" / f"{t}{EXE}"
        if not exe.exists():
            continue
        link = d / f"{t}{EXE}"
        try:
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(exe)
            say(f"pipeline: PATH {link} -> {exe}")
        except OSError:
            cmds.append(f"ln -sf {exe} {link}")
    if cur and Path(cur).parent != d:
        say(f"pipeline: note: {cur} (not writable) comes first on PATH; to replace it: "
            f"sudo ln -sf {rel / 'bin' / ('kairo' + EXE)} {cur}")
    for c in cmds:
        say(f"pipeline: could not link; run: {c}")


def _cross_llvm_stale(target: str) -> bool:
    bld = cross_dir(target) / "llvm"
    if not (bld / "build.ninja").exists():
        return True
    r = subprocess.run(["ninja", "-C", str(bld), "-n", "all", "clang", "llvm-nm", "llvm-objdump", "llvm-ar"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return r.returncode != 0 or "no work to do" not in r.stdout


def _cross_llvm_ready(a, host: str, target: str) -> bool:
    """A target's LLVM, rebuilt when the fork changed or it was never built, by the seed's
    kcc. A seed with no kcc (a bare `kairo` on PATH, a staging tree) gets one first:
    built by the seed's kairo into build/<host>/staging (decided 2026-11-06)."""
    if not _cross_llvm_stale(target):
        return True
    seed = find_seed(host)
    kcc = seed.parent / f"kcc{EXE}"
    if not kcc.exists():
        stg = ROOT / "build" / host / "staging"
        say(f"pipeline: {target}'s LLVM needs a rebuild and the seed {seed} has no kcc: building one")
        try:
            _single(a, "release", stg, ROOT / "build" / host / "cache" / "staging", seed, ["kcc"])
        except PipelineError as e:
            say(f"pipeline: FAILED: {e}")
            return False
        kcc = stg / "bin" / f"kcc{EXE}"
    say(f"pipeline: rebuilding {target}'s LLVM with {kcc}")
    r = subprocess.run([sys.executable, str(ROOT / "Scripts" / "cross_llvm.py"), target, "--kcc", str(kcc)],
                       cwd=str(ROOT))
    if r.returncode != 0:
        say(f"pipeline: FAILED: Scripts/cross_llvm.py {target} (log build/cross-llvm/{target}/llvm.log)")
        return False
    return True


def pipeline(a, host: str) -> int:
    target = a.target
    if not a.debug and not target and release_triple(host) != host:
        target = release_triple(host)
    # A target this machine runs (the host's own static musl tree) still stages: N-1
    # builds staging, staging builds the release. One it cannot run is built by the
    # host's release compiler directly.
    runnable = target is None or target == release_triple(host)
    tt = target or host
    base = ROOT / "build" / tt
    cache = base / "cache"
    targets = [t for t in a.targets] if a.targets != ["kairo"] or a.debug else list(TOOLCHAIN)
    if target and not _cross_llvm_ready(a, host, target):
        return 1
    if a.debug:
        if a.targets == ["kairo"]:
            targets = list(TOOLCHAIN)
        kairo = find_kairo(a.kairo, host)
        try:
            _single(a, "debug", base / "debug", cache / "debug", kairo, targets, target)
        except PipelineError as e:
            say(f"pipeline: FAILED: {e}")
            return 1
        return 0

    rel, n1, stg = base / "release", base / "N-1", base / "staging"
    have_rel = (rel / "bin" / f"kairo{target_exe(target)}").exists()
    # The compiler for step 3 (host) / the cross build: what the last good release was.
    host_rel = find_kairo(None, host) if not a.kairo else Path(a.kairo)
    for c in (cache / "staging", cache / "release"):
        shutil.rmtree(c, ignore_errors=True)
    if have_rel:
        say(f"pipeline: backing up {rel} -> {n1}")
        _copy_tree(rel, n1)
    elif not host_rel.exists():
        die(f"no release compiler to start from at {rel}; pass --kairo <a Stage 1.5 kairo> for the first run")
    touched = False
    try:
        if not runnable:
            seed = Path(a.kairo) if a.kairo else host_rel
            touched = True
            _single(a, "release", rel, cache / "release", seed, targets, target)
        else:
            seed = Path(a.kairo) if a.kairo else (n1 / "bin" / f"kairo{EXE}" if have_rel else host_rel)
            _single(a, "release", stg, cache / "staging", seed, ["kairo"], target)
            shutil.rmtree(cache / "release", ignore_errors=True)
            touched = True
            _single(a, "release", rel, cache / "release", stg / "bin" / f"kairo{EXE}", targets, target)
    except PipelineError as e:
        say(f"pipeline: FAILED: {e}")
        if touched and have_rel:
            _restore(n1, rel)
            say(f"pipeline: {rel} is the N-1 compiler again")
        return 1
    if runnable and not a.no_path:
        _update_path(rel, targets)
    say(f"pipeline: release ready in {rel}" + (f" (backup: {n1})" if have_rel else ""))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="*", default=["kairo"], help=f"targets (default kairo): {', '.join(TARGETS)}")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--debug", action="store_true", help="debug profile (default: release, as kbld)")
    mode.add_argument("--release", action="store_true")
    ap.add_argument("--kairo", help="Stage 1 compiler to build with (default: $KAIRO_SEED, else the newest staged one)")
    ap.add_argument("--src", default=None, help="source root holding Compiler/ Linker/ Extras/KaTAR (default: the repo)")
    ap.add_argument("--out", help="tree to build into (default: build/<triple>/stage1.5/<mode> for a self-host tree, "
                                  "build/<triple>/stage1/<mode> for the repo; never over the compiler doing the build)")
    ap.add_argument("--warnings", action="store_true",
                    help="self-host tree: keep Kairo warnings (default -w: ~15k deferred until after self-host)")
    ap.add_argument("-j", "--jobs", type=int, default=0, help="--threads for the compiler (0 = all CPUs)")
    ap.add_argument("--no-native", action="store_true",
                    help="build against the bundled sysroot instead of the host's C library (default is --native for "
                         "now: the vendored libLLVM / libclang-cpp are built against the host glibc, newer than the "
                         "bundled sysroot's 2.31 floor; see KAIRO_HOST_SYSROOT)")
    ap.add_argument("--target", choices=sorted(CROSS), metavar="TRIPLE",
                    help="build a static shipping tree for another target into build/<TRIPLE>/<stage>/<mode>, "
                         "against the LLVM Scripts/cross_llvm.py built for it (known: " + ", ".join(sorted(CROSS)) + ")")
    ap.add_argument("--mcpu", metavar="CPU",
                    help="tune and target this CPU (kairo --mcpu, e.g. znver4); the binary then only runs on that "
                         "CPU or newer, so never for a tree you ship")
    ap.add_argument("--sanitize-ub", action="store_true", help="debug: pass -fsanitize-ub (accepted but unimplemented today, U005W)")
    ap.add_argument("--print-jobs", action="store_true", help="print the planned clang jobs and link, build nothing")
    ap.add_argument("--print-command", action="store_true",
                    help="print each tool's exact kairo command line (shell-quoted, after any pre-build steps it "
                         "depends on) and stop before compiling it")
    ap.add_argument("--no-prebuild", action="store_true", help="skip build_llvm.py (gen_diag.py always runs: ~0.3 s, writes only on change)")
    ap.add_argument("--registry-object", metavar="PATH",
                    help="link this diagnostic-registry object instead of build/.kbld/registry.o (implies "
                         "--no-prebuild). A self-host build passes a registry compiled by the compiler under test: "
                         "the prebuilt one is Stage 0's, with Stage 0 symbol names")
    ap.add_argument("--no-postbuild", action="store_true", help="skip stage_tree.py")
    ap.add_argument("--reproducible", action=argparse.BooleanOptionalAction, default=None,
                    help="output depends only on (source tree, compiler, flags): fixed epoch and version date, "
                         "path prefix maps, no build-id/timestamps, per-out generated files. OFF unless asked for: a plain release "
                         "build keeps real paths and the real build date")
    ap.add_argument("--source-date-epoch", type=int, default=None,
                    help="--reproducible: the epoch to embed (default $SOURCE_DATE_EPOCH, else the source tree's HEAD commit time)")
    ap.add_argument("--explain-gaps", action="store_true", help="list the build.k flags Stage 1 cannot express, and exit")
    ap.add_argument("--cache-dir", metavar="DIR",
                    help="the build's PERMANENT object cache (tu/, shared by every target, plus registry/); default "
                         "<out>/obj. The pipeline passes build/<triple>/cache/<stage>; kairo reuses the objects "
                         "of unchanged TUs from it (incremental compilation, phase 1)")
    ap.add_argument("--no-path", action="store_true", help="release pipeline: leave the toolchain on PATH alone")
    ap.add_argument("--compiler-flag", action="append", default=[], metavar="FLAG",
                    help="pass FLAG to every kairo invocation of the build (repeatable), e.g. "
                         "--compiler-flag=--type-check-only --compiler-flag=--error-format=basic")
    ap.add_argument("--single", action="store_true", help=argparse.SUPPRESS)   # one tree; the pipeline's step
    a = ap.parse_args()

    if a.explain_gaps:
        for flag, why in STAGE1_GAPS:
            print(f"{flag}\n    {why}")
        return 0

    os_, triple = host_os(), host_triple()
    if not (a.single or a.out or a.print_jobs or a.src) and REPO_SELFHOSTED:
        return pipeline(a, triple)
    debug = a.debug
    mode_name = "debug" if debug else "release"
    src = Path(a.src).resolve() if a.src else ROOT
    selfhost = (src != ROOT) or REPO_SELFHOSTED
    stage = "stage1.5" if selfhost else "stage1"
    tree_triple = a.target or triple
    out = Path(a.out).resolve() if a.out else ROOT / "build" / tree_triple / stage / mode_name
    cache_root = Path(a.cache_dir).resolve() if a.cache_dir else out / "obj"
    # ONE incremental object cache for every tool of this (mode, triple) build: kairo's
    # --cache-dir is both the content-addressed store (kairo-cache-v<N>/<F>/objects, which
    # it names by the toolchain fingerprint F, so another mode or target never sees these
    # objects) and the per-TU link inputs (<module path>.o). The object key is per TU
    # (Compiler/Spec/Incremental.md#as-built), so after `kairo` is built, `kcc` compiles
    # only the TUs kairo's graph does not hold and reuses the rest. The link inputs are
    # shared too: they are rewritten from the store whenever their own record names
    # another key, and each run links its own object list, never a glob of this dir.
    # Per-tool scratch stays apart: logs under <out>/logs, the registry under registry/.
    tu_cache = cache_root / "tu"
    # Reproducible remaps every source path in the debug info to /kairo-root, /kairo-src,
    # /kairo-out (so two builds are bit-identical), and then a debugger cannot find the
    # sources. So it is opt-in for every profile: `build.py --release --reproducible`.
    # run.py's fixedpoint/reprocheck pass --reproducible explicitly.
    repro = bool(a.reproducible)
    epoch = source_epoch(src, a.source_date_epoch) if repro else None
    kairo = find_kairo(a.kairo, triple).resolve()
    if out / "bin" in kairo.parents:
        die(f"--out {out} would overwrite the compiler doing the build ({kairo})")

    for t in a.targets:
        if t in NOT_MIGRATED:
            die(f"{t}: its sources ({NOT_MIGRATED[t]}) are not migrated to Stage 1 yet; build it with kbld")
        if t not in TARGETS:
            die(f"unknown target '{t}' (known: {', '.join(TARGETS)})")

    llvm_build = ROOT / "build" / "llvm"
    llvm_src = ROOT / "Lib" / "llvm-runtimes"
    kbld_dir = ROOT / "build" / ".kbld"
    # Reproducible: the generated meta lives under --out (the shared build/.gen would make
    # two builds race and leak the other's text); the out prefix is remapped.
    gen_dir = (out / "gen") if repro else ROOT / "build" / ".gen"
    out_lib = out / "lib"
    (out / "bin").mkdir(parents=True, exist_ok=True)
    out_lib.mkdir(parents=True, exist_ok=True)

    # --compiler-flag=--type-check-only / --syntax-only: kairo stops before codegen, so no
    # object or binary comes out of any step. The cached native object is then skipped
    # (compiled under that flag it exited 0 and wrote nothing: "did not compile (rc 0)"),
    # and there is no tree to stage.
    check_only = any(f in ("--type-check-only", "--syntax-only") for f in a.compiler_flag)
    staged = (not (a.print_jobs or a.print_command)) and (not a.no_postbuild) and (not check_only) and bool(STAGED & set(a.targets))
    prog = Progress(1 + (0 if a.registry_object else 1) + len(a.targets) + (1 if staged else 0))
    prog.log(f"{stage} {mode_name}, host {triple}" + (f", target {a.target} (static, cross LLVM)" if a.target else ""))
    prog.log(f"  compiler {kairo}")
    prog.log(f"  source   {src}" + ("  (self-hosted repo)" if (selfhost and src == ROOT) else ""))
    prog.log(f"  out      {out}")
    prog.next("prebuild")
    reg_o = Path(a.registry_object).resolve() if a.registry_object else kbld_dir / "registry.o"
    if a.registry_object:
        if not reg_o.exists():
            die(f"--registry-object {reg_o} does not exist")
    elif selfhost:
        # Never gen_diag.py into build/.kbld here (that object is Stage 0's, and the
        # repo's kbld build links it); only the LLVM stamp check.
        if not a.no_prebuild and not (a.print_jobs or a.print_command) and not a.target:
            run_or_die([sys.executable, str(ROOT / "Scripts" / "build_llvm.py")])
        prog.next("registry (gen_diag.py -> build/registry, Diagnostic::Registry)")
        reg_extra = llvm_include_args(llvm_src, cross_dir(a.target) / "llvm" if a.target else llvm_build)
        reg_extra.append("-fduck-generics")  # internal; the compiler tree's own build (see `common`)
        reg_extra += tree_visibility_args(kairo)  # internal; see tree_visibility_args
        if a.target:
            reg_extra += ["--target", a.target, *floor_args(CROSS[a.target][1])]
        reg_o = selfhost_registry(kairo, src, out, prog, reg_extra, cache_root)
    else:
        die("this tree is not self-hosted (no .selfhosted marker): Stage 0 sources need kbld and "
            "a Stage 0 registry.o, which gen_diag.py no longer makes")

    if a.target:
        common = cross_llvm_args(llvm_src, a.target) + profile_args(debug, a.sanitize_ub)
    else:
        common = llvm_args(llvm_src, llvm_build, out_lib, os_) + platform_args(os_) + profile_args(debug, a.sanitize_ub)
    # --native (decided 2026-11-03): link against this machine's C library, headers and
    # libraries. The vendored LLVM was built against the host glibc (2.38 / 2.44 symbol
    # versions), above the bundled sysroot's 2.31 floor, so a sysroot link warns L001W
    # and the binary only runs where that newer glibc is. Drop this once LLVM is built
    # against the old sysroot (KAIRO_HOST_SYSROOT, build_llvm.py).
    # --native is implemented for Linux hosts only (the driver answers U017E elsewhere), so a
    # macOS or Windows host builds against its bundled / first-use sysroot, as --no-native does.
    native = (os_ == "linux" and not a.no_native and not os.environ.get("KAIRO_HOST_SYSROOT")
              and not a.target)
    if native:
        common.append("--native")
    if not a.target:
        common += shared_libcxx_args(os_, native)
    if a.mcpu:
        common += ["--mcpu", a.mcpu]
    if selfhost and not a.warnings:
        common.append("-w")
    if selfhost:
        # The AST node modules import each other by design (a node names the
        # kinds that name it back), so the compiler's own tree carries ~35
        # genuine import cycles; the warning is for user code, not for this.
        common += ["-A", "R058W"]
    common += a.compiler_flag
    # The cached native objects' flags: the build's, without the output tree's path
    # map (native_object says why it is left out of the key).
    native_common = list(common)
    if selfhost:
        # The compiler's own source still has `<T: type>` sites (TODO(DUCK-GENERIC)).
        # -fduck-generics is off by default (decided 2026-11-08: everyone else gets real
        # bounds) and internal; only this tree's targets turn it on. After the
        # native_common copy: the C++ native objects have no generics, and their
        # cache key should not move with a Kairo-only flag.
        common.append("-fduck-generics")
        # The tree's visibility rule (see tree_visibility_args); a Kairo-only
        # flag, after native_common as above.
        common += tree_visibility_args(kairo)
    if repro:
        common += reproducible_args(os_, epoch, src, out)
        native_common += reproducible_args(os_, epoch, src, None)
        prog.log(f"reproducible: epoch {epoch}")
    for t in sorted(a.targets):
        entry, vname, vsuffix, extra_roots = TARGETS[t]
        roots = []
        for r in STAGE1_ROOTS + extra_roots:
            roots += ["-I", str(src / r)]
        # The TARGET's object format picks the section syntax: Mach-O wants
        # "segment,section"; MinGW takes the GNU form like ELF does.
        meta_os = os_ if not a.target else ("macos" if CROSS[a.target][0] == "macos" else "linux")
        meta = write_meta(gen_dir, t, meta_os, epoch, version(vname, vsuffix, epoch))
        # clang's integrated assembler (clang/tools/driver/cc1as_main.cpp) is in no
        # clang library: compiled in from the fork so ClangJobs can run -cc1as jobs
        # in-process (Native/Cc1As.hh). Every target links the clang libs it needs.
        cc1as = llvm_src / "clang" / "tools" / "driver" / "cc1as_main.cpp"
        # The compiler's Win32 calls: the only file that includes <windows.h>,
        # compiled into every binary; it is empty off Windows.
        win32 = src / "Compiler" / "Native" / "Win32.cpp"
        if not (a.print_jobs or a.print_command) and not check_only:
            # No version define: cc1as_main.cpp does not read it, and it would key this
            # object per tool and per day.
            nargs = [*roots, "--threads", str(a.jobs), *native_common]
            llvm_lib = (cross_dir(a.target) / "llvm" / "lib") if a.target else llvm_build / "lib"
            cc1as = native_object(kairo, cc1as, nargs, nargs, llvm_lib,
                                  ROOT / "build" / ".native-objs" / tree_triple, prog)
        argv = [str(kairo), str(src / entry), str(meta), str(reg_o), str(cc1as), str(win32),
                "-o", str(out / "bin" / f"{t}{target_exe(a.target)}"), *roots,
                # The version is in the meta object (write_meta), not a define on every
                # TU: the tools share one object cache (below), and a per-tool define is
                # in every object key.
                "--cxx-define", "KAIRO_VERSION_EXTERN=1",
                "--threads", str(a.jobs),
                "--cache-dir", str(tu_cache), *common]
        if a.print_command:
            print(f"# {t} (cwd {ROOT})")
            print(shlex.join(argv), flush=True)
            continue
        if a.print_jobs:
            argv.append("--print-jobs")
            say(f"{t}: {entry}")
            r = subprocess.run(argv, cwd=str(ROOT))
            if r.returncode != 0:
                die(f"{t} failed ({r.returncode})")
            continue
        prog.next(f"{t}: {entry}")
        obj_dir = tu_cache
        obj_dir.mkdir(parents=True, exist_ok=True)
        # Expected objects (only for a compiler without --progress): one per .k file
        # of the target's roots. The cache is shared, so what it holds is every
        # tool's objects, not this one's.
        expect = sum(1 for r in STAGE1_ROOTS + extra_roots for _ in (src / r).rglob("*.k"))
        binary = out / "bin" / f"{t}{target_exe(a.target)}"
        log_path = out / "logs" / f"{t}.log"
        rc, secs = prog.run(t, argv, log_path, expect=expect, obj_dir=obj_dir, binary=binary)
        if rc != 0:
            prog.fail(log_path)
            die(f"{t} failed ({rc}) after {secs:.0f} s; full log {log_path}")
        if check_only:
            prog.log(f"{t}: checked in {secs:.0f} s, no binary (log {log_path})")
            continue
        prog.log(f"{t}: built {binary} in {secs:.0f} s (log {log_path})")

    if staged:
        prog.next("stage tree (Scripts/stage_tree.py)")
        link_sysroot(out, triple, prog)
        postbuild(out, mode_name, tree_triple, cross_dir(a.target) / "llvm" if a.target else None, a.target, src)
    if not (a.print_jobs or a.print_command):
        prog.done()
        for t in sorted(a.targets) if not check_only else []:
            prog.log(f"  {out / 'bin' / (t + target_exe(a.target))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
