#!/usr/bin/env python3
"""Build the builtin-library benchmark rows in every language and measure
each cell for time and hardware counters.

    python3 lib_bench.py                                 every cell, every column
    python3 lib_bench.py --cells slice.binary_search:1024,map.lookup_hit:100000
    python3 lib_bench.py --rows 'map\\.lookup' --columns kairo,clang,rust
    python3 lib_bench.py --kairo-before <old>/bin/kairo  adds a "Kairo before" column
    python3 lib_bench.py --report-only                   report.md again from results.json

Per cell (row and size) and column this reports nanoseconds per operation
from the protocol's own timer (cpp/bench.h), and from `perf stat`, with K and
2K repetitions differenced: instructions, cycles, IPC, branch misses, L1 data
cache load misses and last-level (DRAM) misses per operation. Each figure is
the median of several runs, interleaved across the columns, with its spread.
lib_bench.md has the rules; run.py's README the protocol.

Output, under --out (default: out/lib/ beside this file): bin/, results.json
(every raw count) and report.md.
"""

import argparse
import concurrent.futures
import datetime
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402  (the four-column harness: toolchain discovery, clang/kcc/rust/kairo commands)

# Column id -> (heading, source directory). Order is the report's order.
COLUMNS = {
    "kairo_before": ("Kairo before", "kairo"),
    "kairo": ("Kairo", "kairo"),
    "clang": ("clang", "cpp"),
    "kcc": ("kcc", "cpp"),
    "gcc": ("gcc", "cpp"),
    "rust": ("Rust", "rust"),
    "zig": ("Zig", "zig"),
    "go": ("Go", "go"),
    "gdc": ("D (gdc)", "d"),
    "ldc": ("LDC", "d"),
    "nim": ("Nim", "nim"),
    "swift": ("Swift", "swift"),
}
KAIRO_COLUMNS = ("kairo", "kairo_before")
# Whether each column's build keeps index bounds checks. The columns are built
# at each language's usual release setting, and those differ: a figure from an
# unchecked column is not a like-for-like comparison with a checked one, so
# the report shows this beside every best-other pick.
SAFETY = {
    "kairo_before": (True, "as that compiler's library does"),
    "kairo": (True, "every index of a slice, vector and string is checked"),
    "clang": (False, "operator[]; libc++ hardening mode none"),
    "kcc": (False, "operator[]; libc++ hardening mode none"),
    "gcc": (False, "operator[]; libstdc++ without _GLIBCXX_ASSERTIONS"),
    "rust": (True, "indexing is checked"),
    "zig": (False, "ReleaseFast removes safety checks"),
    "go": (True, "indexing is checked"),
    "gdc": (False, "-frelease removes bounds checks outside @safe code; only the map keys' hash and "
                   "equality and the input generator are @safe"),
    "ldc": (False, "-release removes bounds checks outside @safe code; only the map keys' hash and "
                   "equality and the input generator are @safe"),
    "nim": (False, "-d:danger removes every runtime check"),
    "swift": (True, "-O keeps the checks (-Ounchecked would remove them)"),
}
GROUPS = ["string", "slice", "vector", "map", "hash", "num", "iter", "alloc"]

# Counter passes. A pass is one `perf stat` call; four events fit the
# general-purpose counters of current x86 cores beside the NMI watchdog's, so
# no pass is multiplexed (scaled) and the K/2K difference is exact.
CORE_EVENTS = ["instructions", "cycles", "branches", "branch-misses"]
L1D_EVENTS = ["L1-dcache-load-misses"]
# The last-level miss, first event set the CPU counts. Several events in a set
# are summed. AMD Zen has no LLC-load-misses: its demand fills from DRAM are
# the loads that missed every cache level.
LLC_CANDIDATES = [
    ["LLC-load-misses"],
    ["ls_dmnd_fills_from_sys.dram_io_near", "ls_dmnd_fills_from_sys.dram_io_far"],
    ["mem_load_retired.l3_miss"],
]
# Metric id -> (heading, lower is better). ns comes from the timer, the rest
# from the counters.
METRICS = {
    "ns": ("ns/op", True),
    "instructions": ("instructions/op", True),
    "cycles": ("cycles/op", True),
    "ipc": ("IPC", False),
    "branch_misses": ("branch misses/op", True),
    "l1d_misses": ("L1d misses/op", True),
    "llc_misses": ("LLC misses/op", True),
}
# Counters at or below this many per operation in both columns are a tie:
# a relative margin of two near-zero numbers is noise.
TIE_FLOOR = 0.01
TIE_REL = 0.005


