#!/usr/bin/env python3
"""
gen_checks.py - generate FileCheck blocks for a Kairo lit test from the
compiler's own output, and keep them regenerable.

Usage:
    gen_checks.py --mode=diag,sema Tests/Sema/Check/foo.k      # add / replace
    gen_checks.py Tests/Sema/Check/foo.k Tests/Codegen/**/*.k   # regenerate
    gen_checks.py --check Tests/Codegen/witness/*.k             # diff only

A file carries any number of generated blocks, one per check prefix:

    // BEGIN-GENERATED-CHECKS(SEMA) mode=sema sections=name-bindings
    // RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | ...
    // SEMA: ...
    // END-GENERATED-CHECKS(SEMA)

The BEGIN line records the options the block was made with, so running the
script on the file with no --mode regenerates every block exactly as it was
asked for. Hand-written RUN/CHECK lines outside the blocks are never touched.

Modes (--mode, comma-separated; each gets its own block and prefix):

  ast      --print-ast=tree, plus the diagnostics that follow it
           (--hoisted-scope adds the global scope dump).          AST
  diag     every diagnostic, note and fix-it, in emission order, with
           --implicit-check-not on "error [" / "warning [" so a NEW
           diagnostic fails the test. No diagnostics = a must-stay-clean
           test (--allow-empty).                                     DIAG
  sema     --print-sema, the test file's own TU only, the sections
           named by --sections.                                      SEMA
  lowered  --print-lowered, same shape as sema.                      LOWERED
  cxx      --print-ir, the test file's own C++ only, with the runtime
           boilerplate every TU shares dropped; --focus narrows it to
           the top-level declarations naming the given identifiers.  CXX
  run      compile, link and run; asserts the exit code and stdout. EXEC

Shared options: --through=check|obj|link picks how far the compile goes
(type-check only, objects, or a linked executable); --kairo-args adds
compiler flags (e.g. --target=...) to the generated RUN line.

How the output is obtained. Every compile goes THROUGH LIT: the script writes
a throwaway probe test beside the target (same directory, so the same
lit.local.cfg applies) whose RUN lines are the generated ones with the
FileCheck stage replaced by a redirect, and runs llvm-lit on it. %kairo,
%t and every other substitution therefore expand exactly as they will when
the suite runs the test -- the checks can't describe a configuration the
suite never uses. (The previous version invoked kairo directly without lit's
--builtins-dir/--std-dir/--resource-dir, and even the AST dump differs.)
The file is compiled IN PLACE, never as a temp copy: imports from Inputs/
resolve, and the C++ namespace -- which is the file's stem -- is the real one.

Every probe runs each command twice; output that differs between the two
runs (iteration order, addresses, a race) is refused, with the diff, instead
of being frozen into a check that passes half the time.

After writing, the script runs lit on each file it changed and fails if the
test does not pass. --no-lit skips that; --check writes nothing and prints
the diff a regeneration would make (exit 1 if any).

Normalization, all mechanical, none of it guessing what is "stable":
  - The test file's absolute path becomes {{.*}}; a diagnostic in another
    file keeps that file's name ({{.*}}/foo.k).
  - In cxx output the module namespace (the file's stem) becomes a glob, so
    renaming the test does not break it; --literal-namespace keeps it.
  - Literal {{ and [[ in compiler output are escaped the way FileCheck
    documents ({{\\{\\{}} / {{\\[\\[}}), so C++ attributes and nested braced
    initializers are checkable.
  - Blank lines become PREFIX-EMPTY.

Placement: an existing block is replaced where it stands. A new block goes
at the bottom of the file, under the `// --- lit wiring ---` rule (added if
the file has none), so the code's line:col positions -- which sema dumps and
diagnostics hardcode -- never move. Blocks written by the old version of this
script (unkeyed `BEGIN-GENERATED-CHECKS (gen_checks.py)` markers) are read,
their options inferred from their content, and rewritten in the new form.

The old invocation, `gen_checks.py <kairo> <source.k>`, still works and means
`--kairo=<kairo> --mode=ast <source.k>`. `// SEPARATE:` segments are gone:
their RUN line compiled the whole file while the checks came from one
segment, so a segmented block never described what lit ran.
"""
import argparse
import concurrent.futures
import difflib
import glob
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field, replace
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent

MODES = ("ast", "diag", "sema", "lowered", "cxx", "run")
DEFAULT_PREFIX = {
    "ast": "AST", "diag": "DIAG", "sema": "SEMA", "lowered": "LOWERED",
    "cxx": "CXX", "run": "EXEC",
}
# How far each mode compiles unless --through says otherwise. cxx needs
# codegen (--type-check-only prints no C++), run needs an executable. -c, not
# a bare compile: without -o a full compile links ./a.out into the test's
# directory, which is how Tests/Codegen/a.out got there.
DEFAULT_THROUGH = {
    "ast": "check", "diag": "check", "sema": "check", "lowered": "check",
    "cxx": "obj", "run": "link",
}
THROUGHS = ("check", "obj", "link")

# The sema/lowered dump's sections, keyed by their header with the
# parenthetical dropped and spaces as dashes. Lang items are left out by
# default: they are the builtin module's bindings, not the test's.
SEMA_DEFAULT_SECTIONS = [
    "scope-symbol-tables", "name-bindings", "expression-types",
    "inferred-decls", "interface-composition",
]

