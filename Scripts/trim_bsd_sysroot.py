#!/usr/bin/env python3
"""Trim a curated FreeBSD / NetBSD sysroot down to what a cross-compiler needs.

Reads a curated root (SYSROOT.toml + usr/ lib/ libcxx/ compiler-rt/) and writes
a trimmed COPY; the source is never modified. Pure stdlib.

    trim_bsd_sysroot.py                       # all three default roots
    trim_bsd_sysroot.py --src ROOT [--name N] # one root
    trim_bsd_sysroot.py --analyze ...         # category table only, no copy

Policy (see RULES below; every drop has a category and a reason):

  profiled    lib*_p.a                       -pg builds; nobody cross-links these
  lib32       usr/lib/i386, usr/lib32        32-bit compat; no 32-bit target ships
  debug       *.debug, *.dbg, *.symcheck     separate debug info
  junk        share/ man/ doc/ locale/ ...   never link- or compile-relevant
  duplicate   base libc++ (.a + headers),    shadowed by libcxx/ (SYSROOT.toml lists
              GNU libstdc++ + g++ headers    libcxx/ first; wrong ABI/version anyway)
  private     libprivate* (FreeBSD)          base-system internals, not linkable API
  toolchain   base clang/lldb resource dir,  Kairo supplies its own resource dir; GCC
              GNU sanitizers/gcov, bfd,      only runtimes cannot be used with clang
              opcodes, gcc intrinsic headers
  internal    BIND, ZFS userland test lib,   daemon/test internals no port links
              hwpmc, dtrace, rump kernels
  plugin      pam_*, snmp_*, ossl modules,   dlopen()ed at run time, never linked
              i18n, lua modules, ...

Everything else is kept. Two closure passes then make the result self-consistent
(a rule can never produce a dangling link or a missing DT_NEEDED):

  * a kept symlink / linker script (GROUP/INPUT) pulls in its target;
  * a kept ELF shared object pulls in every DT_NEEDED library present in the
    original root.

Anything restored that way is recorded in the manifest as `restored`.
"""
import argparse
import os
import re
import shutil
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC_BASE = os.path.join(REPO, "build/x86_64-linux-gnu/release/sysroot")
DEFAULT_OUT_BASE = os.path.join(REPO, "build/sysgen/bsd-trim")
DEFAULT_ROOTS = ["x86_64-unknown-freebsd", "aarch64-unknown-freebsd",
                 "x86_64-unknown-netbsd"]

# --- rules ------------------------------------------------------------------

LIBDIRS = ("usr/lib", "lib")

# directory prefixes (relative to root) dropped wholesale: (category, reason)
COMMON_DIRS = {
    "usr/lib/i386": ("lib32", "32-bit compat libraries"),
    "usr/lib32": ("lib32", "32-bit compat libraries"),
    "lib32": ("lib32", "32-bit compat libraries"),
    "usr/share": ("junk", "docs/locale/man data"),
    "usr/man": ("junk", "man pages"),
    "usr/doc": ("junk", "docs"),
    "usr/local": ("junk", "not part of the base sysroot"),
    "share": ("junk", "docs/locale/man data"),
    "usr/lib/dtrace": ("internal", "DTrace scripts"),
    "usr/lib/i18n": ("plugin", "iconv/locale data loaded at run time"),
}
FAMILY_DIRS = {
    "freebsd": {
        "usr/lib/clang": ("toolchain", "base clang 19 resource dir (sanitizer runtimes, "
                          "headers); Kairo ships its own and uses compiler-rt/"),
        "usr/lib/flua": ("plugin", "flua modules"),
        "usr/lib/engines-3": ("plugin", "OpenSSL engines, dlopen()ed"),
        "usr/lib/ossl-modules": ("plugin", "OpenSSL providers, dlopen()ed"),
        "usr/lib/libxo": ("plugin", "libxo encoder plugins, dlopen()ed"),
        "lib/nvmecontrol": ("plugin", "nvmecontrol plugins"),
        "usr/include/c++": ("duplicate", "base libc++ 19 headers, shadowed by "
                            "libcxx/include (listed first in include_dirs)"),
    },
    "netbsd": {
        "usr/lib/clang": ("toolchain", "base clang resource dir"),
        "usr/lib/lua": ("plugin", "lua modules, dlopen()ed"),
        "usr/lib/named": ("plugin", "BIND plugins"),
        "usr/lib/postfix": ("plugin", "postfix private libs"),
        "usr/lib/security": ("plugin", "PAM modules, dlopen()ed"),
        "usr/lib/openssl": ("plugin", "OpenSSL engines/providers, dlopen()ed"),
        "lib/npf": ("plugin", "npfctl extensions"),
        "usr/include/g++": ("duplicate", "GNU libstdc++ headers; libc++ is used"),
        "usr/include/gcc-10": ("toolchain", "GCC intrinsic headers, unusable by "
                               "clang and not on any default include path"),
    },
}

