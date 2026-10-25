#!/usr/bin/env python3
"""Out-of-process fuzzer for the Stage 1 front end, up to the end of parse.

Drives `kairo --syntax-only` over token-level mutations of the Stage 1 seed
corpus (every .k under Tests/ -- NOT Compiler/ or Lib/, which are Stage 0
syntax and would mostly exercise the lexer's rejection paths).

WHY TOKEN-LEVEL: byte-level noise dies at the lexer (S072E invalid UTF-8) and
never reaches the parser. Splicing whole tokens keeps inputs lexically valid
so the mutations land in the grammar and, above all, in error recovery.

Oracles, in order of how much a hit means:
  crash     exit by signal, or an exit code that is neither 0 nor 1
  hang      exceeded --timeout
  ice       any I-category diagnostic (e.g. I002F) -- an internal error
  invariant a diagnostic contract broke:
              - exit status disagrees with whether an error was reported
              - a location outside the input file (line/col 0, past EOF)
  nondet    --threads=1 and --threads=0 disagree on the same input

Findings land in <out>/<oracle>/<signature>/ with the original input, the
minimized input, the compiler output and a repro.sh. One directory per
signature, so a bug found ten thousand times is still one directory.

Usage:
  Scripts/parser_fuzz.py                       # run until ^C
  Scripts/parser_fuzz.py --time 600 -j 16
  Scripts/parser_fuzz.py --seeds-only          # just run the corpus once
  Scripts/parser_fuzz.py --repro FILE          # classify one file
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import dataclasses
import glob
import hashlib
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --- Seed preparation --------------------------------------------------------

# Lit plumbing is comments to the lexer, so it costs nothing to keep, except
# that every byte of it is a byte the mutator wastes a draw on.
_LIT_LINE = re.compile(
    r"^\s*//\s*(RUN|REQUIRES|UNSUPPORTED|XFAIL|EXPECT-ERROR|BEGIN-GENERATED-CHECKS|"
    r"END-GENERATED-CHECKS|[A-Z][A-Z0-9_-]*:)"
)


def strip_lit(text: str) -> str:
    return "\n".join(l for l in text.splitlines() if not _LIT_LINE.match(l)) + "\n"


def load_seeds(corpus: Path) -> list[str]:
    seeds, seen = [], set()
    for p in sorted(corpus.rglob("*.k")):
        try:
            t = strip_lit(p.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        h = hashlib.sha1(t.encode()).digest()
        if t.strip() and h not in seen:
            seen.add(h)
            seeds.append(t)
    return seeds


# --- Tokenizer ---------------------------------------------------------------
# Approximate on purpose: it only has to cut text at boundaries the real lexer
# would also cut at. A token it gets wrong just becomes an odd mutation.

_PUNCT = sorted(
    "<<= >>= ... ..= :: -> => == != <= >= && || << >> += -= *= /= %= &= |= ^= "
    ".. ?? ?. ++ --".split(),
    key=len, reverse=True,
)
_TOKEN = re.compile(
    r"(?P<ws>\s+)"
    r"|(?P<comment>//[^\n]*|/\*.*?\*/)"
    r'|(?P<str>[A-Za-z]{0,2}"(?:\\.|[^"\\\n])*"?)'
    r"|(?P<chr>'(?:\\.|[^'\\\n])')"
    r"|(?P<num>0[xXbBoO][0-9a-fA-F_]+[A-Za-z0-9_]*|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?[A-Za-z0-9_]*)"
    r"|(?P<ident>[A-Za-z_][A-Za-z0-9_]*!?)"
    r"|(?P<punct>" + "|".join(re.escape(p) for p in _PUNCT) + r"|.)",
    re.S,
)


def tokenize(text: str) -> list[str]:
    return [m.group(0) for m in _TOKEN.finditer(text)]


def significant(toks: list[str]) -> list[int]:
    return [i for i, t in enumerate(toks) if t.strip() and not t.startswith(("//", "/*"))]


# --- Mutator -----------------------------------------------------------------

PAIRS = [("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")]
# Depth caps are 256 (scope) and 512 (expr); straddle both, and go well past
# them, because the interesting bugs are in what happens AT the cap.
DEPTHS = [1, 2, 8, 64, 255, 256, 257, 511, 512, 513, 2000]


class Mutator:
    def __init__(self, seeds: list[str], rng: random.Random):
        self.rng = rng
        self.seed_toks = [tokenize(s) for s in seeds]
        vocab: dict[str, int] = {}
        for toks in self.seed_toks:
            for t in toks:
                if t.strip() and len(t) <= 24 and not t.startswith(("//", "/*")):
                    vocab[t] = vocab.get(t, 0) + 1
        # Frequency-ranked so keywords and operators dominate, with a long
        # tail of rarer identifiers and literals kept for variety.
        self.dict = [t for t, _ in sorted(vocab.items(), key=lambda kv: -kv[1])][:4000]

    def _span(self, sig: list[int]) -> tuple[int, int]:
        a = self.rng.randrange(len(sig))
        n = min(len(sig) - a, self.rng.choice([1, 1, 2, 3, 5, 8, 20]))
        return sig[a], sig[a + n - 1] + 1

    def _word(self) -> str:
        r = self.rng.random()
        return self.dict[int(len(self.dict) * r * r * r)]

    def mutate(self, toks: list[str]) -> list[str]:
        toks = list(toks)
        for _ in range(self.rng.choice([1, 1, 1, 2, 3, 6])):
            sig = significant(toks)
            if not sig:
                toks = [self._word()]
                continue
            op = self.rng.randrange(10)
            a, b = self._span(sig)
            if op == 0:  # delete span
                del toks[a:b]
            elif op == 1:  # duplicate span
                toks[b:b] = [" "] + toks[a:b]
            elif op == 2:  # replace token with a dictionary word
                toks[a] = self._word()
            elif op == 3:  # insert dictionary word
                toks[a:a] = [self._word(), " "]
            elif op == 4:  # splice a span from another seed
                other = self.rng.choice(self.seed_toks)
                osig = significant(other)
                if osig:
                    c = self.rng.randrange(len(osig))
                    d = min(len(osig) - 1, c + self.rng.choice([1, 4, 16, 64]))
                    toks[a:a] = [" "] + other[osig[c] : osig[d] + 1] + [" "]
            elif op == 5:  # swap two spans
                c, d = self._span(sig)
                if b <= c:
                    toks[a:d] = toks[c:d] + toks[b:c] + toks[a:b]
            elif op == 6:  # wrap a span in a balanced pair, possibly deep
                o, c = self.rng.choice(PAIRS)
                n = self.rng.choice(DEPTHS)
                toks[a:b] = [o * n] + toks[a:b] + [c * n]
            elif op == 7:  # lone bracket: unbalanced input stresses sync
                toks[a:a] = [self.rng.choice("()[]{}<>")]
            elif op == 8:  # truncate: EOF mid-construct
                del toks[a:]
            else:  # repeat a span many times (long lists, long chains)
                toks[b:b] = (toks[a:b] + [" "]) * self.rng.choice([2, 16, 300])
        return toks


# --- Running the compiler ----------------------------------------------------

_DIAG = re.compile(
    r"^(?P<file>[^\n:]+):(?P<line>\d+):(?P<col>\d+): "
    r"(?P<sev>fatal error|error|warning|note|remark|fatal)\b[^\[\n]*\[(?P<code>[A-Z]+\d+[A-Z])\]",
    re.M,
)
# Any error line, located or not: I957E and driver errors carry no file:line.
_ERROR_LINE = re.compile(r"^(?:[^\n]*?: )?(?:fatal error|error|fatal)\b[^\[\n]*\[[A-Z]+\d+[A-Z]\]", re.M)
# NOT every I code: I957 (error limit), I006 (stage aborted) and friends are
# bookkeeping a parser emits on ordinary bad input. These four are the ones
# whose own text says "compiler bug" or "invariant" (Internal.diag.toml).
ICE_CODES = {"I002", "I003", "I011", "I102"}
_ICE_CODE = re.compile(r"\[(" + "|".join(sorted(ICE_CODES)) + r")[A-Z]\]")

INPUT_NAME = "fuzz.k"


@dataclasses.dataclass
class Result:
    rc: int | None  # None = timeout
    out: str
    secs: float


@dataclasses.dataclass
class Finding:
    oracle: str
    signature: str
    detail: str


class Runner:
    def __init__(self, kairo: Path, timeout: float, extra: list[str]):
        self.kairo = kairo
        self.timeout = timeout
        lib = ROOT / "Lib"
        # Same roots lit hands %kairo: without --builtins-dir every lang item
        # is unbound and the output is an R-category cascade, not a parse.
        self.base = [str(kairo), "--syntax-only", "--error-format=basic",
                     f"--builtins-dir={lib / 'builtin'}", f"--std-dir={lib / 'std'}"] + extra

    def run(self, text: str, flags: list[str] = (), timeout: float | None = None) -> Result:
        # A private cwd per run: seeds import siblings by relative path, and
        # nothing a mutated import names should resolve to a real file.
        with tempfile.TemporaryDirectory(prefix="kfuzz-") as d:
            Path(d, INPUT_NAME).write_text(text, encoding="utf-8", errors="surrogateescape")
            t0 = time.monotonic()
            try:
                p = subprocess.run(self.base + list(flags) + [INPUT_NAME], cwd=d,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=timeout or self.timeout,
                                   start_new_session=True)
                return Result(p.returncode, self._scrub(p.stdout, d), time.monotonic() - t0)
            except subprocess.TimeoutExpired as e:
                return Result(None, self._scrub(e.stdout or b"", d), time.monotonic() - t0)

    @staticmethod
    def _scrub(raw: bytes, d: str) -> str:
        # The driver prints the input's absolute path, and every run has its
        # own temp dir; left in, no two runs ever compare equal (nondet).
        out = raw.decode("utf-8", "replace")
        for p in {os.path.realpath(d), d}:
            out = out.replace(p + os.sep, "")
        return out


def _norm(s: str) -> str:
    # Signatures must survive the minimizer changing every line/col and
    # every identifier in the message.
    s = re.sub(r"0x[0-9a-fA-F]+", "0x", s)
    s = re.sub(r"\d+", "N", s)
    s = re.sub(r"'[^'\n]*'", "'_'", s)
    return s.strip()


_FRAME = re.compile(r"^\s*#\d+\s+0x[0-9a-fA-F]+\s+(.*)$", re.M)
# LLVM's handler frames sit on top of EVERY crash; keying on them folded all
# segfaults into one signature.
_HANDLER = re.compile(r"PrintStackTrace|RunSignalHandlers|SignalHandler|libc\.so|"
                      r"__restore_rt|\babort\b|\braise\b|__assert|libLLVM")


def _frame_key(f: str) -> str:
    f = re.sub(r"kairo::_\$M_\S*?\$::", "", f)     # mangled module prefix
    f = re.sub(r"<[^<>]*(?:<[^<>]*>[^<>]*)*>", "", f)  # template args
    name = re.split(r"\(|\s", f, maxsplit=1)[0]
    where = re.search(r"([\w.]+\.(?:k|hh|h|cpp|cc)):", f)
    return f"{name}@{where.group(1)}" if where else name


def _crash_sig(out: str) -> str:
    frames = [m.group(1) for m in _FRAME.finditer(out)]
    frames = [f for f in frames if not _HANDLER.search(f)]
    if frames:
        return "\n".join(_frame_key(f) for f in frames[:3])
    # No backtrace: the last lines are where an assert/abort message sits.
    return _norm("\n".join(out.splitlines()[-3:]))[:400]


def classify(text: str, r: Result) -> list[Finding]:
    f: list[Finding] = []
    if r.rc is None:
        return [Finding("hang", "timeout", f"no exit after {r.secs:.1f}s")]
    if r.rc < 0 or r.rc not in (0, 1):
        sig = f"rc={r.rc}\n" + _crash_sig(r.out)
        return [Finding("crash", sig, f"exit {r.rc}")]

    ices = sorted(set(_ICE_CODE.findall(r.out)))
    if ices:
        line = next(l for l in r.out.splitlines() if _ICE_CODE.search(l))
        msg = line.split("]:", 1)[-1]
        f.append(Finding("ice", f"{','.join(ices)} {_norm(msg)}", line.strip()))

    diags = list(_DIAG.finditer(r.out))
    has_error = _ERROR_LINE.search(r.out) is not None
    if (r.rc == 1) != has_error:
        # A nonzero exit with no error line is legitimate only if the output
        # explains itself some other way; report it and let triage decide.
        f.append(Finding("invariant", f"rc={r.rc} has_error={has_error}",
                         "exit status disagrees with reported errors"))

    lines = text.split("\n")
    for m in diags:
        if os.path.basename(m["file"]) != INPUT_NAME:
            continue
        ln, col = int(m["line"]), int(m["col"])
        bad = ln < 1 or col < 1 or ln > len(lines) + 1
        # +2: one past the last char is a valid caret (EOF, missing token).
        if not bad and ln <= len(lines):
            bad = col > len(lines[ln - 1].encode("utf-8", "surrogateescape")) + 2
        if bad:
            f.append(Finding("invariant", f"loc-out-of-range {m['code']}",
                             f"{m.group(0)}  (file has {len(lines)} lines)"))
            break
    return f


# --- Minimizer ---------------------------------------------------------------


def minimize(runner: Runner, text: str, want: Finding, flags: list[str], budget: int) -> str:
    """ddmin over significant tokens, keeping the oracle AND its signature.

    Matching the signature, not just the oracle, is what stops a crash from
    being 'minimized' into a different, shallower crash.
    """
    # Each step that still hangs costs a full timeout, so a 400-step ddmin of
    # a hang ran for minutes. A cut-down input still past 3s under
    # --syntax-only is not slow, it is the same loop.
    tmo = min(runner.timeout, 3.0) if want.oracle == "hang" else None
    toks = tokenize(text)
    # Glue each run of whitespace/comments onto the token before it, so
    # removing a chunk never fuses two neighbours into one token.
    units: list[str] = []
    for t in toks:
        if units and not (t.strip() and not t.startswith(("//", "/*"))):
            units[-1] += t
        else:
            units.append(t)

    def still(us: list[str]) -> bool:
        nonlocal budget
        if budget <= 0:
            return False
        budget -= 1
        cand = "".join(u if u[-1:].isspace() else u + " " for u in us)
        got = classify(cand, runner.run(cand, flags, tmo))
        return any(g.oracle == want.oracle and g.signature == want.signature for g in got)

    n = 2
    while len(units) >= 2 and budget > 0:
        chunk = max(1, len(units) // n)
        progressed = False
        for i in range(0, len(units), chunk):
            cand = units[:i] + units[i + chunk:]
            if cand and still(cand):
                units, n, progressed = cand, max(n - 1, 2), True
                break
        if not progressed:
            if chunk == 1:
                break
            n = min(len(units), n * 2)
    return "".join(u if u[-1:].isspace() else u + " " for u in units)


# --- Findings store ----------------------------------------------------------


class Store:
    def __init__(self, out: Path):
        self.out = out
        self.lock = threading.Lock()
        self.seen: dict[tuple[str, str], int] = {}
        for p in glob.glob(str(out / "*" / "*" / "signature.txt")):
            sp = Path(p)
            self.seen[(sp.parent.parent.name, sp.read_text())] = 0

    def claim(self, f: Finding) -> Path | None:
        """Returns a fresh directory the first time a signature is seen."""
        key = (f.oracle, f.signature)
        with self.lock:
            first = key not in self.seen
            self.seen[key] = self.seen.get(key, 0) + 1
            if not first:
                return None
            h = hashlib.sha1(f.signature.encode()).hexdigest()[:10]
            d = self.out / f.oracle / h
            d.mkdir(parents=True, exist_ok=True)
            (d / "signature.txt").write_text(f.signature)
            return d


def save(d: Path, runner: Runner, text: str, r: Result, f: Finding, flags: list[str],
         min_budget: int) -> None:
    (d / "input.k").write_text(text, encoding="utf-8", errors="surrogateescape")
    (d / "output.txt").write_text(r.out)
    (d / "detail.txt").write_text(f.detail + "\n")
    if min_budget > 0 and f.oracle != "nondet":
        m = minimize(runner, text, f, flags, min_budget)
        (d / "min.k").write_text(m, encoding="utf-8", errors="surrogateescape")
    cmd = " ".join(runner.base[1:] + flags)
    (d / "repro.sh").write_text(
        "#!/bin/sh\n# cd here, then run.\n"
        f"exec {runner.kairo} {cmd} \"${{1:-min.k}}\"\n")
    os.chmod(d / "repro.sh", 0o755)


# --- Main loop ---------------------------------------------------------------


def find_kairo(arg: str | None) -> Path:
    if arg:
        return Path(arg).resolve()
    if os.environ.get("KAIRO_BIN"):
        return Path(os.environ["KAIRO_BIN"]).resolve()
    # Release by default, same as lit; never PATH -- a bare `kairo` is Stage 0.
    hits = sorted(glob.glob(str(ROOT / "build" / "*" / "release" / "bin" / "kairo")))
    if not hits:
        sys.exit("parser_fuzz: no build/<triple>/release/bin/kairo; pass --kairo or KAIRO_BIN")
    return Path(hits[0])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kairo", help="compiler binary (default: build/<triple>/release/bin/kairo)")
    ap.add_argument("--corpus", default=str(ROOT / "Tests"), help="seed directory (default: Tests/)")
    ap.add_argument("--out", default=str(ROOT / "private" / "fuzz"), help="findings directory")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--timeout", type=float, default=10.0, help="per-run seconds before 'hang'")
    ap.add_argument("--time", type=float, default=0, help="stop after N seconds (0 = until ^C)")
    ap.add_argument("--iterations", type=int, default=0, help="stop after N mutants (0 = no limit)")
    ap.add_argument("--seed", type=int, default=None, help="RNG seed for a reproducible run")
    ap.add_argument("--nondet-every", type=int, default=50,
                    help="also check --threads=1 vs 0 on every Nth mutant (0 = off)")
    ap.add_argument("--min-budget", type=int, default=400, help="max compiler runs per minimization")
    ap.add_argument("--seeds-only", action="store_true", help="run each seed once, unmutated, and stop")
    ap.add_argument("--repro", metavar="FILE", help="classify one file and exit")
    ap.add_argument("kairo_args", nargs="*", help="extra compiler flags, after --")
    a = ap.parse_args()

    runner = Runner(find_kairo(a.kairo), a.timeout, a.kairo_args)
    if not runner.kairo.is_file():
        sys.exit(f"parser_fuzz: {runner.kairo} does not exist")

    if a.repro:
        text = Path(a.repro).read_text(encoding="utf-8", errors="surrogateescape")
        r = runner.run(text)
        fs = classify(text, r)
        print(r.out, end="")
        for f in fs:
            print(f"[{f.oracle}] {f.detail}\n  sig: {f.signature!r}")
        print(f"rc={r.rc} {r.secs:.2f}s, {len(fs)} finding(s)")
        return 1 if fs else 0

    seeds = load_seeds(Path(a.corpus))
    if not seeds:
        sys.exit(f"parser_fuzz: no .k seeds under {a.corpus}")
    seed = a.seed if a.seed is not None else random.randrange(1 << 32)
    store = Store(Path(a.out))
    print(f"kairo  {runner.kairo}\nseeds  {len(seeds)} from {a.corpus}\nrng    --seed {seed}\n"
          f"out    {a.out}\njobs   {a.jobs}", flush=True)

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    stats = {"runs": 0, "new": 0, "hits": 0}
    slock = threading.Lock()
    t_start = time.monotonic()

    def one(idx: int) -> None:
        rng = random.Random(seed * 1_000_003 + idx)
        if a.seeds_only:
            text = seeds[idx]
        else:
            toks = tokenize(rng.choice(seeds))
            text = "".join(mut.mutate(toks))
        r = runner.run(text)
        fs = classify(text, r)
        if (not a.seeds_only) and a.nondet_every and idx % a.nondet_every == 0 and r.rc in (0, 1):
            # Only clean exits: a crash's backtrace differs run to run (ASLR),
            # and the crash oracle already owns it.
            r1 = runner.run(text, ["--threads=1"])
            if r1.rc in (0, 1) and (r1.rc, sorted(r1.out.splitlines())) != (r.rc, sorted(r.out.splitlines())):
                fs.append(Finding("nondet", f"rc {r.rc}/{r1.rc}", "--threads=1 output differs from default"))
        with slock:
            stats["runs"] += 1
            stats["hits"] += len(fs)
        for f in fs:
            d = store.claim(f)
            if d is None:
                continue
            with slock:
                stats["new"] += 1
            print(f"\nNEW [{f.oracle}] {d.relative_to(Path(a.out))}: {f.detail[:160]}", flush=True)
            save(d, runner, text, r, f, [], a.min_budget)

    mut = Mutator(seeds, random.Random(seed))
    total = len(seeds) if a.seeds_only else (a.iterations or None)
    idx = 0
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        pending: set[cf.Future] = set()
        last = 0.0
        while not stop.is_set():
            if total is not None and idx >= total:
                break
            if a.time and time.monotonic() - t_start > a.time:
                break
            while len(pending) < a.jobs * 2 and (total is None or idx < total):
                pending.add(ex.submit(one, idx))
                idx += 1
            done, pending = cf.wait(pending, timeout=0.5, return_when=cf.FIRST_COMPLETED)
            for fu in done:
                if fu.exception():
                    print(f"\nparser_fuzz: worker error: {fu.exception()!r}", file=sys.stderr)
            now = time.monotonic()
            if now - last > 2:
                last = now
                el = now - t_start
                print(f"\r{stats['runs']} runs  {stats['runs'] / max(el, 1e-9):.1f}/s  "
                      f"{stats['new']} new  {len(store.seen)} unique  {el:.0f}s", end="", flush=True)
        cf.wait(pending)

    el = time.monotonic() - t_start
    print(f"\n{stats['runs']} runs in {el:.0f}s, {stats['new']} new signature(s), "
          f"{len(store.seen)} unique total, rerun with --seed {seed}")
    return 1 if stats["new"] else 0


if __name__ == "__main__":
    sys.exit(main())
