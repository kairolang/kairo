#!/usr/bin/env python3
"""Build and run the builtin-library benchmarks, and write the report.

    python3 run.py                       every group, every column
    python3 run.py --groups string,map   some groups
    python3 run.py --rows 'map\\.lookup'  rows whose id matches a regex
    python3 run.py --quick               one short pass, to see that it works
    python3 run.py --quiet-machine       more repetitions, for numbers to keep
    python3 run.py --report-only         report.md again from results.json

Four columns are built from the same rows (ops.toml): Kairo against the
installed library (kairo/*.k), C++ through clang and through kcc
(cpp/*.cpp), and Rust (rust/*.rs). Each
(row, size) cell is one process pinned to one CPU; the processes of a cell
run interleaved across the columns, several times each, and the fastest is
kept. Where `perf stat` is permitted, a second pass counts user-mode
instructions and cycles per operation.

Output, under --out (default: out/ beside this file): bin/, results.json and
report.md. README has the protocol and how to add a row.
"""

import argparse
import datetime
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
COLUMNS = ["kairo", "clang", "kcc", "rust"]
BASELINES = ["clang", "kcc", "rust"]
# The columns whose programs are Kairo: driven through the environment, and
# exempt from the checksum comparison on rows that say `kairo_checksum = false`.
KAIRO_COLUMNS = ("kairo",)
SOURCES = {"kairo": ("kairo", "k"), "clang": ("cpp", "cpp"),
           "kcc": ("cpp", "cpp"), "rust": ("rust", "rs")}
HEAD = {"kairo": "Kairo", "clang": "C++ (clang)",
        "kcc": "C++ (kcc)", "rust": "Rust"}
# The tree that holds this file.
TREE = HERE.parents[1]


def sh(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)


def first_line(cmd):
    r = sh(cmd)
    out = (r.stdout or r.stderr).strip().splitlines()
    return out[0] if out else "?"


# --- the toolchain -------------------------------------------------------------

def find_toolchain():
    """The installed toolchain's bin/: $KAIRO_TOOLCHAIN, or the first
    build/x86_64-linux-musl/release/bin at or above this file."""
    env = os.environ.get("KAIRO_TOOLCHAIN")
    if env:
        return Path(env)
    for up in [HERE, *HERE.parents]:
        cand = up / "build" / "x86_64-linux-musl" / "release" / "bin"
        if (cand / "kairo").exists():
            return cand
    sys.exit("run.py: no toolchain found; pass --toolchain or set KAIRO_TOOLCHAIN")


