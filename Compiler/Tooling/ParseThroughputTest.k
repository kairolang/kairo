/// --- The Kairo Project ------------- Tooling/ParseThroughputTest.k --- ///
///
///   \brief Parser throughput, cold vs hot. One number, measured two ways.
///
///   \par What it measures
///     Bytes of source per second through the frontend, to the end of parse.
///     Nothing else   no sema, no codegen, no AST printing. Two regimes:
///
///       COLD   a fresh CompilerInstance per iteration, via parse_once(). Every
///              arena, every table, every cache starts empty and is torn down
///              again. Bytes counted are the whole import graph the entry
///              pulled in, so this is the number a one-shot invocation of the
///              compiler actually sees.
///
///       HOT    one CompilerInstance, warmed by a full parse_file(), then
///              reparse() on the entry fid over and over. The graph stays
///              standing; only the entry's own bytes are re-lexed and
///              re-parsed. This is the keystroke number an editor sees.
///
///     The two are NOT comparable as a ratio of the same work   they are
///     deliberately different denominators (graph bytes vs one file's bytes).
///     What each is good for is its own trend line across commits.
///
///   \par What "cold" does and does not control for
///     It resets everything the PROCESS owns. It does not drop the OS page
///     cache, so file reads after iteration 1 are warm no matter what. That is
///     fine and intentional: this is a parser benchmark, not a disk benchmark,
///     and leaving the page cache warm is what keeps the numbers about the
///     parser. It does mean iteration 0 is an outlier, which is why the
///     summary leads with the median rather than the mean.
///
///   \par Why min AND median are reported
///     Wall-clock samples on a loaded machine have a hard floor and an
///     unbounded tail: scheduler preemption, a thermal step, another build.
///     Only the tail moves. min is therefore the closest thing to the parser's
///     actual cost, and median is what you would feel; a large gap between
///     them means the machine was busy and the run should be repeated, not
///     that the parser regressed.
///
///   \par Usage
///     kparsebench <file.k> [include-dir ...]
///
///     Include dirs are positional, same convention as kparse   there is no
///     flag parser here on purpose.
///
///       $KBENCH_ITERS   timed iterations per regime (default 10)
///       $KBENCH_WARMUP  untimed iterations before each regime (default 1)
///       $KBENCH_ONLY    "cold" or "hot" to run just one regime
///
///   \par Build target
///     Registered in build.k as 'kparsebench'. A measurement driver, not a
///     shipped tool   nothing imports it, same shape as ParseOnceTest.k and
///     Interop/Clang/ClangLocMapTest.k.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Driver::CompilerInstance::*;
import Driver::TUStage::*;
import Config::Invocation::*;
import Tooling::ParseAPI::*;
import Support::FileIO::Path::*;

ffi "c++" import "llvm/Support/TargetSelect.h";
ffi "c++" import "cstdlib";   // getenv/strtoull, for the knobs above

/// \class Samples
/// \brief timed durations for one regime, plus the byte count they moved.
///
/// \details Milliseconds as f64 rather than an integer nanosecond count: the
///          summary divides by them, and the two places that would have to
///          agree on a scale factor collapse into one.
class Samples {
    pub var ms:    vec::<f64>;

    /// Source bytes ONE iteration put through the frontend. Constant across
    /// iterations by construction   cold reparses the same graph, hot reparses
    /// the same file   so it is stored once rather than per sample.
    pub var bytes: u64 = 0;

    /// Iterations that produced no usable AST. Any non-zero value makes every
    /// number here meaningless, because a parse that bailed early is fast for
    /// the wrong reason.
    pub var failed: usize = 0;

    default fn Samples(self);

    fn add(self, ms: f64) { self.ms.push_back(ms); }

    /// Insertion sort, in place. n is the iteration count   a handful   so the
    /// asymptotics do not matter and this avoids dragging in a comparator.
    priv fn _sort(self) {
        for var i: usize = 1; i < self.ms.size(); ++i {
            var v = self.ms[i];
            var j = i;
            while (j > 0) && (self.ms[j - 1] > v) {
                self.ms[j] = self.ms[j - 1];
                j -= 1;
            }
            self.ms[j] = v;
        }
    }

    fn min(self) -> f64 {
        if self.ms.empty() { return 0.0; }
        var m = self.ms[0];
        for var i: usize = 1; i < self.ms.size(); ++i {
            if self.ms[i] < m { m = self.ms[i]; }
        }
        return m;
    }

    fn max(self) -> f64 {
        if self.ms.empty() { return 0.0; }
        var m = self.ms[0];
        for var i: usize = 1; i < self.ms.size(); ++i {
            if self.ms[i] > m { m = self.ms[i]; }
        }
        return m;
    }

    fn mean(self) -> f64 {
        if self.ms.empty() { return 0.0; }
        var t = 0.0;
        for var i: usize = 0; i < self.ms.size(); ++i { t += self.ms[i]; }
        return t / static_cast::<f64>(self.ms.size());
    }

