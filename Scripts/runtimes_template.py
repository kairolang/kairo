#!/usr/bin/env python3
"""Write runtimes-template/ (build/sysroot-share/FORMAT.md, "runtimes-template/") from one
or more runtimes-recipe/ table sets.

The tables (Scripts/runtimes_recipe.py) hold, per target, what CMake decided: every
compile's flags and every archive's members in order. The template holds the same
information as ordered, CONDITIONAL fragments: each fragment is a run of flags (or of
archive members) together with a predicate over target properties (libc, os, objfmt,
bits, int128, float, cpu, crt_arch, rt_arch, endian, arch) under which CMake added it.
A consumer (ksys, Linker/Sysroot/Runtimes.k) evaluates the predicates for the target in
hand and concatenates the fragments that hold, so a target with no table of its own
(armv6 / riscv32 musl, thumbv7, aarch64_be, ...) still gets a build, while every target
the tables were derived from gets exactly its table back.

How a fragment is found: for one sequence (a runtime's [flags].<lang>, a profile's group
flags, an archive's member list) the per-target sequences are merged into one ordered
supersequence by progressive LCS alignment; each node keeps the set of targets it occurs
in, and a maximal run of nodes with the same set is a fragment. Its predicate is the
conjunction of `prop=v1|v2` clauses (a DNF when no conjunction fits), over at most three
properties, that holds for every target with the run and for no target without it and
excludes the fewest property values; ties go to fewer clauses, then to the earlier
properties of PROPS (libc / object format / pointer width before a spelled arch).
Targets the sequence does not apply to (no such runtime, no such language) are
don't-cares; for an archive or object every target counts. FIXUPS edit the input tables
first (CMake verdicts the template deliberately does not keep).

The script verifies its own output: every input target is instantiated from the written
template and compared with its table (the compile set: member -> source + full flag list;
every archive's member order; every loose object). --holdout NAMES trains without those
targets and reports how they come out (a generalisation check, nothing is written then
unless --out is given).

    python3 Scripts/runtimes_template.py --recipe build/sysroot-share/runtimes-recipe \\
        [--recipe MORE ...] --out build/sysroot-share/runtimes-template

stdlib only (tomllib). Later --recipe dirs win for a target listed in several.
"""
import argparse
import itertools
import os
import shutil
import sys
import tomllib
from pathlib import Path

RUNTIMES = ["builtins", "crt", "libunwind", "libcxxabi", "libcxx"]
PROPS = ["libc", "os", "objfmt", "bits", "int128", "cpu", "rt_arch", "float", "crt_arch",
         "endian", "arch"]
LANG_OF = {".c": "c", ".cpp": "cxx", ".S": "asm"}
# The archive ids the template uses, and the file each is (the gather item's basename).
ARCHIVE_FILES = {"builtins": "", "cxx": "libc++.a", "cxxabi": "libc++abi.a",
                 "unwind": "libunwind.a", "cxx_experimental": "libc++experimental.a"}
OBJECT_FILES = {"crtbegin": "clang_rt.crtbegin.o", "crtend": "clang_rt.crtend.o"}


# --- target properties (Linker/Sysroot/Names.k SysNames::properties is the twin) ---

def cpu_of(arch: str) -> str:
    if arch in ("x86_64", "x32") or (len(arch) == 4 and arch[0] == "i" and arch.endswith("86")):
        return "x86"
    if arch.startswith("aarch64") or arch.startswith("arm64"):
        return "aarch64"
    if arch.startswith("arm") or arch.startswith("thumb"):
        return "arm"
    if arch.startswith("riscv"):
        return "riscv"
    if arch.startswith("wasm"):
        return "wasm"
    for fam, pre in (("powerpc", "powerpc"), ("systemz", "s390x"), ("mips", "mips"),
                     ("loongarch", "loongarch"), ("sparc", "sparc")):
        if arch.startswith(pre):
            return fam
    return arch