WIRING_RULE = "// --- lit wiring -----------------------------------------------------------"
BEGIN_RE = re.compile(r"^// BEGIN-GENERATED-CHECKS\(([A-Za-z][A-Za-z0-9_-]*)\)(.*)$")
END_FMT = "// END-GENERATED-CHECKS({})"
LEGACY_BEGIN = "// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead"
LEGACY_END = "// END-GENERATED-CHECKS"
BEGIN_TAIL = " -- regenerate with Tests/gen_checks.py, do not hand-edit"

# path:line:col: kind [CODE]: message   (--error-format=basic)
DIAG_RE = re.compile(r"^(.*?):(\d+):(\d+): (error|warning|note|remark|fatal error) \[(\w+)\]: (.*)$")
FIXIT_RE = re.compile(r'^fix-it:"(.*?)":(\{.*)$')
AST_HEADER_RE = re.compile(r"^============== AST \(tree\) for fid (\d+) ==============$")
STATS_RE = re.compile(r"^-- (\d+) error\(s\), (\d+) warning\(s\) --$")
HOISTED_HEADER_RE = re.compile(r"^-- hoisted scope: (.+) --$")
END_GLOBAL_RE = re.compile(r"^=== End GlobalHoistedScope ===$")
SEMA_TU_RE = re.compile(r"^===== SEMA fid (\d+): (.*) =====$")
SEMA_TOP_RE = re.compile(r"^-- (sema|lowered): .* --$")
SEMA_SECTION_RE = re.compile(r"^-- (.+?) --$")
CXX_HEADER_RE = re.compile(r"^// =+ CODEGEN C\+\+: (.*) =+$")
CXX_END_RE = re.compile(r"^// =+$")
DIRECTIVE_SUFFIX = r"(?:-NEXT|-SAME|-NOT|-DAG|-LABEL|-EMPTY|-COUNT-\d+)?"


class GenError(Exception):
    pass


def warn(msg):
    print(f"gen_checks.py: warning: {msg}", file=sys.stderr)


# --- Options carried by one block ---------------------------------------------

@dataclass
class BlockOpts:
    mode: str
    prefix: str
    through: str = ""
    kargs: list = field(default_factory=list)
    sections: list = field(default_factory=list)  # sema / lowered
    focus: list = field(default_factory=list)  # cxx
    literal_ns: bool = False  # cxx
    stdout: bool = True  # run
    hoisted: bool = False  # ast
    loose_position: bool = False  # ast / diag
    loose_message: bool = False  # ast / diag

    def normalized(self):
        o = replace(self)
        if not o.through:
            o.through = DEFAULT_THROUGH[o.mode]
        if o.mode in ("sema", "lowered") and not o.sections:
            o.sections = list(SEMA_DEFAULT_SECTIONS)
        if o.mode == "cxx" and o.through == "check":
            raise GenError("--mode=cxx needs --through=obj or link: a type-check-only run prints no C++")
        if o.mode == "run" and o.through != "link":
            raise GenError("--mode=run needs --through=link")
        return o

    def encode(self):
        """The BEGIN line's record: only what differs from the mode's default,
        so a block made with plain `--mode=sema` says just `mode=sema`."""
        o = self.normalized()
        parts = [f"mode={o.mode}"]
        if o.through != DEFAULT_THROUGH[o.mode]:
            parts.append(f"through={o.through}")
        if o.kargs:
            parts.append("args=" + shlex.quote(shlex.join(o.kargs)))
        if o.mode in ("sema", "lowered") and o.sections != SEMA_DEFAULT_SECTIONS:
            parts.append("sections=" + ",".join(o.sections))
        if o.focus:
            parts.append("focus=" + ",".join(o.focus))
        if o.literal_ns:
            parts.append("literal-namespace")
        if o.mode == "run" and not o.stdout:
            parts.append("no-stdout")
        if o.mode == "ast" and o.hoisted:
            parts.append("hoisted-scope")
        if o.loose_position:
            parts.append("loose-position")
        if o.loose_message:
            parts.append("loose-message")
        return " ".join(parts)

    @staticmethod
    def decode(prefix, text):
        try:
            words = shlex.split(text)
        except ValueError as e:
            raise GenError(f"cannot parse the options on BEGIN-GENERATED-CHECKS({prefix}): {e}")
        kv = {}
        for w in words:
            k, _, v = w.partition("=")
            kv[k] = v
        mode = kv.get("mode", "")
        if mode not in MODES:
            raise GenError(f"BEGIN-GENERATED-CHECKS({prefix}) names no known mode (got {mode!r})")
        return BlockOpts(
            mode=mode, prefix=prefix,
            through=kv.get("through", ""),
            kargs=shlex.split(kv["args"]) if "args" in kv else [],
            sections=[s for s in kv.get("sections", "").split(",") if s],
            focus=[s for s in kv.get("focus", "").split(",") if s],
            literal_ns="literal-namespace" in kv,
            stdout="no-stdout" not in kv,
            hoisted="hoisted-scope" in kv,
            loose_position="loose-position" in kv,
            loose_message="loose-message" in kv,
        )


# --- Reading the blocks already in a file ---------------------------------------

@dataclass
class Block:
    opts: BlockOpts
    start: int  # line index of BEGIN
    end: int  # line index of END (inclusive)


