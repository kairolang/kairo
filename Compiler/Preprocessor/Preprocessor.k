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
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Diagnostic::BufferedDiagSink::*;

struct PPResult {
    var ok:   bool = false;
    var fids: vec::<u32>;   ///< entry's transitive graph, sorted ascending.
}

// =========================================================================
//  Per-fid walker. One instance per fid; the batch driver owns the shared
//  MacroTable + resolver + contexts and runs walkers in wave order.
// =========================================================================

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
    priv var _unique_counter:    u32 = 0;

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
        module_base: ModulePath
    ) {
        self._fid     = fid;
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
        self._src     = std::create::<TokenSource>(lexer);
        self._imports = std::create::<FileImportIndex>(sym, sm, tcm, resolver, macros, diag, fid);
        self._tracker = std::create::<ScopeTracker>(sym, sm, self._imm, tcm, module_base);
        self._sink    = self._out;
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
        self._diag->report(DiagCode(code), r.start, msg).first(r).emit();
    }

    // ======================================================================
    //  The walk
    // ======================================================================

    fn run(self) -> bool {
        while !self._src->at_eof() {
            var t = self._src->peek(0);
            var k = t.kind;

            if k == TokenKind::TkEof { break; }

            if k == TokenKind::KwFfi        { self._handle_ffi();       continue; }
            if k == TokenKind::KwImport     { self._handle_import(1);   continue; } // 1 = priv default
            if k == TokenKind::KwMacro      { self._handle_macro_def(3); continue; } // 3 = pub default

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
                    self._handle_macro_def(vis);
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
            var inv = self._detect_invocation();
            if inv.found {
                self._expand(inv);
                continue;
            }

            self._emit(self._src->next());
        }

        self._finalize();
        return !self._diag->has_fatal();
    }

    // ======================================================================
    //  Emission single choke point + disallow backstop
    // ======================================================================

    priv fn _emit(self, t: Token) {
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
        self._sink->append(t);
    }

    // ======================================================================
    //  Scope tracking
    // ======================================================================
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

    // ======================================================================
    //  FFI
    // ======================================================================

    priv fn _handle_ffi(self) {
        // Decide form by lookahead BEFORE emitting anything.
        //   peek0 = ffi, peek1 = "lang", peek2 = import | { | decl-lead
        var p2 = self._src->peek(2).kind;

        if p2 == TokenKind::KwImport {
            // ffi "lang" import "hdr" (as name)? ;  -> consume + drop entirely
            self._src->next(); // ffi
            self._src->next(); // lang
            self._src->next(); // import
            while !self._src->at_eof() {
                var t = self._src->next();
                if t.kind == TokenKind::OpSemicolon { break; }
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

    // ======================================================================
    //  Imports
    // ======================================================================

    priv fn _handle_import(self, default_vis: u8) {
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
        // back the source-module fid; a non-zero fid becomes a TU import edge in
        // declaration order (the one writer of import_edges). ffi imports never
        // reach here, so no edge is ever synthesized for them.
        var target_fid = self._imports->record(id);
        if target_fid != 0 {
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

    priv fn _u8_to_vis(self, vis: u8) -> VisibilityKind {
        if vis == 1 { return VisibilityKind::Private;   }
        if vis == 2 { return VisibilityKind::Protected; }
        if vis == 3 { return VisibilityKind::Public;    }
        return VisibilityKind::None;
    }

    // ======================================================================
    //  Macro definitions
    // ======================================================================

    priv fn _handle_macro_def(self, vis: u8) {
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

    // ======================================================================
    //  Invocation detection + expansion
    // ======================================================================
    //  _detect_invocation: PORT of MacroExpander::detect_invocation, retargeted
    //  to peeks on _src. Pattern unchanged: ident (:: ident)* ! ( ... )?.
    //  Critical difference: it must NOT consume until `found` is certain, then
    //  consume exactly the invocation. Because args need to be captured into a
    //  scratch buffer for pre-expansion, detection also copies the raw arg
    //  tokens (between balanced parens) into inv.arg_toks.

    struct InvocationInfo {
        var qualified:    ModulePath;
        var chain:        vec::<SymbolID>; ///< frame names live at detection
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
        var result = InvocationInfo();

        result.origin_site = self._src->bottom_invoke_loc();
        self._src->snapshot_chain(&result.chain);

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
            var nm = self._sym_name(inv.name_sym);
            if self._opts.macro_debug_filter.empty() || (nm == self._opts.macro_debug_filter) {
                Logger::info(Logger::Stage::Preprocessor,
                    f"[macro-debug] expand '{nm}!' depth={self._src->depth()} count={self._expansion_count}");
            }
        }

        var b = self._try_builtin(&inv);
        if b != &null {
            self._push_splice(b, inv.name_sym, inv.range);
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
            self._report_expand_err(DiagID::R008E, &inv,
                f"macro expansion depth limit ({self._opts.max_depth}) exceeded",
                "expanded from here",
                f"limit can be increased with --cmax-macro-depth=N");
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
        self._push_splice(bound, entry->name_sym, inv.range);
    }

    priv fn _push_splice(self, buf: *(TokenBuffer::<512>), name: SymbolID, loc: SourceRange) {
        self._splices.push_back(buf);       // own it for the run's lifetime
        self._src->push_splice(buf, name, loc);
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

    priv fn _expand_buffer(self, src_buf: *(TokenBuffer::<512>)) -> *(TokenBuffer::<512>) {
        var out   = std::create::<TokenBuffer::<512>>();
        var saved = self._sink;
        self._sink = out;

        var d0 = self._src->depth();
        self._src->push_splice(src_buf, 0, SourceRange::invalid());

        while self._src->depth() > d0 {
            var t = self._src->peek(0);
            if t.kind == TokenKind::TkEof { break; }
            var inv = self._detect_invocation();
            if inv.found { self._expand(inv); continue; }
            self._emit(self._src->next());
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
                var ex = self._expand_buffer(args[k]);
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

    priv fn make_ident_token(self, name: string, range: SourceRange) -> Token {
        var tok = Token();
        tok.kind  = TokenKind::LitIdentifier;
        tok.range = range;
        if self._imm != &null {
            tok.imm = self._imm->intern_ident_copy(name);
        }
        return tok;
    }

    // ======================================================================
    //  Builtins
    // ======================================================================

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
        if name == "file"        { return self._builtin_file(invoke); }
        if name == "line"        { return self._builtin_line(invoke); }
        if name == "column"      { return self._builtin_column(invoke); }
        if name == "module_path" { return self._builtin_module_path(invoke); }

        // argument manipulation
        if name == "count"   { return self._builtin_count(invoke); }
        if name == "first"   { return self._builtin_first(invoke); }
        if name == "last"    { return self._builtin_last(invoke); }
        if name == "rest"    { return self._builtin_rest(invoke); }
        if name == "butlast" { return self._builtin_butlast(invoke); }

        // token manipulation
        if name == "paste"       { return self._builtin_paste(invoke); }
        if name == "stringify"   { return self._builtin_stringify(invoke); }
        if name == "unstringify" { return self._builtin_unstringify(invoke); }

        // macro visibility
        if name == "defined" { return self._builtin_defined(invoke); }

        // deferred code generation
        if name == "todo"        { return self._builtin_todo(invoke); }
        if name == "unreachable" { return self._builtin_unreachable(invoke); }
        if name == "unreachable_unchecked" {
            return self._builtin_unreachable_unchecked(invoke);
        }
        if name == "unique_id"   { return self._builtin_unique_id(invoke); }
        if name == "include"     { return self._builtin_include(invoke); }
        if name == "embed_str"   { return self._builtin_embed_str(invoke); }
        if name == "embed"       { return self._builtin_embed(invoke); }

        // diagnostics
        if name == "compile_error" {
            return self._builtin_diag(invoke, DiagSeverity::Error);
        }
        if name == "compile_warn" {
            return self._builtin_diag(invoke, DiagSeverity::Warning);
        }
        if name == "compile_note" {
            return self._builtin_diag(invoke, DiagSeverity::Note);
        }

        return &null;
    }

    /// Builtin names are reserved unqualified: a user definition would never
    /// be reachable (dispatch checks builtins first), so `_handle_macro_def`
    /// rejects the definition outright instead of silently hijacking it.
    /// MUST mirror the dispatch table in `_try_builtin`.
    priv fn _is_builtin_name(self, name: string) -> bool {
        return (name == "file")        || (name == "line")
            || (name == "column")      || (name == "module_path")
            || (name == "count")       || (name == "first")
            || (name == "last")        || (name == "rest")
            || (name == "butlast")     || (name == "paste")
            || (name == "stringify")   || (name == "unstringify")
            || (name == "defined")     || (name == "todo")
            || (name == "unreachable") || (name == "unreachable_unchecked")
            || (name == "unique_id")   || (name == "include")
            || (name == "embed_str")   || (name == "embed")
            || (name == "compile_error")
            || (name == "compile_warn")
            || (name == "compile_note");
    }

    // ======================================================================
    //  Builtin helpers
    // ======================================================================

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
            var ex = self._expand_buffer(run);
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

    // ======================================================================
    //  Source-location builtins
    // ======================================================================

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

    // ======================================================================
    //  Argument manipulation builtins
    // ======================================================================

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

    // ======================================================================
    //  Token transformation builtins
    // ======================================================================

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

    // ======================================================================
    //  Macro visibility builtins
    // ======================================================================

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
                }
            }
        }

        out->append(self.make_int_token(
            found,
            invoke->name.range
        ));

        return out;
    }

    // ======================================================================
    //  Deferred/sentinel builtins
    // ======================================================================

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
                f"__synth_{tag}_{self._fid}_{self._unique_counter}",
                range
            );

            self._unique_tag_cache[key] = tok.imm;
            out->append(tok);
            return out;
        }

        // Untagged, or tagged at the top level: fresh on every invocation.
        self._unique_counter += 1;

        var name = (f"__synth_{self._fid}_{self._unique_counter}")
            if tag.empty()
            else (f"__synth_{tag}_{self._fid}_{self._unique_counter}");

        out->append(self.make_ident_token(name, range));
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

    // ======================================================================
    //  Diagnostic builtins
    // ======================================================================

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

    // ======================================================================
    //  Resolution
    // ======================================================================

    priv fn _resolve(self, inv: InvocationInfo) -> *MacroEntry {
        if inv.is_qualified {
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

    // ======================================================================
    //  Finalize
    // ======================================================================

    priv fn _finalize(self) {
        // hand the produced buffer to the TCM as this fid's tokens.
        self._tcm->close_stream(self._fid, self._out);
        self._out = &null; // ownership transferred to the slot
        // splice buffers stay owned here until op delete their tokens were
        // COPIED into _out via wrap/append, so freeing them post-handoff is safe.
    }
}

// =========================================================================
//  Batch driver replaces the old PreProcessor::preprocess phases
// =========================================================================

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
    priv var _opts:      PreprocessorOptions;
    priv var _walked:    set::<u32>;
    priv var _walked_mu: std::SharedMutex;     // wave tasks are parallel

    fn PreProcessor(self, sm: *SourceManager,       tcm:  *TokenCacheManager,
                    resolver: *ImportResolver,      pool: *ThreadPool, diag: *DiagEngine,
                    gscope:   *GlobalDisambigTable, inv:  *CompilerInvocation,
                    opts:      PreprocessorOptions = PreprocessorOptions()) {
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
    }

    fn op delete (self) {
        std::destroy(self._macros);
        std::destroy(self._sym);
    }

    fn get_macro_table(self)  -> *MacroTable { return self._macros; }
    fn get_symbol_table(self) -> *PreprocessorSymbolTable { return self._sym; }

    fn preprocess(self, entry_fid: u32, entry_path: ModulePath) -> PPResult {
        var out = PPResult();
        self._resolver->wait_for_index();

        var scanner = DepScanner(self._sm, self._tcm, self._resolver, self._sym);
        var graph   = scanner.build_graph(entry_fid, entry_path);

        var executor = WaveExecutor(self._pool);
        executor.run(&graph, fn(fid: u32, mod_path: ModulePath) {
            {
                // claim-on-entry is safe ONLY because execute() runs input files
                // sequentially. if FrontendActions ever parallelize, this needs a
                // per-fid completion latch, not a claimed-set.
                var wlock = std::UniqueLock(self._walked_mu);
                if self._walked.contains(fid) { return; }
                self._walked.insert(fid);
            }

            var lexer = self._tcm->open_stream(fid);
            if lexer == &null {
                Logger::error(Logger::Stage::Preprocessor, f"PP: stream open failed fid={fid}");
                return;
            }

            var ctx = self._gscope->get_or_create_context(
                fid, self._sm, self._tcm, self._diag, self._resolver, self._inv, mod_path);
            var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
            if tu == &null {
                tu = ctx->alloc_init::<TranslationUnit>(ctx, fid, ctx->hoisted, self._gscope);
                ctx->tu = reinterpret_cast::<*void>(tu);
            }

            var walker = std::create::<PPWalker>(
                fid, lexer, ctx, tu, self._macros, self._resolver,
                self._sym, self._sm, self._tcm, self._diag, self._opts, mod_path);
            finally { std::destroy(walker); }

            walker->run();
        });

        out.ok = !self._diag->has_fatal();
        out.fids.reserve(graph.all_fids.size());
        for fid in graph.all_fids { out.fids.push_back(fid); }
        libcxx::sort(out.fids.begin(), out.fids.end());
        return out;
    }
}