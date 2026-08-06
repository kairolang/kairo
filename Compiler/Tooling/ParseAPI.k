/// --- The Kairo Project ------------------------- Tooling/ParseAPI.k --- ///
///
///   Run-to-AST entry points   the compiler as a library.
///
///   The compiler's own path is CompilerInstance::execute()   a batch loop
///   over FrontendAction. Tools want something narrower: hand me a file, give
///   me back a TranslationUnit and the ASTContext to read it with. That is
///   this file.
///
///   WHY Tooling/ AND NOT Frontend/: FrontendAction and FrontendOptions are
///   the compiler's own per-file pipeline   internal machinery. This is the
///   surface OTHER programs consume (kfmt, kals, kpkg, a future LSP). Clang
///   splits the same way: clang/Frontend/ is the pipeline, clang/Tooling/ is
///   the library surface that clang-format and clang-tidy build on.
///
///   Free functions, not methods on CompilerInstance. Everything here drives
///   CI through its public accessors (sm/tcm/pool/global_scope/pp/imp/diag/
///   invocation), which is the same contract FrontendAction already works
///   under. CI stays a resource owner; only construction and teardown live on
///   it. Clang draws the line the same way: ASTUnit::LoadFromCommandLine is a
///   static factory, clang::ParseAST is a free function.
///
///   NAMING: the result type is ParsedUnit, deliberately NOT ASTUnit. Clang's
///   ASTUnit OWNS its ASTContext; this one owns nothing   every pointer in it
///   is borrowed from the CompilerInstance and dies with it, or earlier if
///   release() is called. Reusing clang's name would import the wrong
///   ownership contract. ParseResult was the other candidate, but Driver/
///   already has TUResult meaning a per-file COMPILE result.
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
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Node::Program::*;
import Location::SourceManager::*;
import Support::FileIO::Path::*;
import Resolution::ModulePath::*;
import Config::Frontend::*;
import Config::Invocation::*;
import Diagnostic::Engine::*;
import Diagnostic::Consumer::*;
import Tooling::ToolDiagnostics::*;

/// \enum ParseFidelity
/// \brief what the caller needs the AST to be faithful TO.
///
/// \details "run the preprocessor or not" is the wrong knob, because the PP
///          does three separable jobs:
///
///            1. lex, materialize the token span, create the ASTContext + TU
///            2. consume imports/macro-defs into the TU, resolve the graph
///            3. expand macro invocations
///
///          (1) is file setup and everyone needs it. (2) and (3) are what
///          separates a compiler from a source tool: after the PP, imports
///          have MOVED out of program->items into tu->imports, and macro
///          invocations are GONE, replaced by their expansion.
enum ParseFidelity derives u8 {
    /// Full PP. Imports resolved into tu->imports, macros expanded. The AST
    /// compilation wants. The only mode implemented today.
    Semantic,

    /// No PP. Imports parse as ImportDecls into program->items (the parser
    /// already has that path   DeclParse::_parse_import is live), macro
    /// invocations stay unexpanded. The AST tooling wants.
    ///
    /// NOT IMPLEMENTED. Blocked on an AST representation for an unexpanded
    /// macro invocation: ExprKind has no MacroInvocationExpr (only a
    /// commented-out mention in Expressions.k marked "ambiguous"), so `foo!(x)`
    /// has nowhere to go. See Spec/ discussion   the options are a real
    /// MacroInvocationExpr, a generic VerbatimNode carrying a SourceRange, or
    /// rejecting files that use macros. That is a language decision, not an
    /// API one, so this mode reports unsupported rather than guessing.
    Verbatim,
}

/// \class ParseOptions
struct ParseOptions {
    var fidelity: ParseFidelity = ParseFidelity::Semantic;

    /// Last stage to run. Parsing is what tools want; the compiler passes
    /// Codegen. Mapped onto FrontendOptions' stop-at flags.
    var stop_at:  TUStage = TUStage::Parsing;

