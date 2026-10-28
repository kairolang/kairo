/// --- The Kairo Project ------------------ Preprocessor/Preprocessor.k --- ///
///
///   Single-pass, stream-driven preprocessor. One forward walk per fid over
///   a streaming lexer, via a TokenSource stack. Imports and macro defs are
///   consumed into the TU (never emitted); invocations expand by pushing
///   splice frames the same walk re-enters. FFI imports are skipped; FFI
///   blocks are copied through for the parser.
///
///   Order-dependent macro visibility (C-preprocessor semantics, but scoped
///   and with pub/priv/prot). Token macros may NOT expand into import/macro
///   declarations (enforced at def time + emission backstop); lift by
///   deleting those two checks and routing the kinds back into the walk.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Token::TokenCacheManager::*;
import Token::TokenText::*;
import Token::TokenBuffer::*;
import Resolution::ImportProbe::*;
import Support::FileIO::Path::*;
import Support::TimeReport::*;
import Config::Preprocessor::*;
import Macro::Sentinel::*;
import Preprocessor::TokenSource::*;
import Preprocessor::MacroTable::*;
import Preprocessor::FileImportIndex::*;
import Preprocessor::ScopeTracker::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Preprocessor::DepScanner::*;
import Preprocessor::WaveExecutor::*;
import Parser::Shared::ImportGrammar::*;
import Parser::Shared::MacroHeaderGrammar::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Declarations::*;
import AST::LangItems::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Diagnostic::BufferedDiagSink::*;
import Interop::Clang::HeaderSet::*;

struct PPResult {
    var ok:   bool = false;
    var fids: vec::<u32>;   ///< entry's transitive graph, sorted ascending.
    /// The builtin module's fid (`builtin/module.k`), or 0 when there is no
    /// builtin root or the prelude is off. Handed out rather than rediscovered:
    /// the prelude fold already resolved it, and sema cannot find it on its own
    /// -- ModulePath segments are PreprocessorSymbolTable SymbolIDs, a name
    /// domain nothing in Sema can reach.
    var builtin_fid: u32 = 0;
}

//  Per-fid walker. One instance per fid; the batch driver owns the shared
//  MacroTable + resolver + contexts and runs walkers in wave order.

