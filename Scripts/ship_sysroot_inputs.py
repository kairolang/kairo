#!/usr/bin/env python3
"""Build the `kairo sysroot` input tree (Compiler/Spec/SysRoot.md section 3).

    python3 Scripts/ship_sysroot_inputs.py                  # build/sysroot-share
    python3 Scripts/ship_sysroot_inputs.py --report         # + size report and parity check
    python3 Scripts/ship_sysroot_inputs.py --only mingw     # rebuild one input family
                                  # (--only leaves provenance.toml as the last full run wrote it)

Maintainer tool, never shipped. It replaces the 18 prebuilt cross sysroots a release
carries with the inputs the generator builds them from. Everything comes from disk; nothing
is fetched. Sources, in the order kairo-sysroots' curate/ scripts consumed them:

  musl/           Lib/libc/musl (1.2.6), without git and docs
  linux-uapi/     the kernel headers of the curated *-linux-musl roots, split into the part
                  every arch shares and asm/ (plus arch-only headers) per arch
  glibc/2.31/<a>/ kairo-sysroots extract/<a>-...-glibc2.31 (Ubuntu focal libc6-dev):
                  usr/include verbatim, crt objects, libc_nonshared.a; abilist/ read from
                  the curated roots' focal DSOs (Scripts/glibc_stubs.py). --report rebuilds
                  every stub DSO from the shipped abilists and compares it with the original.
  mingw/          headers from the curated windows-gnu roots (identical on every arch, so
                  shipped once), def/<a>/ preprocessed from Lib/libc/mingw's mingw-w64-crt
                  (in git, outside the sparse checkout) and kept only where llvm-dlltool
                  regenerates the curated import library exactly, crt/<a>/ = every other
                  archive and object of the curated lib/ verbatim
  freebsd/, netbsd/  build/sysgen/bsd-trim/<name> when bsd-trim/DONE exists, else the curated
                  root; minus libcxx/, compiler-rt/ and usr/include/c++ (built from runtimes)
  wasi/33/        the curated wasm32-wasi root minus noeh/ and compiler-rt/
  families/ quirks.toml shims/ validate/   written from the tables in this file; each recipe
                  renders the curated SYSROOT.toml byte for byte (checked by --report)

runtimes/ is not copied: build/sysroot-share/FORMAT.md lets the reader fall back to the
sibling share/kairo/runtimes that package_release.py already ships. Its hash is computed
from a fresh package_release.stage_runtimes() under the scratch dir.

The output contract is build/sysroot-share/FORMAT.md (shared with the Linker/Sysroot
reader); this script never rewrites that file. Output is deterministic: registry.toml and
every tree hash are byte-identical across runs.
"""
import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
import glibc_stubs  # noqa: E402

LLVM_VERSION = "22.1.0"
GLIBC_VERSIONS = ["2.31"]                  # the only version any source on disk covers
MUSL_ARCH = {"x86_64": "x86_64", "i686": "i386", "aarch64": "aarch64", "armv7": "arm",
             "armv6": "arm", "riscv64": "riscv64", "riscv32": "riscv32"}
# Kernel headers_install output depends only on the kernel ARCH (the x86_64 and i686 roots
# carry identical asm/), so arches without a curated root take their kernel twin's set.
UAPI_TWIN = {"armv6": "armv7", "riscv32": "riscv64"}
UAPI_DIRS = ("asm", "asm-generic", "linux", "drm", "misc", "mtd", "rdma", "scsi", "sound",
             "video", "xen", "cxl", "fwctl", "regulator")
MINGW_ARCHES = ["x86_64", "i686", "aarch64", "armv7"]
MINGW_LIBDIR = {"x86_64": "lib64", "i686": "lib32", "armv7": "libarm32", "aarch64": None}
MINGW_DLLTOOL_M = {"x86_64": "i386:x86-64", "i686": "i386", "armv7": "arm", "aarch64": "arm64"}
# What the runtimes stage builds; never an input.
MINGW_FROM_RUNTIMES = {"libc++.a", "libc++abi.a", "libc++experimental.a", "libunwind.a",
                       "libc++.dll.a", "libunwind.dll.a", "libc++.modules.json"}
BSD = {"freebsd": ("14.4", ["x86_64", "aarch64"]), "netbsd": ("10.1", ["x86_64"])}
WASI_VERSION = "33"

