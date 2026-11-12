/// --- The Kairo Project --------------------------- Parser/StmtParse.k --- ///
///
///   The statement parser mixin: recursive descent over statements.
///
///     Entry point: parse_stmt() -> dispatches on the leading (resolved) token
///     to the correct production. Block parsing (parse_block / parse_compound)
///     drives statement sequences inside `{ }`.
///
///     Derives from ASTParse (CRTP) which provides: check, check_peek,
///     match_tok, expect, advance, retreat, current, peek, prev, current_ptr,
///     ctx, diag, is_eof, enter_depth/exit_depth, enter_scope/exit_scope,
///     consume_leading_annotations, apply_annotations_to_node, parse_expr
///     (ExprParse), parse_type (TypeParse), parse_decl (DeclParse), etc.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import AST::ASTSupport::FrozenList // FrozenList in MatchCore
import AST::Context::DeclContext::DeclContextKind
import AST::LangItems::{
    LangAttrs,
    LangIntrinsics,
    WellKnownType,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
}
import AST::Node::Casting::{
    cast,
    is_recovery,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, EnumDecl,     ExtensionDecl, FunctionDecl, InterfaceDecl, StorageClass, StructDecl,
    UnionDecl, VariableDecl,
} // VariableDecl for binder decls (Binding::decl)
import AST::Node::Expressions::{
    CallExpr,
    MatchExpr,
} // MatchExpr / IfExpr for value-form statements
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Lexer::Immediate::Immediate
import Location::SourceRange::SourceRange
import Parser::LexicalScope::ScopeKind
import Support::FlagSet::FlagSet
import Token::Token::Token
import Token::TokenKind::TokenKind
import std::c_char

/// \brief the body form of one match arm; parser-local. The AST records it
///        only as which of MatchCase::body / MatchCase::expression is set.
pub enum ArmForm derives u8 {
    Block, ///< `{ ... }`: a statement arm.
    Value, ///< `=> value`: a value arm.
}

/// \brief the arm forms of a whole match.
pub enum MatchForm derives u8 {
    AllBlock, ///< every arm is a block (or there are none): a statement.
    AllValue, ///< every arm is a value: a value, even in statement position.
    Mixed,    ///< both kinds; an error in statement position.
}

/// \brief what _parse_match_core hands back to the statement and the
///        expression parser, which each build their own node from it.
pub struct MatchCore {
    var ok:          bool ///< false after a reported structural failure.
    var scrutinee:   unsafe *Expr
    var cases:       FrozenList<Statements::MatchCase>
    var form:        MatchForm
    var range:       SourceRange ///< `match` through `}`, or what was consumed.
    var first_block: SourceRange ///< first `{ }` arm; invalid when none.
    var first_value: SourceRange ///< first `=>` arm; invalid when none.
}