    /// Lower median on an even count. Picking the lower element rather than
    /// averaging the middle two keeps every reported figure an actually
    /// observed sample, which matters when you are chasing a specific slow run.
    fn median(self) -> f64 {
        if self.ms.empty() { return 0.0; }
        self._sort();
        return self.ms[(self.ms.size() - 1) / 2];
    }

    /// MiB/s implied by \p ms for this regime's byte count.
    fn mib_per_sec(self, ms: f64) -> f64 {
        if ms <= 0.0        { return 0.0; }
        if self.bytes == 0  { return 0.0; }
        var mib = static_cast::<f64>(self.bytes) / 1048576.0;
        return mib / (ms / 1000.0);
    }
}

/// Elapsed nanoseconds between two steady_clock stamps, as milliseconds.
///
/// Nanoseconds and not microseconds: a hot reparse of a small file lands under
/// 1 ms, and duration_cast truncates, so a microsecond clock quantises the
/// interesting regime into three significant figures at best.
fn <T> _ms_between(t0: T, t1: T) -> f64 {
    return static_cast::<f64>(
        libcxx::chrono::duration_cast::<libcxx::chrono::nanoseconds>(t1 - t0).count()
    ) / 1000000.0;
}

fn _env_usize(name: *kairo::std::Legacy::char, fallback: usize) -> usize {
    var s = getenv(name);
    if s == &null   { return fallback; }
    if s[0] == r'\0' { return fallback; }
    var v = strtoull(s, &null, 10);
    if v == 0 { return fallback; }
    return v;
}

/// True when $KBENCH_ONLY is set and does not name \p want.
fn _skipped(want: string) -> bool {
    var s = getenv(r"KBENCH_ONLY");
    if s == &null { return false; }
    var have = std::nptr_to_string(s, libcxx::strlen(s));
    if have.empty() { return false; }
    return have != want;
}

/// Rounds \p v to \p dp decimal places.
///
/// The f-string `:.N` spec is not honoured for floats today   it parses and is
/// then ignored, so every figure below would print at default precision. Two
/// runs of this tool are meant to be diffed against each other by eye, and
/// eight significant digits of scheduler noise defeats that.
///
/// Positive inputs only, which every duration and rate here is.
fn _round(v: f64, dp: i32) -> f64 {
    var scale = 1.0;
    for var i: i32 = 0; i < dp; ++i { scale *= 10.0; }
    return static_cast::<f64>(static_cast::<i64>((v * scale) + 0.5)) / scale;
}

/// One line per statistic, so a run can be diffed against another run directly.
fn _report(label: string, s: ref!(Samples)) {
    if s.ms.empty() {
        std::print(f"-- {label}: no samples");
        return;
    }

    var kib = _round(static_cast::<f64>(s.bytes) / 1024.0, 1);
    std::print(f"-- {label}  n={s.ms.size()}  bytes={s.bytes} ({kib} KiB)/iter");

    if s.failed > 0 {
        // Loud, and before the numbers: a parse that failed early is FAST, so
        // a regression that breaks the file shows up as a throughput WIN.
        std::print(f"   !! {s.failed} iteration(s) produced no AST   numbers below are meaningless");
    }

    var mn  = s.min();
    var md  = s.median();
    var mu  = s.mean();
    var mx  = s.max();

    // Rate is computed from the UNROUNDED duration and rounded after   round
    // then divide would let a 3-decimal truncation move the throughput figure.
    var mn_t = _round(s.mib_per_sec(mn), 2);
    var md_t = _round(s.mib_per_sec(md), 2);
    var mu_t = _round(s.mib_per_sec(mu), 2);

    std::print(f"   min    {_round(mn, 3)} ms   {mn_t} MiB/s");
    std::print(f"   median {_round(md, 3)} ms   {md_t} MiB/s");
    std::print(f"   mean   {_round(mu, 3)} ms   {mu_t} MiB/s");
    std::print(f"   max    {_round(mx, 3)} ms");

    // Spread flags a noisy machine rather than a slow parser. Reported as a
    // ratio because the absolute gap is meaningless without knowing the floor.
    if mn > 0.0 {
        var spread = mx / mn;
        std::print(f"   spread max/min = {_round(spread, 2)}x");
        if spread > 3.0 {
            std::print("   NOTE: >3x spread   machine was busy, rerun before trusting a delta");
        }
    }
}

