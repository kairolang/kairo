#!/usr/bin/env python3
"""Derive the direct-compile runtimes recipes (share/kairo/sysroot/runtimes-recipe/).

    python3 Scripts/runtimes_recipe.py                         # every bundled target
    python3 Scripts/runtimes_recipe.py --only x86_64-linux-musl   # writes index.toml for that one only

Maintainer tool, run by ship_sysroot_inputs.py (`--only runtimes-recipe`); never shipped.
The sysroot generator builds compiler-rt builtins (+ crtbegin/crtend), libunwind,
libc++abi and libc++ for a target WITHOUT CMake or ninja: it runs one kcc compile per
source and one llvm-ar per archive, from tables. This script makes those tables, once,
here, by doing what the generator would have done with CMake:

  1. a libc-headers stage per target: the curated root minus every c++/ header dir, so
     the configure (and later the runner) sees libc headers only, never an old libc++;
  2. the family recipe's own configure(s) (families/<family>.toml [builtins] and
     [runtimes_cmake], plus the matching quirks.toml entries), with kcc as the compiler,
     into <scratch>/cfg/<name>/<stage>;
  3. the header-generating targets only (generate-cxx-headers, the libc++abi header copy,
     the aarch64 outline-atomic helper links); no object is compiled here;
  4. `ninja -t compdb` (it lists ASM too, compile_commands.json may not) and build.ninja's
     archive edges are normalised into per-runtime tables, deduplicated across targets.

The runner is Scripts/build_runtimes_direct.py; the format is FORMAT.md "runtimes-recipe".
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))

RUNTIMES = ("builtins", "crt", "libunwind", "libcxxabi", "libcxx")
# Bundled targets with a curated root (the 18 the share tree replaces).
BUNDLED = {"musl": ["x86_64", "i686", "aarch64", "armv7", "riscv64"],
           "glibc": ["x86_64", "i686", "aarch64", "armv7", "riscv64"],
           "mingw": ["x86_64", "i686", "aarch64", "armv7"],
           "freebsd": ["x86_64", "aarch64"],
           "netbsd": ["x86_64"],
           "wasi": ["wasm32"]}
# Targets with no curated root: derived only when --headers holds a libc-headers root for
# them (a ksys libc-headers stage product + its SYSROOT.toml, under <headers>/<name>/).
EXTRA = {"musl": ["armv6", "riscv32"]}
HEADERS: Path | None = None


def log(m: str) -> None:
    print(f"[runtimes-recipe] {m}", flush=True)


def die(m: str) -> None:
    print(f"[runtimes-recipe] error: {m}", file=sys.stderr, flush=True)
    sys.exit(1)


# ---------------------------------------------------------------- targets

class Target:
    """One bundled sysroot: its family recipe expanded for one arch."""

    def __init__(self, fam: str, rec: dict, arch: str, quirks: dict, ship):
        self.family, self.rec, self.arch = fam, rec, arch
        libc_version = ship.GLIBC_VERSIONS[0] if fam == "glibc" else ""
        self.env = ship.target_env(rec, arch, libc_version)
        self.env["sysname"] = rec.get("sysname", "")
        self.name = self.env["name"]
        self.subst = lambda s: ship.subst(s, self.env)
        self.quirks = [(qid, q) for qid, q in quirks.items() if self._match(q, probe=None)]
        rw = [q["target_rewrite"] for _, q in self.quirks if "target_rewrite" in q]
        self.cc_triple = self.subst(rw[0]) if rw else self.env["clang_triple"]

    def _match(self, q: dict, probe) -> bool:
        if "match_family" in q and self.family not in q["match_family"]:
            return False
        if "match_arch" in q and self.arch not in q["match_arch"]:
            return False
        return True

    def apply_probes(self, probes: dict) -> None:
        keep = []
        for qid, q in self.quirks:
            ok = True
            for p in q.get("match_probe", []):
                neg = p.startswith("!")
                ok = ok and (probes.get(p.lstrip("!"), False) != neg)
            if ok:
                keep.append((qid, q))
        self.quirks = keep

    def q(self, key: str, stage: str, stage_key: str) -> list:
        out = []
        for _, q in self.quirks:
            if stage in q.get(stage_key, []):
                v = q.get(key, [])
                out += v if isinstance(v, list) else [v]
        return out

    @property
    def runtimes(self) -> list:
        return list(self.rec.get("runtimes", []))

    def layout_path(self, gathered: str) -> str:
        """lib/libc++.a, include/c++/v1 -> the root-relative path ([layout] lib/include)."""
        lay = self.rec["layout"]
        top, rest = gathered.split("/", 1)
        return f"{lay[top][0]}/{rest}"

    def rt_dir(self) -> str:
        return self.subst(self.rec["resource_layout"])

    def builtins_name(self) -> str:
        return self.subst(self.rec["builtins_name"])


def all_targets(ship, only=None) -> list[Target]:
    import tomllib
    quirks = tomllib.loads(ship.QUIRKS).get("quirk", {})
    out = []
    for fam, arches in BUNDLED.items():
        rec = ship.load_recipe(ship.FAMILIES[fam])
        for a in arches + EXTRA.get(fam, []):
            t = Target(fam, rec, a, quirks, ship)
            if only and t.name not in only:
                continue
            if a not in arches and not (HEADERS and (HEADERS / t.name / "SYSROOT.toml").is_file()):
                continue
            out.append(t)
    return out


# ---------------------------------------------------------------- stage 1: headers

def header_stage(curated: Path, t: Target, dst: Path) -> Path:
    """The curated root's libc headers and SYSROOT.toml, no c++/ dir anywhere. A target
    --headers has a root for takes that one instead (the only source for EXTRA targets)."""
    src = curated / t.name
    if HEADERS and (HEADERS / t.name / "SYSROOT.toml").is_file():
        src = HEADERS / t.name
    if not (src / "SYSROOT.toml").is_file():
        die(f"{t.name}: no curated root at {src}")
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    shutil.copyfile(src / "SYSROOT.toml", dst / "SYSROOT.toml")
    import tomllib
    m = tomllib.loads((src / "SYSROOT.toml").read_text())
    # outermost first: glibc lists include/<multiarch> before include/
    copied = []
    for d in sorted(m["include_dirs"], key=lambda x: x.count("/")):
        if "/c++/" in f"/{d}/" or any(d.startswith(c + "/") for c in copied):
            continue
        copied.append(d)
        s = src / d
        def ign(dirpath, names):
            # c++/ = an old libc++; eh/ noeh/ = wasi's libc++ variants (c++ only)
            return [n for n in names if n == "c++" or (n in ("eh", "noeh") and t.family == "wasi")]
        shutil.copytree(s, dst / d, symlinks=True, ignore=ign)
    return dst


# ---------------------------------------------------------------- stage 2: configure

def probe(kcc: Path, t: Target, hdr: Path) -> dict:
    out = subprocess.run([str(kcc), f"--target={t.cc_triple}", f"--sysroot={hdr}", "-dM", "-E", "-x", "c",
                          os.devnull], capture_output=True, text=True).stdout
    return {"int128": "__SIZEOF_INT128__" in out, "float128": "__SIZEOF_FLOAT128__" in out}


def cmake_cmd(t: Target, stage: str, kit: Path, src: Path, hdr: Path, bld: Path, share: Path) -> list:
    rec, b, r = t.rec, t.rec.get("builtins", {}), t.rec.get("runtimes_cmake", {})
    tenv = dict(t.env, stage=str(hdr), runtimes=str(src))
    sub = lambda s: __import__("ship_sysroot_inputs").subst(s, tenv)
    kcc = str(kit / "bin" / "kcc")
    cmd = ["cmake", "-G", "Ninja", "-Wno-dev", "-B", str(bld),
           f"-DCMAKE_C_COMPILER={kcc}", f"-DCMAKE_CXX_COMPILER={kcc}", f"-DCMAKE_ASM_COMPILER={kcc}",
           f"-DCMAKE_C_COMPILER_TARGET={t.cc_triple}", f"-DCMAKE_CXX_COMPILER_TARGET={t.cc_triple}",
           f"-DCMAKE_ASM_COMPILER_TARGET={t.cc_triple}",
           f"-DCMAKE_AR={kit / 'bin' / 'llvm-ar'}", f"-DCMAKE_RANLIB={kit / 'bin' / 'llvm-ranlib'}",
           f"-DCMAKE_SYSROOT={hdr}", f"-DCMAKE_INSTALL_PREFIX={bld / 'install'}",
           "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"]
    if stage == "builtins":
        cmd += ["-S", str(src / "compiler-rt" / "lib" / "builtins")]
        defs = b.get("cmake_defs", [])
        cf, xf, af = b.get("c_flags", []), b.get("cxx_flags", []), b.get("asm_flags", [])
        qstage = ["builtins"]
    else:
        en = []
        if b.get("source") == "runtimes" or rec.get("crt_objects"):
            en.append("compiler-rt")
        en += [x for x in ("libunwind", "libcxxabi", "libcxx") if x in t.runtimes]
        cmd += ["-S", str(src / "runtimes"), f"-DLLVM_ENABLE_RUNTIMES={';'.join(en)}",
                f"-DLLVM_DEFAULT_TARGET_TRIPLE={t.cc_triple}",
                # share/kairo/runtimes ships no docs/ dirs; the recipes do not say so (P600)
                "-DLLVM_INCLUDE_DOCS=OFF", "-DLIBCXX_INCLUDE_DOCS=OFF", "-DLIBUNWIND_INCLUDE_DOCS=OFF"]
        defs = list(r.get("cmake_defs", []))
        cf, xf, af = r.get("c_flags", []), r.get("cxx_flags", []), r.get("asm_flags", [])
        qstage = ["runtimes"]
        if b.get("source") == "runtimes":
            defs += b.get("cmake_defs", [])
            qstage.append("builtins")
        elif "compiler-rt" in en:
            # crt only (musl): without this compiler-rt adds a multilib i386 crt (P601)
            defs.append("COMPILER_RT_DEFAULT_TARGET_ONLY=ON")
    for qs in qstage:
        defs = defs + t.q("cmake_defs", qs, "cmake_stages")
    cadd = []
    for qs in qstage:
        cadd += [x for x in t.q("cflags_add", qs, "cflags_stages") if x not in cadd]
    # The scripts the quirks encode put -fforce-enable-int128 on C only in a runtimes
    # configure (build-bsd-runtimes.sh CMAKE_C_FLAGS; glibc: none, compiler-rt adds it to
    # the builtins itself). On C++ it would change libc++'s ABI on 32-bit targets
    # (_LIBCPP_HAS_INT128) and breaks charconv's LLVM-libc UInt128 on i686 (P605).
    xadd = list(cadd) if stage == "builtins" else []
    for qs in qstage:
        xadd += t.q("cflags_add_cxx", qs, "cflags_stages")
        for f in t.q("force_include_file", qs, "force_include_stages"):
            xadd += ["-include", str(share / f)]
    if t.arch.startswith("armv"):
        # check_assembler_flag errors out under CMake 4.4.4 ("This should not have happened");
        # 4.4.2, which built the curated roots, read both as FALSE. Pin that answer (P602).
        defs = defs + ["COMPILER_RT_HAS_MIMPLICIT_IT=FALSE", "COMPILER_RT_HAS_WA_MIMPLICIT_IT=FALSE"]
    cmd += [f"-D{sub(d)}" for d in defs]
    cmd += [f"-DCMAKE_C_FLAGS={' '.join(sub(x) for x in cf + cadd)}",
            f"-DCMAKE_CXX_FLAGS={' '.join(sub(x) for x in (xf or cf) + xadd)}",
            f"-DCMAKE_ASM_FLAGS={' '.join(sub(x) for x in (af or cf))}"]
    return cmd


def configure(t: Target, kit: Path, src: Path, share: Path, curated: Path, scratch: Path) -> dict:
    hdr = header_stage(curated, t, scratch / "hdr" / t.name)
    t.apply_probes(probe(kit / "bin" / "kcc", t, hdr))
    stages = []
    if t.rec["builtins"].get("source") == "compiler-rt/lib/builtins":
        stages.append("builtins")
    if t.runtimes:
        stages.append("runtimes")
    res = {"hdr": hdr, "stages": {}}
    for st in stages:
        bld = scratch / "cfg" / t.name / st
        if bld.exists():
            shutil.rmtree(bld)
        bld.mkdir(parents=True)
        cmd = cmake_cmd(t, st, kit, src, hdr, bld, share)
        (bld / "cmake-command.txt").write_text(shlex.join(cmd) + "\n")
        with open(bld / "configure.log", "w") as fh:
            rc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT).returncode
        if rc:
            die(f"{t.name}/{st}: configure failed ({bld / 'configure.log'})")
        for rx in t.rec["builtins"].get("assert_cache_regex", []):
            if st == "builtins" or t.rec["builtins"].get("source") == "runtimes":
                if not re.search(rx, (bld / "CMakeCache.txt").read_text()):
                    die(f"{t.name}/{st}: CMakeCache.txt has no {rx}")
        # Header generation only: copies + configure_file output, no compile.
        have = ninja_targets(bld)
        gen = [x for x in GEN_TARGETS if x in have]
        oa = sorted(p for p in have if "outline_atomic_helpers.dir/" in p)
        if gen or oa:
            r = subprocess.run(["ninja", "-C", str(bld), *gen, *oa], capture_output=True, text=True)
            if r.returncode:
                die(f"{t.name}/{st}: header generation failed:\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
        res["stages"][st] = bld
    return res


GEN_TARGETS = ("generate-cxx-headers", "cxxabi-generate-headers", "generate-cxxabi-headers",
               "unwind-generate-headers")


def ninja_targets(bld: Path) -> set:
    r = subprocess.run(["ninja", "-C", str(bld), "-t", "targets", "all"], capture_output=True, text=True)
    return {ln.split(":")[0] for ln in r.stdout.splitlines()}


# ---------------------------------------------------------------- stage 3: extract

def archive_edges(bld: Path) -> dict:
    """build.ninja static-library edges: archive path (build-relative) -> object list."""
    text = (bld / "build.ninja").read_text().replace("$\n", "")
    out = {}
    for m in re.finditer(r"^build (\S+\.a): (\S*STATIC_LIBRARY_LINKER\S*) (.*)$", text, re.M):
        objs = m.group(3).split("||")[0].split("|")[0].split()
        out[m.group(1)] = [o.replace("$:", ":").replace("$ ", " ") for o in objs if o.endswith((".o", ".obj"))]
    return out


def lang_of(path: str) -> str:
    ext = path.rsplit(".", 1)[-1]
    return {"c": "c", "cpp": "cxx", "cc": "cxx", "S": "asm", "s": "asm"}.get(ext, "?")


DROP1 = {"-c", "-MD"}
DROP2 = {"-o", "-MT", "-MF", "--sysroot", "-target"}


def normalise(args: list, srcfile: str, repl: list) -> list:
    """Compile line -> the flags the runner passes (compiler, target, sysroot, -c/-o, deps
    and the source dropped; absolute paths templated)."""
    out, i = [], 1
    while i < len(args):
        a = args[i]
        if a in DROP1:
            i += 1
            continue
        if a in DROP2:
            i += 2
            continue
        if a.startswith(("--target=", "--sysroot=", "-MF", "-MT")) or a == srcfile:
            i += 1
            continue
        # diagnostics only: no effect on the object, and -Werror would make a kcc-only
        # warning fatal
        if (a.startswith("-W") and not a.startswith(("-Wa,", "-Wl,", "-Wp,"))) \
                or a in ("-pedantic", "-fdiagnostics-color", "-fcolor-diagnostics"):
            i += 1
            continue
        for frm, to in repl:
            a = a.replace(frm, to)
        out.append(a)
        i += 1
    return out


def extract(t: Target, cfg: dict, src: Path, share: Path) -> dict:
    """Per runtime: {"compiles": [(object member, source, lang, flags)], "archives": {...},
    "objects": {...}, "build_files": {...}}; plus the c++/v1 install manifest."""
    hdr = cfg["hdr"]
    data = {r: {"compiles": [], "archives": {}, "objects": {}} for r in RUNTIMES}
    build_files = {}            # {build}-relative path -> ("src", rel) | ("gen", bytes)
    for st, bld in cfg["stages"].items():
        repl = [(str(bld), "{build}"), (str(src), "{src}"), (str(hdr), "{sysroot}"), (str(share), "{share}")]
        cdb = json.loads(subprocess.run(["ninja", "-C", str(bld), "-t", "compdb"], capture_output=True,
                                        text=True, check=True).stdout)
        by_out = {}
        for e in cdb:
            o = e.get("output", "")
            if not o.endswith((".o", ".obj")):
                continue
            by_out[o] = e
        arch_edges = archive_edges(bld)

        def runtime_of(obj: str) -> str:
            if "compiler-rt" in obj or st == "builtins":
                return "builtins"
            for r in ("libunwind", "libcxxabi", "libcxx"):
                if obj.startswith(r + "/"):
                    return r
            return "?"

        for ar, objs in arch_edges.items():
            base = ar.rsplit("/", 1)[-1]
            if "builtins" in base:
                rt = "builtins"
                if st == "runtimes" and t.rec["builtins"].get("source") != "runtimes":
                    continue            # the standalone builtins stage owns this archive
                dest = f"{t.rt_dir()}/{t.builtins_name()}"
            else:
                rt = {"libunwind.a": "libunwind", "libc++abi.a": "libcxxabi",
                      "libc++.a": "libcxx", "libc++experimental.a": "libcxx"}.get(base)
                if rt is None:
                    continue
                g = f"lib/{base}"
                if g not in t.rec["layout"]["gather"]:
                    continue
                dest = t.layout_path(g)
            members = []
            for o in objs:
                e = by_out.get(o)
                if e is None:
                    die(f"{t.name}: archive {ar} member {o} has no compile command")
                members.append(add_compile(data, runtime_of(o) if rt == "libcxx" else rt, e, bld, src, repl,
                                           build_files))
            data[rt]["archives"][dest] = members
        # loose objects: crtbegin / crtend
        if t.rec.get("crt_objects") and st == "runtimes":
            for o, e in by_out.items():
                b = o.rsplit("/", 1)[-1]
                if "crtbegin" in b or "crtend" in b:
                    kind = "crtbegin" if "crtbegin" in b else "crtend"
                    mem = add_compile(data, "crt", e, bld, src, repl, build_files)
                    data["crt"]["objects"][f"{t.rt_dir()}/clang_rt.{kind}.o"] = mem
    # install manifest of include/c++/v1 (libc++ + libc++abi headers) from the runtimes stage
    headers = {}
    if "runtimes" in cfg["stages"] and "include/c++/v1" in t.rec["layout"]["gather"]:
        bld = cfg["stages"]["runtimes"]
        inst = bld / "hdr-install"
        if inst.exists():
            shutil.rmtree(inst)
        for comp in ("cxx-headers", "cxxabi-headers"):
            subprocess.run(["cmake", "--install", str(bld), "--component", comp, "--prefix", str(inst)],
                           capture_output=True, text=True, check=True)
        v1 = inst / "include" / "c++" / "v1"
        for p in sorted(v1.rglob("*")):
            if p.is_file():
                rel = p.relative_to(v1).as_posix()
                headers[rel] = classify_file(p, src, rel)
    return {"runtimes": data, "build_files": build_files, "headers": headers}


SRC_HASH = {}


def _src_index(src: Path) -> dict:
    """sha256 -> runtimes-relative paths, over the header/source dirs a header may come from."""
    if SRC_HASH:
        return SRC_HASH
    for sub in ("libcxx/include", "libcxx/vendor", "libcxxabi/include", "libunwind/include",
                "compiler-rt/lib/builtins"):
        for p in (src / sub).rglob("*"):
            if p.is_file():
                SRC_HASH.setdefault(hashlib.sha256(p.read_bytes()).hexdigest(), []).append(
                    p.relative_to(src).as_posix())
    return SRC_HASH


def classify_file(p: Path, src: Path, rel: str):
    """("src", runtimes-relative path) when byte-identical to a source file, else ("gen", bytes)."""
    data = p.read_bytes()
    h = hashlib.sha256(data).hexdigest()
    cands = _src_index(src).get(h, [])
    if cands:
        # prefer the one at the same relative path
        best = [c for c in cands if c.endswith("/" + rel)] or cands
        return ("src", sorted(best)[0])
    return ("gen", data)


def add_compile(data: dict, rt: str, e: dict, bld: Path, src: Path, repl: list, build_files: dict) -> str:
    args = shlex.split(e["command"]) if "command" in e else list(e["arguments"])
    if "&&" in args:
        # "cd <dir> && <compiler> ...": only the crt objects; their paths are absolute
        cut = len(args) - 1 - args[::-1].index("&&")
        pre, args = args[:cut], args[cut + 1:]
        if pre[:1] != ["cd"]:
            die(f"unexpected compound compile command: {e['command']}")
    f = e["file"]
    f = f if os.path.isabs(f) else str(Path(e["directory"]) / f)
    srcarg = e["file"]
    flags = normalise(args, srcarg, repl)
    if f.startswith(str(bld) + "/"):
        # a build-tree source (the aarch64 outline-atomic helpers: links to lse.S)
        real = Path(f).resolve()
        rel_src = real.relative_to(src).as_posix() if str(real).startswith(str(src) + "/") else None
        if rel_src is None:
            die(f"build-tree source {f} is not a link into the runtimes source")
        source = rel_src
    else:
        source = Path(f).resolve().relative_to(src.resolve()).as_posix()
    obj = e["output"]
    member = obj.rsplit("/", 1)[-1]
    # include dirs under {build}: the runner materialises them; remember what they hold
    for a in flags:
        for m in re.finditer(r"\{build\}/([^ ]+)", a):
            d = bld / m.group(1)
            if d.is_dir():
                for p in d.rglob("*"):
                    if p.is_file() and "CMakeFiles" not in p.parts \
                            and not p.name.endswith((".cmake", ".ninja", ".txt", ".json", ".log")):
                        rel = p.relative_to(bld).as_posix()
                        if rel not in build_files:
                            build_files[rel] = classify_file(p, src, p.relative_to(d).as_posix())
    data[rt]["compiles"].append({"member": member, "source": source, "lang": lang_of(source),
                                 "flags": flags})
    return (rt, member)


# ---------------------------------------------------------------- stage 4: normalise + write

def q(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def arr(xs: list, indent: str = "    ") -> str:
    if not xs:
        return "[]"
    if sum(len(x) + 4 for x in xs) < 90:
        return "[" + ", ".join(q(x) for x in xs) + "]"
    return "[\n" + "".join(f"{indent}{q(x)},\n" for x in xs) + "]"


def runtime_body(rt: str, rd: dict) -> tuple[str, dict]:
    """The runtime's TOML body (target-independent: no output paths) and the member order of
    each archive keyed by archive id. Flags are grouped: one [group.<n>] per distinct
    (lang, flags); sources in a group compile with exactly those flags."""
    groups = {}
    member_src = {}
    for c in rd["compiles"]:
        key = (c["lang"], tuple(c["flags"]))
        groups.setdefault(key, [])
        default_member = c["source"].rsplit("/", 1)[-1] + ".o"
        ent = c["source"] if c["member"] == default_member else f"{c['source']}={c['member']}"
        if ent not in groups[key]:
            groups[key].append(ent)
        if c["member"] in member_src and member_src[c["member"]] != ent:
            die(f"{rt}: two sources make member {c['member']}")
        member_src[c["member"]] = ent
    lines = []
    # shared prefix per language -> [flags]; the rest per group
    langs = sorted({k[0] for k in groups})
    common = {}
    for L in langs:
        fl = [list(k[1]) for k in groups if k[0] == L]
        common[L] = _common_seq(fl)
    lines.append("[flags]")
    for L in langs:
        lines.append(f"{L} = {arr(common[L])}")
    for i, (key, srcs) in enumerate(sorted(groups.items(), key=lambda kv: (kv[0][0], kv[1][0]))):
        L, fl = key
        extra = _minus(list(fl), common[L])
        lines.append("")
        lines.append(f"[group.g{i:02d}]")
        lines.append(f"lang    = {q(L)}")
        lines.append(f"flags   = {arr(extra)}")
        lines.append(f"sources = {arr(sorted(srcs))}")
    return "\n".join(lines) + "\n", member_src


def _common_seq(lists: list) -> list:
    """Flags present, in the same order, at the start of every list (a common prefix)."""
    if not lists:
        return []
    p = lists[0]
    for l in lists[1:]:
        n = 0
        while n < len(p) and n < len(l) and p[n] == l[n]:
            n += 1
        p = p[:n]
    return list(p)


def _minus(full: list, prefix: list) -> list:
    return full[len(prefix):]


def write_all(results: dict, out: Path, src: Path) -> dict:
    """results: target name -> (Target, extract dict). Writes out/ and returns the index.

    Every table is deduplicated by content and named after the targets it serves
    (`<families>-<arches>`, `+`-joined), so a key says at a glance what it covers."""
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    index = {}
    bodies = {}                 # (kind, hash) -> (text, gens, [targets])
    for name in sorted(results):
        t, ex = results[name]
        ent = {"family": t.family, "arch": t.arch, "clang_triple": t.cc_triple}
        msrc = {}
        for rt in RUNTIMES:
            rd = ex["runtimes"][rt]
            if not rd["compiles"]:
                continue
            body, msrc[rt] = runtime_body(rt, rd)
            h = hashlib.sha256(body.encode()).hexdigest()
            bodies.setdefault((rt, h), [body, {}, []])[2].append(t)
            ent[rt] = (rt, h)
        for rt in RUNTIMES:
            rd = ex["runtimes"][rt]
            for dest, members in rd["archives"].items():
                ent.setdefault("archives", {})[dest] = [f"{r}:{msrc[r][m]}" for r, m in members]
            for dest, (r, m) in rd["objects"].items():
                ent.setdefault("objects", {})[dest] = f"{r}:{msrc[r][m]}"
        for kind, d in (("build", ex["build_files"]), ("headers", ex["headers"])):
            if not d:
                continue
            man, gens = _manifest(d)
            h = hashlib.sha256(man.encode() + b"".join(k.encode() + gens[k] for k in sorted(gens))).hexdigest()
            bodies.setdefault((kind, h), [man, gens, []])[2].append(t)
            ent[kind] = (kind, h)
        if ex["headers"]:
            ent["headers_dest"] = t.layout_path("include/c++/v1")
        index[name] = ent
    names = {}
    for (kind, h), (text, gens, ts) in sorted(bodies.items(), key=lambda kv: (kv[0][0], _key_name(kv[1][2]))):
        key = _key_name(ts)
        n = 2
        while (kind, key) in names.values():
            key = f"{_key_name(ts)}-{n}"
            n += 1
        names[(kind, h)] = (kind, key)
        (out / kind).mkdir(exist_ok=True)
        if kind in RUNTIMES:
            head = (f"# generated by Scripts/runtimes_recipe.py; do not edit. Format: FORMAT.md "
                    f"(runtimes-recipe).\n# targets: {' '.join(sorted(t.name for t in ts))}\n"
                    f"runtime = {q(kind)}\nkey     = {q(key)}\n\n")
        else:
            head = ("# generated by Scripts/runtimes_recipe.py; do not edit. Format: FORMAT.md "
                    f"(runtimes-recipe).\n# targets: {' '.join(sorted(t.name for t in ts))}\n"
                    "# <dest> = \"src:<runtimes-relative path>\" (copy) or \"gen:<path under this key's dir>\"\n")
        (out / kind / f"{key}.toml").write_text(head + text)
        for rel, data in gens.items():
            p = out / kind / key / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
    for ent in index.values():
        for k in (*RUNTIMES, "build", "headers"):
            if k in ent:
                ent[k] = names[ent[k]][1]
    _write_index(out, index)
    return index


def _manifest(d: dict) -> tuple[str, dict]:
    lines, gens = ["[files]"], {}
    for rel in sorted(d):
        kind, v = d[rel]
        if kind == "src":
            lines.append(f"{q(rel)} = {q('src:' + v)}")
        else:
            gens[rel] = v
            lines.append(f"{q(rel)} = {q('gen:' + rel)}")
    return "\n".join(lines) + "\n", gens


def _key_name(ts: list) -> str:
    fams = sorted({t.family for t in ts})
    arches = sorted({t.arch for t in ts})
    return f"{'+'.join(fams)}-{'+'.join(arches)}"


def _write_index(out: Path, index: dict) -> None:
    """index.toml (the target list) + targets/<name>.toml. One file per target keeps every
    table header bare: TomlLite keeps a header as raw text, and names hold dots."""
    head = "# generated by Scripts/runtimes_recipe.py; do not edit. Format: FORMAT.md (runtimes-recipe)."
    (out / "index.toml").write_text(f"{head}\nschema  = \"1\"\ntargets = {arr(sorted(index))}\n")
    (out / "targets").mkdir()
    for name in sorted(index):
        e = index[name]
        L = [head,
             "# The recipe key of each runtime, and what lands where in the root (root-relative).",
             "# Members are \"<runtime>:<entry>\", <entry> as in that runtime's [group.*] sources.",
             f"name         = {q(name)}"]
        for k in ("family", "arch", "clang_triple", *RUNTIMES, "build", "headers", "headers_dest"):
            if k in e:
                L.append(f"{k:<12} = {q(e[k])}")
        if e.get("objects"):
            L += ["", "[objects]"]
            L += [f"{q(d)} = {q(e['objects'][d])}" for d in sorted(e["objects"])]
        if e.get("archives"):
            L += ["", "[archives]"]
            L += [f"{q(d)} = {arr(e['archives'][d])}" for d in sorted(e["archives"])]
        (out / "targets" / f"{name}.toml").write_text("\n".join(L) + "\n")


# ---------------------------------------------------------------- driver

def make_kit(tree: Path, kit: Path) -> Path:
    """kcc + llvm-ar + lib/ without sysroot/: kcc prefers <prefix>/sysroot/<target> over
    --sysroot, and the header stage must be what it compiles against."""
    (kit / "bin").mkdir(parents=True, exist_ok=True)
    for t in ("kcc", "llvm-ar", "llvm-nm"):
        s = (tree / "bin" / t).resolve()
        d = kit / "bin" / t
        if d.is_file() and d.stat().st_ino == s.stat().st_ino:
            continue                        # still the tree's binary (a rebuild replaces the inode)
        d.unlink(missing_ok=True)
        try:
            os.link(s, kit / "bin" / t)
        except OSError:
            shutil.copy2(s, kit / "bin" / t)
    if not (kit / "bin" / "llvm-ranlib").exists():
        os.symlink("llvm-ar", kit / "bin" / "llvm-ranlib")
    if (kit / "lib").exists():
        shutil.rmtree(kit / "lib")
    (kit / "lib").mkdir()
    for d in ("clang", "builtin", "std", "rt"):
        if (tree / "lib" / d).exists():
            shutil.copytree((tree / "lib" / d).resolve(), kit / "lib" / d, symlinks=False)
    return kit


def derive(share: Path, src: Path, curated: Path, tree: Path, scratch: Path, only=None, jobs=6,
           headers: Path | None = None) -> dict:
    import ship_sysroot_inputs as ship
    global HEADERS
    HEADERS = headers
    kit = make_kit(tree, scratch / "kit")
    _src_index(src)             # once, before the worker threads read it
    targets = all_targets(ship, only)
    results = {}

    def one(t):
        cfg = configure(t, kit, src, share, curated, scratch)
        return t.name, (t, extract(t, cfg, src, share))

    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for name, r in ex.map(one, targets):
            log(f"{name}: " + ", ".join(f"{k} {len(v['compiles'])}" for k, v in r[1]["runtimes"].items()
                                         if v["compiles"]))
            results[name] = r
    return write_all(results, share / "runtimes-recipe", src)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--share", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--runtimes", type=Path, default=ROOT / "build" / "sysgen" / "b2" / "rt" / "share" / "kairo" / "runtimes")
    ap.add_argument("--curated", type=Path, default=ROOT / "build" / "x86_64-linux-gnu" / "release" / "sysroot")
    ap.add_argument("--tree", type=Path, default=ROOT / "build" / "x86_64-linux-musl" / "release")
    ap.add_argument("--scratch", type=Path, default=ROOT / "build" / "sysgen" / "b2")
    ap.add_argument("--only", nargs="+")
    ap.add_argument("-j", type=int, default=6, help="targets configured at once")
    ap.add_argument("--headers", type=Path, default=None,
                    help="dir of <name>/ libc-headers roots (SYSROOT.toml + include dirs), taken over the "
                         "curated root; adds the EXTRA targets it has a root for (armv6/riscv32 musl)")
    a = ap.parse_args()
    derive(a.share.resolve(), a.runtimes.resolve(), a.curated.resolve(), a.tree.resolve(), a.scratch.resolve(),
           a.only, a.j, a.headers.resolve() if a.headers else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
