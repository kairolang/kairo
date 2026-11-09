#!/usr/bin/env python3
"""Which glibc symbols are compat-only, per release (the `.compat` half of glibc/abilists/).

glibc's .abilist files do not say whether a binding is the default (`sym@@VER`) or a compat
one (`sym@VER`, linkable only by old binaries). The stub rule is "a symbol's newest node is its
default" (Scripts/glibc_stubs.py); this module finds the exceptions, where the newest node is
compat-only, from glibc's own source at each release tag:

  - `compat_symbol (lib, local, NAME, VERSION)` and `libc_sunrpc_symbol (local, NAME, VERSION)`
    (multi-line calls included);
  - `libm_alias_finite (from, __NAME)` -> `__NAME_finite`, and the type-generic
    `declare_mgen_finite_alias (from, __NAME)` -> `__NAME{,f,l,f128}_finite` (compat since 2.31);
  - syscalls.list rows whose names column has `NAME@VERSION` (one `@`: compat).

A hit in sysdeps/<arch dir>/ (or sysdeps/unix/sysv/linux/<arch dir>/) counts only for ABIs of
that arch family; anything else is generic. A symbol of library L is compat at release R when
its newest node N on that ABI at R is the node the call names: the call's VERSION <= N and no
other node of the symbol lies in [VERSION, N). The verdict is checked against the DSOs that
exist (Ubuntu focal 2.31 on five arches, Scripts/ship_sysroot_inputs.py --report glibc-z4).
"""
import io
import json
import re
import subprocess
import tarfile
from pathlib import Path

import glibc_stubs

ARCH_DIRS = {"aarch64", "alpha", "arc", "arm", "csky", "hppa", "i386", "ia64", "loongarch", "m68k",
             "microblaze", "mips", "nios2", "or1k", "powerpc", "riscv", "s390", "sh", "sparc", "x86",
             "x86_64", "mach", "hurd", "htl", "tile"}
FAMILY = {"x86_64": {"x86_64", "x86"}, "x32": {"x86_64", "x86"}, "i386": {"i386", "x86"},
          "aarch64": {"aarch64"}, "arm": {"arm"}, "riscv32": {"riscv"}, "riscv64": {"riscv"},
          "powerpc": {"powerpc"}, "powerpc64": {"powerpc"}, "powerpc64le": {"powerpc"},
          "s390x": {"s390"}, "mips": {"mips"}, "mips64": {"mips"}, "mipsn32": {"mips"},
          "loongarch64": {"loongarch"}, "sparc64": {"sparc"}}
# sysdeps/ieee754/ldbl-opt: the long double = double compat layer, Implied only where long
# double changed size (powerpc, s390, sparc32 and alpha; not sparc64).
for _a in ("powerpc", "powerpc64", "powerpc64le", "s390x"):
    FAMILY[_a] = FAMILY[_a] | {"ldbl-opt"}

ID = r"[A-Za-z_][A-Za-z0-9_]*"
RE_COMPAT = re.compile(rf"\bcompat_symbol\s*\(\s*({ID})\s*,\s*{ID}\s*,\s*({ID})\s*,\s*({ID})\s*\)")
RE_LDBL = re.compile(rf"\bldbl_compat_symbol\s*\(\s*({ID})\s*,\s*{ID}\s*,\s*({ID})\s*,\s*(GLIBC_\w+)\s*\)")
RE_UNIQUE = re.compile(rf"\bcompat_symbol_unique\s*\(\s*({ID})\s*,\s*({ID})\s*,\s*(GLIBC_\w+)\s*\)")
RE_NOLINK = re.compile(rf"\bhidden_nolink\s*\(\s*({ID})\s*,\s*({ID})\s*,\s*(GLIBC_\w+)\s*\)")
# #if tests whose truth depends on the arch's long double: not decidable from the path, so a
# compat call under one is left to the newest-is-default rule (the safe side: still linkable).
ARCH_CONDS = ("NO_LONG_DOUBLE", "LDBL_CLASSIFY_COMPAT", "LONG_DOUBLE_COMPAT", "__LONG_DOUBLE_MATH_OPTIONAL",
              "PTHREAD_STACK_MIN", "__WORDSIZE", "__OFF_T_MATCHES_OFF64_T", "__ASSUME_", "__IPC_64",
              "XSTAT_IS_XSTAT64", "STAT_IS_KERNEL_STAT", "__TIMESIZE")