def infer_legacy_opts(body):
    """A block from the old script recorded nothing; read its options back
    out of what it generated. Looseness is inferred per block so that a block
    someone loosened by hand stays loose instead of silently tightening."""
    prefix = "CHECK"
    for line in body:
        m = re.search(r"--check-prefix=([A-Za-z0-9_-]+)", line)
        if line.startswith("// RUN:") and m:
            prefix = m.group(1)
            break
    diag_checks = [l for l in body if re.search(r"\b(error|warning|note|remark) \[\w+\]", l)
                   and not l.startswith("// RUN:")]
    # A block that asserted NO diagnostics predates the errors it now gets;
    # they are news to the test (often a parser test whose code Sema now
    # rejects), not something it meant to pin. Assert only their codes, so
    # rewording a Sema message does not fail a parser test.
    silent = not diag_checks
    return BlockOpts(
        mode="ast", prefix=prefix,
        hoisted=any("hoisted scope:" in l for l in body),
        loose_position=silent or any(not re.search(r":\d+:\d+: ", l) for l in diag_checks),
        loose_message=silent or any(re.search(r"\]:\s*$", l) for l in diag_checks),
    )


def find_blocks(lines, path):
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = BEGIN_RE.match(line)
        if m:
            prefix = m.group(1)
            rest = m.group(2)
            rest = rest.split(" -- ", 1)[0]
            end_line = END_FMT.format(prefix)
            j = next((k for k in range(i + 1, len(lines)) if lines[k] == end_line), None)
            if j is None:
                raise GenError(f"{path}:{i + 1}: BEGIN-GENERATED-CHECKS({prefix}) has no `{end_line}`")
            blocks.append(Block(BlockOpts.decode(prefix, rest), i, j))
            i = j + 1
            continue
        if line == LEGACY_BEGIN:
            j = next((k for k in range(i + 1, len(lines)) if lines[k] == LEGACY_END), None)
            if j is None:
                raise GenError(f"{path}:{i + 1}: legacy BEGIN-GENERATED-CHECKS has no END marker")
            blocks.append(Block(infer_legacy_opts(lines[i + 1:j]), i, j))
            i = j + 1
            continue
        i += 1
    seen = set()
    for b in blocks:
        if b.opts.prefix in seen:
            raise GenError(f"{path}: two generated blocks use the prefix {b.opts.prefix}; give one --prefix")
        seen.add(b.opts.prefix)
    return blocks


# --- FileCheck text ---------------------------------------------------------------

def escape_filecheck(text):
    """FileCheck reads {{ and [[ as the start of a regex / variable even on a
    literal line. Wrap each in a regex that matches it literally. Must run on
    raw compiler text, before this script inserts its own {{.*}} globs."""
    out = []
    i = 0
    while i < len(text):
        two = text[i:i + 2]
        if two == "{{":
            out.append(r"{{\{\{}}")
            i += 2
        elif two == "[[":
            out.append(r"{{\[\[}}")
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


class Checks:
    """Accumulates `// PREFIX[-NEXT]: text` lines. `chain` says the line must
    directly follow the previous match; a blank chained line is -EMPTY."""

    def __init__(self, prefix):
        self.prefix = prefix
        self.lines = []

    def add(self, text, chain=False):
        if chain and not text.strip():
            self.lines.append(f"// {self.prefix}-EMPTY:")
        elif chain:
            self.lines.append(f"// {self.prefix}-NEXT: {text}")
        else:
            if not text.strip():
                raise GenError("internal: an unchained blank check line")
            self.lines.append(f"// {self.prefix}: {text}")


class Norm:
    """Path globbing for one test file. Applied after escape_filecheck."""

    def __init__(self, real_path):
        self.real = str(real_path)
        self.root = str(REPO_ROOT)

    def line(self, raw):
        s = escape_filecheck(raw)
        s = s.replace(self.real, "{{.*}}")
        return s

    def tail(self, path):
        """`{{.*}}parent/name.k`: enough of a path to pick the test's own TU
        out of a dump that also holds the builtin module's files."""
        p = Path(path)
        return "{{.*}}" + escape_filecheck(f"{p.parent.name}/{p.name}")

    def diag_path(self, path):
        if path == self.real:
            return "{{.*}}"
        return "{{.*}}/" + escape_filecheck(Path(path).name)


# --- Command lines --------------------------------------------------------------

def tmp(o, suffix):
    return f"%t.{o.prefix.lower()}.{suffix}"


def stage_flags(o):
    if o.through == "check":
        return ["--type-check-only"]
    if o.through == "obj":
        return ["-c", "--cache-dir", tmp(o, "d")]
    return ["-o", tmp(o, "exe"), "--cache-dir", tmp(o, "d")]


def kairo_cmd(o, src, extra):
    words = ["%kairo", src] + [shlex.quote(a) for a in o.kargs] + stage_flags(o) + extra
    return " ".join(words)


DUMP_FLAG = {"ast": ["--print-ast=tree"], "sema": ["--print-sema"],
             "lowered": ["--print-lowered"], "cxx": ["--print-ir"], "diag": []}
# Where stderr goes in a dump RUN line. ast keeps the diagnostics (they are
# part of what it checks); the other dumps drop them, so a diagnostic line
# can never land in the middle of a dump section -- diagnostics are what
# --mode=diag is for.
STDERR = {"ast": "2>&1", "diag": "2>&1", "sema": "2>/dev/null",
          "lowered": "2>/dev/null", "cxx": "2>/dev/null"}