    /// Detach the engine's consumers for the duration of the parse and collect
    /// diagnostics into ParsedUnit::diags instead of printing them.
    ///
    /// Captured at the ENGINE, not at ctx->diag_sink: the PP reports straight
    /// to the engine and never touches the context sink, so sink-level capture
    /// would miss every unresolved-import and macro error. See
    /// Tooling/ToolDiagnostics.k.
    var capture_diags: bool = true;
}

/// \class ParsedUnit
/// \brief one file's parse result: the fid, the context, and the TU.
///
/// \details fid/ctx/tu always travel together   every consumer that has a TU
///          immediately needs the ctx to resolve tokens through   so they are
///          returned together rather than making callers re-derive ctx from
///          global_scope()->get_context(fid).
///
/// \note NON-OWNING. Every pointer here is borrowed: the ASTContext belongs to
///       the CI's GlobalDisambigTable, and the TU lives in that context's
///       pp_alloc. This struct owns nothing and destroying it frees nothing.
///
///       Valid until the CompilerInstance is destroyed, or until release() is
///       called on this fid   whichever comes first. After release() every
///       pointer here dangles, including anything reached through ctx or tu.
class ParsedUnit {
    pub var fid:      u32 = u32(-1);
    pub var ctx:      obs::<ASTContext>       = &null;
    pub var tu:       obs::<TranslationUnit>  = &null;

    /// Transitive fid set the parse touched. In Semantic mode this is the
    /// entry's whole import graph; the entry is fids[0].
    pub var fids:     vec::<u32>;

    pub var stage:    TUStage = TUStage::Pending;
    pub var errors:   u32     = 0;
    pub var warnings: u32     = 0;

    /// Diagnostics raised by THIS parse, parents and notes flattened in
    /// emission order. Populated only when ParseOptions::capture_diags is set;
    /// otherwise they went to the engine's normal consumers and printed.
    pub var diags:    vec::<ToolDiag>;

    /// True if there is an AST to look at. Does NOT mean it is trustworthy
    /// the parser is error-resilient and produces recovery nodes.
    pub var ok:       bool    = false;

    /// Fids whose artifacts reparse() dropped because they (transitively)
    /// import the reparsed file. Their ASTs were derived from the bytes that
    /// just changed, so they were released rather than left dangling.
    ///
    /// THE CALLER MUST TREAT THESE AS GONE. Any cached ASTContext, TranslationUnit
    /// or node pointer for these fids is dangling after reparse() returns; an
    /// LSP holding per-file state must drop and re-request them. Empty when the
    /// reparsed file is a leaf that nothing imports   the common keystroke.
    pub var invalidated: vec::<u32>;

    /// Import edges with no live target context. Only ever set by reparse(),
    /// which does not resolve imports   non-zero means the edit added an
    /// import and this unit is only partially resolved. Zero from parse_file(),
    /// which resolves the whole graph.
    pub var added_imports: usize = 0;

    default fn ParsedUnit(self);

    /// True if the parse was clean enough to consume. Tools that REWRITE
    /// source (kfmt) must require this: formatting a recovery-node AST would
    /// silently mangle the file.
    fn clean(self) -> bool { return self.ok && (self.errors == 0); }

    fn program(self) -> *Program {
        if self.tu == &null { return &null; }
        return self.tu->program;
    }

    /// First error, for tools that report one line and stop. Empty if none.
    fn first_error(self) -> string {
        for var i: usize = 0; i < self.diags.size(); ++i {
            if self.diags[i].is_error() { return self.diags[i].format(); }
        }
        return "";
    }

    static fn failure(fid: u32, stage: TUStage) -> ParsedUnit {
        var u  = ParsedUnit{};
        u.fid   = fid;
        u.stage = stage;
        u.ok    = false;
        return u;
    }
}

/// Defined at the bottom of this file; OwnedUnit's teardown calls it, and a
/// class body cannot forward-reference a free function.
fn release_all(ci: *CompilerInstance, from: TUStage) -> usize;

