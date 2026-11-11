#!/usr/bin/env python3
"""Run the lit suite with every compile going through the AST round trip.

    python3 Scripts/lit_ast_roundtrip.py Tests -s [lit options ...]

is `llvm-lit Tests -s ...` with KAIRO_AST_ROUNDTRIP=1 in the environment of
every test command, so each kairo the suite starts serializes every parsed
file's AST, reads it back and continues with the reloaded tree
(Compiler/Spec/Serialization.md). The suite itself is not modified, and the
compiler under test is the one lit would pick anyway (KAIRO_BIN, or the
newest build).

Why a script and not `KAIRO_AST_ROUNDTRIP=1 llvm-lit Tests`: lit hands
tests a trimmed environment (Tests/lit.cfg.py forwards a fixed list), so a
variable set on lit's own command line never reaches the compiler, and the
run is the ordinary suite with a misleading name. This wrapper adds the
variable to the environment lit builds for the tests, before any config
file is read.

The gate it is for: the same binary, once through llvm-lit and once through
this, must give the same outcome for every test (`-o out.json` on both,
then compare the per-test codes).
"""

import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_lit():
    """Put the lit package llvm-lit uses on sys.path."""
    bundled = os.path.join(REPO, "Lib", "llvm-runtimes", "llvm", "utils", "lit")
    if os.path.isdir(os.path.join(bundled, "lit")):
        sys.path.insert(0, bundled)


def main():
    find_lit()
    try:
        import lit.TestingConfig as testing_config
        from lit.main import main as lit_main
    except ImportError:
        sys.exit("lit_ast_roundtrip: cannot import lit (looked in Lib/llvm-runtimes and sys.path)")

    defaults = testing_config.TestingConfig.fromdefaults

    def with_roundtrip(lit_config):
        config = defaults(lit_config)
        config.environment["KAIRO_AST_ROUNDTRIP"] = "1"
        return config

    testing_config.TestingConfig.fromdefaults = staticmethod(with_roundtrip)
    lit_main({"build_mode": ".", "config_map": {}})


if __name__ == "__main__":
    main()