class Toolchain:
    def __init__(self, args):
        tc = Path(args.toolchain) if args.toolchain else find_toolchain()
        self.kairo = Path(args.kairo) if args.kairo else tc / "kairo"
        self.kcc = Path(args.kcc) if args.kcc else tc / "kcc"
        self.clang = Path(args.clang) if args.clang else tc / "clang++"
        self.nm = tc / "llvm-nm"
        self.rustc = args.rustc
        self.cpu = args.cpu_name or self._native_cpu()
        self.sysroot, self.triple = self._kcc_sysroot()

    def _native_cpu(self):
        r = sh([self.clang, "-march=native", "-E", "-x", "c++", "-", "-###"], stdin=subprocess.DEVNULL)
        m = re.search(r'"-target-cpu" "([^"]+)"', r.stderr)
        if not m:
            sys.exit("run.py: cannot resolve the native CPU name; pass --cpu-name")
        return m.group(1)

    def _kcc_sysroot(self):
        """The sysroot and triple kcc links with. The clang column uses the
        same ones, so the two C++ columns differ in the heap alone."""
        probe = HERE / "cpp" / "string.cpp"
        r = sh([self.kcc, "-###", "-std=c++20", probe, "-o", os.devnull])
        text = r.stdout + r.stderr
        sysroot = re.search(r"--sysroot=(\S+)", text)
        triple = re.search(r"-triple (\S+)", text)
        if not sysroot or not triple:
            sys.exit("run.py: cannot read the sysroot from `kcc -###`")
        return Path(sysroot.group(1).strip('"')), triple.group(1).strip('"')

    def clang_cmd(self, src, exe):
        """clang++ with the libc++, compiler-rt and C library of kcc's
        sysroot, linked statically against libc++ and dynamically against the
        C library: kcc's own link without the Kairo runtime."""
        sr = self.sysroot
        crt = next((sr / "compiler-rt" / "lib").iterdir())
        return [self.clang, f"--target={self.triple}", f"--sysroot={sr}", "-nostdinc++",
                "-isystem", sr / "include" / "c++" / "v1",
                "-isystem", sr / "include" / "x86_64-linux-gnu", "-isystem", sr / "include",
                "-std=c++20", "-O3", f"-march={self.cpu}", src, "-o", exe,
                "-fuse-ld=lld", "-nostdlib", f"-L{sr / 'lib'}",
                sr / "lib" / "Scrt1.o", sr / "lib" / "crti.o", crt / "clang_rt.crtbegin.o",
                "-lc++", "-lc++abi", "-lunwind", crt / "libclang_rt.builtins.a",
                "-lm", "-lpthread", "-ldl", "-lc", crt / "libclang_rt.builtins.a",
                crt / "clang_rt.crtend.o", sr / "lib" / "crtn.o"]

    def kcc_cmd(self, src, exe):
        return [self.kcc, "-std=c++20", "-O3", f"-march={self.cpu}", src,
                HERE / "cpp" / "kcc_anchor.k", "-o", exe]

    def rust_cmd(self, src, exe):
        return [self.rustc, "--edition", "2021", "-C", "opt-level=3", "-C", f"target-cpu={self.cpu}",
                "-C", "codegen-units=1", src, "-o", exe]

    def kairo_cmd(self, src, exe, cache):
        return [self.kairo, src, "-I", HERE / "cpp", "-O3", "--mcpu", self.cpu,
                "--cache-dir", cache, "-o", exe]

    def versions(self):
        return {
            "kairo": first_line([self.kairo, "--version"]),
            "kcc": first_line([self.kcc, "--version"]),
            "clang": first_line([self.clang, "--version"]),
            "rust": first_line([self.rustc, "--version"]),
        }

    def defines(self, exe, symbol):
        r = sh([self.nm, "--defined-only", exe])
        return any(line.split()[-1] == symbol for line in r.stdout.splitlines() if line.split())


def shown(cmd):
    """A command line for the report: paths under the repository are made
    relative to the checkout that holds them."""
    out = []
    for c in cmd:
        c = str(c)
        c = re.sub(r"^(-L|--sysroot=)?/.*?/(build/x86_64-linux-[a-z]+/release/)", r"\1<kairo>/\2", c)
        if c.startswith(str(HERE)):
            c = os.path.relpath(c, HERE)
        elif c.startswith(str(TREE) + os.sep):
            c = "<tree>/" + os.path.relpath(c, TREE)
        out.append(c)
    return " ".join(out)


