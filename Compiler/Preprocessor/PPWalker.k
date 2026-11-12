/// --- The Kairo Project ---------------------- Preprocessor/PPWalker.k --- ///
///
///   PPWalker: the preprocessor walk over one file, run in wave order.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "algorithm"

import AST::Context::ASTContext::ASTContext
import AST::Context::TranslationUnit::{
    ImportEdge,
    TranslationUnit,
}
import AST::LangItems::{
    LangIntrinsics,
    LangMacros,
    LowerTargets,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Mixin::FFILinkage::LinkageKind
import AST::Node::Declarations::{
    ImportDecl,
    ImportItem,
    ImportKind,
    MacroDecl,
    MacroParamSpec,
}
import AST::Node::Statements::{
    FFILang,
    ffi_lang_of_literal,
}
import Config::Invocation::CompilerInvocation
import Config::Preprocessor::PreprocessorOptions
import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Diagnostic::Severity::DiagSeverity
import Interop::Clang::HeaderSet::HeaderSet
import Interop::Clang::HeaderSetCache::HeaderSetCache
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Lexer::Lexer::Lexer
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Macro::Sentinel::MacroSentinel
import Parser::Shared::ImportGrammar::{
    ImportGrammar,
    ImportSpec,
}
import Parser::Shared::MacroHeaderGrammar::MacroHeaderGrammar
import Preprocessor::FileImportIndex::FileImportIndex
import Preprocessor::MacroTable::{
    MacroEntry,
    MacroTable,
}
import Preprocessor::PreprocessorSymbolTable::{
    PreprocessorSymbolTable,
    SymbolID,
}
import Preprocessor::ScopeTracker::{
    ModuleVisibility,
    ScopeTracker,
}
import Preprocessor::TokenSource::{
    InvokeHop,
    TokenSource,
}
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Support::TimeReport::{
    TimeRegion,
    TimeSampled,
    time_enabled,
    time_region,
}
import Token::IdentifierToken::IdentifierToken
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::TokenKind
import Token::TokenText::TokenText
import std::io

/// A PPWalker's one read of its file (PPWalker::_phase).
pub enum WalkPhase derives u8 {
    Fresh,      ///< constructed; set_* may still configure the read.
    Collecting, ///< collect_macros(): macro definitions only, nothing emitted.
    Walking,    ///< run(): the walk proper.
    Done,       ///< the read is over; the walker is only queried and destroyed.
}

pub class PPWalker
  derives ImportGrammar<PPWalker>,
          MacroHeaderGrammar<PPWalker> {
    priv var _splices:          cxx::std::vector<unsafe *TokenBuffer<512>> ///< frame backing; freed in finalize
    priv var _opts:             PreprocessorOptions
    priv var _src:              unsafe *TokenSource
    priv var _imports:          unsafe *FileImportIndex
    priv var _tracker:          unsafe *ScopeTracker
    priv var _out:              unsafe *TokenBuffer<512>
    priv var _ctx:              unsafe *ASTContext
    priv var _tu:               unsafe *TranslationUnit
    priv var _macros:           unsafe *MacroTable
    priv var _sym:              unsafe *PreprocessorSymbolTable
    priv var _sm:               unsafe *SourceManager
    priv var _tcm:              unsafe *TokenCacheManager
    priv var _diag:             unsafe *DiagEngine
    priv var _imm:              unsafe *ImmediateTable
    priv var _lexer:            unsafe *Lexer
    priv var _inv:              *CompilerInvocation?
    priv var _sink:             unsafe *TokenBuffer<512>
    priv var _unique_tag_cache: llvm::StringMap<u32> ///< probed only, never iterated
    priv var _fid:              u32                                        = u32::MAX //< invalid sentinel
    priv var _expansion_count:  i32                                        = 0
    /// Outermost-invocation sites whose chain already hit --cmax-macro-depth.
    /// Every deeper hop of a runaway chain trips the same limit; one R008E per
    /// chain says it, the rest are noise that buries the real error.
    priv var _depth_reported: llvm::DenseSet<u64> ///< `raw as u64`: any u32 raw location is a valid key
    /// `defined!` invocations passed through to the parser (by the name
    /// token's location), so the rescan of their own output does not take
    /// them for an invocation again.
    priv var _defined_raw:    llvm::DenseSet<u64>     ///< `raw as u64`, as _depth_reported
    priv var _unique_counter: u32                 = 0

    /// ffi headers this file imports, spelled as HeaderSet::unquote does,
    /// deduped, in SOURCE ORDER: the key of the one HeaderSet _finalize
    /// requests. Order is part of the key because it is part of the meaning:
    /// a header may depend on what an earlier one declared or defined.
    priv var _ffi_headers: cxx::std::vector<string>
    /// Parallel to _ffi_headers: written `ffi "c"`. Carried into the set so
    /// the C ones are parsed, and linked, as extern "C".
    priv var _ffi_c: cxx::std::vector<u8>
    /// Parallel to _ffi_headers: the header string's span. A clang error at
    /// the set's synthesized `#include` line reports here, not at <injected>.
    priv var _ffi_locs: cxx::std::vector<SourceRange>
    /// Null in tooling runs with no clang: ffi imports then resolve to nothing.
    priv var _headers: unsafe *HeaderSetCache = &null

    /// # Pass timing (--time-passes)
    ///
    ///   Handles resolved once in run(), null when timing is off   which is
    ///   what makes the sampled scopes below cost a single null check on the
    ///   per-token path. Counters are per-walker, hence per-file and per-thread;
    ///   a shared counter would put a contended cache line in the token loop,
    ///   which is the exact cost sampling exists to avoid.

    priv var _t_detect: unsafe *kairo::KTimeRecord = &null
    priv var _t_emit:   unsafe *kairo::KTimeRecord = &null
    /// The builtin module's scope, searched after this file's own imports
    /// (PreProcessor::_walk_one sets it on every file outside the builtin
    /// root). Unset for the builtin files and with the prelude off.
    priv var _prelude:     ModulePath
    priv var _has_prelude: bool       = false
    priv var _c_detect:    u32        = 0
    priv var _c_emit:      u32        = 0

    /// # Import cycles (PreProcessor::_prelex_cycles)

    /// Where this walker is. A walker does ONE read of its file: either
    /// collect_macros() (an import cycle's first read) or run(), never both
    /// (the collecting walker is destroyed, and the walk gets a new one told
    /// assume_macros_known()). Collecting: nothing is emitted, and only macro
    /// definitions and scope tokens are acted on. The set_* configuration
    /// belongs before the read, while the walker is Fresh: the token source
    /// takes its replay frame before the first pull.
    priv var _phase: WalkPhase = WalkPhase::Fresh
    /// This file's macros are registered already: by collect_macros() on an
    /// earlier walker (assume_macros_known), or by this one's own collect.
    /// run() steps over each definition instead of defining it again.
    priv var _macros_known: bool = false
    /// ig_err is silent: the grammar is re-read for its tokens alone, and
    /// whatever it had to say was said on the first read. Only ever turned
    /// on around one grammar call, saved before and restored after (never
    /// set then cleared), so a nested quiet read cannot unmute the outer
    /// one; the calls that sit in a block of their own restore it in a
    /// `finally`, so no exit from that block leaves the walk muted.
    priv var _quiet: bool = false

    fn PPWalker(self,
                fid:         u32,
                lexer:       unsafe *Lexer,
                ctx:         unsafe *ASTContext,
                tu:          unsafe *TranslationUnit,
                macros:      unsafe *MacroTable,
                resolver:    unsafe *ImportResolver,
                sym:         unsafe *PreprocessorSymbolTable,
                sm:          unsafe *SourceManager,
                tcm:         unsafe *TokenCacheManager,
                diag:        unsafe *DiagEngine,
                opts:        PreprocessorOptions,
                module_base: ModulePath,
                headers:     unsafe *HeaderSetCache = &null) {
        self._fid     = fid
        self._headers = headers
        self._lexer   = lexer
        self._ctx     = ctx
        self._tu      = tu
        self._macros  = macros
        self._sym     = sym
        self._sm      = sm
        self._tcm     = tcm
        self._diag    = diag
        self._opts    = opts
        self._imm     = lexer->get_imm_tbl()
        self._out     = kairo::std::create<TokenBuffer<512>>()
        self._src     = kairo::std::create<TokenSource>(lexer, opts.max_token_count, diag)
        self._src->set_preserve_comments(opts.preserve_comments)
        self._src->set_file_name(sm->get_filename(fid))
        self._imports = kairo::std::create<FileImportIndex>(
            sym,
            sm,
            tcm,
            resolver,
            macros,
            diag,
            fid,
        )

        self._tracker = kairo::std::create<ScopeTracker>(sym, sm, self._imm, tcm, module_base)
        self._sink    = self._out
    }

    /// \brief the prelude for macros: the file behaves as though it wrote
    ///        `import builtin::*` (Compiler/Spec/Panic.md#where-nothing-may-leave: `crash!` is a plain macro
    ///        in Lib/builtin), searched after its own imports so an explicit
    ///        import, or the file's own macro, of the same name wins.
    fn set_prelude_scope(self, const scope: ModulePath) {
        eval if defined!(DEBUG) {
            self._check_fresh("set_prelude_scope")
        }

        self._prelude     = scope
        self._has_prelude = true
    }

    /// \brief an import the file did not write: a prelude-shaped wildcard
    ///        of \p target (an f256 / f512 class file, P723). Called after
    ///        run(), so the TU gets it where the driver's builtin prelude
    ///        import also lands, after every written one. Its edge orders
    ///        Sema (the class is typed first, its N binding the lang item),
    ///        and it binds the class's names as the builtin root's
    ///        re-export did when every program loaded it.
    fn add_implicit_import(self, target: u32) {
        var rng = SourceRange::invalid()
        if self._sm != &null {
            var loc = self._sm->get_loc(self._fid, 0)
            rng = SourceRange(loc, loc)
        }

        var unsafe *id = ImportDecl::create(self._ctx, rng, ImportKind::Native)
        id->is_wildcard    = true
        id->is_prelude     = true
        id->resolved_fid   = target
        id->file_seg_count = 1
        self._tu->imports.push(id)

        var edge = ImportEdge{}
        edge.target_fid = target
        edge.decl       = id
        self._tu->import_edges.push(edge)
    }

    // Not transferable: it owns its output, sources and tracker and is addressed by the parsers it drives; a copy would free them twice.
    @copy fn PPWalker(self, const other: Self) = delete

    fn op finally (self) {
        if self._out != &null {
            kairo::std::destroy(self._out)
            self._out = &null
        }

        for b in self._splices {
            kairo::std::destroy(b)
        }

        self._splices.clear()

        if self._src != &null {
            kairo::std::destroy(self._src)
            self._src = &null
        }

        if self._imports != &null {
            kairo::std::destroy(self._imports)
            self._imports = &null
        }

        if self._tracker != &null {
            kairo::std::destroy(self._tracker)
            self._tracker = &null
        }
    }

    /// # shared-grammar host surface (raw kinds; stream is pre-expansion)

    fn ig_kind(self) -> TokenKind {
        var t = self._src->peek(0)
        return t.kind
    }

    fn ig_peek_kind(self) -> TokenKind {
        var t = self._src->peek(1)
        return t.kind
    }

    fn ig_tok(self) -> Token {
        return self._src->peek(0)
    }

    fn ig_bump(self) {
        self._src->next()
    }

    fn ig_bump_nl(self) {
        self._src->next()
        while self._src->peek(0).kind == TokenKind::TkNewLine {
            self._src->next()
        }
    }

    fn ig_eof(self) -> bool {
        return self._src->at_eof()
    }

    fn ig_err(self, r: SourceRange, const msg: string, code: DiagID) {
        if self._quiet {
            return
        }

        self._diag->report(DiagCode(code), r.start, msg).first(r)->emit()
    }

    fn ig_err_remove(self,
                     r:             SourceRange,
                     const msg:     string,
                     code:          DiagID,
                     cut:           SourceRange,
                     const fix_msg: string) {
        if self._quiet {
            return
        }

        var b = self._diag->report(DiagCode(code), r.start, msg)
        b.first(r)
        b.remove(cut, fix_msg)
        b.emit()
    }

    fn ig_err_insert(self,
                     r:             SourceRange,
                     const msg:     string,
                     code:          DiagID,
                     at:            SourceRange,
                     const text:    string,
                     const fix_msg: string) {
        if self._quiet {
            return
        }

        var b = self._diag->report(DiagCode(code), r.start, msg)
        b.first(r)
        b.insert(at.start, text, fix_msg)
        b.emit()
    }

    /// Frame 0 from tokens already lexed (TokenSource::set_replay).
    fn set_replay(self, toks: unsafe *cxx::std::vector<Token>) {
        eval if defined!(DEBUG) {
            self._check_fresh("set_replay")
        }

        self._src->set_replay(toks)
    }

    /// collect_macros() ran for this file on an earlier walker.
    fn assume_macros_known(self) {
        eval if defined!(DEBUG) {
            self._check_fresh("assume_macros_known")
        }

        self._macros_known = true
    }

    /// Debug builds: \p what configures the read, so it must come before it.
    priv fn _check_fresh(self, what: string) {
        if self._phase != WalkPhase::Fresh {
            kairo::std::ice_fail(f"PPWalker::{what} after the walker started reading (phase {self._phase as u8 as u32})")
        }
    }

    /// The macro DEFINITIONS of this file, registered ahead of its walk.
    ///
    /// \details A file sees an imported macro only once the file defining it
    ///          has been walked, and the waves walk an importee first. On an
    ///          import cycle there is no such order: one side of every cycle
    ///          is walked before a file it imports, and its uses of that
    ///          file's macros found nothing. So every file on a cycle runs
    ///          this first (PreProcessor::_prelex_cycles), and the walks then
    ///          see every macro of the cycle whatever their order. It acts
    ///          only on what a definition needs: `macro` (and its visibility),
    ///          and the `module` blocks and braces that give it its scope.
    ///          Imports are stepped over, silently, so their braces are not
    ///          read as scopes; nothing is emitted or expanded. A macro
    ///          body is raw tokens, so no definition needs another file's
    ///          macros to be read.
    fn collect_macros(self) {
        eval if defined!(DEBUG) {
            self._check_fresh("collect_macros")
        }

        self._phase = WalkPhase::Collecting
        while !self._src->at_eof() {
            var t = self._src->peek(0)
            var k = t.kind
            if k == TokenKind::TkEof {
                break
            }

            if k == TokenKind::KwImport {
                {
                    var was = self._quiet
                    self._quiet = true
                    finally {
                        self._quiet = was
                    }

                    self.parse_import_spec()
                }

                continue
            }

            if k == TokenKind::KwMacro {
                self._handle_macro_def(VisibilityKind::Public)
                continue
            }

            if k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt {
                var vis =      if (k == TokenKind::KwPub) => (VisibilityKind::Public)
                          else if (k == TokenKind::KwPriv) => (VisibilityKind::Private)
                          else => VisibilityKind::Protected
                var nk = self._src->peek(1).kind
                if nk == TokenKind::KwImport {
                    self._src->next()
                    {
                        var was = self._quiet
                        self._quiet = true
                        finally {
                            self._quiet = was
                        }

                        self.parse_import_spec()
                    }

                    continue
                }

                if nk == TokenKind::KwMacro {
                    self._src->next()
                    self._handle_macro_def(vis)
                    continue
                }

                if nk == TokenKind::KwModule {
                    var mv =      if (k == TokenKind::KwPub) => (ModuleVisibility::Public)
                             else if (k == TokenKind::KwPriv) => (ModuleVisibility::Private)
                             else => ModuleVisibility::Protected
                    self._src->next()
                    self._track_scope(self._src->peek(0), mv)
                    continue
                }

                self._src->next()
                continue
            }

            if self._track_scope(t, ModuleVisibility::Public) {
                continue
            }

            self._src->next()
        }

        self._phase        = WalkPhase::Done
        self._macros_known = true
    }

    /// A macro definition collect_macros() already registered: its tokens,
    /// consumed exactly as _handle_macro_def consumes them, and nothing else
    /// -- no second MacroDecl, no duplicate-definition error, no diagnostic
    /// the first read already gave.
    priv fn _skip_macro_def(self) {
        var kw = self._src->next() // `macro`
        if self._src->peek(0).kind == TokenKind::OpAt {
            self._emit(kw)
            return
        }

        var was = self._quiet
        self._quiet = true
        var hdr = self.parse_macro_header()
        self._quiet = was
        if !hdr.ok {
            self._recover_to_terminator()
            return
        }

        var builtin = self._is_builtin_name(TokenText::spelling(hdr.name, self._tcm))
        if self._src->peek(0).kind != TokenKind::OpLBrace {
            if builtin {
                self._recover_to_terminator()
            }

            return
        }

        self._src->next() // `{`
        var d: i32 = 1
        while !self._src->at_eof() && d > 0 {
            var t = self._src->next()
            if t.kind == TokenKind::OpLBrace {
                d += 1
            }

            if t.kind == TokenKind::OpRBrace {
                d -= 1
            }
        }

        if builtin {
            return
        }

        if d == 0 && self._src->peek(0).kind == TokenKind::OpSemicolon {
            self._src->next()
        }
    }

    //  The walk

    fn run(self) -> bool {
        eval if defined!(DEBUG) {
            self._check_fresh("run")
        }

        self._phase = WalkPhase::Walking
        finally {
            self._phase = WalkPhase::Done
        }

        // Resolved once per file, under the Walk region the wave opened. The
        // per-token scopes below check these for null before anything else, so
        // leaving them null when timing is off makes the instrumentation free.
        if time_enabled() {
            self._t_detect = time_region("Detect")
            self._t_emit   = time_region("Emit")
        }

        while !self._src->at_eof() {
            var t = self._src->peek(0)
            var k = t.kind

            if k == TokenKind::TkEof {
                break
            }

            if k == TokenKind::KwFfi {
                self._handle_ffi()
                continue
            }

            if k == TokenKind::KwImport {
                self._handle_import(VisibilityKind::Private)
                continue
            } // an import is priv by default

            if k == TokenKind::KwMacro {
                if self._macros_known { // a macro is pub by default
                    self._skip_macro_def()
                } else {
                    self._handle_macro_def(VisibilityKind::Public)
                }

                continue
            }

            if k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt {
                var vis =      if (k == TokenKind::KwPub) => (VisibilityKind::Public)
                          else if (k == TokenKind::KwPriv) => (VisibilityKind::Private)
                          else => VisibilityKind::Protected
                var nk = self._src->peek(1).kind
                if nk == TokenKind::KwImport {
                    self._src->next() // consume visibility keyword
                    self._handle_import(vis)
                    continue
                }

                if nk == TokenKind::KwMacro {
                    self._src->next()
                    if self._macros_known {
                        self._skip_macro_def()
                    } else {
                        self._handle_macro_def(vis)
                    }

                    continue
                }

                if nk == TokenKind::KwModule {
                    var mv =      if (k == TokenKind::KwPub) => (ModuleVisibility::Public)
                             else if (k == TokenKind::KwPriv) => (ModuleVisibility::Private)
                             else => ModuleVisibility::Protected
                    self._emit(self._src->next()) // vis keyword IS emitted the
                    // parser needs `pub module Foo {`
                    self._track_scope(self._src->peek(0), mv)
                    continue
                }

                self._emit(self._src->next()) // plain visibility on some other decl
                continue
            }

            // scope tracking off structural tokens (module/braces)
            if self._track_scope(t, ModuleVisibility::Public) {
                continue
            }

            // invocation?
            //
            // Timed INSIDE _detect_invocation, not around this call: hoisting
            // the result out of a timing block would copy an InvocationInfo
            // (three vectors) on every token. Pessimizing the preprocessor to
            // measure the preprocessor is a bad trade.
            var inv = self._detect_invocation()
            if inv.found {
                var _tx = TimeRegion("Expand")
                self._expand(unsafe &inv)
                continue
            }

            var chain    = cxx::std::vector<InvokeHop>()
            var next_tok = self._src->next_with_origin(&chain)
            self._emit(next_tok, unsafe &chain)
        }

        {
            var _tf = TimeRegion("Finalize")
            self._finalize()
        }

        return !self._diag->has_fatal()
    }

    //  Emission single choke point + disallow backstop

    /// \param chain the token's macro-origin chain, as captured atomically by
    ///        TokenSource::next_with_origin at the moment it was pulled.
    ///        &null (the default) for call sites that don't route through
    ///        next_with_origin (ffi/vis-keyword passthrough, scope-tracked
    ///        brace/module tokens, the poison sentinel): those tokens are
    ///        never origin-wrapped, same as before this existed.
    priv fn _emit(self, t: Token, chain: unsafe *cxx::std::vector<InvokeHop> = &null) {
        // Sampled, same reasoning as _detect_invocation: the single choke
        // point every token passes through.
        var _t = TimeSampled(self._t_emit, 64, unsafe &self._c_emit)
        if self._phase == WalkPhase::Collecting { // collect_macros: a read, not a walk.
            return
        }

        if self._src->in_splice() {
            if t.kind == TokenKind::KwImport || t.kind == TokenKind::KwMacro {
                // BACKSTOP (primary check is at def time). To lift the rule:
                // delete this block and route these kinds into the walk switch.
                self._diag->report(
                    DiagCode(DiagID::R012E),
                    self._src->top_invoke_loc().start,
                    "macro expansion may not produce 'import' or 'macro' declarations",
                ).first(self._src->top_invoke_loc())->emit()
                return
            }
        }

        t = self._expand_fstring(t, chain)

        if chain != &null && chain->size() > 0 {
            self._wrap_origin(&t, *chain)
        }

        self._sink->append(t)
    }

    /// \brief stamps `t` with a real macro-expansion origin: TkMacroExpand at
    ///        the OUTERMOST invocation's position, `imm` pointing at a chain
    ///        of MacroExpansionInfo records (one per active frame) that
    ///        ASTParse::report_tok/attach_macro_expansion_chain already know
    ///        how to walk back to the true definition-site identity.
    ///
    ///        No-op for a token that's already TkMacroExpand (a poison/builtin
    ///        sentinel, or one wrapped by a deeper nested expansion already --
    ///        re-wrapping would shadow the sentinel/chain it already carries).
    ///
    ///        `chain` is OUTERMOST-first (see next_with_origin). The FIRST
    ///        record built here must be the one attach_macro_expansion_chain's
    ///        walk reaches LAST (since it walks from `t.imm` outward), so this
    ///        builds outermost-to-innermost, chaining each new record's
    ///        original_kind/imm at the PREVIOUS one, and keeps the innermost
    ///        (built last) as `t`'s new imm -- the walk then reports the
    ///        closest cause first and the true call site last, terminating on
    ///        the real original identity.
    ///
    ///        Applies uniformly to body-literal AND argument-substituted
    ///        tokens alike (both flow through the same splice frame by the
    ///        time _emit sees them) -- an argument token's reported position
    ///        moves to the invocation site rather than staying at its own
    ///        (usually adjacent) column. Accepted imprecision: distinguishing
    ///        the two would need per-token provenance threaded out of
    ///        _substitute_body, which isn't worth the complexity here.
    priv fn _wrap_origin(self, t: *Token, const chain: cxx::std::vector<InvokeHop>) {
        if t->kind == TokenKind::TkMacroExpand {
            return
        }

        var cur_kind  = t->kind
        var cur_imm   = t->imm
        var def_range = t->range

        for var i: usize = 0; i < chain.size(); ++i {
            var hop = (chain)[i]

            var        idx   = self._imm->create<Immediate::MacroExpansionInfo>()
            var unsafe *info = self._imm->get<Immediate::MacroExpansionInfo>(idx)
            info->invoke_range  = hop.loc
            info->def_range     = def_range
            info->original_kind = cur_kind
            info->original_imm  = cur_imm
            info->macro_name    = hop.name
            info->parent_idx    = u32::MAX

            cur_kind = TokenKind::TkMacroExpand
            cur_imm  = idx
        }

        t->kind  = TokenKind::TkMacroExpand
        t->imm   = cur_imm
        t->range = (chain)[0].loc           // outermost invocation: the token's reportable position
    }

    //  Scope tracking
    //  ScopeTracker consumes from a TokenSpan today. On the stream we feed it
    //  one token at a time via a 1-token shim. The tracker only needs the
    //  current token + the ability to look at i+1 for `module Foo {`; we give
    //  it a 2-token window built from peeks. This is the one place the
    //  tracker's API forces a small adapter.

    priv fn _track_scope(self, t: Token, vis: ModuleVisibility) -> bool {
        var k = t.kind
        if k != TokenKind::OpLBrace && k != TokenKind::OpRBrace && k != TokenKind::KwModule {
            return false
        }

        self._tracker->feed_stream(self._src, vis, fn(tok: Token) { self._emit(tok) })
        return true
    }

    //  FFI

    priv fn _handle_ffi(self) {
        // Decide form by lookahead BEFORE emitting anything.
        //   peek0 = ffi, peek1 = "lang", peek2 = import | { | decl-lead
        var p2 = self._src->peek(2).kind

        // The language string belongs on the `ffi` line. A lone `ffi` used
        // to take the NEWLINE as its language and the next line's `import
        // "h"` as its own, silently (P993). Copied through instead, so the
        // parser reports it (S064E, "expected a language string") and the
        // next line is a statement of its own.
        if self._src->peek(1).kind != TokenKind::LitString {
            self._emit(self._src->next()) // ffi
            return
        }

        if p2 == TokenKind::KwImport {
            // ffi "lang" import "hdr" (as name)? ;  -> consume + drop the tokens
            //
            // The header is clang's to parse (Interop/Clang/HeaderSet). Every
            // ffi header this file imports joins ONE ordered list, requested
            // as a set in _finalize so the parse runs on the pool while this
            // file is still being walked and parsed. Sema/Foreign indexes the
            // set into one Kairo TU per header before sema, and the driver
            // then stamps resolved_fid and the include closure onto the node
            // built here (FrontendAction::_attach_ffi_edges). Nothing about
            // the header resolves HERE: its fids do not exist until the set
            // is indexed.
            var ffi_kw   = self._src->next() // ffi
            var lang_tok = self._src->next() // "lang"
            self._src->next() // import

            var header_tok = Token()
            var alias_tok  = Token()
            var has_alias  = false
            var last       = lang_tok
            var saw_header = false
            // One header per line, then an optional `as name` (imports.mdx,
            // c-cpp-calling.mdx). Anything else was dropped unread, so
            // `import {"a.h", "nope.h"}` imported only "a.h" and never looked
            // for the second (P993): the first stray token is S064E and the
            // line imports nothing.
            var bad = false
            while !self._src->at_eof() {
                if self._src->peek(0).kind == TokenKind::OpSemicolon {
                    last = self._src->next()
                    break
                }

                var t = self._src->next()
                if t.kind == TokenKind::TkNewLine {
                    break
                }

                last = t
                if !saw_header && t.kind == TokenKind::LitString {
                    header_tok = t
                    saw_header = true
                    continue
                }

                if saw_header && t.kind == TokenKind::KwAs && !has_alias {
                    if self._src->peek(0).kind == TokenKind::LitIdentifier {
                        alias_tok = self._src->next()
                        has_alias = true
                        last      = alias_tok
                    } else if !bad {
                        self.ig_err(t.range, "expected a name after 'as' in ffi import", DiagID::S064E)
                        bad = true
                    }

                    continue
                }

                if !bad {
                    var msg = "unexpected token in an ffi import; the form is 'ffi \"c++\" import \"header\"', optionally followed by 'as name'"
                    if t.kind == TokenKind::OpLBrace && !saw_header {
                        msg = "an ffi import takes one header, not a list; write one 'ffi \"c++\" import \"header\"' line per header"
                    }

                    self.ig_err(t.range, msg, DiagID::S064E)
                    bad = true
                }

                // A brace list may span lines: its `}` must not reach the
                // scope tracker or the parser.
                if t.kind == TokenKind::OpLBrace {
                    var depth: usize = 1
                    while !self._src->at_eof() && depth > 0 {
                        var u = self._src->next()
                        if u.kind == TokenKind::OpLBrace {
                            depth += 1
                        } else if u.kind == TokenKind::OpRBrace {
                            depth -= 1
                        }

                        last = u
                    }
                }
            }

            // `import "a.h" "b.h"`: adjacent literals are ONE token (the
            // lexer chains them), whose spelling is the first segment's, so
            // "b.h" was never looked for.
            if saw_header && !bad && self._chained_string(header_tok) {
                self.ig_err(
                    header_tok.range,
                    "an ffi import takes one header, not a list; write one 'ffi \"c++\" import \"header\"' line per header",
                    DiagID::S064E,
                )
                bad = true
            }

            if !saw_header && !bad {
                self.ig_err(
                    ffi_kw.range | last.range,
                    "expected a header path string after 'ffi \"...\" import'",
                    DiagID::S064E,
                )
                bad = true
            }

            if bad {
                return
            }

            var        fr        = ffi_kw.range | last.range
            var unsafe *fid_node = ImportDecl::create(self._ctx, fr, ImportKind::Native)
            fid_node->header    = header_tok
            fid_node->alias     = alias_tok
            fid_node->has_alias = has_alias
            fid_node->range     = fr
            fid_node->set_ffi_linkage(self._ffi_lang_kind(lang_tok), lang_tok, fr)
            self._tu->imports.push(fid_node)

            if saw_header {
                var h   = HeaderSet::unquote(self._ctx->get_spelling(header_tok))
                var dup = false
                for var i: usize = 0; i < self._ffi_headers.size(); ++i {
                    if self._ffi_headers[i] == h {
                        dup = true
                        break
                    }
                }

                if !dup && h.size() > 0 {
                    self._ffi_headers.push_back(h)
                    self._ffi_c.push_back((self._ffi_lang_kind(lang_tok) == LinkageKind::C) as u8)
                    self._ffi_locs.push_back(header_tok.range)
                }
            }

            return
        }

        // ffi "lang" { ... }  or  ffi "lang" <decl>  -> copy through.
        // Emit ffi + lang, then let the normal walk copy the rest. The block's
        // braces balance via ordinary emission; a single decl ends at its own
        // terminator. Nothing special needed just resume.
        self._emit(self._src->next()) // ffi
        self._emit(self._src->next()) // lang
        // walk resumes; `{`/decl tokens copy normally. Macro invocations INSIDE
        // an ffi block still expand (they did before) the walk doesn't treat
        // ffi-block interior as special, matching current behavior.
    }

    //  Imports

    priv fn _handle_import(self, default_vis: VisibilityKind) {
        var _t = TimeRegion("Import")

        // visibility already consumed by caller when prefixed; default_vis
        // carries Private unless caller saw pub/prot/priv.
        var vis = default_vis

        var spec = self.parse_import_spec() // shared grammar (consumes stmt)
        if !spec.ok {
            self._recover_to_terminator()
            return
        }

        // build the ImportDecl node into the TU (authority for klib)
        var unsafe *id = self._build_import_decl(&spec, vis)
        self._tu->imports.push(id)

        // resolve NOW; errors HERE. record() stamps id->resolved_fid and hands
        // back the source-module fid; a resolved import becomes a TU import
        // edge in declaration order (the one writer of import_edges). ffi
        // imports never reach here, so no edge is ever synthesized for them.
        // Resolved is file_seg_count, not a non-zero fid: fid 0 is the first
        // input, which a module it imports may import back (an import cycle
        // through the entry file), and that edge was dropped with the rest.
        var target_fid = self._imports->record(id)
        if id->file_seg_count > 0 {
            var edge = ImportEdge{}
            edge.target_fid = target_fid
            edge.decl       = id
            self._tu->import_edges.push(edge)
        }

        // consume trailing `;` if present (grammar leaves it)
        if self._src->peek(0).kind == TokenKind::OpSemicolon {
            self._src->next()
        }

        // NOTHING emitted import is PP-invisible in the output buffer.
    }

    priv fn _build_import_decl(self, spec: *ImportSpec, vis: VisibilityKind) -> unsafe *ImportDecl {
        var unsafe *id = ImportDecl::create(self._ctx, spec->range, spec->kind)

        var segs: kairo::std::StackBuf<Token, 8>
        for var i: usize = 0; i < spec->segments.size(); ++i {
            segs.push_back(spec->segments[i])
        }

        id->path_segments.from_buf_pp(segs.data(), (segs.size() as usize), self._ctx)
        id->last_seg_is_macro = spec->last_seg_is_macro
        id->is_wildcard       = spec->is_wildcard

        if spec->has_items {
            var items: kairo::std::StackBuf<ImportItem, 8>
            for var i: usize = 0; i < spec->items.size(); ++i {
                var *s                                  = &spec->items[i]
                var item                                = ImportItem{}
                var sub: kairo::std::StackBuf<Token, 4>
                for var j: usize = 0; j < s->sub_path.size(); ++j {
                    sub.push_back(s->sub_path[j])
                }

                item.sub_path.from_buf_pp(sub.data(), (sub.size() as usize), self._ctx)
                item.alias       = s->alias
                item.has_alias   = s->has_alias
                item.is_wildcard = s->is_wildcard
                item.is_macro    = s->is_macro
                item.range       = s->range
                items.push_back(item)
            }

            id->items.from_buf_pp(items.data(), (items.size() as usize), self._ctx)
            id->has_items = true
        }

        id->alias     = spec->alias
        id->has_alias = spec->has_alias
        id->set_visibility(vis, spec->range)
        id->range = spec->range
        return id
    }

    /// C when the parser's table (Statements::ffi_lang_of) says C, so
    /// `ffi "C"` is C here too; anything else -> Cpp. The parser owns the
    /// classification's diagnostic; the PP only needs enough to make
    /// has_ffi_linkage() true and to carry the language to codegen.
    priv fn _ffi_lang_kind(self, lang_tok: Token) -> LinkageKind {
        var s = *TokenText::resolve(lang_tok, self._tcm).get_text()
        if ffi_lang_of_literal(s) == FFILang::C {
            return LinkageKind::C
        }

        return LinkageKind::Cpp
    }

    //  Macro definitions

    priv fn _handle_macro_def(self, vis: VisibilityKind) {
        var _t = TimeRegion("MacroDef")

        var kw = self._src->next() // `macro`

        // proc macro `macro @name` copy through, not ours
        if self._src->peek(0).kind == TokenKind::OpAt {
            self._emit(kw)
            return // remaining @-macro tokens flow to output via the walk
        }

        var hdr = self.parse_macro_header() // shared grammar
        if !hdr.ok {
            self._recover_to_terminator()
            return
        }

        // builtin names are reserved: dispatch checks builtins before user
        // macros, so this definition could never fire. Reject loudly instead
        // of letting the builtin silently hijack every call site.
        var def_name = TokenText::spelling(hdr.name, self._tcm)
        if self._is_builtin_name(def_name) {
            self._diag->report(
                DiagCode(DiagID::R014E),
                hdr.name.range.start,
                f"macro '{def_name}!' redefines a compiler builtin; builtin names are reserved",
            ).first(hdr.name.range)->emit()

            // discard the balanced body so it doesn't leak into the output
            // stream; _recover_to_terminator stops at newlines and would
            // spill multi-line bodies.
            if self._src->peek(0).kind == TokenKind::OpLBrace {
                self._src->next() // `{`
                var d: i32 = 1
                while !self._src->at_eof() && d > 0 {
                    var t = self._src->next()
                    if t.kind == TokenKind::OpLBrace {
                        d += 1
                    }

                    if t.kind == TokenKind::OpRBrace {
                        d -= 1
                    }
                }
            } else {
                self._recover_to_terminator()
            }

            return
        }

        if self._src->peek(0).kind != TokenKind::OpLBrace {
            self._diag->report(
                DiagCode(DiagID::S038E),
                hdr.name.range.start,
                "expected '{' for macro body",
            ).first(hdr.name.range)->emit()
            return
        }

        var lbrace = self._src->next().range // `{`

        var unsafe *storage         = kairo::std::create<TokenBuffer<512>>()
        var        depth:       i32 = 1
        var        seen_content     = false

        while !self._src->at_eof() {
            var t = self._src->next()
            if t.kind == TokenKind::OpLBrace {
                depth += 1
            }

            if t.kind == TokenKind::OpRBrace {
                depth -= 1
                if depth == 0 {
                    break
                }
            }

            if t.kind == TokenKind::KwImport || t.kind == TokenKind::KwMacro {
                self._diag->report(
                    DiagCode(DiagID::R012E),
                    t.range.start,
                    "'import' and 'macro' are not allowed inside a token macro body",
                ).first(t.range)->emit()
            }

            if !seen_content && t.kind == TokenKind::TkNewLine { // leading trim
                continue
            }

            seen_content = true
            storage->append(t)
        }

        if depth != 0 {
            self._diag->report(
                DiagCode(DiagID::S039E),
                lbrace.start,
                "unmatched '{' in macro body",
            ).first(lbrace)->emit()
            kairo::std::destroy(storage)
            return
        }

        // trim edge newlines (THE newline fix)
        while storage->size() > 0
            && storage->get(storage->size() - 1)->kind == TokenKind::TkNewLine {
            storage->pop_back()
        }

        var lead: usize = 0
        while lead < storage->size() && storage->get(lead)->kind == TokenKind::TkNewLine {
            lead += 1
        }

        if lead > 0 {
            var unsafe *trimmed = kairo::std::create<TokenBuffer<512>>()
            for var i: usize = lead; i < storage->size(); ++i {
                trimmed->append(*storage->get(i))
            }

            kairo::std::destroy(storage)
            storage = trimmed
        }

        var body_len = (storage->size() as u32)

        // params + defaults appended after body
        var specs:      kairo::std::StackBuf<MacroParamSpec, 4>
        var is_variadic                                         = false
        for var i: usize = 0; i < hdr.params.size(); ++i {
            var *hp = &hdr.params[i]
            var sp  = MacroParamSpec{}
            sp.name     = hp->name
            sp.variadic = hp->variadic
            if hp->variadic != 0 {
                is_variadic = true
            }

            if hp->has_default {
                sp.has_default = true
                sp.default_off = (storage->size() as u32)
                for var j: usize = 0; j < hp->default_toks.size(); ++j {
                    storage->append(hp->default_toks[j])
                }

                sp.default_len = (storage->size() as u32) - sp.default_off
            }

            specs.push_back(sp)
        }

        if self._src->peek(0).kind == TokenKind::OpSemicolon {
            self._src->next()
        }

        // node into TU
        var unsafe *decl = MacroDecl::create(self._ctx, kw.range | lbrace, hdr.name)
        decl->params_spec.from_buf_pp(specs.data(), (specs.size() as usize), self._ctx)
        decl->accepts_params = hdr.accepts_params
        decl->is_variadic    = is_variadic

        if body_len > 0 {
            decl->body_span = storage->get(0)->range | storage->get((body_len as usize) - 1)->range
        }

        decl->set_visibility(vis, kw.range | lbrace)
        self._tu->macros.push(decl)

        var unsafe *entry = kairo::std::create<MacroEntry>()
        entry->decl       = decl
        entry->storage    = storage
        entry->body_len   = body_len
        entry->name_sym   = self._sym->intern(TokenText::spelling(hdr.name, self._tcm))
        entry->scope      = *self._tracker->current_scope() // the entry keeps its own copy
        entry->source_fid = self._fid
        entry->visibility = vis

        if !self._macros->register_macro(entry) {
            self._diag->report(
                DiagCode(DiagID::S040E),
                hdr.name.range.start,
                f"duplicate macro '{TokenText::spelling(hdr.name, self._tcm)}!' in this scope",
            ).first(hdr.name.range)->emit()
        }

        // NOTHING emitted.
    }

    //  Invocation detection + expansion
    //  _detect_invocation: PORT of MacroExpander::detect_invocation, retargeted
    //  to peeks on _src. Pattern unchanged: ident (:: ident)* ! ( ... )?.
    //  Critical difference: it must NOT consume until `found` is certain, then
    //  consume exactly the invocation. Because args need to be captured into a
    //  scratch buffer for pre-expansion, detection also copies the raw arg
    //  tokens (between balanced parens) into inv.arg_toks.

    struct InvocationInfo {
        var qualified:    ModulePath
        var chain:        cxx::std::vector<SymbolID>  ///< frame names live at detection
        var parent_chain: cxx::std::vector<InvokeHop> ///< full origin chain live at detection;
        ///  threaded into push_splice for
        ///  THIS invocation's own result
        ///  (see TokenSource::current_chain)
        var arg_toks:     cxx::std::vector<Token> ///< raw tokens between ( ), balanced
        var name:         Token
        var name_sym:     SymbolID                = 0
        var range:        SourceRange             = SourceRange::invalid()
        var origin_site:  SourceRange             = SourceRange::invalid() ///< outermost invoke loc at detection
        var is_qualified: bool                    = false
        var found:        bool                    = false
        var has_args:     bool                    = false
    }

    priv fn _detect_invocation(self) -> Self::InvocationInfo {
        // Sampled: runs on EVERY token and almost always answers no, so it is
        // both hot and a plausible bottleneck   exactly the case an unsampled
        // scope cannot measure without becoming the cost it is measuring.
        var _t = TimeSampled(self._t_detect, 64, unsafe &self._c_detect)

        var result = Self::InvocationInfo()

        result.origin_site = self._src->bottom_invoke_loc()
        self._src->snapshot_chain(&result.chain)
        self._src->current_chain(&result.parent_chain)

        if self._src->peek(0).kind != TokenKind::LitIdentifier {
            return result
        }

        /// ## try to parse a path: ident (:: ident)*
        var path_toks = cxx::std::vector<Token>()
        path_toks.push_back(self._src->peek(0))

        var n: usize = 1
        while true {
            if self._src->peek(n).kind != TokenKind::OpColonColon {
                break
            }

            if self._src->peek(n + 1).kind != TokenKind::LitIdentifier {
                break
            }

            path_toks.push_back(self._src->peek(n + 1))
            n += 2
        }

        /// ## expect `!` after the last identifier
        if self._src->peek(n).kind != TokenKind::OpExclaim {
            return result
        }

        var bang_offset = n

        var name_tok = path_toks[path_toks.size() - 1]

        // label!/jump!/unwrap! are PARSER intrinsics, not macros: leave the
        // raw tokens in the stream untouched; the parser owns the grammar
        // (`label` `!` `(` ident `)` in StmtParse, `unwrap` `!` `(` expr `)`
        // in ExprParse, whose operand must stay an ordinary expression).
        // So are the type facts (Compiler/Spec/Eval.md#deferred-conditions): their operand is a TYPE,
        // which only the parser can tell from a value.
        // Qualified forms (`a::label!`) are NOT intrinsics and still resolve
        // as ordinary macros.
        if path_toks.size() == 1 {
            var sp = TokenText::spelling(name_tok, self._tcm)
            if sp == LangIntrinsics::label()
                || sp == LangIntrinsics::jump()
                || sp == LangIntrinsics::unwrap() {
                return result
            }

            if sp == LangIntrinsics::is_trivially_copyable()
                || sp == LangIntrinsics::is_trivially_destructible() {
                return result
            }

            // A `defined!` _builtin_defined already passed through raw.
            if sp == LangIntrinsics::defined()
                && self._defined_raw.contains(name_tok.range.start.raw() as u64) {
                return result
            }
        }

        result.found    = true
        result.name     = name_tok
        result.name_sym = self._sym->intern(TokenText::spelling(name_tok, self._tcm))

        if path_toks.size() > 1 {
            result.is_qualified = true
            result.qualified    = ModulePath()
            for var k: usize = 0; k + 1 < path_toks.size(); ++k {
                var seg = IdentifierToken()
                seg.token = &null // peeked copy, not a source-owned pointer
                seg.name  = self._sym->intern(TokenText::spelling(path_toks[k], self._tcm))
                result.qualified.segments.push_back(seg)
            }
        }

        n = bang_offset + 1 // past `!`

        /// ## check for argument list `(` ... `)`
        var has_paren             = self._src->peek(n).kind == TokenKind::OpLParen
        var total_consumed: usize

        if has_paren {
            result.has_args = true
            var depth:    i32 = 1
            var arg_start     = n + 1     // first token inside `(`
            var m             = arg_start
            while true {
                // Out of tokens: no invocation. Inside a splice the frame's end
                // is the end (cross-frame lookahead is refused), not TkEof.
                if self._src->peek_leaves_frame(m) {
                    result.found = false
                    return result
                }

                var t = self._src->peek(m)
                if t.kind == TokenKind::TkEof {
                    result.found = false
                    return result
                }

                if t.kind == TokenKind::OpLParen {
                    depth += 1
                }

                if t.kind == TokenKind::OpRParen {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                }

                m += 1
            }

            // m is the index of the matching `)`
            // The invocation's `( ... )` is a bracket like any other: a
            // newline in it terminates nothing, so it is not part of an
            // argument. Kept, it reached the expansion as a statement end
            // (`check!(x` newline `> 3, ...)` became `if (x` / `> 3)`), and
            // a call spelled over lines parsed where the same macro
            // invocation did not. Inside a `{ }` of an argument (a block or
            // closure body) the newlines still separate statements.
            var braces: i32 = 0
            for var k: usize = arg_start; k < m; ++k {
                var at = self._src->peek(k)
                if at.kind == TokenKind::OpLBrace {
                    braces += 1
                }

                if at.kind == TokenKind::OpRBrace && braces > 0 {
                    braces -= 1
                }

                if at.kind == TokenKind::TkNewLine && braces == 0 {
                    continue
                }

                result.arg_toks.push_back(at)
            }

            total_consumed = m + 1 // past `)`
        } else {
            total_consumed = bang_offset + 1 // just past `!`
        }

        result.range = self._src->peek(0).range | self._src->peek(total_consumed - 1).range

        /// ## commit: consume exactly what we detected
        for var k: usize = 0; k < total_consumed; ++k {
            self._src->next()
        }

        return result
    }

    priv fn _report_expand_err(self,
                               code:         DiagID,
                               inv:          unsafe *Self::InvocationInfo,
                               const msg:    string,
                               const note:   string = "expanded from here",
                               const remark: string = "") {
        var site = self._inv_site(inv)
        if !remark.empty() {
            if site.start.id != inv->range.start.id {
                self._diag->report(DiagCode(code), site.start, msg).first(site)->note(
                    inv->range.start,
                    note,
                )->child_first(inv->range)->remark(remark)->emit()
                return
            }

            self._diag->report(DiagCode(code), site.start, msg).first(site)->remark(remark)->emit()

            return
        }

        if site.start.id != inv->range.start.id {
            self._diag->report(DiagCode(code), site.start, msg).first(site)->note(
                inv->range.start,
                note,
            )->child_first(inv->range)->emit()
            return
        }

        self._diag->report(DiagCode(code), site.start, msg).first(site)->emit()

        return
    }

    priv fn _expand(self, inv: unsafe *Self::InvocationInfo) {
        if self._opts.macro_debug {
            // --cmacro-trace-depth caps how deep the log follows nested expansion;
            // 0 (default) is unlimited, matching every other --cmax-* knob's convention.
            var depth = self._src->depth()
            var within_trace_depth = self._opts.trace_depth <= 0
                || (depth as i32) <= self._opts.trace_depth

            var nm = self._sym_name(inv->name_sym)
            if within_trace_depth
                && (self._opts.macro_debug_filter.empty() || nm == self._opts.macro_debug_filter) {
                // Straight to stderr, not the Logger: Logger::info is gated on -v,
                // which made --macro-debug print nothing on its own. The user
                // asked for this trace by name; it must not need a second flag.
                io::eprintln(
                    f"[macro-debug] expand '{nm}!' depth={depth} count={self._expansion_count}",
                )
            }
        }

        var unsafe *b = self._try_builtin(inv)
        if b != &null {
            self._push_splice(b, inv->name_sym, inv->range, unsafe &inv->parent_chain)
            return
        }

        var unsafe *entry = self._resolve(*inv)
        if entry == &null {
            self._report_expand_err(
                DiagID::R013E,
                inv,
                f"unknown macro '{self._sym_name(inv->name_sym)}!' (macros must be defined or imported before use)",
            )

            self._emit_poison(inv)
            return
        }

        if entry->decl->accepts_params && !inv->has_args {
            self._report_expand_err(
                DiagID::R006E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' requires arguments; add '(...)'",
            )

            self._emit_poison(inv)
            return
        }

        if !entry->decl->accepts_params && inv->has_args {
            self._report_expand_err(
                DiagID::R007E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' is parameterless; remove '(...)'",
            )

            self._emit_poison(inv)
            return
        }

        if (self._src->depth() as i32) >= self._opts.max_depth {
            // Once per chain (keyed on the outermost invoke site); the poison
            // still goes out so the chain stops expanding here either way.
            var chain_key = inv->origin_site.start.raw()
            if self._depth_reported.insert(chain_key as u64).second {
                self._report_expand_err(
                    DiagID::R008E,
                    inv,
                    f"macro expansion depth limit ({self._opts.max_depth}) exceeded",
                    "expanded from here",
                    f"limit can be increased with --cmax-macro-depth=N",
                )
            }

            self._emit_poison(inv)
            return
        }

        if self._opts.max_expansions > 0 && self._expansion_count >= self._opts.max_expansions {
            self._report_expand_err(
                DiagID::R008E,
                inv,
                "macro expansion budget exhausted",
                "expanded from here",
                f"budget can be increased with --cmax-macro-expansions=N, current budget is {self._opts.max_expansions}",
            )

            self._emit_poison(inv)
            return
        }

        if self._opts.max_expansions > 0 && self._expansion_count >= self._opts.max_expansions {
            self._report_expand_err(
                DiagID::R008E,
                inv,
                "macro expansion budget exhausted",
                "expanded from here",
                f"budget can be increased with --cmax-macro-expansions=N, current budget is {self._opts.max_expansions}",
            )

            return
        }

        var cyclic = false
        for s in inv->chain {
            if s == entry->name_sym {
                cyclic = true
                break
            }
        }

        // `inv.chain` is the LIVE frame stack, and a tail-position invocation
        // outlives its parent: `ping!` ending in `pong!(x)` has its frame
        // exhausted and popped (by the depth() check above) before pong's
        // body is walked, so pong's `ping!` saw a stack without ping and the
        // pair expanded forever -- each hop copying a chain one longer, so
        // the budget took minutes to trip. The origin chain captured at
        // detection keeps every ancestor, popped or not.
        if !cyclic {
            for var i: usize = 0; i < inv->parent_chain.size(); ++i {
                if inv->parent_chain[i].name == entry->name_sym {
                    cyclic = true
                    break
                }
            }
        }

        if cyclic {
            self._report_expand_err(
                DiagID::R008E,
                inv,
                f"cyclic expansion of macro '{self._sym_name(inv->name_sym)}!'",
                "recursion occurs here, in the macro body",
                "a macro cannot invoke itself; recursion is not supported in token macros",
            )

            self._emit_poison(inv)
            return
        }

        self._expansion_count += 1

        //    ARGUMENTS PRE-EXPAND IN CALLER CONTEXT (before pushing the frame)
        //    Each arg is a token run; expand invocations within it against the
        //    CURRENT chain by recursively running a nested expansion over a
        //    temporary TokenSource seeded with the arg tokens. Because the
        //    callee is NOT yet on the stack, square!(square!(x)) is legal.
        var unsafe *bound = self._bind_and_substitute(entry, inv)
        if bound == &null {
            return
        }

        //    push; the walk re-enters the spliced body next loop turn, and any
        //    nested invocations inside it are found by _detect_invocation again.
        self._push_splice(bound, entry->name_sym, inv->range, unsafe &inv->parent_chain)
    }

    priv fn _push_splice(self,
                         buf:          unsafe *(TokenBuffer<512>),
                         name:         SymbolID,
                         loc:          SourceRange,
                         parent_chain: unsafe *cxx::std::vector<InvokeHop>) {
        self._splices.push_back(buf) // own it for the run's lifetime
        self._src->push_splice(buf, name, loc, *parent_chain)
    }

    priv fn _buf_has_invocation(self, b: unsafe *(TokenBuffer<512>)) -> bool {
        for var i: usize = 0; i + 1 < b->size(); ++i {
            if b->get(i)->kind == TokenKind::LitIdentifier
                && b->get(i + 1)->kind == TokenKind::OpExclaim {
                return true
            }
        }

        return false
    }

    priv fn _expand_buffer(self,
                           src_buf:      unsafe *(TokenBuffer<512>),
                           parent_chain: unsafe *cxx::std::vector<InvokeHop>) -> unsafe *(TokenBuffer<512>) {
        // The sink is redirected for this expansion only: restored on every
        // way out, so a nested expansion hands its caller's sink back intact.
        var unsafe *out   = kairo::std::create<TokenBuffer<512>>()
        var unsafe *saved = self._sink
        self._sink = out
        finally {
            self._sink = saved
        }

        var d0 = self._src->depth()
        self._src->push_splice(src_buf, 0, SourceRange::invalid(), *parent_chain)

        while self._src->depth() > d0 {
            var t = self._src->peek(0)
            if t.kind == TokenKind::TkEof {
                break
            }

            var inv = self._detect_invocation()
            if inv.found {
                self._expand(unsafe &inv)
                continue
            }

            var chain    = cxx::std::vector<InvokeHop>()
            var next_tok = self._src->next_with_origin(&chain)
            self._emit(next_tok, unsafe &chain)
        }

        return out
    }

    priv fn _bind_and_substitute(self,
                                 e:   unsafe *MacroEntry,
                                 inv: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        // Args pre-expand in CALLER context: the callee's frame is not on the
        // stack yet, so square!(square!(x)) is legal. Cycle detection then only
        // fires on true body-recursion (boom!).
        // Split FIRST, then expand each arg: commas produced by expansion do
        // not change the call's arity (C semantics). Value-position builtins
        // deliberately differ see _parse_expanded_builtin_arguments.
        var args = self._parse_builtin_arguments(inv) // splits on top-level commas

        for var k: usize = 0; k < args.size(); ++k {
            if self._buf_has_invocation(args[k]) {
                var unsafe *ex = self._expand_buffer(args[k], unsafe &inv->parent_chain)
                kairo::std::destroy(args[k])
                args[k] = ex
            }
        }

        var *params             = &e->decl->params_spec
        var required:     usize = 0
        var has_variadic        = false
        var variadic_idx: usize = 0
        for var k: usize = 0; k < params->size(); ++k {
            var unsafe *p = params->get(k)
            if p->variadic != 0 {
                has_variadic = true
                variadic_idx = k
                break
            }

            if !p->has_default {
                required += 1
            }
        }

        var non_variadic_count = if has_variadic => variadic_idx else => params->size()

        if args.size() < required {
            self._report_expand_err(
                DiagID::R006E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' expects at least {required} arguments, got {args.size()}",
            )

            return &null
        }

        if !has_variadic && args.size() > params->size() {
            self._report_expand_err(
                DiagID::R006E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' expects at most {params->size()} arguments, got {args.size()}",
            )

            return &null
        }

        // One per expansion, a handful of parameters: inline buckets, no
        // heap node per parameter. Keyed `sym as u64`, clear of the two
        // reserved keys a u32 key would take from the SymbolID range.
        var bindings = llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>()
        for var k: usize = 0; k < non_variadic_count; ++k {
            var unsafe *p       = params->get(k)
            var        name_sym = self._sym->intern(TokenText::spelling(p->name, self._tcm))
            if k < args.size() {
                bindings[name_sym as u64] = args[k]
            } else if p->has_default {
                var unsafe *dflt = kairo::std::create<TokenBuffer<512>>()
                for var d: usize = ((p->default_off) as usize); d < ((p->default_off) as usize) + (p->default_len as usize); ++d {
                    dflt->append(*e->storage->get(d))
                }

                bindings[name_sym as u64] = dflt
                self._splices.push_back(dflt) // owner; freed in op finally (leak fix)
            }
        }

        var variadic_name:    SymbolID = 0
        var variadic_bindings          = cxx::std::vector<unsafe *(TokenBuffer<512>)>()
        if has_variadic {
            var unsafe *vp = params->get(variadic_idx)
            variadic_name = self._sym->intern(TokenText::spelling(vp->name, self._tcm))
            for var k: usize = non_variadic_count; k < args.size(); ++k {
                variadic_bindings.push_back(args[k])
            }
        }

        // Where a rewritten f-string from another file's body is anchored
        // (_subst_fstring): the outermost invocation, which this file wrote.
        var anchor = if (inv->origin_site.is_valid()) => (inv->origin_site) else => inv->range
        return self._substitute_body(
            e,
            unsafe &bindings,
            variadic_name,
            variadic_bindings,
            inv->range,
            anchor,
        )
    }

    /// Body substitution. Pack expansion is POSTFIX, mirroring expression- and
    /// type-level `PackExpansionExpr` (declaration is prefix `...xs`, use is
    /// postfix the same split C++ makes):
    ///
    ///   BARE SPLAT     `xs...`          -> a, b, c              (comma-joined)
    ///   PATTERN SPLAT  `( pattern )...` -> pat(a), pat(b), ...  (comma-joined)
    ///
    /// A pattern splat replicates the parenthesized token run once per pack
    /// element, substituting the pack name with that element (and ordinary
    /// parameter bindings as usual). The parentheses are grouping syntax and
    /// are NOT emitted. A `( ... )...` whose pattern does not mention the pack
    /// name is not ours it passes through verbatim as target-language pack
    /// expansion, as does `ident...` for any non-pack identifier. Expansion is
    /// single-level: a nested `...` inside a pattern is emitted verbatim.
    ///
    /// An empty pack consumes the whole splat and emits nothing.
    priv fn _substitute_body(
        self,
        e:                       unsafe *MacroEntry,
        bindings:                unsafe *llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>,
        variadic_name:           SymbolID,
        const variadic_bindings: cxx::std::vector<unsafe *(TokenBuffer<512>)>,
        invoke_loc:              SourceRange,
        anchor:                  SourceRange,
    ) -> unsafe *(TokenBuffer<512>) {
        var unsafe *output       = kairo::std::create<TokenBuffer<512>>()
        var        i:      usize = 0
        while i < ((e->body_len) as usize) {
            var unsafe *tok = e->storage->get(i)

            /// ### pattern splat: `(` pattern `)` `...`
            if tok->kind == TokenKind::OpLParen && variadic_name != 0 {
                var close = self._find_matching_rparen(e, i)
                if close != 0
                    && close + 1 < (e->body_len as usize)
                    && e->storage->get(close + 1)->kind == TokenKind::OpEllipsis
                    && self._pattern_mentions_pack(e, i + 1, close, variadic_name) {
                    for var k: usize = 0; k < variadic_bindings.size(); ++k {
                        if k > 0 {
                            self._append_builtin_comma(output, invoke_loc)
                        }

                        self._emit_pattern_instance(
                            output,
                            e,
                            i + 1,
                            close,
                            bindings,
                            variadic_name,
                            (variadic_bindings)[k],
                            anchor,
                        )
                    }

                    i = close + 2
                    continue
                }

                // not a pack pattern: plain parenthesized tokens, fall through
            }

            if tok->kind == TokenKind::LitIdentifier {
                var tok_name = self._sym->intern(TokenText::spelling(*tok, self._tcm))

                /// ### bare splat: `xs` `...`
                if tok_name == variadic_name
                    && i + 1 < (e->body_len as usize)
                    && e->storage->get(i + 1)->kind == TokenKind::OpEllipsis {
                    for var k: usize = 0; k < variadic_bindings.size(); ++k {
                        if k > 0 {
                            self._append_builtin_comma(output, invoke_loc)
                        }

                        var unsafe *span = (variadic_bindings)[k]
                        for var j: usize = 0; j < span->size(); ++j {
                            output->append(*span->get(j))
                        }
                    }

                    i += 2
                    continue
                }

                var bit = bindings->find(tok_name as u64)
                if bit != bindings->end() {
                    var unsafe *bound = bit->second
                    for var j: usize = 0; j < bound->size(); ++j {
                        output->append(*bound->get(j))
                    }

                    i += 1
                    continue
                }
            }

            output->append(self._subst_fstring(*tok, &*bindings, variadic_name, &null, anchor))
            i += 1
        }

        return output
    }

    /// index of the `)` matching the `(` at `open`, or 0 if unbalanced
    /// (0 can never be a valid answer: the match is always past `open`).
    priv fn _find_matching_rparen(self, e: unsafe *MacroEntry, open: usize) -> usize {
        var depth: i32 = 0
        for var i: usize = open; i < ((e->body_len) as usize); ++i {
            var k = e->storage->get(i)->kind
            if k == TokenKind::OpLParen {
                depth += 1
            }

            if k == TokenKind::OpRParen {
                depth -= 1
                if depth == 0 {
                    return i
                }
            }
        }

        return 0
    }

    /// does the token run [lo, hi) mention the pack name?
    priv fn _pattern_mentions_pack(self,
                                   e:             unsafe *MacroEntry,
                                   lo:            usize,
                                   hi:            usize,
                                   variadic_name: SymbolID) -> bool {
        for var i: usize = lo; i < hi; ++i {
            var unsafe *t = e->storage->get(i)
            if t->kind != TokenKind::LitIdentifier {
                continue
            }

            if self._sym->intern(TokenText::spelling(*t, self._tcm)) == variadic_name {
                return true
            }
        }

        return false
    }

    /// emits one instance of the pattern token run [lo, hi): the pack name is
    /// replaced by `element`, ordinary parameter bindings substitute as usual,
    /// everything else is copied verbatim.
    priv fn _emit_pattern_instance(
        self,
        output:        unsafe *(TokenBuffer<512>),
        e:             unsafe *MacroEntry,
        lo:            usize,
        hi:            usize,
        bindings:      unsafe *llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>,
        variadic_name: SymbolID,
        element:       unsafe *(TokenBuffer<512>),
        anchor:        SourceRange,
    ) {
        for var i: usize = lo; i < hi; ++i {
            var unsafe *tok = e->storage->get(i)

            if tok->kind == TokenKind::LitIdentifier {
                var tok_name = self._sym->intern(TokenText::spelling(*tok, self._tcm))

                if tok_name == variadic_name {
                    for var j: usize = 0; j < element->size(); ++j {
                        output->append(*element->get(j))
                    }

                    continue
                }

                var bit = bindings->find(tok_name as u64)
                if bit != bindings->end() {
                    var unsafe *bound = bit->second
                    for var j: usize = 0; j < bound->size(); ++j {
                        output->append(*bound->get(j))
                    }

                    continue
                }
            }

            output->append(self._subst_fstring(*tok, &*bindings, variadic_name, element, anchor))
        }
    }

    /// # f-string holes
    ///
    ///   An f-string is ONE token: its holes are token buffers the lexer kept
    ///   on the literal's StringData, which the walk never visits. So neither
    ///   a macro's parameter written in a hole (`macro g!(x) { f"v={x}" }`)
    ///   nor an invocation in one (`f"v={m!}"`) was ever seen: the parser met
    ///   the raw `x` / `m` (R020E). Two steps, in the order the walk reaches
    ///   them. _subst_fstring rewrites a body's f-string per expansion, with
    ///   the parameters bound; _expand_fstring, at emission, runs each hole
    ///   through the walk like an argument, which expands its invocations and
    ///   gives a macro body's hole tokens their origin chain as the body's
    ///   other tokens get theirs.

    /// \p tok's StringData when it is an f-string with holes, read from the
    /// table of the file that lexed it (\p tbl becomes that table); null
    /// otherwise. Adjacent literals join whatever their prefixes (P486), so
    /// the holes can sit in any segment of the chain: `"a" f"{x}"` is one.
    priv fn _fstring_data(self, tok: Token, @inout tbl: unsafe *ImmediateTable) -> unsafe *Immediate::StringData {
        if tok.kind != TokenKind::LitString {
            return &null
        }

        tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return &null
        }

        var unsafe *d   = tbl->get<Immediate::StringData>(tok.imm)
        var unsafe *seg = d
        while seg != &null {
            if seg->exprs.size() > 0 && seg->prefix_kind.has(Immediate::TextPrefixKind::Format) {
                return d
            }

            seg = self._fstring_next(tbl, seg)
        }

        return &null
    }

    /// \p tok is a string literal the lexer made from source (its range is
    /// its spelling), not one with owned text (file!, stringify!).
    priv fn _lexed_string(self, tok: Token) -> bool {
        var unsafe *tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return false
        }

        var unsafe *d = tbl->get<Immediate::StringData>(tok.imm)
        return d != &null && !d->has_owned_text()
    }

    /// \p tok is a string literal with an adjacent one chained after it.
    priv fn _chained_string(self, tok: Token) -> bool {
        var unsafe *tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return false
        }

        var unsafe *d = tbl->get<Immediate::StringData>(tok.imm)
        return d != &null && d->next != u32::MAX
    }

    /// The segment chained after \p seg in \p tbl, or null.
    priv fn _fstring_next(self,
                          tbl: unsafe *ImmediateTable,
                          seg: unsafe *Immediate::StringData) -> unsafe *Immediate::StringData {
        if seg->next == u32::MAX {
            return &null
        }

        return tbl->get<Immediate::StringData>(seg->next)
    }

    /// A fresh slot in this file's table with \p d's text and hole specs and
    /// no hole buffers yet: the caller pushes one per hole. Fresh, never the
    /// lexed slot written over: a body's literal is shared by every
    /// expansion, and the lexed slot frees its own buffers. Its `next` is
    /// unset; the caller links the copy of the chain.
    priv fn _fstring_slot(self, d: unsafe *Immediate::StringData) -> u32 {
        var        idx = self._imm->create<Immediate::StringData>()
        var unsafe *nd = self._imm->get<Immediate::StringData>(idx)
        nd->body        = d->body
        nd->prefix      = d->prefix
        nd->suffix      = d->suffix
        nd->prefix_kind = d->prefix_kind
        nd->owned_ptr   = d->owned_ptr
        nd->owned_len   = d->owned_len
        nd->next        = u32::MAX
        for var i: usize = 0; i < d->holes.size(); ++i {
            nd->holes.push_back(d->holes[i])
        }

        return idx
    }

    /// Every segment of \p d's chain copied into this file's table and
    /// linked, in order; returns the first copy. The caller fills each
    /// copy's hole buffers (segs[i] is the source of copies[i]). The whole
    /// chain is copied, holes or not: a copy's `next` must index THIS table,
    /// and the source chain may live in another file's.
    priv fn _fstring_chain(self,
                           d:      unsafe *Immediate::StringData,
                           tbl:    unsafe *ImmediateTable,
                           segs:   unsafe *cxx::std::vector<unsafe *Immediate::StringData>,
                           copies: unsafe *cxx::std::vector<u32>) -> u32 {
        var unsafe *seg = d
        while seg != &null {
            var idx = self._fstring_slot(seg)
            if copies->size() > 0 {
                self._imm->get<Immediate::StringData>((*copies)[copies->size() - 1])->next = idx
            }

            segs->push_back(seg)
            copies->push_back(idx)
            seg = self._fstring_next(tbl, seg)
        }

        return (*copies)[0]
    }

    /// \p tok from a macro body: an f-string with holes comes back as a copy
    /// whose holes have the parameters substituted (a pack's name, inside a
    /// pattern splat, by \p element); any other token unchanged. The copy
    /// lives in THIS file's table, so a literal from another file's body is
    /// re-anchored at \p anchor, the invocation this file wrote: the parser
    /// finds a string's table from where it was written (ASTContext::
    /// get_payload_table), and the copy was written here. Its hole tokens
    /// stay raw; _expand_fstring wraps them on the way out.
    priv fn _subst_fstring(self,
                           tok:             Token,
                           @inout bindings: llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>,
                           variadic_name:   SymbolID,
                           element:         unsafe *(TokenBuffer<512>),
                           anchor:          SourceRange) -> Token {
        var tbl: unsafe *ImmediateTable = &null
        var unsafe *d = self._fstring_data(tok, &tbl)
        if d == &null {
            return tok
        }

        var        same_tbl = tbl == self._imm
        var        segs     = cxx::std::vector<unsafe *Immediate::StringData>()
        var        copies   = cxx::std::vector<u32>()
        var        idx      = self._fstring_chain(d, tbl, unsafe &segs, unsafe &copies)
        for var s: usize = 0; s < segs.size(); ++s {
            var unsafe *sd = segs[s]
            var unsafe *nd = self._imm->get<Immediate::StringData>(copies[s])
            for var h: usize = 0; h < sd->exprs.size(); ++h {
                var unsafe *src = sd->exprs[h].0
                var        rng  = sd->exprs[h].1
                var unsafe *nb  = kairo::std::create<TokenBuffer<16>>()
                if src != &null {
                    for var k: usize = 0; k < src->size(); ++k {
                        var unsafe *ht = src->get(k)
                        if ht->kind == TokenKind::LitIdentifier {
                            var nm = self._sym->intern(TokenText::spelling(*ht, self._tcm))
                            if element != &null && nm == variadic_name {
                                for var j: usize = 0; j < element->size(); ++j {
                                    nb->append(*element->get(j))
                                }

                                continue
                            }

                            var bit = bindings.find(nm as u64)
                            if bit != bindings.end() {
                                var unsafe *bound = bit->second
                                for var j: usize = 0; j < bound->size(); ++j {
                                    nb->append(*bound->get(j))
                                }

                                continue
                            }
                        }

                        nb->append(*ht)
                    }
                }

                nd->exprs.push_back((nb, rng))
            }
        }

        var out = tok
        out.imm = idx
        if !same_tbl && anchor.is_valid() {
            out.range = anchor
        }

        return out
    }

    /// \p t, about to be emitted with origin chain \p chain: an f-string of
    /// this file's whose holes need the walk comes back as a copy with each
    /// hole walked (_expand_buffer: invocations expanded, every token given
    /// \p chain); any other token unchanged. A hole needs it when it holds
    /// an invocation, or when the string came out of a macro body: its hole
    /// tokens are the body's, raw, and a body token another file wrote reads
    /// against that file's tables only once wrapped. A string another file
    /// lexed that no body rewrote (an argument from a macro of that file)
    /// is left to the parser (ASTContext::wrap_foreign_token).
    priv fn _expand_fstring(self, t: Token, chain: unsafe *cxx::std::vector<InvokeHop>) -> Token {
        var tbl: unsafe *ImmediateTable = &null
        var unsafe *d = self._fstring_data(t, &tbl)
        if d == &null {
            return t
        }

        if tbl != self._imm {
            return t
        }

        var from_body = chain != &null && chain->size() > 0
        var any       = from_body
        var unsafe *scan = d
        while scan != &null && !any {
            for var h: usize = 0; h < scan->exprs.size() && !any; ++h {
                var unsafe *src = scan->exprs[h].0
                if src == &null {
                    continue
                }

                for var k: usize = 0; k + 1 < src->size(); ++k {
                    if src->get(k)->kind == TokenKind::LitIdentifier
                        && src->get(k + 1)->kind == TokenKind::OpExclaim {
                        any = true
                        break
                    }
                }
            }

            scan = self._fstring_next(tbl, scan)
        }

        if !any {
            return t
        }

        var        empty  = cxx::std::vector<InvokeHop>()
        var unsafe *pc    = if (chain != &null) => (chain) else => unsafe &empty
        var        segs   = cxx::std::vector<unsafe *Immediate::StringData>()
        var        copies = cxx::std::vector<u32>()
        var        idx    = self._fstring_chain(d, tbl, unsafe &segs, unsafe &copies)
        for var s: usize = 0; s < segs.size(); ++s {
            var unsafe *sd = segs[s]
            for var h: usize = 0; h < sd->exprs.size(); ++h {
                var unsafe *src = sd->exprs[h].0
                var        rng  = sd->exprs[h].1
                var unsafe *nb  = kairo::std::create<TokenBuffer<16>>()
                if src != &null {
                    // An EOF in the run would end _expand_buffer's walk with its
                    // frame still pushed; the hole's parse needs none.
                    var unsafe *run = kairo::std::create<TokenBuffer<512>>()
                    for var k: usize = 0; k < src->size(); ++k {
                        if src->get(k)->kind != TokenKind::TkEof {
                            run->append(*src->get(k))
                        }
                    }

                    var unsafe *ex = self._expand_buffer(run, pc)
                    for var k: usize = 0; k < ex->size(); ++k {
                        nb->append(*ex->get(k))
                    }

                    self._splices.push_back(run) // owned for the run, as a splice frame's tokens.
                    kairo::std::destroy(ex)
                }

                // re-read: the walk above may have grown this table.
                self._imm->get<Immediate::StringData>(copies[s])->exprs.push_back((nb, rng))
            }
        }

        var out = t
        out.imm = idx
        return out
    }

    priv fn make_int_token(self, value: u64, range: SourceRange) -> Token {
        var tok = Token()
        tok.kind  = TokenKind::LitInt
        tok.range = range
        if self._imm != &null {
            var        idx   = self._imm->create<Immediate::IntData>()
            var unsafe *data = self._imm->get<Immediate::IntData>(idx)
            data->value_lo = value
            data->value_hi = 0
            data->bits     = 32
            data->base     = 10
            data->flags    = 0
            data->body     = range
            tok.imm        = idx
        }

        return tok
    }

    priv fn _punct(self, k: TokenKind, range: SourceRange) -> Token {
        var tok = Token()
        tok.kind  = k
        tok.range = range
        return tok
    }

    priv fn make_ident_token(self, const name: string, range: SourceRange) -> Token {
        var tok = Token()
        tok.kind  = TokenKind::LitIdentifier
        tok.range = range
        if self._imm != &null {
            tok.imm = self._imm->intern_ident_copy(name)
        }

        return tok
    }

    //  Builtins

    priv fn _try_builtin(self, invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        // Builtins are unqualified. `foo::count!` must resolve as an ordinary
        // macro instead of being hijacked by the builtin dispatcher.
        if invoke->is_qualified {
            return &null
        }

        var name = self._sym_name(invoke->name_sym)

        // source location
        if name == LangMacros::file() {
            return self._builtin_file(invoke)
        }

        if name == LangMacros::line() {
            return self._builtin_line(invoke)
        }

        if name == LangMacros::column() {
            return self._builtin_column(invoke)
        }

        if name == LangMacros::module_path() {
            return self._builtin_module_path(invoke)
        }

        // argument manipulation
        if name == LangMacros::count() {
            return self._builtin_count(invoke)
        }

        if name == LangMacros::first() {
            return self._builtin_first(invoke)
        }

        if name == LangMacros::last() {
            return self._builtin_last(invoke)
        }

        if name == LangMacros::rest() {
            return self._builtin_rest(invoke)
        }

        if name == LangMacros::butlast() {
            return self._builtin_butlast(invoke)
        }

        // token manipulation
        if name == LangMacros::paste() {
            return self._builtin_paste(invoke)
        }

        if name == LangMacros::stringify() {
            return self._builtin_stringify(invoke)
        }

        if name == LangMacros::unstringify() {
            return self._builtin_unstringify(invoke)
        }

        // macro visibility
        if name == LangIntrinsics::defined() {
            return self._builtin_defined(invoke)
        }

        // deferred code generation
        if name == LangMacros::todo() {
            return self._builtin_todo(invoke)
        }

        if name == LangMacros::unreachable() {
            return self._builtin_unreachable(invoke)
        }

        if name == LangMacros::unreachable_unchecked() {
            return self._builtin_unreachable_unchecked(invoke)
        }

        if name == LangMacros::unique_id() {
            return self._builtin_unique_id(invoke)
        }

        if name == LangMacros::include() {
            return self._builtin_include(invoke)
        }

        if name == LangMacros::embed_str() {
            return self._builtin_embed_str(invoke)
        }

        if name == LangMacros::embed() {
            return self._builtin_embed(invoke)
        }

        // diagnostics
        if name == LangMacros::compile_error() {
            return self._builtin_diag(invoke, DiagSeverity::Error)
        }

        if name == LangMacros::compile_warn() {
            return self._builtin_diag(invoke, DiagSeverity::Warning)
        }

        if name == LangMacros::compile_note() {
            return self._builtin_diag(invoke, DiagSeverity::Note)
        }

        return &null
    }

    /// Builtin names are reserved unqualified: a user definition would never
    /// be reachable (dispatch checks builtins first), so `_handle_macro_def`
    /// rejects the definition outright instead of silently hijacking it.
    /// MUST mirror the dispatch table in `_try_builtin`; both spell every
    /// name through LangMacros / LangIntrinsics, so a rename cannot split them.
    priv fn _is_builtin_name(self, const name: string) -> bool {
        return name == LangMacros::file()        || name == LangMacros::line()
            || name == LangMacros::column()      || name == LangMacros::module_path()
            || name == LangMacros::count()       || name == LangMacros::first()
            || name == LangMacros::last()        || name == LangMacros::rest()
            || name == LangMacros::butlast()     || name == LangMacros::paste()
            || name == LangMacros::stringify()   || name == LangMacros::unstringify()
            || name == LangIntrinsics::defined()     || name == LangMacros::todo()
            || name == LangMacros::unreachable() || name == LangMacros::unreachable_unchecked()
            || name == LangMacros::unique_id()   || name == LangMacros::include()
            || name == LangMacros::embed_str()   || name == LangMacros::embed()
            || name == LangMacros::compile_error()
            || name == LangMacros::compile_warn()
            || name == LangMacros::compile_note()
            // parser intrinsics (no _try_builtin entry: _detect_invocation
            // passes them through raw): reserved so a user macro named
            // label/jump can never be reached at an unqualified call site.
            || name == LangIntrinsics::label()       || name == LangIntrinsics::jump()
            || name == LangIntrinsics::unwrap()
    }

    //  Builtin helpers

    priv fn _builtin_report(self, range: SourceRange, const message: string, code: DiagID) {
        self._diag->report(DiagCode(code), range.start, message).first(range)->emit()
    }

    priv fn _inv_site(self, inv: unsafe *Self::InvocationInfo) -> SourceRange {
        if inv->origin_site.is_valid() {
            return inv->origin_site
        }

        return inv->range
    }

    priv fn _emit_poison(self, inv: unsafe *Self::InvocationInfo) {
        var tok = Token()
        tok.kind  = TokenKind::TkMacroExpand
        tok.range = self._inv_site(inv)
        tok.imm   = (MacroSentinel::Poison as u32)
        self._emit(tok)
    }

    /// Splits the tokens inside `(...)` at top-level commas.
    ///
    /// `invoke.arg_toks` already excludes the outer `(` and `)`. There is no
    /// whole-file buffer and therefore no args_start/args_end arithmetic.
    priv fn _parse_builtin_arguments(self,
                                     invoke: unsafe *Self::InvocationInfo) -> cxx::std::vector<unsafe *TokenBuffer<512>> {
        var args: cxx::std::vector<unsafe *TokenBuffer<512>>

        if !invoke->has_args {
            return args
        }

        // `foo!()` is zero arguments, not one empty argument.
        if invoke->arg_toks.size() == 0 {
            return args
        }

        var unsafe *current = kairo::std::create<TokenBuffer<512>>()

        var paren_depth:  i32 = 0
        var square_depth: i32 = 0
        var brace_depth:  i32 = 0

        for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
            var tok = invoke->arg_toks[i]

            if tok.kind == TokenKind::OpLParen {
                paren_depth += 1
                current->append(tok)
                continue
            }

            if tok.kind == TokenKind::OpRParen {
                paren_depth -= 1
                current->append(tok)
                continue
            }

            if tok.kind == TokenKind::OpLSquare {
                square_depth += 1
                current->append(tok)
                continue
            }

            if tok.kind == TokenKind::OpRSquare {
                square_depth -= 1
                current->append(tok)
                continue
            }

            if tok.kind == TokenKind::OpLBrace {
                brace_depth += 1
                current->append(tok)
                continue
            }

            if tok.kind == TokenKind::OpRBrace {
                brace_depth -= 1
                current->append(tok)
                continue
            }

            if tok.kind == TokenKind::OpComma
                && paren_depth == 0
                && square_depth == 0
                && brace_depth == 0 {
                args.push_back(current)
                current = kairo::std::create<TokenBuffer<512>>()
                continue
            }

            current->append(tok)
        }

        args.push_back(current)
        return args
    }

    /// Builtin argument pre-expansion policy (documented-asymmetric, C model):
    ///
    /// VALUE-position builtins count!, first!, last!, rest!, butlast!, paste!,
    /// unstringify! fully expand macro invocations inside their arguments
    /// before operating on them, identical to user-macro argument pre-expansion
    /// in _bind_and_substitute. This makes composition sane:
    ///     count!(rest!(a, b, c))  ->  2
    ///
    /// QUOTING/NAME-position builtins stringify!, defined!, unique_id!,
    /// diag builtins operate on RAW tokens: stringify! quotes source spelling
    /// (the `#` analog), defined! probes a macro name without invoking it,
    /// unique_id! takes a literal tag. Pre-expanding those would destroy their
    /// meaning, exactly as in C's `#`/`defined` carve-outs.
    ///
    /// NOTE: unlike C (where commas produced by expansion never act as argument
    /// separators), value-position builtins expand FIRST and split on top-level
    /// commas SECOND. rest!/butlast! return comma lists precisely so they can feed
    /// count!/first!/last!; split-before-expand would make that composition
    /// silently arity-1. User macros keep C semantics (split, then expand each
    /// arg) so expansion cannot change a call's arity.
    priv fn _parse_expanded_builtin_arguments(self,
                                              invoke: unsafe *Self::InvocationInfo) -> cxx::std::vector<unsafe *TokenBuffer<512>> {
        var args: cxx::std::vector<unsafe *TokenBuffer<512>>

        if !invoke->has_args {
            return args
        }

        if invoke->arg_toks.size() == 0 {
            return args
        }

        // 1. gather the raw argument token run
        var unsafe *run = kairo::std::create<TokenBuffer<512>>()
        for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
            run->append(invoke->arg_toks[i])
        }

        // 2. expand invocations within it, in caller context
        if self._buf_has_invocation(run) {
            var unsafe *ex = self._expand_buffer(run, unsafe &invoke->parent_chain)
            kairo::std::destroy(run)
            run = ex
        }

        // an expansion may legitimately produce zero tokens (e.g. butlast!(x));
        // that is zero arguments, not one empty argument
        if run->size() == 0 {
            kairo::std::destroy(run)
            return args
        }

        // 3. split the EXPANDED stream on top-level commas
        var unsafe *current = kairo::std::create<TokenBuffer<512>>()

        var paren_depth:  i32 = 0
        var square_depth: i32 = 0
        var brace_depth:  i32 = 0

        for var i: usize = 0; i < run->size(); ++i {
            var tok = *run->get(i)

            if tok.kind == TokenKind::OpLParen {
                paren_depth += 1
            }

            if tok.kind == TokenKind::OpRParen {
                paren_depth -= 1
            }

            if tok.kind == TokenKind::OpLSquare {
                square_depth += 1
            }

            if tok.kind == TokenKind::OpRSquare {
                square_depth -= 1
            }

            if tok.kind == TokenKind::OpLBrace {
                brace_depth += 1
            }

            if tok.kind == TokenKind::OpRBrace {
                brace_depth -= 1
            }

            if tok.kind == TokenKind::OpComma
                && paren_depth == 0
                && square_depth == 0
                && brace_depth == 0 {
                args.push_back(current)
                current = kairo::std::create<TokenBuffer<512>>()
                continue
            }

            current->append(tok)
        }

        args.push_back(current)
        kairo::std::destroy(run)
        return args
    }

    priv fn _append_builtin_argument(self,
                                     out: unsafe *(TokenBuffer<512>),
                                     arg: unsafe *(TokenBuffer<512>)) {
        for var i: usize = 0; i < arg->size(); ++i {
            out->append(*arg->get(i))
        }
    }

    priv fn _append_builtin_comma(self, out: unsafe *(TokenBuffer<512>), range: SourceRange) {
        var comma = Token()
        comma.kind  = TokenKind::OpComma
        comma.range = range
        out->append(comma)
    }

    priv fn _builtin_token_text(self, tok: unsafe *Token) -> string {
        return TokenText::spelling(*tok, self._tcm)
    }

    //  Source-location builtins

    priv fn _builtin_file(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        var loc      = self._sm->get_full_loc(invoke->name.range.start)
        var filename = self._sm->get_filename((loc.file_id as u32))

        var tok = Token()
        tok.kind  = TokenKind::LitString
        tok.range = invoke->name.range

        if self._imm != &null {
            tok.imm = self._imm->intern_string_copy(filename)
        }

        out->append(tok)
        return out
    }

    priv fn _builtin_line(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        loc  = self._sm->get_full_loc(invoke->name.range.start)

        out->append(self.make_int_token(loc.line as u64, invoke->name.range))

        return out
    }

    priv fn _builtin_column(self,
                            invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        loc  = self._sm->get_full_loc(invoke->name.range.start)

        out->append(self.make_int_token(loc.column as u64, invoke->name.range))

        return out
    }

    priv fn _builtin_module_path(self,
                                 invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out  = kairo::std::create<TokenBuffer<512>>()
        var        *path = self._tracker->current_scope()

        for var i: usize = 0; i < path->segments.size(); ++i {
            if i != 0 {
                var sep = Token()
                sep.kind  = TokenKind::OpColonColon
                sep.range = invoke->range
                out->append(sep)
            }

            var segment_name = self._sym_name(path->segments[i].name)

            out->append(self.make_ident_token(segment_name, invoke->range))
        }

        return out
    }

    //  Argument manipulation builtins

    priv fn _builtin_count(self,
                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        if !invoke->has_args {
            self._builtin_report(
                invoke->range,
                "builtin 'count!' requires an argument list; use 'count!(...)'",
                DiagID::R009E,
            )

            return out
        }

        var args = self._parse_expanded_builtin_arguments(invoke)

        out->append(self.make_int_token(args.size() as u64, invoke->range))

        return out
    }

    priv fn _builtin_first(self,
                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'first!()' requires at least one argument",
                DiagID::R009E,
            )

            return out
        }

        self._append_builtin_argument(out, args[0])
        return out
    }

    priv fn _builtin_last(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'last!()' requires at least one argument",
                DiagID::R009E,
            )

            return out
        }

        self._append_builtin_argument(out, args[args.size() - 1])
        return out
    }

    priv fn _builtin_rest(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        args = self._parse_expanded_builtin_arguments(invoke)

        for var k: usize = 1; k < args.size(); ++k {
            if k > 1 {
                self._append_builtin_comma(out, invoke->range)
            }

            self._append_builtin_argument(out, args[k])
        }

        return out
    }

    priv fn _builtin_butlast(self,
                             invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            return out
        }

        for var k: usize = 0; k + 1 < args.size(); ++k {
            if k > 0 {
                self._append_builtin_comma(out, invoke->range)
            }

            self._append_builtin_argument(out, args[k])
        }

        return out
    }

    /// `paste!(a, b, ...)` token paste. Joins the canonical spelling of every
    /// token in every argument and produces ONE identifier.
    ///   paste!(get_, name) -> `get_name`
    /// Non-identifier results (numbers, operators) are not yet supported: they
    /// need owned imm payloads, which StringData/IntData do not have.
    priv fn _builtin_paste(self,
                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'paste!()' requires at least one argument",
                DiagID::R009E,
            )

            return out
        }

        var text = string()
        for var k: usize = 0; k < args.size(); ++k {
            var unsafe *a = args[k]
            for var i: usize = 0; i < a->size(); ++i {
                text += self._builtin_token_text(a->get(i))
            }
        }

        if !self._is_identifier_text(text) {
            self._builtin_report(
                invoke->range,
                f"builtin 'paste!()': '{text}' is not a valid identifier; paste! can only paste identifier-like tokens",
                DiagID::R009E,
            )

            return out
        }

        out->append(self.make_ident_token(text, invoke->range))
        return out
    }

    priv fn _is_identifier_text(self, const s: string) -> bool {
        if s.empty() {
            return false
        }

        var c0 = s[0]
        var head_ok = c0 >= ('a' as u8) && c0 <= ('z' as u8)
            || c0 >= ('A' as u8) && c0 <= ('Z' as u8)
            || c0 == ('_' as u8)
            || c0 == ('#' as u8)
        if !head_ok {
            return false
        }

        for var i: usize = 1; i < s.length(); ++i {
            var c = s[i]
            var ok = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c >= ('0' as u8) && c <= ('9' as u8)
                || c == ('_' as u8)
                || c == ('#' as u8)
            if !ok {
                return false
            }
        }

        return true
    }

    //  Token transformation builtins

    /// `stringify!(tokens...)`
    ///
    /// Produces an OWNED-text string literal (StringData::owned_ptr). Two text
    /// strategies:
    ///
    ///  - SOURCE-BACKED run: every token's source bytes match its canonical
    ///    spelling and offsets are monotonic the text is the exact source
    ///    slice, preserving whitespace/punctuation, and `body` is additionally
    ///    populated so unstringify! can re-lex it.
    ///  - SYNTHESIZED/discontiguous run (tokens from paste!, unique_id!,
    ///    spliced defaults, ...): canonical spellings joined with single
    ///    spaces. `body` stays invalid.
    priv fn _builtin_stringify(self,
                               invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        if !invoke->has_args || invoke->arg_toks.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'stringify!()' requires at least one token",
                DiagID::R009E,
            )

            return out
        }

        var *first = &invoke->arg_toks[0]
        var *last  = &invoke->arg_toks[invoke->arg_toks.size() - 1]

        // A synthesized token carries a range pointing at whatever produced it,
        // not at its own spelling; source bytes != canonical spelling exposes
        // that. Monotonicity rejects reordered/duplicated splices.
        var source_backed = first->range.start.id <= last->range.end.id
        if source_backed {
            for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
                var *t = &invoke->arg_toks[i]
                if i > 0 && t->range.start.id < invoke->arg_toks[i - 1].range.end.id {
                    source_backed = false
                    break
                }

                // A lexed string literal's source bytes ARE its spelling, a
                // chain's included (its range covers every segment, P879);
                // TokenText rebuilds only `"<head body>"`, which no prefixed
                // or joined literal matches. Only a synthesized one (owned
                // text: file!, a nested stringify!) is not source.
                if t->kind == TokenKind::LitString && self._lexed_string(*t) {
                    continue
                }

                if self._sm->get_text(t->range) != TokenText::spelling(*t, self._tcm) {
                    source_backed = false
                    break
                }
            }
        }

        // A prefixed string's token range starts at its quote (the prefix
        // is the StringData's own token), so the slice starts at the prefix
        // when the first argument has one, or `stringify!(r"a" y)` lost the
        // `r` (P906). A later argument's prefix is inside the slice anyway.
        var head = first->range.start
        if source_backed && first->kind == TokenKind::LitString && self._lexed_string(*first) {
            var unsafe *ftbl = self._tcm->get_imm_table_for_token(*first)
            var unsafe *fd   = ftbl->get<Immediate::StringData>(first->imm)
            if fd->prefix.range.is_valid() && fd->prefix.range.start.id < head.id {
                head = fd->prefix.range.start
            }
        }

        var text = string()
        if source_backed {
            text = self._sm->get_text(SourceRange::from_bounds(head, last->range.end))
        } else {
            for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
                if i > 0 {
                    text += " "
                }

                text += self._builtin_token_text(unsafe &invoke->arg_toks[i])
            }
        }

        var tok = Token()
        tok.kind  = TokenKind::LitString
        tok.range = invoke->range
        tok.imm   = self._imm->intern_string_copy(text)

        if source_backed {
            // also range-backed: lets unstringify! re-lex without owned-text
            // lexing support
            var unsafe *data = self._imm->get<Immediate::StringData>(tok.imm)
            data->body = SourceRange::from_bounds(head, last->range.end)
        }

        out->append(tok)
        return out
    }

    priv fn _builtin_unstringify(self,
                                 invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() != 1 || args[0]->size() != 1 {
            self._builtin_report(
                invoke->range,
                "builtin 'unstringify!()' requires exactly one string literal",
                DiagID::R009E,
            )

            return out
        }

        var unsafe *str_tok = args[0]->get(0)

        if str_tok->kind != TokenKind::LitString {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()' argument must be a string literal",
                DiagID::R009E,
            )

            return out
        }

        if self._lexer == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': no lexer is available for range re-lexing",
                DiagID::R009E,
            )

            return out
        }

        var unsafe *data = self._imm->get<Immediate::StringData>(str_tok->imm)
        if data == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': string literal has no backing data",
                DiagID::R009E,
            )

            return out
        }

        var body = data->body
        if body.start.id >= body.end.id {
            // no source backing: owned-only text (synthesized via stringify!
            // on synthesized tokens, or file!) cannot be re-lexed until the
            // lexer can run over table-owned bytes (load_virtual plumbing).
            if data->has_owned_text() {
                self._builtin_report(
                    str_tok->range,
                    "builtin 'unstringify!()': re-lexing a compiler-synthesized string is not supported yet",
                    DiagID::R009E,
                )
            }

            return out // empty string body, nothing to re-lex
        }

        // the string's body may live in a different file than the one this
        // preprocessor's lexer has loaded (imported macro); re-lexing would
        // read the wrong buffer's bytes.
        if self._sm->get_fid(body) != self._fid {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': string content originates in another file; cross-file re-lexing is not supported yet",
                DiagID::R009E,
            )

            return out
        }

        // SourceLocation ids are GLOBAL (file_base + offset); the lexer cursor
        // is FILE-LOCAL. Convert before slicing passing raw ids re-lexes from
        // the wrong bytes for any nonzero file base.
        var start_off = self._sm->get_offset(body.start)
        var body_len  = ((body.end.id - body.start.id) as usize)

        var unsafe *lexed = self._lexer->lex_slice<512>(
            start_off as u32,
            ((start_off + body_len) as u32)
        )

        if lexed == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': could not re-lex string content",
                DiagID::R009E,
            )

            return out
        }

        finally {
            kairo::std::destroy(lexed)
        }

        for var i: usize = 0; i < lexed->size(); ++i {
            var unsafe *tok = lexed->get(i)
            if tok->kind == TokenKind::TkEof {
                continue
            }

            if tok->kind == TokenKind::TkError {
                self._builtin_report(
                    str_tok->range,
                    "builtin 'unstringify!()': lexical error in string content",
                    DiagID::R009E,
                )

                continue
            }

            out->append(*tok)
        }

        return out
    }

    //  Macro visibility builtins

    priv fn _builtin_defined(self,
                             invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out       = kairo::std::create<TokenBuffer<512>>()
        var        found: u64 = 0
        var        args       = self._parse_builtin_arguments(invoke)

        if args.size() == 1 && args[0]->size() == 1 {
            var unsafe *name_tok = args[0]->get(0)

            if name_tok->kind == TokenKind::LitIdentifier {
                var raw_name = *name_tok
                var name_sym = self._sym->intern(self._builtin_token_text(name_tok))

                var probe = Self::InvocationInfo()
                probe.name         = *name_tok
                probe.name_sym     = name_sym
                probe.is_qualified = false
                probe.has_args     = false
                probe.range        = name_tok->range
                probe.found        = true

                if self._resolve(probe) != &null {
                    found = 1
                } else {
                    // Not a Kairo macro: it may be clang's (predefined, or
                    // from an ffi header), which only Sema can ask, after
                    // the headers are built. Passed on as written for the
                    // parser's DefinedExpr (Compiler/Spec/Eval.md#defined).
                    self._defined_raw.insert(invoke->name.range.start.raw() as u64)
                    out->append(invoke->name)
                    out->append(self._punct(TokenKind::OpExclaim, invoke->name.range))
                    out->append(self._punct(TokenKind::OpLParen, invoke->name.range))
                    out->append(raw_name)
                    out->append(self._punct(TokenKind::OpRParen, invoke->name.range))
                    return out
                }
            }
        }

        // A condition: `true` / `false`, not 1 / 0 (Compiler/Spec/Eval.md#defined).
        var b = Token()
        b.kind  = if (found == (1 as u64)) => (TokenKind::KwTrue) else => TokenKind::KwFalse
        b.range = invoke->name.range
        out->append(b)

        return out
    }

    //  Deferred/sentinel builtins

    priv fn _builtin_todo(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        var tok = Token()
        tok.kind  = TokenKind::TkMacroExpand
        tok.range = invoke->name.range
        tok.imm   = (MacroSentinel::Todo as u32)

        out->append(tok)
        return out
    }

    /// `unreachable!` SAFE: lowers to a panic if reached (Rust semantics).
    /// The UB/optimizer-assume variant is `unreachable_unchecked!`.
    priv fn _builtin_unreachable(self,
                                 invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        var tok = Token()
        tok.kind  = TokenKind::TkMacroExpand
        tok.range = invoke->name.range
        tok.imm   = (MacroSentinel::Unreachable as u32)

        out->append(tok)
        return out
    }

    /// `unreachable_unchecked!` UNSAFE: hard assertion to the optimizer that
    /// the path is dead. Reaching it at runtime is undefined behavior.
    priv fn _builtin_unreachable_unchecked(self,
                                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        var tok = Token()
        tok.kind  = TokenKind::TkMacroExpand
        tok.range = invoke->name.range
        tok.imm   = (MacroSentinel::UnreachableUnchecked as u32)

        out->append(tok)
        return out
    }

    /// `unique_id!` / `unique_id!(tag)`
    ///
    /// TokenSource must expose the serial of the currently active splice frame.
    /// A source location is not a valid substitute because the same source token
    /// can be duplicated and expanded more than once.
    priv fn _builtin_unique_id(self,
                               invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out         = kairo::std::create<TokenBuffer<512>>()
        var        range        = invoke->name.range
        var        tag:  string = ""

        if invoke->has_args {
            var args = self._parse_builtin_arguments(invoke)

            var valid = args.size() == 1
                && args[0]->size() == 1
                && args[0]->get(0)->kind == TokenKind::LitIdentifier

            if !valid {
                self._builtin_report(
                    invoke->range,
                    "builtin 'unique_id!()' takes at most one identifier tag, e.g. unique_id!(guard)",
                    DiagID::R009E,
                )

                return out
            }

            tag = self._builtin_token_text(args[0]->get(0))
        }

        var serial = self._src->current_expansion_serial()

        // Tagged inside a macro expansion: stable for this dynamic expansion
        // instance and this tag.
        if !tag.empty() && serial != 0 {
            var key = f"{serial}:{tag}"
            var it  = self._unique_tag_cache.find(kairo::sref(key))

            if it != self._unique_tag_cache.end() {
                var tok = Token()
                tok.kind  = TokenKind::LitIdentifier
                tok.range = range
                tok.imm   = it->second

                out->append(tok)
                return out
            }

            self._unique_counter += 1

            var tok = self.make_ident_token(
                LowerTargets::unique_ident(tag, self._fid, self._unique_counter),
                range,
            )

            self._unique_tag_cache.try_emplace(kairo::sref(key), tok.imm) // a miss above: never an overwrite
            out->append(tok)
            return out
        }

        // Untagged, or tagged at the top level: fresh on every invocation.
        self._unique_counter += 1

        out->append(
            self.make_ident_token(
                LowerTargets::unique_ident(tag, self._fid, self._unique_counter),
                range,
            ),
        )

        return out
    }

    priv fn _builtin_include(self,
                             invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        var tok = Token()
        tok.kind  = TokenKind::TkMacroExpand
        tok.range = invoke->name.range
        tok.imm   = (MacroSentinel::Include as u32)

        out->append(tok)
        return out
    }

    priv fn _builtin_embed_str(self,
                               invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        var tok = Token()
        tok.kind  = TokenKind::LitString
        tok.range = invoke->name.range
        tok.imm   = (MacroSentinel::EmbedStr as u32)

        out->append(tok)
        return out
    }

    priv fn _builtin_embed(self,
                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()

        var tok = Token()
        tok.kind  = TokenKind::TkMacroExpand
        tok.range = invoke->name.range
        tok.imm   = (MacroSentinel::Embed as u32)

        out->append(tok)
        return out

        /// we have to put some like [ bytes, ... ]
        // if !(invoke->has_args) {
        //     self._builtin_report(
        //         invoke->range,
        //         "builtin 'embed!()' requires at least one argument",
        //         DiagID::R009E
        //     );
        //     return out;
        // }

        // var args = self._parse_builtin_arguments(invoke);

        // // we need to open the file in byte mode read it and store its contents


        // var make_int_tok = fn (value: u8) -> Token {
        //     /// so we need to make a TkMacroExpand and make its underlying point
        //     /// into our buffer

        //     var outer: Token;

        // };



        // return out;
    }

    //  Diagnostic builtins

    priv fn _builtin_diag(self,
                          invoke: unsafe *Self::InvocationInfo,
                          level:  DiagSeverity) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = kairo::std::create<TokenBuffer<512>>()
        var        args = self._parse_builtin_arguments(invoke)

        if args.size() == 0 {
            return out
        }

        var message = string()

        for var i: usize = 0; i < args[0]->size(); ++i {
            message += self._builtin_token_text(args[0]->get(i))
        }

        var code =      if (level == DiagSeverity::Error) => (DiagID::R010E)
                   else if (level == DiagSeverity::Warning) => (DiagID::R010W)
                   else => DiagID::R010N

        self._report_expand_err(code, invoke, message, "diagnostic emitted from this macro body")

        return out
    }

    //  Resolution

    priv fn _resolve(self, const inv: Self::InvocationInfo) -> unsafe *MacroEntry {
        if inv.is_qualified {
            // The rule Sema uses for a qualified name (Compiler/Spec/NameResolution.md#name-resolution N,
            // T "Heads"): the HEAD is looked up in the scopes that LEXICALLY
            // enclose the use -- this file's own module blocks, innermost
            // first, then the file's scope -- and only then through what the
            // file imported. So the path is tried relative to each scope
            // from the current one down to the file's own module path, and
            // only for macros THIS file registered (find_same_fid): a file
            // at `a::b` with `module std { macro m!() }` registers `m` under
            // [a, b, std], and `std::m!()` there must find it, imported or
            // not (6f101377). Shorter prefixes are not enclosing scopes --
            // the parent module's other files are not lexically around this
            // one, and Sema does not see their decls without an import --
            // and neither is a macro another file registered under a
            // relative path: `c::m!()` in L/b.k, which imports library `c`,
            // must expand the library's macro, not one L/module.k declares
            // in its own `module c { }` (it did, while Sema bound `c::g()`
            // in the same file to the library). Then the path as written,
            // then an import alias.
            var *cur = self._tracker->current_scope()
            var base = self._tracker->file_base()->segments.size()
            for var k: usize = cur->segments.size(); k > 0 && k >= base; --k {
                var rel = ModulePath()
                for var j: usize = 0; j < k; ++j {
                    rel.segments.push_back(cur->segments[j])
                }

                for seg in inv.qualified.segments {
                    rel.segments.push_back(seg)
                }

                var unsafe *r = self._macros->find_same_fid(rel, inv.name_sym, self._fid)
                if r != &null {
                    return r
                }
            }

            // exact scope
            var unsafe *e = self._macros->find(inv.qualified, inv.name_sym, self._fid)
            if e != &null {
                return e
            }

            // alias head: module_aliases[first] + rest
            if inv.qualified.segments.size() > 0 {
                var head = inv.qualified.segments[0].name
                var ait  = self._imports->module_aliases.find(head as u64)
                if ait != self._imports->module_aliases.end() {
                    var scope = ait->second
                    for var k: usize = 1; k < inv.qualified.segments.size(); ++k {
                        scope.segments.push_back(inv.qualified.segments[k])
                    }

                    return self._macros->find(scope, inv.name_sym, self._fid)
                }
            }

            return &null // qualified NEVER falls back to unqualified
        }

        // unqualified: current scope chain (same-fid, order irrelevant under
        // the two-phase-free single walk since defs before this point are the
        // only ones registered) -> named imports -> wildcards -> global
        var        *scope = self._tracker->current_scope()
        var unsafe *e     = self._macros->find_same_fid(*scope, inv.name_sym, self._fid)
        if e != &null {
            return e
        }

        var nit = self._imports->named.find(inv.name_sym as u64)
        if nit != self._imports->named.end() {
            return nit->second
        }

        for *wscope in self._imports->wildcards {
            var unsafe *w = self._macros->find(*wscope, inv.name_sym, self._fid)
            if w != &null {
                return w
            }
        }

        // the prelude's own `import builtin::*`, last of the imports
        if self._has_prelude {
            var unsafe *pm = self._macros->find(self._prelude, inv.name_sym, self._fid)
            if pm != &null {
                return pm
            }
        }

        // global scope (empty ModulePath)
        return self._macros->find(ModulePath(), inv.name_sym, self._fid)
    }

    priv fn _sym_name(self, id: SymbolID) -> string {
        var unsafe *p = self._sym->resolve(id)
        return if (p == &null) => ("<unknown>") else => *p
    }

    priv fn _recover_to_terminator(self) {
        while !self._src->at_eof() {
            var k = self._src->peek(0).kind
            if k == TokenKind::OpSemicolon || k == TokenKind::TkNewLine {
                self._src->next()
                return
            }

            self._src->next()
        }
    }

    //  Finalize

    priv fn _finalize(self) {
        // hand the produced buffer to the TCM as this fid's tokens.
        self._tcm->close_stream(self._fid, self._out)
        self._out = &null // ownership transferred to the slot
        // splice buffers stay owned here until op delete their tokens were
        // COPIED into _out via wrap/append, so freeing them post-handoff is safe.

        // One clang parse per distinct ordered header list; another file
        // importing the same headers in the same order shares the set. The
        // quoted-include directory is THIS file's, as for a .cpp beside it.
        if self._headers != &null && self._ffi_headers.size() > 0 {
            var unsafe *hs = self._headers->request(
                self._ffi_headers,
                self._ffi_c,
                self._ffi_locs,
                self._sm->get_file_dir(self._fid).full_path(),
            )

            self._tu->header_set = unsafe (hs as unsafe *void)
        }
    }
}
