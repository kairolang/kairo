#!/usr/bin/env python3
"""Build the `kairo sysroot` input tree (Compiler/Spec/SysRoot.md section 3).

    python3 Scripts/ship_sysroot_inputs.py                  # build/sysroot-share
    python3 Scripts/ship_sysroot_inputs.py --report         # + size report and parity check
    python3 Scripts/ship_sysroot_inputs.py --only mingw     # rebuild one input family
                                  # (--only rewrites only its own provenance.toml sections)

Maintainer tool, never shipped. It replaces the 18 prebuilt cross sysroots a release
carries with the inputs the generator builds them from. Everything comes from disk; nothing
is fetched. Sources, in the order kairo-sysroots' curate/ scripts consumed them:

  musl/           Lib/libc/musl (1.2.6), without git and docs
  linux-uapi/     the kernel headers of the curated *-linux-musl roots, split into the part
                  every arch shares and asm/ (plus arch-only headers) per arch
  glibc/abilists/ every release's sysdeps/**/*.abilist from glibc git (2.17 .. newest),
                  merged per ABI with the releases exporting each entry, and the compat-only
                  bindings from glibc's own source (Scripts/glibc_abilists.py, glibc_compat.py)
  glibc/headers/  the newest release's install-headers for every arch (glibc's configure +
                  make, clang as CC), deduplicated (Scripts/glibc_headers.py)
  glibc/src/, glibc/crt/  the crt objects and libc_nonshared.a as glibc's own make compiles
                  them, per era and arch, and the source subset they read
                  (Scripts/glibc_crt_recipe.py). --report rebuilds the 2.31 stubs from the
                  abilists and compares them with the curated (Ubuntu focal) DSOs.
  mingw/          headers from the curated windows-gnu roots (identical on every arch, so
                  shipped once); crt/<a>/ = the curated lib/ files mingw-crt/ does not build
                  (winpthreads, libssp, ...). Without mingw-crt/ tables: def/<a>/
                  preprocessed from Lib/libc/mingw's mingw-w64-crt (in git, outside the sparse
                  checkout), kept only where llvm-dlltool regenerates the curated import
                  library exactly, and crt/<a>/ = every other archive and object of lib/
  freebsd/, netbsd/  build/sysgen/bsd-trim/<name> when bsd-trim/DONE exists, else the curated
                  root; minus libcxx/, compiler-rt/ and usr/include/c++ (built from runtimes)
  wasi/33/        the curated wasm32-wasi root minus compiler-rt/ and minus what wasi-libc/
                  builds: libc++ (eh/, noeh/) and the LTO libc
  runtimes-recipe/  Scripts/runtimes_recipe.py: per-runtime compile tables (sources, flags,
                  archive layout) + generated headers, from a CMake configure of each family
                  recipe; the generator's no-CMake runtimes stage (Scripts/build_runtimes_direct.py)
  runtimes-template/  Scripts/runtimes_template.py over runtimes-recipe/ and --template-recipes
                  (EXTRA targets' tables): the rule the tables follow, which ksys compiles from
  mingw-crt/, wasi-libc/  sources + tables the mingw and wasi providers build the libc from
                  (Scripts/mingw_crt_recipe.py, Scripts/wasi_libc_recipe.py)
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
GLIBC_VERSIONS = [f"2.{n}" for n in range(17, 43)]   # every release 2.17 .. 2.42 (glibc/abilists)
GLIBC_DEFAULT = "2.31"                                # what a name without -glibc<v> means (0.2.0's)
GLIBC_KEYS = ["glibc/abilists", "glibc/crt", "glibc/headers", "glibc/src"]
MUSL_ARCH = {"x86_64": "x86_64", "i686": "i386", "aarch64": "aarch64", "armv7": "arm",
             "armv6": "arm", "riscv64": "riscv64", "riscv32": "riscv32"}
# Kernel headers_install output depends only on the kernel ARCH (the x86_64 and i686 roots
# carry identical asm/), so arches without a curated root take their kernel twin's set.
UAPI_TWIN = {"armv6": "armv7", "riscv32": "riscv64"}
# Kernel ARCHes with no curated root (Z5): asm/<ARCH>/ comes from `make headers_install
# ARCH=<ARCH>` of the Linux source tree --linux-src names (the same 7.0 the curated roots'
# headers are). Recipes reach them through [per_arch.uapi_arch].
UAPI_KERNEL = ["powerpc", "s390", "mips", "loongarch", "sparc"]
# generic/ files the curated (Alpine linux-headers) set carries in a form a pristine
# headers_install does not: Alpine's musl-compat patches (if_tunnel.h drops the <linux/if.h>
# <linux/ip.h> <linux/in6.h> includes, kernel.h guards <linux/sysinfo.h> with __GLIBC__), and
# musl's own scsi/ headers, which the curated include/ held under a UAPI dir name.
UAPI_GENERIC_CURATED_ONLY = {"linux/if_tunnel.h", "linux/kernel.h", "scsi/scsi.h", "scsi/scsi_ioctl.h", "scsi/sg.h"}
UAPI_DIRS = ("asm", "asm-generic", "linux", "drm", "misc", "mtd", "rdma", "scsi", "sound",
             "video", "xen", "cxl", "fwctl", "regulator")
MINGW_ARCHES = ["x86_64", "i686", "aarch64", "armv7"]
MINGW_LIBDIR = {"x86_64": "lib64", "i686": "lib32", "armv7": "libarm32", "aarch64": None}
MINGW_DLLTOOL_M = {"x86_64": "i386:x86-64", "i686": "i386", "armv7": "arm", "aarch64": "arm64"}
# What the runtimes stage builds; never an input.
MINGW_FROM_RUNTIMES = {"libc++.a", "libc++abi.a", "libc++experimental.a", "libunwind.a",
                       "libc++.dll.a", "libunwind.dll.a", "libc++.modules.json"}
BSD = {"freebsd": ("14.4", ["x86_64", "aarch64"]), "netbsd": ("10.1", ["x86_64"])}
# From-source inputs (Zig-style: the libc built from shipped sources + tables, no prebuilt
# per-target base). Registered whenever their dir exists, so a run that skips them keeps them.
EXTRA_KEYS = ["mingw-crt", "wasi-libc", "runtimes-template"]
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
    "runtimes-recipe": "Apache-2.0 WITH LLVM-exception",   # tables + generated headers from it
    "runtimes-template": "Apache-2.0 WITH LLVM-exception",   # the rule the tables follow, same headers
    "mingw-crt": "ZPL-2.1 AND LicenseRef-mingw-w64-public-domain",   # mingw-w64-crt sources + tables
    "wasi-libc": "Apache-2.0 WITH LLVM-exception AND MIT AND CC0-1.0",   # wasi-libc sources + tables
}

# glibc/src is glibc's files (LGPL, each with its link exception) plus Kairo's own replacements
# for the few that lack it (Scripts/glibc-own/, glibc_own_overlay): the one input with a mixed
# licence. Exact keys win over the prefix map above.
KAIRO_RUNTIME_SPDX = "Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception"
LICENSE_KEYS = {"glibc/src": f"LGPL-2.1-or-later AND {KAIRO_RUNTIME_SPDX}"}


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


# Registry schema 2: an input holds no symlinks at all (links.tsv / casefold.tsv
# record what ksys recreates), and tree_sha256 never follows a link: a link is an error. On a
# link-free tree both rules give the same hash, which is what makes a Windows unzip and a
# Linux untar of the same archive verify identically. --legacy-links writes schema 1.
SCHEMA = 2
LINKS_TSV = "links.tsv"
CASEFOLD_TSV = "casefold.tsv"
CASE_SUFFIX = ".kcase"


def registry_schema(share: Path) -> int | None:
    """The `schema = N` of <share>/registry.toml, None without one."""
    reg = Path(share) / "registry.toml"
    if not reg.is_file():
        return None
    m = re.search(r"^schema\s*=\s*\"?(\d+)", reg.read_text(), re.M)
    return int(m.group(1)) if m else None


def tree_sha256(root: Path, legacy: bool | None = None) -> str:
    """FORMAT.md's algorithm, byte for byte. Schema 2: no link may exist (die). Schema 1
    (--legacy-links): follow symlinks, skip dangling ones. `legacy` unset: the rule of the
    share the dir sits in (the nearest registry.toml above it), so a verifier such as
    package_release.py checks a schema 1 tree by schema 1's rule; no registry: SCHEMA."""
    if legacy is None:
        for up in [Path(root), *Path(root).resolve().parents]:
            sch = registry_schema(up)
            if sch is not None:
                legacy = sch == 1
                break
        else:
            legacy = SCHEMA == 1
    rels = []
    for d, dirs, files in os.walk(root, followlinks=legacy):
        for f in files + ([] if legacy else dirs):
            p = os.path.join(d, f)
            if not legacy and os.path.islink(p):
                die(f"tree_sha256: {p} is a symlink; schema 2 inputs hold none (record it in links.tsv)")
            if f in files and os.path.isfile(p):
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