def pipeline(o, src):
    return f"{{ {kairo_cmd(o, src, DUMP_FLAG[o.mode])} {STDERR[o.mode]} || true; }}"


def filecheck_flags(o, empty):
    flags = []
    if o.prefix != "CHECK":
        flags.append(f"--check-prefix={o.prefix}")
    if o.mode == "diag":
        if empty:
            flags.append("--allow-empty")
        else:
            flags += ['--implicit-check-not="error ["', '--implicit-check-not="warning ["']
    return (" " + " ".join(flags)) if flags else ""


# --- Probe: run the commands through lit ------------------------------------------

@dataclass
class Env:
    kairo: str
    lit: str
    lit_params: list


def run_probe(env, test_path, opts_list, outdir):
    """One probe test beside `test_path`, running each block's command twice
    into files under `outdir`. Returns nothing; the outputs are on disk."""
    src = shlex.quote(str(test_path))
    lines = []
    for n, o in enumerate(opts_list):
        base = os.path.join(outdir, f"job{n}")
        for r in ("a", "b"):
            out = shlex.quote(f"{base}.{r}")
            if o.through != "check":
                lines.append(f"rm -rf {tmp(o, 'd')}")
            if o.mode == "run":
                build = shlex.quote(f"{base}.build")
                lines.append(f"{kairo_cmd(o, src, [])} > {build} 2>&1 || echo $? > {build}.fail")
                lines.append(f"{{ {tmp(o, 'exe')} > {out} 2>/dev/null; echo $? > {out}.code; }}")
            else:
                lines.append(f"{pipeline(o, src)} > {out}")
    probe = test_path.parent / f"__gen_checks_probe_{os.getpid()}_{abs(hash(str(test_path))) % 10**8}.k"
    probe.write_text("".join(f"// RUN: {l}\n" for l in lines))
    try:
        cmd = [env.lit, "-v", "--skip-test-time-recording", str(probe)] + [f"--param={p}" for p in env.lit_params]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           env=dict(os.environ, KAIRO_BIN=env.kairo))
    finally:
        probe.unlink(missing_ok=True)
    if r.returncode != 0 or "PASS:" not in r.stdout:
        raise GenError(f"the lit probe for {test_path} did not run cleanly:\n{r.stdout}")


# --- Builders: compiler output -> check lines ---------------------------------------

def read(path):
    try:
        return Path(path).read_text(errors="replace")
    except FileNotFoundError:
        raise GenError(f"probe produced no {path}")


def build_ast(o, text, norm):
    lines = text.splitlines()
    c = Checks(o.prefix)
    i = 0
    n = len(lines)
    while i < n and not AST_HEADER_RE.match(lines[i]):
        i += 1
    if i >= n:
        raise GenError("no '== AST (tree) for fid N ==' header in kairo's output:\n" + text)
    c.add(norm.line(lines[i]))
    i += 1
    while i < n and not STATS_RE.match(lines[i]):
        c.add(norm.line(lines[i]), chain=True)
        i += 1
    if i >= n:
        raise GenError("no '-- N error(s), M warning(s) --' line in kairo's output")
    # Not chained to the tree: spacing between the two may change.
    c.add(norm.line(lines[i]))
    i += 1
    if i < n and HOISTED_HEADER_RE.match(lines[i]):
        first = True
        while i < n:
            is_end = END_GLOBAL_RE.match(lines[i]) is not None
            if o.hoisted:
                c.add(norm.line(lines[i]), chain=not first)
            first = False
            i += 1
            if is_end:
                break
    diag = diag_checks(o, lines[i:], norm, chain_attached=False)
    if diag:
        c.lines += ["//", "// -- diagnostics (order matches emission order) --"] + diag
    return c.lines


def diag_checks(o, lines, norm, chain_attached=True):
    """One check per diagnostic, in emission order -- the order cascading
    recovery emits them in is part of the behavior. With `chain_attached`,
    notes and fix-its are chained to the line before them, so a note that
    detaches from its error fails the test."""
    c = Checks(o.prefix)
    prev_matched = False
    for raw in lines:
        m = DIAG_RE.match(raw)
        f = FIXIT_RE.match(raw)
        if m:
            path, line_no, col_no, kind, code, msg = m.groups()
            pos = "{{[0-9]+}}:{{[0-9]+}}" if o.loose_position else f"{line_no}:{col_no}"
            text = f"{norm.diag_path(path)}:{pos}: {kind} [{code}]:"
            if not o.loose_message:
                text += " " + norm.line(msg)
            attached = kind in ("note", "remark")
            c.add(text, chain=chain_attached and attached and prev_matched)
            prev_matched = True
        elif f and not o.loose_message:
            text = f'fix-it:"{norm.diag_path(f.group(1))}":{norm.line(f.group(2))}'
            c.add(text, chain=chain_attached and prev_matched)
            prev_matched = True
        elif f:
            prev_matched = True
        else:
            prev_matched = False
    return c.lines


def build_diag(o, text, norm):
    lines = text.splitlines()
    if any("internal compiler error" in l.lower() for l in lines):
        warn("kairo reported an internal compiler error; the generated block freezes it in")
    checks = diag_checks(o, lines, norm)
    if not checks:
        # FileCheck rejects a prefix with no check strings even under
        # --allow-empty; the NOT lines are the must-stay-clean assertion.
        checks = [f"// {o.prefix}-NOT: error [", f"// {o.prefix}-NOT: warning ["]
    return checks


