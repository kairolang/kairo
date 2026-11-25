# -*- Python -*-
# Lit configuration for the Kairo regression suite.
# Run with:  llvm-lit -v Tests/        (or: lit -v Tests/)
#
# Requires the `lit` and `filecheck` Python packages, OR LLVM's lit + FileCheck
# on PATH. We do NOT depend on llvm_config / an LLVM build tree.

import os
import shutil
import glob
import subprocess
import sys
import lit.formats

# --- Suite identity ----------------------------------------------------------
config.name = "Kairo"

# --- Which shell runs RUN lines -----------------------------------------------
# RUN lines are POSIX sh (`$?`, `test`, `{ ...; }`, shebang scripts), so they
# want a real bash. lit caches its bash in lit_config.bashPath and only searches
# PATH when that is None -- and on Windows the first `bash` on PATH is often the
# WSL launcher, which runs Linux, not this host. Pick one here: --param bash=
# if given, else the first bash on PATH that is not a WSL stub. With none, use
# lit's internal shell rather than letting lit fall back to cmd.exe; tests that
# need a real shell say `REQUIRES: shell` and are UNSUPPORTED there.
def _usable_bash():
    if sys.platform != "win32":
        return shutil.which("bash")
    p = lit_config.params.get("bash")
    if p:
        if not os.path.isfile(p):
            lit_config.fatal("--param bash=%s does not exist" % p)
        return p
    # Skip the WSL launcher stubs: they run Linux, not this host, and can't
    # execute Z:\...\kairo.exe with the paths lit hands them.
    windir = os.path.normcase(os.environ.get("SystemRoot", r"C:\Windows"))
    for d in os.environ.get("PATH", "").split(os.pathsep):
        c = os.path.join(d, "bash.exe")
        nc = os.path.normcase(os.path.abspath(c))
        if not os.path.isfile(c) or nc.startswith(windir) or "windowsapps" in nc:
            continue
        return c
    # Git for Windows puts only <Git>\cmd on PATH by default; its bash sits
    # beside that, under the same install root.
    git = shutil.which("git")
    if git:
        root = os.path.dirname(os.path.dirname(os.path.abspath(git)))
        for c in (os.path.join(root, "bin", "bash.exe"),
                  os.path.join(root, "usr", "bin", "bash.exe")):
            if os.path.isfile(c):
                return c
    return None

_bash = _usable_bash()
if _bash:
    lit_config.bashPath = _bash
    # lit 23 refuses execute_external without force_execute_external (the
    # internal shell is its default now; the option goes in 24); older lits
    # do not take the keyword. The suite's RUN lines need a real shell
    # (`$?`, `{ ...; }`), so force it where that is how it is asked for.
    try:
        config.test_format = lit.formats.ShTest(execute_external=True)
    except ValueError:
        config.test_format = lit.formats.ShTest(execute_external=True,
                                                force_execute_external=True)
    config.available_features.add("shell")
else:
    lit_config.note("no usable bash; using lit's internal shell")
    config.test_format = lit.formats.ShTest(execute_external=False)

# An MSYS bash (Git's, MSYS2's) rewrites any argument that looks like a POSIX
# path before handing it to a native program: `--sysroot=/nonexistent` reaches
# kairo.exe as C:/Program Files/Git/nonexistent. Tests mean the words they
# wrote, so turn the conversion off. Cygwin ignores both variables.
if sys.platform == "win32":
    config.environment["MSYS_NO_PATHCONV"] = "1"
    config.environment["MSYS2_ARG_CONV_EXCL"] = "*"
    # lit hands tests a trimmed environment. Without SystemDrive, anything
    # that loads shell32 (a MinGW link pulls it in) expands
    # %SystemDrive%\ProgramData literally and litters the test dir with a
    # `%SystemDrive%/` tree of shell caches.
    for _v in ("SystemDrive", "ProgramData", "ALLUSERSPROFILE", "windir",
               "USERPROFILE", "APPDATA", "LOCALAPPDATA"):
        if _v in os.environ:
            config.environment[_v] = os.environ[_v]

# Paths spliced into a RUN line. bash eats the backslashes in an unquoted
# Z:\projects\... (lit fixes up its own %s and %t for this, not ours), and
# forward slashes work for every Windows program the suite runs. Paths Python
# itself opens (config.kairo_bin, _bundle) stay native.
def _sh(p):
    return p.replace("\\", "/") if sys.platform == "win32" else p

# --- Which files are tests ---------------------------------------------------
# Any .k file containing RUN: lines is a test. Subdirs without RUN-bearing
# files are just traversed.
config.suffixes = [".k"]

# Directories never scanned for tests (inputs/fixtures live here). These match
# a directory NAME at any depth, so do not reuse them for a real test dir.
# clang/ is proof/oracle material, not a suite; manual/ is hand-run scratch.
# bugs/triage/ is a bug-reproducer corpus, not a lit suite: nearly every file
# in it is a known-failing case kept for triage, and its expected behaviour is
# whatever the issue says, not whatever the compiler currently prints.
# (Its sibling bugs/snapshots/ IS collected.)
config.excludes = ["inputs", "manual", "clang", "triage"]

# --- Where tests live --------------------------------------------------------
config.test_source_root = os.path.dirname(__file__)
config.test_exec_root = config.test_source_root  # run in-place; no build dir