B64 = {"x86_64", "riscv64", "wasm64", "powerpc64", "powerpc64le", "s390x", "mips64", "mips64el",
       "loongarch64", "sparcv9", "sparc64"}


def big_endian(arch: str) -> bool:
    if arch.endswith("_be") or arch.endswith("eb") or arch == "s390x":
        return True
    if arch.startswith("sparc"):
        return arch != "sparcel"
    if arch.startswith("powerpc") or arch.startswith("mips"):
        return not (arch.endswith("le") or arch.endswith("el"))
    return False


def os_of(libc: str) -> str:
    return {"musl": "linux", "glibc": "linux", "mingw": "windows"}.get(libc, libc)


def props_of(libc: str, arch: str, clang_triple: str) -> dict:
    cpu = cpu_of(arch)
    os_ = os_of(libc)
    bits = "64" if arch in B64 or cpu == "aarch64" else "32"
    p = {"libc": libc, "os": os_, "arch": arch, "cpu": cpu, "bits": bits}
    p["objfmt"] = "coff" if os_ == "windows" else ("wasm" if cpu == "wasm" else "elf")
    # x32 (Names.k's arch for gnux32 / muslx32): 32-bit pointers, x86_64's registers.
    p["int128"] = "native" if bits == "64" or cpu == "wasm" or arch == "x32" else "soft"
    p["endian"] = "big" if big_endian(arch) else "little"
    if cpu == "arm":
        # armv7-linux-gnueabihf has no vendor: the env is the last component.
        p["float"] = "hard" if os_ == "windows" or clang_triple.endswith("hf") else "soft"
    else:
        p["float"] = "na"
    # compiler-rt's builtins arch (its <arch>_SOURCES): armv6 is arm_min, armv7+ is
    # arm (soft) / armhf (hard), MinGW's is arm; i?86 is i386.
    if arch == "x32":
        rt = "x32"
    elif cpu == "x86":
        rt = "x86_64" if bits == "64" else "i386"
    elif cpu == "aarch64":
        rt = "aarch64"
    elif cpu == "arm":
        sub = arch[5:] if arch.startswith("thumb") else arch[3:]
        if os_ == "windows":
            rt = "arm"
        elif sub.startswith("v6") or sub.startswith("v5") or sub.startswith("v4"):
            rt = "armv6" if sub.startswith("v6") else "armv" + sub[1:]
        else:
            rt = "armhf" if p["float"] == "hard" else "arm"
    elif arch == "sparc64":
        rt = "sparcv9"   # compiler-rt's spelling
    else:
        rt = arch
    p["rt_arch"] = rt
    # The arch in crtbegin/crtend's object names (the crt configure's own spelling).
    if cpu == "arm":
        p["crt_arch"] = "armhf" if p["float"] == "hard" else "arm"
    else:
        p["crt_arch"] = rt
    return p


# --- reading the tables ---

def load(path: Path) -> dict:
    return tomllib.loads(path.read_text())


def member_of(entry: str) -> str:
    return entry.split("=", 1)[1] if "=" in entry else os.path.basename(entry) + ".o"


def path_of(entry: str) -> str:
    return entry.split("=", 1)[0]


def norm_entry(rt: str, entry: str, P: dict) -> str:
    """`<rt>:<path>[=<member>]` with the member reduced to what the template spells:
    omitted when it is the default (file name + .o / .obj), `{o}` for the object
    suffix, `{crt_arch}` for the arch in a crt object's name."""
    path, member = path_of(entry), member_of(entry)
    suf = ".obj" if P["objfmt"] == "coff" else ".o"
    if member == os.path.basename(path) + suf:
        return f"{rt}:{path}"
    member = member.replace("-" + P["crt_arch"] + ".", "-{crt_arch}.")
    if member.endswith(suf):
        member = member[: -len(suf)] + "{o}"
    return f"{rt}:{path}={member}"


