#!/usr/bin/env python3
"""Build a target's LLVM runtimes with direct kcc compiles: no CMake, no ninja.

    python3 Scripts/build_runtimes_direct.py x86_64-linux-musl --out build/sysgen/b2/out/x86_64-linux-musl
    python3 Scripts/build_runtimes_direct.py aarch64-unknown-freebsd --out DIR --sysroot <libc-headers stage> -j 16

The reference runner for share/kairo/sysroot/runtimes-recipe/ (FORMAT.md, "runtimes-recipe";
made by Scripts/runtimes_recipe.py). ksys (Linker/Sysroot/) ports exactly these steps:

  1. read targets/<name>.toml (index.toml lists the names): one recipe key per runtime
     (builtins, crt, libunwind, libcxxabi, libcxx), the build-tree and header manifests,
     and where every archive ([archives]) and loose object ([objects]) lands in the root;
  2. materialise the build tree ({build}): every `[files]` entry of build/<key>.toml, copied
     from the runtimes source (`src:`) or from build/<key>/ (`gen:`); the compiles include
     {build}/include/c++/v1 (libc++'s generated headers + libc++abi's);
  3. compile every source of every runtime, all in one parallel pool (compile-only: no
     runtime needs another's objects, only headers, and those are in place after step 2):
        kcc --target=<clang_triple> --sysroot=<libc headers> <[flags].<lang>> <group flags>
            -c {src}/<source> -o <work>/obj/<runtime>/<member>
     <member> is the source's file name + ".o" unless the entry says `<source>=<member>`;
  4. archive: `llvm-ar qc <archive> <members in index order>` then `llvm-ar s`
     (CMake's own <CMAKE_AR> qc + <CMAKE_RANLIB>), loose objects copied (crtbegin/crtend);
  5. install the c++/v1 headers: headers/<key>.toml [files] into <headers_dest>.

Templates in flags: {src} the runtimes source, {build} the materialised build tree,
{sysroot} the libc-headers root (also passed as --sysroot), {share} the share tree.

--sysroot MUST name a root with libc headers and NO libc++ headers (kcc puts the root's
include/c++/v1 on the path ahead of libc). Without --sysroot the runner makes one from the
curated root of the same name (Scripts/runtimes_recipe.py header_stage). kcc must be a
build whose prefix has no sysroot/<target> (kcc prefers that over --sysroot): by default
the kit Scripts/runtimes_recipe.py makes under build/sysgen/b2/kit.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))

COMPILED = ("builtins", "crt", "libunwind", "libcxxabi", "libcxx")


def log(m: str) -> None:
    print(f"[runtimes-direct] {m}", flush=True)


def die(m: str) -> None:
    print(f"[runtimes-direct] error: {m}", file=sys.stderr, flush=True)
    sys.exit(1)


def expand(s: str, env: dict) -> str:
    for k, v in env.items():
        s = s.replace("{" + k + "}", v)
    return s


def split_entry(ent: str) -> tuple[str, str]:
    """"<source>" or "<source>=<member>" -> (source, member)."""
    if "=" in ent:
        s, m = ent.split("=", 1)
        return s, m
    return ent, ent.rsplit("/", 1)[-1] + ".o"


def materialise(manifest: Path, gen_dir: Path, src: Path, dst: Path) -> int:
    files = tomllib.loads(manifest.read_text())["files"]
    for rel, how in files.items():
        p = dst / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        kind, v = how.split(":", 1)
        shutil.copyfile(src / v if kind == "src" else gen_dir / v, p)
    return len(files)


def plan(rec: Path, ent: dict, env: dict, work: Path, sysroot: Path, triple: str, kcc: str,
         extra: list) -> list:
    jobs = []
    for rt in COMPILED:
        if rt not in ent:
            continue
        t = tomllib.loads((rec / rt / f"{ent[rt]}.toml").read_text())
        common = t.get("flags", {})
        od = work / "obj" / rt
        od.mkdir(parents=True, exist_ok=True)
        for g in t.get("group", {}).values():
            fl = [expand(x, env) for x in common.get(g["lang"], []) + g["flags"]]
            for e in g["sources"]:
                s, m = split_entry(e)
                cmd = [kcc, f"--target={triple}", f"--sysroot={sysroot}", *fl, *extra,
                       "-c", str(Path(env["src"]) / s), "-o", str(od / m)]
                jobs.append((rt, m, cmd))
    return jobs


def run(cmd: list) -> tuple[int, str]:
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr)


def build(name: str, share: Path, src: Path, out: Path, sysroot: Path | None, kcc: Path, ar: Path,
          work: Path, jobs: int, curated: Path) -> dict:
    rec = share / "runtimes-recipe"
    names = tomllib.loads((rec / "index.toml").read_text())["targets"]
    if name not in names:
        die(f"no runtimes recipe for {name} (have: {', '.join(names)})")
    ent = tomllib.loads((rec / "targets" / f"{name}.toml").read_text())
    t0 = time.monotonic()
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    if sysroot is None:
        import runtimes_recipe as rr
        import ship_sysroot_inputs as ship
        tgt = [t for t in rr.all_targets(ship, [name])][0]
        sysroot = rr.header_stage(curated, tgt, work / "sysroot")
    env = {"src": str(src), "build": str(work / "build"), "sysroot": str(sysroot), "share": str(share)}
    # 2. build tree
    nb = 0
    if "build" in ent:
        nb = materialise(rec / "build" / f"{ent['build']}.toml", rec / "build" / ent["build"], src,
                         work / "build")
    # 3. compiles. The prefix maps keep the build machine's paths out of the objects
    # (libc++abi asserts embed __FILE__) and make a rebuild comparable byte for byte.
    extra = [f"-ffile-prefix-map={src}=kairo-runtimes", f"-ffile-prefix-map={work}=kairo-work"]
    js = plan(rec, ent, env, work, sysroot, ent["clang_triple"], str(kcc), extra)
    t1 = time.monotonic()
    fails = []
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for (rt, m, cmd), (rc, outp) in zip(js, ex.map(lambda j: run(j[2]), js)):
            if rc:
                fails.append((rt, m, cmd, outp))
    t2 = time.monotonic()
    if fails:
        for rt, m, cmd, outp in fails[:5]:
            print(f"--- {rt}/{m}\n$ {' '.join(cmd)}\n{outp[-3000:]}", file=sys.stderr)
        die(f"{name}: {len(fails)} of {len(js)} compiles failed")
    # 4. archives + loose objects
    def obj(ref: str) -> Path:
        rt, e = ref.split(":", 1)
        return work / "obj" / rt / split_entry(e)[1]
    for dest, members in ent.get("archives", {}).items():
        p = out / dest
        p.parent.mkdir(parents=True, exist_ok=True)
        p.unlink(missing_ok=True)
        r = subprocess.run([str(ar), "qc", str(p), *[str(obj(m)) for m in members]],
                           capture_output=True, text=True)
        if r.returncode:
            die(f"llvm-ar {dest}: {r.stderr}")
        subprocess.run([str(ar), "s", str(p)], check=True)
    for dest, ref in ent.get("objects", {}).items():
        p = out / dest
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(obj(ref), p)
    # 5. headers
    nh = 0
    if "headers" in ent:
        d = out / ent["headers_dest"]
        if d.exists():
            shutil.rmtree(d)
        nh = materialise(rec / "headers" / f"{ent['headers']}.toml", rec / "headers" / ent["headers"], src, d)
    t3 = time.monotonic()
    st = {"compiles": len(js), "build_files": nb, "headers": nh, "setup_s": round(t1 - t0, 1),
          "compile_s": round(t2 - t1, 1), "archive_s": round(t3 - t2, 1), "total_s": round(t3 - t0, 1)}
    log(f"{name}: {st}")
    return st


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("name", help="sysroot name, e.g. x86_64-linux-musl")
    ap.add_argument("--out", type=Path, required=True, help="root to write into (layout-relative paths)")
    ap.add_argument("--share", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--runtimes", type=Path, default=None,
                    help="LLVM runtimes source (default: <share>/runtimes, else <share>/../runtimes, "
                         "else build/sysgen/b2/rt/share/kairo/runtimes)")
    ap.add_argument("--sysroot", type=Path, default=None, help="libc-headers root (no c++/v1)")
    ap.add_argument("--curated", type=Path, default=ROOT / "build" / "x86_64-linux-gnu" / "release" / "sysroot")
    ap.add_argument("--kcc", type=Path, default=ROOT / "build" / "sysgen" / "b2" / "kit" / "bin" / "kcc")
    ap.add_argument("--ar", type=Path, default=None, help="llvm-ar (default: beside kcc)")
    ap.add_argument("--work", type=Path, default=None, help="scratch (default: build/sysgen/b2/work/<name>)")
    ap.add_argument("-j", type=int, default=max(1, min(os.cpu_count() or 4, 16)))
    a = ap.parse_args()
    share = a.share.resolve()
    src = a.runtimes
    if src is None:
        for c in (share / "runtimes", share.parent / "runtimes",
                  ROOT / "build" / "sysgen" / "b2" / "rt" / "share" / "kairo" / "runtimes"):
            if (c / "REVISION").is_file():
                src = c
                break
    if src is None:
        die("no runtimes source (pass --runtimes)")
    ar = a.ar or a.kcc.parent / "llvm-ar"
    work = (a.work or ROOT / "build" / "sysgen" / "b2" / "work" / a.name).resolve()
    build(a.name, share, src.resolve(), a.out.resolve(), a.sysroot.resolve() if a.sysroot else None,
          a.kcc.resolve(), ar.resolve(), work, a.j, a.curated.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
