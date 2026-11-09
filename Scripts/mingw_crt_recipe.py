#!/usr/bin/env python3
"""Derive the mingw-w64-crt from-source tables (share/kairo/sysroot/mingw-crt/).

    python3 Scripts/mingw_crt_recipe.py                     # into build/sysroot-share/mingw-crt
    python3 Scripts/ship_sysroot_inputs.py --only mingw-crt # the same, as a share step

Maintainer tool, never shipped. The generator builds a MinGW root's crt objects and every
lib*.a (code archives, import libraries from .def files, the MRI-merged CRT archives such as
libucrt.a = libmsvcrt.a) with one kcc compile per source, one cpp per .def.in, llvm's dlltool
and an archive writer: no autotools, make or shell. This script is the port of
mingw-w64-crt's Makefile.am selection logic, done mechanically rather than by hand: per arch
it runs the real `configure` (the flags llvm-mingw's build-mingw-w64.sh passes) and
`make -n all V=1`, and turns the printed commands into the TOML tables
(build/sysroot-share/FORMAT.md, "mingw-crt"). Nothing is compiled here; the reference runner
Scripts/build_mingw_crt_direct.py compiles from the tables.

Sources: Lib/libc/mingw at PIN (git archive: mingw-w64-crt is outside the sparse checkout).
PIN is the last mingw-w64 commit before llvm-mingw 20260224, the release the curated
windows-gnu roots and the shipped mingw/include headers came from: 2028 of the 2054
installed headers are byte-identical to mingw-w64-headers at PIN (HEAD: 1585), so crt and
headers stay one revision.
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))

PIN = "43f2643cbde20aff1c4b89a98c78d0b4b0fe90c2"
ARCHES = ["x86_64", "i686", "aarch64", "armv7"]
# llvm-mingw build-mingw-w64.sh: one lib dir per configure, UCRT default, CFG on.
CONFIGURE = {
    "x86_64":  ["--disable-lib32", "--enable-lib64"],
    "i686":    ["--enable-lib32", "--disable-lib64"],
    "armv7":   ["--disable-lib32", "--disable-lib64", "--enable-libarm32"],
    "aarch64": ["--disable-lib32", "--disable-lib64", "--enable-libarm64"],
}
COMMON_CONFIGURE = ["--with-default-msvcrt=ucrt", "--enable-cfguard"]
LIBDIR = {"x86_64": "lib64", "i686": "lib32", "armv7": "libarm32", "aarch64": "libarm64"}
DLLTOOL_M = {"x86_64": "i386:x86-64", "i686": "i386", "armv7": "arm", "aarch64": "arm64"}
# What make writes into the build dir itself rather than reading from the source.
GENERATED = {"_libm_dummy.c": 'static int __attribute__((unused)) __mingw_libm_dummy;\n', "config.h": None}
SRCREL = "../mingw-w64-crt"     # configure was run from <scratch>/b-<arch>, the source beside it
PREFIX = "/P"                   # configure --prefix; -I/P/include is the installed headers
INSTALL_VARS = re.compile(r"^(lib|crt|dx|winrt)(32|64|arm32|arm64)_(DATA|LIBRARIES)$")


def log(m: str) -> None:
    print(f"[mingw-crt] {m}", file=sys.stderr, flush=True)


def die(m: str) -> None:
    sys.exit(f"[mingw-crt] error: {m}")


def q(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def arr(xs) -> str:
    return "[" + ", ".join(q(x) for x in xs) + "]"


# ---------------------------------------------------------------- source + configure

def source(scratch: Path) -> Path:
    out = scratch / "src"
    stamp = out / ".pin"
    if stamp.is_file() and stamp.read_text() == PIN:
        return out / "mingw-w64-crt"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    tar = subprocess.run(["git", "-C", str(ROOT / "Lib/libc/mingw"), "archive", "--format=tar", PIN,
                          "mingw-w64-crt"], check=True, capture_output=True).stdout
    (out / "s.tar").write_bytes(tar)
    with tarfile.open(out / "s.tar") as t:
        t.extractall(out, filter="data")
    (out / "s.tar").unlink()
    stamp.write_text(PIN)
    return out / "mingw-w64-crt"


def configure(arch: str, src: Path, scratch: Path, kcc: Path, curated: Path) -> Path:
    """The real configure, compiling with kcc against the curated root only for its probes:
    every value the tables keep is a Makefile variable, never a probe result about libc."""
    b = scratch / f"b-{arch}"
    if b.exists():
        shutil.rmtree(b)
    b.mkdir(parents=True)
    if not (b.parent / "mingw-w64-crt").exists():
        os.symlink(src, b.parent / "mingw-w64-crt")
    cc = f"{kcc} --target={arch}-w64-windows-gnu --sysroot={curated / f'{arch}-windows-gnu'}"
    tools = Path(kcc).parent
    # relative, so make prints sources as ../mingw-w64-crt/... (SRCREL), never absolute
    cmd = [f"{SRCREL}/configure", f"--host={arch}-w64-mingw32", f"--prefix={PREFIX}",
           *CONFIGURE[arch], *COMMON_CONFIGURE, f"CC={cc}", "CFLAGS=-O2", f"AR={tools / 'llvm-ar'}",
           f"RANLIB={tools / 'llvm-ranlib'}", "DLLTOOL=llvm-dlltool", "AS=false"]
    r = subprocess.run(cmd, cwd=b, capture_output=True, text=True)
    (b / "configure.out").write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        die(f"{arch}: configure failed, see {b / 'configure.out'}")
    return b


def make_var(b: Path, var: str) -> str:
    pv = b / "printvars.mk"
    if not pv.is_file():
        pv.write_text("print-%:\n\t@echo '$*=$($*)'\n")
    r = subprocess.run(["make", "-s", "-f", "Makefile", "-f", str(pv), f"print-{var}"], cwd=b,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip().split("=", 1)[1]


def install_set(b: Path, arch: str) -> list[str]:
    vars_ = set()
    r = subprocess.run(["make", "-pn"], cwd=b, capture_output=True, text=True)
    for line in r.stdout.splitlines():
        m = re.match(r"^([A-Za-z0-9_]+) [:+]?= ", line)
        if m and INSTALL_VARS.match(m.group(1)):
            vars_.add(m.group(1))
    files = []
    for v in sorted(vars_):
        d = make_var(b, v.rsplit("_", 1)[0] + "dir")
        if d.rstrip("/") != f"{PREFIX}/lib":
            die(f"{arch}: {v} installs into {d}, not {PREFIX}/lib")
        files += make_var(b, v).split()
    return sorted(set(files))


# ---------------------------------------------------------------- dry-run parsing

def norm_path(p: str) -> str:
    """A make-relative path as a table template: {src}/x or a {build}-relative path."""
    if p.startswith(SRCREL + "/"):
        return "{src}/" + p[len(SRCREL) + 1:]
    if p == SRCREL:
        return "{src}"
    if p == ".":
        return "{build}"
    if p.startswith(PREFIX + "/include"):
        return "{sysroot}/include" + p[len(PREFIX) + len("/include"):]
    if os.path.isabs(p):
        die(f"absolute path {p} in a make command")
    return "{build}/" + p


def norm_flags(toks: list[str]) -> list[str]:
    """Compile / cpp flags as the tables keep them: no driver, target, sysroot, dependency
    tracking, -pipe or warnings (none changes an object; -Werror= would make a kcc-only
    warning fatal); include paths templated."""
    out, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t in ("-MT", "-MF", "-MQ", "-o"):
            i += 2
            continue
        if t in ("-MD", "-MP", "-MMD", "-c", "-pipe", "-E", "-P") or t.startswith(("--target=", "--sysroot=")):
            i += 1
            continue
        if t.startswith("-W") and not t.startswith(("-Wa,", "-Wl,", "-Wp,")):
            i += 1
            continue
        if t == "-Wp,-w":
            i += 1
            continue
        if t.startswith("-I") and len(t) > 2:
            out.append("-I" + norm_path(t[2:]))
        elif t in ("-I", "-isystem", "-include"):
            out += [t, norm_path(toks[i + 1])]
            i += 1
        else:
            out.append(t)
        i += 1
    return out


BACKTICK = re.compile(r"`test -f '([^']+)' \|\| echo '[^']*'`\1")


def parse_dry(log_text: str, kcc: str, arch: str) -> dict:
    defs, compiles, archives, alias = {}, {}, {}, {}
    order = []
    logical, cur = [], ""
    for raw in log_text.splitlines():          # join shell continuations into one command
        if raw.endswith("\\"):
            cur += raw[:-1] + " "
            continue
        logical.append(cur + raw)
        cur = ""
    for raw in logical:
        line = raw.strip()
        if line.startswith(("fail=", "Making ", "make[", "test -f config.h")):
            continue                           # automake's recursion and config.h stamp
        line = re.sub(r"^/usr/bin/mkdir -p \S+ && ", "", line)
        if not line or line.startswith(("mv ", "rm ", ": ", "/usr/bin/mkdir", "echo ", "test ", "make")):
            continue
        if line.startswith(kcc + " ") and " -E -x c " in line:
            m = re.match(r"(.*) > (\S+)$", line)
            cmd, out = m.group(1), m.group(2)
            strip_at = "| sed -E" in cmd
            cmd = cmd.split(" | ")[0]
            toks = shlex.split(cmd)[1:]
            srcs = [t for t in toks if t.endswith(".def.in") or t.endswith(".def")]
            if len(srcs) != 1:
                die(f"{arch}: cannot read def command {line[:200]}")
            toks = [t for t in toks if t != srcs[0] and t not in ("-x", "c")]
            e = {"source": norm_path(srcs[0]), "out": out, "flags": norm_flags(toks), "strip_at": strip_at}
            if out in defs and defs[out] != e:
                die(f"{arch}: {out} preprocessed two ways")
            defs[out] = e
            continue
        if line.startswith(kcc + " "):
            line = BACKTICK.sub(lambda m: SRCREL + "/" + m.group(1) if not (m.group(1) in GENERATED)
                                else m.group(1), line)
            toks = shlex.split(line)[1:]
            o = toks[toks.index("-o") + 1]
            srcs = [t for t in toks if re.search(r"\.(c|S|s|cpp|cc)$", t) and toks[toks.index(t) - 1] not in
                    ("-o", "-MT", "-MF")]
            if len(srcs) != 1:
                die(f"{arch}: cannot read compile {line[:300]}")
            s = srcs[0]
            flags = norm_flags([t for t in toks if t != s])
            ext = s.rsplit(".", 1)[1]
            lang = {"c": "c", "S": "asm", "s": "asm", "cpp": "cxx", "cc": "cxx"}[ext]
            e = {"source": norm_path(s), "obj": o, "lang": lang, "flags": flags}
            if o in compiles and compiles[o] != e:
                die(f"{arch}: {o} compiled two ways")
            compiles[o] = e
            continue
        if "llvm-dlltool" in line.split()[0] or line.split()[0].endswith("dlltool"):
            # DTLIB32 and friends: $(top_srcdir)/`echo $@ | sed 's|/lib|/|;s|\.a|.def|'`
            line = re.sub(r"`echo (\S+) \| \S*sed 's\|/lib\|/\|;s\|\\\.a\|\.def\|'`",
                          lambda m: m.group(1).replace("/lib", "/", 1).replace(".a", ".def", 1), line)
            parts = line.split(" && ")
            d = shlex.split(parts[0])
            out = d[d.index("--output-lib") + 1]
            dfile = d[d.index("--input-def") + 1]
            mach = d[d.index("-m") + 1]
            if mach != DLLTOOL_M[arch]:
                die(f"{arch}: dlltool -m {mach}")
            members = []
            if len(parts) > 1:
                a = shlex.split(parts[1])
                if a[1] != "cru" or a[2] != out:
                    die(f"{arch}: unexpected {parts[1][:200]}")
                members = a[3:]
            e = {"out": out, "def": norm_path(dfile), "members": members}
            if out in archives:
                if archives[out] != e:
                    die(f"{arch}: {out} archived two ways")
                continue
            archives[out] = e
            order.append(out)
            continue
        w = line.split()
        if w[0].endswith("llvm-ar") and w[1] == "cru":
            out = w[2]
            e = {"out": out, "members": w[3:]}
            if out in archives:
                if archives[out] != e:
                    die(f"{arch}: {out} archived two ways")
                continue
            archives[out] = e
            order.append(out)
            continue
        if w[0].endswith("llvm-ranlib"):
            continue
        if w[0] == "cp" and len(w) == 3:
            alias[w[2]] = w[1]
            continue
        if w[0] == "cd" and " -M < " in line:
            m = re.match(r"cd (\S+?)/? && \S+ -M < (\S+)$", line)
            sub, mri = m.group(1), Path(m.group(2))
            create, adds = None, []
            for ml in mri.read_text().splitlines():
                ml = ml.strip()
                if not ml or ml.startswith(("*", ";")):
                    continue
                kw, *rest = ml.split()
                kw = kw.upper()
                if kw == "CREATE":
                    create = f"{sub}/{rest[0]}"
                elif kw == "ADDLIB":
                    adds.append(f"{sub}/{rest[0]}")
                elif kw in ("SAVE", "END"):
                    pass
                else:
                    die(f"{mri}: MRI {kw} not handled")
            e = {"out": create, "addlib": adds}
            if create in archives:
                if archives[create] != e:
                    die(f"{arch}: {create} merged two ways")
                continue
            archives[create] = e
            order.append(create)
            continue
        die(f"{arch}: unclassified command: {line[:200]}")
    return {"defs": defs, "compiles": compiles, "archives": archives, "order": order, "alias": alias}


def resolve(alias: dict, p: str) -> str:
    seen = 0
    while p in alias:
        p = alias[p]
        seen += 1
        if seen > 16:
            die(f"alias loop at {p}")
    return p


def prune(arch: str, d: dict, installed: list[str]) -> dict:
    """Only what the installed files need; aliases (cp) resolved away."""
    al = d["alias"]
    need_ar, need_obj, need_def = set(), set(), set()
    install = {}
    stack = []
    for f in installed:
        src = resolve(al, f)
        install["lib/" + f.split("/", 1)[1]] = src
        if src in d["archives"]:
            stack.append(src)
        elif src in d["compiles"]:
            need_obj.add(src)
        else:
            die(f"{arch}: installed {f} ({src}) is built by nothing the dry run printed")
    while stack:
        a = resolve(al, stack.pop())
        if a in need_ar:
            continue
        need_ar.add(a)
        e = d["archives"][a]
        for m in e.get("members", []):
            m = resolve(al, m)
            if m not in d["compiles"]:
                die(f"{arch}: {a} member {m} is not compiled")
            need_obj.add(m)
        for x in e.get("addlib", []):
            x = resolve(al, x)
            if x not in d["archives"]:
                die(f"{arch}: {a} ADDLIB {x} is built by nothing")
            stack.append(x)
        if "def" in e and e["def"].startswith("{build}/"):
            need_def.add(e["def"][len("{build}/"):])
    for x in need_def:
        if x not in d["defs"]:
            die(f"{arch}: def {x} is generated by nothing")
    archives = []
    for a in d["order"]:
        if a in need_ar:
            e = dict(d["archives"][a])
            if "addlib" in e:
                e["addlib"] = [resolve(al, x) for x in e["addlib"]]
            if "members" in e:
                e["members"] = [resolve(al, x) for x in e["members"]]
            archives.append(e)
    pos = {e["out"]: i for i, e in enumerate(archives)}
    for i, e in enumerate(archives):
        for x in e.get("addlib", []):
            if pos[x] >= i:
                die(f"{arch}: {e['out']} merges {x} before it is built")
    return {"defs": [d["defs"][k] for k in sorted(need_def)],
            "compiles": [d["compiles"][k] for k in sorted(need_obj)],
            "archives": archives, "install": install}


# ---------------------------------------------------------------- writing

def common_prefix(lists: list[list[str]]) -> list[str]:
    if not lists:
        return []
    p = list(lists[0])
    for l in lists[1:]:
        n = 0
        while n < len(p) and n < len(l) and p[n] == l[n]:
            n += 1
        p = p[:n]
    return p


def write_arch(out: Path, arch: str, t: dict, gen: dict) -> None:
    L = [f"# mingw-w64-crt {PIN[:12]} for {arch}: generated by Scripts/mingw_crt_recipe.py from",
         "# configure + `make -n all V=1`; do not edit. Format: build/sysroot-share/FORMAT.md, \"mingw-crt\".",
         f"arch            = {q(arch)}",
         f"clang_triple    = {q(arch + '-w64-windows-gnu')}",
         f"dlltool_machine = {q(DLLTOOL_M[arch])}",
         'dlltool_flags   = ["-k"]', ""]
    L += ["[files]                         # {build}-relative = gen file (mingw-crt/gen/<arch>/...)"]
    L += [f"{q(k)} = {q('gen:' + arch + '/' + k)}" for k in sorted(gen)]
    flags = {}
    for lang in ("c", "asm", "cxx"):
        fl = [c["flags"] for c in t["compiles"] if c["lang"] == lang]
        if fl:
            flags[lang] = common_prefix(fl)
    L += ["", "[flags]                         # leading flags of every compile of that language"]
    L += [f"{k:<3} = {arr(v)}" for k, v in flags.items()]
    groups = {}
    for c in t["compiles"]:
        rest = c["flags"][len(flags[c["lang"]]):]
        groups.setdefault((c["lang"], tuple(rest)), []).append(c)
    for i, ((lang, rest), cs) in enumerate(sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1]))):
        L += ["", f"[group.g{i:03d}]", f"lang    = {q(lang)}", f"flags   = {arr(rest)}",
              "sources = " + arr(f"{c['source']}={c['obj']}" for c in sorted(cs, key=lambda c: c["obj"]))]
    for i, d in enumerate(t["defs"]):
        L += ["", f"[def.d{i:03d}]", f"source   = {q(d['source'])}", f"out      = {q(d['out'])}",
              f"flags    = {arr(d['flags'])}", f"strip_at = {'true' if d['strip_at'] else 'false'}"]
    for i, a in enumerate(t["archives"]):
        L += ["", f"[archive.a{i:04d}]", f"out     = {q(a['out'])}"]
        if "def" in a:
            L.append(f"def     = {q(a['def'])}")
        if a.get("members"):
            L.append(f"members = {arr(a['members'])}")
        if a.get("addlib"):
            L.append(f"addlib  = {arr(a['addlib'])}")
    L += ["", "[install]                       # root-relative = {build}-relative"]
    L += [f"{q(k)} = {q(v)}" for k, v in sorted(t["install"].items())]
    (out / f"{arch}.toml").write_text("\n".join(L) + "\n")


def derive(share: Path, scratch: Path, curated: Path, kcc: Path, deps: Path | None = None) -> dict:
    """Configure + dry-run every arch, write <share>/mingw-crt/{index,<arch>}.toml and gen/.
    The src/ subset is written by ship_src() once a reference build has listed the headers."""
    src = source(scratch)
    out = share / "mingw-crt"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    tables = {}
    for arch in ARCHES:
        log(f"{arch}: configure")
        b = configure(arch, src, scratch, kcc, curated)
        r = subprocess.run(["make", "-n", "all", "V=1"], cwd=b, capture_output=True, text=True)
        if r.returncode != 0:
            die(f"{arch}: make -n failed: {r.stderr[-500:]}")
        (b / "dry.log").write_text(r.stdout)
        d = parse_dry(r.stdout, f"{kcc} --target={arch}-w64-windows-gnu --sysroot={curated / f'{arch}-windows-gnu'}"
                      .split(" --target")[0], arch)
        t = prune(arch, d, install_set(b, arch))
        gen = {"config.h": (b / "config.h").read_text(), "_libm_dummy.c": GENERATED["_libm_dummy.c"]}
        used = {c["source"] for c in t["compiles"]}
        gen = {k: v for k, v in gen.items() if k == "config.h" or "{build}/" + k in used}
        for k, v in gen.items():
            p = out / "gen" / arch / k
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(v)
        write_arch(out, arch, t, gen)
        tables[arch] = t
        log(f"{arch}: {len(t['compiles'])} compiles, {len(t['defs'])} defs, {len(t['archives'])} archives, "
            f"{len(t['install'])} installed files")
    (out / "index.toml").write_text(
        "# mingw-w64-crt from source; generated by Scripts/mingw_crt_recipe.py. Format: FORMAT.md, \"mingw-crt\".\n"
        'schema   = "1"\n'
        f'revision = "{PIN}"\n'
        f"arches   = {arr(ARCHES)}\n")
    return tables


def referenced_sources(tables: dict) -> set[str]:
    refs = set()
    for t in tables.values():
        for c in t["compiles"]:
            if c["source"].startswith("{src}/"):
                refs.add(c["source"][6:])
        for d in t["defs"]:
            refs.add(d["source"][6:])
        for a in t["archives"]:
            if a.get("def", "").startswith("{src}/"):
                refs.add(a["def"][6:])
    return refs


def ship_src(share: Path, src: Path, files: set[str]) -> None:
    """mingw-crt/src/: exactly `files` (sources, defs, the headers the reference build read)
    plus def-include/ whole (the .def.in cpp includes)."""
    out = share / "mingw-crt" / "src"
    if out.exists():
        shutil.rmtree(out)
    want = set(files)
    for d, _, fs in os.walk(src / "def-include"):
        for f in fs:
            want.add(os.path.relpath(os.path.join(d, f), src).replace(os.sep, "/"))
    for r in sorted(want):
        s = src / r
        if not s.is_file():
            die(f"src/{r}: not in mingw-w64-crt at {PIN[:12]}")
        (out / r).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(s, out / r)


def deps_closure(src: Path, works: list[Path]) -> set[str]:
    """Every file under `src` that a reference build's -MD dependency files name."""
    src = Path(os.path.realpath(src))
    files = set()
    for w in works:
        for d, _, fs in os.walk(w):
            for f in fs:
                if not f.endswith(".d"):
                    continue
                txt = Path(d, f).read_text().replace("\\\n", " ")
                for tok in txt.split(":", 1)[1].split():
                    p = Path(os.path.realpath(tok if os.path.isabs(tok) else os.path.join(w, tok)))
                    if str(p).startswith(str(src) + os.sep):
                        files.add(p.relative_to(src).as_posix())
    return files