def expand_entry(e: str, P: dict) -> tuple:
    """(runtime, path, member) of a template entry for target properties P."""
    body, _, _ = e.partition("@")
    rt, _, rest = body.partition(":")
    path = path_of(rest)
    suf = ".obj" if P["objfmt"] == "coff" else ".o"
    if "=" in rest:
        member = rest.split("=", 1)[1].replace("{o}", suf).replace("{crt_arch}", P["crt_arch"])
    else:
        member = os.path.basename(path) + suf
    return rt, path, member


class Target:
    def __init__(self, rdir: Path, name: str):
        t = load(rdir / "targets" / f"{name}.toml")
        self.name = name
        self.t = t
        self.P = props_of(t["family"], t["arch"], t["clang_triple"])
        self.rdir = rdir
        self.tables = {rt: load(rdir / rt / f"{t[rt]}.toml") for rt in RUNTIMES if rt in t}
        self.fixed = [why for match, fix, why in FIXUPS if match(self) and fix(self) is None]
        # compiles: member -> (runtime, lang, profile role, path, group flags)
        self.groups = {}       # role -> group flags
        self.entry_role = {}   # (rt, member) -> role
        for rt, tb in self.tables.items():
            for g in tb.get("group", {}).values():
                anchor = norm_entry(rt, g["sources"][0], self.P)
                role = f"{rt}/{g['lang']}/{anchor}"
                self.groups[role] = list(g["flags"])
                for e in g["sources"]:
                    self.entry_role[(rt, member_of(e))] = role
                    assert LANG_OF[os.path.splitext(path_of(e))[1]] == g["lang"], e

    def archive_id(self, dest: str, members: list) -> str:
        if all(m.startswith("builtins:") for m in members):
            return "builtins"
        base = os.path.basename(dest)
        for k, v in ARCHIVE_FILES.items():
            if v == base:
                return k
        raise SystemExit(f"{self.name}: archive {dest} has no template id")

    def object_id(self, dest: str) -> str:
        for k, v in OBJECT_FILES.items():
            if os.path.basename(dest) == v:
                return k
        raise SystemExit(f"{self.name}: object {dest} has no template id")


# --- fixups: CMake verdicts the template deliberately does not keep ---
#
# Each is (applies to target?, edit the target's tables in place, why). They run on the
# input tables before anything is derived, so the template carries the corrected rule and
# `derived` targets are checked against the corrected tables. They only touch targets
# with no curated root; the 18 shipped tables are used as they are.

def _armv6_hf(t) -> None:
    # compiler-rt's CMake defines COMPILER_RT_ARMHF_TARGET only for the arches it lists
    # (builtins/CMakeLists.txt:987, armv6 not among them): without it COMPILER_RT_ABI is
    # __attribute__((pcs("aapcs"))) and every builtin returning float/double passes it in
    # core registers, while a hard-float caller reads s0/d0: __trunctfdf2(1.5) is 0 under
    # qemu-arm (tfbf.k exits 0). armv7 hard-float gets it; so must armv6 hard-float.
    for lang in ("c", "asm"):
        fl = t.tables["builtins"]["flags"][lang]
        if "-DCOMPILER_RT_ARMHF_TARGET" not in fl:
            fl.insert(fl.index("-DCOMPILER_RT_HAS_FLOAT16") + 1, "-DCOMPILER_RT_ARMHF_TARGET")


def _riscv32_atomic(t) -> None:
    # rv32 has no 8-byte atomic instructions, so libc++ calls __atomic_load_8 and
    # friends; musl has no libatomic and the builtins exclude atomic.c by default
    # (COMPILER_RT_EXCLUDE_ATOMIC_BUILTIN). Taken as MinGW's quirk takes it: at the end
    # of GENERIC_SOURCES (after eprintf.c), compiled with the generic C flags.
    groups = t.tables["builtins"]["group"]
    for g in groups.values():
        if g["lang"] == "c" and "compiler-rt/lib/builtins/eprintf.c" in g["sources"]:
            if "compiler-rt/lib/builtins/atomic.c" not in g["sources"]:
                g["sources"].insert(g["sources"].index("compiler-rt/lib/builtins/eprintf.c") + 1,
                                    "compiler-rt/lib/builtins/atomic.c")
    for dest, ms in t.t["archives"].items():
        e = "builtins:compiler-rt/lib/builtins/eprintf.c"
        if e in ms and "builtins:compiler-rt/lib/builtins/atomic.c" not in ms:
            ms.insert(ms.index(e) + 1, "builtins:compiler-rt/lib/builtins/atomic.c")