RE_NOLINK_RPC = re.compile(rf"\blibc_hidden_nolink_sunrpc\s*\(\s*({ID})\s*,\s*(GLIBC_\w+)\s*\)")
RE_SIGLIST = re.compile(r"^\s*DEFINE_COMPAT_SIGLIST\s*\(\s*\w+\s*,\s*(GLIBC_\w+)\s*\)", re.M)
RE_VERSIONED = re.compile(rf"\bversioned_symbol\s*\(\s*({ID})\s*,\s*{ID}\s*,\s*({ID})\s*,\s*(GLIBC_\w+)\s*\)")
RE_ERRLIST = re.compile(r"^\s*DEFINE_COMPAT_ERRLIST\s*\(\s*\w+\s*,\s*(GLIBC_\w+)\s*\)", re.M)
BENIGN = {"SHLIB_COMPAT", "OTHER_SHLIB_COMPAT", "IS_IN", "defined", "SHARED", "PIC", "libc", "libm",
          "libpthread", "ld", "rtld", "libdl", "librt", "libutil", "libanl", "libresolv", "libnsl",
          "libcrypt", "libmvec", "nonlib", "libc_malloc_debug",
          # true on every Linux port (0 only on Hurd)
          "PTHREAD_MUTEX_VERSIONS", "PTHREAD_IN_LIBC"}
# Configure options that are off in an upstream default build: their #ifdef branch is never
# built, and their #else branch always is (EXPORT_RPC_SYMBOLS: --enable-obsolete-rpc, <= 2.31).
CONFIG_OFF = ("EXPORT_RPC_SYMBOLS",)
DEAD = "dead"
RE_SUNRPC = re.compile(rf"\blibc_sunrpc_symbol\s*\(\s*{ID}\s*,\s*({ID})\s*,\s*(GLIBC_\w+)\s*\)")
RE_FINITE = re.compile(rf"\blibm_alias_finite\s*\(\s*{ID}\s*,\s*({ID})\s*\)")
RE_MGEN = re.compile(rf"\bdeclare_mgen_finite_alias\s*\(\s*{ID}\s*,\s*({ID})\s*\)")


def macro_version(m: str) -> str:
    """GLIBC_2_2_5 -> GLIBC_2.2.5"""
    head, _, nums = m.partition("_")
    return head + "_" + nums.replace("_", ".")


def arch_of(path: str):
    """The arch dir a sysdeps path belongs to, or None (generic)."""
    p = path.split("/")
    # Hurd's own trees (htl/ is its pthread, mach/ and hurd/ its kernel glue) never build on
    # Linux: their pthread_self compat_symbol is not Linux's
    top = p[1] if p[0].startswith("glibc-") and len(p) > 1 else p[0]
    if top in ("htl", "hurd", "mach"):
        return "hurd"
    if "ldbl-opt" in p:
        return "ldbl-opt"
    if "sysdeps" not in p:
        return None
    rest = p[p.index("sysdeps") + 1:]
    if rest[:3] == ["unix", "sysv", "linux"]:
        rest = rest[3:]
    elif rest[:1] == ["unix"]:
        rest = rest[1:]
    if rest and rest[0] in ARCH_DIRS:
        return rest[0]
    return None


RE_SHLIB = re.compile(rf"(!?)\s*\(?\s*SHLIB_COMPAT\s*\(\s*{ID}\s*,\s*\w+\s*,\s*({ID})\s*\)")
RE_LOCAL_DEF = re.compile(rf"^\s*#\s*define\s+({ID})\s+(GLIBC_\w+)\s*$", re.M)
UNKNOWN = "?"
RE_SHLIB_DEF = re.compile(rf"^\s*#\s*define\s+({ID})\s+SHLIB_COMPAT\s*\(\s*{ID}\s*,\s*GLIBC_\w+\s*,\s*(GLIBC_\w+)\s*\)", re.M)


