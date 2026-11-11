#!/usr/bin/env python3
"""Run --verify-ast-roundtrip over a corpus of .k files and list the failures.

The serialized AST (Compiler/Spec/Serialization.md) is gated on this: every
file under Tests/ that the parser builds a tree for must serialize, reload
and compare equal to the parsed tree (the printed tree, the re-serialized
bytes and the rebuilt scope tables; see AST/Serialize/RoundTrip.k).

Each file is compiled on its own with

    kairo --syntax-only --verify-ast-roundtrip --print-stats <file>

and classified by what the compiler printed:

    FAIL  an "AST round trip of ... failed" internal error, a crash, or a
          timeout
    PASS  the "[stats] ast-serialize" line: at least one tree was verified
    SKIP  neither: the file never reached the parser (it could not be
          loaded, or the preprocessor stopped the run)

A file with syntax errors is NOT skipped: the parser still builds a tree,
with recovery nodes, and that tree must round-trip like any other.

Usage:
    python3 Scripts/ast_roundtrip_corpus.py [--kairo BIN] [--jobs N]
                                            [--whole-graph] [--flag=F ...]
                                            [PATH ...]

PATH defaults to Tests/. --whole-graph drops --syntax-only for
--type-check-only, so every file each input imports is verified as well.
--flag adds a compiler flag to every run: --flag=--preserve-comments puts
comments in the trees as annotations, which is a second corpus.
Exit status is 1 when any file fails.
"""

import argparse
import concurrent.futures
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FAIL_MARK = "AST round trip of"
PASS_MARK = "[stats] ast-serialize:"


def default_kairo():
    """The most recently built of the debug and release compilers."""
    best = None
    build = os.path.join(REPO, "build")
    if not os.path.isdir(build):
        return None
    for triple in sorted(os.listdir(build)):
        for mode in ("debug", "release"):
            cand = os.path.join(build, triple, mode, "bin", "kairo")
            if os.path.isfile(cand):
                if best is None or os.path.getmtime(cand) > os.path.getmtime(best):
                    best = cand
    return best


def collect(paths):
    out = []
    for p in paths:
        if os.path.isfile(p):
            out.append(p)
            continue
        for root, dirs, files in os.walk(p):
            dirs[:] = sorted(d for d in dirs if d != "Output")
            for name in sorted(files):
                if name.endswith(".k"):
                    out.append(os.path.join(root, name))
    return out


def run_one(kairo, path, whole_graph, timeout, extra):
    action = "--type-check-only" if whole_graph else "--syntax-only"
    cmd = [kairo, action, "--verify-ast-roundtrip", "--print-stats",
           "--error-format=basic"] + extra + [path]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout, cwd=os.path.dirname(path) or ".")
    except subprocess.TimeoutExpired:
        return path, "FAIL", "timed out after %d s" % timeout, 0, 0
    text = proc.stdout.decode("utf-8", "replace")

    serialized = source = 0
    for line in text.splitlines():
        if PASS_MARK in line:
            # "[stats] ast-serialize: N files, B bytes for S source bytes, ..."
            words = line.split()
            try:
                serialized = int(words[words.index("bytes") - 1])
                source = int(words[words.index("source") - 1])
            except (ValueError, IndexError):
                pass

    for line in text.splitlines():
        if FAIL_MARK in line:
            return path, "FAIL", line.strip(), serialized, source
    if proc.returncode < 0 or proc.returncode >= 128:
        tail = text.strip().splitlines()[-1:] or [""]
        return path, "FAIL", "compiler died (%d): %s" % (proc.returncode, tail[0]), 0, 0
    if PASS_MARK in text:
        return path, "PASS", "", serialized, source
    return path, "SKIP", "", 0, 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="*", default=[os.path.join(REPO, "Tests")])
    ap.add_argument("--kairo", default=os.environ.get("KAIRO_BIN") or default_kairo())
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--whole-graph", action="store_true")
    ap.add_argument("--list-skipped", action="store_true")
    ap.add_argument("--flag", action="append", default=[], metavar="FLAG",
                    help="extra compiler flag for every file (repeatable), "
                         "e.g. --flag=--preserve-comments")
    args = ap.parse_args()

    if not args.kairo or not os.path.isfile(args.kairo):
        sys.exit("ast_roundtrip_corpus: no kairo binary (pass --kairo or set KAIRO_BIN)")
    kairo = os.path.abspath(args.kairo)

    files = [os.path.abspath(p) for p in collect(args.paths)]
    print("ast_roundtrip_corpus: %d files, %s, %d jobs%s"
          % (len(files), kairo, args.jobs, "".join(" " + f for f in args.flag)))

    started = time.time()
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    failures, skipped = [], []
    serialized = source = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = [pool.submit(run_one, kairo, f, args.whole_graph, args.timeout, args.flag)
                for f in files]
        for job in concurrent.futures.as_completed(jobs):
            path, verdict, why, ser, src = job.result()
            counts[verdict] += 1
            serialized += ser
            source += src
            if verdict == "FAIL":
                failures.append((path, why))
            elif verdict == "SKIP":
                skipped.append(path)

    for path, why in sorted(failures):
        print("FAIL %s\n     %s" % (os.path.relpath(path, REPO), why))
    if args.list_skipped:
        for path in sorted(skipped):
            print("SKIP %s" % os.path.relpath(path, REPO))

    print("ast_roundtrip_corpus: %d pass, %d fail, %d skipped (no tree), %.0f s"
          % (counts["PASS"], counts["FAIL"], counts["SKIP"], time.time() - started))
    if source:
        print("ast_roundtrip_corpus: %d serialized bytes for %d source bytes (%.2fx)"
              % (serialized, source, serialized / source))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
