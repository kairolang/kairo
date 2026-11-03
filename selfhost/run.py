#!/usr/bin/env python3
"""The self-host scratch pipeline (private/SELFHOST.md section 4).

    python3 selfhost/run.py                       # pin main's HEAD, phase syntax
    python3 selfhost/run.py --commit 1ab00200     # pin a given main commit
    python3 selfhost/run.py --only Compiler/Lexer # one directory, end to end
    python3 selfhost/run.py --phase-only          # rerun the phase on the
                                                  # existing scratch tree

Steps, every run from nothing (the scratch tree is a build artifact):

  1. selfhost/scratch/ = a detached, SPARSE git worktree of the pinned commit
     holding only Compiler/, Linker/ and Extras/KaTAR (the three -I roots of
     the section 3 build line). It is a real worktree so `git apply --3way`
     works; a previous one is removed with `git worktree remove --force`,
     never deleted by hand while still registered.
  2. cast_facts.py on the PRISTINE scratch tree (cpp_casts pairs casts by line,
     so the facts must come from exactly the pinned source, not from main's
     working tree, which other agents are editing), cached per commit in
     selfhost/logs/cast-facts-<commit>.json. Then Scripts/Migration/migrate.py
     --apply over the scratch root with --with-libcxx and --check-idempotent;
     a pass that changes its own output stops the run.
  3. The migrated tree is committed inside the scratch worktree, so that
     `git apply --3way` (which implies --index) has an index that matches the
     files, and selfhost/patches/*.patch are applied in order. A patch that no
     longer applies stops the run and names the patch.
  4. The requested phase runs and writes selfhost/logs/<phase>-<commit>.log and
     .json.

Portable on purpose (no shell, no POSIX-only calls): pathlib + subprocess.
"""
import argparse, collections, concurrent.futures, datetime, json, os, re
import shutil, subprocess, sys, time
from pathlib import Path

SELF = Path(__file__).resolve().parent
REPO = SELF.parent
SCRATCH = SELF / "scratch"
LOGS = SELF / "logs"
PATCHES = SELF / "patches"
MIGRATION = REPO / "Scripts" / "Migration"
# What the scratch tree holds and the phase walks ...
ROOTS = ["Compiler", "Linker", "Extras/KaTAR"]
# ... and the -I list EVERY per-file invocation gets, identically: module
# identity depends on the -I set (P344, decision A, 2026-11-02), so `-I .` and
# `-I Extras/KaTAR` (imported by nothing in Compiler/ or Linker/) are gone and
# linker_api_imports.py moved `import Linker::API::X` onto Linker's own root.
INCLUDE_ROOTS = ["Compiler", "Linker"]
DEFAULT_KAIRO = REPO / "build" / "x86_64-linux-gnu" / "release" / "bin" / "kairo"

# cast_facts.py runs Stage 0 and clang inside the scratch root, and both need
# trees that are submodules or build output -- never in a sparse worktree.
# They are linked in for that one step and unlinked before migration, so they
# can never be committed into the scratch history or walked by a pass.
FACTS_LINKS = ["Lib/bootstrap/lib-helix", "Lib/llvm-runtimes", "build/llvm"]

# private/SELFHOST.md 5.0. Extras/KaTAR imports nothing from Compiler/, so it
# sits with the bottom layer.
LAYERS = [
    (1, "Native/Support/Memory/Threading (+KaTAR)",
     ["Compiler/Native", "Compiler/Support", "Compiler/Memory", "Compiler/Threading", "Extras/KaTAR"]),
    (2, "Location/Token/Diagnostic", ["Compiler/Location", "Compiler/Token", "Compiler/Diagnostic"]),
    (3, "Lexer/Macro/Preprocessor", ["Compiler/Lexer", "Compiler/Macro", "Compiler/Preprocessor"]),
    (4, "Resolution/AST", ["Compiler/Resolution", "Compiler/AST"]),
    (5, "Parser", ["Compiler/Parser"]),
    (6, "Sema", ["Compiler/Sema"]),
    (7, "Codegen/Interop", ["Compiler/Codegen", "Compiler/Interop"]),
    (8, "Command/Config/Tooling/Driver",
     ["Compiler/Command", "Compiler/Config", "Compiler/Tooling", "Compiler/Driver"]),
    (9, "Linker", ["Linker"]),
]