# --- Locate the kairo binary -------------------------------------------------
# Priority: explicit param (--param kairo=/path) > env KAIRO_BIN > the most
# recently built of build/<triple>/{debug,release}/bin/kairo. Never PATH. Fail
# loudly if not found so a missing binary isn't a silent "0 tests".
def _find_kairo():
    # Explicit override always wins.
    p = lit_config.params.get("kairo")
    if p:
        return os.path.abspath(p)
    env = os.environ.get("KAIRO_BIN")
    if env:
        return os.path.abspath(env)

    # Default: the most recently built Stage 1 binary, debug or release.
    # Release alone used to be the default, and a debug edit loop then
    # silently tested a stale release build unless KAIRO_BIN was set.
    # test_source_root is Tests/, so the repo root is one up.
    matches = [
        p for p in glob.glob(os.path.join(
            config.test_source_root, "..", "build", "*", "*", "bin", "kairo*"))
        if os.path.basename(p) in ("kairo", "kairo.exe")
        and os.path.basename(os.path.dirname(os.path.dirname(p))) in ("debug", "release")
    ]

    if not matches:
        lit_config.fatal(
            "Could not locate the Stage 1 compiler under build/<triple>/"
            "{debug,release}/bin/kairo. Build it first (kbld kairo --debug), or "
            "pass --param kairo=/abs/path / set KAIRO_BIN.")

    default = os.path.normpath(max(matches, key=os.path.getmtime))
    lit_config.note("kairo: %s (newest build; override with KAIRO_BIN)" % default)

    # DO NOT fall through to PATH. A stale Stage 0 install at /usr/local/bin
    # will silently answer and you'll test the wrong compiler with the wrong
    # flags. Fail loudly instead.
    if not os.path.exists(default):
        lit_config.fatal(
            "Stage 1 kairo not found at {}. Build it first, or pass "
            "--param kairo=/abs/path / set KAIRO_BIN. (Refusing to fall back "
            "to PATH, a stale /usr/local/bin/kairo is Stage 0 and lacks "
            "--print-ast.)".format(default)
        )
    return default

kairo_bin = _find_kairo()
# The staged tree the binary sits in (Scripts/stage_tree.py): bin/ holds its
# clang, lld, llvm-objdump; lib/clang/<ver> its resource dir. Preferred over
# build/llvm and PATH everywhere below, so a bare `llvm-lit Tests/` uses the
# same toolchain the compiler does, on any host.
_tree = os.path.dirname(os.path.dirname(kairo_bin))
_exe = ".exe" if sys.platform == "win32" else ""
_llvm_bin = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "build", "llvm", "bin"))
# Exposed for lit.local.cfg files (they do not see this module's globals).
config.kairo_bin = kairo_bin

