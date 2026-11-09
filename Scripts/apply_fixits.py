#!/usr/bin/env python3
"""Apply the compiler's fix-its to the source.

    # run the compiler and apply what it suggests (kairo args after --)
    python3 Scripts/apply_fixits.py -- Compiler/Driver/Kairo.k --type-check-only -I ...
    # or read a log a compiler run already wrote (build.py / run.py logs, lit output)
    python3 Scripts/apply_fixits.py --from build/x86_64-linux-gnu/stage1.5/debug/logs/kairo.log

    --dry-run            print the unified diff, change nothing
    --code R049E,S012E   only fix-its of these diagnostic codes
    --severity error     only errors (default: error,warning; 'all' adds remarks etc.)
    --notes              also apply fix-its attached to notes (off by default, as clang:
                         a note's fix-it is an alternative, not the fix)
    --root DIR           resolve relative paths in the output against DIR (default: the
                         directory the compiler ran in, i.e. the current one)
    --kairo PATH         compiler for the run form (default: the newest staged Stage 1;
                         $KAIRO_BIN overrides)

The compiler's basic error format prints each ranged edit on its own line right after
its diagnostic (BasicConsumer.k; clang's -fdiagnostics-parseable-fixits form):

    file.k:3:14: error [S012E]: expected '=>' after the pattern
    fix-it:"file.k":{3:14-3:16}:"=> "

Lines and columns are 1-based, the end is exclusive, columns count bytes. All the
fix-its of one diagnostic are ONE edit (e.g. an open and a close paren) and are applied
together or not at all. An edit that overlaps one already taken is skipped and reported;
identical edits reported twice (one header seen from two TUs) are applied once. Files
are edited from the end backwards, so earlier offsets stay valid.
"""
import argparse, collections, difflib, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXE = ".exe" if os.name == "nt" else ""

DIAG_RE = re.compile(r"^(?P<file>.*?):(?P<line>\d+):(?P<col>\d+): (?P<sev>\w+) \[(?P<code>[A-Z]+\d+[A-Z])\]: ")
NOLOC_RE = re.compile(r"^(?P<sev>\w+) \[(?P<code>[A-Z]+\d+[A-Z])\]: ")
FIXIT_RE = re.compile(r'^fix-it:"(?P<file>(?:[^"\\]|\\.)*)":\{(?P<l1>\d+):(?P<c1>\d+)-(?P<l2>\d+):(?P<c2>\d+)\}:"(?P<text>(?:[^"\\]|\\.)*)"\s*$')
ESC = {"\\": "\\", '"': '"', "n": "\n", "t": "\t", "r": "\r"}

Edit = collections.namedtuple("Edit", "file l1 c1 l2 c2 text")
Group = collections.namedtuple("Group", "code sev where edits")