FIXUPS = [
    (lambda t: t.P["cpu"] == "arm" and t.P["float"] == "hard" and t.P["rt_arch"] == "armv6",
     _armv6_hf, "armv6 hard-float builtins get -DCOMPILER_RT_ARMHF_TARGET (P640)"),
    (lambda t: t.P["rt_arch"] == "riscv32" and t.P["libc"] == "musl",
     _riscv32_atomic, "riscv32 musl builtins get atomic.c (P641)"),
]


# --- alignment and predicates ---

def merge(nodes: list, seq: list, tag: str) -> list:
    """Merges \\p seq into the supersequence \\p nodes ([token, set]) by LCS."""
    n, m = len(nodes), len(seq)
    L = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            L[i][j] = L[i + 1][j + 1] + 1 if nodes[i][0] == seq[j] else max(L[i + 1][j], L[i][j + 1])
    out, i, j = [], 0, 0
    while i < n or j < m:
        if i < n and j < m and nodes[i][0] == seq[j]:
            nodes[i][1].add(tag)
            out.append(nodes[i])
            i += 1
            j += 1
        elif i < n and (j == m or L[i + 1][j] >= L[i][j + 1]):
            out.append(nodes[i])
            i += 1
        else:
            out.append([seq[j], {tag}])
            j += 1
    return out


def fragments(seqs: dict) -> list:
    """[(tokens, member set)] for {target: sequence}."""
    nodes = []
    for name in sorted(seqs):
        nodes = merge(nodes, seqs[name], name)
    frags = []
    for tok, s in nodes:
        if frags and frags[-1][1] == s:
            frags[-1][0].append(tok)
        else:
            frags.append(([tok], set(s)))
    return frags


# --widen: put back every value no negative needs (the most general rule). Measured by
# leaving each of the 20 targets out in turn, it serves fewer of them than the tight
# rule (builtins 3/20 vs 5/20, libc++ 15/20 vs 16/20): what one family alone does
# (FreeBSD's getauxval shim, MinGW's chkstk) then leaks into the others. Off by default.
WIDEN = False
RANK = {p: i for i, p in enumerate(PROPS)}
COMBOS = [c for k in (1, 2, 3) for c in itertools.combinations(PROPS, k)]
COMBOS.sort(key=lambda c: (len(c), sum(RANK[p] for p in c)))


def holds(alt: dict, P: dict) -> bool:
    return all(P[p] in vs for p, vs in alt.items())


def widen(alt: dict, N: set, props: dict, domain: dict) -> dict:
    """`alt` with every value no negative needs put back: the most general
    conjunction over the same properties that still rejects all of `N`. A target
    the tables do not cover (a new combination of known values) then gets every
    fragment the data does not rule out."""
    alt = {p: set(v) for p, v in alt.items()}
    for p in list(alt):
        for v in sorted(domain[p] - alt[p]):
            alt[p].add(v)
            if any(holds(alt, props[n]) for n in N):
                alt[p].discard(v)
    return {p: v for p, v in alt.items() if v != domain[p]}


