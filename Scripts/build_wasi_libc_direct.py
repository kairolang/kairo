#!/usr/bin/env python3
"""Build wasi-libc (headers, crt1*.o, every archive and shared lib) from the shipped sources.

    python3 Scripts/build_wasi_libc_direct.py wasm32-wasi --out DIR      # DIR/include, DIR/lib
    python3 Scripts/build_wasi_libc_direct.py wasm32-wasi --out DIR --builtins <libclang_rt.builtins.a>

The reference runner for share/kairo/sysroot/wasi-libc/ (build/sysroot-share/FORMAT.md,
"wasi-libc"; made by Scripts/wasi_libc_recipe.py). Stdlib Python; ksys ports these steps:

  1. read wasi-libc/<name>.toml;
  2. lay out {sysroot} = {build}/sysroot: every [headers] entry (`src:` from wasi-libc/src,
     `gen:` from wasi-libc/gen), the target's rendered SYSROOT.toml, and the builtins
     archive at compiler-rt/lib/<clang_triple>/libclang_rt.builtins.a (the builtins stage's
     product: libc.so links it explicitly, the other shared libs through kcc's resource dir);
  3. compile every [group.*] entry in one parallel pool:
        kcc --target=<clang_triple> --sysroot={sysroot} <[flags].<lang>> <group flags>
            -ffile-prefix-map=<src>=wasi-libc -ffile-prefix-map=<build>=kairo-work
            -c <source> -o {build}/<obj>
  4. archive every [archive.*] (`llvm-ar --format=gnu qc` + symbol table), write each
     `empty` archive, and copy every [install] entry whose source now exists into {sysroot};
  5. link every [link.*] in order with wasm-ld (ksys: its lld, `kld -flavor wasm`; NOT a kcc
     link, which injects the Kairo runtime): `ld` with {members} replaced by the members
     ({build}-relative, in order), then `-o {build}/<out>`; install it into {sysroot} at once
     (later links take -lc and crt1-reactor.o from there);
  6. the product root is {sysroot}'s include/ and lib/ (not its SYSROOT.toml or compiler-rt/).
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


def log(m: str) -> None:
    print(f"[wasi-libc-direct] {m}", flush=True)


def die(m: str) -> None:
    print(f"[wasi-libc-direct] error: {m}", file=sys.stderr, flush=True)
    sys.exit(1)


def deps_files(work: Path, src: Path) -> set[str]:
    src = Path(os.path.realpath(src))
    out = set()
    for d, _, fs in os.walk(work):
        for f in fs:
            if f.endswith(".d"):
                txt = Path(d, f).read_text().replace("\\\n", " ")
                for tok in txt.split(":", 1)[1].split():
                    p = Path(os.path.realpath(tok if os.path.isabs(tok) else os.path.join(work, tok)))
                    if str(p).startswith(str(src) + os.sep):
                        out.add(p.relative_to(src).as_posix())
    return out


def build(share: Path, name: str, out: Path, kit: Path, work: Path, builtins: Path, jobs: int,
          deps: bool = False, src: Path | None = None, wasm_ld: Path | None = None) -> dict:
    import ship_sysroot_inputs as ship
    t = tomllib.loads((share / "wasi-libc" / f"{name}.toml").read_text())
    src = src or share / "wasi-libc" / "src"
    kcc, ar = str(kit / "bin" / "kcc"), str(kit / "bin" / "llvm-ar")
    wasm_ld = str(wasm_ld or ROOT / "build" / "relcand" / "bin" / "wasm-ld")
    if work.exists():
        shutil.rmtree(work)
    sysroot = work / "sysroot"
    sysroot.mkdir(parents=True)
    env = {"src": str(src), "build": str(work), "sysroot": str(sysroot)}
    sub = lambda s: re.sub(r"\{(src|build|sysroot)\}", lambda m: env[m.group(1)], s)
    for rel, ref in t["headers"].items():
        kind, p = ref.split(":", 1)
        s = src / p if kind == "src" else share / "wasi-libc" / "gen" / p
        (sysroot / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(s, sysroot / rel)
    rec = ship.load_recipe(ship.FAMILIES["wasi"])
    (sysroot / "SYSROOT.toml").write_text(ship.render_toml(rec, ship.target_env(rec, name.split("-")[0])))
    rt = sysroot / "compiler-rt" / "lib" / t["clang_triple"] / "libclang_rt.builtins.a"
    rt.parent.mkdir(parents=True)
    shutil.copyfile(builtins, rt)
    base = [kcc, f"--target={t['clang_triple']}", f"--sysroot={sysroot}"]
    jobs_list = [(g, *e.split("=", 1)) for g in t["group"].values() for e in g["sources"]]

    def cc(job):
        g, s, o = job
        (work / o).parent.mkdir(parents=True, exist_ok=True)
        cmd = base + [*map(sub, t["flags"][g["lang"]]), *map(sub, g["flags"]),
                      f"-ffile-prefix-map={src}=wasi-libc", f"-ffile-prefix-map={work}=kairo-work",
                      "-c", sub(s), "-o", str(work / o)]
        if deps:
            cmd += ["-MD", "-MF", str(work / (o + ".d"))]
        r = subprocess.run(cmd, capture_output=True, text=True)
        return None if r.returncode == 0 else f"{s}: {r.stderr.strip()[:600]}"

    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        errs = [e for e in ex.map(cc, jobs_list) if e]
    if errs:
        die(f"{name}: {len(errs)} compiles failed; first: {errs[0]}")
    t1 = time.time()
    for a in t.get("archive", {}).values():
        o = work / a["out"]
        o.unlink(missing_ok=True)
        subprocess.run([ar, "--format=gnu", "qc", str(o), *[str(work / m) for m in a["members"]]], check=True)
        subprocess.run([ar, "s", str(o)], check=True)
    for e in t.get("empty", []):
        (sysroot / e).parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([ar, "crs", str(sysroot / e)], check=True)

    def install_ready():
        for dst, s in t["install"].items():
            if (work / s).is_file() and not (sysroot / dst).exists():
                (sysroot / dst).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(work / s, sysroot / dst)

    install_ready()
    for l in t.get("link", {}).values():
        o = work / l["out"]
        o.parent.mkdir(parents=True, exist_ok=True)
        args = []
        for x in l["ld"]:
            args += [str(work / m) for m in l["members"]] if x == "{members}" else [sub(x)]
        r = subprocess.run([wasm_ld, *args, "-o", str(o)], capture_output=True, text=True)
        if r.returncode != 0:
            die(f"{l['out']}: link failed: {r.stderr.strip()[:800]}")
        install_ready()
    missing = [d for d in t["install"] if not (sysroot / d).is_file()]
    if missing:
        die(f"{name}: never built: {missing[:5]}")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for d in ("include", "lib"):
        shutil.copytree(sysroot / d, out / d)
    log(f"{name}: {len(jobs_list)} compiles in {t1 - t0:.1f}s, {len(t.get('archive', {}))} archives + "
        f"{len(t.get('link', {}))} links in {time.time() - t1:.1f}s")
    return t


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("name")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--share", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("--builtins", type=Path, help="wasm builtins archive (default: the curated root's)")
    ap.add_argument("--kit", type=Path, default=ROOT / "build" / "sysgen" / "z1" / "kit")
    ap.add_argument("--tree", type=Path, default=ROOT / "build" / "relcand")
    ap.add_argument("--work", type=Path)
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()
    import runtimes_recipe
    kit = runtimes_recipe.make_kit(a.tree.resolve(), a.kit.resolve())
    builtins = a.builtins or next((ROOT / "build/x86_64-linux-gnu/release/sysroot/wasm32-wasi/compiler-rt/lib")
                                  .glob("*/libclang_rt.builtins.a"))
    out = a.out.resolve()
    build(a.share.resolve(), a.name, out, kit, (a.work or out.parent / f"{out.name}.work").resolve(),
          builtins.resolve(), a.jobs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
