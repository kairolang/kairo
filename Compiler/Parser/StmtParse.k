/// --- The Kairo Project ----------------- Compiler/Parser/StmtParse.k ----- ///
///
///   \brief Statement parsing mixin. Recursive-descent over statement-position
///          productions.
///
///   \detail
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
///     Pattern parsing is not yet implemented; `_parse_pattern` is a stub that
///     returns null and is the single seam where PatternParse will plug in.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------- ///

import AST::Node::Base::*;
import AST::Node::Statements::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::CodeCompleteConsumer::*;
import AST::Context::ASTContext::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Parser::LexicalScope::*;

class <T> StmtParse {
    /// \enum StmtSyncCtx
    /// \brief sync contexts for statement-level error recovery.
    enum StmtSyncCtx derives u8 {
        TopLevel, ///< sync to newline / ; / EOF
        Block,    ///< sync to } at depth 0, or a statement lead-in
        Paren,    ///< sync to ) at depth 0 (for-loop clauses)
    }

    // ========================================================================
    //  CRTP helpers
    // ========================================================================

    priv inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
    }

    priv inline fn _error_stmt(self, range: SourceRange) -> *Stmt {
        return static_cast::<*Stmt>(ExpressionStmt::create_error(dyn()->ctx, range));
    }

    priv inline fn is_fatal_stmt(self, s: *Stmt) -> bool {
        inline "c++" {
            return dyn()->template is_fatal<Stmt>(s);
        }
    }

    // ========================================================================
    //  Statement-boundary helpers
    // ========================================================================

    /// \brief consumes the optional statement terminator (newline or `;`).
    /// \details statements are newline-terminated; an explicit `;` is also
    ///          accepted. Multiple blank lines collapse. Never errors absence
    ///          of a terminator before `}` or EOF is legal.
    inline fn _consume_terminator(self) {
        while dyn()->_is_terminator_tok(dyn()->current_ptr()) {
            dyn()->advance_raw();
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
            || k == TokenKind::KwProt;
    }

    // ========================================================================
    //  Block parsing
    // ========================================================================

    /// \brief parses a brace-delimited statement sequence into a CompoundStmt.
    ///  Grammar:  '{' (stmt terminator?)* '}'
    ///
    /// \details precondition: current token is `{`. Pushes a Block scope,
    ///          parses statements until `}` or EOF, pops the scope. On a
    ///          missing close brace, emits a diagnostic and returns what was
    ///          parsed so far. The body FrozenList is always populated (even
    ///          when empty) via from_buf.
    fn parse_compound(self, scope_kind: ScopeKind = ScopeKind::Block) -> *CompoundStmt {
        if !dyn()->check(TokenKind::OpLBrace) {
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S056E, r.start,
                "expected '{' to begin a block"
            ).first(r).emit();
            return CompoundStmt::create_error(dyn()->ctx, r);
        }

        if !dyn()->enter_depth() {
            var r = dyn()->current_ptr()->range;
            return CompoundStmt::create_error(dyn()->ctx, r);
        }

        var lbrace_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `{`

        dyn()->enter_scope(scope_kind, dyn()->scope.current_dc());

        var stmts: std::StackBuf::<*Stmt, 16>;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            // collapse blank lines / stray semicolons between statements
            if dyn()->_is_terminator_tok(dyn()->current_ptr()) {
                dyn()->advance_raw();
                continue;
            }

            var s = self.parse_stmt();
            if s == &null {
                break; // EOF mid-statement
            }

            if self.is_fatal_stmt(s) {
                break; // fatal error in statement
            }

            stmts.push_back(s);
            dyn()->_attach_trailing(s);
            self._consume_terminator();
        }

        var full_range = lbrace_range;
        if dyn()->check(TokenKind::OpRBrace) {
            full_range = lbrace_range | dyn()->current_ptr()->range;
            dyn()->advance(T::SkipNL::Before); // consume `}`
        } else {
            dyn()->diag->report(DiagID::S057E, lbrace_range.start,
                "expected '}' to close block"
            ).first(lbrace_range).emit();
            full_range = lbrace_range | dyn()->prev().range;
        }

        dyn()->exit_scope();
        dyn()->exit_depth();

        var block = CompoundStmt::create(dyn()->ctx, full_range);
        block->body.from_buf(stmts.data(), stmts.size(), dyn()->ctx);
        return block;
    }

    // ========================================================================
    //  Top-level statement dispatch
    // ========================================================================

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
    fn parse_stmt(self) -> *Stmt {
        if dyn()->is_eof() { return &null; }

        inline "c++" { typename T::PendingAnnotations annot; }
        dyn()->consume_leading_annotations(&annot);

        if dyn()->is_eof() { return &null; }

        var s = self._dispatch_stmt();
        if (s != &null) && (!is_fatal_stmt(s)) {
            // DeclStmt annotations (incl. visibility) belong to the decl;
            // the Stmt overload would drop visibility (with a diagnostic).
            if isa::<DeclStmt>(s) {
                var ds = cast::<DeclStmt>(s);
                
                if ds->decl != &null {
                    dyn()->apply_annotations_to_decl(ds->decl, &annot);
                }

            } else {
                dyn()->apply_annotations_to_node(s, &annot);
            }
        }
        return s;
    }

    /// \brief routes the current token to its statement production.
    priv fn _dispatch_stmt(self) -> *Stmt {
        var cur_ptr = dyn()->current_ptr();
        if cur_ptr == &null { return &null; }
        var k = dyn()->resolve_kind_deep(cur_ptr);

        switch k {
            // -- block ----------------------------------------------------
            case TokenKind::OpLBrace {
                return static_cast::<*Stmt>(self.parse_compound());
            }

            // -- control flow ---------------------------------------------
            case TokenKind::KwIf     {
                return self._parse_conditional();
            } case TokenKind::KwWhile  {
                return self._parse_while();
            } case TokenKind::KwLoop   {
                return self._parse_loop();
            } case TokenKind::KwFor    {
                return self._parse_for(false);
            } case TokenKind::KwMatch  {
                return self._parse_match();
            }

            // -- jump / signal --------------------------------------------
            case TokenKind::KwReturn {
                return self._parse_return();
            } case TokenKind::KwBreak {
                return self._parse_break();
            } case TokenKind::KwContinue {
                return self._parse_continue();
            } case TokenKind::KwPanic {
                return self._parse_panic();
            } case TokenKind::KwYield {
                return self._parse_yield();
            } case TokenKind::KwAssert {
                return self._parse_assert();
            }

            // -- exception / scope ----------------------------------------
            case TokenKind::KwTry     {
                return self._parse_try_catch();
            } case TokenKind::KwFinally {
                return self._parse_finally();
            }

            // -- unsafe: block form `unsafe { }` vs expr form `unsafe expr` -
            case TokenKind::KwUnsafe {
                if dyn()->check_peek(TokenKind::OpLBrace) {
                    return self._parse_unsafe_block();
                }
                // otherwise it's a unary `unsafe expr` fall through to expr-stmt.
            }

            // -- eval: block form `eval { }` vs `eval if/for/var` vs expr --
            case TokenKind::KwEval {
                // `eval {` -> decl-only eval block
                if dyn()->check_peek(TokenKind::OpLBrace) {
                    return self._parse_eval_block();
                }
                // `eval for` -> compile-time unrolled loop
                if dyn()->check_peek(TokenKind::KwFor) {
                    dyn()->advance(); // consume `eval`
                    return self._parse_for(true);
                }
                // `eval if` / `eval var` are handled by ConditionalStmt / decl
                // with is_eval; those routes consume `eval` themselves. For `eval
                // if` we fall into the conditional path after consuming eval:
                if dyn()->check_peek(TokenKind::KwIf) {
                    dyn()->advance(); // consume `eval`
                    return self._parse_conditional(); // FIXME: thread is_eval once ConditionalStmt carries it
                }
                // `eval var` / `eval const` -> decl with is_eval (decl parser owns)
                if dyn()->check_peek(TokenKind::KwVar) || dyn()->check_peek(TokenKind::KwConst) {
                    return self._parse_decl_stmt();
                }
                // otherwise `eval expr` unary fall through to expr-stmt.
            }

            // -- label! / jump! intrinsics --------------------------------
            // surfaced as macro syntax `label!(name)` / `jump!(name)`. The lexer
            // emits dedicated keyword-ish tokens for these; if instead they arrive
            // as identifier `label` + `!`, the macro layer resolves them. We gate
            // on the resolved kind here.
            // case TokenKind::KwLabel { return self._parse_label_intrinsic(); }
            // case TokenKind::KwJump  { return self._parse_jump_intrinsic(); }

            // -- inline foreign block -------------------------------------
            case TokenKind::KwInline {
                return self._parse_inline_block();
            }
        }

        // -- labeled loop:  ident ':' (while|for|loop) ----------------
        if (k == TokenKind::LitIdentifier) && (dyn()->check_peek(TokenKind::OpColon)) {
            return self._parse_labeled_stmt();
        }

        // -- var / const: plain decl, destructuring decl --------------
        if (k == TokenKind::KwVar) || (k == TokenKind::KwConst) {
            return self._parse_var_or_destructure();
        }

        // -- other declarations ---------------------------------------
        if self._starts_decl(k) {
            return self._parse_decl_stmt();
        }

        // -- fallthrough: expression statement OR context binding -----
        return self._parse_expr_or_context();
    }

    // ========================================================================
    //  Expression statement  /  context binding
    // ========================================================================

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
    priv fn _parse_expr_or_context(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;

        var lhs = dyn()->parse_expr();
        if lhs == &null {
            return self._error_stmt(start_range);
        }

        // dangling `as` => context binding
        if dyn()->check(TokenKind::KwAs) {
            return self._parse_context_binding(lhs, start_range);
        }

        var es = ExpressionStmt::create(dyn()->ctx, lhs->range, lhs);
        return static_cast::<*Stmt>(es);
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
        var as_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `as`

        var bindings: std::StackBuf::<Binding, 4>;
        var ok = self._parse_binding_spec(&bindings, as_range);

        if !ok {
            // binding spec malformed; recover by syncing to the block or EOL.
            self._sync_stmt(StmtSyncCtx::Block, 0);
            var err = ContextBindingStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return static_cast::<*Stmt>(err);
        }

        // a block is mandatory after a context binding spec.
        if !dyn()->check(TokenKind::OpLBrace) {
            var r = dyn()->current_ptr()->range;
            dyn()->diag->report(DiagID::S056E, as_range.start,
                "expected '{' after binding in context-binding statement"
            ).first(as_range)
             .note(DiagID::S056N, as_range.start,
                "a binding after 'as' (e.g. 'as var x') begins a context block and requires a body; "
                "for a type cast write 'as <Type>' with no 'var'/'const\x27")
             .emit();
            var err = ContextBindingStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return static_cast::<*Stmt>(err);
        }

        var body = self.parse_compound();
        var full = start_range | body->range;

        var node = ContextBindingStmt::create(dyn()->ctx, full, value, body);
        node->bindings.from_buf(bindings.data(), bindings.size(), dyn()->ctx);
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  Binding spec  (shared: destructuring decl, ranged-for, context binding)
    // ========================================================================

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
    fn _parse_binding_spec(self, out: *std::StackBuf::<Binding, 4>, ctx_range: SourceRange) -> bool {
        // leading 'var' | 'const' sets the default mutability.
        var leading_const = false;
        var have_leading  = false;
        if dyn()->check(TokenKind::KwVar) {
            leading_const = false;
            have_leading  = true;
            dyn()->advance();
        } else if dyn()->check(TokenKind::KwConst) {
            leading_const = true;
            have_leading  = true;
            dyn()->advance();
        }

        if !have_leading {
            dyn()->diag->report(DiagID::S058E, ctx_range.start,
                "expected 'var' or 'const' to begin a binding"
            ).first(ctx_range).emit();
            return false;
        }

        // parenthesized tuple binding list
        if dyn()->check(TokenKind::OpLParen) {
            dyn()->advance(T::SkipNL::After); // consume `(`

            if dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S058E, ctx_range.start,
                    "empty binding list is not allowed"
                ).first(ctx_range).emit();
                dyn()->advance(); // consume `)`
                return false;
            }

            while !dyn()->is_eof() {
                var b = self._parse_binding(leading_const);
                if (!b.is_discard) && (b.name == &null) {
                    return false; // malformed binding element
                }
                out->push_back(b);

                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                    if dyn()->check(TokenKind::OpRParen) { break; } // trailing comma
                    continue;
                }
                break;
            }

            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S058E, ctx_range.start,
                    "expected ')' to close binding list"
                ).first(ctx_range).emit();
                return false;
            }
            dyn()->advance(); // consume `)`
            return true;
        }

        // single bare binding: `var f`
        var b = self._parse_binding(leading_const);
        if (!b.is_discard) && (b.name == &null) {
            return false;
        }
        out->push_back(b);
        return true;
    }

    /// \brief parses a binding spec where the leading 'var'/'const' is OPTIONAL.
    ///  Grammar:  ('var'|'const')? (binding | '(' binding (',' binding)* ')')
    ///
    /// \details when no leading keyword is present, bindings default to mutable
    ///          (var). A per-element 'var'/'const' still overrides per binding.
    ///          Unlike _parse_binding_spec, absence of a leading keyword is NOT
    ///          an error here it's the mutable-by-default case.
    fn _parse_binding_spec_opt(self, out: *std::StackBuf::<Binding, 4>, ctx_range: SourceRange) -> bool {
        // leading 'var' | 'const' sets the default mutability; absent => mutable.
        var leading_const = false;
        if dyn()->check(TokenKind::KwVar) {
            leading_const = false;
            dyn()->advance();
        } else if dyn()->check(TokenKind::KwConst) {
            leading_const = true;
            dyn()->advance();
        }
        // no else: missing keyword is fine, leading_const stays false (mutable).

        // parenthesized tuple binding list
        if dyn()->check(TokenKind::OpLParen) {
            dyn()->advance(T::SkipNL::After); // consume `(`

            if dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S058E, ctx_range.start,
                    "empty binding list is not allowed"
                ).first(ctx_range).emit();
                dyn()->advance(); // consume `)`
                return false;
            }

            while !dyn()->is_eof() {
                var b = self._parse_binding(leading_const);
                if (!b.is_discard) && (b.name == &null) {
                    return false; // malformed binding element
                }
                out->push_back(b);

                if dyn()->check(TokenKind::OpComma) {
                    dyn()->advance(T::SkipNL::After);
                    if dyn()->check(TokenKind::OpRParen) { break; } // trailing comma
                    continue;
                }
                break;
            }

            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(DiagID::S058E, ctx_range.start,
                    "expected ')' to close binding list"
                ).first(ctx_range).emit();
                return false;
            }
            dyn()->advance(); // consume `)`
            return true;
        }

        // single bare binding
        var b = self._parse_binding(leading_const);
        if (!b.is_discard) && (b.name == &null) {
            return false;
        }
        out->push_back(b);
        return true;
    }

    /// \brief parses a single binding element.
    ///  Grammar:  ('var'|'const')? ('unsafe'? '*')? (identifier | '_') '?'?
    ///
    /// \details a per-element 'var'/'const' overrides `default_const`.
    ///          Shorthand qualifiers (`*`, `unsafe *`, trailing `?`) reshape the
    ///          inferred type; sema applies them. `_` produces a discard.
    ///          On a missing identifier, returns a Binding with name == null
    ///          (and is_discard == false) so the caller can detect failure.
    priv fn _parse_binding(self, default_const: bool) -> Binding {
        var result = Binding{};
        result.name        = &null;
        result.is_const    = default_const;
        result.is_explicit = false;
        result.is_discard  = false;
        result.shorthand   = BindingShorthand::None;

        var start = dyn()->current_ptr()->range;

        // per-element override
        if dyn()->check(TokenKind::KwVar) {
            result.is_const    = false;
            result.is_explicit = true;
            dyn()->advance();
        } else if dyn()->check(TokenKind::KwConst) {
            result.is_const    = true;
            result.is_explicit = true;
            dyn()->advance();
        }

        // pointer shorthand: `unsafe *` or `*`
        if dyn()->check(TokenKind::KwUnsafe) {
            // must be followed by `*` to be a pointer shorthand
            if dyn()->check_peek(TokenKind::OpStar) {
                dyn()->advance(); // consume `unsafe`
                dyn()->advance(); // consume `*`
                result.shorthand = static_cast::<BindingShorthand>(
                    static_cast::<u8>(result.shorthand)
                    | static_cast::<u8>(BindingShorthand::Pointer)
                    | static_cast::<u8>(BindingShorthand::Unsafe)
                );
            }
        } else if dyn()->check(TokenKind::OpStar) {
            dyn()->advance(); // consume `*`
            result.shorthand = static_cast::<BindingShorthand>(
                static_cast::<u8>(result.shorthand)
                | static_cast::<u8>(BindingShorthand::Pointer)
            );
        }

        // discard `_`
        if (dyn()->check(TokenKind::LitIdentifier))
        && (TokenText::from_token(*(dyn()->current_ptr()), dyn()->ctx).text == "_") {
            var und = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `_`
            result.is_discard = true;
            result.range      = start | und;
            return result;
        }

        // identifier
        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S058E, start.start,
                "expected binding name or '_' in binding"
            ).first(start).emit();
            result.range = start;
            return result; // name stays null -> caller treats as failure
        }

        var id_ptr   = dyn()->current_ptr();
        var id_range = id_ptr->range;
        dyn()->advance(); // consume identifier
        result.name = NamedIdentExpr::create(dyn()->ctx, id_range, *id_ptr);

        // nullable shorthand suffix `?`
        if dyn()->check(TokenKind::OpQuestion) {
            dyn()->advance(); // consume `?`
            result.shorthand = static_cast::<BindingShorthand>(
                static_cast::<u8>(result.shorthand)
                | static_cast::<u8>(BindingShorthand::Nullable)
            );
            result.range = start | dyn()->prev().range;
        } else {
            result.range = start | id_range;
        }

        return result;
    }

    // ========================================================================
    //  var / const  -> plain decl vs destructuring decl
    // ========================================================================

    /// \brief routes a `var`/`const` lead-in to a destructuring decl or a plain
    ///        declaration.
    ///  Grammar:  ('var'|'const') '(' ... ')' '=' expr      (tuple destructure)
    ///          | ('var'|'const') '{' ... '}' '=' expr      (struct destructure)
    ///          | ('var'|'const') <plain decl ...>          (-> DeclParse)
    ///
    /// \details peeks one token past the keyword. `(` or `{` => destructuring;
    ///          anything else => plain decl handled by the decl parser.
    priv fn _parse_var_or_destructure(self) -> *Stmt {
        var is_const = dyn()->check(TokenKind::KwConst);

        // peek past the keyword
        if dyn()->check_peek(TokenKind::OpLParen) {
            return self._parse_destructure(is_const, DestructureKind::Tuple);
        }
        if dyn()->check_peek(TokenKind::OpLBrace) {
            return self._parse_destructure(is_const, DestructureKind::Struct);
        }

        // plain decl
        return self._parse_decl_stmt();
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
    priv fn _parse_destructure(self, is_const: bool, dkind: DestructureKind) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return self._error_stmt(start_range);
        }

        // consume `var`/`const`
        dyn()->advance();

        var open  = (TokenKind::OpLParen) if (dkind == DestructureKind::Tuple) else (TokenKind::OpLBrace);
        var close = (TokenKind::OpRParen) if (dkind == DestructureKind::Tuple) else (TokenKind::OpRBrace);

        // consume opener
        dyn()->advance(T::SkipNL::After);

        var bindings: std::StackBuf::<Binding, 4>;

        if dyn()->check(close) {
            dyn()->diag->report(DiagID::S058E, start_range.start,
                "empty destructuring pattern is not allowed"
            ).first(start_range).emit();
            dyn()->advance(); // consume closer
            dyn()->exit_depth();
            var err = DestructuringDeclStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return static_cast::<*Stmt>(err);
        }

        while !dyn()->is_eof() {
            var b = self._parse_binding(is_const);
            if (!b.is_discard) && (b.name == &null) {
                self._sync_stmt(StmtSyncCtx::Block, 0);
                dyn()->exit_depth();
                var err = DestructuringDeclStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
                return static_cast::<*Stmt>(err);
            }
            bindings.push_back(b);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                if dyn()->check(close) { break; } // trailing comma
                continue;
            }
            break;
        }

        if !dyn()->check(close) {
            dyn()->diag->report(DiagID::S058E, start_range.start,
                "expected closing delimiter in destructuring pattern"
            ).first(start_range).emit();
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_depth();
            var err = DestructuringDeclStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return static_cast::<*Stmt>(err);
        }
        dyn()->advance(); // consume closer

        // require `=`
        if !dyn()->check(TokenKind::OpEqual) {
            dyn()->diag->report(DiagID::S058E, start_range.start,
                "expected '=' after destructuring pattern"
            ).first(start_range).emit();
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_depth();
            var err = DestructuringDeclStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return static_cast::<*Stmt>(err);
        }
        dyn()->advance(T::SkipNL::After); // consume `=`

        var value = dyn()->parse_expr();
        if (value == &null) || is_recovery(value) {
            dyn()->exit_depth();
            var err = DestructuringDeclStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return static_cast::<*Stmt>(err);
        }

        var full = start_range | value->range;
        var node = DestructuringDeclStmt::create(dyn()->ctx, full, dkind, value, is_const);
        node->bindings.from_buf(bindings.data(), bindings.size(), dyn()->ctx);

        dyn()->exit_depth();
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  Declaration statement  (delegates to DeclParse)
    // ========================================================================

    /// \brief wraps a declaration parsed by DeclParse in a DeclStmt.
    ///  Grammar:  decl
    ///
    /// \details DeclParse::parse_decl owns annotation/qualifier consumption for
    ///          the decl itself; parse_stmt already stripped leading
    ///          annotations, so any consumed here are decl-specific (e.g. `pub`
    ///          on a local). NOTE: parse_decl is currently a stub returning
    ///          null; this path produces a recovery DeclStmt until it lands.
    priv fn _parse_decl_stmt(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;

        var decl = dyn()->parse_decl();
        if decl == &null {
            // stub / failure: guarantee forward progress before syncing,
            // since _sync_stmt may no-op when sitting on a stmt lead-in.
            dyn()->advance();
            self._sync_stmt(StmtSyncCtx::Block, 0);
            var err = DeclStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return static_cast::<*Stmt>(err);
        }

        var ds = DeclStmt::create(dyn()->ctx, decl->range, decl);
        return static_cast::<*Stmt>(ds);
    }

    // ========================================================================
    //  Conditional
    // ========================================================================

    /// \brief parses an if statement with else-if chaining.
    ///  Grammar:  'if' expr block ('else' 'if' expr block)* ('else' block)?
    ///
    /// \details precondition: current token is `if`. The condition is parsed
    ///          with struct-literal suppression so `if Foo { }` is not misread
    ///          as a named initializer (NoStructLiteral stop bit). `else_` is a
    ///          *Stmt: either the next ConditionalStmt (an `else if`) or a
    ///          CompoundStmt (the final `else`).
    priv fn _parse_conditional(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return self._error_stmt(start_range);
        }

        dyn()->advance(T::SkipNL::After); // consume `if`

        var cond = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
        if ((cond == &null)) || is_recovery(cond) {
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_depth();
            return static_cast::<*Stmt>(ConditionalStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after 'if' condition"
            ).first(start_range).emit();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(ConditionalStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var then_ = self.parse_compound();

        var else_: *Stmt = &null;
        if dyn()->check(TokenKind::KwElse) {
            dyn()->advance(T::SkipNL::After); // consume `else`

            if dyn()->check(TokenKind::KwIf) {
                // else-if: recurse, store the ConditionalStmt directly as else_
                else_ = self._parse_conditional();
            } else if dyn()->check(TokenKind::OpLBrace) {
                // final else: a block
                else_ = static_cast::<*Stmt>(self.parse_compound());
            } else {
                dyn()->diag->report(DiagID::S056E, start_range.start,
                    "expected '{' or 'if' after 'else\x27"
                ).first(start_range).emit();
                // leave else_ null; recover.
            }
        }

        var end = (else_->range) if (else_ != &null) else (then_->range);
        var node = ConditionalStmt::create(dyn()->ctx, start_range | end, cond, then_, else_);
        dyn()->exit_depth();
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  While / Loop
    // ========================================================================

    /// \brief parses a while loop.
    ///  Grammar:  'while' expr block
    priv fn _parse_while(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `while`

        var cond = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
        if (cond == &null) || is_recovery(cond) {
            self._sync_stmt(StmtSyncCtx::Block, 0);
            return static_cast::<*Stmt>(WhileLoopStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after 'while' condition"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(WhileLoopStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var body = self.parse_compound();

        var node = WhileLoopStmt::create(dyn()->ctx, start_range | body->range, cond, body);
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses an unconditional loop.
    ///  Grammar:  'loop' block
    priv fn _parse_loop(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `loop`

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after 'loop\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(LoopStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var body = self.parse_compound();

        var node = LoopStmt::create(dyn()->ctx, start_range | body->range, body);
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  For  (ranged and C-style)
    // ========================================================================

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
    ///          simplest robust split: tentatively scan the header keyword shape
    ///          ranged headers never contain `;`. We peek for that.
    priv fn _parse_for(self, is_eval: bool) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return self._error_stmt(start_range);
        }

        dyn()->advance(T::SkipNL::After); // consume `for`

        dyn()->enter_scope(ScopeKind::ForLoop, dyn()->scope.current_dc());

        // Disambiguate ranged vs C-style.
        // C-style begins with a decl that has an `=` initializer and uses `;`
        // separators. Ranged begins with a binding spec and uses `in`.
        // We use a tentative scan: parse the binding spec; if `in` follows, it's
        // ranged. Otherwise roll back and parse the C-style header.
        var saved = dyn()->tentative_begin();

        var bindings: std::StackBuf::<Binding, 4>;
        var spec_ok = self._parse_binding_spec_opt(&bindings, start_range);

        if spec_ok && dyn()->check(TokenKind::KwIn) {
            // -- ranged form ------------------------------------------
            dyn()->advance(T::SkipNL::After); // consume `in`

            var iterable = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
            if (iterable == &null) || is_recovery(iterable) {
                self._sync_stmt(StmtSyncCtx::Block, 0);
                dyn()->exit_scope();
                dyn()->exit_depth();
                return static_cast::<*Stmt>(RangedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
            }

            if !dyn()->check(TokenKind::OpLBrace) {
                dyn()->diag->report(DiagID::S056E, start_range.start,
                    "expected '{' after 'for ... in' header"
                ).first(start_range).emit();
                dyn()->exit_scope();
                dyn()->exit_depth();
                return static_cast::<*Stmt>(RangedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
            }
            var body = self.parse_compound();

            var node = RangedForStmt::create(dyn()->ctx, start_range | body->range, iterable, body, is_eval);
            node->bindings.from_buf(bindings.data(), bindings.size(), dyn()->ctx);

            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(node);
        }

        // -- C-style form ---------------------------------------------
        dyn()->tentative_rollback(saved);
        return self._parse_indexed_for(start_range, is_eval);
    }

    /// \brief parses a C-style three-part for loop.
    ///  Grammar:  'for' decl_stmt ';' expr ';' expr block
    ///
    /// \details precondition: cursor is at the start of the init clause (after
    ///          `for`). The init is a variable declaration scoped to the loop
    ///          (a DeclStmt). `cond` and `update` are bare expressions. The
    ///          enclosing scope (ForLoop) was already pushed by _parse_for and
    ///          is popped here.
    priv fn _parse_indexed_for(self, start_range: SourceRange, is_eval: bool) -> *Stmt {
        // init clause: a var/const decl (DeclParse owns it).
        var init = self._parse_decl_stmt();
        if (init == &null) || is_fatal_stmt(init) {
            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(IndexedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        if !dyn()->check(TokenKind::OpSemicolon) {
            dyn()->diag->report(DiagID::S059E, start_range.start,
                "expected ';' after for-loop initializer"
            ).first(start_range).emit();
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(IndexedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        dyn()->advance(T::SkipNL::After); // consume `;`

        var cond = dyn()->parse_expr();
        if (cond == &null) || is_recovery(cond) {
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(IndexedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        if !dyn()->check(TokenKind::OpSemicolon) {
            dyn()->diag->report(DiagID::S059E, start_range.start,
                "expected ';' after for-loop condition"
            ).first(start_range).emit();
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(IndexedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        dyn()->advance(T::SkipNL::After); // consume `;`

        var update = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
        if (update == &null) || is_recovery(update) {
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(IndexedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after C-style for header"
            ).first(start_range).emit();
            dyn()->exit_scope();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(IndexedForStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var body = self.parse_compound();

        var node = IndexedForStmt::create(dyn()->ctx, start_range | body->range, init, cond, update, body, is_eval);
        dyn()->exit_scope();
        dyn()->exit_depth();
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  Match
    // ========================================================================

    /// \brief parses a match statement.
    ///  Grammar:  'match' expr '{' match_case* '}'
    ///    match_case := 'case' pattern (',' pattern)* ('where' expr)? block
    ///                | 'default' block
    ///
    /// \details precondition: current token is `match`. The scrutinee is parsed
    ///          with struct-literal suppression. Cases are collected until `}`.
    ///          Pattern parsing delegates to _parse_pattern (currently a stub).
    pub fn _parse_match(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;

        if !dyn()->enter_depth() {
            return self._error_stmt(start_range);
        }

        dyn()->advance(T::SkipNL::After); // consume `match`

        var scrutinee = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
        if (scrutinee == &null) || is_recovery(scrutinee) {
            self._sync_stmt(StmtSyncCtx::Block, 0);
            dyn()->exit_depth();
            return static_cast::<*Stmt>(MatchStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after 'match' scrutinee"
            ).first(start_range).emit();
            dyn()->exit_depth();
            return static_cast::<*Stmt>(MatchStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var lbrace_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `{`

        var cases: std::StackBuf::<MatchCase, 8>;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            if dyn()->check(TokenKind::TkNewLine) {
                dyn()->advance();
                continue;
            }

            var mc = self._parse_match_case();
            // a case with a null body indicates a failed parse; recover.
            if mc.body == &null {
                self._sync_stmt(StmtSyncCtx::Block, 0);
                if dyn()->check(TokenKind::OpRBrace) { break; }
                continue;
            }
            cases.push_back(mc);
        }

        var full_range = start_range;
        if dyn()->check(TokenKind::OpRBrace) {
            full_range = start_range | dyn()->current_ptr()->range;
            dyn()->advance(T::SkipNL::Before); // consume `}`
        } else {
            dyn()->diag->report(DiagID::S057E, lbrace_range.start,
                "expected '}' to close match statement"
            ).first(lbrace_range).emit();
            full_range = start_range | dyn()->prev().range;
        }

        var node = MatchStmt::create(dyn()->ctx, full_range, scrutinee);
        node->cases.from_buf(cases.data(), cases.size(), dyn()->ctx);

        dyn()->exit_depth();
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a single match case or default arm.
    ///  Grammar:  'case' pattern (',' pattern)* ('where' expr)? block
    ///          | 'default' block
    ///
    /// \details returns a MatchCase whose `body` is null on a structural parse
    ///          failure (caller recovers). Pattern alternatives share one body;
    ///          the `where` guard, if present, applies to the whole arm.
    priv fn _parse_match_case(self) -> MatchCase {
        var result = MatchCase{};
        result.guard      = &null;
        result.body       = &null;
        result.is_default = false;

        var start_range = dyn()->current_ptr()->range;

        // default arm
        if dyn()->check(TokenKind::KwDefault) {
            dyn()->advance(T::SkipNL::After); // consume `default`
            result.is_default = true;

            if !dyn()->check(TokenKind::OpLBrace) {
                dyn()->diag->report(DiagID::S056E, start_range.start,
                    "expected '{' after 'default' in match"
                ).first(start_range).emit();
                return result; // body stays null
            }
            result.body  = self.parse_compound();
            result.range = start_range | result.body->range;
            // patterns left empty; caller must from_buf it.
            result.patterns.from_buf(static_cast::<*(*Pattern)>(&null), 0, dyn()->ctx);
            return result;
        }

        // case arm
        if !dyn()->check(TokenKind::KwCase) {
            dyn()->diag->report(DiagID::S059E, start_range.start,
                "expected 'case' or 'default' in match body"
            ).first(start_range).emit();
            return result; // body stays null
        }
        dyn()->advance(T::SkipNL::After); // consume `case`

        var pats: std::StackBuf::<*Pattern, 4>;

        while !dyn()->is_eof() {
            var p = self._parse_pattern();
            pats.push_back(p);
            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                continue;
            }
            break;
        }

        // optional `where` guard
        if dyn()->check(TokenKind::KwWhere) {
            dyn()->advance(T::SkipNL::After); // consume `where`
            var guard = dyn()->parse_expr(T::ExprStopKind::NoStructLiteral);
            if (guard == &null) || (is_recovery(guard)) {
                self._sync_stmt(StmtSyncCtx::Block, 0);
                return result; // body stays null
            }
            result.guard = guard;
        }

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after match case pattern"
            ).first(start_range).emit();
            return result; // body stays null
        }
        result.body  = self.parse_compound();
        result.range = start_range | result.body->range;
        result.patterns.from_buf(pats.data(), pats.size(), dyn()->ctx);
        return result;
    }

    /// \brief STUB: pattern parsing seam.
    /// \details PatternParse is not yet implemented. This consumes a single
    ///          conservative token run (until `,`, `where`, `{`, or a stop
    ///          token) so the surrounding match-arm structure parses, and
    ///          returns null. Replace with a real `dyn()->parse_pattern()`
    ///          call once PatternParse exists.
    priv fn _parse_pattern(self) -> *Pattern {
        return dyn()->parse_pattern();
    }

    // ========================================================================
    //  Jump / signal statements
    // ========================================================================

    /// \brief parses a return statement.
    ///  Grammar:  'return' | 'return' expr
    ///
    /// \details a value is present unless the next token ends the statement
    ///          (newline, `;`, `}`, EOF).
    priv fn _parse_return(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `return` (do NOT skip newlines: bare return)

        // bare return if the statement ends here
        if dyn()->is_eof()
        || dyn()->check(TokenKind::TkNewLine)
        || dyn()->check(TokenKind::OpSemicolon)
        || dyn()->check(TokenKind::OpRBrace) {
            var node = ReturnStmt::create(dyn()->ctx, start_range, &null);
            return static_cast::<*Stmt>(node);
        }

        var value = dyn()->parse_expr();
        if (value == &null) || (is_recovery(value)) {
            return static_cast::<*Stmt>(ReturnStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var node = ReturnStmt::create(dyn()->ctx, start_range | value->range, value);
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a break statement.
    ///  Grammar:  'break' | 'break' identifier
    priv fn _parse_break(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `break` (no NL skip: optional label is same-line)

        if dyn()->check(TokenKind::LitIdentifier) {
            var label = dyn()->current();
            dyn()->advance();
            var node = BreakStmt::create(dyn()->ctx, start_range | label.range, true, label);
            return static_cast::<*Stmt>(node);
        }

        var node = BreakStmt::create(dyn()->ctx, start_range, false, Token());
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a continue statement.
    ///  Grammar:  'continue' | 'continue' identifier
    priv fn _parse_continue(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `continue`

        if dyn()->check(TokenKind::LitIdentifier) {
            var label = dyn()->current();
            dyn()->advance();
            var node = ContinueStmt::create(dyn()->ctx, start_range | label.range, true, label);
            return static_cast::<*Stmt>(node);
        }

        var node = ContinueStmt::create(dyn()->ctx, start_range, false, Token());
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a panic statement.
    ///  Grammar:  'panic' expr
    priv fn _parse_panic(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `panic`

        var payload = dyn()->parse_expr();
        if (payload == &null) || is_recovery(payload) {
            dyn()->diag->report(DiagID::S052E, start_range.start,
                "expected expression after 'panic\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(PanicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var node = PanicStmt::create(dyn()->ctx, start_range | payload->range, payload);
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a yield statement.
    ///  Grammar:  'yield' expr
    priv fn _parse_yield(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `yield`

        var value = dyn()->parse_expr();
        if (value == &null) || is_recovery(value) {
            dyn()->diag->report(DiagID::S052E, start_range.start,
                "expected expression after 'yield\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(YieldStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var node = YieldStmt::create(dyn()->ctx, start_range | value->range, value);
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a runtime or static assertion.
    ///  Grammar:  'assert' 'static'? expr (',' expr)?
    ///
    /// \details `assert static` produces a StaticAssertStmt; plain `assert`
    ///          produces a RuntimeAssertStmt. The optional second operand is a
    ///          diagnostic message expression.
    priv fn _parse_assert(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `assert`

        var is_static = false;
        if dyn()->check(TokenKind::KwStatic) {
            is_static = true;
            dyn()->advance(T::SkipNL::After); // consume `static`
        }

        var cond = dyn()->parse_expr(T::ExprStopKind::StopComma);
        if (cond == &null) || is_recovery(cond) {
            dyn()->diag->report(DiagID::S052E, start_range.start,
                "expected condition expression after 'assert\x27"
            ).first(start_range).emit();
            if is_static {
                return static_cast::<*Stmt>(StaticAssertStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
            }
            return static_cast::<*Stmt>(RuntimeAssertStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var message: *Expr = &null;
        if dyn()->check(TokenKind::OpComma) {
            dyn()->advance(T::SkipNL::After); // consume `,`
            message = dyn()->parse_expr();
            if (message == &null) || (is_recovery(message)) {
                message = &null; // recover: drop the malformed message
            }
        }

        var end = (message->range) if (message != &null) else (cond->range);
        if is_static {
            var node = StaticAssertStmt::create(dyn()->ctx, start_range | end, cond, message);
            return static_cast::<*Stmt>(node);
        }
        var node = RuntimeAssertStmt::create(dyn()->ctx, start_range | end, cond, message);
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  Try / catch  (finally is separate)
    // ========================================================================

    /// \brief parses a try/catch statement.
    ///  Grammar:  'try' block ('catch' catch_filter? block)+
    ///    catch_filter := identifier (':' type)?
    ///
    /// \details `finally` is NOT consumed here; `try {} finally {}` is a
    ///          TryCatchStmt followed by a separate FinallyStmt. At least one
    ///          catch arm is expected; absence is reported but recovered.
    priv fn _parse_try_catch(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `try`

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after 'try\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(TryCatchStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var try_body = self.parse_compound();

        var arms: std::StackBuf::<CatchArm, 4>;

        while dyn()->check(TokenKind::KwCatch) {
            var arm = self._parse_catch_arm();
            if arm.body == &null {
                self._sync_stmt(StmtSyncCtx::Block, 0);
                break;
            }
            arms.push_back(arm);
        }

        if arms.size() == 0 {
            dyn()->diag->report(DiagID::S059E, start_range.start,
                "expected at least one 'catch' arm after 'try' block"
            ).first(start_range).emit();
        }

        var full = start_range | dyn()->prev().range;
        var node = TryCatchStmt::create(dyn()->ctx, full, try_body);
        node->arms.from_buf(arms.data(), arms.size(), dyn()->ctx);
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses one catch arm.
    ///  Grammar:  'catch' (identifier (':' type)?)? block
    ///
    /// \details forms: `catch { }` (bare), `catch e { }` (binding only),
    ///          `catch e: Type { }` (binding + filter). Returns an arm with a
    ///          null body on parse failure.
    priv fn _parse_catch_arm(self) -> CatchArm {
        var result = CatchArm{};
        result.filter  = &null;
        result.binding = &null;
        result.body    = &null;

        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `catch`

        // optional binding identifier
        if dyn()->check(TokenKind::LitIdentifier) {
            var id_ptr   = dyn()->current_ptr();
            var id_range = id_ptr->range;
            dyn()->advance(); // consume identifier
            result.binding = NamedIdentExpr::create(dyn()->ctx, id_range, *id_ptr);

            // optional `: Type` filter
            if dyn()->check(TokenKind::OpColon) {
                dyn()->advance(T::SkipNL::After); // consume `:`
                var filter = dyn()->parse_type();
                if (filter == &null) || is_recovery(filter) {
                    dyn()->diag->report(DiagID::S053E, start_range.start,
                        "expected panic type after ':' in catch arm"
                    ).first(start_range).emit();
                    return result; // body stays null
                }
                result.filter = filter;
            }
        }

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' to begin catch arm body"
            ).first(start_range).emit();
            return result; // body stays null
        }
        result.body  = self.parse_compound();
        result.range = start_range | result.body->range;
        return result;
    }

    /// \brief parses a standalone finally statement.
    ///  Grammar:  'finally' block
    priv fn _parse_finally(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `finally`

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after 'finally\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(FinallyStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var body = self.parse_compound();

        var node = FinallyStmt::create(dyn()->ctx, start_range | body->range, body);
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  Unsafe / eval blocks
    // ========================================================================

    /// \brief parses an unsafe block.
    ///  Grammar:  'unsafe' block
    ///
    /// \details precondition: current is `unsafe`, peek is `{` (the dispatcher
    ///          checked). Pushes a Block scope via parse_compound; the unsafe
    ///          context itself (AMT suspension) is a sema concern keyed on the
    ///          node kind.
    priv fn _parse_unsafe_block(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `unsafe`

        var body = self.parse_compound();
        var node = UnsafeBlockStmt::create(dyn()->ctx, start_range | body->range, body);
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a decl-only eval block.
    ///  Grammar:  'eval' '{' decl* '}'
    ///
    /// \details precondition: current is `eval`, peek is `{`. Only declarations
    ///          are legal inside; a non-decl statement is a sema error (the
    ///          parser still consumes it for recovery, but only decls are
    ///          retained in the body list).
    priv fn _parse_eval_block(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `eval`

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' after 'eval\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(EvalBlockStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var lbrace_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `{`

        var decls: std::StackBuf::<*Decl, 8>;

        while (!dyn()->is_eof()) && (!dyn()->check(TokenKind::OpRBrace)) {
            if dyn()->check(TokenKind::TkNewLine) || dyn()->check(TokenKind::OpSemicolon) {
                dyn()->advance();
                continue;
            }

            var decl = dyn()->parse_decl();
            if decl == &null {
                dyn()->advance();
                // decl parser stub / non-decl content: recover to a boundary.
                self._sync_stmt(StmtSyncCtx::Block, 0);
                if dyn()->check(TokenKind::OpRBrace) { break; }
                continue;
            }
            decls.push_back(decl);
            self._consume_terminator();
        }

        var full_range = start_range;
        if dyn()->check(TokenKind::OpRBrace) {
            full_range = start_range | dyn()->current_ptr()->range;
            dyn()->advance(T::SkipNL::Before); // consume `}`
        } else {
            dyn()->diag->report(DiagID::S057E, lbrace_range.start,
                "expected '}' to close eval block"
            ).first(lbrace_range).emit();
            full_range = start_range | dyn()->prev().range;
        }

        var node = EvalBlockStmt::create(dyn()->ctx, full_range);
        node->body.from_buf(decls.data(), decls.size(), dyn()->ctx);
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  label! / jump! intrinsics
    // ========================================================================

    /// \brief parses a label intrinsic.
    ///  Grammar:  'label' '!' '(' identifier ')'
    priv fn _parse_label_intrinsic(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `label`

        if !dyn()->check(TokenKind::OpExclaim) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected '!' after 'label' intrinsic"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(LabelIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        dyn()->advance(); // consume `!`

        if !dyn()->check(TokenKind::OpLParen) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected '(' after 'label!\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(LabelIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        dyn()->advance(T::SkipNL::After); // consume `(`

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected label name inside 'label!(...)\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(LabelIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var name = dyn()->current();
        dyn()->advance(T::SkipNL::After); // consume identifier

        if !dyn()->check(TokenKind::OpRParen) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected ')' to close 'label!(...)\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(LabelIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var end = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `)`

        var node = LabelIntrinsicStmt::create(dyn()->ctx, start_range | end, name);
        return static_cast::<*Stmt>(node);
    }

    /// \brief parses a jump intrinsic.
    ///  Grammar:  'jump' '!' '(' identifier ')'
    priv fn _parse_jump_intrinsic(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `jump`

        if !dyn()->check(TokenKind::OpExclaim) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected '!' after 'jump' intrinsic"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(JumpIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        dyn()->advance(); // consume `!`

        if !dyn()->check(TokenKind::OpLParen) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected '(' after 'jump!\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(JumpIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        dyn()->advance(T::SkipNL::After); // consume `(`

        if !dyn()->check(TokenKind::LitIdentifier) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected target name inside 'jump!(...)\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(JumpIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var target = dyn()->current();
        dyn()->advance(T::SkipNL::After); // consume identifier

        if !dyn()->check(TokenKind::OpRParen) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected ')' to close 'jump!(...)\x27"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(JumpIntrinsicStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var end = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `)`

        var node = JumpIntrinsicStmt::create(dyn()->ctx, start_range | end, target);
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  Inline foreign block
    // ========================================================================

    /// \brief parses an inline foreign block.
    ///  Grammar:  'inline' string_literal '{' <opaque> '}'
    ///
    /// \details the language is taken from the string literal ("asm"/"c"/"c++").
    ///          The body is opaque to the Kairo parser; we record only the span
    ///          between the braces and skip the raw tokens with brace-balanced
    ///          counting. The lexer is expected to have tokenized the body as a
    ///          raw run; here we balance braces to find the matching `}`.
    priv fn _parse_inline_block(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `inline`

        // language string literal
        if !dyn()->check(TokenKind::LitString) {
            dyn()->diag->report(DiagID::S060E, start_range.start,
                "expected a language string after 'inline' (e.g. inline \"c++\")"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(InlineBlockStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var lang_tok = dyn()->current();
        dyn()->advance(T::SkipNL::After); // consume the language string

        // resolve the language. The token text drives the discriminant; sema
        // validates against the known set. Default to Cpp on an unknown string
        // (and warn) so codegen has something to route to.
        var lang = self._inline_lang_from_token(lang_tok, start_range);

        if !dyn()->check(TokenKind::OpLBrace) {
            dyn()->diag->report(DiagID::S056E, start_range.start,
                "expected '{' to begin an inline foreign block"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(InlineBlockStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }
        var lbrace_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `{` (do NOT skip newlines: body is raw)

        var body_start = dyn()->current_ptr()->range;

        // brace-balanced skip of the opaque body.
        var depth: u32 = 1;
        var body_end = body_start;
        while (!dyn()->is_eof()) && depth > 0 {
            var k = dyn()->current().kind;
            if k == TokenKind::OpLBrace {
                depth += 1;
            } else if k == TokenKind::OpRBrace {
                depth -= 1;
                if depth == 0 { break; }
            }
            body_end = dyn()->current_ptr()->range;
            dyn()->advance();
        }

        var full_range = start_range;
        if dyn()->check(TokenKind::OpRBrace) {
            full_range = start_range | dyn()->current_ptr()->range;
            dyn()->advance(T::SkipNL::Before); // consume closing `}`
        } else {
            dyn()->diag->report(DiagID::S057E, lbrace_range.start,
                "expected '}' to close inline foreign block"
            ).first(lbrace_range).emit();
            full_range = start_range | dyn()->prev().range;
        }

        var node = InlineBlockStmt::create(dyn()->ctx, full_range, lang, body_start | body_end);
        return static_cast::<*Stmt>(node);
    }

    /// \brief maps an inline-block language string token to InlineLang.
    /// \details recognizes "asm", "c", "c++". Unknown languages default to Cpp
    ///          with a diagnostic; sema makes the final call.
    priv fn _inline_lang_from_token(self, tok: Token, ctx_range: SourceRange) -> InlineLang {
        if tok.kind != TokenKind::LitString {
            dyn()->diag->report(DiagID::S060E, ctx_range.start,
                "expected a string literal for the inline foreign language"
            ).first(ctx_range).emit();
            return InlineLang::Cpp;
        }

        inline "c++" {
            auto imm = dyn()->ctx->get_imm_table()->template get<Immediate::StringData>(tok.imm);
        }

        var txt = TokenText::from_range(imm->body, dyn()->ctx);
        if txt.text == "asm"    { return InlineLang::Asm;    }
        if txt.text == "c"      { return InlineLang::C;      }
        if txt.text == "cpp"    { return InlineLang::Cpp;    }
        if txt.text == "cuda"   { return InlineLang::Cuda;   }
        if txt.text == "hip"    { return InlineLang::Hip;    }
        if txt.text == "opencl" { return InlineLang::OpenCL; }
        if txt.text == "hlsl"   { return InlineLang::Hlsl;   }
        if txt.text == "metal"  { return InlineLang::Metal;  }
        if txt.text == "spirv"  { return InlineLang::SpirV;  }
        if txt.text == "wgsl"   { return InlineLang::Wgsl;   }
        if txt.text == "glsl"   { return InlineLang::Glsl;   }
        if txt.text == "kairo"  { return InlineLang::Kairo;  }

        if txt.text == "Asm"    { return InlineLang::Asm;    }
        if txt.text == "C"      { return InlineLang::C;      }
        if txt.text == "Cpp"    { return InlineLang::Cpp;    }
        if txt.text == "Cuda"   { return InlineLang::Cuda;   }
        if txt.text == "Hip"    { return InlineLang::Hip;    }
        if txt.text == "Opencl" { return InlineLang::OpenCL; }
        if txt.text == "Hlsl"   { return InlineLang::Hlsl;   }
        if txt.text == "Metal"  { return InlineLang::Metal;  }
        if txt.text == "Spirv"  { return InlineLang::SpirV;  }
        if txt.text == "Wgsl"   { return InlineLang::Wgsl;   }
        if txt.text == "Glsl"   { return InlineLang::Glsl;   }
        if txt.text == "Kairo"  { return InlineLang::Kairo;  }

        if txt.text == "ASM"    { return InlineLang::Asm;    }
        if txt.text == "C"      { return InlineLang::C;      }
        if txt.text == "CPP"    { return InlineLang::Cpp;    }
        if txt.text == "CUDA"   { return InlineLang::Cuda;   }
        if txt.text == "HIP"    { return InlineLang::Hip;    }
        if txt.text == "OPENCL" { return InlineLang::OpenCL; }
        if txt.text == "HLSL"   { return InlineLang::Hlsl;   }
        if txt.text == "METAL"  { return InlineLang::Metal;  }
        if txt.text == "SPIRV"  { return InlineLang::SpirV;  }
        if txt.text == "WGSL"   { return InlineLang::Wgsl;   }
        if txt.text == "GLSL"   { return InlineLang::Glsl;   }
        if txt.text == "KAIRO"  { return InlineLang::Kairo;  }

        if txt.text == "cxx"    { return InlineLang::Cpp;    }
        if txt.text == "Cxx"    { return InlineLang::Cpp;    }
        if txt.text == "CXX"    { return InlineLang::Cpp;    }

        if txt.text == "c++"    { return InlineLang::Cpp;    }
        if txt.text == "C++"    { return InlineLang::Cpp;    }

        dyn()->diag->report(DiagID::S060W, ctx_range.start,
            f"unknown inline foreign language '{txt.text}'; falling back to 'c++\x27"
        ).first(ctx_range).emit();
        return InlineLang::Cpp;
    }

    // ========================================================================
    //  Labeled loop
    // ========================================================================

    /// \brief parses a labeled loop statement.
    ///  Grammar:  identifier ':' (while_stmt | ranged_for | indexed_for | loop_stmt)
    ///
    /// \details precondition: current is an identifier, peek is `:`. Only loops
    ///          may be labeled; labeling any other statement is reported.
    priv fn _parse_labeled_stmt(self) -> *Stmt {
        var start_range = dyn()->current_ptr()->range;
        var label = dyn()->current();
        dyn()->advance(); // consume identifier
        dyn()->advance(T::SkipNL::After); // consume `:`

        var k = dyn()->resolve_kind_deep(dyn()->current_ptr());
        var is_loop = (k == TokenKind::KwWhile)
                   || (k == TokenKind::KwLoop)
                   || (k == TokenKind::KwFor)
                   || (k == TokenKind::KwEval); // `label: eval for ...`

        if !is_loop {
            dyn()->diag->report(DiagID::S059E, start_range.start,
                "a label may only be applied to a loop ('while', 'for', or 'loop')"
            ).first(start_range).emit();
            return static_cast::<*Stmt>(LabeledStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var inner = self._dispatch_stmt();
        if (inner == &null) || is_fatal_stmt(inner) {
            return static_cast::<*Stmt>(LabeledStmt::create_error(dyn()->ctx, start_range | dyn()->prev().range));
        }

        var node = LabeledStmt::create(dyn()->ctx, start_range | inner->range, label, inner);
        return static_cast::<*Stmt>(node);
    }

    // ========================================================================
    //  Recovery
    // ========================================================================

    /// \brief consumes tokens until a statement boundary or a stop delimiter.
    /// \details delimiter-aware: tracks ()/[]/{} depth so it does not stop on a
    ///          closer that belongs to a nested construct. Stops at depth 0 on
    ///          a statement terminator (newline / `;`), a `}` (end of block), a
    ///          statement lead-in keyword, or EOF. Capped at MAX_SYNC tokens.
    fn _sync_stmt(self, ctx: StmtSyncCtx, paren_depth: i32) {
        var balance_paren:   i32 = paren_depth;
        var balance_square:  i32 = 0;
        var balance_brace:   i32 = 0;
        var tokens_consumed: u32 = 0;
        const var MAX_SYNC:  u32 = 128;

        while !dyn()->is_eof() {
            if tokens_consumed >= MAX_SYNC { return; }
            ++tokens_consumed;

            var k = dyn()->current().kind;

            if k == TokenKind::OpLParen  { ++balance_paren;  }
            else if k == TokenKind::OpLSquare { ++balance_square; }
            else if k == TokenKind::OpLBrace  { ++balance_brace;  }
            else if k == TokenKind::OpRParen {
                if balance_paren == 0 { return; }
                --balance_paren;
            }
            else if k == TokenKind::OpRSquare {
                if balance_square == 0 { return; }
                --balance_square;
            }
            else if k == TokenKind::OpRBrace {
                if balance_brace == 0 { return; } // closer of the enclosing block
                --balance_brace;
            }
            else if balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                if k == TokenKind::TkNewLine || k == TokenKind::OpSemicolon { return; }
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
                    return;
                }
            }

            dyn()->advance();
        }
    }
}