class PPWalker
  derives ImportGrammar::<PPWalker>,
          MacroHeaderGrammar::<PPWalker> {

    priv var _splices: vec::<own::<TokenBuffer::<512>>>; ///< frame backing; freed in finalize
    priv var _opts:    PreprocessorOptions;
    priv var _src:     own::<TokenSource>;
    priv var _imports: own::<FileImportIndex>;
    priv var _tracker: own::<ScopeTracker>;
    priv var _out:     own::<TokenBuffer::<512>>;
    priv var _ctx:     obs::<ASTContext>;
    priv var _tu:      obs::<TranslationUnit>;
    priv var _macros:  obs::<MacroTable>;
    priv var _sym:     obs::<PreprocessorSymbolTable>;
    priv var _sm:      obs::<SourceManager>;
    priv var _tcm:     obs::<TokenCacheManager>;
    priv var _diag:    obs::<DiagEngine>;
    priv var _imm:     obs::<ImmediateTable>;
    priv var _lexer:   obs::<Lexer>;
    priv var _inv:     obs::<CompilerInvocation>;
    priv var _sink:    obs::<TokenBuffer::<512>>;
    priv var _unique_tag_cache:  map::<string, u32>;
    priv var _fid:               u32 = u32(-1); //< invalid sentinel
    priv var _expansion_count:   i32 = 0;
    /// Outermost-invocation sites whose chain already hit --cmax-macro-depth.
    /// Every deeper hop of a runaway chain trips the same limit; one R008E per
    /// chain says it, the rest are noise that buries the real error.
    priv var _depth_reported:    set::<u32>;
    /// `defined!` invocations passed through to the parser (by the name
    /// token's location), so the rescan of their own output does not take
    /// them for an invocation again.
    priv var _defined_raw:       set::<u32>;
    priv var _unique_counter:    u32 = 0;

    /// ffi headers this file imports, spelled as HeaderSet::unquote does,
    /// deduped, in SOURCE ORDER: the key of the one HeaderSet _finalize
    /// requests. Order is part of the key because it is part of the meaning:
    /// a header may depend on what an earlier one declared or defined.
    priv var _ffi_headers: vec::<string>;
    /// Parallel to _ffi_headers: written `ffi "c"`. Carried into the set so
    /// the C ones are parsed, and linked, as extern "C".
    priv var _ffi_c:       vec::<bool>;
    /// Parallel to _ffi_headers: the header string's span. A clang error at
    /// the set's synthesized `#include` line reports here, not at <injected>.
    priv var _ffi_locs:    vec::<SourceRange>;
    /// Null in tooling runs with no clang: ffi imports then resolve to nothing.
    priv var _headers:     obs::<HeaderSetCache> = &null;

    // --- Pass timing (--time-passes) --------------------------------------
    //
    //   Handles resolved once in run(), null when timing is off   which is
    //   what makes the sampled scopes below cost a single null check on the
    //   per-token path. Counters are per-walker, hence per-file and per-thread;
    //   a shared counter would put a contended cache line in the token loop,
    //   which is the exact cost sampling exists to avoid.
    priv var _t_detect: *kairo::KTimeRecord = &null;
    priv var _t_emit:   *kairo::KTimeRecord = &null;
    /// The builtin module's scope, searched after this file's own imports
    /// (PreProcessor::_walk_one sets it on every file outside the builtin
    /// root). Unset for the builtin files and with the prelude off.
    priv var _prelude:     ModulePath;
    priv var _has_prelude: bool = false;
    priv var _c_detect: u32 = 0;
    priv var _c_emit:   u32 = 0;

    // --- Import cycles (PreProcessor::_prelex_cycles) ---------------------
    /// collect_macros() is running: nothing is emitted, and only macro
    /// definitions and scope tokens are acted on.
    priv var _collect:      bool = false;
    /// This file's macros were registered by collect_macros() ahead of the
    /// walk; run() steps over each definition instead of defining it again.
    priv var _macros_known: bool = false;
    /// ig_err is silent: the grammar is re-read for its tokens alone, and
    /// whatever it had to say was said on the first read.
    priv var _quiet:        bool = false;

    fn PPWalker(
        self,
        fid:         u32,
        lexer:      *Lexer,
        ctx:        *ASTContext,
        tu:         *TranslationUnit,
        macros:     *MacroTable,
        resolver:   *ImportResolver,
        sym:        *PreprocessorSymbolTable,
        sm:         *SourceManager,
        tcm:        *TokenCacheManager,
        diag:       *DiagEngine,
        opts:        PreprocessorOptions,
        module_base: ModulePath,
        headers:    *HeaderSetCache = &null
    ) {
        self._fid     = fid;
        self._headers = headers;
        self._lexer   = lexer;
        self._ctx     = ctx;
        self._tu      = tu;
        self._macros  = macros;
        self._sym     = sym;
        self._sm      = sm;
        self._tcm     = tcm;
        self._diag    = diag;
        self._opts    = opts;
        self._imm     = lexer->get_imm_tbl();
        self._out     = std::create::<TokenBuffer::<512>>();
        self._src     = std::create::<TokenSource>(lexer, opts.max_token_count, diag);
        self._src->set_preserve_comments(opts.preserve_comments);
        self._src->set_file_name(sm->get_filename(fid));
        self._imports = std::create::<FileImportIndex>(sym, sm, tcm, resolver, macros, diag, fid);
        self._tracker = std::create::<ScopeTracker>(sym, sm, self._imm, tcm, module_base);
        self._sink    = self._out;
    }

    /// \brief the prelude for macros: the file behaves as though it wrote
    ///        `import builtin::*` (PANIC.md §2.4: `crash!` is a plain macro
    ///        in Lib/builtin), searched after its own imports so an explicit
    ///        import, or the file's own macro, of the same name wins.
    fn set_prelude_scope(self, scope: ModulePath) {
        self._prelude     = scope;
        self._has_prelude = true;
    }

    fn op delete (self) {
        if self._out != &null  { std::destroy(self._out); self._out = &null; }
        for b in self._splices { std::destroy(b); }
        
        self._splices.clear();
        
        if self._src     != &null { std::destroy(self._src);     self._src     = &null; }
        if self._imports != &null { std::destroy(self._imports); self._imports = &null; }
        if self._tracker != &null { std::destroy(self._tracker); self._tracker = &null; }
    }

    // --- shared-grammar host surface (raw kinds; stream is pre-expansion) --

    fn ig_kind(self) -> TokenKind {
        var t = self._src->peek(0);
        return t.kind;
    }
    fn ig_peek_kind(self) -> TokenKind {
        var t = self._src->peek(1);
        return t.kind;
    }
    fn ig_tok(self)  -> Token { return self._src->peek(0); }
    fn ig_bump(self) { self._src->next(); }
    fn ig_bump_nl(self) {
        self._src->next();
        while self._src->peek(0).kind == TokenKind::TkNewLine { self._src->next(); }
    }
    fn ig_eof(self) -> bool { return self._src->at_eof(); }
    fn ig_err(self, r: SourceRange, msg: string, code: DiagID) {
        if self._quiet { return; }
        self._diag->report(DiagCode(code), r.start, msg).first(r).emit();
    }

    /// Frame 0 from tokens already lexed (TokenSource::set_replay).
    fn set_replay(self, toks: *vec::<Token>) { self._src->set_replay(toks); }

    /// collect_macros() ran for this file on an earlier walker.
    fn assume_macros_known(self) { self._macros_known = true; }

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
        self._collect = true;
        while !self._src->at_eof() {
            var t = self._src->peek(0);
            var k = t.kind;
            if k == TokenKind::TkEof { break; }
            if k == TokenKind::KwImport { self._quiet = true; self.parse_import_spec(); self._quiet = false; continue; }
            if k == TokenKind::KwMacro  { self._handle_macro_def(3); continue; }
            if (k == TokenKind::KwPub) || (k == TokenKind::KwPriv) || (k == TokenKind::KwProt) {
                var vis: u8 = (3) if (k == TokenKind::KwPub) else (1) if (k == TokenKind::KwPriv) else (2);
                var nk = self._src->peek(1).kind;
                if nk == TokenKind::KwImport {
                    self._src->next();
                    self._quiet = true; self.parse_import_spec(); self._quiet = false;
                    continue;
                }
                if nk == TokenKind::KwMacro { self._src->next(); self._handle_macro_def(vis); continue; }
                if nk == TokenKind::KwModule {
                    var mv = (ModuleVisibility::Public) if (k == TokenKind::KwPub)
                        else (ModuleVisibility::Private) if (k == TokenKind::KwPriv)
                        else (ModuleVisibility::Protected);
                    self._src->next();
                    self._track_scope(self._src->peek(0), mv);
                    continue;
                }
                self._src->next();
                continue;
            }
            if self._track_scope(t, ModuleVisibility::Public) { continue; }
            self._src->next();
        }
        self._collect = false;
        self._macros_known = true;
    }

    /// A macro definition collect_macros() already registered: its tokens,
    /// consumed exactly as _handle_macro_def consumes them, and nothing else
    /// -- no second MacroDecl, no duplicate-definition error, no diagnostic
    /// the first read already gave.
    priv fn _skip_macro_def(self) {
        var kw = self._src->next(); // `macro`
        if self._src->peek(0).kind == TokenKind::OpAt { self._emit(kw); return; }
        self._quiet = true;
        var hdr = self.parse_macro_header();
        self._quiet = false;
        if !hdr.ok { self._recover_to_terminator(); return; }
        var builtin = self._is_builtin_name(TokenText::spelling(hdr.name, self._tcm));
        if self._src->peek(0).kind != TokenKind::OpLBrace {
            if builtin { self._recover_to_terminator(); }
            return;
        }
        self._src->next(); // `{`
        var d: i32 = 1;
        while (!self._src->at_eof()) && (d > 0) {
            var t = self._src->next();
            if t.kind == TokenKind::OpLBrace { d += 1; }
            if t.kind == TokenKind::OpRBrace { d -= 1; }
        }
        if builtin { return; }
        if (d == 0) && (self._src->peek(0).kind == TokenKind::OpSemicolon) { self._src->next(); }
    }

    //  The walk

    fn run(self) -> bool {
        // Resolved once per file, under the Walk region the wave opened. The
        // per-token scopes below check these for null before anything else, so
        // leaving them null when timing is off makes the instrumentation free.
        if time_enabled() {
            self._t_detect = time_region("Detect");
            self._t_emit   = time_region("Emit");
        }

        while !self._src->at_eof() {
            var t = self._src->peek(0);
            var k = t.kind;

            if k == TokenKind::TkEof { break; }

            if k == TokenKind::KwFfi        { self._handle_ffi();       continue; }
            if k == TokenKind::KwImport     { self._handle_import(1);   continue; } // 1 = priv default
            if k == TokenKind::KwMacro      {
                if self._macros_known { self._skip_macro_def(); } else { self._handle_macro_def(3); } // 3 = pub default
                continue;
            }

            if (k == TokenKind::KwPub) || (k == TokenKind::KwPriv) || (k == TokenKind::KwProt) {
                var vis: u8 = (3) if (k == TokenKind::KwPub) else (1) if (k == TokenKind::KwPriv) else (2);
                var nk = self._src->peek(1).kind;
                if nk == TokenKind::KwImport {
                    self._src->next(); // consume visibility keyword
                    self._handle_import(vis);
                    continue;
                }
                if nk == TokenKind::KwMacro {
                    self._src->next();
                    if self._macros_known { self._skip_macro_def(); } else { self._handle_macro_def(vis); }
                    continue;
                }
                if nk == TokenKind::KwModule {
                    var mv = (ModuleVisibility::Public) if (k == TokenKind::KwPub)
                        else (ModuleVisibility::Private) if (k == TokenKind::KwPriv)
                        else (ModuleVisibility::Protected);
                    self._emit(self._src->next()); // vis keyword IS emitted the
                                                  // parser needs `pub module Foo {`
                    self._track_scope(self._src->peek(0), mv);
                    continue;
                }
                self._emit(self._src->next()); // plain visibility on some other decl
                continue;
            }

            // scope tracking off structural tokens (module/braces)
            if self._track_scope(t, ModuleVisibility::Public) { continue; }

            // invocation?
            //
            // Timed INSIDE _detect_invocation, not around this call: hoisting
            // the result out of a timing block would copy an InvocationInfo
            // (three vectors) on every token. Pessimizing the preprocessor to
            // measure the preprocessor is a bad trade.
            var inv = self._detect_invocation();
            if inv.found {
                var _tx = TimeRegion("Expand");
                self._expand(inv);
                continue;
            }

            var chain = vec::<InvokeHop>();
            var next_tok = self._src->next_with_origin(&chain);
            self._emit(next_tok, &chain);
        }

        {
            var _tf = TimeRegion("Finalize");
            self._finalize();
        }
        return !self._diag->has_fatal();
    }

    //  Emission single choke point + disallow backstop

    /// \param chain the token's macro-origin chain, as captured atomically by
    ///        TokenSource::next_with_origin at the moment it was pulled.
    ///        &null (the default) for call sites that don't route through
    ///        next_with_origin (ffi/vis-keyword passthrough, scope-tracked
    ///        brace/module tokens, the poison sentinel): those tokens are
    ///        never origin-wrapped, same as before this existed.
    priv fn _emit(self, t: Token, chain: *vec::<InvokeHop> = &null) {
        // Sampled, same reasoning as _detect_invocation: the single choke
        // point every token passes through.
        var _t = TimeSampled(self._t_emit, 64, &self._c_emit);
        if self._collect { return; }   // collect_macros: a read, not a walk.

        if self._src->in_splice() {
            if (t.kind == TokenKind::KwImport) || (t.kind == TokenKind::KwMacro) {
                // BACKSTOP (primary check is at def time). To lift the rule:
                // delete this block and route these kinds into the walk switch.
                self._diag->report(DiagCode(DiagID::R012E),
                    self._src->top_invoke_loc().start,
                    "macro expansion may not produce 'import' or 'macro' declarations"
                ).first(self._src->top_invoke_loc()).emit();
                return;
            }
        }

        if (chain != &null) && (chain->size() > 0) {
            self._wrap_origin(&t, chain);
        }

        self._sink->append(t);
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
    priv fn _wrap_origin(self, t: *Token, chain: *vec::<InvokeHop>) {
        if t->kind == TokenKind::TkMacroExpand { return; }

        var cur_kind  = t->kind;
        var cur_imm   = t->imm;
        var def_range = t->range;

        for var i: usize = 0; i < chain->size(); ++i {
            var hop = (*chain)[i];

            var idx  = self._imm->create::<Immediate::MacroExpansionInfo>();
            var info = self._imm->get::<Immediate::MacroExpansionInfo>(idx);
            info->invoke_range  = hop.loc;
            info->def_range     = def_range;
            info->original_kind = cur_kind;
            info->original_imm  = cur_imm;
            info->macro_name    = hop.name;
            info->parent_idx    = u32(-1);

            cur_kind = TokenKind::TkMacroExpand;
            cur_imm  = idx;
        }

        t->kind  = TokenKind::TkMacroExpand;
        t->imm   = cur_imm;
        t->range = (*chain)[0].loc; // outermost invocation: the token's reportable position
    }

    //  Scope tracking
    //  ScopeTracker consumes from a TokenSpan today. On the stream we feed it
    //  one token at a time via a 1-token shim. The tracker only needs the
    //  current token + the ability to look at i+1 for `module Foo {`; we give
    //  it a 2-token window built from peeks. This is the one place the
    //  tracker's API forces a small adapter.

    priv fn _track_scope(self, t: Token, vis: ModuleVisibility) -> bool {
        var k = t.kind;
        if (k != TokenKind::OpLBrace) && (k != TokenKind::OpRBrace)
        && (k != TokenKind::KwModule) {
            return false;
        }
        self._tracker->feed_stream(self._src, vis, fn(tok: Token) { self._emit(tok); });
        return true;
    }

    //  FFI

    priv fn _handle_ffi(self) {
        // Decide form by lookahead BEFORE emitting anything.
        //   peek0 = ffi, peek1 = "lang", peek2 = import | { | decl-lead
        var p2 = self._src->peek(2).kind;

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
            var ffi_kw   = self._src->next(); // ffi
            var lang_tok = self._src->next(); // "lang"
            self._src->next();                // import

            var header_tok = Token{};
            var alias_tok  = Token{};
            var has_alias  = false;
            var last       = lang_tok;
            var saw_header = false;
            while !self._src->at_eof() {
                if self._src->peek(0).kind == TokenKind::OpSemicolon {
                    last = self._src->next();
                    break;
                }
                var t = self._src->next();
                last = t;
                if (!saw_header) && (t.kind == TokenKind::LitString) {
                    header_tok = t;
                    saw_header = true;
                    continue;
                }
                if t.kind == TokenKind::KwAs {
                    if self._src->peek(0).kind == TokenKind::LitIdentifier {
                        alias_tok = self._src->next();
                        has_alias = true;
                        last      = alias_tok;
                    }
                    continue;
                }
                if t.kind == TokenKind::TkNewLine { break; }
            }

            var fr = ffi_kw.range | last.range;
            var fid_node = ImportDecl::create(self._ctx, fr, ImportKind::Native);
            fid_node->header    = header_tok;
            fid_node->alias     = alias_tok;
            fid_node->has_alias = has_alias;
            fid_node->range     = fr;
            fid_node->set_ffi_linkage(self._ffi_lang_kind(lang_tok), lang_tok, fr);
            self._tu->imports.push(static_cast::<*Decl>(fid_node));

            if saw_header {
                var h = HeaderSet::unquote(self._ctx->get_spelling(header_tok));
                var dup = false;
                for var i: usize = 0; i < self._ffi_headers.size(); ++i {
                    if self._ffi_headers[i] == h { dup = true; break; }
                }
                if (!dup) && (h.size() > 0) {
                    self._ffi_headers.push_back(h);
                    self._ffi_c.push_back(self._ffi_lang_kind(lang_tok) == LinkageKind::C);
                    self._ffi_locs.push_back(header_tok.range);
                }
            }
            return;
        }

        // ffi "lang" { ... }  or  ffi "lang" <decl>  -> copy through.
        // Emit ffi + lang, then let the normal walk copy the rest. The block's
        // braces balance via ordinary emission; a single decl ends at its own
        // terminator. Nothing special needed just resume.
        self._emit(self._src->next()); // ffi
        self._emit(self._src->next()); // lang
        // walk resumes; `{`/decl tokens copy normally. Macro invocations INSIDE
        // an ffi block still expand (they did before) the walk doesn't treat
        // ffi-block interior as special, matching current behavior.
    }

    //  Imports

    priv fn _handle_import(self, default_vis: u8) {
        var _t = TimeRegion("Import");

        // visibility already consumed by caller when prefixed; default_vis
        // carries priv(1) unless caller saw pub/prot/priv.
        var vis = default_vis;

        var spec = self.parse_import_spec();   // shared grammar (consumes stmt)
        if !spec.ok {
            self._recover_to_terminator();
            return;
        }

        // build the ImportDecl node into the TU (authority for klib)
        var id = self._build_import_decl(&spec, vis);
        self._tu->imports.push(static_cast::<*Decl>(id));

        // resolve NOW; errors HERE. record() stamps id->resolved_fid and hands
        // back the source-module fid; a resolved import becomes a TU import
        // edge in declaration order (the one writer of import_edges). ffi
        // imports never reach here, so no edge is ever synthesized for them.
        // Resolved is file_seg_count, not a non-zero fid: fid 0 is the first
        // input, which a module it imports may import back (an import cycle
        // through the entry file), and that edge was dropped with the rest.
        var target_fid = self._imports->record(id);
        if id->file_seg_count > 0 {
            var edge = ImportEdge{};
            edge.target_fid = target_fid;
            edge.decl       = static_cast::<*Decl>(id);
            self._tu->import_edges.push(edge);
        }

        // consume trailing `;` if present (grammar leaves it)
        if self._src->peek(0).kind == TokenKind::OpSemicolon { self._src->next(); }
        // NOTHING emitted import is PP-invisible in the output buffer.
    }

    priv fn _build_import_decl(self, spec: *ImportSpec, vis: u8) -> *ImportDecl {
        var id = ImportDecl::create(self._ctx, spec->range,
            (ImportKind::ModuleOnly) if (spec->is_module) else (ImportKind::Native));

        var segs: std::StackBuf::<Token, 8>;
        for var i: usize = 0; i < spec->segments.size(); ++i { segs.push_back(spec->segments[i]); }
        id->path_segments.from_buf(segs.data(), segs.size(), self._ctx);
        id->last_seg_is_macro = spec->last_seg_is_macro;
        id->is_wildcard       = spec->is_wildcard;

        if spec->has_items {
            var items: std::StackBuf::<ImportItem, 8>;
            for var i: usize = 0; i < spec->items.size(); ++i {
                var s = &spec->items[i];
                var item = ImportItem{};
                var sub: std::StackBuf::<Token, 4>;
                for var j: usize = 0; j < s->sub_path.size(); ++j { sub.push_back(s->sub_path[j]); }
                item.sub_path.from_buf(sub.data(), sub.size(), self._ctx);
                item.alias       = s->alias;
                item.has_alias   = s->has_alias;
                item.is_wildcard = s->is_wildcard;
                item.is_macro    = s->is_macro;
                item.range       = s->range;
                items.push_back(item);
            }
            id->items.from_buf(items.data(), items.size(), self._ctx);
            id->has_items = true;
        }

        id->alias     = spec->alias;
        id->has_alias = spec->has_alias;
        id->set_visibility(self._u8_to_vis(vis), spec->range);
        id->range     = spec->range;
        return id;
    }

    /// `"c"` -> C, anything else -> Cpp. The parser owns the real
    /// classification and its diagnostic; the PP only needs enough to make
    /// has_ffi_linkage() true and to carry the language to codegen.
    priv fn _ffi_lang_kind(self, lang_tok: Token) -> LinkageKind {
        var s = TokenText::resolve(lang_tok, self._tcm).get_text();
        if (s == "\"c\"") || (s == "c") { return LinkageKind::C; }
        return LinkageKind::Cpp;
    }

    priv fn _u8_to_vis(self, vis: u8) -> VisibilityKind {
        if vis == 1 { return VisibilityKind::Private;   }
        if vis == 2 { return VisibilityKind::Protected; }
        if vis == 3 { return VisibilityKind::Public;    }
        return VisibilityKind::None;
    }

    //  Macro definitions

    priv fn _handle_macro_def(self, vis: u8) {
        var _t = TimeRegion("MacroDef");

        var kw = self._src->next(); // `macro`

        // proc macro `macro @name` copy through, not ours
        if self._src->peek(0).kind == TokenKind::OpAt {
            self._emit(kw);
            return; // remaining @-macro tokens flow to output via the walk
        }

        var hdr = self.parse_macro_header();  // shared grammar
        if !hdr.ok { self._recover_to_terminator(); return; }

        // builtin names are reserved: dispatch checks builtins before user
        // macros, so this definition could never fire. Reject loudly instead
        // of letting the builtin silently hijack every call site.
        var def_name = TokenText::spelling(hdr.name, self._tcm);
        if self._is_builtin_name(def_name) {
            self._diag->report(DiagCode(DiagID::R014E), hdr.name.range.start,
                f"macro '{def_name}!' redefines a compiler builtin; builtin names are reserved"
            ).first(hdr.name.range).emit();

            // discard the balanced body so it doesn't leak into the output
            // stream; _recover_to_terminator stops at newlines and would
            // spill multi-line bodies.
            if self._src->peek(0).kind == TokenKind::OpLBrace {
                self._src->next(); // `{`
                var d: i32 = 1;
                while (!self._src->at_eof()) && (d > 0) {
                    var t = self._src->next();
                    if t.kind == TokenKind::OpLBrace { d += 1; }
                    if t.kind == TokenKind::OpRBrace { d -= 1; }
                }
            } else {
                self._recover_to_terminator();
            }
            return;
        }

        if self._src->peek(0).kind != TokenKind::OpLBrace {
            self._diag->report(DiagCode(DiagID::S038E), hdr.name.range.start,
                "expected '{' for macro body").first(hdr.name.range).emit();
            return;
        }
        var lbrace = self._src->next().range; // `{`

        var storage = std::create::<TokenBuffer::<512>>();
        var depth: i32 = 1;
        var seen_content = false;

        while !self._src->at_eof() {
            var t = self._src->next();
            if t.kind == TokenKind::OpLBrace { depth += 1; }
            if t.kind == TokenKind::OpRBrace {
                depth -= 1;
                if depth == 0 { break; }
            }
            if (t.kind == TokenKind::KwImport) || (t.kind == TokenKind::KwMacro) {
                self._diag->report(DiagCode(DiagID::R012E), t.range.start,
                    "'import' and 'macro' are not allowed inside a token macro body"
                ).first(t.range).emit();
            }
            if (!seen_content) && (t.kind == TokenKind::TkNewLine) { continue; } // leading trim
            seen_content = true;
            storage->append(t);
        }
        if depth != 0 {
            self._diag->report(DiagCode(DiagID::S039E), lbrace.start,
                "unmatched '{' in macro body").first(lbrace).emit();
            std::destroy(storage);
            return;
        }

        // trim edge newlines (THE newline fix)
        while (storage->size() > 0)
           && (storage->get(storage->size() - 1)->kind == TokenKind::TkNewLine) {
            storage->pop_back();
        }
        var lead: usize = 0;
        while (lead < storage->size())
           && (storage->get(lead)->kind == TokenKind::TkNewLine) { lead += 1; }
        if lead > 0 {
            var trimmed = std::create::<TokenBuffer::<512>>();
            for var i: usize = lead; i < storage->size(); ++i {
                trimmed->append(*(storage->get(i)));
            }
            std::destroy(storage);
            storage = trimmed;
        }

        var body_len = u32(storage->size());

        // params + defaults appended after body
        var specs: std::StackBuf::<MacroParamSpec, 4>;
        var is_variadic = false;
        for var i: usize = 0; i < hdr.params.size(); ++i {
            var hp = &hdr.params[i];
            var sp = MacroParamSpec{};
            sp.name     = hp->name;
            sp.variadic = hp->variadic;
            if hp->variadic != 0 { is_variadic = true; }
            if hp->has_default {
                sp.has_default = true;
                sp.default_off = u32(storage->size());
                for var j: usize = 0; j < hp->default_toks.size(); ++j {
                    storage->append(hp->default_toks[j]);
                }
                sp.default_len = u32(storage->size()) - sp.default_off;
            }
            specs.push_back(sp);
        }

        if self._src->peek(0).kind == TokenKind::OpSemicolon { self._src->next(); }

        // node into TU
        var decl = MacroDecl::create(self._ctx, kw.range | lbrace, hdr.name);
        decl->params_spec.from_buf(specs.data(), specs.size(), self._ctx);
        decl->accepts_params = hdr.accepts_params;
        decl->is_variadic    = is_variadic;
        
        if body_len > 0 {
            decl->body_span = storage->get(0)->range | storage->get(usize(body_len) - 1)->range;
        }

        decl->set_visibility(self._u8_to_vis(vis), kw.range | lbrace);
        self._tu->macros.push(decl);

        var entry = std::create::<MacroEntry>();
        entry->decl       = decl;
        entry->storage    = storage;
        entry->body_len   = body_len;
        entry->name_sym   = self._sym->intern(TokenText::spelling(hdr.name, self._tcm));
        entry->scope      = self._tracker->current_scope();
        entry->source_fid = self._fid;
        entry->visibility = vis;

        if !self._macros->register(entry) {
            self._diag->report(DiagCode(DiagID::S040E), hdr.name.range.start,
                f"duplicate macro '{TokenText::spelling(hdr.name, self._tcm)}!' in this scope"
            ).first(hdr.name.range).emit();
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
        var qualified:     ModulePath;
        var chain:         vec::<SymbolID>;  ///< frame names live at detection
        var parent_chain:  vec::<InvokeHop>; ///< full origin chain live at detection;
                                              ///  threaded into push_splice for
                                              ///  THIS invocation's own result
                                              ///  (see TokenSource::current_chain)
        var arg_toks:     vec::<Token>;    ///< raw tokens between ( ), balanced
        var name:         Token;
        var name_sym:     SymbolID    = 0;
        var range:        SourceRange = SourceRange::invalid();
        var origin_site:  SourceRange = SourceRange::invalid(); ///< outermost invoke loc at detection
        var is_qualified: bool        = false;
        var found:        bool        = false;
        var has_args:     bool        = false;
    }

    priv fn _detect_invocation(self) -> InvocationInfo {
        // Sampled: runs on EVERY token and almost always answers no, so it is
        // both hot and a plausible bottleneck   exactly the case an unsampled
        // scope cannot measure without becoming the cost it is measuring.
        var _t = TimeSampled(self._t_detect, 64, &self._c_detect);

        var result = InvocationInfo();

        result.origin_site = self._src->bottom_invoke_loc();
        self._src->snapshot_chain(&result.chain);
        self._src->current_chain(&result.parent_chain);

        if self._src->peek(0).kind != TokenKind::LitIdentifier { return result; }

        // -- try to parse a path: ident (:: ident)* ----------------------
        var path_toks = vec::<Token>();
        path_toks.push_back(self._src->peek(0));

        var n: usize = 1;
        while true {
            if self._src->peek(n).kind != TokenKind::OpColonColon { break; }
            if self._src->peek(n + 1).kind != TokenKind::LitIdentifier { break; }
            path_toks.push_back(self._src->peek(n + 1));
            n += 2;
        }

        // -- expect `!` after the last identifier -------------------------
        if self._src->peek(n).kind != TokenKind::OpExclaim { return result; }
        var bang_offset = n;

        var name_tok = path_toks[path_toks.size() - 1];

        // label!/jump!/unwrap! are PARSER intrinsics, not macros: leave the
        // raw tokens in the stream untouched; the parser owns the grammar
        // (`label` `!` `(` ident `)` in StmtParse, `unwrap` `!` `(` expr `)`
        // in ExprParse, whose operand must stay an ordinary expression).
        // So are the type facts (EVAL.md 4.2b): their operand is a TYPE,
        // which only the parser can tell from a value.
        // Qualified forms (`a::label!`) are NOT intrinsics and still resolve
        // as ordinary macros.
        if path_toks.size() == 1 {
            var sp = TokenText::spelling(name_tok, self._tcm);
            if (sp == LangIntrinsics::label()) || (sp == LangIntrinsics::jump()) || (sp == LangIntrinsics::unwrap()) { return result; }
            if (sp == LangIntrinsics::is_trivially_copyable()) || (sp == LangIntrinsics::is_trivially_destructible()) { return result; }
            // A `defined!` _builtin_defined already passed through raw.
            if (sp == LangIntrinsics::defined()) && self._defined_raw.contains(name_tok.range.start.raw()) { return result; }
        }

        result.found   = true;
        result.name    = name_tok;
        result.name_sym = self._sym->intern(TokenText::spelling(name_tok, self._tcm));

        if path_toks.size() > 1 {
            result.is_qualified = true;
            result.qualified    = ModulePath();
            for var k: usize = 0; k + 1 < path_toks.size(); ++k {
                var seg = IdentifierToken();
                seg.token = &null; // peeked copy, not a source-owned pointer
                seg.name  = self._sym->intern(TokenText::spelling(path_toks[k], self._tcm));
                result.qualified.segments.push_back(seg);
            }
        }

        n = bang_offset + 1; // past `!`

        // -- check for argument list `(` ... `)` ---------------------------
        var has_paren = (self._src->peek(n).kind == TokenKind::OpLParen);
        var total_consumed: usize;

        if has_paren {
            result.has_args = true;
            var depth: i32 = 1;
            var arg_start = n + 1; // first token inside `(`
            var m = arg_start;
            while true {
                var t = self._src->peek(m);
                if t.kind == TokenKind::TkEof    { result.found = false; return result; }
                if t.kind == TokenKind::OpLParen { depth += 1; }
                if t.kind == TokenKind::OpRParen {
                    depth -= 1;
                    if depth == 0 { break; }
                }

                m += 1;
            }

            // m is the index of the matching `)`
            for var k: usize = arg_start; k < m; ++k {
                result.arg_toks.push_back(self._src->peek(k));
            }

            total_consumed = m + 1; // past `)`
        } else {
            total_consumed = bang_offset + 1; // just past `!`
        }

        result.range = self._src->peek(0).range | self._src->peek(total_consumed - 1).range;

        // -- commit: consume exactly what we detected -----------------------
        for var k: usize = 0; k < total_consumed; ++k {
            self._src->next();
        }

        return result;
    }

    priv fn _report_expand_err(
        self, code: DiagID, inv: *InvocationInfo, msg: string,
        note: string = "expanded from here", remark: string = ""
    ) {
        var site = self._inv_site(inv);
        if !remark.empty() {
            if (site.start.id) != (inv->range.start.id) {
                self._diag->report(DiagCode(code), site.start, msg)
                    .first(site)
                    .note(inv->range.start, note)
                        .child_first(inv->range)
                    .remark(remark)
                    .emit();
                return;
            }

            self._diag->report(DiagCode(code), site.start, msg)
                .first(site).remark(remark).emit();
            
            return;
        }

        if (site.start.id) != (inv->range.start.id) {
            self._diag->report(DiagCode(code), site.start, msg)
                .first(site)
                .note(inv->range.start, note)
                    .child_first(inv->range)
                .emit();
            return;
        }

        self._diag->report(DiagCode(code), site.start, msg)
            .first(site).emit();
        
        return;
    }

    priv fn _expand(self, inv: InvocationInfo) {
        if self._opts.macro_debug {
            // --cmacro-trace-depth caps how deep the log follows nested expansion;
            // 0 (default) is unlimited, matching every other --cmax-* knob's convention.
            var depth = self._src->depth();
            var within_trace_depth = (self._opts.trace_depth <= 0) || (i32(depth) <= self._opts.trace_depth);

            var nm = self._sym_name(inv.name_sym);
            if within_trace_depth
            && (self._opts.macro_debug_filter.empty() || (nm == self._opts.macro_debug_filter)) {
                // Straight to stderr, not the Logger: Logger::info is gated on -v,
                // which made --macro-debug print nothing on its own. The user
                // asked for this trace by name; it must not need a second flag.
                std::eprintln(f"[macro-debug] expand '{nm}!' depth={depth} count={self._expansion_count}");
            }
        }

        var b = self._try_builtin(&inv);
        if b != &null {
            self._push_splice(b, inv.name_sym, inv.range, &inv.parent_chain);
            return;
        }

        var entry = self._resolve(inv);
        if entry == &null {
            self._report_expand_err(DiagID::R013E, &inv,
                f"unknown macro '{self._sym_name(inv.name_sym)}!' (macros must be defined or imported before use)");
            self._emit_poison(&inv);
            return;
        }

        if entry->decl->accepts_params && (!inv.has_args) {
            self._report_expand_err(DiagID::R006E, &inv,
                f"macro '{self._sym_name(inv.name_sym)}!' requires arguments; add '(...)\x27");
            self._emit_poison(&inv);
            return;
        }

        if (!entry->decl->accepts_params) && inv.has_args {
            self._report_expand_err(DiagID::R007E, &inv,
                f"macro '{self._sym_name(inv.name_sym)}!' is parameterless; remove '(...)\x27");
            self._emit_poison(&inv);
            return;
        }

        if i32(self._src->depth()) >= self._opts.max_depth {
            // Once per chain (keyed on the outermost invoke site); the poison
            // still goes out so the chain stops expanding here either way.
            var chain_key = inv.origin_site.start.raw();
            if !self._depth_reported.contains(chain_key) {
                self._depth_reported.insert(chain_key);
                self._report_expand_err(DiagID::R008E, &inv,
                    f"macro expansion depth limit ({self._opts.max_depth}) exceeded",
                    "expanded from here",
                    f"limit can be increased with --cmax-macro-depth=N");
            }
            self._emit_poison(&inv);
            return;
        }

        if (self._opts.max_expansions > 0) && (self._expansion_count >= self._opts.max_expansions) {
            self._report_expand_err(DiagID::R008E, &inv,
                "macro expansion budget exhausted",
                "expanded from here",
                f"budget can be increased with --cmax-macro-expansions=N, current budget is {self._opts.max_expansions}");

            self._emit_poison(&inv);
            return;
        }

        if (self._opts.max_expansions > 0) && (self._expansion_count >= self._opts.max_expansions) {
            self._report_expand_err(DiagID::R008E, &inv,
                "macro expansion budget exhausted",
                "expanded from here",
                f"budget can be increased with --cmax-macro-expansions=N, current budget is {self._opts.max_expansions}");
            return;
        }

        var cyclic = false;
        for s in inv.chain {
            if s == entry->name_sym { cyclic = true; break; }
        }

        if cyclic {
            self._report_expand_err(DiagID::R008E, &inv,
                f"cyclic expansion of macro '{self._sym_name(inv.name_sym)}!\x27",
                "recursion occurs here, in the macro body",
                "a macro cannot invoke itself; recursion is not supported in token macros");
            self._emit_poison(&inv);
            return;
        }

        self._expansion_count += 1;

        //    ARGUMENTS PRE-EXPAND IN CALLER CONTEXT (before pushing the frame)
        //    Each arg is a token run; expand invocations within it against the
        //    CURRENT chain by recursively running a nested expansion over a
        //    temporary TokenSource seeded with the arg tokens. Because the
        //    callee is NOT yet on the stack, square!(square!(x)) is legal.
        var bound = self._bind_and_substitute(entry, &inv);
        if bound == &null { return; }

        //    push; the walk re-enters the spliced body next loop turn, and any
        //    nested invocations inside it are found by _detect_invocation again.
        self._push_splice(bound, entry->name_sym, inv.range, &inv.parent_chain);
    }

    priv fn _push_splice(
        self, buf: *(TokenBuffer::<512>), name: SymbolID, loc: SourceRange,
        parent_chain: *vec::<InvokeHop>
    ) {
        self._splices.push_back(buf);       // own it for the run's lifetime
        self._src->push_splice(buf, name, loc, parent_chain);
    }

    priv fn _buf_has_invocation(self, b: *(TokenBuffer::<512>)) -> bool {
        for var i: usize = 0; i + 1 < b->size(); ++i {
            if (b->get(i)->kind == TokenKind::LitIdentifier)
            && (b->get(i + 1)->kind == TokenKind::OpExclaim) {
                return true;
            }
        }
        return false;
    }

    priv fn _expand_buffer(self, src_buf: *(TokenBuffer::<512>), parent_chain: *vec::<InvokeHop>) -> *(TokenBuffer::<512>) {
        var out   = std::create::<TokenBuffer::<512>>();
        var saved = self._sink;
        self._sink = out;

        var d0 = self._src->depth();
        self._src->push_splice(src_buf, 0, SourceRange::invalid(), parent_chain);

        while self._src->depth() > d0 {
            var t = self._src->peek(0);
            if t.kind == TokenKind::TkEof { break; }
            var inv = self._detect_invocation();
            if inv.found { self._expand(inv); continue; }
            var chain = vec::<InvokeHop>();
            var next_tok = self._src->next_with_origin(&chain);
            self._emit(next_tok, &chain);
        }

        self._sink = saved;
        return out;
    }

    priv fn _bind_and_substitute(self, e: *MacroEntry, inv: *InvocationInfo) -> *(TokenBuffer::<512>) {
        // Args pre-expand in CALLER context: the callee's frame is not on the
        // stack yet, so square!(square!(x)) is legal. Cycle detection then only
        // fires on true body-recursion (boom!).
        // Split FIRST, then expand each arg: commas produced by expansion do
        // not change the call's arity (C semantics). Value-position builtins
        // deliberately differ see _parse_expanded_builtin_arguments.
        var args = self._parse_builtin_arguments(inv); // splits on top-level commas

        for var k: usize = 0; k < args.size(); ++k {
            if self._buf_has_invocation(args[k]) {
                var ex = self._expand_buffer(args[k], &inv->parent_chain);
                std::destroy(args[k]);
                args[k] = ex;
            }
        }

        var params   = &(e->decl->params_spec);
        var required: usize = 0;
        var has_variadic = false;
        var variadic_idx: usize = 0;
        for var k: usize = 0; k < params->size(); ++k {
            var p = params->get(k);
            if p->variadic != 0 { has_variadic = true; variadic_idx = k; break; }
            if !p->has_default { required += 1; }
        }
        var non_variadic_count = variadic_idx if has_variadic else params->size();

        if args.size() < required {
            self._report_expand_err(DiagID::R006E, inv,
                f"macro '{self._sym_name(inv->name_sym)}!' expects at least {required} arguments, got {args.size()}");
            return &null;
        }
        if (!has_variadic) && (args.size() > params->size()) {
            self._report_expand_err(DiagID::R006E, inv,
                f"macro '{self._sym_name(inv->name_sym)}!' expects at most {params->size()} arguments, got {args.size()}");
            return &null;
        }

        var bindings = map::<SymbolID, *(TokenBuffer::<512>)>();
        for var k: usize = 0; k < non_variadic_count; ++k {
            var p = params->get(k);
            var name_sym = self._sym->intern(TokenText::spelling(p->name, self._tcm));
            if k < args.size() {
                bindings[name_sym] = args[k];
            } else if p->has_default {
                var dflt = std::create::<TokenBuffer::<512>>();
                for var d: usize = p->default_off; d < p->default_off + p->default_len; ++d {
                    dflt->append(*(e->storage->get(d)));
                }
                bindings[name_sym] = dflt;
                self._splices.push_back(dflt); // owner; freed in op delete (leak fix)
            }
        }

        var variadic_name: SymbolID = 0;
        var variadic_bindings = vec::<*(TokenBuffer::<512>)>();
        if has_variadic {
            var vp = params->get(variadic_idx);
            variadic_name = self._sym->intern(TokenText::spelling(vp->name, self._tcm));
            for var k: usize = non_variadic_count; k < args.size(); ++k {
                variadic_bindings.push_back(args[k]);
            }
        }

        return self._substitute_body(e, &bindings, variadic_name, &variadic_bindings, inv->range);
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
        e: *MacroEntry,
        bindings: *map::<SymbolID, *(TokenBuffer::<512>)>,
        variadic_name: SymbolID,
        variadic_bindings: *vec::<*(TokenBuffer::<512>)>,
        invoke_loc: SourceRange
    ) -> *(TokenBuffer::<512>) {
        var output = std::create::<TokenBuffer::<512>>();
        var i: usize = 0;
        while i < e->body_len {
            var tok = e->storage->get(i);

            // -- pattern splat: `(` pattern `)` `...` --------------------
            if (tok->kind == TokenKind::OpLParen) && (variadic_name != 0) {
                var close = self._find_matching_rparen(e, i);
                if (close != 0)
                && (close + 1 < e->body_len)
                && (e->storage->get(close + 1)->kind == TokenKind::OpEllipsis)
                && self._pattern_mentions_pack(e, i + 1, close, variadic_name) {
                    for var k: usize = 0; k < variadic_bindings->size(); ++k {
                        if k > 0 { self._append_builtin_comma(output, invoke_loc); }
                        self._emit_pattern_instance(
                            output, e, i + 1, close,
                            bindings, variadic_name, (*variadic_bindings)[k]);
                    }
                    i = close + 2;
                    continue;
                }
                // not a pack pattern: plain parenthesized tokens, fall through
            }

            if tok->kind == TokenKind::LitIdentifier {
                var tok_name = self._sym->intern(TokenText::spelling(*tok, self._tcm));

                // -- bare splat: `xs` `...` ------------------------------
                if (tok_name == variadic_name)
                && (i + 1 < e->body_len)
                && (e->storage->get(i + 1)->kind == TokenKind::OpEllipsis) {
                    for var k: usize = 0; k < variadic_bindings->size(); ++k {
                        if k > 0 { self._append_builtin_comma(output, invoke_loc); }
                        var span = (*variadic_bindings)[k];
                        for var j: usize = 0; j < span->size(); ++j {
                            output->append(*(span->get(j)));
                        }
                    }
                    i += 2;
                    continue;
                }

                if bindings->contains(tok_name) {
                    var bound = (*bindings)[tok_name];
                    for var j: usize = 0; j < bound->size(); ++j {
                        output->append(*(bound->get(j)));
                    }
                    i += 1;
                    continue;
                }
            }

            output->append(*tok);
            i += 1;
        }
        return output;
    }

    /// index of the `)` matching the `(` at `open`, or 0 if unbalanced
    /// (0 can never be a valid answer: the match is always past `open`).
    priv fn _find_matching_rparen(self, e: *MacroEntry, open: usize) -> usize {
        var depth: i32 = 0;
        for var i: usize = open; i < e->body_len; ++i {
            var k = e->storage->get(i)->kind;
            if k == TokenKind::OpLParen { depth += 1; }
            if k == TokenKind::OpRParen {
                depth -= 1;
                if depth == 0 { return i; }
            }
        }
        return 0;
    }

    /// does the token run [lo, hi) mention the pack name?
    priv fn _pattern_mentions_pack(
        self,
        e: *MacroEntry,
        lo: usize,
        hi: usize,
        variadic_name: SymbolID
    ) -> bool {
        for var i: usize = lo; i < hi; ++i {
            var t = e->storage->get(i);
            if t->kind != TokenKind::LitIdentifier { continue; }
            if self._sym->intern(TokenText::spelling(*t, self._tcm)) == variadic_name {
                return true;
            }
        }
        return false;
    }

    /// emits one instance of the pattern token run [lo, hi): the pack name is
    /// replaced by `element`, ordinary parameter bindings substitute as usual,
    /// everything else is copied verbatim.
    priv fn _emit_pattern_instance(
        self,
        output: *(TokenBuffer::<512>),
        e: *MacroEntry,
        lo: usize,
        hi: usize,
        bindings: *map::<SymbolID, *(TokenBuffer::<512>)>,
        variadic_name: SymbolID,
        element: *(TokenBuffer::<512>)
    ) {
        for var i: usize = lo; i < hi; ++i {
            var tok = e->storage->get(i);

            if tok->kind == TokenKind::LitIdentifier {
                var tok_name = self._sym->intern(TokenText::spelling(*tok, self._tcm));

                if tok_name == variadic_name {
                    for var j: usize = 0; j < element->size(); ++j {
                        output->append(*(element->get(j)));
                    }
                    continue;
                }

                if bindings->contains(tok_name) {
                    var bound = (*bindings)[tok_name];
                    for var j: usize = 0; j < bound->size(); ++j {
                        output->append(*(bound->get(j)));
                    }
                    continue;
                }
            }

            output->append(*tok);
        }
    }

    priv fn make_int_token(self, value: u64, range: SourceRange) -> Token {
        var tok = Token();
        tok.kind  = TokenKind::LitInt;
        tok.range = range;
        if self._imm != &null {
            var idx  = self._imm->create::<Immediate::IntData>();
            var data = self._imm->get::<Immediate::IntData>(idx);
            data->value_lo = value;
            data->value_hi = 0;
            data->bits     = 32;
            data->base     = 10;
            data->flags    = 0;
            data->body     = range;
            tok.imm = idx;
        }
        return tok;
    }

    priv fn _punct(self, k: TokenKind, range: SourceRange) -> Token {
        var tok = Token();
        tok.kind  = k;
        tok.range = range;
        return tok;
    }

    priv fn make_ident_token(self, name: string, range: SourceRange) -> Token {
        var tok = Token();
        tok.kind  = TokenKind::LitIdentifier;
        tok.range = range;
        if self._imm != &null {
            tok.imm = self._imm->intern_ident_copy(name);
        }
        return tok;
    }

    //  Builtins

    priv fn _try_builtin(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        // Builtins are unqualified. `foo::count!` must resolve as an ordinary
        // macro instead of being hijacked by the builtin dispatcher.
        if invoke->is_qualified {
            return &null;
        }

        var name = self._sym_name(invoke->name_sym);

        // source location
        if name == LangMacros::file()        { return self._builtin_file(invoke); }
        if name == LangMacros::line()        { return self._builtin_line(invoke); }
        if name == LangMacros::column()      { return self._builtin_column(invoke); }
        if name == LangMacros::module_path() { return self._builtin_module_path(invoke); }

        // argument manipulation
        if name == LangMacros::count()   { return self._builtin_count(invoke); }
        if name == LangMacros::first()   { return self._builtin_first(invoke); }
        if name == LangMacros::last()    { return self._builtin_last(invoke); }
        if name == LangMacros::rest()    { return self._builtin_rest(invoke); }
        if name == LangMacros::butlast() { return self._builtin_butlast(invoke); }

        // token manipulation
        if name == LangMacros::paste()       { return self._builtin_paste(invoke); }
        if name == LangMacros::stringify()   { return self._builtin_stringify(invoke); }
        if name == LangMacros::unstringify() { return self._builtin_unstringify(invoke); }

        // macro visibility
        if name == LangIntrinsics::defined() { return self._builtin_defined(invoke); }

        // deferred code generation
        if name == LangMacros::todo()        { return self._builtin_todo(invoke); }
        if name == LangMacros::unreachable() { return self._builtin_unreachable(invoke); }
        if name == LangMacros::unreachable_unchecked() {
            return self._builtin_unreachable_unchecked(invoke);
        }
        if name == LangMacros::unique_id()   { return self._builtin_unique_id(invoke); }
        if name == LangMacros::include()     { return self._builtin_include(invoke); }
        if name == LangMacros::embed_str()   { return self._builtin_embed_str(invoke); }
        if name == LangMacros::embed()       { return self._builtin_embed(invoke); }

        // diagnostics
        if name == LangMacros::compile_error() {
            return self._builtin_diag(invoke, DiagSeverity::Error);
        }
        if name == LangMacros::compile_warn() {
            return self._builtin_diag(invoke, DiagSeverity::Warning);
        }
        if name == LangMacros::compile_note() {
            return self._builtin_diag(invoke, DiagSeverity::Note);
        }

        return &null;
    }

    /// Builtin names are reserved unqualified: a user definition would never
    /// be reachable (dispatch checks builtins first), so `_handle_macro_def`
    /// rejects the definition outright instead of silently hijacking it.
    /// MUST mirror the dispatch table in `_try_builtin`; both spell every
    /// name through LangMacros / LangIntrinsics, so a rename cannot split them.
    priv fn _is_builtin_name(self, name: string) -> bool {
        return (name == LangMacros::file())        || (name == LangMacros::line())
            || (name == LangMacros::column())      || (name == LangMacros::module_path())
            || (name == LangMacros::count())       || (name == LangMacros::first())
            || (name == LangMacros::last())        || (name == LangMacros::rest())
            || (name == LangMacros::butlast())     || (name == LangMacros::paste())
            || (name == LangMacros::stringify())   || (name == LangMacros::unstringify())
            || (name == LangIntrinsics::defined())     || (name == LangMacros::todo())
            || (name == LangMacros::unreachable()) || (name == LangMacros::unreachable_unchecked())
            || (name == LangMacros::unique_id())   || (name == LangMacros::include())
            || (name == LangMacros::embed_str())   || (name == LangMacros::embed())
            || (name == LangMacros::compile_error())
            || (name == LangMacros::compile_warn())
            || (name == LangMacros::compile_note())
            // parser intrinsics (no _try_builtin entry: _detect_invocation
            // passes them through raw): reserved so a user macro named
            // label/jump can never be reached at an unqualified call site.
            || (name == LangIntrinsics::label())       || (name == LangIntrinsics::jump())
            || (name == LangIntrinsics::unwrap());
    }

    //  Builtin helpers

    priv fn _builtin_report(
        self,
        range: SourceRange,
        message: string,
        code: DiagID
    ) {
        self._diag->report(
            DiagCode(code),
            range.start,
            message
        ).first(range).emit();
    }

    priv fn _inv_site(self, inv: *InvocationInfo) -> SourceRange {
        if inv->origin_site.is_valid() { return inv->origin_site; }
        return inv->range;
    }

    priv fn _emit_poison(self, inv: *InvocationInfo) {
        var tok = Token();
        tok.kind  = TokenKind::TkMacroExpand;
        tok.range = self._inv_site(inv);
        tok.imm   = static_cast::<u32>(MacroSentinel::Poison);
        self._emit(tok);
    }

    /// Splits the tokens inside `(...)` at top-level commas.
    ///
    /// `invoke.arg_toks` already excludes the outer `(` and `)`. There is no
    /// whole-file buffer and therefore no args_start/args_end arithmetic.
    priv fn _parse_builtin_arguments(
        self,
        invoke: *InvocationInfo
    ) -> vec::<own::<TokenBuffer::<512>>> {
        var args: vec::<own::<TokenBuffer::<512>>>;

        if !invoke->has_args {
            return args;
        }

        // `foo!()` is zero arguments, not one empty argument.
        if invoke->arg_toks.size() == 0 {
            return args;
        }

        var current = std::create::<TokenBuffer::<512>>();

        var paren_depth:   i32 = 0;
        var square_depth: i32 = 0;
        var brace_depth:   i32 = 0;

        for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
            var tok = invoke->arg_toks[i];

            if tok.kind == TokenKind::OpLParen {
                paren_depth += 1;
                current->append(tok);
                continue;
            }

            if tok.kind == TokenKind::OpRParen {
                paren_depth -= 1;
                current->append(tok);
                continue;
            }

            if tok.kind == TokenKind::OpLSquare {
                square_depth += 1;
                current->append(tok);
                continue;
            }

            if tok.kind == TokenKind::OpRSquare {
                square_depth -= 1;
                current->append(tok);
                continue;
            }

            if tok.kind == TokenKind::OpLBrace {
                brace_depth += 1;
                current->append(tok);
                continue;
            }

            if tok.kind == TokenKind::OpRBrace {
                brace_depth -= 1;
                current->append(tok);
                continue;
            }

            if (tok.kind == TokenKind::OpComma)
            && (paren_depth == 0)
            && (square_depth == 0)
            && (brace_depth == 0) {
                args.push_back(current);
                current = std::create::<TokenBuffer::<512>>();
                continue;
            }

            current->append(tok);
        }

        args.push_back(current);
        return args;
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
    priv fn _parse_expanded_builtin_arguments(
        self,
        invoke: *InvocationInfo
    ) -> vec::<own::<TokenBuffer::<512>>> {
        var args: vec::<own::<TokenBuffer::<512>>>;

        if !invoke->has_args {
            return args;
        }
        if invoke->arg_toks.size() == 0 {
            return args;
        }

        // 1. gather the raw argument token run
        var run = std::create::<TokenBuffer::<512>>();
        for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
            run->append(invoke->arg_toks[i]);
        }

        // 2. expand invocations within it, in caller context
        if self._buf_has_invocation(run) {
            var ex = self._expand_buffer(run, &invoke->parent_chain);
            std::destroy(run);
            run = ex;
        }

        // an expansion may legitimately produce zero tokens (e.g. butlast!(x));
        // that is zero arguments, not one empty argument
        if run->size() == 0 {
            std::destroy(run);
            return args;
        }

        // 3. split the EXPANDED stream on top-level commas
        var current = std::create::<TokenBuffer::<512>>();

        var paren_depth:  i32 = 0;
        var square_depth: i32 = 0;
        var brace_depth:  i32 = 0;

        for var i: usize = 0; i < run->size(); ++i {
            var tok = *(run->get(i));

            if tok.kind == TokenKind::OpLParen  { paren_depth  += 1; }
            if tok.kind == TokenKind::OpRParen  { paren_depth  -= 1; }
            if tok.kind == TokenKind::OpLSquare { square_depth += 1; }
            if tok.kind == TokenKind::OpRSquare { square_depth -= 1; }
            if tok.kind == TokenKind::OpLBrace  { brace_depth  += 1; }
            if tok.kind == TokenKind::OpRBrace  { brace_depth  -= 1; }

            if (tok.kind == TokenKind::OpComma)
            && (paren_depth == 0)
            && (square_depth == 0)
            && (brace_depth == 0) {
                args.push_back(current);
                current = std::create::<TokenBuffer::<512>>();
                continue;
            }

            current->append(tok);
        }

        args.push_back(current);
        std::destroy(run);
        return args;
    }

    priv fn _append_builtin_argument(
        self,
        out: *(TokenBuffer::<512>),
        arg: *(TokenBuffer::<512>)
    ) {
        for var i: usize = 0; i < arg->size(); ++i {
            out->append(*(arg->get(i)));
        }
    }

    priv fn _append_builtin_comma(
        self,
        out: *(TokenBuffer::<512>),
        range: SourceRange
    ) {
        var comma = Token();
        comma.kind  = TokenKind::OpComma;
        comma.range = range;
        out->append(comma);
    }

    priv fn _builtin_token_text(self, tok: *Token) -> string {
        return TokenText::spelling(*tok, self._tcm);
    }

    //  Source-location builtins

    priv fn _builtin_file(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        var loc      = self._sm->get_full_loc(invoke->name.range.start);
        var filename = self._sm->get_filename(loc.file_id);

        var tok = Token();
        tok.kind  = TokenKind::LitString;
        tok.range = invoke->name.range;

        if self._imm != &null {
            tok.imm = self._imm->intern_string_copy(filename);
        }

        out->append(tok);
        return out;
    }

    priv fn _builtin_line(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();
        var loc = self._sm->get_full_loc(invoke->name.range.start);

        out->append(self.make_int_token(
            static_cast::<u64>(loc.line),
            invoke->name.range
        ));

        return out;
    }

    priv fn _builtin_column(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();
        var loc = self._sm->get_full_loc(invoke->name.range.start);

        out->append(self.make_int_token(
            static_cast::<u64>(loc.column),
            invoke->name.range
        ));

        return out;
    }

    priv fn _builtin_module_path(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var path = self._tracker->current_scope();

        for var i: usize = 0; i < path.segments.size(); ++i {
            if i != 0 {
                var sep = Token();
                sep.kind  = TokenKind::OpColonColon;
                sep.range = invoke->range;
                out->append(sep);
            }

            var segment_name = self._sym_name(path.segments[i].name);

            out->append(self.make_ident_token(
                segment_name,
                invoke->range
            ));
        }

        return out;
    }

    //  Argument manipulation builtins

    priv fn _builtin_count(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        if !invoke->has_args {
            self._builtin_report(
                invoke->range,
                "builtin 'count!' requires an argument list; use 'count!(...)\x27",
                DiagID::R009E
            );
            return out;
        }

        var args = self._parse_expanded_builtin_arguments(invoke);

        out->append(self.make_int_token(
            static_cast::<u64>(args.size()),
            invoke->range
        ));

        return out;
    }

    priv fn _builtin_first(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var args = self._parse_expanded_builtin_arguments(invoke);

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'first!()' requires at least one argument",
                DiagID::R009E
            );
            return out;
        }

        self._append_builtin_argument(out, args[0]);
        return out;
    }

    priv fn _builtin_last(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var args = self._parse_expanded_builtin_arguments(invoke);

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'last!()' requires at least one argument",
                DiagID::R009E
            );
            return out;
        }

        self._append_builtin_argument(out, args[args.size() - 1]);
        return out;
    }

    priv fn _builtin_rest(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var args = self._parse_expanded_builtin_arguments(invoke);

        for var k: usize = 1; k < args.size(); ++k {
            if k > 1 {
                self._append_builtin_comma(out, invoke->range);
            }

            self._append_builtin_argument(out, args[k]);
        }

        return out;
    }

    priv fn _builtin_butlast(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var args = self._parse_expanded_builtin_arguments(invoke);

        if args.size() == 0 {
            return out;
        }

        for var k: usize = 0; k + 1 < args.size(); ++k {
            if k > 0 {
                self._append_builtin_comma(out, invoke->range);
            }

            self._append_builtin_argument(out, args[k]);
        }

        return out;
    }

    /// `paste!(a, b, ...)` token paste. Joins the canonical spelling of every
    /// token in every argument and produces ONE identifier.
    ///   paste!(get_, name) -> `get_name`
    /// Non-identifier results (numbers, operators) are not yet supported: they
    /// need owned imm payloads, which StringData/IntData do not have.
    priv fn _builtin_paste(self, invoke: *InvocationInfo) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var args = self._parse_expanded_builtin_arguments(invoke);

        if args.size() == 0 {
            self._builtin_report(invoke->range,
                "builtin 'paste!()' requires at least one argument", DiagID::R009E);
            return out;
        }

        var text = string();
        for var k: usize = 0; k < args.size(); ++k {
            var a = args[k];
            for var i: usize = 0; i < a->size(); ++i {
                text += self._builtin_token_text(a->get(i));
            }
        }

        if !self._is_identifier_text(text) {
            self._builtin_report(invoke->range,
                f"builtin 'paste!()': '{text}' is not a valid identifier; paste! can only paste identifier-like tokens",
                DiagID::R009E);
            return out;
        }

        out->append(self.make_ident_token(text, invoke->range));
        return out;
    }

    priv fn _is_identifier_text(self, s: string) -> bool {
        if s.empty() { return false; }
        var c0 = s[0];
        var head_ok = ((c0 >= 'a') && (c0 <= 'z'))
                   || ((c0 >= 'A') && (c0 <= 'Z'))
                   || (c0 == '_') || (c0 == '#');
        if !head_ok { return false; }
        for var i: usize = 1; i < s.length(); ++i {
            var c = s[i];
            var ok = ((c >= 'a') && (c <= 'z'))
                  || ((c >= 'A') && (c <= 'Z'))
                  || ((c >= '0') && (c <= '9'))
                  || (c == '_') || (c == '#');
            if !ok { return false; }
        }
        return true;
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
    priv fn _builtin_stringify(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        if (!invoke->has_args) || (invoke->arg_toks.size() == 0) {
            self._builtin_report(
                invoke->range,
                "builtin 'stringify!()' requires at least one token",
                DiagID::R009E
            );
            return out;
        }

        var first = &invoke->arg_toks[0];
        var last  = &invoke->arg_toks[invoke->arg_toks.size() - 1];

        // A synthesized token carries a range pointing at whatever produced it,
        // not at its own spelling; source bytes != canonical spelling exposes
        // that. Monotonicity rejects reordered/duplicated splices.
        var source_backed = first->range.start.id <= last->range.end.id;
        if source_backed {
            for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
                var t = &invoke->arg_toks[i];
                if (i > 0)
                && (t->range.start.id < invoke->arg_toks[i - 1].range.end.id) {
                    source_backed = false;
                    break;
                }
                if self._sm->get_text(t->range) != TokenText::spelling(*t, self._tcm) {
                    source_backed = false;
                    break;
                }
            }
        }

        var text = string();
        if source_backed {
            text = self._sm->get_text(SourceRange::from_bounds(
                first->range.start,
                last->range.end
            ));
        } else {
            for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
                if i > 0 { text += " "; }
                text += self._builtin_token_text(&invoke->arg_toks[i]);
            }
        }

        var tok = Token();
        tok.kind  = TokenKind::LitString;
        tok.range = invoke->range;
        tok.imm   = self._imm->intern_string_copy(text);

        if source_backed {
            // also range-backed: lets unstringify! re-lex without owned-text
            // lexing support
            var data = self._imm->get::<Immediate::StringData>(tok.imm);
            data->body = SourceRange::from_bounds(
                first->range.start,
                last->range.end
            );
        }

        out->append(tok);
        return out;
    }

    priv fn _builtin_unstringify(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var args = self._parse_expanded_builtin_arguments(invoke);

        if (args.size() != 1) || (args[0]->size() != 1) {
            self._builtin_report(
                invoke->range,
                "builtin 'unstringify!()' requires exactly one string literal",
                DiagID::R009E
            );
            return out;
        }

        var str_tok = args[0]->get(0);

        if str_tok->kind != TokenKind::LitString {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()' argument must be a string literal",
                DiagID::R009E
            );
            return out;
        }

        if self._lexer == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': no lexer is available for range re-lexing",
                DiagID::R009E
            );
            return out;
        }

        var data = self._imm->get::<Immediate::StringData>(str_tok->imm);
        if data == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': string literal has no backing data",
                DiagID::R009E
            );
            return out;
        }

        var body = data->body;
        if body.start.id >= body.end.id {
            // no source backing: owned-only text (synthesized via stringify!
            // on synthesized tokens, or file!) cannot be re-lexed until the
            // lexer can run over table-owned bytes (load_virtual plumbing).
            if data->has_owned_text() {
                self._builtin_report(
                    str_tok->range,
                    "builtin 'unstringify!()': re-lexing a compiler-synthesized string is not supported yet",
                    DiagID::R009E
                );
            }
            return out; // empty string body, nothing to re-lex
        }

        // the string's body may live in a different file than the one this
        // preprocessor's lexer has loaded (imported macro); re-lexing would
        // read the wrong buffer's bytes.
        if self._sm->get_fid(body) != self._fid {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': string content originates in another file; cross-file re-lexing is not supported yet",
                DiagID::R009E
            );
            return out;
        }

        // SourceLocation ids are GLOBAL (file_base + offset); the lexer cursor
        // is FILE-LOCAL. Convert before slicing passing raw ids re-lexes from
        // the wrong bytes for any nonzero file base.
        var start_off = self._sm->get_offset(body.start);
        var body_len  = static_cast::<usize>(body.end.id - body.start.id);

        var lexed = self._lexer->lex_slice::<512>(
            static_cast::<u32>(start_off),
            static_cast::<u32>(start_off + body_len)
        );
        if lexed == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': could not re-lex string content",
                DiagID::R009E
            );
            return out;
        }

        finally { std::destroy(lexed); }

        for var i: usize = 0; i < lexed->size(); ++i {
            var tok = lexed->get(i);
            if tok->kind == TokenKind::TkEof { continue; }
            if tok->kind == TokenKind::TkError {
                self._builtin_report(
                    str_tok->range,
                    "builtin 'unstringify!()': lexical error in string content",
                    DiagID::R009E
                );
                continue;
            }
            out->append(*tok);
        }

        return out;
    }

    //  Macro visibility builtins

    priv fn _builtin_defined(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out   = std::create::<TokenBuffer::<512>>();
        var found: u64 = 0;
        var args  = self._parse_builtin_arguments(invoke);

        if (args.size() == 1) && (args[0]->size() == 1) {
            var name_tok = args[0]->get(0);

            if name_tok->kind == TokenKind::LitIdentifier {
                var raw_name = *name_tok;
                var name_sym = self._sym->intern(
                    self._builtin_token_text(name_tok)
                );

                var probe = InvocationInfo();
                probe.name         = *name_tok;
                probe.name_sym     = name_sym;
                probe.is_qualified = false;
                probe.has_args     = false;
                probe.range        = name_tok->range;
                probe.found        = true;

                if self._resolve(probe) != &null {
                    found = 1;
                } else {
                    // Not a Kairo macro: it may be clang's (predefined, or
                    // from an ffi header), which only Sema can ask, after
                    // the headers are built. Passed on as written for the
                    // parser's DefinedExpr (EVAL.md §4.3).
                    self._defined_raw.insert(invoke->name.range.start.raw());
                    out->append(invoke->name);
                    out->append(self._punct(TokenKind::OpExclaim, invoke->name.range));
                    out->append(self._punct(TokenKind::OpLParen, invoke->name.range));
                    out->append(raw_name);
                    out->append(self._punct(TokenKind::OpRParen, invoke->name.range));
                    return out;
                }
            }
        }

        // A condition: `true` / `false`, not 1 / 0 (EVAL.md 4.3a).
        var b = Token();
        b.kind  = (TokenKind::KwTrue) if (found == u64(1)) else (TokenKind::KwFalse);
        b.range = invoke->name.range;
        out->append(b);

        return out;
    }

    //  Deferred/sentinel builtins

    priv fn _builtin_todo(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        var tok = Token();
        tok.kind  = TokenKind::TkMacroExpand;
        tok.range = invoke->name.range;
        tok.imm   = static_cast::<u32>(MacroSentinel::Todo);

        out->append(tok);
        return out;
    }

    /// `unreachable!` SAFE: lowers to a panic if reached (Rust semantics).
    /// The UB/optimizer-assume variant is `unreachable_unchecked!`.
    priv fn _builtin_unreachable(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        var tok = Token();
        tok.kind  = TokenKind::TkMacroExpand;
        tok.range = invoke->name.range;
        tok.imm   = static_cast::<u32>(MacroSentinel::Unreachable);

        out->append(tok);
        return out;
    }

    /// `unreachable_unchecked!` UNSAFE: hard assertion to the optimizer that
    /// the path is dead. Reaching it at runtime is undefined behavior.
    priv fn _builtin_unreachable_unchecked(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        var tok = Token();
        tok.kind  = TokenKind::TkMacroExpand;
        tok.range = invoke->name.range;
        tok.imm   = static_cast::<u32>(MacroSentinel::UnreachableUnchecked);

        out->append(tok);
        return out;
    }

    /// `unique_id!` / `unique_id!(tag)`
    ///
    /// TokenSource must expose the serial of the currently active splice frame.
    /// A source location is not a valid substitute because the same source token
    /// can be duplicated and expanded more than once.
    priv fn _builtin_unique_id(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out   = std::create::<TokenBuffer::<512>>();
        var range = invoke->name.range;
        var tag: string = "";

        if invoke->has_args {
            var args = self._parse_builtin_arguments(invoke);

            var valid = (args.size() == 1)
                && (args[0]->size() == 1)
                && (args[0]->get(0)->kind == TokenKind::LitIdentifier);

            if !valid {
                self._builtin_report(
                    invoke->range,
                    "builtin 'unique_id!()' takes at most one identifier tag, e.g. unique_id!(guard)",
                    DiagID::R009E
                );
                return out;
            }

            tag = self._builtin_token_text(args[0]->get(0));
        }

        var serial = self._src->current_expansion_serial();

        // Tagged inside a macro expansion: stable for this dynamic expansion
        // instance and this tag.
        if (!tag.empty()) && (serial != 0) {
            var key = f"{serial}:{tag}";
            var it  = self._unique_tag_cache.find(key);

            if it != self._unique_tag_cache.end() {
                var tok = Token();
                tok.kind  = TokenKind::LitIdentifier;
                tok.range = range;
                tok.imm   = it->second;

                out->append(tok);
                return out;
            }

            self._unique_counter += 1;

            var tok = self.make_ident_token(
                LowerTargets::unique_ident(tag, self._fid, self._unique_counter),
                range
            );

            self._unique_tag_cache[key] = tok.imm;
            out->append(tok);
            return out;
        }

        // Untagged, or tagged at the top level: fresh on every invocation.
        self._unique_counter += 1;

        out->append(self.make_ident_token(LowerTargets::unique_ident(tag, self._fid, self._unique_counter), range));
        return out;
    }

    priv fn _builtin_include(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        var tok = Token();
        tok.kind  = TokenKind::TkMacroExpand;
        tok.range = invoke->name.range;
        tok.imm   = static_cast::<u32>(MacroSentinel::Include);

        out->append(tok);
        return out;
    }

    priv fn _builtin_embed_str(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        var tok = Token();
        tok.kind  = TokenKind::LitString;
        tok.range = invoke->name.range;
        tok.imm   = static_cast::<u32>(MacroSentinel::EmbedStr);

        out->append(tok);
        return out;
    }

    priv fn _builtin_embed(
        self,
        invoke: *InvocationInfo
    ) -> *(TokenBuffer::<512>) {
        var out = std::create::<TokenBuffer::<512>>();

        var tok = Token();
        tok.kind  = TokenKind::TkMacroExpand;
        tok.range = invoke->name.range;
        tok.imm   = static_cast::<u32>(MacroSentinel::Embed);

        out->append(tok);
        return out;

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

    priv fn _builtin_diag(
        self,
        invoke: *InvocationInfo,
        level: DiagSeverity
    ) -> *(TokenBuffer::<512>) {
        var out  = std::create::<TokenBuffer::<512>>();
        var args = self._parse_builtin_arguments(invoke);

        if args.size() == 0 {
            return out;
        }

        var message = string();

        for var i: usize = 0; i < args[0]->size(); ++i {
            message += self._builtin_token_text(args[0]->get(i));
        }

        var code = (DiagID::R010E)
            if (level == DiagSeverity::Error)
            else (DiagID::R010W)
            if (level == DiagSeverity::Warning)
            else (DiagID::R010N);

        self._report_expand_err(
            code,
            invoke,
            message,
            "diagnostic emitted from this macro body"
        );

        return out;
    }

    //  Resolution

    priv fn _resolve(self, inv: InvocationInfo) -> *MacroEntry {
        if inv.is_qualified {
            // The rule Sema uses for a qualified name (RESOLUTION.md §2.5 N,
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
            var cur  = self._tracker->current_scope();
            var base = self._tracker->file_base().segments.size();
            for var k: usize = cur.segments.size(); (k > 0) && (k >= base); --k {
                var rel = ModulePath();
                for var j: usize = 0; j < k; ++j { rel.segments.push_back(cur.segments[j]); }
                for seg in inv.qualified.segments { rel.segments.push_back(seg); }
                var r = self._macros->find_same_fid(rel, inv.name_sym, self._fid);
                if r != &null { return r; }
            }
            // exact scope
            var e = self._macros->find(inv.qualified, inv.name_sym, self._fid);
            if e != &null { return e; }
            // alias head: module_aliases[first] + rest
            if inv.qualified.segments.size() > 0 {
                var head = inv.qualified.segments[0].name;
                if self._imports->module_aliases.contains(head) {
                    var scope = self._imports->module_aliases[head];
                    for var k: usize = 1; k < inv.qualified.segments.size(); ++k {
                        scope.segments.push_back(inv.qualified.segments[k]);
                    }
                    return self._macros->find(scope, inv.name_sym, self._fid);
                }
            }
            return &null; // qualified NEVER falls back to unqualified
        }

        // unqualified: current scope chain (same-fid, order irrelevant under
        // the two-phase-free single walk since defs before this point are the
        // only ones registered) -> named imports -> wildcards -> global
        var scope = self._tracker->current_scope();
        var e = self._macros->find_same_fid(scope, inv.name_sym, self._fid);
        if e != &null { return e; }

        if self._imports->named.contains(inv.name_sym) {
            return self._imports->named[inv.name_sym];
        }

        for wscope in self._imports->wildcards {
            var w = self._macros->find(wscope, inv.name_sym, self._fid);
            if w != &null { return w; }
        }

        // the prelude's own `import builtin::*`, last of the imports
        if self._has_prelude {
            var pm = self._macros->find(self._prelude, inv.name_sym, self._fid);
            if pm != &null { return pm; }
        }

        // global scope (empty ModulePath)
        return self._macros->find(ModulePath(), inv.name_sym, self._fid);
    }

    priv fn _sym_name(self, id: SymbolID) -> string {
        var p = self._sym->resolve(id);
        return ("<unknown>") if (p == &null) else (*p);
    }

    priv fn _recover_to_terminator(self) {
        while !self._src->at_eof() {
            var k = self._src->peek(0).kind;
            if (k == TokenKind::OpSemicolon) || (k == TokenKind::TkNewLine) {
                self._src->next();
                return;
            }
            self._src->next();
        }
    }

    //  Finalize

    priv fn _finalize(self) {
        // hand the produced buffer to the TCM as this fid's tokens.
        self._tcm->close_stream(self._fid, self._out);
        self._out = &null; // ownership transferred to the slot
        // splice buffers stay owned here until op delete their tokens were
        // COPIED into _out via wrap/append, so freeing them post-handoff is safe.

        // One clang parse per distinct ordered header list; another file
        // importing the same headers in the same order shares the set. The
        // quoted-include directory is THIS file's, as for a .cpp beside it.
        if (self._headers != &null) && (self._ffi_headers.size() > 0) {
            var hs = self._headers->request(self._ffi_headers, self._ffi_c, self._ffi_locs, self._sm->get_file_dir(self._fid).full_path());
            self._tu->header_set = reinterpret_cast::<*void>(hs);
        }
    }
}