LICENSES = {   # input key prefix -> SPDX (sources.toml in kairo-sysroots)
    "musl": "MIT",
    "linux-uapi": "GPL-2.0-only WITH Linux-syscall-note",
    "glibc": "LGPL-2.1-or-later",
    "mingw": "ZPL-2.1 AND LicenseRef-mingw-w64-public-domain",
    "freebsd": "BSD-2-Clause",
    "netbsd": "BSD-2-Clause",
    "wasi": "Apache-2.0 WITH LLVM-exception AND MIT AND CC0-1.0",
    "runtimes": "Apache-2.0 WITH LLVM-exception",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def die(msg: str) -> None:
    sys.exit(f"ship_sysroot_inputs: {msg}")


# ---------------------------------------------------------------- hashing (FORMAT.md)

def file_sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_sha256(root: Path) -> str:
    """FORMAT.md's algorithm, byte for byte: follow symlinks, skip dangling ones."""
    rels = []
    for d, _, files in os.walk(root, followlinks=True):
        for f in files:
            p = os.path.join(d, f)
            if os.path.isfile(p):
                rels.append(os.path.relpath(p, root).replace(os.sep, "/"))
    h = hashlib.sha256()
    for r in sorted(rels, key=lambda r: r.encode()):
        h.update(r.encode() + b"\n")
        h.update(file_sha256(root / r).encode() + b"\n")
    return h.hexdigest()


# ---------------------------------------------------------------- copying

def fresh(p: Path) -> Path:
    if p.is_symlink() or p.is_file():
        p.unlink()
    elif p.exists():
        shutil.rmtree(p)
    p.mkdir(parents=True)
    return p


def copy_tree(src: Path, dst: Path, skip=lambda rel: False) -> None:
    """Content-only copy (no mtimes or modes beyond the exec bit), symlinks kept as links.
    `skip(rel)` sees '/'-separated paths relative to src; a skipped dir prunes its subtree."""
    for d, dirs, files in os.walk(src):
        reld = os.path.relpath(d, src).replace(os.sep, "/")
        reld = "" if reld == "." else reld + "/"
        keep = []
        for n in sorted(dirs):
            if skip(reld + n):
                continue
            s = Path(d, n)
            if s.is_symlink():          # os.walk lists a dir link as a dir; keep it a link
                (dst / (reld + n)).parent.mkdir(parents=True, exist_ok=True)
                os.symlink(os.readlink(s), dst / (reld + n))
                continue
            keep.append(n)
        dirs[:] = keep
        (dst / reld).mkdir(parents=True, exist_ok=True)
        for n in sorted(files):
            if skip(reld + n):
                continue
            s, t = Path(d, n), dst / (reld + n)
            if s.is_symlink():
                os.symlink(os.readlink(s), t)
            else:
                shutil.copyfile(s, t)
                os.chmod(t, 0o755 if os.access(s, os.X_OK) else 0o644)


def sweep_links(root: Path, dropped: list) -> None:
    """An input may hold only relative links that resolve inside it: absolute, escaping and
    dangling ones are removed and reported (the generated root would not have them either)."""
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = Path(d, n)
            if not p.is_symlink():
                continue
            t = os.readlink(p)
            res = os.path.normpath(os.path.join(d, t))
            inside = res == str(root) or res.startswith(str(root) + os.sep)
            if os.path.isabs(t) or not inside or not os.path.exists(p):
                dropped.append(f"{p.relative_to(root).as_posix()} -> {t}")
                p.unlink()


def remove_empty_dirs(root: Path) -> None:
    for d, dirs, files in os.walk(root, topdown=False):
        if d != str(root) and not os.listdir(d):
            os.rmdir(d)


# ---------------------------------------------------------------- static data

# Template variables in recipes: {arch} {name} {triple} {clang_triple} {libc_version}
# {os_version}, plus one per [per_arch.<var>] table. FORMAT.md's TOML subset: no inline
# tables, no arrays of tables, versions as strings.

FAMILIES = {}

FAMILIES["musl"] = '''\
# Linux / musl. Reference invocations: kairo-sysroots curate/musl.sh (layout, [toml]),
# build-builtins.sh (builtins), fetch-musl-libcxx.sh + fetch-musl-compiler-rt.sh (the curated
# roots took libc, libc++ and crtbegin/end from Alpine; the generator builds all of them).
family       = "musl"
provider     = "musl"
arches       = ["x86_64", "i686", "aarch64", "armv7", "armv6", "riscv64", "riscv32"]
name         = "{arch}-linux-musl"
triple       = "{arch}-linux-musl"
clang_triple = "{arch}-unknown-linux-musl"        # armv7/armv6: quirk armv7-musl-hardfloat
inputs       = ["musl", "linux-uapi"]
runtimes     = ["libunwind", "libcxxabi", "libcxx"]
crt_objects  = true                               # clang_rt.crtbegin.o / crtend.o
cxx_abi      = "libcxxabi"
sysname      = "Linux"
os_dir       = "linux"
static_only  = true
# musl.sh:74 names the dir after the arch, not the clang triple: armv7 is
# armv7-unknown-linux-musl although it is compiled as ...-musleabihf.
resource_layout = "compiler-rt/lib/{arch}-unknown-linux-musl"
builtins_name   = "libclang_rt.builtins.a"

[per_arch.musl_arch]                              # ARCH= for musl's Makefile (section 4.4)
x86_64  = "x86_64"
i686    = "i386"
aarch64 = "aarch64"
armv7   = "arm"
armv6   = "arm"
riscv64 = "riscv64"
riscv32 = "riscv32"

[libc]                                            # section 4.6, musl provider
configure = ["--target={clang_triple}", "--disable-shared"]
cflags    = ["-O2", "-fPIC"]
targets   = ["lib/libc.a", "lib/crt1.o", "lib/Scrt1.o", "lib/rcrt1.o", "lib/crti.o", "lib/crtn.o", "lib/libcrypt.a", "lib/libdl.a", "lib/libm.a", "lib/libpthread.a", "lib/libresolv.a", "lib/librt.a", "lib/libutil.a", "lib/libxnet.a"]
uapi      = ["linux-uapi/generic", "linux-uapi/asm/{arch}"]   # copied in this order into include/

[builtins]                                        # build-builtins.sh:75-92
source     = "compiler-rt/lib/builtins"
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "COMPILER_RT_DEFAULT_TARGET_ONLY=ON", "COMPILER_RT_INCLUDE_TESTS=OFF", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF"]
c_flags    = ["-nostdlibinc", "-isystem", "{stage}/include"]
cxx_flags  = ["-nostdlibinc", "-nostdinc++", "-isystem", "{stage}/include"]
asm_flags  = ["-nostdlibinc", "-isystem", "{stage}/include"]
assert_cache_regex = ["COMPILER_RT_HAS_[a-z0-9_]+_BFLOAT16:INTERNAL=1"]   # build-builtins.sh:95

[runtimes_cmake]                                  # as glibc (build-glibc-runtimes.sh); the
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "CMAKE_POSITION_INDEPENDENT_CODE=ON", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF", "LLVM_INCLUDE_TESTS=OFF", "COMPILER_RT_BUILD_CRT=ON", "COMPILER_RT_BUILD_SANITIZERS=OFF", "COMPILER_RT_BUILD_XRAY=OFF", "COMPILER_RT_BUILD_LIBFUZZER=OFF", "COMPILER_RT_BUILD_PROFILE=OFF", "COMPILER_RT_BUILD_MEMPROF=OFF", "COMPILER_RT_BUILD_ORC=OFF", "COMPILER_RT_BUILD_CTX_PROFILE=OFF", "COMPILER_RT_INCLUDE_TESTS=OFF", "LIBUNWIND_ENABLE_SHARED=OFF", "LIBUNWIND_USE_COMPILER_RT=ON", "LIBCXXABI_ENABLE_SHARED=OFF", "LIBCXXABI_USE_LLVM_UNWINDER=ON", "LIBCXXABI_USE_COMPILER_RT=ON", "LIBCXX_ENABLE_SHARED=OFF", "LIBCXX_CXX_ABI=libcxxabi", "LIBCXX_USE_COMPILER_RT=ON", "LIBCXX_INCLUDE_BENCHMARKS=OFF", "LIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF"]
c_flags    = ["-fPIC"]                            # curated musl runtimes were Alpine's (no
cxx_flags  = ["-fPIC"]                            # fork recipe); this mirrors the glibc one

[layout]                                          # section 4.8
include = ["include"]
lib     = ["lib"]
gather  = ["lib/libc++.a", "lib/libc++abi.a", "lib/libunwind.a", "lib/libc++experimental.a", "include/c++/v1"]

[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "linux-musl"
sysroot       = "."
include_dirs  = ["include/c++/v1", "include"]
lib_dirs      = ["lib"]
has_libcxx    = true
static        = true
crt_startup   = ["crt1.o", "crti.o"]
crt_end       = ["crtn.o"]
libc_link     = ["-lc"]
libcxx_link   = ["-lc++", "-lc++abi", "-lunwind"]
rtlib         = "compiler-rt"
unwindlib     = "libunwind"
linker        = "lld"
resource_dir  = "compiler-rt"
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]

[validate]
run = "native-or-qemu"
'''

FAMILIES["glibc"] = '''\
# Linux / glibc. Reference invocations: kairo-sysroots curate/glibc.sh (layout, [toml]),
# fetch-glibc.sh (Ubuntu focal inputs), build-glibc-runtimes.sh (builtins + crt + C++ runtimes
# in one runtimes configure, against the floor version).
family       = "glibc"
provider     = "glibc"
arches       = ["x86_64", "i686", "aarch64", "armv7", "riscv64"]
name         = "{triple}-glibc{libc_version}"
triple       = "{per_arch.triple}"                # glibc.sh triple_of(): the name minus -glibc<v>
clang_triple = "{triple}"                         # build-glibc-runtimes.sh:58 passes it as is
inputs       = ["glibc/{libc_version}/{arch}", "linux-uapi"]
runtimes     = ["libunwind", "libcxxabi", "libcxx"]
crt_objects  = true
runtimes_libc_version = "floor"
cxx_abi      = "libcxxabi"
sysname      = "Linux"
os_dir       = "linux"
static_only  = true
resource_layout = "compiler-rt/lib/{triple}"
builtins_name   = "libclang_rt.builtins.a"

[per_arch.triple]
x86_64  = "x86_64-linux-gnu"
i686    = "i686-linux-gnu"
aarch64 = "aarch64-linux-gnu"
armv7   = "armv7-linux-gnueabihf"
riscv64 = "riscv64-linux-gnu"

[per_arch.multiarch]                              # glibc.sh:65 (the dir holding crt1.o)
x86_64  = "x86_64-linux-gnu"
i686    = "i386-linux-gnu"
aarch64 = "aarch64-linux-gnu"
armv7   = "arm-linux-gnueabihf"
riscv64 = "riscv64-linux-gnu"

[libc]                                            # section 4.6, glibc provider
include = "glibc/{libc_version}/{arch}/include"   # carries its own UAPI (linux/version.h)
crt     = "glibc/{libc_version}/{arch}/crt"
nonshared = "glibc/{libc_version}/{arch}/libc_nonshared.a"
abilist = "glibc/{libc_version}/{arch}/abilist"   # <stem>.abilist + <stem>.compat, libs.toml (FORMAT.md)

[builtins]                                        # built inside the runtimes configure
source     = "runtimes"
cmake_defs = ["COMPILER_RT_BUILD_BUILTINS=ON", "COMPILER_RT_DEFAULT_TARGET_ONLY=ON"]

[runtimes_cmake]                                  # build-glibc-runtimes.sh:52-91
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "CMAKE_POSITION_INDEPENDENT_CODE=ON", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF", "LLVM_INCLUDE_TESTS=OFF", "COMPILER_RT_BUILD_CRT=ON", "COMPILER_RT_BUILD_SANITIZERS=OFF", "COMPILER_RT_BUILD_XRAY=OFF", "COMPILER_RT_BUILD_LIBFUZZER=OFF", "COMPILER_RT_BUILD_PROFILE=OFF", "COMPILER_RT_BUILD_MEMPROF=OFF", "COMPILER_RT_BUILD_ORC=OFF", "COMPILER_RT_BUILD_CTX_PROFILE=OFF", "COMPILER_RT_INCLUDE_TESTS=OFF", "LIBUNWIND_ENABLE_SHARED=OFF", "LIBUNWIND_USE_COMPILER_RT=ON", "LIBCXXABI_ENABLE_SHARED=OFF", "LIBCXXABI_USE_LLVM_UNWINDER=ON", "LIBCXXABI_USE_COMPILER_RT=ON", "LIBCXX_ENABLE_SHARED=OFF", "LIBCXX_CXX_ABI=libcxxabi", "LIBCXX_USE_COMPILER_RT=ON", "LIBCXX_INCLUDE_BENCHMARKS=OFF", "LIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF"]
c_flags    = ["-fPIC"]
cxx_flags  = ["-fPIC"]

[layout]
include = ["include"]
lib     = ["lib"]
gather  = ["lib/libc++.a", "lib/libc++abi.a", "lib/libunwind.a", "lib/libc++experimental.a", "include/c++/v1"]

[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "linux-gnu"
glibc_version = "{libc_version}"
sysroot       = "."
include_dirs  = ["include/c++/v1", "include/{per_arch.multiarch}", "include"]
lib_dirs      = ["lib"]
has_libcxx    = true
static        = false
crt_startup   = ["crt1.o", "crti.o"]
crt_end       = ["crtn.o"]
libc_link     = ["-lm", "-lpthread", "-ldl", "-lc"]
libcxx_link   = ["-lc++", "-lc++abi", "-lunwind"]
rtlib         = "compiler-rt"
unwindlib     = "libunwind"
linker        = "lld"
resource_dir  = "compiler-rt"
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]

[validate]
run = "native-or-qemu-with-root"
'''

FAMILIES["mingw"] = '''\
# Windows / MinGW-w64 (UCRT). Reference invocations: kairo-sysroots curate/mingw.sh (layout,
# [toml]; the curated roots are llvm-mingw 20260224's per-arch trees), build-builtins.sh
# (builtins), ship-mingw.sh (the def/ + crt/ split).
family       = "mingw"
provider     = "mingw"
arches       = ["x86_64", "i686", "aarch64", "armv7"]
name         = "{arch}-windows-gnu"
triple       = "{arch}-windows-gnu"
clang_triple = "{arch}-w64-windows-gnu"           # build-builtins.sh:55
inputs       = ["mingw"]
runtimes     = ["libunwind", "libcxxabi", "libcxx"]
crt_objects  = false                              # crtbegin.o / crtend.o come from crt/<arch>
cxx_abi      = "libcxxabi"
cxxabi_merged_into_cxx = true                     # libc++.a carries the abi, as llvm-mingw's
sysname      = "Windows"
os_dir       = "windows"
static_only  = true
resource_layout = "compiler-rt/lib/windows"
builtins_name   = "libclang_rt.builtins-{per_arch.rt_arch}.a"

[per_arch.rt_arch]                                # build-builtins.sh:57
x86_64  = "x86_64"
i686    = "i386"
aarch64 = "aarch64"
armv7   = "arm"

[per_arch.dlltool_machine]                        # llvm-dlltool -m
x86_64  = "i386:x86-64"
i686    = "i386"
aarch64 = "arm64"
armv7   = "arm"

[libc]                                            # section 4.6, mingw provider
include = "mingw/include"                         # one set: byte-identical on all four arches
defs    = "mingw/def/{arch}"                      # kar --dlltool -m {dlltool_machine} -k -d X.def -l libX.a
dlltool_flags = ["-k"]                            # mingw-w64-crt Makefile.am AM_DLLTOOLFLAGS
crt     = "mingw/crt/{arch}"                      # copied into lib/ verbatim

[builtins]                                        # build-builtins.sh:75-92
source     = "compiler-rt/lib/builtins"
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "COMPILER_RT_DEFAULT_TARGET_ONLY=ON", "COMPILER_RT_INCLUDE_TESTS=OFF", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF"]
c_flags    = ["-nostdlibinc", "-isystem", "{stage}/include"]
cxx_flags  = ["-nostdlibinc", "-nostdinc++", "-isystem", "{stage}/include"]
asm_flags  = ["-nostdlibinc", "-isystem", "{stage}/include"]
assert_cache_regex = ["COMPILER_RT_HAS_[a-z0-9_]+_BFLOAT16:INTERNAL=1"]

[runtimes_cmake]                                  # no fork recipe: the curated libc++ is llvm-mingw's
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF", "LLVM_INCLUDE_TESTS=OFF", "LIBUNWIND_ENABLE_SHARED=OFF", "LIBUNWIND_USE_COMPILER_RT=ON", "LIBCXXABI_ENABLE_SHARED=OFF", "LIBCXXABI_USE_LLVM_UNWINDER=ON", "LIBCXXABI_USE_COMPILER_RT=ON", "LIBCXX_ENABLE_SHARED=OFF", "LIBCXX_CXX_ABI=libcxxabi", "LIBCXX_USE_COMPILER_RT=ON", "LIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON", "LIBCXX_INCLUDE_BENCHMARKS=OFF"]

[layout]
include = ["include"]
lib     = ["lib"]
gather  = ["lib/libc++.a", "lib/libunwind.a", "include/c++/v1"]

[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "windows-gnu"
sysroot       = "."
include_dirs  = ["include/c++/v1", "include"]
lib_dirs      = ["lib"]
has_libcxx    = true
static        = true
crt_startup   = ["crt2.o", "crtbegin.o"]
crt_end       = ["crtend.o"]
libc_link     = ["-lmingw32", "-lmoldname", "-lmingwex", "-lmsvcrt", "-ladvapi32", "-lshell32", "-luser32", "-lkernel32"]
libcxx_link   = ["-lc++", "-lunwind"]
rtlib         = "compiler-rt"
unwindlib     = "libunwind"
linker        = "lld"
resource_dir  = "compiler-rt"
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]

[validate]
run = "wine-if-present"
'''

_BSD_RUNTIMES = '''\
[builtins]                                        # built inside the runtimes configure
source     = "runtimes"
cmake_defs = ["COMPILER_RT_BUILD_BUILTINS=ON", "COMPILER_RT_DEFAULT_TARGET_ONLY=ON"]

[runtimes_cmake]                                  # build-bsd-runtimes.sh:119-158
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "CMAKE_POSITION_INDEPENDENT_CODE=ON", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF", "LLVM_INCLUDE_TESTS=OFF", "COMPILER_RT_BUILD_CRT=OFF", "COMPILER_RT_BUILD_SANITIZERS=OFF", "COMPILER_RT_BUILD_XRAY=OFF", "COMPILER_RT_BUILD_LIBFUZZER=OFF", "COMPILER_RT_BUILD_PROFILE=OFF", "COMPILER_RT_BUILD_MEMPROF=OFF", "COMPILER_RT_BUILD_ORC=OFF", "COMPILER_RT_BUILD_CTX_PROFILE=OFF", "COMPILER_RT_INCLUDE_TESTS=OFF", "LIBUNWIND_ENABLE_SHARED=OFF", "LIBUNWIND_USE_COMPILER_RT=ON", "LIBCXXABI_ENABLE_SHARED=OFF", "LIBCXXABI_USE_LLVM_UNWINDER=ON", "LIBCXXABI_USE_COMPILER_RT=ON", "LIBCXX_ENABLE_SHARED=OFF", "LIBCXX_CXX_ABI=libcxxabi", "LIBCXX_USE_COMPILER_RT=ON", "LIBCXX_INCLUDE_BENCHMARKS=OFF", "LIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF"]
c_flags    = ["-fPIC"]
cxx_flags  = ["-fPIC"]

[bundle_layout]                                   # input subdir = root subdir, copied verbatim
"usr/include" = "usr/include"
"usr/lib"     = "usr/lib"
"lib"         = "lib"

[layout]                                          # build-bsd-runtimes.sh:177-185
include = ["libcxx/include"]
lib     = ["libcxx/lib"]
gather  = ["lib/libc++.a", "lib/libc++abi.a", "lib/libunwind.a", "include/c++/v1"]
'''

FAMILIES["freebsd"] = '''\
# FreeBSD base. Reference invocations: kairo-sysroots curate/freebsd.sh (layout),
# build-bsd-runtimes.sh (builtins + C++ runtimes, [toml]), ship-bsd.sh (pruning).
family       = "freebsd"
provider     = "bundle"
arches       = ["x86_64", "aarch64"]
os_version   = "14.4"
name         = "{arch}-unknown-freebsd"
triple       = "{arch}-unknown-freebsd"
clang_triple = "{arch}-unknown-freebsd{os_version}"   # build-bsd-runtimes.sh:40
inputs       = ["freebsd/{os_version}/{arch}"]
runtimes     = ["libunwind", "libcxxabi", "libcxx"]
crt_objects  = false
cxx_abi      = "libcxxabi"
sysname      = "FreeBSD"
os_dir       = "freebsd"
static_only  = true
resource_layout = "compiler-rt/lib/freebsd"
builtins_name   = "libclang_rt.builtins-{arch}.a"

''' + _BSD_RUNTIMES + '''
[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "freebsd"
sysroot       = "."
include_dirs  = ["libcxx/include/c++/v1", "usr/include"]
lib_dirs      = ["libcxx/lib", "usr/lib", "lib"]
has_libcxx    = true
static        = true
crt_startup   = ["crt1.o", "crti.o"]
crt_end       = ["crtn.o"]
libc_link     = ["-lm", "-lthr", "-lc"]
libcxx_link   = ["-lc++", "-lc++abi", "-lunwind"]
rtlib         = "compiler-rt"
unwindlib     = "libunwind"
linker        = "lld"
resource_dir  = "compiler-rt"
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]

[validate]
run = "link-only"
'''

FAMILIES["netbsd"] = '''\
# NetBSD base. Reference invocations: kairo-sysroots curate/netbsd.sh (layout),
# build-bsd-runtimes.sh (builtins + C++ runtimes, [toml]), ship-bsd.sh (pruning).
family       = "netbsd"
provider     = "bundle"
arches       = ["x86_64"]
os_version   = "10.1"
name         = "{arch}-unknown-netbsd"
triple       = "{arch}-unknown-netbsd"
clang_triple = "{arch}-unknown-netbsd{os_version}"
inputs       = ["netbsd/{os_version}/{arch}"]
runtimes     = ["libunwind", "libcxxabi", "libcxx"]
crt_objects  = false
cxx_abi      = "libcxxabi"
sysname      = "NetBSD"
os_dir       = "netbsd"
static_only  = true
resource_layout = "compiler-rt/lib/netbsd"
builtins_name   = "libclang_rt.builtins-{arch}.a"

''' + _BSD_RUNTIMES + '''
[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "netbsd"
sysroot       = "."
include_dirs  = ["libcxx/include/c++/v1", "usr/include"]
lib_dirs      = ["libcxx/lib", "usr/lib", "lib"]
has_libcxx    = true
static        = true
crt_startup   = ["crt0.o", "crti.o"]
crt_end       = ["crtn.o"]
libc_link     = ["-lm", "-lpthread", "-lc"]
libcxx_link   = ["-lc++", "-lc++abi", "-lunwind"]
rtlib         = "compiler-rt"
unwindlib     = "libunwind"
linker        = "lld"
resource_dir  = "compiler-rt"
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]

[validate]
run = "link-only"
'''

FAMILIES["wasi"] = '''\
# WASI (wasi-sdk 33). Reference invocations: kairo-sysroots curate/wasi.sh (layout, [toml]),
# build-wasi-builtins.sh (builtins). libc++ is the bundle's EH build (same fork commit).
family       = "wasi"
provider     = "bundle"
arches       = ["wasm32"]
os_version   = "33"
name         = "wasm32-wasi"
triple       = "wasm32-wasi"
clang_triple = "wasm32-unknown-wasi"
inputs       = ["wasi/{os_version}"]
runtimes     = []                                 # the builtins stage (4.5) still runs cmake
crt_objects  = false
cxx_abi      = "libcxxabi"
sysname      = "WASI"
os_dir       = "wasi"
static_only  = true
baremetal    = true
resource_layout = "compiler-rt/lib/wasm32-unknown-wasi"
builtins_name   = "libclang_rt.builtins.a"

[bundle_layout]
"include" = "include"
"lib"     = "lib"

[builtins]                                        # build-wasi-builtins.sh:54-68
source     = "compiler-rt/lib/builtins"
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "COMPILER_RT_BAREMETAL_BUILD=ON", "COMPILER_RT_DEFAULT_TARGET_ONLY=ON", "COMPILER_RT_INCLUDE_TESTS=OFF", "COMPILER_RT_OS_DIR=wasi", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF"]
c_flags    = ["-isystem", "{stage}/include/wasm32-wasi"]
assert_cache_regex = ["COMPILER_RT_HAS_wasm32_BFLOAT16:INTERNAL=1"]   # build-wasi-builtins.sh:71

[layout]
include = ["include"]
lib     = ["lib"]
gather  = []

[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "wasi"
sysroot       = "."
include_dirs  = ["include/wasm32-wasi/eh/c++/v1", "include/wasm32-wasi"]
lib_dirs      = ["lib/wasm32-wasi/eh", "lib/wasm32-wasi"]
has_libcxx    = true
static        = false
crt_startup   = ["crt1-command.o"]
crt_end       = []
libc_link     = ["-lc"]
libcxx_link   = ["-lc++", "-lc++abi", "-lunwind"]
extra_cflags  = ["-fwasm-exceptions"]
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]
rtlib         = "compiler-rt"
resource_dir  = "compiler-rt"

[validate]
run = "wasmtime-or-node-if-present"
'''

FAMILIES["msvc"] = '''\
# Windows / MSVC. User provider: the Microsoft CRT + Windows SDK come from --input (an xwin
# splat) and are never shipped. Reference invocation: kairo-sysroots curate/msvc.sh
# (stage_msvc, build_runtimes, add_tf_compare_aliases, emit_toml).
family       = "msvc"
provider     = "user"
user_input   = "xwin splat (xwin --accept-license --arch ... splat --output DIR)"
user_input_marker = "sdk/include/um/Windows.h"
arches       = ["x86_64", "i686", "aarch64"]
name         = "{arch}-windows-msvc"
triple       = "{arch}-windows-msvc"
clang_triple = "{arch}-pc-windows-msvc"
inputs       = []
runtimes     = ["libcxx"]
crt_objects  = false
cxx_abi      = "vcruntime"
driver       = "cl"
sysname      = "Windows"
os_dir       = "windows"
static_only  = true
resource_layout = "compiler-rt/lib/windows"
builtins_name   = "clang_rt.builtins-{arch}.lib"
local_only      = ["msvc"]

[per_arch.xa]                                     # xwin's arch spelling (msvc.sh:258-260)
x86_64  = "x86_64"
i686    = "x86"
aarch64 = "aarch64"

[user]                                            # msvc.sh stage_msvc
headers_all_arches = ["crt/include", "sdk/include/ucrt", "sdk/include/um", "sdk/include/shared", "sdk/include/winrt"]
libs_this_arch     = ["crt/lib/{per_arch.xa}", "sdk/lib/um/{per_arch.xa}", "sdk/lib/ucrt/{per_arch.xa}"]
dest               = "msvc"

[builtins]                                        # built inside the runtimes configure
source     = "runtimes"
cmake_defs = ["COMPILER_RT_BUILD_BUILTINS=ON", "COMPILER_RT_DEFAULT_TARGET_ONLY=ON"]

[runtimes_cmake]                                  # msvc.sh build_runtimes
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME=Windows", "CMAKE_SYSTEM_VERSION=10.0", "CMAKE_USER_MAKE_RULES_OVERRIDE={runtimes}/llvm/cmake/platforms/ClangClCMakeCompileRules.cmake", "CMAKE_C_STANDARD_LIBRARIES=", "CMAKE_CXX_STANDARD_LIBRARIES=", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "CMAKE_POLICY_DEFAULT_CMP0091=NEW", "CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF", "LLVM_INCLUDE_TESTS=OFF", "COMPILER_RT_BUILD_CRT=OFF", "COMPILER_RT_BUILD_SANITIZERS=OFF", "COMPILER_RT_BUILD_XRAY=OFF", "COMPILER_RT_BUILD_LIBFUZZER=OFF", "COMPILER_RT_BUILD_PROFILE=OFF", "COMPILER_RT_BUILD_MEMPROF=OFF", "COMPILER_RT_BUILD_ORC=OFF", "COMPILER_RT_BUILD_CTX_PROFILE=OFF", "COMPILER_RT_INCLUDE_TESTS=OFF", "LIBCXX_CXX_ABI=vcruntime", "LIBCXX_ENABLE_SHARED=OFF", "LIBCXX_ENABLE_STATIC=ON", "LIBCXX_INCLUDE_TESTS=OFF", "LIBCXX_INCLUDE_BENCHMARKS=OFF"]
c_flags    = ["-imsvc", "{stage}/msvc/crt/include", "-imsvc", "{stage}/msvc/sdk/include/ucrt", "-imsvc", "{stage}/msvc/sdk/include/um", "-imsvc", "{stage}/msvc/sdk/include/shared"]
cxx_flags  = ["-imsvc", "{stage}/msvc/crt/include", "-imsvc", "{stage}/msvc/sdk/include/ucrt", "-imsvc", "{stage}/msvc/sdk/include/um", "-imsvc", "{stage}/msvc/sdk/include/shared"]
linker_flags = ["/libpath:{stage}/msvc/crt/lib/{per_arch.xa}", "/libpath:{stage}/msvc/sdk/lib/um/{per_arch.xa}", "/libpath:{stage}/msvc/sdk/lib/ucrt/{per_arch.xa}"]

[layout]
include = ["include"]
lib     = ["lib"]
gather  = ["lib/libc++.lib", "include/c++/v1"]

[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "windows-msvc"
sysroot       = "."
include_dirs  = ["include/c++/v1", "msvc/crt/include", "msvc/sdk/include/ucrt", "msvc/sdk/include/um", "msvc/sdk/include/shared"]
lib_dirs      = ["lib", "msvc/crt/lib/{per_arch.xa}", "msvc/sdk/lib/um/{per_arch.xa}", "msvc/sdk/lib/ucrt/{per_arch.xa}"]
has_libcxx    = true
static        = true
crt_startup   = []
crt_end       = []
libc_link     = ["libcmt.lib", "libvcruntime.lib", "libucrt.lib", "oldnames.lib", "kernel32.lib", "user32.lib", "advapi32.lib", "shell32.lib", "uuid.lib"]
libcxx_link   = ["libc++.lib", "libcpmt.lib"]
rtlib         = "compiler-rt"
linker        = "lld-link"
resource_dir  = "compiler-rt"
msvc_crt      = "static"
local_only    = ["msvc"]
cc_defines    = ["_CRT_STDIO_ISO_WIDE_SPECIFIERS"]
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]

[validate]
run = "native-if-host"
'''

FAMILIES["darwin"] = '''\
# macOS. User provider, host only: the SDK comes from --input (xcrun --sdk macosx
# --show-sdk-path) and is never shipped. Reference invocation: kairo-sysroots curate/darwin.sh
# (stage_sdk, build_libcxx, build_tf_builtins, emit_toml).
family       = "darwin"
provider     = "user"
user_input   = "macOS SDK (xcrun --sdk macosx --show-sdk-path)"
user_input_marker = "SDKSettings.json"
host_only    = "darwin"
arches       = ["arm64", "arm64e", "x86_64"]
name         = "{arch}-apple-macosx"
triple       = "{arch}-apple-macosx"
clang_triple = "{arch}-apple-macos{per_arch.min_macos}"
inputs       = []
runtimes     = ["libcxx", "libcxxabi"]
crt_objects  = false
cxx_abi      = "libcxxabi"
cxx_hermetic = true
cxxabi_merged_into_cxx = true
sysname      = "Darwin"
os_dir       = "darwin"
static_only  = true
resource_layout = "clang/lib/darwin"
builtins_name   = "libclang_rt.osx.a"
redistributable = false

[per_arch.min_macos]                              # darwin.sh MIN_MACOS defaults
arm64   = "11.0"
arm64e  = "11.0"
x86_64  = "10.15"

[per_arch.fp_arch]                                # darwin.sh:139-142 (fp_mode.c source dir)
arm64   = "aarch64"
arm64e  = "aarch64"
x86_64  = "i386"

[user]                                            # darwin.sh stage_sdk
copy_files   = ["SDKSettings.json", "SDKSettings.plist"]
exclude      = ["usr/include/c++/", "usr/lib/swift/", "usr/lib/libc++*.tbd", "*.swiftmodule", "*.swiftinterface", "*.swiftdoc", "*.abi.json"]
trees        = ["usr/include", "usr/lib", "System/Library/Frameworks"]

[builtins]                                        # darwin.sh build_tf_builtins: no cmake
source     = "subset"
subset     = ["@GENERIC_TF_SOURCES", "@BF16_SOURCES", "{per_arch.fp_arch}/fp_mode.c"]
c_flags    = ["-O2", "-fPIC", "-ffreestanding", "-fno-builtin", "-fvisibility=hidden"]
archive    = "darwin"                             # llvm-ar --format=darwin + llvm-ranlib
required_symbols = ["___addtf3", "___fe_getround", "___truncsfbf2"]

[runtimes_cmake]                                  # darwin.sh build_libcxx
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_OSX_ARCHITECTURES={arch}", "CMAKE_OSX_DEPLOYMENT_TARGET={per_arch.min_macos}", "LIBCXX_ENABLE_SHARED=OFF", "LIBCXXABI_ENABLE_SHARED=OFF", "LIBCXX_ENABLE_STATIC=ON", "LIBCXXABI_ENABLE_STATIC=ON", "LIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON", "LIBCXX_HERMETIC_STATIC_LIBRARY=ON", "LIBCXXABI_USE_LLVM_UNWINDER=OFF", "LIBCXX_INCLUDE_TESTS=OFF", "LIBCXX_INCLUDE_BENCHMARKS=OFF", "LIBCXXABI_INCLUDE_TESTS=OFF", "LIBCXX_INSTALL_LIBRARY_DIR=lib", "LIBCXXABI_INSTALL_LIBRARY_DIR=lib", "LIBCXX_INSTALL_INCLUDE_DIR=include/c++/v1", "LIBCXX_INSTALL_INCLUDE_TARGET_DIR=include/c++/v1"]

[layout]
include = ["usr/include"]
lib     = ["usr/lib"]
gather  = ["lib/libc++.a", "include/c++/v1"]

[toml]
triple        = "{triple}"
llvm_version  = "22.1.0"
family        = "darwin"
sysroot       = "."
resource_dir  = "clang"
include_dirs  = ["usr/include/c++/v1", "usr/include"]
lib_dirs      = ["usr/lib"]
has_libcxx    = true
static        = false
crt_startup   = []
crt_end       = []
libc_link     = ["-lSystem"]
libcxx_link   = ["-lc++"]
rtlib         = "compiler-rt"
linker        = "lld"
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]

[validate]
run = "native-if-host"
'''

QUIRKS = '''\
# Per-target special cases, extracted from kairo-sysroots curate/*.sh. Schema: FORMAT.md
# ("quirks.toml"). Each entry cites the script lines it encodes. Family-wide settings that
# the scripts apply unconditionally live in the family recipe, not here.
#
# Not expressible in this schema, so kept in the recipes instead:
#   - the bf16 configure assertion (build-builtins.sh:95, build-wasi-builtins.sh:71):
#     [builtins] assert_cache_regex
#   - glibc armv7 = gnueabihf (fetch-glibc.sh:28, glibc.sh triple_of): [per_arch.triple]
#   - the post_archive shim compiles with -I<runtimes>/compiler-rt/lib/builtins and the
#     builtins stage's own flags (msvc.sh:211-214)

# build-builtins.sh:48-50, fetch-musl-compiler-rt.sh:25: Alpine armv7 is AAPCS-VFP
# (musleabihf); a plain -musl triple makes clang assume soft-float, another call ABI.
[quirk.armv7-musl-hardfloat]
match_family   = ["musl"]
match_arch     = ["armv7", "armv6"]
target_rewrite = "{arch}-unknown-linux-musleabihf"
musl_arch      = "arm"

# build-builtins.sh:72-89 (-fforce-enable-int128 + SOFTWARE_INT128, every musl/mingw arch),
# build-glibc-runtimes.sh:19-22,72, build-bsd-runtimes.sh:130,138. The scripts pass it on
# every arch; it only changes anything where __int128 is not native, hence the probe.
[quirk.int128-software]
match_family  = ["musl", "glibc", "mingw", "freebsd", "netbsd", "wasi"]
match_probe   = ["!int128"]
cflags_stages = ["builtins", "runtimes"]
cflags_add    = ["-fforce-enable-int128"]
cmake_stages  = ["builtins"]
cmake_defs    = ["COMPILER_RT_ENABLE_SOFTWARE_INT128=ON"]

# msvc.sh:107-112: clang-cl drops the plain spelling ("unknown argument"), and on i686 the
# __int128 and quad-float routines then compile empty.
[quirk.int128-software-cl]
match_family  = ["msvc"]
match_probe   = ["!int128"]
cflags_stages = ["builtins", "runtimes"]
cflags_add    = ["-Xclang", "-fforce-enable-int128"]
cmake_stages  = ["builtins"]
cmake_defs    = ["COMPILER_RT_ENABLE_SOFTWARE_INT128=ON"]

# build-builtins.sh:65, build-bsd-runtimes.sh:84, msvc.sh:266, darwin.sh check_float128:
# without the fork's __float128 on the target the TF sources compile empty.
[quirk.float128-required]
match_family    = ["musl", "mingw", "freebsd", "netbsd", "msvc", "darwin"]
assert_compiles = ["__float128 kairo_q(__float128 x) { return x + x; }"]

# build-builtins.sh:59-61,107: MinGW has no libatomic; __atomic_* live in the builtins.
[quirk.mingw-atomics-in-builtins]
match_family     = ["mingw"]
cmake_stages     = ["builtins"]
cmake_defs       = ["COMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF"]
required_symbols = ["__atomic_load", "__atomic_compare_exchange"]

# msvc.sh:185-221 (add_tf_compare_aliases): COMPILER_RT_ALIAS is empty on _WIN32, so the
# comparetf2.c aliases do not exist; the shim forwards them, merged into the archive.
[quirk.coff-tf-compare-aliases]
match_family     = ["msvc"]
post_archive     = "shims/tf-compare-aliases.c"
required_symbols = ["__eqtf2", "__netf2", "__lttf2", "__gttf2", "__cmptf2"]

# msvc.sh:177-178: a __config_site without it imports __imp_ symbols from a missing DLL.
[quirk.msvc-config-site-static]
match_family         = ["msvc"]
assert_file_contains = ["include/c++/v1/__config_site:_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS"]

# build-bsd-runtimes.sh:91-108: libunwind's aarch64 SME probe calls getauxval(); FreeBSD 14
# has only elf_aux_info(). Force-included into the C++ compiles.
[quirk.freebsd-aarch64-getauxval]
match_family         = ["freebsd"]
match_arch           = ["aarch64"]
force_include_stages = ["runtimes"]
force_include_file   = "shims/freebsd-getauxval.h"

# build-bsd-runtimes.sh:109-114 (kairo-lang P460): dlopen is in libc; a compile-only
# try_compile still finds libdl and libunwind then demands one no static link can give.
[quirk.netbsd-no-libdl]
match_family = ["netbsd"]
cmake_stages = ["runtimes"]
cmake_defs   = ["LIBUNWIND_HAS_DL_LIB=OFF"]

# build-bsd-runtimes.sh:116-118,131: the base tree's own c++/v1 (libc++ 19 on FreeBSD) must
# not shadow ours during the runtimes build.
[quirk.bsd-nostdincxx]
match_family   = ["freebsd", "netbsd"]
cflags_stages  = ["runtimes"]
cflags_add_cxx = ["-nostdinc++"]

# build-wasi-builtins.sh:39-48: the WebAssembly backend must legalize bf16 or the configure
# check reads as no. The script compiles both functions at -O0 and at -O2.
[quirk.wasm-bf16-lowering]
match_arch      = ["wasm32"]
assert_compiles = ["__bf16 f(__bf16 x) { return x; }", "__bf16 g(float x) { return (__bf16)x; }"]
'''

SHIMS = {
    # build-bsd-runtimes.sh:99-106, verbatim
    "freebsd-getauxval.h": "#pragma once\n#include <sys/auxv.h>\nstatic inline unsigned long getauxval(int type) {\n"
                           "  unsigned long v = 0;\n  return elf_aux_info(type, &v, sizeof v) == 0 ? v : 0;\n}\n",
    # msvc.sh:195-210, verbatim
    "tf-compare-aliases.c": "#define QUAD_PRECISION\n#include \"fp_lib.h\"\n#if defined(CRT_HAS_TF_MODE)\n"
                            "#include \"fp_compare_impl.inc\"\n"
                            "COMPILER_RT_ABI CMP_RESULT __letf2(fp_t a, fp_t b);\n"
                            "COMPILER_RT_ABI CMP_RESULT __getf2(fp_t a, fp_t b);\n"
                            "COMPILER_RT_ABI CMP_RESULT __cmptf2(fp_t a, fp_t b) { return __letf2(a, b); }\n"
                            "COMPILER_RT_ABI CMP_RESULT __eqtf2(fp_t a, fp_t b) { return __letf2(a, b); }\n"
                            "COMPILER_RT_ABI CMP_RESULT __lttf2(fp_t a, fp_t b) { return __letf2(a, b); }\n"
                            "COMPILER_RT_ABI CMP_RESULT __netf2(fp_t a, fp_t b) { return __letf2(a, b); }\n"
                            "COMPILER_RT_ABI CMP_RESULT __gttf2(fp_t a, fp_t b) { return __getf2(a, b); }\n"
                            "#else\n#error \"no TF mode: __float128 / int128 missing on this target\"\n#endif\n",
}

VALIDATE = {
    # replay-validate.sh:89-93
    "t.c": "#include <stdio.h>\n#include <string.h>\n"
           "int main(void) { char b[16]; strcpy(b, \"hello-c\"); return (int)strlen(b); }\n",
    # replay-validate.sh:72-85
    "t.cpp": "#include <string>\n#include <vector>\n#include <stdexcept>\nint main() {\n  try {\n"
             "    std::vector<std::string> v;\n    v.push_back(\"hello-libcxx\");\n"
             "    throw std::runtime_error(v[0]);\n  } catch (const std::exception &e) {\n"
             "    return (int)std::string(e.what()).size();\n  }\n  return -1;\n}\n",
    # Scripts/smoke_release.py's hello.k
    "test.k": "import std::io\n\nfn main() -> i32 {\n    io::println(\"Hello from Kairo\")\n    return 0\n}\n",
    # f16 -> f64 and f32 -> f64 arithmetic: 2.5 + 2.5 + 0.5 truncates to 5
    "floats.k": "fn main() -> i32 {\n    var x: f64 = 2.5\n    var y: f32 = 2.5\n    var z: f16 = 0.5\n"
                "    var s: f64 = x + (y as f64) + (z as f64)\n    return s as i32\n}\n",
    # f128 arithmetic and an f32 -> bf16 truncation: __addtf3 / __truncsfbf2 from the builtins
    "tfbf.k": "fn main() -> i32 {\n    var a: f128 = 1.5\n    var b: f128 = a + 2.25\n"
              "    var h: bf16 = (b as f32) as bf16\n    var back: f32 = h\n"
              "    if back > 3.0 && b != a {\n        return 1\n    }\n    return 0\n}\n",
    # Exit codes as strings: FORMAT.md's TOML subset carries no numbers that matter.
    "expect.toml": "# exit code each program must return when the validate stage runs it (section 4.10)\n"
                   "[exit]\n\"t.c\"      = \"7\"\n\"t.cpp\"    = \"12\"\n\"test.k\"   = \"0\"\n"
                   "\"floats.k\" = \"5\"\n\"tfbf.k\"   = \"1\"\n\n"
                   "# defined (T) in every builtins archive (section 4.5); quirks add more.\n"
                   "# build-builtins.sh:106, build-bsd-runtimes.sh:173, build-wasi-builtins.sh:80\n"
                   "[symbols]\nbase_required = [\"__addtf3\", \"__netf2\", \"__divti3\", \"__extendhfsf2\", "
                   "\"__truncsfhf2\", \"__truncsfbf2\", \"__truncdfbf2\", \"__trunctfbf2\"]\n",
}


# ---------------------------------------------------------------- recipes -> SYSROOT.toml

def load_recipe(text: str) -> dict:
    return tomllib.loads(text)


def subst(s: str, env: dict) -> str:
    def rep(m):
        k = m.group(1)
        if k not in env:
            raise KeyError(f"template variable {{{k}}} unbound")
        return env[k]
    for _ in range(3):              # {name} expands to {triple}... expands to {per_arch.x}
        s2 = re.sub(r"\{([a-z_.]+)\}", rep, s)
        if s2 == s:
            return s
        s = s2
    return s


def target_env(rec: dict, arch: str, libc_version: str = "") -> dict:
    env = {"arch": arch, "libc_version": libc_version, "os_version": rec.get("os_version", "")}
    for var, table in rec.get("per_arch", {}).items():
        if arch in table:
            env[f"per_arch.{var}"] = table[arch]
    env["triple"] = subst(rec["triple"], env)
    env["name"] = subst(rec["name"], env)
    env["clang_triple"] = subst(rec["clang_triple"], env)
    return env


def render_toml(rec: dict, env: dict) -> str:
    out = []
    for k, v in rec["toml"].items():
        if isinstance(v, bool):
            val = "true" if v else "false"
        elif isinstance(v, list):
            val = "[" + ", ".join(f'"{subst(x, env)}"' for x in v) + "]"
        else:
            val = f'"{subst(v, env)}"'
        out.append(f"{k:<13} = {val}")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- ar / COFF import parsing

def ar_members(data: bytes):
    """(name, payload) for every member of a GNU/BSD archive, symbol tables skipped."""
    if not data.startswith(b"!<arch>\n"):
        return None
    pos, longnames, out = 8, b"", []
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        name = hdr[:16].decode("latin-1").rstrip()
        size = int(hdr[48:58].decode().strip())
        body = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)
        if name in ("/", "/SYM64/", "__.SYMDEF", "__.SYMDEF SORTED"):
            continue
        if name == "//":
            longnames = body
            continue
        if name.startswith("#1/"):
            n = int(name[3:])
            name, body = body[:n].rstrip(b"\0").decode("latin-1"), body[n:]
        elif name.startswith("/") and name[1:].isdigit():
            off = int(name[1:])
            # GNU ends a long name with "/\n", the COFF flavour with "\0"
            end = min((i for i in (longnames.find(b"\n", off), longnames.find(b"\0", off)) if i >= 0),
                      default=len(longnames))
            name = longnames[off:end].decode("latin-1").rstrip("/")
        else:
            name = name.rstrip("/")
        out.append((name, body))
    return out


