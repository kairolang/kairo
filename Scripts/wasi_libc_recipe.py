#!/usr/bin/env python3
"""Derive the wasi-libc from-source tables (share/kairo/sysroot/wasi-libc/).

    python3 Scripts/ship_sysroot_inputs.py --only wasi-libc     # the share step
    python3 Scripts/wasi_libc_recipe.py --share DIR             # the same, standalone

Maintainer tool, never shipped. The generator builds the wasm32-wasi libc (headers,
crt1*.o, libc.a and the other archives, libc.so and the other shared libs) with one kcc
compile per source, an archive writer and kcc -shared links: no CMake, ninja or sed. Like
Scripts/runtimes_recipe.py this derives the tables from the project's own build: CMake
configure with the options wasi-sdk 33 passes, `ninja -t commands sysroot` (every command
the sysroot target runs, in order) parsed into TOML (build/sysroot-share/FORMAT.md,
"wasi-libc"), plus one real offline build (`unshare -rn`, so the ExternalProject download
rules can never fire) whose generated headers are shipped and which the runner is checked
against. The reference runner is Scripts/build_wasi_libc_direct.py.

Source: Lib/libc/wasi at tag wasi-sdk-33 (git archive: the sparse checkout lacks cmake/,
dlmalloc/, ...), the wasi-libc the curated wasm32-wasi root (wasi-sdk 33) was built from.
WASI_SDK_VERSION = "33.0+m", the string that root's wasi/version.h carries; with it all 206
installed headers are byte-identical to the curated ones.
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

TAG = "wasi-sdk-33"
SDK_VERSION = "33.0+m"
TARGETS = {"wasm32-wasi": "wasm32-unknown-wasi"}     # sysroot name -> clang triple (FORMAT recipe)
LIBDIR = "lib/wasm32-wasi"
INCDIR = "include/wasm32-wasi"


def log(m: str) -> None:
    print(f"[wasi-libc] {m}", file=sys.stderr, flush=True)


def die(m: str) -> None:
    sys.exit(f"[wasi-libc] error: {m}")


def q(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def arr(xs) -> str:
    return "[" + ", ".join(q(x) for x in xs) + "]"


def commit() -> str:
    return subprocess.run(["git", "-C", str(ROOT / "Lib/libc/wasi"), "rev-parse", f"{TAG}^{{commit}}"],
                          check=True, capture_output=True, text=True).stdout.strip()


def source(scratch: Path) -> Path:
    out = scratch / "src"
    rev = commit()
    if (scratch / ".pin").is_file() and (scratch / ".pin").read_text() == rev:
        return out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    tar = subprocess.run(["git", "-C", str(ROOT / "Lib/libc/wasi"), "archive", "--format=tar", rev],
                         check=True, capture_output=True).stdout
    (scratch / "s.tar").write_bytes(tar)
    with tarfile.open(scratch / "s.tar") as t:
        t.extractall(out, filter="data")
    (scratch / "s.tar").unlink()
    (scratch / ".pin").write_text(rev)
    return out


def configure_and_build(name: str, src: Path, scratch: Path, kit: Path, builtins: Path) -> Path:
    """CMake configure (wasi-sdk's options) and a real offline `ninja sysroot`. The configure
    runs with clang, not kcc: CMake and builtins.cmake query -dumpversion,
    --print-libgcc-file-name and -print-resource-dir, which kcc does not answer. Only the
    commands' flags are kept; the runner compiles with kcc."""
    b = scratch / f"b-{name}"
    if b.exists():
        shutil.rmtree(b)
    clang = ROOT / "build" / "relcand" / "bin" / "clang"
    stub = scratch / f"stub-{name}"         # replaced by {sysroot} in the tables
    stub.mkdir(parents=True, exist_ok=True)
    k = kit / "bin"
    cmd = ["cmake", "-G", "Ninja", "-S", str(src), "-B", str(b), f"-DCMAKE_C_COMPILER={clang}",
           f"-DCMAKE_AR={k / 'llvm-ar'}", f"-DCMAKE_NM={k / 'llvm-nm'}", f"-DCMAKE_RANLIB={k / 'llvm-ranlib'}",
           f"-DCMAKE_C_FLAGS=--sysroot={stub}", f"-DCMAKE_ASM_FLAGS=--sysroot={stub}",
           "-DCMAKE_C_COMPILER_WORKS=1", "-DCMAKE_ASM_COMPILER_WORKS=1",
           "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", f"-DTARGET_TRIPLE={name}",
           f"-DBUILTINS_LIB={builtins}", f"-DWASI_SDK_VERSION={SDK_VERSION}", "-DBINDINGS_TARGET=OFF",
           "-DCMAKE_BUILD_TYPE=Release"]
    offline = ["unshare", "-rn"] if shutil.which("unshare") else []
    r = subprocess.run(offline + cmd, capture_output=True, text=True)
    (scratch / f"cmake-{name}.log").write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        die(f"{name}: cmake failed, see {scratch / f'cmake-{name}.log'}")
    r = subprocess.run(["ninja", "-C", str(b), "-t", "commands", "sysroot"], capture_output=True, text=True,
                       check=True)
    (b / "commands.txt").write_text(r.stdout)
    r = subprocess.run(offline + ["ninja", "-C", str(b), "sysroot"], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"{name}: ninja sysroot failed: {r.stdout[-800:]}")
    return b


def parse(name: str, b: Path, src: Path, scratch: Path, builtins: Path) -> dict:
    stub = str(scratch / f"stub-{name}")
    sysroot = str(b / "sysroot")
    tmp_rd = str(b / "temp-resource-dir")

    def tp(p: str) -> str:
        """An absolute or build-relative path as a template."""
        if not os.path.isabs(p):
            p = str(b / p)
        p = os.path.normpath(p)
        for base, t in ((str(src), "{src}"), (sysroot, "{sysroot}"), (stub, "{sysroot}"),
                        (tmp_rd + "/lib", "{sysroot}/compiler-rt/lib"), (str(b), "{build}")):
            if p == base or p.startswith(base + "/"):
                return t + p[len(base):]
        die(f"{name}: path {p} outside src/build")

    def flags(toks: list[str]) -> list[str]:
        out, i = [], 0
        while i < len(toks):
            t = toks[i]
            if t in ("-MT", "-MF", "-o", "-resource-dir"):
                i += 2
                continue
            if t in ("-MD", "-c") or t.startswith(("--target=", "--sysroot=")):
                i += 1
                continue
            if t.startswith("-W") and not t.startswith(("-Wa,", "-Wl,", "-Wp,")):
                i += 1
                continue
            if t.startswith("-I") and len(t) > 2:
                out.append("-I" + tp(t[2:]))
            elif t in ("-I", "-isystem", "-include", "-iquote"):
                out += [t, tp(toks[i + 1])]
                i += 1
            elif t.startswith("-Wl,--allow-undefined-file="):
                out.append("-Wl,--allow-undefined-file=" + tp(t.split("=", 1)[1]))
            elif t.endswith("libclang_rt.builtins.a"):
                out.append("{sysroot}/compiler-rt/lib/" + TARGETS[name] + "/libclang_rt.builtins.a")
            else:
                out.append(t)
            i += 1
        return out

    compiles, archives, links, headers, install, empty = [], [], [], {}, {}, []
    for line in (b / "commands.txt").read_text().splitlines():
        if line.startswith(": && "):
            line = line[5:]
        if line.endswith(" && :"):
            line = line[:-5]
        parts = [p.strip() for p in line.split(" && ")]
        if parts[0].startswith("cd "):
            parts = parts[1:]
        p0 = shlex.split(parts[0])
        if p0[0].endswith("/clang") and "-c" in p0:
            o, s = p0[p0.index("-o") + 1], p0[p0.index("-c") + 1]
            lang = {"c": "c", "s": "asm", "S": "asm"}[s.rsplit(".", 1)[1]]
            compiles.append({"source": tp(s), "obj": o, "lang": lang,
                             "flags": flags([t for t in p0[1:] if t != s])})
        elif p0[0].endswith("/clang") and "-shared" in p0:
            # The link runs as the wasm-ld command clang would run (`-###`): a kcc link step
            # injects the Kairo runtime, so the generator links with its own lld.
            o = p0[p0.index("-o") + 1]
            objs = [t for t in p0 if t.endswith(".obj")]
            r = subprocess.run(p0 + ["-###"], cwd=b, capture_output=True, text=True)
            ld = shlex.split(r.stderr.strip().splitlines()[-1])
            if not ld[0].endswith("wasm-ld"):
                die(f"{name}: {o}: clang -### ran {ld[0]}")
            args, seen = [], False
            i = 1
            while i < len(ld):
                x = ld[i]
                if x == "-o":
                    i += 2
                    continue
                if x in objs:
                    if not seen:
                        args.append("{members}")
                        seen = True
                elif x.startswith("-L"):
                    args.append("-L" + tp(x[2:]))
                elif x.startswith("--allow-undefined-file="):
                    args.append("--allow-undefined-file=" + tp(x.split("=", 1)[1]))
                elif os.path.isabs(x) or "/" in x:
                    args.append(tp(x))
                else:
                    args.append(x)
                i += 1
            if not seen or [x for x in ld if x in objs] != objs:
                die(f"{name}: {o}: members not one ordered run in the wasm-ld line")
            links.append({"out": o, "ld": args, "members": objs})
        elif p0[:3] == ["/usr/bin/cmake", "-E", "rm"] or (p0[0].endswith("cmake") and p0[1:3] == ["-E", "rm"]):
            a = shlex.split(parts[1])
            if a[1:3] != ["--format=gnu", "qc"]:
                die(f"{name}: archive {parts[1][:120]}")
            archives.append({"out": a[3], "members": a[4:]})
        elif p0[0].endswith("cmake") and p0[1:3] == ["-E", "copy"]:
            s, d = p0[3], p0[4]
            if d.startswith(tmp_rd):
                continue                        # builtins into the temp resource dir: {sysroot}/compiler-rt
            rel = os.path.relpath(d, sysroot)
            if s.startswith(str(src) + "/"):
                headers[rel] = "src:" + os.path.relpath(s, src)
            else:
                sb = os.path.relpath(s, b)
                if sb.startswith("sysroot/"):   # crt1.o = a copy of crt1-command.o
                    sb = install.get(sb[len("sysroot/"):], sb)
                install[rel] = sb
        elif p0[0].endswith("cmake") and p0[1:3] == ["-E", "make_directory"]:
            rest = parts[1] if len(parts) > 1 else ""
            r = shlex.split(rest) if rest else []
            if r and r[0].endswith("llvm-ar") and r[1] == "crs":
                empty.append(os.path.relpath(r[2], sysroot))
            elif r and r[0].endswith("sed"):
                out = rest.split(" > ")[1].strip()
                headers[os.path.relpath(out, sysroot)] = "gen:" + os.path.relpath(out, sysroot)
            else:
                die(f"{name}: unhandled {line[:200]}")
        else:
            die(f"{name}: unhandled {line[:200]}")
    # configure_file outputs: in the built sysroot, produced by no command
    for d, _, fs in os.walk(b / "sysroot"):
        for f in fs:
            rel = os.path.relpath(os.path.join(d, f), b / "sysroot")
            if rel not in headers and rel not in install and rel not in empty:
                if not rel.startswith("include/"):
                    die(f"{name}: {rel} in the built sysroot comes from no command")
                headers[rel] = "gen:" + rel
    return {"compiles": compiles, "archives": archives, "links": links, "headers": headers,
            "install": install, "empty": empty}


def common_prefix(lists):
    if not lists:
        return []
    p = list(lists[0])
    for l in lists[1:]:
        n = 0
        while n < len(p) and n < len(l) and p[n] == l[n]:
            n += 1
        p = p[:n]
    return p


def write_target(out: Path, name: str, t: dict, b: Path) -> None:
    L = [f"# wasi-libc {TAG} for {name}: generated by Scripts/wasi_libc_recipe.py from CMake +",
         "# `ninja -t commands sysroot`; do not edit. Format: build/sysroot-share/FORMAT.md, \"wasi-libc\".",
         f"name         = {q(name)}", f"clang_triple = {q(TARGETS[name])}",
         f"empty        = {arr(sorted(t['empty']))}   # root paths of empty archives (llvm-ar crs)", ""]
    L += ["[headers]                       # root path = src:<src path> | gen:<name>/<path>"]
    for k in sorted(t["headers"], key=str.encode):
        v = t["headers"][k]
        if v.startswith("gen:"):
            g = out / "gen" / name / v[4:]
            g.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(b / "sysroot" / v[4:], g)
            v = f"gen:{name}/{v[4:]}"
        L.append(f"{q(k)} = {q(v)}")
    fl = {}
    for lang in ("c", "asm"):
        xs = [c["flags"] for c in t["compiles"] if c["lang"] == lang]
        if xs:
            fl[lang] = common_prefix(xs)
    L += ["", "[flags]"] + [f"{k:<3} = {arr(v)}" for k, v in fl.items()]
    groups = {}
    for c in t["compiles"]:
        groups.setdefault((c["lang"], tuple(c["flags"][len(fl[c["lang"]]):])), []).append(c)
    for i, ((lang, rest), cs) in enumerate(sorted(groups.items())):
        L += ["", f"[group.g{i:03d}]", f"lang    = {q(lang)}", f"flags   = {arr(rest)}",
              "sources = " + arr(f"{c['source']}={c['obj']}" for c in sorted(cs, key=lambda c: c["obj"]))]
    for i, a in enumerate(t["archives"]):
        L += ["", f"[archive.a{i:03d}]", f"out     = {q(a['out'])}", f"members = {arr(a['members'])}"]
    for i, l in enumerate(t["links"]):
        L += ["", f"[link.l{i:02d}]", f"out     = {q(l['out'])}", f"ld      = {arr(l['ld'])}",
              f"members = {arr(l['members'])}"]
    L += ["", "[install]                       # root path = {build} path (into {sysroot} too, see FORMAT)"]
    L += [f"{q(k)} = {q(v)}" for k, v in sorted(t["install"].items(), key=lambda kv: kv[0].encode())]
    (out / f"{name}.toml").write_text("\n".join(L) + "\n")


def derive(share: Path, scratch: Path, kit: Path, builtins: Path) -> dict:
    src = source(scratch)
    out = share / "wasi-libc"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    res = {}
    for name in TARGETS:
        b = configure_and_build(name, src, scratch, kit, builtins)
        t = parse(name, b, src, scratch, builtins)
        write_target(out, name, t, b)
        res[name] = (t, b)
        log(f"{name}: {len(t['headers'])} headers, {len(t['compiles'])} compiles, {len(t['archives'])} archives, "
            f"{len(t['links'])} links, {len(t['install'])} installed + {len(t['empty'])} empty")
    (out / "index.toml").write_text(
        "# wasi-libc from source; generated by Scripts/wasi_libc_recipe.py. Format: FORMAT.md, \"wasi-libc\".\n"
        'schema   = "1"\n'
        f'revision = "{commit()}"   # tag {TAG}\n'
        f"targets  = {arr(list(TARGETS))}\n")
    return res


def ship_src(share: Path, src: Path, files: set[str]) -> None:
    out = share / "wasi-libc" / "src"
    if out.exists():
        shutil.rmtree(out)
    for r in sorted(files):
        (out / r).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src / r, out / r)