/// A file on an import cycle, lexed and its macros collected ahead of the
/// waves (PreProcessor::_prelex_cycles): the open stream and every token it
/// produced, for _walk_one to replay.
struct PrelexedFile {
    var lexer:  *Lexer;
    var tokens: *vec::<Token>;
}

//  Batch driver replaces the old PreProcessor::preprocess phases

class PreProcessor {
    priv var _sym:      *PreprocessorSymbolTable;
    priv var _macros:   *MacroTable;
    priv var _sm:       *SourceManager;
    priv var _tcm:      *TokenCacheManager;
    priv var _diag:     *DiagEngine;
    priv var _pool:     *ThreadPool;
    priv var _resolver: *ImportResolver;
    priv var _gscope:   *GlobalDisambigTable;  ///< owns per-fid ASTContext/TU now
    priv var _inv:      *CompilerInvocation;
    priv var _headers:  *HeaderSetCache = &null;  ///< borrowed from CompilerInstance; handed to every walker.
    priv var _opts:      PreprocessorOptions;
    priv var _walked:    set::<u32>;
    /// Every fid a preprocess() of this batch scanned, with its edges and
    /// module path (DepScanner::set_known). Driver thread only: written after
    /// each walk, read by the next scan.
    priv var _scanned:   DepGraph;
    priv var _walked_mu: std::SharedMutex;     // wave tasks are parallel
    /// The builtin module's scope and fid, and every fid in its own import
    /// closure (the builtin files): the macro prelude. Set by preprocess()
    /// when the real builtin root is folded in; read by _walk_one.
    priv var _prelude_scope: ModulePath;
    priv var _prelude_fid:   u32 = 0;
    priv var _prelude_files: set::<u32>;
    /// Files on an import cycle, lexed ahead of the waves. Written before
    /// the waves start and only read while they run (_walk_one).
    priv var _prelexed:      map::<u32, PrelexedFile>;
    priv var _define_storage: vec::<libcxx::string>; ///< -D value bytes; load_virtual
                                                       ///  needs them stable for the
                                                       ///  whole compile. reserved
                                                       ///  up front so it never
                                                       ///  reallocates after that.

