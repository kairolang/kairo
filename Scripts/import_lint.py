#!/usr/bin/env python3
"""import_lint.py: report and fix the import lines of Kairo source files.

Input is one or more JSON dumps written by `kairo --dump-import-uses=<path>`
(FrontendAction::_dump_import_uses): per TU, its written imports and every
name the import overlay answered, attributed to the import(s) that folded it,
with the spelled use sites. Run the compiler once per configuration the
sources compile under (debug and release, every target with arch branches,
every entry point) and pass every dump: the uses are unioned, and a file no
dump reached is never touched.

For the compiler tree, a dump is a whole-tree type-check with the build's own
flags plus the dump flag, from each build.py TARGETS entry (Kairo.k, Kcc.k,
kld.k, ParseOnceTest.k, GenClangDiagIdentity.k), under x86-64 debug (-D
DEBUG), x86-64 release and aarch64 debug. The aarch64 form is the host
argv template with the target flags swapped; the host form takes build.py's llvm_args +
platform_args + profile_args + --native + shared_libcxx_args, then
`--type-check-only -A R058W -fduck-generics -fdefault-visibility=spec -I Compiler -I Linker
--dump-import-uses=<out>.json` (-fduck-generics and -fdefault-visibility are internal; since
2026-11-08 the first is off by default and the tree turns it on, and the tree builds under
the language's `spec` visibility with a module.k per top-level directory, as build.py passes
them, build.tree_visibility_args).
Warnings left on, those runs double as the before/after diagnostics gate.

    python3 Scripts/import_lint.py Compiler/ --dump a.json --dump b.json         # report
    python3 Scripts/import_lint.py Compiler/ --dump a.json ... --fix             # rewrite

Per file it reports wildcard imports, dead imports (no recorded use) and
misordered imports. --fix rewrites:

  * `import A::B::*;` -> `import A::B::{x, y, z};` (sorted) with the names
    resolved through it. When more than --max-selective names come through
    it, and every one of them has only spelled, rewritable use sites, it
    becomes `import A::B;` and each use is qualified as `B::name` instead,
    unless `B` is already an identifier anywhere in the file (it would then
    collide with a name the file uses). A name with an unspelled use (a lang
    item probe, a macro body expanded here) cannot be qualified, so it keeps
    the selective form.
  * a Kairo import nothing resolved through is removed, unless it is a
    `pub`/`prot` re-export (reported only: nobody downstream was asked), or
    its target file holds `extend` blocks (used through no name, so the edge
    is what compiles it), or its removal would leave a file of the build
    reachable from no entry. Reachability is over the import graph of the
    dumps (every written edge, used or not), re-planned until no file is lost;
    any TU that no import reaches counts as an entry too.
  * anchors: `import X` searches the roots, `import self::x` the
    importing file's directory, `import module::x` its module root. They are
    parsed, kept through every rewrite and checked against the dump's `anchor`
    ("", "self", "module"); `import module X` (space form) is removed from the
    language and no longer read.
  * order: every ffi import first, in its original relative order, one blank
    line, then the Kairo imports sorted by path. A comment line directly
    above an import travels with it, as does a trailing comment.

Style (the user's formatter rule, 2026-11-08), applied to every Kairo import
--fix or --format-only writes:

  * one plain name in braces loses them: `import A::B::{x};` -> `import A::B::x;`
    unless `A/B/x.k` or `A/B/x/module.k` exists under the file's directory or
    a search root (Compiler/, Linker/, Lib/, the repo root): then the bare
    form resolves to that MODULE (file-first lookup) and the braces, which
    name the declaration, stay. An alias (`{x as y}`), a nested path
    (`{a::B}`) or a `*` item also keeps its braces.
  * a single aliased name drops them too (`import A::B::x as y;`), same
    module exception.
  * two to six items go one per line, 4-space indent, trailing comma, the `}`
    alone and with no `;`:

        import A::B::{
            x,
            y,
        }

  * more than six items, each at most 24 columns: the grid form, names in
    rows, each column padded to its widest, as many columns (max 8) as fit
    in 100 columns, order kept, trailing comma, `}` alone.

--format-only does only this (no dump needed, nothing reordered or removed).
A multi-line import is read back as one import, so a second run is a no-op.

ffi imports are never removed: a header's names are bound for the whole TU
through its include closure and inline C++ uses names Sema never sees.

A generated file (its header says "auto-generated" / "do not edit") is
skipped and reported: its generator owns its import lines.

A file with platform-conditional code (`defined!(_WIN32)` and the like) that
the dumps' configurations do not cover keeps its imports as written; only its
order is fixed. The uses inside the branches no dump compiled are unknown.

Every edit is checked against the file as it is when it is written: a site
whose text is not the name the dump recorded makes the whole file skipped
(it changed since the dump). A second --fix over a fresh dump changes nothing.
"""
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Never edited, whatever the arguments say: Tests/ is frozen and Lib/ is the
# user's (see CLAUDE.md).
FORBIDDEN = [ROOT / "Tests", ROOT / "Lib"]

