#!/usr/bin/env python3
"""Build erase_check (erase_check.k beside this file) and run it over the toolchain's tools.

erase_check imports the compiler's own modules, so it is built exactly like a tool of the
tree: the command comes from the repository's build.py (--print-command for kparse, the
smallest target over the same roots), with the entry and the output swapped. That also
builds the diagnostic registry object the command links.

    python3 Scripts/LlvmEraseCheck/build.py                 # build, release profile
    python3 Scripts/LlvmEraseCheck/build.py --run           # build, then check every tool
    python3 Scripts/LlvmEraseCheck/build.py --run-only kals # check one tool, no build

--run takes each tool's own compile command (build.py --print-command), so every file is
checked with the flags it is built with, and walks only the files under Compiler/,
Analyzer/, Linker/ and Extras/. The merged report goes to <out>/report.txt: the HIT and
PASS lines, the CALL inventory and the FILE list, each once.
"""
import argparse
import os
import shlex
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ENTRY = HERE / "erase_check.k"
TOOLS = ["kairo", "kcc", "kld", "ksys", "kfmt", "kals", "kunit"]
WALKED = ["Compiler", "Analyzer", "Linker", "Extras"]


def print_commands(a, targets: list) -> dict:
    """Each target's compile command, as the repository's build.py would run it."""
    argv = [sys.executable, str(ROOT / "build.py"), "--single", "--no-prebuild", "--print-command",
            "--debug" if a.debug else "--release", "--out", str(a.out / "tree")]
    if a.kairo:
        argv += ["--kairo", a.kairo]
    r = subprocess.run(argv + targets, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"build.py --print-command failed ({r.returncode}):\n{r.stdout}{r.stderr}")
    out = {}
    lines = r.stdout.splitlines()
    for i, l in enumerate(lines):
        if l.startswith("# ") and "(cwd" in l and i + 1 < len(lines):
            out[l.split()[1]] = shlex.split(lines[i + 1])
    missing = [t for t in targets if t not in out]
    if missing:
        sys.exit(f"build.py printed no command for {', '.join(missing)}")
    return out


def build(a) -> Path:
    cmd = print_commands(a, ["kparse"])["kparse"]
    exe = a.out / "bin" / "erase_check"
    exe.parent.mkdir(parents=True, exist_ok=True)
    argv = []
    i = 0
    while i < len(cmd):
        x = cmd[i]
        if x.endswith("ParseOnceTest.k"):
            x = str(ENTRY)
        elif x == "-o":
            argv += ["-o", str(exe)]
            i += 2
            continue
        elif x == "--cache-dir":
            argv += ["--cache-dir", str(a.out / "cache")]
            i += 2
            continue
        argv.append(x)
        i += 1
    print("erase_check: " + shlex.join(argv), flush=True)
    r = subprocess.run(argv, cwd=ROOT)
    if r.returncode != 0:
        sys.exit(f"erase_check did not build ({r.returncode})")
    link_libs(Path(cmd[0]), a.out / "lib")
    return exe


def link_libs(kairo: Path, lib: Path) -> None:
    """The shared libraries the binary loads through its $ORIGIN/../lib rpath, which a
    tree build gets from stage_tree.py: libLLVM and libclang-cpp from the LLVM build it
    linked against, and the libc++ they need from a staged tree of this checkout (a
    worktree's main checkout counts). Without them the loader takes the host's."""
    lib.mkdir(parents=True, exist_ok=True)
    want = list((ROOT / "build" / "llvm" / "lib").glob("libLLVM.so.*"))
    want += list((ROOT / "build" / "llvm" / "lib").glob("libclang-cpp.so.*"))
    roots = [ROOT]
    common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if common:
        roots.append(Path(common).parent)
    for r in roots:
        # A host tree (<triple>/release, <triple>/debug) before any other staged one.
        staged = sorted((r / "build").glob("*/*/lib/libc++.so.1"),
                        key=lambda p: (p.parent.parent.name not in ("release", "debug"), str(p)))
        if staged:
            want += [staged[0], staged[0].with_name("libc++abi.so.1")]
            break
    for so in want:
        if not so.is_file():
            continue
        dst = lib / so.name
        if dst.is_symlink() or dst.exists():
            dst.unlink()
        dst.symlink_to(so.resolve())
    # The rest of a staged tree, which the front end finds beside its binary: the clang
    # resource dir and the sysroot from the compiler's own tree, and this checkout's
    # library (Lib/builtin, Lib/std, Lib/rt), which the tree's tools are checked against.
    seed = kairo.resolve().parent.parent
    links = {lib / "clang": seed / "lib" / "clang", lib.parent / "sysroot": seed / "sysroot"}
    for d in ("builtin", "std", "rt"):
        links[lib / d] = ROOT / "Lib" / d
    for dst, src in links.items():
        if not src.exists():
            continue
        if dst.is_symlink() or dst.exists():
            dst.unlink()
        dst.symlink_to(src.resolve())


