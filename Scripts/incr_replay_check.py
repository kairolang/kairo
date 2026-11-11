#!/usr/bin/env python3
"""The oracle for a live check (Compiler/Spec/IncrementalSema.md, phase 4).

`kairo --incr-replay=<script>` type-checks an entry once and then applies the script's
edits step by step IN ONE PROCESS, bringing its result up to date after each
(Compiler/Tooling/LiveCheck.k). This script proves every step against a clean run:

  1. run the compiler with --incr-replay on the project (it edits the files in place),
     keeping each step's diagnostics and --dump-interface;
  2. restore the project, and for step 0 and after applying each step's edits here,
     run a FRESH `kairo --type-check-only --dump-interface` on the same paths;
  3. a step whose diagnostics (stderr, byte for byte) or interface dump differ from
     the fresh run's is reported, and the exit status is 1.

Nothing is normalized: same directory, same paths, same flags on both sides.

The script format is the compiler's (Compiler/Tooling/IncrReplay.k): `step <name>`,
`replace <file>:::<old>:::<new>`, `write <file>:::<text>`, `remove <file>`, `\\n` for a
line break, `#` comments. --from-scenarios makes one from an incr_oracle.py scenario
file instead: each scenario is two steps, its edits and then their reversal, so a
whole scenario list runs as one session.

Usage:
  incr_replay_check.py --kairo BIN --root DIR --entry main.k --script FILE [--flag F ...]
  incr_replay_check.py --kairo BIN --root DIR --from-scenarios scenarios.json [--flag F ...]

--root is edited in place and left as the last step made it: point it at a copy.
--rss prints the live process's resident size after each step (Linux /proc).
--expect-mode NAME=MODE fails unless step NAME reports that mode.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

STEP = re.compile(r"^incr-replay: step (\d+) (.*?): (\S+) \((.*)\), (\d+) files, (\d+) errors, (\d+) ms$")
MARK = re.compile(r"^== incr-replay step (\d+) (.*)$")


def die(msg):
    print(f"incr_replay_check: {msg}", file=sys.stderr)
    sys.exit(2)


def unescape(s):
    return s.replace("\\n", "\n")


def parse_script(text):
    """[(name, [(op, file, a, b)])]"""
    steps = []
    for line in text.split("\n"):
        if not line or line.startswith("#"):
            continue
        if line.startswith("step "):
            steps.append((line[5:], []))
            continue
        if not steps:
            die(f"an edit before the first `step`: {line}")
        if line.startswith("replace "):
            f = line[8:].split(":::")
            if len(f) != 3:
                die(f"replace wants <file>:::<old>:::<new>: {line}")
            steps[-1][1].append(("replace", f[0], unescape(f[1]), unescape(f[2])))
        elif line.startswith("write "):
            f = line[6:].split(":::")
            if len(f) != 2:
                die(f"write wants <file>:::<text>: {line}")
            steps[-1][1].append(("write", f[0], unescape(f[1]), ""))
        elif line.startswith("remove "):
            steps[-1][1].append(("remove", line[7:], "", ""))
        else:
            die(f"unknown command: {line}")
    return steps


def apply(root, edits):
    for op, f, a, b in edits:
        p = root / f
        if op == "replace":
            cur = p.read_text()
            if cur.count(a) != 1:
                die(f"{f}: old text occurs {cur.count(a)} times, need exactly 1")
            p.write_text(cur.replace(a, b))
        elif op == "write":
            p.write_text(a)
        else:
            p.unlink()


def script_from_scenarios(path):
    spec = json.loads(Path(path).read_text())
    lines = []

    def esc(s):
        if ":::" in s:
            die("a scenario edit holds ':::'")
        return s.replace("\n", "\\n")

    for sc in spec["scenarios"]:
        lines.append(f"step {sc['name']}")
        for e in sc["edits"]:
            lines.append(f"replace {e['file']}:::{esc(e['old'])}:::{esc(e['new'])}")
        lines.append(f"step {sc['name']}.revert")
        for e in reversed(sc["edits"]):
            lines.append(f"replace {e['file']}:::{esc(e['new'])}:::{esc(e['old'])}")
    return "\n".join(lines) + "\n", spec.get("entry"), list(spec.get("flags", []))


def rss_kb(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kairo", required=True)
    ap.add_argument("--root", required=True, help="the project directory; edited in place")
    ap.add_argument("--entry")
    ap.add_argument("--script")
    ap.add_argument("--from-scenarios")
    ap.add_argument("--flag", action="append", default=[])
    ap.add_argument("--flags-file")
    ap.add_argument("--scratch", required=True)
    ap.add_argument("--rss", action="store_true")
    ap.add_argument("--live-only", action="store_true",
                    help="run the live session alone (for timing): no clean runs, nothing compared")
    ap.add_argument("--expect-mode", action="append", default=[], help="NAME=MODE")
    ap.add_argument("--timeout", type=int, default=3600)
    args = ap.parse_args()

    root = Path(args.root).resolve()
    scratch = Path(args.scratch).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    kairo = str(Path(args.kairo).resolve())
    flags, entry = [], args.entry
    if args.from_scenarios:
        text, sc_entry, sc_flags = script_from_scenarios(args.from_scenarios)
        entry = entry or sc_entry
        flags += sc_flags
    elif args.script:
        text = Path(args.script).read_text()
    else:
        die("give --script or --from-scenarios")
    if not entry:
        die("no entry")
    if args.flags_file:
        flags += [l for l in Path(args.flags_file).read_text().splitlines() if l.strip()]
    flags += args.flag
    script_path = scratch / "replay.script"
    script_path.write_text(text)
    steps = [("initial", [])] + parse_script(text)

    # What the edits touch, kept so the clean side starts from the same files.
    touched = sorted({f for _, edits in steps for _, f, _, _ in edits})
    saved = {f: ((root / f).read_bytes() if (root / f).exists() else None) for f in touched}

    dumps = scratch / "live-dumps"
    if dumps.exists():
        shutil.rmtree(dumps)
    cmd = [kairo, entry, *flags, "--error-format=basic", f"--incr-replay={script_path}"]
    if not args.live_only:
        cmd.append(f"--incr-replay-dump={dumps}")
    err_path = scratch / "live.stderr"
    live = []
    with open(err_path, "wb") as se:
        p = subprocess.Popen(cmd, cwd=root, stdout=subprocess.PIPE, stderr=se, text=True)
        for line in p.stdout:
            m = STEP.match(line.rstrip("\n"))
            if m:
                live.append({"n": int(m.group(1)), "name": m.group(2), "mode": m.group(3), "why": m.group(4),
                             "files": int(m.group(5)), "ms": int(m.group(7)), "rss": rss_kb(p.pid)})
        rc = p.wait(timeout=args.timeout)
    if rc != 0:
        die(f"the live run exited {rc}\n" + err_path.read_text(errors="replace")[-2000:])
    if len(live) != len(steps):
        die(f"the live run reported {len(live)} steps, the script has {len(steps)}")

    blocks, cur = {}, None
    for line in err_path.read_text(errors="replace").splitlines(keepends=True):
        m = MARK.match(line.rstrip("\n"))
        if m:
            cur = int(m.group(1))
            blocks[cur] = ""
        elif cur is not None:
            blocks[cur] += line

    failed = False
    if not args.live_only:
        for f, data in saved.items():
            if data is None:
                (root / f).unlink(missing_ok=True)
            else:
                (root / f).write_bytes(data)
    modes = {}
    for i, (name, edits) in enumerate(steps):
        s = live[i]
        modes[s["mode"]] = modes.get(s["mode"], 0) + 1
        verdict = "not compared"
        if not args.live_only:
            apply(root, edits)
            clean_dump = scratch / "clean.interface.json"
            cp = subprocess.run([kairo, entry, *flags, "--error-format=basic", "--type-check-only",
                                 f"--dump-interface={clean_dump}"], cwd=root, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, timeout=args.timeout)
            if cp.returncode < 0 or cp.returncode > 1:
                die(f"step {i} {name}: the clean run exited {cp.returncode}")
            what = []
            if cp.stderr.decode(errors="replace") != blocks.get(i, ""):
                what.append("diagnostics")
                (scratch / f"step{i}.clean.stderr").write_bytes(cp.stderr)
                (scratch / f"step{i}.live.stderr").write_text(blocks.get(i, ""))
            live_dump = dumps / f"step{i}.interface.json"
            a = clean_dump.read_bytes() if clean_dump.exists() else b""
            b = live_dump.read_bytes() if live_dump.exists() else b""
            if a != b:
                what.append("interface")
            verdict = "ok" if not what else "DIFFERS (" + ", ".join(what) + ")"
            failed = failed or bool(what)
        rss = f"  rss {s['rss'] // 1024} MB" if args.rss else ""
        print(f"step {i} {name}: {s['mode']} ({s['why']})  {s['ms']} ms{rss}  {verdict}")
    for em in args.expect_mode:
        n, _, want = em.partition("=")
        got = [s["mode"] for s in live if s["name"] == n]
        if got != [want]:
            print(f"UNEXPECTED MODE: step {n} is {got}, expected {want}")
            failed = True
    print("modes: " + ", ".join(f"{k} {v}" for k, v in sorted(modes.items())) + f"; {len(steps)} steps")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