# The compiler's default target triple, as `kairo --version` prints it. The
# host-*, default-* and %datamodel facts below come from it, not from the
# machine lit runs on: a compiler for another architecture (run through
# binfmt and an emulator) builds and runs that architecture's programs.
def _default_triple():
    try:
        out = subprocess.run([kairo_bin, "--version"], capture_output=True,
                             text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        k, sep, v = line.partition(":")
        if sep and k.strip() == "target triple":
            return v.strip()
    return ""

_dt = _default_triple()
_dt_arch = _dt.split("-")[0]

# Scratch state a run keeps between tests (the kcc library cache, the
# compiler-rt shim): beside the tree when the tree is a build output (it sits
# under a build/ directory), else under this checkout's build/lit-external/
# <tree hash>, so testing an installed compiler never writes into its install
# prefix or the user's cache.
_lit_state = os.path.dirname(os.path.dirname(os.path.dirname(kairo_bin)))
if "build" not in os.path.realpath(_tree).split(os.sep):
    import hashlib
    _lit_state = os.path.join(config.test_source_root, "..", "build", "lit-external",
                              hashlib.sha256(os.path.realpath(_tree).encode("utf-8"))
                              .hexdigest()[:16])
    _lit_state = os.path.normpath(_lit_state)
# --- Locate FileCheck --------------------------------------------------------
def _find_filecheck():
    p = lit_config.params.get("filecheck")
    if p:
        return p
    # The LLVM build's FileCheck (with `not` beside it) before PATH: a fresh
    # macOS or Windows host has none on PATH.
    local = os.path.join(_llvm_bin, "FileCheck" + _exe)
    if os.path.isfile(local):
        return local
    for name in ("FileCheck", "filecheck"):
        found = shutil.which(name)
        if found:
            return found
    lit_config.fatal(
        "could not find FileCheck. Install LLVM's FileCheck or the 'filecheck' "
        "pip package, or pass --param filecheck=/abs/path"
    )

filecheck_bin = _find_filecheck()

# `not` is a builtin only of lit's internal shell; under a real one it is the
# LLVM tool, which sits beside an LLVM FileCheck. Put that dir on the tests'
# PATH when it has one (the pip filecheck package ships no `not`).
_llvm_tools = os.path.dirname(os.path.abspath(filecheck_bin))
if os.path.isfile(os.path.join(_llvm_tools, "not.exe" if sys.platform == "win32" else "not")):
    config.environment["PATH"] = _llvm_tools + os.pathsep + config.environment.get(
        "PATH", os.environ.get("PATH", ""))

# --- Substitutions -----------------------------------------------------------
# Plain-text substitution. Order matters only when one pattern is a prefix of
# another; ours are distinct, but list longest-first as habit.
# --- C++ header roots for ffi imports -----------------------------------------
# kairo discovers its roots beside the binary (CompilerInstance::
# _discover_roots), but the suite passes them explicitly anyway, so a test
# never depends on discovery working and builtin/std are always the source
# tree's (current without a re-stage). Defaults: the staged resource dir, else
# build/llvm's; no --sysroot, so kairo picks the sysroot bundled for its
# default target. Override: --param sysroot=/path, --param resource_dir=/path.
def _find_resource_dir():
    res = lit_config.params.get("resource_dir")
    if res:
        return res
    cands = sorted(glob.glob(os.path.join(_tree, "lib", "clang", "*"))) or \
            sorted(glob.glob(os.path.join(
                config.test_source_root, "..", "build", "llvm", "lib", "clang", "*")))
    cands = [c for c in cands
             if os.path.isfile(os.path.join(c, "include", "stddef.h"))]
    return os.path.normpath(cands[-1]) if cands else ""

def _clang_roots(with_builtins=True, with_std=True):
    sysroot = lit_config.params.get("sysroot", "")
    # A sysroot that does not exist is not an error to kairo (no system
    # headers, as with no --sysroot), so a stale path fails every ffi test
    # with a missing-header cascade instead of saying what is wrong.
    if sysroot != "" and not os.path.isdir(sysroot):
        lit_config.fatal("--param sysroot=%s is not a directory" % sysroot)
    res = _find_resource_dir()
    roots = (" --sysroot=%s" % _sh(sysroot)) if sysroot != "" else ""
    if res:
        roots += " --resource-dir=%s" % _sh(res)
    # The builtin module tree. An installed compiler finds it under
    # <resource-dir>/builtin, but nothing in the build copies Lib/builtin
    # there, so the suite points at the source tree directly. Without this
    # every lang item is unbound and `string` does not resolve -- which looks
    # like a sema bug rather than a missing flag.
    builtins = os.path.normpath(
        os.path.join(config.test_source_root, "..", "Lib", "builtin"))
    # The flag names the builtin tree ITSELF (the directory holding module.k),
    # not its parent -- the driver registers it as a search root named
    # `builtin`, and `import builtin` resolves through that name.
    if with_builtins and os.path.isdir(builtins):
        roots += " --builtins-dir=%s" % _sh(builtins)
    # The std module tree, same story: an installed compiler finds it under
    # <resource-dir>/std, nothing in the build copies Lib/std there. The
    # driver registers it under the ROOT NAME `kairo::std`, so bare `std` in a
    # test is the prelude alias for it and `cxx::std` is C++'s.
    stdlib = os.path.normpath(
        os.path.join(config.test_source_root, "..", "Lib", "std"))
    if with_std and os.path.isdir(stdlib):
        roots += " --std-dir=%s" % _sh(stdlib)
    return roots

kairo_roots = _clang_roots()

# A --target picks <prefix>/sysroot/<target> beside the compiler over the
# --sysroot above (CompilerInstance::_use_bundled_sysroot). Tests that compile
# for another target's C library need that directory, and fail with a
# confusing typedef clash rather than skip without it.
#
# One feature per bundled sysroot, from the triple its SYSROOT.toml names
# with the vendor dropped: sysroot-x86_64-linux-gnu, sysroot-wasm32-wasi,
# sysroot-x86_64-windows-msvc, sysroot-arm64-macosx (and -aarch64- for the
# same dir). A test that compiles for a target says `REQUIRES: sysroot-<t>`
# and is UNSUPPORTED, not failed, where that sysroot is not shipped -- the
# msvc and Apple ones are not redistributable, so most machines lack them.
# `bundled-sysroot` alone still says the directory exists at all; a test that
# builds for the default target (no --target) wants `default-sysroot`.
_bundle = os.path.join(os.path.dirname(os.path.dirname(kairo_bin)), "sysroot")
_VENDORS = {"unknown", "pc", "apple", "w64", "none"}

def _sysroot_features(triple):
    c = triple.split("-")
    if len(c) < 2:
        return []
    arch, rest = c[0], c[1:]
    # arch-vendor-os[-env] vs arch-os[-env]: the second slot is a vendor only
    # if it is a known one and something follows it.
    if len(rest) >= 2 and rest[0] in _VENDORS:
        rest = rest[1:]
    key = "-".join([arch] + rest)
    out = ["sysroot-" + key]
    alias = {"arm64": "aarch64", "aarch64": "arm64"}.get(arch)
    if alias:
        out.append("sysroot-" + "-".join([alias] + rest))
    return out

if os.path.isdir(_bundle):
    config.available_features.add("bundled-sysroot")
    for _d in sorted(os.listdir(_bundle)):
        _m = os.path.join(_bundle, _d, "SYSROOT.toml")
        if not os.path.isfile(_m):
            continue
        _triple = ""
        for _line in open(_m, encoding="utf-8"):
            if _line.split("#", 1)[0].strip().startswith("triple"):
                _triple = _line.split("=", 1)[1].strip().strip('"')
                break
        for _f in _sysroot_features(_triple or _d):
            config.available_features.add(_f)

# A --target with no bundled sysroot is built by ksys on first use and cached
# (Compiler/Spec/SysRoot.md), so the sysroots the toolchain can build count as
# present too. `ksys probe <name>` answers that without building: exit 0 and
# `supports: yes` (it needs the toolchain's share/kairo/sysroot inputs, and the
# Apple and MSVC ones need an SDK this host has). The first test that needs
# one pays for its build; parallel tests wait on the cache's lock.
# --param sysroots=bundled counts only the bundled directories.
_SYSROOT_NAMES = (
    "x86_64-linux-musl", "x86_64-linux-gnu", "i686-linux-musl", "i686-linux-gnu",
    "aarch64-linux-musl", "aarch64-linux-gnu", "armv7-linux-musl",
    "armv7-linux-gnueabihf", "riscv64-linux-musl", "riscv64-linux-gnu",
    "x86_64-windows-gnu", "i686-windows-gnu", "aarch64-windows-gnu",
    "armv7-windows-gnu", "x86_64-windows-msvc", "i686-windows-msvc",
    "aarch64-windows-msvc", "wasm32-wasi", "arm64-apple-macosx",
    "arm64e-apple-macosx", "x86_64-apple-macosx", "x86_64-unknown-freebsd",
    "aarch64-unknown-freebsd", "x86_64-unknown-netbsd")
_sysroot_mode = lit_config.params.get("sysroots", "ondemand")
if _sysroot_mode not in ("ondemand", "bundled"):
    lit_config.fatal("--param sysroots=%s: expected ondemand or bundled" % _sysroot_mode)
_ksys_probe = os.environ.get("KSYS_BIN") or os.path.join(os.path.dirname(kairo_bin), "ksys" + _exe)

def _ksys_builds(name):
    try:
        r = subprocess.run([_ksys_probe, "probe", name], capture_output=True,
                           text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0 and any(
        l.split(":", 1)[0].strip() == "supports" and l.split(":", 1)[1].strip() == "yes"
        for l in r.stdout.splitlines() if ":" in l)

if _sysroot_mode == "ondemand" and os.path.isfile(_ksys_probe):
    _todo = [n for n in _SYSROOT_NAMES
             if not all(f in config.available_features for f in _sysroot_features(n))]
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as _pool:
        _built = [n for n, ok in zip(_todo, _pool.map(_ksys_builds, _todo)) if ok]
    for _n in _built:
        for _f in _sysroot_features(_n):
            config.available_features.add(_f)
    if _built:
        lit_config.note("sysroots ksys builds on first use: %s (--param sysroots=bundled "
                        "skips their tests)" % " ".join(_built))

# `%wine <exe> [args]` runs a Windows executable under Wine (Scripts/run_wine.py:
# a private prefix, Wine from $KAIRO_WINE, PATH or Steam's Proton). The `wine`
# feature is set when a tiny generated PE program (Scripts/mk_probe_exe.py,
# no compiler involved) runs and exits with its code; the check runs once per
# lit run, here, and costs nothing when no Wine is installed.
_run_wine = os.path.normpath(
    os.path.join(config.test_source_root, "..", "Scripts", "run_wine.py"))
config.substitutions.append(("%wine", "%s %s" % (_sh(sys.executable), _sh(_run_wine))))

def _wine_works():
    import subprocess
    import tempfile
    mk = os.path.join(os.path.dirname(_run_wine), "mk_probe_exe.py")
    if not (os.path.isfile(_run_wine) and os.path.isfile(mk)):
        return False
    with tempfile.TemporaryDirectory() as d:
        probe = os.path.join(d, "probe.exe")
        try:
            subprocess.run([sys.executable, mk, probe], check=True)
            r = subprocess.run([sys.executable, _run_wine, probe],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=120)
        except (OSError, subprocess.SubprocessError):
            return False
    return r.returncode == 42

if _wine_works():
    config.available_features.add("wine")

# The bare binary, no flags: for tests of what the driver does WITHOUT the
# roots above (Tests/cli/driver/root_discovery.k). Before %kairo, which lit
# would otherwise substitute inside it.
config.substitutions.append(("%kairo_bin", _sh(kairo_bin)))
# --threads=2: lit already runs one test per hardware thread, and each
# kairo spawns its own pool (codegen fans out to the physical core count),
# so the default oversubscribed the machine several times over. A test that
# passes its own --threads (cli/driver/threads.k) writes it later, and the
# last one wins.
_kairo_threads = " --threads=2"
# --mcpu=baseline: without --target kairo compiles for the CPU of the machine
# it runs on (its x86-64 level, -mcpu=native on arm64), and FP contraction
# follows the CPU. A test's IR, assembly and cc1 line must not depend on
# the machine lit runs on, so every test compiles for the target's default
# CPU, as a --target build does. A test of the host default itself passes
# `--mcpu=` (empty: the flag as if it were not given); one that names a CPU
# with --march or --mcpu writes it later, and the last one wins.
_kairo_cpu = " --mcpu=baseline"
# A test of a builtin declaration the library does not have yet builds its
# own builtin tree: `%overlay_builtins %t.lib base/x.k=%S/inputs/x.k` copies
# Lib/builtin to %t.lib/builtin with the named files added (overlay_builtins.py),
# and `%kairo_overlay --builtins-dir=%t.lib/builtin` is %kairo without its own
# --builtins-dir, which would win. Before %kairo, as %kairo_bin is.
config.substitutions.append(
    ("%overlay_builtins", "%s %s %s" % (
        _sh(sys.executable),
        _sh(os.path.join(config.test_source_root, "overlay_builtins.py")),
        _sh(os.path.normpath(os.path.join(config.test_source_root, "..", "Lib"))))))
config.substitutions.append(("%kairo_overlay", _sh(kairo_bin) + " --error-format=basic" + _kairo_threads + _kairo_cpu + _clang_roots(with_builtins=False)))
config.substitutions.append(("%kairo", _sh(kairo_bin) + " --error-format=basic" + _kairo_threads + _kairo_cpu + kairo_roots))

# --- kcc ----------------------------------------------------------------------
# The clang drop-in, built beside kairo (Compiler/Driver/Kcc.k). It takes
# clang's options, so kairo's own words -- the same roots %kairo gets --
# go through -Xkairo, one word each. Tests that use it REQUIRE: kcc.
import shlex as _shlex
kcc_bin = os.path.join(os.path.dirname(kairo_bin), "kcc")
if os.path.isfile(kcc_bin):
    config.available_features.add("kcc")
    _kcc_x = "".join(" -Xkairo " + _sh(w) for w in ["--error-format=basic", _kairo_threads.strip()] + _shlex.split(kairo_roots))
    config.substitutions.append(("%kcc", _sh(kcc_bin) + _kcc_x))
# --- long-tests ----------------------------------------------------------------
# Tests that take more than ~30 s (ksys sysroot builds, kcc/runtime-cache
# rebuilds, huge codegen cases) say `// REQUIRES: long-tests`, so a normal
# `lit Tests` reports them UNSUPPORTED and stays fast. Opt in with
# `--param long=1` or KAIRO_LIT_LONG=1 (any value but "" / "0").
_long = lit_config.params.get("long", os.environ.get("KAIRO_LIT_LONG", ""))
if str(_long) not in ("", "0", "false", "no"):
    config.available_features.add("long-tests")
# --- ksys ---------------------------------------------------------------------
# The sysroot generator (linker/sysroot/driver/ksys.k, Compiler/Spec/SysRoot.md):
# $KSYS_BIN, else the one beside the kairo under test. Tests that use it
# REQUIRE: ksys.
ksys_bin = os.environ.get("KSYS_BIN") or os.path.join(os.path.dirname(kairo_bin), "ksys")
if os.path.isfile(ksys_bin):
    config.available_features.add("ksys")
    config.substitutions.append(("%ksys", _sh(ksys_bin)))
# clang's own test corpus, run through kcc (Tests/cli/kcc/clang_corpus): the
# fork's clang/test and the bundled clang the preprocessor mode compares with.
# The reference is the clang staged in the tree under test, else build/llvm's:
# its predefined macros (__VERSION__, __clang_version__) name the LLVM build
# it comes from, so only the clang of the LLVM kcc links prints the same
# text. A release tree links the cross LLVM (Scripts/cross_llvm.py), a debug
# tree build/llvm, and the two are separate builds. The sysroot is the one kcc
# itself picks for the musl target, <tree>/sysroot/x86_64-linux-musl.
_repo = os.path.dirname(config.test_source_root)
_clang_tests = os.path.join(_repo, "Lib", "llvm-runtimes", "clang", "test")
_bundled_clang = os.path.join(_tree, "bin", "clang" + _exe)
if not os.path.isfile(_bundled_clang):
    _bundled_clang = os.path.join(_repo, "build", "llvm", "bin", "clang")
_musl_sysroot = os.path.join(_tree, "sysroot", "x86_64-linux-musl")
if not os.path.isdir(_musl_sysroot):
    _musl_sysroot = os.path.join(_tree, "..", "release", "sysroot", "x86_64-linux-musl")
if os.path.isdir(_clang_tests) and os.path.isfile(_bundled_clang):
    config.available_features.add("clang-corpus")
    config.substitutions.append(("%clang_tests", _sh(_clang_tests)))
    config.substitutions.append(("%bundled_clang", _sh(_bundled_clang)))
    config.substitutions.append(("%musl_sysroot", _sh(_musl_sysroot)))
# A kcc link builds and caches the Kairo library (builtin, std, the runtime)
# on first use. One cache for the suite, under the build tree, never the
# user cache directory; parallel tests that race to build it are safe (the
# library is renamed into place).
config.environment["KAIRO_CACHE_DIR"] = os.path.join(_lit_state, "lit-kairo-cache")

# --- C data model of the default target ---------------------------------------
# C `long` is 64-bit on LP64 (64-bit Linux, macOS) and 32-bit on LLP64
# (Windows) and ILP32 (32-bit targets), and kairo's emitted C++ spells i64 the
# way that target's int64_t is spelled. Tests that check either pass
# %datamodel to FileCheck and match [[CLONG]], [[CULONG]], [[CXX_I64]], so one
# test states the right answer on every target instead of only on LP64.
# Apple's LP64 spells int64_t `long long`, so its i64 is long long too.
# (Not to kairo as -D types: a macro-expanded type does not yet bind an
# untyped literal the way the same type written out does.)
if "windows" in _dt or "mingw" in _dt or "msvc" in _dt:
    _long, _cxx_i64 = 32, "signed long long"  # LLP64
elif _dt_arch in ("i386", "i486", "i586", "i686", "x86", "riscv32", "wasm32") \
        or _dt_arch.startswith(("arm", "thumb")) and _dt_arch not in ("arm64", "arm64e"):
    _long, _cxx_i64 = 32, "signed long long"  # ILP32
elif "-apple-" in _dt or "darwin" in _dt:
    _long, _cxx_i64 = 64, "signed long long"  # LP64, int64_t is long long
else:
    _long, _cxx_i64 = 64, "signed long"       # LP64
config.substitutions.append(("%datamodel", "-DCLONG=i%d -DCULONG=u%d '-DCXX_I64=%s' '-DCXX_U64=%s'"
                             % (_long, _long, _cxx_i64,
                                _cxx_i64.replace("signed", "unsigned", 1))))

# --- The default build's host system ------------------------------------------
# `default-glibc` / `default-musl`: the C library of the default triple. With
# glibc, a bare `kairo` builds for <arch>-unknown-linux-gnu against the bundled
# glibc floor with the host's system dirs after it (a glibc Linux host). `pkg-config`, `pkg-<name>`: pkg-config is installed and knows <name>,
# so a test of --pkg-config against a real host library is UNSUPPORTED, not
# failed, on a machine without that library's development files.
if _dt.endswith("-linux-gnu") or "-linux-gnueabi" in _dt:
    config.available_features.add("default-glibc")
elif "-linux-musl" in _dt:
    config.available_features.add("default-musl")
_pkgconfig = shutil.which("pkg-config")
if _pkgconfig:
    config.available_features.add("pkg-config")
    for _pkg in ("zlib", "libcurl"):
        try:
            if subprocess.call([_pkgconfig, "--exists", _pkg], timeout=30) == 0:
                config.available_features.add("pkg-" + _pkg)
        except (OSError, subprocess.SubprocessError):
            pass

# --- Host facts as lit features ---------------------------------------------
# For tests whose expectations are the HOST's ABI (f80 on x86, `long` int64_t,
# size_t == uint64_t): `REQUIRES: host-x86_64`, `REQUIRES: host-linux`, so an
# arm64 or Darwin host reports them UNSUPPORTED instead of failing on facts
# the test never claimed to hold there. "Host" is the platform a bare kairo
# builds for and the test then runs: the compiler's default triple, which is
# the machine's own except for a compiler run under an emulator. Without a
# triple, the machine lit runs on.
def _triple_os(triple):
    for c in triple.split("-")[1:]:
        c = c.lower()
        if c.startswith(("darwin", "macos", "ios")):
            return "darwin"
        if c.startswith(("windows", "mingw", "win32", "cygwin")):
            return "windows"
        if c in ("linux", "freebsd", "netbsd", "openbsd", "wasi"):
            return c
        if c.startswith(("freebsd", "netbsd", "openbsd")):
            return c.rstrip("0123456789.")
    return ""

_ARCH_NAMES = {"x86_64": "x86_64", "amd64": "x86_64", "AMD64": "x86_64",
               "arm64": "aarch64", "arm64e": "aarch64", "aarch64": "aarch64",
               "ARM64": "aarch64"}
_host_os = _triple_os(_dt) or {"linux": "linux", "darwin": "darwin",
                               "win32": "windows"}.get(sys.platform, sys.platform)
config.available_features.add("host-" + _host_os)
import platform as _platform
_host_arch = _dt_arch or _platform.machine()
_host_arch = _ARCH_NAMES.get(_host_arch, _host_arch)
config.available_features.add("host-" + _host_arch)

# --- `timeout` on hosts without coreutils -------------------------------------
# Tests guard a parser that could hang with `timeout 10 %kairo ...; test $? -ne
# 124`. macOS ships no `timeout` (Homebrew coreutils has `gtimeout`), and a
# missing command fails the test with "command not found" -- which says nothing
# about kairo. Windows HAS a `timeout.exe`, and it is a sleep command, so only
# a `timeout` outside SystemRoot counts there -- Git and MSYS2 ship GNU's next
# to their bash, often in a usr\bin that is not on PATH, so look there too and
# put the one found ahead of System32. Else prepend a shim dir to the tests'
# PATH: a symlink to gtimeout where there is one, else a Python stand-in with
# the same exit code contract. Without a real shell the tests that use it are
# UNSUPPORTED (REQUIRES: shell), so none of this matters there.
def _host_timeout():
    if sys.platform != "win32":
        return shutil.which("timeout")
    windir = os.path.normcase(os.environ.get("SystemRoot", r"C:\Windows"))
    dirs = os.environ.get("PATH", "").split(os.pathsep)
    if _bash:
        b = os.path.dirname(os.path.abspath(_bash))
        dirs = [b, os.path.join(os.path.dirname(b), "usr", "bin")] + dirs
    for d in dirs:
        c = os.path.join(d, "timeout.exe")
        if os.path.isfile(c) and not os.path.normcase(
                os.path.abspath(c)).startswith(windir):
            return c
    return None

_timeout = _host_timeout()
if _timeout and sys.platform == "win32":
    config.environment["PATH"] = os.path.dirname(_timeout) + os.pathsep + \
        config.environment.get("PATH", os.environ.get("PATH", ""))
elif not _timeout:
    _shim_dir = os.path.join(config.test_exec_root, "Output", ".lit-bin")
    os.makedirs(_shim_dir, exist_ok=True)
    _shim = os.path.join(_shim_dir, "timeout")
    _gtimeout = shutil.which("gtimeout") if sys.platform != "win32" else None
    if os.path.islink(_shim) or os.path.exists(_shim):
        os.remove(_shim)
    if _gtimeout:
        os.symlink(_gtimeout, _shim)
    else:
        # The Python lives in a sibling file, launched from an sh script: a
        # Windows interpreter path (backslashes, maybe spaces) can't be a
        # shebang line, but it can be a quoted word.
        with open(_shim + ".py", "w") as f:
            f.write("""import subprocess, sys
# timeout DURATION COMMAND [ARG]... -> 124 on expiry, else the command's status.
dur = float(sys.argv[1].rstrip("s"))
try:
    sys.exit(subprocess.call(sys.argv[2:], timeout=dur))
except subprocess.TimeoutExpired:
    sys.exit(124)
""")
        with open(_shim, "w", newline="\n") as f:
            f.write('#!/bin/sh\nexec "%s" "%s" "$@"\n'
                    % (_sh(sys.executable), _sh(_shim + ".py")))
        os.chmod(_shim, 0o755)
    config.environment["PATH"] = _shim_dir + os.pathsep + config.environment.get(
        "PATH", os.environ.get("PATH", ""))
config.substitutions.append(("%FileCheck", _sh(filecheck_bin)))

# --- Parity (differential) tests --------------------------------------------
# Tests/sema/redecl_merge/parity/*.k each sit beside a .cpp that is the ORACLE:
# the assertion is that kairo and clang reach the same verdict. That needs a
# clang, which is not guaranteed, so it is a lit FEATURE -- tests requiring it
# say `// REQUIRES: clang` and are reported UNSUPPORTED (not failed) without it.
def _find_clang():
    # Every candidate is VERIFIED before it is returned. Advertising the
    # "clang" feature for a path that does not exist turns 18 UNSUPPORTED
    # tests into 18 failures that say nothing about kairo.
    def ok(path):
        return path and os.path.isfile(path) and os.access(path, os.X_OK)

    p = lit_config.params.get("clang")
    if p:
        p = os.path.abspath(p)
        if not ok(p):
            lit_config.fatal("--param clang=%s is not an executable" % p)
        return p
    env = os.environ.get("CLANG_BIN")
    if env:
        env = os.path.abspath(env)
        if not ok(env):
            lit_config.fatal("CLANG_BIN=%s is not an executable" % env)
        return env
    # Prefer the tree's own clang: it is the one kairo's FFI is built against,
    # so its C++ verdicts are the ones kairo is actually claiming parity with.
    # The staged copy beside kairo first, then the LLVM build's.
    for local in (os.path.join(os.path.dirname(kairo_bin), "clang" + _exe),
                  os.path.join(_llvm_bin, "clang" + _exe)):
        if ok(local):
            return local
    found = shutil.which("clang")
    return found if ok(found) else None

clang_bin = _find_clang()

def _bundled_default_target():
    """(triple, sysroot dir, manifest dict) for what a bare `kairo` compiles
    for, when that sysroot is a bundled one with a SYSROOT.toml; else None."""
    try:
        import tomllib
    except ImportError:  # Python < 3.11: keep the host-clang behaviour
        return None
    probe = os.path.join(config.test_exec_root, "Output", ".lit-probe.k")
    os.makedirs(os.path.dirname(probe), exist_ok=True)
    with open(probe, "w") as f:
        f.write("fn main() -> i32 { return 0; }\n")
    try:
        out = subprocess.run([kairo_bin, probe, "--print-dirs"] + kairo_roots.split(),
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    facts = {}
    for line in out.splitlines():
        k, sep, v = line.partition(":")
        if sep and k.strip() in ("target", "sysroot"):
            facts[k.strip()] = v.strip()
    sysroot = facts.get("sysroot", "")
    if not facts.get("target") or not sysroot.endswith("(manifest)"):
        return None
    sysroot = sysroot[:-len("(manifest)")].strip()
    try:
        with open(os.path.join(sysroot, "SYSROOT.toml"), "rb") as f:
            manifest = tomllib.load(f)
    except (OSError, ValueError):
        return None
    return facts["target"], sysroot, manifest

def _bundle_rt_dir(rd, triple, mtriple):
    """The resource dir clang should get for a bundle's compiler-rt.

    clang looks for crtbegin and the builtins only under lib/<its normalized
    triple>. The musl bundles name that dir x86_64-unknown-linux-musl, which
    is what clang looks for; the glibc ones name it vendorless
    (x86_64-linux-gnu), which no clang spelling of the default
    x86_64-unknown-linux-gnu finds. For those, a shim resource dir under the
    build tree whose lib/<triple> links to the bundle's own."""
    want = os.path.join(rd, "lib", triple)
    have = os.path.join(rd, "lib", mtriple)
    if os.path.isdir(want) or not mtriple or not os.path.isdir(have):
        return rd
    shim = os.path.join(_lit_state, "lit-compiler-rt", os.path.basename(os.path.dirname(rd)))
    link = os.path.join(shim, "lib", triple)
    try:
        if not os.path.isdir(link):
            os.makedirs(os.path.dirname(link), exist_ok=True)
            try:
                os.symlink(have, link, target_is_directory=True)
            except OSError:
                shutil.copytree(have, link)
    except OSError:
        return rd
    return shim

def _clangxx_for_bundle(clangxx, triple, sysroot, m):
    root = os.path.normpath(os.path.join(sysroot, m.get("sysroot", ".")))
    flags = ["--target=" + triple, "--sysroot=" + _sh(root)]
    if not m.get("has_libcxx", True):
        clangxx = clangxx.replace(" -stdlib=libc++", "")
    # The headers exactly as kairo searches them: libc++, then clang's own
    # builtin headers, then the C library -- libc++'s <stddef.h> wrappers
    # include_next past themselves and need that order.
    incs = [os.path.join(root, d) for d in m.get("include_dirs", [])]
    cxx = [d for d in incs if "c++" in d.replace("\\", "/").split("/")]
    res = _find_resource_dir()
    flags.append("-nostdinc")
    for d in cxx + ([os.path.join(res, "include")] if res else []) + \
             [d for d in incs if d not in cxx]:
        flags += ["-isystem", _sh(d)]
    # rtlib/unwinder come from the bundle; clang looks for the builtins
    # archive under its resource dir, so point that at the bundle's.
    if m.get("resource_dir"):
        flags.append("-resource-dir=" + _sh(_bundle_rt_dir(
            os.path.join(root, m["resource_dir"]), triple, m.get("triple", ""))))
    for key, flag in (("rtlib", "-rtlib="), ("unwindlib", "-unwindlib=")):
        if m.get(key):
            flags.append(flag + m[key])
    if m.get("linker"):
        flags.append("-fuse-ld=" + m["linker"])
    # The C++ runtime exactly as the manifest links it. clang's driver adds a
    # bare -lc++ for -stdlib=libc++, but a bundle whose libc++abi is its own
    # archive (operator new, the type_info vtables) needs -lc++abi too, which
    # kairo's linker takes from libcxx_link. -nostdlib++ drops clang's own
    # line (and its -lm, restored here). Order is safe: these come before the
    # objects on the command line, and lld resolves against earlier archives.
    if m.get("libcxx_link"):
        flags.append("-nostdlib++")
        flags += list(m["libcxx_link"])
        flags.append("-lm")
    # The runtime's mimalloc uses pthread keys and mutexes, and kairo's ELF
    # link passes -lpthread; a glibc before 2.34 (the bundled floor) keeps
    # them out of libc, so a link without it is undefined pthread_key_create.
    if not any(k in triple for k in ("windows", "mingw", "darwin", "apple", "wasi", "wasm")):
        flags.append("-pthread")
    # A static-only bundle may still carry import libs (libc++.dll.a), which
    # clang prefers, and the test exe then dies looking for libc++.dll.
    if m.get("static"):
        flags.append("-static")
    return clangxx + " " + " ".join(flags)

# `default-sysroot`: a bare `kairo` (no --target) finds a bundled sysroot for
# its default target, so tests that build for the host need no --target.
_bt = _bundled_default_target()
if _bt:
    config.available_features.add("default-sysroot")

if clang_bin:
    config.available_features.add("clang")
    config.substitutions.append(
        ("%parity", "%s %s '%s' %s" % (
            _sh(sys.executable),
            _sh(os.path.join(config.test_source_root, "parity_check.py")),
            _sh(kairo_bin) + _kairo_cpu + kairo_roots,  # one quoted command: kairo + its header roots
            _sh(clang_bin))))
    # A C++ driver for tests that compile kairo's emitted objects and LINK them
    # (Tests/codegen/operators). --driver-mode=g++ rather than a sibling
    # "clang++" path: clang_bin may have come from PATH or from --param, and
    # guessing a neighbour binary that may not exist turns a link test into a
    # confusing "file not found" instead of a clean UNSUPPORTED.
    #
    # -stdlib=libc++: kairo's objects are compiled against libc++'s headers
    # (<sysroot>/include/c++/v1, see ClangBackend), so they must link against
    # libc++. The driver's default on a GCC host is libstdc++, which links only
    # while no test happens to touch a std:: symbol -- then fails with
    # `std::__1::...` undefined.
    clangxx = _sh(clang_bin) + " --driver-mode=g++ -stdlib=libc++"
    # Without --target kairo compiles for its DEFAULT target against the
    # sysroot bundled for it (x86_64-pc-windows-gnu on a Windows host, not
    # clang's msvc), so its objects only link with a clang aimed the same
    # way: same triple, and that sysroot's libc++, rtlib, unwinder, linker
    # and include order, as its SYSROOT.toml spells them for kairo.
    if _bt:
        clangxx = _clangxx_for_bundle(clangxx, *_bt)
    # Darwin: a clang built in-tree has no default SDK, so without -isysroot
    # its link step finds no libSystem. The bundled sysroot IS an SDK copy
    # (SDKSettings.json, usr/lib/libSystem.tbd, usr/lib/libc++.a with the ABI
    # merged in), so link against the same roots kairo compiled against;
    # otherwise fall back to the toolchain's own SDK.
    elif sys.platform == "darwin":
        sdk = lit_config.params.get("sysroot", "")
        if not os.path.isfile(os.path.join(sdk, "SDKSettings.json")):
            try:
                sdk = subprocess.check_output(
                    ["xcrun", "--show-sdk-path"],
                    stderr=subprocess.DEVNULL).decode().strip()
            except (OSError, subprocess.CalledProcessError):
                sdk = ""
        if sdk:
            clangxx += " -isysroot " + sdk
    # A TU that includes an emitted header declares i256 / u512 as _BitInt(256)
    # / _BitInt(512). Where clang caps _BitInt below 512 by default (AArch64,
    # 32-bit Arm, WebAssembly) it gets Kairo's cap, as kcc's driver line does.
    try:
        _bw = subprocess.run(_shlex.split(clangxx) + ["-x", "c++", "-E", "-P", "-"],
                             input=b"__BITINT_MAXWIDTH__", stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL).stdout.decode().split()
        if _bw and _bw[-1].isdigit() and int(_bw[-1]) < 512:
            clangxx += " -Xclang -fexperimental-max-bitint-width=512"
    except OSError:
        pass
    config.substitutions.append(("%clangxx", clangxx))
    # The bare clang driver, for building native fixtures (a shared library
    # with a crafted version need) with no kairo roots in the way.
    config.substitutions.append(("%clang_c", _sh(clang_bin)))
else:
    # Leave a substitution that explains itself, in case a test forgets
    # `REQUIRES: clang` and runs anyway.
    config.substitutions.append(
        ("%parity", "echo 'parity needs clang; pass --param clang=/path or set "
                    "CLANG_BIN' >&2; false #"))
    config.substitutions.append(
        ("%clangxx", "echo 'this test needs clang; pass --param clang=/path or set "
                     "CLANG_BIN' >&2; false #"))

# --- Object inspection: %objdump, %nm ------------------------------------------
# Disassembly and symbol checks use LLVM's tools on every host: they read ELF,
# COFF and Mach-O alike and take the same flags everywhere (--show-all-symbols
# is not GNU objdump's, and GNU nm cannot read a Mach-O). Looked for as
# --param objdump= / nm=, then beside kairo (a staged tree has them, of the
# compiler's own LLVM), beside clang and beside FileCheck (an LLVM tree has
# them; Scripts/build_llvm.py builds them), then llvm-* on PATH, then a plain
# objdump / nm only where it IS LLVM's (macOS). Each found is a feature, so a
# test says `REQUIRES: llvm-objdump` and is UNSUPPORTED, not "command not
# found", without one.
def _find_llvm_tool(name):
    p = lit_config.params.get(name[len("llvm-"):])
    if p:
        if not os.path.isfile(p):
            lit_config.fatal("--param %s=%s does not exist" % (name[len("llvm-"):], p))
        return p
    exe = name + (".exe" if sys.platform == "win32" else "")
    for d in (os.path.dirname(kairo_bin),
              os.path.dirname(clang_bin) if clang_bin else None,
              os.path.dirname(os.path.abspath(filecheck_bin))):
        if d and os.path.isfile(os.path.join(d, exe)):
            return os.path.join(d, exe)
    found = shutil.which(name)
    if found:
        return found
    plain = shutil.which(name[len("llvm-"):])
    if plain:
        try:
            out = subprocess.run([plain, "--version"], capture_output=True,
                                 text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        if "LLVM" in out:
            return plain
    return None

for _tool, _sub in (("llvm-objdump", "%objdump"), ("llvm-nm", "%nm")):
    _p = _find_llvm_tool(_tool)
    if _p:
        config.available_features.add(_tool)
        config.substitutions.append((_sub, _sh(_p)))
    else:
        config.substitutions.append(
            (_sub, "echo 'this test needs %s; pass --param %s=/path' >&2; false #"
                   % (_tool, _tool[len("llvm-"):])))
# %s and %t are provided by lit automatically:
#   %s -> absolute path to the current test file
#   %t -> a temp path unique to this test (use for scratch output)