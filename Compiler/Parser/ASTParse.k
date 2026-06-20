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
import AST::Mixin::TypeQual::*;
import AST::Mixin::Annotation::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import Token::TokenSpan::*;
import Token::Token::*;
import Diagnostic::Engine::*;

import Parser::LexicalScope::*;
import Parser::ExprParse::*;
import Parser::StmtParse::*;
import Parser::DeclParse::*;
import Parser::TypeParse::*;
import Parser::PatternParse::*;

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
          PatternParse::<ASTParse> {
    inline "c++" {
        using PendingAnnotations = PendingAnnotations;
        using PendingQuals = PendingQuals;
    }

    // --- Context handles ----------------------------------------------------
    pub var ctx:   obs::<ASTContext>;           ///< owning context for allocations.
    pub var diag:  obs::<DiagEngine>;           ///< sink for parse errors and warnings.
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
    pub var in_recovery:       bool = false; ///< true if parser is currently skipping to a SyncSet.
    

    class TentativeGuard {
        priv var _parser:    obs::<ASTParse>;
        priv var _cursor:    usize;
        priv var _nl_depth:  u32;
        priv var _committed: bool;

        fn TentativeGuard(self, p: *ASTParse) {
            self._parser    = p;
            self._cursor    = p->c_idx;
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

        fn StreamGuard(self, p: *ASTParse, span: TokenSpan) {
            self._p        = p;
            self._span     = p->span;
            self._c_idx    = p->c_idx;
            self._prev     = p->_prev;
            self._current  = p->_current;
            self._peek     = p->_peek;
            self._nl_depth = p->nl_depth;

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
        }
    }

    /// \brief initializes a parser for a specific context and token stream.
    ///
    /// \param ctx      the ASTContext which provides tokens and memory arenas.
    /// \param cc       optional completion consumer for IDE features.
    /// \param g_scope  the global scope used for hoisting top-level declarations.
    fn ASTParse(self, ctx: *ASTContext, cc: *CodeCompleteConsumer, g_scope: *GlobalHoistedScope) {
        self.ctx   = ctx;
        self.diag  = ctx->diags;
        self.imm   = ctx->get_imm_table();
        self.cc    = cc;
        self.span  = ctx->get_tokens();
        self.tu    = ctx->alloc_init::<TranslationUnit>(ctx, ctx->fid, ctx->hoisted, g_scope);
        self.scope.set_ctx(ctx);

        self._prev    = &null;
        self._current = (self.span.get(0)) if (self.span.size() > 0) else (&null);
        self._peek    = (self.span.get(1)) if (self.span.size() > 1) else (&null);

        self.max_depth        = ctx->ci->frontend.max_scope_depth;
        self.error_count_base = self.diag->error_count();
    }

    /// \brief executes the full parse of the token stream.
    ///
    /// \details top-level loop. Annotations are consumed ONCE per item and
    ///          stamped on the routed node. Decl lead-ins go to parse_decl and
    ///          land in tu->dc_decls (source order) AND program->items;
    ///          everything else parses as a statement (script-style top level
    ///          is legal). var/const always route through the stmt path it
    ///          owns the plain-decl vs destructuring split. After the loop, a
    ///          wiring pass connects each named DeclContext to its hoisted
    ///          ScopeNode so sema lookup_local works.
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

            if self.check(TokenKind::TkNewLine) || self.check(TokenKind::OpSemicolon) {
                self.advance();
                continue;
            }

            var annot: PendingAnnotations;
            self.consume_leading_annotations(&annot);
            if self.is_eof() { break; }

            var k = self.resolve_kind_deep(self._current);

            var route_decl = self._starts_decl_kw(k);
            if (k == TokenKind::KwVar) || (k == TokenKind::KwConst) {
                route_decl = false; // stmt path owns destructuring split
            }
            if (k == TokenKind::KwEval) && (!self.check_peek(TokenKind::OpLBrace)) {
                route_decl = false; // `eval {` is a decl block; `eval for/if/var`
                                    // are statements (stmt dispatcher owns them).
            }

            if route_decl {
                var d = self.parse_decl();
                if d == &null { break; }
                if self.is_fatal::<Decl>(d) { break; }

                if isa::<VisibilityGroupDecl>(d) {
                    var annot_has_any: bool = !annot.empty();
                    if annot_has_any {
                        var first_span: SourceRange = annot.entries.front().range;

                        var b = self.diag->report(DiagID::S048E, first_span.start,
                            "annotations and attributes cannot be applied to a visibility group; "
                            "apply them to individual members instead"
                        );

                        b.first(first_span);

                        // one note per additional annotation: each gets its own
                        // caret on its own line, instead of one fused multi-line span.
                        for var i: usize = 1; i < annot.entries.size(); ++i {
                            var e = &annot.entries[i];
                            b.note(DiagID::S048N, e->range.start,
                                "this annotation also cannot apply to the group"
                            ).first(e->range);
                        }

                        b.emit();
                    }
                    // do NOT stamp annot onto the group
                } else {
                    self.apply_annotations_to_decl(d, &annot);
                }

                self.tu->add_decl(d);
                program->add_item(TopLevelItem::from_decl(d));
            } else {
                var s = self.parse_stmt();
                if s == &null { break; }
                if self.is_fatal::<Stmt>(s) { break; }

                if isa::<DeclStmt>(s) {
                    var ds = cast::<DeclStmt>(s);
                    if ds->decl != &null {
                        self.apply_annotations_to_decl(ds->decl, &annot);
                    }
                } else {
                    self.apply_annotations_to_node(s, &annot);
                }
                program->add_item(TopLevelItem::from_stmt(s));
            }

            while self.check(TokenKind::TkNewLine) || self.check(TokenKind::OpSemicolon) {
                self.advance();
            }
        }

        self.scope.pop();
        self.tu->error_count = self.diag->error_count() - self.error_count_base;
        self.tu->warn_count  = self.diag->warn_count()  - warn_count_base;

        self._wire_scopes();
        return self.tu;
    }

    /// \brief routes parsing to specific top-level declaration logic.
    pub fn dispatch_top_level(self) -> TopLevelItem {
        self.advance();
        return TopLevelItem::from_decl(&null);
    }

    //  Hoisted-scope wiring (post-parse)

    /// \brief connects each named DeclContext in the tree to its ScopeNode in
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

    priv fn _wire_dc_children(self, dc: *DeclContext, node: *ScopeNode) {
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

            var text  = TokenText::from_token(name_tok, self.ctx);
            var child = node->get_child(self.ctx->hoisted->intern(text.text));
            if child == &null { continue; }

            child_dc->set_scope(child);
            self._wire_dc_children(child_dc, child);
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

    //  Token resolution

    /// \brief resolves macro expansion chains to the underlying token identity.
    ///
    /// \details if `tok` is a `TkMacroExpand`, this recursively walks the expansion
    ///          chain to find the original source token kind.
    ///
    /// \return a token copy with the resolved kind and imm, but the original range.
    inline pub fn resolve_deep(self, tok: *Token) -> Token {
        var kind = tok->kind;
        var imm  = tok->imm;
        var iter: u32 = 0;

        while static_cast::<u32>(kind) == static_cast::<u32>(TokenKind::TkMacroExpand) {
            if (iter) >= (self.ctx->ci->pp.max_depth) {
                self.diag->report(DiagID::I002F, tok->range.start,
                    "excessive iterations during AST indexing token kind resolution, aborting to prevent infinite loop"
                ).first(tok->range)
                 .note(DiagID::S063N, tok->range.start, f"token kind resolution chain truncated after {iter} levels")
                 .emit();
                return Token(tok->range, TokenKind::TkUnknown, 0);
            }

            if imm >= static_cast::<u32>(MacroSentinel::Threshold) {
                return Token(tok->range, TokenKind::TkMacroExpand, imm);
            }

            var info = self.imm->get::<Immediate::MacroExpansionInfo>(imm);
            kind     = info->original_kind;
            imm      = info->original_imm;
            iter    += 1;
        }

        return Token(tok->range, kind, imm);
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

        if static_cast::<u32>(tok->kind) != static_cast::<u32>(TokenKind::TkMacroExpand) {
            return tok->kind;
        }

        if tok->imm >= static_cast::<u32>(MacroSentinel::Threshold) {
            return TokenKind::TkMacroExpand;
        }

        if self.imm == &null {
            return TokenKind::TkUnknown;
        }

        var info = self.imm->get::<Immediate::MacroExpansionInfo>(tok->imm);
        return info->original_kind;
    }

    /// \brief fully resolves a token and automatically skips `AtComment` tokens.
    /// \note will advance the cursor if `AtComment` tokens are encountered.
    inline pub fn resolve_fully(self, tok: *Token) -> Token {
        if tok == &null {
            return Token();
        }

        var resolved = self.resolve_deep(tok);

        if resolved.kind == TokenKind::AtComment {
            // we should be accumulating these into attributes, but for now
            // just brush them off so they don't interfere with parsing
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
            // we should be accumulating these into attributes, but for now
            // just brush them off so they don't interfere with parsing
            if advance_on_at { self.advance(); }
            return self.check(kind);
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

        while resolved_kind == TokenKind::AtComment {
            // we should be accumulating these into attributes, but for now
            // just brush them off so they don't interfere with parsing
            self.advance();
            return self.check(pre);
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
            // brush off
            self.advance();
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

        self.diag->report(DiagID::S063E, tok->range.start,
            f"expected '{token_kind_to_readable_string(kind)}', found '{token_kind_to_readable_string(resolved_kind)}\x27"
        ).first(tok->range).emit();

        if tok->kind == TokenKind::TkMacroExpand {
            var builder = self.diag->report(DiagID::S063N, tok->range.start,
                f"expected '{token_kind_to_readable_string(kind)}', found '{token_kind_to_readable_string(resolved_kind)}\x27"
            );
            builder.first(tok->range);
            self.attach_macro_expansion_chain(&builder, tok);
            builder.emit();
        }

        var err     = Token();
        err.kind    = TokenKind::TkError;
        err.range   = tok->range;
        err.imm     = static_cast::<u32>(kind);
        return err;
    }

    //  Macro expansion chain diagnostics

    /// \brief appends notes to a diagnostic builder showing the macro expansion history.
    inline pub fn attach_macro_expansion_chain(self, builder: *DiagBuilder, tok: *Token) {
        if tok == &null { return; }
        if static_cast::<u32>(tok->kind) != static_cast::<u32>(TokenKind::TkMacroExpand) { return; }

        var kind = tok->kind;
        var imm  = tok->imm;
        var depth: u32 = 0;

        while static_cast::<u32>(kind) == static_cast::<u32>(TokenKind::TkMacroExpand) {
            if depth >= static_cast::<u32>(self.ctx->ci->pp.max_backtrace) {
                builder->note(DiagID::S063N, tok->range.start,
                    f"macro expansion chain truncated after {depth} levels"
                );
                return;
            }

            if imm >= static_cast::<u32>(MacroSentinel::Threshold) {
                builder->note(DiagID::S063N, tok->range.start,
                    f"expanded from compiler-internal macro sentinel"
                );
                return;
            }

            if self.imm == &null { return; }

            var info = self.imm->get::<Immediate::MacroExpansionInfo>(imm);

            builder->note(DiagID::S063N, info->def_range.start,
                f"expanded from macro defined here (depth {depth})"
            );

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

        while !self.is_eof() {
            var tok = self._current;
            if tok == &null { break; }

            var resolved = self.resolve_deep(tok);

            if resolved.kind == TokenKind::AtComment {
                out->add(AnnotationKind::DocComment, InternedStr::invalid(), tok->range);
                self.advance();
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

                var name_tok  = self.current();
                var name_text = TokenText::from_token(name_tok, self.ctx);
                var name      = self.ctx->hoisted->intern(name_text.text);
                self.advance(); // consume identifier

                var end_range = name_tok.range;
                inline "c++" {
                    FrozenList<Expr*> frozen = FrozenList<Expr*>::empty();
                }

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

                var vk = PendingAnnotations::VisAnnotation::VisibilityKind::Public;
                if resolved.kind == TokenKind::KwPriv {
                    vk = PendingAnnotations::VisAnnotation::VisibilityKind::Private;
                } else if resolved.kind == TokenKind::KwProt {
                    vk = PendingAnnotations::VisAnnotation::VisibilityKind::Protected;
                }
                out->set_visibility(vk, tok->range);
                self.advance();
                continue;
            }

            break;
        }
    }

    /// \brief transfers annotations and visibility to a declaration.
    pub fn apply_annotations_to_decl(self, decl: *Decl, annot: *PendingAnnotations) {
        if annot->empty() { return; }

        for var i: usize = 0; i < annot->entries.size(); ++i {
            var e = &annot->entries[i];
            decl->add_annotation(e->kind, e->name, e->range, e->args);
        }

        if annot->visibility != PendingAnnotations::VisAnnotation::VisibilityKind::None {
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
        if annot->visibility == PendingAnnotations::VisAnnotation::VisibilityKind::None {
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

    /// \brief consumes tokens until a member of `set` or EOF is encountered.
    fn skip_until(self, set: SyncSet) -> SyncSet {
        // TODO
        return SyncSet::None;
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
    fn maybe_complete_qualified(self, scope: *ScopeNode) {
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