def build(tc, groups, columns, out, log):
    """Build <out>/bin/<group>.<column>. A column whose program fails to
    build stays empty for that group; the report says so."""
    bindir = out / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    exes, commands, failures = {}, {}, []
    for g in groups:
        for col in columns:
            exe = bindir / f"{g}.{col}"
            if col == "clang":
                cmd = tc.clang_cmd(HERE / "cpp" / f"{g}.cpp", exe)
            elif col == "kcc":
                cmd = tc.kcc_cmd(HERE / "cpp" / f"{g}.cpp", exe)
            elif col == "rust":
                cmd = tc.rust_cmd(HERE / "rust" / f"{g}.rs", exe)
            else:
                cmd = tc.kairo_cmd(HERE / "kairo" / f"{g}.k", exe, out / "kairo-cache")
            src = HERE / SOURCES[col][0] / f"{g}.{SOURCES[col][1]}"
            commands.setdefault(col, shown(cmd).replace(f"{g}.", "<group>."))
            if not src.exists():
                failures.append(f"{g}.{col}: no source ({src.name})")
                continue
            log(f"build {g}.{col}")
            if exe.exists():
                exe.unlink()
            r = sh(cmd)
            if r.returncode != 0 or not exe.exists():
                failures.append(f"{g}.{col}: build failed")
                (out / f"build-{g}.{col}.log").write_text(r.stdout + r.stderr)
                continue
            exes[(g, col)] = exe
            # The kcc column exists to show the heap: its binary must carry
            # the runtime's allocator, and the clang one must not.
            if col in ("clang", "kcc") and tc.defines(exe, "mi_malloc") != (col == "kcc"):
                sys.exit(f"run.py: {exe.name}: the Kairo heap is {'missing' if col == 'kcc' else 'present'}")
    return exes, commands, failures


# --- running -------------------------------------------------------------------

def perf_usable():
    if not shutil.which("perf"):
        return False, "perf is not installed"
    r = sh(["perf", "stat", "-x,", "-e", "instructions:u,cycles:u", "true"])
    ok = r.returncode == 0 and "instructions" in r.stderr and "<not" not in r.stderr
    return ok, "" if ok else "perf stat is not permitted here (kernel.perf_event_paranoid)"


def run_cell(exe, col, row, size, cpu, min_ms=None, reps=None, perf=False):
    """One process for one cell. Returns (ns, reps, ops, check, counters) or
    None when the program has no such row; ns is NaN for a row it skips."""
    env = dict(os.environ)
    cmd = ["taskset", "-c", str(cpu)]
    if perf:
        cmd += ["perf", "stat", "-x,", "-e", "instructions:u,cycles:u", "--"]
    cmd += [str(exe)]
    # A Kairo main takes no arguments, so that column is driven by the
    # environment; the others take the same values as arguments.
    if col in KAIRO_COLUMNS:
        env.update(BENCH_ROW=row, BENCH_SIZE=str(size))
        if min_ms is not None:
            env["BENCH_MIN_MS"] = str(min_ms)
        if reps is not None:
            env["BENCH_REPS"] = str(reps)
    else:
        cmd += [row, str(size)]
        if min_ms is not None:
            cmd.append(f"--min-ms={min_ms}")
        if reps is not None:
            cmd.append(f"--reps={reps}")
    r = sh(cmd, env=env)
    if r.returncode in (-9, 137):
        # The machine's memory guard kills by SIGKILL; wait for room and retry once.
        time.sleep(120)
        r = sh(cmd, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"{exe.name} {row} {size}: exit {r.returncode}\n{r.stderr[-2000:]}")
    line = next((l for l in r.stdout.splitlines() if l.startswith(f"{row},{size},")), None)
    if line is None:
        return None
    _, _, ns, n = line.split(",")
    ops, check, counters = 0, None, {}
    for l in r.stderr.splitlines():
        f = l.split(",")
        if f[0] == "check" and f[1] == row and f[2] == str(size):
            check, ops = f[3], int(f[4])
        elif len(f) > 2 and f[2].startswith(("instructions", "cycles")) and f[0].isdigit():
            counters[f[2].split(":")[0]] = int(f[0])
    return float(ns), int(n), ops, check, counters