def make_all(share: Path, scratch: Path, tree: Path, jobs: int = 16) -> None:
    import build_wasi_libc_direct as run
    import runtimes_recipe
    kit = runtimes_recipe.make_kit(tree, scratch / "kit")
    builtins = next((ROOT / "build" / "x86_64-linux-gnu" / "release" / "sysroot" / "wasm32-wasi" /
                     "compiler-rt" / "lib").glob("*/libclang_rt.builtins.a"))
    res = derive(share, scratch, kit, builtins)
    src = source(scratch)
    files = set()
    for name, (t, b) in res.items():
        work = scratch / "ref" / f"{name}.work"
        run.build(share, name, scratch / "ref" / name, kit, work, builtins, jobs, deps=True, src=src)
        files |= run.deps_files(work, src)
        files |= {v[4:] for v in t["headers"].values() if v.startswith("src:")}
        files |= {c["source"][6:] for c in t["compiles"] if c["source"].startswith("{src}/")}
        for l in t["links"]:
            files |= {f.split("{src}/", 1)[1] for f in l["ld"] if "{src}/" in f}
        shutil.rmtree(work)
        shutil.rmtree(b)
    ship_src(share, src, files)


def provenance() -> list[str]:
    return [f"src/: Lib/libc/wasi at tag {TAG} ({commit()[:12]}; git archive), only the sources the table "
            "compiles, the headers it installs and those a reference build read (-MD)",
            "wasm32-wasi.toml: CMake (TARGET_TRIPLE=wasm32-wasi, WASI_SDK_VERSION=" + SDK_VERSION + ", Release, "
            "BINDINGS_TARGET=OFF, BUILTINS_LIB = the curated root's wasm builtins, configured offline) + "
            "`ninja -t commands sysroot`, parsed: compiles, archives, -shared links, header copies, installs",
            "gen/: bits/alltypes.h (mkalltypes.sed) and wasi/version.h (configure_file) from an offline ninja build"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--share", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--scratch", type=Path, default=ROOT / "build" / "sysgen" / "z1" / "wasi-libc")
    ap.add_argument("--tree", type=Path, default=ROOT / "build" / "relcand")
    a = ap.parse_args()
    make_all(a.share.resolve(), a.scratch.resolve(), a.tree.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
