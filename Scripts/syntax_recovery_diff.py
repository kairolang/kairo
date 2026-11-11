#!/usr/bin/env python3
"""The differential proof for --check-past-syntax-errors (the language
server's index run, Compiler/Spec/LanguageServer.md section 9).

Every `.k` under Tests/ is type-checked as its own entry with the mode OFF.
Each one whose output has a syntax error (`error [S<n>E]`, not `SC`) is
checked again with the mode ON, and the two sets of diagnostic lines are
compared. The mode may let Sema run over what the errors leave sound; it
must not make the compiler say anything about the broken code that it did
not say before.

Each extra diagnostic is classified:
  cascade  - in a file that has syntax errors, or naming one: recovery let
             Sema see something it should not have (a bug to fix by
             poisoning, never by filtering);
  genuine  - in a file with no syntax error, which the mode OFF never
             reached because the parse failure stopped the action first.
A missing diagnostic, or a different exit code, is always a failure.

    python3 Scripts/syntax_recovery_diff.py [--kairo BIN] [--jobs N] [paths...]

Exit 0 when there is no cascade and nothing is missing.
"""
import argparse, concurrent.futures, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYNTAX = re.compile(r"error \[S\d+E\]")
DIAG = re.compile(r"^(.*?):(\d+):(\d+): (error|warning|note|fatal error)")


BODY = re.compile(r"^syntax-recovery: dropped body (.*):(\d+)-(\d+)$")
ADMIT = re.compile(r"^syntax-recovery: entry (checked|skipped), (\d+) of (\d+) files skipped")


def run(kairo, path, on, timeout):
    cmd = [kairo, "--type-check-only", "--error-format=basic", os.path.basename(path)]
    env = dict(os.environ)
    if on:
        cmd.append("--check-past-syntax-errors")
        env["KAIRO_DEBUG_SYNTAX_RECOVERY"] = "1"
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True, text=True, errors="replace", timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return None, [], None, []
    out = (p.stdout + p.stderr).splitlines()
    lines = [l for l in out if DIAG.match(l)]
    admit = next((ADMIT.match(l) for l in out if ADMIT.match(l)), None)
    bodies = [(m.group(1), int(m.group(2)), int(m.group(3))) for m in map(BODY.match, out) if m]
    return p.returncode, lines, (admit.group(1) if admit else None), bodies


def one(kairo, path, timeout):
    rc0, off, _, _ = run(kairo, path, False, timeout)
    if rc0 is None or not any(SYNTAX.search(l) for l in off):
        return path, None
    rc1, on, admit, bodies = run(kairo, path, True, timeout)
    return path, (rc0, off, rc1, on, admit, bodies)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kairo", default=os.environ.get("KAIRO_BIN") or os.path.join(ROOT, "build", "x86_64-linux-gnu", "debug", "bin", "kairo"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args()
    files = []
    for top in (a.paths or [os.path.join(ROOT, "Tests")]):
        if os.path.isfile(top):
            files.append(os.path.abspath(top))
            continue
        for d, dirs, names in os.walk(top):
            dirs[:] = [x for x in dirs if x != "Output"]
            files += [os.path.join(d, n) for n in names if n.endswith(".k")]
    files.sort()

    broken, same, cascades, genuine, failures = 0, 0, [], [], []
    admitted = {"checked": 0, "skipped": 0, None: 0}
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        for path, r in ex.map(lambda f: one(a.kairo, f, a.timeout), files):
            if r is None:
                continue
            broken += 1
            rc0, off, rc1, on, admit, bodies = r
            admitted[admit] += 1
            rel = os.path.relpath(path, ROOT)
            if rc1 is None:
                failures.append((rel, "timed out with the mode on"))
                continue
            if rc1 != rc0:
                failures.append((rel, f"exit {rc0} became {rc1}"))
            missing = [l for l in off if l not in on]
            for l in missing:
                failures.append((rel, "missing: " + l))
            extra = [l for l in on if l not in off]
            if not extra and not missing:
                same += 1
            # A cascade is a diagnostic inside a body the mode dropped (it
            # cannot be about anything else there), or in a file whose syntax
            # errors were NOT all kept inside such bodies; anything else is
            # about a healthy declaration Sema reached.
            bad = {DIAG.match(l).group(1) for l in off if SYNTAX.search(l)}
            dropped_in = {b[0] for b in bodies}
            for l in extra:
                m = DIAG.match(l)
                f, ln = m.group(1), int(m.group(2))
                inside = any(b[0] == f and b[1] <= ln <= b[2] for b in bodies)
                cascade = inside or (f in bad and f not in dropped_in)
                (cascades if cascade else genuine).append((rel, l))

    print(f"files checked: {len(files)}")
    print(f"files with syntax errors: {broken}")
    print(f"  went on to Sema with the entry checked: {admitted['checked']}")
    print(f"  went on to Sema with the entry skipped (only its imports checked): {admitted['skipped']}")
    print(f"  stopped after the parse as without the mode: {admitted[None]}")
    print(f"identical with the mode on: {same}")
    print(f"files with extra diagnostics: {len({r for r, _ in cascades + genuine})}")
    print(f"  cascades (inside a dropped body, or in a broken file not recovered): {len(cascades)}")
    for r, l in cascades:
        print(f"    {r}: {l}")
    print(f"  about healthy code (outside every dropped body): {len(genuine)}")
    for r, l in genuine:
        print(f"    {r}: {l}")
    print(f"failures (missing / exit code / timeout): {len(failures)}")
    for r, why in failures:
        print(f"    {r}: {why}")
    return 1 if (cascades or failures) else 0


if __name__ == "__main__":
    sys.exit(main())