# library "stems" (name minus .a/.so.N and a trailing _p) dropped wholesale
# across usr/lib and lib, with all their symlinks. (regex, category, reason)
FAMILY_STEMS = {
    "freebsd": [
        (r"libprivate.*", "private", "FreeBSD base-private libraries"),
        (r"libzpool|libicp|libicp_rescue", "internal", "ZFS userland test/ICP code"),
        (r"libpmc", "internal", "hwpmc profiling"),
        (r"libdtrace", "internal", "DTrace consumer"),
        (r"libc_pic", "internal", "PIC libc archive used to build libc itself"),
        (r"pam_.*", "plugin", "PAM modules, dlopen()ed"),
        (r"snmp_.*", "plugin", "bsnmpd modules, dlopen()ed"),
        (r"libalias_.*", "plugin", "libalias modules, dlopen()ed"),
        (r"nss_tacplus", "plugin", "NSS module, dlopen()ed"),
    ],
    "netbsd": [
        (r"libasan|libtsan|liblsan|libubsan|libgcov", "toolchain",
         "GCC sanitizer/gcov runtimes, unusable with clang"),
        (r"libstdc\+\+|libsupc\+\+", "duplicate", "GNU C++ runtime; libc++ is used"),
        (r"libbfd|libopcodes|libgnuctf", "toolchain", "binutils internals"),
        (r"libdtrace", "internal", "DTrace consumer"),
        (r"libzpool", "internal", "ZFS userland test code"),
        (r"libdns|libisc|libisccc|libisccfg|libns|libbind9|libirs", "internal",
         "BIND daemon libraries"),
        (r"librump(?!client$|res$).*", "internal", "rump kernel components"),
    ],
}
# single files dropped (relative path regex)
FAMILY_FILES = {
    "freebsd": [
        (r"usr/lib/libc\+\+\.a", "duplicate",
         "base libc++ 19 archive, shadowed by libcxx/lib/libc++.a"),
    ],
    "netbsd": [],
}

SO_RE = re.compile(r"\.so(\.[0-9.]+)?$")


def stem_of(name):
    s = re.sub(r"(\.a|\.so(\.[0-9]+)*)$", "", name)
    return re.sub(r"_p$", "", s) if name.endswith("_p.a") else s


def read_family(root):
    with open(os.path.join(root, "SYSROOT.toml")) as f:
        for line in f:
            m = re.match(r'\s*family\s*=\s*"([^"]+)"', line)
            if m:
                return m.group(1)
    raise SystemExit(f"{root}: no family in SYSROOT.toml")


class Rules:
    def __init__(self, family):
        self.dirs = dict(COMMON_DIRS)
        self.dirs.update(FAMILY_DIRS[family])
        self.stems = [(re.compile("(?:" + p + ")$"), c, r) for p, c, r in FAMILY_STEMS[family]]
        self.files = [(re.compile("(?:" + p + ")$"), c, r) for p, c, r in FAMILY_FILES[family]]

    def classify(self, rel):
        """-> (category, reason) if the path is dropped, else None."""
        for d, cr in self.dirs.items():
            if rel == d or rel.startswith(d + "/"):
                return cr
        base = os.path.basename(rel)
        if re.search(r"\.(debug|dbg|symcheck)$", base):
            return ("debug", "separate debug info")
        parent = os.path.dirname(rel)
        if parent in LIBDIRS:
            if re.search(r"_p\.a$", base):
                return ("profiled", "gprof-instrumented archive")
            for rx, c, r in self.files:
                if rx.match(rel):
                    return (c, r)
            st = stem_of(base)
            for rx, c, r in self.stems:
                if rx.match(st):
                    return (c, r)
        return None