    fn PreProcessor(self, sm: *SourceManager,       tcm:  *TokenCacheManager,
                    resolver: *ImportResolver,      pool: *ThreadPool, diag: *DiagEngine,
                    gscope:   *GlobalDisambigTable, inv:  *CompilerInvocation,
                    opts:      PreprocessorOptions = PreprocessorOptions(),
                    headers:  *HeaderSetCache = &null) {
        self._headers  = headers;
        self._sym      = std::create::<PreprocessorSymbolTable>();
        self._macros   = std::create::<MacroTable>();
        self._sm       = sm;
        self._tcm      = tcm;
        self._resolver = resolver;
        self._pool     = pool;
        self._diag     = diag;
        self._gscope   = gscope;
        self._opts     = opts;
        self._inv      = inv;
        self._register_defines();
    }

    /// \brief pre-registers `-D NAME[=VALUE]` as parameterless, pub, global-scope
    ///        macros before any file is walked. Runs once, from the constructor
    ///        not from preprocess(), since preprocess() runs once per input file
    ///        and a second registration attempt would just be silently dropped by
    ///        MacroTable::register's duplicate check while still reallocating
    ///        _define_storage (dangling every buffer load_virtual already handed
    ///        out for the first pass).
    ///
    ///        Each value gets its own virtual file (SourceManager::load_virtual)
    ///        so it goes through the SAME lex path a real macro body would,
    ///        rather than hand-building tokens; that's also what gives the
    ///        macro's tokens a real fid/ImmediateTable pair for later diagnostics.
    ///        Bare `-D FOO` (no `=value`) expands to `1`, matching gcc/clang.
    priv fn _register_defines(self) {
        if self._opts.defines.size() == 0 { return; }
        self._define_storage.reserve(self._opts.defines.size());

        for var i: usize = 0; i < self._opts.defines.size(); ++i {
            var raw = self._opts.defines[i];

            var name:  string;
            var value: string;
            var eq = raw.view().find('=');
            if eq != string::npos {
                name  = raw.subslice(0, eq);
                value = raw.subslice(eq + 1, raw.size());
            } else {
                name  = raw;
                value = "1";
            }
            if name.empty() {
                // "=VALUE" and "" used to be skipped silently, so a typo'd -D
                // looked accepted and the macro just never existed.
                self._diag->report(DiagID::U001E,
                    f"invalid -D argument '{raw}\x27: expected NAME or NAME=VALUE with a non-empty NAME"
                ).emit();
                continue;
            }

            self._define_storage.push_back(value.std_string());
            var stored = &(self._define_storage[self._define_storage.size() - 1]);

            var fid = self._sm->load_virtual(
                Path(f"<command-line>:{name}"),
                reinterpret_cast::<std::ConstPtr::<u8>>(stored->data()),
                value.size()
            );

            var lexer = self._tcm->open_stream(fid);
            if lexer == &null { continue; }
            var imm = lexer->get_imm_tbl();

            var tcm_tokens    = std::create::<TokenBuffer::<512>>();
            var macro_storage = std::create::<TokenBuffer::<512>>();
            var src = TokenSource(lexer);
            while !src.at_eof() {
                var t = src.next();
                if t.kind == TokenKind::TkEof { break; }
                tcm_tokens->append(t);
                macro_storage->append(t);
            }
            self._tcm->close_stream(fid, tcm_tokens);

            var ctx = self._gscope->get_or_create_context(
                fid, self._sm, self._tcm, self._diag, self._resolver, self._inv, ModulePath());
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null {
                tu = ctx->alloc_init_pp_cleanup::<TranslationUnit>(ctx, fid, ctx->hoisted, self._gscope);
                ctx->tu = reinterpret_cast::<*void>(tu);
            }

            var name_tok = Token();
            name_tok.kind  = TokenKind::LitIdentifier;
            name_tok.range = SourceRange::invalid();
            name_tok.imm   = imm->intern_ident_copy(name);

            var decl = MacroDecl::create(ctx, SourceRange::invalid(), name_tok);
            decl->accepts_params = false;

            var entry = std::create::<MacroEntry>();
            entry->decl       = decl;
            entry->storage    = macro_storage;
            entry->body_len   = u32(macro_storage->size());
            entry->name_sym   = self._sym->intern(name);
            entry->scope      = ModulePath(); // global: visible from every TU
            entry->source_fid = fid;
            entry->visibility = 3;            // pub: MacroTable::find's cross-file check needs it

            self._macros->register(entry);
        }
    }

