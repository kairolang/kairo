#!/usr/bin/env python3
"""llvm_version_drift.py CLANG SCRIPT: the LLVM version the share tree's
templates write into every generated SYSROOT.toml (Scripts/
ship_sysroot_inputs.py: LLVM_VERSION and each template's llvm_version
line) against the LLVM the toolchain is built from (the staged clang
beside kairo, the same build/llvm the compiler links; Sdk.k's roots take
the number from llvm-config.h). Prints "same <version>" or every
disagreement."""
import re, subprocess, sys

clang, script = sys.argv[1], sys.argv[2]
out = subprocess.run([clang, "--version"], capture_output=True, text=True).stdout
m = re.search(r"clang version (\d+\.\d+\.\d+)", out)
if not m:
    sys.exit(f"no version in `{clang} --version`: {out!r}")
want = m.group(1)
text = open(script, encoding="utf-8").read()
seen = re.findall(r'^LLVM_VERSION = "([^"]*)"', text, re.M)
seen += re.findall(r'^llvm_version\s*=\s*"([^"]*)"', text, re.M)
if not seen:
    sys.exit(f"{script}: no LLVM version found")
bad = [v for v in seen if v != want]
if bad:
    print(f"drift: the toolchain is LLVM {want}, {script} says {sorted(set(bad))}")
else:
    print(f"same {want} ({len(seen)} sites)")