/// \class OwnedUnit
/// \brief a ParsedUnit that owns the CompilerInstance behind it.
///
/// \details ParsedUnit borrows everything from a CI the caller stood up. This
///          owns that CI, so ctx/tu stay valid for as long as this value lives
///          and die with it. The one-shot case: parse a file, read the AST,
///          drop it.
///
/// \warning MOVE ONLY. Copying would double-destroy the instance. Everything
///          reached through unit.ctx or unit.tu dangles after this goes out
///          of scope.
class OwnedUnit {
    pub var unit: ParsedUnit;
    priv var _ci: *CompilerInstance = &null;

    default fn OwnedUnit(self);

    // Move-only: a copy would destroy the same CompilerInstance twice.
    // Prefix `delete fn` and `op =` are the spellings Kairo accepts   see
    // DiagBuilder in Diagnostic/Engine.k for the same pattern.
    delete fn OwnedUnit(self, other: ref!(OwnedUnit));
    delete fn op = (self, other: ref!(OwnedUnit)) -> ref!(OwnedUnit);

    /// Move. The source is left holding no instance, so its destructor is a
    /// no-op   this is what lets parse_once() return by value at all. Declaring
    /// a destructor and deleting the copy suppresses the implicit move, so it
    /// has to be spelled out.
    fn OwnedUnit(self, other: mref!(OwnedUnit)) {
        self.unit  = other.unit;
        self._ci   = other._ci;
        other._ci  = &null;
    }

    fn op = (self, other: mref!(OwnedUnit)) -> ref!(OwnedUnit) {
        // Parenthesised: `&self == &other` binds as `&(self == &other)`.
        if (&self) == (&other) { return self; }
        self._release();
        self.unit  = other.unit;
        self._ci   = other._ci;
        other._ci  = &null;
        return self;
    }

    fn op delete (self) { self._release(); }

    /// \brief takes ownership of \p ci. It is destroyed with this value.
    ///
    /// \details Exists because the entry points below are free functions and
    ///          cannot touch \c _ci directly. Passing a CI that something else
    ///          also owns is a double-free.
    fn adopt(self, ci: *CompilerInstance) {
        if self._ci == ci { return; }
        self._release();
        self._ci = ci;
    }

    /// Borrowed. Valid until this OwnedUnit dies.
    fn ci(self) -> *CompilerInstance { return self._ci; }

    fn ok(self)    -> bool { return self.unit.ok;      }
    fn clean(self) -> bool { return self.unit.clean(); }

    static fn failure(stage: TUStage) -> OwnedUnit {
        var o = OwnedUnit();
        o.unit = ParsedUnit::failure(u32(-1), stage);
        return o;
    }

    /// Teardown, shared by the destructor and move-assignment.
    ///
    /// release_all() BEFORE destroying the instance, not instead of it: the
    /// instance's own destructor frees the subsystems, but the per-fid
    /// artifacts hanging off GlobalDisambigTable are only reclaimed by an
    /// explicit release, and clear_retained() drops the diagnostics the engine
    /// held for this run.
    priv fn _release(self) {
        if self._ci == &null { return; }
        release_all(self._ci, TUStage::Lexing);
        self._ci->diag()->clear_retained();
        std::destroy(self._ci);
        self._ci = &null;
    }
}

/// \brief loads \p path into the SourceManager and returns its fid.
///
/// \details Idempotent for an already-loaded path   SourceManager returns the
///          existing fid. \c u32(-1) on failure.
fn load(ci: *CompilerInstance, path: Path) -> u32 {
    if ci == &null { return u32(-1); }
    return ci->sm()->load_file(path);
}

/// \brief maps ParseOptions::stop_at onto the invocation's frontend action.
///
/// \details The stage gates already exist   FrontendOptions::stops_at_parse()
///          and friends, checked by FrontendAction::run(). This just selects
///          the action kind that produces the gate the caller asked for.
fn _apply_stop_at(ci: *CompilerInstance, stop_at: TUStage) -> FrontendActionKind {
    var fe  = &((ci->invocation()).frontend);
    var old = fe->action;

    if      stop_at <= TUStage::Preprocessing { fe->action = FrontendActionKind::Preprocess;    }
    else if stop_at <= TUStage::Parsing       { fe->action = FrontendActionKind::SyntaxOnly;    }
    else if stop_at <= TUStage::Sema          { fe->action = FrontendActionKind::TypeCheckOnly; }

    return old;
}

