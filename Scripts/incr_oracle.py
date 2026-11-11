#!/usr/bin/env python3
"""The oracle for incremental Sema's dependency log (Compiler/Spec/IncrementalSema.md).

Phase 1 records, per file, what its check read of other files (--dump-deps) and what
every file exports (--dump-interface). Nothing is reused yet, so nothing can be wrong
yet; this script is how the log is proven complete before phase 2 trusts it.

For each scenario (a set of text edits applied to a project):

  1. dump interface + deps of the project as it is            (BEFORE)
  2. apply the edits, dump again                              (AFTER)
  3. from the BEFORE deps and the interface DIFF, compute the files that must be
     re-checked (the invalidation rules, below)
  4. verify by brute force: every file predicted UNAFFECTED must have a
     byte-identical --print-sema section and byte-identical diagnostics.

A predicted-unaffected file that differs is a HOLE in the dependency log: the script
names the file and the scenario and exits 1. Over-invalidation (predicted, but nothing
observable changed) is allowed and reported.

Invalidation rules (file X is re-checked when any holds):

  R0  X was edited.
  R1  X has a name row (M, scope, name) and the declarations of that name in that
      scope of M differ: one added, removed, or with a different interface hash I.
      A row on a type's scope also reads the same-named members of every extension
      of that type, in whatever file.
  R2  X has an overlay row (of H, name) and some file in H's surface (its imports and
      what they re-export) changed that name at file scope; or H's surface changed.
  R3  X has a declaration row (id, part): sig -> I(id) changed; layout -> I changed
      for id or for a record its layout names (closed over `refs`); body -> the body
      hash or I changed. A removed declaration changed.
  R4  A name appeared at / disappeared from the file scope of a file in X's surface
      while another file in X's surface declares it (import collision, which I
      reports without any use).
  R5  X has a body row into a file that is itself re-checked (what a body reads is
      logged against the file that checked it, not against every later reader).
  R6  X has a body row into a file G, and G names (a name row, or an overlay row
      through its surface) a declaration whose BODY changed: a generic's body is
      compiled per instance by whoever names the instance first, so a later
      reader of an outer generic reads the inner one's body through G's lookups.
  R7  The macro definitions of a file in X's surface changed. A macro is expanded
      in the importer before it is parsed; no declaration row can stand for it.

Usage:
  incr_oracle.py --kairo BIN --root DIR --scenarios FILE.json [--only NAME] [--report OUT.json]
  incr_oracle.py --kairo BIN --root DIR --entry main.k [--flag F ...] \
                 --edit 'FILE:::OLD:::NEW' [--edit ...]

The scenario file: {"entry": "main.k", "flags": [...], "scenarios": [{"name": ...,
"edits": [{"file": ..., "old": ..., "new": ...}], "expect": [files], "line_shift":
false}]}. `expect`, when given, is the exact set of re-checked files (edited ones
included); a different prediction fails the run, which is how a test pins precision.

Edits are applied IN PLACE under --root and restored afterwards, also on failure:
point --root at a copy when the tree matters. An edit must keep the line count
unless the scenario says "line_shift": true (see `normalize`): a declaration's
position is not part of its interface, and --print-sema prints positions.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SECTION = re.compile(r"^===== SEMA fid \d+: (.*) =====$")
DIAG = re.compile(r"^(.*?):(\d+):(\d+): (error|warning|note|remark|fatal)\b")
POS = re.compile(r" @ \d+:\d+")


def die(msg):
    print(f"incr_oracle: {msg}", file=sys.stderr)
    sys.exit(2)


class Run:
    """One compile of the project: its dumps, its per-file --print-sema sections and
    per-file diagnostics."""

    def __init__(self, kairo, root, entry, flags, scratch, tag, timeout):
        self.iface_path = scratch / f"{tag}.interface.json"
        self.deps_path = scratch / f"{tag}.deps.json"
        cmd = [str(kairo), entry, *flags, "--type-check-only", "--error-format=basic", "--print-sema",
               f"--dump-interface={self.iface_path}", f"--dump-deps={self.deps_path}"]
        out_path = scratch / f"{tag}.stdout"
        err_path = scratch / f"{tag}.stderr"
        with open(out_path, "wb") as so, open(err_path, "wb") as se:
            try:
                p = subprocess.run(cmd, cwd=root, stdout=so, stderr=se, timeout=timeout)
            except subprocess.TimeoutExpired:
                die(f"{tag}: compile timed out after {timeout} s")
        self.rc = p.returncode
        # A crash is not a verdict: there is nothing to compare.
        if self.rc < 0 or self.rc > 1:
            tail = err_path.read_text(errors="replace")[-2000:]
            die(f"{tag}: compiler exited {self.rc}\n{tail}")
        if not self.iface_path.exists() or not self.deps_path.exists():
            die(f"{tag}: no dumps written (exit {self.rc}); stderr:\n" + err_path.read_text(errors="replace")[-2000:])
        self.iface = json.loads(self.iface_path.read_text())
        self.deps = json.loads(self.deps_path.read_text())
        self.root = self.iface["root"]
        self.sections = self._sections(out_path)
        self.diags = self._diags(err_path)
        for p_ in (out_path, err_path):
            p_.unlink()

    def _rel(self, path):
        pre = self.root.rstrip("/\\") + os.sep
        if path.startswith(pre):
            return path[len(pre):].replace(os.sep, "/")
        return path

    def _sections(self, out_path):
        sections, cur = {}, None
        with open(out_path, "r", errors="replace") as f:
            for line in f:
                m = SECTION.match(line.rstrip("\n"))
                if m:
                    cur = self._rel(m.group(1))
                    sections[cur] = []
                elif cur is not None:
                    sections[cur].append(line)
        return {k: "".join(v) for k, v in sections.items()}

    def _diags(self, err_path):
        """Diagnostics by the file of their primary line; a note belongs to the
        diagnostic above it, wherever it points."""
        diags, cur = {}, None
        with open(err_path, "r", errors="replace") as f:
            for line in f:
                m = DIAG.match(line)
                if m and m.group(4) != "note":
                    cur = self._rel(m.group(1))
                if cur is None:
                    cur = "<driver>"
                diags.setdefault(cur, []).append(line.replace(self.root, "<root>"))
        return {k: "".join(v) for k, v in diags.items()}


class Interface:
    """An interface dump, indexed the way the rules ask."""

    def __init__(self, iface):
        self.names = {}      # (module, scope, name) -> sorted [(id, I)]
        self.ext = {}        # (extended type id, name) -> sorted [(id, I)]
        self.decl = {}       # id -> (sorted [I], sorted [body])
        self.refs = {}       # id -> set(ids its types name)
        self.ext_of = {}     # extension scope id -> extended type id
        self.file_names = {}  # module -> set(names at file scope)
        self.modules = set()
        self.bodies = {}     # (module, scope, name) -> sorted [(id, body)]
        self.macros = {}     # module -> hash of its macro definitions
        for f in iface["files"]:
            m = f["module"]
            self.modules.add(m)
            self.macros[m] = f.get("macros", "")
            for d in f["decls"]:
                self.names.setdefault((m, d["scope"], d["name"]), []).append((d["id"], d["I"]))
                self.bodies.setdefault((m, d["scope"], d["name"]), []).append((d["id"], d["body"]))
                if d.get("ext"):
                    self.ext.setdefault((d["ext"], d["name"]), []).append((d["id"], d["I"]))
                e = self.decl.setdefault(d["id"], ([], []))
                e[0].append(d["I"])
                e[1].append(d["body"])
                self.refs.setdefault(d["id"], set()).update(d["refs"])
            for s in f["scopes"]:
                if s["ext"]:
                    self.ext_of[s["scope"]] = s["ext"]
                if s["scope"] == "":
                    self.file_names.setdefault(m, set()).update(s["names"])
                # A name a scope declares with no entry of this file (a C++ binding)
                # still exists: keep the key so its presence can change.
                for n in s["names"]:
                    self.names.setdefault((m, s["scope"], n), [])
        for v in list(self.names.values()) + list(self.ext.values()) + list(self.bodies.values()):
            v.sort()
        for e in self.decl.values():
            e[0].sort()
            e[1].sort()


def diff(a, b):
    """What changed between two interfaces, as the sets the rules test."""
    names = {k for k in a.names.keys() | b.names.keys() if a.names.get(k) != b.names.get(k)}
    ext = {k for k in a.ext.keys() | b.ext.keys() if a.ext.get(k) != b.ext.get(k)}
    ids = a.decl.keys() | b.decl.keys()
    sig = {i for i in ids if a.decl.get(i, (None,))[0] != b.decl.get(i, (None,))[0]}
    body = {i for i in ids if a.decl.get(i, (0, None))[1] != b.decl.get(i, (0, None))[1]}
    # Layout: closed over the records a layout names, in either version.
    layout = set(sig)
    grew = True
    while grew:
        grew = False
        for i in ids:
            if i in layout:
                continue
            if (a.refs.get(i, set()) | b.refs.get(i, set())) & layout:
                layout.add(i)
                grew = True
    presence = {k for k in names if k[1] == "" and (k in a.names) != (k in b.names)}
    for k in names:
        if k[1] == "" and bool(a.names.get(k)) != bool(b.names.get(k)):
            presence.add(k)
    for m in a.modules | b.modules:
        for n in a.file_names.get(m, set()) ^ b.file_names.get(m, set()):
            presence.add((m, "", n))
    name_bodies = {k for k in a.bodies.keys() | b.bodies.keys() if a.bodies.get(k) != b.bodies.get(k)}
    macros = {m for m in a.modules | b.modules if a.macros.get(m, "") != b.macros.get(m, "")}
    return {"names": names, "ext": ext, "sig": sig, "body": body, "layout": layout, "presence": presence,
            "name_bodies": name_bodies, "macros": macros}


def run_scenario(args, sc, before, ia, flags, entry, scratch):
    root = Path(args.root)
    name = sc["name"]
    saved = {}
    try:
        for e in sc["edits"]:
            p = root / e["file"]
            cur = p.read_text()
            if e["file"] not in saved:
                saved[e["file"]] = cur
            if cur.count(e["old"]) != 1:
                die(f"{name}: edit of {e['file']}: old text occurs {cur.count(e['old'])} times, need exactly 1")
            if e["old"].count("\n") != e["new"].count("\n") and not sc.get("line_shift"):
                die(f"{name}: edit of {e['file']} changes the line count; make it line-preserving "
                    f"or set \"line_shift\": true")
            p.write_text(cur.replace(e["old"], e["new"]))
        after = Run(args.kairo, root, entry, flags, scratch, "after", args.timeout)
    finally:
        for f, text in saved.items():
            (root / f).write_text(text)

    ib = Interface(after.iface)
    d = diff(ia, ib)
    deps = {f["module"]: f for f in before.deps["files"]}
    path_of = {f["module"]: f["path"] for f in before.deps["files"]}
    module_of_path = {p: m for m, p in path_of.items() if p}
    surf_a = {f["module"]: set(f["surface"]) for f in before.deps["files"]}
    surf_b = {f["module"]: set(f["surface"]) for f in after.deps["files"]}
    if set(surf_a) != set(surf_b):
        die(f"{name}: the edit changes the set of files in the graph; that is a graph change, not a "
            f"re-check (out of this oracle's scope)")

    why = {}
    for f in saved:
        if f not in module_of_path:
            die(f"{name}: edited file {f} is not in the project's graph")
        why[module_of_path[f]] = "R0 edited"

    file_changed = {}  # name -> modules whose file scope changed it
    for (m, s, n) in d["names"]:
        if s == "":
            file_changed.setdefault(n, set()).add(m)
    presence = {}
    for (m, s, n) in d["presence"]:
        presence.setdefault(n, set()).add(m)

    for m, f in deps.items():
        if m in why:
            continue
        reason = None
        for r in f["names"]:
            k = (r["module"], r["scope"], r["name"])
            if k in d["names"]:
                reason = f"R1 name {r['name']} in {r['scope'] or r['module'] + '#<file>'}"
                break
            if r["scope"]:
                # The scope of a type, or of an extension of one: every extension
                # of that type answers the same lookup.
                target = ia.ext_of.get(r["scope"], ib.ext_of.get(r["scope"], r["scope"]))
                if (target, r["name"]) in d["ext"]:
                    reason = f"R1 extension member {r['name']} of {target}"
                    break
        if reason is None:
            for o in f["overlay"]:
                h = o["of"]
                if surf_a.get(h) != surf_b.get(h):
                    reason = f"R2 surface of {h} changed"
                    break
                surf = surf_a.get(h, set())
                for n in o["names"]:
                    if file_changed.get(n, set()) & surf:
                        reason = f"R2 overlay name {n} via {sorted(file_changed[n] & surf)[0]}"
                        break
                if reason:
                    break
        if reason is None:
            for r in f["decls"]:
                i, part = r["id"], r["part"]
                if part == "sig" and i in d["sig"]:
                    reason = f"R3 signature of {i}"
                elif part == "layout" and i in d["layout"]:
                    reason = f"R3 layout of {i}"
                elif part == "body" and (i in d["body"] or i in d["sig"]):
                    reason = f"R3 body of {i}"
                if reason:
                    break
        if reason is None:
            surf = surf_a.get(m, set()) | surf_b.get(m, set())
            for n, mods in presence.items():
                src = mods & surf
                if not src:
                    continue
                others = [s for s in surf if s not in src and (n in ia.file_names.get(s, ()) or n in ib.file_names.get(s, ()))]
                own = n in ia.file_names.get(m, ()) or n in ib.file_names.get(m, ())
                if others or own:
                    reason = f"R4 import collision on {n} ({sorted(src)[0]} vs {(others or [m])[0]})"
                    break
        if reason is None:
            hit = (surf_a.get(m, set()) | surf_b.get(m, set())) & d["macros"]
            if hit:
                reason = f"R7 macros of {sorted(hit)[0]}"
        if reason:
            why[m] = reason

    # R6: the files that name a declaration whose body changed.
    body_file_scope = {}
    for (bm, bs, bn) in d["name_bodies"]:
        if bs == "":
            body_file_scope.setdefault(bn, set()).add(bm)
    names_changed_body = set()
    for m, f in deps.items():
        if any((r["module"], r["scope"], r["name"]) in d["name_bodies"] for r in f["names"]):
            names_changed_body.add(m)
            continue
        for o in f["overlay"]:
            surf = surf_a.get(o["of"], set())
            if any(body_file_scope.get(n, set()) & surf for n in o["names"]):
                names_changed_body.add(m)
                break

    grew = True
    while grew:
        grew = False
        for m, f in deps.items():
            if m in why:
                continue
            for r in f["decls"]:
                if r["part"] != "body":
                    continue
                home = r["id"].split("#", 1)[0]
                if home in why:
                    why[m] = f"R5 body of {r['id']} in re-checked {home}"
                    grew = True
                    break
                if home in names_changed_body:
                    why[m] = f"R6 body of {r['id']}, whose file names a changed body"
                    grew = True
                    break

    def normalize(text):
        return POS.sub(" @ L:C", text) if sc.get("line_shift") else text

    def norm_diag(text):
        return re.sub(r":\d+:\d+: ", ":L:C: ", text) if sc.get("line_shift") else text

    predicted = {path_of[m] or f"<{m}>" for m in why}
    actual, holes = set(), []
    keys = set(before.sections) | set(after.sections) | set(before.diags) | set(after.diags)
    for k in sorted(keys):
        same = (normalize(before.sections.get(k, "")) == normalize(after.sections.get(k, ""))
                and norm_diag(before.diags.get(k, "")) == norm_diag(after.diags.get(k, "")))
        if same:
            continue
        actual.add(k)
        if k not in predicted:
            what = "print-sema" if normalize(before.sections.get(k, "")) != normalize(after.sections.get(k, "")) else "diagnostics"
            holes.append((k, what))

    res = {
        "name": name,
        "predicted": sorted(predicted),
        "actual": sorted(actual),
        "over": sorted(predicted - actual - set(saved)),
        "holes": holes,
        "why": {path_of[m] or f"<{m}>": r for m, r in sorted(why.items())},
        "interface_changed": sorted(d["sig"] | d["body"])[:40],
    }
    if "expect" in sc and sorted(sc["expect"]) != res["predicted"]:
        res["expect_mismatch"] = sorted(sc["expect"])
    if args.keep and holes:
        keep = scratch / f"hole-{name}"
        keep.mkdir(exist_ok=True)
        for k, _ in holes:
            safe = k.replace("/", "_")
            (keep / f"{safe}.before").write_text(before.sections.get(k, "") + "\n--diag--\n" + before.diags.get(k, ""))
            (keep / f"{safe}.after").write_text(after.sections.get(k, "") + "\n--diag--\n" + after.diags.get(k, ""))
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kairo", required=True, help="the compiler to run (a build with --dump-interface / --dump-deps)")
    ap.add_argument("--root", required=True, help="the project directory; the compiler runs there and edits are applied there")
    ap.add_argument("--scenarios", help="a scenario file (see the module docstring)")
    ap.add_argument("--entry", help="the entry file, relative to --root (without --scenarios, or to override its)")
    ap.add_argument("--flag", action="append", default=[], help="a compiler flag; repeatable, added after the scenario file's")
    ap.add_argument("--flags-file", help="a file of compiler flags, one per line, added before --flag")
    ap.add_argument("--edit", action="append", default=[], help="FILE:::OLD:::NEW; all --edit form one scenario")
    ap.add_argument("--only", action="append", default=[], help="run only the scenario(s) of this name")
    ap.add_argument("--line-shift", action="store_true", help="the --edit scenario may change line counts")
    ap.add_argument("--report", help="write the results as JSON here")
    ap.add_argument("--scratch", help="where dumps go (default: a temporary directory)")
    ap.add_argument("--keep", action="store_true", help="keep the before/after sections of every hole under --scratch")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds one compile may take")
    args = ap.parse_args()

    spec = {"flags": [], "scenarios": []}
    if args.scenarios:
        spec = json.loads(Path(args.scenarios).read_text())
    entry = args.entry or spec.get("entry")
    if not entry:
        die("no entry: pass --entry or give the scenario file one")
    flags = list(spec.get("flags", []))
    if args.flags_file:
        flags += [l for l in Path(args.flags_file).read_text().splitlines() if l.strip()]
    flags += args.flag
    scenarios = list(spec.get("scenarios", []))
    if args.edit:
        edits = []
        for e in args.edit:
            parts = e.split(":::")
            if len(parts) != 3:
                die(f"--edit wants FILE:::OLD:::NEW, got {e!r}")
            edits.append({"file": parts[0], "old": parts[1], "new": parts[2]})
        scenarios.append({"name": "cli", "edits": edits, "line_shift": args.line_shift})
    if args.only:
        scenarios = [s for s in scenarios if s["name"] in args.only]
    if not scenarios:
        die("no scenarios to run")

    tmp = None
    if args.scratch:
        scratch = Path(args.scratch)
        scratch.mkdir(parents=True, exist_ok=True)
    else:
        tmp = tempfile.TemporaryDirectory(prefix="incr-oracle-")
        scratch = Path(tmp.name)
    scratch = scratch.resolve()
    args.kairo = str(Path(args.kairo).resolve())

    before = Run(args.kairo, Path(args.root), entry, flags, scratch, "before", args.timeout)
    ia = Interface(before.iface)
    results, failed = [], False
    print(f"{'scenario':34} {'predicted':>9} {'changed':>8} {'over':>5}  verdict")
    for sc in scenarios:
        r = run_scenario(args, sc, before, ia, flags, entry, scratch)
        results.append(r)
        verdict = "ok"
        if r["holes"]:
            verdict = "HOLE"
            failed = True
        elif "expect_mismatch" in r:
            verdict = "UNEXPECTED PREDICTION"
            failed = True
        print(f"{r['name']:34} {len(r['predicted']):>9} {len(r['actual']):>8} {len(r['over']):>5}  {verdict}")
        for k, what in r["holes"]:
            print(f"    HOLE: {k} was predicted unaffected by '{r['name']}' but its {what} changed")
        if "expect_mismatch" in r:
            print(f"    expected re-check set {r['expect_mismatch']}")
            print(f"    predicted            {r['predicted']}")
            for f, w in r["why"].items():
                print(f"      {f}: {w}")
        if args.only or args.edit:
            for f, w in r["why"].items():
                print(f"    {f}: {w}")
    if args.report:
        Path(args.report).write_text(json.dumps(results, indent=1) + "\n")
    if tmp is not None:
        tmp.cleanup()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