def _bounds(cond: str, macros: dict, local: dict) -> list:
    """The `obsoleted` versions of the SHLIB_COMPAT tests a #if condition requires to hold
    (UNKNOWN when one is a macro this file does not define)."""
    out = []
    if "||" in cond:
        # `A && (SHLIB_COMPAT (...) || defined NO_LONG_DOUBLE ...)`: a disjunction only widens
        # where the code is built; keep the conjuncts' named bounds, drop the rest
        return [b for name, b in macros.items() if re.search(rf"(?<![!\w]){name}\b", cond)]
    if any(c in cond for c in ARCH_CONDS):
        return [UNKNOWN]
    # Any other macro the test reads may vary per arch (_HAVE_STRUCT_OLD_TERMIOS, ...): only a
    # test built from these is decided here.
    for tok in re.findall(ID, re.sub(r"/\*.*?\*/", " ", cond)):
        if tok not in BENIGN and tok not in macros and tok not in local and not tok.startswith("GLIBC_"):
            return [UNKNOWN]
    for m in RE_SHLIB.finditer(cond):
        if not m.group(1):
            b = m.group(2)
            b = local.get(b, b)
            out.append(macro_version(b) if b.startswith("GLIBC_") else UNKNOWN)
    for name, b in macros.items():
        if re.search(rf"(?<![!\w]){name}\b", cond):
            out.append(b)
    return out


def _cond_lines(text: str, macros: dict) -> list:
    """Per line: the obsoleted bounds of the SHLIB_COMPAT conditions enclosing it (an #else or
    #elif branch drops its #if's bound)."""
    local = {m.group(1): m.group(2) for m in RE_LOCAL_DEF.finditer(text)}
    stack, per, lines = [], [], text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        full = line
        while full.endswith("\\") and i + 1 < len(lines):
            i += 1
            full = full[:-1] + " " + lines[i]
            per.append([b for fr in stack for b in fr])
        s = full.lstrip()
        if s.startswith("#"):
            d = s[1:].lstrip()
            if d.startswith("if"):
                if d.startswith("ifdef") and any(c in d for c in CONFIG_OFF):
                    stack.append([DEAD])
                elif d.startswith(("ifdef", "ifndef")):
                    stack.append([UNKNOWN] if any(c in d for c in ARCH_CONDS) else [])
                else:
                    stack.append(_bounds(d[2:], macros, local))
            elif d.startswith("elif") and stack:
                stack[-1] = _bounds(d[4:], macros, local)
            elif d.startswith("else") and stack and stack[-1] == [DEAD]:
                stack[-1] = []
            elif d.startswith("else") and stack:
                # the other branch of an arch-dependent test (PTHREAD_STACK_MIN == 16384 ...):
                # not decidable here, so nothing in it counts as compat
                stack[-1] = [UNKNOWN]
            elif d.startswith("endif") and stack:
                stack.pop()
        per.append([b for fr in stack for b in fr])
        i += 1
    return per


