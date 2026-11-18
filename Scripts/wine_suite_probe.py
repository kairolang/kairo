#!/usr/bin/env python3
"""Measure how many of Tests/codegen's run-tests behave the same on Windows.

    wine_suite_probe.py [--kairo PATH] [--limit N] [--jobs N] [--out DIR]

Takes the tests under Tests/codegen whose RUN lines are `%kairo %s -o %t.exe`
(optionally with `--cache-dir %t.d`), `rm` lines, and a run of `%t.exe`. Each
is compiled for the host and for x86_64-windows-gnu, both programs are run
(the Windows one under Scripts/run_wine.py), and exit code and stdout are
compared. No test is modified. Writes REPORT.md (counts and failures grouped
by first error) and per-test logs into the output directory, default
build/wine-probe.

Outcome per test: same, different, no-windows-compile (the Windows build
failed), no-native (the host build or run failed, so there is nothing to
compare), timeout (a program ran past its limit).
"""
import argparse
import collections
import concurrent.futures
import glob
import os
import re
import shlex
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(REPO, "Tests", "codegen")
RUN_WINE = os.path.join(REPO, "Scripts", "run_wine.py")
COMPILE_RE = re.compile(r"%kairo %s -o %t\.exe( --cache-dir %t\.d)?")
RUN_RE = re.compile(r"(?:\{ )?%t\.exe((?: [^|>&;}<2]+)?)")
COMPILE_TIMEOUT = 600
RUN_TIMEOUT = 60


def candidates():
    out = []
    for f in sorted(glob.glob(os.path.join(TESTS, "**", "*.k"), recursive=True)):
        if "/inputs/" in f or "/windows_run/" in f:
            continue
        text = open(f, encoding="utf-8", errors="replace").read()
        runs = re.findall(r"^// RUN: (.*)$", text, re.M)
        if re.search(r"^// (XFAIL|UNSUPPORTED):", text, re.M):
            continue
        reqs = re.findall(r"^// REQUIRES: (.*)$", text, re.M)
        if any(r.strip() not in ("clang",) for r in reqs):
            continue
        runs = [r for r in runs if not r.startswith("rm ")]
        if len(runs) != 2 or not COMPILE_RE.fullmatch(runs[0]):
            continue
        m = RUN_RE.match(runs[1])
        if not m:
            continue
        out.append((f, shlex.split(m.group(1))))
    return out


def kairo_flags(kairo):
    lib = os.path.join(REPO, "Lib")
    res = glob.glob(os.path.join(os.path.dirname(os.path.dirname(kairo)), "lib", "clang", "*"))
    flags = ["--error-format=basic", "--threads=2"]
    if res:
        flags.append("--resource-dir=" + res[0])
    flags += ["--builtins-dir=" + os.path.join(lib, "builtin"),
              "--std-dir=" + os.path.join(lib, "std")]
    return flags


def run(cmd, timeout, cwd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, cwd=cwd)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return None, b"", b"timeout"


def first_error(stderr):
    text = stderr.decode("utf-8", "replace")
    for line in text.splitlines():
        if re.search(r"\berror\b|\bundefined reference\b|\bfatal\b", line):
            line = re.sub(r"^\S*?[/\\]", "", line) if line.startswith("/") else line
            line = re.sub(r"^[^ ]*?\.k:\d+:\d+: ", "", line)
            line = re.sub(r"'[^']*'", "'_'", line)
            line = re.sub(r"\d+", "N", line)
            return line.strip()[:160]
    lines = [l for l in text.splitlines() if l.strip()]
    return lines[-1][:160] if lines else "(no output)"