def short_import(body: bytes):
    """The (symbol, dll, type, name_type, ordinal-if-by-ordinal, export_as) of a short
    import member, or None. The hint is left out: it is a def-file index, not an ABI."""
    if len(body) < 20 or body[:4] != b"\0\0\xff\xff":
        return None
    ordhint, bits = struct.unpack_from("<HH", body, 16)
    names = body[20:].split(b"\0")
    typ, ntype = bits & 3, (bits >> 2) & 7
    return (names[0].decode("latin-1"), names[1].decode("latin-1"), typ, ntype,
            ordhint if ntype == 0 else -1, names[2].decode("latin-1") if ntype == 4 else "")


def coff_idata_only(body: bytes) -> bool:
    """A regular COFF member holding only .idata$N sections: the descriptor / null-thunk
    objects dlltool adds to an import library."""
    if len(body) < 20:
        return False
    nsec, opt = struct.unpack_from("<H", body, 2)[0], struct.unpack_from("<H", body, 16)[0]
    if nsec == 0 or 20 + opt + 40 * nsec > len(body):
        return False
    for i in range(nsec):
        n = body[20 + opt + 40 * i: 20 + opt + 40 * i + 8].rstrip(b"\0")
        if not n.startswith(b".idata$"):
            return False
    return True


def import_entries(path: Path):
    """Sorted import tuples if `path` is a pure import library, else None."""
    members = ar_members(path.read_bytes())
    if not members:
        return None
    ents = []
    for _, body in members:
        si = short_import(body)
        if si:
            ents.append(si)
        elif not coff_idata_only(body):
            return None
    return sorted(ents) if ents else None


