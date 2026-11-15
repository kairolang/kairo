#!/usr/bin/env python3
"""Out-of-process fuzzer for everything after the parser: name and type
resolution, the checks, lowering and C++ emission.

Each input is a .k file. It goes through `kairo --type-check-only` and, when
that is clean, through the cheapest command that runs lowering, C++ emission
and clang's front end on the input alone:

    kairo FILE -c --emit-scope=inputs --cache-dir=DIR

(about 0.15 s for a small file; `--emit-scope=graph` would rebuild builtin and
the runtime on every run, about 2 s). Every run gets its own --cache-dir, so
no run reuses another's objects. The compiler finds its own builtin and std
beside the binary, so the library is always the one the binary ships with.

Oracles, most valuable first (`--oracles` picks a subset):

  accept     accepted-then-rejected: --type-check-only reports no error, but
             the compile through C++ does (clang rejected the generated C++,
             CL001E and friends, or a late C/CL/I/SC error). Every hit is a
             compiler bug: Sema should have rejected the program with its own
             diagnostic, or codegen emitted wrong C++.
  crash      exit by signal, or an exit code that is neither 0 nor 1, under
             either command
  hang       either command ran past --timeout
  ice        an I-category diagnostic whose text says "compiler bug"
  nondet     --sema-threads=1 and --sema-threads=4 disagree on the
             diagnostics (as sorted sets of one-line diagnostics)
  invariant  the exit status disagrees with whether an error was reported;
             a location outside its file (line or column 0, past EOF); a
             location in a file that is neither the input, a file beside the
             seed, a library file nor a header; one error printed twice at
             one location
  kals       the language server's diagnostics for a file differ from
             --type-check-only's (opt-in: one server process per worker)

Seeds are the .k files under Tests/ that have RUN: lines or are fixtures
(a file under Inputs/ or a lowercase fixture directory). Compiler/ and Lib/
are never seeds. A test's own RUN: line is read for the flags that change
what the program means (-f..., --target, -I, -D, --no-*, ...); a flag whose
value names a lit temp path makes the seed a counted skip. Every input runs
in a private directory under its seed's own file name, with -I naming the
seed's directory, so sibling imports resolve.

Mutations are small and keep the program mostly well-formed, so it lands in
Sema and codegen instead of dying in the parser (that is parser_fuzz.py's
job). Each is token-aware and grammar-light:

  param_name   drop or add a parameter name, mostly in a bodiless signature
               (an interface requirement, a forward declaration)
  modifier     add, drop or swap const, pub, priv, static, inline, unsafe,
               @move, @copy, @inout
  type_swap    swap a type for another named in the file; T -> *T, T?, [T];
               *T -> unsafe *T or T
  binder       swap a for-loop binder: x, *x, const x, const *x, unsafe *x
  operator     swap a binary operator for another of the same family
  expr         replace a use with a literal, another name, or a call
  member       duplicate or delete a member of a class, struct, interface
  clause       drop or duplicate an impl / derives entry or a requires clause
  generic      make a function or a type generic, or strip its generics
  splice       insert a top-level declaration taken from another seed
  rename       rename one use of an identifier to another in the file

Seeds whose --type-check-only is clean are drawn four times as often as the
rest: they are what the accept oracle can chew on. XFAIL seeds are not drawn
(their mutants rediscover the failure the XFAIL records), and a hit on an
XFAIL seed, or one whose code or text the seed's own test (or the test that
uses a fixture) checks for, is counted as expected rather than filed. The draw is deterministic
under --seed N (given the same corpus and the same cached seed results).

A finding is kept only when it reproduces three times in a row. It lands in
<out>/<oracle>/<hash of signature>/ with orig.k, min.k (ddmin over lines,
then tokens, keeping the oracle and its signature), out.txt, repro.sh (the
exact commands; exit 1 when the finding reproduces), README (one line),
signature.txt, and up to three more inputs with the same signature under
samples/. Signatures carry no source positions or names, so one bug is one
directory.

Seeds already clean under the same binary (its mtime and size) are not run
again by --seeds-only; --no-cache runs them anyway.

Usage:
  Scripts/sema_fuzz.py --out DIR               # run until ^C
  Scripts/sema_fuzz.py --out DIR --time 1800 -j 8
  Scripts/sema_fuzz.py --out DIR --seeds-only
  Scripts/sema_fuzz.py --repro FILE [--as NAME] [-I DIR] [-- FLAGS]
  Scripts/sema_fuzz.py --out DIR --mutations param_name --filter interface
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import dataclasses
import fnmatch
import glob
import hashlib
import json
import os
import random
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parser_fuzz import _crash_sig, _norm, _SANITIZER, ICE_CODES, significant, tokenize  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ALL_ORACLES = ["accept", "crash", "hang", "ice", "nondet", "invariant", "kals"]
DEFAULT_ORACLES = [o for o in ALL_ORACLES if o != "kals"]

# --- Seeds -------------------------------------------------------------------


@dataclasses.dataclass
class Seed:
    path: Path            # the file in Tests/
    rel: str              # path relative to the corpus root
    text: str
    flags: list[str]      # semantic flags from the test's RUN: line
    inputs: list[Path]    # further inputs that RUN: line compiles with it
    xfail: bool
    duck: bool            # -fduck-generics: C++ checks generic bodies by design
    skip: str | None      # why this seed is not run, or None

    _expects: set[str] | None = None

    def expects(self) -> set[str]:
        """Diagnostic codes this file's test checks for: its own CHECK lines,
        or those of a sibling test that names this file (a fixture)."""
        if self._expects is None:
            texts = [self.text]
            try:
                for q in self.dir.parent.glob("*.k") if self.dir.name == "Inputs" else self.dir.glob("*.k"):
                    if q != self.path:
                        t = q.read_text(encoding="utf-8", errors="replace")
                        if self.path.stem in t:
                            texts.append(t)
            except OSError:
                pass
            # Positive check lines only: a CHECK-NOT or --implicit-check-not
            # naming a code says the opposite.
            checks = [m.group(2).strip() for t in texts
                      for m in re.finditer(r"^\s*//\s*([A-Z][A-Z0-9_-]*):(.*)$", t, re.M)
                      if "NOT" not in m.group(1) and m.group(1) not in ("RUN", "REQUIRES", "XFAIL", "UNSUPPORTED")]
            self._expects = {c for line in checks for c in re.findall(r"\b([A-Z]+\d+[EFW])\b", line)}
            self._checks = [c for c in checks if len(c) >= 12]
        return self._expects

    _checks: list[str] | None = None

    def expected(self, f: "Finding", out: str) -> bool:
        """The test this seed belongs to checks for what the finding saw:
        its first error's code or text (accept), or a code in the output of
        an ICE or crash (a test that pins an ICE on purpose)."""
        codes = self.expects()
        if f.oracle == "accept":
            line = f.detail
            return f.signature.split()[1] in codes or any(c in line for c in self._checks or [])
        if f.oracle in ("ice", "crash"):
            # Only an internal-error code the test checks: a mutant of an
            # expected-error test that also ICEs is still a finding.
            return any(c in codes and c[:-1] in ICE_CODES
                       for c in re.findall(r"\[([A-Z]+\d+[EFW])\]", out))
        return False

    @property
    def name(self) -> str:
        return self.path.name

    @property
    def dir(self) -> Path:
        return self.path.parent


_RUN = re.compile(r"^\s*//\s*RUN:(.*)$", re.M)
_XFAIL = re.compile(r"^\s*//\s*XFAIL:", re.M)

# Flags that change what a program means. Anything else on a RUN: line (dump
# flags, output paths, stop-after flags) is about the test, not the program.
_FLAG_VALUE = {"-I", "--include", "--ffi-include", "--cxx-include", "--cxx-define",
               "--cxx-undefine", "--macro-search-path", "--force-include", "--target",
               "-D", "-A", "-W", "-E", "-F", "--std-dir", "--builtins-dir", "--prelude",
               "--cxx-std", "--unmatched", "--fdefault-visibility", "--test-panic-id-bits"}
_FLAG_BARE = re.compile(
    r"^(-f(no-)?[a-z][a-z0-9-]*|--no-(unsafe|ffi|cxx|yield|modules|fp|prelude|builtins|stdlib)"
    r"|--freestanding|--test-panic-type|--signed-wrap|--Werror|-w|--m32|--m64)$")
_FLAG_JOINED = re.compile(
    r"^(-I|-D|-A|-W|-E|-F)(?=.)|^(--(include|ffi-include|cxx-include|cxx-define|cxx-undefine|"
    r"macro-search-path|force-include|target|std-dir|builtins-dir|prelude|cxx-std|unmatched|"
    r"fdefault-visibility|test-panic-id-bits))=")
# -f words that are not language flags (clang's, or output shape).
_F_NOT_SEMANTIC = {"-fsyntax-only"}


def _run_commands(text: str) -> list[str]:
    lines, cur = [], ""
    for m in _RUN.finditer(text):
        part = m.group(1).rstrip()
        if part.endswith("\\"):
            cur += part[:-1] + " "
            continue
        lines.append(cur + part)
        cur = ""
    if cur:
        lines.append(cur)
    cmds = []
    for line in lines:
        for seg in re.split(r"\|\||&&|\||;", line):
            if re.search(r"%kairo(?![_\w])", seg):
                cmds.append(seg)
    return cmds


def _subst(word: str, seed_path: Path) -> str | None:
    w = word.replace("%s", str(seed_path)).replace("%S", str(seed_path.parent)).replace(
        "%p", str(seed_path.parent))
    return None if "%" in w else w


def parse_run(text: str, seed_path: Path) -> tuple[list[str], list[Path], str | None]:
    """(flags, extra inputs, skip reason) from the RUN: line that compiles this file."""
    best = None
    for cmd in _run_commands(text):
        try:
            words = shlex.split(cmd)
        except ValueError:
            continue
        try:
            words = words[words.index(next(w for w in words if re.fullmatch(r"%kairo", w))) + 1:]
        except StopIteration:
            continue
        if "%s" not in words:
            continue
        # Prefer a run that type-checks or compiles over one that only dumps.
        rank = 0 if "--type-check-only" in words else (2 if "--syntax-only" in words else 1)
        if best is None or rank < best[0]:
            best = (rank, words)
    if best is None:
        return [], [], None
    words = best[1]
    flags: list[str] = []
    inputs: list[Path] = []
    i = 0
    while i < len(words):
        w = words[i]
        if w in _FLAG_VALUE and i + 1 < len(words):
            v = _subst(words[i + 1], seed_path)
            if v is None:
                return [], [], f"RUN flag {w} names a lit temp path"
            flags += [w, v]
            i += 2
            continue
        if _FLAG_JOINED.match(w) or (_FLAG_BARE.match(w) and w not in _F_NOT_SEMANTIC):
            v = _subst(w, seed_path)
            if v is None:
                return [], [], f"RUN flag {w.split('=')[0]} names a lit temp path"
            flags.append(v)
        elif w == "--":
            break
        elif not w.startswith("-") and w != "%s" and w.endswith(".k"):
            v = _subst(w, seed_path)
            if v is None:
                return [], [], "RUN line compiles a lit temp file with it"
            inputs.append(Path(v))
        elif w in ("-o", "--cache-dir", "--emit-headers", "--stats-file", "--time-trace",
                   "--dump-interface", "--dump-deps", "--dump-import-uses", "--incr-replay",
                   "--incr-replay-dump", "--emit-ast-bin", "-x", "--language", "--error-format",
                   "--threads", "--sema-threads", "--codegen-threads", "--emit", "-O",
                   "--profile", "-l", "-L", "--link", "--lib-dir", "--sysroot"):
            i += 1  # its value, if given separately
        i += 1
    return flags, inputs, None


def _is_fixture(rel: Path) -> bool:
    parts = rel.parts[:-1]
    return "Inputs" in parts or any(p[:1].islower() for p in parts)


# Whole trees that are not suites (Tests/README): oracle material for clang,
# hand-run scratch, self-checking programs run by their own scripts.
_NOT_SUITES = ("Clang", "Manual", "NumericConformance")


def load_seeds(corpus: Path, filt: str | None, grep: str | None = None) -> tuple[list[Seed], dict[str, int]]:
    seeds: list[Seed] = []
    skipped: dict[str, int] = {}
    seen: set[bytes] = set()

    def skip(why: str) -> None:
        skipped[why] = skipped.get(why, 0) + 1

    for p in sorted(corpus.rglob("*.k")):
        rel = p.relative_to(corpus)
        if filt and not (re.search(filt, str(rel)) or fnmatch.fnmatch(str(rel), filt)):
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="surrogateescape")
        except OSError:
            skip("unreadable")
            continue
        if grep and not re.search(grep, text, re.M):
            continue
        has_run = bool(_RUN.search(text))
        if not has_run and not _is_fixture(rel):
            skip("no RUN line and not a fixture" if rel.parts[0] not in _NOT_SUITES
                 else f"{rel.parts[0]}/ is not a suite")
            continue
        if not text.strip():
            skip("empty")
            continue
        h = hashlib.sha1(text.encode("utf-8", "surrogateescape")).digest()
        if h in seen:
            skip("duplicate text")
            continue
        seen.add(h)
        flags, inputs, why = parse_run(text, p) if has_run else ([], [], None)
        seeds.append(Seed(p, str(rel), text, flags, inputs, bool(_XFAIL.search(text)),
                          "-fduck-generics" in flags, why))
    return seeds, skipped


# --- Running the compiler ----------------------------------------------------

# One-line diagnostics as --error-format=basic prints them; an unlocated one
# (a driver error) has no file:line:col.
_DIAG = re.compile(
    r"^(?:(?P<file>[^\n]*?):(?P<line>\d+):(?P<col>\d+): )?"
    r"(?P<sev>fatal error|error|warning|note|remark|fatal) \[(?P<code>[A-Z]+\d+[A-Z])\]: (?P<msg>[^\n]*)$",
    re.M)
_ICE_CODE = re.compile(r"\[(" + "|".join(sorted(ICE_CODES)) + r")[A-Z]\]")
_ERROR_SEVS = ("error", "fatal error", "fatal")


@dataclasses.dataclass
class Result:
    rc: int | None  # None = timeout
    out: str
    secs: float

    def diags(self) -> list[re.Match]:
        return list(_DIAG.finditer(self.out))

    def errors(self) -> list[re.Match]:
        return [m for m in self.diags() if m["sev"] in _ERROR_SEVS]

    def has_error(self) -> bool:
        return bool(self.errors())

    def clean(self) -> bool:
        return self.rc == 0 and not self.has_error()


@dataclasses.dataclass
class Finding:
    oracle: str
    signature: str
    detail: str


class Runner:
    def __init__(self, kairo: Path, timeout: float, work: Path, extra: list[str]):
        self.kairo = kairo
        self.timeout = timeout
        self.work = work
        self.extra = extra
        # Diagnostics are compared as sets, so every one must be printed:
        # the default cap of 20 cuts a different 20 depending on order.
        self.base = [str(kairo), "--error-format=basic", "--threads=2", "--cmax-errors=0"]
        self.tool_root = kairo.resolve().parent.parent

    def tc_cmd(self, seed: Seed) -> list[str]:
        return self.base + ["--type-check-only"] + self._common(seed)

    def cg_cmd(self, seed: Seed, cache: str) -> list[str]:
        return self.base + ["-c", "--emit-scope=inputs", f"--cache-dir={cache}"] + self._common(seed)

    def _common(self, seed: Seed) -> list[str]:
        inc = ["-I", str(seed.dir)] if seed.dir.is_dir() else []
        return inc + seed.flags + self.extra + [seed.name] + [str(p) for p in seed.inputs]

    def run(self, cmd: list[str], d: str, timeout: float | None = None) -> Result:
        t0 = time.monotonic()
        # A session of its own, so a timeout kills clang and any other child
        # with the driver, not just the driver.
        p = subprocess.Popen(cmd, cwd=d, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
        try:
            out, _ = p.communicate(timeout=timeout or self.timeout)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out, _ = p.communicate()
            rc = None
        return Result(rc, self._scrub(out, d), time.monotonic() - t0)

    @staticmethod
    def _scrub(raw: bytes, d: str) -> str:
        # Each run has its own directory; left in, no two outputs compare equal.
        out = raw.decode("utf-8", "replace")
        for p in {os.path.realpath(d), d}:
            out = out.replace(p + os.sep, "")
        return out

    def workdir(self, text: str, seed: Seed) -> str:
        self.work.mkdir(parents=True, exist_ok=True)
        d = tempfile.mkdtemp(prefix="ksf-", dir=self.work)
        Path(d, seed.name).write_text(text, encoding="utf-8", errors="surrogateescape")
        return d


# --- Classification ----------------------------------------------------------

_line_counts: dict[str, list[int] | None] = {}
_lc_lock = threading.Lock()


def _file_lines(path: str) -> list[int] | None:
    with _lc_lock:
        if path in _line_counts:
            return _line_counts[path]
    try:
        data = Path(path).read_bytes().split(b"\n")
        got = [len(l) for l in data]
    except OSError:
        got = None
    with _lc_lock:
        _line_counts[path] = got
    return got


_HEADER_EXT = (".h", ".hh", ".hpp", ".hxx", ".inc", ".def", ".ipp", ".tcc")


def _loc_check(r: Result, text: str, seed: Seed, runner: Runner, phase: str) -> list[Finding]:
    f: list[Finding] = []
    own = [len(l.encode("utf-8", "surrogateescape")) for l in text.split("\n")]
    for m in r.diags():
        if m["file"] is None:
            continue
        fn, ln, col = m["file"], int(m["line"]), int(m["col"])
        if fn == seed.name:
            lines = own
        else:
            ap = os.path.realpath(fn)
            is_header = fn.endswith(_HEADER_EXT) or "/include/" in fn or "/c++/" in fn
            known = (ap.startswith(str(seed.dir) + os.sep)
                     or ap.startswith(str(runner.tool_root) + os.sep)
                     or any(ap == str(p.resolve()) for p in seed.inputs)
                     or is_header or fn.startswith("<"))
            if not known:
                f.append(Finding("invariant", f"{phase} foreign-file {m['code']}",
                                 f"{m.group(0)}  (not the input, a seed sibling, the library or a header)"))
                break
            if is_header or fn.startswith("<"):
                continue
            lines = _file_lines(ap)
            if lines is None:
                f.append(Finding("invariant", f"{phase} missing-file {m['code']}", m.group(0)))
                break
        # Line and column are 1-based; one past the last character is a valid
        # caret (EOF, a missing token), hence +2.
        bad = ln < 1 or col < 1 or ln > len(lines) + 1
        if not bad and ln <= len(lines):
            bad = col > lines[ln - 1] + 2
        if bad:
            where = "input" if fn == seed.name else "library"
            f.append(Finding("invariant", f"{phase} loc-out-of-range {where} {m['code']}",
                             f"{m.group(0)}  (file has {len(lines)} lines)"))
            break
    seen: set[tuple] = set()
    for m in r.errors():
        if m["file"] is None:
            continue
        key = (m["file"], m["line"], m["col"], m["code"], m["msg"])
        if key in seen:
            f.append(Finding("invariant", f"{phase} duplicate-error {m['code']} {_norm(m['msg'])}",
                             f"printed twice: {m.group(0)}"))
            break
        seen.add(key)
    return f


_ICE_LINE = re.compile(r"^Kairo Internal Compiler Error: (.*?)(?:, at \S+:\d+:\d+)?$", re.M)


def _ice_message(out: str) -> str:
    """The compiler's own ICE line: an abort with no backtrace is otherwise
    keyed on the boilerplate under it, which every ICE prints alike."""
    m = _ICE_LINE.search(out)
    return _norm(m.group(1)) + "\n" if m else ""


def _basic_checks(r: Result, phase: str, oracles: set[str]) -> list[Finding]:
    if r.rc is None:
        return [Finding("hang", f"{phase} timeout", f"{phase}: no exit after {r.secs:.1f}s")] \
            if "hang" in oracles else []
    if r.rc < 0 or r.rc not in (0, 1) or _SANITIZER.search(r.out):
        return [Finding("crash", f"{phase} rc={r.rc}\n" + _ice_message(r.out) + _crash_sig(r.out),
                        f"{phase}: exit {r.rc}")] if "crash" in oracles else []
    f: list[Finding] = []
    ices = sorted(set(_ICE_CODE.findall(r.out)))
    if ices and "ice" in oracles:
        line = next(l for l in r.out.splitlines() if _ICE_CODE.search(l))
        f.append(Finding("ice", f"{phase} {','.join(ices)} {_norm(line.split(']:', 1)[-1])}", line.strip()))
    if "invariant" in oracles and (r.rc == 1) != r.has_error():
        f.append(Finding("invariant", f"{phase} rc={r.rc} has_error={r.has_error()}",
                         f"{phase}: exit status disagrees with reported errors"))
    return f


def _diag_set(r: Result) -> list[str]:
    return sorted(m.group(0) for m in r.diags())


def _snorm(s: str) -> str:
    """_norm, but a quoted run of punctuation is kept: `expected ')'` and
    `expected ';'` are different clang complaints, `'x'` and `'y'` are not."""
    s = re.sub(r"0x[0-9a-fA-F]+", "0x", s)
    s = re.sub(r"'[^'\n]*[A-Za-z0-9_][^'\n]*'", "'_'", s)
    s = re.sub(r"\d+", "N", s)
    return s.strip()


def _code_family(code: str) -> str:
    m = re.match(r"[A-Z]+", code)
    fam = m.group(0) if m else code
    # C0001.. are clang's own warning groups; CL001 is clang's unnamed errors.
    return "C" if re.fullmatch(r"C\d{4}[A-Z]", code) else fam


def accept_signature(cg: Result) -> tuple[str, str]:
    """Keyed on the first error only: later ones are usually its cascade."""
    errs = cg.errors()
    if not errs:
        return f"rc={cg.rc} no-error-line", "compile failed without an error line"
    e = errs[0]
    where = "header" if (e["file"] or "").endswith(_HEADER_EXT) else "kairo"
    return f"{_code_family(e['code'])} {e['code']} {_snorm(e['msg'])} @{where}", e.group(0)


@dataclasses.dataclass
class Outcome:
    findings: list[Finding]
    tc: Result | None = None
    tc_alt: Result | None = None
    cg: Result | None = None
    tc_clean: bool = False
    notes: list[str] = dataclasses.field(default_factory=list)

    def transcript(self) -> str:
        parts = []
        for name, r in (("type-check-only", self.tc), ("type-check-only --sema-threads=1", self.tc_alt),
                        ("compile (-c --emit-scope=inputs)", self.cg)):
            if r is not None:
                parts.append(f"===== {name}: rc={r.rc} {r.secs:.2f}s\n{r.out}")
        return "\n".join(parts)


def evaluate(runner: Runner, text: str, seed: Seed, oracles: set[str], nondet: bool,
             kals: "KalsPool | None" = None, keep: bool = False) -> Outcome:
    d = runner.workdir(text, seed)
    try:
        o = Outcome([])
        tc = runner.run(runner.tc_cmd(seed), d)
        o.tc = tc
        o.findings += _basic_checks(tc, "tc", oracles)
        if tc.rc not in (0, 1):
            return o
        if "invariant" in oracles:
            o.findings += _loc_check(tc, text, seed, runner, "tc")
        if nondet and "nondet" in oracles:
            # 4 against 1, not the run's own 2: more threads, more orders.
            a = runner.run(runner.tc_cmd(seed) + ["--sema-threads=4"], d)
            b = runner.run(runner.tc_cmd(seed) + ["--sema-threads=1"], d)
            o.tc_alt = b
            if a.rc in (0, 1) and b.rc in (0, 1) and (a.rc != b.rc or _diag_set(a) != _diag_set(b)):
                only_a = sorted(set(_diag_set(a)) - set(_diag_set(b)))
                only_b = sorted(set(_diag_set(b)) - set(_diag_set(a)))
                o.findings.append(Finding(
                    "nondet", f"rc {a.rc}/{b.rc} " + _norm(" ".join(
                        m.split("]:")[0].rsplit("[", 1)[-1] for m in (only_a + only_b)[:3])),
                    f"--sema-threads=4 only: {only_a[:3]}  --sema-threads=1 only: {only_b[:3]}"))
        if kals is not None and "kals" in oracles and KalsPool.comparable(seed, text):
            o.findings += kals.compare(Path(d, seed.name), tc, seed)
        o.tc_clean = tc.clean()
        if not o.tc_clean:
            return o
        if not ({"accept", "crash", "hang", "ice", "invariant"} & oracles):
            return o
        cache = os.path.join(d, "cache")
        cg = runner.run(runner.cg_cmd(seed, cache), d)
        o.cg = cg
        o.findings += _basic_checks(cg, "cg", oracles)
        if cg.rc in (0, 1):
            if "invariant" in oracles:
                o.findings += _loc_check(cg, text, seed, runner, "cg")
            if "accept" in oracles and not cg.clean():
                sig, detail = accept_signature(cg)
                if seed.duck and _code_family(sig.split()[0]) in ("CL", "C"):
                    o.notes.append("duck-generics: C++ checks generic bodies by design")
                else:
                    o.findings.append(Finding("accept", sig, detail))
        return o
    finally:
        if not keep:
            shutil.rmtree(d, ignore_errors=True)


# --- kals oracle -------------------------------------------------------------


class KalsPool:
    """One language server per worker thread, reused across files.

    Each file is opened in a fresh workspace folder of its own, the server's
    published diagnostics are compared with --type-check-only's as sets of
    (line, code). Messages are not compared: the server may word a note
    differently, and the location and code are what an editor shows.
    """

    def __init__(self, kals: Path, timeout: float, work: Path):
        sys.path.insert(0, str(ROOT / "Analyzer" / "Dev"))
        import lsp_client  # noqa: F401  (fail early when it is missing)
        self.kals = kals
        self.timeout = timeout
        self.work = work
        self.local = threading.local()
        self.all: list = []
        self.lock = threading.Lock()

    def _client(self):
        from lsp_client import Client
        c = getattr(self.local, "c", None)
        if c is None:
            # Every run's directory is under the work root, so one server
            # (workspace = that root) checks every file a worker hands it.
            self.work.mkdir(parents=True, exist_ok=True)
            c = Client(str(self.kals), str(self.work))
            c.start()
            self.local.c = c
            with self.lock:
                self.all.append(c)
        return c

    @staticmethod
    def comparable(seed: Seed, text: str) -> bool:
        """kals takes no command line: a seed whose meaning needs RUN flags,
        further inputs or a sibling module (-I) would differ for that alone."""
        if seed.flags or seed.inputs:
            return False
        roots = re.findall(r"^\s*(?:pub\s+)?import\s+([A-Za-z_]\w*)", text, re.M)
        headers = re.findall(r'^\s*ffi\s+"[^"]*"\s+import\s+"([^"]+)"', text, re.M)
        return (all(r in ("std", "builtin", "cxx") for r in roots)
                and not any((seed.dir / h).exists() for h in headers))

    def compare(self, path: Path, tc: Result, seed: Seed) -> list[Finding]:
        rel = str(path.relative_to(self.work))
        try:
            c = self._client()
            c.notes.clear()
            c.open(rel, path.read_text(encoding="utf-8", errors="surrogateescape"))
            # Lsp_client's settle() takes any entry's `$/kals/analysed`; a late
            # one for the previous file would end the wait before this one's.
            settled, end = False, time.time() + self.timeout
            while not settled and time.time() < end:
                settled = any(n["method"] == "$/kals/analysed" and n["params"].get("entry") == str(path)
                              and n["params"]["revision"] >= n["params"]["current"]
                              and n["params"].get("pending", 0) == 0 for n in c.notes)
                if not settled:
                    c.pump(0.05)
            diags = c.diagnostics(rel)
            c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri(rel)}})
        except Exception as e:  # a dead server is a finding of its own
            self.local.c = None
            return [Finding("kals", f"kals-error {type(e).__name__}", repr(e)[:300])]
        if not settled or diags is None:
            return [Finding("kals", "kals-timeout", f"no analysed answer in {self.timeout}s")]
        want = {(int(m["line"]), m["code"]) for m in tc.diags()
                if m["file"] == seed.name and m["sev"] != "note"}
        got = {(d["range"]["start"]["line"] + 1, str(d.get("code", ""))) for d in diags
               if d.get("severity", 1) != 4}
        if want != got:
            miss, extra = sorted(want - got), sorted(got - want)
            codes = sorted({c for _, c in miss} | {c for _, c in extra})
            return [Finding("kals", "kals-differs " + " ".join(codes[:4]),
                            f"kairo only: {miss[:5]}  kals only: {extra[:5]}")]
        return []

    def shutdown(self) -> None:
        for c in self.all:
            try:
                c.stop()
            except Exception:
                c.p.kill()


# --- Mutator -----------------------------------------------------------------

KEYWORDS = set("""fn var let const if else for in while loop return class struct enum interface
union impl derives requires self Self true false null pub priv prot static inline unsafe match case
break continue import ffi as is type extend op eval yield async await try catch finally throw panic
defer sizeof alignof where macro module default delete thread extern""".split())
PRIMS = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "isize", "usize", "f32", "f64",
         "bool", "char", "string"]
MODIFIERS = ["const", "pub", "priv", "static", "inline", "unsafe", "@move", "@copy", "@inout"]
OP_FAMILIES = [["+", "-", "*", "/", "%"], ["&", "|", "^", "<<", ">>"],
               ["==", "!=", "<", ">", "<=", ">="], ["&&", "||"],
               ["+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]]
LITERALS = ["0", "1", "-1", "true", "false", "null", '"s"', "1.5", "'c'", "255", "0u8"]
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")
DECL_KW = {"class", "struct", "enum", "interface", "union", "type"}


def _is_ident(t: str) -> bool:
    return bool(_IDENT.match(t)) and t not in KEYWORDS


def _match(toks: list[str], i: int) -> int | None:
    """Index of the bracket closing the one at toks[i], or None."""
    pairs = {"(": ")", "[": "]", "{": "}", "<": ">"}
    o = toks[i]
    c = pairs[o]
    depth = 0
    for j in range(i, len(toks)):
        if toks[j] == o:
            depth += 1
        elif toks[j] == c:
            depth -= 1
            if depth == 0:
                return j
        elif o == "<" and toks[j] in ("{", ";", "=") :
            return None
    return None


def _ffi_mask(toks: list[str]) -> list[bool]:
    """True for tokens inside an ffi block: C++ owns that grammar."""
    mask = [False] * len(toks)
    sig = significant(toks)
    for k, i in enumerate(sig):
        if toks[i] == "ffi":
            for j in sig[k + 1:k + 4]:
                if toks[j] == "{":
                    e = _match(toks, j)
                    if e:
                        for x in range(i, e + 1):
                            mask[x] = True
                    break
    return mask


class Mutator:
    def __init__(self, seeds: list[Seed], rng_seed: int):
        self.seeds = seeds
        self.rng_seed = rng_seed
        self._decls: dict[int, list[str]] = {}
        self.ops = {
            "param_name": self.m_param_name, "modifier": self.m_modifier,
            "type_swap": self.m_type_swap, "binder": self.m_binder,
            "operator": self.m_operator, "expr": self.m_expr, "member": self.m_member,
            "clause": self.m_clause, "generic": self.m_generic, "splice": self.m_splice,
            "rename": self.m_rename,
        }

    # Each op takes (rng, toks) and returns new tokens, or None when the file
    # has nowhere to apply it.

    def _sig(self, toks):
        mask = _ffi_mask(toks)
        return [i for i in significant(toks) if not mask[i]]

    def _names(self, toks, sig):
        return sorted({toks[i] for i in sig if _is_ident(toks[i])})

    def _types(self, toks, sig):
        names = set()
        for k, i in enumerate(sig[:-1]):
            if toks[i] in DECL_KW and _is_ident(toks[sig[k + 1]]):
                names.add(toks[sig[k + 1]])
            if toks[i] in (":", "->") and _is_ident(toks[sig[k + 1]]):
                names.add(toks[sig[k + 1]])
        return sorted(names) + PRIMS

    def _fn_params(self, toks, sig):
        """(open paren, close paren, bodiless) for each fn signature."""
        out = []
        for k, i in enumerate(sig):
            if toks[i] != "fn":
                continue
            for j in sig[k + 1:k + 12]:
                if toks[j] == "(":
                    e = _match(toks, j)
                    if e is None:
                        break
                    rest = [x for x in sig if x > e]
                    bodiless = True
                    for x in rest:
                        if toks[x] == "{":
                            bodiless = False
                            break
                        if toks[x] in ("}", ";", "fn", "=") or "\n" in "".join(toks[e:x]):
                            break
                    out.append((j, e, bodiless))
                    break
                if toks[j] in ("{", ";"):
                    break
        return out

    def _split_params(self, toks, a, b):
        """Token index ranges of each top-level parameter between a and b."""
        parts, start, depth = [], a + 1, 0
        for x in range(a + 1, b):
            t = toks[x]
            if t in "([{<":
                depth += 1
            elif t in ")]}>":
                depth -= 1
            elif t == "," and depth == 0:
                parts.append((start, x))
                start = x + 1
        parts.append((start, b))
        return [(s, e) for s, e in parts if any(toks[y].strip() for y in range(s, e))]

    def m_param_name(self, rng, toks):
        sig = self._sig(toks)
        fns = self._fn_params(toks, sig)
        if not fns:
            return None
        bodiless = [f for f in fns if f[2]]
        a, b, _ = rng.choice(bodiless if bodiless and rng.random() < 0.75 else fns)
        params = self._split_params(toks, a, b)
        if not params:
            return None
        s, e = rng.choice(params)
        ps = [y for y in range(s, e) if toks[y].strip() and not toks[y].startswith(("//", "/*"))]
        words = [toks[y] for y in ps]
        if words and words[-1] in ("self",) or "self" in words[:3]:
            return None
        colon = next((k for k, y in enumerate(ps) if toks[y] == ":"), None)
        toks = list(toks)
        if colon is not None and colon >= 1 and _is_ident(toks[ps[colon - 1]]):
            # Drop the name: `x: T` -> `T`, modifiers kept.
            del toks[ps[colon - 1]:ps[colon] + 1]
            if toks[ps[colon - 1]: ps[colon - 1] + 1] == [" "]:
                del toks[ps[colon - 1]]
        else:
            # Add a name before the type, after any modifiers.
            k = 0
            while k < len(ps) and (toks[ps[k]] in MODIFIERS or toks[ps[k]] == "@"
                                   or (k and toks[ps[k - 1]] == "@")):
                k += 1
            if k >= len(ps):
                return None
            toks[ps[k]:ps[k]] = [rng.choice(["p", "other", "x", "rhs"]), ":", " "]
        return toks

    def m_modifier(self, rng, toks):
        sig = self._sig(toks)
        toks = list(toks)
        mods = [i for i in sig if toks[i] in ("const", "pub", "priv", "static", "inline", "unsafe")
                or (toks[i] in ("move", "copy", "inout") and i and toks[i - 1] == "@")]
        r = rng.random()
        if mods and r < 0.35:
            i = rng.choice(mods)
            lo = i - 1 if toks[i - 1] == "@" else i
            del toks[lo:i + 1]
            return toks
        if mods and r < 0.6:
            i = rng.choice(mods)
            lo = i - 1 if toks[i - 1] == "@" else i
            toks[lo:i + 1] = [rng.choice(MODIFIERS)]
            return toks
        spots = [i for k, i in enumerate(sig) if toks[i] in ("fn", "var", "let", "class", "struct", "self")
                 or (_is_ident(toks[i]) and k + 1 < len(sig) and toks[sig[k + 1]] == ":")]
        if not spots:
            return None
        i = rng.choice(spots)
        toks[i:i] = [rng.choice(MODIFIERS), " "]
        return toks

    def m_type_swap(self, rng, toks):
        sig = self._sig(toks)
        pos = [sig[k + 1] for k, i in enumerate(sig[:-1])
               if toks[i] in (":", "->", "<", ",") and _is_ident(toks[sig[k + 1]])
               and (toks[i] != "," or toks[i - 1:i] != [" "])
               and (toks[sig[k + 1]] in PRIMS or toks[sig[k + 1]][:1].isupper())]
        if not pos:
            return None
        i = rng.choice(pos)
        toks = list(toks)
        t = toks[i]
        r = rng.random()
        if r < 0.4:
            toks[i] = rng.choice([x for x in self._types(toks, sig) if x != t] or PRIMS)
        elif r < 0.55:
            toks[i] = "*" + t
        elif r < 0.7:
            toks[i] = t + "?"
        elif r < 0.8:
            toks[i] = "[" + t + "]"
        elif r < 0.9 and toks[i - 1] == "*":
            toks[i - 1] = "unsafe *"
        elif toks[i - 1] == "*":
            toks[i - 1] = ""
        else:
            toks[i] = "[" + t + "; 4]"
        return toks

    def m_binder(self, rng, toks):
        sig = self._sig(toks)
        spots = []
        for k, i in enumerate(sig):
            if toks[i] != "for":
                continue
            j = next((m for m in range(k + 1, min(k + 5, len(sig))) if toks[sig[m]] == "in"), None)
            if j is None:
                continue
            words = [toks[sig[m]] for m in range(k + 1, j)]
            name = next((w for w in words if _is_ident(w)), None)
            if name and set(words) <= {name, "*", "const", "unsafe"}:
                spots.append((sig[k + 1], sig[j - 1], name))
        if not spots:
            return None
        a, b, name = rng.choice(spots)
        toks = list(toks)
        toks[a:b + 1] = [rng.choice([name, "*" + name, "const " + name, "const *" + name,
                                     "unsafe *" + name])]
        return toks

    def m_operator(self, rng, toks):
        sig = self._sig(toks)
        spots = []
        for k in range(1, len(sig) - 1):
            i = sig[k]
            t = toks[i]
            fam = next((f for f in OP_FAMILIES if t in f), None)
            if fam is None:
                continue
            # Binary context only: spaced on both sides, and an operand
            # before it (keeps pointer `*`, address `&` and generics `<>` out).
            if not (toks[i - 1].isspace() and toks[i + 1].isspace()):
                continue
            prev = toks[sig[k - 1]]
            if not (_IDENT.match(prev) or prev[:1].isdigit() or prev in (")", "]", '"') or prev.endswith('"')):
                continue
            if prev in ("op", "fn"):
                continue
            spots.append((i, fam))
        if not spots:
            return None
        i, fam = rng.choice(spots)
        toks = list(toks)
        pool = fam if rng.random() < 0.85 else [o for f in OP_FAMILIES[:4] for o in f]
        toks[i] = rng.choice([o for o in pool if o != toks[i]])
        return toks

    def _uses(self, toks, sig):
        out = []
        for k in range(1, len(sig) - 1):
            i = sig[k]
            if not _is_ident(toks[i]):
                continue
            prev, nxt = toks[sig[k - 1]], toks[sig[k + 1]]
            if prev in (".", "::", "fn", "var", "let", "const", "class", "struct", "enum",
                        "interface", "import", ":", "->", "type", "union", "@", "for") or nxt in (":", "::", "{"):
                continue
            if prev in ("=", "(", ",", "return", "[", "+", "-", "*", "/", "==", "!=", "<", ">",
                        "&&", "||", "+=", "-=", "!"):
                out.append((k, i))
        return out

    def m_expr(self, rng, toks):
        sig = self._sig(toks)
        uses = self._uses(toks, sig)
        if not uses:
            return None
        k, i = rng.choice(uses)
        toks = list(toks)
        names = [n for n in self._names(toks, sig) if n != toks[i]]
        fns = sorted({toks[sig[m + 1]] for m, x in enumerate(sig[:-1])
                      if toks[x] == "fn" and _is_ident(toks[sig[m + 1]])})
        r = rng.random()
        if r < 0.5:
            toks[i] = rng.choice(LITERALS)
        elif r < 0.75 and fns:
            toks[i] = rng.choice(fns) + "()"
        elif names:
            toks[i] = rng.choice(names)
        else:
            return None
        return toks

    def _items(self, lines: list[str], top: bool) -> list[tuple[int, int]]:
        """Line spans of declarations: at depth 0 (top) or inside a body."""
        spans, depth = [], 0
        decl = re.compile(r"^\s*((pub|priv|prot|static|const|inline|unsafe|eval|@\w+(\([^)]*\))?)\s+)*"
                          r"(fn|var|let|const|static|class|struct|enum|interface|union|extend|type|case)\b"
                          r"|^\s*[A-Za-z_]\w*\s*:")
        i = 0
        while i < len(lines):
            line = lines[i]
            code = re.sub(r'"(\\.|[^"\\])*"|//.*', "", line)
            want = depth == 0 if top else depth >= 1
            if want and decl.match(code) and not line.lstrip().startswith("//"):
                d, j = 0, i
                while j < len(lines):
                    c = re.sub(r'"(\\.|[^"\\])*"|//.*', "", lines[j])
                    d += c.count("{") - c.count("}")
                    if d <= 0 and (j > i or "{" not in c or d == 0):
                        break
                    j += 1
                if j < len(lines) and d <= 0:
                    spans.append((i, j))
            depth += code.count("{") - code.count("}")
            i += 1
        return spans

    def m_member(self, rng, toks):
        lines = "".join(toks).split("\n")
        spans = self._items(lines, top=False)
        if not spans:
            return None
        a, b = rng.choice(spans)
        if rng.random() < 0.5:
            lines[b + 1:b + 1] = lines[a:b + 1]
        else:
            del lines[a:b + 1]
        return tokenize("\n".join(lines))

    def m_clause(self, rng, toks):
        sig = self._sig(toks)
        spots = [k for k, i in enumerate(sig) if toks[i] in ("impl", "derives", "requires")]
        if not spots:
            return None
        k = rng.choice(spots)
        i = sig[k]
        toks = list(toks)
        # The clause runs to the next `{`, `>`, newline or `,` at depth 0.
        end, depth = k + 1, 0
        while end < len(sig):
            t = toks[sig[end]]
            if t in "([":
                depth += 1
            elif t in ")]":
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and (t in ("{", ">", ";", "where") or (t == "," and toks[i] != "requires")
                                 or "\n" in "".join(toks[sig[end - 1]:sig[end]])):
                break
            end += 1
        if end == k + 1:
            return None
        names = [m for m in range(k + 1, end) if _is_ident(toks[sig[m]])]
        r = rng.random()
        if r < 0.4 or not names:
            del toks[i:sig[end - 1] + 1]           # drop the whole clause
        elif r < 0.7:
            m = rng.choice(names)                 # duplicate one entry
            toks[sig[m] + 1:sig[m] + 1] = [", ", toks[sig[m]]]
        else:
            m = rng.choice(names)                 # point it at another name
            ifaces = [toks[sig[x + 1]] for x, y in enumerate(sig[:-1])
                      if toks[y] in ("interface", "class", "struct") and _is_ident(toks[sig[x + 1]])]
            toks[sig[m]] = rng.choice(ifaces or PRIMS)
        return toks

    def m_generic(self, rng, toks):
        sig = self._sig(toks)
        spots = []
        for k in range(len(sig) - 2):
            i = sig[k]
            if toks[i] in ("fn", "class", "struct") and _is_ident(toks[sig[k + 1]]):
                spots.append((k, "name"))
            if toks[i] in ("fn", "class", "struct", "interface") and toks[sig[k + 1]] == "<":
                spots.append((k, "pre"))
            if toks[i] in ("class", "struct", "interface", "fn") and _is_ident(toks[sig[k + 1]]) \
                    and toks[sig[k + 2]] == "<":
                spots.append((k + 1, "post"))
        if not spots:
            return None
        k, kind = rng.choice(spots)
        toks = list(toks)
        i = sig[k + 1]
        if kind == "name":
            # Make it generic: `fn <T> f(` (the spec's form) or `class C<T>`.
            if toks[sig[k]] == "fn":
                toks[i:i] = [rng.choice(["<T> ", "<T impl Copy> ", "<T, U> "])]
            else:
                toks[i + 1:i + 1] = [rng.choice(["<T>", "<T, U>"])]
            return toks
        if toks[i] != "<":
            return None
        e = _match(toks, i)
        if e is None:
            return None
        if rng.random() < 0.7:
            del toks[i:e + 1]                     # strip the generics
        else:
            toks[e:e] = [", Extra"]              # one more parameter
        return toks

    def _top_decls(self, idx: int) -> list[str]:
        if idx not in self._decls:
            lines = self.seeds[idx].text.split("\n")
            self._decls[idx] = ["\n".join(lines[a:b + 1]) for a, b in self._items(lines, top=True)
                                if b - a < 60 and not lines[a].lstrip().startswith(("import", "ffi"))]
        return self._decls[idx]

    def m_splice(self, rng, toks):
        for _ in range(8):
            decls = self._top_decls(rng.randrange(len(self.seeds)))
            if decls:
                break
        else:
            return None
        piece = rng.choice(decls)
        lines = "".join(toks).split("\n")
        tops = self._items(lines, top=True)
        at = rng.choice([b + 1 for _, b in tops] or [len(lines)])
        lines[at:at] = [piece]
        return tokenize("\n".join(lines))

    def m_rename(self, rng, toks):
        sig = self._sig(toks)
        idents = [i for i in sig if _is_ident(toks[i]) and toks[i] not in PRIMS]
        names = self._names(toks, sig)
        if not idents or len(names) < 2:
            return None
        i = rng.choice(idents)
        toks = list(toks)
        toks[i] = rng.choice([n for n in names if n != toks[i]])
        return toks

    def mutate(self, rng: random.Random, text: str, allowed: list[str]) -> tuple[str, list[str]] | None:
        toks = tokenize(text)
        applied = []
        for _ in range(rng.choice([1, 1, 1, 2])):
            for _attempt in range(6):
                name = rng.choice(allowed)
                got = self.ops[name](rng, toks)
                if got is not None and got != toks:
                    toks = got
                    applied.append(name)
                    break
        if not applied:
            return None
        return "".join(toks), applied


# --- Minimizer ---------------------------------------------------------------


def minimize(runner: Runner, text: str, seed: Seed, want: Finding, oracles: set[str], budget: int) -> str:
    """ddmin over lines, then over tokens, keeping the oracle AND its signature.

    Matching the signature stops a finding from being minimized into a
    different, shallower one; for accept the predicate also needs
    --type-check-only to stay clean, which evaluate() requires anyway.
    """
    nondet = want.oracle == "nondet"

    def still(cand: str) -> bool:
        nonlocal budget
        if budget <= 0 or not cand.strip():
            return False
        budget -= 1
        got = evaluate(runner, cand, seed, oracles, nondet)
        return any(g.oracle == want.oracle and g.signature == want.signature for g in got.findings)

    def ddmin(units: list[str], join) -> list[str]:
        n = 2
        while len(units) >= 2 and budget > 0:
            chunk = max(1, len(units) // n)
            progressed = False
            for i in range(0, len(units), chunk):
                cand = units[:i] + units[i + chunk:]
                if cand and still(join(cand)):
                    units, n, progressed = cand, max(n - 1, 2), True
                    break
            if not progressed:
                if chunk == 1:
                    break
                n = min(len(units), n * 2)
        return units

    lines = ddmin(text.split("\n"), "\n".join)
    text = "\n".join(lines)
    # Each unit is a token with the whitespace after it, so joining them
    # gives back the text exactly; a cut that fuses two neighbours is just a
    # candidate the predicate rejects. (Re-spacing every token would return
    # a text never tested when no cut succeeds: `op []=` is not `op [ ] =`.)
    units: list[str] = []
    for t in tokenize(text):
        if units and not (t.strip() and not t.startswith(("//", "/*"))):
            units[-1] += t
        else:
            units.append(t)
    units = ddmin(units, "".join)
    return "".join(units).rstrip() + "\n"


# --- Findings store ----------------------------------------------------------


class Store:
    def __init__(self, out: Path):
        self.out = out
        self.lock = threading.Lock()
        self.seen: dict[tuple[str, str], int] = {}
        self.pending: set[tuple[str, str]] = set()
        self.failed: dict[tuple[str, str], int] = {}
        self.dropped = 0
        for p in glob.glob(str(out / "*" / "*" / "signature.txt")):
            sp = Path(p)
            self.seen[(sp.parent.parent.name, sp.read_text())] = 0

    def dirof(self, f: Finding) -> Path:
        return self.out / f.oracle / hashlib.sha1(f.signature.encode()).hexdigest()[:10]

    def claim(self, f: Finding) -> str:
        """'new' the first time, 'sample' for a later hit, 'skip' otherwise."""
        key = (f.oracle, f.signature)
        with self.lock:
            if key in self.pending or self.failed.get(key, 0) >= 3:
                return "skip"
            if key in self.seen:
                self.seen[key] += 1
                return "sample" if self.seen[key] <= 3 else "skip"
            self.pending.add(key)
            return "new"

    def settle(self, f: Finding, confirmed: bool) -> Path | None:
        key = (f.oracle, f.signature)
        with self.lock:
            self.pending.discard(key)
            if not confirmed:
                self.failed[key] = self.failed.get(key, 0) + 1
                self.dropped += 1
                return None
            self.seen[key] = 0
            d = self.dirof(f)
            d.mkdir(parents=True, exist_ok=True)
            (d / "signature.txt").write_text(f.signature)
            return d


def confirm(runner: Runner, text: str, seed: Seed, f: Finding, oracles: set[str]) -> bool:
    """Three in a row. A nondet hit needs a disagreement in each of three
    rounds of up to four tries: a race that shows once is the line-index
    race class, not a finding until it shows again."""
    for _ in range(3):
        tries = 4 if f.oracle == "nondet" else 1
        if not any(any(g.oracle == f.oracle and g.signature == f.signature
                       for g in evaluate(runner, text, seed, oracles, f.oracle == "nondet").findings)
                   for _ in range(tries)):
            return False
    return True


_README = {
    "accept": "--type-check-only accepts this program, but compiling it through C++ fails",
    "crash": "the compiler dies by a signal or an unexpected exit code",
    "hang": "the compiler does not finish within the timeout",
    "ice": "the compiler reports an internal compiler error",
    "nondet": "--sema-threads=1 and --sema-threads=4 report different diagnostics",
    "invariant": "a diagnostic contract breaks (exit status, location or a repeated error)",
    "kals": "the language server and --type-check-only disagree on the diagnostics",
}


def write_repro(d: Path, runner: Runner, seed: Seed, f: Finding) -> None:
    q = shlex.quote
    tc = '"$KAIRO" ' + " ".join(q(w) for w in runner.tc_cmd(seed)[1:])
    cg = '"$KAIRO" ' + " ".join(q(w) for w in runner.cg_cmd(seed, '"$t/cache"')[1:]).replace(
        q('--cache-dir="$t/cache"'), '--cache-dir="$t/cache"')
    name = q(seed.name)
    body = [
        "#!/bin/sh",
        f"# {f.oracle}: {_README[f.oracle]}.",
        "# Usage: ./repro.sh [file.k]   (default min.k; exit 1 when the finding reproduces)",
        "# The input is compiled under its seed's file name, in a directory of its own.",
        "# KAIRO=/path/to/kairo ./repro.sh checks another compiler.",
        f"KAIRO=${{KAIRO:-{q(str(runner.kairo))}}}",
        'here=$(cd "$(dirname "$0")" && pwd)',
        'src=$(cd "$(dirname "${1:-$here/min.k}")" && pwd)/$(basename "${1:-min.k}")',
        't=$(mktemp -d)',
        "trap 'rm -rf \"$t\"' EXIT",
        f'cp "$src" "$t"/{name}',
        'cd "$t"',
        f"{tc} > tc.txt 2>&1; tc=$?",
        "cat tc.txt",
    ]
    if f.oracle == "nondet":
        body += [
            "i=0; while [ $i -lt 8 ]; do i=$((i+1))",
            f"  {tc} --sema-threads=4 2>&1 | sort > a.txt",
            f"  {tc} --sema-threads=1 2>&1 | sort > b.txt",
            '  if ! cmp -s a.txt b.txt; then diff a.txt b.txt; echo "REPRODUCED (try $i)"; exit 1; fi',
            "done",
            'echo "not reproduced in 8 tries"; exit 0',
        ]
    elif f.oracle != "accept":
        body += [
            f"# Signature: {f.signature.splitlines()[0]}",
            'case $tc in 0|1) ;; *) echo "REPRODUCED: type-check-only exit $tc"; exit 1;; esac',
            "grep -qE '\\[(I002|I003|I011|I102)[A-Z]\\]' tc.txt && { echo 'REPRODUCED: ICE in type-check-only'; exit 1; }",
        ]
        if f.signature.startswith("cg "):
            body += [
                f"{cg} > cg.txt 2>&1; cg=$?",
                "cat cg.txt",
                'case $cg in 0|1) ;; *) echo "REPRODUCED: compile exit $cg"; exit 1;; esac',
                "grep -qE '\\[(I002|I003|I011|I102)[A-Z]\\]' cg.txt && { echo 'REPRODUCED: ICE in the compile'; exit 1; }",
            ]
        body += ['echo "not reproduced (an invariant or kals finding: compare the output with out.txt)"; exit 0']
    else:
        body += [
            "if grep -qE ' (error|fatal error|fatal) \\[' tc.txt; then echo 'type-check-only reports an error: not reproduced'; exit 0; fi",
            f"{cg} > cg.txt 2>&1; cg=$?",
            "cat cg.txt",
            'case $cg in 0) echo "compile clean: not reproduced"; exit 0;; 1) ;; *) echo "REPRODUCED: compile exit $cg"; exit 1;; esac',
            "grep -qE ' (error|fatal error|fatal) \\[' cg.txt && { echo 'REPRODUCED: type-check-only is clean, the compile fails'; exit 1; }",
            'echo "exit 1 without an error line: REPRODUCED"; exit 1',
        ]
    (d / "repro.sh").write_text("\n".join(body) + "\n")
    os.chmod(d / "repro.sh", 0o755)


def save(d: Path, runner: Runner, text: str, seed: Seed, o: Outcome, f: Finding, oracles: set[str],
         min_budget: int, mutations: list[str]) -> None:
    (d / "orig.k").write_text(text, encoding="utf-8", errors="surrogateescape")
    (d / "out.txt").write_text(f"detail: {f.detail}\nseed: {seed.rel}\nflags: {' '.join(seed.flags)}\n"
                               f"mutations: {', '.join(mutations) or 'none (the seed itself)'}\n\n"
                               + o.transcript())
    write_repro(d, runner, seed, f)
    m = minimize(runner, text, seed, f, oracles, min_budget) if min_budget > 0 else text
    (d / "min.k").write_text(m, encoding="utf-8", errors="surrogateescape")
    (d / "README").write_text(f"{_README[f.oracle]}: {f.signature.splitlines()[0]} "
                              f"(seed {seed.rel}{', mutated: ' + '+'.join(mutations) if mutations else ''})\n")
    (d / "seed.json").write_text(json.dumps({"seed": seed.rel, "name": seed.name, "dir": str(seed.dir),
                                             "flags": seed.flags, "inputs": [str(p) for p in seed.inputs],
                                             "mutations": mutations}, indent=1))


def save_sample(d: Path, text: str, seed: Seed, mutations: list[str]) -> None:
    s = d / "samples"
    s.mkdir(exist_ok=True)
    n = len(list(s.glob("*.k"))) + 1
    if n > 3:
        return
    (s / f"sample{n}.k").write_text(f"// seed: {seed.rel} mutations: {'+'.join(mutations) or 'none'}\n" + text,
                                    encoding="utf-8", errors="surrogateescape")


# --- Main loop ---------------------------------------------------------------


def find_kairo(arg: str | None) -> Path:
    if arg:
        return Path(arg).resolve()
    if os.environ.get("KAIRO_BIN"):
        return Path(os.environ["KAIRO_BIN"]).resolve()
    # Release by default, as lit; a worktree has none, so also the main
    # checkout's (the git common dir's parent).
    roots = [ROOT]
    try:
        common = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--git-common-dir"],
                                capture_output=True, text=True).stdout.strip()
        if common:
            roots.append((ROOT / common).resolve().parent)
    except OSError:
        pass
    hits = [h for r in roots for h in sorted(glob.glob(str(r / "build" / "*" / "release" / "bin" / "kairo")))]
    # Cross builds sit beside the host's; only one of this machine's arch runs.
    import platform
    host = f"{platform.machine()}-{sys.platform.rstrip('0123456789')}"
    hits = [h for h in hits if f"/build/{host}-" in h.replace(os.sep, "/")] or hits
    if not hits:
        sys.exit("sema_fuzz: no build/<triple>/release/bin/kairo; pass --kairo or KAIRO_BIN")
    return Path(max(hits, key=os.path.getmtime))  # the newest, as lit picks


def bin_key(p: Path) -> str:
    st = p.stat()
    return hashlib.sha1(f"{p.resolve()}|{st.st_mtime_ns}|{st.st_size}".encode()).hexdigest()[:16]


class SeedCache:
    """Per-binary record of seed outcomes: clean ones are not run again."""

    def __init__(self, out: Path, kairo: Path, oracles: set[str], enabled: bool):
        self.path = out / ".cache" / f"seeds-{bin_key(kairo)}.json"
        self.lock = threading.Lock()
        self.data: dict[str, dict] = {}
        self.enabled = enabled
        self.oracles = ",".join(sorted(oracles))
        if self.path.is_file():
            try:
                self.data = json.loads(self.path.read_text())
            except ValueError:
                self.data = {}

    def key(self, seed: Seed) -> str:
        return hashlib.sha1((seed.text + "\0" + " ".join(seed.flags) + "\0" + self.oracles)
                            .encode("utf-8", "surrogateescape")).hexdigest()

    def get(self, seed: Seed) -> dict | None:
        return self.data.get(self.key(seed)) if self.enabled else None

    def tc_clean(self, seed: Seed) -> bool | None:
        got = self.data.get(self.key(seed))
        return None if got is None else got.get("tc_clean")

    def put(self, seed: Seed, rec: dict) -> None:
        with self.lock:
            self.data[self.key(seed)] = rec

    def flush(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.lock:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data))
            tmp.replace(self.path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kairo", help="compiler binary (default: build/<triple>/release/bin/kairo)")
    ap.add_argument("--kals", help="language server for the kals oracle (default: beside --kairo)")
    ap.add_argument("--corpus", default=str(ROOT / "Tests"), help="seed directory (default: Tests/)")
    ap.add_argument("--filter", help="only seeds whose path under the corpus matches this regex or glob")
    ap.add_argument("--grep", help="only seeds whose text matches this regex (e.g. '^\\s*interface ')")
    ap.add_argument("--out", default=str(ROOT / "private" / "fuzz" / "sema"), help="findings directory")
    ap.add_argument("-j", "--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=float, default=60.0, help="per-command seconds before 'hang'")
    ap.add_argument("--time", type=float, default=0, help="stop after N seconds (0 = until ^C)")
    ap.add_argument("--iterations", type=int, default=0, help="stop after N mutants (0 = no limit)")
    ap.add_argument("--seed", type=int, default=None, help="RNG seed for a reproducible run")
    ap.add_argument("--oracles", default=",".join(DEFAULT_ORACLES),
                    help=f"comma-separated subset of {','.join(ALL_ORACLES)} (default: all but kals)")
    ap.add_argument("--mutations", default="", help="comma-separated mutation names (default: all)")
    ap.add_argument("--nondet-every", type=int, default=4,
                    help="run the nondet pair on every Nth mutant (0 = off; seeds always)")
    ap.add_argument("--min-budget", type=int, default=300, help="max evaluations per minimization")
    ap.add_argument("--seeds-only", action="store_true", help="run each seed once, unmutated, and stop")
    ap.add_argument("--no-cache", action="store_true", help="run seeds even if clean under this binary")
    ap.add_argument("--repro", metavar="FILE", help="classify one file and exit")
    ap.add_argument("--as", dest="as_name", help="with --repro: compile the file under this name")
    ap.add_argument("-I", dest="incdir", help="with --repro: the seed directory (sibling imports)")
    ap.add_argument("kairo_args", nargs="*", help="extra compiler flags, after --")
    a = ap.parse_args()

    oracles = {o for o in a.oracles.split(",") if o}
    bad = oracles - set(ALL_ORACLES)
    if bad:
        sys.exit(f"sema_fuzz: unknown oracle(s) {', '.join(sorted(bad))}")
    out = Path(a.out).resolve()
    kairo = find_kairo(a.kairo)
    if not kairo.is_file():
        sys.exit(f"sema_fuzz: {kairo} does not exist")
    runner = Runner(kairo, a.timeout, out / ".work", a.kairo_args)
    kals = None
    if "kals" in oracles:
        # The server finds the nearest project file (kairo_compile.json) above
        # a file it opens, so its files live outside any Kairo tree.
        runner.work = Path(tempfile.mkdtemp(prefix="ksf-kals-"))
        kp = Path(a.kals) if a.kals else kairo.parent / "kals"
        if not kp.is_file():
            sys.exit(f"sema_fuzz: no language server at {kp}")
        kals = KalsPool(kp, a.timeout, runner.work)

    if a.repro:
        p = Path(a.repro).resolve()
        name = a.as_name or p.name
        sdir = Path(a.incdir).resolve() if a.incdir else p.parent
        seed = Seed(sdir / name, name, p.read_text(encoding="utf-8", errors="surrogateescape"),
                    [], [], False, "-fduck-generics" in a.kairo_args, None)
        o = evaluate(runner, seed.text, seed, oracles, True, kals)
        print(o.transcript())
        for f in o.findings:
            print(f"[{f.oracle}] {f.detail}\n  sig: {f.signature!r}")
        print(f"{len(o.findings)} finding(s)")
        if kals:
            kals.shutdown()
            shutil.rmtree(runner.work, ignore_errors=True)
        return 1 if o.findings else 0

    seeds, skipped = load_seeds(Path(a.corpus).resolve(), a.filter, a.grep)
    runnable = [s for s in seeds if s.skip is None]
    for s in seeds:
        if s.skip:
            skipped[s.skip] = skipped.get(s.skip, 0) + 1
    if not runnable:
        sys.exit(f"sema_fuzz: no runnable seeds under {a.corpus}")
    rng_seed = a.seed if a.seed is not None else random.randrange(1 << 32)
    store = Store(out)
    cache = SeedCache(out, kairo, oracles, not a.no_cache)
    mut = Mutator(runnable, rng_seed)
    allowed = [m for m in a.mutations.split(",") if m] or list(mut.ops)
    unknown = set(allowed) - set(mut.ops)
    if unknown:
        sys.exit(f"sema_fuzz: unknown mutation(s) {', '.join(sorted(unknown))}; have {', '.join(mut.ops)}")
    print(f"kairo   {kairo}\nseeds   {len(runnable)} runnable from {a.corpus}"
          f"{' (filter ' + a.filter + ')' if a.filter else ''}\nrng     --seed {rng_seed}\n"
          f"out     {out}\njobs    {a.jobs}\noracles {','.join(sorted(oracles))}", flush=True)
    if not a.seeds_only:
        print(f"mutate  {','.join(allowed)}", flush=True)

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    slock = threading.Lock()
    stats: dict = {"runs": 0, "new": 0, "tc_clean": 0, "cg": 0, "cached": 0, "duck": 0,
                   "xfail_hits": 0, "expected_by_test": 0, "per_oracle": {}, "seed_hits": {}, "mut": {}}
    t_start = time.monotonic()

    def bump(path: list[str], n: int = 1) -> None:
        with slock:
            d = stats
            for k in path[:-1]:
                d = d.setdefault(k, {})
            d[path[-1]] = d.get(path[-1], 0) + n

    def handle(text: str, seed: Seed, o: Outcome, mutations: list[str]) -> None:
        for f in o.findings:
            if seed.xfail:
                bump(["xfail_hits"])
                continue
            if seed.expected(f, o.transcript()):
                bump(["expected_by_test"])
                continue
            bump(["per_oracle", f.oracle])
            if a.seeds_only:
                with slock:
                    stats["seed_hits"].setdefault(f.oracle, []).append(seed.rel)
            got = store.claim(f)
            if got == "sample":
                save_sample(store.dirof(f), text, seed, mutations)
                continue
            if got != "new":
                continue
            ok = confirm(runner, text, seed, f, oracles)
            d = store.settle(f, ok)
            if d is None:
                print(f"\ndropped [{f.oracle}] (did not reproduce 3 times): {f.signature.splitlines()[0][:120]}",
                      flush=True)
                continue
            bump(["new"])
            print(f"\nNEW [{f.oracle}] {d.relative_to(out)}: {f.signature.splitlines()[0][:150]} "
                  f"(seed {seed.rel})", flush=True)
            save(d, runner, text, seed, o, f, oracles, a.min_budget, mutations)

    # Clean seeds are drawn four times as often: they give accept the most.
    # An XFAIL seed is a known failure on record: its mutants rediscover it.
    weights = []
    for s in runnable:
        c = cache.tc_clean(s)
        weights.append(0.0 if s.xfail else 4.0 if c else (1.0 if c is False else 2.0))
    if not a.seeds_only and not any(weights):
        sys.exit("sema_fuzz: every selected seed is XFAIL")

    def one(idx: int) -> None:
        if stop.is_set():
            return
        if a.seeds_only:
            seed = runnable[idx]
            hit = cache.get(seed)
            if hit is not None and not hit.get("findings"):
                bump(["cached"])
                bump(["runs"])
                if hit.get("tc_clean"):
                    bump(["tc_clean"])
                return
            o = evaluate(runner, seed.text, seed, oracles, True, kals)
            text, mutations = seed.text, []
        else:
            rng = random.Random(rng_seed * 1_000_003 + idx)
            seed = rng.choices(runnable, weights)[0]
            got = mut.mutate(rng, seed.text, allowed)
            if got is None:
                bump(["mut", "(none applicable)"])
                return
            text, mutations = got
            nd = a.nondet_every > 0 and idx % a.nondet_every == 0
            o = evaluate(runner, text, seed, oracles, nd, kals)
            for m in set(mutations):
                bump(["mut", m, "applied"])
                if o.tc_clean:
                    bump(["mut", m, "tc_clean"])
                if o.findings:
                    bump(["mut", m, "findings"])
        bump(["runs"])
        if o.tc_clean:
            bump(["tc_clean"])
        if o.cg is not None:
            bump(["cg"])
        if o.notes:
            bump(["duck"])
        if a.seeds_only:
            cache.put(seed, {"tc_clean": o.tc_clean, "findings": [f.oracle for f in o.findings],
                             "tc_rc": o.tc.rc if o.tc else None})
        handle(text, seed, o, mutations)

    total = len(runnable) if a.seeds_only else (a.iterations or None)
    idx = 0
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        pending: set[cf.Future] = set()
        last = 0.0
        while not stop.is_set():
            if total is not None and idx >= total and not pending:
                break
            if a.time and time.monotonic() - t_start > a.time:
                break
            while len(pending) < a.jobs * 2 and (total is None or idx < total):
                pending.add(ex.submit(one, idx))
                idx += 1
            done, pending = cf.wait(pending, timeout=0.5, return_when=cf.FIRST_COMPLETED)
            for fu in done:
                if fu.exception():
                    print(f"\nsema_fuzz: worker error: {fu.exception()!r}", file=sys.stderr)
            now = time.monotonic()
            if now - last > 5:
                last = now
                el = now - t_start
                if a.seeds_only:
                    cache.flush()
                print(f"\r{stats['runs']} runs  {stats['runs'] / max(el, 1e-9):.1f}/s  "
                      f"{stats['tc_clean']} tc-clean  {stats['new']} new  {len(store.seen)} unique  "
                      f"{el:.0f}s", end="", flush=True)
        stop.set()  # a --time stop: queued work returns at once
        cf.wait(pending)
    if a.seeds_only:
        cache.flush()
    if kals:
        kals.shutdown()
    shutil.rmtree(runner.work, ignore_errors=True)

    el = time.monotonic() - t_start
    summary = {
        "kairo": str(kairo), "seed": rng_seed, "mode": "seeds-only" if a.seeds_only else "mutate",
        "wall_s": round(el, 1), "seeds_runnable": len(runnable), "skipped": skipped,
        "runs": stats["runs"], "cached_clean": stats["cached"], "tc_clean": stats["tc_clean"],
        "compiled": stats["cg"], "duck_generics_cl": stats["duck"], "xfail_seed_hits": stats["xfail_hits"],
        "accept_expected_by_test": stats["expected_by_test"],
        "hits_per_oracle": stats["per_oracle"], "new_signatures": stats["new"],
        "dropped_unreproducible": store.dropped, "unique_signatures": len(store.seen),
        "mutations": stats["mut"], "seed_hits": stats["seed_hits"],
        "hits_per_signature": {f"{o}/{store.dirof(Finding(o, sig, '')).name}": n + 1
                               for (o, sig), n in store.seen.items()},
    }
    (out / "runs").mkdir(parents=True, exist_ok=True)
    (out / "runs" / f"{time.strftime('%Y%m%d-%H%M%S')}-{summary['mode']}.json").write_text(
        json.dumps(summary, indent=1))
    print(f"\n{stats['runs']} runs in {el:.0f}s ({stats['tc_clean']} type-check clean, "
          f"{stats['cg']} compiled), {stats['new']} new signature(s), {store.dropped} dropped as "
          f"unreproducible, {len(store.seen)} unique total; rerun with --seed {rng_seed}")
    print("skipped: " + ", ".join(f"{k}: {v}" for k, v in sorted(skipped.items())))
    print("hits per oracle: " + (", ".join(f"{k}: {v}" for k, v in sorted(stats["per_oracle"].items())) or "none"))
    if stats["mut"]:
        for m, v in sorted(stats["mut"].items()):
            print(f"  {m:12} {v}")
    return 1 if stats["new"] else 0


if __name__ == "__main__":
    sys.exit(main())
