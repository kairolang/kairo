#!/usr/bin/env python3
"""Build the prebuilt SDK overlays a release ships in share/kairo/sdk-overlays/.

    python3 Scripts/build_sdk_overlays.py --sdk-arm64 <MacOSX.sdk> --sdk-x86_64 <MacOSX.sdk> --xwin <splat>
    python3 Scripts/build_sdk_overlays.py --sdk <MacOSX.sdk> --xwin <splat>       # one universal SDK
    python3 Scripts/build_sdk_overlays.py --xwin <splat> --only msvc-x86_64      # a subset (others kept)
    python3 Scripts/build_sdk_overlays.py --check build/sdk-overlays             # allowlist check only

A macOS or MSVC root is two halves: the vendor's SDK (Apple's, Microsoft's), which
no Kairo archive may contain, and our half, libc++ and the compiler-rt builtins built
against it from the LLVM fork (Apache-2.0 WITH LLVM-exception, which may ship). An
overlay is our half alone, laid out like the root, so scripts/darwin-sysroot.sh and
scripts/msvc-sysroot.{sh,ps1} assemble a root from the user's SDK by copying instead
of a CMake build.

  darwin-arm64, darwin-x86_64       usr/include/c++/v1, usr/lib/libc++{,experimental}.a,
                                    usr/lib/libc++.modules.json, usr/share/libc++/v1,
                                    clang/lib/darwin/libclang_rt.osx.a
  msvc-x86_64, msvc-aarch64, msvc-i686
                                    include/c++/v1, lib/libc++.lib,
                                    compiler-rt/lib/windows/clang_rt.builtins-<arch>.lib
  REVISION                          the LLVM fork revision (= share/kairo/runtimes/REVISION)

The overlays are made by the release scripts themselves (--overlay-only DIR, their full
build path), so an overlay is byte for byte what the full build would put in a root.
They run from a throwaway kit: this host's release binaries, lib/, the scripts and the
curated runtimes source, and no sysroot/ (kcc prefers <install>/sysroot/<target>, and
the dev trees hold curated Apple/MSVC roots that would leak into the build).

Overlays are per TARGET, not per host: the output (build/sdk-overlays/ by default) is
the one canonical copy, which package_release.py copies into every host archive. It is
also linked into the --tree's share/kairo/sdk-overlays so that tree sees them.

arm64e is not built: kld cannot link it, so no overlay of it could be validated.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))

DARWIN = ("arm64", "x86_64")
MSVC = {"x86_64": "x86_64", "aarch64": "aarch64", "i686": "i386"}   # arch -> builtins name
ALL = [f"darwin-{a}" for a in DARWIN] + [f"msvc-{a}" for a in MSVC]

# Generated at install time, so they have no file of the same name in the source.
GENERATED_HEADERS = {"__assertion_handler", "libcxx.imp"}


def log(m: str) -> None:
    print(f"[sdk-overlays] {m}", flush=True)


def die(m: str) -> None:
    print(f"[sdk-overlays] FAIL: {m}", flush=True)
    sys.exit(1)


def _from_source(rel: str, *dirs: Path) -> bool:
    return any((d / rel).is_file() or (d / (rel + ".in")).is_file() for d in dirs)


def overlay_violations(ov: Path, runtimes: Path) -> list[str]:
    """Files in overlay dir `ov` (darwin-<arch> or msvc-<arch>) that are not ours.

    An ALLOWLIST: the exact archives the builds make, and headers/module sources only
    when the curated runtimes source (`runtimes`, share/kairo/runtimes) has the same
    file (or its .in template). An SDK header, a .tbd, an msvc/ tree, an Apple or
    Microsoft library, a symlink: anything else is a violation."""
    flavor, _, arch = ov.name.partition("-")
    cxx_inc = [runtimes / "libcxx" / "include", runtimes / "libcxxabi" / "include"]
    modules = runtimes / "libcxx" / "modules"
    if flavor == "darwin" and arch in DARWIN:
        inc, mods = "usr/include/c++/v1/", "usr/share/libc++/v1/"
        libs = {"usr/lib/libc++.a", "usr/lib/libc++experimental.a", "usr/lib/libc++.modules.json",
                "clang/lib/darwin/libclang_rt.osx.a"}
        need = {"usr/lib/libc++.a", "clang/lib/darwin/libclang_rt.osx.a", inc + "__config_site"}
    elif flavor == "msvc" and arch in MSVC:
        inc, mods = "include/c++/v1/", None
        libs = {"lib/libc++.lib", f"compiler-rt/lib/windows/clang_rt.builtins-{MSVC[arch]}.lib"}
        need = libs | {inc + "__config_site"}
    else:
        return [f"{ov.name}: not an overlay name (want one of {', '.join(ALL)})"]
    bad, seen = [], set()
    for p in sorted(ov.rglob("*")):
        rel = p.relative_to(ov).as_posix()
        if p.is_symlink():
            bad.append(f"{ov.name}/{rel}: symlink")
            continue
        if p.is_dir():
            continue
        seen.add(rel)
        if rel in libs:
            data = p.read_bytes()[:8]
            if rel.endswith((".a", ".lib")) and data != b"!<arch>\n":
                bad.append(f"{ov.name}/{rel}: not an ar archive")
            continue
        if rel.startswith(inc):
            h = rel[len(inc):]
            if h in GENERATED_HEADERS or _from_source(h, *cxx_inc):
                continue
        if mods and rel.startswith(mods) and _from_source(rel[len(mods):], modules):
            continue
        bad.append(f"{ov.name}/{rel}: not on the overlay allowlist (only our libc++/builtins may ship)")
    bad += [f"{ov.name}/{n}: missing" for n in sorted(need - seen)]
    return bad


def check_overlays(top: Path, runtimes: Path) -> list[str]:
    """Every entry of an sdk-overlays dir: REVISION plus known overlays, each clean."""
    errs = []
    for e in sorted(top.iterdir()):
        if e.name == "REVISION" and e.is_file():
            continue
        if not e.is_dir() or e.is_symlink():
            errs.append(f"{e.name}: unexpected entry in sdk-overlays")
            continue
        errs += overlay_violations(e, runtimes)
    if not (top / "REVISION").is_file():
        errs.append("REVISION: missing")
    return errs


def make_kit(tree: Path, kit: Path) -> None:
    """A minimal install the scripts can run from: bin (kcc, kld, llvm-ar and its
    aliases), lib (resource dir + Kairo libs: kcc links the Kairo runtime library),
    scripts/, share/kairo/runtimes. No sysroot/."""
    import package_release as pr
    shutil.rmtree(kit, ignore_errors=True)
    (kit / "bin").mkdir(parents=True)
    for t in ("kcc", "kld", "llvm-ar"):
        src = tree / "bin" / t
        if not src.is_file():
            die(f"{src} is missing (build the release tree first)")
        try:
            os.link(src.resolve(), kit / "bin" / t)    # 190 MB each; a hard link costs nothing
        except OSError:
            shutil.copy2(src, kit / "bin" / t)
    for a in ("llvm-ranlib", "llvm-lib"):
        os.symlink("llvm-ar", kit / "bin" / a)          # llvm-ar picks its mode by argv[0]
    (kit / "lib").mkdir()
    for d in ("clang", "builtin", "std", "rt"):
        shutil.copytree((tree / "lib" / d).resolve(), kit / "lib" / d, symlinks=False)
    pr.stage_scripts(kit)
    pr.stage_runtimes(kit)


def run_one(name: str, kit: Path, out: Path, sdk: dict[str, Path], xwin: Path | None,
            jobs: int, logs: Path) -> tuple[str, bool, float, str]:
    flavor, arch = name.split("-", 1)
    env = dict(os.environ, JOBS=str(jobs), WORK=str(kit / ".work" / name), OUT=str(kit / ".unused"))
    if flavor == "darwin":
        env["SDK"] = str(sdk[arch])
        cmd = [str(kit / "scripts" / "darwin-sysroot.sh"), "--overlay-only", str(out), arch]
    else:
        env["XWIN"] = str(xwin)
        cmd = [str(kit / "scripts" / "msvc-sysroot.sh"), "--overlay-only", str(out), arch]
    lg = logs / f"{name}.log"
    t0 = time.monotonic()
    with open(lg, "w") as fh:
        rc = subprocess.run(cmd, env=env, stdout=fh, stderr=subprocess.STDOUT).returncode
    tail = "" if rc == 0 else "".join(lg.read_text().splitlines(True)[-15:])
    return name, rc == 0, time.monotonic() - t0, tail


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tree", default=str(ROOT / "build" / "x86_64-linux-musl" / "release"),
                    help="release tree whose kcc/kld/llvm-ar build the overlays (default: x86_64-linux-musl)")
    ap.add_argument("--out", default=str(ROOT / "build" / "sdk-overlays"))
    ap.add_argument("--sdk", help="MacOSX.sdk for both darwin arches (a real SDK is universal)")
    ap.add_argument("--sdk-arm64")
    ap.add_argument("--sdk-x86_64")
    ap.add_argument("--xwin", help="xwin splat with x86_64, aarch64 and x86 libs")
    ap.add_argument("--only", action="append", choices=ALL, help="build only these (repeatable)")
    ap.add_argument("--jobs", type=int, default=0, help="compile jobs per build (default: CPUs / builds)")
    ap.add_argument("--check", metavar="DIR", help="only run the allowlist check on an sdk-overlays dir")
    a = ap.parse_args()

    if a.check:
        import package_release as pr
        kit = ROOT / "build" / ".sdk-overlays-kit"
        shutil.rmtree(kit, ignore_errors=True)
        kit.mkdir(parents=True)
        pr.stage_runtimes(kit)
        errs = check_overlays(Path(a.check), kit / "share" / "kairo" / "runtimes")
        shutil.rmtree(kit, ignore_errors=True)
        for e in errs:
            log(f"FAIL: {e}")
        return 1 if errs else 0

    want = a.only or ALL
    sdk = {"arm64": a.sdk_arm64 or a.sdk, "x86_64": a.sdk_x86_64 or a.sdk}
    for n in want:
        f, arch = n.split("-", 1)
        if f == "darwin" and not sdk[arch]:
            die(f"{n} needs --sdk or --sdk-{arch}")
        if f == "msvc" and not a.xwin:
            die(f"{n} needs --xwin")
    sdk = {k: Path(v).resolve() for k, v in sdk.items() if v}
    xwin = Path(a.xwin).resolve() if a.xwin else None
    tree = Path(a.tree).resolve()
    out = Path(a.out).resolve()
    kit = out.parent / ".sdk-overlays-kit"
    new = out.parent / (out.name + ".new")
    logs = out.parent / "sdk-overlays-logs"

    import package_release as pr
    rev = pr.runtimes_revision()
    log(f"kit from {tree} (runtimes rev {rev})")
    make_kit(tree, kit)
    shutil.rmtree(new, ignore_errors=True)
    new.mkdir(parents=True)
    # A partial rebuild (--only) keeps the other overlays, but only of the same revision.
    if a.only and out.is_dir():
        old_rev = (out / "REVISION").read_text().strip() if (out / "REVISION").is_file() else ""
        if old_rev != rev:
            die(f"{out} is rev {old_rev or '?'}, the runtimes are rev {rev}: rebuild all (drop --only)")
        for e in out.iterdir():
            if e.is_dir() and e.name not in want:
                shutil.copytree(e, new / e.name, symlinks=True)
    shutil.rmtree(logs, ignore_errors=True)
    logs.mkdir(parents=True)
    jobs = a.jobs or max(2, (os.cpu_count() or 8) // len(want))
    with concurrent.futures.ThreadPoolExecutor(len(want)) as ex:
        res = list(ex.map(lambda n: run_one(n, kit, new, sdk, xwin, jobs, logs), want))
    failed = False
    for name, ok, secs, tail in res:
        log(f"{name}: {'ok' if ok else 'FAILED'} in {secs:.0f} s (log {logs / (name + '.log')})")
        if not ok:
            failed = True
            print(tail, flush=True)
    if failed:
        die("an overlay build failed; nothing replaced")
    (new / "REVISION").write_text(rev + "\n")
    errs = check_overlays(new, kit / "share" / "kairo" / "runtimes")
    if errs:
        for e in errs:
            log(f"FAIL: {e}")
        die("an overlay holds something that is not ours; nothing replaced")
    shutil.rmtree(out, ignore_errors=True)
    new.rename(out)
    shutil.rmtree(kit, ignore_errors=True)
    # The tree sees the canonical copy (a link, so there is only ever one to go stale).
    link = tree / "share" / "kairo" / "sdk-overlays"
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() or link.is_file():
        link.unlink()
    elif link.is_dir():
        shutil.rmtree(link)
    os.symlink(os.path.relpath(out, link.parent), link)
    for e in sorted(out.iterdir()):
        if e.is_dir():
            size = sum(p.stat().st_size for p in e.rglob("*") if p.is_file())
            log(f"{e.name}: {size / (1 << 20):.1f} MiB")
    log(f"done: {out} (rev {rev}); linked from {link}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