KAIRO_IMPORT = re.compile(
    r'^(?P<vis>(?:pub|prot|priv)\s+)?import\s+(?P<anchor>(?:self|module)::)?'
    r'(?P<path>[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)'
    r'(?P<tail>::\*|::\{[^}]*\}|\s+as\s+[A-Za-z_]\w*)?'
    r'\s*(?P<semi>;)?\s*(?P<comment>//.*)?$')
FFI_IMPORT = re.compile(r'^ffi\s+"[^"]*"\s+import\s+"[^"]*"(?:\s+as\s+[A-Za-z_]\w*)?\s*;?\s*(?://.*)?$')
COMMENT = re.compile(r'^\s*//')
IMPORT_HEAD = re.compile(r'^(?:(?:pub|prot|priv)\s+)?import\b')
PLAIN_ITEM = re.compile(r'^[A-Za-z_]\w*$')
# Where a module path can resolve besides the importing file's directory
# (build.py passes -I Compiler -I Linker; std:: lives in Lib/).
SEARCH_ROOTS = [ROOT / "Compiler", ROOT / "Linker", ROOT / "Lib", ROOT]
INDENT = "    "  # Kairo's tab size


def module_root_of(d):
    """The nearest directory at or above `d` holding a module.k, or None."""
    for c in [d] + list(d.parents):
        if (c / "module.k").is_file():
            return c
    return None


def module_exists(src, modpath, anchor=""):
    """True when `modpath` (a list of segments) names a module file, so that a
    bare `import P::name;` would resolve to it rather than to a declaration.
    An anchored import looks in one directory only: `self::` the importing
    file's, `module::` its module root (Compiler/Spec/Imports.md, Path
    resolution); a plain one in the file's directory and the search roots."""
    rel = Path(*modpath)
    here = Path(src).resolve().parent
    if anchor == "self":
        bases = [here]
    elif anchor == "module":
        mr = module_root_of(here)
        bases = [mr] if mr else []
    else:
        bases = [here] + SEARCH_ROOTS
    for base in bases:
        if (base / rel).with_suffix(".k").is_file() or (base / rel / "module.k").is_file():
            return True
    return False


def grid_rows(items, indent=INDENT, width=100):
    """Rule 4.1's grid: row-major, each column padded to its widest `name,`,
    as many columns (max 8) as fit in `width`; the last cell of a row is not
    padded. Order is preserved."""
    cells = [x + "," for x in items]
    for ncol in range(min(8, len(cells)), 0, -1):
        rows = [cells[i:i + ncol] for i in range(0, len(cells), ncol)]
        wid = [max(len(r[c]) for r in rows if c < len(r)) for c in range(ncol)]
        lines = []
        for r in rows:
            parts = [r[c].ljust(wid[c]) if c + 1 < len(r) else r[c] for c in range(len(r))]
            lines.append(indent + " ".join(parts))
        if ncol == 1 or max(len(l) for l in lines) <= width:
            return lines
    return [indent + c for c in cells]