def seal_input(root: Path) -> list[str]:
    """Make one input dir portable to a case-insensitive, link-less filesystem (a Windows
    unzip). Every symlink becomes a row of <root>/links.tsv and is removed; every name that
    collides with another in the same dir under case folding (Linux netfilter's xt_MARK.h /
    xt_mark.h) except the bytewise-greatest of its group is stored as <name>.kcase and listed
    in <root>/casefold.tsv. Idempotent: rows already recorded are kept, so a rerun over a
    sealed dir changes nothing. Returns notes for provenance."""
    links = {}
    lt = root / LINKS_TSV
    if lt.is_file():
        for line in lt.read_text().splitlines():
            rel, target, kind = line.split("\t")
            links[rel] = (target, kind)
    found = []
    for d, dirs, files in os.walk(root):
        for n in sorted(dirs + files):
            p = Path(d, n)
            if p.is_symlink():
                rel = p.relative_to(root).as_posix()
                t = os.readlink(p)
                if os.path.isabs(t) or "\\" in t or "\t" in t or "\n" in t:
                    die(f"{p}: link text {t!r} cannot be recorded (absolute or unportable)")
                found.append((rel, t, "d" if p.is_dir() else "f"))
    # A dir link's target must exist as a real dir once every link is gone: unlink files first,
    # dirs last, then check every recorded target resolves to a real entry inside root.
    for rel, t, kind in sorted(found, key=lambda e: e[2] == "d"):
        (root / rel).unlink()
        links[rel] = (t, kind)
    for rel, (t, kind) in links.items():
        res = resolve_recorded(root, rel, links)
        if res is None:
            die(f"{root}: link {rel} -> {t} does not resolve inside the input once links are gone")
        if (root / res).is_dir() != (kind == "d"):
            die(f"{root}: link {rel} -> {t}: kind {kind} does not match its target")
    if links:
        rows = [f"{r}\t{links[r][0]}\t{links[r][1]}" for r in sorted(links, key=str.encode)]
        lt.write_text("\n".join(rows) + "\n")
    folds = {}
    ct = root / CASEFOLD_TSV
    if ct.is_file():
        for line in ct.read_text().splitlines():
            stored, rel = line.split("\t")
            folds[stored] = rel
    for d, dirs, files in os.walk(root):
        groups = {}
        for n in dirs + files:
            groups.setdefault(n.casefold(), []).append(n)
        for g in groups.values():
            if len(g) < 2:
                continue
            for n in sorted(g, key=str.encode)[:-1]:
                if Path(d, n).is_dir():
                    die(f"{d}: case-colliding directory {n}; casefold.tsv covers files only")
                rel = Path(d, n).relative_to(root).as_posix()
                stored = rel + CASE_SUFFIX
                if (root / stored).exists():
                    die(f"{root}: {stored} already exists")
                os.rename(root / rel, root / stored)
                folds[stored] = rel
    if folds:
        rows = [f"{s}\t{folds[s]}" for s in sorted(folds, key=str.encode)]
        ct.write_text("\n".join(rows) + "\n")
    notes = []
    if links:
        notes.append(f"{len(links)} symlinks recorded in links.tsv (none on disk; ksys recreates them)")
    if folds:
        notes.append(f"{len(folds)} case-colliding files stored as <name>{CASE_SUFFIX}, listed in casefold.tsv")
    return notes


def resolve_recorded(root: Path, rel: str, links: dict) -> str | None:
    """The real (link-free) path inside root that recorded link `rel` names, following chains
    and dir links on the way, as the OS would; None if it escapes root, loops or dangles.
    FORMAT.md's links.tsv rule; ksys's copy fallback resolves the same way."""
    parts, seen = rel.split("/"), 0
    done = []
    while parts:
        cur = "/".join(done + [parts[0]])
        if cur in links:
            seen += 1
            if seen > 64:
                return None
            t = links[cur][0]
            parts = t.split("/") + parts[1:]
            continue
        head = parts.pop(0)
        if head in ("", "."):
            continue
        if head == "..":
            if not done:
                return None
            done.pop()
            continue
        done.append(head)
    res = "/".join(done)
    return res if res and (root / res).exists() else None


def windows_hazards(root: Path) -> list[str]:
    """Names a Windows extract cannot create: reserved device basenames, forbidden characters,
    a trailing dot or space. (Case collisions are sealed away by seal_input.)"""
    reserved = re.compile(r"^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$", re.I)
    bad = re.compile(r'[<>:"\\|?*\x00-\x1f]')
    out = []
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            if reserved.match(n) or bad.search(n) or n.endswith((".", " ")):
                out.append(Path(d, n).relative_to(root).as_posix())
    return out


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
arches       = ["x86_64", "i686", "aarch64", "aarch64_be", "armv7", "armv6", "thumbv7", "riscv64", "riscv32",
                "powerpc", "powerpc64", "powerpc64le", "s390x", "mips", "mipsel", "mips64", "mips64el",
                "loongarch64", "x32"]
# x32 (Names.k arch "x32", x86_64 code with 32-bit pointers) spells its triple through the
# environment, so the triples are per-arch rows rather than "{arch}-linux-musl" (Z5).
name         = "{triple}"
triple       = "{per_arch.triple}"
clang_triple = "{per_arch.clang_triple}"          # 32-bit Arm: quirk armv7-musl-hardfloat
inputs       = ["musl", "linux-uapi"]
runtimes     = ["libunwind", "libcxxabi", "libcxx"]
crt_objects  = true                               # clang_rt.crtbegin.o / crtend.o
cxx_abi      = "libcxxabi"
sysname      = "Linux"
os_dir       = "linux"
static_only  = true
# musl.sh:74 names the dir after the arch, not the clang triple: armv7 is
# armv7-unknown-linux-musl although it is compiled as ...-musleabihf.
resource_layout = "compiler-rt/lib/{per_arch.clang_triple}"
builtins_name   = "libclang_rt.builtins.a"

[per_arch.triple]                                 # SYSROOT.toml triple = the name
x86_64      = "x86_64-linux-musl"
i686        = "i686-linux-musl"
aarch64     = "aarch64-linux-musl"
aarch64_be  = "aarch64_be-linux-musl"
armv7       = "armv7-linux-musl"
armv6       = "armv6-linux-musl"
thumbv7     = "thumbv7-linux-musl"
riscv64     = "riscv64-linux-musl"
riscv32     = "riscv32-linux-musl"
powerpc     = "powerpc-linux-musl"
powerpc64   = "powerpc64-linux-musl"
powerpc64le = "powerpc64le-linux-musl"
s390x       = "s390x-linux-musl"
mips        = "mips-linux-musl"
mipsel      = "mipsel-linux-musl"
mips64      = "mips64-linux-musl"
mips64el    = "mips64el-linux-musl"
loongarch64 = "loongarch64-linux-musl"
x32         = "x86_64-linux-muslx32"

# Before the quirks (armv7-musl-hardfloat rewrites 32-bit Arm to -musleabihf); also the
# compiler-rt dir (musl.sh:74 names it after the arch: armv7-unknown-linux-musl).
[per_arch.clang_triple]
x86_64      = "x86_64-unknown-linux-musl"
i686        = "i686-unknown-linux-musl"
aarch64     = "aarch64-unknown-linux-musl"
aarch64_be  = "aarch64_be-unknown-linux-musl"
armv7       = "armv7-unknown-linux-musl"
armv6       = "armv6-unknown-linux-musl"
thumbv7     = "thumbv7-unknown-linux-musl"
riscv64     = "riscv64-unknown-linux-musl"
riscv32     = "riscv32-unknown-linux-musl"
powerpc     = "powerpc-unknown-linux-musl"
powerpc64   = "powerpc64-unknown-linux-musl"
powerpc64le = "powerpc64le-unknown-linux-musl"
s390x       = "s390x-unknown-linux-musl"
mips        = "mips-unknown-linux-musl"
mipsel      = "mipsel-unknown-linux-musl"
mips64      = "mips64-unknown-linux-musl"
mips64el    = "mips64el-unknown-linux-musl"
loongarch64 = "loongarch64-unknown-linux-musl"
x32         = "x86_64-unknown-linux-muslx32"