# ---------------------------------------------------------------- inputs

class Ctx:
    def __init__(self, a):
        self.share = a.out.resolve()
        self.scratch = a.scratch.resolve()
        self.curated = a.curated.resolve()
        self.ksys = a.kairo_sysroots.resolve()
        self.bsd_trim = a.bsd_trim.resolve()
        self.cc = a.cc
        self.prov = {}          # input key -> list of provenance lines
        self.dropped_links = {}
        self.mingw_defs = {}    # arch -> {lib name: def name}
        self.glibc_stub_ok = {}  # arch -> {curated DSO file name: abilist stem} (stubs proven equal)


def build_data(c: Ctx) -> None:
    fam = fresh(c.share / "families")
    for name, text in sorted(FAMILIES.items()):
        load_recipe(text)                       # must parse
        (fam / f"{name}.toml").write_text(text)
    tomllib.loads(QUIRKS)
    (c.share / "quirks.toml").write_text(QUIRKS)
    for d, files in (("shims", SHIMS), ("validate", VALIDATE)):
        out = fresh(c.share / d)
        for n, t in sorted(files.items()):
            (out / n).write_text(t)
    g = c.share / "glibc"
    g.mkdir(exist_ok=True)
    vs = ", ".join(f'"{v}"' for v in GLIBC_VERSIONS)
    (g / "VERSIONS.toml").write_text(
        "# glibc versions this share tree carries. ship-glibc.sh wants 2.28 (floor) .. 2.41;\n"
        "# only 2.31 has a source on disk (Ubuntu focal), so it is floor, default and only.\n"
        f"versions = [{vs}]\nfloor    = \"{GLIBC_VERSIONS[0]}\"\ndefault  = \"{GLIBC_VERSIONS[0]}\"\n")