def styled_tail(src, path, tail, anchor=""):
    """The tail (`::{...}`) in the formatter spec's layout (README 4.1, 4.2, 5.1,
    5.2): a list of output lines whose first one continues the `import path`
    line. The closing `}` is flagged by the caller (no `;` after it)."""
    if not tail.startswith("::{"):
        return [tail]
    items = [re.sub(r'\s+', ' ', x.strip()) for x in tail[3:-1].split(",")]
    items = [x for x in items if x]
    if len(items) == 1:
        it = items[0]
        base = it.split(" as ")[0].strip()
        if PLAIN_ITEM.match(base) and src is not None and not module_exists(src, path.split("::") + [base], anchor):
            return ["::" + it]
        return ["::{" + it + "}"]
    if len(items) > 6 and all(len(x) <= 24 for x in items):
        return ["::{"] + grid_rows(items) + ["}"]
    return ["::{"] + [INDENT + it + "," for it in items] + ["}"]


# Arch / OS branches no dump configuration compiles (x86-64 debug and release,
# aarch64 debug): uses inside them are invisible to the dumps.
UNCOVERED_BRANCH = re.compile(
    r'defined!\((?:_WIN32|_WIN64|_MSC_VER|__APPLE__|__AVX\w*|__SIZEOF_INT128__|__wasm__|__s390x__|'
    r'__riscv|__ppc64__|__powerpc64__|__linux__|__i386__|__arm__|__SSE2__|__x86_64__|__aarch64__|__ARM_NEON)\)')
GENERATED = re.compile(r'(?i)auto-generated|do not edit')
IDENT = re.compile(r'[A-Za-z_]\w*')


def ident_char(c: str) -> bool:
    return c.isalnum() or c == "_"


class Import:
    """One import statement as written: a line, plus the comment lines directly above it."""

    def __init__(self, lineno, text, m, ffi, end=None, src=None):
        self.lineno = lineno          # 1-based, the `import` line
        self.end = end or lineno      # last line (a braced list may span several)
        self.text = text              # the lines as written, joined with "\n"
        self.src = src                # the file, for the module-collision test
        self.ffi = ffi
        self.lead = []                # comment lines attached above
        if ffi:
            self.vis = self.path = self.tail = self.comment = ""
            self.anchor = ""
            self.semi = True
            return
        self.vis = (m.group("vis") or "").strip()
        self.anchor = (m.group("anchor") or "").rstrip(":")   # "", "self" or "module"
        self.path = m.group("path")
        self.tail = (m.group("tail") or "").strip()
        self.semi = bool(m.group("semi"))
        self.comment = m.group("comment") or ""

    @property
    def wildcard(self):
        return self.tail == "::*"

    @property
    def reexport(self):
        return self.vis in ("pub", "prot")

    def render(self, tail=None):
        """The import as output text (possibly several lines, joined with "\n")."""
        if self.ffi:
            return self.text
        t = self.tail if tail is None else tail
        s = (self.vis + " " if self.vis else "") + "import " + (self.anchor + "::" if self.anchor else "") + self.path
        if t.startswith("as"):
            out = [s + " " + t]
        else:
            parts = styled_tail(self.src, self.path, t, self.anchor)
            out = [s + parts[0]] + parts[1:]
        if not out[-1].startswith("}"):
            out[-1] += ";"   # a closing `}` stands alone: no `;` after it
        if self.comment:
            out[-1] += " " + self.comment
        return "\n".join(out)

    def sort_key(self):
        return (self.path, self.tail, self.vis, self.anchor)

    def written(self, lines):
        """The import's lines as they are in `lines` now."""
        return "\n".join(l.rstrip("\n") for l in lines[self.lineno - 1:self.end])


class FileUses:
    """The union of every dump's view of one file."""

    def __init__(self):
        self.lines = {}                        # import line -> (resolved_path, pub)
        self.anchors = {}                      # import line -> "", "self" or "module"
        self.names = defaultdict(lambda: {"origins": set(), "sites": {}, "unspelled": 0})
        self.seen = 0


