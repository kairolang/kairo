# -*- Python -*-
# Lit configuration for the Kairo regression suite.
# Run with:  llvm-lit -v Tests/        (or: lit -v Tests/)
#
# Requires the `lit` and `filecheck` Python packages, OR LLVM's lit + FileCheck
# on PATH. We do NOT depend on llvm_config / an LLVM build tree.

import os
import shutil
import glob
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

config.substitutions.append(("%kairo", kairo_bin + " --error-format=basic" + kairo_roots))
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
    config.substitutions.append(("%clangxx", clang_bin + " --driver-mode=g++"))
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