#!/usr/bin/env python3
"""glibc's installed headers for every arch, from one release, deduplicated (FORMAT.md
"glibc/headers").

Maintainer tool, never shipped. Per arch, glibc's own configure and `make install-headers`
run offline with clang as CC against Linux UAPI headers made by the kernel's own
`make headers_install` (in the work dir only: the share's linux-uapi is a separate input),
plus the two files install-headers leaves to a full build: gnu/lib-names-<abi>.h (glibc's own
make target for it) and gnu/stubs.h / stubs-<abi>.h (written here: the __stub_ list a full
build derives from its stub objects; see STUBS).

Dedup: for each header path the content most arches share is the generic copy, if more than
one arch has it; every arch whose copy differs, or that has a path no other arch shares, gets
its own under <arch>/; a generic path an arch's install lacks is listed in index.toml [omit],
so generic + <arch> - omit is that arch's install exactly. The majority rule is Zig's
(tools/process_headers.zig); the omit list is ours. No Zig code or data is used.

Version gates (decided 2026-11-09, FORMAT.md "glibc/headers"): one header set, the newest
release's, serves every release. ksys writes the target's minor into the one
`#define __GLIBC_MINOR__` line of features.h (no compile flag: SYSROOT.toml stays as it is),
so `__GLIBC_PREREQ` and libc++'s glibc checks see the target. Declarations newer than the
target stay declared (using one fails at link time: the stubs do not export it, as in Zig). A
header that binds an OLD name to a symbol only newer releases export (__REDIRECT to
__isoc23_strtol, fcntl64, ...) would break a link that names nothing new, so those few are
gated on __GLIBC_MINOR__ here (GATES, each marked `Kairo:`): every asm label the installed
headers can bind a declaration to, in C / _GNU_SOURCE / C23 / _FILE_OFFSET_BITS=64 /
_TIME_BITS=64 / _FORTIFY_SOURCE=3 / C++, checked against the first release exporting it
(build/sysgen/z4/tools/redirects.py, 2026-11-09). Not gated: names new in their own right
(strlcpy, preadv64v2, fts64_* with LFS), the stat family (libc_nonshared.a provides stat64 and
the rest before 2.33), and _TIME_BITS=64 (the __*_time64 symbols, 2.34; an explicit opt-in).

    python3 Scripts/glibc_headers.py build --git build/sysgen/glibc --linux build/sysgen/linux \
        --work build/sysgen/z4/hdrwork --out DIR [--tag 2.42] [--arches ...]
"""
import argparse
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
import glibc_crt_recipe as gcr  # noqa: E402  (ARCHES, configure, uapi, source)

# The __stub_ macros a full build of the newest release writes on Linux: the generic stub
# functions no Linux file replaces (checked against glibc 2.44's installed stubs-64.h and
# stubs-32.h), plus __compat_<x> for the old-syscall compat wrappers an arch has in its
# abilist but whose __NR_<x> its kernel headers lack (x86_64: bdflush; aarch64: all five).
STUBS = ["chflags", "fchflags", "gtty", "revoke", "setlogin", "sigreturn", "stty"]
COMPAT_SYSCALLS = {"bdflush": "__NR_bdflush", "create_module": "__NR_create_module",
                   "get_kernel_syms": "__NR_get_kernel_syms", "query_module": "__NR_query_module",
                   "uselib": "__NR_uselib"}

# (file, exact text, replacement): our version gates. Each guards a binding of an old name to
# a symbol newer than some supported release; the replacement keeps the newest behaviour when
# the target is new enough.
GATES = [
    # __GLIBC_MINOR__ is defined near the end of features.h, after the tests below read it:
    # it moves up (ksys rewrites this one line per target, wherever it is).
    ("features.h", "#define\t__GLIBC_MINOR__\t{minor}\n", ""),
    ("features.h", "#define\t_FEATURES_H\t1\n",
     "#define\t_FEATURES_H\t1\n\n/* Kairo: the target release; ksys writes its minor here.  */\n"
     "#define\t__GLIBC_MINOR__\t{minor}\n"),
    ("features.h",
     "#if __GLIBC_USE (ISOC23)\n# define __GLIBC_USE_C23_STRTOL 1\n",
     "/* Kairo: strtol, scanf and the rest bind to __isoc23_* only where glibc\n"
     "   exports those (2.38); older targets keep the old names.  */\n"
     "#if __GLIBC_USE (ISOC23) && __GLIBC_MINOR__ >= 38\n# define __GLIBC_USE_C23_STRTOL 1\n"),
    ("fcntl.h",
     "# ifndef __USE_FILE_OFFSET64\nextern int fcntl (int __fd, int __cmd, ...);\n",
     "/* Kairo: fcntl64 is exported from 2.28; before it fcntl took the 64-bit locks.  */\n"
     "# if !defined __USE_FILE_OFFSET64 || __GLIBC_MINOR__ < 28\nextern int fcntl (int __fd, int __cmd, ...);\n"),
    ("arpa/inet.h",
     "#if __USE_FORTIFY_LEVEL > 0 && defined __fortify_function\n/* Include functions with security checks.  */\n"
     "#  include <bits/inet-fortified.h>",
     "/* Kairo: __inet_pton_chk / __inet_ntop_chk are exported from 2.42.  */\n"
     "#if __USE_FORTIFY_LEVEL > 0 && defined __fortify_function && __GLIBC_MINOR__ >= 42\n"
     "/* Include functions with security checks.  */\n#  include <bits/inet-fortified.h>"),
]


