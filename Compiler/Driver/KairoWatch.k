/// --- The Kairo Project -------------------------- Driver/KairoWatch.k --- ///
///
///   kwatch: reparse-on-save loop, for measuring the incremental path.
///
///   Watches one file, and on every mtime change runs the frontend to the end
///   of sema, clears the terminal, and reprints the AST in place. Each pass
///   reports wall time and arena occupancy so you can see, per keystroke:
///
///     - how long a full reparse of that file actually costs
///     - whether memory returns to a steady state or climbs
///
///   The second one is the point. Nothing was reclaimed per-file before the
///   arena split, so this loop is what proves release_all() actually gives the
///   memory back rather than merely compiling.
///
///   NOT a language server. There is no incremental reuse here: every pass is
///   a FULL reparse of the file and its import graph, released and rebuilt
///   from scratch. That is deliberate   it is the pessimistic baseline any
///   real incremental scheme has to beat.
///
///   Usage:  kwatch <file.k> [-I dir ...]
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
import Tooling::ParseAPI::*;
import Tooling::ToolDiagnostics::*;
import AST::Printer::ASTPrinter::*;
import AST::Printer::PrintCore::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import Support::FileIO::Path::*;

ffi "c++" import "llvm/Support/InitLLVM.h";
ffi "c++" import "llvm/Support/TargetSelect.h";
// mach, not sys/resource.h: getrusage only exposes ru_maxrss, which is a PEAK
// and cannot decrease. See rss_kib().
ffi "c++" import "Native/GlobalRecycler.hh";
ffi "c++" import "cstdlib";   // getenv/strtoull, for max_passes()
ffi "c++" import "mach/mach.h";
ffi "c++" import "mach/task_info.h";

/// Poll interval. Coarse on purpose: mtime granularity is the real floor and
/// a tighter loop just burns CPU between saves.
fn poll_ms() -> i64 { return 120; }

/// Pass limit from $KWATCH_MAX_PASSES; 0 (unset) means run forever.
///
/// Exists for leak checking. LeakSanitizer reports from an atexit handler, so
/// a tool whose main loop is `while true` never produces a report no matter how
/// many passes it runs   the interesting state is only ever observed by killing
/// the process, which is exactly the path that skips the check. This gives the
/// loop a normal exit so `kbld --debug` builds can be scripted:
///
///     KWATCH_MAX_PASSES=4 ./kwatch file.k -I Compiler
fn max_passes() -> usize {
    fn run() -> usize {
        var s = getenv(r"KWATCH_MAX_PASSES");
        if s == &null { return 0; }
        return strtoull(s, &null, 10);
    }

    return run();
}

fn clear_terminal() {
    // \033[2J clears, \033[H homes the cursor. Together they keep the dump
    // pinned to the top so successive passes overwrite in place instead of
    // scrolling.
    // \u001b = ESC. Written as \u rather than \033 because an octal escape is
    // only valid in a byte string here (S025W).
    std::print("\u001b[2J\u001b[H");
}

fn mtime_of(p: libcxx::filesystem::path) -> i64 {
    var ec = libcxx::error_code();
    var t  = libcxx::filesystem::last_write_time(p, ec);
    if ec { return 0; }
    return __inline_cpp("t.time_since_epoch().count()");
}

