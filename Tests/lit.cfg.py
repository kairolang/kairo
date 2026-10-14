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
config.test_format = lit.formats.ShTest(execute_external=True)

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

# --- Substitutions -----------------------------------------------------------
# Plain-text substitution. Order matters only when one pattern is a prefix of
# another; ours are distinct, but list longest-first as habit.
# --- C++ header roots for ffi imports -----------------------------------------
# kairo takes its header-search roots ONLY from flags (no discovery), and ffi
# imports parse real headers, so the suite hard-passes them. Defaults: the
# host as sysroot (libc++ at /usr/include/c++/v1, libc at /usr/include) and
# the tree's own clang resource dir. Override: --param sysroot=/path,
# --param resource_dir=/path.
def _clang_roots():
    sysroot = lit_config.params.get("sysroot", "/usr")
    # A sysroot that does not exist is not an error to kairo (no system
    # headers, as with no --sysroot), so a stale path fails every ffi test
    # with a missing-header cascade instead of saying what is wrong.
    if not os.path.isdir(sysroot):
        lit_config.fatal("--param sysroot=%s is not a directory" % sysroot)
    res = lit_config.params.get("resource_dir")
    if not res:
        cands = sorted(glob.glob(os.path.join(
            config.test_source_root, "..", "build", "llvm", "lib", "clang", "*")))
        cands = [c for c in cands
                 if os.path.isfile(os.path.join(c, "include", "stddef.h"))]
        res = os.path.normpath(cands[-1]) if cands else ""
    roots = " --sysroot=%s" % sysroot
    if res:
        roots += " --resource-dir=%s" % res
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
        roots += " --builtins-dir=%s" % builtins
    # The std module tree, same story: an installed compiler finds it under
    # <resource-dir>/std, nothing in the build copies Lib/std there. The
    # driver registers it under the ROOT NAME `kairo::std`, so bare `std` in a
    # test is the prelude alias for it and `cxx::std` is C++'s.
    stdlib = os.path.normpath(
        os.path.join(config.test_source_root, "..", "Lib", "std"))
    if os.path.isdir(stdlib):
        roots += " --std-dir=%s" % stdlib
    return roots

kairo_roots = _clang_roots()

# A --target picks <prefix>/sysroot/<target> beside the compiler over the
# --sysroot above (CompilerInstance::_use_bundled_sysroot). Tests that compile
# for another target's C library need that directory, and fail with a
# confusing typedef clash rather than skip without it.
if os.path.isdir(os.path.join(os.path.dirname(os.path.dirname(kairo_bin)), "sysroot")):
    config.available_features.add("bundled-sysroot")

config.substitutions.append(("%kairo", kairo_bin + " --error-format=basic" + kairo_roots))

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
              "arm64": "aarch64", "aarch64": "aarch64"}.get(
    _platform.machine(), _platform.machine())
config.available_features.add("host-" + _host_arch)

# --- `timeout` on hosts without coreutils -------------------------------------
# Tests guard a parser that could hang with `timeout 10 %kairo ...; test $? -ne
# 124`. macOS ships no `timeout` (Homebrew coreutils has `gtimeout`), and a
# missing command fails the test with "command not found" -- which says nothing
# about kairo. Prepend a shim dir to the tests' PATH: a symlink to gtimeout
# where there is one, else a Python stand-in with the same exit code contract.
if not shutil.which("timeout"):
    _shim_dir = os.path.join(config.test_exec_root, "Output", ".lit-bin")
    os.makedirs(_shim_dir, exist_ok=True)
    _shim = os.path.join(_shim_dir, "timeout")
    _gtimeout = shutil.which("gtimeout")
    if _gtimeout:
        if os.path.islink(_shim) or os.path.exists(_shim):
            os.remove(_shim)
        os.symlink(_gtimeout, _shim)
    else:
        with open(_shim, "w") as f:
            f.write("""#!%s
import subprocess, sys
# timeout DURATION COMMAND [ARG]... -> 124 on expiry, else the command's status.
dur = float(sys.argv[1].rstrip("s"))
try:
    sys.exit(subprocess.call(sys.argv[2:], timeout=dur))
except subprocess.TimeoutExpired:
    sys.exit(124)
""" % sys.executable)
        os.chmod(_shim, 0o755)
    config.environment["PATH"] = _shim_dir + os.pathsep + config.environment.get(
        "PATH", os.environ.get("PATH", ""))
config.substitutions.append(("%FileCheck", filecheck_bin))

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
    local = os.path.normpath(
        os.path.join(config.test_source_root, "..", "build", "llvm", "bin", "clang"))
    if ok(local):
        return local
    found = shutil.which("clang")
    return found if ok(found) else None

clang_bin = _find_clang()
if clang_bin:
    config.available_features.add("clang")
    config.substitutions.append(
        ("%parity", "%s %s '%s' %s" % (
            sys.executable,
            os.path.join(config.test_source_root, "parity_check.py"),
            kairo_bin + kairo_roots,     # one quoted command: kairo + its header roots
            clang_bin)))
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
    clangxx = clang_bin + " --driver-mode=g++ -stdlib=libc++"
    # Darwin: a clang built in-tree has no default SDK, so without -isysroot
    # its link step finds no libSystem. The bundled sysroot IS an SDK copy
    # (SDKSettings.json, usr/lib/libSystem.tbd, usr/lib/libc++.a with the ABI
    # merged in), so link against the same roots kairo compiled against;
    # otherwise fall back to the toolchain's own SDK.
    if sys.platform == "darwin":
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
# %s and %t are provided by lit automatically:
#   %s -> absolute path to the current test file
#   %t -> a temp path unique to this test (use for scratch output)