/// \brief runs the frontend over \p path and returns its AST.
///
/// \details Reuses FrontendAction rather than reimplementing the pipeline, so
///          tools get exactly the compiler's load/preprocess/parse behaviour
///          and stay correct as it evolves.
///
/// \pre CompilerInstance::initialize(cwd) must have run   it builds the
///      ImportResolver and PreProcessor this depends on.
fn parse_file(ci: *CompilerInstance, path: Path, opts: ParseOptions) -> ParsedUnit {
    if ci == &null { return ParsedUnit::failure(u32(-1), TUStage::Failed); }

    if opts.fidelity == ParseFidelity::Verbatim {
        ci->diag()->report(DiagID::U001F,
            "Verbatim parse fidelity is not implemented: the AST has no node for "
            "an unexpanded macro invocation").emit();
        return ParsedUnit::failure(u32(-1), TUStage::Failed);
    }

    if ci->imp() == &null {
        ci->diag()->report(DiagID::U001F,
            "parse_file: CompilerInstance::initialize(cwd) has not run").emit();
        return ParsedUnit::failure(u32(-1), TUStage::Failed);
    }

    var err0 = ci->diag()->error_count();
    var wrn0 = ci->diag()->warn_count();

    var prev_action = _apply_stop_at(ci, opts.stop_at);
    finally { ((ci->invocation()).frontend).action = prev_action; }

    // Swap the engine's consumers for a collector so nothing prints. Restored
    // unconditionally   a tool that leaves the driver's consumers detached
    // would silence the rest of the process.
    var collector = std::create::<ToolDiagConsumer>(ci->sm());
    finally { std::destroy(collector); }

    var saved = vec::<obs::<DiagConsumer>>();
    if opts.capture_diags {
        saved = ci->diag()->take_consumers();
        ci->diag()->add_consumer(collector);
    }
    finally {
        if opts.capture_diags { ci->diag()->restore_consumers(saved); }
    }

    var action = std::create::<FrontendAction>(
        path, ModulePath(), ci->global_scope(), ci->imp(), ci);
    finally { std::destroy(action); }

    action->run();

    var u = ParsedUnit{};
    u.fid      = action->file_id();
    u.fids     = action->fids();
    u.stage    = action->stage();
    u.errors   = ci->diag()->error_count() - err0;
    u.warnings = ci->diag()->warn_count()  - wrn0;
    if opts.capture_diags { u.diags = collector->diags; }

    if u.fid == u32(-1) { u.ok = false; return u; }

    u.ctx = ci->global_scope()->get_context(u.fid);
    if u.ctx == &null { u.ok = false; return u; }

    u.tu = reinterpret_cast::<*TranslationUnit>(u.ctx->tu);
    u.ok = (u.tu != &null) && (!ci->diag()->has_fatal());

    if u.fids.empty() && (u.fid != u32(-1)) { u.fids.push_back(u.fid); }
    return u;
}

/// \brief parse_file for a fid already loaded into the SourceManager.
///
/// \details A fid is not something a caller can hold before calling   it comes
///          from load()   so this resolves back to the path and defers. The
///          SourceManager hands back the same fid for an already-loaded file,
///          so nothing is re-read.
fn parse_fid(ci: *CompilerInstance, fid: u32, opts: ParseOptions) -> ParsedUnit {
    if ci == &null { return ParsedUnit::failure(fid, TUStage::Failed); }

    var name = ci->sm()->get_filename(fid);
    if name.empty() { return ParsedUnit::failure(fid, TUStage::Failed); }

    return parse_file(ci, Path(name), opts);
}