def load_dumps(paths):
    files = defaultdict(FileUses)
    edges = defaultdict(set)                   # file -> files its Kairo imports resolve to
    entries = set()
    for p in paths:
        d = json.load(open(p))
        for tu in d["tus"]:
            f = str(Path(tu["path"]).resolve())
            if tu["fid"] == 0:
                entries.add(f)
            fu = files[f]
            fu.seen += 1
            idx_line = {}
            for imp in tu["imports"]:
                if imp is None:
                    continue
                if imp["prelude"]:
                    continue
                idx_line[imp["idx"]] = imp["line"]
                if not imp["ffi"]:
                    rp = str(Path(imp["resolved_path"]).resolve()) if imp["resolved_path"] else ""
                    fu.lines[imp["line"]] = (rp, imp["pub"])
                    fu.anchors[imp["line"]] = imp.get("anchor", "")
                    if rp:
                        edges[f].add((imp["line"], rp))
            for n in tu["names"]:
                e = fu.names[n["name"]]
                for o in n["origins"]:
                    if o in idx_line:
                        e["origins"].add(idx_line[o])
                for off, line, col in n["sites"]:
                    e["sites"][off] = (line, col)
                e["unspelled"] += n["implicit"] + n["foreign"]
    # A TU nothing imports is a root of the build whatever its fid: the entry
    # file is fid 0 in a one-input run, but extra inputs, or a dump of a
    # differently ordered run, must not turn a root into "unreachable" (that
    # would only ever make the reachability test blind, never stricter).
    imported = {t for es in edges.values() for _, t in es}
    entries |= {f for f in files if f not in imported}
    return files, edges, entries


EXTEND_BLOCK = re.compile(r'^\s*(?:(?:pub|prot|priv)\s+)?extend\b', re.M)
_extend_cache = {}


def holds_extend(path):
    """True when the file declares `extend` blocks. Such a file is used through
    no name (its methods are found on the extended type), so no dump records a
    use of the import that brings it into the build: the edge is its only
    reason to be compiled."""
    if path not in _extend_cache:
        try:
            _extend_cache[path] = bool(EXTEND_BLOCK.search(Path(path).read_text()))
        except OSError:
            _extend_cache[path] = False
    return _extend_cache[path]


def reachable(entries, edges, dropped):
    seen = set()
    work = list(entries)
    while work:
        f = work.pop()
        if f in seen:
            continue
        seen.add(f)
        for line, t in edges.get(f, ()):
            if (f, line) in dropped:
                continue
            work.append(t)
    return seen


def parse_imports(lines, src=None):
    """The file's imports, and whether they form one block with nothing but
    comments and blank lines between them (only then are they reordered)."""
    imps = []
    i = 0
    while i < len(lines):
        s = lines[i].rstrip("\n")
        if s.startswith("ffi") and " import " in s and FFI_IMPORT.match(s):
            imps.append(Import(i + 1, s, None, True))
            i += 1
            continue
        if IMPORT_HEAD.match(s):
            # A braced list written one item per line: read up to its `}`.
            j = i
            if "{" in s and "}" not in s:
                while j + 1 < len(lines) and "}" not in lines[j]:
                    j += 1
                if "}" not in lines[j]:
                    return None, False, f"line {i + 1}: unterminated import list"
            raw = [l.rstrip("\n") for l in lines[i:j + 1]]
            flat = raw[0] + "".join(" " + r.strip() for r in raw[1:])
            flat = re.sub(r'\{\s+', '{', re.sub(r'\s+\}', '}', flat))
            m = KAIRO_IMPORT.match(flat)
            if not m:
                return None, False, f"line {i + 1}: import not understood: {flat.strip()}"
            imps.append(Import(i + 1, "\n".join(raw), m, False, end=j + 1, src=src))
            i = j + 1
            continue
        i += 1
    if not imps:
        return imps, False, None
    first, last = imps[0].lineno, imps[-1].end
    at = set()
    for im in imps:
        at.update(range(im.lineno, im.end + 1))
    clean = True
    for ln in range(first, last + 1):
        if ln in at:
            continue
        s = lines[ln - 1].strip()
        if s and not s.startswith("//"):
            clean = False
            break
    # Comment lines directly above an import (no blank between) travel with it.
    if clean:
        for im in imps:
            ln = im.lineno - 1
            while ln >= first and ln not in at and lines[ln - 1].strip().startswith("//"):
                im.lead.insert(0, lines[ln - 1].rstrip("\n"))
                ln -= 1
    return imps, clean, None


class Plan:
    def __init__(self, path):
        self.path = path
        self.problems = []
        self.wildcards = 0
        self.selective = []      # (import, names)
        self.module = []         # (import, names, qualifier)
        self.dead = []           # imports to remove
        self.dead_reported = []  # dead but kept (re-export / reachability / ffi)
        self.misordered = False
        self.kept_wild = []      # (import, why)
        self.site_edits = {}     # offset -> (name, insert)
        self.skip = None
        self.restyle = False


