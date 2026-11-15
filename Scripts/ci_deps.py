#!/usr/bin/env python3
"""Pack and unpack the prebuilt cross LLVM trees for CI.

`build/cross-llvm/<triple>/llvm` is a CMake build directory (objects, an LTO
cache, ninja files). A Kairo build for that target reads a small part of it:
the generated headers, the static libraries, the clang resource directory,
the tools in bin/, and the zlib / zstd prefix beside it. `pack` archives that
part, one archive per target, so a CI job downloads only its own target.

Archives are tar + zstd: zstd decompresses at disk speed whatever level it
was written at, so the level only costs time here. Paths inside start at
`build/cross-llvm/<triple>/`, so an archive unpacks at the repository root.

    Scripts/ci_deps.py pack   [--out dist/ci-deps] [--level 19] [triple ...]
    Scripts/ci_deps.py unpack <archive>... [--root <repo>]
    Scripts/ci_deps.py list   [--out dist/ci-deps]

Each archive carries `build/cross-llvm/<triple>/PREBUILT`, naming the LLVM
fork commit it was built from. build.py takes a tree with that file as
up to date when the commit matches the checked-out fork, since the archive
has no ninja files to ask.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CROSS = ROOT / "build" / "cross-llvm"
LLVM_SRC = ROOT / "Lib" / "llvm-runtimes"
PREFIX = "kairo-cross-llvm-"
# Linked into nothing and shipped nowhere; a quarter of bin/.
SKIP_BIN = ("-fuzzer", "clang-import-test", "clang-diff")
LIB_EXT = (".a", ".lib", ".so", ".dylib", ".dll", ".def", ".tbd")


def die(msg):
    print(f"ci_deps: error: {msg}", file=sys.stderr)
    sys.exit(1)


def llvm_commit():
    r = subprocess.run(["git", "-C", str(LLVM_SRC), "rev-parse", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else "unknown"


def members(triple):
    """Paths, relative to ROOT, that a build for \\p triple reads."""
    base = CROSS / triple
    llvm = base / "llvm"
    if not (llvm / "lib" / "libLLVMCore.a").exists() and not (llvm / "lib" / "LLVMCore.lib").exists():
        die(f"{llvm} holds no built LLVM")
    out = []

    def tree(p):
        if p.exists():
            out.append(p)

    tree(llvm / "include")
    tree(llvm / "tools" / "clang" / "include")
    tree(llvm / "lib" / "clang")
    tree(llvm / "lib" / "cmake")
    tree(base / "deps" / "prefix")
    for f in sorted((llvm / "lib").iterdir()):
        if (f.is_file() or f.is_symlink()) and (f.name.endswith(LIB_EXT) or ".so." in f.name):
            out.append(f)
    for f in sorted((llvm / "bin").iterdir()):
        if not any(s in f.name for s in SKIP_BIN):
            out.append(f)
    for f in (base / "llvm-toolchain.cmake", base / "deps" / "toolchain.cmake", base / "PREBUILT"):
        if f.exists():
            out.append(f)
    return [str(p.relative_to(ROOT)) for p in out]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def pack(triples, out, level):
    for tool in ("tar", "zstd"):
        if not shutil.which(tool):
            die(f"{tool} not found")
    out.mkdir(parents=True, exist_ok=True)
    commit = llvm_commit()
    sums = []
    for t in triples:
        (CROSS / t / "PREBUILT").write_text(f"llvm {commit}\ntriple {t}\n")
        files = members(t)
        lst = out / f".{t}.files"
        lst.write_text("\n".join(files) + "\n")
        dst = out / f"{PREFIX}{t}.tar.zst"
        tmp = dst.with_suffix(".zst.part")
        t0 = time.time()
        # --long=27 is the largest window every zstd decompresses without a flag.
        tar = subprocess.Popen(["tar", "-C", str(ROOT), "-cf", "-", "--owner=0", "--group=0",
                                "--numeric-owner", "-T", str(lst)], stdout=subprocess.PIPE)
        with open(tmp, "wb") as f:
            z = subprocess.run(["zstd", "-T0", f"-{level}", "--long=27", "-q", "-c"], stdin=tar.stdout, stdout=f)
        tar.stdout.close()
        if tar.wait() != 0 or z.returncode != 0:
            die(f"packing {t} failed")
        tmp.replace(dst)
        lst.unlink()
        # The stamp belongs to the archive: left in a real build tree it would
        # stand in for ninja's own answer.
        if (CROSS / t / "llvm" / "build.ninja").exists():
            (CROSS / t / "PREBUILT").unlink()
        digest = sha256(dst)
        sums.append(f"{digest}  {dst.name}")
        print(f"{t}: {dst.stat().st_size / 2**20:.0f} MiB in {time.time() - t0:.0f} s", flush=True)
    done = {l.split("  ")[1]: l for l in (out / "SHA256SUMS").read_text().splitlines()} \
        if (out / "SHA256SUMS").exists() else {}
    for l in sums:
        done[l.split("  ")[1]] = l
    (out / "SHA256SUMS").write_text("\n".join(done[k] for k in sorted(done)) + "\n")
    (out / "LLVM_COMMIT").write_text(commit + "\n")


def unpack(archives, root):
    for a in archives:
        t0 = time.time()
        z = subprocess.Popen(["zstd", "-dc", "-T0", str(a)], stdout=subprocess.PIPE)
        r = subprocess.run(["tar", "-C", str(root), "-xf", "-"], stdin=z.stdout)
        z.stdout.close()
        if z.wait() != 0 or r.returncode != 0:
            die(f"unpacking {a} failed")
        print(f"{Path(a).name}: unpacked in {time.time() - t0:.1f} s", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack")
    p.add_argument("triples", nargs="*")
    p.add_argument("--out", default=str(ROOT / "dist" / "ci-deps"))
    p.add_argument("--level", type=int, default=19)
    u = sub.add_parser("unpack")
    u.add_argument("archives", nargs="+")
    u.add_argument("--root", default=str(ROOT))
    l = sub.add_parser("list")
    l.add_argument("--out", default=str(ROOT / "dist" / "ci-deps"))
    a = ap.parse_args()
    if a.cmd == "pack":
        triples = a.triples or sorted(d.name for d in CROSS.iterdir() if (d / "llvm" / "lib").is_dir())
        pack(triples, Path(a.out), a.level)
    elif a.cmd == "unpack":
        unpack(a.archives, Path(a.root))
    else:
        for f in sorted(Path(a.out).glob(PREFIX + "*.tar.zst")):
            print(f"{f.stat().st_size / 2**20:8.0f} MiB  {f.name}")


if __name__ == "__main__":
    main()
