#!/usr/bin/env python3
"""Package built Stage 1.5 trees as release archives.

    python3 Scripts/package_release.py x86_64-linux-musl
    python3 Scripts/package_release.py --out build/ship/dist --work build/ship/work x86_64-linux-musl
    python3 Scripts/package_release.py --all                  # every tree that is built
    python3 Scripts/package_release.py --sysroots none ...    # compiler only
    python3 Scripts/package_release.py --legacy-sysroots ...  # 0.2.0 layout: all 18 roots prebuilt
    python3 Scripts/package_release.py --stage-only --work build/sysgen/c/stage x86_64-linux-musl

The archive is an ALLOWLIST of build/<triple>/release, not a copy of it (that tree keeps
clang, lld and the dev tools, which dev builds want on disk; kairo and kcc run clang and
lld in-process, and a user never needs the binaries):

  bin/      kairo kcc kld kfmt ksys llvm-symbolizer llvm-ar + alias links llvm-ranlib llvm-lib
  lib/      clang/<ver> (resource dir), builtin, std, rt        (copies, never symlinks)
  sysroot/  the host's own prebuilt roots (HOST_ROOTS below), and a manifest.json naming
            just those; every other target is built by ksys on first use, from:
  share/kairo/sysroot/  the ksys input tree (Scripts/ship_sysroot_inputs.py writes it to
            build/sysroot-share; its contract is that tree's FORMAT.md). Copied, then every
            registry.toml [inputs] hash is recomputed on the staged copy, "runtimes" against
            the share/kairo/runtimes staged beside it, so a share tree generated from other
            runtimes than the ones shipped (ksys would refuse every build) never archives.
  scripts/  darwin-sysroot.sh, msvc-sysroot.{sh,ps1}: build the macOS / MSVC roots a release
            cannot ship, from the user's own Apple SDK / Microsoft CRT+SDK
            (source: Scripts/release-scripts/; the msvc one is a sh/PowerShell polyglot)
  share/kairo/runtimes/  the LLVM runtimes source those scripts compile (compiler-rt
            builtins, libunwind, libc++abi, libc++, cmake glue; no tests/docs/benchmarks/utils)
  share/kairo/sdk-overlays/  our half of those roots prebuilt (libc++ + compiler-rt builtins,
            darwin-{arm64,x86_64}, msvc-{x86_64,aarch64,i686}), so the scripts copy instead of
            compiling. Target-specific, so the SAME overlays go into every host archive, from
            one canonical build/sdk-overlays (Scripts/build_sdk_overlays.py); their REVISION
            must match the runtimes', and every file must be on the overlay allowlist.
  LICENSE, NOTICE, LICENSES/, THIRD-PARTY-NOTICES               (Scripts/collect_licenses.py)

--legacy-sysroots ships all 18 redistributable roots of sysroot/manifest.json, as 0.2.0 did
(the share tree and ksys still ship: additive, and a prebuilt root shadows the build).

Sysroots: Apple and MSVC roots exist in a development sysroot/ and are never packaged
(Compiler/Spec/SysRoot.md section 12). They are excluded by SYSROOT.toml family
(darwin, windows-msvc) or redistributable = false, not by name, and the packager fails if
such a file is in the staged tree or in the finished archive.

Names: kairo-<version>-<triple>.tar.xz (Linux, BSD) or .zip (Windows, macOS), into
dist/<version>/ (or --out), with SHA256SUMS.

llvm-symbolizer and the llvm-ar alias links are not staged into build/<triple>/release/bin
yet; they are taken from build/cross-llvm/<triple>/llvm/bin (the LLVM build the release's
llvm-ar came from) when the tree lacks them. A tool that is nowhere is an error unless it
is named with --allow-missing.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tomllib
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
import cross_llvm  # noqa: E402
import collect_licenses  # noqa: E402
import build_sdk_overlays  # noqa: E402

# bin/: name -> alias links to it. An alias is a symlink (a copy on Windows).
# llvm-dlltool is dropped: nothing in Compiler/, Linker/ or the sysroot flow uses it at
# link time (mingw import libs ship prebuilt in the sysroots); only the unimplemented
# sysroot generator (SysRoot.md 4.6) would.
SHIP_BIN = {
    "kairo": [], "kcc": [], "kld": [], "kfmt": [], "ksys": [],
    "llvm-symbolizer": [],
    "llvm-ar": ["llvm-ranlib", "llvm-lib"],
}
SHIP_LIB = ["builtin", "std", "rt"]          # plus clang/<ver>
# Families that are never redistributable, whatever a root's own toml says.
BANNED_FAMILIES = {"darwin", "windows-msvc", "msvc"}
BANNED_PATH_PARTS = ("apple-macosx", "windows-msvc", "/msvc/", ".tbd", "MacOSX")


def die(m: str) -> None:
    print(f"[package] FAIL: {m}", flush=True)
    sys.exit(1)


def version() -> str:
    sys.path.insert(0, str(ROOT))
    import build  # noqa: E402
    return build.KAIRO_VERSION


def log(m: str) -> None:
    print(f"[package] {m}", flush=True)


TREE_OVERRIDE: Path | None = None    # --tree: package another release tree (a dry run)


def tree_of(triple: str) -> Path:
    return TREE_OVERRIDE or ROOT / "build" / triple / "release"


def exe_suffix(triple: str) -> str:
    return ".exe" if "windows" in triple else ""


def find_tool(triple: str, name: str) -> Path | None:
    exe = exe_suffix(triple)
    for d in (tree_of(triple) / "bin", ROOT / "build" / "cross-llvm" / triple / "llvm" / "bin"):
        p = d / (name + exe)
        if p.is_file() and not p.is_symlink():
            return p
    return None


def copy_resolved(src: Path, dst: Path) -> None:
    """copytree that never leaves a symlink: the archive must not depend on where it was built."""
    shutil.copytree(src, dst, symlinks=False, ignore=shutil.ignore_patterns("*.log", "*.tmp", ".git*"))


# Debug info is most of each toolchain binary (kairo/kcc ~187 MB unstripped). Only
# debug sections go: the symbol table stays, so a crash backtrace still names
# functions (llvm-symbolizer reads it). llvm-objcopy handles ELF and
# COFF alike. Mach-O is never stripped: kld ad-hoc signs arm64 output at link time
# (LC_CODE_SIGNATURE), and rewriting the file after that breaks the signature, so an
# arm64 Mac would kill the binary on launch. Release builds carry no debug info, so
# skipping the strip there costs nothing.
STRIP = True


def objcopy() -> str:
    host = ROOT / "build" / "cross-llvm" / "x86_64-linux-musl" / "llvm" / "bin" / "llvm-objcopy"
    if host.is_file():
        return str(host)
    found = shutil.which("llvm-objcopy")
    if found:
        return found
    die("llvm-objcopy not found (ninja -C build/cross-llvm/x86_64-linux-musl/llvm llvm-objcopy), "
        "or pass --no-strip")


def strip_debug(path: Path) -> None:
    if not STRIP:
        return
    before = path.stat().st_size
    subprocess.run([objcopy(), "--strip-debug", str(path)], check=True)
    log(f"stripped {path.name}: {before >> 20} -> {path.stat().st_size >> 20} MiB")


def stage_bin(triple: str, dst: Path, allow_missing: set[str]) -> None:
    exe = exe_suffix(triple)
    (dst / "bin").mkdir(parents=True)
    for tool, aliases in SHIP_BIN.items():
        src = find_tool(triple, tool)
        if src is None:
            if tool in allow_missing:
                log(f"WARNING: bin/{tool} is not built for {triple}; leaving it out (--allow-missing)")
                continue
            die(f"bin/{tool} is not built for {triple} (looked in {tree_of(triple) / 'bin'} and "
                f"build/cross-llvm/{triple}/llvm/bin); build it, or pass --allow-missing {tool}")
        shutil.copy2(src, dst / "bin" / (tool + exe))
        if "apple" not in triple:
            strip_debug(dst / "bin" / (tool + exe))
        for a in aliases:
            if exe:
                shutil.copy2(src, dst / "bin" / (a + exe))
            else:
                os.symlink(tool, dst / "bin" / a)


def stage_lib(triple: str, dst: Path) -> None:
    src = tree_of(triple) / "lib"
    (dst / "lib").mkdir()
    clang = src / "clang"
    vers = sorted(p for p in clang.iterdir() if (p / "include" / "stddef.h").is_file()) if clang.is_dir() else []
    if len(vers) != 1:
        die(f"{clang}: expected exactly one resource dir with builtin headers, found {[p.name for p in vers]}")
    (dst / "lib" / "clang").mkdir()
    copy_resolved(vers[0], dst / "lib" / "clang" / vers[0].name)
    for name in SHIP_LIB:
        if not (src / name).is_dir():
            die(f"{src / name} is missing")
        copy_resolved((src / name).resolve(), dst / "lib" / name)
    # A non-musl host tree bundles shared libraries into lib/ (stage_tree.bundle_tree);
    # they ship too, and collect_licenses fails on any it has no entry for.
    for p in src.glob("*"):
        if p.is_file() and (fnmatch.fnmatch(p.name, "*.so*") or p.suffix in (".dylib", ".dll")):
            shutil.copy2(p, dst / "lib" / p.name)


# scripts/: shipped as is, mode 0755. They may only run the install's own tools (kcc, kld,
# llvm-ar/lib/ranlib) and host cmake/ninja/sh tools; a release has no clang or lld binary.
RELEASE_SCRIPTS = ROOT / "Scripts" / "release-scripts"
# shipped name -> source. msvc-sysroot is one sh/PowerShell polyglot shipped under both names.
SHIP_SCRIPTS = {"darwin-sysroot.sh": "darwin-sysroot.sh",
                "msvc-sysroot.sh": "msvc-sysroot", "msvc-sysroot.ps1": "msvc-sysroot"}
BANNED_COMMANDS = ("clang", "clang++", "clang-cl", "clang-cpp", "lld", "ld.lld", "lld-link", "ld64.lld",
                   "wasm-ld", "llvm-nm", "llvm-rc", "llvm-mt", "libtool", "nm", "xcrun-clang")
LLVM_SRC = ROOT / "Lib" / "llvm-runtimes"
# What the scripts compile, curated like kairo-sysroots' ship-runtimes.sh.
RUNTIMES_FILES = ["compiler-rt/CMakeLists.txt", "compiler-rt/lib/CMakeLists.txt", "libc/LICENSE.TXT"]
RUNTIMES_TREES = ["compiler-rt/cmake", "compiler-rt/include", "compiler-rt/lib/builtins",
                  # add_subdirectory()d unconditionally by compiler-rt (empty when off):
                  "compiler-rt/tools", "compiler-rt/lib/scudo/standalone/fuzz",
                  "llvm/cmake", "cmake",
                  # libc++ parses floats with LLVM-libc's header-only utilities
                  # (cmake/Modules/FindLibcCommonUtils.cmake puts libc/ on the include path):
                  # the closure of libc/shared/*.h's includes lives in these dirs.
                  "libc/shared", "libc/hdr", "libc/include/llvm-libc-macros",
                  "libc/include/llvm-libc-types", "libc/src/__support",
                  # aarch64 builtins: emupac.cpp includes <siphash/SipHash.h> (P603)
                  "third-party/siphash"]
RUNTIMES_PRUNED = ["libunwind", "libcxxabi", "libcxx", "runtimes"]   # minus RUNTIMES_DROP
RUNTIMES_DROP = {"test", "tests", "docs", "benchmarks", "utils", "__pycache__"}
# libcxx/utils stays (unlike ship-runtimes.sh): libcxx/CMakeLists.txt add_subdirectory()s it
# unconditionally, and its include/ build runs utils/generate_iwyu_mapping.py (target ALL).
RUNTIMES_KEEP = {"libcxx/utils"}
RUNTIMES_REV_PATHS = ["compiler-rt", "libunwind", "libcxxabi", "libcxx", "runtimes", "llvm/cmake", "cmake",
                      "libc/shared", "libc/hdr", "libc/include", "libc/src/__support"]


def script_violations(text: str) -> list[str]:
    """Lines of a shell script that run a clang/lld tool (or build/llvm) as a COMMAND.
    Comments are skipped and heredoc bodies are data (SYSROOT.toml says linker = "lld-link"
    and resource_dir = "clang"; a path like clang/lib/darwin/... is not a command)."""
    bad = []
    names = "|".join(re.escape(n) for n in BANNED_COMMANDS)
    cmd_pos = re.compile(r"(?:^|[;&|(`]|\$\(|\bthen\b|\bdo\b|\belse\b|\bexec\b|\bcommand -v\b|\bwhich\b)\s*"
                         r"(?:[\w/.$\{\}\"-]*/)?(?:" + names + r")(?=[\s\";)|&]|$)")
    # NAME=tool, CMAKE_X_COMPILER=tool, -fuse-ld=tool: a variable that will be run.
    as_value = re.compile(r"(?:\b\w+|-fuse-ld)=\"?(?:[\w/.$\{\}-]*/)?(?:" + names + r")\"?(?=[\s;)]|$)")
    heredoc_end = None
    for i, line in enumerate(text.splitlines(), 1):
        if heredoc_end is not None:
            if line.strip() == heredoc_end:
                heredoc_end = None
            continue
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        code = line.split("#", 1)[0] if not line.lstrip().startswith("#!") else ""
        if "build/llvm" in code or cmd_pos.search(code) or as_value.search(code):
            bad.append(f"{i}: {line.strip()}")
        if m:
            heredoc_end = m.group(1)
    return bad


def stage_scripts(dst: Path) -> None:
    (dst / "scripts").mkdir()
    for name, source in SHIP_SCRIPTS.items():
        src = RELEASE_SCRIPTS / source
        if not src.is_file():
            die(f"{src} is missing")
        bad = script_violations(src.read_text())
        if bad:
            die(f"{src.name} runs a tool the release does not ship (use kcc / kld / llvm-ar):\n  "
                + "\n  ".join(bad))
        shutil.copyfile(src, dst / "scripts" / name)
        os.chmod(dst / "scripts" / name, 0o755)


def git_out(*args: str) -> bytes:
    return subprocess.run(["git", "-C", str(LLVM_SRC), *args], check=True, capture_output=True).stdout


def runtimes_revision() -> str:
    """The fork commit the runtimes come from, with a diff hash when the checkout is dirty.
    share/kairo/sdk-overlays/REVISION is the same string, so a stale overlay is caught."""
    rev = git_out("rev-parse", "HEAD").decode().strip()
    diff = git_out("diff", "HEAD", "--", *RUNTIMES_REV_PATHS)
    if diff:
        rev += "+" + hashlib.sha256(diff).hexdigest()[:12]
    return rev


def stage_runtimes(dst: Path) -> None:
    """share/kairo/runtimes: the sources scripts/*.sh build, plus REVISION (the fork commit,
    with a diff hash when the checkout is dirty) and compiler-rt/lib/builtins/sources.toml."""
    if not (LLVM_SRC / "runtimes" / "CMakeLists.txt").is_file():
        die(f"no LLVM runtimes source at {LLVM_SRC} (the Lib/llvm-runtimes submodule)")
    out = dst / "share" / "kairo" / "runtimes"
    out.mkdir(parents=True)
    ignore = shutil.ignore_patterns(".git*")
    for d in RUNTIMES_TREES:
        shutil.copytree(LLVM_SRC / d, out / d, symlinks=True, ignore=ignore)
    for d in RUNTIMES_PRUNED:
        shutil.copytree(LLVM_SRC / d, out / d, symlinks=True,
                        ignore=lambda dirpath, names: [
                            n for n in names
                            if (n in RUNTIMES_DROP or n.startswith(".git"))
                            and Path(dirpath, n).relative_to(LLVM_SRC).as_posix() not in RUNTIMES_KEEP])
    for f in RUNTIMES_FILES:
        (out / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(LLVM_SRC / f, out / f)
    rev = runtimes_revision()
    (out / "REVISION").write_text(rev + "\n")
    # Source lists a no-cmake builder can read, scraped so they follow the fork.
    cm = (out / "compiler-rt" / "lib" / "builtins" / "CMakeLists.txt").read_text()
    lines = []
    for name in ("GENERIC_SOURCES", "GENERIC_TF_SOURCES", "BF16_SOURCES"):
        m = re.search(r"^set\(" + name + r"\b(.*?)\)", cm, re.S | re.M)
        if not m:
            die(f"compiler-rt builtins CMakeLists.txt has no set({name} ...)")
        srcs = re.findall(r"[a-z0-9_/]+\.(?:c|S)\b", m.group(1))
        lines.append(f"{name} = [" + ",".join(f'"{x}"' for x in srcs) + "]")
    (out / "compiler-rt" / "lib" / "builtins" / "sources.toml").write_text("\n".join(lines) + "\n")
    for must in ("libcxx/include/vector", "runtimes/CMakeLists.txt", "libcxxabi/CMakeLists.txt",
                 "compiler-rt/lib/builtins/addtf3.c", "llvm/cmake/modules/HandleLLVMOptions.cmake",
                 "libc/shared/fp_bits.h", "libcxx/utils/CMakeLists.txt", "compiler-rt/tools/CMakeLists.txt"):
        if not (out / must).exists():
            die(f"curated runtimes lack {must}")
    size = sum(p.stat().st_size for p in out.rglob("*") if p.is_file() and not p.is_symlink())
    log(f"share/kairo/runtimes: rev {rev} ({size / (1 << 20):.1f} MiB unpacked)")


SDK_OVERLAYS = ROOT / "build" / "sdk-overlays"


def stage_sdk_overlays(dst: Path) -> None:
    """share/kairo/sdk-overlays from the canonical build/sdk-overlays. Checked twice over:
    the allowlist (only libc++/builtins files the runtimes source accounts for; never a
    .tbd, an SDK header, an msvc/ tree or a vendor library) and the revision (an overlay
    built from other runtimes than the ones beside it is stale)."""
    if not (SDK_OVERLAYS / "REVISION").is_file():
        die(f"no SDK overlays at {SDK_OVERLAYS}: build them with Scripts/build_sdk_overlays.py "
            "(or pass --no-sdk-overlays for an archive without the macOS/MSVC fast path)")
    runtimes = dst / "share" / "kairo" / "runtimes"
    want, got = (runtimes / "REVISION").read_text().strip(), (SDK_OVERLAYS / "REVISION").read_text().strip()
    if want != got:
        die(f"{SDK_OVERLAYS} is rev {got}, share/kairo/runtimes is rev {want}: rebuild the overlays")
    missing = [n for n in build_sdk_overlays.ALL if not (SDK_OVERLAYS / n).is_dir()]
    if missing:
        die(f"{SDK_OVERLAYS} lacks {', '.join(missing)}: rebuild the overlays")
    errs = build_sdk_overlays.check_overlays(SDK_OVERLAYS, runtimes)
    if errs:
        die("SDK overlay content check failed:\n  " + "\n  ".join(errs))
    out = dst / "share" / "kairo" / "sdk-overlays"
    shutil.copytree(SDK_OVERLAYS, out, symlinks=False)
    # Checked again on the copy: what ships, not what was meant to.
    errs = build_sdk_overlays.check_overlays(out, runtimes)
    if errs:
        die("SDK overlay content check failed on the staged copy:\n  " + "\n  ".join(errs))
    size = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    log(f"share/kairo/sdk-overlays: rev {got}, {len(build_sdk_overlays.ALL)} overlays "
        f"({size / (1 << 20):.1f} MiB unpacked)")


def redistributable(root: Path) -> tuple[bool, str]:
    """(ok, why not) from the root's own SYSROOT.toml: family or redistributable = false."""
    toml = root / "SYSROOT.toml"
    if not toml.is_file():
        return False, "no SYSROOT.toml"
    with open(toml, "rb") as f:
        d = tomllib.load(f)
    fam = d.get("family", "")
    if fam in BANNED_FAMILIES:
        return False, f"family {fam}"
    if d.get("redistributable", True) is False:
        return False, "redistributable = false"
    if d.get("local_only"):
        return False, f"local_only = {d['local_only']}"
    return True, ""


def copy_root(src: Path, dst: Path) -> int:
    """Copies one sysroot root keeping its symlinks, but makes absolute links relative when
    their target lies inside the root (musl's libc.so -> /lib/ld-musl-*.so.1 is meant
    relative to the root). A link whose target only exists on a real filesystem (musl's
    loader) is REMOVED, not shipped: a dangling
    libc.so is a lookup trap for `-lc` (SysRoot.md 4.6: "keep the dangling libc.so out"),
    and nothing can use one. Returns how many were dropped."""
    shutil.copytree(src, dst, symlinks=True)
    dropped = []
    for d, dirs, files in os.walk(dst):
        for n in dirs + files:
            p = Path(d) / n
            if not p.is_symlink():
                continue
            t = os.readlink(p)
            if os.path.isabs(t):
                inside = dst / t.lstrip("/")
                if os.path.lexists(inside):
                    p.unlink()
                    os.symlink(os.path.relpath(inside, p.parent), p)
                    continue
                dropped.append(p)
            elif not p.exists():
                dropped.append(p)
    for p in dropped:
        p.unlink()
    return len(dropped)


# The prebuilt roots a host archive keeps (the rest come from ksys, share/kairo/sysroot).
# The rule: the roots a user of that host most likely targets first, so the common
# `--target <host>` and the native-libc case need no first-use build (about 5-25 s, and a
# working kcc + the runtimes source). Linux hosts are musl-hosted toolchains whose users
# build for both libcs of their own arch: the musl root and the glibc one (glibc's name
# carries its version and, on armv7, the gnueabihf ABI, so names are spelled out here,
# never derived). Windows keeps its own -windows-gnu root (the default target there);
# the BSDs keep their own root. macOS keeps none: its native root is the user's Apple SDK
# plus share/kairo/sdk-overlays (scripts/darwin-sysroot.sh, run by the installer).
# Every key of cross_llvm.FAMILIES must be here: a new host is a decision, not a default.
HOST_ROOTS = {
    "x86_64-linux-musl":        ["x86_64-linux-musl", "x86_64-linux-gnu-glibc2.31"],
    "i686-linux-musl":          ["i686-linux-musl", "i686-linux-gnu-glibc2.31"],
    "aarch64-linux-musl":       ["aarch64-linux-musl", "aarch64-linux-gnu-glibc2.31"],
    "armv7-linux-musl":         ["armv7-linux-musl", "armv7-linux-gnueabihf-glibc2.31"],
    "riscv64-linux-musl":       ["riscv64-linux-musl", "riscv64-linux-gnu-glibc2.31"],
    "x86_64-windows-gnu":       ["x86_64-windows-gnu"],
    "i686-windows-gnu":         ["i686-windows-gnu"],
    "aarch64-windows-gnu":      ["aarch64-windows-gnu"],
    "armv7-windows-gnu":        ["armv7-windows-gnu"],
    "x86_64-unknown-freebsd":   ["x86_64-unknown-freebsd"],
    "aarch64-unknown-freebsd":  ["aarch64-unknown-freebsd"],
    "x86_64-unknown-netbsd":    ["x86_64-unknown-netbsd"],
    "arm64-apple-macosx11.0":   [],
    "x86_64-apple-macosx10.15": [],
}


def stage_sysroots(triple: str, dst: Path, legacy: bool) -> None:
    """sysroot/: the host's HOST_ROOTS (default) or every redistributable root (legacy)."""
    sr = (tree_of(triple) / "sysroot").resolve()
    manifest = json.loads((sr / "manifest.json").read_text())
    want = set(manifest["targets"])
    cand = {p.name for p in sr.iterdir() if (p / "SYSROOT.toml").is_file()}
    redist = set()
    for name in sorted(cand):
        ok, why = redistributable(sr / name)
        if not ok:
            log(f"sysroot/{name}: not packaged ({why})")
            continue
        redist.add(name)
    if legacy:
        if redist != want:
            die(f"sysroot roots differ from manifest.json: only on disk {sorted(redist - want)}, "
                f"only in manifest {sorted(want - redist)}")
        shipped = redist
    else:
        if triple not in HOST_ROOTS:
            die(f"{triple} has no HOST_ROOTS entry in Scripts/package_release.py: decide which "
                "prebuilt roots its archive keeps ([] = none, ksys builds every target)")
        shipped = set(HOST_ROOTS[triple])
        bad = sorted(n for n in shipped if n not in want or n not in redist)
        if bad:
            die(f"HOST_ROOTS[{triple}] names {bad}: not a redistributable root of {sr} / its manifest.json")
    if not shipped:
        log("sysroot/: no prebuilt roots for this host (ksys builds every target)")
        return
    (dst / "sysroot").mkdir()
    # The manifest names only what ships: a 0.2.0 reader took it as the list of roots on disk.
    kept = dict(manifest, targets={n: t for n, t in manifest["targets"].items() if n in shipped})
    (dst / "sysroot" / "manifest.json").write_text(json.dumps(kept, indent=2) + "\n")
    dangling = 0
    for name in sorted(shipped):
        log(f"sysroot/{name}")
        dangling += copy_root(sr / name, dst / "sysroot" / name)
    log(f"sysroots: {len(shipped)} of {len(want)} roots prebuilt{' (legacy)' if legacy else ''}, "
        f"{dangling} dangling links dropped (musl libc.so -> loader, FreeBSD libxo test.enc)")


SYSROOT_SHARE = ROOT / "build" / "sysroot-share"
# What of build/sysroot-share ships, besides the [inputs] dirs registry.toml names. Anything
# else at its top level is an error: a new entry is a decision. FORMAT.md is the maintainer
# contract between the producer and ksys, not something an install reads.
SHARE_META = {"registry.toml", "quirks.toml", "provenance.toml", "families", "shims", "validate",
              "licenses"}
SHARE_SKIP = {"FORMAT.md"}


def stage_share(dst: Path, src: Path) -> None:
    """share/kairo/sysroot from build/sysroot-share (or --share). Copied with its symlinks
    (the BSD inputs' relative usr/lib links, a 23 MB include dir among them: resolving them
    would double that payload), then checked on the staged copy: every registry hash, the
    "runtimes" one against share/kairo/runtimes staged beside it, no link leaving its input,
    and a non-empty licenses/<component>/ for every input."""
    import ship_sysroot_inputs   # lazily: it imports this module back
    reg_src = src / "registry.toml"
    if not reg_src.is_file():
        die(f"no ksys input tree at {src}: build it with python3 Scripts/ship_sysroot_inputs.py "
            "(or pass --legacy-sysroots for the 0.2.0 layout)")
    with open(reg_src, "rb") as f:
        reg = tomllib.load(f)
    inputs, lic = reg.get("inputs", {}), reg.get("licenses", {})
    if not inputs or set(inputs) != set(lic):
        die(f"{reg_src}: [inputs] and [licenses] must name the same dirs "
            f"(only inputs {sorted(set(inputs) - set(lic))}, only licenses {sorted(set(lic) - set(inputs))})")
    tops = {k.split("/")[0] for k in inputs}
    out = dst / "share" / "kairo" / "sysroot"
    out.mkdir(parents=True)
    for e in sorted(src.iterdir()):
        if e.name in SHARE_SKIP:
            continue
        if e.name == "runtimes":
            die(f"{e}: the share tree carries its own runtimes/; package_release ships one copy, "
                "share/kairo/runtimes (FORMAT.md fallback)")
        if e.name not in SHARE_META and e.name not in tops:
            die(f"{e}: not an input dir of registry.toml nor a known share file; decide whether it ships "
                "(SHARE_META in Scripts/package_release.py)")
        if e.is_dir():
            shutil.copytree(e, out / e.name, symlinks=True, ignore=shutil.ignore_patterns(".git*", "__pycache__"))
        else:
            shutil.copy2(e, out / e.name)
    # A link must stay inside its own input dir (FORMAT.md, producer notes): the hash
    # follows links, so one escaping into a sibling, or out of the tree, would hash here
    # and dangle (or differ) in an install.
    for d, dirs, files in os.walk(out):
        for n in dirs + files:
            p = Path(d) / n
            if not p.is_symlink():
                continue
            t = os.readlink(p)
            rel = p.relative_to(out).as_posix()
            owner = next((k for k in inputs if rel.startswith(k + "/")), None)
            target = (p.parent / t).resolve()
            if os.path.isabs(t) or owner is None or not target.exists() \
                    or not target.is_relative_to((out / owner).resolve()):
                die(f"share/kairo/sysroot/{rel} -> {t}: a link must be relative and resolve inside its input dir")
    runtimes = dst / "share" / "kairo" / "runtimes"
    if not (runtimes / "REVISION").is_file():
        die("stage_share runs after stage_runtimes: share/kairo/runtimes is not staged")
    bad = []
    for k, want in sorted(inputs.items()):
        d = runtimes if k == "runtimes" else out / k
        if not d.is_dir():
            bad.append(f"{k}: missing")
            continue
        got = ship_sysroot_inputs.tree_sha256(d)
        if got != want:
            bad.append(f"{k}: registry {want[:12]}, staged {got[:12]}")
    if bad:
        die("share/kairo/sysroot/registry.toml does not match what was staged (ksys would refuse these "
            "targets); regenerate the share tree with python3 Scripts/ship_sysroot_inputs.py:\n  "
            + "\n  ".join(bad))
    have = {p.name for p in (out / "licenses").iterdir() if p.is_dir()} if (out / "licenses").is_dir() else set()
    empty = sorted(c for c in have if not any((out / "licenses" / c).iterdir()))
    if tops != have or empty:
        die(f"share/kairo/sysroot/licenses must hold one non-empty dir per input component: "
            f"missing {sorted(tops - have)}, unexpected {sorted(have - tops)}, empty {empty}")
    size = sum(p.stat().st_size for p in out.rglob("*") if p.is_file() and not p.is_symlink())
    log(f"share/kairo/sysroot: {len(inputs)} inputs verified against registry.toml "
        f"({size / (1 << 20):.1f} MiB unpacked)")


def check_banned(dst: Path) -> None:
    """The release must never contain an Apple or MSVC root. Checked on the staged tree by
    SYSROOT.toml family and by path, so a file that slipped in under any name is caught."""
    sr = dst / "sysroot"
    for root in (sr.iterdir() if sr.is_dir() else ()):
        if root.is_dir():
            ok, why = redistributable(root)
            if not ok:
                die(f"{root.relative_to(dst)} is in the archive tree but is not redistributable ({why})")
    # The ksys input tree too: its darwin/msvc recipes are ours (families/*.toml), but an
    # input dir of SDK content under any name must never ship.
    for top in (sr, dst / "share" / "kairo" / "sysroot"):
        for d, dirs, files in os.walk(top):
            for n in dirs + files:
                rel = str((Path(d) / n).relative_to(dst))
                if any(b in rel for b in BANNED_PATH_PARTS):
                    die(f"{rel} looks like Apple/MSVC content and must never be in an archive")


def check_names(names, what: str) -> None:
    for n in names:
        # Match below the top directory: a macOS host archive is itself named
        # kairo-<ver>-arm64-apple-macosx11.0/, so its own name would match every member.
        inner = "/".join(Path(n).parts[1:])
        if any(b in inner for b in BANNED_PATH_PARTS):
            die(f"{what}: {n} looks like Apple/MSVC content and must never be in an archive")
        parts = Path(n).parts
        if len(parts) >= 3 and parts[1] == "bin" and parts[2].split(".")[0] in (
                "clang", "clang++", "clang-22", "clang-cl", "clang-cpp", "lld", "ld.lld", "ld64.lld",
                "lld-link", "wasm-ld", "llvm-nm", "llvm-objdump", "katar", "kparse"):
            die(f"{what}: {n} must not ship")


def stage_dir(triple: str, ver: str, sysroots: str, work: Path, allow_missing: set[str],
              overlays: bool = True, legacy: bool = False, share: Path = SYSROOT_SHARE) -> Path:
    name = f"kairo-{ver}-{triple}"
    dst = work / name
    shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True)
    stage_bin(triple, dst, allow_missing)
    stage_lib(triple, dst)
    stage_scripts(dst)
    stage_runtimes(dst)
    if overlays:
        stage_sdk_overlays(dst)
    if sysroots == "bundled":
        stage_share(dst, share)
        stage_sysroots(triple, dst, legacy)
        check_banned(dst)
    errs = collect_licenses.collect(dst, triple)
    if errs:
        for e in errs:
            log(f"FAIL: {e}")
        die("license collection failed; nothing was archived")
    return dst


def archive(dst: Path, triple: str, out: Path) -> Path:
    windows_or_mac = cross_llvm.FAMILIES.get(triple, ("Linux",))[0] in ("Windows", "Darwin")
    if windows_or_mac:
        path = out / f"{dst.name}.zip"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for p in sorted(dst.rglob("*")):
                rel = p.relative_to(dst.parent)
                if p.is_symlink():
                    # zip keeps a symlink as a file whose mode says link and whose
                    # data is the target (what unzip and macOS Archive Utility read).
                    info = zipfile.ZipInfo(str(rel))
                    info.create_system = 3
                    info.external_attr = (0o120777 << 16)
                    z.writestr(info, os.readlink(p))
                elif p.is_file():
                    z.write(p, rel)
        check_names(zipfile.ZipFile(path).namelist(), path.name)
        return path
    path = out / f"{dst.name}.tar.xz"
    # tar streams straight into the external xz (multi-threaded, and no 3 GB temp tar).
    with open(path, "wb") as fh:
        xz = subprocess.Popen(["xz", "-T0", "-6", "-c"], stdin=subprocess.PIPE, stdout=fh)
        with tarfile.open(fileobj=xz.stdin, mode="w|") as t:
            t.add(dst, arcname=dst.name)
        xz.stdin.close()
        if xz.wait() != 0:
            die("xz failed")
    # Verify what was actually written, not what was meant to be.
    with tarfile.open(path, "r|xz") as t:
        check_names((m.name for m in t), path.name)
    return path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("triples", nargs="*")
    ap.add_argument("--all", action="store_true", help="every target whose release tree exists")
    ap.add_argument("--sysroots", choices=["bundled", "none"], default="bundled",
                    help="none: no sysroot/ and no share/kairo/sysroot (compiler only)")
    ap.add_argument("--legacy-sysroots", action="store_true",
                    help="prebuild all 18 redistributable roots (the 0.2.0 layout) instead of the host's HOST_ROOTS")
    ap.add_argument("--share", type=Path, default=SYSROOT_SHARE,
                    help="the ksys input tree to ship as share/kairo/sysroot (default: build/sysroot-share)")
    ap.add_argument("--tree", type=Path,
                    help="package this release tree instead of build/<triple>/release (one triple)")
    ap.add_argument("--stage-only", action="store_true",
                    help="stage into --work and stop: no archive, no SHA256SUMS, nothing written to --out")
    ap.add_argument("--no-strip", action="store_true", help="keep debug info in bin/ (default: --strip-debug)")
    ap.add_argument("--out", help="output directory (default: dist/<version>)")
    ap.add_argument("--work", help="scratch directory for the staged tree (default: <out>/.stage)")
    ap.add_argument("--no-sdk-overlays", action="store_true",
                    help="leave out share/kairo/sdk-overlays (the macOS/MSVC scripts then do the full build)")
    ap.add_argument("--allow-missing", action="append", default=[], metavar="TOOL",
                    help="package without this bin/ tool instead of failing (a test archive)")
    a = ap.parse_args()
    global STRIP, TREE_OVERRIDE
    STRIP = not a.no_strip
    ver = version()
    if a.tree:
        if a.all or len(a.triples) != 1:
            die("--tree packages one tree: name exactly one triple, without --all")
        TREE_OVERRIDE = a.tree.resolve()
    triples = [t for t in cross_llvm.FAMILIES if (tree_of(t) / "bin").is_dir()] if a.all else a.triples
    if not triples:
        log("nothing to package")
        return 1
    if a.stage_only:
        # Returns before anything touches --out (default dist/<ver>, the real release dir).
        if not a.work:
            die("--stage-only needs --work DIR (the staged tree is left there)")
        for t in triples:
            if not (tree_of(t) / "bin").is_dir():
                die(f"{t}: no tree at {tree_of(t)}")
            dst = stage_dir(t, ver, a.sysroots, Path(a.work).resolve(), set(a.allow_missing),
                            not a.no_sdk_overlays, a.legacy_sysroots, a.share.resolve())
            log(f"{t}: staged {dst} (--stage-only: not archived)")
        return 0
    out = Path(a.out).resolve() if a.out else ROOT / "dist" / ver
    work = Path(a.work).resolve() if a.work else out / ".stage"
    out.mkdir(parents=True, exist_ok=True)
    for t in triples:
        if not (tree_of(t) / "bin").is_dir():
            log(f"{t}: no tree at {tree_of(t)}; build it: python3 build.py --target {t} kairo kcc")
            return 1
        dst = stage_dir(t, ver, a.sysroots, work, set(a.allow_missing), not a.no_sdk_overlays,
                        a.legacy_sysroots, a.share.resolve())
        p = archive(dst, t, out)
        # A staged tree is ~1.5-2 GB (the share tree + the host roots; ~3.4 GB with
        # --legacy-sysroots), so drop each one as soon as its archive is written.
        shutil.rmtree(dst, ignore_errors=True)
        log(f"{t}: {p.name} ({p.stat().st_size / (1 << 20):.0f} MiB)")
    shutil.rmtree(work, ignore_errors=True)
    with open(out / "SHA256SUMS", "w") as f:
        for p in sorted(out.glob("kairo-*")):
            h = hashlib.sha256()
            with open(p, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            f.write(f"{h.hexdigest()}  {p.name}\n")
    # The installer rides along, as the two names the website serves it under, so one
    # `gh release upload` attaches it. Not named kairo-*, so SHA256SUMS above never lists it.
    for n in ("install.sh", "install.ps1"):
        shutil.copyfile(ROOT / "Scripts" / "install-release", out / n)
    log(f"done: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