def plan_file(path, fu, args, keep_line):
    pl = Plan(path)
    text = Path(path).read_text()
    # A generated file is rewritten by its generator on the next build; fix
    # the generator instead.
    if GENERATED.search(text[:2000]):
        pl.skip = "generated file (fix its generator)"
        return pl, text
    lines = text.splitlines(keepends=True)
    imps, clean, err = parse_imports(lines, path)
    if err:
        pl.skip = err
        return pl, text
    uncovered = bool(UNCOVERED_BRANCH.search(text))
    import_lines = set()
    for im in imps:
        import_lines.update(range(im.lineno, im.end + 1))
    # Identifiers anywhere outside the import lines: a module qualifier must
    # not be one of them, or `B::` would land on a name the file already uses.
    idents = set()
    for i, l in enumerate(lines):
        if (i + 1) not in import_lines:
            idents.update(IDENT.findall(l))

    by_line = defaultdict(list)
    for name, e in fu.names.items():
        for ln in e["origins"]:
            by_line[ln].append(name)

    taken_quals = set()
    for im in imps:
        if im.ffi:
            continue
        if im.wildcard:
            pl.wildcards += 1
        if im.lineno not in fu.lines:
            pl.problems.append(f"line {im.lineno}: no dump saw this import (left as written)")
            continue
        if fu.anchors.get(im.lineno, im.anchor) != im.anchor:
            pl.problems.append(f"line {im.lineno}: the dump saw this import anchored "
                               f"'{fu.anchors[im.lineno]}', the source says '{im.anchor}' (left as written)")
            pl.skip = "dump and source disagree on an import anchor (file changed since the dump?)"
            return pl, text
        names = sorted(set(by_line.get(im.lineno, [])))
        if not names:
            if im.reexport:
                pl.dead_reported.append((im, "pub/prot re-export: unused here, downstream unknown"))
            elif uncovered:
                pl.dead_reported.append((im, "file has branches no dump compiled"))
            elif fu.lines[im.lineno][0] and holds_extend(fu.lines[im.lineno][0]):
                pl.dead_reported.append((im, "its file holds extend blocks: no name is looked up through it, "
                                             "but the edge is what compiles it"))
            elif (path, im.lineno) in keep_line:
                pl.dead_reported.append((im, "only edge keeping its target file in the build"))
            else:
                pl.dead.append(im)
            continue
        if not im.wildcard:
            continue
        if uncovered:
            pl.kept_wild.append((im, "file has branches no dump compiled"))
            continue
        if im.reexport:
            pl.kept_wild.append((im, "pub/prot re-export: narrowing it changes the file's surface"))
            continue
        qual = im.path.split("::")[-1]
        spelled = all(fu.names[n]["unspelled"] == 0 for n in names)
        if len(names) > args.max_selective and spelled and qual not in idents and qual not in taken_quals \
                and qual not in names:
            taken_quals.add(qual)
            pl.module.append((im, names, qual))
            for n in names:
                for off in fu.names[n]["sites"]:
                    pl.site_edits[off] = (n, qual + "::")
        else:
            pl.selective.append((im, names))
    order_ok = True
    if imps:
        ffi_seen_kairo = False
        prev = None
        for im in imps:
            if im.ffi:
                if ffi_seen_kairo:
                    order_ok = False
            else:
                ffi_seen_kairo = True
                if prev is not None and im.sort_key() < prev:
                    order_ok = False
                prev = im.sort_key()
    pl.misordered = not order_ok
    pl.restyle = any((not im.ffi) and im.render() != im.text for im in imps)
    pl.clean = clean
    pl.imps = imps
    return pl, text