[per_arch.musl_arch]                              # ARCH= for musl's Makefile (section 4.4)
x86_64  = "x86_64"
i686    = "i386"
aarch64 = "aarch64"
aarch64_be = "aarch64"                            # musl's SUBARCH _be: same arch/ dir
armv7   = "arm"
armv6   = "arm"
thumbv7 = "arm"
riscv64 = "riscv64"
riscv32 = "riscv32"
# Z5: clang's defaults are the ABIs musl's configure accepts (checked with kcc -dM): ppc64
# ELFv2 (_CALL_ELF 2, musl refuses ELFv1), ppc32 and ppc64 long double = double (musl's
# bits/float.h), mips o32 / n64 hard-float (no -sf SUBARCH), loongarch64 lp64d. kcc passes
# configure's per-arch asm probes too ('d' constraint on ppc, FCSR on loongarch), so no
# -DBROKEN_* define and no per-arch cflags.
powerpc     = "powerpc"
powerpc64   = "powerpc64"
powerpc64le = "powerpc64"                          # musl's SUBARCH le: same arch/ dir
s390x       = "s390x"
mips        = "mips"
mipsel      = "mips"                               # SUBARCH el
mips64      = "mips64"                             # n64 (clang's default for mips64-linux)
mips64el    = "mips64"
loongarch64 = "loongarch64"
x32         = "x32"                                # musl configure: x86_64 + __ILP32__

# Kernel headers_install output depends only on the kernel ARCH and not on endianness or the
# Arm instruction set (P642): linux-uapi/asm/<dir> per arch.
[per_arch.uapi_arch]
x86_64     = "x86_64"
i686       = "i686"
aarch64    = "aarch64"
aarch64_be = "aarch64"
armv7      = "armv7"
armv6      = "armv6"
thumbv7    = "armv7"
riscv64    = "riscv64"
riscv32    = "riscv32"
# Z5: from `make headers_install ARCH=<kernel arch>` (Linux 7.0), dirs named by kernel ARCH.
powerpc     = "powerpc"
powerpc64   = "powerpc"
powerpc64le = "powerpc"
s390x       = "s390"
mips        = "mips"
mipsel      = "mips"
mips64      = "mips"
mips64el    = "mips"
loongarch64 = "loongarch"
x32         = "x86_64"                             # ARCH=x86: asm/ has unistd_x32.h

[libc]                                            # section 4.6, musl provider
configure = ["--target={clang_triple}", "--disable-shared"]
cflags    = ["-O2", "-fPIC"]
targets   = ["lib/libc.a", "lib/crt1.o", "lib/Scrt1.o", "lib/rcrt1.o", "lib/crti.o", "lib/crtn.o", "lib/libcrypt.a", "lib/libdl.a", "lib/libm.a", "lib/libpthread.a", "lib/libresolv.a", "lib/librt.a", "lib/libutil.a", "lib/libxnet.a"]
uapi      = ["linux-uapi/generic", "linux-uapi/asm/{per_arch.uapi_arch}"]   # copied in this order into include/

[builtins]                                        # build-builtins.sh:75-92
source     = "compiler-rt/lib/builtins"
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "COMPILER_RT_DEFAULT_TARGET_ONLY=ON", "COMPILER_RT_INCLUDE_TESTS=OFF", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF"]
c_flags    = ["-nostdlibinc", "-isystem", "{stage}/include"]
cxx_flags  = ["-nostdlibinc", "-nostdinc++", "-isystem", "{stage}/include"]
asm_flags  = ["-nostdlibinc", "-isystem", "{stage}/include"]
assert_cache_regex = ["COMPILER_RT_HAS_[a-z0-9_]+_BFLOAT16:INTERNAL=1"]   # build-builtins.sh:95

