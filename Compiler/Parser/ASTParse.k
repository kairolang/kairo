/// --- The Kairo Project ---------------------------- Parser/ASTParse.k --- ///
///
///   The parser class: owns parser state and derives the five sub-parsers.
///
///   It owns all parser state: token cursor, scope stack, recovery state,
///   completion consumer, diagnostics handle, AST context.
///
///   Produces a TranslationUnit from a fully-indexed ASTContext.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::CodeCompleteConsumer::{
    CodeCompleteConsumer,
    CompletionContextKind,
}
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::DisambigTable::{
    DisambigEntry,
    DisambigKind,
    DisambigNode,
    DisambigTable,
}
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::SymbolTable::{
    DeclName,
    SymbolTable,
}
import AST::Context::TranslationUnit::{
    ParentRef,
    TranslationUnit,
}
import AST::LangItems::{
    LangAttrs,
    LowerTargets,
}
import AST::Mixin::Annotation::{
    AnnotationEntry,
    AnnotationKind,
    VisibilityKind,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    is_recovery,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,    EnumDecl,      EvalBlockDecl, ExtensionDecl,      FFIBlockDecl,        FieldDecl,
    FunctionDecl, InterfaceDecl, ModuleDecl,    ProcedureMacroDecl, StructDecl,          TestDecl,
    TransferKind, TypeAliasDecl, UnionDecl,     VariableDecl,       VisibilityGroupDecl,
}
import AST::Node::PrimaryExpressions::{
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Program::{
    Program,
    TopLevelItem,
    TopLevelKind,
}
import AST::Node::Statements::{
    CompoundStmt,
    ConditionalStmt,
    DeclStmt,
    DestructuringDeclStmt,
    ExpressionStmt,
}
import AST::ParamMode::ParamMode
import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::Code::{
    DiagCode,
    diag_from_code,
}
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::Engine::diag_policy_key
import Diagnostic::Registry::DiagID
import Diagnostic::Severity::DiagSeverity
import Driver::TUStage::TUStage
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Location::SourceRange::SourceRange
import Macro::Sentinel::MacroSentinel
import Parser::DeclParse::DeclParse
import Parser::ExprParse::ExprParse
import Parser::LexicalScope::{
    LexicalScope,
    ScopeKind,
    ScopeStack,
}
import Parser::LexicalScope::{
    PendingAnnotations as PendingAnnotationsDecl,
    PendingQuals as PendingQualsDecl,
}
import Parser::PatternParse::PatternParse
import Parser::Shared::ImportGrammar::ImportGrammar
import Parser::Shared::MacroHeaderGrammar::MacroHeaderGrammar
import Parser::StmtParse::StmtParse
import Parser::TypeParse::TypeParse
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    token_kind_to_readable_string,
}
import Token::TokenSpan::TokenSpan
import Token::TokenText::unwrap_expansion

pub struct PendingComment {
    var kind:  AnnotationKind = AnnotationKind::DocComment
    var range: SourceRange    = SourceRange::invalid()
}