def log(m):
    print(f"[glibc-headers] {m}", file=sys.stderr, flush=True)


def install(git, linux, work, tag, arch, cc):
    src = gcr.source(git, tag, work)
    inc = gcr.uapi(linux, gcr.ARCHES[arch][2], work)
    b = work / "b" / tag / arch
    gcr.configure(src, b, arch, inc, cc)
    out = work / "hdr" / tag / arch
    shutil.rmtree(out, ignore_errors=True)
    if gcr.run(["make", "-j4", "install-headers", f"install_root={out}", "cross-compiling=yes",
                "install-bootstrap-headers=yes"], b / "z4-install-headers.log", cwd=b):
        raise RuntimeError(f"install-headers {arch} failed, see {b}/z4-install-headers.log")
    abi = None
    for l in (b / "config.make").read_text().splitlines():
        if l.startswith("default-abi ="):
            abi = l.split("=", 1)[1].strip()
    if not abi:
        for d in gcr.make_eval(src, b, "config-sysdirs") or []:
            mk = src / d / "Makefile"
            if mk.is_file():
                m = re.search(r"^default-abi\s*:?=\s*(\S+)", mk.read_text(), re.M)
                if m:
                    abi = m.group(1)
                    break
    if not abi:
        for l in (b / "config.make").read_text().splitlines():
            if l.startswith("config-sysdirs ="):
                for d in l.split("=", 1)[1].split():
                    mk = src / d / "Makefile"
                    if mk.is_file():
                        m = re.search(r"^default-abi\s*:?=\s*(\S+)", mk.read_text(), re.M)
                        if m:
                            abi = m.group(1)
                            break
            if abi:
                break
    if gcr.run(["make", f"{b}/gnu/lib-names-{abi}.stmp", "cross-compiling=yes"], b / "z4-lib-names.log", cwd=b):
        raise RuntimeError(f"lib-names {arch} failed")
    gi = out / "usr/include/gnu"
    shutil.copyfile(b / f"gnu/lib-names-{abi}.h", gi / f"lib-names-{abi}.h")
    # gnu/stubs.h selects stubs-<abi>.h exactly as gnu/lib-names.h selects lib-names-<abi>.h
    # (glibc's Makefile writes both from the same abi-variants table).
    ln = (gi / "lib-names.h").read_text()
    st = ln.replace("lib-names", "stubs").replace("__GNU_LIB_NAMES_H", "__GNU_STUBS_H_KAIRO")
    st = re.sub(r"/\* This file is automatically generated\.\n.*?\*/",
                "/* This file is automatically generated.\n   This file selects the right generated file of "
                "`__stub_FUNCTION' macros\n   based on the architecture being compiled for.  */", st, flags=re.S)
    st = re.sub(r"\n#ifndef __GNU_STUBS_H_KAIRO\n#define __GNU_STUBS_H_KAIRO\t1\n", "\n", st)
    st = st.replace("\n#endif\t/* gnu/stubs.h */\n", "\n")
    (gi / "stubs.h").write_text(st)
    # the syscall numbers this ABI sees (asm/unistd.h selects unistd_64 / _32 / _x32 by the
    # compiler's own macros), so ask the compiler
    unistd = subprocess.run(["clang", f"--target={gcr.ARCHES[arch][1]}", "-dM", "-E", "-nostdinc",
                             "-isystem", str(inc), "-x", "c", "-"], input="#include <asm/unistd.h>\n",
                            capture_output=True, text=True, check=True).stdout
    names = list(STUBS)
    stubs = ["/* This file is automatically generated.", "   It defines a symbol `__stub_FUNCTION' for each function",
             "   in the C library which is a stub, meaning it will fail", "   every time called, usually setting errno to ENOSYS.  */",
             "", "#ifdef _LIBC", " #error Applications may not define the macro _LIBC", "#endif", ""]
    compat = [x for x, nr in COMPAT_SYSCALLS.items() if not re.search(rf"\b{nr}\b", unistd)]
    for n in sorted([f"__compat_{c}" for c in compat_have(arch, compat)] + names):
        stubs.append(f"#define __stub_{n}")
    (gi / f"stubs-{abi}.h").write_text("\n".join(stubs) + "\n")
    return out / "usr/include"