def section_slug(title):
    return re.sub(r"\s+", "-", re.sub(r"\s*\(.*?\)\s*", "", title).strip()).lower()


def build_sema(o, text, norm):
    lines = text.splitlines()
    start = next((k for k, l in enumerate(lines)
                  if (m := SEMA_TU_RE.match(l)) and m.group(2) == norm.real), None)
    if start is None:
        raise GenError(f"no '===== SEMA fid N: {norm.real} =====' section in the --print-{o.mode} output")
    end = next((k for k in range(start + 1, len(lines))
                if SEMA_TU_RE.match(lines[k]) or SEMA_TOP_RE.match(lines[k])), len(lines))
    # Sections of this TU: (slug, header index, end index exclusive).
    heads = [k for k in range(start + 1, end) if SEMA_SECTION_RE.match(lines[k])]
    sections = []
    for idx, h in enumerate(heads):
        stop = heads[idx + 1] if idx + 1 < len(heads) else end
        sections.append((section_slug(SEMA_SECTION_RE.match(lines[h]).group(1)), h, stop))
    present = {s[0] for s in sections}
    want = ["*"] if o.sections == ["all"] else o.sections
    for s in want:
        if s != "*" and s not in present:
            warn(f"--sections names {s!r}, which this dump has no section for "
                 f"(it has: {', '.join(s[0] for s in sections)})")
    c = Checks(o.prefix)
    m = SEMA_TU_RE.match(lines[start])
    c.add(f"===== SEMA fid {{{{[0-9]+}}}}: {norm.tail(m.group(2))} =====")
    chained = False
    for slug, h, stop in sections:
        if want != ["*"] and slug not in want:
            if chained:
                # Pin where the previous section ENDS: without this, a row
                # appended to it would still pass.
                c.add(norm.line(lines[h]), chain=True)
            chained = False
            continue
        c.add(norm.line(lines[h]), chain=chained)
        for k in range(h + 1, stop):
            c.add(norm.line(lines[k]), chain=True)
        chained = True
    if chained and end < len(lines):
        nxt = lines[end]
        if SEMA_TU_RE.match(nxt):
            c.add("===== SEMA fid {{[0-9]+}}: {{.*}} =====", chain=True)
        else:
            c.add(norm.line(nxt), chain=True)
    return c.lines


def split_cxx_items(lines):
    """Top-level C++ declarations, as (start, end) line ranges. An item ends
    when bracket depth is back to zero on a line ending in `;` or `}` (or a
    preprocessor line); a `template<...>` alone on a line joins what follows.
    String and character literals are skipped so a brace inside one does not
    count."""
    items = []
    depth = 0
    start = None
    for k, line in enumerate(lines):
        if start is None:
            if not line.strip():
                items.append((k, k + 1))
                continue
            start = k
        i = 0
        while i < len(line):
            ch = line[i]
            if ch in "\"'":
                q = ch
                i += 1
                while i < len(line) and line[i] != q:
                    i += 2 if line[i] == "\\" else 1
            elif line.startswith("//", i):
                break
            elif ch in "{([":
                depth += 1
            elif ch in "})]":
                depth -= 1
            i += 1
        s = line.strip()
        if depth <= 0 and (s.endswith((";", "}")) or s.startswith(("#", "//"))):
            items.append((start, k + 1))
            start = None
            depth = 0
    if start is not None:
        items.append((start, len(lines)))
    return items


def cxx_sections(lines):
    out = {}
    k = 0
    while k < len(lines):
        m = CXX_HEADER_RE.match(lines[k])
        if not m:
            k += 1
            continue
        end = next((j for j in range(k + 1, len(lines)) if CXX_END_RE.match(lines[j])), len(lines))
        out[m.group(1)] = (k, end)
        k = end + 1
    return out


def build_cxx(o, text, norm, test_path):
    lines = text.splitlines()
    secs = cxx_sections(lines)
    if norm.real not in secs:
        raise GenError(f"no 'CODEGEN C++: {norm.real}' section in the --print-ir output")
    head, end = secs[norm.real]
    body = lines[head + 1:end]
    # Runtime boilerplate: any top-level item another TU in the same build
    # emits verbatim. Every TU carries the same helper templates; checking
    # them in every test would fail the whole suite over one helper edit.
    shared = set()
    for p, (h, e) in secs.items():
        if p == norm.real:
            continue
        other = lines[h + 1:e]
        for a, b in split_cxx_items(other):
            shared.add(tuple(l.strip() for l in other[a:b]))
    ns = re.sub(r"\W", "_", test_path.stem)
    glob_ns = not o.literal_ns and any(re.match(rf"^\s*namespace {re.escape(ns)}\b", l) for l in body)

    def norm_line(raw):
        s = norm.line(raw)
        if glob_ns:
            s = re.sub(rf"(?<![A-Za-z0-9_])namespace {re.escape(ns)}(?![A-Za-z0-9_])",
                       "namespace {{[A-Za-z0-9_]+}}", s)
            s = re.sub(rf"(?<![A-Za-z0-9_]){re.escape(ns)}::", "{{[A-Za-z0-9_]+}}::", s)
        return s

    focus_res = [re.compile(rf"(?<![A-Za-z0-9_]){re.escape(f)}(?![A-Za-z0-9_])") for f in o.focus]
    kept = []
    for a, b in split_cxx_items(body):
        chunk = body[a:b]
        if not any(l.strip() for l in chunk) or tuple(l.strip() for l in chunk) in shared:
            continue
        if focus_res and not any(r.search(l) for l in chunk for r in focus_res):
            continue
        kept.append(chunk)
    if focus_res and not kept:
        raise GenError(f"--focus={','.join(o.focus)} matches no top-level declaration in the C++")
    # Each declaration is exact inside (-NEXT), but declarations are only
    # ordered against each other: one the compiler adds between two checked
    # ones -- a new forward declaration, an instantiation -- does not fail
    # the test.
    c = Checks(o.prefix)
    c.add(escape_filecheck(lines[head]).replace(escape_filecheck(norm.real), norm.tail(norm.real)))
    for chunk in kept:
        for j, l in enumerate(chunk):
            c.add(norm_line(l), chain=j > 0)
    return c.lines