/// CURRENT physical footprint, in KiB.
///
/// THE leak signal. The arena counters below cannot show a leak: they are
/// LIFETIME totals on a context that is destroyed and rebuilt every pass, so
/// they report "what this pass allocated", not what is still held. This number
/// is process-wide and live   if it climbs pass after pass on an UNCHANGED
/// file, something is not being given back.
///
/// NOT ru_maxrss. That is a HIGH WATER MARK: monotonic by construction, so it
/// can only ever report a leak, never a fix. A release path that correctly
/// returns every byte still shows a flat-or-rising getrusage number, which is
/// exactly the reading that makes this loop useless as a regression check.
///
/// phys_footprint is what Activity Monitor shows: resident pages plus
/// compressed pages plus IOKit mappings. Compressed pages matter here   under
/// pressure macOS will compress a leaked page rather than evict it, and plain
/// resident_size would show that as a drop.
fn rss_kib() -> usize {
    return __inline_cpp("
        []() -> unsigned long long {
          task_vm_info_data_t    info {};
          mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
          
          if (task_info(mach_task_self(),
              TASK_VM_INFO,
              reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
            return 0ull;
          }

          return (unsigned long long)info.phys_footprint / 1024ull;
        }()
    ");
}

/// True when $KWATCH_INCREMENTAL is set to something other than "0".
///
/// Selects the single-file reparse path. Off by default because the full
/// release-and-rebuild loop is the pessimistic baseline any incremental scheme
/// has to beat, and that comparison is what this tool is for.
fn incremental() -> bool {
    fn run() -> bool {
        var s = getenv(r"KWATCH_INCREMENTAL");
        if s == &null { return false; }
        return s[0] != r'\0' && !(s[0] == r'0' && s[1] == r'\0');
    }
    return run();
}

/// Bytes / slabs / alloc-calls summed across the context's arenas.
fn report_mem(u: ref!(ParsedUnit)) -> string {
    if u.ctx == &null { return "ctx=<null>"; }

    // mem_profile() returns (bytes, slabs, alloc_calls) as a tuple.
    var prof  = u.ctx->mem_profile();
    var bytes = libcxx::get::<0>(prof);
    var slabs = libcxx::get::<1>(prof);
    var calls = libcxx::get::<2>(prof);

    return f"arena={bytes / 1024}KiB slabs={slabs} allocs={calls}";
}

/// Blocks parked in GlobalRecycler, not held by any live arena.
///
/// Reported per pass because this pool is invisible to both of the other two
/// numbers: it is not resident in any ASTContext (so report_mem misses it) and
/// it is malloc'd-and-retained (so it inflates the footprint). A steady arena
/// figure next to a climbing retained figure means the release path works and
/// the recycler is hoarding.
fn report_recycler() -> string {
    var blocks: usize = 0;
    var bytes:  usize = 0;
    kairo::GlobalRecycler::instance().stats(blocks, bytes);
    return f"recycled={bytes / 1024}KiB/{blocks}blk";
}

/// Occupancy of the tables that live for the whole CompilerInstance.
///
/// A reparse loop releases per-file artifacts and rebuilds them, so every one
/// of these should be FLAT across passes. Any counter that tracks the pass
/// number is a structure that is being appended to and never pruned   which is
/// what a leak looks like from up here, long before it is visible as a size
/// class in `heap`.
fn report_tables(ci: *CompilerInstance) -> string {
    var ctxs   = ci->global_scope()->size();
    var macros = ci->pp()->macro_count();
    var diags  = ci->diag()->retained_diag_count();
    var slots  = ci->tcm()->live_slots();
    var nslot  = ci->tcm()->slot_count();
    var lines  = ci->sm()->line_table_files();
    var files  = ci->sm()->mapped_files();
    return f"ctxs={ctxs} macros={macros} heldDiags={diags} lexSlots={slots}/{nslot} lineFiles={lines} mapped={files}";
}

/// Single-file reparse of \p fid, against a graph left standing from pass 1.
///
/// This is the incremental path: everything except the edited file keeps its
/// mapping, tokens, context and AST. Compare its timing against the full
/// reparse above   that ratio is the whole point of the exercise.
fn run_reparse(ci: *CompilerInstance, fid: u32, pass: usize) {
    var opts     = ParseOptions{};
    opts.stop_at = TUStage::Parsing;
    opts.capture_diags = true;

    var t0 = libcxx::chrono::steady_clock::now();
    var u  = reparse(ci, fid, opts);
    var t1 = libcxx::chrono::steady_clock::now();

    var ms = static_cast::<f64>(
        libcxx::chrono::duration_cast::<libcxx::chrono::microseconds>(t1 - t0).count()
    ) / 1000.0;

    clear_terminal();

    var ms_str = f"{ms:.2}";
    var rss    = rss_kib();
    var rec    = report_recycler();
    var tbl    = report_tables(ci);
    std::print(f"== kwatch  reparse {pass}  {ms_str} ms  rss={rss}KiB  {rec}");
    var st = static_cast::<u32>(u.stage);
    var ninv = u.invalidated.size();
    std::print(f"== fid={fid} stage={st} errors={u.errors} warnings={u.warnings} clean={u.clean()} added_imports={u.added_imports} invalidated={ninv}");
    std::print(f"== {tbl}");

    if u.added_imports > 0 {
        std::print("== NOTE: imports changed; single-file reparse cannot resolve them, rerun full");
    }

    if u.diags.size() > 0 {
        std::print(f"-- {u.diags.size()} diagnostic(s) --");
        for var i: usize = 0; i < u.diags.size(); ++i {
            std::print(f"  {u.diags[i].format()}");
        }
    }

    ci->diag()->clear_retained();
}

/// True when $KWATCH_REPARSE_CYCLE is set to something other than "0".
///
/// Incremental mode normally re-edits the entry file forever, which only ever
/// exercises a LEAF of the import graph   nothing imports the entry, so
/// reparse() never has to invalidate a dependent. This cycles through every fid
/// in the graph instead, so importers get reparsed after their imports and the
/// cross-file invalidation path is actually hit.
/// True when $KWATCH_SELF_DRIVE is set to something other than "0".
///
/// Runs passes back-to-back instead of waiting on saves. Separate from
/// KWATCH_MAX_PASSES so a MTIME-DRIVEN run can still exit normally after N
/// passes   which matters because stdout is block-buffered when redirected,
/// so a run that has to be killed loses its output entirely.
fn self_drive() -> bool {
    fn run() -> bool {
        var s = getenv(r"KWATCH_SELF_DRIVE");
        if s == &null { return false; }
        return s[0] != r'\0' && !(s[0] == r'0' && s[1] == r'\0');
    }

    return run();
}

fn reparse_cycle() -> bool {
    fn run() -> bool {
        var s = getenv(r"KWATCH_REPARSE_CYCLE");
        if s == &null { return false; }
        return s[0] != r'\0' && !(s[0] == r'0' && s[1] == r'\0');
    }

    return run();
}

fn run_pass(ci: *CompilerInstance, path: Path, pass: usize) -> vec::<u32> {
    var opts     = ParseOptions{};
    opts.stop_at = TUStage::Sema;   // parse + sema, no codegen

    // Capture rather than print: the dump below is the output, and interleaved
    // pretty diagnostics would fight it for the screen.
    opts.capture_diags = true;

    var t0 = libcxx::chrono::steady_clock::now();
    var u  = parse_file(ci, path, opts);
    var t1 = libcxx::chrono::steady_clock::now();

    var ms = static_cast::<f64>(
        libcxx::chrono::duration_cast::<libcxx::chrono::microseconds>(t1 - t0).count()
    ) / 1000.0;

    var mem = report_mem(u);

    clear_terminal();

    var ms_str = f"{ms:.2}";
    var rss    = rss_kib();
    var rec = report_recycler();
    std::print(f"== kwatch  pass {pass}  {ms_str} ms  rss={rss}KiB  {mem}  {rec}");
    var nf = u.fids.size();
    var st = static_cast::<u32>(u.stage);
    // entry fid, not just the count. A fid is an index into SourceManager's
    // file table, so on a correct release path pass N reuses pass 1's number.
    // If it climbs by the graph size every pass, released files are not being
    // deregistered and the fid space is leaking   which drags the mmap, the
    // line table and the TCM slot vector along with it.
    var f0 = u.fid;
    var tbl = report_tables(ci);
    std::print(f"== fids={nf} entry_fid={f0} stage={st} errors={u.errors} warnings={u.warnings} clean={u.clean()}");
    std::print(f"== {tbl}");
    std::print("");

    if u.tu != &null {
        // ASTPrinter::print(u.tu, PrintOptions::dump());
        std::print("AST dump omitted for brevity");
    } else {
        std::print("<no translation unit>");
    }

    if u.diags.size() > 0 {
        std::print("");
        std::print(f"-- {u.diags.size()} diagnostic(s) --");
        // for var i: usize = 0; i < u.diags.size(); ++i {
        //     std::print(f"  {u.diags[i].format()}");
        // }
    }

    // Incremental mode keeps the graph standing: reparse() works AGAINST the
    // already-parsed imports, so releasing them here would defeat it.
    if incremental() {
        std::print("");
        std::print("== graph retained for incremental reparse");
        return u.fids;
    }

    // Release before the next pass. Without this the loop is measuring
    // accumulation, not steady state   which is exactly the thing being
    // checked, so it must be unconditional.
    var freed = release_all(ci, TUStage::Lexing);

    // Diagnostics are owned by the engine and outlive the parse that made
    // them, so a loop that never clears them accumulates one full run's worth
    // per pass. Safe here because ParsedUnit::diags is a flattened COPY (see
    // ToolDiag) and nothing else holds a *Diagnostic past run_pass.
    ci->diag()->clear_retained();
    std::print("");
    std::print(f"== released {freed} fid(s); next pass reparses from scratch");
    return u.fids;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    static var init_llvm = llvm::InitLLVM(argc, argv);
    llvm::InitializeAllTargetInfos();
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmParsers();
    llvm::InitializeAllAsmPrinters();

    // Quiet: the AST dump is the output, and a trace log fights it for
    // the screen. Raise this if you are debugging the pipeline itself.
    Logger::init(Logger::Level::Warn);

    if argc < 2 {
        std::print("Usage: kwatch <file.k> [-I dir ...]");
        return 1;
    }

    // CompilerInstance parses argv itself, so include dirs and friends pass
    // straight through   kwatch adds no flag surface of its own.
    var ci = std::create::<CompilerInstance>(argc, argv);
    finally { std::destroy(ci); }

    if !ci->args_ok() { return 1; }

    var target = ci->invocation().input_files;
    if target.empty() {
        std::print("kwatch: no input file");
        return 1;
    }

    var path  = Path(target[0]);
    var fspath = libcxx::filesystem::path(std::string_to_nstring(target[0]).raw());

    if !libcxx::filesystem::exists(fspath) {
        std::print(f"kwatch: no such file: {target[0]}");
        return 1;
    }

    ci->initialize(Path::cwd());

    std::print(f"kwatch: watching {target[0]} (ctrl-c to stop)");

    var last: i64  = 0;
    var pass: usize = 0;

    var limit = max_passes();
    var entry_fid: u32 = u32(-1);
    var graph_fids = vec::<u32>();

    while true {
        var now = mtime_of(fspath);

        // Pass-limit mode drives itself instead of waiting on saves: the point
        // is a fixed, repeatable number of reparses under a sanitizer, and
        // nobody is at the keyboard to touch the file.
        if (self_drive() && (limit > 0)) || (now != last) {
            last  = now;
            pass += 1;

            // $KWATCH_INCREMENTAL: full parse once to stand the graph up, then
            // single-file reparses. Off by default   the full path is the
            // pessimistic baseline this tool exists to measure.
            if incremental() && (pass > 1) {
                var target = entry_fid;
                if reparse_cycle() && (!graph_fids.empty()) {
                    target = graph_fids[(pass - 2) % graph_fids.size()];
                }
                run_reparse(ci, target, pass);
            } else {
                graph_fids = run_pass(ci, path, pass);
                entry_fid  = ci->sm()->load_file(path);
            }

            if (limit > 0) && (pass >= limit) {
                std::print(f"== kwatch: KWATCH_MAX_PASSES={limit} reached, exiting");
                // Falls out through main's `finally`, so the CompilerInstance is
                // destroyed normally   without that teardown a leak report is
                // just a list of everything the compiler owns.
                return 0;
            }

            continue;
        }

        libcxx::this_thread::sleep_for(libcxx::chrono::milliseconds(poll_ms()));
    }

    return 0;
}