/// \struct ParserCheckpoint
/// \brief everything a speculative parse can move, taken by
///        ASTParse::checkpoint() and applied by ASTParse::rewind().
///
/// \details What a rollback restores is deliberately narrower than what is
///          recorded:
///
///          - restored by every rewind: the cursor and the `>>` debt (a debt
///            run up inside the speculation belongs to tokens being given
///            back);
///          - restored by TentativeGuard only: nl_depth and the pending
///            comments (the bare tentative_begin/rollback pairs never did,
///            and their callers' newline handling depends on it);
///          - never restored, only checked (and recorded only in a debug
///            build): the depth counters and _no_comment_skip. Every enter/exit pair inside a speculation is
///            balanced, so they must come back on their own; a debug build
///            asserts that they did. A depth cap that fired inside is sticky
///            on purpose (_depth_aborted) and is not rewound either.
pub struct ParserCheckpoint {
    pub var cursor:          usize = 0
    pub var nl_depth:        u32   = 0
    pub var comments:        usize = 0
    pub var angle_debt:      u8    = 0
    pub var depth:           u32   = 0
    pub var expr_depth:      u32   = 0
    pub var ffi_decl_depth:  u32   = 0
    pub var no_comment_skip: bool  = false
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
pub class ASTParse
  derives ExprParse<ASTParse>,
          StmtParse<ASTParse>,
          DeclParse<ASTParse>,
          TypeParse<ASTParse>,
          PatternParse<ASTParse>,
          ImportGrammar<ASTParse>,
          MacroHeaderGrammar<ASTParse> {
    type PendingAnnotations = PendingAnnotationsDecl
    type PendingQuals = PendingQualsDecl

    /// # Context handles

    pub var ctx:   unsafe *ASTContext           ///< owning context for allocations.
    pub var diag:  *BufferedDiagSink            ///< sink for parse errors and warnings.
    pub var scope: ScopeStack                   ///< active lexical scope hierarchy.
    pub var cc:    unsafe *CodeCompleteConsumer ///< null during standard batch compilation.

    /// # Token state

    pub var span:  TokenSpan                  ///< the full token stream from the lexer.
    pub var c_idx: usize                  = 0 ///< index of the `_current` token in `span`.
    pub var imm:   unsafe *ImmediateTable     ///< table for resolving macro expansion metadata.

    // Source-of-truth pointers into span private
    var _prev:    unsafe *Token = &null ///< the token immediately preceding the cursor.
    var _current: unsafe *Token = &null ///< the token at the current cursor position.
    var _peek:    unsafe *Token = &null ///< the token one position ahead of the cursor.

    /// # Output

    pub var tu: unsafe *TranslationUnit ///< the TU being populated by this parse.

    /// # Recovery state

    pub var _fatal_sentinels: u32 = 0 ///< special marker type used to signal unrecoverable errors during type parsing.
    pub var depth:            u32 = 0 ///< current recursion depth.
    /// >0 while parsing the declaration(s) an `ffi "..."` prefix or block
    /// applies to: there a bodiless `struct S` / `union U` is a foreign
    /// forward declaration (it names the header's tag, Compiler/Spec/Interop.md#ffi-imports)
    /// instead of a missing body.
    pub var ffi_decl_depth: u32  = 0
    pub var max_depth:      u32  = 256 ///< limit to prevent stack overflow on malicious input (--cmax-scope-depth).
    pub var expr_depth:     u32  = 0 ///< current expression recursion depth.
    pub var max_expr_depth: u32  = 512 ///< expression nesting cap (--cmax-expr-depth); separate from max_depth so each flag governs what it names.
    pub var _depth_aborted: bool = false ///< a depth cap fired; is_eof() now reports true and later checks stay silent.
    /// The closer a failed operand reported and left in place (ExprParse's
    /// no-match path). A statement loop that then stands on it skips it
    /// without parsing it again, which would only report the same
    /// "expected expression" a second time. Recorded only when the report
    /// was really emitted (not under a TentativeGuard's suppression), so
    /// skipping the token can never hide the only report of it.
    pub var _kept_closer: unsafe *Token = &null
    /// Set by _parse_top_decl / _parse_top_stmt when the item they parsed is
    /// a recovery node: with no error reported for it, the top-level loop
    /// reports one.
    pub var _top_item_failed: bool = false
    /// TypeParse::parse_bound_type: a rooted type path `::m::I` is legal
    ///.
    pub var rooted_type_ok:     bool                             = false
    pub var error_count_base:   u32                              = 0 ///< error count recorded at parse start.
    pub var nl_depth:           u32                              = 0 ///< if non-zero, the parser ignores newlines.
    pub var _no_comment_skip:   bool                             = false
    pub var _pending_trailing:  cxx::std::vector<PendingComment>
    pub var _last_exp_diag_loc: u32                              = 0 ///< raw loc of the last expansion-site diagnostic;
    ///  collapses repeated backtraces for one invocation.

    /// # Index mode (merged indexer)

    /// \enum ParseMode
    /// \brief selects between the full parse and the table-building index pass.
    ///
    /// \details Index mode drives the SAME decl grammar as Full, but decl
    ///          productions cut after their heads (name, generics, spec
    ///          pattern) and token-skip signatures/bodies, so nothing heavy is
    ///          materialized and no expression parsing runs against the
    ///          half-built DisambigTable. Statement positions are never walked
    ///          into, so no phantom-global hoists arise from them.
    pub enum ParseMode derives u8 {
        Full,  ///< normal parse: builds the AST, emits diagnostics.
        Index, ///< pre-pass: populates ctx->hoisted, suppresses diagnostics.
    }

    pub var mode: Self::ParseMode = Self::ParseMode::Full ///< see ParseMode.
    /// --check-past-syntax-errors: function block bodies are watched for
    /// errors kept inside their braces (DeclParse::_parse_fn_body). Off, and
    /// nothing recorded, in every other run.
    pub var recover_bodies:     bool = false
    pub var recover_body_depth: u32  = 0
    /// The last closure signature's `|...|` / `||`, as written (invalid when
    /// it had none): DeclParse::_parse_closure_sig sets it and
    /// ExprParse::_parse_closure_expr moves it onto the node, before the body
    /// (where a nested closure would overwrite it) is parsed.
    pub var closure_cap_range: SourceRange = SourceRange::invalid()
    /// The last closure signature's declared `panic(E1, E2)` set, empty when
    /// it had none: handed over the same way as closure_cap_range.
    pub var closure_panic_set: FrozenList<unsafe *Type>
    /// The same signature's `panic` specifier (set included) and its
    /// parameter list's `)`, invalid when absent: fix-it anchors.
    pub var closure_panic_range: SourceRange = SourceRange::invalid()
    pub var closure_params_end:  SourceRange = SourceRange::invalid()
    /// the module whose body holds the `eval if` / `eval for` being parsed
    /// (DeclParse::_parse_eval_stmt_decl). Declarations in its branches are
    /// branch-local, so StmtParse::_attach_local_decl must not add them to
    /// this context as it would for a local in a module-scope block.
    pub var eval_branch_dc: *DeclContext? = &null

    /// True in normal AST-building mode. Used by mixin parsers (which cannot
    /// name the nested ParseMode enum directly) to gate Full-only behavior such
    /// as the import-edge generic disambiguation fallback.
    pub fn is_full_mode(self) -> bool {
        return self.mode == Self::ParseMode::Full
    }

    var _index_path: cxx::std::vector<string> ///< named-scope path for hoisted inserts (index mode only).
    var _sym_tables: cxx::std::vector<unsafe *SymbolTable> ///< tables created by _build_symbols; frozen at parse exit.


    /// \brief a speculative parse with its diagnostics suppressed, rolled
    ///        back on scope exit unless committed. Rolls back the checkpoint
    ///        (rewind) and also nl_depth and the pending comments.
    class TentativeGuard {
        priv var _parser:    *ASTParse
        priv var _cp:        ParserCheckpoint
        priv var _committed: bool

        fn TentativeGuard(self, p: *ASTParse) {
            self._parser    = p
            self._cp        = p->checkpoint()
            self._committed = false
            p->diag->push_suppress()
        }

        /// \brief commits the speculative parse: cursor is kept, diagnostics
        ///        emitted after this point are no longer suppressed.
        fn commit(self) {
            self._committed = true
        }

        // Not transferable: the destructor rewinds the parser, and a copy would rewind it twice.
        @copy fn TentativeGuard(self, const other: Self) = delete

        fn op finally (self) {
            self._parser->diag->pop_suppress()
            if !self._committed {
                self._parser->rewind(self._cp)
                self._parser->nl_depth = self._cp.nl_depth
                while self._parser->_pending_trailing.size() > self._cp.comments {
                    self._parser->_pending_trailing.pop_back()
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
        priv var _p:              *ASTParse
        priv var _span:           TokenSpan
        priv var _c_idx:          usize
        priv var _prev:           unsafe *Token
        priv var _current:        unsafe *Token
        priv var _peek:           unsafe *Token
        priv var _nl_depth:       u32
        priv var _saved_comments: usize

        fn StreamGuard(self, p: *ASTParse, span: TokenSpan) {
            self._p              = p
            self._span           = p->span
            self._c_idx          = p->c_idx
            self._prev           = p->_prev
            self._current        = p->_current
            self._peek           = p->_peek
            self._nl_depth       = p->nl_depth
            self._saved_comments = p->_pending_trailing.size()

            p->span     = span
            p->c_idx    = 0
            p->nl_depth = 0
            p->_prev    = &null
            p->_current = if (p->span.size() > 0) => (p->span.get(0)) else => &null
            p->_peek = if (p->span.size() > 1) => (p->span.get(1)) else => &null
        }

        // Not transferable: the destructor restores the parser stream, and a copy would restore it twice.
        @copy fn StreamGuard(self, const other: Self) = delete

        fn op finally (self) {
            self._p->span     = self._span
            self._p->c_idx    = self._c_idx
            self._p->_prev    = self._prev
            self._p->_current = self._current
            self._p->_peek    = self._peek
            self._p->nl_depth = self._nl_depth
            while self._p->_pending_trailing.size() > self._saved_comments {
                self._p->_pending_trailing.pop_back()
            }
        }
    }

    /// \brief initializes a parser for a specific context and token stream.
    ///
    /// \param ctx      the ASTContext which provides tokens and memory arenas.
    /// \param cc       optional completion consumer for IDE features.
    /// \param g_scope  the global scope used for hoisting top-level declarations.
    /// \param mode     Full (default) or Index; Index allocates ctx->hoisted
    ///                 and expects index() to be called instead of parse().
    pub fn ASTParse(self,
                    ctx:     unsafe *ASTContext,
                    cc:      unsafe *CodeCompleteConsumer,
                    g_scope: unsafe *GlobalDisambigTable,
                    mode:    Self::ParseMode = Self::ParseMode::Full) {
        self.ctx  = ctx
        self.diag = &ctx->diag_sink
        self.imm  = ctx->get_imm_table()
        self.cc   = cc
        self.span = ctx->get_tokens()

        self.mode = mode
        self.recover_bodies = mode == Self::ParseMode::Full
            && ctx->ci != &null
            && ctx->ci->frontend.check_past_syntax
        if mode == Self::ParseMode::Index && ctx->hoisted == &null {
            // the index pass owns table allocation; must precede TU creation
            // below since the TU constructor captures ctx->hoisted.
            ctx->hoisted = ctx->alloc_init_index_cleanup<DisambigTable>(ctx)
        }

        var unsafe *existing = ctx->tu
        if existing != &null {
            self.tu = existing // PP-built TU: imports/macros already in it
        } else {
            // ParseSource / test-harness path: no PP ran
            self.tu = ctx->alloc_init_pp<TranslationUnit>(
                ctx,
                ctx->fid,
                ctx->hoisted,
                g_scope,
            )

            ctx->tu = self.tu
        }

        self.scope.set_ctx(ctx)
        self._pending_trailing.reserve(4)

        self._prev = &null
        self._current = if (self.span.size() > 0) => (self.span.get(0)) else => &null
        self._peek = if (self.span.size() > 1) => (self.span.get(1)) else => &null

        self.max_depth        = ((ctx->ci->frontend.max_scope_depth) as u32)
        self.max_expr_depth   = ((ctx->ci->frontend.max_expr_depth) as u32)
        self.error_count_base = self.diag->error_count()
    }

    /// \brief executes the full parse of the token stream.
    ///
    /// \details top-level loop. Annotations are consumed ONCE per item and
    ///          stamped on the routed node. Routing: decl lead-ins go to
    ///          _parse_top_decl, everything else to _parse_top_stmt. See
    ///          _routes_to_decl for the var/const/eval/fn carve-outs.
    ///          After the loop, _wire_scopes connects named DeclContexts to
    ///          their hoisted DisambigNodes so sema lookup_local works.
    pub fn parse(self) -> unsafe *TranslationUnit {
        // A reparse of a PP-built TU (release_from(Parsing), then parse_one)
        // reuses it: its decl list still names the previous parse's decls,
        // which died with ast_alloc. Its storage is the TU's (pp_alloc, GH
        // #71), so clearing it is safe, and this parse refills it.
        self.tu->dc_decls.clear()
        self._kept_closer = &null // a token of an earlier parse's stream

        self.tu->advance(TUStage::Parsing)
        var unsafe *program = self.ctx->alloc_init<Program>(
            self.ctx->fid,
            self.ctx,
        )

        self.tu->program = program
        self.scope.push(ScopeKind::Block, self.tu)

        var warn_count_base = self.diag->warn_count()

        var iterations: usize = 0
        var max_iter          = self.span.size() << 2

        while !self.is_eof() {
            ++iterations
            if iterations > max_iter {
                break
            }

            if self._is_terminator_tok(self._current) {
                self.advance_raw()
                continue
            }

            var annot: Self::PendingAnnotations
            self.consume_leading_annotations(unsafe &annot, true, true)
            if self.is_eof() {
                break
            }

            // `@set_global_allocator(A)` is a property of the program, not an
            // attribute of what follows it: taken here, before the routing
            // below could stamp it on the next declaration.
            if self._global_alloc_ahead() {
                self._parse_global_allocator(program, unsafe &annot)
                while self._is_terminator_tok(self._current) {
                    self.advance_raw()
                }

                continue
            }

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
                self.advance_raw()
                if self.is_eof() {
                    break
                }
            }

            if self.is_eof() {
                break
            }

            // a closer a failed operand already reported: nothing at the top
            // level owns it, so it is skipped here, not parsed a second time
            if self._current == self._kept_closer {
                self.advance()
                continue
            }

            var k = self.resolve_kind_deep(self._current)

            // The bare `module a::b` pin is a FILE property, not a decl: it is
            // intercepted here so it never reaches parse_decl, which would
            // build a ModuleDecl, bind `a` in this file's table and reopen a
            // namespace -- a meaning the pin must not have outside the
            // resolver (the pin names the library, the resolver reads it).
            if k == TokenKind::KwModule && self._is_module_pin() {
                self._parse_module_pin()
                while self._is_terminator_tok(self._current) {
                    self.advance_raw()
                }

                continue
            }

            var before      = self.c_idx
            var errs_before = self.diag->error_count()
            self._top_item_failed = false
            var ok = if self._routes_to_decl(k) => (self._parse_top_decl(
                         program,
                         unsafe &annot,
                         k,
                     ))
                     else => self._parse_top_stmt(program, unsafe &annot)

            // An item that failed with no error said about it -- a null from
            // the production, or a recovery node -- dropped the rest of the
            // file silently when the loop stopped, or kept an <error>
            // node nobody reported. Whatever path got here, the loop says so
            // once and carries on from the next line.
            if (!ok || self._top_item_failed) && self.diag->error_count() == errs_before {
                self._report_unparsed_item(before)
                if !ok {
                    self._skip_failed_item(before)
                    continue
                }
            }

            if !ok {
                break
            }

            while self._is_terminator_tok(self._current) {
                self.advance_raw()
            }

            // A stray closer at the top level (`)`, `]`, `}`) is reported by
            // the expression parser and left in place, since inside a
            // construct it belongs to something around the failed operand;
            // here nothing owns it, so the loop skips it.
            if self.c_idx == before && !self.is_eof() {
                self.advance()
            }
        }

        self.scope.pop()
        self.tu->error_count = self.diag->error_count() - self.error_count_base
        self.tu->warn_count  = self.diag->warn_count() - warn_count_base

        self._wire_scopes()
        self._build_symbols()
        self._synthesize_module_self()
        return self.tu
    }

    /// \brief restores, on a tree that was NOT parsed here, everything
    ///        parse() derives from the finished tree: the scope links into
    ///        the hoisted table, the per-scope symbol tables with the
    ///        lexical / semantic context stamps and the out-of-line list,
    ///        and the file's own module declaration.
    ///
    /// \details The serialized AST (Compiler/Spec/Serialization.md) stores the
    ///          tree and none of these: they are functions of it, and one
    ///          implementation of them, this one, is what keeps a reloaded
    ///          tree's tables identical to a parsed one's. `ctx->tu` must be
    ///          the reloaded TU (this parser adopted it in its constructor)
    ///          and `ctx->hoisted` the file's index.
    pub fn rebuild_derived(self) {
        self._wire_scopes()
        self._build_symbols()
        self._synthesize_module_self()
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
        var base = self.ctx->module_base
        if base.segments.size() == 0 { // anonymous root file.
            return
        }

        var leaf = base.segments[base.segments.size() - 1]

        // Prefer the leaf's real source token; else synthesize an identifier
        // token carrying the leaf imm (name-domain only, no source slice).
        var name_tok: Token
        // Both halves of this token must belong to THIS file.
        //
        //   imm:   `leaf.name` is a PP SymbolID -- a different name domain
        //          from an imm index -- and `leaf.token` is a token of
        //          whichever file spelled the path. The PP re-interns the
        //          leaf into this file's imm space for exactly this
        //          (ASTContext::module_leaf_imm).
        //   range: TokenText resolves the interner FROM THE RANGE's fid, so
        //          an invalid range means no interner and the name spells as
        //          "$FALLBACK-MISSING-INTERN$". A zero-length range at the
        //          file's start is both resolvable and honest: the module IS
        //          the file.
        var at = SourceRange::invalid()
        if self.ctx->sm != &null {
            var start = self.ctx->sm->get_loc(self.ctx->fid, 0)
            at = SourceRange(start, start)
        }

        name_tok       = Token()
        name_tok.kind  = TokenKind::LitIdentifier
        name_tok.range = at
        if leaf.token != &null {
            name_tok.imm = leaf.token->imm
        }

        if self.ctx->module_leaf_imm != u32::MAX {
            name_tok.imm = self.ctx->module_leaf_imm
        }

        var unsafe *tu_dc = unsafe (self.tu as unsafe *DeclContext)
        var unsafe *md    = ModuleDecl::create(self.ctx, at, name_tok, tu_dc)

        // A2: share the TU's symbol table rather than owning a second one, so
        // member lookup through the module hits the same frozen decls. A file
        // with no top-level named decls never triggered _symtab_for, so the TU
        // table can be null share an empty frozen table so qualified lookup
        // through the module is a clean miss, not a null deref.
        if self.tu->dc_symbols == &null {
            var unsafe *empty = self.ctx->alloc_init_cleanup<SymbolTable>(
                self.ctx,
            )

            empty->freeze()
            self.tu->set_symbols(empty)
        }

        md->set_symbols(self.tu->dc_symbols)
        md->module_path = base

        self.tu->module_self = md
    }

    /// \brief true when the cursor sits on a bare `module a::b` pin: `module`,
    ///        a path, then a terminator or EOF.
    ///
    /// \details Lookahead over the raw span, so a block `module foo { }` is
    ///          left untouched for parse_decl. Only `{` (or anything else that
    ///          is not a terminator) after the path means "not a pin"; that
    ///          keeps `module foo` followed by junk on the block path, whose
    ///          S050E already says what is missing. Comments are skipped: the
    ///          lexer leaves them in the span, and `module foo // why` is
    ///          still a pin.
    priv fn _is_module_pin(self) -> bool {
        var i     = self.c_idx
        var n     = self.span.size()
        var state = 0 // 0 = want `module`, 1 = want ident, 2 = after ident, 3 = after the newline
        while i < n {
            var k = self.resolve_kind_shallow(self.span.get(i))
            i += 1
            if k == TokenKind::AtComment {
                continue
            }

            if state == 0 {
                if k != TokenKind::KwModule {
                    return false
                }

                state = 1
                continue
            }

            if state == 1 {
                if k != TokenKind::LitIdentifier {
                    return false
                }

                state = 2
                continue
            }

            if state == 2 {
                if k == TokenKind::OpColonColon {
                    state = 1
                    continue
                }

                if k == TokenKind::OpSemicolon || k == TokenKind::TkEof {
                    return true
                }

                if k != TokenKind::TkNewLine {
                    return false
                }

                state = 3
                continue
            }

            // Past a newline: `module foo` NEWLINE `{` was the block form with
            // its brace on the next line, an S050E before the bare form
            // existed. It stays one rather than silently becoming a pin plus a
            // stray block statement.
            if k == TokenKind::TkNewLine {
                continue
            }

            return k != TokenKind::OpLBrace
        }

        return state >= 2
    }

    /// \brief consumes a bare `module a::b` pin and records its path on the TU.
    ///
    /// \details Recorded, not acted on: what the pin MEANS is the resolver's
    ///          (ImportProbe reads module.k's first declaration itself, without
    ///          a parse), and WHERE it may appear is ModulePinCheck::pin_allowed's
    ///          (module.k only, today). Accepted in every file all the same, so
    ///          that rule can change without touching the parser. Only the
    ///          first pin of a file is kept; the range of a second is kept
    ///          for ModulePinCheck to report.
    priv fn _parse_module_pin(self) {
        var start = self._current->range
        var keep  = self.tu->pin_segments.size() == 0
        self.advance_raw() // `module`
        while self._current != &null && !self.is_eof() {
            var k = self.resolve_kind_shallow(self._current)
            if k == TokenKind::LitIdentifier {
                if keep {
                    self.tu->pin_segments.push(*self._current)
                }

                self.advance_raw()
                continue
            }

            if k == TokenKind::OpColonColon {
                self.advance_raw()
                continue
            }

            break
        }

        if keep {
            self.tu->pin_range = start | self._prev->range
        } else if !self.tu->pin_extra_range.is_valid() {
            self.tu->pin_extra_range = start | self._prev->range
        }
    }

    /// \brief S063E at the first token of a top-level item that failed
    ///        without a diagnostic of its own.
    priv fn _report_unparsed_item(self, at: usize) {
        var unsafe *tok = if (at < self.span.size()) => (self.span.get(at)) else => self._current
        if tok == &null {
            return
        }

        var k = self.resolve_kind_deep(tok)
        self.report_tok(
            DiagID::S063E,
            tok,
            f"unexpected '{token_kind_to_readable_string(k)}': expected a declaration or a statement",
        )
    }

    /// \brief moves the cursor past a top-level item that failed: from where
    ///        the production stopped (never before the item's start) to the
    ///        next line or declaration. Always makes progress, so the loop
    ///        cannot spin on the token it just reported.
    priv fn _skip_failed_item(self, before: usize) {
        if self.c_idx < before {
            self._restore_cursor(before)
        }

        self.sync_top_level_progress()
    }

    /// \brief decl-vs-stmt routing for the top-level loop.
    ///
    /// \details var/const take the stmt path (it owns the plain-decl vs
    ///          destructuring split), except `const static` / `const thread`
    ///          / `const eval`: those are the same declaration as `static
    ///          const` (DeclParse::_parse_storage_head), so they route where
    ///          `static` does and both orders build the same tree. `thread`
    ///          and `eval` are decls only when they open one (see below).
    priv fn _routes_to_decl(self, k: TokenKind) -> bool {
        if k == TokenKind::KwConst {
            return self.check_peek(TokenKind::KwStatic)
                || self.check_peek(TokenKind::KwThread)
                || self.check_peek(TokenKind::KwEval)
                || self._mods_lead_to_fn()
        }

        // `thread n: T` is a declaration, `thread work()` a spawn expression.
        if k == TokenKind::KwThread {
            return self._storage_binding_ahead()
        }

        if !self._starts_decl_kw(k) {
            return false
        }

        if k == TokenKind::KwVar {
            return false
        }

        // `eval { }`, `eval fn f()` and `eval N = e` are declarations, the
        // same nodes a module body builds for them; `eval if` / `eval for`
        // and an `eval f(3)` expression are statements.
        if k == TokenKind::KwEval {
            return self.check_peek(TokenKind::OpLBrace)
                || self._mods_lead_to_fn()
                || self._storage_binding_ahead()
        }

        return true
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
    priv fn _parse_top_decl(self,
                            program: unsafe *Program,
                            annot:   unsafe *Self::PendingAnnotations,
                            k:       TokenKind) -> bool {
        var        at   = self.c_idx
        var        errs = self.diag->error_count()
        var unsafe *d   = self.parse_decl(true)
        if d == &null {
            // `fn` that is a closure, and any lead-in parse_decl declined
            // without consuming or reporting anything (`inline "c++" { }`
            // opens a statement, not a declaration): the statement path owns
            // it. Before, the `inline` case ended the loop with no error and
            // the rest of the file unparsed.
            if k == TokenKind::KwFn || (self.c_idx == at && self.diag->error_count() == errs) {
                return self._parse_top_stmt(program, annot)
            }

            return false
        }

        if self.is_fatal<Decl>(d) {
            return false
        }

        self._top_item_failed = is_recovery(d)
        if isa<VisibilityGroupDecl>(d) {
            self._diag_annot_on_vis_group(annot)
            // do NOT stamp annot onto the group
        } else {
            self.apply_annotations_to_decl(d, annot)
        }

        self.tu->add_decl(d)
        program->add_item(TopLevelItem::from_decl(d))
        self._attach_trailing(d)
        return true
    }

    /// \brief parses one top-level statement (script-style top level is legal).
    ///
    /// \details DeclStmt unwraps so annotations land on the inner decl, not
    ///          the statement wrapper.
    ///
    /// \return false to stop the top-level loop (null or fatal).
    priv fn _parse_top_stmt(self,
                            program: unsafe *Program,
                            annot:   unsafe *Self::PendingAnnotations) -> bool {
        var unsafe *s = self.parse_stmt()
        if s == &null {
            return false
        }

        if self.is_fatal<Stmt>(s) {
            return false
        }

        self._top_item_failed = is_recovery(s)
        if isa<ExpressionStmt>(s) {
            var unsafe *es = cast<ExpressionStmt>(s)
            self._top_item_failed = self._top_item_failed
                || es->expr == &null
                || is_recovery(es->expr)
        }

        if isa<DeclStmt>(s) {
            var unsafe *ds = cast<DeclStmt>(s)
            if ds->decl != &null {
                self.apply_annotations_to_decl(ds->decl, annot)
            }
        } else {
            self.apply_annotations_to_node(s, annot)
        }

        program->add_item(TopLevelItem::from_stmt(s))
        self._attach_trailing(s)
        return true
    }

    /// \brief S048E: annotations/attributes cannot apply to a visibility group.
    ///        one note per additional annotation so each gets its own caret
    ///        instead of one fused multi-line span.
    priv fn _diag_annot_on_vis_group(self, annot: unsafe *Self::PendingAnnotations) {
        if annot->empty() {
            return
        }

        var first_span: SourceRange = annot->entries.front().range

        var b = self.diag->report(
            DiagID::S048E,
            first_span.start,
            "annotations and attributes cannot be applied to a visibility group; "
            "apply them to individual members instead",
        )

        b.first(first_span)

        for var i: usize = 1; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            b.note(
                DiagCode(DiagID::S048N),
                e->range.start,
                "this annotation also cannot apply to the group",
            )->child_first(e->range)
        }

        b.emit()
    }

    /// \brief routes parsing to specific top-level declaration logic.
    pub fn dispatch_top_level(self) -> TopLevelItem {
        self.advance()
        return TopLevelItem::from_decl(&null)
    }

    //  Hoisted-scope wiring (post-parse)

    /// \brief connects each named DeclContext in the tree to its DisambigNode in
    ///        the hoisted trie, descending both in lockstep. Decls the indexer
    ///        didn't hoist (locals, anonymous modules) are skipped lexical
    ///        lookup covers them. A missing trie node for a hoisted-eligible
    ///        type is an indexer/parser disagreement; we stay silent here and
    ///        let sema's resolve-or-error path surface it with context.
    fn _wire_scopes(self) {
        var unsafe *root = self.ctx->hoisted->root()
        self.tu->set_scope(root)
        self._wire_dc_children(unsafe (self.tu as unsafe *DeclContext), root)
    }

    priv fn _wire_dc_children(self, dc: unsafe *DeclContext, node: unsafe *DisambigNode) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i { // FIXME
            var unsafe *d = *dc->dc_decls.get(i) // FIXME
            if d == &null {
                continue
            }

            var name_tok                      = Token()
            var child_dc: unsafe *DeclContext = &null

            if isa<ClassDecl>(d) {
                var unsafe *n = cast<ClassDecl>(d)
                name_tok = n->name
                child_dc = n
            } else if isa<StructDecl>(d) {
                var unsafe *n = cast<StructDecl>(d)
                name_tok = n->name
                child_dc = n
            } else if isa<EnumDecl>(d) {
                var unsafe *n = cast<EnumDecl>(d)
                name_tok = n->name
                child_dc = n
            } else if isa<UnionDecl>(d) {
                var unsafe *n = cast<UnionDecl>(d)
                name_tok = n->name
                child_dc = n
            } else if isa<InterfaceDecl>(d) {
                var unsafe *n = cast<InterfaceDecl>(d)
                name_tok = n->name
                child_dc = n
            } else if isa<ModuleDecl>(d) {
                var unsafe *n = cast<ModuleDecl>(d)
                if n->is_anonymous {
                    continue
                }

                name_tok = n->name
                child_dc = n
            } else {
                continue // fns/vars: no trie children; ScopeStack covers bodies
            }

            var unsafe *child = node->get_child(
                self.ctx->hoisted->intern_tok(name_tok),
            )

            if child == &null {
                continue
            }

            child_dc->set_scope(child)
            self._wire_dc_children(child_dc, child)
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
        var unsafe *tu_dc = unsafe (self.tu as unsafe *DeclContext)
        self._collect_symbols(tu_dc, tu_dc, u32::MAX)

        // top-level DeclStmt-wrapped decls (script-style `var x = 5`).
        var unsafe *prog = self.tu->program
        if prog != &null {
            for var i: usize = 0; i < prog->items.size(); ++i {
                var unsafe *item = prog->items.get(i)
                if item == &null {
                    continue
                }

                if item->get_kind() != TopLevelKind::Stmt {
                    continue
                }

                var unsafe *s = item->as_stmt()
                if s == &null {
                    continue
                }

                if isa<DeclStmt>(s) {
                    var unsafe *ds = cast<DeclStmt>(s)
                    if ds->decl != &null {
                        self._index_symbol_decl(
                            ds->decl,
                            tu_dc,
                            tu_dc,
                            u32::MAX,
                        )
                    }

                    continue
                }

                if isa<ConditionalStmt>(s) {
                    self._index_eval_branches(s, tu_dc, tu_dc, u32::MAX)
                    continue
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
                if isa<DestructuringDeclStmt>(s) {
                    var unsafe *dd = cast<DestructuringDeclStmt>(s)
                    for var b: usize = 0; b < dd->bindings.size(); ++b {
                        var bind = dd->bindings[b]
                        if bind.is_discard {
                            continue
                        }

                        if bind.decl == &null {
                            continue
                        }

                        self._index_symbol_decl(
                            bind.decl,
                            tu_dc,
                            tu_dc,
                            u32::MAX,
                        )
                    }
                }
            }
        }

        for var i: usize = 0; i < self._sym_tables.size(); ++i {
            self._sym_tables[i]->freeze()
        }
    }

    /// \brief indexes EVERY branch of a declaration-scope `eval if` into the
    ///        enclosing table, as if hoisted. Which branch is taken is
    ///        Sema's (EvalIfFolding, phase E), and a table is frozen here:
    ///        so the parser records them all -- member tables, dc links and
    ///        all -- and the fold builds the scope a new table without the
    ///        untaken ones (Compiler/Spec/Eval.md#folding-eval-if). A nested `eval if` in a branch
    ///        is indexed the same way; anything else in a branch is not a
    ///        declaration.
    priv fn _index_eval_branches(self,
                                 s:              unsafe *Stmt,
                                 walk_dc:        unsafe *DeclContext,
                                 table_dc:       unsafe *DeclContext,
                                 owner_name_imm: u32) {
        if s == &null || !isa<ConditionalStmt>(s) {
            return
        }

        var unsafe *c = cast<ConditionalStmt>(s)
        if !c->is_eval {
            return
        }

        self._index_eval_block(c->then_, walk_dc, table_dc, owner_name_imm)
        if c->else_ == &null {
            return
        }

        if isa<ConditionalStmt>(c->else_) {
            self._index_eval_branches(
                c->else_,
                walk_dc,
                table_dc,
                owner_name_imm,
            )

            return
        }

        self._index_eval_block(c->else_, walk_dc, table_dc, owner_name_imm)
    }

    priv fn _index_eval_block(self,
                              s:              unsafe *Stmt,
                              walk_dc:        unsafe *DeclContext,
                              table_dc:       unsafe *DeclContext,
                              owner_name_imm: u32) {
        if s == &null || !isa<CompoundStmt>(s) {
            return
        }

        var unsafe *b = cast<CompoundStmt>(s)
        for var i: usize = 0; i < b->body.size(); ++i {
            var unsafe *st = b->body[i]
            if st == &null {
                continue
            }

            if isa<DeclStmt>(st) {
                var unsafe *ds = cast<DeclStmt>(st)
                if ds->decl != &null {
                    self._index_symbol_decl(
                        ds->decl,
                        walk_dc,
                        table_dc,
                        owner_name_imm,
                    )
                }

                continue
            }

            self._index_eval_branches(st, walk_dc, table_dc, owner_name_imm)
        }
    }

    /// \brief lazily allocates the SymbolTable for \p dc and registers it
    ///        for the freeze sweep at the end of _build_symbols.
    priv fn _symtab_for(self, dc: unsafe *DeclContext) -> unsafe *SymbolTable {
        if dc->dc_symbols == &null {
            var unsafe *t = self.ctx->alloc_init_cleanup<SymbolTable>(self.ctx)
            dc->set_symbols(t)
            self._sym_tables.push_back(t)
        }

        return dc->dc_symbols
    }

    /// \brief appends \p d under \p name in \p table_dc's table and stamps
    ///        the dual-context links (lexical = where written, semantic =
    ///        lookup home). They differ for anonymous-module members
    ///        and for extension members once sema folds them.
    priv fn _append_symbol(self,
                           table_dc: unsafe *DeclContext,
                           lex_dc:   unsafe *DeclContext,
                           name:     DeclName,
                           d:        unsafe *Decl) {
        self._symtab_for(table_dc)->append(name, d)
        d->lexical_dc  = lex_dc
        d->semantic_dc = table_dc
    }

    /// \brief identifier-keyed append. Silently skips recovery/synthetic
    ///        names that fail imm resolution sema surfaces those with
    ///        context; a half-keyed table entry helps no one.
    priv fn _append_ident_symbol(self,
                                 table_dc: unsafe *DeclContext,
                                 lex_dc:   unsafe *DeclContext,
                                 name_tok: Token,
                                 d:        unsafe *Decl) {
        var im = self.ctx->get_ident_imm(name_tok)
        if im == u32::MAX {
            return
        }

        self._append_symbol(table_dc, lex_dc, DeclName::ident(im), d)
    }

    /// \brief the name half of indexing a scope-owning decl. In a real scope
    ///        the name goes in \p table_dc's table. In an EXECUTABLE scope
    ///        (a `class Local` inside a function body) there is no table by
    ///        design -- N's lexical stack and T's ltypes find the NAME -- so
    ///        only the dual-context links are stamped; the decl's own body is
    ///        still indexed by the caller.
    priv fn _table_or_link(self,
                           table_dc: unsafe *DeclContext,
                           lex_dc:   unsafe *DeclContext,
                           name_tok: Token,
                           d:        unsafe *Decl,
                           tabled:   bool) {
        if tabled {
            self._append_ident_symbol(table_dc, lex_dc, name_tok, d)
            return
        }

        d->lexical_dc  = lex_dc
        d->semantic_dc = table_dc
    }

    /// \brief indexes the BODIES of scope-owning decls written at statement
    ///        scope (StmtParse::_attach_local_decl put them in the function's
    ///        dc_decls). Their names are not tabled; their members are, in
    ///        their own tables, so `l.v` on a local class resolves.
    priv fn _index_local_scopes(self, fn_dc: unsafe *DeclContext) {
        if fn_dc == &null {
            return
        }

        for var i: usize = 0; i < fn_dc->dc_decls.size(); ++i {
            var unsafe *d = *fn_dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            self._index_symbol_decl(d, fn_dc, fn_dc, u32::MAX, false)
        }
    }

    /// \brief DeclName for `fn op <x>` from its operator tokens. The `l`/`r`
    ///        fixity marker on `++`/`--` is a fact about the decl, not part of
    ///        its name: `op l++` and `op r++` share one cell, and X picks by
    ///        fixity. AST/OperatorFacts.k keys the sema side by the same rule;
    ///        the parser cannot import it, so the three lines live twice.
    priv fn _op_decl_name(self, f: unsafe *FunctionDecl) -> DeclName {
        var n        = f->op_token.size()
        var i: usize = 0
        if n == 2
            && f->op_token[0].kind == TokenKind::LitIdentifier
            && (f->op_token[1].kind == TokenKind::OpPlusPlus
                || f->op_token[1].kind == TokenKind::OpMinusMinus) {
            i = 1
        }

        var k0 = TokenKind::TkUnknown
        var k1 = TokenKind::TkUnknown
        var k2 = TokenKind::TkUnknown
        if i < n {
            k0 = f->op_token[i].kind
        }

        if i + 1 < n {
            k1 = f->op_token[i + 1].kind
        }

        if i + 2 < n {
            k2 = f->op_token[i + 2].kind
        }

        return DeclName::op_name_of(k0, k1, k2)
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
    priv fn _collect_symbols(self,
                             walk_dc:        unsafe *DeclContext,
                             table_dc:       unsafe *DeclContext,
                             owner_name_imm: u32) {
        var type_body = walk_dc->is_type_scope()
        for var i: usize = 0; i < walk_dc->dc_decls.size(); ++i {
            var unsafe *d = *walk_dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            if type_body && isa<VisibilityGroupDecl>(d) {
                continue
            }

            self._index_symbol_decl(d, walk_dc, table_dc, owner_name_imm)
        }
    }

    /// \brief routes one decl into the tables. Pass-through containers
    ///        (visibility groups, eval blocks, ffi blocks) recurse with the
    ///        SAME table_dc; scope-owning named decls append themselves and
    ///        recurse into their own context.
    ///
    /// \param tabled false when \p d was written at STATEMENT scope (a
    ///        `class Local` / `fn inner` inside a body, reached through
    ///        _index_local_scopes). Its NAME then goes in no table -- N's
    ///        lexical stack and T's ltypes find it -- but its own body is
    ///        still indexed so its members have a table to be looked up in.
    priv fn _index_symbol_decl(self,
                               d:              unsafe *Decl,
                               walk_dc:        unsafe *DeclContext,
                               table_dc:       unsafe *DeclContext,
                               owner_name_imm: u32,
                               tabled:         bool = true) {
        if isa<ClassDecl>(d) {
            var unsafe *n = cast<ClassDecl>(d)
            self._table_or_link(table_dc, walk_dc, n->name, d, tabled)

            var unsafe *dc   = unsafe (n as unsafe *DeclContext)
            var        owner = self.ctx->get_ident_imm(n->name)
            // Members live in the typed FrozenLists (fields/methods), NOT in
            // dc_decls; only nested types are add_decl'd. Route each member
            // back through _index_symbol_decl so operator/ctor detection fires.
            for var mi: usize = 0; mi < n->fields.size(); ++mi {
                var unsafe *fd = n->fields[mi]
                if fd != &null {
                    self._index_symbol_decl(fd, dc, dc, owner)
                }
            }

            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var unsafe *md = n->methods[mi]
                if md != &null {
                    self._index_symbol_decl(md, dc, dc, owner)
                }
            }

            self._collect_symbols(dc, dc, owner) // nested types from dc_decls

            return
        }

        if isa<StructDecl>(d) {
            var unsafe *n = cast<StructDecl>(d)
            self._table_or_link(table_dc, walk_dc, n->name, d, tabled)

            var unsafe *dc   = unsafe (n as unsafe *DeclContext)
            var        owner = self.ctx->get_ident_imm(n->name)
            // struct: fields + nested types, plus the ctors/operators the body
            // does admit (named methods are rejected at parse).
            for var mi: usize = 0; mi < n->fields.size(); ++mi {
                var unsafe *fd = n->fields[mi]
                if fd != &null {
                    self._index_symbol_decl(fd, dc, dc, owner)
                }
            }

            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var unsafe *md = n->methods[mi]
                if md != &null {
                    self._index_symbol_decl(md, dc, dc, owner)
                }
            }

            self._collect_symbols(dc, dc, owner)

            return
        }

        if isa<UnionDecl>(d) {
            var unsafe *n = cast<UnionDecl>(d)
            self._table_or_link(table_dc, walk_dc, n->name, d, tabled)

            var unsafe *dc   = unsafe (n as unsafe *DeclContext)
            var        owner = self.ctx->get_ident_imm(n->name)
            // union: fields + nested types, plus ctors/operators - same rule as
            // struct.
            for var mi: usize = 0; mi < n->fields.size(); ++mi {
                var unsafe *fd = n->fields[mi]
                if fd != &null {
                    self._index_symbol_decl(fd, dc, dc, owner)
                }
            }

            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var unsafe *md = n->methods[mi]
                if md != &null {
                    self._index_symbol_decl(md, dc, dc, owner)
                }
            }

            self._collect_symbols(dc, dc, owner)

            return
        }

        if isa<InterfaceDecl>(d) {
            var unsafe *n = cast<InterfaceDecl>(d)
            self._table_or_link(table_dc, walk_dc, n->name, d, tabled)

            var unsafe *dc   = unsafe (n as unsafe *DeclContext)
            var        owner = self.ctx->get_ident_imm(n->name)
            // interface: requirement-signature methods + nested types.
            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var unsafe *md = n->methods[mi]
                if md != &null {
                    self._index_symbol_decl(md, dc, dc, owner)
                }
            }

            self._collect_symbols(dc, dc, owner)

            return
        }

        if isa<EnumDecl>(d) {
            var unsafe *n = cast<EnumDecl>(d)
            self._table_or_link(table_dc, walk_dc, n->name, d, tabled)
            var unsafe *dc = unsafe (n as unsafe *DeclContext)
            // variants are owned via n->variants (not dc_decls); key them in
            // the enum's own table so `Direction::North` resolves per segment.
            for var v: usize = 0; v < n->variants.count; ++v {
                var unsafe *vd = n->variants[v]
                if vd != &null {
                    self._append_ident_symbol(dc, dc, vd->name, vd)
                }
            }

            self._collect_symbols(dc, dc, u32::MAX)
            return
        }

        if isa<ModuleDecl>(d) {
            var unsafe *n  = cast<ModuleDecl>(d)
            var unsafe *dc = unsafe (n as unsafe *DeclContext)
            if n->is_anonymous {
                // anonymous modules get no table; decls land in the
                // enclosing DC's table. lexical_dc still records the module.
                self._collect_symbols(dc, table_dc, owner_name_imm)
                return
            }

            self._table_or_link(table_dc, walk_dc, n->name, d, tabled)
            self._collect_symbols(dc, dc, u32::MAX)
            return
        }

        if isa<ExtensionDecl>(d) {
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
            var unsafe *n  = cast<ExtensionDecl>(d)
            var unsafe *dc = unsafe (n as unsafe *DeclContext)

            for var mi: usize = 0; mi < n->methods.size(); ++mi {
                var unsafe *md = n->methods[mi]
                if md != &null {
                    self._index_symbol_decl(
                        unsafe (md as unsafe *Decl),
                        dc,
                        dc,
                        u32::MAX,
                    )
                }
            }

            self._collect_symbols(dc, dc, u32::MAX)
            return
        }

        if isa<FunctionDecl>(d) {
            var unsafe *f  = cast<FunctionDecl>(d)
            var unsafe *dc = unsafe (f as unsafe *DeclContext)
            if f->is_out_of_line() {
                // `fn Class::method` no table entry; N(a) attaches it.
                self.tu->out_of_line.push(d)
                d->lexical_dc  = walk_dc
                d->semantic_dc = &null   // unknown until attachment
                self._index_local_scopes(dc)
                return
            }

            if f->is_operator {
                if tabled {
                    self._append_symbol(
                        table_dc,
                        walk_dc,
                        self._op_decl_name(f),
                        d,
                    )
                } else {
                    d->lexical_dc  = walk_dc
                    d->semantic_dc = table_dc
                }

                self._index_local_scopes(dc)
                return
            }

            var im = self.ctx->get_ident_imm(f->name)
            if im == u32::MAX {
                return
            }

            if tabled && table_dc->is_type_scope() && im == owner_name_imm {
                self._append_symbol(table_dc, walk_dc, DeclName::ctor(), d)
                self._index_local_scopes(dc)
                return
            }

            if tabled {
                self._append_symbol(table_dc, walk_dc, DeclName::ident(im), d)
            } else {
                d->lexical_dc  = walk_dc
                d->semantic_dc = table_dc
            }

            // Locals and params are not tabled (lexical stack / signature),
            // but a local TYPE's body still needs a table of its own.
            self._index_local_scopes(dc)
            return
        }

        if isa<VariableDecl>(d) {
            var unsafe *n = cast<VariableDecl>(d)
            self._append_ident_symbol(table_dc, walk_dc, n->name, d)
            return
        }

        if isa<FieldDecl>(d) {
            var unsafe *n = cast<FieldDecl>(d)
            self._append_ident_symbol(table_dc, walk_dc, n->name, d)
            return
        }

        if isa<TypeAliasDecl>(d) {
            var unsafe *n = cast<TypeAliasDecl>(d)
            self._append_ident_symbol(table_dc, walk_dc, n->name, d)
            return
        }

        if isa<VisibilityGroupDecl>(d) {
            var unsafe *n = cast<VisibilityGroupDecl>(d)
            for var i: usize = 0; i < n->members.count; ++i {
                var unsafe *m = n->members[i]
                if m != &null {
                    self._index_symbol_decl(
                        m,
                        walk_dc,
                        table_dc,
                        owner_name_imm,
                        tabled,
                    )
                }
            }

            return
        }

        if isa<EvalBlockDecl>(d) {
            var unsafe *n = cast<EvalBlockDecl>(d)
            for var i: usize = 0; i < n->body.count; ++i {
                var unsafe *m = n->body[i]
                if m != &null {
                    self._index_symbol_decl(
                        m,
                        walk_dc,
                        table_dc,
                        owner_name_imm,
                        tabled,
                    )
                }
            }

            if n->stmt != &null {
                self._index_eval_branches(
                    n->stmt,
                    walk_dc,
                    table_dc,
                    owner_name_imm,
                )
            }

            return
        }

        if isa<FFIBlockDecl>(d) {
            var unsafe *n = cast<FFIBlockDecl>(d)
            for var i: usize = 0; i < n->body.count; ++i {
                var unsafe *m = n->body[i]
                if m != &null {
                    self._index_symbol_decl(
                        m,
                        walk_dc,
                        table_dc,
                        owner_name_imm,
                        tabled,
                    )
                }
            }

            return
        }

        if isa<ProcedureMacroDecl>(d) {
            // A proc macro (`macro @name(...) { ... }`) is an eval-time function:
            // it has a real name, executes at compile time, and is referenced by
            // that name. Key it by ident in the enclosing table exactly like a
            // FunctionDecl. Params are ParamDecl (off the signature) and body
            // locals are on the lexical stack; only local TYPE bodies descend.
            //
            // NOTE distinct from MacroDecl (`macro name!`), which is a PP token
            // macro owned by the preprocessor and deliberately never tabled.
            var unsafe *n = cast<ProcedureMacroDecl>(d)
            self._append_ident_symbol(table_dc, walk_dc, n->name, d)
            self._index_local_scopes(n)
            return
        }

        if isa<TestDecl>(d) {
            // Anonymous, never looked up -- but its body is an executable
            // scope that may declare local types.
            self._index_local_scopes((cast<TestDecl>(d)))
            return
        }

        // ImportDecl:                   phase I owns imports (overlay), nothing to record.
        // MacroDecl:                    the macro table belongs to the PP.
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
    ///          global.
    ///
    ///          Diagnostics are suppressed for the whole pass: the Full parse
    ///          that follows re-parses everything and owns every diagnostic;
    ///          emitting here would double-report.
    pub fn index(self) {
        if self.mode != Self::ParseMode::Index {
            return
        }

        if self.ctx->hoisted == &null {
            return
        }

        self.diag->push_suppress()

        var iterations: usize = 0
        var max_iter          = self.span.size() << 2
        var prev_idx:   usize = 0
        var have_prev         = false

        while !self.is_eof() {
            ++iterations
            if iterations > max_iter {
                break
            }

            // progress guard: a production that consumed nothing (recovery
            // stopping on the very token we dispatched on) must not spin.
            if have_prev && self.c_idx == prev_idx {
                self.advance_raw()
                continue
            }

            prev_idx  = self.c_idx
            have_prev = true

            if self._is_terminator_tok(self._current) {
                self.advance_raw()
                continue
            }

            var annot: Self::PendingAnnotations
            self.consume_leading_annotations(unsafe &annot) // consumed, discarded
            if self.is_eof() {
                break
            }

            var k = self.resolve_kind_deep(self._current)
            if self._starts_decl_here(k) {
                var unsafe *d = self.parse_decl(true)
                if d == &null {
                    // closure IIFE fallback (cursor rolled back to `fn`) or a
                    // non-decl after modifiers: skip the statement wholesale.
                    self._index_skip_stmt()
                } else {
                    self._index_hoist_decl(d, false)
                }
            } else {
                // statement position: never walked into.
                self._index_skip_stmt()
            }
        }

        self.diag->pop_suppress()
    }

    /// \brief inserts one entry at the current _index_path scope.
    priv fn _index_insert(self, const name: string, entry: DisambigEntry) {
        if name == "" {
            return
        }

        if self._index_path.empty() {
            self.ctx->hoisted->insert(name, entry)
        } else {
            self.ctx->hoisted->insert_into(&self._index_path, name, entry)
        }
    }

    /// \brief builds a DisambigEntry for \p d and inserts it, recursing into
    ///        container decls (modules, visibility groups, eval/ffi blocks,
    ///        type bodies via dc_decls) with the scope path maintained.
    ///
    /// \details genericness comes from TemplateParams::is_generic() on the
    ///          node: has_type_params() || spec_kind == Primary. Explicit and
    ///          Partial specializations therefore never mark a name generic
    ///          on their own.
    fn _index_hoist_decl(self, d: unsafe *Decl, foreign: bool) {
        if d == &null {
            return
        }

        if isa<FunctionDecl>(d) {
            var unsafe *n = cast<FunctionDecl>(d)
            if n->qualifier != &null { // out-of-line impl: not a new decl
                return
            }

            if n->name.kind == TokenKind::KwSelf { // ctor: not a root name
                return
            }

            // Operators carry no name token (`fn op +`): spelling the empty
            // default resolved to "$unknown$" and keyed every operator of
            // every type under it, and asserts on the null table in debug.
            if n->is_operator {
                return
            }

            // Non-generic callables are stored as NEGATIVE evidence: rule 4
            // of the disambiguation model demands that `<` after a known
            // non-generic name commits to a comparison, and the verdict
            // (_generic_verdict) needs found-and-not-generic to be
            // distinguishable from not-found (which stays tentative for
            // unqualified imported generics).
            var e = DisambigEntry{}
            e.kind = if (n->is_operator) => (DisambigKind::Operator) else => DisambigKind::Function
            e.generic     = n->is_generic()
            e.is_foreign  = foreign
            e.extended    = false
            e.decl.origin = n->range
            self._index_insert(self.ctx->get_spelling(n->name), e)
            return
        }

        if isa<ClassDecl>(d) {
            var unsafe *n = cast<ClassDecl>(d)
            self._index_hoist_type_scope(
                n,
                n->name,
                DisambigKind::ClassType,
                n->is_generic(),
                n->range,
                foreign,
            )

            return
        }

        if isa<StructDecl>(d) {
            var unsafe *n = cast<StructDecl>(d)
            self._index_hoist_type_scope(
                n,
                n->name,
                DisambigKind::StructType,
                n->is_generic(),
                n->range,
                foreign,
            )

            return
        }

        if isa<UnionDecl>(d) {
            var unsafe *n = cast<UnionDecl>(d)
            self._index_hoist_type_scope(
                n,
                n->name,
                DisambigKind::UnionType,
                n->is_generic(),
                n->range,
                foreign,
            )

            return
        }

        if isa<InterfaceDecl>(d) {
            var unsafe *n = cast<InterfaceDecl>(d)
            self._index_hoist_type_scope(
                n,
                n->name,
                DisambigKind::InterfaceType,
                n->is_generic(),
                n->range,
                foreign,
            )

            return
        }

        if isa<EnumDecl>(d) {
            var unsafe *n = cast<EnumDecl>(d)
            var        e  = DisambigEntry{}
            e.kind        = DisambigKind::EnumType
            e.generic     = n->is_generic()
            e.is_foreign  = foreign
            e.extended    = false
            e.decl.origin = n->range
            self._index_insert(self.ctx->get_spelling(n->name), e)
            return // variants are not hoisted
        }

        if isa<TypeAliasDecl>(d) {
            var unsafe *n = cast<TypeAliasDecl>(d)
            var        e  = DisambigEntry{}
            e.kind        = DisambigKind::TypeAlias
            e.generic     = n->is_generic()
            e.is_foreign  = foreign
            e.extended    = false
            e.decl.origin = n->range
            self._index_insert(self.ctx->get_spelling(n->name), e)
            return
        }

        if isa<VariableDecl>(d) {
            // Negative evidence for rule 4 (see FunctionDecl above):
            // `scale<a>(10)` on a known global var must commit to a
            // comparison chain. Generic closures bound to vars are a
            // LexicalScope concern (locals shadow globals; the verdict
            // checks the scope stack first). PatternParse uses is_type()
            // so value entries cannot flip `case x` into a constructor.
            var unsafe *n = cast<VariableDecl>(d)
            var        e  = DisambigEntry{}
            e.kind        = DisambigKind::Variable
            e.generic     = false
            e.is_foreign  = foreign
            e.extended    = false
            e.decl.origin = n->range
            self._index_insert(self.ctx->get_spelling(n->name), e)
            return
        }

        // MacroDecl / ProcedureMacroDecl: never hoisted. Macro invocations
        // are resolved by the PP; is_macro() has zero parser callsites, and
        // macro names never head a `<` disambiguation (`foo!` / `@foo`).

        if isa<ModuleDecl>(d) {
            var unsafe *n = cast<ModuleDecl>(d)
            // no entry for the module itself;
            // named modules contribute a scope-path segment for their decls.
            if !n->is_anonymous {
                self._index_path.push_back(self.ctx->get_spelling(n->name))
            }

            self._index_hoist_dc_children(n, foreign)
            if !n->is_anonymous {
                self._index_path.pop_back()
            }

            return
        }

        if isa<VisibilityGroupDecl>(d) {
            var unsafe *n = cast<VisibilityGroupDecl>(d)
            for var i: usize = 0; i < n->members.size(); ++i {
                self._index_hoist_decl(n->members[i], foreign)
            }

            return
        }

        if isa<EvalBlockDecl>(d) {
            var unsafe *n = cast<EvalBlockDecl>(d)
            for var i: usize = 0; i < n->body.size(); ++i {
                self._index_hoist_decl(n->body[i], foreign)
            }

            return
        }

        if isa<FFIBlockDecl>(d) {
            var unsafe *n = cast<FFIBlockDecl>(d)
            for var i: usize = 0; i < n->body.size(); ++i {
                self._index_hoist_decl(n->body[i], true) // ffi block: foreign
            }

            return
        }

        // ImportDecl, TestDecl, ExtensionDecl, error nodes: nothing to hoist.
        // (Extension members are sema's job; hoisting extend bodies flat
        // would pollute the table.)
    }

    /// \brief hoists a type entry, then recurses into its dc_decls with the
    ///        type's name pushed onto the scope path so members land in the
    ///        child trie node (which _wire_scopes later connects to the DC).
    priv fn _index_hoist_type_scope(self,
                                    dc:       unsafe *DeclContext,
                                    name_tok: Token,
                                    kind:     DisambigKind,
                                    generic:  bool,
                                    origin:   SourceRange,
                                    foreign:  bool) {
        var name_str = self.ctx->get_spelling(name_tok)

        var e = DisambigEntry{}
        e.kind        = kind
        e.generic     = generic
        e.is_foreign  = foreign
        e.extended    = false
        e.decl.origin = origin
        self._index_insert(name_str, e)

        if name_str == "" {
            return
        }

        self._index_path.push_back(name_str)
        self._index_hoist_dc_children(dc, foreign)
        self._index_path.pop_back()
    }

    priv fn _index_hoist_dc_children(self, dc: unsafe *DeclContext, foreign: bool) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            self._index_hoist_decl(d, foreign)
        }
    }