# LIBCXX_HAS_MUSL_LIBC: without it __config_site says glibc and <__locale> #errors (P604).
# LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF: musl has none; a compile-only try_compile "finds" it
# and libc++abi then needs it strongly (Alpine's references it weakly, as this gives) (P606).
[runtimes_cmake]                                  # as glibc (build-glibc-runtimes.sh); the
cmake_defs = ["CMAKE_BUILD_TYPE=Release", "CMAKE_SYSTEM_NAME={sysname}", "CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "CMAKE_POSITION_INDEPENDENT_CODE=ON", "LLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF", "LLVM_INCLUDE_TESTS=OFF", "COMPILER_RT_BUILD_CRT=ON", "COMPILER_RT_BUILD_SANITIZERS=OFF", "COMPILER_RT_BUILD_XRAY=OFF", "COMPILER_RT_BUILD_LIBFUZZER=OFF", "COMPILER_RT_BUILD_PROFILE=OFF", "COMPILER_RT_BUILD_MEMPROF=OFF", "COMPILER_RT_BUILD_ORC=OFF", "COMPILER_RT_BUILD_CTX_PROFILE=OFF", "COMPILER_RT_INCLUDE_TESTS=OFF", "LIBUNWIND_ENABLE_SHARED=OFF", "LIBUNWIND_USE_COMPILER_RT=ON", "LIBCXXABI_ENABLE_SHARED=OFF", "LIBCXXABI_USE_LLVM_UNWINDER=ON", "LIBCXXABI_USE_COMPILER_RT=ON", "LIBCXX_ENABLE_SHARED=OFF", "LIBCXX_CXX_ABI=libcxxabi", "LIBCXX_USE_COMPILER_RT=ON", "LIBCXX_INCLUDE_BENCHMARKS=OFF", "LIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF", "LIBCXX_HAS_MUSL_LIBC=ON", "LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF"]
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
# Linux / glibc, built from glibc's own sources for any release and arch (Z4): stubs from
# glibc/abilists, headers from glibc/headers, crt + libc_nonshared.a from glibc/src + glibc/crt.
# Layout and [toml] as kairo-sysroots curate/glibc.sh made the 0.2.0 roots (Ubuntu focal);
# runtimes as build-glibc-runtimes.sh (builtins + crt + C++ runtimes in one configure).
family       = "glibc"
provider     = "glibc"
arches       = ["x86_64", "i686", "aarch64", "armv7", "riscv64", "x32", "aarch64_be", "riscv32", "powerpc", "powerpc64", "powerpc64le", "s390x", "mips", "mipsel", "mips64", "mips64el", "loongarch64", "sparc64"]
name         = "{triple}-glibc{libc_version}"
triple       = "{per_arch.triple}"                # glibc.sh triple_of(): the name minus -glibc<v>
clang_triple = "{triple}"                         # build-glibc-runtimes.sh:58 passes it as is
inputs       = ["glibc/abilists", "glibc/headers", "glibc/src", "glibc/crt", "linux-uapi"]
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
x86_64      = "x86_64-linux-gnu"
i686        = "i686-linux-gnu"
aarch64     = "aarch64-linux-gnu"
armv7       = "armv7-linux-gnueabihf"
riscv64     = "riscv64-linux-gnu"
x32         = "x86_64-linux-gnux32"
aarch64_be  = "aarch64_be-linux-gnu"
riscv32     = "riscv32-linux-gnu"
powerpc     = "powerpc-linux-gnu"
powerpc64   = "powerpc64-linux-gnu"
powerpc64le = "powerpc64le-linux-gnu"
s390x       = "s390x-linux-gnu"
mips        = "mips-linux-gnu"
mipsel      = "mipsel-linux-gnu"
mips64      = "mips64-linux-gnu"
mips64el    = "mips64el-linux-gnu"
loongarch64 = "loongarch64-linux-gnu"
sparc64     = "sparc64-linux-gnu"

[per_arch.multiarch]                              # Debian's multiarch dirs (glibc.sh:65): per-arch headers
x86_64      = "x86_64-linux-gnu"
i686        = "i386-linux-gnu"
aarch64     = "aarch64-linux-gnu"
armv7       = "arm-linux-gnueabihf"
riscv64     = "riscv64-linux-gnu"
x32         = "x86_64-linux-gnux32"
aarch64_be  = "aarch64_be-linux-gnu"
riscv32     = "riscv32-linux-gnu"
powerpc     = "powerpc-linux-gnu"
powerpc64   = "powerpc64-linux-gnu"
powerpc64le = "powerpc64le-linux-gnu"
s390x       = "s390x-linux-gnu"
mips        = "mips-linux-gnu"
mipsel      = "mipsel-linux-gnu"
mips64      = "mips64-linux-gnuabi64"
mips64el    = "mips64el-linux-gnuabi64"
loongarch64 = "loongarch64-linux-gnu"
sparc64     = "sparc64-linux-gnu"

[per_arch.uapi_arch]                              # linux-uapi/asm/<dir>, as the musl recipe's (new
x86_64      = "x86_64"                            # arches: dirs named by kernel ARCH)
i686        = "i686"
aarch64     = "aarch64"
armv7       = "armv7"
riscv64     = "riscv64"
x32         = "x86_64"
aarch64_be  = "aarch64"
riscv32     = "riscv32"
powerpc     = "powerpc"
powerpc64   = "powerpc"
powerpc64le = "powerpc"
s390x       = "s390"
mips        = "mips"
mipsel      = "mips"
mips64      = "mips"
mips64el    = "mips"
loongarch64 = "loongarch"
sparc64     = "sparc"

[per_arch.output_format]                          # the libc.so / libm.so scripts' OUTPUT_FORMAT
x86_64      = "elf64-x86-64"
i686        = "elf32-i386"
aarch64     = "elf64-littleaarch64"
armv7       = "elf32-littlearm"
riscv64     = "elf64-littleriscv"
x32         = "elf32-x86-64"
aarch64_be  = "elf64-bigaarch64"
riscv32     = "elf32-littleriscv"
powerpc     = "elf32-powerpc"
powerpc64   = "elf64-powerpc"
powerpc64le = "elf64-powerpcle"
s390x       = "elf64-s390"
mips        = "elf32-tradbigmips"
mipsel      = "elf32-tradlittlemips"
mips64      = "elf64-tradbigmips"
mips64el    = "elf64-tradlittlemips"
loongarch64 = "elf64-loongarch"
sparc64     = "elf64-sparc"

[libc]                                            # section 4.6, glibc provider (FORMAT.md glibc/*)
abilists = "glibc/abilists"                       # <abi>/<stem>.abilist|.nodes|.compat, targets.toml
headers  = "glibc/headers"                        # generic/ + <arch>/ - [omit], index.toml
src      = "glibc/src"                            # <era>/: what the crt compiles read
crt      = "glibc/crt"                            # <era>/<arch>.toml + <arch>/gen/
uapi     = ["linux-uapi/generic", "linux-uapi/asm/{per_arch.uapi_arch}"]   # copied in this order into include/

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
# (builtins). The crt (crt objects, libmingw*, the CRT and import libraries) is built from
# mingw-crt/ (mingw-w64-crt sources + tables, Scripts/mingw_crt_recipe.py); mingw/crt/<arch>
# holds only what mingw-w64-crt does not build (P623).
family       = "mingw"
provider     = "mingw"
arches       = ["x86_64", "i686", "aarch64", "armv7"]
name         = "{arch}-windows-gnu"
triple       = "{arch}-windows-gnu"
clang_triple = "{arch}-w64-windows-gnu"           # build-builtins.sh:55
inputs       = ["mingw", "mingw-crt"]
runtimes     = ["libunwind", "libcxxabi", "libcxx"]
crt_objects  = false                              # crtbegin.o / crtend.o come from mingw-crt
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
crt     = "mingw/crt/{arch}"                      # winpthreads, libssp, ...: copied into lib/ verbatim

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
# build-wasi-builtins.sh (builtins). The libc is built from wasi-libc/ (sources + tables,
# Scripts/wasi_libc_recipe.py); libc++ is wasi/<v>'s EH build (same fork commit, P624).
family       = "wasi"
provider     = "wasi"
arches       = ["wasm32"]
os_version   = "33"
name         = "wasm32-wasi"
triple       = "wasm32-wasi"
clang_triple = "wasm32-unknown-wasi"
inputs       = ["wasi/{os_version}", "wasi-libc"]
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
# (musleabihf); a plain -musl triple makes clang assume soft-float, another call ABI. Every
# 32-bit Arm musl name is hard-float (names carry no float ABI), thumbv7 too (P642).
[quirk.armv7-musl-hardfloat]
match_family   = ["musl"]
match_cpu      = ["arm"]
target_rewrite = "{arch}-unknown-linux-musleabihf"
musl_arch      = "arm"

# build-builtins.sh:72-89 (-fforce-enable-int128 + SOFTWARE_INT128, every musl/mingw arch),
# Z5: libunwind (LLVM 22) on x32 narrows Registers_x86_64's 64-bit link_reg_t into
# LocalAddressSpace's 32-bit pint_t in an initializer list (DwarfParser.hpp:480), an error
# by default; the value is an x32 address, so it fits. Kept through the derivation's
# warning filter (runtimes_recipe.py KEEP_W).
[quirk.x32-libunwind-narrowing]
match_arch     = ["x32"]
cflags_stages  = ["runtimes"]
cflags_add_cxx = ["-Wno-c++11-narrowing"]

# Z5: 32-bit PowerPC and MIPS have no 8-byte lock-free atomics, so clang emits __atomic_*_8
# libcalls (the Kairo runtime's mimalloc needs __atomic_load_8), and neither musl nor glibc
# ships a libatomic (it is GCC's): compiler-rt's atomic.c goes into the builtins, as for MinGW
# (and riscv32 musl's template fixup, P641).
[quirk.atomics-in-builtins-32]
match_family = ["musl", "glibc"]
match_arch   = ["powerpc", "mips", "mipsel"]
cmake_stages = ["builtins"]
cmake_defs   = ["COMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF"]

# Z5: compiler-rt spells 64-bit SPARC sparcv9; with COMPILER_RT_DEFAULT_TARGET_ONLY its arch is
# the clang triple's first component (COMPILER_RT_DEFAULT_TARGET_TRIPLE is refused then), and
# sparc64 is not in its list, so no builtins or crt objects were configured at all. LLVM reads
# sparc64 and sparcv9 as one arch, so every compile names it sparcv9.
[quirk.sparc64-as-sparcv9]
match_family   = ["glibc"]
match_arch     = ["sparc64"]
target_rewrite = "sparcv9-unknown-linux-gnu"

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
                   "# the Kairo float types a program spells: validate SKIPs it where the target lacks one\n"
                   "# (Z5: no f16 on PowerPC / MIPS, no bf16 there or on SystemZ, no f128 on any of them)\n"
                   "[types]\n\"floats.k\" = [\"f16\"]\n\"tfbf.k\"   = [\"f128\", \"bf16\"]\n\n"
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
        self.kcc_tree = a.kcc_tree.resolve()
        self.runtimes_headers = a.runtimes_headers.resolve() if a.runtimes_headers else None
        self.crt_tree = a.crt_tree.resolve()
        self.template_recipes = [Path(x).resolve() for x in a.template_recipes]
        self.linux_src = a.linux_src.resolve()
        self.seal_notes = {}    # input key -> seal notes (links.tsv / casefold.tsv)
        self.prov = {}          # input key -> list of provenance lines
        self.dropped_links = {}
        self.mingw_defs = {}    # arch -> {lib name: def name}
        self.glibc_stub_ok = {}  # arch -> {curated DSO file name: abilist stem} (stubs proven equal)
        self.glibc_git = a.glibc_git.resolve()


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
        "# glibc releases this share tree builds (glibc/abilists, glibc/headers, glibc/crt). The\n"
        "# floor is the oldest release's abilists read; an arch's own first release is in\n"
        "# glibc/abilists/targets.toml. default = what a name without -glibc<v> means.\n"
        f"versions = [{vs}]\nfloor    = \"{GLIBC_VERSIONS[0]}\"\ndefault  = \"{GLIBC_DEFAULT}\"\n")


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
    kextra = uapi_kernel_arches(c, out)
    ver = (out / "generic" / "linux" / "version.h").read_text()
    m = re.search(r"LINUX_VERSION_MAJOR (\d+).*?PATCHLEVEL (\d+).*?SUBLEVEL (\d+)", ver, re.S)
    c.prov["linux-uapi"] = [
        f"kernel {'.'.join(m.groups()) if m else '?'} headers_install output, taken from the curated "
        "*-linux-musl roots' include/ (Alpine linux-headers) minus musl's own headers and c++/",
        "generic/ = files every arch has (checked identical); asm/<arch>/ = asm/ plus arch-only "
        "headers (" + ", ".join(extra) + "); copy generic/ then every entry of asm/<arch>/",
        "asm/armv6 = asm/armv7 and asm/riscv32 = asm/riscv64 (kernel ARCH twins; x86_64 and i686 "
        "roots carry identical asm/, which is what makes this sound)",
        f"asm/{{{','.join(UAPI_KERNEL)}}}/: `make O=<scratch> headers_install ARCH=<a>` of "
        f"{os.path.relpath(c.linux_src, ROOT) if c.linux_src.is_relative_to(ROOT) else c.linux_src} (Linux "
        "7.0, the curated version), minus generic/ by name (every non-asm file but the curated-only "
        "ones checked identical to generic/); arch-only headers: " + (", ".join(kextra) or "none")]