def build_musl(c: Ctx) -> None:
    src = ROOT / "Lib" / "libc" / "musl"
    out = fresh(c.share / "musl")
    docs = {"README", "INSTALL", "WHATSNEW"}
    copy_tree(src, out, lambda r: r.split("/")[0].startswith(".git") or r in docs)
    if not (out / "configure").is_file() or not (out / "arch" / "riscv32").is_dir():
        die("Lib/libc/musl is not a musl tree")
    rev = subprocess.run(["git", "-C", str(src), "rev-parse", "--short=12", "HEAD"], capture_output=True,
                         text=True).stdout.strip() or "?"
    c.prov["musl"] = [f"Lib/libc/musl VERSION {(src / 'VERSION').read_text().strip()} (git {rev}), "
                      "minus .git*, README, INSTALL, WHATSNEW"]


def musl_headers(c: Ctx, musl_arch: str) -> Path:
    """musl's own `make install-headers` for one ARCH (no compiler needed)."""
    b = fresh(c.scratch / "musl-hdr" / f"b-{musl_arch}")
    h = c.scratch / "musl-hdr" / f"h-{musl_arch}"
    if h.exists():
        shutil.rmtree(h)
    src = ROOT / "Lib" / "libc" / "musl"
    subprocess.run(["make", "-s", "-C", str(b), "-f", str(src / "Makefile"), f"srcdir={src}",
                    f"ARCH={musl_arch}", "install-headers", f"DESTDIR={h}", "prefix=/"],
                   check=True, stdout=subprocess.DEVNULL)
    return h / "include"


def build_uapi(c: Ctx) -> None:
    """Kernel headers = a curated musl root's include/ minus what musl installs minus c++/."""
    out = fresh(c.share / "linux-uapi")
    per_arch = {}
    for arch in ("x86_64", "i686", "aarch64", "armv7", "riscv64"):
        inc = c.curated / f"{arch}-linux-musl" / "include"
        files = {}
        for d, _, fs in os.walk(inc):
            for f in fs:
                rel = os.path.relpath(os.path.join(d, f), inc).replace(os.sep, "/")
                if rel.split("/")[0] in UAPI_DIRS:
                    files[rel] = file_sha256(inc / rel)
        per_arch[arch] = files
    # generic = non-asm files present on every arch, identical everywhere
    nonasm = [{r: h for r, h in fs.items() if not r.startswith("asm/")} for fs in per_arch.values()]
    common = set.intersection(*(set(f) for f in nonasm))
    for r in sorted(common):
        if len({f[r] for f in nonasm}) != 1:
            die(f"linux-uapi: {r} differs between arches; the generic split is wrong")
        dst = out / "generic" / r
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(c.curated / "x86_64-linux-musl" / "include" / r, dst)
    extra = []
    for arch in ("x86_64", "i686", "aarch64", "armv7", "riscv64", "armv6", "riscv32"):
        twin = UAPI_TWIN.get(arch, arch)
        inc = c.curated / f"{twin}-linux-musl" / "include"
        for r in sorted(per_arch[twin]):
            if r in common:
                continue
            dst = out / "asm" / arch / r
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(inc / r, dst)
            if not r.startswith("asm/") and arch == twin:
                extra.append(f"{arch}:{r}")
    ver = (out / "generic" / "linux" / "version.h").read_text()
    m = re.search(r"LINUX_VERSION_MAJOR (\d+).*?PATCHLEVEL (\d+).*?SUBLEVEL (\d+)", ver, re.S)
    c.prov["linux-uapi"] = [
        f"kernel {'.'.join(m.groups()) if m else '?'} headers_install output, taken from the curated "
        "*-linux-musl roots' include/ (Alpine linux-headers) minus musl's own headers and c++/",
        "generic/ = files every arch has (checked identical); asm/<arch>/ = asm/ plus arch-only "
        "headers (" + ", ".join(extra) + "); copy generic/ then every entry of asm/<arch>/",
        "asm/armv6 = asm/armv7 and asm/riscv32 = asm/riscv64 (kernel ARCH twins; x86_64 and i686 "
        "roots carry identical asm/, which is what makes this sound)"]