# --- ELF / linker-script helpers (closure passes) ----------------------------

def elf_needed(path):
    """DT_NEEDED sonames of an ELF file, [] for anything else. Handles 32/64-bit,
    either endianness; walks section headers (SHT_DYNAMIC + linked strtab)."""
    try:
        with open(path, "rb") as f:
            hdr = f.read(64)
            if hdr[:4] != b"\x7fELF":
                return []
            is64 = hdr[4] == 2
            e = "<" if hdr[5] == 1 else ">"
            if is64:
                shoff, = struct.unpack(e + "Q", hdr[0x28:0x30])
                shentsize, shnum = struct.unpack(e + "HH", hdr[0x3A:0x3E])
            else:
                shoff, = struct.unpack(e + "I", hdr[0x20:0x24])
                shentsize, shnum = struct.unpack(e + "HH", hdr[0x2E:0x32])
            if not shoff:
                return []
            f.seek(shoff)
            raw = f.read(shentsize * shnum)
            secs = []
            for i in range(shnum):
                b = raw[i * shentsize:(i + 1) * shentsize]
                if is64:
                    t, = struct.unpack(e + "I", b[4:8])
                    off, size = struct.unpack(e + "QQ", b[0x18:0x28])
                    link, = struct.unpack(e + "I", b[0x28:0x2C])
                else:
                    t, = struct.unpack(e + "I", b[4:8])
                    off, size = struct.unpack(e + "II", b[0x10:0x18])
                    link, = struct.unpack(e + "I", b[0x18:0x1C])
                secs.append((t, off, size, link))
            out = []
            for t, off, size, link in secs:
                if t != 6:  # SHT_DYNAMIC
                    continue
                _, soff, ssize, _ = secs[link]
                f.seek(soff)
                strtab = f.read(ssize)
                f.seek(off)
                dyn = f.read(size)
                step = 16 if is64 else 8
                fmt = e + ("qQ" if is64 else "iI")
                for j in range(0, len(dyn) - step + 1, step):
                    tag, val = struct.unpack(fmt, dyn[j:j + step])
                    if tag == 0:
                        break
                    if tag == 1:  # DT_NEEDED
                        end = strtab.index(b"\0", val)
                        out.append(strtab[val:end].decode())
            return out
    except (OSError, ValueError, struct.error):
        return []


def script_refs(path):
    """Paths named by a GROUP/INPUT/AS_NEEDED linker script (text, small)."""
    try:
        if os.path.getsize(path) > 4096:
            return []
        with open(path, "rb") as f:
            data = f.read()
        if b"\0" in data or b"GROUP" not in data and b"INPUT" not in data:
            return []
        text = data.decode("ascii", "ignore")
    except OSError:
        return []
    return [t for t in re.findall(r"[^\s()]+", text)
            if t.startswith("/") or re.match(r"lib[^/]*\.(a|so[0-9.]*)$", t)]


# --- core ------------------------------------------------------------------

def walk(root):
    """All non-directory entries (files and symlinks) as relative paths."""
    out = []
    for dp, dns, fns in os.walk(root):
        for n in fns + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
            out.append(os.path.relpath(os.path.join(dp, n), root))
    return sorted(out)


def size_of(root, rel):
    p = os.path.join(root, rel)
    return 0 if os.path.islink(p) else os.path.getsize(p)


def resolve_link(root, rel):
    """Relative path (inside root) a symlink points at, or None if outside."""
    p = os.path.join(root, rel)
    t = os.readlink(p)
    full = os.path.normpath(os.path.join(root, t.lstrip("/")) if t.startswith("/")
                            else os.path.join(os.path.dirname(p), t))
    r = os.path.relpath(full, root)
    return None if r.startswith("..") else r