    fn op delete (self) {
        std::destroy(self._macros);
        std::destroy(self._sym);
    }

    fn get_macro_table(self)  -> *MacroTable { return self._macros; }
    fn get_symbol_table(self) -> *PreprocessorSymbolTable { return self._sym; }

    /// \brief drops \p fid from the walked set so a later preprocess() will
    ///        walk it again.
    ///
    /// \details _walked is the DAG dedup: within one batch a fid shared by two
    ///          inputs is preprocessed once. That is correct for a batch, where
    ///          nothing is ever released, and WRONG the moment a fid's
    ///          artifacts are torn down   the walk is what creates the
    ///          ASTContext and the TranslationUnit, so a released-then-reparsed
    ///          fid that is still marked walked comes back with no context at
    ///          all and only the diagnostics its importers happened to raise.
    ///
    ///          This has been load-bearing in reverse: because release(Loading)
    ///          also dropped the SourceManager entry, every reparse minted a
    ///          BRAND NEW fid, which never matched _walked and so always
    ///          re-walked. The fid leak was what made reparse appear to work.
    ///          Keeping a fid stable across a release is only correct once the
    ///          walked set is invalidated with it.
    ///
    /// \note ALSO drops this fid's macros. MacroEntry::decl is an obs<MacroDecl>
    ///       into the fid's ASTContext, so entries must not outlive it. Leaving
    ///       them is worse than a dangling read: register()'s duplicate check
    ///       keeps the FIRST entry for a (scope, name) and destroys the later
    ///       one, so the next walk's freshly-built macro is discarded in favour
    ///       of the stale one and the table converges on all-dangling decls.
    ///
    /// \return false if \p fid was neither walked nor had macros.
    fn forget(self, fid: u32) -> bool {
        var dropped = self._macros->forget_fid(fid);

        var wlock = std::UniqueLock(self._walked_mu);
        if !self._walked.contains(fid) { return dropped > 0; }
        self._walked.erase(fid);
        return true;
    }