def unescape(s: str) -> str:
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append(ESC.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def parse(text: str):
    """[Group]: each diagnostic (or note) with the fix-its printed under it."""
    groups, cur = [], None
    for line in text.splitlines():
        m = FIXIT_RE.match(line)
        if m:
            if cur is not None:
                cur.edits.append(Edit(unescape(m["file"]), int(m["l1"]), int(m["c1"]),
                                      int(m["l2"]), int(m["c2"]), unescape(m["text"])))
            continue
        m = DIAG_RE.match(line) or NOLOC_RE.match(line)
        if m:
            where = f"{m['file']}:{m['line']}:{m['col']}" if "file" in m.groupdict() else "-"
            cur = Group(m["code"], m["sev"], where, [])
            groups.append(cur)
        # Any other line (source excerpt, summary) does not end the current group:
        # fix-its always follow their diagnostic directly, and a new diagnostic
        # starts a new group.
    return [g for g in groups if g.edits]


def default_kairo() -> Path:
    if os.environ.get("KAIRO_BIN"):
        return Path(os.environ["KAIRO_BIN"])
    cands = list((ROOT / "build").glob(f"*/release/bin/kairo{EXE}")) + list((ROOT / "build").glob(f"*/debug/bin/kairo{EXE}"))
    cands = [c for c in cands if c.parent.parent.parent.name != "release"]  # build/release/<triple> is Stage 0
    if not cands:
        sys.exit("apply_fixits.py: no Stage 1 compiler under build/<triple>/{release,debug}/bin; pass --kairo")
    return max(cands, key=lambda p: p.stat().st_mtime)


def offsets(data: bytes):
    """Byte offset of the start of each 1-based line (index 0 unused)."""
    starts = [0, 0]
    for i, b in enumerate(data):
        if b == 0x0A:
            starts.append(i + 1)
    return starts


def to_off(starts, size, line, col):
    if line < 1 or line >= len(starts):
        return None
    off = starts[line] + col - 1
    return off if 0 <= off <= size else None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="from_log", action="append", default=[], help="read diagnostics from this log (repeatable)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--code", default="", help="comma-separated diagnostic codes to apply (default all)")
    ap.add_argument("--severity", default="error,warning", help="comma list, or 'all'")
    ap.add_argument("--notes", action="store_true", help="also apply fix-its attached to notes")
    ap.add_argument("--root", default=None, help="base for relative paths (default: cwd)")
    ap.add_argument("--kairo", default=None)
    ap.add_argument("kairo_args", nargs="*", help="after --: arguments for a compiler run")
    a = ap.parse_args(argv)

    root = Path(a.root).resolve() if a.root else Path.cwd()
    texts = []
    for p in a.from_log:
        texts.append(Path(p).read_text(encoding="utf-8", errors="replace"))
    if a.kairo_args:
        kairo = Path(a.kairo) if a.kairo else default_kairo()
        cmd = [str(kairo), *a.kairo_args, "--error-format=basic"]
        print(f"apply_fixits.py: {' '.join(cmd)}", file=sys.stderr)
        r = subprocess.run(cmd, cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        texts.append(r.stdout.decode("utf-8", "replace"))
    if not texts:
        ap.error("nothing to read: pass --from LOG or compiler arguments after --")

    codes = {c.strip() for c in a.code.split(",") if c.strip()}
    sevs = None if a.severity == "all" else {s.strip() for s in a.severity.split(",")}
    groups = []
    for t in texts:
        groups += parse(t)

    picked, skipped = [], collections.Counter()
    for g in groups:
        if g.sev == "note" and not a.notes:
            skipped["note fix-it (use --notes)"] += 1
            continue
        if g.sev != "note" and sevs is not None and g.sev not in sevs:
            skipped[f"severity {g.sev}"] += 1
            continue
        if codes and g.code not in codes:
            skipped["code not selected"] += 1
            continue
        picked.append(g)

    # Resolve edits to byte ranges per file; a group is taken whole or not at all.
    files = {}          # path -> bytes
    taken = collections.defaultdict(list)   # path -> [(start, end, text)]
    seen = set()
    applied = collections.Counter()
    problems = []
    for g in picked:
        resolved = []
        ok = True
        for e in g.edits:
            p = Path(e.file)
            p = (p if p.is_absolute() else root / p).resolve()
            if p not in files:
                try:
                    files[p] = p.read_bytes()
                except OSError as ex:
                    problems.append(f"{g.where} [{g.code}]: cannot read {p}: {ex}")
                    ok = False
                    break
            data = files[p]
            st = offsets(data)
            b = to_off(st, len(data), e.l1, e.c1)
            en = to_off(st, len(data), e.l2, e.c2)
            if b is None or en is None or en < b:
                problems.append(f"{g.where} [{g.code}]: range {e.l1}:{e.c1}-{e.l2}:{e.c2} is outside {p.name}")
                ok = False
                break
            resolved.append((p, b, en, e.text.encode("utf-8")))
        if not ok:
            continue
        key = tuple(resolved)
        if key in seen:
            skipped["duplicate"] += 1
            continue
        clash = None
        for (p, b, en, _) in resolved:
            for (tb, te, _) in taken[p]:
                # Overlap, or two inserts at one point (order would be a guess).
                if (b < te and tb < en) or (b == en == tb == te):
                    clash = p
                    break
            if clash:
                break
        if clash:
            problems.append(f"{g.where} [{g.code}]: overlaps an edit already taken in {clash.name}; skipped")
            continue
        seen.add(key)
        for (p, b, en, t) in resolved:
            taken[p].append((b, en, t))
        applied[g.code] += 1

    changed = 0
    for p, edits in sorted(taken.items()):
        old = files[p]
        new = old
        for (b, en, t) in sorted(edits, key=lambda x: (x[0], x[1]), reverse=True):
            new = new[:b] + t + new[en:]
        if new == old:
            continue
        changed += 1
        rel = os.path.relpath(p, root)
        if a.dry_run:
            sys.stdout.writelines(difflib.unified_diff(
                old.decode("utf-8", "replace").splitlines(True), new.decode("utf-8", "replace").splitlines(True),
                f"a/{rel}", f"b/{rel}"))
        else:
            p.write_bytes(new)

    verb = "would change" if a.dry_run else "changed"
    print(f"apply_fixits.py: {sum(applied.values())} fix-it group(s) from {len(groups)} with fix-its; "
          f"{verb} {changed} file(s)", file=sys.stderr)
    for code, n in applied.most_common():
        print(f"    {code}: {n}", file=sys.stderr)
    for why, n in skipped.most_common():
        print(f"    skipped {n}: {why}", file=sys.stderr)
    for pr in problems[:50]:
        print(f"    ! {pr}", file=sys.stderr)
    if len(problems) > 50:
        print(f"    ! ... {len(problems) - 50} more", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