def plan(root):
    family = read_family(root)
    rules = Rules(family)
    files = walk(root)
    fileset = set(files)
    drop = {}  # rel -> (category, reason)
    for rel in files:
        c = rules.classify(rel)
        if c:
            drop[rel] = c

    by_name = {}
    for rel in files:
        if os.path.dirname(rel) in LIBDIRS:
            by_name.setdefault(os.path.basename(rel), []).append(rel)

    restored = {}
    changed = True
    while changed:
        changed = False
        for rel in files:
            if rel in drop:
                continue
            targets = []
            p = os.path.join(root, rel)
            if os.path.islink(p):
                t = resolve_link(root, rel)
                if t:
                    targets.append((t, "symlink target"))
            else:
                for t in script_refs(p):
                    t = t.lstrip("/") if t.startswith("/") else None
                    if t and t in fileset:
                        targets.append((t, "linker-script member"))
                    elif t is None:
                        pass
                if SO_RE.search(rel) or rel.endswith(".so"):
                    for n in elf_needed(p):
                        for cand in by_name.get(n, []):
                            targets.append((cand, "DT_NEEDED of " + os.path.basename(rel)))
            for t, why in targets:
                if t in drop:
                    restored[t] = (drop[t][0], f"{why} of kept {rel}")
                    del drop[t]
                    changed = True
    return family, files, drop, restored


def human(n):
    return f"{n / (1 << 20):.1f} MiB"


def copy_tree(src, dst, drop):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    for dp, dns, fns in os.walk(src):
        rd = os.path.relpath(dp, src)
        os.makedirs(os.path.join(dst, rd), exist_ok=True)
        for n in fns + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
            rel = os.path.normpath(os.path.join(rd, n))
            if rel in drop:
                continue
            s, d = os.path.join(dp, n), os.path.join(dst, rel)
            if os.path.islink(s):
                os.symlink(os.readlink(s), d)
            else:
                shutil.copy2(s, d)
                os.chmod(d, os.stat(d).st_mode | 0o200)
    # prune directories that ended up empty because of drops
    for dp, dns, fns in os.walk(dst, topdown=False):
        if dp != dst and not os.listdir(dp):
            os.rmdir(dp)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", help="curated root (default: the three BSD roots)")
    ap.add_argument("--src-base", default=DEFAULT_SRC_BASE)
    ap.add_argument("--out-base", default=DEFAULT_OUT_BASE)
    ap.add_argument("--name", help="output name (default: basename of --src)")
    ap.add_argument("--analyze", action="store_true", help="report only; no copy")
    a = ap.parse_args()

    roots = [(a.name or os.path.basename(a.src.rstrip("/")), a.src)] if a.src else \
        [(n, os.path.join(a.src_base, n)) for n in DEFAULT_ROOTS]
    for name, root in roots:
        family, files, drop, restored = plan(root)
        total = sum(size_of(root, r) for r in files)
        cats = {}
        for rel, (c, _) in drop.items():
            n, s = cats.get(c, (0, 0))
            cats[c] = (n + 1, s + size_of(root, rel))
        dropped = sum(s for _, s in cats.values())
        print(f"== {name} ({family}): {human(total)} -> {human(total - dropped)}")
        for c, (n, s) in sorted(cats.items(), key=lambda kv: -kv[1][1]):
            print(f"   {c:<10} {n:>6} files {human(s):>11}")
        for t, (c, why) in sorted(restored.items()):
            print(f"   restored {t}  ({why})")
        if a.analyze:
            continue
        out = os.path.join(a.out_base, name)
        copy_tree(root, out, drop)
        man = os.path.join(a.out_base, name + ".manifest.tsv")
        with open(man, "w") as f:
            f.write("# category\tbytes\tpath\treason   (category `restored` = kept, NOT removed: a rule hit it but a closure pass put it back)\n")
            for rel in sorted(drop):
                c, r = drop[rel]
                f.write(f"{c}\t{size_of(root, rel)}\t{rel}\t{r}\n")
            for rel in sorted(restored):
                f.write(f"restored\t{size_of(root, rel)}\t{rel}\t{restored[rel][1]}\n")
        print(f"   wrote {out}\n   manifest {man}")


if __name__ == "__main__":
    sys.exit(main())