    /// Live macro entries across all fids. See MacroTable::size.
    fn macro_count(self) -> usize { return self._macros->size(); }

    /// \brief clears the whole walked set. For a full batch reset.
    fn forget_all(self) {
        var wlock = std::UniqueLock(self._walked_mu);
        self._walked.clear();
    }

    /// \brief every fid \p entry_fid's own imports reach, itself included:
    ///        the scan preprocess() starts with, without the prelude or
    ///        --force-include, and without walking anything. For ordering
    ///        the batch's inputs before the first walk (CompilerInstance).
    fn reach(self, entry_fid: u32) -> set::<u32> {
        self._resolver->wait_for_index();
        var scanner = DepScanner(self._sm, self._tcm, self._resolver, self._sym, self._opts.max_import_depth);
        var graph   = scanner.build_graph(entry_fid, ModulePath());
        return graph.all_fids;
    }

    /// \brief true if \p fid has already been walked in this batch.
    fn has_walked(self, fid: u32) -> bool {
        var rlock = std::SharedLock(self._walked_mu);
        return self._walked.contains(fid);
    }

    /// \brief preprocesses exactly one fid: lex it, walk it, build its
    ///        ASTContext and TranslationUnit.
    ///
    /// \details The unit of work the wave executor dispatches, factored out so
    ///          a single file can be re-walked without re-walking the graph
    ///          around it (see preprocess_one).
    ///
    /// \return false if the fid was already walked, too large, or would not lex.
    priv fn _walk_one(self, fid: u32, mod_path: ModulePath) -> bool {
        {
            // claim-on-entry is safe ONLY because execute() runs input files
            // sequentially. if FrontendActions ever parallelize, this needs a
            // per-fid completion latch, not a claimed-set.
            var wlock = std::UniqueLock(self._walked_mu);
            if self._walked.contains(fid) { return false; }
            self._walked.insert(fid);
        }

        if self._opts.max_file_size_mb > 0 {
            // compare exact bytes, not truncated MB: a 1.9MB file under a
            // 1MB cap would otherwise round down to size_mb=1, and 1 > 1
            // is false so the cap silently wouldn't fire until 2x over.
            var size_bytes = self._sm->get_file_size(fid);
            var max_bytes  = usize(self._opts.max_file_size_mb) * 1024 * 1024;
            if size_bytes > max_bytes {
                var size_mb = size_bytes / (1024 * 1024); // display only
                self._diag->report(DiagID::S066E,
                    f"'{self._sm->get_filename(fid)}' is {size_mb}MB, over the {self._opts.max_file_size_mb}MB cap; raise it with --cmax-file-size-mb=N"
                ).emit();
                return false;
            }
        }

        // Slot setup plus contention on TokenCacheManager::_lex_mu, which
        // every file in the wave serializes through. If this is anything but
        // noise, the wave is queueing on that one mutex and widening the pool
        // will not help. NOT lex time   see Lexer::next, which bills "Lex".
        var lexer: *Lexer = &null;
        var replay: *vec::<Token> = &null;
        if self._prelexed.contains(fid) {
            // Opened, lexed and its macros registered by _prelex_cycles.
            var pf = self._prelexed[fid];
            lexer  = pf.lexer;
            replay = pf.tokens;
        } else {
            var _tl = TimeRegion("Open");
            lexer = self._tcm->open_stream(fid);
        }

        if lexer == &null {
            Logger::error(Logger::Stage::Preprocessor, f"PP: stream open failed fid={fid}");
            return false;
        }

        var ctx = self._gscope->get_or_create_context(
            fid, self._sm, self._tcm, self._diag, self._resolver, self._inv, mod_path);

        // Re-intern the module path's leaf into this file's imm space. The
        // path is spelled in the PP symbol table; the parser's synthesized
        // ModuleDecl name token needs an imm, and the two are different name
        // domains (see ASTContext::module_leaf_imm).
        if (ctx->module_leaf_imm == u32(-1)) && (ctx->module_base.segments.size() > 0) {
            var segs = &(ctx->module_base.segments);
            var leaf = self._sym->resolve((*segs)[segs->size() - 1].name);
            var imms = ctx->get_imm_table();
            if (leaf != &null) && (imms != &null) {
                ctx->module_leaf_imm = imms->intern_ident_copy(*leaf);
            }
        }

        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if tu == &null {
            tu = ctx->alloc_init_pp_cleanup::<TranslationUnit>(ctx, fid, ctx->hoisted, self._gscope);
            ctx->tu = reinterpret_cast::<*void>(tu);
        }

        var walker = std::create::<PPWalker>(
            fid, lexer, ctx, tu, self._macros, self._resolver,
            self._sym, self._sm, self._tcm, self._diag, self._opts, mod_path, self._headers);
        finally { std::destroy(walker); }
        if (self._prelude_fid != 0) && (!self._prelude_files.contains(fid)) {
            walker->set_prelude_scope(self._prelude_scope);
        }
        if replay != &null {
            walker->set_replay(replay);
            walker->assume_macros_known();
        }

        walker->run();
        return true;
    }

