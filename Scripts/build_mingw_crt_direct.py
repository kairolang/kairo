#!/usr/bin/env python3
"""Build a MinGW root's mingw-w64-crt (crt objects + every lib*.a) from the shipped sources.

    python3 Scripts/build_mingw_crt_direct.py x86_64 --out DIR            # DIR/lib/...
    python3 Scripts/build_mingw_crt_direct.py armv7 --out DIR --sysroot <libc-headers root> -j 16

The reference runner for share/kairo/sysroot/mingw-crt/ (build/sysroot-share/FORMAT.md,
"mingw-crt"; made by Scripts/mingw_crt_recipe.py). Stdlib Python; ksys ports these steps:

  1. read mingw-crt/<arch>.toml;
  2. materialise {build}: every [files] entry, `gen:<arch>/<path>` = mingw-crt/gen/<arch>/<path>;
  3. preprocess every [def.*] (independent of each other and of the compiles):
        kcc --target=<clang_triple> --sysroot=<libc headers> -E -P -x c <flags> -Wp,-w <source>
     to {build}/<out>; strip_at = true drops a trailing @N from each line's first word
     (`sed -E 's/^([^ ]+)@[0-9]+( |\\r?$)/\\1\\2/'`, the Makefile's i686-free stdcall strip);
  4. compile every [group.*] entry, all in one parallel pool:
        kcc --target=<clang_triple> --sysroot=<libc headers> <[flags].<lang>> <group flags>
            -ffile-prefix-map=<src>=mingw-w64-crt -ffile-prefix-map=<build>=kairo-work
            -c <source> -o {build}/<obj>
     an entry is `<source>=<obj>`, <source> a {src}/ or {build}/ template;
  5. archive, in [archive.*] order (later ones merge earlier ones): delete <out>; with `def`,
     start from the import library `dlltool -m <dlltool_machine> -k -d <def> -l <out>`;
     then append `members` ({build}-relative objects) in order; `addlib` = the members of each
     listed archive in order, duplicates kept (llvm-ar -M ADDLIB). Then a symbol table;
  6. install: every [install] "<root path>" = "<{build} path>" copied (crt2.o and crt1.o, or
     libmsvcrt.a and libucrt.a, are the same file under two names: the Makefile's cp).

Templates: {src} = mingw-crt/src, {build} = the work dir, {sysroot} = the libc-headers root
(also --sysroot; its include/ is the mingw headers). The headers root must hold NO libc++
headers, and kcc must come from a prefix without sysroot/<target> (P610): by default the
kit Scripts/runtimes_recipe.py make_kit() makes under build/sysgen/z1/kit.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
STRIP_AT = re.compile(r"^([^ ]+)@[0-9]+( |\r?$)")


def log(m: str) -> None:
    print(f"[mingw-crt-direct] {m}", flush=True)


def die(m: str) -> None:
    print(f"[mingw-crt-direct] error: {m}", file=sys.stderr, flush=True)
    sys.exit(1)


def header_stage(share: Path, arch: str, dst: Path) -> Path:
    """mingw/include + the recipe's rendered SYSROOT.toml: what kcc compiles the crt against."""
    import ship_sysroot_inputs as ship
    rec = ship.load_recipe(ship.FAMILIES["mingw"])
    env = ship.target_env(rec, arch)
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    shutil.copytree(share / "mingw" / "include", dst / "include")
    (dst / "SYSROOT.toml").write_text(ship.render_toml(rec, env))
    return dst