/// \brief releases everything \p unit produced, from \p from onward.
///
/// \details Thin wrapper over CompilerInstance::release for callers holding a
///          ParsedUnit. Nothing is reclaimed until the CI dies otherwise, so a
///          tool walking a tree MUST call this per file or it holds every AST
///          it has ever parsed.
///
/// \warning Invalidates unit.ctx, unit.tu, and every node reached through
///          them. Refuses while another live TU still imports this fid.
fn release(ci: *CompilerInstance, unit: ref!(ParsedUnit), from: TUStage) -> bool {
    if ci == &null            { return false; }
    if unit.fid == u32(-1)    { return false; }
    return ci->release(unit.fid, from);
}

/// \brief parses in-memory source, no file on disk.
///
/// \details Identical to parse_file downstream   only the SourceManager entry
///          point differs (load_virtual vs load_file). \p vname is the logical
///          name diagnostics and ranges report against.
///
///          This replaces Parser/ParseSource.k, which tried to own its own
///          ThreadPool/VFM/SourceManager/PP stack and was never finished. A
///          snippet is not special: it is a fid like any other, and it should
///          go through the same pipeline as a real file so tests exercise what
///          the compiler actually does.
///
/// \warning \p code IS NOT COPIED. VirtualFileManager::register_virtual calls
///          attach_raw() on the pointer, so the SourceManager holds a VIEW.
///          \p code must outlive the returned unit   until release(), or until
///          the CompilerInstance dies.
///
///          It is a narrow libcxx::string rather than a Kairo string because
///          the buffer is a BYTE view; Kairo's string is wchar-backed and its
///          raw_string() would hand over wide characters. Convert once at the
///          call site and keep it alive:
///
///              var owned = libcxx::string(std::string_to_nstring(src));
///              var u     = parse_string(ci, owned, "<snippet>", opts);
fn parse_string(
    ci:    *CompilerInstance,
    code:   ref!(libcxx::string),
    vname:  string,
    opts:   ParseOptions
) -> ParsedUnit {
    if ci == &null { return ParsedUnit::failure(u32(-1), TUStage::Failed); }

    var bytes = reinterpret_cast::<std::ConstPtr::<u8>>(code.data());
    var fid   = ci->sm()->load_virtual(Path(vname), bytes, code.size());
    if fid == u32(-1) { return ParsedUnit::failure(u32(-1), TUStage::Failed); }

    return parse_fid(ci, fid, opts);
}

/// \brief stands up a CompilerInstance from \p inv, parses one file, returns both.
///
/// \details The one-shot entry point. parse_file() needs a caller-owned CI that
///          has already had initialize(cwd) run on it; this does that setup and
///          hands back a value that owns its own teardown.
///
///          There are deliberately no per-flag parameters here   no `includes`,
///          no `defines`. Options go in the invocation, which is the typed
///          representation of exactly that, and adding a second way to spell
///          them would mean two things to keep in sync. Include dirs:
///
///              var inv = CompilerInvocation();
///              inv.include_dirs.push_back("Compiler");
///              var o = parse_once(Path("x.k"), &inv, TUStage::Parsing);
///
/// \details \p inv is COPIED into the instance (see CompilerInstance(inv)), so
///          a stack temporary is fine and nothing has to outlive the call.
///
///          Diagnostics are always captured   a one-shot caller has no other
///          way to see them, since the CI is gone before it could ask. Read
///          them off `result.unit.diags`.
///
/// \param inv      the options for this parse. May be null   the result is a
///                 failure unit.
/// \param stop_at  last stage to run. Parsing for syntax tools, Sema if you
///                 need types resolved.
fn parse_once(path: Path, inv: *CompilerInvocation, stop_at: TUStage) -> OwnedUnit {
    var ci = std::create::<CompilerInstance>(inv);

    if !ci->args_ok() {
        std::destroy(ci);
        return OwnedUnit::failure(TUStage::Failed);
    }

    // parse_file() hard-requires this   it reports U001F and bails otherwise.
    ci->initialize(Path::cwd());

    var opts = ParseOptions{};
    opts.stop_at       = stop_at;
    opts.capture_diags = true;

    var o = OwnedUnit();
    o.adopt(ci);                      // owned from here; dtor tears it down
    o.unit = parse_file(ci, path, opts);
    return o;
}