    /// Every file on an import cycle, opened, lexed in full and its macro
    /// definitions registered BEFORE any file is walked (PPWalker::
    /// collect_macros). The waves walk an importee before its importer, and
    /// on a cycle one import always points the other way: without this, the
    /// file walked first expanded none of the macros of a file it imports.
    /// With it every file on the cycle sees every macro the cycle defines,
    /// in either direction and whatever the walk order. Files off every
    /// cycle are untouched -- lexed once, walked once, as before.
    priv fn _prelex_cycles(self, graph: *DepGraph) {
        for var c: usize = 0; c < graph->cycles.size(); ++c {
            var cyc = &(graph->cycles[c]);
            for var i: usize = 0; i < cyc->size(); ++i {
                var fid = (*cyc)[i];
                if self._prelexed.contains(fid) { continue; }
                {
                    var rlock = std::SharedLock(self._walked_mu);
                    if self._walked.contains(fid) { continue; }
                }
                // Over the size cap: the walk reports it and stops there.
                if (self._opts.max_file_size_mb > 0)
                && (self._sm->get_file_size(fid) > usize(self._opts.max_file_size_mb) * 1024 * 1024) { continue; }
                var lexer = self._tcm->open_stream(fid);
                if lexer == &null { continue; }
                var toks = std::create::<vec::<Token>>();
                var t = Token();
                while lexer->next(&t) { toks->push_back(t); }
                var mp  = graph->mod_paths[fid];
                var ctx = self._gscope->get_or_create_context(
                    fid, self._sm, self._tcm, self._diag, self._resolver, self._inv, mp);
                var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
                if tu == &null {
                    tu = ctx->alloc_init_pp_cleanup::<TranslationUnit>(ctx, fid, ctx->hoisted, self._gscope);
                    ctx->tu = reinterpret_cast::<*void>(tu);
                }
                var walker = std::create::<PPWalker>(
                    fid, lexer, ctx, tu, self._macros, self._resolver,
                    self._sym, self._sm, self._tcm, self._diag, self._opts, mp, self._headers);
                walker->set_replay(toks);
                walker->collect_macros();
                std::destroy(walker);
                var pf = PrelexedFile{};
                pf.lexer  = lexer;
                pf.tokens = toks;
                self._prelexed[fid] = pf;
            }
        }
    }

