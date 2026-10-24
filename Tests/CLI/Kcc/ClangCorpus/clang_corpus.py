#!/usr/bin/env python3
"""kcc against clang's own test corpus (Lib/llvm-runtimes/clang/test).

kcc is clang with Kairo in front, so clang's tests are a strict regression
suite for it: whatever clang accepts, rejects or prints, kcc must too.

Two modes, each over a list of `<path relative to clang/test>\t<cc1 flags>`:

  verify  `kcc -fsyntax-only -Xclang <flag>... -Xclang -verify... <file>` must
          exit 0: clang's -verify checks every expected-error/warning/note
          comment in the file against what kcc's clang reported.
  pp      `kcc -E -P <file>` and the bundled clang's `-E -P` (same target and
          sysroot) must agree on exit status and print the same text.

`gen` builds the lists: it reads each test's RUN lines, keeps the first plain
`%clang_cc1 ... %s` line of the right shape, runs it through the bundled
`clang -cc1` and through kcc, and lists the files where both pass. A file
clang passes and kcc does not is a kcc bug, reported, never listed.
"""
import argparse, os, re, shlex, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

# cc1 words a RUN line may carry and kcc can pass through -Xclang. Anything
# else (pipes, %t, -emit-*, -ast-dump, plugins, -I with %S is allowed) makes
# the line unusable.
# -triple, -x and the MS/Borland modes are skipped as well: the driver writes
# its own target and language into the cc1 line, and a second one through
# -Xclang does not cleanly replace them.
_SKIP = re.compile(r"[|<>]|%t|%T|%\{|%itanium|%ms_abi|-ast-|-emit-|-load|-plugin|-o\b|-fmodules|(^| )-x|-include-pch|-chain-include|-fmodule|-triple|-fms-|-fborland|-fdelayed-template")


def _std_default(path):
    return "-std=gnu17" if path.endswith(".c") else "-std=gnu++17"


def _cc1_line(text, path, want):
    """The cc1 flags of the first usable RUN line, or None."""
    lines = []
    cur = ""
    for raw in text.splitlines():
        m = re.search(r"RUN:(.*)$", raw)
        if not m:
            if cur:
                lines.append(cur)
                cur = ""
            continue
        part = m.group(1).rstrip()
        if part.endswith("\\"):
            cur += part[:-1] + " "
            continue
        lines.append(cur + part)
        cur = ""
    for ln in lines:
        ln = ln.strip()
        if not ln.startswith("%clang_cc1 "):
            continue
        # A preprocessor test pipes its output into FileCheck; the command
        # before the pipe is the one compared.
        if want == "pp":
            ln = ln.split("|", 1)[0].strip()
        if _SKIP.search(ln):
            continue
        words = shlex.split(ln)[1:]
        if "%s" not in words:
            continue
        words = [w for w in words if w != "%s"]
        # %S / %p (the test's directory) stay as written in the list and are
        # expanded at run time (_expand), so the list names no local path.
        words = [w.replace("%p", "%S") for w in words]
        if any("%" in w.replace("%S", "") for w in words):
            continue
        if want == "verify":
            if not any(w == "-verify" or w.startswith("-verify=") for w in words):
                continue
            if "-fsyntax-only" not in words:
                continue
            words = [w for w in words if w != "-fsyntax-only"]
        else:
            if "-E" not in words:
                continue
            words = [w for w in words if w not in ("-E", "-P")]
            if any(w.startswith("-verify") for w in words):
                continue
        if not any(w.startswith("-std=") for w in words):
            words = [_std_default(path)] + words
        return words
    return None


def _expand(flags, path):
    d = os.path.dirname(path)
    return [f.replace("%S", d) for f in flags]


def _run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, b"", b"timeout"


# What a bare `clang -cc1` assumes and clang's driver does not: no error
# limit (the driver stops at 19, and a test's later expectations go unseen)
# and no exceptions (a RUN line that wants them says -fcxx-exceptions, which
# comes after these).
_CC1_DEFAULTS = ["-ferror-limit=0", "-fno-exceptions"]


def _cc1_defaults(path):
    # cc1's Objective-C runtime is the non-fragile macOS one; on Linux the
    # driver picks the legacy GNU runtime, which has no ARC and lays out
    # ivars differently.
    if path.endswith((".m", ".mm")):
        return _CC1_DEFAULTS + ["-fobjc-runtime=macosx"]
    return _CC1_DEFAULTS


def _kcc_verify(kcc, path, flags):
    cmd = kcc + ["-fsyntax-only"] + _cc1_defaults(path)
    for f in _expand(flags, path):
        cmd += ["-Xclang", f]
    return _run(cmd + [path])


