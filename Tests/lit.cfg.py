# -*- Python -*-
# Lit configuration for the Kairo regression suite.
# Run with:  llvm-lit -v Tests/        (or: lit -v Tests/)
#
# Requires the `lit` and `filecheck` Python packages, OR LLVM's lit + FileCheck
# on PATH. We do NOT depend on llvm_config / an LLVM build tree.

import os
import shutil
import lit.formats

# --- Suite identity ----------------------------------------------------------
config.name = "Kairo"
config.test_format = lit.formats.ShTest(execute_external=True)

# --- Which files are tests ---------------------------------------------------
# Any .k file containing RUN: lines is a test. Subdirs without RUN-bearing
# files are just traversed.
config.suffixes = [".k"]

# Directories never scanned for tests (inputs/fixtures live here).
config.excludes = ["Inputs"]

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
    default = os.path.normpath(os.path.join(
        config.test_source_root, "..",
        "build", "x86_64-linux-gnu", "release", "bin", "kairo",
    ))

    # DO NOT fall through to PATH. A stale Stage 0 install at /usr/local/bin
    # will silently answer and you'll test the wrong compiler with the wrong
    # flags. Fail loudly instead.
    if not os.path.exists(default):
        lit_config.fatal(
            "Stage 1 kairo not found at {}. Build it first, or pass "
            "--param kairo=/abs/path / set KAIRO_BIN. (Refusing to fall back "
            "to PATH — a stale /usr/local/bin/kairo is Stage 0 and lacks "
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
config.substitutions.append(("%kairo", kairo_bin))
config.substitutions.append(("%FileCheck", filecheck_bin))

# %s and %t are provided by lit automatically:
#   %s -> absolute path to the current test file
#   %t -> a temp path unique to this test (use for scratch output)