def sh(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def load1():
    try:
        return float(Path("/proc/loadavg").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return float("nan")


def cpu_siblings(cpu):
    """`cpu` and its SMT siblings."""
    try:
        text = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list").read_text().strip()
    except OSError:
        return [cpu]
    out = []
    for part in text.split(","):
        a, _, b = part.partition("-")
        out += range(int(a), int(b or a) + 1)
    return out or [cpu]


def cpu_times():
    t = {}
    for line in Path("/proc/stat").read_text().splitlines():
        f = line.split()
        if f[0].startswith("cpu") and f[0] != "cpu":
            v = [int(x) for x in f[1:]]
            t[int(f[0][3:])] = (sum(v), v[3] + v[4])  # total, idle + iowait
    return t


def cpus_busy(cpus, secs=1.0):
    """The busiest share of time among `cpus` over `secs`. The 1-minute load
    average lags and covers the whole machine; this sees the pinned core and
    its SMT sibling, which share the counters' and the timer's pipeline."""
    try:
        a = cpu_times()
        time.sleep(secs)
        b = cpu_times()
    except (OSError, ValueError):
        return float("nan")
    busy = []
    for c in cpus:
        if c in a and c in b and b[c][0] > a[c][0]:
            total, idle = b[c][0] - a[c][0], b[c][1] - a[c][1]
            busy.append(1.0 - idle / total)
    return max(busy) if busy else float("nan")


def quiet(args):
    """(quiet, load, cpu busy share) of the machine right now."""
    load = load1()
    busy = cpus_busy(args.cpus)
    ok = not (load > args.max_load) and not (busy > args.max_cpu_busy)
    return ok, load, busy


class NotQuiet(Exception):
    pass


def wait_quiet(args, what):
    """Wait until the machine is quiet before `what`, at most --settle seconds.
    A build or another job leaves the 1-minute load high for a minute or two
    after it ends, so the cells after the builds would otherwise start busy.
    With --force nothing waits; the cell is marked instead."""
    ok, load, busy = quiet(args)
    if ok or args.force:
        return load, busy
    log(f"waiting for a quiet machine before {what} (load {load:.1f}, CPU {args.cpu} busy {busy:.0%})")
    t0 = time.time()
    while time.time() - t0 < args.settle:
        time.sleep(10)
        ok, load, busy = quiet(args)
        if ok:
            log(f"  quiet after {time.time() - t0:.0f} s")
            return load, busy
    raise NotQuiet(f"lib_bench.py: the machine did not become quiet within {args.settle} s before {what} "
             f"(load {load:.1f}, above {args.max_load:.1f}, or CPUs {args.cpus} busy {busy:.0%}, above "
             f"{args.max_cpu_busy:.0%}); pass --force to measure anyway")


# --- events ----------------------------------------------------------------------

def perf_events_ok(events):
    r = sh(["perf", "stat", "-x,", "-e", ",".join(e + ":u" for e in events), "true"])
    if r.returncode != 0:
        return False
    seen = [l.split(",") for l in r.stderr.splitlines() if l.count(",") >= 3]
    return len(seen) == len(events) and all(f[0].isdigit() for f in seen)


def choose_passes(want_cache):
    """The counter passes this machine supports, as [(name, [events])], and
    a note for the report."""
    if not shutil.which("perf"):
        return [], "perf is not installed: no counters"
    if not perf_events_ok(CORE_EVENTS):
        return [], "perf stat may not count user-mode events here (kernel.perf_event_paranoid): no counters"
    passes = [("core", CORE_EVENTS)]
    notes = []
    if want_cache:
        cache = list(L1D_EVENTS) if perf_events_ok(L1D_EVENTS) else []
        if not cache:
            notes.append("no L1-dcache-load-misses on this CPU")
        llc = next((c for c in LLC_CANDIDATES if perf_events_ok(cache + c)), None)
        if llc is None:
            notes.append("no last-level miss event on this CPU")
        else:
            cache += llc
        if cache:
            passes.append(("cache", cache))
    return passes, "; ".join(notes)


# --- the toolchain and the build commands ---------------------------------------

def find_swiftc():
    p = shutil.which("swiftc")
    if p:
        return p
    cand = Path.home() / ".local" / "share" / "swiftly" / "bin" / "swiftc"
    return str(cand) if cand.exists() else None


def host_goamd64():
    flags = set()
    for line in Path("/proc/cpuinfo").read_text().splitlines():
        if line.startswith("flags"):
            flags = set(line.split(":", 1)[1].split())
            break
    v2 = {"cx16", "popcnt", "sse4_1", "sse4_2", "ssse3"}
    v3 = v2 | {"avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "abm", "movbe", "xsave"}
    v4 = v3 | {"avx512f", "avx512bw", "avx512cd", "avx512dq", "avx512vl"}
    for level, need in (("v4", v4), ("v3", v3), ("v2", v2)):
        if need <= flags:
            return level
    return "v1"


def goamd64(cpu):
    """Go takes a microarchitecture level, not a CPU name: the level a named
    baseline means, else the highest level the host supports."""
    if cpu == "x86-64":
        return "v1"
    m = re.fullmatch(r"x86-64-v([234])", cpu)
    return f"v{m.group(1)}" if m else host_goamd64()


class Tools:
    def __init__(self, args):
        self.args = args
        self.tc = run.Toolchain(args)
        self.cpu = self.tc.cpu
        self.found = {
            "gcc": shutil.which(args.gxx),
            "rust": shutil.which(args.rustc),
            "zig": shutil.which(args.zig),
            "go": shutil.which(args.go),
            "gdc": shutil.which(args.gdc),
            "ldc": shutil.which(args.ldc2),
            "nim": shutil.which(args.nim),
            "swift": args.swiftc or find_swiftc(),
            "kairo": str(self.tc.kairo) if Path(self.tc.kairo).exists() else None,
            "clang": str(self.tc.clang) if Path(self.tc.clang).exists() else None,
            "kcc": str(self.tc.kcc) if Path(self.tc.kcc).exists() else None,
            "kairo_before": args.kairo_before,
        }

    def command(self, col, g, exe, out):
        """(argv, cwd, extra environment) that builds group `g` for `col`."""
        cpu, d = self.cpu, HERE / COLUMNS[col][1]
        cache = out / "cache"
        if col == "kairo":
            return self.tc.kairo_cmd(d / f"{g}.k", exe, cache / "kairo" / g), None, {}
        if col == "kairo_before":
            return ([self.found[col], d / f"{g}.k", "-I", HERE / "cpp", "-O3", "--mcpu", cpu,
                     "--cache-dir", cache / "kairo-before" / g, "-o", exe], None, {})
        if col == "clang":
            return self.tc.clang_cmd(d / f"{g}.cpp", exe), None, {}
        if col == "kcc":
            # Two steps: -std=c++20 on a kcc line that also holds a .k input
            # reaches that input's compile and breaks it, so the C++ is
            # compiled alone and the object linked with the anchor.
            obj = cache / f"kcc-{g}.o"
            return ([[self.found[col], "-std=c++20", "-O3", f"-march={cpu}", "-c", d / f"{g}.cpp", "-o", obj],
                     [self.found[col], "-O3", f"-march={cpu}", obj, HERE / "cpp" / "kcc_anchor.k", "-o", exe]],
                    None, {})
        if col == "gcc":
            return [self.found[col], "-std=c++20", "-O3", f"-march={cpu}", d / f"{g}.cpp", "-o", exe], None, {}
        if col == "rust":
            return self.tc.rust_cmd(d / f"{g}.rs", exe), None, {}
        if col == "zig":
            return ([self.found[col], "build-exe", "-O", "ReleaseFast", f"-mcpu={cpu.replace('-', '_')}",
                     "-lc", d / f"{g}.zig", f"-femit-bin={exe}", "--cache-dir", cache / "zig"], None, {})
        if col == "go":
            return ([self.found[col], "build", "-o", exe, "bench.go", f"{g}.go"], d,
                    {"GOAMD64": goamd64(cpu)})
        if col == "gdc":
            return ([self.found[col], "-O3", "-frelease", "-fno-weak-templates", f"-march={cpu}",
                     f"-I{d}", d / "bench.d", d / f"{g}.d", "-o", exe], None, {})
        if col == "ldc":
            return ([self.found[col], "-O3", "-release", f"-mcpu={cpu}", f"-I={d}", d / "bench.d",
                     d / f"{g}.d", f"-of={exe}", f"-od={cache / ('ldc-' + g)}"], None, {})
        if col == "nim":
            return ([self.found[col], "c", "-d:danger", "--hints:off", f"--passC:-march={cpu}",
                     f"--nimcache:{cache / ('nim-' + g)}", f"-o:{exe}", d / f"{g}.nim"], None, {})
        if col == "swift":
            return ([self.found[col], "-O", "-parse-as-library", "-target-cpu", cpu,
                     d / "bench.swift", d / f"{g}.swift", "-o", exe], None, {})
        raise KeyError(col)

    def source(self, col, g):
        ext = {"kairo": "k", "kairo_before": "k", "clang": "cpp", "kcc": "cpp", "gcc": "cpp",
               "rust": "rs", "zig": "zig", "go": "go", "gdc": "d", "ldc": "d", "nim": "nim",
               "swift": "swift"}[col]
        return HERE / COLUMNS[col][1] / f"{g}.{ext}"

    def version(self, col):
        tool = self.found.get(col)
        if not tool:
            return "?"
        arg = {"zig": ["version"], "go": ["version"]}.get(col, ["--version"])
        return run.first_line([tool, *arg])


def steps(cmd):
    """A build command is one argv or a list of argvs run in order."""
    return cmd if isinstance(cmd[0], list) else [cmd]


def shown(cmd, env, cwd):
    text = " && ".join(run.shown(c) for c in steps(cmd))
    pre = " ".join(f"{k}={v}" for k, v in env.items())
    where = f"(in {os.path.relpath(cwd, HERE)}) " if cwd else ""
    return where + (pre + " " if pre else "") + text


def build(tools, groups, columns, out, jobs):
    """Build <out>/bin/<group>.<column> with `jobs` builds at a time. A
    column whose tool is missing or whose program fails to build stays empty
    for that group; the report says why."""
    bindir = out / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    (out / "cache").mkdir(exist_ok=True)
    exes, commands, notes = {}, {}, []
    todo = []
    for col in columns:
        if not tools.found.get(col):
            notes.append(f"{COLUMNS[col][0]}: tool not found, column skipped")
            continue
        for g in groups:
            if not tools.source(col, g).exists():
                notes.append(f"{g}.{col}: no source")
                continue
            exe = bindir / f"{g}.{col}"
            cmd, cwd, env = tools.command(col, g, exe, out)
            commands.setdefault(col, {})[g] = shown(cmd, env, cwd)
            todo.append((col, g, exe, cmd, cwd, env))

    def one(item):
        col, g, exe, cmd, cwd, env = item
        if exe.exists():
            exe.unlink()
        t0 = time.time()
        for c in steps(cmd):
            r = sh(c, cwd=cwd, env=dict(os.environ, **env))
            if r.returncode != 0:
                break
        return item, r, time.time() - t0

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for (col, g, exe, *_), r, secs in pool.map(one, todo):
            if r.returncode != 0 or not exe.exists():
                (out / f"build-{g}.{col}.log").write_text(r.stdout + r.stderr)
                first = next((l for l in (r.stdout + r.stderr).splitlines() if "error" in l.lower()), "")
                notes.append(f"{g}.{col}: build failed ({first.strip()[:160]})")
                log(f"build {g}.{col}: FAILED, see build-{g}.{col}.log")
                continue
            log(f"build {g}.{col}: {secs:.0f} s")
            # The kcc column exists to show the heap: its binary must carry
            # the runtime's allocator, and the clang one must not.
            if col in ("clang", "kcc") and tools.tc.defines(exe, "mi_malloc") != (col == "kcc"):
                sys.exit(f"lib_bench.py: {exe.name}: the Kairo heap is {'missing' if col == 'kcc' else 'present'}")
            exes[(g, col)] = exe
    return exes, commands, notes


# --- running ---------------------------------------------------------------------

def run_proc(exe, row, size, cpu, min_ms=None, reps=None, events=None):
    """One process for one cell. Every program reads BENCH_ROW, BENCH_SIZE,
    BENCH_MIN_MS and BENCH_REPS (a Kairo main takes no arguments), so every
    column is driven the same way. Returns None for a cell the program does
    not hold, else a dict; its ns is NaN for a row the program skips."""
    env = dict(os.environ, BENCH_ROW=row, BENCH_SIZE=str(size))
    if min_ms is not None:
        env["BENCH_MIN_MS"] = str(min_ms)
    if reps is not None:
        env["BENCH_REPS"] = str(reps)
    cmd = ["taskset", "-c", str(cpu)]
    if events:
        cmd += ["perf", "stat", "-x,", "-e", ",".join(e + ":u" for e in events), "--"]
    cmd.append(str(exe))
    load = load1()
    r = sh(cmd, env=env)
    if r.returncode in (-9, 137):
        # The machine's memory guard kills by SIGKILL; wait for room and retry once.
        time.sleep(120)
        load = load1()
        r = sh(cmd, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"{exe.name} {row} {size}: exit {r.returncode}\n{r.stderr[-2000:]}")
    line = next((l for l in r.stdout.splitlines() if l.startswith(f"{row},{size},")), None)
    if line is None:
        return None
    _, _, ns, n = line.split(",")
    got = {"ns": float(ns), "reps": int(n), "ops": 0, "check": None, "load": load, "counters": {},
           "scaled": []}
    for l in r.stderr.splitlines():
        f = l.split(",")
        if f[0] == "check" and len(f) >= 5 and f[1] == row and f[2] == str(size):
            got["check"], got["ops"] = f[3], int(f[4])
        elif events and len(f) >= 5 and f[2].split(":")[0] in events:
            name = f[2].split(":")[0]
            got["counters"][name] = int(f[0]) if f[0].isdigit() else None
            try:
                if float(f[4]) < 100.0:
                    got["scaled"].append(name)
            except ValueError:
                got["scaled"].append(name)
    return got


def derive(k, ops, a, b, passes):
    """Per-operation metrics of one run from the K and 2K counts of each pass."""
    m = {}
    per = k * ops

    def diff(pass_name, names):
        da, db = a.get(pass_name, {}), b.get(pass_name, {})
        if any(da.get(n) is None or db.get(n) is None for n in names):
            return None
        return sum(db[n] - da[n] for n in names)

    for name, events in passes:
        if name == "core":
            ins, cyc = diff("core", ["instructions"]), diff("core", ["cycles"])
            # Instructions and cycles only grow with repetitions; a difference
            # that is not positive is a disturbed run and is dropped.
            if ins is not None and ins > 0:
                m["instructions"] = ins / per
            if cyc is not None and cyc > 0:
                m["cycles"] = cyc / per
            if ins and cyc and ins > 0 and cyc > 0:
                m["ipc"] = ins / cyc
            br = diff("core", ["branch-misses"])
            if br is not None:
                m["branch_misses"] = br / per
        else:
            l1 = [e for e in events if e in L1D_EVENTS]
            llc = [e for e in events if e not in L1D_EVENTS]
            if l1 and (v := diff(name, l1)) is not None:
                m["l1d_misses"] = v / per
            if llc and (v := diff(name, llc)) is not None:
                m["llc_misses"] = v / per
    return m


def measure_cell(cell, cols, exes, args, passes):
    """Every run of one cell. Columns run interleaved: each round runs every
    column once, starting one column later than the round before."""
    row, size, g = cell["id"], cell["size"], cell["group"]
    res = {c: {"runs": []} for c in cols if (g, c) in exes}
    order = list(res)
    for rnd in range(args.runs):
        for c in order[rnd % len(order):] + order[:rnd % len(order)] if order else []:
            st = res[c]
            if st.get("skip"):
                continue
            try:
                t = run_proc(exes[(g, c)], row, size, args.cpu, min_ms=args.min_ms)
                if t is None or math.isnan(t["ns"]):
                    st["skip"] = "absent" if t is None else "not implemented"
                    continue
                k = st.setdefault("k", args.k or max(1, t["reps"] // 2))
                a, b, raw = {}, {}, {"timed": t}
                for name, events in passes:
                    pa = run_proc(exes[(g, c)], row, size, args.cpu, reps=k, events=events)
                    pb = run_proc(exes[(g, c)], row, size, args.cpu, reps=2 * k, events=events)
                    if pa is None or pb is None:
                        raise RuntimeError(f"{exes[(g, c)].name} {row} {size}: no result line in a counted process")
                    a[name], b[name] = pa["counters"], pb["counters"]
                    raw[f"{name}_k"], raw[f"{name}_2k"] = pa, pb
                metrics = derive(k, t["ops"], a, b, passes)
                metrics["ns"] = t["ns"]
                loads = [t["load"]] + [raw[x]["load"] for x in raw if x != "timed"]
                scaled = sorted({e for x in raw.values() for e in x.get("scaled", [])})
                checks = {x["check"] for x in raw.values()}
                st["runs"].append({"metrics": metrics, "raw": raw, "load_max": max(loads),
                                   "scaled": scaled, "checks": sorted(c_ for c_ in checks if c_)})
                st["check"], st["ops_per_rep"] = t["check"], t["ops"]
            except RuntimeError as e:
                st["skip"] = "failed"
                st["failed_after"] = len(st["runs"])
                st["error"] = str(e)
                log(f"  {c}: {str(e).splitlines()[0]}")
    for c, st in res.items():
        if st["runs"]:
            st["summary"] = summarize([r["metrics"] for r in st["runs"]])
            st["load_max"] = max(r["load_max"] for r in st["runs"])
            st["scaled"] = sorted({e for r in st["runs"] for e in r["scaled"]})
            # One program printing two checksums for a cell across its own
            # processes is as wrong as two columns disagreeing.
            st["self_consistent"] = len({x for r in st["runs"] for x in r["checks"]}) <= 1
    return res


def summarize(runs):
    out = {}
    for m in METRICS:
        vals = [r[m] for r in runs if m in r]
        if m.endswith("misses"):
            # A miss count near zero differences to small negative numbers;
            # the count itself is never below zero. results.json keeps the raw runs.
            vals = [max(v, 0.0) for v in vals]
        if vals:
            out[m] = {"median": statistics.median(vals), "min": min(vals), "max": max(vals), "n": len(vals)}
    return out


def checksum_verdict(cell, res):
    """(agree, majority checksum, dissenting columns). A row whose result is
    the library's own hash (kairo_checksum = false) leaves the Kairo columns
    out of the comparison."""
    exempt = KAIRO_COLUMNS if not cell.get("kairo_checksum", True) else ()
    votes = {}
    for c, st in res.items():
        if st.get("runs") and c not in exempt:
            votes.setdefault(st["check"], []).append(c)
    bad_self = [c for c, st in res.items() if st.get("runs") and not st.get("self_consistent", True)]
    if not votes:
        return True, None, bad_self
    major = max(votes, key=lambda v: len(votes[v]))
    dissent = sorted(c for v, cs in votes.items() if v != major for c in cs) + bad_self
    return not dissent, major, dissent


# --- the cells -------------------------------------------------------------------

def discover_cells(spec, exes, groups):
    """Every (row, size) the built programs hold, in ops.toml's order, then
    the rows ops.toml does not list in the order the programs print them."""
    held = {}
    for g in groups:
        for (gg, col), exe in sorted(exes.items()):
            if gg != g:
                continue
            r = sh([exe], env=dict(os.environ, BENCH_ROW="list"))
            for line in r.stdout.split():
                rid, _, size = line.partition(",")
                if size.isdigit():
                    held.setdefault((rid, int(size)), g)
    rows = {r["id"]: r for r in spec["row"]}
    cells = []
    for r in spec["row"]:
        for s in r["sizes"]:
            if (r["id"], s) in held:
                cells.append({"id": r["id"], "size": s, "group": held.pop((r["id"], s)),
                              "label": r["label"], "op": r["op"],
                              "kairo_checksum": r.get("kairo_checksum", True)})
    for (rid, s), g in held.items():
        d = rows.get(rid, {})
        cells.append({"id": rid, "size": s, "group": g, "label": d.get("label", rid),
                      "op": d.get("op"), "kairo_checksum": d.get("kairo_checksum", True)})
    return cells


def group_of(spec, rid):
    for r in spec["row"]:
        if r["id"] == rid:
            return r.get("group", rid.split(".")[0])
    return rid.split(".")[0]


# --- the report ------------------------------------------------------------------

def fmt(x):
    if x is None:
        return "–"
    if abs(x) >= 1e6:
        return f"{x / 1e6:.2f}M"
    if abs(x) >= 100:
        return f"{x:,.0f}"
    if abs(x) >= 10:
        return f"{x:.1f}"
    if abs(x) >= 1:
        return f"{x:.2f}"
    return f"{x:.3f}"


def plural(n, word):
    return f"{n} {word}" + ("" if n == 1 else "s")


def spread(s):
    """Spread of a metric as a share of its median."""
    if not s or not s["median"]:
        return None
    return (s["max"] - s["min"]) / abs(s["median"])


def compare(metric, k, best):
    """'ahead', 'tied' or 'behind' of Kairo's summary `k` against the best
    other column's `best`, and the margin (+ = Kairo better), as a share of
    best. ns ties when the two ranges of runs overlap; a counter ties within
    0.5%, or when both are below TIE_FLOOR per operation."""
    km, bm = k["median"], best["median"]
    margin = (bm - km) / abs(bm) if bm else None
    if metric == "ns":
        tied = k["min"] <= best["max"] and best["min"] <= k["max"]
    else:
        tied = (abs(km) <= TIE_FLOOR and abs(bm) <= TIE_FLOOR) or (margin is not None and abs(margin) <= TIE_REL)
    if tied:
        # Two near-zero counts have no meaningful ratio.
        return "tied", None if metric != "ns" and abs(km) <= TIE_FLOOR else margin
    return ("ahead" if km < bm else "behind"), margin


def eligible(r, c):
    """Whether column `c` of cell `r` may set the best other figure: a column
    that computed a different checksum, printed two checksums, or failed
    partway (its summary covers only the runs before the failure) is shown in
    the cell's table but sets no margin."""
    st = r["columns"][c]
    return (c not in KAIRO_COLUMNS and c not in r.get("checksum_dissent", [])
            and st.get("self_consistent", True) and st.get("skip") != "failed")


def best_other(r, metric, heads):
    res = r["columns"]
    have = [(c, st["summary"][metric]) for c, st in res.items()
            if eligible(r, c) and metric in st.get("summary", {})]
    if not have:
        return None, None
    lower = METRICS[metric][1]
    pick = min if lower else max
    v = pick(s["median"] for _, s in have)
    who = [c for c, s in have if s["median"] == v]
    return dict(have)[who[0]], " / ".join(heads[c] + ("" if SAFETY[c][0] else "*") for c in who)


def write_report(path, meta, results):
    heads = {c: COLUMNS[c][0] for c in COLUMNS}
    cols = [c for c in COLUMNS if c in meta["columns"]]
    # The figures are derived from the raw runs here, so --report-only
    # applies the current rules to a saved results.json.
    for r in results:
        for st in r["columns"].values():
            if st.get("runs"):
                st["summary"] = summarize([x["metrics"] for x in st["runs"]])
    o = []
    o.append("# Builtin library benchmarks: time and counters\n")
    busy = [r for r in results if r.get("busy")]
    if meta["forced"] or busy:
        o.append(f"> **Measured on a busy machine.** The 1-minute load average went above the threshold "
                 f"({meta['max_load']}), or the pinned core was busy, on {len(busy)} of {len(results)} cells (marked BUSY). Instruction "
                 "counts hold up under load; ns/op, cycles and the cache misses do not. Keep numbers from "
                 "a run without --force.\n")
    o.append("## Run\n")
    m = meta["machine"]
    o.append("| | |\n|---|---|")
    o.append(f"| Date | {meta['date']} |")
    o.append(f"| CPU | {m['cpu']}; every process pinned to CPU {meta['pinned_cpu']} with taskset |")
    o.append(f"| Governor | {m['governor']} ({m['scaling_driver']}), kernel {m['kernel']} |")
    o.append(f"| Load | 1-minute average {meta['load_start']} at the start; threshold {meta['max_load']} |")
    o.append(f"| Target CPU | {meta['target_cpu']}, given to every compiler (Go: GOAMD64={meta['goamd64']}) |")
    o.append(f"| Runs | {meta['runs']} per cell and column, interleaved; each run is one timed process "
             f"(at least {meta['min_ms']} ms of repetitions) and, per counter pass, processes of K and 2K "
             f"repetitions ({meta['k_policy']}) |")
    o.append(f"| Counters | {meta['counters']} |")
    if "cpu_busy_threshold" in meta:
        o.append(f"| Pinned core | CPUs {meta['quiet_cpus']} (the pinned CPU and its SMT siblings) at most "
                 f"{meta['cpu_busy_threshold']:.0%} busy over 1 s before each cell; the cell tables show the share |")
    o.append("")
    o.append("| Column | Version | Bounds checks |\n|---|---|---|")
    for c in cols:
        checked, why = SAFETY[c]
        o.append(f"| {heads[c]} | {meta['versions'].get(c, '?')} | {'kept' if checked else '**removed**'}: {why} |")
    o.append("")
    o.append("Every column is built at its language's usual release setting (the build commands are at the end), "
             "and those settings differ in safety: the columns marked * in a Best other cell run without "
             "bounds checks, where Kairo keeps them.\n")
    o.append("Each figure is the median of the runs. ns/op is the protocol's own timer: the fastest "
             "repetition of the timed process divided by its operations, and it covers the timed region "
             "only. The counters are user-mode `perf stat` counts of whole processes, K and 2K repetitions "
             "differenced and divided by K repetitions' operations: start-up, input generation and the "
             "warm-up cancel, but each repetition's untimed setup does not, so on rows with a large setup "
             "(the sorts copy their input) cycles/op can exceed what ns/op implies. ns/op is also the fastest repetition, where a counter is the mean of K, so on a busy machine cycles/op runs above ns/op times the clock. IPC = differenced "
             "instructions / differenced cycles. LLC misses: "
             f"{meta['llc_event']}.\n")
    o.append("Margin: how much less (+) or more (-) Kairo spends than the best other column, as a share of "
             "that column's figure. A counter within 0.5% is tied (both below 0.01 per operation also ties); "
             "ns/op is tied when the min..max ranges of the two columns' runs overlap.\n")
    for n in meta["notes"]:
        o.append(f"- {n}")
    if meta["notes"]:
        o.append("")
    bad = [f"`{r['id']}` {r['size']:,} ({', '.join(heads[c] for c in r['checksum_dissent'])})"
           for r in results if not r["checksums_agree"]]
    if bad:
        o.append("**Checksums disagree** (those columns did not compute the same thing): " + "; ".join(bad) + ".\n")

    def k_summary(r, c, metric):
        return r["columns"].get(c, {}).get("summary", {}).get(metric)

    def line_for(r, metrics):
        notes = [f"{heads[c]} failed after {st.get('failed_after', len(st.get('runs', [])))} of {plural(meta['runs'], 'run')}"
                 for c, st in r["columns"].items() if st.get("skip") == "failed"]
        left = [heads[c] for c in r["columns"] if c not in KAIRO_COLUMNS and r["columns"][c].get("summary")
                and not eligible(r, c) and r["columns"][c].get("skip") != "failed"]
        if left:
            notes.append(", ".join(left) + ": checksum wrong, left out of Best other")
        cells = [f"{r['label']} (`{r['id']}`)" + ("" if r["checksums_agree"] else " (!)")
                 + (" (" + "; ".join(notes) + ")" if notes else ""), f"{r['size']:,}"]
        for metric in metrics:
            if "kairo_before" in cols:
                cells.append(fmt((k_summary(r, "kairo_before", metric) or {}).get("median")))
            k = k_summary(r, "kairo", metric)
            best, who = best_other(r, metric, heads)
            cells.append(fmt(k["median"]) if k else "–")
            cells.append(f"{fmt(best['median'])} {who}" if best else "–")
            if k and best:
                verdict, margin = compare(metric, k, best)
                cells.append(f"{verdict} {margin:+.0%}" if margin is not None else verdict)
            else:
                cells.append("")
        cells.append(f"{r['load_max']:.1f}" + (" BUSY" if r.get("busy") else ""))
        return "| " + " | ".join(cells) + " |"

    def summary_table(title, metrics):
        o.append(f"## {title}\n")
        hdr = ["Row", "Size"]
        for metric in metrics:
            h = METRICS[metric][0]
            if "kairo_before" in cols:
                hdr.append(f"Kairo before {h}")
            hdr += [f"Kairo {h}", "Best other", "Margin"]
        hdr.append("Load")
        o.append("| " + " | ".join(hdr) + " |")
        o.append("|---|---:|" + "---:|" * (len(hdr) - 3) + "---:|")
        for r in results:
            o.append(line_for(r, metrics))
        o.append("")

    summary_table("Summary: time and instructions", ["ns", "instructions", "cycles"])
    summary_table("Summary: branch and cache misses", ["branch_misses", "l1d_misses", "llc_misses"])

    o.append("## Every cell\n")
    for r in results:
        verdict = (f"checksum {r['checksum']} in every compared column" if r["checksums_agree"]
                   else f"checksums disagree: {', '.join(heads[c] for c in r['checksum_dissent'])} differ from {r['checksum']}")
        o.append(f"### {r['id']} {r['size']:,}\n")
        what = f"{r['label']}; one operation is {r['op']}" if r.get("op") else r["label"]
        core = (f"; CPUs {meta.get('quiet_cpus')} {r['cpu_busy']:.0%} busy before the cell"
                if r.get("cpu_busy") is not None and not math.isnan(r["cpu_busy"]) else "")
        o.append(f"{what}. {verdict.capitalize()}. Load {r['load_min']:.1f} "
                 f"to {r['load_max']:.1f}{core}" + (" (BUSY)" if r.get("busy") else "") + ".\n")
        hdr = ["Column", "ns/op", "ns spread", "instructions/op", "cycles/op", "IPC", "branch misses/op",
               "L1d misses/op", "LLC misses/op", "runs", "load"]
        o.append("| " + " | ".join(hdr) + " |")
        o.append("|---|" + "---:|" * (len(hdr) - 1))
        for c in cols:
            st = r["columns"].get(c)
            if st is None:
                continue
            if not st.get("summary"):
                o.append(f"| {heads[c]} | {st.get('skip', 'no result')} |" + " |" * (len(hdr) - 2))
                continue
            if not eligible(r, c) and c not in KAIRO_COLUMNS:
                why = (f"failed after {plural(st.get('failed_after', 0), 'run')}" if st.get("skip") == "failed"
                       else "checksum wrong")
                flag_note = f" ({why}; not a Best other)"
            else:
                flag_note = ""
            s = st["summary"]
            sp = spread(s.get("ns"))
            vals = [fmt(s["ns"]["median"]) if "ns" in s else "–", f"{sp:.1%}" if sp is not None else "–"]
            for metric in ("instructions", "cycles", "ipc", "branch_misses", "l1d_misses", "llc_misses"):
                v = s.get(metric, {}).get("median")
                vals.append(fmt(v))
            vals += [str(len(st["runs"])), f"{st['load_max']:.1f}"]
            flag = " (scaled: " + ", ".join(st["scaled"]) + ")" if st.get("scaled") else ""
            o.append(f"| {heads[c]}{flag}{flag_note} | " + " | ".join(vals) + " |")
        o.append("")

    o.append("## Build commands\n")
    o.append("`<group>` is each group id (string, slice, vector, map, hash, num, iter, alloc).\n")
    for c in cols:
        cmds = meta["commands"].get(c)
        if not cmds:
            o.append(f"{heads[c]}: not built.\n")
            continue
        g0 = next(iter(cmds))
        o.append(f"{heads[c]}:\n\n```\n{re.sub(rf'\b{g0}\b', '<group>', cmds[g0])}\n```\n")
    path.write_text("\n".join(o))


# --- main ------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cells", help="comma-separated id:size pairs (default: every cell)")
    ap.add_argument("--rows", help="only rows whose id matches this regex")
    ap.add_argument("--groups", help="comma-separated group ids to build (default: those the cells need)")
    ap.add_argument("--columns", default=",".join(c for c in COLUMNS if c != "kairo_before"),
                    help="comma-separated: " + ",".join(COLUMNS))
    ap.add_argument("--runs", type=int, default=5, help="runs per cell and column (default 5)")
    ap.add_argument("--min-ms", type=int, default=200, help="timed milliseconds per timed process (default 200)")
    ap.add_argument("--k", type=int, help="K for the counter passes (default: half the timed process's repetitions)")
    ap.add_argument("--no-cache-counters", action="store_true", help="count instructions, cycles and branches only")
    ap.add_argument("--max-load", type=float, help="highest 1-minute load average to measure under "
                    "(default: cores / 8)")
    ap.add_argument("--force", action="store_true", help="measure above --max-load or --max-cpu-busy without "
                    "waiting; such cells are marked BUSY")
    ap.add_argument("--max-cpu-busy", type=float, default=0.10, help="highest busy share of the pinned CPU and "
                    "its SMT siblings over 1 s before a cell (default 0.10)")
    ap.add_argument("--settle", type=int, default=900, help="seconds to wait for a quiet machine after the builds "
                    "and before each cell before giving up (default 900)")
    ap.add_argument("--cpu", type=int, help="CPU to pin to (default: the last one this process may use)")
    ap.add_argument("--jobs", type=int, default=4, help="builds at a time (default 4)")
    ap.add_argument("--out", default=str(HERE / "out" / "lib"), help="output directory")
    ap.add_argument("--report-only", action="store_true", help="write report.md again from results.json")
    ap.add_argument("--toolchain", help="the Kairo toolchain's bin/ (kairo, kcc, clang++, llvm-nm); "
                    "default $KAIRO_TOOLCHAIN, else the installed release above this directory")
    ap.add_argument("--kairo", help="the kairo of the Kairo column (default: the toolchain's)")
    ap.add_argument("--kairo-before", help="a second kairo, measured as the 'Kairo before' column")
    ap.add_argument("--kcc")
    ap.add_argument("--clang")
    ap.add_argument("--cpu-name", help="target CPU for every compiler (default: what clang resolves "
                    "-march=native to; x86-64 is the baseline)")
    for flag, default in (("gxx", "g++"), ("rustc", "rustc"), ("zig", "zig"), ("go", "go"), ("gdc", "gdc"),
                          ("ldc2", "ldc2"), ("nim", "nim"), ("swiftc", None)):
        ap.add_argument(f"--{flag}", default=default)
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.report_only:
        saved = json.loads((out / "results.json").read_text())
        write_report(out / "report.md", saved["meta"], saved["results"])
        return

    columns = [c for c in args.columns.split(",") if c]
    for c in columns:
        if c not in COLUMNS:
            sys.exit(f"lib_bench.py: unknown column {c!r}")
    if args.kairo_before and "kairo_before" not in columns:
        columns.insert(0, "kairo_before")
    columns = [c for c in COLUMNS if c in columns]
    if args.cpu is None:
        args.cpu = max(os.sched_getaffinity(0))
    if args.max_load is None:
        args.max_load = os.cpu_count() / 8
    args.cpus = cpu_siblings(args.cpu)
    load = load1()
    if load > args.max_load and not args.force:
        sys.exit(f"lib_bench.py: the 1-minute load average is {load:.1f}, above {args.max_load:.1f}; "
                 "wait for a quiet machine or pass --force (cells are then marked BUSY)")

    spec = tomllib.loads((HERE / "ops.toml").read_text())
    want = None
    if args.cells:
        want = set()
        for item in args.cells.split(","):
            rid, _, size = item.partition(":")
            want.add((rid, int(size)) if size else (rid, None))
    groups = GROUPS
    if args.groups:
        groups = [g for g in GROUPS if g in args.groups.split(",")]
    elif want:
        need = {group_of(spec, rid) for rid, _ in want}
        groups = [g for g in GROUPS if g in need]

    tools = Tools(args)
    t0 = time.time()
    exes, commands, notes = build(tools, groups, columns, out, args.jobs)
    log(f"builds: {time.time() - t0:.0f} s")
    cells = discover_cells(spec, exes, groups)
    if want:
        cells = [c for c in cells if (c["id"], c["size"]) in want or (c["id"], None) in want]
    if args.rows:
        cells = [c for c in cells if re.search(args.rows, c["id"])]

    passes, pnote = choose_passes(not args.no_cache_counters)
    if pnote:
        notes.append(pnote)
    llc = next((e for _, ev in passes for e in ev if e not in L1D_EVENTS + CORE_EVENTS), None)
    llc_events = [e for _, ev in passes for e in ev if e not in L1D_EVENTS + CORE_EVENTS]
    meta = {
        "date": datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z"),
        "machine": run.machine(),
        "pinned_cpu": args.cpu,
        "columns": columns,
        "versions": {c: tools.version(c) for c in columns},
        "commands": commands,
        "target_cpu": tools.cpu,
        "goamd64": goamd64(tools.cpu),
        "runs": args.runs,
        "min_ms": args.min_ms,
        "k_policy": f"K = {args.k}" if args.k else "K = half the first timed process's repetitions",
        "passes": passes,
        "counters": ("; ".join(f"{n}: " + ", ".join(e + ":u" for e in ev) for n, ev in passes)
                     or "none") + " (one perf stat call per pass, so nothing is multiplexed)",
        "llc_event": (" + ".join(llc_events) + (" (loads that missed every cache level)"
                                               if llc and llc.startswith("ls_dmnd") else "")) if llc else "not counted",
        "max_load": args.max_load,
        "cpu_busy_threshold": args.max_cpu_busy,
        "quiet_cpus": ",".join(map(str, args.cpus)),
        "load_start": load,
        "forced": args.force and load > args.max_load,
        "notes": notes,
    }

    def save(results):
        (out / "results.json").write_text(json.dumps({"meta": meta, "results": results}, indent=1))

    results = []
    for i, cell in enumerate(cells):
        t1 = time.time()
        try:
            cload, cbusy = wait_quiet(args, f"{cell['id']} {cell['size']}")
        except NotQuiet as e:
            # The cells measured so far are kept: results.json and report.md
            # cover them.
            write_report(out / "report.md", meta, results)
            sys.exit(str(e))
        log(f"[{i + 1}/{len(cells)}] {cell['id']} {cell['size']} (load {cload:.1f}, CPUs {args.cpus} busy {cbusy:.0%})")
        res = measure_cell(cell, columns, exes, args, passes)
        agree, major, dissent = checksum_verdict(cell, res)
        loads = [r["load_max"] for st in res.values() for r in st.get("runs", [])]
        r = dict(cell, columns=res, checksums_agree=agree, checksum=major, checksum_dissent=dissent,
                 load_min=min(loads) if loads else load1(), load_max=max(loads) if loads else load1(),
                 seconds=round(time.time() - t1, 1), cpu_busy=cbusy)
        r["busy"] = r["load_max"] > args.max_load or cbusy > args.max_cpu_busy
        if not agree:
            log(f"  CHECKSUM MISMATCH: {', '.join(dissent)} differ from {major}")
        results.append(r)
        save(results)
    write_report(out / "report.md", meta, results)
    log(f"wrote {out / 'report.md'} and {out / 'results.json'}")
    for n in notes:
        log(f"note: {n}")
    failed = [f"{r['id']} {r['size']} {COLUMNS[c][0]}" for r in results for c, st in r["columns"].items()
              if st.get("skip") == "failed"]
    if failed:
        log("failed: " + "; ".join(failed))
    if any(not r["checksums_agree"] for r in results):
        sys.exit("lib_bench.py: some cells' checksums disagree between columns (see the report)")
    if failed:
        sys.exit("lib_bench.py: some columns failed to run on some cells (see the report)")


if __name__ == "__main__":
    main()