def uapi_kernel_arches(c: Ctx, out: Path) -> list:
    """asm/<ARCH>/ for UAPI_KERNEL from the Linux tree: the headers_install output minus
    generic/ by name. Every file of it generic/ also has must be byte-identical to generic/'s
    copy (but UAPI_GENERIC_CURATED_ONLY), so generic/ stays one set for every arch."""
    if not (c.linux_src / "Makefile").is_file():
        die(f"linux-uapi: no Linux source tree at {c.linux_src} (--linux-src)")
    gen = out / "generic"
    names = {}
    for d, _, fs in os.walk(gen):
        for f in fs:
            rel = os.path.relpath(os.path.join(d, f), gen).replace(os.sep, "/")
            names[rel[:-6] if rel.endswith(".kcase") else rel] = rel
    extra = []
    for ka in UAPI_KERNEL:
        work = fresh(c.scratch / "uapi" / f"o-{ka}")
        hdr = c.scratch / "uapi" / f"h-{ka}"
        if hdr.exists():
            shutil.rmtree(hdr)
        # O= keeps the source tree clean (it is shared, and read by other runs)
        subprocess.run(["make", "-s", "-C", str(c.linux_src), f"O={work}", f"ARCH={ka}",
                        f"INSTALL_HDR_PATH={hdr}", "headers_install"], check=True, stdout=subprocess.DEVNULL)
        inc = hdr / "include"
        for d, _, fs in os.walk(inc):
            for f in sorted(fs):
                rel = os.path.relpath(os.path.join(d, f), inc).replace(os.sep, "/")
                if rel.split("/")[0] not in UAPI_DIRS:
                    continue
                if rel in names:
                    if rel not in UAPI_GENERIC_CURATED_ONLY and file_sha256(inc / rel) != file_sha256(gen / names[rel]):
                        die(f"linux-uapi: ARCH={ka} {rel} differs from generic/{names[rel]}")
                    continue
                if rel.startswith("asm-generic/") or not (rel.startswith("asm/") or rel.startswith("linux/")):
                    die(f"linux-uapi: ARCH={ka} has {rel}, a shared header generic/ lacks")
                dst = out / "asm" / ka / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(inc / rel, dst)
                if not rel.startswith("asm/"):
                    extra.append(f"{ka}:{rel}")
        shutil.rmtree(work)
    return extra


GLIBC_OWN = ROOT / "Scripts" / "glibc-own"
# Sources glibc ships without its link exception (NOTICE), replaced by Kairo's own files:
# (file in Scripts/glibc-own, path under glibc/src/<era>/, eras). The tables name the same
# relative paths, so nothing else changes.
GLIBC_OWN_FILES = [
    ("init.c", "csu/init.c", ("2.32", "2.33", "2.42")),
    ("static-reloc.c", "csu/static-reloc.c", ("2.32", "2.33", "2.42")),
    ("aarch64-start.S", "sysdeps/aarch64/start.S", ("2.32", "2.33")),     # 2.42's carries the exception
    ("aarch64-read_tp.S", "sysdeps/unix/sysv/linux/aarch64/__read_tp.S", ("2.32", "2.33")),
    ("generic-crti.S", "sysdeps/generic/crti.S", ("2.32", "2.33", "2.42")),
    ("generic-crtn.S", "sysdeps/generic/crtn.S", ("2.32", "2.33", "2.42")),
]
# Sources dropped instead: (path under glibc/src/<era>/, the object the tables build from it,
# eras). powerpc32's _mcount (-pg profiling only) has no replacement; the object leaves the
# powerpc tables and libc_nonshared.a, so `-pg` does not link there.
GLIBC_OWN_DROP = [("sysdeps/powerpc/powerpc32/ppc-mcount.S", "gmon/ppc-mcount.oS", ("2.32", "2.33", "2.42"))]


GLIBC_OWN_LICENSES = [(ROOT / "LICENSE", "Kairo-Apache-2.0.txt"),
                      (ROOT / "LICENSES" / "AdditionRef-Kairo-Runtime-exception.txt",
                       "AdditionRef-Kairo-Runtime-exception.txt")]


def drop_table_object(text: str, obj: str) -> str:
    """The table with the compile that makes `obj` and every mention of it removed."""
    parts = re.split(r"(?m)^(?=\[(?:compile|link)\.)", text)
    keep = [x for x in parts if not (x.startswith("[compile.") and f'out  = "{obj}"' in x)]
    text = "".join(keep)
    text = re.sub(rf'(?m)^ +"\{{out\}}/{re.escape(obj)}",\n', "", text)
    return text.replace(f', "{obj}"', "").replace(f'"{obj}", ', "")


def glibc_own_overlay(share: Path) -> list[str]:
    """Put Kairo's own start-file sources (Scripts/glibc-own/) over glibc's in <share>/glibc/src
    and drop what has no replacement from the tables; idempotent. Returns provenance lines."""
    g = share / "glibc"
    for own, rel, eras in GLIBC_OWN_FILES:
        for era in eras:
            dst = g / "src" / era / rel
            if not dst.is_file():
                die(f"glibc-own: {dst} is not in the share (the recipe no longer reads it?)")
            shutil.copyfile(GLIBC_OWN / own, dst)
    for rel, obj, eras in GLIBC_OWN_DROP:
        for era in eras:
            (g / "src" / era / rel).unlink(missing_ok=True)
            for t in sorted((g / "crt" / era).glob("*.toml")):
                old = t.read_text()
                if f'"{obj}"' in old:
                    t.write_text(drop_table_object(old, obj))
                    if rel in old and f"{{src}}/{rel}" in t.read_text():
                        die(f"glibc-own: {t} still names {rel}")
    d = share / "licenses" / "glibc"
    if d.is_dir():      # build_licenses adds them too; this keeps an --only glibc-own run complete
        for src_, name in GLIBC_OWN_LICENSES:
            shutil.copyfile(src_, d / name)
    return [f"Scripts/glibc-own/ over glibc/src/<era>/: "
            + ", ".join(f"{rel} ({'/'.join(eras)})" for _, rel, eras in GLIBC_OWN_FILES)
            + " are Kairo's own files or adapted from a glibc file that has the link exception "
            "(audit: Scripts/audit_glibc_exception.py); "
            + ", ".join(f"{rel} dropped from the tables ({'/'.join(eras)}; no -pg on powerpc32)"
                        for rel, _, eras in GLIBC_OWN_DROP)]


def build_glibc_own(c: Ctx) -> None:
    """Re-apply glibc_own_overlay to an existing share (--only glibc-own): no glibc rebuild."""
    old = tomllib.loads((c.share / "provenance.toml").read_text()).get("glibc/src", {}).get("how", [])
    old = [h.replace("), unchanged", "), then overridden where the next line says") for h in old]
    c.prov["glibc/src"] = [h for h in old if not h.startswith("Scripts/glibc-own/")] + glibc_own_overlay(c.share)