def learn(S: set, N: set, props: dict, domain: dict) -> list:
    """A DNF (list of {prop: values}) true on every target of S and on none of N:
    the conjunction with the fewest excluded values, few properties and preferred
    properties first; a greedy cover when no conjunction fits."""
    if not N:
        return []
    best = None
    for c in COMBOS:
        alt = {p: {props[s][p] for s in S} for p in c}
        if any(holds(alt, props[n]) for n in N):
            continue
        if WIDEN:
            alt = widen(alt, N, props, domain)
        score = (sum(len(domain[p] - v) for p, v in alt.items()), len(alt),
                 sum(RANK[p] for p in alt))
        if best is None or score < best[0]:
            best = (score, alt)
    if best is not None:
        return [best[1]]
    dnf, left = [], set(S)
    while left:
        best = None
        for c in COMBOS:
            for s in sorted(left):
                alt = {p: {props[s][p]} for p in c}
                if any(holds(alt, props[n]) for n in N):
                    continue
                if WIDEN:
                    alt = widen(alt, N, props, domain)
                cov = {x for x in left if holds(alt, props[x])}
                if best is None or len(cov) > len(best[1]):
                    best = (alt, cov)
        if best is None:
            raise SystemExit(f"no predicate separates {sorted(S)} from {sorted(N)}")
        dnf.append(best[0])
        left -= best[1]
    return dnf


def when_text(dnf: list) -> list:
    return [" ".join(f"{p}={'|'.join(sorted(v))}" for p, v in alt.items()) for alt in dnf]


def parse_when(when: list) -> list:
    dnf = []
    for alt in when:
        d = {}
        for clause in alt.split():
            p, _, vs = clause.partition("=")
            d[p] = set(vs.split("|"))
        dnf.append(d)
    return dnf


def eval_when(when, P: dict) -> bool:
    return not when or any(holds(a, P) for a in parse_when(when))


def conditional(seqs: dict, relevant: set, props: dict) -> list:
    """[(when, tokens)] for {target: sequence} over the targets in \\p relevant."""
    domain = {p: {props[t][p] for t in props} for p in PROPS}
    out = []
    for toks, s in fragments(seqs):
        out.append((when_text(learn(s, relevant - s, props, domain)), toks))
    return out


# --- build the template ---

def tree_text(base: Path, key: str):
    """A build/ or headers/ table and its dir, as comparable content: the `# targets:` comment
    (which names the targets of the run that derived it) left out."""
    if not key:
        return None
    toml = [l for l in (base / f"{key}.toml").read_text().splitlines() if not l.startswith("# targets:")]
    files = {}
    d = base / key
    if d.is_dir():
        for p in sorted(d.rglob("*")):
            if p.is_file():
                files[str(p.relative_to(d))] = p.read_bytes()
    return toml, files