def make_all(share: Path, scratch: Path, curated: Path, kcc: Path, tree: Path, jobs: int = 16) -> dict:
    """derive() + a reference build of every arch from the full source (with -MD) + src/ =
    the files those builds read. Returns per-arch stats for provenance."""
    import build_mingw_crt_direct as run
    import runtimes_recipe
    tables = derive(share, scratch, curated, kcc)
    src = source(scratch)
    kit = runtimes_recipe.make_kit(tree, scratch / "kit")
    works, stats = [], {}
    for arch in ARCHES:
        hdr = run.header_stage(share, arch, scratch / "ref" / f"{arch}.hdr")
        w = scratch / "ref" / f"{arch}.work"
        run.build(share, arch, scratch / "ref" / arch, hdr, kit, w, jobs, deps=True, src=src)
        works.append(w)
        t = tables[arch]
        stats[arch] = (len(t["compiles"]), len(t["defs"]), len(t["archives"]), len(t["install"]))
    ship_src(share, src, deps_closure(src, works) | referenced_sources(tables))
    for w in works:
        shutil.rmtree(w)
    return stats


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--share", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--scratch", type=Path, default=ROOT / "build" / "sysgen" / "z1" / "mingw")
    ap.add_argument("--curated", type=Path, default=ROOT / "build" / "x86_64-linux-gnu" / "release" / "sysroot")
    ap.add_argument("--kcc", type=Path, default=ROOT / "build" / "relcand" / "bin" / "kcc",
                    help="compiler for configure's probes only")
    a = ap.parse_args()
    derive(a.share.resolve(), a.scratch.resolve(), a.curated.resolve(), a.kcc.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