def build_glibc(c: Ctx) -> None:
    """glibc/abilists, glibc/headers, glibc/src + glibc/crt from glibc git and Linux source
    (Scripts/glibc_abilists.py, glibc_headers.py, glibc_crt_recipe.py; their work dirs under
    <scratch>/glibc keep the configured trees, so a rerun only redoes what changed)."""
    import glibc_abilists, glibc_compat, glibc_headers, glibc_crt_recipe
    g = c.share / "glibc"
    work = c.scratch / "glibc"
    work.mkdir(parents=True, exist_ok=True)
    for old in sorted(g.glob("2.*")) if g.is_dir() else []:
        if old.is_dir():
            shutil.rmtree(old)                 # the per-release Ubuntu inputs (pre-Z4)
    tags, per_tag = glibc_abilists.collect(c.glibc_git, work / "abilist-cache")
    merged = glibc_abilists.merge(tags, per_tag)
    compat = glibc_compat.compat_rows(c.glibc_git, work / "abilist-cache", tags, merged)
    glibc_abilists.write(fresh(g / "abilists"), tags, merged, compat)
    if tags[0] != GLIBC_VERSIONS[0] or tags[-1] != GLIBC_VERSIONS[-1]:
        die(f"glibc tags {tags[0]}..{tags[-1]} != GLIBC_VERSIONS {GLIBC_VERSIONS[0]}..{GLIBC_VERSIONS[-1]}")
    py = sys.executable
    for argv in ([py, str(ROOT / "Scripts/glibc_headers.py"), "build", "--git", str(c.glibc_git),
                  "--abilists", str(g / "abilists"),
                  "--linux", str(c.linux_src), "--work", str(work / "build"), "--out", str(fresh(g / "headers"))],
                 [py, str(ROOT / "Scripts/glibc_crt_recipe.py"), "--git", str(c.glibc_git), "--linux",
                  str(c.linux_src), "--work", str(work / "build"), "--out", str(work / "crt-out")]):
        subprocess.run(argv, check=True)
    for d in ("src", "crt"):
        fresh(g / d)
        copy_tree(work / "crt-out" / d, g / d)
    own_note = glibc_own_overlay(c.share)
    newest = tags[-1]
    head = subprocess.run(["git", "-C", str(c.glibc_git), "rev-parse", f"glibc-{newest}^{{commit}}"],
                          capture_output=True, text=True).stdout.strip()[:12]
    c.prov["glibc/abilists"] = [
        f"glibc git ({c.glibc_git}) tags glibc-{tags[0]} .. glibc-{newest}: every sysdeps/**/*.abilist, mapped "
        "to ABIs (glibc_abilists.ABI_DIRS) and merged with the releases exporting each entry",
        "<stem>.compat: compat-only bindings found in each tag's source (compat_symbol and friends, "
        "Scripts/glibc_compat.py); checked against the Ubuntu focal 2.31 DSOs on five arches"]
    c.prov["glibc/headers"] = [
        f"glibc-{newest} ({head}) configure + make install-headers per arch, clang as CC, against "
        f"Linux UAPI from {c.linux_src} (work dir only); gnu/lib-names-<abi>.h from glibc's make, "
        "gnu/stubs*.h written by glibc_headers.py; generic/ + <arch>/ + [omit] by majority vote",
        "version gates: features.h __GLIBC_MINOR__ set per target by ksys; glibc_headers.GATES"]
    c.prov["glibc/src"] = [f"glibc-2.32, glibc-2.33, glibc-{newest} source files the crt compiles read "
                           "(their -MD dependency lists), then overridden where the next line says", own_note[0]]
    c.prov["glibc/crt"] = ["per era and arch: the compiles and -r links glibc's own make ran for csu/"
                           "{crt1,Scrt1,crti,crtn}.o and every subdir's static-only-routines "
                           "(libc_nonshared.a), clang as CC; gen/ = the configure/make outputs they include"]
    for k in GLIBC_KEYS:
        sweep_links(g / k.split("/", 1)[1], c.dropped_links.setdefault(k, []))