def build_run(o, base, norm):
    if os.path.exists(f"{base}.build.fail"):
        raise GenError("the compile for --mode=run failed:\n" + read(f"{base}.build"))
    code_a = read(f"{base}.a.code").strip()
    code_b = read(f"{base}.b.code").strip()
    if code_a != code_b:
        raise GenError(f"the executable exited {code_a} on one run and {code_b} on the other")
    out = read(f"{base}.a")
    return int(code_a), out


# --- Assembling one block -----------------------------------------------------------

def block_text(o, outdir, n, test_path, norm):
    base = os.path.join(outdir, f"job{n}")
    head = [f"// BEGIN-GENERATED-CHECKS({o.prefix}) {o.encode()}{BEGIN_TAIL}"]
    if o.through != "check":
        # The suite's convention for anything that goes past Sema: object
        # emission and linking go through clang, so a clang-less host reports
        # UNSUPPORTED rather than FAIL.
        head.append("// REQUIRES: clang")
        head.append(f"// RUN: rm -rf {tmp(o, 'd')}")

    if o.mode == "run":
        code, out = build_run(o, base, norm)
        if read(f"{base}.b") != out:
            raise GenError("the executable printed different output on two runs:\n" +
                           "".join(difflib.unified_diff(out.splitlines(True), read(f"{base}.b").splitlines(True))))
        run = [f"// RUN: {kairo_cmd(o, '%s', [])}",
               f"// RUN: {tmp(o, 'exe')} > {tmp(o, 'out')}; test $? -eq {code}"]
        checks = []
        if o.stdout and out.strip():
            run.append(f"// RUN: %FileCheck %s --check-prefix={o.prefix} --input-file={tmp(o, 'out')}")
            c = Checks(o.prefix)
            for l in out.strip("\n").splitlines():
                c.add(norm.line(l), chain=bool(c.lines))
            checks = c.lines
        elif o.stdout:
            run.append(f"// RUN: test ! -s {tmp(o, 'out')}")
        return head + run + checks + [END_FMT.format(o.prefix)]

    outs = []
    for r in ("a", "b"):
        text = read(f"{base}.{r}")
        if o.mode == "ast":
            outs.append(build_ast(o, text, norm))
        elif o.mode == "diag":
            outs.append(build_diag(o, text, norm))
        elif o.mode in ("sema", "lowered"):
            outs.append(build_sema(o, text, norm))
        else:
            outs.append(build_cxx(o, text, norm, test_path))
    if outs[0] != outs[1]:
        diff = "".join(difflib.unified_diff([l + "\n" for l in outs[0]], [l + "\n" for l in outs[1]],
                                            "run 1", "run 2"))
        raise GenError(f"--mode={o.mode} output differs between two identical runs; refusing to "
                       f"freeze a nondeterministic check:\n{diff}")
    checks = outs[0]
    empty = o.mode == "diag" and all("-NOT:" in l for l in checks)
    run = f"// RUN: {pipeline(o, '%s')} | %FileCheck %s{filecheck_flags(o, empty)}"
    return head + [run] + checks + [END_FMT.format(o.prefix)]


# --- Per file -------------------------------------------------------------------------

def lint_prose(numbered, prefixes, path):
    """The trap that has bitten this suite: a comment reading `... the AST:
    ...` is an AST check when a RUN line says --check-prefix=AST. Flag a
    prefix that appears mid-line rather than as the line's directive."""
    for k, line in numbered:
        stripped = line.lstrip()
        for p in prefixes:
            for m in re.finditer(rf"(?<![A-Za-z0-9_-]){re.escape(p)}{DIRECTIVE_SUFFIX}:", line):
                lead = stripped[2:].lstrip() if stripped.startswith("//") else stripped
                if line[m.start():].lstrip() != lead:
                    warn(f"{path}:{k + 1}: `{m.group(0)}` mid-line will be read as a {p} check")


