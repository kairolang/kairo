/// --- The Kairo Project ------------------- Compiler/Parser/ASTParse.k ----- ///
///
///   Main parser class. Derives the five sub-parser mixins and owns all
///   parser state: token cursor, scope stack, recovery state, completion
///   consumer, diagnostics handle, AST context.
///
///   Produces a TranslationUnit from a fully-indexed ASTContext.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::CodeCompleteConsumer::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Mixin::TypeQual::*;
import AST::Mixin::Annotation::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Program::*;
import Resolution::ModulePath::*;
import Token::TokenSpan::*;
import Token::Token::*;
import Token::TokenKind::*;
import Token::IdentifierToken::*;
import Token::TokenText::*;
import Diagnostic::Engine::*;

import Parser::LexicalScope::*;
import Parser::ExprParse::*;
import Parser::StmtParse::*;
import Parser::DeclParse::*;
import Parser::TypeParse::*;
import Parser::PatternParse::*;
import Parser::Shared::ImportGrammar::*;
import Parser::Shared::MacroHeaderGrammar::*;

struct PendingComment {
    var kind:  AnnotationKind = AnnotationKind::DocComment;
    var range: SourceRange    = SourceRange::invalid();
}

/// \class ASTParse
/// \brief the primary recursive-descent parser for the Kairo language.
///
/// \details `ASTParse` implements the Kairo grammar by deriving from specialized
///          parse mixins (`ExprParse`, `StmtParse`, etc.). it maintains the
///          token cursor, manages lexical scopes, and handles macro expansion
///          resolution during the parse.
///
/// result of a parse is a `TranslationUnit` containing the top-level `Program`
/// node and any accumulated diagnostics.
///
/// \par Token Resolution
/// most parser methods should use `check()`, `expect()`, or `resolve_fully()`
/// rather than inspecting `_current` directly. this ensures that macro
/// expansions and doc-comment attributes are handled transparently.
class ASTParse
  derives ExprParse::<ASTParse>,
          StmtParse::<ASTParse>,
          DeclParse::<ASTParse>,
          TypeParse::<ASTParse>,
          PatternParse::<ASTParse>,
          ImportGrammar::<ASTParse>,
          MacroHeaderGrammar::<ASTParse> {
    inline "c++" {
        using PendingAnnotations = PendingAnnotations;
        using PendingQuals = PendingQuals;
    }

    // --- Context handles ----------------------------------------------------
    pub var ctx:   obs::<ASTContext>;           ///< owning context for allocations.
    pub var diag:  obs::<BufferedDiagSink>;     ///< sink for parse errors and warnings.
    pub var scope: ScopeStack;                  ///< active lexical scope hierarchy.
    pub var cc:    obs::<CodeCompleteConsumer>; ///< null during standard batch compilation.

    // --- Token state --------------------------------------------------------
    pub var span:  TokenSpan;                   ///< the full token stream from the lexer.
    pub var c_idx: usize = 0;                   ///< index of the `_current` token in `span`.
    pub var imm:   obs::<ImmediateTable>;       ///< table for resolving macro expansion metadata.

    // Source-of-truth pointers into span private
    var _prev:    obs::<Token> = &null;         ///< the token immediately preceding the cursor.
    var _current: obs::<Token> = &null;         ///< the token at the current cursor position.
    var _peek:    obs::<Token> = &null;         ///< the token one position ahead of the cursor.

    // --- Output -------------------------------------------------------------
    pub var tu: obs::<TranslationUnit>;         ///< the TU being populated by this parse.

    // --- Recovery state -----------------------------------------------------
    pub var _fatal_sentinels:  u32 = 0;      ///< special marker type used to signal unrecoverable errors during type parsing.
    pub var depth:             u32  = 0;     ///< current recursion depth.
    pub var max_depth:         u32  = 256;   ///< limit to prevent stack overflow on malicious input.
    pub var error_count_base:  u32  = 0;     ///< error count recorded at parse start.
    pub var nl_depth:          u32  = 0;     ///< if non-zero, the parser ignores newlines.
    pub var _no_comment_skip: bool = false;
    pub var in_recovery:       bool = false; ///< true if parser is currently skipping to a SyncSet.
    pub var _pending_trailing: vec::<PendingComment>;
    pub var _last_exp_diag_loc: u32 = 0;     ///< raw loc of the last expansion-site diagnostic;
                                             ///  collapses repeated backtraces for one invocation.

    // --- Index mode (merged indexer) -----------------------------------------

    /// \enum ParseMode
    /// \brief selects between the full parse and the table-building index pass.
    ///
    /// \details Index mode drives the SAME decl grammar as Full, but decl
    ///          productions cut after their heads (name, generics, spec
    ///          pattern) and token-skip signatures/bodies, so nothing heavy is
    ///          materialized and no expression parsing runs against the
    ///          half-built DisambigTable. Statement positions are never walked
    ///          into, which kills the old indexer's phantom-global hoists.
    enum ParseMode derives u8 {
        Full,   ///< normal parse: builds the AST, emits diagnostics.
        Index,  ///< pre-pass: populates ctx->hoisted, suppresses diagnostics.
    }

    pub var mode: ParseMode = ParseMode::Full; ///< see ParseMode.

    /// True in normal AST-building mode. Used by mixin parsers (which cannot
    /// name the nested ParseMode enum directly) to gate Full-only behavior such
    /// as the import-edge generic disambiguation fallback.
    pub fn is_full_mode(self) -> bool { return self.mode == ParseMode::Full; }

    var _index_path: vec::<string>;            ///< named-scope path for hoisted inserts (index mode only).
    var _sym_tables: vec::<*SymbolTable>;      ///< tables created by _build_symbols; frozen at parse exit.
    

    class TentativeGuard {
        priv var _parser:    obs::<ASTParse>;
        priv var _cursor:    usize;
        priv var _nl_depth:  u32;
        priv var _committed: bool;
        priv var _saved_comments: usize;

        fn TentativeGuard(self, p: *ASTParse) {
            self._parser    = p;
            self._cursor    = p->c_idx;
            self._saved_comments = p->_pending_trailing.size();
            self._nl_depth  = p->nl_depth;
            self._committed = false;
            p->diag->push_suppress();
        }

        /// \brief commits the speculative parse: cursor is kept, diagnostics
        ///        emitted after this point are no longer suppressed.
        fn commit(self) { self._committed = true; }

        fn op delete (self) {
            self._parser->diag->pop_suppress();
            if !self._committed {
                self._parser->_restore_cursor(self._cursor);
                self._parser->nl_depth = self._nl_depth;
                while (self._parser->_pending_trailing.size()) > self._saved_comments {
                    self._parser->_pending_trailing.pop_back();
                }
            }
        }
    }

    /// \brief RAII swap of the token cursor onto a foreign TokenBuffer (an
    ///        f-string interpolation hole), restoring the main stream on exit.
    ///        Mirrors Lexer::lex_slice's state-stash, but unconditional via
    ///        op delete so no early-return/throw leaks a half-swapped cursor.
    ///
    /// \warning no TentativeGuard may straddle this, a c_idx saved in the outer
    ///          stream is meaningless in the hole stream. Hole parsing must begin
    ///          and end fully inside the guard's lifetime.
    class StreamGuard {
        priv var _p:        obs::<ASTParse>;
        priv var _span:     TokenSpan;
        priv var _c_idx:    usize;
        priv var _prev:     obs::<Token>;
        priv var _current:  obs::<Token>;
        priv var _peek:     obs::<Token>;
        priv var _nl_depth: u32;
        priv var _saved_comments: usize;

        fn StreamGuard(self, p: *ASTParse, span: TokenSpan) {
            self._p        = p;
            self._span     = p->span;
            self._c_idx    = p->c_idx;
            self._prev     = p->_prev;
            self._current  = p->_current;
            self._peek     = p->_peek;
            self._nl_depth = p->nl_depth;
            self._saved_comments = p->_pending_trailing.size();

            p->span     = span;
            p->c_idx    = 0;
            p->nl_depth = 0;
            p->_prev    = &null;
            p->_current = (p->span.get(0)) if (p->span.size() > 0) else (&null);
            p->_peek    = (p->span.get(1)) if (p->span.size() > 1) else (&null);
        }

        fn op delete (self) {
            self._p->span     = self._span;
            self._p->c_idx    = self._c_idx;
            self._p->_prev    = self._prev;
            self._p->_current = self._current;
            self._p->_peek    = self._peek;
            self._p->nl_depth = self._nl_depth;
            while self._p->_pending_trailing.size() > self._saved_comments {
                self._p->_pending_trailing.pop_back();
            }
        }
    }

    /// \brief initializes a parser for a specific context and token stream.
    ///
    /// \param ctx      the ASTContext which provides tokens and memory arenas.
    /// \param cc       optional completion consumer for IDE features.
    /// \param g_scope  the global scope used for hoisting top-level declarations.
    /// \param mode     Full (default) or Index; Index allocates ctx->hoisted
    ///                 (previously ASTIndex's job) and expects index() to be
    ///                 called instead of parse().
    fn ASTParse(self, ctx: *ASTContext, cc: *CodeCompleteConsumer, g_scope: *GlobalDisambigTable, mode: ParseMode = ParseMode::Full) {
        self.ctx   = ctx;
        self.diag = &(ctx->diag_sink);
        self.imm   = ctx->get_imm_table();
        self.cc    = cc;
        self.span  = ctx->get_tokens();

        self.mode = mode;
        if (mode == ParseMode::Index) && (ctx->hoisted == &null) {
            // the index pass owns table allocation; must precede TU creation
            // below since the TU constructor captures ctx->hoisted.
            ctx->hoisted = ctx->alloc_init_index_cleanup::<DisambigTable>(ctx);
        }

        var existing = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if existing != &null {
            self.tu = existing;   // PP-built TU: imports/macros already in it
        } else {
            // ParseSource / test-harness path: no PP ran
            self.tu = ctx->alloc_init_pp::<TranslationUnit>(ctx, ctx->fid, ctx->hoisted, g_scope);
            ctx->tu = reinterpret_cast::<*void>(self.tu);
        }
        self.scope.set_ctx(ctx);
        self._pending_trailing.reserve(4);

        self._prev    = &null;
        self._current = (self.span.get(0)) if (self.span.size() > 0) else (&null);
        self._peek    = (self.span.get(1)) if (self.span.size() > 1) else (&null);

        self.max_depth        = ctx->ci->frontend.max_scope_depth;
        self.error_count_base = self.diag->error_count();
    }

    /// \brief executes the full parse of the token stream.
    ///
    /// \details top-level loop. Annotations are consumed ONCE per item and
    ///          stamped on the routed node. Routing: decl lead-ins go to
    ///          _parse_top_decl, everything else to _parse_top_stmt. See
    ///          _routes_to_decl for the var/const/eval/fn carve-outs.
    ///          After the loop, _wire_scopes connects named DeclContexts to
    ///          their hoisted DisambigNodes so sema lookup_local works.
    fn parse(self) -> *TranslationUnit {
        var program = self.ctx->alloc_init::<Program>(self.ctx->fid, self.ctx);
        self.tu->program = program;
        self.scope.push(ScopeKind::Block, self.tu);

        var warn_count_base = self.diag->warn_count();

        var iterations: usize = 0;
        var max_iter = self.span.size() << 2;

        while !self.is_eof() {
            ++iterations;
            if iterations > max_iter { break; }

            if self._is_terminator_tok(self._current) {
                self.advance_raw();
                continue;
            }

            var annot: PendingAnnotations;
            self.consume_leading_annotations(&annot);
            if self.is_eof() { break; }

            // A leading comment binds to the NEXT construct, but the PP deletes
            // imports/ffi-imports before parsing so a comment written directly
            // above an import (`// why\nimport foo`) leaves its trailing
            // newline(s) orphaned in the stream. Without this skip the loop
            // would dispatch on that residual terminator and mis-parse it as an
            // expression statement (spurious S052E). Skipping terminators here
            // does NOT drop `annot`: it is a local and still applies to the
            // real decl that follows. If only terminators remain to EOF, the
            // comment was genuinely trailing nothing break, no diagnostic.
            while self._is_terminator_tok(self._current) {
                self.advance_raw();
                if self.is_eof() { break; }
            }
            if self.is_eof() { break; }

            var k  = self.resolve_kind_deep(self._current);
            var ok = (self._parse_top_decl(program, &annot, k))
                     if self._routes_to_decl(k)
                     else (self._parse_top_stmt(program, &annot));
            if !ok { break; }

            while self._is_terminator_tok(self._current) {
                self.advance_raw();
            }
        }

        self.scope.pop();
        self.tu->error_count = self.diag->error_count() - self.error_count_base;
        self.tu->warn_count  = self.diag->warn_count()  - warn_count_base;

        self._wire_scopes();
        self._build_symbols();
        self._synthesize_module_self();
        return self.tu;
    }

    /// \brief Create the synthetic per-file ModuleDecl (A2: shares the TU's
    ///        symbol table) so a plain `import bar` binds a REAL *Decl and
    ///        `bar::foo` resolves through one uniform module path.
    ///
    /// \details Runs AFTER _build_symbols so tu->dc_symbols exists to share.
    ///          The module name is the LEAF segment of ctx->module_base (the
    ///          file's resolved module path). An empty base = the root/main
    ///          file: no name to bind, left anonymous (module_self stays null).
    ///          The node's dc_symbols is aliased to the TU's table (read-only
    ///          post-freeze), and its full module_path is carried for a future
    ///          codegen uniqueness fix (see ModuleDecl::module_path).
    priv fn _synthesize_module_self(self) {
        var base = self.ctx->module_base;
        if base.segments.size() == 0 { return; }   // anonymous root file.

        var leaf = base.segments[base.segments.size() - 1];

        // Prefer the leaf's real source token; else synthesize an identifier
        // token carrying the leaf imm (name-domain only, no source slice).
        var name_tok: Token;
        if leaf.token != &null {
            name_tok = *(leaf.token);
        } else {
            name_tok       = Token{};
            name_tok.kind  = TokenKind::LitIdentifier;
            name_tok.imm   = leaf.name;
            name_tok.range = SourceRange::invalid();
        }

        var tu_dc = static_cast::<*DeclContext>(self.tu);
        var md = ModuleDecl::create(self.ctx, SourceRange::invalid(), name_tok, tu_dc);

        // A2: share the TU's symbol table rather than owning a second one, so
        // member lookup through the module hits the same frozen decls. A file
        // with no top-level named decls never triggered _symtab_for, so the TU
        // table can be null share an empty frozen table so qualified lookup
        // through the module is a clean miss, not a null deref.
        if self.tu->dc_symbols == &null {
            var empty = self.ctx->alloc_init_cleanup::<SymbolTable>();
            empty->freeze();
            self.tu->set_symbols(empty);
        }
        md->set_symbols(self.tu->dc_symbols);
        md->module_path = base;

        self.tu->module_self = static_cast::<*Decl>(md);
    }

    /// \brief decl-vs-stmt routing for the top-level loop.
    ///
    /// \details var/const always take the stmt path (it owns the plain-decl vs
    ///          destructuring split). `eval` is a decl only when followed by
    ///          `{`; `eval for/if/var` are statements.
    priv fn _routes_to_decl(self, k: TokenKind) -> bool {
        if !self._starts_decl_kw(k) { return false; }
        if (k == TokenKind::KwVar) || (k == TokenKind::KwConst) { return false; }
        if (k == TokenKind::KwEval) && (!self.check_peek(TokenKind::OpLBrace)) { return false; }
        return true;
    }

    /// \brief parses one top-level declaration and lands it in tu->dc_decls
    ///        (source order) AND program->items.
    ///
    /// \details `fn` at top level may be a named decl or an anonymous closure
    ///          (`fn ()|&| { }()` as an IIFE). parse_decl speculates and returns
    ///          null with the cursor rolled back to `fn` when it's the latter;
    ///          we hand off to the statement path, which owns the expression.
    ///
    /// \return false to stop the top-level loop (fatal or unroutable).
    priv fn _parse_top_decl(self, program: *Program, annot: *PendingAnnotations, k: TokenKind) -> bool {
        var d = self.parse_decl(true);
        if d == &null {
            if k == TokenKind::KwFn {
                return self._parse_top_stmt(program, annot);
            }
            return false;
        }
        if self.is_fatal::<Decl>(d) { return false; }

        if isa::<VisibilityGroupDecl>(d) {
            self._diag_annot_on_vis_group(annot);
            // do NOT stamp annot onto the group
        } else {
            self.apply_annotations_to_decl(d, annot);
        }

        self.tu->add_decl(d);
        program->add_item(TopLevelItem::from_decl(d));
        self._attach_trailing(d);
        return true;
    }

    /// \brief parses one top-level statement (script-style top level is legal).
    ///
    /// \details DeclStmt unwraps so annotations land on the inner decl, not
    ///          the statement wrapper.
    ///
    /// \return false to stop the top-level loop (null or fatal).
    priv fn _parse_top_stmt(self, program: *Program, annot: *PendingAnnotations) -> bool {
        var s = self.parse_stmt();
        if s == &null { return false; }
        if self.is_fatal::<Stmt>(s) { return false; }

        if isa::<DeclStmt>(s) {
            var ds = cast::<DeclStmt>(s);
            if ds->decl != &null {
                self.apply_annotations_to_decl(ds->decl, annot);
            }
        } else {
            self.apply_annotations_to_node(s, annot);
        }

        program->add_item(TopLevelItem::from_stmt(s));
        self._attach_trailing(s);
        return true;
    }

    /// \brief S048E: annotations/attributes cannot apply to a visibility group.
    ///        one note per additional annotation so each gets its own caret
    ///        instead of one fused multi-line span.
    priv fn _diag_annot_on_vis_group(self, annot: *PendingAnnotations) {
        if annot->empty() { return; }

        var first_span: SourceRange = annot->entries.front().range;

        var b = self.diag->report(DiagID::S048E, first_span.start,
            "annotations and attributes cannot be applied to a visibility group; "
            "apply them to individual members instead"
        );
        b.first(first_span);

        for var i: usize = 1; i < annot->entries.size(); ++i {
            var e = &annot->entries[i];
            b.note(DiagID::S048N, e->range.start,
                "this annotation also cannot apply to the group"
            ).first(e->range);
        }

        b.emit();
    }

    /// \brief routes parsing to specific top-level declaration logic.
    pub fn dispatch_top_level(self) -> TopLevelItem {
        self.advance();
        return TopLevelItem::from_decl(&null);
    }

    //  Hoisted-scope wiring (post-parse)

    /// \brief connects each named DeclContext in the tree to its DisambigNode in
    ///        the hoisted trie, descending both in lockstep. Decls the indexer
    ///        didn't hoist (locals, anonymous modules) are skipped lexical
    ///        lookup covers them. A missing trie node for a hoisted-eligible
    ///        type is an indexer/parser disagreement; we stay silent here and
    ///        let sema's resolve-or-error path surface it with context.
    fn _wire_scopes(self) {
        var root = self.ctx->hoisted->root();
        self.tu->set_scope(root);
        self._wire_dc_children(static_cast::<*DeclContext>(self.tu), root);
    }

    priv fn _wire_dc_children(self, dc: *DeclContext, node: *DisambigNode) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i { // FIXME
            var d = *(dc->dc_decls.get(i)); // FIXME
            if d == &null { continue; }

            var name_tok = Token();
            var child_dc: *DeclContext = &null;

            if isa::<ClassDecl>(d) {
                var n = cast::<ClassDecl>(d);
                name_tok = n->name; child_dc = static_cast::<*DeclContext>(n);
            } else if isa::<StructDecl>(d) {
                var n = cast::<StructDecl>(d);
                name_tok = n->name; child_dc = static_cast::<*DeclContext>(n);
            } else if isa::<EnumDecl>(d) {
                var n = cast::<EnumDecl>(d);
                name_tok = n->name; child_dc = static_cast::<*DeclContext>(n);
            } else if isa::<UnionDecl>(d) {
                var n = cast::<UnionDecl>(d);
                name_tok = n->name; child_dc = static_cast::<*DeclContext>(n);
            } else if isa::<InterfaceDecl>(d) {
                var n = cast::<InterfaceDecl>(d);
                name_tok = n->name; child_dc = static_cast::<*DeclContext>(n);
            } else if isa::<ModuleDecl>(d) {
                var n = cast::<ModuleDecl>(d);
                if n->is_anonymous { continue; }
                name_tok = n->name; child_dc = static_cast::<*DeclContext>(n);
            } else {
                continue; // fns/vars: no trie children; ScopeStack covers bodies
            }

            var child = node->get_child(self.ctx->hoisted->intern_tok(name_tok));
            if child == &null { continue; }

            child_dc->set_scope(child);
            self._wire_dc_children(child_dc, child);
        }
    }

    //  Symbol table build (post-parse)

    /// \brief builds the REAL per-DeclContext symbol tables (dc_symbols) in
    ///        one walk over the completed TU, then freezes them. This is the
    ///        table sema resolves against; dc_scope/DisambigTable stays a
    ///        parser-only phase artifact. See Sema/RESOLUTION.md #1.
    ///
    /// \details Rules:
    ///        - append-only multimap, ZERO diagnostics. Duplicate names,
    ///          fwd-decl + definition, primary + specializations: all just
    ///          stack in the cell. NameResolution links Redeclarable
    ///          chains and reports redefinitions later.
    ///        - `fn Class::method` out-of-line defs land in
    ///          tu->out_of_line, never in a table (attachment is N(a)'s
    ///          job).
    ///        - locals and params are EXCLUDED: the walk never descends
    ///          into Function/Lambda/Block contexts. Body resolution
    ///          walks its own lexical stack; params come off the
    ///          FunctionDecl signature.
    ///        - anonymous containers (anonymous modules, visibility
    ///          groups, eval blocks, ffi blocks) get no table of their
    ///          own; their decls land in the enclosing DC's table.
    ///        - a fn in a type scope whose name equals the type's name
    ///          keys as DeclName::ctor() context-relative, no type info
    ///          in the key. Operators key on the packed op-token kinds.
    ///        - extension members go in the ExtensionDecl's OWN table;
    ///          folding them into the target type is sema's job.
    ///        - top-level `var`/`const` route through the stmt path
    ///          (DeclStmt) and never hit tu->dc_decls, so they are picked
    ///          up from program->items separately.
    ///        - after the walk, every created table is frozen. FROZEN
    ///          MEANS FROZEN: later phases grow overlays, node links, or
    ///          registries never these tables.
    fn _build_symbols(self) {
        var tu_dc = static_cast::<*DeclContext>(self.tu);
        self._collect_symbols(tu_dc, tu_dc, u32(-1));

        // top-level DeclStmt-wrapped decls (script-style `var x = 5`).
        var prog = self.tu->program;
        if prog != &null {
            for var i: usize = 0; i < prog->items.size(); ++i {
                var item = prog->items.get(i);
                if item == &null { continue; }
                if item->get_kind() != TopLevelKind::Stmt { continue; }

                var s = item->as_stmt();
                if s == &null { continue; }

                if isa::<DeclStmt>(s) {
                    var ds = cast::<DeclStmt>(s);
                    if ds->decl != &null {
                        self._index_symbol_decl(ds->decl, tu_dc, tu_dc, u32(-1));
                    }
                    continue;
                }

                // `var (a, b) = t` at file scope. A destructuring decl declares
                // into its ENCLOSING scope (it is a decl statement, not a scope
                // of its own), so at top level its binders belong in the TU
                // table exactly like a plain `var`. Without this they were
                // findable from nowhere: sema's lexical stack only covers
                // executable scopes, and file scope has none.
                //
                // Ranged-for / context bindings are deliberately NOT swept
                // here: those bind only inside their own body, which IS an
                // executable scope, so sema's lexical stack owns them.
                if isa::<DestructuringDeclStmt>(s) {
                    var dd = cast::<DestructuringDeclStmt>(s);
                    for var b: usize = 0; b < dd->bindings.size(); ++b {
                        var bind = dd->bindings[b];
                        if bind.is_discard { continue; }
                        if bind.decl == &null { continue; }
                        self._index_symbol_decl(bind.decl, tu_dc, tu_dc, u32(-1));
                    }
                }
            }
        }

        for var i: usize = 0; i < self._sym_tables.size(); ++i {
            self._sym_tables[i]->freeze();
        }
    }

    /// \brief lazily allocates the SymbolTable for \p dc and registers it
    ///        for the freeze sweep at the end of _build_symbols.
    priv fn _symtab_for(self, dc: *DeclContext) -> *SymbolTable {
        if dc->dc_symbols == &null {
            var t = self.ctx->alloc_init_cleanup::<SymbolTable>();
            dc->set_symbols(t);
            self._sym_tables.push_back(t);
        }

        return dc->dc_symbols;
    }

    /// \brief appends \p d under \p name in \p table_dc's table and stamps
    ///        the dual-context links (lexical = where written, semantic =
    ///        lookup home). They differ for anonymous-module members now
    ///        and for extension members once sema folds them.
    priv fn _append_symbol(self, table_dc: *DeclContext, lex_dc: *DeclContext, name: DeclName, d: *Decl) {
        self._symtab_for(table_dc)->append(name, d);
        d->lexical_dc  = reinterpret_cast::<*void>(lex_dc);
        d->semantic_dc = reinterpret_cast::<*void>(table_dc);
    }

    /// \brief identifier-keyed append. Silently skips recovery/synthetic
    ///        names that fail imm resolution sema surfaces those with
    ///        context; a half-keyed table entry helps no one.
    priv fn _append_ident_symbol(self, table_dc: *DeclContext, lex_dc: *DeclContext, name_tok: Token, d: *Decl) {
        var im = self.ctx->get_ident_imm(name_tok);
        if im == u32(-1) { return; }
        
        self._append_symbol(table_dc, lex_dc, DeclName::ident(im), d);
    }

    /// \brief DeclName for `fn op <x>` from its (up to two) operator tokens.
    priv fn _op_decl_name(self, f: *FunctionDecl) -> DeclName {
        var k0 = TokenKind::TkUnknown;
        var k1 = TokenKind::TkUnknown;
        if f->op_token.count > 0 { k0 = f->op_token[0].kind; }
        if f->op_token.count > 1 { k1 = f->op_token[1].kind; }
        
        return DeclName::op_name(k0, k1);
    }

    /// \brief walks \p walk_dc's owned decls, appending each named decl to
    ///        \p table_dc's table. \p owner_name_imm is the imm of the
    ///        enclosing TYPE's name when table_dc is a type scope (ctor
    ///        detection), u32(-1) otherwise.
    ///
    /// \details a TYPE body's dc_decls holds nested type decls PLUS the
    ///          VisibilityGroupDecl wrappers, and a wrapper's `members` are
    ///          pointers back into the type's fields/methods lists and back
    ///          into dc_decls (see DeclParse::_parse_member_vis_group, which
    ///          pushes each grouped member into BOTH). Indexing the wrapper
    ///          there would append every grouped member a second time and
    ///          hand N a cell that redefines a decl against itself, so the
    ///          wrapper is skipped   the same rule RecursiveASTVisitor::
    ///          _rav_dc_nested and ASTPrinter::_collect_type_members follow.
    ///
    ///          At MODULE/TU scope the wrapper IS the only container (a
    ///          top-level `pub { ... }` never projects its members anywhere
    ///          else), so there it is walked through normally.
    priv fn _collect_symbols(self, walk_dc: *DeclContext, table_dc: *DeclContext, owner_name_imm: u32) {
        var type_body = walk_dc->is_type_scope();
        for var i: usize = 0; i < walk_dc->dc_decls.size(); ++i {
            var d = *(walk_dc->dc_decls.get(i));
            if d == &null { continue; }
            if type_body && isa::<VisibilityGroupDecl>(d) { continue; }
            self._index_symbol_decl(d, walk_dc, table_dc, owner_name_imm);
        }
    }

    /// \brief routes one decl into the tables. Pass-through containers
    ///        (visibility groups, eval blocks, ffi blocks) recurse with the
    ///        SAME table_dc; scope-owning named decls append themselves and
    ///        recurse into their own context.
    priv fn _index_symbol_decl(self, d: *Decl, walk_dc: *DeclContext, table_dc: *DeclContext, owner_name_imm: u32) {
        if isa::<ClassDecl>(d) {
            var n = cast::<ClassDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);

            var dc    = static_cast::<*DeclContext>(n);
            var owner = self.ctx->get_ident_imm(n->name);
            // Members live in the typed FrozenLists (fields/methods), NOT in
            // dc_decls; only nested types are add_decl'd. Route each member
            // back through _index_symbol_decl so operator/ctor detection fires.
            for var mi: usize = 0; mi < n->fields.size(); ++mi {
                var fd = n->fields[mi];
                if fd != &null { self._index_symbol_decl(static_cast::<*Decl>(fd), dc, dc, owner); }
            }
            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var md = n->methods[mi];
                if md != &null { self._index_symbol_decl(static_cast::<*Decl>(md), dc, dc, owner); }
            }
            self._collect_symbols(dc, dc, owner);   // nested types from dc_decls

            return;
        } if isa::<StructDecl>(d) {
            var n = cast::<StructDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);

            var dc    = static_cast::<*DeclContext>(n);
            var owner = self.ctx->get_ident_imm(n->name);
            // struct: fields + nested types, plus the ctors/operators the body
            // does admit (named methods are rejected at parse).
            for var mi: usize = 0; mi < n->fields.size(); ++mi {
                var fd = n->fields[mi];
                if fd != &null { self._index_symbol_decl(static_cast::<*Decl>(fd), dc, dc, owner); }
            }
            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var md = n->methods[mi];
                if md != &null { self._index_symbol_decl(static_cast::<*Decl>(md), dc, dc, owner); }
            }
            self._collect_symbols(dc, dc, owner);

            return;
        } if isa::<UnionDecl>(d) {
            var n = cast::<UnionDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);

            var dc    = static_cast::<*DeclContext>(n);
            var owner = self.ctx->get_ident_imm(n->name);
            // union: fields + nested types, plus ctors/operators - same rule as
            // struct.
            for var mi: usize = 0; mi < n->fields.size(); ++mi {
                var fd = n->fields[mi];
                if fd != &null { self._index_symbol_decl(static_cast::<*Decl>(fd), dc, dc, owner); }
            }
            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var md = n->methods[mi];
                if md != &null { self._index_symbol_decl(static_cast::<*Decl>(md), dc, dc, owner); }
            }
            self._collect_symbols(dc, dc, owner);

            return;
        } if isa::<InterfaceDecl>(d) {
            var n = cast::<InterfaceDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);

            var dc    = static_cast::<*DeclContext>(n);
            var owner = self.ctx->get_ident_imm(n->name);
            // interface: requirement-signature methods + nested types.
            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var md = n->methods[mi];
                if md != &null { self._index_symbol_decl(static_cast::<*Decl>(md), dc, dc, owner); }
            }
            self._collect_symbols(dc, dc, owner);

            return;
        } if isa::<EnumDecl>(d) {
            var n = cast::<EnumDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);
            var dc = static_cast::<*DeclContext>(n);
            // variants are owned via n->variants (not dc_decls); key them in
            // the enum's own table so `Direction::North` resolves per segment.
            for var v: usize = 0; v < n->variants.count; ++v {
                var vd = n->variants[v];
                if vd != &null {
                    self._append_ident_symbol(dc, dc, vd->name, static_cast::<*Decl>(vd));
                }
            }
            
            self._collect_symbols(dc, dc, u32(-1));
            return;
        } if isa::<ModuleDecl>(d) {
            var n  = cast::<ModuleDecl>(d);
            var dc = static_cast::<*DeclContext>(n);
            if n->is_anonymous {
                // anonymous modules get no table; decls land in the
                // enclosing DC's table. lexical_dc still records the module.
                self._collect_symbols(dc, table_dc, owner_name_imm);
                return;
            }
            
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);
            self._collect_symbols(dc, dc, u32(-1));
            return;
        } if isa::<ExtensionDecl>(d) {
            // extension members key in the extension's OWN table. Folding
            // into the target type (and rewriting semantic_dc) is sema's
            // job the parser cannot resolve the target here.
            //
            // Methods live in the typed `methods` list, NOT in dc_decls
            // (only nested types are add_decl'd), so they are routed back
            // through _index_symbol_decl exactly like class methods -
            // otherwise an ungrouped `extend` method is in no table at all
            // and qualified lookup through the extension finds nothing.
            // owner_name_imm stays -1: an extension body has no name of its
            // own, so `fn Foo(self)` inside `extend Foo` is a named method
            // here, not a ctor (ctors belong to the type's own body).
            var n  = cast::<ExtensionDecl>(d);
            var dc = static_cast::<*DeclContext>(n);

            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var md = n->methods[mi];
                if md != &null { self._index_symbol_decl(static_cast::<*Decl>(md), dc, dc, u32(-1)); }
            }
            self._collect_symbols(dc, dc, u32(-1));
            return;
        } if isa::<FunctionDecl>(d) {
            var f = cast::<FunctionDecl>(d);
            if f->is_out_of_line() {
                // `fn Class::method` no table entry; N(a) attaches it.
                self.tu->out_of_line.push(d);
                d->lexical_dc  = reinterpret_cast::<*void>(walk_dc);
                d->semantic_dc = &null; // unknown until attachment
                return;
            }

            if f->is_operator {
                self._append_symbol(table_dc, walk_dc, self._op_decl_name(f), d);
                return;
            }
            
            var im = self.ctx->get_ident_imm(f->name);
            if im == u32(-1) { return; }
            if table_dc->is_type_scope() && (im == owner_name_imm) {
                self._append_symbol(table_dc, walk_dc, DeclName::ctor(), d);
                return;
            }
            
            self._append_symbol(table_dc, walk_dc, DeclName::ident(im), d);
            // no recursion: locals/params are excluded by design.
            return;
        }
        if isa::<VariableDecl>(d) {
            var n = cast::<VariableDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);
            return;
        }
        if isa::<FieldDecl>(d) {
            var n = cast::<FieldDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);
            return;
        }
        if isa::<TypeAliasDecl>(d) {
            var n = cast::<TypeAliasDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);
            return;
        }
        if isa::<VisibilityGroupDecl>(d) {
            var n = cast::<VisibilityGroupDecl>(d);
            for var i: usize = 0; i < n->members.count; ++i {
                var m = n->members[i];
                if m != &null { self._index_symbol_decl(m, walk_dc, table_dc, owner_name_imm); }
            }
            return;
        }
        if isa::<EvalBlockDecl>(d) {
            var n = cast::<EvalBlockDecl>(d);
            for var i: usize = 0; i < n->body.count; ++i {
                var m = n->body[i];
                if m != &null { self._index_symbol_decl(m, walk_dc, table_dc, owner_name_imm); }
            }
            return;
        }
        if isa::<FFIBlockDecl>(d) {
            var n = cast::<FFIBlockDecl>(d);
            for var i: usize = 0; i < n->body.count; ++i {
                var m = n->body[i];
                if m != &null { self._index_symbol_decl(m, walk_dc, table_dc, owner_name_imm); }
            }
            return;
        }
        if isa::<ProcedureMacroDecl>(d) {
            // A proc macro (`macro @name(...) { ... }`) is an eval-time function:
            // it has a real name, executes at compile time, and is referenced by
            // that name. Key it by ident in the enclosing table exactly like a
            // FunctionDecl. No recursion: params are ParamDecl (off the
            // signature) and the body holds locals, both excluded by design   the
            // same rule as the FunctionDecl branch above.
            //
            // NOTE distinct from MacroDecl (`macro name!`), which is a PP token
            // macro owned by the preprocessor and deliberately never tabled.
            var n = cast::<ProcedureMacroDecl>(d);
            self._append_ident_symbol(table_dc, walk_dc, n->name, d);
            return;
        }
        // ImportDecl:                   phase I owns imports (overlay), nothing to record.
        // MacroDecl:                    the macro table belongs to the PP.
        // TestDecl:                     anonymous, never looked up.
        // ParamDecl / GenericParamDecl: excluded (come off signatures).
        // EnumVariantDecl:              handled at its owning EnumDecl above.
    }

    //  Index mode (merged indexer)

    /// \brief Index-mode entry point: walks the token stream with the REAL
    ///        decl grammar (shallow: heads only, bodies token-skipped) and
    ///        populates ctx->hoisted from the returned decl nodes.
    ///
    /// \details replaces ASTIndex. One grammar, two depths: decl productions
    ///          check `mode` and cut after their heads; this loop and
    ///          _index_hoist_decl own all table population. Statement
    ///          positions are token-skipped wholesale, so a `var` inside a
    ///          for-header or destructure RHS can never hoist a phantom
    ///          global (old indexer bug #2).
    ///
    ///          Diagnostics are suppressed for the whole pass: the Full parse
    ///          that follows re-parses everything and owns every diagnostic;
    ///          emitting here would double-report.
    fn index(self) {
        if self.mode != ParseMode::Index { return; }
        if self.ctx->hoisted == &null    { return; }

        self.diag->push_suppress();

        var iterations: usize = 0;
        var max_iter  = self.span.size() << 2;
        var prev_idx: usize = 0;
        var have_prev = false;

        while !self.is_eof() {
            ++iterations;
            if iterations > max_iter { break; }

            // progress guard: a production that consumed nothing (recovery
            // stopping on the very token we dispatched on) must not spin.
            if have_prev && (self.c_idx == prev_idx) {
                self.advance_raw();
                continue;
            }
            prev_idx  = self.c_idx;
            have_prev = true;

            if self._is_terminator_tok(self._current) {
                self.advance_raw();
                continue;
            }

            var annot: PendingAnnotations;
            self.consume_leading_annotations(&annot); // consumed, discarded
            if self.is_eof() { break; }

            var k = self.resolve_kind_deep(self._current);
            if self._starts_decl_kw(k) {
                var d = self.parse_decl(true);
                if d == &null {
                    // closure IIFE fallback (cursor rolled back to `fn`) or a
                    // non-decl after modifiers: skip the statement wholesale.
                    self._index_skip_stmt();
                } else {
                    self._index_hoist_decl(d, false);
                }
            } else {
                // statement position: never walked into.
                self._index_skip_stmt();
            }
        }

        self.diag->pop_suppress();
    }

    /// \brief inserts one entry at the current _index_path scope.
    priv fn _index_insert(self, name: string, entry: DisambigEntry) {
        if name == "" { return; }
        if self._index_path.empty() {
            self.ctx->hoisted->insert(name, entry);
        } else {
            self.ctx->hoisted->insert_into(&self._index_path, name, entry);
        }
    }

    /// \brief builds a DisambigEntry for \p d and inserts it, recursing into
    ///        container decls (modules, visibility groups, eval/ffi blocks,
    ///        type bodies via dc_decls) with the scope path maintained.
    ///
    /// \details genericness comes from TemplateParams::is_generic() on the
    ///          node: has_type_params() || spec_kind == Primary. Explicit and
    ///          Partial specializations therefore never mark a name generic
    ///          on their own (old indexer bug #1).
    fn _index_hoist_decl(self, d: *Decl, foreign: bool) {
        if d == &null { return; }

        if isa::<FunctionDecl>(d) {
            var n = cast::<FunctionDecl>(d);
            if n->qualifier != &null { return; }             // out-of-line impl: not a new decl
            if n->name.kind == TokenKind::KwSelf { return; } // ctor: not a root name
            // Non-generic callables are stored as NEGATIVE evidence: rule 4
            // of the disambiguation model demands that `<` after a known
            // non-generic name commits to a comparison, and the verdict
            // (_generic_verdict) needs found-and-not-generic to be
            // distinguishable from not-found (which stays tentative for
            // unqualified imported generics).
            var e = DisambigEntry{};
            e.kind        = (DisambigKind::Operator) if (n->is_operator) else (DisambigKind::Function);
            e.generic     = n->is_generic();
            e.is_foreign  = foreign;
            e.extended    = false;
            e.decl.origin = n->range;
            self._index_insert(self.ctx->get_spelling(n->name), e);
            return;
        }

        if isa::<ClassDecl>(d) {
            var n = cast::<ClassDecl>(d);
            self._index_hoist_type_scope(static_cast::<*DeclContext>(n), n->name,
                DisambigKind::ClassType, n->is_generic(), n->range, foreign);
            return;
        }
        if isa::<StructDecl>(d) {
            var n = cast::<StructDecl>(d);
            self._index_hoist_type_scope(static_cast::<*DeclContext>(n), n->name,
                DisambigKind::StructType, n->is_generic(), n->range, foreign);
            return;
        }
        if isa::<UnionDecl>(d) {
            var n = cast::<UnionDecl>(d);
            self._index_hoist_type_scope(static_cast::<*DeclContext>(n), n->name,
                DisambigKind::UnionType, n->is_generic(), n->range, foreign);
            return;
        }
        if isa::<InterfaceDecl>(d) {
            var n = cast::<InterfaceDecl>(d);
            self._index_hoist_type_scope(static_cast::<*DeclContext>(n), n->name,
                DisambigKind::InterfaceType, n->is_generic(), n->range, foreign);
            return;
        }

        if isa::<EnumDecl>(d) {
            var n = cast::<EnumDecl>(d);
            var e = DisambigEntry{};
            e.kind        = DisambigKind::EnumType;
            e.generic     = n->is_generic();
            e.is_foreign  = foreign;
            e.extended    = false;
            e.decl.origin = n->range;
            self._index_insert(self.ctx->get_spelling(n->name), e);
            return; // variants are not hoisted (parity with the old indexer)
        }

        if isa::<TypeAliasDecl>(d) {
            var n = cast::<TypeAliasDecl>(d);
            var e = DisambigEntry{};
            e.kind        = DisambigKind::TypeAlias;
            e.generic     = n->is_generic();
            e.is_foreign  = foreign;
            e.extended    = false;
            e.decl.origin = n->range;
            self._index_insert(self.ctx->get_spelling(n->name), e);
            return;
        }

        if isa::<VariableDecl>(d) {
            // Negative evidence for rule 4 (see FunctionDecl above):
            // `scale<a>(10)` on a known global var must commit to a
            // comparison chain. Generic closures bound to vars are a
            // LexicalScope concern (locals shadow globals; the verdict
            // checks the scope stack first). PatternParse uses is_type()
            // so value entries cannot flip `case x` into a constructor.
            var n = cast::<VariableDecl>(d);
            var e = DisambigEntry{};
            e.kind        = DisambigKind::Variable;
            e.generic     = false;
            e.is_foreign  = foreign;
            e.extended    = false;
            e.decl.origin = n->range;
            self._index_insert(self.ctx->get_spelling(n->name), e);
            return;
        }

        // MacroDecl / ProcedureMacroDecl: never hoisted. Macro invocations
        // are resolved by the PP; is_macro() has zero parser callsites, and
        // macro names never head a `<` disambiguation (`foo!` / `@foo`).

        if isa::<ModuleDecl>(d) {
            var n = cast::<ModuleDecl>(d);
            // no entry for the module itself (parity with the old indexer);
            // named modules contribute a scope-path segment for their decls.
            if !n->is_anonymous {
                self._index_path.push_back(self.ctx->get_spelling(n->name));
            }
            self._index_hoist_dc_children(static_cast::<*DeclContext>(n), foreign);
            if !n->is_anonymous {
                self._index_path.pop_back();
            }
            return;
        }

        if isa::<VisibilityGroupDecl>(d) {
            var n = cast::<VisibilityGroupDecl>(d);
            for var i: usize = 0; i < n->members.size(); ++i {
                self._index_hoist_decl(n->members[i], foreign);
            }
            return;
        }
        if isa::<EvalBlockDecl>(d) {
            var n = cast::<EvalBlockDecl>(d);
            for var i: usize = 0; i < n->body.size(); ++i {
                self._index_hoist_decl(n->body[i], foreign);
            }
            return;
        }
        if isa::<FFIBlockDecl>(d) {
            var n = cast::<FFIBlockDecl>(d);
            for var i: usize = 0; i < n->body.size(); ++i {
                self._index_hoist_decl(n->body[i], true); // ffi block: foreign
            }
            return;
        }

        // ImportDecl, TestDecl, ExtensionDecl, error nodes: nothing to hoist.
        // (Extension members are sema's job; the old indexer's flat-hoisting
        // of extend bodies was pollution, not a feature.)
    }

    /// \brief hoists a type entry, then recurses into its dc_decls with the
    ///        type's name pushed onto the scope path so members land in the
    ///        child trie node (which _wire_scopes later connects to the DC).
    priv fn _index_hoist_type_scope(
        self,
        dc:       *DeclContext,
        name_tok: Token,
        kind:     DisambigKind,
        generic:  bool,
        origin:   SourceRange,
        foreign:  bool
    ) {
        var name_str = self.ctx->get_spelling(name_tok);

        var e = DisambigEntry{};
        e.kind        = kind;
        e.generic     = generic;
        e.is_foreign  = foreign;
        e.extended    = false;
        e.decl.origin = origin;
        self._index_insert(name_str, e);

        if name_str == "" { return; }
        self._index_path.push_back(name_str);
        self._index_hoist_dc_children(dc, foreign);
        self._index_path.pop_back();
    }

    priv fn _index_hoist_dc_children(self, dc: *DeclContext, foreign: bool) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            self._index_hoist_decl(d, foreign);
        }
    }

    //  Index-mode token skippers: dumb bracket-balanced skips, no grammar.

    /// \brief skips to the end of the current decl/statement: a `;`/newline at
    ///        depth 0, or an unmatched `}` (left unconsumed the enclosing
    ///        walker owns it). Brace/paren/bracket contents are crossed whole.
    fn _index_skip_stmt(self) {
        var depth: u32 = 0;
        while !self.is_eof() {
            var k = self.resolve_kind_deep(self._current);
            if depth == 0 {
                if (k == TokenKind::OpSemicolon) || (k == TokenKind::TkNewLine) { return; }
                if k == TokenKind::OpRBrace { return; }
            }
            if (k == TokenKind::OpLBrace) || (k == TokenKind::OpLParen) || (k == TokenKind::OpLSquare) {
                depth += 1;
            } else if (k == TokenKind::OpRBrace) || (k == TokenKind::OpRParen) || (k == TokenKind::OpRSquare) {
                if depth > 0 { depth -= 1; }
            }
            self.advance_raw();
        }
    }

    /// \brief crosses a type-decl head's tail (heritage, impl, requires) to
    ///        the body without parsing it.
    /// \return true with the `{` consumed, or false at a decl end (newline,
    ///         `;`, unmatched `}` left unconsumed) forward declaration.
    fn _index_skip_to_body(self) -> bool {
        var depth: u32 = 0;
        while !self.is_eof() {
            var k = self.resolve_kind_deep(self._current);
            if depth == 0 {
                if k == TokenKind::OpLBrace {
                    self.advance_raw(); // consume `{`
                    return true;
                }
                if (k == TokenKind::OpSemicolon) || (k == TokenKind::TkNewLine) { return false; }
                if k == TokenKind::OpRBrace { return false; }
            }
            if (k == TokenKind::OpLParen) || (k == TokenKind::OpLSquare) {
                depth += 1;
            } else if (k == TokenKind::OpRParen) || (k == TokenKind::OpRSquare) {
                if depth > 0 { depth -= 1; }
            }
            self.advance_raw();
        }
        return false;
    }

    /// \brief precondition: just inside a `{`. Skips to and consumes the
    ///        matching `}`.
    fn _index_skip_block(self) {
        var depth: u32 = 0;
        while !self.is_eof() {
            var k = self.resolve_kind_deep(self._current);
            if k == TokenKind::OpLBrace {
                depth += 1;
            } else if k == TokenKind::OpRBrace {
                if depth == 0 {
                    self.advance_raw(); // consume `}`
                    return;
                }
                depth -= 1;
            }
            self.advance_raw();
        }
    }

    //  Token accessors return 16-byte copies (trivial)

    inline pub fn current(self) -> Token {
        if self._current == &null { return Token(); }
        return *self._current;
    }

    inline pub fn prev(self) -> Token {
        if self._prev == &null { return Token(); }
        return *self._prev;
    }

    inline pub fn peek(self) -> Token {
        if self._peek == &null { return Token(); }
        return *self._peek;
    }

    /// \brief provides direct access to the current token pointer.
    /// \warning not for general use; preferred for diagnostics or macro walking.
    inline pub fn current_ptr(self) -> *Token { return self._current; }
    inline pub fn prev_ptr(self)    -> *Token { return self._prev; }
    inline pub fn peek_ptr(self)    -> *Token { return self._peek; }

    //  Cursor movement

    /// \enum SkipNL
    /// \brief controls newline skipping behavior during cursor movement.
    enum SkipNL derives u8 {
        None,   ///< treat newlines as significant tokens.
        Before, ///< consume newlines before performing the move.
        After,  ///< move once, then consume all subsequent newlines.
        Only,   ///< consume newlines without moving the primary cursor index.
    }

    // --- private helpers ---

    inline fn _skip_nl_fwd(self) {
        while self.current().kind == TokenKind::TkNewLine {
            self._advance();
        }
    }

    inline fn _skip_nl_bwd(self) {
        while self.current().kind == TokenKind::TkNewLine {
            self.retreat();
        }
    }

    // --- public API ---

    /// \brief moves the cursor forward one token.
    inline pub fn advance(self, const skip: SkipNL = SkipNL::None) {
        switch skip {
            case SkipNL::Before { self._skip_nl_fwd(); self._advance(); }
            case SkipNL::After  { self._advance(); self._skip_nl_fwd(); }
            case SkipNL::Only   { self._skip_nl_fwd(); }
            default             { self._advance(); }
        }
        if self.nl_depth > 0 { self._skip_nl_fwd(); }
    }

    /// \brief moves the cursor backward one token.
    inline pub fn retreat(self, const skip: SkipNL = SkipNL::None) {
        switch skip {
            case SkipNL::Before {
                self._skip_nl_bwd();
                self._retreat();
            } case SkipNL::After {
                self._retreat();
                self._skip_nl_bwd();
            } case SkipNL::Only {
                self._skip_nl_bwd();
            } default {
                self._retreat();
            }
        }
    }

    inline fn _advance(self) {
        self._prev = self._current;

        if (self.c_idx + 1) < self.span.size() {
            self.c_idx += 1;
        } else {
            self._current = &null;
            self._peek    = &null;
            return;
        }

        self._sync_cursor();

        if self._no_comment_skip { return; }

        // Comments never rest under the cursor. Stash and step over any we land
        // on so check()/current() always see a real token. _prev stays the
        // pre-comment token so `start | prev().range` joins don't absorb it.
        while (self._current != &null)
           && (self._current->kind == TokenKind::AtComment) {
            self._stash_comment(self._current);
            if (self.c_idx + 1) < self.span.size() {
                self.c_idx += 1;
            } else {
                self._current = &null;
                self._peek    = &null;
                return;
            }
            self._sync_cursor();
        }
    }

    inline fn _retreat(self) {
        if self.c_idx == 0 { return; }

        self._peek    = self._current;
        self.c_idx   -= 1;
        self._current = (self.span.get(self.c_idx));
        self._prev    = (self.span.get(self.c_idx - 1)) if (self.c_idx > 0) else (&null);
    }

    /// \brief syncs `_current` and `_peek` from c_idx.
    /// \note must be called after any direct mutation of `c_idx`.
    inline fn _sync_cursor(self) {
        self._current = (self.span.get(self.c_idx))     if (self.c_idx     < self.span.size()) else (&null);
        self._peek    = (self.span.get(self.c_idx + 1)) if (self.c_idx + 1 < self.span.size()) else (&null);
    }

    inline pub fn ig_kind(self) -> TokenKind {
        if self._current == &null { return TokenKind::TkEof; }
        return self.resolve_kind_deep(self._current);
    }

    inline pub fn ig_peek_kind(self) -> TokenKind {
        if self._peek == &null { return TokenKind::TkEof; }
        return self.resolve_kind_deep(self._peek);
    }

    inline pub fn ig_tok(self) -> Token {
        return self.current(); // resolved copy semantics preserved by callers
    }

    inline pub fn ig_bump(self)    { self.advance(); }
    inline pub fn ig_bump_nl(self) { self.advance(SkipNL::After); }
    inline pub fn ig_eof(self) -> bool { return self.is_eof(); }

    pub fn ig_err(self, r: SourceRange, msg: string, code: DiagID) {
        self.diag->report(code, r.start, msg).first(r).emit();
    }

    //  Token resolution

    /// \brief resolves macro expansion chains to the underlying token identity.
    ///
    /// \details if `tok` is a `TkMacroExpand`, this recursively walks the expansion
    ///          chain to find the original source token kind.
    ///
    /// \return a token copy with the resolved kind and imm, but the original range.
    ///
    /// \details mechanism lives in Token::TokenText::unwrap_expansion; this
    ///          wrapper owns the parser policy: emit I002F on a truncated
    ///          chain and degrade to TkUnknown.
    inline pub fn resolve_deep(self, tok: *Token) -> Token {
        var u = unwrap_expansion(*tok, self.ctx->tcm, self.ctx->ci->pp.max_depth);

        if u.hit_limit {
            self.diag->report(DiagID::I002F, tok->range.start,
                "excessive iterations during token kind resolution, aborting to prevent infinite loop"
            ).first(tok->range)
             .note(DiagID::S063N, tok->range.start, f"token kind resolution chain truncated after {u.depth} levels")
             .emit();
            return Token(tok->range, TokenKind::TkUnknown, 0);
        }

        if u.is_sentinel {
            return Token(tok->range, TokenKind::TkMacroExpand, u.imm);
        }

        return Token(tok->range, u.kind, u.imm);
    }

    /// \brief shorthand for `resolve_deep(tok).kind`.
    inline pub fn resolve_kind_deep(self, tok: *Token) -> TokenKind {
        return self.resolve_deep(tok).kind;
    }

    /// \brief performs a single-step macro resolution.
    inline pub fn resolve_kind_shallow(self, tok: *Token) -> TokenKind {
        if tok == &null {
            return TokenKind::TkUnknown;
        }

        // wrapped non-sentinel token with no table: nothing to resolve with
        if (static_cast::<u32>(tok->kind) == static_cast::<u32>(TokenKind::TkMacroExpand))
        && (tok->imm < static_cast::<u32>(MacroSentinel::Threshold))
        && (self.imm == &null) {
            return TokenKind::TkUnknown;
        }

        return unwrap_expansion(*tok, self.ctx->tcm, 1).kind;
    }

    /// \brief fully resolves a token and automatically skips `AtComment` tokens.
    /// \note will advance the cursor if `AtComment` tokens are encountered.
    inline pub fn resolve_fully(self, tok: *Token) -> Token {
        if tok == &null {
            return Token();
        }

        var resolved = self.resolve_deep(tok);

        if resolved.kind == TokenKind::AtComment {
            self.advance();
            return self.resolve_fully(self._current);
        }

        return resolved;
    }

    //  Token checking unified core + convenience wrappers

    /// \brief internal shared logic for token checking and attribute skipping.
    ///
    /// \param tok            the pointer to the token to check.
    /// \param kind           the expected token kind.
    /// \param advance_on_at  if true, encountering an `AtComment` advances the stream.
    inline fn _resolve_and_check(self, tok: *Token, kind: TokenKind, advance_on_at: bool) -> bool {
        if tok == &null { return false; }

        var resolved = self.resolve_deep(tok);
        var resolved_kind = resolved.kind;

        if resolved_kind == TokenKind::AtComment {
            return false;
        }

        if resolved_kind == TokenKind::TkError {
            // the imm of this token stores the expected kind from recovery
            self.diag->report(DiagID::S063E, tok->range.start,
                f"unexpected token found where '{token_kind_to_readable_string(static_cast::<TokenKind>(resolved.imm))}' expected"
            ).first(tok->range).emit();
            resolved_kind = static_cast::<TokenKind>(resolved.imm);
        }

        return resolved_kind == kind;
    }

    /// \brief checks if the current resolved token matches `kind`.
    inline pub fn check(self, kind: TokenKind) -> bool {
        return self._resolve_and_check(self._current, kind, true);
    }

    /// \brief checks if the current resolved token satisfies a predicate.
    inline pub fn check(self, pre: fn (TokenKind) -> bool) -> bool {
        if self._current == &null { return false; }
        var resolved = self.resolve_deep(self._current);
        var resolved_kind = resolved.kind;

        if resolved_kind == TokenKind::AtComment {
            return false;
        }

        if resolved_kind == TokenKind::TkError {
            if !self.in_recovery {
                self.diag->report(DiagID::S063E, self._current->range.start,
                    f"unexpected token found where '{token_kind_to_readable_string(static_cast::<TokenKind>(resolved.imm))}' expected"
                ).first(self._current->range).emit();
            }
            resolved_kind = static_cast::<TokenKind>(resolved.imm);
        }

        return pre(resolved_kind);
    }

    /// \brief checks the previous token without advancing the stream.
    inline pub fn check_prev(self, kind: TokenKind) -> bool {
        return self._resolve_and_check(self._prev, kind, false);
    }

    /// \brief checks the lookahead token without advancing the stream.
    inline pub fn check_peek(self, kind: TokenKind) -> bool {
        return self._resolve_and_check(self._peek, kind, true);
    }

    /// \brief advances the cursor if the current token matches `kind`.
    inline pub fn match_tok(self, kind: TokenKind) -> bool {
        if self.check(kind) {
            self.advance();
            return true;
        }

        return false;
    }

    /// \brief consumes the expected token or emits a diagnostic and returns a `TkError`.
    ///
    /// \details used for mandatory grammar components. if the token does not match,
    ///          a placeholder error token is returned to allow the parse to continue
    ///          with local recovery.
    inline pub fn expect(self, kind: TokenKind) -> Token {
        var tok = self._current;
        if tok == &null {
            // unexpected EOF emit diag with best available location
            var eof_range = (self._prev->range) if (self._prev != &null) else SourceRange::invalid();
            self.diag->report(DiagID::S063E, eof_range.start,
                f"expected '{token_kind_to_readable_string(kind)}', found end of file"
            ).first(eof_range).emit();

            var err   = Token();
            err.kind  = TokenKind::TkError;
            err.range = eof_range;
            err.imm   = static_cast::<u32>(kind);
            return err;
        }

        var resolved = self.resolve_deep(tok);
        var resolved_kind = resolved.kind;

        if resolved_kind == TokenKind::AtComment {
            self.advance(); // advance skips+stashes; re-expect on the real token
            return self.expect(kind);
        }

        if resolved_kind == TokenKind::TkError {
            // recovery token extract what was expected
            resolved_kind = static_cast::<TokenKind>(resolved.imm);
        }

        if resolved_kind == kind {
            self.advance();
            return resolved;
        }

        self.report_tok(DiagID::S063E, tok,
            f"expected '{token_kind_to_readable_string(kind)}', found '{token_kind_to_readable_string(resolved_kind)}\x27"
        );

        var err     = Token();
        err.kind    = TokenKind::TkError;
        err.range   = tok->range;
        err.imm     = static_cast::<u32>(kind);
        return err;
    }

    //  Macro expansion chain diagnostics

    /// \brief expansion-aware diagnostic emitter for parse errors on a token.
    ///
    /// \details if `tok` was produced by a macro expansion, the primary caret
    ///          is placed on the invocation site (the code the user actually
    ///          wrote) with the message tagged "(in expansion of macro 'name!')",
    ///          and the failing position inside the macro body is attached via
    ///          the expansion-chain notes. otherwise this is exactly
    ///          `report(id, tok->range.start, msg).first(tok->range).emit()`.
    ///
    ///          the macro name needs no PP symbol table: `invoke_range` covers
    ///          the macro-name identifier at the call site, so its source text
    ///          is the name.
    ///
    /// \note repeated errors from the same invocation instance keep the tagged
    ///       primary but drop the note backtrace (see `_last_exp_diag_loc`),
    ///       so one broken expansion doesn't flood the output.
    ///
    /// \note nested case: a token from an inner macro invoked inside another
    ///       macro's body carries an `invoke_range` pointing into the outer
    ///       macro's body rather than the user's file; the chain notes cover
    ///       the remaining hops.
    inline pub fn report_tok(self, id: DiagID, tok: *Token, msg: string) {
        if tok == &null {
            self.diag->report(id, msg).emit();
            return;
        }

        var wrapped = (static_cast::<u32>(tok->kind) == static_cast::<u32>(TokenKind::TkMacroExpand))
            && (tok->imm < static_cast::<u32>(MacroSentinel::Threshold))
            && (self.imm != &null);

        if !wrapped {
            self.diag->report(id, tok->range.start, msg).first(tok->range).emit();
            return;
        }

        var info   = self.imm->get::<Immediate::MacroExpansionInfo>(tok->imm);
        var invoke = info->invoke_range;

        if !invoke.is_valid() {
            // degenerate record; fall back to the def-site range
            self.diag->report(id, tok->range.start, msg).first(tok->range).emit();
            return;
        }

        var name = self.ctx->sm->get_text(invoke);
        var tail: string = " (in a macro expansion)";
        if (name.length() > 0) && (name.length() <= 64) {
            // invoke spans the WHOLE invocation (name, `!`, and any args), so
            // name already reads e.g. "foo!" or "error!(\"yes\")" -- no extra
            // '!' here, or a bare invocation renders as "foo!!" .
            tail = f" (in expansion of macro '{name}')";
        }

        // The primary caret belongs on the DEFINITION site: the offending token
        // as written inside the macro body. That is the one location the
        // invocation-site chain notes can never show, and without it the
        // primary and the chain's innermost note render the same span twice
        // ("^^^^ expected type" then "^^^^ invoked here" on one line).
        //
        // Compiler-synthesized tokens (builtins, poison) carry the invocation
        // range as their own def_range; there is no distinct body site to point
        // at, so those keep the invocation as primary and drop the innermost
        // note instead of repeating it.
        var def     = info->def_range;
        var use_def = def.is_valid() && (def.start.raw() != invoke.start.raw());
        var primary = (def) if (use_def) else (invoke);

        var builder = self.diag->report(id, primary.start, f"{msg}{tail}");
        builder.first(primary);

        if invoke.start.raw() != self._last_exp_diag_loc {
            self._last_exp_diag_loc = invoke.start.raw();
            self.attach_macro_expansion_chain(&builder, tok, !use_def);
        }

        builder.emit();
    }

    /// \brief appends notes to a diagnostic builder showing the macro expansion history.
    ///
    /// \param skip_innermost drops the note for the FIRST record walked (the
    ///        innermost invocation). Set by callers that already placed the
    ///        primary caret on that same invocation range, so the backtrace
    ///        starts one hop out instead of restating the primary.
    inline pub fn attach_macro_expansion_chain(self, builder: *DiagBuilder, tok: *Token, skip_innermost: bool = false) {
        if tok == &null { return; }
        if self.imm == &null { return; }
        if static_cast::<u32>(tok->kind) != static_cast::<u32>(TokenKind::TkMacroExpand) { return; }

        var kind = tok->kind;
        var imm  = tok->imm;
        var depth: u32 = 0;

        while static_cast::<u32>(kind) == static_cast::<u32>(TokenKind::TkMacroExpand) {
            // PP already reported the real error at the invocation site; adding a
            // chain here would double-report. Stay silent.
            if imm == static_cast::<u32>(MacroSentinel::Poison) { return; }

            // todo!/unreachable!/include! etc. carry no expansion info to walk.
            if imm >= static_cast::<u32>(MacroSentinel::Threshold) { return; }

            if depth >= static_cast::<u32>(self.ctx->ci->pp.max_backtrace) {
                builder->note(tok->range.start,
                    f"macro expansion chain truncated after {depth} levels"
                );
                return;
            }

            var info = self.imm->get::<Immediate::MacroExpansionInfo>(imm);
            if info == &null { return; }

            // Primary already sits on the failing token in the macro body; the chain
            // walks OUTWARD through invocation sites toward user code.
            // invoke_range spans the WHOLE invocation (name, `!`, any args), so
            // mname already reads e.g. "foo!" -- no extra '!' in the template.
            var mname = self.ctx->sm->get_text(info->invoke_range);
            if (depth == 0) && skip_innermost {
                0; // caller's primary already sits on this exact range
            } else if (mname.length() > 0) && (mname.length() <= 64) {
                builder->note(info->invoke_range.start,
                    f"in expansion of macro '{mname}' invoked here"
                ).child_first(info->invoke_range);
            } else {
                builder->note(info->invoke_range.start,
                    f"in a macro expansion invoked here (depth {depth})"
                ).child_first(info->invoke_range);
            }

            kind  = info->original_kind;
            imm   = info->original_imm;
            depth += 1;
        }
    }

    //  EOF / first-token queries

    inline pub fn is_eof(self) -> bool {
        return (self._current == &null)
            || (self._current->kind == TokenKind::TkEof);
    }

    /// \brief returns the absolute first token of the stream for indexing.
    inline pub fn first(self) -> *Token {
        if (self.span.size()) > 0 {
            return self.span.get(0);
        }

        return &null;
    }

    //  Annotation consumption

    /// \brief consumes doc-comments, @attributes, and visibility keywords
    ///        before a production into a PendingAnnotations buffer.
    ///
    /// \details attribute args reuse the call-argument grammar verbatim,
    ///          including named args (`@ser(do_sum: true)`); the attr pass
    ///          distinguishes named/positional exactly like call sema does.
    ///          A visibility keyword followed by `{` is NOT consumed it
    ///          is the lead-in of a visibility group decl, owned by DeclParse.
    pub fn consume_leading_annotations(self, out: *PendingAnnotations) {
        out->clear();

        var prev_flag = self._no_comment_skip;
        self._no_comment_skip = true;

        while !self.is_eof() {
            var tok = self._current;
            if tok == &null { break; }

            var resolved = self.resolve_deep(tok);

            if resolved.kind == TokenKind::AtComment {
                out->add(self._comment_kind_from_imm(tok->imm), u32(-1), tok->range);
                self.advance();
                if (self._current != &null) && (self.resolve_kind_shallow(self._current) == TokenKind::TkNewLine) {
                    self.advance_raw(); // stay bound regardless of blank-line gap
                }
                continue;
            }

            // -- @attribute ( args? ) ------------------------------------
            if resolved.kind == TokenKind::OpAt {
                var at_range = tok->range;
                self.advance(); // consume `@`

                if !self.check(TokenKind::LitIdentifier) {
                    self.diag->report(DiagID::S046E, at_range.start,
                        "expected attribute name after '@\x27"
                    ).first(at_range).emit();
                    continue; // `@` consumed; forward progress made
                }

                var name_tok = self.current();
                var name     = self.ctx->hoisted->intern_tok(name_tok);
                self.advance(); // consume identifier

                var end_range = name_tok.range;
                var frozen = create_empty_frozen_list::<*Expr>();

                if self.check(TokenKind::OpLParen) {
                    var lparen = self.current_ptr()->range;
                    self.advance(SkipNL::After); // consume `(`
                    self.nl_push();

                    var args: std::StackBuf::<*Expr, 8>;
                    if !self.check(TokenKind::OpRParen) {
                        self._parse_call_args(&args, lparen);
                    }

                    self.nl_pop();
                    if self.check(TokenKind::OpRParen) {
                        end_range = self.current_ptr()->range;
                        self.advance_raw();
                    } else {
                        self.diag->report(DiagID::S051E, lparen.start,
                            "expected ')' to close attribute argument list"
                        ).first(lparen).emit();
                        // _parse_call_args already synced
                    }

                    frozen.from_buf(args.data(), args.size(), self.ctx);
                }

                out->add_attr(name, at_range | end_range, frozen);
                self._skip_nl_fwd(); // an attribute attaches to the next decl/stmt;
                                     // a newline between `@attr` and its target is
                                     // never significant. without this the top-level
                                     // parse() loop sees the NL as the decl lead.
                continue;
            }

            // -- visibility ------------------------------------------------
            if resolved.kind == TokenKind::KwPub
            || resolved.kind == TokenKind::KwPriv
            || resolved.kind == TokenKind::KwProt {
                // `pub {` is a visibility group, not a modifier leave it.
                if self.check_peek(TokenKind::OpLBrace) { break; }

                var vk = VisibilityKind::Public;
                if resolved.kind == TokenKind::KwPriv {
                    vk = VisibilityKind::Private;
                } else if resolved.kind == TokenKind::KwProt {
                    vk = VisibilityKind::Protected;
                }
                out->set_visibility(vk, tok->range);
                self.advance();
                continue;
            }

            break;
        }

        self._no_comment_skip = prev_flag;
    }

    priv fn _comment_kind_from_imm(self, imm: u32) -> AnnotationKind {
        switch imm {
            case 1  { return AnnotationKind::DocComment;   }
            case 2  { return AnnotationKind::LineComment;  }
            case 3  { return AnnotationKind::BlockComment; }
            default { return AnnotationKind::DocComment;   }
        }
    }

    pub fn _stash_comment(self, tok: *Token) {
        if tok == &null { return; }
        var pc = PendingComment{};
        pc.kind  = self._comment_kind_from_imm(tok->imm);
        pc.range = tok->range;
        self._pending_trailing.push_back(pc);
    }

    priv fn _absorb_trailing_comments(self) {
        while (self._current != &null)
           && (self.resolve_kind_shallow(self._current) == TokenKind::AtComment) {
            self._stash_comment(self._current);
            self._advance();
        }
    }

    inline pub fn _is_terminator_tok(self, t: *Token) -> bool {
        var k = self.resolve_kind_shallow(t);
        return (k == TokenKind::TkNewLine) || (k == TokenKind::OpSemicolon);
    }

    pub fn _attach_trailing(self, n: *Decl) {
        self._absorb_trailing_comments();
        for var i: usize = 0; i < self._pending_trailing.size(); ++i {
            var c = &self._pending_trailing[i];
            n->add_annotation(c->kind, u32(-1), c->range);
        }
        self._pending_trailing.clear();
    }

    pub fn _attach_trailing(self, n: *Stmt) {
        self._absorb_trailing_comments();
        for var i: usize = 0; i < self._pending_trailing.size(); ++i {
            var c = &self._pending_trailing[i];
            n->add_annotation(c->kind, u32(-1), c->range);
        }
        self._pending_trailing.clear();
    }

    /// \brief transfers annotations and visibility to a declaration.
    pub fn apply_annotations_to_decl(self, decl: *Decl, annot: *PendingAnnotations) {
        if annot->empty() { return; }

        for var i: usize = 0; i < annot->entries.size(); ++i {
            var e = &annot->entries[i];
            decl->add_annotation(e->kind, e->name, e->range, e->args);
        }

        if annot->visibility != VisibilityKind::None {
            decl->set_visibility(annot->visibility, annot->vis_range);
        }
    }

    /// \brief transfers annotations to an expression node.
    pub fn apply_annotations_to_node(self, node: *Expr, annot: *PendingAnnotations) {
        if annot->empty() { return; }
        self._diag_vis_on_non_decl(annot, "an expression");
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var e = &annot->entries[i];
            node->add_annotation(e->kind, e->name, e->range, e->args);
        }
    }

    /// \brief reports a diagnostic error if a visibility modifier is applied to a non-declaration.
    priv fn _diag_vis_on_non_decl(self, annot: *PendingAnnotations, what: string) {
        if annot->visibility == VisibilityKind::None {
            return;
        }
        self.diag->report(DiagID::S048E, annot->vis_range.start,
            f"a visibility modifier cannot be applied to {what}"
        ).first(annot->vis_range).emit();
    }

    /// \brief transfers annotations to a statement node.
    pub fn apply_annotations_to_node(self, node: *Stmt, annot: *PendingAnnotations) {
        if annot->empty() { return; }
        self._diag_vis_on_non_decl(annot, "a statement");
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var e = &annot->entries[i];
            node->add_annotation(e->kind, e->name, e->range, e->args);
        }
    }

    /// \brief transfers annotations to a type node.
    pub fn apply_annotations_to_node(self, node: *Type, annot: *PendingAnnotations) {
        if annot->empty() { return; }
        self._diag_vis_on_non_decl(annot, "a type");
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var e = &annot->entries[i];
            node->add_annotation(e->kind, e->name, e->range, e->args);
        }
    }

    //  Type qualifier consumption

    /// \brief consumes leading type qualifier keywords (const, atomic, etc.).
    ///
    /// \details populates the `PendingQuals` accumulator. these are consumed by
    ///          type parsing logic to apply to the constructed `Type` node.
    pub fn consume_leading_quals(self, out: *PendingQuals) {
        out->clear();

        while !self.is_eof() {
            var tok = self._current;
            if tok == &null { break; }

            var resolved = self.resolve_deep(tok);
            var rk = resolved.kind;

            if      rk == TokenKind::KwConst    { out->add(PendingQuals::TypeQualifier::Flags::IsConst,    tok->range); }
            else if rk == TokenKind::KwVolatile { out->add(PendingQuals::TypeQualifier::Flags::IsVolatile, tok->range); }
            else if rk == TokenKind::KwAtomic   { out->add(PendingQuals::TypeQualifier::Flags::IsAtomic,   tok->range); }
            else if rk == TokenKind::KwUnsafe   { out->add(PendingQuals::TypeQualifier::Flags::IsUnsafe,   tok->range); }
            else if rk == TokenKind::KwEval     { out->add(PendingQuals::TypeQualifier::Flags::IsEval,     tok->range); }
            else if rk == TokenKind::KwAsync    { out->add(PendingQuals::TypeQualifier::Flags::IsAsync,    tok->range); }
            else if rk == TokenKind::KwYield    { out->add(PendingQuals::TypeQualifier::Flags::IsYield,    tok->range); }
            else if rk == TokenKind::KwPanic    { out->add(PendingQuals::TypeQualifier::Flags::IsPanic,    tok->range); }
            else { break; }

            self.advance();
        }
    }

    /// \brief applies accumulated qualifiers to a constructed type.
    pub fn apply_quals(self, ty: *Type, quals: *PendingQuals) {
        if quals->empty() { return; }

        ty->flags |= quals->flags;
        for var i: usize = 0; i < quals->spans.size(); ++i {
            ty->spans.push(*(&quals->spans[i]));
        }
    }

    //  Recovery primitives

    /// \brief starts a speculative parse branch.
    /// \return the current cursor index to be used for rollback.
    fn tentative_begin(self) -> usize {
        return self.c_idx;
    }

    /// \brief commits a speculative parse.
    fn tentative_commit(self, state: usize) {
        // no-op currently parse proceeds. State was just a saved cursor.
    }

    /// \brief reverts the cursor to a previously saved state.
    fn tentative_rollback(self, state: usize) {
        self._restore_cursor(state);
    }

    /// \brief restores the token cursor to a previously saved index.
    fn _restore_cursor(self, idx: usize) {
        self.c_idx = idx;
        self._prev = (self.span.get(idx - 1)) if (idx > 0) else (&null);
        self._sync_cursor();
    }

    /// \brief checks and increments the recursion depth counter.
    fn enter_depth(self) -> bool {
        if self.depth >= self.max_depth {
            var cur_range = self.current_ptr()->range;
            self.diag->report(DiagID::S063E, cur_range.start,
                "exceeded maximum nesting depth"
            ).first(cur_range)
             .note(DiagID::S063N, "this is likely caused by excessively deep or infinite recursion while parsing. consider refactoring to reduce nesting depth or changing `--cmax-scope-depth` to a higher value if necessary.")
             .emit();
            return false;
        }

        ++self.depth;
        return true;
    }

    /// \brief decrements the recursion depth counter.
    fn exit_depth(self) {
        if self.depth > 0 { --self.depth; }
    }

    //  Scope primitives

    /// \brief pushes a new lexical scope and associates it with `dc`.
    fn enter_scope(self, kind: ScopeKind, dc: *DeclContext) -> *LexicalScope {
        return self.scope.push(kind, dc);
    }

    /// \brief pops the current lexical scope.
    fn exit_scope(self) {
        self.scope.pop();
    }

    //  Unified lookup (lexical -> hoisted -> global)

    /// \brief performs a full scope-walking name lookup.
    /// \note slower than direct hoisted scope access; intended for non-parser consumers.
    fn lookup(self, name: string) -> ParentRef {
        var local = self.scope.lookup(name);
        if local != &null {
            return ParentRef::from_decl(local->decl);
        }

        var hr = self.ctx->hoisted->lookup(name);
        if hr.found() {
            return ParentRef::from_hoisted(hr.first());
        }

        return ParentRef::none();
    }

    //  Completion hooks

    /// \brief notifies completion consumer of a generic context point.
    fn maybe_complete(self, kind: CompletionContextKind) {
        if self.cc == &null { return; }

        // TODO: only fire if self._current is at/past cc.cursor_loc.
        self.cc->on_completion(kind, self.scope.current_dc());
    }

    /// \brief triggers member completion for dot or arrow access.
    fn maybe_complete_member(self, base: *Expr, is_arrow: bool) {
        if self.cc == &null { return; }
        self.cc->on_member_access(base, is_arrow);
    }

    /// \brief triggers completion for a qualified name (e.g. `namespace::...`).
    fn maybe_complete_qualified(self, scope: *DisambigNode) {
        if self.cc == &null { return; }
        self.cc->on_qualified_name(scope);
    }

    /// \brief triggers signature help/parameter hint completion.
    fn maybe_complete_sighelp(self, callee: *Expr, arg_index: u32) {
        if self.cc == &null { return; }
        self.cc->on_signature_help(callee, arg_index);
    }

    inline pub fn nl_push(self) {
        ++self.nl_depth;
        self._skip_nl_fwd();
    }

    inline pub fn nl_pop(self) {
        if self.nl_depth > 0 { --self.nl_depth; }
    }

    /// \brief raw single-step advance that NEVER applies suppression skipping.
    ///        used to consume closing delimiters so a trailing statement
    ///        terminator after `)`/`]`/`}`/`>` survives for the caller.
    inline pub fn advance_raw(self) {
        self._advance();
    }

    /// \brief resolved kind of the next non-newline token, without moving.
    inline pub fn peek_past_nl_kind(self) -> TokenKind {
        var i = self.c_idx;
        while i < self.span.size() {
            var t = self.span.get(i);
            var k = self.resolve_kind_shallow(t);
            if k != TokenKind::TkNewLine { return k; }
            ++i;
        }
        return TokenKind::TkEof;
    }

    ///
    /// Sentinel checks
    ///
    
    fn <T> fatal_ptr(self) -> *T {
        inline "c++" {
            auto base = reinterpret_cast<uint8_t*>(&this->_fatal_sentinels);
            if constexpr (libcxx::is_same_v<T, Type>) {
                return reinterpret_cast<T*>(base + 0);
            } else if constexpr (libcxx::is_same_v<T, Expr>) {
                return reinterpret_cast<T*>(base + 1);
            } else if constexpr (libcxx::is_same_v<T, Stmt>) {
                 return reinterpret_cast<T*>(base + 2);
            } else if constexpr (libcxx::is_same_v<T, Decl>) {
                 return reinterpret_cast<T*>(base + 3);
            } else {
                static_assert(false, "unsupported sentinel type");
                return nullptr;
            }
        }
    }
    
    fn <T> is_fatal(self, ptr: *T) -> bool {
        inline "c++" {
            auto base = reinterpret_cast<uint8_t*>(&this->_fatal_sentinels);
            if constexpr (libcxx::is_same_v<T, Type>) {
                return reinterpret_cast<T*>(base + 0) == ptr;
            } else if constexpr (libcxx::is_same_v<T, Expr>) {
                return reinterpret_cast<T*>(base + 1) == ptr;
            } else if constexpr (libcxx::is_same_v<T, Stmt>) {
                return reinterpret_cast<T*>(base + 2) == ptr;
            } else if constexpr (libcxx::is_same_v<T, Decl>) {
                return reinterpret_cast<T*>(base + 3) == ptr;
            } else {
                static_assert(false, "unsupported sentinel type");
                return false;
            }
        }
    }
}