def glibc_stub_parity(c: Ctx) -> list:
    """The 2.31 proof: every stub DSO rebuilt from the SHIPPED glibc/abilists projected at 2.31
    and compared with the curated focal DSO: SONAME and the public versioned dynsym (name,
    node, @/@@, kind, size). Differences are listed, not hidden."""
    import glibc_abilists
    rec = load_recipe(FAMILIES["glibc"])
    cc = [str(c.cc)]
    ab = c.share / "glibc" / "abilists"
    targets = tomllib.loads((ab / "targets.toml").read_text())
    rows = ["glibc stubs from glibc/abilists at 2.31 (kcc + lld) vs curated focal DSOs:",
            "arch     | lib        | soname                       | symbols | result",
            "---------|------------|------------------------------|--------:|-------"]
    for arch in ("x86_64", "i686", "aarch64", "armv7", "riscv64"):
        env = target_env(rec, arch, "2.31")
        t = targets[arch]
        for stem in glibc_abilists.STEMS:
            if not (ab / t["abi"] / f"{stem}.abilist").is_file():
                continue
            soname = t["ld"] if stem == "ld" else targets["sonames"][stem]
            cur = c.curated / env["name"] / "lib" / soname
            if not cur.exists():
                continue
            ents, nodes = glibc_abilists.project(ab / t["abi"], "2.31", stem)
            work = c.scratch / "glibc-stubs" / arch / stem
            so = glibc_stubs.build_stub(cc, env["clang_triple"], soname, ents, nodes, work)
            diffs = glibc_stubs.compare(glibc_stubs.read_dso(cur), glibc_stubs.read_dso(so))
            if not diffs:
                ok = c.glibc_stub_ok.setdefault(arch, {})
                ok[soname] = stem
                ok[os.path.basename(os.path.realpath(cur))] = stem
            rows.append(f"{arch:<8} | {stem:<10} | {soname:<28} | {len(ents):>7} | "
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

    built = mingw_crt_installed(c)
    if built:
        # mingw-crt/ builds every crt file and import library mingw-w64-crt has, so mingw/
        # carries no def/ and crt/<arch> only what mingw-w64-crt does not build.
        stats = []
        for a in MINGW_ARCHES:
            (out / "crt" / a).mkdir(parents=True)
            keep = [f for f in sorted((roots[a] / "lib").iterdir())
                    if f.is_file() and f.name not in MINGW_FROM_RUNTIMES and not f.name.endswith(".la")
                    and f"lib/{f.name}" not in built[a]]
            for f in keep:
                shutil.copyfile(f, out / "crt" / a / f.name)
            stats.append(f"{a}: crt/ = {len(keep)} files mingw-w64-crt does not build ({', '.join(f.name for f in keep)})")
        c.prov["mingw"] = [
            "include/: the curated windows-gnu roots' include/ (llvm-mingw 20260224), minus c++/ and "
            "libunwind's headers; byte-identical on all four arches, so shipped once",
            "crt/<arch>/: the curated lib/ files that mingw-crt/<arch>.toml [install] does not build "
            "(winpthreads, libssp, winstorecompat, windowsappcompat, libomp's import lib: P623), verbatim; "
            "no def/ (mingw-crt builds every import library, P622)", *stats]
        return
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


def mingw_crt_installed(c: Ctx) -> dict:
    """arch -> the root paths mingw-crt/<arch>.toml [install] builds; {} unless every arch has a
    table (then mingw/ need not carry what they build)."""
    out = {}
    for a in MINGW_ARCHES:
        t = c.share / "mingw-crt" / f"{a}.toml"
        if not t.is_file():
            return {}
        out[a] = set(tomllib.loads(t.read_text())["install"])
    return out


def wasi_libc_built(c: Ctx) -> set:
    """The root paths wasi-libc/<name>.toml builds (headers, installed libs, empty archives);
    empty without the table."""
    t = c.share / "wasi-libc" / "wasm32-wasi.toml"
    if not t.is_file():
        return set()
    w = tomllib.loads(t.read_text())
    return set(w["headers"]) | set(w["install"]) | set(w.get("empty", []))


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
    # What wasi-libc/ builds (the libc headers and libraries) is not shipped twice. This
    # skip only ever matched a top-level noeh/, so the noeh/ trees under wasm32-wasi/ ship.
    built = wasi_libc_built(c)
    for d in ("include", "lib"):
        copy_tree(src / d, out / d, lambda r, d=d: r == "noeh" or f"{d}/{r}" in built)
    remove_empty_dirs(out)
    must = ["lib/wasm32-wasi/eh/libc++.a"] + ([] if built else ["lib/wasm32-wasi/crt1-command.o"])
    for m in must:
        if not (out / m).is_file():
            die(f"wasi: no {m}")
    c.prov[f"wasi/{WASI_VERSION}"] = [
        "curated wasm32-wasi root (wasi-sdk 33 sysroot): include/ and lib/ minus compiler-rt/"
        + (f", minus the {len(built)} libc headers and libraries wasi-libc/ builds: libc++ "
           "(eh/, noeh/) and the LTO libc (lib/wasm32-wasi/llvm-lto/, not built from source: P626)" if built else "")]


def build_licenses(c: Ctx) -> None:
    lt, out = ROOT / "Scripts" / "license-texts", fresh(c.share / "licenses")
    m = ROOT / "Lib" / "libc" / "mingw"
    # glibc's own notices from the newest tag the inputs come from (ZIG-STUDY 12.4); COPYING
    # (GPL-2.0) because LICENSES and some build scripts refer to it
    glibc_src = c.scratch / "glibc" / "build" / "src" / f"glibc-{GLIBC_VERSIONS[-1]}"
    files = {
        "musl": [ROOT / "Lib/libc/musl/COPYRIGHT"],
        "linux-uapi": [lt / "GPL-2.0-only.txt", lt / "Linux-syscall-note.txt"],
        "glibc": [lt / "LGPL-2.1-or-later.txt", (glibc_src / "COPYING.LIB", "COPYING.LIB"),
                  (glibc_src / "LICENSES", "LICENSES"), (glibc_src / "COPYING", "COPYING"),
                  *GLIBC_OWN_LICENSES],
        "mingw": [m / "COPYING", m / "DISCLAIMER", m / "DISCLAIMER.PD"],
        "freebsd": [lt / "FreeBSD-COPYRIGHT.txt"],
        "netbsd": [lt / "NetBSD-COPYRIGHT.txt"],
        "wasi": sorted((ROOT / "Lib/libc/wasi").glob("LICENSE*")),
        "runtimes": [ROOT / "Lib/llvm-runtimes/LICENSE.TXT"],
        "runtimes-recipe": [ROOT / "Lib/llvm-runtimes/LICENSE.TXT"],
        "runtimes-template": [ROOT / "Lib/llvm-runtimes/LICENSE.TXT"],
        "mingw-crt": [m / "COPYING", m / "DISCLAIMER", m / "DISCLAIMER.PD"],
        "wasi-libc": sorted((ROOT / "Lib/libc/wasi").glob("LICENSE*")),
    }
    for comp, srcs in files.items():
        d = out / comp
        d.mkdir()
        for s in srcs:
            s, n = (s if isinstance(s, tuple) else (s, s.name))
            shutil.copyfile(s, d / n)
    # Not in the sparse checkout. Each is a DIR holding <name>.txt: `git show HEAD:<dir>` printed a
    # tree listing.
    import mingw_crt_recipe
    for comp, rev in (("mingw", "HEAD"), ("mingw-crt", mingw_crt_recipe.PIN)):
        for n in ("COPYING.MinGW-w64-runtime", "COPYING.MinGW-w64"):
            txt = subprocess.run(["git", "-C", str(m), "show", f"{rev}:{n}/{n}.txt"], check=True,
                                 capture_output=True).stdout
            (out / comp / f"{n}.txt").write_bytes(txt)
    for f in (ROOT / "Lib/libc/wasi/libc-top-half/musl").glob("COPYRIGHT"):
        shutil.copyfile(f, out / "wasi-libc" / "musl-COPYRIGHT")


def build_runtimes_recipe(c: Ctx) -> None:
    """runtimes-recipe/: the direct-compile tables for every bundled target (Scripts/
    runtimes_recipe.py). Configures each family recipe with CMake against a libc-headers
    stage of the curated root (scratch: <scratch>/runtimes-recipe); compiles nothing."""
    import runtimes_recipe
    rev, _, rt = stage_runtimes(c)
    tree = c.kcc_tree
    runtimes_recipe.derive(c.share, rt, c.curated, tree, c.scratch / "runtimes-recipe",
                           headers=getattr(c, "runtimes_headers", None))
    c.prov["runtimes-recipe"] = [
        f"Scripts/runtimes_recipe.py: CMake configure of each family recipe ([builtins], [runtimes_cmake], "
        f"quirks) for the bundled targets, runtimes REVISION {rev}, kcc {tree / 'bin' / 'kcc'}; "
        "ninja -t compdb + build.ninja archive edges, normalised and deduplicated; generated headers "
        "(__config_site, module.modulemap, libcxx.imp) copied from the configure"]


def build_runtimes_template(c: Ctx) -> None:
    """runtimes-template/ (FORMAT.md "runtimes-template/"): Scripts/runtimes_template.py over
    <out>/runtimes-recipe plus every --template-recipes dir (a later one wins per target), so
    its fragments are as general as every CMake table there is. The script re-instantiates each
    input target from what it wrote and exits 1 on any difference."""
    recipes = [c.share / "runtimes-recipe", *c.template_recipes]
    for r in recipes:
        if not (r / "index.toml").is_file():
            die(f"runtimes-template: {r} is not a runtimes-recipe/ dir (no index.toml)")
    out = c.share / "runtimes-template"
    if out.exists():
        shutil.rmtree(out)
    cmd = [sys.executable, str(ROOT / "Scripts" / "runtimes_template.py")]
    for r in recipes:
        cmd += ["--recipe", str(r)]
    r = subprocess.run(cmd + ["--out", str(out)], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"runtimes_template.py failed:\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
    head = next((l for l in r.stdout.splitlines() if l.startswith("template:")), "")
    derived = tomllib.loads((out / "index.toml").read_text())["derived"]
    extra = sorted(set(derived) - set(tomllib.loads((c.share / "runtimes-recipe" / "index.toml").read_text())["targets"]))
    c.prov["runtimes-template"] = [
        "Scripts/runtimes_template.py over runtimes-recipe/" + "".join(
            f" + {os.path.relpath(x, ROOT) if x.is_relative_to(ROOT) else x}" for x in c.template_recipes)
        + f" ({head.strip() or f'{len(derived)} targets'}; every one re-instantiated and compared IDENTICAL)",
        "targets with no shipped table, derived from the extra CMake tables: " + (", ".join(extra) or "none"),
        "build/ and headers/ per family: the runtimes-recipe trees of that family"]


def build_mingw_crt(c: Ctx) -> None:
    """mingw-crt/: mingw-w64-crt sources at mingw_crt_recipe.PIN + per-arch tables derived from
    its configure + `make -n` (Scripts/mingw_crt_recipe.py); built once per arch from the full
    checkout to learn which sources and headers src/ must hold."""
    import mingw_crt_recipe as M
    if not (c.share / "mingw" / "include").is_dir():
        die("mingw-crt needs mingw/include (run the mingw step first)")
    stats = M.make_all(c.share, c.scratch / "mingw-crt", c.curated, ROOT / "build" / "relcand" / "bin" / "kcc",
                       c.crt_tree)
    c.prov["mingw-crt"] = [
        f"src/: Lib/libc/mingw mingw-w64-crt at {M.PIN[:12]} (git archive; the last commit before llvm-mingw "
        "20260224, the release mingw/include and the curated roots are), only the files the tables name plus "
        "the headers a reference build read (-MD) and def-include/",
        "<arch>.toml: configure --host=<arch>-w64-mingw32 " + " ".join(M.COMMON_CONFIGURE) + " CFLAGS=-O2 (llvm-mingw "
        "build-mingw-w64.sh's flags; -g dropped), then `make -n all V=1` parsed: compiles, .def.in cpp, dlltool "
        "import libs, ar cru, MRI merges (flattened to addlib), cp aliases (resolved into [install])",
        *[f"{a}: {n[0]} compiles, {n[1]} defs, {n[2]} archives, {n[3]} installed files" for a, n in stats.items()],
        "gen/<arch>/: configure's config.h, the Makefile's _libm_dummy.c"]


def build_wasi_libc(c: Ctx) -> None:
    import wasi_libc_recipe as W
    W.make_all(c.share, c.scratch / "wasi-libc", c.crt_tree)
    c.prov["wasi-libc"] = W.provenance()


def stage_runtimes(c: Ctx) -> tuple[str, str, Path]:
    if getattr(c, "_rt_stage", None):
        return c._rt_stage
    import package_release
    dst = fresh(c.scratch / "runtimes-stage")
    package_release.stage_runtimes(dst)
    rt = dst / "share" / "kairo" / "runtimes"
    c._rt_stage = ((rt / "REVISION").read_text().strip(), tree_sha256(rt, legacy=SCHEMA == 1), rt)
    return c._rt_stage


def write_registry(c: Ctx, rt_hash: str) -> None:
    keys = ["musl", "linux-uapi", f"wasi/{WASI_VERSION}", "mingw"]
    keys += GLIBC_KEYS
    keys += [f"{o}/{v}/{a}" for o, (v, arches) in BSD.items() for a in arches]
    if (c.share / "runtimes-recipe" / "index.toml").is_file():
        keys.append("runtimes-recipe")
    keys += [k for k in EXTRA_KEYS if (c.share / k).is_dir()]
    keys = sorted(keys)
    hazards = []
    for k in keys:
        if SCHEMA >= 2:
            c.seal_notes[k] = seal_input(c.share / k)
        hazards += [f"{k}/{h}" for h in windows_hazards(c.share / k)]
    if hazards:
        die("names a Windows extract cannot create: " + ", ".join(hazards[:10]))
    hashes = {k: tree_sha256(c.share / k, legacy=SCHEMA == 1) for k in keys}
    hashes["runtimes"] = rt_hash
    keys = sorted(hashes)
    w = max(len(k) for k in keys) + 2
    lines = ["# generated by Scripts/ship_sysroot_inputs.py; do not edit. Format: FORMAT.md.",
             f"schema = {SCHEMA}", "", "[inputs]"]
    lines += [f'{chr(34) + k + chr(34):<{w}} = "{hashes[k]}"' for k in keys]
    lines += ["", "[licenses]"]
    lines += [f'{chr(34) + k + chr(34):<{w}} = "{LICENSE_KEYS.get(k) or LICENSES[k.split("/")[0]]}"' for k in keys]
    (c.share / "registry.toml").write_text("\n".join(lines) + "\n")


def write_provenance(c: Ctx, rev: str, merge: bool = False) -> None:
    """Human/audit record; ksys never reads it (not part of FORMAT.md's contract)."""
    def q(s: str) -> str:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    lines = ["# where every input came from; generated by Scripts/ship_sysroot_inputs.py", ""]
    c.prov["runtimes"] = [f"not copied: share/kairo/runtimes as Scripts/package_release.py stages it (REVISION {rev})"]
    old = {}
    if merge and (c.share / "provenance.toml").is_file():
        # --only: keep every section this run did not rebuild, as the last run wrote it
        old = tomllib.loads((c.share / "provenance.toml").read_text())
    keys = sorted(set(c.prov) | set(old))
    for k in keys:
        how = list(c.prov.get(k, old.get(k, {}).get("how", [])))
        how += [n for n in c.seal_notes.get(k, []) if n not in how]
        lines.append(f"[{q(k)}]")
        lines.append("how = [" + ", ".join(q(s) for s in how) + "]")
        n = len(c.dropped_links.get(k, [])) if k in c.prov else old.get(k, {}).get("dropped_symlinks", 0)
        if n:
            lines.append(f"dropped_symlinks = {n}   # absolute, escaping or dangling")
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
        # Since Z4 glibc roots are built from source: headers from glibc/headers (newest
        # release, not focal's 2.31), crt objects and libc_nonshared.a compiled from glibc/src.
        if rel.startswith("include/c++/"):
            return "DERIVED", f"{rt}: libc++ headers (4.7)"
        if rel.startswith("include/"):
            return "DERIVED", "glibc/headers (glibc install-headers, newest release) + linux-uapi"
        n = rel[len("lib/"):]
        if n in ("libc++.a", "libc++abi.a", "libc++experimental.a", "libunwind.a"):
            return "DERIVED", f"{rt}: runtimes stage (4.7)"
        if n in ("crt1.o", "Scrt1.o", "crti.o", "crtn.o", "libc_nonshared.a"):
            return "DERIVED", "compiled from glibc/src per glibc/crt/2.32/<arch>.toml (4.6)"
        if n.endswith(".o"):
            return "DROPPED", "gcrt1/Mcrt1/rcrt1/grcrt1: profiling and static-pie start files, not built"
        if n in ("libc.so", "libm.so"):
            return "DERIVED", "linker script the glibc provider writes (4.6)"
        if n.endswith(".a"):
            return "DROPPED", "static glibc archive: the recipe links glibc dynamically (static = false)"
        ok = c.glibc_stub_ok.get(arch, {})
        stem = ok.get(n)
        if not stem and p.is_symlink() and ok.get(os.path.basename(os.path.realpath(p))):
            return "DERIVED", "alias link to a stub DSO (Debian's ld-linux.so.3 -> ld-linux-armhf.so.3)"
        if stem:
            return "DERIVED", f"stub DSO from glibc/abilists at 2.31 ({stem}; regenerated, dynsym equal)"
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
        if rel in mingw_crt_installed(c).get(arch, set()):
            return "DERIVED", f"mingw-crt/{arch}.toml (built from mingw-w64-crt sources)"
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
        if rel in wasi_libc_built(c):
            return "DERIVED", "wasi-libc/wasm32-wasi.toml (built from wasi-libc sources)"
        if _same(p, S / "wasi" / WASI_VERSION / rel):
            return "VERBATIM", f"wasi/{WASI_VERSION}"
        return "GAP", "not in wasi input"
    return "GAP", "unknown family"


# ---------------------------------------------------------------- main

STEPS = ["data", "musl", "uapi", "glibc", "mingw", "bsd", "wasi", "runtimes-recipe", "runtimes-template",
         "mingw-crt", "wasi-libc", "licenses"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--scratch", type=Path, default=ROOT / "build" / "sysgen" / "a2")
    ap.add_argument("--curated", type=Path, default=ROOT / "build" / "x86_64-linux-gnu" / "release" / "sysroot")
    ap.add_argument("--kairo-sysroots", type=Path, default=Path.home() / "linux-dev" / "projects" / "kairo-sysroots")
    ap.add_argument("--bsd-trim", type=Path, default=ROOT / "build" / "sysgen" / "bsd-trim")
    ap.add_argument("--cc", type=Path, default=ROOT / "build" / "x86_64-linux-gnu" / "release" / "bin" / "kcc",
                    help="compiler driver for the glibc stub check (--report)")
    ap.add_argument("--kcc-tree", type=Path, default=ROOT / "build" / "x86_64-linux-musl" / "release",
                    help="toolchain tree whose kcc configures the runtimes-recipe step (its bin/ and lib/ "
                         "are linked into a kit without sysroot/: kcc prefers <prefix>/sysroot/<target>)")
    ap.add_argument("--runtimes-headers", type=Path, default=None,
                    help="runtimes-recipe step: dir of <name>/ libc-headers roots for targets with no curated "
                         "root (armv6/riscv32 musl; Scripts/runtimes_recipe.py --headers)")
    ap.add_argument("--crt-tree", type=Path, default=ROOT / "build" / "relcand",
                    help="toolchain whose kcc builds the mingw-crt / wasi-libc reference builds (linked into a "
                         "kit without sysroot/, P610)")
    ap.add_argument("--template-recipes", type=Path, nargs="+", default=[],
                    help="runtimes-template step: runtimes-recipe/ dirs to derive over besides <out>/runtimes-recipe "
                         "(the EXTRA targets' tables, e.g. build/sysgen/b3/rr-with-armv6-riscv32)")
    ap.add_argument("--linux-src", type=Path, default=ROOT / "build" / "sysgen" / "linux",
                    help="uapi step: Linux 7.0 source tree for the kernel ARCHes no curated root covers "
                         "(UAPI_KERNEL: headers_install out of tree, O= under the scratch dir)")
    ap.add_argument("--glibc-git", type=Path, default=ROOT / "build" / "sysgen" / "glibc",
                    help="glibc step: glibc git clone with the release tags (abilists, headers, crt sources)")
    ap.add_argument("--only", nargs="+", choices=STEPS + ["glibc-own"],
                    help="rebuild only these inputs (registry is always rewritten); glibc-own re-applies "
                         "Scripts/glibc-own/ to the glibc inputs already in <out>, without rebuilding glibc")
    ap.add_argument("--report", action="store_true", help="size report + parity check into <scratch>/")
    ap.add_argument("--legacy-links", action="store_true",
                    help="schema 1: keep the BSD symlinks on disk and hash following them (the reader "
                         "before P612); the default (schema 2) records them in links.tsv instead")
    ap.add_argument("--upgrade-schema", action="store_true",
                    help="allow writing schema 2 over an existing schema 1 tree (a ksys that reads only "
                         "schema 1 then refuses it: flip a shared tree only with its reader)")
    a = ap.parse_args()
    global SCHEMA
    if a.legacy_links:
        SCHEMA = 1
    have = registry_schema(a.out)
    if have is not None and have != SCHEMA and not (a.upgrade_schema and SCHEMA > have):
        die(f"{a.out} is registry schema {have}, this run would write schema {SCHEMA}: pass "
            + ("--legacy-links to keep schema 1, or --upgrade-schema to flip it (P612)" if have == 1
               else "no --legacy-links (a schema 2 tree is never downgraded in place)"))
    c = Ctx(a)
    c.share.mkdir(parents=True, exist_ok=True)
    c.scratch.mkdir(parents=True, exist_ok=True)
    steps = a.only or STEPS
    fn = {"data": build_data, "musl": build_musl, "uapi": build_uapi, "glibc": build_glibc, "glibc-own": build_glibc_own,
          "mingw": build_mingw, "bsd": build_bsd, "wasi": build_wasi, "runtimes-recipe": build_runtimes_recipe,
          "runtimes-template": build_runtimes_template,
          "mingw-crt": build_mingw_crt, "wasi-libc": build_wasi_libc, "licenses": build_licenses}
    for s in steps:
        log(f"== {s}")
        fn[s](c)
    if a.only and "mingw" not in steps:
        # mingw_defs feeds parity; rebuild the mapping from what is on disk
        for arch in MINGW_ARCHES:
            for d in sorted((c.share / "mingw" / "def" / arch).glob("*.def")) if (c.share / "mingw" / "def").is_dir() else []:
                c.mingw_defs.setdefault(arch, {})[f"lib{d.stem}.a"] = d.name
    log("== runtimes (hash only)")
    rev, rt_hash, rt = stage_runtimes(c)
    write_registry(c, rt_hash)
    write_provenance(c, rev, merge=bool(a.only))
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