def apply(pl, text):
    """The new text, or None when the file no longer matches the dump."""
    b = text.encode()
    for off in sorted(pl.site_edits, reverse=True):
        name, ins = pl.site_edits[off]
        nb = name.encode()
        if b[off:off + len(nb)] != nb:
            pl.skip = f"use of '{name}' at byte {off} not found (file changed since the dump?)"
            return None
        before = b[off - 1:off].decode(errors="replace") if off > 0 else ""
        after = b[off + len(nb):off + len(nb) + 1].decode(errors="replace")
        if before in (":", ".", "@") or (before and ident_char(before)) or (after and ident_char(after)):
            pl.skip = f"use of '{name}' at byte {off} is not a bare name head"
            return None
        b = b[:off] + ins.encode() + b[off:]
    text = b.decode()
    lines = text.splitlines(keepends=True)
    imps = pl.imps
    new_tail = {}
    for im, names in pl.selective:
        new_tail[im.lineno] = "::{" + ", ".join(names) + "}"
    for im, names, qual in pl.module:
        new_tail[im.lineno] = ""
    dead = {im.lineno for im in pl.dead}
    for im in imps:
        if im.written(lines) != im.text:
            pl.skip = f"line {im.lineno} changed since it was read"
            return None
    nl = "\n"
    if pl.clean and imps:
        first = min([im.lineno for im in imps] + [im.lineno - len(im.lead) for im in imps])
        last = imps[-1].end
        ffi = [im for im in imps if im.ffi]
        kai = sorted((im for im in imps if (not im.ffi) and im.lineno not in dead), key=lambda im: im.sort_key())
        block = []
        for im in ffi:
            block += im.lead + [im.render()]
        if ffi and kai:
            block.append("")
        for im in kai:
            block += im.lead + im.render(new_tail.get(im.lineno)).split(nl)
        # Lead comments of a removed import are removed with it.
        out = lines[:first - 1] + [l + nl for l in block] + lines[last:]
        return "".join(out)
    # Not one clean block: edit in place, never move.
    return restyle_in_place(lines, imps, dead, new_tail)


def restyle_in_place(lines, imps, dead=frozenset(), new_tail=None):
    """Every Kairo import rewritten where it stands (style, new tails), the
    dead ones dropped; nothing moves."""
    new_tail = new_tail or {}
    by_line = {im.lineno: im for im in imps}
    out = []
    ln = 1
    while ln <= len(lines):
        im = by_line.get(ln)
        if im is None:
            out.append(lines[ln - 1])
            ln += 1
            continue
        if ln not in dead:
            if im.ffi:
                out.extend(lines[ln - 1:im.end])
            else:
                out.append(im.render(new_tail.get(ln)) + "\n")
        ln = im.end + 1
    return "".join(out)