/// \brief parse_once for a caller that has an argv rather than an invocation.
///
/// \details Delegates: argv becomes a CompilerInvocation via
///          CompilerInvocation::from_args, and everything past that point is
///          the overload above. \p argv is read here and not retained   the
///          invocation holds owned copies   so the caller's buffers may die as
///          soon as this returns.
///
/// \note from_args needs somewhere to report flag errors and there is no
///       CompilerInstance yet, so this stands up a throwaway DiagEngine with a
///       collector on it. A bad command line therefore comes back as a failure
///       unit whose `diags` hold the flag errors, rather than as silence.
fn parse_once(
    path:    Path,
    argc:    i32,
    argv:   *(*kairo::std::Legacy::char),
    stop_at: TUStage
) -> OwnedUnit {
    var diag = std::create::<DiagEngine>();
    var sink = std::create::<ToolDiagConsumer>(&null); // no SM yet; flag errors carry no loc
    diag->add_consumer(sink);

    var inv      = CompilerInvocation::from_args(argc, argv, diag);
    var flag_err = sink->diags;

    diag->remove_consumer(sink);
    diag->clear_retained();
    std::destroy(sink);
    std::destroy(diag);

    if !inv.ok {
        var bad = OwnedUnit::failure(TUStage::Failed);
        bad.unit.diags = flag_err;
        return bad;
    }

    return parse_once(path, &inv, stop_at);
}

/// \brief parse_once with the common defaults: stock options, stop after parse.
fn parse_once(path: Path) -> OwnedUnit {
    var inv = CompilerInvocation();
    return parse_once(path, &inv, TUStage::Parsing);
}