def build(targets: list) -> dict:
    props = {t.name: t.P for t in targets}
    tmpl = {"flags": {}, "profiles": {}, "archives": {}, "objects": {}, "families": {}}
    fam_rdir = {}

    # [flags].<lang> per runtime: only targets that compile that language care.
    for rt in RUNTIMES:
        for lang in ("c", "cxx", "asm"):
            seqs = {}
            for t in targets:
                tb = t.tables.get(rt)
                if tb and lang in tb.get("flags", {}) and any(
                        g["lang"] == lang for g in tb.get("group", {}).values()):
                    seqs[t.name] = list(tb["flags"][lang])
            if seqs:
                tmpl["flags"][(rt, lang)] = conditional(seqs, set(seqs), props)

    # Profiles (group flags): a role with no flags anywhere is no profile at all;
    # roles with the same flags on every target that has them share one id.
    roles = {}
    for t in targets:
        for role, fl in t.groups.items():
            roles.setdefault(role, {})[t.name] = fl
    role_pid, by_sig = {}, {}
    for role in sorted(roles):
        seqs = roles[role]
        if not any(seqs.values()):
            role_pid[role] = ""
            continue
        frags = conditional(seqs, set(seqs), props)
        sig = repr(frags)
        if sig not in by_sig:
            pid = f"p{len(by_sig):03d}"
            by_sig[sig] = pid
            tmpl["profiles"][pid] = frags
        role_pid[role] = by_sig[sig]

    def tok(t: Target, ref: str) -> str:
        rt, _, entry = ref.partition(":")
        role = t.entry_role[(rt, member_of(entry))]
        pid = role_pid[role]
        e = norm_entry(rt, entry, t.P)
        return e + ("@" + pid if pid else "")

    arch_seqs, obj_seqs = {}, {}
    for t in targets:
        for dest, members in t.t.get("archives", {}).items():
            aid = t.archive_id(dest, members)
            arch_seqs.setdefault(aid, {})[t.name] = [tok(t, m) for m in members]
        for dest, ref in t.t.get("objects", {}).items():
            obj_seqs.setdefault(t.object_id(dest), {})[t.name] = [tok(t, ref)]
        fam = t.t["family"]
        f = {"headers_dest": t.t.get("headers_dest", ""), "build": t.t.get("build", ""),
             "headers": t.t.get("headers", "")}
        if fam in tmpl["families"] and tmpl["families"][fam] != f:
            # Tables derived in separate runtimes_recipe.py runs name the same tree after
            # different targets (Z5: the new arches' musl-loongarch64+... is the old
            # musl-aarch64+... byte for byte). Same content is the same family tree.
            first, frdir = tmpl["families"][fam], fam_rdir[fam]
            if first["headers_dest"] != f["headers_dest"] or any(
                    tree_text(frdir / k, first[k]) != tree_text(t.rdir / k, f[k]) for k in ("build", "headers")):
                raise SystemExit(f"{t.name}: family {fam} has two build/headers keys")
            continue
        tmpl["families"][fam] = f
        fam_rdir[fam] = t.rdir
    # Whether a target has an output at all is part of the rule (wasi has no libc++,
    # MinGW no libc++abi.a, the BSDs no crt objects): every target is relevant to
    # every output, one without it a negative for all of its fragments.
    every = set(props)
    for aid, seqs in arch_seqs.items():
        tmpl["archives"][aid] = conditional(seqs, every, props)
    for oid, seqs in obj_seqs.items():
        tmpl["objects"][oid] = conditional(seqs, every, props)
    return tmpl


# --- instantiate (the consumer's algorithm, for the self-check) ---

def pick(frags: list, P: dict) -> list:
    return [x for when, toks in frags if eval_when(when, P) for x in toks]


def instantiate(tmpl: dict, P: dict) -> dict:
    """{"compiles": {(rt, member): (path, flags)}, "archives": {id: [(rt, member)]},
    "objects": {id: (rt, member)}}"""
    out = {"compiles": {}, "archives": {}, "objects": {}}

    def add(e: str):
        rt, path, member = expand_entry(e, P)
        _, _, pid = e.partition("@")
        lang = LANG_OF[os.path.splitext(path)[1]]
        fl = pick(tmpl["flags"].get((rt, lang), []), P)
        if pid:
            fl = fl + pick(tmpl["profiles"][pid], P)
        out["compiles"][(rt, member)] = (path, fl)
        return (rt, member)

    for aid, frags in tmpl["archives"].items():
        ms = [add(e) for e in pick(frags, P)]
        if ms:
            out["archives"][aid] = ms
    for oid, frags in tmpl["objects"].items():
        es = pick(frags, P)
        if es:
            out["objects"][oid] = add(es[0])
    return out


def from_tables(t: Target) -> dict:
    out = {"compiles": {}, "archives": {}, "objects": {}}
    for rt, tb in t.tables.items():
        for g in tb.get("group", {}).values():
            for e in g["sources"]:
                out["compiles"][(rt, member_of(e))] = (path_of(e), list(tb["flags"][g["lang"]]) + list(g["flags"]))

    def ref(r):
        rt, _, e = r.partition(":")
        return (rt, member_of(e))

    for dest, members in t.t.get("archives", {}).items():
        out["archives"][t.archive_id(dest, members)] = [ref(m) for m in members]
    for dest, r in t.t.get("objects", {}).items():
        out["objects"][t.object_id(dest)] = ref(r)
    return out