def layer_of(rel):
    for n, _, dirs in LAYERS:
        if any(rel == d or rel.startswith(d + "/") for d in dirs):
            return n
    return 0  # Compiler/*.k at the top: no layer in the spec


def say(*a):
    print(*a, flush=True)


def git(*args, cwd=REPO, check=True, capture=True):
    p = subprocess.run(["git", *args], cwd=str(cwd), text=True,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None)
    if check and p.returncode != 0:
        sys.exit(f"run.py: git {' '.join(args)} failed ({p.returncode}):\n{p.stdout or ''}")
    return (p.stdout or "").strip()


# --------------------------------------------------------------------------
# 1. scratch
# --------------------------------------------------------------------------
def registered_worktrees():
    out = git("worktree", "list", "--porcelain")
    return {Path(l[len("worktree "):]).resolve() for l in out.splitlines() if l.startswith("worktree ")}


def remove_scratch():
    if SCRATCH.resolve() in registered_worktrees():
        say(f"[1] removing previous scratch worktree")
        git("worktree", "remove", "--force", str(SCRATCH))
    if SCRATCH.exists():
        git("worktree", "prune")
        if SCRATCH.exists():
            sys.exit(f"run.py: {SCRATCH} exists but is not a registered worktree; "
                     "not deleting it blind -- remove it by hand")


def make_scratch(sha):
    remove_scratch()
    say(f"[1] scratch: sparse worktree of {sha[:12]} ({', '.join(ROOTS)})")
    git("worktree", "add", "--no-checkout", "--detach", str(SCRATCH), sha)
    git("sparse-checkout", "set", "--cone", *ROOTS, cwd=SCRATCH)
    git("checkout", "--detach", sha, cwd=SCRATCH)