/// \brief re-reads and re-parses ONE fid. Nothing else in the graph is touched.
///
/// \details The edit path, and deliberately a narrow one. Given a fid that is
///          already part of a parsed graph, this:
///
///            1. releases that fid's artifacts (AST, context, tokens, imm
///               table, walked mark, macros),
///            2. re-maps its buffer from disk and rebuilds its line index,
///            3. re-lexes, re-walks it through the preprocessor ALONE,
///            4. re-indexes and re-parses it.
///
///          Every OTHER file keeps its mapping, tokens, context and AST. On a
///          148-file graph that is the difference between reparsing one file
///          and reparsing all of them.
///
/// \par What this does NOT do
///      The preprocessor pass is partial ON PURPOSE   no DepScanner, no import
///      graph, no wave executor. Consequences the caller must accept:
///
///        - An import ADDED by the edit is not resolved and its file is not
///          loaded. Names from it will not resolve. \c added_imports on the
///          result reports how many edges the file now has that are not backed
///          by a live context, so this is detectable rather than silent.
///        - An import REMOVED by the edit leaves the formerly-imported file
///          loaded and parsed. Harmless, just not reclaimed.
///        - Macros this file exports are re-registered, so importers that were
///          already parsed keep pointing at the PREVIOUS expansion. Anything
///          that depends on this file's macros must be reparsed too.
///
///      In short: correct for edits inside a file's own body, which is the
///      common keystroke. For an edit to the import block, run parse_file().
///
/// \pre \p fid must already be loaded (a previous parse_file/load).
/// \pre No other parse may be in flight   this re-maps a buffer other threads
///      could be reading.
///
/// \return a ParsedUnit for \p fid alone; \c fids holds just this fid.
fn reparse(ci: *CompilerInstance, fid: u32, opts: ParseOptions) -> ParsedUnit {
    if ci == &null         { return ParsedUnit::failure(fid, TUStage::Failed); }
    if fid == u32(-1)      { return ParsedUnit::failure(fid, TUStage::Failed); }
    if ci->imp() == &null  {
        ci->diag()->report(DiagID::U001F,
            "reparse: CompilerInstance::initialize(cwd) has not run").emit();
        return ParsedUnit::failure(fid, TUStage::Failed);
    }

    // The module path is a property of the file's position in the import graph,
    // not of its bytes, so it has to survive the release   and the context that
    // holds it is about to be destroyed. Capture before invalidating.
    var mod_path = ModulePath();
    var old_ctx  = ci->global_scope()->get_context(fid);
    if old_ctx != &null { mod_path = old_ctx->module_base; }

    var err0 = ci->diag()->error_count();
    var wrn0 = ci->diag()->warn_count();

    var collector = std::create::<ToolDiagConsumer>(ci->sm());
    finally { std::destroy(collector); }

    var saved = vec::<obs::<DiagConsumer>>();
    if opts.capture_diags {
        saved = ci->diag()->take_consumers();
        ci->diag()->add_consumer(collector);
    }
    finally {
        if opts.capture_diags { ci->diag()->restore_consumers(saved); }
    }

    var u = ParsedUnit{};
    u.fid = fid;
    u.fids.push_back(fid);

    // Captured BEFORE invalidate, which is what releases them.
    u.invalidated = ci->transitive_importers(fid);

    // 1 + 2: drop artifacts, re-read the bytes, rebuild the line index.
    if !ci->invalidate(fid) {
        ci->diag()->report(DiagID::U001F,
            f"reparse: cannot re-read fid={fid}").emit();
        u.stage = TUStage::Failed;
        if opts.capture_diags { u.diags = collector->diags; }
        return u;
    }

    // 3: this file's own preprocess. No graph walk.
    u.stage = TUStage::Preprocessing;
    if !ci->pp()->preprocess_one(fid, mod_path) {
        u.stage = TUStage::Failed;
        u.errors = ci->diag()->error_count() - err0;
        u.warnings = ci->diag()->warn_count() - wrn0;
        if opts.capture_diags { u.diags = collector->diags; }
        return u;
    }

    u.ctx = ci->global_scope()->get_context(fid);
    if u.ctx == &null {
        u.stage = TUStage::Failed;
        if opts.capture_diags { u.diags = collector->diags; }
        return u;
    }

    if opts.stop_at > TUStage::Preprocessing {
        // 4: index then parse, both single-fid, both on this thread. The batch
        // path fans these across the pool and runs an ordered diag flusher
        // behind them; with one file there is nothing to order or overlap.
        u.stage = TUStage::Parsing;
        ci->parse_one(fid);
        u.ctx->diag_sink.drain_into(ci->diag());
    }

    u.tu = reinterpret_cast::<*TranslationUnit>(u.ctx->tu);
    u.errors   = ci->diag()->error_count() - err0;
    u.warnings = ci->diag()->warn_count()  - wrn0;
    u.ok       = (u.tu != &null) && (!ci->diag()->has_fatal());
    u.added_imports = ci->unresolved_import_count(fid);
    if opts.capture_diags { u.diags = collector->diags; }

    if u.added_imports > 0 {
        Logger::warn(Logger::Stage::Driver,
            f"reparse: fid={fid} has {u.added_imports} import(s) with no live target; "
            "single-file reparse does not resolve imports   run parse_file() to make this unit whole");
    }

    if u.stage != TUStage::Failed { u.stage = opts.stop_at; }
    return u;
}

/// \brief releases every registered fid, dependency order handled internally.
///
/// \details release() refuses while another live TU still imports the fid, so
///          a caller sweeping a whole batch has to release LEAVES LAST   the
///          importers first. Rather than make every caller know the graph
///          order, repeat until a full pass frees nothing: each pass removes
///          the current importers and exposes the next layer.
///
///          A tool walking a directory needs this. Nothing is reclaimed until
///          the CompilerInstance dies otherwise, so kfmt over a large tree
///          would hold every AST it has ever parsed.
///
/// \return the number of fids released.
fn release_all(ci: *CompilerInstance, from: TUStage) -> usize {
    if ci == &null { return 0; }

    var freed: usize = 0;
    var progress     = true;

    while progress {
        progress = false;
        for f: u32 in ci->global_scope()->all_fids() {
            if ci->release(f, from) {
                freed   += 1;
                progress = true;
            }
        }
    }

    return freed;
}