def compare(a: dict, b: dict) -> list:
    bad = []
    for k in ("archives", "objects"):
        if a[k] != b[k]:
            bad.append(f"{k}: {sorted(set(a[k]) ^ set(b[k])) or [x for x in a[k] if a[k][x] != b[k].get(x)]}")
    ca, cb = a["compiles"], b["compiles"]
    for m in sorted(set(ca) | set(cb)):
        if ca.get(m) != cb.get(m):
            bad.append(f"compile {m}: template {ca.get(m)} table {cb.get(m)}")
            if len(bad) > 6:
                break
    return bad


# --- writing ---

def q(s: str) -> str:
    assert '"' not in s and "\\" not in s, s
    return f'"{s}"'


def arr(xs: list, indent: str = "") -> str:
    if not xs:
        return "[]"
    one = "[" + ", ".join(q(x) for x in xs) + "]"
    if len(one) <= 96:
        return one
    return "[\n" + "".join(f"    {q(x)},\n" for x in xs) + "]"


def frag_tables(prefix: str, frags: list) -> str:
    s = ""
    for i, (when, toks) in enumerate(frags):
        s += f"\n[{prefix}.f{i:03d}]\n"
        if when:
            s += f"when = {arr(when)}\n"
        s += f"add  = {arr(toks)}\n"
    return s


HEAD = ("# generated by Scripts/runtimes_template.py; do not edit. "
        "Format: FORMAT.md (runtimes-template).\n")