def build_glibc(c: Ctx) -> None:
    rec = load_recipe(FAMILIES["glibc"])
    for v in GLIBC_VERSIONS:
        for arch in rec["arches"]:
            env = target_env(rec, arch, v)
            name = env["name"]
            ex = c.ksys / "extract" / name
            ma = env["per_arch.multiarch"]
            if not (ex / "usr" / "lib" / ma / "crt1.o").is_file():
                die(f"no glibc extract at {ex}")
            out = fresh(c.share / "glibc" / v / arch)
            copy_tree(ex / "usr" / "include", out / "include")
            (out / "crt").mkdir()
            libdir = ex / "usr" / "lib" / ma
            for o in sorted(libdir.glob("*.o")):
                shutil.copyfile(o, out / "crt" / o.name)
            shutil.copyfile(libdir / "libc_nonshared.a", out / "libc_nonshared.a")
            key = f"glibc/{v}/{arch}"
            sweep_links(out, c.dropped_links.setdefault(key, []))
            if not (out / "include" / ma / "gnu" / "lib-names.h").is_file():
                die(f"{key}: no gnu/lib-names.h")
            libs = write_abilists(c, out, ma, c.curated / name / "lib")
            c.prov[key] = [f"kairo-sysroots extract/{name} (Ubuntu focal libc6-dev + linux-libc-dev): "
                           "usr/include verbatim (multiarch dir kept), usr/lib/<multiarch>/*.o, libc_nonshared.a",
                           f"abilist/: read from the curated root's focal DSOs ({', '.join(libs)}) by "
                           "Scripts/glibc_stubs.py, in glibc's abilist.awk format, plus <lib>.compat (@ vs @@ "
                           "where the newest-is-default rule is wrong) and libs.toml (soname, verdef order)"]


# The section 4.6 soname table: lib-names.h macro -> abilist stem (glibc's own file names).
GLIBC_STUB_LIBS = {"LIBC_SO": "libc", "LD_SO": "ld", "LIBM_SO": "libm", "LIBPTHREAD_SO": "libpthread",
                   "LIBDL_SO": "libdl", "LIBRT_SO": "librt", "LIBUTIL_SO": "libutil", "LIBANL_SO": "libanl",
                   "LIBRESOLV_SO": "libresolv", "LIBMVEC_SO": "libmvec"}


def glibc_sonames(include: Path, ma: str) -> dict:
    """abilist stem -> soname, from gnu/lib-names-*.h (the ABI variant this arch installs)."""
    out = {}
    for h in sorted((include / ma / "gnu").glob("lib-names*.h")):
        for m in re.finditer(r'#define\s+(\w+_SO)\s+"([^"]+)"', h.read_text()):
            if m.group(1) in GLIBC_STUB_LIBS:
                out[GLIBC_STUB_LIBS[m.group(1)]] = m.group(2)
    return out


def write_abilists(c: Ctx, out: Path, ma: str, dso_dir: Path) -> list:
    """abilist/<stem>.abilist + <stem>.compat for every soname-table DSO the root has, and
    libs.toml naming each soname and its version nodes in definition order."""
    ab = out / "abilist"
    ab.mkdir()
    toml = ["# per library: soname and the version nodes in verdef order (the stub's version script)"]
    done = []
    for stem, soname in sorted(glibc_sonames(out / "include", ma).items()):
        dso = dso_dir / soname
        if not dso.exists():
            continue                    # libmvec exists on x86_64 only in 2.31
        d = glibc_stubs.read_dso(dso)
        if d.soname != soname:
            die(f"{dso}: SONAME {d.soname}, lib-names.h says {soname}")
        (ab / f"{stem}.abilist").write_text(glibc_stubs.abilist_text(d))
        (ab / f"{stem}.compat").write_text(glibc_stubs.compat_text(d))
        toml += ["", f"[{stem}]", f'soname   = "{soname}"',
                 "versions = [" + ", ".join(f'"{v}"' for v in d.versions) + "]"]
        done.append(stem)
    (ab / "libs.toml").write_text("\n".join(toml) + "\n")
    for need in ("libc", "ld", "libm", "libpthread", "libdl"):
        if need not in done:
            die(f"{out}: no {need} DSO to read an abilist from")
    return done


def glibc_stub_parity(c: Ctx) -> list:
    """Regenerate every stub DSO from the SHIPPED abilist files alone and compare it with the
    curated focal DSO: SONAME and the public versioned dynsym (name, node, @/@@, kind, size)."""
    rec = load_recipe(FAMILIES["glibc"])
    cc = [str(c.cc)]
    rows = ["glibc stubs regenerated from abilist/ (kcc + lld) vs curated focal DSOs:",
            "arch     | lib        | soname                   | symbols | result",
            "---------|------------|--------------------------|--------:|-------"]
    for v in GLIBC_VERSIONS:
        for arch in rec["arches"]:
            env = target_env(rec, arch, v)
            ab = c.share / "glibc" / v / arch / "abilist"
            libs = tomllib.loads((ab / "libs.toml").read_text())
            for stem, info in sorted(libs.items()):
                ents = glibc_stubs.parse_abilist((ab / f"{stem}.abilist").read_text(),
                                                 (ab / f"{stem}.compat").read_text())
                work = c.scratch / "glibc-stubs" / v / arch / stem
                so = glibc_stubs.build_stub(cc, env["clang_triple"], info["soname"], ents, info["versions"], work)
                cur = c.curated / env["name"] / "lib" / info["soname"]
                diffs = glibc_stubs.compare(glibc_stubs.read_dso(cur), glibc_stubs.read_dso(so))
                if not diffs:
                    ok = c.glibc_stub_ok.setdefault(arch, {})
                    ok[info["soname"]] = stem
                    ok[os.path.basename(os.path.realpath(cur))] = stem
                rows.append(f"{arch:<8} | {stem:<10} | {info['soname']:<24} | {len(ents):>7} | "
                            + ("same" if not diffs else f"{len(diffs)} diffs, e.g. {diffs[0]}"))
    return rows


def mingw_def_sources(c: Ctx) -> Path:
    """mingw-w64-crt's def files, from git (they are outside the sparse checkout)."""
    repo = ROOT / "Lib" / "libc" / "mingw"
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], check=True,
                          capture_output=True, text=True).stdout.strip()
    out = c.scratch / "mingw-crt-src"
    stamp = out / ".head"
    if stamp.is_file() and stamp.read_text() == head:
        return out / "mingw-w64-crt"
    fresh(out)
    paths = [f"mingw-w64-crt/{d}" for d in ("lib-common", "lib32", "lib64", "libarm32", "def-include")]
    tar = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", head, *paths],
                         check=True, capture_output=True).stdout
    tf = out / "src.tar"
    tf.write_bytes(tar)
    with tarfile.open(tf) as t:
        t.extractall(out, filter="data")
    tf.unlink()
    stamp.write_text(head)
    return out / "mingw-w64-crt"


def find_tool(name: str) -> str | None:
    for p in (ROOT / "build" / "llvm" / "bin" / name,):
        if p.is_file():
            return str(p)
    return shutil.which(name)


def mingw_def_for(crt: Path, arch: str, stem: str, work: Path, clang: str) -> Path | None:
    """The def the mingw-w64-crt Makefile would feed dlltool for lib<stem>.a on `arch`:
    <libdir>/X.def.in, <libdir>/X.def, lib-common/X.def.in (cpp; @N stripped off lib32),
    lib-common/X.def."""
    libdir = MINGW_LIBDIR[arch]
    cands = []
    if libdir:
        cands += [(crt / libdir / f"{stem}.def.in", True, False), (crt / libdir / f"{stem}.def", False, False)]
    cands += [(crt / "lib-common" / f"{stem}.def.in", True, arch != "i686"),
              (crt / "lib-common" / f"{stem}.def", False, False)]
    for p, cpp, strip_at in cands:
        if not p.is_file():
            continue
        if not cpp:
            return p
        r = subprocess.run([clang, "-E", "-x", "c", f"--target={arch}-w64-windows-gnu", str(p),
                            "-Wp,-w", "-P", f"-I{crt / 'def-include'}"], capture_output=True, text=True)
        if r.returncode != 0:
            return None
        text = r.stdout
        if strip_at:
            text = "\n".join(re.sub(r"^([^ ]+)@[0-9]+( |\r?$)", r"\1\2", l) for l in text.split("\n"))
        o = work / f"{stem}.def"
        o.write_text(text)
        return o
    return None


def build_mingw(c: Ctx) -> None:
    out = fresh(c.share / "mingw")
    roots = {a: c.curated / f"{a}-windows-gnu" for a in MINGW_ARCHES}
    # Headers: llvm-mingw installs one generic set per arch; ship it once, after proving it.
    unwind_hdrs = {os.path.relpath(os.path.join(d, f), ROOT / "Lib/llvm-runtimes/libunwind/include").replace(os.sep, "/")
                   for d, _, fs in os.walk(ROOT / "Lib/llvm-runtimes/libunwind/include") for f in fs} - {"CMakeLists.txt"}
    skip = lambda r: r == "c++" or r in unwind_hdrs
    ref = tree_sha256_filtered(roots["x86_64"] / "include", skip)
    for a, r in roots.items():
        if tree_sha256_filtered(r / "include", skip) != ref:
            die(f"mingw headers of {a} differ from x86_64's; ship them per arch")
    copy_tree(roots["x86_64"] / "include", out / "include", skip)

    crt_src = mingw_def_sources(c)
    clang, dlltool = find_tool("clang"), shutil.which("llvm-dlltool")
    if not clang or not dlltool:
        log("   mingw: no clang/llvm-dlltool; every import library ships verbatim in crt/")
    stats = []
    for a in MINGW_ARCHES:
        libd = roots[a] / "lib"
        work = fresh(c.scratch / "mingw-def" / a)
        (out / "def" / a).mkdir(parents=True)
        (out / "crt" / a).mkdir(parents=True)
        n_def = n_crt = n_mismatch = n_nodef = 0
        for f in sorted(libd.iterdir()):
            n = f.name
            if n in MINGW_FROM_RUNTIMES or n.endswith(".la"):
                continue
            ents = import_entries(f) if n.endswith(".a") else None
            if ents and clang and dlltool and n.startswith("lib"):
                stem = n[3:-2]
                d = mingw_def_for(crt_src, a, stem, work, clang)
                if d:
                    regen = work / n
                    r = subprocess.run([dlltool, "-m", MINGW_DLLTOOL_M[a], "-k", "-d", str(d), "-l", str(regen)],
                                       capture_output=True)
                    if r.returncode == 0 and import_entries(regen) == ents:
                        shutil.copyfile(d, out / "def" / a / f"{stem}.def")
                        c.mingw_defs.setdefault(a, {})[n] = f"{stem}.def"
                        n_def += 1
                        continue
                    n_mismatch += 1
                else:
                    n_nodef += 1
            shutil.copyfile(f, out / "crt" / a / n)
            n_crt += 1
        for need in ("crt2.o", "crtbegin.o", "crtend.o", "libmingw32.a", "libmingwex.a", "libmoldname.a"):
            if not (out / "crt" / a / need).is_file():
                die(f"mingw {a}: {need} missing from crt/")
        stats.append(f"{a}: {n_def} import libs as defs (regenerated by llvm-dlltool -k and checked "
                     f"equal), {n_crt} files verbatim in crt/ ({n_mismatch} import libs whose source def "
                     f"no longer matches, {n_nodef} with no def in mingw-w64-crt)")
    head = (c.scratch / "mingw-crt-src" / ".head").read_text()
    c.prov["mingw"] = [
        "include/: the curated windows-gnu roots' include/ (llvm-mingw 20260224), minus c++/ and "
        "libunwind's headers; byte-identical on all four arches, so shipped once",
        f"def/<arch>/: Lib/libc/mingw mingw-w64-crt at {head[:12]} (git, outside the sparse checkout), "
        "preprocessed as its Makefile.am does; kept only where the regenerated import lib equals the curated one",
        "crt/<arch>/: every other archive / object of the curated lib/ verbatim (crt objects, "
        "libmingw*.a, mixed import+code libs such as libkernel32.a, umbrella libs)", *stats]