ABILISTS = None   # glibc/abilists (Scripts/glibc_abilists.py output), set by --abilists


def compat_have(arch, names):
    """The compat syscall wrappers this arch's newest libc.abilist lists."""
    import glibc_abilists as ga
    abi = ga.TARGETS[arch][0]
    data = (ABILISTS / abi / "libc.abilist").read_text()
    newest = ga.release_tags(ROOT / "build/sysgen/glibc")[-1]
    have = set()
    for line in data.splitlines():
        p = line.split()
        if p[1] in names and ga.in_ranges(p[-1], newest):
            have.add(p[1])
    return sorted(have)


def tree(inc: Path) -> dict:
    out = {}
    for d, _, fs in os.walk(inc):
        for f in fs:
            p = Path(d) / f
            out[p.relative_to(inc).as_posix()] = p.read_bytes()
    return out


def dedupe(per: dict, out: Path, tag: str) -> dict:
    shutil.rmtree(out, ignore_errors=True)
    paths = sorted(set().union(*per.values()))
    order = list(per)
    omit = {a: [] for a in order}
    stats = {"generic": 0, "arch": 0}
    for rel in paths:
        votes = {}
        for a in order:
            if rel in per[a]:
                votes.setdefault(hashlib.sha256(per[a][rel]).hexdigest(), []).append(a)
        best = max(votes.values(), key=lambda v: (len(v), -order.index(v[0])))
        generic = len(best) > 1
        if generic:
            (out / "generic" / rel).parent.mkdir(parents=True, exist_ok=True)
            (out / "generic" / rel).write_bytes(per[best[0]][rel])
            stats["generic"] += 1
        for a in order:
            if rel not in per[a]:
                if generic:
                    omit[a].append(rel)
                continue
            if generic and a in best:
                continue
            (out / a / rel).parent.mkdir(parents=True, exist_ok=True)
            (out / a / rel).write_bytes(per[a][rel])
            stats["arch"] += 1
    lines = ["# generated by Scripts/glibc_headers.py; do not edit. Format: FORMAT.md (glibc/headers).",
             "# install = generic/ + <arch>/ (an <arch>/ file replaces the generic one), minus [omit].",
             f'release = "{tag}"', "arches  = [" + ", ".join(f'"{a}"' for a in order) + "]", "", "[omit]"]
    for a in order:
        lines.append(f"{a} = [" + ", ".join(f'"{r}"' for r in omit[a]) + "]")
    (out / "index.toml").write_text("\n".join(lines) + "\n")
    return stats


def gate(per: dict, tag: str) -> list:
    minor = tag.split(".")[1]
    applied = []
    for f, old, new in GATES:
        old, new = old.replace("{minor}", minor), new.replace("{minor}", minor)
        n = 0
        for a, files in per.items():
            if f in files and old.encode() in files[f]:
                files[f] = files[f].replace(old.encode(), new.encode())
                n += 1
        applied.append(f"{f}: {n}/{len(per)} arches")
        if n == 0:
            raise SystemExit(f"gate for {f} matched nothing: the header changed, revisit GATES")
    return applied


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["build"])
    ap.add_argument("--git", type=Path, required=True)
    ap.add_argument("--linux", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--tag", default=None)
    ap.add_argument("--abilists", type=Path, required=True, help="glibc/abilists to read compat syscalls from")
    ap.add_argument("--arches", nargs="*", default=[a for a in gcr.ARCHES])
    ap.add_argument("-j", type=int, default=6)
    a = ap.parse_args()
    global ABILISTS
    ABILISTS = a.abilists.resolve()
    work = a.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    import glibc_abilists as ga
    tag = a.tag or ga.release_tags(a.git)[-1]
    cc = gcr.clang_wrapper(work)
    gcr.source(a.git, tag, work)
    incs = {}
    with ThreadPoolExecutor(a.j) as ex:
        futs = {x: ex.submit(install, a.git, a.linux, work, tag, x, cc) for x in a.arches}
        for x, f in futs.items():
            incs[x] = f.result()
            log(f"{x}: installed")
    per = {x: tree(incs[x]) for x in a.arches}
    for line in gate(per, tag):
        log(f"gate {line}")
    st = dedupe(per, a.out.resolve(), tag)
    log(f"{st['generic']} generic files, {st['arch']} per-arch files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