def check_args(cmd: list) -> list:
    """A tool's compile command as erase_check's arguments: its .k entry and flags, without
    the other inputs and the outputs (only the front end runs)."""
    drop_with_arg = {"-o", "--cache-dir"}
    out = []
    i = 1
    while i < len(cmd):
        x = cmd[i]
        if x in drop_with_arg:
            i += 2
            continue
        if x.endswith((".o", ".cpp", ".cc", ".c")) or x == "--sema-agreement-summary":
            i += 1
            continue
        out.append(x)
        i += 1
    return out


def run(a, exe: Path) -> int:
    tools = a.run_only or TOOLS
    cmds = print_commands(a, tools)
    env = dict(os.environ)
    env["ERASE_CHECK_ROOTS"] = ":".join(str(ROOT / d) + "/" for d in WALKED)
    seen = {}
    rc_all = 0
    for t in tools:
        log = a.out / f"run-{t}.log"
        argv = [str(exe)] + check_args(cmds[t])
        with log.open("w") as f:
            r = subprocess.run(argv, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
        text = log.read_text(errors="replace")
        summary = [l for l in text.splitlines() if l.startswith("SUMMARY")]
        print(f"{t}: rc {r.returncode}  {summary[-1] if summary else '(no summary: see ' + str(log) + ')'}",
              flush=True)
        if r.returncode == 2 or not summary:
            rc_all = 2
        for l in text.splitlines():
            if l.split(" ", 1)[0] in ("HIT", "PASS", "CALL", "FILE", "UNCHECKED"):
                seen.setdefault(l, t)
    order = {"HIT": 0, "PASS": 1, "UNCHECKED": 2, "CALL": 3, "FILE": 4}
    lines = sorted(seen, key=lambda l: (order[l.split(" ", 1)[0]], l))
    rep = a.out / "report.txt"
    rep.write_text("".join(l + "\n" for l in lines))
    hits = sum(1 for l in lines if l.startswith("HIT"))
    print(f"report: {rep} ({hits} HIT, {sum(1 for l in lines if l.startswith('PASS'))} PASS, "
          f"{sum(1 for l in lines if l.startswith('CALL'))} CALL, "
          f"{sum(1 for l in lines if l.startswith('FILE'))} FILE)")
    if rc_all:
        return rc_all
    return 1 if hits else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kairo", help="compiler to build with (default: build.py's seed, the installed release)")
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "erase-check")
    ap.add_argument("--debug", action="store_true", help="debug profile (default release: the check runs "
                    "the whole front end over the tree)")
    ap.add_argument("--run", action="store_true", help="check every tool after building")
    ap.add_argument("--run-only", nargs="*", metavar="TOOL", help=f"check these tools ({', '.join(TOOLS)}; "
                    "default all) with the erase_check already built")
    a = ap.parse_args()
    a.out = a.out.resolve()
    if a.run_only is not None:
        exe = a.out / "bin" / "erase_check"
        if not exe.is_file():
            sys.exit(f"{exe} is not built; run without --run-only first")
        return run(a, exe)
    exe = build(a)
    return run(a, exe) if a.run else 0


if __name__ == "__main__":
    sys.exit(main())