// TODO(DUCK-GENERIC): T uses _assume_ahead, _attach_trailing, _depth_aborted, _else_attr_kind, _expect_arrow_recover, _finish_if_expr, _is_terminator_tok, _mods_lead_to_fn, _parse_arm_value, _parse_call_args, _peek_kind_past_nl, _reject_mode_binding, ... (52). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> StmtParse {
    /// \enum StmtSyncCtx
    /// \brief sync contexts for statement-level error recovery.
    enum StmtSyncCtx derives u8 {
        TopLevel, ///< sync to newline / ; / EOF
        Block,    ///< sync to } at depth 0, or a statement lead-in
        Paren,    ///< sync to ) at depth 0 (for-loop clauses)
    }

    //  CRTP helpers

    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    priv inline fn _error_stmt(self, range: SourceRange) -> *Stmt {
        return Statements::ExpressionStmt::create_error(self.dyn()->ctx, range)
    }

    priv inline fn is_fatal_stmt(self, s: unsafe *Stmt) -> bool {
        return self.dyn()->is_fatal<Stmt>(s)
    }

    //  Statement-boundary helpers

    /// \brief consumes the optional statement terminator (newline or `;`).
    /// \details statements are newline-terminated; an explicit `;` is also
    ///          accepted. Multiple blank lines collapse. Never errors absence
    ///          of a terminator before `}` or EOF is legal.
    inline fn _consume_terminator(self) {
        while self.dyn()->_is_terminator_tok(self.dyn()->current_ptr()) {
            self.dyn()->advance_raw()
        }
    }

    /// \brief true if the resolved current token can begin a declaration.
    /// \details used by parse_stmt to route into the decl parser. Mirrors
    ///          ExprParse::_is_decl_keyword but is the positive dispatch gate.
    inline fn _starts_decl(self, k: TokenKind) -> bool {
        return k == TokenKind::KwFn
            || k == TokenKind::KwClass
            || k == TokenKind::KwStruct
            || k == TokenKind::KwEnum
            || k == TokenKind::KwInterface
            || k == TokenKind::KwUnion
            || k == TokenKind::KwModule
            || k == TokenKind::KwImport
            || k == TokenKind::KwFfi
            || k == TokenKind::KwExtend
            || k == TokenKind::KwType
            || k == TokenKind::KwMacro
            || k == TokenKind::KwStatic
            || k == TokenKind::KwPub
            || k == TokenKind::KwPriv
            || k == TokenKind::KwProt
    }

    //  Block parsing

    /// \brief parses a brace-delimited statement sequence into a CompoundStmt.
    ///  Grammar:  '{' (stmt terminator?)* '}'
    ///
    /// \details precondition: current token is `{`. Pushes a Block scope,
    ///          parses statements until `}` or EOF, pops the scope. On a
    ///          missing close brace, emits a diagnostic and returns what was
    ///          parsed so far. The body FrozenList is always populated (even
    ///          when empty) via from_buf.
    fn parse_compound(self,
                      scope_kind: ScopeKind = ScopeKind::Block) -> unsafe *Statements::CompoundStmt {
        if !self.dyn()->check(TokenKind::OpLBrace) {
            var r = self.dyn()->current_ptr()->range
            self.dyn()->diag->report(
                DiagID::S056E,
                r.start,
                "expected '{' to begin a block",
            ).first(r)->emit()
            return Statements::CompoundStmt::create_error(self.dyn()->ctx, r)
        }

        if !self.dyn()->enter_depth() {
            var r = self.dyn()->current_ptr()->range
            return Statements::CompoundStmt::create_error(self.dyn()->ctx, r)
        }

        var lbrace_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `{`

        // A block is a statement context wherever it sits: a closure body in
        // an argument list, an if head's operand. Inherited suppression
        // folded `var z = y` newline `-z` into `y - z`. Restored before `}`,
        // so the closer's trailing newline is the enclosing context's call.
        var saved_nl = self.dyn()->nl_depth
        self.dyn()->nl_depth = 0

        self.dyn()->enter_scope(scope_kind, self.dyn()->scope.current_dc())

        var stmts: kairo::std::StackBuf<unsafe *Stmt, 16>

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            // collapse blank lines / stray semicolons between statements
            if self.dyn()->_is_terminator_tok(self.dyn()->current_ptr()) {
                self.dyn()->advance_raw()
                continue
            }

            // a stray `)` / `]` a failed operand already reported (the
            // block's own `}` ended the loop above): skipped, not re-parsed
            if self.dyn()->current_ptr() == self.dyn()->_kept_closer {
                self.dyn()->advance()
                continue
            }

            var        before = self.dyn()->c_idx
            var unsafe *s     = self.parse_stmt()
            if s == &null {
                break // EOF mid-statement
            }

            if self.is_fatal_stmt(s) {
                break // fatal error in statement
            }

            stmts.push_back(s)
            self.dyn()->_attach_trailing(s)
            self._consume_terminator()

            // A failed operand leaves a closer where it is (the primary
            // parser's no-match path), so a stray `)` or `]` here comes back
            // unconsumed, already reported. `}` ends the loop; anything else
            // that did not move is skipped, or the loop would retry it forever.
            if self.dyn()->c_idx == before
                && !self.dyn()->is_eof()
                && !self.dyn()->check(TokenKind::OpRBrace) {
                self.dyn()->advance()
            }
        }

        self.dyn()->nl_depth = saved_nl
        var full_range = lbrace_range
        if self.dyn()->check(TokenKind::OpRBrace) {
            full_range = lbrace_range | self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        } else {
            // After a depth abort every enclosing block is unclosed by
            // construction; one S063E already said why, so the cascade of
            // "expected '}'" from each of them would only bury it.
            if !self.dyn()->_depth_aborted {
                self.dyn()->diag->report(
                    DiagID::S057E,
                    lbrace_range.start,
                    "expected '}' to close block",
                ).first(lbrace_range)->emit()
            }

            full_range = lbrace_range | self.dyn()->prev().range
        }

        self.dyn()->exit_scope()
        self.dyn()->exit_depth()

        var block = Statements::CompoundStmt::create(
            self.dyn()->ctx,
            full_range,
        )

        block->body.from_buf(stmts.data(), stmts.size(), self.dyn()->ctx)
        return block
    }

    //  Top-level statement dispatch

    /// \brief parses `@assume(cond)`.
    ///  Grammar:  '@' 'assume' '(' expr ')'   then a newline, `;`, `}` or EOF
    ///
    /// \details builds the call `__builtin_assume(cond)` in an ExpressionStmt;
    ///          name resolution binds it to the Assume lang item, which codegen
    ///          spells as clang's builtin. It attaches to nothing: what follows
    ///          on its line is an error (an attribute reading as if it
    ///          applied to `foo()` would hide that it does not), and the rest
    ///          of the line is skipped so it cannot cascade.
    priv fn _parse_assume(self) -> unsafe *Stmt {
        var at_r = self.dyn()->current_ptr()->range
        self.dyn()->advance() // `@`
        var name_r = self.dyn()->current_ptr()->range
        self.dyn()->advance() // `assume`
        var lparen = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // `(`
        self.dyn()->nl_push()
        var args: kairo::std::StackBuf<*Expr, 8>
        if !self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->_parse_call_args(&args, lparen)
        }

        self.dyn()->nl_pop()
        if !self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->diag->report(
                DiagID::S051E,
                lparen.start,
                "expected ')' to close " + LangAttrs::quoted(
                    LangAttrs::assume(),
                ),
            ).first(lparen)->emit()
            return self._error_stmt(at_r | self.dyn()->prev().range)
        }

        var rparen = self.dyn()->current_ptr()->range
        self.dyn()->advance_raw() // `)`; the terminator stays

        var full = at_r | rparen
        if args.size() != 1 {
            self.dyn()->diag->report(
                DiagID::S080E,
                at_r.start,
                LangAttrs::quoted(LangAttrs::assume()) + " takes exactly one condition",
            ).first(full)->emit()
            return self._error_stmt(full)
        }

        if !self.dyn()->is_eof()
            && !self.dyn()->check(TokenKind::OpRBrace)
            && !self.dyn()->_is_terminator_tok(self.dyn()->current_ptr()) {
            var nxt = self.dyn()->current_ptr()->range
            var b = self.dyn()->diag->report(
                DiagID::SC148E,
                at_r.start,
                LangAttrs::at(
                    LangAttrs::assume(),
                ) + " is a statement of its own; it does not attach to what follows on its line",
            )

            b.first(full)
            b.insert(nxt.start, "\n", "put the next statement on its own line")
            b.emit()
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
        }

        var nt = Token()
        nt.kind  = TokenKind::LitIdentifier
        nt.range = name_r
        nt.imm = self.dyn()->ctx->hoisted->intern(
            to_string(WellKnownType::Assume),
        )

        var callee = NamedIdentExpr::create(self.dyn()->ctx, name_r, nt)
        var ce     = CallExpr::create(self.dyn()->ctx, full, callee)
        ce->args.from_buf(args.data(), args.size(), self.dyn()->ctx)
        return unsafe (Statements::ExpressionStmt::create(self.dyn()->ctx, full, unsafe (ce as unsafe *Expr)) as unsafe *Stmt)
    }

    /// \brief parses a single statement.
    ///  Grammar (dispatch):
    ///    block | if | while | loop | for | match | return | break | continue
    ///    | panic | yield | assert | try | finally | unsafe-block | eval-block
    ///    | label!/jump! | inline-block | labeled-loop | decl | destructuring-decl
    ///    | expr-stmt | context-binding
    ///
    /// \details consumes leading annotations (e.g. @likely, doc comments) and
    ///          stamps them onto the produced node. Dispatch is on the resolved
    ///          current token. Returns null only at EOF.
    fn parse_stmt(self) -> unsafe *Stmt {
        if self.dyn()->is_eof() {
            return &null
        }

        // `@assume(cond)` is a statement of its own, so it is taken before
        // the annotation pass, which would stamp it on the NEXT statement.
        if self.dyn()->check(TokenKind::OpAt) && self.dyn()->_assume_ahead() {
            return self._parse_assume()
        }

        var annot: T::PendingAnnotations
        self.dyn()->consume_leading_annotations(&annot, true)

        if self.dyn()->is_eof() {
            return &null
        }

        var unsafe *s = self._dispatch_stmt()
        if s != &null && !self.is_fatal_stmt(s) {
            // DeclStmt annotations (incl. visibility) belong to the decl;
            // the Stmt overload would drop visibility (with a diagnostic).
            if isa<Statements::DeclStmt>(s) {
                var unsafe *ds = cast<Statements::DeclStmt>(s)

                if ds->decl != &null {
                    self.dyn()->apply_annotations_to_decl(ds->decl, &annot)
                }
            } else {
                self.dyn()->apply_annotations_to_node(s, &annot)
            }
        }

        return s
    }

    /// A named decl at statement scope is reachable only through its DeclStmt;
    /// nothing in the decl productions links it into the enclosing
    /// DeclContext. `_build_symbols` walks dc_decls, so a `class Local { }`
    /// inside a function body never got a table and every `l.v` was "no
    /// member named v". Link every DC-owning local decl (types, fns) into the
    /// executable scope it was written in. The enclosing scope is never a
    /// table-bearing one here, so this adds no table entry -- N's lexical
    /// stack and T's ltypes are still how the NAME is found.
    ///
    /// The TU is excluded: a top-level DeclStmt is already indexed from
    /// program->items, and adding it to tu->dc_decls too would index it twice
    /// and make N call it a redefinition of itself. Type bodies never reach
    /// here (members are routed by the body parser, not as statements).
    priv fn _attach_local_decl(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        var dc = self.dyn()->scope.current_dc()
        if dc == &null {
            return
        }

        if dc->dc_kind == DeclContextKind::TranslationUnit {
            return
        }

        if dc->is_type_scope() {
            return
        }

        if dc == self.dyn()->eval_branch_dc {
            return
        }

        if isa<ClassDecl>(d)
            || isa<StructDecl>(d)
            || isa<UnionDecl>(d)
            || isa<InterfaceDecl>(d)
            || isa<EnumDecl>(d)
            || isa<FunctionDecl>(d)
            || isa<ExtensionDecl>(d) {
            dc->add_decl(d)
            // Where it was written, for whoever asks the decl and not the
            // tree around it: codegen hoists a local fn or type to the
            // namespace of the function it sits in (CXXSpell::
            // is_hoisted_local), and finds that function from here. The
            // symbol build stamps the same scope when it reaches the decl;
            // a body parsed after that build is not reached by it.
            if d->semantic_dc == &null {
                d->semantic_dc = dc
            }

            if d->lexical_dc == &null {
                d->lexical_dc = dc
            }
        }
    }

    /// \brief routes the current token to its statement production.
    priv fn _dispatch_stmt(self) -> unsafe *Stmt {
        var cur_ptr = self.dyn()->current_ptr()
        if cur_ptr == &null {
            return &null
        }

        var k = self.dyn()->resolve_kind_deep(cur_ptr)

        match k {
            /// ## block
            case TokenKind::OpLBrace {
                return self.parse_compound()
            }

            /// ## control flow
            case TokenKind::KwIf {
                return self._parse_conditional()
            } case TokenKind::KwWhile {
                return self._parse_while()
            } case TokenKind::KwLoop {
                return self._parse_loop()
            } case TokenKind::KwFor {
                return self._parse_for(false)
            } case TokenKind::KwMatch {
                return self._parse_match()
            }

            /// ## jump / signal
            case TokenKind::KwReturn {
                return self._parse_return()
            } case TokenKind::KwBreak {
                return self._parse_break()
            } case TokenKind::KwContinue {
                return self._parse_continue()
            } case TokenKind::KwPanic {
                return self._parse_panic()
            } case TokenKind::KwYield {
                return self._parse_yield()
            } case TokenKind::KwAssert {
                return self._parse_assert()
            }

            /// ## exception / scope
            /// `try {` is the statement form. Anything else is a value-form
            /// `try` (`try f() catch => g()`) used as an expression statement.
            case TokenKind::KwTry {
                if self.dyn()->_peek_kind_past_nl(1) == TokenKind::OpLBrace {
                    return self._parse_try_catch()
                }

                return self._parse_expr_or_context()
            } case TokenKind::KwFinally {
                return self._parse_finally()
            }

            // -- unsafe: block form `unsafe { }` vs expr form `unsafe expr` -
            case TokenKind::KwUnsafe {
                if self.dyn()->check_peek(TokenKind::OpLBrace) {
                    return self._parse_unsafe_block()
                }

                // otherwise it's a unary `unsafe expr` fall through to expr-stmt.
            }

            /// ## eval: block form `eval { }` vs `eval if/for/var` vs expr
            case TokenKind::KwEval {
                // `eval {` -> decl-only eval block
                if self.dyn()->check_peek(TokenKind::OpLBrace) {
                    return self._parse_eval_block()
                }

                // `eval for` -> compile-time unrolled loop
                if self.dyn()->check_peek(TokenKind::KwFor) {
                    self.dyn()->advance() // consume `eval`
                    if self.dyn()->tu != &null {
                        self.dyn()->tu->has_eval_for = true
                    }

                    return self._parse_for(true)
                }

                // `eval if`: the conditional, marked (every `else if` of its
                // chain too) for EvalIfFolding.
                if self.dyn()->check_peek(TokenKind::KwIf) {
                    self.dyn()->advance() // consume `eval`
                    if self.dyn()->tu != &null {
                        self.dyn()->tu->has_eval_if = true
                    }

                    return self._parse_conditional(false, true)
                }

                // `eval fn f()`: a (local) function declaration, as in a
                // module. Left to the expression path, `eval` took the
                // `fn` as a closure and its parameters were undeclared.
                if self.dyn()->_mods_lead_to_fn() {
                    var d = self.dyn()->parse_decl(true)
                    if d != &null {
                        if self.dyn()->is_fatal_decl(d) {
                            return self.dyn()->fatal_ptr<Stmt>()
                        }

                        self._attach_local_decl(d)
                        return Statements::DeclStmt::create(
                            self.dyn()->ctx,
                            d->range,
                            d,
                        )
                    }
                }

                // `eval N = e`, `eval N: T = e`, `eval const N = e`: the
                // binding (DeclParse::_storage_binding_ahead tells it from
                // an `eval f(3)` expression).
                if self.dyn()->_storage_binding_ahead() {
                    return self._parse_decl_stmt()
                }

                // otherwise `eval expr` unary fall through to expr-stmt.
            }

            // -- label! / jump! intrinsics: see the ident+`!` gate below the
            // switch. The PP's _detect_invocation passes these through as raw
            // tokens (parser intrinsics, not macros).

            /// ## inline foreign block
            /// `inline` fronts two unrelated things: the ffi block
            /// (`inline "c++" { ... }`) and the function modifier
            /// (`inline fn f()`). Only a lookahead to the `fn` head separates
            /// them, and the ffi block is the fallback.
            case TokenKind::KwInline {
                if self.dyn()->_mods_lead_to_fn() {
                    var d = self.dyn()->parse_decl(true)
                    if d != &null {
                        if self.dyn()->is_fatal_decl(d) {
                            return self.dyn()->fatal_ptr<Stmt>()
                        }

                        self._attach_local_decl(d)
                        return Statements::DeclStmt::create(
                            self.dyn()->ctx,
                            d->range,
                            d,
                        )
                    }
                }

                return self._parse_inline_block()
            } default { } // any other kind falls out to the ident / decl / expression checks below.
        }

        /// # label! / jump! intrinsics:  ident '!' '(' ident ')'
        /// raw tokens: the PP deliberately does not treat unqualified
        /// label!/jump! as macro invocations.
        if k == TokenKind::LitIdentifier && self.dyn()->check_peek(TokenKind::OpExclaim) {
            var sp = self.dyn()->ctx->get_spelling(self.dyn()->current())
            if sp == LangIntrinsics::label() {
                return self._parse_label_intrinsic()
            }

            if sp == LangIntrinsics::jump() {
                return self._parse_jump_intrinsic()
            }
        }

        /// # labeled loop:  ident ':' (while|for|loop)
        if k == TokenKind::LitIdentifier && self.dyn()->check_peek(TokenKind::OpColon) {
            return self._parse_labeled_stmt()
        }

        /// # var / const: plain decl, destructuring decl
        /// `const fn f()`: a (local) function declaration, not a binding.
        if k == TokenKind::KwConst && self.dyn()->_mods_lead_to_fn() {
            var d = self.dyn()->parse_decl(true)
            if d != &null {
                if self.dyn()->is_fatal_decl(d) {
                    return self.dyn()->fatal_ptr<Stmt>()
                }

                self._attach_local_decl(d)
                return Statements::DeclStmt::create(
                    self.dyn()->ctx,
                    d->range,
                    d,
                )
            }
        }

        if k == TokenKind::KwVar || k == TokenKind::KwConst {
            return self._parse_var_or_destructure()
        }

        if k == TokenKind::KwFn {
            var d = self.dyn()->parse_decl(true)
            if d == &null {
                return self._parse_expr_or_context() // cursor on `fn`
            }

            if self.dyn()->is_fatal_decl(d) {
                return self.dyn()->fatal_ptr<Stmt>()
            }

            // A local `fn` belongs to the function it is written in, as a
            // local type does (_parse_decl_stmt): codegen hoists both.
            self._attach_local_decl(d)
            return Statements::DeclStmt::create(self.dyn()->ctx, d->range, d)
        }

        /// # thread-local binding: `thread n: T` (not `thread work()`)
        if k == TokenKind::KwThread && self.dyn()->_storage_binding_ahead() {
            return self._parse_decl_stmt()
        }

        /// # other declarations
        if self._starts_decl(k) {
            return self._parse_decl_stmt()
        }

        /// # fallthrough: expression statement OR context binding
        return self._parse_expr_or_context()
    }

    //  Expression statement  /  context binding

    /// \brief parses an expression statement, or a context binding if the
    ///        expression is followed by a dangling `as` (left unconsumed by
    ///        the expr parser because it saw `as var` / `as const`).
    ///  Grammar:  expr
    ///          | expr 'as' binding_spec block        (context binding)
    ///
    /// \details the expr parser, on encountering `as` followed by `var`/`const`,
    ///          rolls back its tentative cast and returns the LHS with the cursor
    ///          sitting on `as`. We observe that dangling `as` here no shared
    ///          flag is needed and route to context-binding parsing.
    priv fn _parse_expr_or_context(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range

        var lhs = self.dyn()->parse_expr()
        if lhs == &null {
            return self._error_stmt(start_range)
        }

        // dangling `as` => context binding
        if self.dyn()->check(TokenKind::KwAs) {
            return self._parse_context_binding(lhs, start_range)
        }

        var es = Statements::ExpressionStmt::create(
            self.dyn()->ctx,
            lhs->range,
            lhs,
        )

        return es
    }

    /// \brief completes a context binding after the LHS and the dangling `as`.
    ///  Grammar:  <already parsed expr> 'as' binding_spec block
    ///    binding_spec := ('var'|'const') (binding | '(' binding (',' binding)* ')')
    ///
    /// \details precondition: current token is `as`. Consumes `as`, parses the
    ///          binding spec, then REQUIRES a block. A missing block is a hard
    ///          error (the construct is neither a valid cast nor a valid context
    ///          block, since a cast would never have a var/const binding).
    priv fn _parse_context_binding(self, value: *Expr, start_range: SourceRange) -> *Stmt {
        var as_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `as`

        var bindings: kairo::std::StackBuf<Statements::Binding, 4>
        var ok = self._parse_binding_spec(&bindings, as_range)

        if !ok {
            // binding spec malformed; recover by syncing to the block or EOL.
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            var err = Statements::ContextBindingStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err
        }

        // a block is mandatory after a context binding spec.
        if !self.dyn()->check(TokenKind::OpLBrace) {
            var r = self.dyn()->current_ptr()->range
            self.dyn()->diag->report(
                DiagID::S056E,
                as_range.start,
                "expected '{' after binding in context-binding statement",
            ).first(as_range)->note(
                DiagCode(DiagID::S056N),
                as_range.start,
                "a binding after 'as' (e.g. 'as var x') begins a context block and requires a body; "
                "for a type cast write 'as <Type>' with no 'var'/'const'",
            )->emit()
            var err = Statements::ContextBindingStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err
        }

        var unsafe *body = self.parse_compound()
        var        full  = start_range | body->range

        var node = Statements::ContextBindingStmt::create(
            self.dyn()->ctx,
            full,
            value,
            body,
        )

        node->bindings.from_buf(
            bindings.data(),
            bindings.size(),
            self.dyn()->ctx,
        )

        return node
    }

    //  Binding spec  (shared: destructuring decl, ranged-for, context binding)

    /// \brief parses a binding spec into `out`.
    ///  Grammar:  ('var'|'const') (binding | '(' binding (',' binding)* ')')
    ///    binding := ('var'|'const')? shorthand? (identifier | '_')
    ///    shorthand := 'unsafe'? '*' | '?'      (suffix '?' handled per-binding)
    ///
    /// \details the leading 'var'/'const' sets the default mutability; a
    ///          per-element 'var'/'const' overrides it. A single bare binding
    ///          (no parens) is permitted: `as var f`. Returns false on a
    ///          malformed spec (caller recovers). The leading keyword is
    ///          consumed by the CALLER for decls (which need to know it for
    ///          plain non-destructuring decls); for context binding and for
    ///          loops, this function reads it. To keep one path, this function
    ///          reads the leading keyword itself and reports it via the first
    ///          binding's resolution.
    ///
    /// \param out         buffer to collect parsed bindings.
    /// \param ctx_range   range for diagnostics (the `as`/`for`/decl keyword).
    /// \return true if the spec parsed and closed cleanly.
    fn _parse_binding_spec(self,
                           out:       unsafe *kairo::std::StackBuf<Statements::Binding, 4>,
                           ctx_range: SourceRange) -> bool {
        // leading 'var' | 'const' sets the default mutability.
        var leading_const = false
        var have_leading  = false
        if self.dyn()->check(TokenKind::KwVar) {
            leading_const = false
            have_leading  = true
            self.dyn()->advance()
        } else if self.dyn()->check(TokenKind::KwConst) {
            leading_const = true
            have_leading  = true
            self.dyn()->advance()
        }

        if !have_leading {
            self.dyn()->diag->report(
                DiagID::S058E,
                ctx_range.start,
                "expected 'var' or 'const' to begin a binding",
            ).first(ctx_range)->emit()
            return false
        }

        // parenthesized tuple binding list
        if self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->advance(T::SkipNL::After) // consume `(`

            if self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->diag->report(
                    DiagID::S058E,
                    ctx_range.start,
                    "empty binding list is not allowed",
                ).first(ctx_range)->emit()
                self.dyn()->advance() // consume `)`
                return false
            }

            while !self.dyn()->is_eof() {
                var b = self._parse_binding(leading_const)
                if !b.is_discard && b.name == &null {
                    return false // malformed binding element
                }

                out->push_back(b)

                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    if self.dyn()->check(TokenKind::OpRParen) { // trailing comma
                        break
                    }

                    continue
                }

                break
            }

            if !self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->diag->report(
                    DiagID::S058E,
                    ctx_range.start,
                    "expected ')' to close binding list",
                ).first(ctx_range)->emit()
                return false
            }

            self.dyn()->advance() // consume `)`
            return true
        }

        // single bare binding: `var f`
        var b = self._parse_binding(leading_const)
        if !b.is_discard && b.name == &null {
            return false
        }

        out->push_back(b)
        return true
    }

    /// \brief parses a binding spec where the leading 'var'/'const' is OPTIONAL.
    ///  Grammar:  ('var'|'const')? (binding | '(' binding (',' binding)* ')')
    ///
    /// \details when no leading keyword is present, bindings default to mutable
    ///          (var). A per-element 'var'/'const' still overrides per binding.
    ///          Unlike _parse_binding_spec, absence of a leading keyword is NOT
    ///          an error here it's the mutable-by-default case.
    fn _parse_binding_spec_opt(self,
                               out:       unsafe *kairo::std::StackBuf<Statements::Binding, 4>,
                               ctx_range: SourceRange) -> bool {
        // `for @move y in`: taken before the keyword probe, which would not
        // recognise `@` as a binding start. _parse_binding asks again; the
        // mode is consumed here, so it is never reported twice.
        self.dyn()->_reject_mode_binding()
        // leading 'var' | 'const' sets the default mutability; absent => mutable.
        var leading_const = false
        if self.dyn()->check(TokenKind::KwVar) {
            leading_const = false
            self.dyn()->advance()
        } else if self.dyn()->check(TokenKind::KwConst) {
            leading_const = true
            self.dyn()->advance()
        }

        // no else: missing keyword is fine, leading_const stays false (mutable).

        // parenthesized tuple binding list
        if self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->advance(T::SkipNL::After) // consume `(`

            if self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->diag->report(
                    DiagID::S058E,
                    ctx_range.start,
                    "empty binding list is not allowed",
                ).first(ctx_range)->emit()
                self.dyn()->advance() // consume `)`
                return false
            }

            while !self.dyn()->is_eof() {
                var b = self._parse_binding(leading_const)
                if !b.is_discard && b.name == &null {
                    return false // malformed binding element
                }

                out->push_back(b)

                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    if self.dyn()->check(TokenKind::OpRParen) { // trailing comma
                        break
                    }

                    continue
                }

                break
            }

            if !self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->diag->report(
                    DiagID::S058E,
                    ctx_range.start,
                    "expected ')' to close binding list",
                ).first(ctx_range)->emit()
                return false
            }

            self.dyn()->advance() // consume `)`
            return true
        }

        // single bare binding
        var b = self._parse_binding(leading_const)
        if !b.is_discard && b.name == &null {
            return false
        }

        out->push_back(b)
        return true
    }

    /// \brief parses a single binding element.
    ///  Grammar:  ('var'|'const')? ('unsafe'? '*')? (identifier | '_') '?'?
    ///
    /// \details a per-element 'var'/'const' overrides `default_const`.
    ///          Shorthand qualifiers (`*`, `unsafe *`, trailing `?`) reshape the
    ///          inferred type; sema applies them. `_` produces a discard.
    ///          On a missing identifier, returns a Binding with name == null
    ///          (and is_discard == false) so the caller can detect failure.
    priv fn _parse_binding(self, default_const: bool) -> Statements::Binding {
        var result = Statements::Binding{}
        result.name        = &null
        result.is_const    = default_const
        result.is_explicit = false
        result.is_discard  = false
        result.shorthand   = FlagSet<Statements::BindingShorthand, u8>()

        var start = self.dyn()->current_range() // `for ` may end the file

        // per-element override
        if self.dyn()->check(TokenKind::KwVar) {
            result.is_const    = false
            result.is_explicit = true
            self.dyn()->advance()
        } else if self.dyn()->check(TokenKind::KwConst) {
            result.is_const    = true
            result.is_explicit = true
            self.dyn()->advance()
        }

        self.dyn()->_reject_mode_binding() // `(@inout a, b)` / `for @move y`: parameter-only.

        // pointer shorthand: `unsafe *` or `*`
        if self.dyn()->check(TokenKind::KwUnsafe) {
            // must be followed by `*` to be a pointer shorthand
            if self.dyn()->check_peek(TokenKind::OpStar) {
                self.dyn()->advance() // consume `unsafe`
                self.dyn()->advance() // consume `*`
                result.shorthand.set(Statements::BindingShorthand::Pointer)
                result.shorthand.set(Statements::BindingShorthand::Unsafe)
            }
        } else if self.dyn()->check(TokenKind::OpStar) {
            self.dyn()->advance() // consume `*`
            result.shorthand.set(Statements::BindingShorthand::Pointer)
        }

        // discard `_`
        if self.dyn()->check(TokenKind::LitIdentifier)
            && self.dyn()->ctx->get_spelling(*self.dyn()->current_ptr()) == "_" {
            var und = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `_`
            result.is_discard = true
            result.range      = start | und
            return result
        }

        // identifier
        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S058E,
                start.start,
                "expected binding name or '_' in binding",
            ).first(start)->emit()
            result.range = start
            return result // name stays null -> caller treats as failure
        }

        var id_ptr   = self.dyn()->current_ptr()
        var id_range = id_ptr->range
        self.dyn()->advance() // consume identifier
        result.name = NamedIdentExpr::create(self.dyn()->ctx, id_range, *id_ptr)

        // nullable shorthand suffix `?`
        if self.dyn()->check(TokenKind::OpQuestion) {
            self.dyn()->advance() // consume `?`
            result.shorthand.set(Statements::BindingShorthand::Nullable)
            result.range = start | self.dyn()->prev().range
        } else {
            result.range = start | id_range
        }

        // explicit type ascription: `for var p: Path in xs`. Optional - a
        // binding without one is inferred from the iterable. `::` is a distinct
        // token, so a qualified name never reaches here as a false positive.
        if self.dyn()->check(TokenKind::OpColon) {
            self.dyn()->advance(T::SkipNL::After) // consume `:`
            result.type_ = self.dyn()->parse_type()
            result.range = start | self.dyn()->prev().range
        }

        // A binder IS a declaration, so give it a real one. Sema binds uses of
        // the name to this decl (Binding::decl); without it, every `for x in
        // xs` body that mentions `x` reported unresolved-ident. Built last so
        // the range and the `: T` ascription are final.
        var storage = if (result.is_const) => (StorageClass::Const) else => StorageClass::Var
        var bvd = VariableDecl::create(
            self.dyn()->ctx,
            result.range,
            *id_ptr,
            storage,
        )

        bvd->type_  = result.type_
        result.decl = bvd

        return result
    }

    //  var / const  -> plain decl vs destructuring decl

    /// \brief routes a `var`/`const` lead-in to a destructuring decl or a plain
    ///        declaration.
    ///  Grammar:  ('var'|'const') '(' ... ')' '=' expr      (tuple destructure)
    ///          | ('var'|'const') '{' ... '}' '=' expr      (struct destructure)
    ///          | ('var'|'const') <plain decl ...>          (-> DeclParse)
    ///
    /// \details peeks one token past the keyword. `(` or `{` => destructuring;
    ///          anything else => plain decl handled by the decl parser.
    priv fn _parse_var_or_destructure(self) -> unsafe *Stmt {
        var is_const = self.dyn()->check(TokenKind::KwConst)

        // peek past the keyword
        if self.dyn()->check_peek(TokenKind::OpLParen) {
            return self._parse_destructure(
                is_const,
                Statements::DestructureKind::Tuple,
            )
        }

        if self.dyn()->check_peek(TokenKind::OpLBrace) {
            return self._parse_destructure(
                is_const,
                Statements::DestructureKind::Struct,
            )
        }

        // plain decl
        return self._parse_decl_stmt()
    }

    /// \brief parses a destructuring declaration.
    ///  Grammar:  ('var'|'const') tuple_pat  '=' expr
    ///          | ('var'|'const') struct_pat '=' expr
    ///    tuple_pat  := '(' binding (',' binding)* ')'
    ///    struct_pat := '{' binding (',' binding)* '}'
    ///
    /// \details precondition: current token is `var`/`const`, next is `(`/`{`.
    ///          For struct destructuring, binding names must match field names
    ///          (sema-checked). The RHS is a full expression.
    priv fn _parse_destructure(self, is_const: bool, dkind: Statements::DestructureKind) -> *Stmt {
        var start_range = self.dyn()->current_ptr()->range

        if !self.dyn()->enter_depth() {
            return self._error_stmt(start_range)
        }

        // consume `var`/`const`
        self.dyn()->advance()

        var open = if (dkind == Statements::DestructureKind::Tuple) => (TokenKind::OpLParen)
                   else => TokenKind::OpLBrace
        var close = if (dkind == Statements::DestructureKind::Tuple) => (TokenKind::OpRParen)
                    else => TokenKind::OpRBrace

        // consume opener
        self.dyn()->advance(T::SkipNL::After)

        var bindings: kairo::std::StackBuf<Statements::Binding, 4>

        if self.dyn()->check(close) {
            self.dyn()->diag->report(
                DiagID::S058E,
                start_range.start,
                "empty destructuring pattern is not allowed",
            ).first(start_range)->emit()
            self.dyn()->advance() // consume closer
            self.dyn()->exit_depth()
            var err = Statements::DestructuringDeclStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err
        }

        while !self.dyn()->is_eof() {
            var b = self._parse_binding(is_const)
            if !b.is_discard && b.name == &null {
                self._sync_stmt(Self::StmtSyncCtx::Block, 0)
                self.dyn()->exit_depth()
                var err = Statements::DestructuringDeclStmt::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                )

                return err
            }

            bindings.push_back(b)

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                if self.dyn()->check(close) { // trailing comma
                    break
                }

                continue
            }

            break
        }

        if !self.dyn()->check(close) {
            self.dyn()->diag->report(
                DiagID::S058E,
                start_range.start,
                "expected closing delimiter in destructuring pattern",
            ).first(start_range)->emit()
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_depth()
            var err = Statements::DestructuringDeclStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err
        }

        self.dyn()->advance() // consume closer

        // require `=`
        if !self.dyn()->check(TokenKind::OpEqual) {
            self.dyn()->diag->report(
                DiagID::S058E,
                start_range.start,
                "expected '=' after destructuring pattern",
            ).first(start_range)->emit()
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_depth()
            var err = Statements::DestructuringDeclStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err
        }

        self.dyn()->advance(T::SkipNL::After) // consume `=`

        var value = self.dyn()->parse_expr()
        if value == &null || is_recovery(value) {
            self.dyn()->exit_depth()
            var err = Statements::DestructuringDeclStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err
        }

        var full = start_range | value->range
        var node = Statements::DestructuringDeclStmt::create(
            self.dyn()->ctx,
            full,
            dkind,
            value,
            is_const,
        )

        node->bindings.from_buf(
            bindings.data(),
            bindings.size(),
            self.dyn()->ctx,
        )

        self.dyn()->exit_depth()
        return node
    }

    //  Declaration statement  (delegates to DeclParse)

    /// \brief wraps a declaration parsed by DeclParse in a DeclStmt.
    ///  Grammar:  decl
    ///
    /// \details DeclParse::parse_decl owns annotation/qualifier consumption for
    ///          the decl itself; parse_stmt already stripped leading
    ///          annotations, so any consumed here are decl-specific (e.g. `pub`
    ///          on a local). NOTE: parse_decl is currently a stub returning
    ///          null; this path produces a recovery DeclStmt until it lands.
    priv fn _parse_decl_stmt(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range

        var decl = self.dyn()->parse_decl()
        if decl == &null {
            // stub / failure: guarantee forward progress before syncing,
            // since _sync_stmt may no-op when sitting on a stmt lead-in.
            self.dyn()->advance()
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            var err = Statements::DeclStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err
        }

        self._attach_local_decl(decl)
        var ds = Statements::DeclStmt::create(
            self.dyn()->ctx,
            decl->range,
            decl,
        )

        return ds
    }

    //  Conditional

    /// \brief parses an if statement with else-if chaining.
    ///  Grammar:  'if' expr block ('else' 'if' expr block)* ('else' block)?
    ///          | 'if' expr NL* '=>' ...                   (value form, see below)
    ///
    /// \details precondition: current token is `if`. The condition is parsed
    ///          with struct-literal suppression so `if Foo { }` is not misread
    ///          as a named initializer (NoStructLiteral stop bit). `else_` is a
    ///          *Stmt: either the next ConditionalStmt (an `else if`) or a
    ///          CompoundStmt (the final `else`).
    ///
    ///          A `=>` after the condition makes it a value-form `if` used as a
    ///          statement (`if c => f() else => g()`): the rest is the
    ///          expression parser's _finish_if_expr, reusing the condition
    ///          already parsed, wrapped in an ExpressionStmt. Nothing is
    ///          re-lexed or backtracked. `in_chain` is set for the `else if`
    ///          of a statement chain, where a `=>` cannot start a value form:
    ///          the chain is already a statement (S056E).
    priv fn _parse_conditional(self,
                               in_chain: bool = false,
                               is_eval:  bool = false) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range

        if !self.dyn()->enter_depth() {
            return self._error_stmt(start_range)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `if`

        // The head runs to `{` (or `=>`), never to a newline: nothing can
        // start a statement inside it, so `if a` newline `+ b == c {` is one
        // condition, as it is inside parentheses.
        self.dyn()->nl_push()
        var cond = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
        )

        self.dyn()->nl_pop()
        if cond == &null || is_recovery(cond) {
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_depth()
            return (Statements::ConditionalStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self.dyn()->_require_parens(cond)

        if self.dyn()->_skip_nl_if_next(TokenKind::OpFatArrow) {
            if in_chain {
                var arrow = self.dyn()->current_ptr()->range
                self.dyn()->diag->report(
                    DiagID::S056E,
                    arrow.start,
                    "expected '{' after 'else if' condition; a statement 'if' chain cannot continue with '=>' arms",
                ).first(arrow)->emit()
                // still consume the value-form arms, so they cannot cascade.
                self.dyn()->_finish_if_expr(
                    start_range,
                    cond,
                    self.dyn()->no_stop(),
                )

                self.dyn()->exit_depth()
                return (Statements::ConditionalStmt::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }

            var value = self.dyn()->_finish_if_expr(
                start_range,
                cond,
                self.dyn()->no_stop(),
            )

            self.dyn()->exit_depth()
            return Statements::ExpressionStmt::create(
                self.dyn()->ctx,
                value->range,
                value,
            )
        }

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after 'if' condition",
            ).first(start_range)->emit()
            self.dyn()->exit_depth()
            return (Statements::ConditionalStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var unsafe *then_ = self.parse_compound()

        var else_: unsafe *Stmt = &null

        // `} @unlikely else`: a branch hint for the else branch. It is only
        // taken when `else` follows it (_else_attr_kind looks ahead), so an
        // attribute that opens the next statement is left alone.
        var else_hint: u8 = 0
        var hint_kind     = self.dyn()->_else_attr_kind()
        if hint_kind != 0 {
            if self.dyn()->nl_depth == 0 && self.dyn()->check(TokenKind::TkNewLine) {
                self.dyn()->advance(T::SkipNL::Only)
            }

            var at_r = self.dyn()->current_ptr()->range
            self.dyn()->advance()                 // `@`
            self.dyn()->advance(T::SkipNL::After) // the name, then up to `else`
            if hint_kind == 3 {
                var b = self.dyn()->diag->report(
                    DiagID::S081E,
                    at_r.start,
                    "only " + LangAttrs::at(LangAttrs::likely()) + " / " + LangAttrs::at(
                        LangAttrs::unlikely(),
                    ) + " may precede 'else'",
                )

                b.first(at_r)
                b.remove(
                    at_r | self.dyn()->prev().range,
                    "remove the attribute",
                )

                b.emit()
            } else {
                else_hint = (hint_kind as u8)
            }
        }

        // `else` may sit on its own line after the then-branch's closing `}`:
        //     if      c { ... }
        //     else if d { ... }
        // `else` cannot begin a statement, so a newline in front of it is never
        // ambiguous with the start of a new one.
        if hint_kind == 0
            && self.dyn()->nl_depth == 0
            && self.dyn()->ig_kind() == TokenKind::TkNewLine {
            if self.dyn()->peek_past_nl_kind() == TokenKind::KwElse {
                self.dyn()->advance(T::SkipNL::Only)
            }
        }

        if self.dyn()->check(TokenKind::KwElse) {
            self.dyn()->advance(T::SkipNL::After) // consume `else`

            if self.dyn()->check(TokenKind::KwIf) {
                // else-if: recurse, store the ConditionalStmt directly as else_
                else_ = self._parse_conditional(true, is_eval)
            } else if self.dyn()->check(TokenKind::OpLBrace) {
                // final else: a block
                else_ = self.parse_compound()
            } else {
                self.dyn()->diag->report(
                    DiagID::S056E,
                    start_range.start,
                    "expected '{' or 'if' after 'else'",
                ).first(start_range)->emit()
                // leave else_ null; recover.
            }
        }

        var end = if (else_ != &null) => (else_->range) else => then_->range
        var node = Statements::ConditionalStmt::create(
            self.dyn()->ctx,
            start_range | end,
            cond,
            then_,
            else_,
        )

        node->is_eval   = is_eval
        node->else_hint = else_hint
        self.dyn()->exit_depth()
        return node
    }

    //  While / Loop

    /// \brief parses a while loop.
    ///  Grammar:  'while' expr block
    priv fn _parse_while(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `while`

        // as an if head (_parse_conditional): the head ends at `{`.
        self.dyn()->nl_push()
        var cond = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
        )

        self.dyn()->nl_pop()
        if cond == &null || is_recovery(cond) {
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            return (Statements::WhileLoopStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after 'while' condition",
            ).first(start_range)->emit()
            return (Statements::WhileLoopStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var unsafe *body = self.parse_compound()

        var node = Statements::WhileLoopStmt::create(
            self.dyn()->ctx,
            start_range | body->range,
            cond,
            body,
        )

        return node
    }

    /// \brief parses an unconditional loop.
    ///  Grammar:  'loop' block
    priv fn _parse_loop(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `loop`

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after 'loop'",
            ).first(start_range)->emit()
            return (Statements::LoopStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var unsafe *body = self.parse_compound()

        var node = Statements::LoopStmt::create(
            self.dyn()->ctx,
            start_range | body->range,
            body,
        )

        return node
    }

    //  For  (ranged and C-style)

    /// \brief parses a for loop, dispatching between ranged and C-style forms.
    ///  Grammar:  'for' binding_spec 'in' expr block          (ranged)
    ///          | 'for' decl_stmt ';' expr ';' expr block     (C-style)
    ///
    /// \details precondition: current token is `for` (the `eval` prefix, if any,
    ///          was already consumed by the dispatcher, hence `is_eval`).
    ///          Disambiguation: after `for`, a `var`/`const` followed eventually
    ///          by `in` is ranged; a `var`/`const` followed by an initializer and
    ///          `;` is C-style. We detect the C-style form by the presence of an
    ///          `=` initializer or a `;` before any `in` within the header. The
    ///          split: tentatively scan the header keyword shape
    ///          ranged headers never contain `;`. We peek for that.
    priv fn _parse_for(self, is_eval: bool) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range

        if !self.dyn()->enter_depth() {
            return self._error_stmt(start_range)
        }

        self.dyn()->advance(T::SkipNL::After) // consume `for`

        self.dyn()->enter_scope(
            ScopeKind::ForLoop,
            self.dyn()->scope.current_dc(),
        )

        // Disambiguate ranged vs C-style.
        // C-style begins with a decl that has an `=` initializer and uses `;`
        // separators. Ranged begins with a binding spec and uses `in`.
        // We use a tentative scan: parse the binding spec; if `in` follows, it's
        // ranged. Otherwise roll back and parse the C-style header.
        // `for ; c; s` (empty init) is C-style from its first token, and
        // the binding scan would report the `;` it cannot bind.
        if self.dyn()->check(TokenKind::OpSemicolon) {
            return self._parse_indexed_for(start_range, is_eval)
        }

        var saved = self.dyn()->tentative_begin()

        var bindings: kairo::std::StackBuf<Statements::Binding, 4>
        var spec_ok = self._parse_binding_spec_opt(&bindings, start_range)

        if spec_ok && self.dyn()->check(TokenKind::KwIn) {
            /// ## ranged form
            self.dyn()->advance(T::SkipNL::After) // consume `in`

            var iterable = self.dyn()->parse_expr(
                self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
            )

            if iterable == &null || is_recovery(iterable) {
                self._sync_stmt(Self::StmtSyncCtx::Block, 0)
                self.dyn()->exit_scope()
                self.dyn()->exit_depth()
                return (Statements::RangedForStmt::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }

            if !self.dyn()->check(TokenKind::OpLBrace) {
                self.dyn()->diag->report(
                    DiagID::S056E,
                    start_range.start,
                    "expected '{' after 'for ... in' header",
                ).first(start_range)->emit()
                self.dyn()->exit_scope()
                self.dyn()->exit_depth()
                return (Statements::RangedForStmt::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }

            var unsafe *body = self.parse_compound()

            var node = Statements::RangedForStmt::create(
                self.dyn()->ctx,
                start_range | body->range,
                iterable,
                body,
                is_eval,
            )

            node->bindings.from_buf(
                bindings.data(),
                bindings.size(),
                self.dyn()->ctx,
            )

            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            return node
        }

        /// # C-style form
        self.dyn()->tentative_rollback(saved)
        return self._parse_indexed_for(start_range, is_eval)
    }

    /// \brief parses a C-style three-part for loop.
    ///  Grammar:  'for' decl_stmt? ';' expr ';' expr block
    ///
    /// \details the init clause may be empty: `for ; c; s`
    ///          loops over a variable declared before it, and unlike the
    ///          `while` it would otherwise be, a `continue` still runs `s`.
    ///
    /// \details precondition: cursor is at the start of the init clause (after
    ///          `for`). The init is a variable declaration scoped to the loop
    ///          (a DeclStmt). `cond` and `update` are bare expressions. The
    ///          enclosing scope (ForLoop) was already pushed by _parse_for and
    ///          is popped here.
    priv fn _parse_indexed_for(self, start_range: SourceRange, is_eval: bool) -> *Stmt {
        // init clause: a var/const decl (DeclParse owns it), or nothing.
        var empty_init              = self.dyn()->check(TokenKind::OpSemicolon)
        var init:      unsafe *Stmt = &null
        if !empty_init {
            init = self._parse_decl_stmt()
        }

        if !empty_init && (init == &null || self.is_fatal_stmt(init)) {
            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            return (Statements::IndexedForStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        if !self.dyn()->check(TokenKind::OpSemicolon) {
            self.dyn()->diag->report(
                DiagID::S059E,
                start_range.start,
                "expected ';' after for-loop initializer",
            ).first(start_range)->emit()
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            return (Statements::IndexedForStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance(T::SkipNL::After) // consume `;`

        var cond = self.dyn()->parse_expr()
        if cond == &null || is_recovery(cond) {
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            return (Statements::IndexedForStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        if !self.dyn()->check(TokenKind::OpSemicolon) {
            self.dyn()->diag->report(
                DiagID::S059E,
                start_range.start,
                "expected ';' after for-loop condition",
            ).first(start_range)->emit()
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            return (Statements::IndexedForStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance(T::SkipNL::After) // consume `;`

        var update = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
        )

        if update == &null || is_recovery(update) {
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            return (Statements::IndexedForStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after C-style for header",
            ).first(start_range)->emit()
            self.dyn()->exit_scope()
            self.dyn()->exit_depth()
            return (Statements::IndexedForStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var unsafe *body = self.parse_compound()

        var node = Statements::IndexedForStmt::create(
            self.dyn()->ctx,
            start_range | body->range,
            init,
            cond,
            update,
            body,
            is_eval,
        )

        self.dyn()->exit_scope()
        self.dyn()->exit_depth()
        return node
    }

    //  Match

    /// \brief parses a match in statement position.
    ///  Grammar:  'match' expr '{' arm* '}'           (see _parse_match_core)
    ///
    /// \details the arms decide what the statement is. All `{ }` blocks: a
    ///          MatchStmt, as before. All `=> value`: still a value, so it
    ///          becomes ExpressionStmt(MatchExpr) and the expression-form rules
    ///          (mandatory exhaustiveness included) apply to it in sema. Both:
    ///          S075E, with a note at the first arm of the other form.
    pub fn _parse_match(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range

        var core = self._parse_match_core(start_range)
        if !core.ok {
            return Statements::MatchStmt::create_error(
                self.dyn()->ctx,
                core.range,
            )
        }

        if core.form == MatchForm::AllValue {
            var me = MatchExpr::create(
                self.dyn()->ctx,
                core.range,
                core.scrutinee,
            )

            me->cases = core.cases
            return unsafe (Statements::ExpressionStmt::create(self.dyn()->ctx, core.range, unsafe (me as unsafe *Expr)) as unsafe *Stmt)
        }

        if core.form == MatchForm::Mixed {
            // the first arm sets the form; the note goes to the first arm
            // that broke it.
            var other = if (core.first_block < core.first_value) => (core.first_value)
                        else => core.first_block
            var b = self.dyn()->diag->report(
                DiagID::S075E,
                start_range.start,
                "match arms mix '=>' and '{ }' forms",
            )

            b.first(start_range)
            b.note(
                other.start,
                "this arm uses the other form; every arm of one 'match' uses the same form",
            )

            b.emit()
            return Statements::MatchStmt::create_error(
                self.dyn()->ctx,
                core.range,
            )
        }

        var node = Statements::MatchStmt::create(
            self.dyn()->ctx,
            core.range,
            core.scrutinee,
        )

        node->cases = core.cases
        return node
    }

    /// \brief the part of `match` shared by both positions: scrutinee, braces
    ///        and arms.
    ///  Grammar:  'match' expr(NoStructLiteral) '{' arm* '}'
    ///    arm      := 'case' pattern (',' pattern)* ('where' expr(NoStructLiteral))? NL* arm_body
    ///              | 'default' NL* arm_body
    ///    arm_body := block                       // statement arm
    ///              | '=>' NL* value              // value arm, value stop = StopBrace
    ///
    /// \details precondition: current token is `match`. The caller turns the
    ///          result into a MatchStmt or a MatchExpr by `form`. `ok` is false
    ///          on a structural failure (already reported), with `range`
    ///          covering what was consumed. A `,` after an arm is the Rust
    ///          spelling: S076E, removed by the fix-it, and parsing continues.
    pub fn _parse_match_core(self, start_range: SourceRange) -> MatchCore {
        var core = MatchCore{}
        core.ok          = false
        core.scrutinee   = &null
        core.form        = MatchForm::AllBlock
        core.range       = start_range
        core.first_block = SourceRange::invalid()
        core.first_value = SourceRange::invalid()

        if !self.dyn()->enter_depth() {
            return core
        }

        self.dyn()->advance(T::SkipNL::After) // consume `match`

        var scrutinee = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
        )

        if scrutinee == &null || is_recovery(scrutinee) {
            self._sync_stmt(Self::StmtSyncCtx::Block, 0)
            self.dyn()->exit_depth()
            core.range = start_range | self.dyn()->prev().range
            return core
        }

        self.dyn()->_require_parens(scrutinee)

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after 'match' scrutinee",
            ).first(start_range)->emit()
            self.dyn()->exit_depth()
            core.range = start_range | self.dyn()->prev().range
            return core
        }

        var lbrace_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var cases:    kairo::std::StackBuf<Statements::MatchCase, 8>
        var has_block                                                = false
        var has_value                                                = false

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            if self.dyn()->check(TokenKind::TkNewLine) {
                self.dyn()->advance()
                continue
            }

            var form = ArmForm::Block
            var mc   = self._parse_match_case(&form)
            // an arm with neither a body nor a value failed to parse; recover.
            if mc.body == &null && mc.expression == &null {
                if self._sync_stmt_progress(Self::StmtSyncCtx::Block, 0) {
                    if self.dyn()->is_eof() || self.dyn()->check(TokenKind::OpRBrace) {
                        break // the match's own `}`: the arm loop ends on it
                    }

                    self.dyn()->advance() // a stray `)` / `]` inside the braces
                }

                continue
            }

            if form == ArmForm::Value {
                // `case 1 =>` with no value is already reported; which form
                // the arm meant is unknown, so it does not make the match
                // "mixed" against the `{ }` arms around it.
                if !is_recovery(mc.expression) {
                    if !has_value {
                        core.first_value = mc.range
                    }

                    has_value = true
                }
            } else {
                if !has_block {
                    core.first_block = mc.range
                }

                has_block = true
            }

            cases.push_back(mc)

            if self.dyn()->check(TokenKind::OpComma) {
                var comma = self.dyn()->current_ptr()->range
                var b = self.dyn()->diag->report(
                    DiagID::S076E,
                    comma.start,
                    "match arms are not separated by ','",
                )

                b.first(comma)
                b.remove(comma, "remove ','")
                b.emit()
                self.dyn()->advance() // consume `,`
            }
        }

        if self.dyn()->check(TokenKind::OpRBrace) {
            core.range = start_range | self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        } else {
            self.dyn()->diag->report(
                DiagID::S057E,
                lbrace_range.start,
                "expected '}' to close match statement",
            ).first(lbrace_range)->emit()
            core.range = start_range | self.dyn()->prev().range
        }

        core.scrutinee = scrutinee
        core.cases.from_buf(cases.data(), cases.size(), self.dyn()->ctx)
        if has_block && has_value {
            core.form = MatchForm::Mixed
        } else if has_value {
            core.form = MatchForm::AllValue
        }

        core.ok = true

        self.dyn()->exit_depth()
        return core
    }

    /// \brief parses a single match case or default arm.
    ///  Grammar:  'case' pattern (',' pattern)* ('where' expr)? NL* arm_body
    ///          | 'default' NL* arm_body
    ///    arm_body := block | '=>' NL* value
    ///
    /// \details `{` makes a statement arm (`body`), `=>` a value arm
    ///          (`expression`), and `form` says which. On success exactly one
    ///          of the two is non-null; both null is a structural parse
    ///          failure (caller recovers). Pattern alternatives share one arm;
    ///          the `where` guard, if present, applies to the whole arm.
    priv fn _parse_match_case(self, form: *ArmForm) -> Statements::MatchCase {
        var result = Statements::MatchCase{}
        result.guard      = &null
        result.body       = &null
        result.expression = &null
        result.is_default = false

        var start_range = self.dyn()->current_ptr()->range
        var pats:  kairo::std::StackBuf<*Pattern, 4>
        var after: string                            = "pattern"

        if self.dyn()->check(TokenKind::KwDefault) {
            // default arm: patterns left empty
            self.dyn()->advance(T::SkipNL::After) // consume `default`
            result.is_default = true
            after             = "'default'"
        } else {
            // case arm
            if !self.dyn()->check(TokenKind::KwCase) {
                self.dyn()->diag->report(
                    DiagID::S059E,
                    start_range.start,
                    "expected 'case' or 'default' in match body",
                ).first(start_range)->emit()
                return result // body stays null
            }

            self.dyn()->advance(T::SkipNL::After) // consume `case`

            var last_bad = false
            while !self.dyn()->is_eof() {
                var *p = self._parse_pattern()
                pats.push_back(p)
                last_bad = p->is_error()
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                break
            }

            // `case` then the match's `}`: the missing pattern is reported;
            // an "expected '=>'" on the same `}` would say nothing more.
            if last_bad && self.dyn()->check(TokenKind::OpRBrace) {
                return result // body stays null
            }

            // optional `where` guard
            if self.dyn()->check(TokenKind::KwWhere) {
                self.dyn()->advance(T::SkipNL::After) // consume `where`
                var guard = self.dyn()->parse_expr(
                    self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
                )

                if guard == &null || is_recovery(guard) {
                    self._sync_stmt(Self::StmtSyncCtx::Block, 0)
                    return result // body stays null
                }

                self.dyn()->_require_parens(guard)
                result.guard = guard
            }
        }

        result.patterns.from_buf(pats.data(), pats.size(), self.dyn()->ctx)

        // statement arm
        if self.dyn()->_skip_nl_if_next(TokenKind::OpLBrace) {
            *form        = ArmForm::Block
            result.body  = self.parse_compound()
            result.range = start_range | result.body->range
            return result
        }

        // value arm; the next `case`, `default` or the closing `}` ends it.
        var value: unsafe *Expr = &null
        if self.dyn()->_skip_nl_if_next(TokenKind::OpFatArrow) {
            value = self.dyn()->_parse_arm_value(
                self.dyn()->stop_on(T::ExprStopKind::StopBrace),
            )
        } else {
            value = self.dyn()->_expect_arrow_recover(
                after,
                self.dyn()->stop_on(T::ExprStopKind::StopBrace),
            )
        }

        if value == &null {
            return result // both stay null
        }

        *form             = ArmForm::Value
        result.expression = value
        result.range      = start_range | value->range
        return result
    }

    /// \brief STUB: pattern parsing seam.
    /// \details PatternParse is not yet implemented. This consumes a single
    ///          conservative token run (until `,`, `where`, `{`, or a stop
    ///          token) so the surrounding match-arm structure parses, and
    ///          returns null. Replace with a real `dyn()->parse_pattern()`
    ///          call once PatternParse exists.
    priv fn _parse_pattern(self) -> *Pattern {
        return self.dyn()->parse_pattern()
    }

    //  Jump / signal statements

    /// \brief parses a return statement.
    ///  Grammar:  'return' | 'return' expr
    ///
    /// \details a value is present unless the next token ends the statement
    ///          (newline, `;`, `}`, EOF).
    priv fn _parse_return(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `return` (do NOT skip newlines: bare return)

        // bare return if the statement ends here
        if self.dyn()->is_eof()
            || self.dyn()->check(TokenKind::TkNewLine)
            || self.dyn()->check(TokenKind::OpSemicolon)
            || self.dyn()->check(TokenKind::OpRBrace) {
            var node = Statements::ReturnStmt::create(
                self.dyn()->ctx,
                start_range,
                &null,
            )

            return node
        }

        var value = self.dyn()->parse_expr()
        if value == &null || is_recovery(value) {
            return (Statements::ReturnStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var node = Statements::ReturnStmt::create(
            self.dyn()->ctx,
            start_range | value->range,
            value,
        )

        return node
    }

    /// \brief parses a break statement.
    ///  Grammar:  'break' | 'break' identifier
    priv fn _parse_break(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `break` (no NL skip: optional label is same-line)

        if self.dyn()->check(TokenKind::LitIdentifier) {
            var label = self.dyn()->current()
            self.dyn()->advance()
            var node = Statements::BreakStmt::create(
                self.dyn()->ctx,
                start_range | label.range,
                true,
                label,
            )

            return node
        }

        var node = Statements::BreakStmt::create(
            self.dyn()->ctx,
            start_range,
            false,
            Token(),
        )

        return node
    }

    /// \brief parses a continue statement.
    ///  Grammar:  'continue' | 'continue' identifier
    priv fn _parse_continue(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `continue`

        if self.dyn()->check(TokenKind::LitIdentifier) {
            var label = self.dyn()->current()
            self.dyn()->advance()
            var node = Statements::ContinueStmt::create(
                self.dyn()->ctx,
                start_range | label.range,
                true,
                label,
            )

            return node
        }

        var node = Statements::ContinueStmt::create(
            self.dyn()->ctx,
            start_range,
            false,
            Token(),
        )

        return node
    }

    /// \brief parses a panic statement.
    ///  Grammar:  'panic' expr
    priv fn _parse_panic(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `panic`

        var payload = self.dyn()->parse_expr()
        if payload == &null || is_recovery(payload) {
            self.dyn()->diag->report(
                DiagID::S052E,
                start_range.start,
                "expected expression after 'panic'",
            ).first(start_range)->emit()
            return (Statements::PanicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var node = Statements::PanicStmt::create(
            self.dyn()->ctx,
            start_range | payload->range,
            payload,
        )

        return node
    }

    /// \brief parses a yield statement.
    ///  Grammar:  'yield' expr
    priv fn _parse_yield(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `yield`

        var value = self.dyn()->parse_expr()
        if value == &null || is_recovery(value) {
            self.dyn()->diag->report(
                DiagID::S052E,
                start_range.start,
                "expected expression after 'yield'",
            ).first(start_range)->emit()
            return (Statements::YieldStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var node = Statements::YieldStmt::create(
            self.dyn()->ctx,
            start_range | value->range,
            value,
        )

        return node
    }

    /// \brief parses a runtime or static assertion.
    ///  Grammar:  'assert' 'static'? expr (',' expr)?
    ///
    /// \details `assert static` produces a StaticAssertStmt; plain `assert`
    ///          produces a RuntimeAssertStmt. The optional second operand is a
    ///          diagnostic message expression.
    priv fn _parse_assert(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `assert`

        var is_static = false
        if self.dyn()->check(TokenKind::KwStatic) {
            is_static = true
            self.dyn()->advance(T::SkipNL::After) // consume `static`
        }

        var cond = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::StopComma),
        )

        if cond == &null || is_recovery(cond) {
            self.dyn()->diag->report(
                DiagID::S052E,
                start_range.start,
                "expected condition expression after 'assert'",
            ).first(start_range)->emit()
            if is_static {
                return (Statements::StaticAssertStmt::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                ))
            }

            return (Statements::RuntimeAssertStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var message: unsafe *Expr = &null
        if self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->advance(T::SkipNL::After) // consume `,`
            message = self.dyn()->parse_expr()
            if message == &null || is_recovery(message) {
                message = &null // recover: drop the malformed message
            }
        }

        var end = if (message != &null) => (message->range) else => cond->range
        if is_static {
            var node = Statements::StaticAssertStmt::create(
                self.dyn()->ctx,
                start_range | end,
                cond,
                message,
            )

            return node
        }

        var node = Statements::RuntimeAssertStmt::create(
            self.dyn()->ctx,
            start_range | end,
            cond,
            message,
        )

        return node
    }

    //  Try / catch  (finally is separate)

    /// \brief parses a try/catch statement.
    ///  Grammar:  'try' block ('catch' catch_filter? block)+
    ///    catch_filter := identifier (':' type)?
    ///
    /// \details `finally` is NOT consumed here; `try {} finally {}` is a
    ///          TryCatchStmt followed by a separate FinallyStmt. At least one
    ///          catch arm is expected; absence is reported but recovered.
    priv fn _parse_try_catch(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `try`

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after 'try'",
            ).first(start_range)->emit()
            return (Statements::TryCatchStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var unsafe *try_body = self.parse_compound()

        var arms: kairo::std::StackBuf<Statements::CatchArm, 4>

        while self.dyn()->check(TokenKind::KwCatch) {
            var arm = self._parse_catch_arm()
            if arm.body == &null {
                self._sync_stmt(Self::StmtSyncCtx::Block, 0)
                break
            }

            arms.push_back(arm)
        }

        if arms.size() == 0 {
            self.dyn()->diag->report(
                DiagID::S059E,
                start_range.start,
                "expected at least one 'catch' arm after 'try' block",
            ).first(start_range)->emit()
        }

        var full = start_range | self.dyn()->prev().range
        var node = Statements::TryCatchStmt::create(
            self.dyn()->ctx,
            full,
            try_body,
        )

        node->arms.from_buf(arms.data(), arms.size(), self.dyn()->ctx)
        return node
    }

    /// \brief parses one catch arm.
    ///  Grammar:  'catch' (identifier (':' type)?)? block
    ///
    /// \details forms: `catch { }` (bare), `catch e { }` (binding only),
    ///          `catch e: Type { }` (binding + filter). Returns an arm with a
    ///          null body on parse failure.
    priv fn _parse_catch_arm(self) -> Statements::CatchArm {
        var result = Statements::CatchArm{}
        result.filter  = &null
        result.binding = &null
        result.body    = &null

        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `catch`
        self.dyn()->_reject_mode_binding()    // `catch @inout e`: parameter-only.

        // optional binding identifier
        if self.dyn()->check(TokenKind::LitIdentifier) {
            var id_ptr   = self.dyn()->current_ptr()
            var id_range = id_ptr->range
            self.dyn()->advance() // consume identifier
            result.binding = NamedIdentExpr::create(
                self.dyn()->ctx,
                id_range,
                *id_ptr,
            )

            // The caught error is a declaration; see CatchArm::decl.
            result.decl = VariableDecl::create(
                self.dyn()->ctx,
                id_range,
                *id_ptr,
                StorageClass::Var,
            )

            // optional `: Type` filter
            if self.dyn()->check(TokenKind::OpColon) {
                self.dyn()->advance(T::SkipNL::After) // consume `:`
                var filter = self.dyn()->parse_type()
                if filter == &null || is_recovery(filter) {
                    self.dyn()->diag->report(
                        DiagID::S053E,
                        start_range.start,
                        "expected panic type after ':' in catch arm",
                    ).first(start_range)->emit()
                    return result // body stays null
                }

                result.filter = filter
            }
        }

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' to begin catch arm body",
            ).first(start_range)->emit()
            return result // body stays null
        }

        result.body  = self.parse_compound()
        result.range = start_range | result.body->range
        return result
    }

    /// \brief parses a standalone finally statement.
    ///  Grammar:  'finally' block
    priv fn _parse_finally(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `finally`

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after 'finally'",
            ).first(start_range)->emit()
            return (Statements::FinallyStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var unsafe *body = self.parse_compound()

        var node = Statements::FinallyStmt::create(
            self.dyn()->ctx,
            start_range | body->range,
            body,
        )

        return node
    }

    //  Unsafe / eval blocks

    /// \brief parses an unsafe block.
    ///  Grammar:  'unsafe' block
    ///
    /// \details precondition: current is `unsafe`, peek is `{` (the dispatcher
    ///          checked). Pushes a Block scope via parse_compound; the unsafe
    ///          context itself (AMT suspension) is a sema concern keyed on the
    ///          node kind.
    priv fn _parse_unsafe_block(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `unsafe`

        var unsafe *body = self.parse_compound()
        var node = Statements::UnsafeBlockStmt::create(
            self.dyn()->ctx,
            start_range | body->range,
            body,
        )

        return node
    }

    /// \brief parses a decl-only eval block.
    ///  Grammar:  'eval' '{' decl* '}'
    ///
    /// \details precondition: current is `eval`, peek is `{`. Only declarations
    ///          are legal inside; a non-decl statement is a sema error (the
    ///          parser still consumes it for recovery, but only decls are
    ///          retained in the body list).
    priv fn _parse_eval_block(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `eval`

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' after 'eval'",
            ).first(start_range)->emit()
            return (Statements::EvalBlockStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var lbrace_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `{`

        var decls: kairo::std::StackBuf<*Decl, 8>

        while !self.dyn()->is_eof() && !self.dyn()->check(TokenKind::OpRBrace) {
            if self.dyn()->check(TokenKind::TkNewLine)
                || self.dyn()->check(TokenKind::OpSemicolon) {
                self.dyn()->advance()
                continue
            }

            var decl = self.dyn()->parse_decl()
            if decl == &null {
                self.dyn()->advance()
                // decl parser stub / non-decl content: recover to a boundary.
                // the advance above already moved; a `)` / `]` left by the
                // sync is retried, and parse_decl's failure advances past it
                self._sync_stmt_progress(Self::StmtSyncCtx::Block, 0)
                if self.dyn()->check(TokenKind::OpRBrace) {
                    break
                }

                continue
            }

            decls.push_back(decl)
            self._consume_terminator()
        }

        var full_range = start_range
        if self.dyn()->check(TokenKind::OpRBrace) {
            full_range = start_range | self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::Before) // consume `}`
        } else {
            self.dyn()->diag->report(
                DiagID::S057E,
                lbrace_range.start,
                "expected '}' to close eval block",
            ).first(lbrace_range)->emit()
            full_range = start_range | self.dyn()->prev().range
        }

        var node = Statements::EvalBlockStmt::create(
            self.dyn()->ctx,
            full_range,
        )

        node->body.from_buf(decls.data(), decls.size(), self.dyn()->ctx)
        return node
    }

    //  label! / jump! intrinsics

    /// \brief parses a label intrinsic.
    ///  Grammar:  'label' '!' '(' identifier ')'
    priv fn _parse_label_intrinsic(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `label`

        if !self.dyn()->check(TokenKind::OpExclaim) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected '!' after 'label' intrinsic",
            ).first(start_range)->emit()
            return (Statements::LabelIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance() // consume `!`

        if !self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected '(' after 'label!'",
            ).first(start_range)->emit()
            return (Statements::LabelIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance(T::SkipNL::After) // consume `(`

        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected label name inside 'label!(...)'",
            ).first(start_range)->emit()
            return (Statements::LabelIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var name = self.dyn()->current()
        self.dyn()->advance(T::SkipNL::After) // consume identifier

        if !self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected ')' to close 'label!(...)'",
            ).first(start_range)->emit()
            return (Statements::LabelIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var end = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `)`

        var node = Statements::LabelIntrinsicStmt::create(
            self.dyn()->ctx,
            start_range | end,
            name,
        )

        return node
    }

    /// \brief parses a jump intrinsic.
    ///  Grammar:  'jump' '!' '(' identifier ')'
    priv fn _parse_jump_intrinsic(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `jump`

        if !self.dyn()->check(TokenKind::OpExclaim) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected '!' after 'jump' intrinsic",
            ).first(start_range)->emit()
            return (Statements::JumpIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance() // consume `!`

        if !self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected '(' after 'jump!'",
            ).first(start_range)->emit()
            return (Statements::JumpIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        self.dyn()->advance(T::SkipNL::After) // consume `(`

        if !self.dyn()->check(TokenKind::LitIdentifier) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected target name inside 'jump!(...)'",
            ).first(start_range)->emit()
            return (Statements::JumpIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var target = self.dyn()->current()
        self.dyn()->advance(T::SkipNL::After) // consume identifier

        if !self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected ')' to close 'jump!(...)'",
            ).first(start_range)->emit()
            return (Statements::JumpIntrinsicStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var end = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `)`

        var node = Statements::JumpIntrinsicStmt::create(
            self.dyn()->ctx,
            start_range | end,
            target,
        )

        return node
    }

    //  Inline foreign block

    /// \brief parses an inline foreign block.
    ///  Grammar:  'inline' string_literal '{' <opaque> '}'
    ///
    /// \details the language is taken from the string literal ("asm"/"c"/"c++").
    ///          The body is opaque to the Kairo parser; we record only the span
    ///          between the braces and skip the raw tokens with brace-balanced
    ///          counting. The lexer is expected to have tokenized the body as a
    ///          raw run; here we balance braces to find the matching `}`.
    priv fn _parse_inline_block(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `inline`

        // language string literal
        if !self.dyn()->check(TokenKind::LitString) {
            self.dyn()->diag->report(
                DiagID::S060E,
                start_range.start,
                "expected a language string after 'inline' (e.g. inline \"c++\")",
            ).first(start_range)->emit()
            return (Statements::InlineBlockStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var lang_tok = self.dyn()->current()
        self.dyn()->advance(T::SkipNL::After) // consume the language string

        // resolve the language. The token text drives the discriminant; sema
        // validates against the known set. Default to Cpp on an unknown string
        // (and warn) so codegen has something to route to.
        var lang = self.parse_ffi_lang(lang_tok, start_range)

        if !self.dyn()->check(TokenKind::OpLBrace) {
            self.dyn()->diag->report(
                DiagID::S056E,
                start_range.start,
                "expected '{' to begin an inline foreign block",
            ).first(start_range)->emit()
            return (Statements::InlineBlockStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var lbrace_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `{` (do NOT skip newlines: body is raw)

        var body_start = self.dyn()->current_ptr()->range

        // brace-balanced skip of the opaque body.
        var depth:   u32 = 1
        var body_end     = body_start
        while !self.dyn()->is_eof() && depth > 0 {
            var k = self.dyn()->ig_kind()
            if k == TokenKind::OpLBrace {
                depth += 1
            } else if k == TokenKind::OpRBrace {
                depth -= 1
                if depth == 0 {
                    break
                }
            }

            body_end = self.dyn()->current_ptr()->range
            self.dyn()->advance()
        }

        var full_range = start_range
        if self.dyn()->check(TokenKind::OpRBrace) {
            full_range = start_range | self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::Before) // consume closing `}`
        } else {
            self.dyn()->diag->report(
                DiagID::S057E,
                lbrace_range.start,
                "expected '}' to close inline foreign block",
            ).first(lbrace_range)->emit()
            full_range = start_range | self.dyn()->prev().range
        }

        var node = Statements::InlineBlockStmt::create(
            self.dyn()->ctx,
            full_range,
            lang,
            body_start | body_end,
        )

        return node
    }

    /// \brief maps an inline-block language string token to FFILang.
    /// \details recognizes "asm", "c", "c++". Unrecognized strings are reported
    ///          with a diagnostic; sema makes the final call.
    pub fn parse_ffi_lang(self, raw: Token, rng: SourceRange) -> Statements::FFILang {
        // Through the wrapper: from a macro body the string is TkMacroExpand
        // (check(LitString) looks through it, so the callers pass it), its
        // imm the expansion record, and its payload in the table of the file
        // that wrote it (ASTContext::get_payload_table).
        var tok = self.dyn()->ctx->unwrap_token(raw)
        if tok.kind != TokenKind::LitString {
            self.dyn()->diag->report(
                DiagID::S060E,
                rng.start,
                "expected a string literal for the inline foreign language",
            ).first(rng)->emit()
            return Statements::FFILang::Cpp
        }

        var tbl = self.dyn()->ctx->get_payload_table(raw)
        var imm = tbl->get<Immediate::StringData>(tok.imm)

        // owned-text strings (synthesized by the PP) have no source range
        var spelling = string()
        if imm->has_owned_text() {
            spelling = string(
                unsafe ((unsafe (imm->owned_ptr as kairo::std::ConstPtr<c_char>) as unsafe *const u8) as *const u8),
                imm->owned_len as usize,
            )
        } else {
            spelling = self.dyn()->ctx->get_spelling(imm->body)
        }

        // The one table (Statements::ffi_lang_of), matched without case.
        var lang = Statements::ffi_lang_of(spelling)
        if lang != Statements::FFILang::None {
            return lang
        }

        self.dyn()->diag->report(
            DiagID::S060W,
            rng.start,
            f"unknown inline foreign language '{spelling}'; fix the string literal like using 'c++' instead",
        ).first(rng)->emit()

        return Statements::FFILang::None
    }

    //  Labeled loop

    /// \brief parses a labeled loop statement.
    ///  Grammar:  identifier ':' (while_stmt | ranged_for | indexed_for | loop_stmt)
    ///
    /// \details precondition: current is an identifier, peek is `:`. Only loops
    ///          may be labeled; labeling any other statement is reported.
    priv fn _parse_labeled_stmt(self) -> unsafe *Stmt {
        var start_range = self.dyn()->current_ptr()->range
        var label       = self.dyn()->current()
        self.dyn()->advance()                 // consume identifier
        self.dyn()->advance(T::SkipNL::After) // consume `:`

        var k = self.dyn()->resolve_kind_deep(self.dyn()->current_ptr())
        var is_loop = k == TokenKind::KwWhile
            || k == TokenKind::KwLoop
            || k == TokenKind::KwFor
            || k == TokenKind::KwEval // `label: eval for ...`

        if !is_loop {
            self.dyn()->diag->report(
                DiagID::S059E,
                start_range.start,
                "a label may only be applied to a loop ('while', 'for', or 'loop')",
            ).first(start_range)->emit()
            return (Statements::LabeledStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var unsafe *inner = self._dispatch_stmt()
        if inner == &null || self.is_fatal_stmt(inner) {
            return (Statements::LabeledStmt::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            ))
        }

        var node = Statements::LabeledStmt::create(
            self.dyn()->ctx,
            start_range | inner->range,
            label,
            inner,
        )

        return node
    }

    //  Recovery

    /// \brief consumes tokens until a statement boundary or a stop delimiter.
    /// \details delimiter-aware: tracks ()/[]/{} depth so it does not stop on a
    ///          closer that belongs to a nested construct. Stops at depth 0 on
    ///          a statement terminator (newline / `;`), a `}` (end of block), a
    ///          statement lead-in keyword, or EOF. Capped at MAX_SYNC tokens.
    fn _sync_stmt(self, ctx: Self::StmtSyncCtx, paren_depth: i32) {
        var   balance_paren:   i32 = paren_depth
        var   balance_square:  i32 = 0
        var   balance_brace:   i32 = 0
        var   tokens_consumed: u32 = 0
        const MAX_SYNC:        u32 = 128

        while !self.dyn()->is_eof() {
            if tokens_consumed >= MAX_SYNC {
                return
            }

            ++tokens_consumed

            var k = self.dyn()->ig_kind()

            if k == TokenKind::OpLParen {
                ++balance_paren
            } else if k == TokenKind::OpLSquare {
                ++balance_square
            } else if k == TokenKind::OpLBrace {
                ++balance_brace
            } else if k == TokenKind::OpRParen {
                if balance_paren == 0 {
                    return
                }

                --balance_paren
            } else if k == TokenKind::OpRSquare {
                if balance_square == 0 {
                    return
                }

                --balance_square
            } else if k == TokenKind::OpRBrace {
                if balance_brace == 0 { // closer of the enclosing block
                    return
                }

                --balance_brace
            } else if balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                if k == TokenKind::TkNewLine || k == TokenKind::OpSemicolon {
                    return
                }

                // a statement lead-in keyword at depth 0 ends recovery so the
                // next statement parses cleanly.
                if self._starts_decl(k)
                    || k == TokenKind::KwIf
                    || k == TokenKind::KwWhile
                    || k == TokenKind::KwFor
                    || k == TokenKind::KwLoop
                    || k == TokenKind::KwMatch
                    || k == TokenKind::KwReturn
                    || k == TokenKind::KwBreak
                    || k == TokenKind::KwContinue
                    || k == TokenKind::KwTry
                    || k == TokenKind::KwVar
                    || k == TokenKind::KwConst {
                    return
                }
            }

            self.dyn()->advance()
        }
    }

    /// Sync, then guarantee the cursor moved. For use inside recovery LOOPS:
    /// _sync_stmt stops ON a boundary token without consuming it, which is
    /// correct positioning but spins a caller that retries from the same spot.
    ///
    /// Except on a closing bracket, which closes the construct being parsed
    /// or one around it: with `case 2 =>` then the match's `}`, consuming
    /// that `}` would let the match run on through the rest of the function.
    /// Returns true when the cursor is left on a closer (or EOF); the caller
    /// leaves its loop and lets its own closer check deal with the token.
    priv fn _sync_stmt_progress(self, ctx: Self::StmtSyncCtx, paren_depth: i32) -> bool {
        var before = self.dyn()->c_idx
        self._sync_stmt(ctx, paren_depth)
        var k = self.dyn()->ig_kind()
        if self.dyn()->is_eof()
            || ((k == TokenKind::OpRBrace || k == TokenKind::OpRParen || k == TokenKind::OpRSquare)
                && self.dyn()->closer_is_owned()) {
            return true
        }

        if self.dyn()->c_idx == before {
            self.dyn()->advance()
        }

        return false
    }
}