def build(share: Path, arch: str, out: Path, sysroot: Path, kit: Path, work: Path, jobs: int,
          deps: bool = False, src: Path | None = None) -> dict:
    """`src` overrides mingw-crt/src (the derivation builds from the full checkout to learn
    which files src/ must hold)."""
    t = tomllib.loads((share / "mingw-crt" / f"{arch}.toml").read_text())
    src = src or share / "mingw-crt" / "src"
    kcc, ar = str(kit / "bin" / "kcc"), str(kit / "bin" / "llvm-ar")
    dlltool = shutil.which("llvm-dlltool") or str(ROOT / "build" / "llvm" / "bin" / "llvm-dlltool")
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    env = {"src": str(src), "build": str(work), "sysroot": str(sysroot)}
    sub = lambda s: re.sub(r"\{(src|build|sysroot)\}", lambda m: env[m.group(1)], s)
    for rel, ref in t.get("files", {}).items():
        kind, path = ref.split(":", 1)
        if kind != "gen":
            die(f"[files] {rel}: unknown kind {kind}")
        (work / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(share / "mingw-crt" / "gen" / path, work / rel)
    base = [kcc, f"--target={t['clang_triple']}", f"--sysroot={sysroot}"]
    jobs_list = []
    for d in t.get("def", {}).values():
        jobs_list.append(("def", d))
    for g in t.get("group", {}).values():
        for e in g["sources"]:
            s, o = e.split("=", 1)
            jobs_list.append(("cc", (g, s, o)))

    def run(job):
        kind, x = job
        if kind == "def":
            o = work / x["out"]
            o.parent.mkdir(parents=True, exist_ok=True)
            dep = ["-MD", "-MF", str(o) + ".d"] if deps else []    # .def.in files #include their neighbours
            r = subprocess.run(base + ["-E", "-P", "-x", "c", *map(sub, x["flags"]), "-Wp,-w", *dep, sub(x["source"])],
                               capture_output=True, text=True)
            if r.returncode != 0:
                return f"{x['source']}: {r.stderr.strip().splitlines()[:1]}"
            text = r.stdout
            if x["strip_at"]:
                text = "\n".join(STRIP_AT.sub(r"\1\2", l) for l in text.split("\n"))
            o.write_text(text)
            return None
        g, s, o = x
        (work / o).parent.mkdir(parents=True, exist_ok=True)
        cmd = base + [*map(sub, t["flags"][g["lang"]]), *map(sub, g["flags"]),
                      f"-ffile-prefix-map={src}=mingw-w64-crt", f"-ffile-prefix-map={work}=kairo-work",
                      "-c", sub(s), "-o", str(work / o)]
        if deps:
            cmd += ["-MD", "-MF", str(work / (o + ".d"))]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            return f"{s}: {r.stderr.strip()[:600]}"
        return None

    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        errs = [e for e in ex.map(run, jobs_list) if e]
    if errs:
        die(f"{arch}: {len(errs)} failed; first: {errs[0]}")
    t1 = time.time()
    for a in t.get("archive", {}).values():  # table order: a0000, a0001, ... (merges after their inputs)
        o = work / a["out"]
        o.parent.mkdir(parents=True, exist_ok=True)
        o.unlink(missing_ok=True)
        if "def" in a:
            r = subprocess.run([dlltool, "-m", t["dlltool_machine"], *t["dlltool_flags"], "-d", sub(a["def"]),
                                "-l", str(o)], capture_output=True, text=True)
            if r.returncode != 0:
                die(f"{a['out']}: dlltool: {r.stderr.strip()[:300]}")
        if a.get("members"):
            subprocess.run([ar, "qc", str(o), *[str(work / m) for m in a["members"]]], check=True)
        if a.get("addlib"):
            mri = "CREATE " + str(o) + "\n" + "".join(f"ADDLIB {work / x}\n" for x in a["addlib"]) + "SAVE\nEND\n"
            subprocess.run([ar, "-M"], input=mri, text=True, check=True)
        if not o.exists():                 # an import lib whose def exports nothing, never ar'd
            subprocess.run([ar, "qc", str(o)], check=True)
        subprocess.run([ar, "s", str(o)], check=True)
    for dst, s in t["install"].items():
        (out / dst).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(work / s, out / dst)
    t2 = time.time()
    log(f"{arch}: {len(jobs_list)} cpp/compiles in {t1 - t0:.1f}s, {len(t['archive'])} archives + "
        f"{len(t['install'])} installed in {t2 - t1:.1f}s")
    return t


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("arch")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--share", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--sysroot", type=Path, help="libc-headers root (default: one made from mingw/include)")
    ap.add_argument("--kit", type=Path, default=ROOT / "build" / "sysgen" / "z1" / "kit")
    ap.add_argument("--tree", type=Path, default=ROOT / "build" / "relcand",
                    help="toolchain the kit links its kcc / llvm-ar from")
    ap.add_argument("--work", type=Path)
    ap.add_argument("--deps", action="store_true", help="also write <obj>.d (Scripts/mingw_crt_recipe.py src/)")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()
    import runtimes_recipe
    kit = runtimes_recipe.make_kit(a.tree.resolve(), a.kit.resolve())
    out = a.out.resolve()
    work = (a.work or out.parent / f"{out.name}.work").resolve()
    sysroot = a.sysroot.resolve() if a.sysroot else header_stage(a.share.resolve(), a.arch, work.parent / f"{out.name}.hdr")
    build(a.share.resolve(), a.arch, out, sysroot, kit, work, a.jobs, a.deps)
    return 0


if __name__ == "__main__":
    sys.exit(main())