def tree_sha256_filtered(root: Path, skip) -> str:
    h = hashlib.sha256()
    rels = []
    for d, dirs, fs in os.walk(root):
        reld = os.path.relpath(d, root).replace(os.sep, "/")
        reld = "" if reld == "." else reld + "/"
        dirs[:] = [x for x in dirs if not skip(reld + x)]
        rels += [reld + f for f in fs if not skip(reld + f)]
    for r in sorted(rels, key=str.encode):
        h.update(r.encode() + b"\n" + file_sha256(root / r).encode() + b"\n")
    return h.hexdigest()


def bsd_source(c: Ctx, name: str) -> tuple[Path, str]:
    if (c.bsd_trim / "DONE").exists() and (c.bsd_trim / name).is_dir():
        return c.bsd_trim / name, "build/sysgen/bsd-trim (DONE)"
    return c.curated / name, "curated root, untrimmed (build/sysgen/bsd-trim/DONE absent)"


def build_bsd(c: Ctx) -> None:
    for os_, (ver, arches) in BSD.items():
        fresh(c.share / os_)
        for arch in arches:
            name = f"{arch}-unknown-{os_}"
            src, how = bsd_source(c, name)
            out = c.share / os_ / ver / arch
            out.mkdir(parents=True)
            copy_tree(src / "usr" / "include", out / "usr" / "include", lambda r: r == "c++")
            copy_tree(src / "usr" / "lib", out / "usr" / "lib")
            if (src / "lib").is_dir():
                copy_tree(src / "lib", out / "lib")
            key = f"{os_}/{ver}/{arch}"
            sweep_links(out, c.dropped_links.setdefault(key, []))
            remove_empty_dirs(out)
            for must in ("usr/include/stdio.h", "usr/lib/libc.a"):
                if not (out / must).is_file():
                    die(f"{key}: no {must}")
            c.prov[key] = [f"{how}: usr/include (minus c++/: the base libc++ headers, which "
                           "-nostdinc++ and libcxx/ replace), usr/lib, lib"]


def build_wasi(c: Ctx) -> None:
    src = c.curated / "wasm32-wasi"
    out = fresh(c.share / "wasi") / WASI_VERSION
    noeh = lambda r: r == "noeh"
    copy_tree(src / "include", out / "include", noeh)
    copy_tree(src / "lib", out / "lib", noeh)
    for must in ("lib/wasm32-wasi/crt1-command.o", "lib/wasm32-wasi/eh/libc++.a"):
        if not (out / must).is_file():
            die(f"wasi: no {must}")
    c.prov[f"wasi/{WASI_VERSION}"] = ["curated wasm32-wasi root (wasi-sdk 33 sysroot): include/ and lib/ "
                                      "minus noeh/ (the recipe links the EH libc++) and compiler-rt/"]


def build_licenses(c: Ctx) -> None:
    lt, out = ROOT / "Scripts" / "license-texts", fresh(c.share / "licenses")
    m = ROOT / "Lib" / "libc" / "mingw"
    gl = c.ksys / "extract" / "x86_64-linux-gnu-glibc2.31" / "usr" / "share" / "doc"
    files = {
        "musl": [ROOT / "Lib/libc/musl/COPYRIGHT"],
        "linux-uapi": [lt / "GPL-2.0-only.txt", lt / "Linux-syscall-note.txt"],
        "glibc": [lt / "LGPL-2.1-or-later.txt", (gl / "libc6" / "copyright", "debian-libc6-copyright")],
        "mingw": [m / "COPYING", m / "DISCLAIMER", m / "DISCLAIMER.PD"],
        "freebsd": [lt / "FreeBSD-COPYRIGHT.txt"],
        "netbsd": [lt / "NetBSD-COPYRIGHT.txt"],
        "wasi": sorted((ROOT / "Lib/libc/wasi").glob("LICENSE*")),
        "runtimes": [ROOT / "Lib/llvm-runtimes/LICENSE.TXT"],
    }
    for comp, srcs in files.items():
        d = out / comp
        d.mkdir()
        for s in srcs:
            s, n = (s if isinstance(s, tuple) else (s, s.name))
            shutil.copyfile(s, d / n)
    for n in ("COPYING.MinGW-w64-runtime", "COPYING.MinGW-w64"):   # not in the sparse checkout
        txt = subprocess.run(["git", "-C", str(m), "show", f"HEAD:{n}"], check=True, capture_output=True).stdout
        (out / "mingw" / n).write_bytes(txt)


def stage_runtimes(c: Ctx) -> tuple[str, str, Path]:
    import package_release
    dst = fresh(c.scratch / "runtimes-stage")
    package_release.stage_runtimes(dst)
    rt = dst / "share" / "kairo" / "runtimes"
    return (rt / "REVISION").read_text().strip(), tree_sha256(rt), rt


def write_registry(c: Ctx, rt_hash: str) -> None:
    keys = ["musl", "linux-uapi", f"wasi/{WASI_VERSION}", "mingw"]
    keys += [f"glibc/{v}/{a}" for v in GLIBC_VERSIONS for a in load_recipe(FAMILIES["glibc"])["arches"]]
    keys += [f"{o}/{v}/{a}" for o, (v, arches) in BSD.items() for a in arches]
    keys = sorted(keys)
    hashes = {k: tree_sha256(c.share / k) for k in keys}
    hashes["runtimes"] = rt_hash
    keys = sorted(hashes)
    w = max(len(k) for k in keys) + 2
    lines = ["# generated by Scripts/ship_sysroot_inputs.py; do not edit. Format: FORMAT.md.",
             "schema = 1", "", "[inputs]"]
    lines += [f'{chr(34) + k + chr(34):<{w}} = "{hashes[k]}"' for k in keys]
    lines += ["", "[licenses]"]
    lines += [f'{chr(34) + k + chr(34):<{w}} = "{LICENSES[k.split("/")[0]]}"' for k in keys]
    (c.share / "registry.toml").write_text("\n".join(lines) + "\n")


def write_provenance(c: Ctx, rev: str) -> None:
    """Human/audit record; ksys never reads it (not part of FORMAT.md's contract)."""
    def q(s: str) -> str:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    lines = ["# where every input came from; generated by Scripts/ship_sysroot_inputs.py", ""]
    c.prov["runtimes"] = [f"not copied: share/kairo/runtimes as Scripts/package_release.py stages it (REVISION {rev})"]
    for k in sorted(c.prov):
        lines.append(f"[{q(k)}]")
        lines.append("how = [" + ", ".join(q(s) for s in c.prov[k]) + "]")
        dl = c.dropped_links.get(k, [])
        if dl:
            lines.append(f"dropped_symlinks = {len(dl)}   # absolute, escaping or dangling")
        lines.append("")
    (c.share / "provenance.toml").write_text("\n".join(lines))


# ---------------------------------------------------------------- report

def raw_size(p: Path) -> tuple[int, int]:
    n = b = 0
    for d, _, fs in os.walk(p):
        for f in fs:
            fp = Path(d, f)
            if not fp.is_symlink():
                n, b = n + 1, b + fp.stat().st_size
    return n, b


def xz_size(base: Path, rels: list[str]) -> int:
    env = dict(os.environ, XZ_OPT="-6 -T0")
    p = subprocess.Popen(["tar", "--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner",
                          "-cJf", "-", "-C", str(base), *rels], stdout=subprocess.PIPE, env=env)
    total = 0
    for chunk in iter(lambda: p.stdout.read(1 << 20), b""):
        total += len(chunk)
    if p.wait() != 0:
        die(f"tar failed on {rels}")
    return total


def mb(b: int) -> str:
    return f"{b / (1 << 20):8.1f}"


CURATED_FAMILY = {"linux-musl": "musl", "linux-gnu": "glibc", "windows-gnu": "mingw",
                  "freebsd": "freebsd", "netbsd": "netbsd", "wasi": "wasi"}
SHARE_DIRS = {"musl": ["musl", "linux-uapi"], "glibc": ["glibc"], "mingw": ["mingw"],
              "freebsd": ["freebsd"], "netbsd": ["netbsd"], "wasi": ["wasi"],
              "common": ["families", "quirks.toml", "shims", "validate", "licenses", "registry.toml", "provenance.toml"]}


def size_report(c: Ctx, rt: Path) -> list[str]:
    import json
    man = json.loads((c.curated / "manifest.json").read_text())["targets"]
    cur = {}
    for name, t in man.items():
        f = CURATED_FAMILY[t["family"]]
        n, b = raw_size(c.curated / name)
        e = cur.setdefault(f, [0, 0, 0])
        e[0] += 1; e[1] += b; e[2] += t["size"]
    rows = ["family    | share raw MB | share xz MB | curated roots | curated raw MB | curated xz MB",
            "----------|-------------:|------------:|--------------:|---------------:|-------------:"]
    tot = [0, 0, 0, 0]
    for f, dirs in SHARE_DIRS.items():
        rb = sum(raw_size(c.share / d)[1] if (c.share / d).is_dir() else (c.share / d).stat().st_size for d in dirs)
        xb = xz_size(c.share, dirs)
        cr = cur.get(f, [0, 0, 0])
        rows.append(f"{f:<9} | {mb(rb)} | {mb(xb)} | {cr[0]:>13} | {mb(cr[1])} | {mb(cr[2])}")
        tot[0] += rb; tot[1] += xb; tot[2] += cr[1]; tot[3] += cr[2]
    rows.append(f"{'total':<9} | {mb(tot[0])} | {mb(tot[1])} | {18:>13} | {mb(tot[2])} | {mb(tot[3])}")
    rtx = xz_size(rt.parent, ["runtimes"])
    rows.append(f"(runtimes/: {mb(raw_size(rt)[1]).strip()} MB raw, {mb(rtx).strip()} MB xz; already in every "
                "archive as share/kairo/runtimes, so not counted)")
    host = {n: man[n]["size"] for n in ("x86_64-linux-musl", "x86_64-linux-gnu-glibc2.31")}
    delta = tot[1] + sum(host.values()) - tot[3]
    rows.append("")
    rows.append(f"Per release archive (x86_64-linux host): drop the 18 roots ({mb(tot[3]).strip()} MB xz), add the "
                f"share tree ({mb(tot[1]).strip()} MB xz), keep the two host-native roots prebuilt "
                f"({' + '.join(f'{k} {mb(v).strip()}' for k, v in host.items())} MB xz): "
                f"net {'+' if delta >= 0 else ''}{mb(delta).strip()} MB.")
    return rows


# ---------------------------------------------------------------- parity