# --------------------------------------------------------------------------
# 2. cast facts + migrate
# --------------------------------------------------------------------------
def cast_facts(short, log):
    out = LOGS / f"cast-facts-{short}.json"
    if out.exists():
        say(f"[2] cast facts: reusing {out.relative_to(REPO)}")
        return out
    made = []
    try:
        for rel in FACTS_LINKS:
            dst = SCRATCH / rel
            parent = dst.parent
            stack = []
            while not parent.exists():
                stack.append(parent)
                parent = parent.parent
            for d in reversed(stack):
                d.mkdir()
                made.append(d)
            os.symlink(REPO / rel, dst, target_is_directory=True)
            made.append(dst)
        say(f"[2] cast facts: Stage 0 + clang over the pristine scratch tree (about a minute)")
        tmp = out.with_suffix(".tmp")
        p = subprocess.run([sys.executable, str(MIGRATION / "cast_facts.py"), "--root", str(SCRATCH),
                            "--out", str(tmp)], cwd=str(SCRATCH), env=dict(os.environ, PWD=str(SCRATCH)), text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write("==== cast_facts.py\n" + p.stdout + "\n")
        if p.returncode != 0:
            sys.exit(f"run.py: cast_facts.py failed ({p.returncode}); see {log.name}\n" + p.stdout[-3000:])
        # Every Compiler/ site must come from THIS tree. On 2026-11-02 one run
        # came back with every site in main's checkout instead (Stage 0's
        # shared cache/cxx/ file, most likely clobbered by a concurrent Stage 0
        # build); cpp_casts would then pair casts against the wrong source.
        with open(tmp, encoding="utf-8") as fh:
            sites = json.load(fh)["sites"]
        here = str(SCRATCH).replace("\\", "/") + "/"
        stray = [s["file"] for s in sites if s["file"] and any(
            ("/" + r + "/") in s["file"].replace("\\", "/") for r in ROOTS)
            and not s["file"].replace("\\", "/").startswith(here)]
        if stray:
            tmp.unlink()
            sys.exit(f"run.py: cast_facts.py read {len(stray)} site(s) from outside the scratch tree "
                     f"(e.g. {stray[0]}); a concurrent Stage 0 build likely raced its cache. Rerun.")
        tmp.replace(out)
    finally:
        # Links first (unlink never follows them), then the directories made
        # for them, deepest first, only if empty.
        for m in reversed(made):
            if m.is_symlink():
                m.unlink()
            elif m.is_dir() and not any(m.iterdir()):
                m.rmdir()
    return out


def migrate(facts, log, only):
    cmd = [sys.executable, str(MIGRATION / "migrate.py"), str(SCRATCH), "--apply",
           "--with-libcxx", "--cast-facts", str(facts), "--check-idempotent"]
    if only:
        cmd += ["--only", only]
    say("[2] migrate: " + " ".join(Path(c).name if os.sep in c else c for c in cmd[1:]))
    p = subprocess.run(cmd, cwd=str(REPO), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write("==== migrate.py\n" + " ".join(cmd) + "\n" + p.stdout + "\n")
    m = re.search(r"idempotency: (\d+) file\(s\) change on a second run", p.stdout)
    unstable = int(m.group(1)) if m else -1
    m2 = re.search(r"(\d+) of (\d+) file\(s\) changed", p.stdout)
    say(f"    {m2.group(0) if m2 else '?'}; idempotency: "
        f"{'OK' if unstable == 0 else str(unstable) + ' file(s) unstable'}")
    if p.returncode != 0 or unstable != 0:
        sys.exit(f"run.py: migrate.py failed or is not idempotent (rc {p.returncode}); see {log.name}")
    return unstable


# --------------------------------------------------------------------------
# 3. patches
# --------------------------------------------------------------------------
SCRATCH_ID = ["-c", "user.name=selfhost", "-c", "user.email=selfhost@localhost",
              "-c", "commit.gpgsign=false"]


def scratch_commit(msg):
    git("add", "-A", cwd=SCRATCH)
    if git("status", "--porcelain", cwd=SCRATCH):
        git(*SCRATCH_ID, "commit", "-q", "--no-verify", "-m", msg, cwd=SCRATCH)


def apply_patches(log):
    patches = sorted(PATCHES.glob("*.patch"))
    say(f"[3] patches: {len(patches)}")
    for pt in patches:
        p = subprocess.run(["git", "apply", "--3way", str(pt)], cwd=str(SCRATCH), text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write(f"==== git apply --3way {pt.name}\n{p.stdout}\n")
        if p.returncode != 0:
            sys.exit(f"run.py: patch {pt.name} no longer applies:\n{p.stdout}")
    if patches:
        scratch_commit("patches: " + ", ".join(p.name for p in patches))


# --------------------------------------------------------------------------
# 4. phase: syntax
# --------------------------------------------------------------------------
DIAG = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<col>\d+): (?P<sev>[a-z ]+?) "
                  r"\[(?P<code>[A-Z]+\d+[A-Z])\]: (?P<msg>.*)$")


def normalize(msg):
    """Message with names, numbers and quoted text masked: the bucket key."""
    m = re.sub(r"'[^']*'", "'_'", msg)
    m = re.sub(r"`[^`]*`", "`_`", m)
    m = re.sub(r'"[^"]*"', '"_"', m)
    m = re.sub(r"\b\d+\b", "N", m)
    return m


def scratch_rel(path):
    s = path.replace("\\", "/")
    root = str(SCRATCH).replace("\\", "/") + "/"
    return s[len(root):] if s.startswith(root) else s


# Stage 0 reads $PWD rather than the real cwd (cast_facts.py); keep the two
# in agreement for every compiler this script starts.
ENV = dict(os.environ, PWD=str(SCRATCH))


def run_one(kairo, path, timeout):
    # --cmax-errors=0: the default limit (20) is spent on the imported files'
    # errors long before the input's own, and I957E then hides the rest.
    cmd = [str(kairo), "--syntax-only", "--error-format=basic", "--no-color", "--cmax-errors=0"]
    for r in INCLUDE_ROOTS:
        cmd += ["-I", str(SCRATCH / r)]
    cmd.append(str(path))
    t = time.monotonic()
    try:
        p = subprocess.run(cmd, cwd=str(SCRATCH), env=ENV, text=True, errors="replace",
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        rc, out, to = p.returncode, p.stdout, False
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        rc, to = None, True
    return {"file": scratch_rel(str(path)), "rc": rc, "timeout": to,
            "secs": round(time.monotonic() - t, 2), "out": out}


def classify(r):
    diags, other = [], []
    for ln in r["out"].splitlines():
        m = DIAG.match(ln)
        if m:
            d = m.groupdict()
            d["file"] = scratch_rel(d["file"])
            d["line"], d["col"] = int(d["line"]), int(d["col"])
            diags.append(d)
        elif ln.strip():
            other.append(ln)
    # An I-category ERROR or FATAL is an ICE; I957E (the error-limit note)
    # and I-category notes (I900N explains a parse error) are not.
    ice = any(re.search(r"internal compiler error|(?:error|fatal)[a-z ]* \[I(?!957E)\d+[EF]\]|Assertion .* failed"
                        r"|Segmentation fault|stack dump|PLEASE submit", ln, re.I)
              for ln in r["out"].splitlines())
    crash = (not r["timeout"]) and (r["rc"] is None or r["rc"] < 0 or r["rc"] not in (0, 1) or ice)
    return diags, other, crash


def phase_syntax(kairo, files, jobs, timeout):
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = [ex.submit(run_one, kairo, f, timeout) for f in files]
        for i, fu in enumerate(concurrent.futures.as_completed(futs), 1):
            results.append(fu.result())
            if i % 50 == 0 or i == len(files):
                say(f"    {i}/{len(files)}")
    results.sort(key=lambda r: r["file"])
    # A `file:0:0` diagnostic is a known compiler race (MEMORY: flaky suite);
    # rerun such a file once, alone, before believing it.
    for k, r in enumerate(results):
        if re.search(r":0:0: ", r["out"]):
            results[k] = run_one(kairo, SCRATCH / r["file"], timeout)
            results[k]["rerun_0_0"] = True
    return results


def triage(results):
    seen = set()
    dups = 0
    per_file = {}
    buckets = {}
    crashes, timeouts = [], []
    for r in results:
        diags, other, crash = classify(r)
        own = [d for d in diags if d["file"] == r["file"]]
        foreign = len(diags) - len(own)
        # setdefault: an earlier input that imports this file may already
        # have counted some of its diagnostics.
        pf = per_file.setdefault(r["file"], {"layer": layer_of(r["file"]), "diags": 0, "errors": 0,
                                             "first": None})
        pf.update({"rc": r["rc"], "secs": r["secs"], "timeout": r["timeout"], "crash": crash,
                   "foreign_diags": foreign, "other_output": other[:20]})
        if crash:
            crashes.append({"file": r["file"], "rc": r["rc"], "tail": r["out"].splitlines()[-15:]})
        if r["timeout"]:
            timeouts.append(r["file"])
        first_err = True
        for d in diags:
            key = (d["file"], d["line"], d["col"], d["code"], d["msg"])
            if key in seen:
                dups += 1
                continue
            seen.add(key)
            f = d["file"]
            pf = per_file.setdefault(f, {"layer": layer_of(f), "diags": 0, "errors": 0, "first": None})
            pf["diags"] += 1
            is_err = d["sev"] in ("error", "fatal error", "fatal")
            pf["errors"] += is_err
            bk = (d["code"], normalize(d["msg"]))
            b = buckets.setdefault(bk, {"code": d["code"], "sev": d["sev"], "norm": bk[1], "count": 0,
                                        "files": set(), "first_in": set(),
                                        "layers": collections.Counter(), "examples": []})
            b["count"] += 1
            b["files"].add(f)
            b["layers"][layer_of(f)] += 1
            if len(b["examples"]) < 3 and all(e.split(":")[0] != f for e in b["examples"]):
                b["examples"].append(f"{f}:{d['line']}:{d['col']}: {d['msg']}")
            if is_err and (pf["first"] is None or (d["line"], d["col"]) < tuple(pf["first_at"])):
                pf["first"], pf["first_at"] = list(bk), [d["line"], d["col"]]
    # Each file's FIRST error (by position) is the one that unblocks it; later
    # ones may be recovery cascades, so ranking is by first-error files.
    for f, pf in per_file.items():
        if pf.get("first"):
            buckets[tuple(pf["first"])]["first_in"].add(f)
    out = []
    for b in buckets.values():
        out.append(dict(b, files=sorted(b["files"]), nfiles=len(b["files"]),
                        first_in=sorted(b["first_in"]), nfirst=len(b["first_in"]),
                        layers={str(k): v for k, v in sorted(b["layers"].items())}))
    out.sort(key=lambda b: (-b["nfirst"], -b["count"]))
    return per_file, out, crashes, timeouts, dups


def kairo_info(kairo, pin_time):
    st = Path(kairo).stat()
    mtime = datetime.datetime.fromtimestamp(st.st_mtime).astimezone()
    ver = subprocess.run([str(kairo), "--version"], text=True, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT).stdout.splitlines()
    ver = next((l.split(":", 1)[1].strip() for l in ver if "version" in l), "?")
    # The binary records no commit; the newest main commit not after its mtime
    # is the best available bound ("built from at most this").
    before = git("log", "-1", "--format=%h %ci", f"--before={mtime.isoformat()}", "main", check=False)
    return {"path": str(kairo), "mtime": mtime.isoformat(timespec="seconds"), "version": ver,
            "newest_main_commit_before_mtime": before,
            "built_before_pin": st.st_mtime < pin_time}


def write_reports(phase, short, meta, results, per_file, buckets, crashes, timeouts, dups):
    LOGS.mkdir(parents=True, exist_ok=True)
    js = LOGS / f"{phase}-{short}.json"
    lg = LOGS / f"{phase}-{short}.log"
    by_layer = {}
    for f, pf in per_file.items():
        L = by_layer.setdefault(pf["layer"], {"files": 0, "clean": 0, "diags": 0, "errors": 0})
        L["files"] += 1
        L["clean"] += pf["diags"] == 0 and not pf.get("crash") and not pf.get("timeout")
        L["diags"] += pf["diags"]
        L["errors"] += pf["errors"]
    meta = dict(meta, duplicate_diagnostics_dropped=dups)
    with open(js, "w", encoding="utf-8") as fh:
        json.dump({"meta": meta, "layers": {str(k): v for k, v in sorted(by_layer.items())},
                   "files": per_file, "buckets": buckets, "crashes": crashes,
                   "timeouts": timeouts,
                   "raw": [{"file": r["file"], "rc": r["rc"], "out": r["out"]} for r in results]},
                  fh, indent=1)
    names = {n: nm for n, nm, _ in LAYERS}
    names[0] = "(no layer)"
    with open(lg, "w", encoding="utf-8") as fh:
        w = fh.write
        w(f"phase {phase} at {meta['commit']}  ({meta['when']})\n")
        w(f"kairo {meta['kairo']['path']}\n  version {meta['kairo']['version']}, mtime {meta['kairo']['mtime']}"
          f", newest main commit before it: {meta['kairo']['newest_main_commit_before_mtime']}\n")
        w(f"jobs {meta['jobs']}, timeout {meta['timeout']} s, files {len(results)}, "
          f"duplicate diagnostics dropped {dups}\n\n")
        w(f"{'layer':40s} {'files':>6s} {'clean':>6s} {'errors':>7s} {'diags':>7s}\n")
        for k, L in sorted(by_layer.items()):
            w(f"{str(k) + ' ' + names.get(k, '?'):40s} {L['files']:6d} {L['clean']:6d} {L['errors']:7d} {L['diags']:7d}\n")
        w(f"\ncrashes ({len(crashes)}):\n")
        for c in crashes:
            w(f"  {c['file']} rc={c['rc']}\n" + "".join("      " + t + "\n" for t in c["tail"]))
        w(f"\ntimeouts ({len(timeouts)}):\n" + "".join(f"  {t}\n" for t in timeouts))
        w(f"\nbuckets ({len(buckets)}), by files whose FIRST error is in the bucket, then count:\n")
        for b in buckets:
            w(f"\n[{b['code']}] {b['norm']}\n   count {b['count']}  files {b['nfiles']}  first-error-in {b['nfirst']}"
              f"  layers {b['layers']}\n")
            for e in b["examples"]:
                w(f"   e.g. {e}\n")
        w("\nper file (diags, first error bucket):\n")
        for f, pf in sorted(per_file.items()):
            tag = " CRASH" if pf.get("crash") else (" TIMEOUT" if pf.get("timeout") else "")
            w(f"  {pf['diags']:5d}  {f}{tag}  {pf['first'][0] + ' ' + pf['first'][1] if pf['first'] else ''}\n")
    return lg, js


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--commit", default="main", help="main commit to pin (default: main's HEAD)")
    ap.add_argument("--phase", default="syntax", choices=["syntax"])
    ap.add_argument("--only", help="restrict migrate and the phase to paths containing this")
    ap.add_argument("--kairo", default=str(DEFAULT_KAIRO), help="Stage 1 binary (spec 4.1 rule 5: release)")
    ap.add_argument("--jobs", type=int, default=8)
    # 180 s: with the import closure parsed per file (gap G8), CompilerInstance.k
    # took 62 s under a load average of 50 and 38 s alone -- slow, not hung.
    ap.add_argument("--timeout", type=int, default=180, help="per-file seconds")
    ap.add_argument("--phase-only", action="store_true", help="skip steps 1-3; reuse the scratch tree")
    a = ap.parse_args()

    sha = git("rev-parse", "--verify", a.commit + "^{commit}")
    short = sha[:8]
    pin_time = int(git("log", "-1", "--format=%ct", sha))
    LOGS.mkdir(parents=True, exist_ok=True)
    plog = LOGS / f"pipeline-{short}.log"
    started = datetime.datetime.now().astimezone().isoformat(timespec="seconds")

    if not a.phase_only:
        with open(plog, "w", encoding="utf-8") as log:
            log.write(f"pipeline at {sha}  ({started})\n")
            make_scratch(sha)
            facts = cast_facts(short, log)
            migrate(facts, log, a.only)
            scratch_commit(f"migrate @{short}")
            apply_patches(log)
    elif not SCRATCH.exists():
        sys.exit("run.py: --phase-only but there is no scratch tree")
    head = git("rev-parse", "HEAD", cwd=SCRATCH)

    files = sorted(p for r in ROOTS for p in (SCRATCH / r).rglob("*.k")
                   if not a.only or a.only in p.relative_to(SCRATCH).as_posix())
    say(f"[4] phase {a.phase}: {len(files)} file(s), {a.jobs} jobs, {a.timeout} s timeout")
    meta = {"commit": sha, "scratch_head": head, "when": started, "phase": a.phase, "only": a.only,
            "jobs": a.jobs, "timeout": a.timeout, "kairo": kairo_info(a.kairo, pin_time),
            "files": len(files)}
    results = phase_syntax(a.kairo, files, a.jobs, a.timeout)
    per_file, buckets, crashes, timeouts, dups = triage(results)
    lg, js = write_reports(a.phase, short, meta, results, per_file, buckets, crashes, timeouts, dups)
    clean = sum(1 for r in results if per_file[r["file"]]["diags"] == 0 and not per_file[r["file"]]["crash"]
                and not r["timeout"])
    say(f"[4] {clean}/{len(results)} clean, {sum(b['count'] for b in buckets)} diagnostic(s) in "
        f"{len(buckets)} bucket(s), {len(crashes)} crash(es), {len(timeouts)} timeout(s)")
    say(f"    {lg.relative_to(REPO)}\n    {js.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