def measure(cells, exes, args, perf_ok, log, save):
    """Every cell, in order. A process that fails marks its column's cell
    failed and the run goes on; `save` is called after each cell, so an
    interrupted run leaves what it measured."""
    results = []
    for i, (row, size) in enumerate(cells):
        g = row["group"]
        cols = {c: {} for c in args.columns if (g, c) in exes}
        log(f"[{i + 1}/{len(cells)}] {row['id']} {size}")
        for _ in range(args.repeats):
            for c, cell in cols.items():
                if cell.get("skip"):
                    continue
                try:
                    got = run_cell(exes[(g, c)], c, row["id"], size, args.cpu, min_ms=args.min_ms)
                except RuntimeError as e:
                    cell["skip"] = "failed"
                    cell["error"] = str(e)
                    cell.pop("ns", None)
                    log(f"  {c}: {str(e).splitlines()[0]}")
                    continue
                if got is None or math.isnan(got[0]):
                    cell["skip"] = "absent" if got is None else "not implemented"
                    continue
                ns, reps, ops, check, _ = got
                cell.setdefault("runs", []).append(ns)
                if "ns" not in cell or ns < cell["ns"]:
                    cell.update(ns=ns, reps=reps, ops_per_rep=ops, check=check)
        if perf_ok:
            for c, cell in cols.items():
                if "ns" not in cell:
                    continue
                # Counters cover the whole process, so two runs of K and 2K
                # repetitions are differenced: start-up, input generation and
                # the warm-up repetition cancel. What is left is K repetitions
                # with their untimed per-repetition setup.
                k = max(1, cell["reps"] // 2)
                try:
                    a = run_cell(exes[(g, c)], c, row["id"], size, args.cpu, reps=k, perf=True)[4]
                    b = run_cell(exes[(g, c)], c, row["id"], size, args.cpu, reps=2 * k, perf=True)[4]
                except RuntimeError as e:
                    log(f"  {c}: counters: {str(e).splitlines()[0]}")
                    continue
                for name in ("instructions", "cycles"):
                    # A difference that is not positive is noise (cycles on
                    # a busy machine); the cell then has no counter.
                    if name in a and name in b and b[name] > a[name]:
                        cell[name] = (b[name] - a[name]) / (k * cell["ops_per_rep"])
        checks = {cell["check"] for c, cell in cols.items() if "ns" in cell
                  and (c not in KAIRO_COLUMNS or row.get("kairo_checksum", True))}
        results.append({"id": row["id"], "group": g, "size": size, "columns": cols,
                        "checksums_agree": len(checks) <= 1})
        if len(checks) > 1:
            log(f"  CHECKSUM MISMATCH: " + ", ".join(f"{c}={v.get('check')}" for c, v in cols.items()))
        save(results)
    return results


# --- the report ----------------------------------------------------------------

def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return "?"


def machine():
    model = "?"
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            model = line.split(":", 1)[1].strip()
            break
    cpufreq = "/sys/devices/system/cpu/cpu0/cpufreq/"
    return {
        "cpu": model,
        "governor": read(cpufreq + "scaling_governor"),
        "scaling_driver": read(cpufreq + "scaling_driver"),
        "kernel": platform.release(),
        "load_average": read("/proc/loadavg").split()[:3],
    }


def fmt_ns(x):
    if x is None:
        return ""
    if x >= 100:
        return f"{x:,.0f}"
    if x >= 10:
        return f"{x:.1f}"
    if x >= 1:
        return f"{x:.2f}"
    return f"{x:.3f}"


def fmt_size(n):
    return f"{n:,}"


def ratio(a, b):
    return f"{a / b:.2f}" if a is not None and b else ""


def write_report(path, meta, spec, results):
    kairo_lib = spec["kairo"]["library"]
    head = HEAD
    cols = [c for c in COLUMNS if c in meta["columns"]]
    rows = {r["id"]: r for r in spec["row"]}
    by_group = {}
    for r in results:
        by_group.setdefault(r["group"], []).append(r)

    def times(r):
        return {c: r["columns"].get(c, {}).get("ns") for c in cols}

    def cell_text(c, v):
        # A group with no Kairo program reads `nan`, as a row a program
        # skips does.
        if v is None:
            return "nan" if c == "kairo" else ""
        return fmt_ns(v)

    o = []
    o.append("# Builtin library benchmarks\n")
    if not meta["quiet_machine"]:
        o.append("> **These numbers are noisy.** Other jobs were running on the machine "
                 f"(load average {' '.join(meta['machine']['load_average'])} at the start). "
                 "Read them as a first picture; the numbers to keep come from a `--quiet-machine` run.\n")
    # One line per operation and size, every column, and which one is fastest.
    o.append("## Summary\n")
    o.append("Nanoseconds per operation. `nan`: no Kairo program for that row yet.\n")
    o.append("| Operation | Size | " + " | ".join(f"{head[c]} ns" for c in cols) + " | Fastest |")
    o.append("|---|---:|" + "---:|" * len(cols) + "---|")
    for g in spec["group"]:
        for r in by_group.get(g["id"], []):
            ns = times(r)
            have = {c: v for c, v in ns.items() if v is not None}
            fastest = head[min(have, key=have.get)] if have else ""
            flag = "" if r["checksums_agree"] else " (!)"
            o.append(f"| {rows[r['id']]['label']}{flag} | {fmt_size(r['size'])} | "
                     + " | ".join(cell_text(c, ns[c]) for c in cols) + f" | {fastest} |")
    o.append("")

    o.append("## Run\n")
    m = meta["machine"]
    o.append("| | |\n|---|---|")
    o.append(f"| Date | {meta['date']} |")
    o.append(f"| CPU | {m['cpu']}, benchmarks pinned to CPU {meta['pinned_cpu']} |")
    o.append(f"| Governor | {m['governor']} ({m['scaling_driver']}) |")
    o.append(f"| Kernel | {m['kernel']} |")
    heap = {"kairo": f"{kairo_lib}; heap: mimalloc (the Kairo runtime)",
            "clang": "libc++ of the Kairo sysroot; heap: glibc malloc",
            "kcc": "the same libc++, linked with the Kairo runtime; heap: mimalloc",
            "rust": "std; heap: glibc malloc"}
    for c in cols:
        o.append(f"| {head[c]} | {meta['versions'].get(c, '?')}<br>{heap[c]} |")
    o.append(f"| Target CPU | {meta['target_cpu']}, given to every compiler; -O3 everywhere (commands at the end) |")
    o.append(f"| Protocol | best of {meta['repeats']} processes per cell; in each, the fastest repetition "
             f"after a warm-up, repetitions continuing for at least {meta['min_ms']} ms |")
    o.append(f"| Counters | {meta['perf']} |")
    o.append("")
    o.append("Every time is **nanoseconds per operation**; the row notes under each table say what one "
             "operation is. The fastest cell of a row, among all columns, is **bold**. \"Kairo vs fastest\" "
             "is the Kairo time divided by the fastest of the three baselines (the two C++ columns and "
             "Rust): below 1.00 Kairo wins; \"Kairo vs Rust\" is the same against Rust alone. An empty "
             "cell is a row that column does not implement.\n")
    o.append("The two C++ columns are one compiler, one libc++ and one set of flags. `C++ (clang)` allocates "
             "from the C library (glibc malloc); `C++ (kcc)` links the Kairo runtime, so `malloc` and "
             "`operator new` are mimalloc. The difference between them is the allocator. Rust allocates "
             "from the C library as well, so Kairo against `C++ (kcc)` is the comparison on one heap.\n")
    if meta["failures"]:
        o.append("Problems while building: " + "; ".join(meta["failures"]) + ".\n")
    failed = [f"`{r['id']}` {fmt_size(r['size'])} ({head[c]})" for r in results
              for c, cell in r["columns"].items() if cell.get("skip") == "failed"]
    if failed:
        o.append("**Failed to run** (the cell is empty): " + ", ".join(failed) + ".\n")
    bad = [f"`{r['id']}` {fmt_size(r['size'])}" for r in results if not r["checksums_agree"]]
    if bad:
        o.append("**Checksums disagree** (the columns did not compute the same thing): " + ", ".join(bad) + ".\n")

    ratio_heads = []
    if "kairo" in cols:
        ratio_heads += ["Kairo vs Rust", "Kairo vs fastest"]
    wins = {c: 0 for c in cols}
    for g in spec["group"]:
        rs = by_group.get(g["id"])
        if not rs:
            continue
        o.append(f"## {g['title']}\n")
        o.append(f"Against: {g['against']}.\n")
        o.append("| Operation | Size | " + " | ".join(head[c] for c in cols)
                 + "".join(f" | {h}" for h in ratio_heads) + " |")
        o.append("|---|---:|" + "---:|" * (len(cols) + len(ratio_heads)))
        for r in rs:
            ns = times(r)
            have = [v for v in ns.values() if v is not None]
            best = min(have) if have else None
            cells = []
            for c in cols:
                t = cell_text(c, ns[c])
                if ns[c] is not None and ns[c] == best and len(have) > 1:
                    t = f"**{t}**"
                    wins[c] += 1
                cells.append(t)
            base = [ns[c] for c in BASELINES if ns.get(c) is not None]
            fastest_base = min(base) if base else None
            ratios = []
            if "kairo" in cols:
                ratios += [ratio(ns.get("kairo"), ns.get("rust")), ratio(ns.get("kairo"), fastest_base)]
            flag = "" if r["checksums_agree"] else " (!)"
            o.append(f"| {rows[r['id']]['label']}{flag} | {fmt_size(r['size'])} | " + " | ".join(cells)
                     + "".join(f" | {x}" for x in ratios) + " |")
        o.append("")
        if any("instructions" in c for r in rs for c in r["columns"].values()):
            o.append("Instructions / cycles per operation (user mode, including each repetition's untimed setup):\n")
            o.append("| Operation | Size | " + " | ".join(head[c] for c in cols) + " |")
            o.append("|---|---:|" + "---:|" * len(cols))
            for r in rs:
                cells = []
                for c in cols:
                    cell = r["columns"].get(c, {})
                    cells.append(f"{fmt_ns(cell['instructions'])} / {fmt_ns(cell['cycles'])}"
                                 if cell.get("instructions") and cell.get("cycles") else "")
                o.append(f"| {rows[r['id']]['label']} | {fmt_size(r['size'])} | " + " | ".join(cells) + " |")
            o.append("")
        o.append("Rows:\n")
        seen = set()
        for r in rs:
            if r["id"] in seen:
                continue
            seen.add(r["id"])
            d = rows[r["id"]]
            o.append(f"- **{d['label']}** (`{d['id']}`): one operation is {d['op']}. Timed: {d['timed']}. "
                     f"Size: {d['size']}. C++: {d['cpp']}. Rust: {d['rust']}. Kairo: {d['kairo']}.")
        o.append("")

    o.append("## Fastest column, by count of cells\n")
    o.append("| " + " | ".join(head[c] for c in cols) + " |")
    o.append("|" + "---:|" * len(cols))
    o.append("| " + " | ".join(str(wins[c]) for c in cols) + " |")
    o.append("")
    o.append("## Build commands\n")
    o.append("`<kairo>` is the checkout that holds the installed toolchain, `<tree>` the one that holds "
             "these benchmarks; `<group>` is each group id.\n")
    for c in cols:
        o.append(f"{head[c]}:\n\n```\n{meta['commands'].get(c, '(not built)')}\n```\n")
    path.write_text("\n".join(o))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--groups", help="comma-separated group ids (default: all)")
    ap.add_argument("--rows", help="only rows whose id matches this regex")
    ap.add_argument("--columns", default=",".join(COLUMNS), help="comma-separated: " + ",".join(COLUMNS))
    ap.add_argument("--repeats", type=int, help="processes per cell (default 3; 7 with --quiet-machine)")
    ap.add_argument("--min-ms", type=int, help="timed milliseconds per process (default 200)")
    ap.add_argument("--quick", action="store_true", help="1 process of 20 ms per cell, no counters")
    ap.add_argument("--quiet-machine", action="store_true",
                    help="the machine is idle: more repetitions, and the report drops its noise warning")
    ap.add_argument("--no-perf", action="store_true", help="skip the instructions/cycles pass")
    ap.add_argument("--report-only", action="store_true",
                    help="write report.md again from the results.json in --out; build and run nothing")
    ap.add_argument("--cpu", type=int, help="CPU to pin to (default: the last one this process may use)")
    ap.add_argument("--out", default=str(HERE / "out"), help="output directory")
    ap.add_argument("--toolchain", help="the toolchain's bin/ (kairo, kcc, clang++, llvm-nm)")
    ap.add_argument("--kairo")
    ap.add_argument("--kcc")
    ap.add_argument("--clang")
    ap.add_argument("--rustc", default="rustc")
    ap.add_argument("--cpu-name", help="target CPU for every compiler (default: clang's -march=native)")
    args = ap.parse_args()

    args.columns = [c for c in args.columns.split(",") if c]
    if args.repeats is None:
        args.repeats = 1 if args.quick else 7 if args.quiet_machine else 3
    if args.min_ms is None:
        args.min_ms = 20 if args.quick else 200
    if args.cpu is None:
        args.cpu = max(os.sched_getaffinity(0))

    spec = tomllib.loads((HERE / "ops.toml").read_text())
    for r in spec["row"]:
        r.setdefault("group", r["id"].split(".")[0])
    groups = [g["id"] for g in spec["group"]]
    if args.groups:
        groups = [g for g in groups if g in args.groups.split(",")]
    cells = [(r, s) for r in spec["row"] if r["group"] in groups
             and (not args.rows or re.search(args.rows, r["id"])) for s in r["sizes"]]

    def log(msg):
        print(msg, file=sys.stderr, flush=True)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.report_only:
        saved = json.loads((out / "results.json").read_text())
        write_report(out / "report.md", saved["meta"], spec, saved["results"])
        return
    tc = Toolchain(args)
    exes, commands, failures = build(tc, groups, args.columns, out, log)

    # Every program must hold exactly the cells ops.toml lists for its group.
    for (g, col), exe in exes.items():
        env = dict(os.environ, BENCH_ROW="list")
        have = set(sh([exe, "list"], env=env).stdout.split())
        want = {f"{r['id']},{s}" for r in spec["row"] if r["group"] == g for s in r["sizes"]}
        if have != want:
            failures.append(f"{g}.{col}: rows differ from ops.toml "
                            f"(missing {sorted(want - have)}, extra {sorted(have - want)})")

    perf_ok, perf_why = perf_usable()
    if args.quick or args.no_perf:
        perf_ok, perf_why = False, "not collected in this run"
    meta = {
        "date": datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z"),
        "machine": machine(),
        "pinned_cpu": args.cpu,
        "columns": args.columns,
        "versions": tc.versions(),
        "tree": str(TREE),
        "commands": commands,
        "target_cpu": tc.cpu,
        "repeats": args.repeats,
        "min_ms": args.min_ms,
        "quiet_machine": args.quiet_machine,
        "perf": "instructions and cycles per operation from `perf stat` (user mode), "
                "as the difference between runs of K and 2K repetitions" if perf_ok else perf_why,
        "failures": failures,
    }

    def save(results):
        (out / "results.json").write_text(json.dumps({"meta": meta, "results": results}, indent=1))

    results = measure(cells, exes, args, perf_ok, log, save)
    write_report(out / "report.md", meta, spec, results)
    log(f"wrote {out / 'report.md'} and {out / 'results.json'}")
    for f in failures:
        log(f"warning: {f}")
    if any(cell.get("skip") == "failed" for r in results for cell in r["columns"].values()):
        sys.exit("run.py: some cells failed to run (see the report)")
    if any(not r["checksums_agree"] for r in results):
        sys.exit("run.py: some rows' checksums disagree between columns (see the report)")


if __name__ == "__main__":
    main()