    /// \brief re-walks ONE fid, leaving the rest of the import graph alone.
    ///
    /// \details The single-file reparse path. No DepScanner, no wave executor,
    ///          no graph: just this file's own lex + walk, against the macro
    ///          and symbol tables the rest of the graph already populated.
    ///
    ///          DELIBERATELY PARTIAL. The imports of \p fid are NOT re-resolved
    ///          or re-walked. If the edit added an import, the target is not
    ///          pulled in and names from it will not resolve   report it rather
    ///          than assume a full preprocess happened. Callers that need the
    ///          graph re-examined must run preprocess() instead.
    ///
    /// \pre \p fid must have been forgotten first (CompilerInstance::invalidate
    ///      does this), otherwise the walked-set check refuses and this is a
    ///      no-op returning false.
    fn preprocess_one(self, fid: u32, mod_path: ModulePath) -> bool {
        self._resolver->wait_for_index();
        return self._walk_one(fid, mod_path);
    }

    /// The `import` in \p from that names \p to, as the walk recorded it,
    /// or an invalid range when there is none.
    priv fn _import_range(self, from: u32, to: u32) -> SourceRange {
        var ctx = self._gscope->get_context(from);
        if (ctx == &null) || (ctx->tu == &null) { return SourceRange::invalid(); }
        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        for var i: usize = 0; i < tu->import_edges.size(); ++i {
            var e = tu->import_edges.get(i);
            if (e == &null) || (e->target_fid != to) || (e->decl == &null) { continue; }
            return e->decl->range;
        }
        return SourceRange::invalid();
    }

    /// An import cycle (modules.mdx, Circular Dependencies). \p cyc is its
    /// files in import order, the last importing the first (DepGraph::
    /// cycles). A cycle compiles, but is warned about (R001W): no module on
    /// it can be read, built or tested without the others. -fno-import-
    /// cycles makes it an error (R001E), which stops the build after parse.
    /// The diagnostic is at the import that closes it -- the one the scan
    /// met with its target still open -- and each edge of the cycle gets a
    /// note at its own import, so the whole loop reads off it. No fix-it
    /// for a real cycle: which import to drop, or what to move into a third
    /// module, is a design call. A self-import is the exception: it only
    /// closes the cycle, and the fix-it removes it.
    priv fn _report_cycle(self, cyc: *vec::<u32>) {
        var n = cyc->size();
        if n == 0 { return; }
        var path = "";
        for var i: usize = 0; i < n; ++i {
            path += Path::filename_of(self._sm->get_filename((*cyc)[i]));
            path += " -> ";
        }
        path += Path::filename_of(self._sm->get_filename((*cyc)[0]));
        var last  = (*cyc)[n - 1];
        var first = (*cyc)[0];
        var at = self._import_range(last, first);
        var forbid = self._opts.import_cycles == 0;
        var head = f"import cycle: {path}";
        if n == 1 { head = f"'{Path::filename_of(self._sm->get_filename(first))}' imports itself"; }
        var msg = f"{head}; import cycles are disabled (-fno-import-cycles)";
        if !forbid { msg = f"{head}; a cycle hinders maintainability: no module on it can be read, built or tested without the others"; }
        var b = self._diag->report((DiagID::R001E) if (forbid) else (DiagID::R001W), at.start, msg);
        b.first(at, "this import closes the cycle");
        if n > 1 {
            for var i: usize = 0; i < n; ++i {
                var a = (*cyc)[i];
                var t = (*cyc)[(i + 1) % n];
                var r = self._import_range(a, t);
                b.note(r.start, f"'{Path::filename_of(self._sm->get_filename(a))}' imports '{Path::filename_of(self._sm->get_filename(t))}' here");
            }
        }
        if n == 1 {
            // A file sees its own declarations without importing itself, so
            // the import does nothing but close the cycle: drop it.
            b.remove(at, "remove the import; a file sees its own declarations without one");
        } else {
            b.note("move the declarations the modules share into a third module that each of them imports");
        }
        b.emit();
    }

    fn preprocess(self, entry_fid: u32, entry_path: ModulePath) -> PPResult {
        var out = PPResult();

        // Separate region: the resolver index is built on the pool at
        // initialize() to overlap with this. Time spent here is time the
        // overlap failed to hide.
        {
            var _tw = TimeRegion("ResolverIndexWait");
            self._resolver->wait_for_index();
        }

        // Timed inside DepScanner::build_graph, not wrapped here: hoisting the
        // graph out of a timing block would cost a default-construct plus a
        // copy-assign of five maps on every TU, and pessimizing the compiler
        // to measure the compiler is a bad trade.
        var scanner = DepScanner(self._sm, self._tcm, self._resolver, self._sym, self._opts.max_import_depth);
        // What an earlier input of the batch scanned (every input reaches
        // builtin) is followed through the edges recorded then, not rescanned.
        scanner.set_known(&(self._scanned));
        var graph   = scanner.build_graph(entry_fid, entry_path);

        if !graph.depth_exceeded_path.empty() {
            self._diag->report(DiagID::R019E,
                f"import depth limit ({self._opts.max_import_depth}) exceeded at '{graph.depth_exceeded_path}'; raise it with --cmax-import-depth=N"
            ).emit();
        }

        // The PRELUDE: every TU behaves as though it wrote `import builtin::*`
        // before its first token. Folded HERE, beside --force-include, for the
        // same reason: the graph has to reach it before the walk, or sema asks
        // for a lang item that was never parsed.
        //
        // Resolved as a MODULE, not a path -- the resolver answers with the
        // canonical `builtin` segments, which is what the lang-item fill keys
        // on. A custom --prelude REPLACES it (a plain file, folded like a
        // force-include); --no-prelude and --freestanding turn it off; and a
        // builtin file reached as the entry is its own prelude, so the
        // self-edge is skipped.
        if !self._opts.no_prelude {
            var p_fid: u32 = 0;
            if self._opts.prelude_path.size() > 0 {
                p_fid = self._sm->load_file(Path(self._opts.prelude_path));
                if (p_fid != u32(-1)) && (p_fid != 0) && (p_fid != entry_fid) {
                    scanner.add_root_dependency(p_fid, &graph);
                }
            } else {
                var segs = vec::<string>();
                segs.push_back(builtin_root_name());
                p_fid = scanner.add_module_dependency(segs, &graph);
                // Only the real builtin module is reported: a custom --prelude
                // is a file, not the lang-item root, and sema must not read
                // lang items out of it.
                if (p_fid != 0) && (p_fid != u32(-1)) {
                    out.builtin_fid = p_fid;
                    self._prelude_fid   = p_fid;
                    self._prelude_scope = graph.mod_paths[p_fid];
                }
            }
            if (p_fid != 0) && (p_fid != u32(-1)) && (p_fid != entry_fid) {
                graph.add_edge(entry_fid, p_fid);
            }
        }

        // --force-include: fold each file (and its own transitive imports) into
        // the graph at global scope, as if this TU implicitly wrote
        // `import <file>::*;` before its own first token. load_file() already
        // reports U001F (fatal) on a missing/unreadable path, so a u32(-1)
        // return needs no diagnostic of its own here just skip it.
        for path_str: string in self._opts.force_includes {
            var fi_fid = self._sm->load_file(Path(path_str));
            if (fi_fid == u32(-1)) || (fi_fid == entry_fid) { continue; } // self-include: a no-op, not a self-edge

            scanner.add_root_dependency(fi_fid, &graph);
            graph.add_edge(entry_fid, fi_fid);
        }

        // The macro prelude needs the builtin root WALKED before any file
        // that may expand one of its macros, and the graph above only has
        // the entry's edge to it. Every other file outside the builtin
        // root's own closure gets one too; a builtin file never does, or a
        // builtin import of it would close a cycle.
        if (self._prelude_fid != 0) && graph.all_fids.contains(self._prelude_fid) {
            self._prelude_files.clear();
            var work = vec::<u32>();
            work.push_back(self._prelude_fid);
            while !work.empty() {
                var f = work.back();
                work.pop_back();
                if self._prelude_files.contains(f) { continue; }
                self._prelude_files.insert(f);
                if graph.deps.contains(f) {
                    for d in graph.deps[f] { work.push_back(d); }
                }
            }
            for fid in graph.all_fids {
                if self._prelude_files.contains(fid) { continue; }
                graph.add_edge(fid, self._prelude_fid);
            }
        }

        self._prelex_cycles(&graph);

        var executor = WaveExecutor(self._pool);
        var dispatched: usize = 0;
        {
            // One region, not a Wave/walk pair. The driver's time here is the
            // wave's LATENCY (dispatch + dependency stalls); each worker bills
            // its file's walk as WORK to the same record. par is then exactly
            // the parallelism the import DAG allowed   which is the only thing
            // anyone wants to know about a wave scheduler.
            var _te  = TimeRegion("Walk");
            var wrec = _te.record();

            dispatched = executor.run(&graph, fn(fid: u32, mod_path: ModulePath) {
                var _tw = TimeWorker(wrec);
                _tw.units(u64(self._sm->get_file_size(fid)), r"B");
                self._walk_one(fid, mod_path);
            });
        }

        for var c: usize = 0; c < graph.cycles.size(); ++c { self._report_cycle(&(graph.cycles[c])); }
        // The replayed tokens were copied into each walk's output; the lexers
        // went with their streams (close_stream).
        for var it = self._prelexed.begin(); it != self._prelexed.end(); ++it { std::destroy(it->second.tokens); }
        self._prelexed.clear();

        // A file the waves never reached was never walked, so it is never
        // parsed or compiled. The scan drops (and reports) every edge that
        // would close a cycle, so this is a scanner bug if it fires -- but it
        // is reported, not ignored: dropping a file and exiting 0 is how an
        // import cycle used to lose both of its files without a word.
        if dispatched < graph.all_fids.size() {
            var lost = "";
            for fid in graph.all_fids {
                if graph.in_degree[fid] == 0 { continue; }
                lost = self._sm->get_filename(fid);
                break;
            }
            self._diag->report(DiagID::I003E,
                f"{graph.all_fids.size() - dispatched} file(s) of the import graph were never preprocessed (first: '{lost}'); the graph has a cycle the dependency scan did not break"
            ).emit();
        }

        // Recorded for the next input's scan. A fid already known keeps its
        // first entry: this graph followed it from there.
        for fid in graph.all_fids {
            if self._scanned.all_fids.contains(fid) { continue; }
            self._scanned.add_node(fid, graph.mod_paths[fid]);
            self._scanned.deps[fid] = graph.deps[fid];
        }

        out.ok = !self._diag->has_fatal();
        out.fids.reserve(graph.all_fids.size());
        for fid in graph.all_fids { out.fids.push_back(fid); }
        libcxx::sort(out.fids.begin(), out.fids.end());
        return out;
    }
}