def _clang_verify(clang, path, flags):
    return _run([clang, "-cc1", "-fsyntax-only"] + _expand(flags, path) + [path])


def _norm(out):
    return b"\n".join(l.rstrip() for l in out.splitlines() if l.strip())


def _kcc_pp(kcc, path, flags):
    cmd = kcc + ["-E", "-P", "-ferror-limit=0"]
    for f in _expand(flags, path):
        cmd += ["-Xclang", f]
    return _run(cmd + [path])


def _clang_pp(clang, target, sysroot, path, flags):
    cmd = [clang, "--target=" + target, "--sysroot=" + sysroot, "-E", "-P", "-ferror-limit=0"]
    for f in _expand(flags, path):
        cmd += ["-Xclang", f]
    return _run(cmd + [path])


def cmd_gen(a):
    root = os.path.abspath(a.root)
    files = []
    for sub in a.dirs:
        d = os.path.join(root, sub)
        for dp, dn, fn in os.walk(d):
            dn[:] = sorted(x for x in dn if x != "Inputs")
            for n in sorted(fn):
                if os.path.splitext(n)[1] in a.ext:
                    files.append(os.path.relpath(os.path.join(dp, n), root))
    jobs = []
    for rel in files:
        p = os.path.join(root, rel)
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "REQUIRES:" in text and not a.allow_requires:
            continue
        fl = _cc1_line(text, p, a.mode)
        if fl is not None:
            jobs.append((rel, fl))
    kcc = shlex.split(a.kcc)

    def one(j):
        rel, fl = j
        p = os.path.join(root, rel)
        if a.mode == "verify":
            c = _clang_verify(a.clang, p, fl)
            if c[0] != 0:
                return rel, fl, "clang-fails"
            k = _kcc_verify(kcc, p, fl)
            return rel, fl, ("ok" if k[0] == 0 else "kcc-fails")
        c = _clang_pp(a.clang, a.target, a.sysroot, p, fl)
        k = _kcc_pp(kcc, p, fl)
        if c[0] != 0:
            return rel, fl, "clang-fails"
        same = (k[0] == c[0]) and (_norm(k[1]) == _norm(c[1]))
        return rel, fl, ("ok" if same else "kcc-fails")

    with ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(one, jobs))
    ok = [(r, f) for r, f, s in res if s == "ok"]
    bad = [(r, f) for r, f, s in res if s == "kcc-fails"]
    with open(a.list, "w") as out:
        for r, f in ok:
            out.write(r + "\t" + " ".join(shlex.quote(x) for x in f) + "\n")
    with open(a.list + ".kcc-fails", "w") as out:
        for r, f in bad:
            out.write(r + "\t" + " ".join(shlex.quote(x) for x in f) + "\n")
    print(f"{len(jobs)} candidates: {len(ok)} listed, {len(bad)} kcc-only failures, "
          f"{len(jobs) - len(ok) - len(bad)} clang-only failures")


def cmd_run(a):
    kcc = shlex.split(a.kcc)
    entries = []
    for line in open(a.list):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        rel, _, fl = line.partition("\t")
        entries.append((rel, shlex.split(fl)))

    def one(e):
        rel, fl = e
        p = os.path.join(a.root, rel)
        if a.mode == "verify":
            k = _kcc_verify(kcc, p, fl)
            return rel, k[0] == 0, k[2]
        k = _kcc_pp(kcc, p, fl)
        c = _clang_pp(a.clang, a.target, a.sysroot, p, fl)
        same = (k[0] == c[0]) and (_norm(k[1]) == _norm(c[1]))
        return rel, same, k[2]

    with ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(one, entries))
    bad = [(r, err) for r, good, err in res if not good]
    for r, err in bad:
        print(f"FAIL {a.mode}: {r}")
        for l in err.decode("utf-8", "replace").splitlines()[:8]:
            print("    " + l)
    print(f"{len(res) - len(bad)} / {len(res)} passed")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["gen", "run"])
    ap.add_argument("--mode", choices=["verify", "pp"], required=True)
    ap.add_argument("--kcc", required=True)
    ap.add_argument("--clang", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--list", required=True)
    ap.add_argument("--target", default="x86_64-unknown-linux-musl")
    ap.add_argument("--sysroot", default="")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--dirs", nargs="*", default=[])
    ap.add_argument("--ext", nargs="*", default=[".c", ".cpp"])
    ap.add_argument("--allow-requires", action="store_true")
    a = ap.parse_args()
    if a.action == "gen":
        cmd_gen(a)
        return 0
    return cmd_run(a)


if __name__ == "__main__":
    sys.exit(main())
