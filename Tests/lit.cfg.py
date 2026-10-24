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
    config.test_format = lit.formats.ShTest(execute_external=True)
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
# Clang/ is proof/oracle material, not a suite; Manual/ is hand-run scratch.
# Bugs/Triage/ is a bug-reproducer corpus, not a lit suite: nearly every file
# in it is a known-failing case kept for triage, and its expected behaviour is
# whatever the issue says, not whatever the compiler currently prints.
# (Its sibling Bugs/Snapshots/ IS collected.)
config.excludes = ["Inputs", "Manual", "Clang", "Triage"]

# --- Where tests live --------------------------------------------------------
config.test_source_root = os.path.dirname(__file__)
config.test_exec_root = config.test_source_root  # run in-place; no build dir

# --- Locate the kairo binary -------------------------------------------------
# Priority: explicit param (--param kairo=/path) > env KAIRO_BIN > default build
# path > PATH lookup. Fail loudly if not found so a missing binary isn't a
# silent "0 tests".
def _find_kairo():
    # Explicit override always wins.
    p = lit_config.params.get("kairo")
    if p:
        return os.path.abspath(p)
    env = os.environ.get("KAIRO_BIN")
    if env:
        return os.path.abspath(env)

    # Default: the freshly-built Stage 1 binary. test_source_root is Tests/,
    # so repo root is one up.
    matches = sorted(
        p for p in glob.glob(os.path.join(
            config.test_source_root,
            "..",
            "build",
            "*",
            "release",
            "bin",
            "kairo*",
        ))
        if os.path.basename(p) in ("kairo", "kairo.exe")
    )

    if not matches:
        raise FileNotFoundError(
            "Could not locate Kairo compiler under build/*/release/bin/kairo"
        )

    default = os.path.normpath(matches[0])

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
# Exposed for lit.local.cfg files (they do not see this module's globals).
config.kairo_bin = kairo_bin
# --- Locate FileCheck --------------------------------------------------------
def _find_filecheck():
    p = lit_config.params.get("filecheck")
    if p:
        return p
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
# kairo takes its header-search roots ONLY from flags (no discovery), and ffi
# imports parse real headers, so the suite hard-passes them. Defaults: the
# host as sysroot (libc++ at /usr/include/c++/v1, libc at /usr/include) and
# the tree's own clang resource dir. Override: --param sysroot=/path,
# --param resource_dir=/path.
def _find_resource_dir():
    res = lit_config.params.get("resource_dir")
    if res:
        return res
    cands = sorted(glob.glob(os.path.join(
        config.test_source_root, "..", "build", "llvm", "lib", "clang", "*")))
    cands = [c for c in cands
             if os.path.isfile(os.path.join(c, "include", "stddef.h"))]
    return os.path.normpath(cands[-1]) if cands else ""

def _clang_roots():
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
    if os.path.isdir(builtins):
        roots += " --builtins-dir=%s" % _sh(builtins)
    # The std module tree, same story: an installed compiler finds it under
    # <resource-dir>/std, nothing in the build copies Lib/std there. The
    # driver registers it under the ROOT NAME `kairo::std`, so bare `std` in a
    # test is the prelude alias for it and `cxx::std` is C++'s.
    stdlib = os.path.normpath(
        os.path.join(config.test_source_root, "..", "Lib", "std"))
    if os.path.isdir(stdlib):
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

config.substitutions.append(("%kairo", _sh(kairo_bin) + " --error-format=basic" + kairo_roots))

# --- kcc ----------------------------------------------------------------------
# The clang drop-in, built beside kairo (Compiler/Driver/Kcc.k). It takes
# clang's options, so kairo's own words -- the same roots %kairo gets --
# go through -Xkairo, one word each. Tests that use it REQUIRE: kcc.
import shlex as _shlex
kcc_bin = os.path.join(os.path.dirname(kairo_bin), "kcc")
if os.path.isfile(kcc_bin):
    config.available_features.add("kcc")
    _kcc_x = "".join(" -Xkairo " + _sh(w) for w in ["--error-format=basic"] + _shlex.split(kairo_roots))
    config.substitutions.append(("%kcc", _sh(kcc_bin) + _kcc_x))
# A kcc link builds and caches the Kairo library (builtin, std, the runtime)
# on first use. One cache for the suite, under the build tree, never the
# user's ~/.cache; parallel tests that race to build it are safe (the
# library is renamed into place).
config.environment["KAIRO_CACHE_DIR"] = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(kairo_bin))), "lit-kairo-cache")

# --- C data model of the default target ---------------------------------------
# C `long` is 64-bit on LP64 (64-bit Linux, macOS) and 32-bit on LLP64
# (Windows) and ILP32 (32-bit targets), and kairo's emitted C++ spells i64 the
# way that target's int64_t is spelled. Tests that check either pass
# %datamodel to FileCheck and match [[CLONG]], [[CULONG]], [[CXX_I64]], so one
# test states the right answer on every target instead of only on LP64.
# (Not to kairo as -D types: a macro-expanded type does not yet bind an
# untyped literal the way the same type written out does.)
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
if "windows" in _dt or "mingw" in _dt or "msvc" in _dt:
    _long, _cxx_i64 = 32, "signed long long"  # LLP64
elif _dt_arch in ("i386", "i486", "i586", "i686", "x86", "riscv32", "wasm32") \
        or _dt_arch.startswith(("arm", "thumb")) and _dt_arch not in ("arm64", "arm64e"):
    _long, _cxx_i64 = 32, "signed long long"  # ILP32
else:
    _long, _cxx_i64 = 64, "signed long"       # LP64
config.substitutions.append(("%datamodel", "-DCLONG=i%d -DCULONG=u%d '-DCXX_I64=%s'"
                             % (_long, _long, _cxx_i64)))

# --- Host facts as lit features ---------------------------------------------
# For tests whose expectations are the HOST's ABI (f80 on x86, `long` int64_t,
# size_t == uint64_t): `REQUIRES: host-x86_64`, `REQUIRES: host-linux`, so an
# arm64 or Darwin host reports them UNSUPPORTED instead of failing on facts
# the test never claimed to hold there.
_host_os = {"linux": "linux", "darwin": "darwin", "win32": "windows"}.get(
    sys.platform, sys.platform)
config.available_features.add("host-" + _host_os)
import platform as _platform
_host_arch = {"x86_64": "x86_64", "amd64": "x86_64", "AMD64": "x86_64",
              "arm64": "aarch64", "aarch64": "aarch64", "ARM64": "aarch64"}.get(
    _platform.machine(), _platform.machine())
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
# Tests/Sema/RedeclMerge/parity/*.k each sit beside a .cpp that is the ORACLE:
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
    local = os.path.normpath(os.path.join(
        config.test_source_root, "..", "build", "llvm", "bin",
        "clang.exe" if sys.platform == "win32" else "clang"))
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
        flags.append("-resource-dir=" + _sh(os.path.join(root, m["resource_dir"])))
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
            _sh(kairo_bin) + kairo_roots,  # one quoted command: kairo + its header roots
            _sh(clang_bin))))
    # A C++ driver for tests that compile kairo's emitted objects and LINK them
    # (Tests/Codegen/operators). --driver-mode=g++ rather than a sibling
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
    config.substitutions.append(("%clangxx", clangxx))
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
# --param objdump= / nm=, then beside FileCheck and clang (an LLVM tree has
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
    for d in (os.path.dirname(os.path.abspath(filecheck_bin)),
              os.path.dirname(clang_bin) if clang_bin else None):
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