def probe(item, kairo, flags, work):
    path, args = item
    name = os.path.relpath(path, TESTS)
    tag = name.replace("/", "__")
    d = os.path.join(work, tag)
    os.makedirs(d, exist_ok=True)
    res = {"name": name, "kind": "", "detail": ""}
    nat = os.path.join(d, "native.exe")
    win = os.path.join(d, "win.exe")
    rc, _, err = run([kairo] + flags + [path, "-o", nat, "--cache-dir", os.path.join(d, "n.d")],
                     COMPILE_TIMEOUT, d)
    if rc != 0:
        res.update(kind="no-native", detail=first_error(err))
        return res
    nrc, nout, nerr = run([nat] + args, RUN_TIMEOUT, d)
    if nrc is None:
        res.update(kind="no-native", detail="native run timed out")
        return res
    rc, _, err = run([kairo] + flags + [path, "--target=x86_64-windows-gnu", "-o", win,
                                         "--cache-dir", os.path.join(d, "w.d")],
                     COMPILE_TIMEOUT, d)
    if rc != 0:
        res.update(kind="no-windows-compile", detail=first_error(err))
        open(os.path.join(d, "compile.err"), "wb").write(err)
        return res
    wrc, wout, werr = run([sys.executable, RUN_WINE, win] + args, RUN_TIMEOUT, d)
    if wrc is None:
        res.update(kind="timeout", detail="windows run timed out")
        return res
    # Windows programs write CRLF only if they open files in text mode; wine's
    # stdout pipe is binary, so bytes are compared as they are, but a trailing
    # CR before LF is normalised to keep the comparison about content.
    wnorm = wout.replace(b"\r\n", b"\n")
    if wrc == nrc and wnorm == nout:
        res.update(kind="same")
        return res
    why = []
    if wrc != nrc:
        why.append("exit native=%s windows=%s" % (nrc, wrc))
    if wnorm != nout:
        nl, wl = nout.decode("utf-8", "replace").splitlines(), wnorm.decode("utf-8", "replace").splitlines()
        i = next((k for k in range(min(len(nl), len(wl))) if nl[k] != wl[k]), min(len(nl), len(wl)))
        why.append("stdout differs at line %d: native=%r windows=%r" % (
            i + 1, nl[i][:60] if i < len(nl) else "<end>", wl[i][:60] if i < len(wl) else "<end>"))
    res.update(kind="different", detail="; ".join(why))
    open(os.path.join(d, "windows.stderr"), "wb").write(werr)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kairo", default=os.path.join(REPO, "build", "x86_64-linux-musl", "release", "bin", "kairo"))
    ap.add_argument("--limit", type=int, default=150)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", default=os.path.join(REPO, "build", "wine-probe"))
    a = ap.parse_args()
    items = candidates()[:a.limit]
    os.makedirs(a.out, exist_ok=True)
    work = os.path.join(a.out, "work")
    flags = kairo_flags(a.kairo)
    results = []
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        futs = [ex.submit(probe, it, a.kairo, flags, work) for it in items]
        for i, f in enumerate(futs):
            r = f.result()
            results.append(r)
            print("[%d/%d] %-20s %s" % (i + 1, len(items), r["kind"], r["name"]), flush=True)
    write_report(os.path.join(a.out, "REPORT.md"), results)


def write_report(path, results):
    by = collections.defaultdict(list)
    for r in results:
        by[r["kind"]].append(r)
    lines = ["# Windows (Wine) probe of Tests/codegen run-tests", "",
             "Tests probed: %d. Each is built for the host and for x86_64-windows-gnu;"
             " exit code and stdout are compared." % len(results), "",
             "| outcome | count |", "|---|---|"]
    for k in ("same", "different", "no-windows-compile", "timeout", "no-native"):
        lines.append("| %s | %d |" % (k, len(by.get(k, []))))
    for k, title in (("no-windows-compile", "Does not compile for Windows"),
                     ("different", "Different result"),
                     ("timeout", "Timeout"),
                     ("no-native", "No native baseline (not compared)")):
        rs = by.get(k, [])
        if not rs:
            continue
        groups = collections.defaultdict(list)
        for r in rs:
            groups[r["detail"]].append(r["name"])
        lines += ["", "## %s (%d)" % (title, len(rs)), ""]
        for detail, names in sorted(groups.items(), key=lambda kv: -len(kv[1])):
            lines.append("- %d x `%s`" % (len(names), detail))
            for n in names[:6]:
                lines.append("    - %s" % n)
            if len(names) > 6:
                lines.append("    - ... %d more" % (len(names) - 6))
    lines += ["", "## Same (%d)" % len(by.get("same", [])), ""]
    lines += ["- %s" % r["name"] for r in by.get("same", [])]
    open(path, "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