def process_file(path, env, requested, args):
    path = path.resolve()
    original = path.read_text()
    lines = original.splitlines()
    if any(l.strip() == "// SEPARATE:" for l in lines):
        warn(f"{path}: `// SEPARATE:` segments are no longer supported; the file is checked as one "
             f"unit, as its RUN line always compiled it")
    if any(re.match(r"^//\s*XFAIL:", l) for l in lines) and not args.allow_xfail:
        # Checks regenerated from today's output turn "expected to fail" into
        # "passes" without anyone reading why the test is XFAIL. The header
        # says what the checks wait on; regenerate only once that landed.
        raise GenError(f"{path} is XFAIL; regenerating it from today's output would make it XPASS. "
                       f"Read its header, then pass --allow-xfail if that is what you mean")
    blocks = find_blocks(lines, path)
    by_prefix = {b.opts.prefix: b for b in blocks}

    hand = hand_written_prefixes(lines, blocks)
    jobs = []  # (BlockOpts, existing Block or None)
    if requested:
        for o in requested:
            existing = by_prefix.get(o.prefix)
            if existing:
                o = merge_opts(existing.opts, o, args)
            if not existing and o.prefix in hand:
                # A generated block and hand-written checks under one prefix
                # merge into a single FileCheck run: each set would be checked
                # against the other's RUN line.
                raise GenError(f"{path} already has hand-written {o.prefix} checks; "
                               f"pick another --prefix for the generated block")
            jobs.append((o.normalized(), existing))
        if not args.only:
            named = {o.prefix for o, _ in jobs}
            jobs += [(b.opts.normalized(), b) for b in blocks if b.opts.prefix not in named]
    else:
        if not blocks:
            raise GenError(f"{path} has no generated blocks; say which to make with --mode")
        jobs = [(b.opts.normalized(), b) for b in blocks]

    outdir = tempfile.mkdtemp(prefix="gen_checks_")
    try:
        run_probe(env, path, [o for o, _ in jobs], outdir)
        norm = Norm(path)
        texts = [block_text(o, outdir, n, path, norm) for n, (o, _) in enumerate(jobs)]
    finally:
        shutil.rmtree(outdir, ignore_errors=True)

    # Replace existing blocks bottom-up so earlier indices stay valid, then
    # append new ones under the wiring rule.
    new_lines = list(lines)
    replaced = sorted([(b, t) for (o, b), t in zip(jobs, texts) if b], key=lambda x: -x[0].start)
    for b, t in replaced:
        new_lines[b.start:b.end + 1] = t
    fresh = [t for (o, b), t in zip(jobs, texts) if not b]
    if fresh:
        while new_lines and not new_lines[-1].strip():
            new_lines.pop()
        if not any(l.startswith("// --- lit wiring") for l in new_lines):
            new_lines += ["", WIRING_RULE]
        for t in fresh:
            new_lines += [""] + t
    new_text = "\n".join(new_lines) + "\n"

    prefixes = {o.prefix for o, _ in jobs}
    outside = []
    inside = False
    for k, l in enumerate(new_lines):
        if l.startswith("// BEGIN-GENERATED-CHECKS"):
            inside = True
        if not inside:
            outside.append((k, l))
        if l.startswith("// END-GENERATED-CHECKS"):
            inside = False
    lint_prose(outside, prefixes, path)
    return original, new_text


def hand_written_prefixes(lines, blocks):
    """Prefixes the file's own RUN lines (outside generated blocks) hand to
    FileCheck. A RUN line with no --check-prefix uses CHECK."""
    inside = set()
    for b in blocks:
        inside.update(range(b.start, b.end + 1))
    out = set()
    for k, l in enumerate(lines):
        if k in inside or "// RUN:" not in l or "FileCheck" not in l:
            continue
        found = re.findall(r"--check-prefix(?:es)?[= ]([A-Za-z0-9_,-]+)", l)
        if found:
            for f in found:
                out.update(f.split(","))
        else:
            out.add("CHECK")
    return out


def merge_opts(old, new, args):
    """Options given on the command line override the block's recorded ones;
    anything not given keeps what the block was made with."""
    if new.mode != old.mode:
        return new
    o = replace(old)
    for name in ("through", "kargs", "sections", "focus"):
        if getattr(args, "cli_" + name) is not None:
            setattr(o, name, getattr(new, name))
    for name in ("literal_ns", "loose_position", "loose_message"):
        if getattr(args, name):
            setattr(o, name, True)
    if args.no_stdout:
        o.stdout = False
    if args.hoisted_scope:
        o.hoisted = True
    return o


def run_lit(env, path):
    cmd = [env.lit, "-v", "--skip-test-time-recording", str(path)] + [f"--param={p}" for p in env.lit_params]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                       env=dict(os.environ, KAIRO_BIN=env.kairo))
    ok = r.returncode == 0 and re.search(r"^(PASS|XFAIL|UNSUPPORTED): ", r.stdout, re.M)
    return bool(ok), r.stdout


# --- Driver ----------------------------------------------------------------------------

def find_kairo(explicit):
    if explicit:
        return str(Path(explicit).resolve())
    if os.environ.get("KAIRO_BIN"):
        return str(Path(os.environ["KAIRO_BIN"]).resolve())
    # The debug build: it is what the edit/test loop rebuilds, and lit's own
    # default (release) is the stale-binary trap CLAUDE.md warns about.
    cands = glob.glob(str(REPO_ROOT / "build" / "*" / "debug" / "bin" / "kairo"))
    if not cands:
        raise GenError("no kairo binary: pass --kairo, set KAIRO_BIN, or `kbld kairo --debug`")
    return max(cands, key=os.path.getmtime)