    //  Index-mode token skippers: dumb bracket-balanced skips, no grammar.

    /// \brief skips to the end of the current decl/statement: a `;`/newline at
    ///        depth 0, or an unmatched `}` (left unconsumed the enclosing
    ///        walker owns it). Brace/paren/bracket contents are crossed whole.
    fn _index_skip_stmt(self) {
        var depth: u32 = 0
        while !self.is_eof() {
            var k = self.resolve_kind_deep(self._current)
            if depth == 0 {
                if k == TokenKind::OpSemicolon || k == TokenKind::TkNewLine {
                    return
                }

                if k == TokenKind::OpRBrace {
                    return
                }
            }

            if k == TokenKind::OpLBrace || k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                depth += 1
            } else if k == TokenKind::OpRBrace
                || k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare {
                if depth > 0 {
                    depth -= 1
                }
            }

            self.advance_raw()
        }
    }

    /// \brief crosses a type-decl head's tail (heritage, impl, requires) to
    ///        the body without parsing it.
    /// \return true with the `{` consumed, or false at a decl end (newline,
    ///         `;`, unmatched `}` left unconsumed) forward declaration.
    fn _index_skip_to_body(self) -> bool {
        var depth: u32 = 0
        while !self.is_eof() {
            var k = self.resolve_kind_deep(self._current)
            if depth == 0 {
                if k == TokenKind::OpLBrace {
                    self.advance_raw() // consume `{`
                    return true
                }

                if k == TokenKind::OpSemicolon || k == TokenKind::TkNewLine {
                    return false
                }

                if k == TokenKind::OpRBrace {
                    return false
                }
            }

            if k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                depth += 1
            } else if k == TokenKind::OpRParen || k == TokenKind::OpRSquare {
                if depth > 0 {
                    depth -= 1
                }
            }

            self.advance_raw()
        }

        return false
    }

    /// \brief precondition: just inside a `{`. Skips to and consumes the
    ///        matching `}`.
    fn _index_skip_block(self) {
        var depth: u32 = 0
        while !self.is_eof() {
            var k = self.resolve_kind_deep(self._current)
            if k == TokenKind::OpLBrace {
                depth += 1
            } else if k == TokenKind::OpRBrace {
                if depth == 0 {
                    self.advance_raw() // consume `}`
                    return
                }

                depth -= 1
            }

            self.advance_raw()
        }
    }

    //  Token accessors return 16-byte copies (trivial)

    pub inline fn current(self) -> Token {
        if self._current == &null {
            return Token()
        }

        return *self._current
    }

    pub inline fn prev(self) -> Token {
        if self._prev == &null {
            return Token()
        }

        return *self._prev
    }

    pub inline fn peek(self) -> Token {
        if self._peek == &null {
            return Token()
        }

        return *self._peek
    }

    /// \brief provides direct access to the current token pointer.
    /// \warning not for general use; preferred for diagnostics or macro walking.
    pub inline fn current_ptr(self) -> unsafe *Token {
        return self._current
    }

    pub inline fn prev_ptr(self) -> unsafe *Token {
        return self._prev
    }

    pub inline fn peek_ptr(self) -> unsafe *Token {
        return self._peek
    }

    /// \brief the range of the current token, or past EOF a one-byte range
    ///        just after the last token consumed.
    /// \details for diagnostics that report "expected X here": the cursor is
    ///          null once the parser steps off the last token, and
    ///          `current_ptr()->range` there is a null load (fuzzer finds on
    ///          `if if main`, `for `). Anchoring on the previous token keeps
    ///          the error on the line the input actually stopped at.
    pub inline fn current_range(self) -> SourceRange {
        if self._current != &null {
            return self._current->range
        }

        if self._prev != &null {
            return SourceRange::single(self._prev->range.end)
        }

        return SourceRange::invalid()
    }

    //  Cursor movement

    /// \enum SkipNL
    /// \brief controls newline skipping behavior during cursor movement.
    enum SkipNL derives u8 {
        None,   ///< treat newlines as significant tokens.
        Before, ///< consume newlines before performing the move.
        After,  ///< move once, then consume all subsequent newlines.
        Only,   ///< consume newlines without moving the primary cursor index.
    }

    /// # private helpers

    inline fn _skip_nl_fwd(self) {
        while self.current().kind == TokenKind::TkNewLine {
            self._advance()
        }
    }

    inline fn _skip_nl_bwd(self) {
        while self.current().kind == TokenKind::TkNewLine {
            self.retreat()
        }
    }

    /// # public API

    /// \brief moves the cursor forward one token.
    pub inline fn advance(self, const skip: Self::SkipNL = Self::SkipNL::None) {
        match skip {
            case Self::SkipNL::Before {
                self._skip_nl_fwd()
                self._advance()
            } case Self::SkipNL::After {
                self._advance()
                self._skip_nl_fwd()
            } case Self::SkipNL::Only {
                self._skip_nl_fwd()
            } default {
                self._advance()
            }
        }

        if self.nl_depth > 0 {
            self._skip_nl_fwd()
        }
    }

    /// \brief moves the cursor backward one token.
    pub inline fn retreat(self, const skip: Self::SkipNL = Self::SkipNL::None) {
        match skip {
            case Self::SkipNL::Before {
                self._skip_nl_bwd()
                self._retreat()
            } case Self::SkipNL::After {
                self._retreat()
                self._skip_nl_bwd()
            } case Self::SkipNL::Only {
                self._skip_nl_bwd()
            } default {
                self._retreat()
            }
        }
    }

    inline fn _advance(self) {
        self._prev = self._current

        if self.c_idx + 1 < self.span.size() {
            self.c_idx += 1
        } else {
            self._current = &null
            self._peek    = &null
            return
        }

        self._sync_cursor()

        if self._no_comment_skip {
            return
        }

        // Comments never rest under the cursor. Stash and step over any we land
        // on so check()/current() always see a real token. _prev stays the
        // pre-comment token so `start | prev().range` joins don't absorb it.
        while self._current != &null && self._current->kind == TokenKind::AtComment {
            self._stash_comment(self._current)
            if self.c_idx + 1 < self.span.size() {
                self.c_idx += 1
            } else {
                self._current = &null
                self._peek    = &null
                return
            }

            self._sync_cursor()
        }
    }

    inline fn _retreat(self) {
        if self.c_idx == 0 {
            return
        }

        self._peek = self._current
        self.c_idx -= 1
        self._current = self.span.get(self.c_idx)
        self._prev = if (self.c_idx > 0) => (self.span.get(self.c_idx - 1)) else => &null
    }

    /// \brief syncs `_current` and `_peek` from c_idx.
    /// \note must be called after any direct mutation of `c_idx`.
    inline fn _sync_cursor(self) {
        self._current = if (self.c_idx < self.span.size()) => (self.span.get(
                            self.c_idx,
                        ))
                        else => &null
        self._peek = if (self.c_idx + 1 < self.span.size()) => (self.span.get(
                         self.c_idx + 1,
                     ))
                     else => &null
    }

    pub inline fn ig_kind(self) -> TokenKind {
        if self._current == &null {
            return TokenKind::TkEof
        }

        return self.resolve_kind_deep(self._current)
    }

    pub inline fn ig_peek_kind(self) -> TokenKind {
        if self._peek == &null {
            return TokenKind::TkEof
        }

        return self.resolve_kind_deep(self._peek)
    }

    pub inline fn ig_tok(self) -> Token {
        return self.current() // resolved copy semantics preserved by callers
    }

    pub inline fn ig_bump(self) {
        self.advance()
    }

    pub inline fn ig_bump_nl(self) {
        self.advance(Self::SkipNL::After)
    }

    pub inline fn ig_eof(self) -> bool {
        return self.is_eof()
    }

    pub fn ig_err(self, r: SourceRange, const msg: string, code: DiagID) {
        self.diag->report(code, r.start, msg).first(r)->emit()
    }

    pub fn ig_err_remove(self,
                         r:             SourceRange,
                         const msg:     string,
                         code:          DiagID,
                         cut:           SourceRange,
                         const fix_msg: string) {
        var b = self.diag->report(code, r.start, msg)
        b.first(r)
        b.remove(cut, fix_msg)
        b.emit()
    }

    pub fn ig_err_insert(self,
                         r:             SourceRange,
                         const msg:     string,
                         code:          DiagID,
                         at:            SourceRange,
                         const text:    string,
                         const fix_msg: string) {
        var b = self.diag->report(code, r.start, msg)
        b.first(r)
        b.insert(at.start, text, fix_msg)
        b.emit()
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
    pub inline fn resolve_deep(self, tok: unsafe *Token) -> Token {
        // Past EOF the cursor is null; answer TkEof like ig_kind does rather
        // than load through it. resolve_kind_shallow has the same guard.
        if tok == &null {
            return Token(SourceRange::invalid(), TokenKind::TkEof, 0)
        }

        // The cap is a malformed-chain backstop, NOT --cmax-macro-depth: that
        // flag belongs to the preprocessor (it reports R008E itself). Reusing
        // it here made a low value truncate every tail-position chain the
        // preprocessor had already accepted, printing an I002F/S063N pair per
        // token instead of one error. 65536 is the flag's own registry ceiling.
        var u = unwrap_expansion(*tok, self.ctx->tcm, 65536)

        if u.hit_limit {
            self.diag->report(
                DiagID::I002F,
                tok->range.start,
                "excessive iterations during token kind resolution, aborting to prevent infinite loop",
            ).first(tok->range)->note(
                DiagCode(DiagID::S063N),
                tok->range.start,
                f"token kind resolution chain truncated after {u.depth} levels",
            )->emit()
            return Token(tok->range, TokenKind::TkUnknown, 0)
        }

        if u.is_sentinel {
            return Token(tok->range, TokenKind::TkMacroExpand, u.imm)
        }

        return Token(tok->range, u.kind, u.imm)
    }

    /// \brief shorthand for `resolve_deep(tok).kind`.
    pub inline fn resolve_kind_deep(self, tok: unsafe *Token) -> TokenKind {
        return self.resolve_deep(tok).kind
    }

    /// \brief performs a single-step macro resolution.
    pub inline fn resolve_kind_shallow(self, tok: unsafe *Token) -> TokenKind {
        if tok == &null {
            return TokenKind::TkUnknown
        }

        // wrapped non-sentinel token with no table: nothing to resolve with
        if (tok->kind as u32) == (TokenKind::TkMacroExpand as u32)
            && tok->imm < (MacroSentinel::Threshold as u32)
            && self.imm == &null {
            return TokenKind::TkUnknown
        }

        return unwrap_expansion(*tok, self.ctx->tcm, 1).kind
    }

    /// \brief fully resolves a token and automatically skips `AtComment` tokens.
    /// \note will advance the cursor if `AtComment` tokens are encountered.
    pub inline fn resolve_fully(self, tok: unsafe *Token) -> Token {
        if tok == &null {
            return Token()
        }

        var resolved = self.resolve_deep(tok)

        if resolved.kind == TokenKind::AtComment {
            self.advance()
            return self.resolve_fully(self._current)
        }

        return resolved
    }

    //  Token checking unified core + convenience wrappers

    /// \brief internal shared logic for token checking and attribute skipping.
    ///
    /// \param tok            the pointer to the token to check.
    /// \param kind           the expected token kind.
    /// \param advance_on_at  if true, encountering an `AtComment` advances the stream.
    inline fn _resolve_and_check(self,
                                 tok:           unsafe *Token,
                                 kind:          TokenKind,
                                 advance_on_at: bool) -> bool {
        if tok == &null {
            return false
        }

        var resolved      = self.resolve_deep(tok)
        var resolved_kind = resolved.kind

        if resolved_kind == TokenKind::AtComment {
            return false
        }

        if resolved_kind == TokenKind::TkError {
            // the imm of this token stores the expected kind from recovery
            self.diag->report(
                DiagID::S063E,
                tok->range.start,
                f"unexpected token found where '{token_kind_to_readable_string((resolved.imm as TokenKind))}' expected",
            ).first(tok->range)->emit()
            resolved_kind = (resolved.imm as TokenKind)
        }

        return resolved_kind == kind
    }

    /// \brief checks if the current resolved token matches `kind`.
    pub inline fn check(self, kind: TokenKind) -> bool {
        return self._resolve_and_check(self._current, kind, true)
    }

    /// \brief checks if the current resolved token satisfies a predicate.
    pub inline fn check(self, pre: fn (TokenKind) -> bool) -> bool {
        if self._current == &null {
            return false
        }

        var resolved      = self.resolve_deep(self._current)
        var resolved_kind = resolved.kind

        if resolved_kind == TokenKind::AtComment {
            return false
        }

        if resolved_kind == TokenKind::TkError {
            self.diag->report(
                DiagID::S063E,
                self._current->range.start,
                f"unexpected token found where '{token_kind_to_readable_string((resolved.imm as TokenKind))}' expected",
            ).first(self._current->range)->emit()

            resolved_kind = (resolved.imm as TokenKind)
        }

        return pre(resolved_kind)
    }

    /// \brief checks the previous token without advancing the stream.
    pub inline fn check_prev(self, kind: TokenKind) -> bool {
        return self._resolve_and_check(self._prev, kind, false)
    }

    /// \brief checks the lookahead token without advancing the stream.
    pub inline fn check_peek(self, kind: TokenKind) -> bool {
        return self._resolve_and_check(self._peek, kind, true)
    }

    /// \brief advances the cursor if the current token matches `kind`.
    pub inline fn match_tok(self, kind: TokenKind) -> bool {
        if self.check(kind) {
            self.advance()
            return true
        }

        return false
    }

    /// \brief consumes the expected token or emits a diagnostic and returns a `TkError`.
    ///
    /// \details used for mandatory grammar components. if the token does not match,
    ///          a placeholder error token is returned to allow the parse to continue
    ///          with local recovery.
    pub inline fn expect(self, kind: TokenKind) -> Token {
        var unsafe *tok = self._current
        if tok == &null {
            // unexpected EOF emit diag with best available location
            var eof_range = if (self._prev != &null) => (self._prev->range)
                            else => SourceRange::invalid()
            self.diag->report(
                DiagID::S063E,
                eof_range.start,
                f"expected '{token_kind_to_readable_string(kind)}', found end of file",
            ).first(eof_range)->emit()

            var err = Token()
            err.kind  = TokenKind::TkError
            err.range = eof_range
            err.imm   = (kind as u32)
            return err
        }

        var resolved      = self.resolve_deep(tok)
        var resolved_kind = resolved.kind

        if resolved_kind == TokenKind::AtComment {
            self.advance() // advance skips+stashes; re-expect on the real token
            return self.expect(kind)
        }

        if resolved_kind == TokenKind::TkError {
            // recovery token extract what was expected
            resolved_kind = (resolved.imm as TokenKind)
        }

        if resolved_kind == kind {
            self.advance()
            return resolved
        }

        self.report_tok(
            DiagID::S063E,
            tok,
            f"expected '{token_kind_to_readable_string(kind)}', found '{token_kind_to_readable_string(resolved_kind)}'",
        )

        var err = Token()
        err.kind  = TokenKind::TkError
        err.range = tok->range
        err.imm   = (kind as u32)
        return err
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
    pub inline fn report_tok(self, id: DiagID, tok: unsafe *Token, const msg: string) {
        if tok == &null {
            self.diag->report(id, msg).emit()
            return
        }

        var wrapped = (tok->kind as u32) == (TokenKind::TkMacroExpand as u32)
            && tok->imm < (MacroSentinel::Threshold as u32)
            && self.imm != &null

        if !wrapped {
            self.diag->report(id, tok->range.start, msg).first(tok->range)->emit()
            return
        }

        var unsafe *info = self.imm->get<Immediate::MacroExpansionInfo>(
            tok->imm,
        )

        var invoke = info->invoke_range

        if !invoke.is_valid() {
            // degenerate record; fall back to the def-site range
            self.diag->report(id, tok->range.start, msg).first(tok->range)->emit()
            return
        }

        var name         = self.ctx->sm->get_text(invoke)
        var tail: string = " (in a macro expansion)"
        if name.length() > 0 && name.length() <= 64 {
            // invoke spans the WHOLE invocation (name, `!`, and any args), so
            // name already reads e.g. "foo!" or "error!(\"yes\")" -- no extra
            // '!' here, or a bare invocation renders as "foo!!" .
            tail = f" (in expansion of macro '{name}')"
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
        var def     = info->def_range
        var use_def = def.is_valid() && def.start.raw() != invoke.start.raw()
        var primary = if (use_def) => (def) else => invoke

        var builder = self.diag->report(id, primary.start, f"{msg}{tail}")
        builder.first(primary)

        if invoke.start.raw() != self._last_exp_diag_loc {
            self._last_exp_diag_loc = invoke.start.raw()
            self.attach_macro_expansion_chain(&builder, tok, !use_def)
        }

        builder.emit()
    }

    /// \brief appends notes to a diagnostic builder showing the macro expansion history.
    ///
    /// \param skip_innermost drops the note for the FIRST record walked (the
    ///        innermost invocation). Set by callers that already placed the
    ///        primary caret on that same invocation range, so the backtrace
    ///        starts one hop out instead of restating the primary.
    pub inline fn attach_macro_expansion_chain(self,
                                               builder:        *DiagBuilder,
                                               tok:            unsafe *Token,
                                               skip_innermost: bool = false) {
        if tok == &null {
            return
        }

        if self.imm == &null {
            return
        }

        if (tok->kind as u32) != (TokenKind::TkMacroExpand as u32) {
            return
        }

        var kind       = tok->kind
        var imm        = tok->imm
        var depth: u32 = 0

        while (kind as u32) == (TokenKind::TkMacroExpand as u32) {
            // PP already reported the real error at the invocation site; adding a
            // chain here would double-report. Stay silent.
            if imm == (MacroSentinel::Poison as u32) {
                return
            }

            // todo!/unreachable!/include! etc. carry no expansion info to walk.
            if imm >= (MacroSentinel::Threshold as u32) {
                return
            }

            if depth >= (self.ctx->ci->pp.max_backtrace as u32) {
                builder->note(
                    tok->range.start,
                    f"macro expansion chain truncated after {depth} levels",
                )

                return
            }

            var unsafe *info = self.imm->get<Immediate::MacroExpansionInfo>(imm)
            if info == &null {
                return
            }

            // Primary already sits on the failing token in the macro body; the chain
            // walks OUTWARD through invocation sites toward user code.
            // invoke_range spans the WHOLE invocation (name, `!`, any args), so
            // mname already reads e.g. "foo!" -- no extra '!' in the template.
            var mname = self.ctx->sm->get_text(info->invoke_range)
            if depth == 0 && skip_innermost {
                0 // caller's primary already sits on this exact range
            } else if mname.length() > 0 && mname.length() <= 64 {
                builder->note(
                    info->invoke_range.start,
                    f"in expansion of macro '{mname}' invoked here",
                )->child_first(info->invoke_range)
            } else {
                builder->note(
                    info->invoke_range.start,
                    f"in a macro expansion invoked here (depth {depth})",
                )->child_first(info->invoke_range)
            }

            kind = info->original_kind
            imm  = info->original_imm
            depth += 1
        }
    }

    //  EOF / first-token queries

    pub inline fn is_eof(self) -> bool {
        return self._depth_aborted
            || self._current == &null
            || self._current->kind == TokenKind::TkEof
    }

    /// \brief returns the absolute first token of the stream for indexing.
    pub inline fn first(self) -> unsafe *Token {
        if self.span.size() > 0 {
            return self.span.get(0)
        }

        return &null
    }

    //  Parameter passing modes (AST/ParamMode.k)

    /// `@inout` / `@move` at the cursor, or Value. Does not consume.
    ///
    /// A mode is `@` + identifier, the same two tokens an attribute opens
    /// with, so every caller must ask BEFORE consume_leading_annotations
    /// runs; after it the mode has been swallowed as an attribute.
    pub fn _peek_mode(self) -> ParamMode {
        if !self.check(TokenKind::OpAt) {
            return ParamMode::Value
        }

        if !self.check_peek(TokenKind::LitIdentifier) {
            return ParamMode::Value
        }

        var sp = self.ctx->get_spelling(self.peek())
        if sp == LangAttrs::param_inout() {
            return ParamMode::Inout
        }

        if sp == LangAttrs::param_move() {
            return ParamMode::Move
        }

        return ParamMode::Value
    }

    /// Consume the two tokens of a mode the caller peeked; returns the range
    /// spanning both.
    pub fn _consume_mode(self) -> SourceRange {
        var r = self.current_ptr()->range
        self.advance() // consume `@`
        r = r | self.current_ptr()->range
        self.advance() // consume `inout` / `move`
        return r
    }

    /// Rejection helper for binding sites: if a mode is at the cursor, report
    /// it, consume it, and return true. Consuming is the recovery -- the
    /// binding that follows parses as if the mode were never written.
    pub fn _reject_mode_binding(self) -> bool {
        if self._peek_mode() == ParamMode::Value {
            return false
        }

        var r = self._consume_mode()
        self.diag->report(
            DiagID::S069E,
            r.start,
            f"{LangAttrs::quoted(LangAttrs::param_inout())} and {LangAttrs::quoted(LangAttrs::param_move())} are parameter passing modes; a mode can only be written on a function or closure parameter",
        ).first(r)->emit()
        return true
    }

    //  Annotation consumption

    /// \brief at an `@` that starts a statement: true when the attribute (or
    ///        a same-line run of them) applies to an expression, so the
    ///        statement is an expression statement over an AttributedExpr.
    ///  Lookahead:  ( '@' name ( '(' ... ')' )? )+  X
    ///  true iff X is on the same line and begins an expression: not a
    ///  newline / `;` / EOF, not `{` or `}`, not a declaration lead, not a
    ///  statement keyword (`if`, `for`, `match`, `return`, `try`, `default`,
    ///  ...), not `unsafe {`, and not a loop label (`name:`).
    ///
    /// \details `@destroy p` and `@create T()` are expression attributes
    ///          (attributes.mdx, tether-promotion.mdx); the
    ///          annotation pass must not take them as statement attributes
    ///          named `destroy` / `create` on the statement `p` / `T()`, which
    ///          would accept them silently. What stays a statement attribute is
    ///          what has no expression to attach to: a declaration (`@copy
    ///          fn`, `@deprecated var`), a keyword statement (`@likely if`),
    ///          a block (`@repeat(3) { }`), and an attribute on a line of its
    ///          own, which attaches to whatever follows (`@always_inline` NL
    ///          `fn`). Only a plain name: the expression grammar reads no
    ///          `a::b` attribute path. The guard rolls back unconditionally.
    pub fn _attr_opens_expr_stmt(self) -> bool {
        var t            = Self::TentativeGuard(&self)
        var destroy_call = false
        while self.check(TokenKind::OpAt) {
            self.advance() // `@`
            if !self.check(TokenKind::LitIdentifier) {
                return false
            }

            // `@destroy(p)` is the whole expression: nothing follows it, and
            // without this the newline would make it a statement attribute
            // on the NEXT line's statement.
            var anm = self.ctx->get_spelling(self.current())
            destroy_call = anm == LangAttrs::destroy()
            self.advance() // the name
            // `@cxx::new ...` / `@cxx::delete p`: an expression statement.
            if anm == LangAttrs::cxx_mem() && self.check(TokenKind::OpColonColon) {
                self.advance() // `::`
                if self.check(TokenKind::KwDelete) {
                    return true
                }

                return self.check(TokenKind::LitIdentifier)
                    && self.ctx->get_spelling(self.current()) == LangAttrs::cxx_new()
            }

            if self.check(TokenKind::OpColonColon) {
                return false
            }

            if !self.check(TokenKind::OpLParen) {
                destroy_call = false
            }

            if self.check(TokenKind::OpLParen) {
                var depth: u32 = 0
                while !self.is_eof() {
                    var pk = self.resolve_kind_deep(self._current)
                    if pk == TokenKind::OpLParen {
                        depth += 1
                    } else if pk == TokenKind::OpRParen {
                        depth -= 1
                        if depth == 0 {
                            self.advance()
                            break
                        }
                    }

                    self.advance_raw()
                }
            }
        }

        if self.is_eof() || self._is_terminator_tok(self._current) {
            return destroy_call
        }

        var k = self.resolve_kind_deep(self._current)
        if destroy_call && k == TokenKind::OpRBrace {
            return true
        }

        if k == TokenKind::OpLBrace || k == TokenKind::OpRBrace {
            return false
        }

        if self._starts_decl_here(k) {
            return false
        }

        if k == TokenKind::KwIf
            || k == TokenKind::KwWhile
            || k == TokenKind::KwLoop
            || k == TokenKind::KwFor
            || k == TokenKind::KwMatch
            || k == TokenKind::KwReturn
            || k == TokenKind::KwBreak
            || k == TokenKind::KwContinue
            || k == TokenKind::KwPanic
            || k == TokenKind::KwYield
            || k == TokenKind::KwAssert
            || k == TokenKind::KwTry
            || k == TokenKind::KwFinally
            || k == TokenKind::KwDefault
            || k == TokenKind::KwCase
            || k == TokenKind::KwElse
            || k == TokenKind::KwCatch {
            return false
        }

        if k == TokenKind::KwUnsafe && self.check_peek(TokenKind::OpLBrace) {
            return false
        }

        if k == TokenKind::LitIdentifier && self.check_peek(TokenKind::OpColon) {
            return false
        }

        return true
        // guard dtor rolls back unconditionally (never commit)
    }

    /// \brief what attribute, if any, sits between a branch's `}` and the
    ///        `else` that follows it: 0 none, 1 `@likely`, 2 `@unlikely`,
    ///        3 any other name.
    ///
    /// \details `} @unlikely else {`, with the attribute and `else` possibly
    ///          on lines of their own. Only an attribute that IS followed by
    ///          `else` counts: `@x` before anything else belongs to the next
    ///          statement, so it must be left unconsumed. The guard rolls back
    ///          unconditionally; the caller consumes what this found.
    pub fn _else_attr_kind(self) -> u32 {
        var t = Self::TentativeGuard(&self)
        if self.nl_depth == 0 && self.check(TokenKind::TkNewLine) {
            self.advance(Self::SkipNL::Only)
        }

        if !self.check(TokenKind::OpAt) {
            return 0
        }

        self.advance() // `@`
        if !self.check(TokenKind::LitIdentifier) {
            return 0
        }

        var name = self.ctx->hoisted->intern_tok(self.current())
        self.advance(Self::SkipNL::After) // the name, and any newlines
        if !self.check(TokenKind::KwElse) {
            return 0
        }

        if name == self.ctx->hoisted->intern(LangAttrs::likely()) {
            return 1
        }

        if name == self.ctx->hoisted->intern(LangAttrs::unlikely()) {
            return 2
        }

        return 3
        // guard dtor rolls back unconditionally (never commit)
    }

    /// \brief true at `@set_global_allocator (`. The guard rolls back
    ///        unconditionally.
    pub fn _global_alloc_ahead(self) -> bool {
        var t = Self::TentativeGuard(&self)
        if !self.check(TokenKind::OpAt) {
            return false
        }

        self.advance() // `@`
        if !self.check(TokenKind::LitIdentifier) {
            return false
        }

        if self.ctx->hoisted->intern_tok(self.current()) != self.ctx->hoisted->intern(
            LangAttrs::set_global_allocator(),
        ) {
            return false
        }

        self.advance() // `set_global_allocator`
        return self.check(TokenKind::OpLParen)
        // guard dtor rolls back unconditionally (never commit)
    }

    /// \brief `@set_global_allocator(A)` at file scope: A as a private
    ///        TypeAliasDecl of the file (LowerTargets::global_allocator_alias),
    ///        recorded as TranslationUnit::global_alloc.
    ///
    /// \details An alias rather than a field holding a Type, so N and T
    ///          resolve A where it is written, with every diagnostic a
    ///          written type gets, and EmitPlan lays A out like any type the
    ///          file names. The argument is a TYPE, parsed by the type parser
    ///          (`a::Arena<4096>`), not the call-argument grammar the
    ///          annotation buffer uses. A file sets it once; a link, once
    ///          (CompilerInstance::_reject_second_global_allocator, and kld
    ///          for objects built apart). \p annot is what stood before it:
    ///          nothing there has a declaration to apply to.
    priv fn _parse_global_allocator(self,
                                    program: unsafe *Program,
                                    annot:   unsafe *Self::PendingAnnotations) {
        var at = self._current->range
        self.advance() // `@`
        self.advance() // `set_global_allocator`
        var lparen = self._current->range
        self.advance(Self::SkipNL::After) // `(`
        var unsafe *ty = self.parse_type()
        var        end = self._prev->range
        if self.check(TokenKind::OpRParen) {
            end = self._current->range
            self.advance_raw()
        } else {
            self.diag->report(
                DiagID::S051E,
                lparen.start,
                "expected ')' to close '" + LangAttrs::at(
                    LangAttrs::set_global_allocator(),
                ) + "('",
            ).first(lparen)->emit()
            while !self.is_eof()
                && !self._is_terminator_tok(self._current)
                && !self.check(TokenKind::OpRParen) {
                self.advance_raw()
            }

            if self.check(TokenKind::OpRParen) {
                self.advance_raw()
            }
        }

        var whole = at | end
        if self.mode != Self::ParseMode::Full {
            return
        }

        for var i: usize = 0; i < annot->entries.size(); ++i {
            var unsafe *e = unsafe &annot->entries[i]
            if e->kind != AnnotationKind::Attribute {
                continue
            }

            var b = self.diag->report(
                DiagID::SC139E,
                e->range.start,
                "an attribute cannot be applied to " + LangAttrs::quoted(
                    LangAttrs::set_global_allocator(),
                ) + "; it declares nothing",
            )

            b.first(e->range)
            b.remove(e->range, "remove the attribute")
            b.emit()
        }

        if annot->visibility != VisibilityKind::None {
            self.diag->report(
                DiagID::S048E,
                annot->vis_range.start,
                "a visibility modifier cannot be applied to " + LangAttrs::quoted(
                    LangAttrs::set_global_allocator(),
                ),
            ).first(annot->vis_range)->emit()
        }

        if ty == &null || is_recovery(ty) {
            self.diag->report(
                DiagID::S052E,
                lparen.start,
                "expected the allocator type: '" + LangAttrs::at(
                    LangAttrs::set_global_allocator(),
                ) + "(MyAllocator)'",
            ).first(whole)->emit()
            return
        }

        if self.tu->global_alloc != &null {
            var b = self.diag->report(
                DiagID::SC138E,
                at.start,
                "the global allocator is already set in this file; a program has one",
            )

            b.first(whole)
            b.note(
                DiagCode(DiagID::SC138N),
                self.tu->global_alloc_at.start,
                "set here first",
            )->child_first(self.tu->global_alloc_at)
            b.remove(
                whole,
                "remove the second " + LangAttrs::quoted(
                    LangAttrs::set_global_allocator(),
                ),
            )

            b.emit()
            return
        }

        var unsafe *imms = self.ctx->get_imm_table()
        if imms == &null {
            return
        }

        var tok = Token()
        tok.kind  = TokenKind::LitIdentifier
        tok.range = whole
        tok.imm = imms->intern_ident_copy(
            LowerTargets::global_allocator_alias(),
        )

        var unsafe *ta = TypeAliasDecl::create(self.ctx, whole, tok, ty)
        var unsafe *d  = unsafe (ta as unsafe *Decl)
        // Private: the alias is this file's, never part of its module's
        // interface, so two modules that each name one cannot collide.
        var vis: Self::PendingAnnotations
        vis.set_visibility(VisibilityKind::Private, whole)
        self.apply_annotations_to_decl(d, unsafe &vis)

        self.tu->add_decl(d)
        program->add_item(TopLevelItem::from_decl(d))
        self.tu->global_alloc    = d
        self.tu->global_alloc_at = whole
    }

    /// \brief SC001E for an `@set_global_allocator` the annotation buffer
    ///        took (not at file scope, or after another attribute's
    ///        target): it applies to nothing there, and dropping it would
    ///        leave the program on System without a word.
    priv fn _reject_global_alloc_attr(self, annot: unsafe *Self::PendingAnnotations) {
        if self.mode != Self::ParseMode::Full {
            return
        }

        var k = self.ctx->hoisted->intern(LangAttrs::set_global_allocator())
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            if e->kind != AnnotationKind::Attribute || e->name != k {
                continue
            }

            var b = self.diag->report(
                DiagID::SC139E,
                e->range.start,
                LangAttrs::quoted(
                    LangAttrs::set_global_allocator(),
                ) + " stands on a line of its own at file scope; it is not an attribute of a declaration or statement",
            )

            b.first(e->range)
            b.emit()
        }
    }

    /// \brief true at `@assume (`: the free-standing `@assume(cond)`
    ///        statement (StmtParse::_parse_assume), which takes no part in
    ///        the attribute buffer. The guard rolls back unconditionally.
    pub fn _assume_ahead(self) -> bool {
        var t = Self::TentativeGuard(&self)
        if !self.check(TokenKind::OpAt) {
            return false
        }

        self.advance() // `@`
        if !self.check(TokenKind::LitIdentifier) {
            return false
        }

        if self.ctx->hoisted->intern_tok(self.current()) != self.ctx->hoisted->intern(
            LangAttrs::assume(),
        ) {
            return false
        }

        self.advance() // `assume`
        return self.check(TokenKind::OpLParen)
        // guard dtor rolls back unconditionally (never commit)
    }

    /// \brief consumes doc-comments, @attributes, and visibility keywords
    ///        before a production into a PendingAnnotations buffer.
    ///
    /// \details attribute args reuse the call-argument grammar verbatim,
    ///          including named args (`@ser(do_sum: true)`); the attr pass
    ///          distinguishes named/positional exactly like call sema does.
    ///          A visibility keyword followed by `{` is NOT consumed it
    ///          is the lead-in of a visibility group decl, owned by DeclParse.
    ///
    /// \param stmt_pos the production is a statement (a function body, or
    ///        file scope), where an `@name` may instead open an expression
    ///        statement: _attr_opens_expr_stmt decides, and when it does the
    ///        `@` is left for the expression parser (AttributedExpr).
    ///
    /// \param file_scope the top-level loop: `@set_global_allocator(` stops
    ///        the buffer there, for _parse_global_allocator to take.
    pub fn consume_leading_annotations(self,
                                       out:        unsafe *Self::PendingAnnotations,
                                       stmt_pos:   bool = false,
                                       file_scope: bool = false) {
        out->clear()

        self._collect_leading_comments(out)

        var prev_flag = self._no_comment_skip
        self._no_comment_skip = true

        while !self.is_eof() {
            var unsafe *tok = self._current
            if tok == &null {
                break
            }

            var resolved = self.resolve_deep(tok)

            if resolved.kind == TokenKind::AtComment {
                out->add(
                    self._comment_kind_from_imm(tok->imm),
                    u32::MAX,
                    tok->range,
                )

                self.advance()
                if self._current != &null
                    && self.resolve_kind_shallow(self._current) == TokenKind::TkNewLine {
                    // a blank line detaches everything above it (a license
                    // banner), exactly as _collect_leading_comments does.
                    if self._current->imm >= 2 {
                        self._drop_comment_entries(out)
                    }

                    self.advance_raw()
                }

                continue
            }

            /// ## @attribute ( args? )
            if resolved.kind == TokenKind::OpAt && stmt_pos && self._attr_opens_expr_stmt() {
                break
            }

            if resolved.kind == TokenKind::OpAt && file_scope && self._global_alloc_ahead() {
                break
            }

            if resolved.kind == TokenKind::OpAt {
                var at_range = tok->range
                self.advance() // consume `@`

                if !self.check(TokenKind::LitIdentifier) {
                    self.diag->report(
                        DiagID::S046E,
                        at_range.start,
                        "expected attribute name after '@'",
                    ).first(at_range)->emit()
                    continue // `@` consumed; forward progress made
                }

                var name_tok = self.current()
                var name     = self.ctx->hoisted->intern_tok(name_tok)
                self.advance() // consume identifier

                var end_range = name_tok.range
                var frozen    = create_empty_frozen_list<unsafe *Expr>()

                if self.check(TokenKind::OpLParen) {
                    var lparen = self.current_ptr()->range
                    self.advance(Self::SkipNL::After) // consume `(`
                    self.nl_push()

                    var args: kairo::std::StackBuf<unsafe *Expr, 8>
                    if !self.check(TokenKind::OpRParen) {
                        self._parse_call_args(unsafe &args, lparen)
                    }

                    self.nl_pop()
                    if self.check(TokenKind::OpRParen) {
                        end_range = self.current_ptr()->range
                        self.advance_raw()
                    } else {
                        self.diag->report(
                            DiagID::S051E,
                            lparen.start,
                            "expected ')' to close attribute argument list",
                        ).first(lparen)->emit()
                        // _parse_call_args already synced
                    }

                    frozen.from_buf(args.data(), (args.size() as usize), self.ctx)
                }

                out->add_attr(name, at_range | end_range, frozen)
                self._skip_nl_fwd() // an attribute attaches to the next decl/stmt;
                // a newline between `@attr` and its target is
                // never significant. without this the top-level
                // parse() loop sees the NL as the decl lead.
                continue
            }

            /// ## visibility
            if resolved.kind == TokenKind::KwPub
                || resolved.kind == TokenKind::KwPriv
                || resolved.kind == TokenKind::KwProt {
                // `pub {` is a visibility group, not a modifier leave it.
                if self.check_peek(TokenKind::OpLBrace) {
                    break
                }

                var vk = VisibilityKind::Public
                if resolved.kind == TokenKind::KwPriv {
                    vk = VisibilityKind::Private
                } else if resolved.kind == TokenKind::KwProt {
                    vk = VisibilityKind::Protected
                }

                out->set_visibility(vk, tok->range)
                self.advance()
                continue
            }

            break
        }

        self._no_comment_skip = prev_flag
    }

    priv fn _comment_kind_from_imm(self, imm: u32) -> AnnotationKind {
        match imm {
            case 1 {
                return AnnotationKind::DocComment
            } case 2 {
                return AnnotationKind::LineComment
            } case 3 {
                return AnnotationKind::BlockComment
            } default {
                return AnnotationKind::DocComment
            }
        }
    }

    /// \brief removes the comment entries gathered so far, keeping attributes.
    priv fn _drop_comment_entries(self, out: unsafe *Self::PendingAnnotations) {
        var kept = cxx::std::vector<AnnotationEntry>()
        for var i: usize = 0; i < out->entries.size(); ++i {
            if out->entries[i].kind == AnnotationKind::Attribute {
                kept.push_back(out->entries[i])
            }
        }

        out->entries = kept
    }

    /// \brief a comment that opens its own line is not a trailing comment.
    priv fn _comment_opens_line(self) -> bool {
        if self.c_idx == 0 {
            return true
        }

        return self.resolve_kind_shallow(self.span.get(self.c_idx - 1)) == TokenKind::TkNewLine
    }

    /// \brief the comments directly above the cursor become its leading
    ///        annotations: the contiguous run of own-line comments that follows
    ///        the previous code token, minus anything a blank line cuts off.
    ///
    /// \details read straight off the token span instead of being remembered
    ///          while stepping: _advance steps over every comment it lands on,
    ///          so a pending list could not tell a doc block from a comment
    ///          buried in the middle of an expression, and a stash would hand
    ///          such comments to whichever declaration was parsed next. A
    ///          comment that shares its line with the previous code token is
    ///          that token's trailing comment (_attach_trailing), never ours.
    priv fn _collect_leading_comments(self, out: unsafe *Self::PendingAnnotations) {
        if self._current == &null || self.c_idx == 0 {
            return
        }

        var j = self.c_idx
        while j > 0 {
            var k = self.resolve_kind_shallow(self.span.get(j - 1))
            if k != TokenKind::TkNewLine && k != TokenKind::AtComment {
                break
            }

            --j
        }

        for var t: usize = j; t < self.c_idx; ++t {
            var unsafe *tok = self.span.get(t)
            var        k    = self.resolve_kind_shallow(tok)
            if k == TokenKind::TkNewLine {
                if tok->imm >= 2 {
                    self._drop_comment_entries(out)
                }

                continue
            }

            if t > 0 {
                var pk = self.resolve_kind_shallow(self.span.get(t - 1))
                if pk != TokenKind::TkNewLine && pk != TokenKind::AtComment {
                    continue
                }
            }

            out->add(
                self._comment_kind_from_imm(tok->imm),
                u32::MAX,
                tok->range,
            )
        }
    }

    pub fn _stash_comment(self, tok: unsafe *Token) {
        if tok == &null {
            return
        }

        // an own-line comment belongs to what follows (_collect_leading_comments).
        if self._comment_opens_line() {
            return
        }

        var pc = PendingComment{}
        pc.kind  = self._comment_kind_from_imm(tok->imm)
        pc.range = tok->range
        self._pending_trailing.push_back(pc)
    }

    priv fn _absorb_trailing_comments(self) {
        while self._current != &null
            && self.resolve_kind_shallow(self._current) == TokenKind::AtComment {
            self._stash_comment(self._current)
            self._advance()
        }
    }

    /// Resolved through the whole expansion chain: a `;` that a macro body
    /// produced through another macro (`outer!()` expanding to `semi!()`)
    /// is wrapped twice, and one step left it a TkMacroExpand, so a
    /// statement ended by it read "expected expression, found ';'".
    /// No report on a truncated chain here: resolve_deep owns that, at the
    /// token's real use.
    pub inline fn _is_terminator_tok(self, t: unsafe *Token) -> bool {
        if t == &null {
            return false
        }

        var k = t->kind
        if (k as u32) == (TokenKind::TkMacroExpand as u32) {
            if t->imm < (MacroSentinel::Threshold as u32) && self.imm == &null {
                return false
            }

            k = unwrap_expansion(*t, self.ctx->tcm, 65536).kind
        }

        return k == TokenKind::TkNewLine || k == TokenKind::OpSemicolon
    }

    pub fn _attach_trailing(self, n: unsafe *Decl) {
        self._absorb_trailing_comments()
        for var i: usize = 0; i < self._pending_trailing.size(); ++i {
            var *c = &self._pending_trailing[i]
            n->add_annotation(c->kind, u32::MAX, c->range)
        }

        self._pending_trailing.clear()
    }

    pub fn _attach_trailing(self, n: unsafe *Stmt) {
        self._absorb_trailing_comments()
        for var i: usize = 0; i < self._pending_trailing.size(); ++i {
            var *c = &self._pending_trailing[i]
            n->add_annotation(c->kind, u32::MAX, c->range)
        }

        self._pending_trailing.clear()
    }

    /// \brief `@no_warn(CODE)` over the warnings this parse already reported
    ///        inside \p decl.
    ///
    /// \details Sema registers every `@no_warn` scope before its first pass
    ///          (AttributeCheck::register_suppressions), but the parser's own
    ///          warnings (S055W on a nested nullable) are reported while the
    ///          declaration is still being parsed, before its range or its
    ///          attributes are known, and are drained before Sema runs. So the
    ///          scope is applied here as well, the moment the declaration is
    ///          complete: BufferedDiagSink::quiet_in drops the matching
    ///          warnings still buffered. Only valid warning codes; a bad one is
    ///          AttributeCheck's error. The lexer and preprocessor report to
    ///          the engine directly, so their warnings are not covered.
    priv fn _quiet_parse_warnings(self,
                                  decl:  unsafe *Decl,
                                  annot: unsafe *Self::PendingAnnotations) {
        var k_nw = self.ctx->hoisted->intern(LangAttrs::no_warn())
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            if e->kind != AnnotationKind::Attribute || e->name != k_nw {
                continue
            }

            for var j: usize = 0; j < e->args.size(); ++j {
                var unsafe *a   = e->args[j]
                var        text = ""
                if a != &null && isa<NamedIdentExpr>(a) {
                    text = self.ctx->get_spelling(cast<NamedIdentExpr>(a)->name)
                } else if a != &null && isa<StringLiteralExpr>(a) {
                    var sp = self.ctx->get_spelling(a->range)
                    if sp.size() >= 2 && sp[0] == ('"' as u8) && sp[sp.size() - 1] == ('"' as u8) {
                        var inner: string = sp.subslice(1, sp.size() - 2)
                        text = inner
                    }
                }

                if text.size() == 0 {
                    continue
                }

                var id = diag_from_code(text)
                if id == DiagID::Invalid {
                    continue
                }

                var c = DiagCode(id)
                if c.severity() != DiagSeverity::Warning {
                    continue
                }

                self.diag->quiet_in(
                    diag_policy_key(c.category(), c.number()),
                    decl->range,
                )
            }
        }
    }

    /// \brief transfers annotations and visibility to a declaration.
    pub fn apply_annotations_to_decl(self,
                                     decl:  unsafe *Decl,
                                     annot: unsafe *Self::PendingAnnotations) {
        if annot->empty() {
            return
        }

        self._reject_global_alloc_attr(annot)

        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            decl->add_annotation(e->kind, e->name, e->range, e->args)
        }

        self._quiet_parse_warnings(decl, annot)

        // `@copy fn T(self, other: Self)` / `@move ...`: the transfer-ctor
        // attribute IS the TransferKind. Everything downstream (ClassLifecycle,
        // the printer, codegen) reads FunctionDecl::transfer and never the
        // attribute, so it is stamped here, where every decl's annotations
        // land -- in-class, out-of-line, and nested alike. Without it a Kairo
        // transfer ctor is an ordinary method and the lifecycle rules are blind.
        if isa<FunctionDecl>(decl) {
            var unsafe *fd = cast<FunctionDecl>(decl)
            var k_copy = self.ctx->hoisted->intern(LangAttrs::transfer_copy())
            var k_move = self.ctx->hoisted->intern(LangAttrs::transfer_move())
            for var i: usize = 0; i < annot->entries.size(); ++i {
                var *e = &annot->entries[i]
                if e->kind != AnnotationKind::Attribute {
                    continue
                }

                if e->name == k_copy {
                    fd->transfer = TransferKind::Copy
                }

                if e->name == k_move {
                    fd->transfer = TransferKind::Move
                }
            }
        }

        // `@open enum E`: EnumDecl::is_open, the one field the niche, the
        // checked `as` and match lowering read. Anywhere else the attribute
        // means nothing, and silently ignoring it would let a reader believe
        // an ADT or a struct had been opened.
        var k_open = self.ctx->hoisted->intern(LangAttrs::open_enum())
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            if e->kind != AnnotationKind::Attribute || e->name != k_open {
                continue
            }

            var unsafe *oe = dyn_cast<EnumDecl>(decl)
            if oe != &null && !oe->is_adt {
                oe->is_open = true
                continue
            }

            if self.mode != Self::ParseMode::Full { // the Full parse reports it once.
                continue
            }

            var what = if (oe != &null) => ("an ADT enum: no cast makes its tag, so it is always closed")
                       else => "this declaration; only a plain enum can be open"
            var an = "'@" + LangAttrs::open_enum() + "'"
            var b = self.diag->report(
                DiagID::SC143E,
                e->range.start,
                an + " does not apply to " + what,
            )

            b.first(e->range)
            b.note(decl->range.start, "the attribute is on this declaration")
            b.remove(e->range, "remove " + an)
            b.emit()
        }

        // `@hot_path` / `@cold_path` / `@pure`: stamped on the
        // function, which is what codegen and FnPurityCheck read (never the
        // attribute list). On anything else the attribute means nothing, and
        // ignoring it silently would let a reader believe a variable or a
        // type had been given a hint.
        var        k_hot     = self.ctx->hoisted->intern(LangAttrs::hot_path())
        var        k_cold    = self.ctx->hoisted->intern(LangAttrs::cold_path())
        var        k_pure    = self.ctx->hoisted->intern(LangAttrs::pure_fn())
        var        k_noin    = self.ctx->hoisted->intern(LangAttrs::no_inline())
        var unsafe *fnd      = dyn_cast<FunctionDecl>(decl)
        var        hot_seen  = false
        var        cold_at   = SourceRange()
        var        cold_seen = false
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            if e->kind != AnnotationKind::Attribute {
                continue
            }

            var fa = ""
            if e->name == k_hot {
                fa = LangAttrs::hot_path()
            } else if e->name == k_cold {
                fa = LangAttrs::cold_path()
            } else if e->name == k_pure {
                fa = LangAttrs::pure_fn()
            } else if e->name == k_noin {
                fa = LangAttrs::no_inline()
            }

            if fa.size() == 0 {
                continue
            }

            if fnd != &null {
                if e->name == k_hot {
                    fnd->hot_path = true
                    hot_seen      = true
                } else if e->name == k_cold {
                    fnd->cold_path = true
                    cold_seen      = true
                    cold_at        = e->range
                } else if e->name == k_noin {
                    fnd->no_inline = true
                } else {
                    fnd->is_pure   = true
                    fnd->purity_at = e->range
                }

                continue
            }

            if self.mode != Self::ParseMode::Full { // the Full parse reports it once.
                continue
            }

            var an = "'@" + fa + "'"
            var b = self.diag->report(
                DiagID::SC143E,
                e->range.start,
                an + " applies only to a function",
            )

            b.first(e->range)
            b.note(decl->range.start, "the attribute is on this declaration")
            b.remove(e->range, "remove " + an)
            b.emit()
        }

        // `@preserve_most` / `@preserve_all` / `@preserve_none`: the calling
        // convention, stamped like the hints above. A function has one
        // convention, so a second, different one is an error naming both;
        // where a convention may stand at all is CallConvCheck's (it needs
        // types: a generator is known only once its return is resolved).
        var k_pm = self.ctx->hoisted->intern(LangAttrs::preserve_most())
        var k_pa = self.ctx->hoisted->intern(LangAttrs::preserve_all())
        var k_pn = self.ctx->hoisted->intern(LangAttrs::preserve_none())
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            if e->kind != AnnotationKind::Attribute {
                continue
            }

            var cc: u8 = 0
            if e->name == k_pm {
                cc = 1
            } else if e->name == k_pa {
                cc = 2
            } else if e->name == k_pn {
                cc = 3
            }

            if cc == 0 {
                continue
            }

            var an = "'@" + LangAttrs::call_conv_name(cc) + "'"
            if fnd == &null {
                if self.mode != Self::ParseMode::Full {
                    continue
                }

                var b = self.diag->report(
                    DiagID::SC143E,
                    e->range.start,
                    an + " applies only to a function",
                )

                b.first(e->range)
                b.note(
                    decl->range.start,
                    "the attribute is on this declaration",
                )

                b.remove(e->range, "remove " + an)
                b.emit()
                continue
            }

            if fnd->call_conv != 0 && fnd->call_conv != cc {
                if self.mode == Self::ParseMode::Full {
                    var pn = "'@" + LangAttrs::call_conv_name(fnd->call_conv) + "'"
                    var b = self.diag->report(
                        DiagID::SC133E,
                        e->range.start,
                        pn + " and " + an + " cannot both be on one function; a function has one calling convention",
                    )

                    b.first(e->range)
                    b.note(decl->range.start, "both are on this function")
                    b.remove(e->range, "remove " + an)
                    b.emit()
                }

                continue
            }

            fnd->call_conv = cc
        }

        if hot_seen && cold_seen && self.mode == Self::ParseMode::Full {
            // One function cannot be both the path to optimize for and the
            // path to keep out of the way.
            var b = self.diag->report(
                DiagID::SC147E,
                cold_at.start,
                LangAttrs::quoted(LangAttrs::hot_path()) + " and " + LangAttrs::quoted(
                    LangAttrs::cold_path(),
                ) + " contradict each other",
            )

            b.first(cold_at)
            b.note(decl->range.start, "both are on this function")
            b.remove(
                cold_at,
                "remove " + LangAttrs::quoted(LangAttrs::cold_path()),
            )

            b.emit()
        }

        if annot->visibility != VisibilityKind::None {
            decl->set_visibility(annot->visibility, annot->vis_range)
        }
    }

    /// \brief transfers annotations to an expression node.
    pub fn apply_annotations_to_node(self,
                                     node:  unsafe *Expr,
                                     annot: unsafe *Self::PendingAnnotations) {
        if annot->empty() {
            return
        }

        self._diag_vis_on_non_decl(annot, "an expression")
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            node->add_annotation(e->kind, e->name, e->range, e->args)
        }
    }

    /// \brief reports a diagnostic error if a visibility modifier is applied to a non-declaration.
    priv fn _diag_vis_on_non_decl(self,
                                  annot:      unsafe *Self::PendingAnnotations,
                                  const what: string) {
        if annot->visibility == VisibilityKind::None {
            return
        }

        self.diag->report(
            DiagID::S048E,
            annot->vis_range.start,
            f"a visibility modifier cannot be applied to {what}",
        ).first(annot->vis_range)->emit()
    }

    /// \brief transfers annotations to a statement node.
    pub fn apply_annotations_to_node(self,
                                     node:  unsafe *Stmt,
                                     annot: unsafe *Self::PendingAnnotations) {
        if annot->empty() {
            return
        }

        self._reject_global_alloc_attr(annot)
        self._diag_vis_on_non_decl(annot, "a statement")
        var k_hot  = self.ctx->hoisted->intern(LangAttrs::hot_path())
        var k_cold = self.ctx->hoisted->intern(LangAttrs::cold_path())
        var k_pure = self.ctx->hoisted->intern(LangAttrs::pure_fn())
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            node->add_annotation(e->kind, e->name, e->range, e->args)
            // The function attributes name a function; a statement is none.
            if e->kind != AnnotationKind::Attribute || self.mode != Self::ParseMode::Full {
                continue
            }

            var fa = ""
            if e->name == k_hot {
                fa = LangAttrs::hot_path()
            } else if e->name == k_cold {
                fa = LangAttrs::cold_path()
            } else if e->name == k_pure {
                fa = LangAttrs::pure_fn()
            } else if e->name == self.ctx->hoisted->intern(
                LangAttrs::no_inline(),
            ) {
                fa = LangAttrs::no_inline()
            } else if e->name == self.ctx->hoisted->intern(
                LangAttrs::preserve_most(),
            ) {
                fa = LangAttrs::preserve_most()
            } else if e->name == self.ctx->hoisted->intern(
                LangAttrs::preserve_all(),
            ) {
                fa = LangAttrs::preserve_all()
            } else if e->name == self.ctx->hoisted->intern(
                LangAttrs::preserve_none(),
            ) {
                fa = LangAttrs::preserve_none()
            }

            if fa.size() == 0 {
                continue
            }

            var an = "'@" + fa + "'"
            var b = self.diag->report(
                DiagID::SC143E,
                e->range.start,
                an + " applies only to a function",
            )

            b.first(e->range)
            b.note(node->range.start, "the attribute is on this statement")
            b.remove(e->range, "remove " + an)
            b.emit()
        }
    }

    /// \brief transfers annotations to a type node.
    pub fn apply_annotations_to_node(self,
                                     node:  unsafe *Type,
                                     annot: unsafe *Self::PendingAnnotations) {
        if annot->empty() {
            return
        }

        self._diag_vis_on_non_decl(annot, "a type")
        for var i: usize = 0; i < annot->entries.size(); ++i {
            var *e = &annot->entries[i]
            node->add_annotation(e->kind, e->name, e->range, e->args)
        }
    }

    //  Type qualifier consumption

    /// \brief consumes leading type qualifier keywords (const, atomic, etc.).
    ///
    /// \details populates the `PendingQuals` accumulator. these are consumed by
    ///          type parsing logic to apply to the constructed `Type` node.
    pub fn consume_leading_quals(self, out: *Self::PendingQuals) {
        out->clear()

        while !self.is_eof() {
            var unsafe *tok = self._current
            if tok == &null {
                break
            }

            var resolved = self.resolve_deep(tok)
            var rk       = resolved.kind

            if rk == TokenKind::KwConst {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsConst,
                    tok->range,
                )
            } else if rk == TokenKind::KwVolatile {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsVolatile,
                    tok->range,
                )
            } else if rk == TokenKind::KwAtomic {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsAtomic,
                    tok->range,
                )
            } else if rk == TokenKind::KwUnsafe {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsUnsafe,
                    tok->range,
                )
            } else if rk == TokenKind::KwEval {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsEval,
                    tok->range,
                )
            } else if rk == TokenKind::KwAsync {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsAsync,
                    tok->range,
                )
            } else if rk == TokenKind::KwYield {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsYield,
                    tok->range,
                )
            } else if rk == TokenKind::KwPanic {
                out->add(
                    Self::PendingQuals::TypeQualifier::Flags::IsPanic,
                    tok->range,
                )
            } else {
                break
            }

            self.advance()
        }
    }

    /// \brief applies accumulated qualifiers to a constructed type.
    pub fn apply_quals(self, ty: *Type, quals: *Self::PendingQuals) {
        if quals->empty() {
            return
        }

        ty->flags.add_all(quals->flags)
        for var i: usize = 0; i < quals->spans.size(); ++i {
            ty->spans.push(*&quals->spans[i])
        }
    }

    /// \brief where a `const` was written at the TOP of \p ty. A `const` under
    ///        a pointer (`*const i32`) lands on the pointee's node, not this
    ///        one, so it does not answer here. Callers test ty->is_const()
    ///        first; this is only the location.
    pub fn top_const_range(self, ty: *Type) -> SourceRange {
        return ty->qual_range(Self::PendingQuals::TypeQualifier::Flags::IsConst)
    }

    //  Recovery primitives

    /// \brief records the state a speculative parse can move. See
    ///        ParserCheckpoint for what rewind() gives back.
    inline fn checkpoint(self) -> ParserCheckpoint {
        var cp = ParserCheckpoint{}
        cp.cursor     = self.c_idx
        cp.nl_depth   = self.nl_depth
        cp.comments   = self._pending_trailing.size()
        cp.angle_debt = self._angle_debt
        // Read only by the debug check in rewind(): a release build does
        // not pay for them on every speculation.
        eval if defined!(DEBUG) {
            cp.depth           = self.depth
            cp.expr_depth      = self.expr_depth
            cp.ffi_decl_depth  = self.ffi_decl_depth
            cp.no_comment_skip = self._no_comment_skip
        }

        return cp
    }

    /// \brief rolls the cursor and the `>>` debt back to \p cp, and (debug
    ///        builds) checks that the balanced counters came back by
    ///        themselves.
    fn rewind(self, cp: ParserCheckpoint) {
        eval if defined!(DEBUG) {
            self._check_balanced(cp)
        }

        self._restore_cursor(cp.cursor)
        self._angle_debt = cp.angle_debt
    }

    /// \brief the debug half of rewind(): a speculation that returns with a
    ///        depth counter or _no_comment_skip moved has an unbalanced
    ///        enter/exit inside it, which a rollback would silently carry
    ///        into the reparse. A fired depth cap unwinds without its exits,
    ///        so it is the one excuse.
    priv fn _check_balanced(self, cp: ParserCheckpoint) {
        if self._depth_aborted {
            return
        }

        if self.depth != cp.depth
            || self.expr_depth != cp.expr_depth
            || self.ffi_decl_depth != cp.ffi_decl_depth
            || self._no_comment_skip != cp.no_comment_skip {
            kairo::std::ice_fail(
                f"ASTParse::rewind: a speculative parse left its counters moved (depth {cp.depth} -> {self.depth}, expr_depth {cp.expr_depth} -> {self.expr_depth}, ffi_decl_depth {cp.ffi_decl_depth} -> {self.ffi_decl_depth})",
            )
        }
    }

    /// \brief starts a speculative parse branch (no suppression; see
    ///        TentativeGuard for the suppressing form).
    /// \return the checkpoint to hand to tentative_rollback.
    inline fn tentative_begin(self) -> ParserCheckpoint {
        return self.checkpoint()
    }

    /// \brief commits a speculative parse: nothing to undo, the parse proceeds.
    fn tentative_commit(self, cp: ParserCheckpoint) {
        // no-op: committing keeps every moved field where it is.
    }

    /// \brief reverts to \p cp: cursor and `>>` debt (rewind). nl_depth and
    ///        the pending comments are left as they are, as they always were
    ///        for this pair.
    fn tentative_rollback(self, cp: ParserCheckpoint) {
        self.rewind(cp)
    }

    /// \brief restores the token cursor to a previously saved index.
    fn _restore_cursor(self, idx: usize) {
        self.c_idx = idx
        self._prev = if (idx > 0) => (self.span.get(idx - 1)) else => &null
        self._sync_cursor()
    }

    /// \brief parks the cursor on the final token so every enclosing loop sees
    ///        EOF and unwinds.
    /// \details a depth-cap failure jumps to EOF: returning an error node
    ///          WITHOUT consuming anything would make the caller's loop (top
    ///          level, block body) re-enter the same construct, fail the same
    ///          check and spin forever. Jumping to EOF guarantees progress and
    ///          turns the cap into exactly one diagnostic instead of a retry
    ///          storm.
    /// Stops the parse after a depth cap fires. Only a flag is set: is_eof()
    /// reads it, so every statement/declaration loop ends on its next check
    /// no matter which token window it is iterating. Moving the cursor
    /// instead does not work: a class body is parsed over a swapped-in
    /// sub-span, so a cursor parked at ITS end is restored to the middle of
    /// the file, and the refused-without-consuming block then spins the
    /// outer statement loop forever (the original --cmax-scope-depth hang).
    /// The cursor stays on the refusing token so callers that read
    /// current_ptr()->range for their error node never see null.
    fn _abort_to_eof(self) {
        self._depth_aborted = true
    }

    /// \brief checks and increments the recursion depth counter.
    fn enter_depth(self) -> bool {
        if self._depth_aborted {
            return false
        }

        if self.depth >= self.max_depth {
            var cur_range = self.current_ptr()->range
            self.diag->report(
                DiagID::S063E,
                cur_range.start,
                "exceeded maximum nesting depth",
            ).first(cur_range)->note(
                DiagCode(DiagID::S063N),
                "this is likely caused by excessively deep or infinite recursion while parsing. consider refactoring to reduce nesting depth or changing `--cmax-scope-depth` to a higher value if necessary.",
            )->emit()
            self._abort_to_eof()
            return false
        }

        ++self.depth
        return true
    }

    /// \brief decrements the recursion depth counter.
    fn exit_depth(self) {
        if self.depth > 0 {
            --self.depth
        }
    }

    /// \brief expression-recursion twin of enter_depth, bounded by
    ///        --cmax-expr-depth rather than the scope cap.
    fn enter_expr_depth(self) -> bool {
        if self._depth_aborted {
            return false
        }

        if self.expr_depth >= self.max_expr_depth {
            var cur_range = self.current_ptr()->range
            self.diag->report(
                DiagID::S063E,
                cur_range.start,
                "exceeded maximum expression nesting depth",
            ).first(cur_range)->note(
                DiagCode(DiagID::S063N),
                "this is likely caused by excessively deep or infinite recursion while parsing an expression. consider simplifying the expression or changing `--cmax-expr-depth` to a higher value if necessary.",
            )->emit()
            self._abort_to_eof()
            return false
        }

        ++self.expr_depth
        return true
    }

    /// \brief decrements the expression recursion depth counter.
    fn exit_expr_depth(self) {
        if self.expr_depth > 0 {
            --self.expr_depth
        }
    }

    //  Scope primitives

    /// \brief pushes a new lexical scope and associates it with `dc`.
    fn enter_scope(self, kind: ScopeKind, dc: unsafe *DeclContext) -> unsafe *LexicalScope {
        return self.scope.push(kind, dc)
    }

    /// \brief pops the current lexical scope.
    fn exit_scope(self) {
        self.scope.pop()
    }

    //  Unified lookup (lexical -> hoisted -> global)

    /// \brief performs a full scope-walking name lookup.
    /// \note slower than direct hoisted scope access; intended for non-parser consumers.
    fn lookup(self, const name: string) -> ParentRef {
        var unsafe *local = self.scope.lookup(name)
        if local != &null {
            return ParentRef::from_decl(local->decl)
        }

        var hr = self.ctx->hoisted->lookup(name)
        if hr.found() {
            return ParentRef::from_hoisted(hr.first())
        }

        return ParentRef::none()
    }

    //  Completion hooks

    /// \brief notifies completion consumer of a generic context point.
    fn maybe_complete(self, kind: CompletionContextKind) {
        if self.cc == &null {
            return
        }

        // TODO: only fire if self._current is at/past cc.cursor_loc.
        self.cc->on_completion(kind, self.scope.current_dc())
    }

    /// \brief triggers member completion for dot or arrow access.
    fn maybe_complete_member(self, base: *Expr, is_arrow: bool) {
        if self.cc == &null {
            return
        }

        self.cc->on_member_access(base, is_arrow)
    }

    /// \brief triggers completion for a qualified name (e.g. `namespace::...`).
    fn maybe_complete_qualified(self, scope: *DisambigNode) {
        if self.cc == &null {
            return
        }

        self.cc->on_qualified_name(scope)
    }

    /// \brief triggers signature help/parameter hint completion.
    fn maybe_complete_sighelp(self, callee: *Expr, arg_index: u32) {
        if self.cc == &null {
            return
        }

        self.cc->on_signature_help(callee, arg_index)
    }

    pub inline fn nl_push(self) {
        ++self.nl_depth
        self._skip_nl_fwd()
    }

    pub inline fn nl_pop(self) {
        if self.nl_depth > 0 {
            --self.nl_depth
        }
    }

    /// \brief single-step advance that keeps a trailing newline for the
    ///        caller. Consumes closing delimiters so a statement
    ///        terminator after `)`/`]`/`}`/`>` survives.
    ///
    /// \details "for the caller" is the ENCLOSING context: a closer is
    ///          consumed after its own nl_pop(), so a still-positive depth
    ///          means the closer sits inside another bracket, where that
    ///          newline is no terminator. Left under the cursor it ended the
    ///          enclosing expression -- `g((y)` newline `+ 1, 2)`, a generic
    ///          last parameter `seen: vec<u8>` newline `)` -- while the same
    ///          code with a bare operand parsed. Under
    ///          suppression the cursor never rests on a newline.
    pub inline fn advance_raw(self) {
        self._advance()
        if self.nl_depth > 0 {
            self._skip_nl_fwd()
        }
    }

    /// \brief whether the closer under the cursor closes a bracket the TEXT
    ///        still has open before it. Walking back, every closer waits for
    ///        an opener of its own kind, this one at the bottom. An opener
    ///        pairs with the nearest waiting closer of its kind, and the
    ///        closers waiting above that one are strays; an opener nothing
    ///        waits for is unclosed and is stepped over. So in `{ foo(1,`
    ///        then `}` the `(` is the error and the `}` is still the block's,
    ///        and in `foo(1 + ]` then `}` the `]` is the stray.
    ///
    /// \details recovery keeps such a closer for the construct that owns it
    ///          (`var x = 1 +` then the body's `}`) and skips any other one
    ///          as junk (`n + ) = 1` inside a `{ }`: no `(` is open), which
    ///          is what it did with every closer before. The walk is on
    ///          the error path only; past CLOSER_SCAN_LIMIT tokens the closer
    ///          is taken as owned, the reading that never runs a construct on
    ///          past its brace.
    pub fn closer_is_owned(self) -> bool {
        const CLOSER_SCAN_LIMIT: usize = 1 << 16

        if self._current == &null {
            return false
        }

        var k    = self.resolve_kind_shallow(self._current)
        var want = TokenKind::OpLBrace
        if k == TokenKind::OpRParen {
            want = TokenKind::OpLParen
        } else if k == TokenKind::OpRSquare {
            want = TokenKind::OpLSquare
        } else if k != TokenKind::OpRBrace {
            return false
        }

        // the openers the closers seen so far (walking back) are waiting for,
        // this closer's at the bottom; `top` is the live depth, the buffer
        // only ever grows
        var waiting: kairo::std::StackBuf<TokenKind, 32>
        waiting.push_back(want)
        var top:  u32   = 1
        var i:    usize = self.c_idx
        var seen: usize = 0
        while i > 0 {
            i -= 1
            ++seen
            if seen > CLOSER_SCAN_LIMIT {
                return true
            }

            var tk     = self.resolve_kind_shallow(self.span.get(i))
            var opener = TokenKind::TkEof
            if tk == TokenKind::OpRBrace {
                opener = TokenKind::OpLBrace
            } else if tk == TokenKind::OpRParen {
                opener = TokenKind::OpLParen
            } else if tk == TokenKind::OpRSquare {
                opener = TokenKind::OpLSquare
            }

            if opener != TokenKind::TkEof {
                if top < waiting.size() {
                    waiting[top] = opener
                } else {
                    waiting.push_back(opener)
                }

                ++top
            } else if tk == TokenKind::OpLBrace
                || tk == TokenKind::OpLParen
                || tk == TokenKind::OpLSquare {
                var j = top
                while j > 0 && waiting[j - 1] != tk {
                    --j
                }

                if j == 1 {
                    return true // pairs with this closer: still open before it
                }

                if j > 1 {
                    top = j - 1 // paired; the closers waiting above it were strays
                }

                // j == 0: nothing waits for it, an unclosed opener: stepped over
            }
        }

        return false
    }

    /// \brief closer_is_owned, and for a `}` also that it can end a block
    ///        here: it ends its line or is followed by what can follow a
    ///        block (`else`, `catch`, `;`, `,`, a closer). For a failed
    ///        OPERAND only: `var v = } 0` is junk in the middle of a line,
    ///        not the body's end. A list's own `}` (`{1, 2,}.size()`) is
    ///        never asked this.
    pub fn operand_closer_is_owned(self) -> bool {
        if !self.closer_is_owned() {
            return false
        }

        if self.resolve_kind_shallow(self._current) != TokenKind::OpRBrace
            || self.c_idx + 1 >= self.span.size() {
            return true
        }

        var nk = self.resolve_kind_shallow(self.span.get(self.c_idx + 1))
        return nk == TokenKind::TkNewLine
            || nk == TokenKind::TkEof
            || nk == TokenKind::OpSemicolon
            || nk == TokenKind::OpComma
            || nk == TokenKind::OpRBrace
            || nk == TokenKind::OpRParen
            || nk == TokenKind::OpRSquare
            || nk == TokenKind::KwElse
            || nk == TokenKind::KwCatch
    }

    /// \brief true when the token under the cursor is the first on its line
    ///        (or of the stream): an arm lead `case` / `default` that starts
    ///        a line is the next arm; one in the middle of a line is junk.
    pub fn starts_line(self) -> bool {
        if self.c_idx == 0 {
            return true
        }

        return self.resolve_kind_shallow(self.span.get(self.c_idx - 1)) == TokenKind::TkNewLine
    }

    /// \brief whether the token just consumed is the one the TEXT pairs with
    ///        the opener at \p open: brackets of every kind counted together
    ///        from it, the first that brings the count back to zero. A parse
    ///        that stopped at an inner closer, ran past the right one, or
    ///        never closed (S057E) did not, and what follows it was not
    ///        parsed as it would have been without the error.
    pub fn closes_lexically(self, open: usize) -> bool {
        if self._prev == &null || open >= self.span.size() {
            return false
        }

        var depth: i64 = 0
        for var i: usize = open; i < self.span.size(); ++i {
            var unsafe *t = self.span.get(i)
            var        k  = self.resolve_kind_shallow(t)
            if k == TokenKind::OpLBrace || k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                depth += 1
            } else if k == TokenKind::OpRBrace
                || k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare {
                depth -= 1
                if depth == 0 {
                    return k == TokenKind::OpRBrace && t == self._prev
                }
            }
        }

        return false
    }

    /// \brief resolved kind of the next non-newline token, without moving.
    pub inline fn peek_past_nl_kind(self) -> TokenKind {
        // c_idx stays on the last token when the cursor steps off the end, so
        // scanning from it would report that (already consumed) token again.
        if self._current == &null {
            return TokenKind::TkEof
        }

        var i = self.c_idx
        while i < self.span.size() {
            var unsafe *t = self.span.get(i)
            var        k  = self.resolve_kind_shallow(t)
            // --preserve-comments leaves AtComment tokens in the stream; a
            // comment line between `a` and a leading `||`/`.` must not hide the
            // continuation token, or the same file parses differently with the
            // flag on.
            if k != TokenKind::TkNewLine && k != TokenKind::AtComment {
                return k
            }

            ++i
        }

        return TokenKind::TkEof
    }

    ///
    /// Sentinel checks
    ///

    fn <T> fatal_ptr(self) -> unsafe *T {
        var unsafe *base = unsafe ((&self._fatal_sentinels) as unsafe *u8)
        eval if cxx::std::is_same<T, Type>::value {
            return unsafe ((base + 0) as unsafe *T)
        } else if cxx::std::is_same<T, Expr>::value {
            return unsafe ((base + 1) as unsafe *T)
        } else if cxx::std::is_same<T, Stmt>::value {
            return unsafe ((base + 2) as unsafe *T)
        } else if cxx::std::is_same<T, Decl>::value {
            return unsafe ((base + 3) as unsafe *T)
        } else {
            assert static false, r"unsupported sentinel type"
            return &null
        }
    }

    fn <T> is_fatal(self, ptr: unsafe *T) -> bool {
        var unsafe *base = unsafe ((&self._fatal_sentinels) as unsafe *u8)
        eval if cxx::std::is_same<T, Type>::value {
            return (unsafe ((base + 0) as unsafe *T)) == ptr
        } else if cxx::std::is_same<T, Expr>::value {
            return (unsafe ((base + 1) as unsafe *T)) == ptr
        } else if cxx::std::is_same<T, Stmt>::value {
            return (unsafe ((base + 2) as unsafe *T)) == ptr
        } else if cxx::std::is_same<T, Decl>::value {
            return (unsafe ((base + 3) as unsafe *T)) == ptr
        } else {
            assert static false, r"unsupported sentinel type"
            return false
        }
    }
}