def format_file(path):
    """--format-only: the file restyled, or None when its imports are not understood."""
    text = Path(path).read_text()
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    imps, _, err = parse_imports(lines, path)
    if err:
        return None, err
    new = restyle_in_place(lines, imps)
    if not text.endswith("\n"):
        new = new[:-1]
    return new, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="files or directories whose .k files may be reported / edited")
    ap.add_argument("--dump", action="append", default=[], help="a --dump-import-uses JSON (repeatable; required unless --format-only)")
    ap.add_argument("--fix", action="store_true", help="rewrite the files")
    ap.add_argument("--format-only", action="store_true",
                    help="only restyle the import lines (see Style above); no dump, nothing removed or reordered")
    ap.add_argument("--max-selective", type=int, default=12,
                    help="above this many names, a wildcard becomes a module import with qualified uses (default 12)")
    ap.add_argument("-v", "--verbose", action="store_true", help="per-file detail")
    a = ap.parse_args()

    roots = [Path(p).resolve() for p in a.paths]
    for r in roots:
        for f in FORBIDDEN:
            if r == f or f in r.parents or r in f.parents:
                sys.exit(f"import_lint: refusing {r}: {f.relative_to(ROOT)}/ is never edited")
    if a.format_only:
        return format_only(roots)
    if not a.dump:
        ap.error("--dump is required (or pass --format-only)")
    files, edges, entries = load_dumps(a.dump)

    targets = []
    for r in roots:
        cand = [r] if r.is_file() else sorted(r.rglob("*.k"))
        for f in cand:
            if any(x == f or x in f.parents for x in FORBIDDEN):
                continue
            targets.append(str(f))

    # Dead-import removal must not orphan a file: plan every removal, then put
    # back the edges into any file that stops being reachable from an entry.
    plans = {}
    keep_line = set()
    while True:
        plans = {}
        for f in targets:
            if f not in files:
                continue
            pl, text = plan_file(f, files[f], a, keep_line)
            plans[f] = (pl, text)
        dropped = set()
        for f, (pl, _) in plans.items():
            for im in pl.dead:
                dropped.add((f, im.lineno))
        before = reachable(entries, edges, set())
        after = reachable(entries, edges, dropped)
        lost = before - after
        if not lost:
            break
        grew = False
        for f, line in dropped:
            for l2, t in edges.get(f, ()):
                if l2 == line and t in lost and (f, line) not in keep_line:
                    keep_line.add((f, line))
                    grew = True
        if not grew:
            # A file lost through a chain no single edge explains: keep every
            # edge this round would have dropped. Conservative, and it ends the
            # loop (keep_line only grows, so each round removes fewer edges).
            keep_line |= dropped

    tot = defaultdict(int)
    unseen = [f for f in targets if f not in files]
    for f in sorted(plans):
        pl, text = plans[f]
        rel = Path(f).relative_to(ROOT) if ROOT in Path(f).parents else f
        if pl.skip:
            print(f"{rel}: SKIPPED: {pl.skip}")
            tot["skipped"] += 1
            continue
        tot["wild_before"] += pl.wildcards
        tot["selective"] += len(pl.selective)
        tot["module"] += len(pl.module)
        tot["sites"] += len(pl.site_edits)
        tot["dead"] += len(pl.dead)
        tot["dead_reported"] += len(pl.dead_reported)
        tot["kept_wild"] += len(pl.kept_wild)
        tot["misordered"] += int(pl.misordered)
        changes = pl.selective or pl.module or pl.dead or pl.misordered or pl.restyle
        if a.verbose or (not a.fix):
            for im, names in pl.selective:
                print(f"{rel}:{im.lineno}: wildcard '{im.path}::*' -> {{{', '.join(names)}}}")
            for im, names, q in pl.module:
                print(f"{rel}:{im.lineno}: wildcard '{im.path}::*' -> module import, {len(names)} names qualified as {q}::")
            for im in pl.dead:
                print(f"{rel}:{im.lineno}: dead import '{im.text.strip()}'")
            if pl.misordered:
                print(f"{rel}: imports misordered" + ("" if pl.clean else " (not one block: left in place)"))
        for im, why in pl.dead_reported:
            print(f"{rel}:{im.lineno}: unused import kept: '{im.text.strip()}' ({why})")
        for im, why in pl.kept_wild:
            print(f"{rel}:{im.lineno}: wildcard kept: '{im.text.strip()}' ({why})")
        for p in pl.problems:
            print(f"{rel}: {p}")
        if a.fix and changes:
            # Re-read now: another tool may have written the file since it was planned.
            cur = Path(f).read_text()
            if cur != text:
                print(f"{rel}: SKIPPED: changed while planning; rerun")
                tot["skipped"] += 1
                continue
            new = apply(pl, cur)
            if new is None:
                print(f"{rel}: SKIPPED: {pl.skip}")
                tot["skipped"] += 1
                continue
            if new != cur:
                Path(f).write_text(new)
                tot["written"] += 1
    for f in unseen:
        print(f"{Path(f).relative_to(ROOT) if ROOT in Path(f).parents else f}: no dump reached this file (left as written)")
    print(f"import_lint: {len(plans)} files; wildcards {tot['wild_before']}: {tot['selective']} -> selective, "
          f"{tot['module']} -> module + {tot['sites']} qualified sites, {tot['kept_wild']} kept; "
          f"dead {tot['dead']} removable + {tot['dead_reported']} reported; misordered {tot['misordered']}; "
          f"skipped {tot['skipped']}; unreached {len(unseen)}" + (f"; written {tot['written']}" if a.fix else ""))
    return 0


def format_only(roots):
    n = changed = 0
    for r in roots:
        for f in ([r] if r.is_file() else sorted(r.rglob("*.k"))):
            if any(x == f or x in f.parents for x in FORBIDDEN):
                continue
            text = f.read_text()
            if GENERATED.search(text[:2000]):
                continue
            n += 1
            new, err = format_file(f)
            if err:
                print(f"{f}: SKIPPED: {err}")
                continue
            if new != text:
                f.write_text(new)
                changed += 1
    print(f"import_lint --format-only: {n} files, {changed} rewritten")
    return 0


if __name__ == "__main__":
    sys.exit(main())