def find_lit(explicit):
    if explicit:
        return explicit
    p = REPO_ROOT / "build" / "llvm" / "bin" / "llvm-lit"
    if p.exists():
        return str(p)
    for name in ("llvm-lit", "lit"):
        if shutil.which(name):
            return shutil.which(name)
    raise GenError("no llvm-lit: pass --lit")


def csv(s):
    return [x for x in s.split(",") if x] if s is not None else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help=".k test files (a leading kairo binary path is the old form)")
    ap.add_argument("--mode", help=f"comma-separated, from: {', '.join(MODES)}; omit to regenerate the "
                                   f"blocks already in each file")
    ap.add_argument("--prefix", help="check prefix for the block (one --mode only)")
    ap.add_argument("--only", action="store_true",
                    help="with --mode: regenerate only the named blocks, leave the file's others alone")
    ap.add_argument("--through", dest="cli_through", choices=THROUGHS,
                    help="how far the compile goes: check (type-check only), obj (-c), link (-o exe)")
    ap.add_argument("--kairo-args", dest="cli_kargs", help="extra compiler flags for the RUN line")
    ap.add_argument("--sections", dest="cli_sections",
                    help=f"sema/lowered sections, or `all` (default: {','.join(SEMA_DEFAULT_SECTIONS)})")
    ap.add_argument("--focus", dest="cli_focus",
                    help="cxx: keep only top-level declarations naming one of these identifiers")
    ap.add_argument("--literal-namespace", dest="literal_ns", action="store_true",
                    help="cxx: keep the module namespace literal instead of globbing it")
    ap.add_argument("--no-stdout", action="store_true", help="run: check the exit code only")
    ap.add_argument("--hoisted-scope", action="store_true",
                    help="ast: also check the global hoisted-scope dump (every TU, builtins included)")
    ap.add_argument("--loose-position", action="store_true",
                    help="ast/diag: glob line:col in diagnostic checks")
    ap.add_argument("--loose-message", action="store_true",
                    help="ast/diag: assert only `kind [CODE]:`, not the message")
    ap.add_argument("--kairo", help="kairo binary (default: $KAIRO_BIN, else the debug build)")
    ap.add_argument("--lit", help="llvm-lit (default: build/llvm/bin/llvm-lit, else PATH)")
    ap.add_argument("--lit-param", action="append", default=[], metavar="K=V",
                    help="passed to lit as --param (e.g. clang=/usr/bin/clang++)")
    ap.add_argument("--allow-xfail", action="store_true", help="regenerate XFAIL files too")
    ap.add_argument("--check", action="store_true", help="write nothing; print the diff, exit 1 if any")
    ap.add_argument("--dry-run", action="store_true", help="print the new file instead of writing it")
    ap.add_argument("--no-lit", action="store_true", help="skip running lit on the written files")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1)
    args = ap.parse_args()

    files = list(args.files)
    kairo_arg = args.kairo
    if not files[0].endswith(".k") and os.access(files[0], os.X_OK) and not os.path.isdir(files[0]):
        kairo_arg = kairo_arg or files.pop(0)
        args.mode = args.mode or "ast"
    try:
        env = Env(find_kairo(kairo_arg), find_lit(args.lit), args.lit_param)
        requested = []
        if args.mode:
            modes = csv(args.mode)
            bad = [m for m in modes if m not in MODES]
            if bad:
                ap.error(f"unknown mode(s) {', '.join(bad)}; known: {', '.join(MODES)}")
            if args.prefix and len(modes) != 1:
                ap.error("--prefix needs exactly one --mode")
            for m in modes:
                requested.append(BlockOpts(
                    mode=m, prefix=args.prefix or DEFAULT_PREFIX[m],
                    through=args.cli_through or "",
                    kargs=shlex.split(args.cli_kargs) if args.cli_kargs else [],
                    sections=csv(args.cli_sections) or [],
                    focus=csv(args.cli_focus) or [],
                    literal_ns=args.literal_ns, stdout=not args.no_stdout,
                    hoisted=args.hoisted_scope,
                    loose_position=args.loose_position, loose_message=args.loose_message,
                ))
                requested[-1].normalized()  # validate early
    except GenError as e:
        print(f"gen_checks.py: {e}", file=sys.stderr)
        sys.exit(2)

    paths = [Path(f) for f in files]
    for p in paths:
        if not p.is_file():
            ap.error(f"not a file: {p}")

    def work(p):
        try:
            return p, process_file(p, env, requested, args), None
        except GenError as e:
            return p, None, str(e)

    failed = changed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        results = list(pool.map(work, paths))
    to_verify = []
    for p, res, err in results:
        if err:
            print(f"gen_checks.py: {p}: {err}", file=sys.stderr)
            failed += 1
            continue
        old, new = res
        if old == new:
            continue
        changed += 1
        if args.check:
            sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                                       str(p), str(p)))
        elif args.dry_run:
            print(new, end="")
        else:
            p.write_text(new)
            print(f"gen_checks.py: wrote {p}", file=sys.stderr)
            to_verify.append(p)

    if to_verify and not args.no_lit:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            for p, (ok, out) in zip(to_verify, pool.map(lambda q: run_lit(env, q), to_verify)):
                if not ok:
                    print(f"gen_checks.py: {p}: the regenerated test does NOT pass:\n{out}", file=sys.stderr)
                    failed += 1

    if args.check and changed:
        sys.exit(1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()