def scan_tree(files) -> list:
    """files: list of (path, text). -> [(lib, name, version, arch_or_None, obsoleted_or_"")]"""
    files = list(files)
    macros = {}
    for _, text in files:
        if "SHLIB_COMPAT" in text:
            for m in RE_SHLIB_DEF.finditer(text):
                macros[m.group(1)] = macro_version(m.group(2))
    # `#if SHLIB_COMPAT (libc, GLIBC_2_0, GLIBC_2_24)` / `# define HAVE_MALLOC_INIT_HOOK 1`: the
    # macro carries the test's bound wherever it is used.
    for _, text in files:
        if "SHLIB_COMPAT" not in text or "define" not in text:
            continue
        per = _cond_lines(text, macros)
        for m in re.finditer(rf"^\s*#\s*define\s+({ID})\s+1\s*$", text, re.M):
            bs = per[text.count("\n", 0, m.start())]
            if bs and UNKNOWN not in bs:
                macros.setdefault(m.group(1), min(bs, key=glibc_stubs._ver_key))
    # `#define PTHREAD_ATFORK_COMPAT_INTRODUCED GLIBC_2_0`: a version spelled as a macro, as its
    # generic (non-arch) header defines it
    vmacros = {}
    for path, text in files:
        if arch_of(path) is None and "GLIBC_" in text:
            for m in RE_LOCAL_DEF.finditer(text):
                vmacros.setdefault(m.group(1), m.group(2))
    out = set()

    def bound(per, text, pos):
        bs = per[text.count("\n", 0, pos)] if per else []
        if UNKNOWN in bs or DEAD in bs:
            return UNKNOWN
        return min(bs, key=glibc_stubs._ver_key) if bs else ""

    for path, text in files:
        arch = arch_of(path)
        if path.endswith("syscalls.list"):
            for line in text.splitlines():
                if line.lstrip().startswith("#"):
                    continue
                cols = line.split()
                if len(cols) < 5:
                    continue
                for tok in cols[-1].split(","):
                    if "@" in tok and "@@" not in tok:
                        name, _, ver = tok.partition("@")
                        v, _, obs = ver.partition(":")
                        out.add(("libc", name, v, arch, obs))
            continue
        hits = []
        if "compat_symbol" in text:
            local = {m.group(1): m.group(2) for m in RE_LOCAL_DEF.finditer(text)}
            for m in RE_COMPAT.finditer(text):
                v = m.group(3)
                v = local.get(v) or vmacros.get(v) or v
                if v.startswith("GLIBC_"):
                    hits.append((m.start(), m.group(1), m.group(2), macro_version(v)))
        if "ldbl_compat_symbol" in text:
            hits += [(m.start(), m.group(1), m.group(2), macro_version(m.group(3)))
                     for m in RE_LDBL.finditer(text)]
        if "compat_symbol_unique" in text:
            hits += [(m.start(), m.group(1), m.group(2), macro_version(m.group(3)))
                     for m in RE_UNIQUE.finditer(text)]
        if "hidden_nolink" in text:
            hits += [(m.start(), m.group(2), m.group(1), macro_version(m.group(3)))
                     for m in RE_NOLINK.finditer(text)]
        if "libc_hidden_nolink_sunrpc" in text:
            hits += [(m.start(), "libc", m.group(1), macro_version(m.group(2)))
                     for m in RE_NOLINK_RPC.finditer(text)]
        if "DEFINE_COMPAT_ERRLIST" in text:
            for m in RE_ERRLIST.finditer(text):
                hits += [(m.start(), "libc", n, macro_version(m.group(1)))
                         for n in ("sys_errlist", "_sys_errlist", "sys_nerr", "_sys_nerr")]
        if "DEFINE_COMPAT_SIGLIST" in text:
            for m in RE_SIGLIST.finditer(text):
                hits += [(m.start(), "libc", n, macro_version(m.group(1)))
                         for n in ("sys_siglist", "_sys_siglist", "sys_sigabbrev")]
        if "versioned_symbol" in text:
            # a default binding (@@): recorded with obsoleted "@@" so compat_at lets it win
            for m in RE_VERSIONED.finditer(text):
                out.add((m.group(1), m.group(2), macro_version(m.group(3)), arch, "@@"))
        if "libc_sunrpc_symbol" in text:
            hits += [(m.start(), "libc", m.group(1), macro_version(m.group(2)))
                     for m in RE_SUNRPC.finditer(text)]
        if "finite_alias" in text or "libm_alias_finite" in text:
            for m in RE_FINITE.finditer(text):
                hits.append((m.start(), "libm", m.group(1) + "_finite", "GLIBC_2.15"))
                # ldbl-128 sources are also compiled as the _Float128 ones (float128/, names
                # renamed l -> f128), whose _finite aliases date from 2.26
                f128 = re.sub(r"l(_r)?$", r"f128\1", m.group(1))
                if f128 != m.group(1):
                    hits.append((m.start(), "libm", f128 + "_finite", "GLIBC_2.26"))
            for m in RE_MGEN.finditer(text):
                hits += [(m.start(), "libm", m.group(1) + suf + "_finite", "GLIBC_2.15")
                         for suf in ("", "f", "l", "f128")]
        if not hits:
            continue
        per = _cond_lines(text, macros) if ("SHLIB_COMPAT" in text or macros) else []
        for pos, lib, name, ver in hits:
            out.add((lib, name, ver, arch, bound(per, text, pos)))
    return sorted(out, key=lambda x: (x[0], x[1], x[2], x[3] or "", x[4] or ""))


def scan_tag(gitdir: Path, tag: str) -> list:
    data = subprocess.run(["git", "-C", str(gitdir), "archive", f"glibc-{tag}", "--",
                           ":(glob)**/*.c", ":(glob)**/*.h", ":(glob)**/*.S", ":(glob)**/syscalls.list"],
                          capture_output=True, check=True).stdout

    def files():
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            for m in tf.getmembers():
                if m.isfile() and "/tests" not in m.name and not m.name.split("/")[-1].startswith("tst-"):
                    yield m.name, tf.extractfile(m).read().decode("utf-8", "replace")
    return scan_tree(files())