def parity(c: Ctx) -> list[str]:
    """Each file (and link) of each curated root: VERBATIM in an input, DERIVED (how),
    DROPPED (by design, why) or GAP (no source). Writes one TSV per root."""
    pdir = fresh(c.scratch / "parity")
    recipes = {k: load_recipe(v) for k, v in FAMILIES.items()}
    import json
    man = json.loads((c.curated / "manifest.json").read_text())["targets"]
    trim_reason = {}
    for os_, (ver, arches) in BSD.items():
        for a in arches:
            mf = c.bsd_trim / f"{a}-unknown-{os_}.manifest.tsv"
            if mf.is_file() and (c.bsd_trim / "DONE").exists():
                for line in mf.read_text().splitlines():
                    p = line.split("\t")
                    if len(p) >= 4 and not line.startswith("#") and p[0] != "restored":
                        trim_reason[(a, os_, p[2])] = f"bsd-trim {p[0]}: {p[3]}"
    musl_hdr_cache = {}
    summary = ["root                             | files | verbatim | derived | dropped | GAP | toml",
               "---------------------------------|------:|---------:|--------:|--------:|----:|-----"]
    gaps_all = {}
    for name in sorted(man):
        root = c.curated / name
        fam = CURATED_FAMILY[man[name]["family"]]
        rec = recipes[fam]
        arch = name.split("-")[0]
        env = target_env(rec, arch, "2.31" if fam == "glibc" else "")
        toml_ok = render_toml(rec, env) == (root / "SYSROOT.toml").read_text()
        rows = []
        for d, dirs, fs in os.walk(root):
            for n in sorted(fs) + sorted(x for x in dirs if Path(d, x).is_symlink()):
                p = Path(d, n)
                rel = p.relative_to(root).as_posix()
                cat, how = classify(c, fam, arch, env, root, rel, p, trim_reason, musl_hdr_cache)
                rows.append((rel, cat, how))
        rows.sort()
        (pdir / f"{name}.tsv").write_text("".join(f"{r}\t{k}\t{h}\n" for r, k, h in rows))
        cnt = {k: sum(1 for r in rows if r[1] == k) for k in ("VERBATIM", "DERIVED", "DROPPED", "GAP")}
        summary.append(f"{name:<32} | {len(rows):>5} | {cnt['VERBATIM']:>8} | {cnt['DERIVED']:>7} | "
                       f"{cnt['DROPPED']:>7} | {cnt['GAP']:>3} | {'same' if toml_ok else 'DIFF'}")
        for r, k, h in rows:
            if k == "GAP":
                gaps_all.setdefault((fam, h), []).append(f"{name}/{r}")
    summary.append("")
    summary.append("GAP groups (family: reason: count, examples):")
    for (fam, h), files in sorted(gaps_all.items()):
        summary.append(f"  {fam}: {h}: {len(files)}  e.g. {', '.join(files[:3])}")
    # The 7 local user-provider roots have no input files, but their TOML must render too.
    for name in sorted(p.name for p in c.curated.iterdir() if p.is_dir() and p.name not in man):
        t = (c.curated / name / "SYSROOT.toml")
        if not t.is_file():
            continue
        fam = {"windows-msvc": "msvc", "darwin": "darwin"}.get(tomllib.loads(t.read_text())["family"])
        if fam:
            env = target_env(recipes[fam], name.split("-")[0])
            summary.append(f"toml {name}: {'same' if render_toml(recipes[fam], env) == t.read_text() else 'DIFF'}")
    return summary


def _same(a: Path, b: Path) -> bool:
    return b.is_file() and a.is_file() and file_sha256(a) == file_sha256(b)


def _link_same(p: Path, q: Path) -> bool:
    return q.is_symlink() and os.readlink(p) == os.readlink(q)


def classify(c, fam, arch, env, root, rel, p, trim_reason, mcache):
    S = c.share
    rt = "runtimes"
    if rel == "SYSROOT.toml":
        return "DERIVED", "recipe [toml] (section 4.9)"
    top = rel.split("/")[0]
    if top == "compiler-rt":
        return "DERIVED", f"{rt}: builtins stage (4.5) / crtbegin-crtend (4.7)"
    if fam == "musl":
        if rel.startswith("include/c++/"):
            return "DERIVED", f"{rt}: libc++ headers (4.7; curated: Alpine llvm 22.1.3)"
        if rel.startswith("include/"):
            r = rel[len("include/"):]
            if r.split("/")[0] in UAPI_DIRS:
                for q in (S / "linux-uapi/generic" / r, S / "linux-uapi/asm" / arch / r):
                    if _same(p, q):
                        return "VERBATIM", "linux-uapi"
                return "GAP", "kernel header not in linux-uapi"
            ma = MUSL_ARCH[arch]
            if ma not in mcache:
                mcache[ma] = musl_headers(c, ma)
            q = mcache[ma] / r
            if _same(p, q):
                return "DERIVED", "musl install-headers (4.4)"
            if q.is_file():
                return "DERIVED", "musl install-headers (4.4); content differs (Lib/libc/musl is musl git past 1.2.6; Alpine ships the release)"
            return "GAP", "header neither musl nor UAPI"
        n = rel[len("lib/"):]
        if n == "libc.so":
            return "DROPPED", "dangling libc.so symlink (section 4.6 keeps it out)"
        if n in ("libc++.a", "libc++abi.a", "libc++experimental.a", "libunwind.a"):
            return "DERIVED", f"{rt}: runtimes stage (4.7; curated: Alpine llvm 22.1.3)"
        if n in ("libc.a", "crt1.o", "Scrt1.o", "rcrt1.o", "crti.o", "crtn.o") or \
                n in {f"lib{x}.a" for x in ("crypt", "dl", "m", "pthread", "resolv", "rt", "util", "xnet")}:
            return "DERIVED", "musl configure + make (4.6; curated: Alpine musl-dev)"
        return "GAP", "Alpine-only file (gcc's libssp_nonshared)" if n == "libssp_nonshared.a" else "no source"
    if fam == "glibc":
        g = S / "glibc/2.31" / arch
        if rel.startswith("include/c++/"):
            return "DERIVED", f"{rt}: libc++ headers (4.7)"
        if rel.startswith("include/"):
            q = g / rel
            if (p.is_symlink() and _link_same(p, q)) or _same(p, q):
                return "VERBATIM", f"glibc/2.31/{arch}/include"
            return "GAP", "header not in glibc input"
        n = rel[len("lib/"):]
        if n in ("libc++.a", "libc++abi.a", "libc++experimental.a", "libunwind.a"):
            return "DERIVED", f"{rt}: runtimes stage (4.7)"
        if n.endswith(".o"):
            return ("VERBATIM", f"glibc/2.31/{arch}/crt") if _same(p, g / "crt" / n) else ("GAP", "crt object missing")
        if n == "libc_nonshared.a":
            return ("VERBATIM", f"glibc/2.31/{arch}") if _same(p, g / n) else ("GAP", "libc_nonshared.a differs")
        if n in ("libc.so", "libm.so"):
            return "DERIVED", "linker script the glibc provider writes (4.6)"
        if n.endswith(".a"):
            return "DROPPED", "static glibc archive: the recipe links glibc dynamically (static = false)"
        ok = c.glibc_stub_ok.get(arch, {})
        stem = ok.get(n)
        if not stem and p.is_symlink() and ok.get(os.path.basename(os.path.realpath(p))):
            return "DERIVED", "alias link to a stub DSO (Debian's ld-linux.so.3 -> ld-linux-armhf.so.3)"
        if stem:
            return "DERIVED", f"stub DSO from glibc/2.31/{arch}/abilist/{stem}.abilist (4.6; regenerated, dynsym equal)"
        if n in ("libpthread.so", "libdl.so", "librt.so", "libutil.so", "libanl.so", "libresolv.so", "libmvec.so") \
                and p.is_symlink():
            return "DERIVED", "dev symlink the glibc provider writes (4.6)"
        base = re.sub(r"(-2\.31)?\.so(\.[0-9]+)*$", "", n)
        if base in ("libc", "libm", "libpthread", "libdl", "librt", "libutil", "libanl", "libresolv", "libcrypt",
                    "libmvec") or base.startswith("ld"):
            return "GAP", "stub DSO derivable from <lib>.abilist (4.6), but no abilist on disk"
        return "DROPPED", "DSO outside the 4.6 soname table (nss/nsl/BrokenLocale/preload/debug helpers)"
    if fam == "mingw":
        m = S / "mingw"
        if rel.startswith("include/"):
            r = rel[len("include/"):]
            if r.startswith("c++/"):
                return "DERIVED", f"{rt}: libc++ headers (4.7; curated: llvm-mingw)"
            if _same(p, m / "include" / r):
                return "VERBATIM", "mingw/include"
            if (ROOT / "Lib/llvm-runtimes/libunwind/include" / r).is_file():
                return "DERIVED", f"{rt}: libunwind headers"
            return "GAP", "header not in mingw input"
        n = rel[len("lib/"):]
        if n in ("libc++.a", "libunwind.a", "libc++experimental.a"):
            return "DERIVED", f"{rt}: runtimes stage (4.7; curated: llvm-mingw)"
        if n == "libc++abi.a":
            return "DROPPED", "the recipe merges libc++abi into libc++.a (cxxabi_merged_into_cxx)"
        if n in ("libc++.dll.a", "libunwind.dll.a", "libc++.modules.json"):
            return "DROPPED", "shared-runtime import lib / module map: static_only recipe"
        if n.endswith(".la"):
            return "DROPPED", "libtool metadata (build-host paths)"
        if n in c.mingw_defs.get(arch, {}):
            return "DERIVED", f"kar --dlltool from mingw/def/{arch}/{c.mingw_defs[arch][n]} (regenerated, equal)"
        if _same(p, m / "crt" / arch / n):
            return "VERBATIM", f"mingw/crt/{arch}"
        return "GAP", "not in mingw input"
    if fam in ("freebsd", "netbsd"):
        ver = BSD[fam][0]
        b = S / fam / ver / arch
        if top == "libcxx":
            return "DERIVED", f"{rt}: runtimes stage into libcxx/ (4.7)"
        if rel.startswith("usr/include/c++/"):
            return "DROPPED", "base libc++/libstdc++ headers: -nostdinc++ and libcxx/ replace them"
        q = b / rel
        if p.is_symlink():
            if _link_same(p, q):
                return "VERBATIM", f"{fam}/{ver}/{arch}"
        elif _same(p, q):
            return "VERBATIM", f"{fam}/{ver}/{arch}"
        why = trim_reason.get((arch, fam, rel))
        if why:
            return "DROPPED", why
        if p.is_symlink() and not os.path.exists(p):
            return "DROPPED", "dangling symlink"
        return "GAP", "not in bsd input"
    if fam == "wasi":
        if "/noeh/" in rel or rel.endswith("/noeh"):
            return "DROPPED", "noeh libc++ variant: the recipe links eh/"
        if _same(p, S / "wasi" / WASI_VERSION / rel):
            return "VERBATIM", f"wasi/{WASI_VERSION}"
        return "GAP", "not in wasi input"
    return "GAP", "unknown family"


# ---------------------------------------------------------------- main

STEPS = ["data", "musl", "uapi", "glibc", "mingw", "bsd", "wasi", "licenses"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--scratch", type=Path, default=ROOT / "build" / "sysgen" / "a2")
    ap.add_argument("--curated", type=Path, default=ROOT / "build" / "x86_64-linux-gnu" / "release" / "sysroot")
    ap.add_argument("--kairo-sysroots", type=Path, default=Path.home() / "linux-dev" / "projects" / "kairo-sysroots")
    ap.add_argument("--bsd-trim", type=Path, default=ROOT / "build" / "sysgen" / "bsd-trim")
    ap.add_argument("--cc", type=Path, default=ROOT / "build" / "x86_64-linux-gnu" / "release" / "bin" / "kcc",
                    help="compiler driver for the glibc stub check (--report)")
    ap.add_argument("--only", nargs="+", choices=STEPS, help="rebuild only these inputs (registry is always rewritten)")
    ap.add_argument("--report", action="store_true", help="size report + parity check into <scratch>/")
    a = ap.parse_args()
    c = Ctx(a)
    c.share.mkdir(parents=True, exist_ok=True)
    c.scratch.mkdir(parents=True, exist_ok=True)
    steps = a.only or STEPS
    fn = {"data": build_data, "musl": build_musl, "uapi": build_uapi, "glibc": build_glibc,
          "mingw": build_mingw, "bsd": build_bsd, "wasi": build_wasi, "licenses": build_licenses}
    for s in steps:
        log(f"== {s}")
        fn[s](c)
    if a.only and "mingw" not in steps:
        # mingw_defs feeds parity; rebuild the mapping from what is on disk
        for arch in MINGW_ARCHES:
            for d in sorted((c.share / "mingw" / "def" / arch).glob("*.def")):
                c.mingw_defs.setdefault(arch, {})[f"lib{d.stem}.a"] = d.name
    log("== runtimes (hash only)")
    rev, rt_hash, rt = stage_runtimes(c)
    write_registry(c, rt_hash)
    if not a.only:
        write_provenance(c, rev)
    log(f"registry: {c.share / 'registry.toml'}")
    if a.report:
        log("== size report")
        rep = size_report(c, rt)
        log("== glibc stubs")
        stubs = glibc_stub_parity(c)
        log("== parity")
        rep += ["", *stubs, "", *parity(c)]
        (c.scratch / "report.txt").write_text("\n".join(rep) + "\n")
        print("\n".join(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