/// COLD: fresh CompilerInstance per iteration, torn down before the next.
///
/// parse_once() owns its instance, so the teardown is the OwnedUnit destructor
/// at the bottom of the loop body   AFTER t1, deliberately. Teardown cost is
/// real but it is not parse cost, and folding it in would hide a parser change
/// behind an allocator change.
fn run_cold(path: Path, inv: *CompilerInvocation, iters: usize, warmup: usize) -> Samples {
    var s = Samples();

    for var i: usize = 0; i < (warmup + iters); ++i {
        var t0 = libcxx::chrono::steady_clock::now();
        var owned = parse_once(path, inv, TUStage::Parsing);
        var t1 = libcxx::chrono::steady_clock::now();

        if i < warmup {
            // Byte count is taken from a warmup iteration so that a failure on
            // the very first timed pass still reports against a real figure.
            if (owned.ci()) != &null {
                s.bytes = owned.ci()->sm()->total_bytes();
            }
            continue;
        }

        if !owned.ok() { s.failed += 1; }
        if (s.bytes == 0) && ((owned.ci()) != &null) {
            s.bytes = owned.ci()->sm()->total_bytes();
        }

        s.add(_ms_between(t0, t1));
    }

    return s;
}

/// HOT: one instance, warmed once, then reparse() on the entry fid.
///
/// reparse() releases and rebuilds exactly one fid's artifacts and leaves the
/// rest of the graph standing, so the bytes attributed here are that fid's
/// alone   see get_file_size below. Attributing the whole graph would report a
/// throughput figure for work the hot path never does.
///
/// \note No edit is simulated. reparse() re-reads the buffer from disk
///       unconditionally, so re-running it on an unchanged file exercises the
///       same code path an editor's keystroke would, minus the bytes actually
///       differing. Lexing does not care what the bytes are.
fn run_hot(path: Path, inv: *CompilerInvocation, iters: usize, warmup: usize) -> Samples {
    var s = Samples();

    var ci = std::create::<CompilerInstance>(inv);
    finally { std::destroy(ci); }

    if !ci->args_ok() {
        std::print("-- hot: invocation rejected");
        s.failed = iters;
        return s;
    }

    ci->initialize(Path::cwd());

    var opts = ParseOptions{};
    opts.stop_at       = TUStage::Parsing;
    opts.capture_diags = true;

    // The warm graph every timed iteration below reparses INTO. Without this
    // there is no import graph standing and reparse() would be measuring a
    // different thing entirely.
    var seed = parse_file(ci, path, opts);
    if !seed.ok {
        std::print(f"-- hot: seed parse failed (stage={static_cast::<i32>(seed.stage)}, errors={seed.errors})");
        for var i: usize = 0; i < seed.diags.size(); ++i {
            std::print(f"   {seed.diags[i].format()}");
        }
        s.failed = iters;
        return s;
    }

    var fid = seed.fid;
    s.bytes = static_cast::<u64>(ci->sm()->get_file_size(fid));

    for var i: usize = 0; i < (warmup + iters); ++i {
        var t0 = libcxx::chrono::steady_clock::now();
        var u  = reparse(ci, fid, opts);
        var t1 = libcxx::chrono::steady_clock::now();

        // Retained diagnostics accumulate across iterations otherwise, which
        // is a slow leak that would show up as a downward drift in throughput.
        ci->diag()->clear_retained();

        if i < warmup { continue; }

        if !u.ok { s.failed += 1; }
        s.add(_ms_between(t0, t1));
    }

    return s;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    llvm::InitializeAllTargetInfos();
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmParsers();
    llvm::InitializeAllAsmPrinters();

    // Error, not Warn: a warning printed mid-iteration is I/O inside the timed
    // window, and on a redirected stdout that is a syscall per line.
    Logger::init(Logger::Level::Error);

    if argc < 2 {
        std::print("Usage: kparsebench <file.k> [include-dir ...]");
        std::print("  $KBENCH_ITERS=N   timed iterations per regime (default 10)");
        std::print("  $KBENCH_WARMUP=N  untimed iterations first    (default 1)");
        std::print("  $KBENCH_ONLY=cold|hot");
        return 1;
    }

    var target = std::nptr_to_string(argv[1], libcxx::strlen(argv[1]));

    var inv = CompilerInvocation();
    for var i: i32 = 2; i < argc; ++i {
        inv.include_dirs.push_back(std::nptr_to_string(argv[i], libcxx::strlen(argv[i])));
    }

    // Single-threaded on purpose. The pool makes wall time a function of how
    // many cores happened to be free, and this benchmark is about the parser's
    // cost, not the scheduler's luck. kwatch does the same.
    inv.frontend.thread_count = 1;

    var iters  = _env_usize(r"KBENCH_ITERS",  10);
    var warmup = _env_usize(r"KBENCH_WARMUP", 1);

    std::print(f"=== kparsebench {target}");
    std::print(f"=== iters={iters} warmup={warmup} threads=1 stop_at=Parsing");

    var rc: i32 = 0;

    if !_skipped("cold") {
        var cold = run_cold(Path(target), &inv, iters, warmup);
        _report("COLD  fresh CompilerInstance per iteration, whole import graph", cold);
        if cold.failed > 0 { rc = 1; }
    }

    if !_skipped("hot") {
        var hot = run_hot(Path(target), &inv, iters, warmup);
        _report("HOT   warm instance, reparse() of the entry fid only", hot);
        if hot.failed > 0 { rc = 1; }
    }

    return rc;
}