def write(tmpl: dict, out: Path, sources: dict, targets: list):
    tmp = out.with_name(out.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    names = sorted(t.name for t in targets)
    idx = HEAD + 'schema     = "1"\n'
    idx += f"properties = {arr(PROPS)}\n"
    idx += f"runtimes   = {arr(RUNTIMES)}\n"
    idx += f"derived    = {arr(names)}\n"
    # The value of each property the rules were derived over: a target with any other
    # value is outside the template (a fragment keyed on that property cannot know
    # about it), and the consumer refuses it rather than build a partial library.
    # Only the properties some rule names: one no rule reads (arch, endian) says
    # nothing about whether the rules fit.
    used = {c.partition("=")[0] for k in ("flags", "profiles", "archives", "objects")
            for frags in tmpl[k].values() for when, _ in frags for alt in when
            for c in alt.split()}
    idx += "\n[domain]\n"
    for p in PROPS:
        if p in used:
            idx += f"{p:<8} = {arr(sorted({t.P[p] for t in targets}))}\n"
    idx += "\n[archive_files]\n" + "".join(f"{k} = {q(v)}\n" for k, v in ARCHIVE_FILES.items())
    idx += "\n[object_files]\n" + "".join(f"{k} = {q(v)}\n" for k, v in OBJECT_FILES.items())
    for fam in sorted(tmpl["families"]):
        f = tmpl["families"][fam]
        idx += f"\n[family.{fam}]\n"
        for k in ("build", "headers"):
            idx += f"{k:<12} = {q(fam if f[k] else '')}\n"
        idx += f"headers_dest = {q(f['headers_dest'])}\n"
        # build/<family>.toml + dir and headers/<family>.toml + dir: copies of the
        # family's one table key (every arch of a family shares it).
        for k in ("build", "headers"):
            if not f[k]:
                continue
            src = sources[fam] / k
            (tmp / k).mkdir(exist_ok=True)
            text = (src / f"{f[k]}.toml").read_text()
            (tmp / k / f"{fam}.toml").write_text(text)
            if (src / f[k]).is_dir():
                shutil.copytree(src / f[k], tmp / k / fam)
    # Each derived target's properties: the consumer computes its own and treats a
    # mismatch on a derived name as an internal error (the two property rules drifted).
    for t in sorted(targets, key=lambda t: t.name):
        idx += f'\n[props."{t.name}"]\n' + "".join(f"{p:<8} = {q(t.P[p])}\n" for p in PROPS)
    (tmp / "index.toml").write_text(idx)

    for rt in RUNTIMES:
        s = HEAD + f'runtime = "{rt}"\n'
        for lang in ("c", "cxx", "asm"):
            if (rt, lang) in tmpl["flags"]:
                s += frag_tables(f"flags.{lang}", tmpl["flags"][(rt, lang)])
        (tmp / f"{rt}.toml").write_text(s)

    s = HEAD
    for pid in sorted(tmpl["profiles"]):
        s += frag_tables(f"profile.{pid}", tmpl["profiles"][pid])
    (tmp / "profiles.toml").write_text(s)

    s = HEAD
    for aid in ARCHIVE_FILES:
        if aid in tmpl["archives"]:
            s += frag_tables(f"archive.{aid}", tmpl["archives"][aid])
    for oid in OBJECT_FILES:
        if oid in tmpl["objects"]:
            s += frag_tables(f"object.{oid}", tmpl["objects"][oid])
    (tmp / "outputs.toml").write_text(s)

    shutil.rmtree(out, ignore_errors=True)
    tmp.rename(out)


def read_back(out: Path) -> dict:
    """The written template, read as a consumer reads it."""
    def frags(tb: dict) -> list:
        return [(v.get("when", []), v["add"]) for _, v in sorted(tb.items())]

    tmpl = {"flags": {}, "profiles": {}, "archives": {}, "objects": {}}
    for rt in RUNTIMES:
        d = load(out / f"{rt}.toml")
        for lang, tb in d.get("flags", {}).items():
            tmpl["flags"][(rt, lang)] = frags(tb)
    for pid, tb in load(out / "profiles.toml").get("profile", {}).items():
        tmpl["profiles"][pid] = frags(tb)
    o = load(out / "outputs.toml")
    for aid, tb in o.get("archive", {}).items():
        tmpl["archives"][aid] = frags(tb)
    for oid, tb in o.get("object", {}).items():
        tmpl["objects"][oid] = frags(tb)
    return tmpl


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--recipe", action="append", required=True, type=Path,
                    help="a runtimes-recipe/ dir (repeatable; later ones win per target)")
    ap.add_argument("--out", type=Path, help="the runtimes-template/ dir to write")
    ap.add_argument("--holdout", default="", help="comma-separated targets to train without")
    ap.add_argument("--props", action="store_true", help="print each target's properties")
    ap.add_argument("--widen", action="store_true",
                    help="most general clauses (see WIDEN); for experiments")
    a = ap.parse_args()
    global WIDEN
    WIDEN = a.widen

    found = {}
    for rdir in a.recipe:
        for n in load(rdir / "index.toml")["targets"]:
            found[n] = rdir
    targets = [Target(found[n], n) for n in sorted(found)]
    for t in targets:
        for why in t.fixed:
            print(f"{t.name}: fixup: {why}")
    if a.props:
        for t in targets:
            print(t.name, " ".join(f"{p}={t.P[p]}" for p in PROPS))
    held = {h for h in a.holdout.split(",") if h}
    train = [t for t in targets if t.name not in held]
    tmpl = build(train)
    sources = {}
    for t in train:
        if t.t.get("build", "") == tmpl["families"].get(t.t["family"], {}).get("build", ""):
            sources.setdefault(t.t["family"], t.rdir)

    if a.out:
        write(tmpl, a.out, sources, train)
        tmpl = read_back(a.out)
    nf = sum(len(v) for k in ("flags", "profiles", "archives", "objects") for v in tmpl[k].values())
    print(f"template: {len(train)} targets, {nf} fragments, {len(tmpl['profiles'])} profiles")
    fail = 0
    for t in targets:
        bad = compare(instantiate(tmpl, t.P), from_tables(t))
        tag = "held-out" if t.name in held else "trained"
        print(f"{t.name}: {tag}: {'IDENTICAL' if not bad else 'DIFF'}")
        for b in bad:
            print("    " + b[:400])
        fail += bool(bad) and t.name not in held
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