# From 2.34 these libraries' code lives in libc, and their old bindings are made there with
# `compat_symbol (libpthread, ...)` under OTHER_SHLIB_COMPAT: the symbol is libc's.
FOLDED = ("libpthread", "libdl", "librt", "libutil", "libanl", "libresolv")


def lib_matches(lib: str, stem: str, tag: str = "") -> bool:
    if lib == stem or (stem == "ld" and lib in ("ld", "rtld")):
        return True
    return bool(tag) and stem == "libc" and lib in FOLDED and \
        glibc_stubs._ver_key("V_" + tag) >= glibc_stubs._ver_key("V_2.34")


def compat_at(entries, calls, abi: str, stem: str, tag: str = "") -> set:
    """{(version, name, "@" | "@@")} for `entries` (active at one release): "@" where a
    symbol's newest node is compat-only, and then "@@" on its newest node that is not (the
    default the newest-is-default rule would miss: i386 open64@@GLIBC_2.1 beside the
    compat open64@GLIBC_2.2 since 2.34)."""
    vk = glibc_stubs._ver_key
    fam = FAMILY[abi]
    by_name = {}
    for v, n, k, s in entries:
        by_name.setdefault(n, set()).add(v)
    if not by_name:
        return set()
    # SHLIB_COMPAT (lib, introduced, obsoleted) holds where the ABI's baseline (its oldest
    # node: GLIBC_2.2.5 on x86_64, GLIBC_2.0 on i386) is below obsoleted: on x86_64 a
    # GLIBC_2_0 .. GLIBC_2_1 compat symbol is not built at all.
    base = min((v for vs in by_name.values() for v in vs), key=vk)

    def node(name, ver):
        """The node a binding at `ver` lands on: the symbol's oldest node >= ver."""
        up = [x for x in by_name[name] if vk(x) >= vk(ver)]
        return min(up, key=vk) if up else None

    defaults = set()
    for lib, name, ver, arch, obs in calls:
        if obs == "@@" and lib_matches(lib, stem, tag) and name in by_name and not (arch and arch not in fam):
            nd = node(name, ver)
            if nd:
                defaults.add((name, nd))
    compat = {}
    for lib, name, ver, arch, obs in calls:
        if obs in (UNKNOWN, "@@"):
            continue
        if not lib_matches(lib, stem, tag) or name not in by_name or (arch and arch not in fam):
            continue
        if obs and vk(base) >= vk(obs):
            continue
        nd = node(name, ver)
        if nd and (name, nd) not in defaults:
            compat.setdefault(name, set()).add(nd)
    # glibc defines its version placeholders only by compat_symbol, at every node they keep
    # alive (nptl/libpthread-compat.c and friends): never a default.
    for name in by_name:
        if re.fullmatch(r"__lib\w+_version_placeholder", name):
            compat[name] = set(by_name[name])
    out = set()
    for name, cn in compat.items():
        nodes = sorted(by_name[name], key=vk)
        if nodes[-1] not in cn:
            continue
        out.add((nodes[-1], name, "@"))
        rest = [x for x in nodes if x not in cn]
        if rest:
            out.add((rest[-1], name, "@@"))
    return out


def compat_rows(gitdir: Path, cache: Path, tags: list, merged: dict) -> dict:
    """{abi: {stem: ["VERSION NAME @ <releases>"]}} over every release."""
    import glibc_abilists as ga
    calls = {}
    for t in tags:
        cf = cache / f"compat-{t}.json"
        if cf.is_file():
            calls[t] = [tuple(x) for x in json.loads(cf.read_text())]
        else:
            calls[t] = scan_tag(gitdir, t)
            cf.write_text(json.dumps(calls[t]))
    out = {}
    for abi, a in merged.items():
        for stem, lib in a["libs"].items():
            hits = {}
            for t in tags:
                active = [e for e, ts in lib["entries"].items() if t in ts]
                for key in compat_at(active, calls[t], abi, stem, t):
                    hits.setdefault(key, []).append(t)
            out.setdefault(abi, {})[stem] = [f"{v} {n} {f} {ga.ranges(ts, tags)}" for (v, n, f), ts in hits.items()]
    return out
