/// --- The Kairo Project --------------------------- Parser/TypeParse.k --- ///
///
///   The type expression parser mixin.
///
///     Handles: *T, atomic T, Foo, Foo<T>, (T1, T2), (T) -> U
///     (const/atomic/unsafe/eval/async are TypeQual flags, not wrapper nodes)
///     Derives from ASTParse which provides: check, match_tok, expect, advance,
///     ctx, diag, is_eof, current, peek, prev, current_ptr,
///     consume_leading_quals, apply_quals, consume_leading_annotations,
///     apply_annotations_to_node, depth, etc.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE SPDX-License-Identifier:
///   Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception Copyright (c) 2026 Kairo Software
///   Foundation
///
/// ----------------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "set"

import AST::CodeCompleteConsumer::CompletionContextKind
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LangAttrs,
    TUPLE_MAX_ARITY,
}
import AST::Mixin::TypeQual::TypeQual
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_for_token,
}
import AST::Node::Casting::{
    cast,
    is_recovery,
    isa,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types
import AST::ParamMode::ParamMode
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Parser::ExprParse::ExprStopBit
import Support::FlagSet::FlagSet
import Token::TokenKind::{
    TokenKind,
    token_kind_to_readable_string,
}

/// \class TypeParse
/// \brief CRTP mixin providing type expression parsing for the Kairo parser.
///
/// \details concrete parser type `T` (always `ASTParse`) derives
///          `TypeParse::<T>` to inherit all type-position productions. the
///          mixin owns no state beyond a monotonic `inferred_type_counter`
///          and a static token-kind lookup table used for leaf-type dispatch.
///
/// \par grammar coverage
/// handles pointer types (`*T`, `*const T`, `**T`), parenthesized groupings and
/// tuples (`(T)`, `(T, U)`), fixed arrays and vectors (`[T; N]`, `[T]`), set
/// and map types (`{T}`, `{K: V}`), function pointer types (`fn(T) -> U`), and
/// leaf named/builtin types. qualifier keywords (`const`, `atomic`, `unsafe`,
/// `eval`, `async`) are consumed by the caller (`parse_type`) via
/// `consume_leading_quals` and applied as `TypeQual` flags on the returned node
/// they do not produce wrapper AST nodes.
///
/// \par entry point
/// `parse_type()` is the single public entry point. it strips leading
/// annotations and qualifiers, dispatches to `parse_primary_type`, and applies
/// the collected qualifiers to the result. all other `_parse_*` methods are
/// private productions called from the primary dispatch.
///
/// \par error recovery
/// every production constructs a valid AST node on all paths, using
/// `create_error` factory methods to produce recovery sentinels that suppress
/// cascading diagnostics in sema. `_sync_type` implements delimiter-aware token
/// skipping with a 64-token runaway cap and configurable sync contexts
/// (`TypeSyncCtx`).
///
/// \par code completion
/// `TkCodeComplete` tokens are checked at each delimiter boundary and forwarded
/// to `CompletionContextKind::TypeRef` via `maybe_complete` before returning an
/// error node, allowing the LSP to offer type-position completions mid-parse.
///
/// \par flag propagation
/// child element types propagate their `TypeQual` flags upward into composite
/// nodes (tuples, arrays, vectors, maps, sets) via `propagate_flags`. this
/// ensures that effect qualifiers on inner types are visible to sema without
/// re-traversal.
///
/// \par limitations
/// `_parse_qual_type` currently produces a bare `NamedType` from a single
/// identifier token. template arguments (`Foo::<T>`) and scoped paths
/// (`Foo::Bar`) are not yet handled; these require integration with the
/// `ChainExpr` parser (tracked as a FIXME). `_parse_const_expr` only accepts
/// integer literals full constant folding is deferred until the expression
/// parser is complete.
///
/// \see ASTParse, TypeQual, Type, TupleType, PointerType, FixedArrayType
// TODO(DUCK-GENERIC): T uses _consume_mode, _peek_mode, advance, advance_raw, apply_annotations_to_node, apply_quals, at_value_expr_continuation, c_idx, check, check_peek, check_prev, consume_leading_annotations, ... (32). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> TypeParse {
    var inferred_type_counter: u32 = 0

    /// The `>>` debt. The lexer gives `>>` as one token, so a nested generic
    /// whose `>` is the first half closes itself and owes the second half to
    /// the list around it. owe_close() is the one writer that sets it,
    /// pay_close() settles it (test and clear), forgive_close() drops one
    /// nobody is owed, owes_close() looks without settling. Only 0 or 1:
    /// `>>>` reaches the parser as `>>` then `>`, so it needs no more, and
    /// owing twice is owing one. `>>=` is a token of its own and is not
    /// split (`var v: A<A<i32>>= x` is S049E, P279).
    ///
    /// Part of a speculation's checkpoint (ASTParse::checkpoint), so a
    /// rollback cannot leave a debt behind that a later list pays wrongly.
    pub var _angle_debt: u8 = 0

    /// \brief a nested generic consumed `>>`: the enclosing list's `>` is gone.
    pub inline fn owe_close(self) {
        self._angle_debt = 1
    }

    /// \brief settles the debt if there is one.
    /// \return true if a `>` was owed (the caller's list is closed).
    pub inline fn pay_close(self) -> bool {
        if self._angle_debt == 0 {
            return false
        }

        self._angle_debt = 0
        return true
    }

    /// \brief drops a debt without using it: after a list nothing encloses
    ///        (a `>>` there owes no one), and the defensive clears at a list's
    ///        start, where a debt can only be stale.
    pub inline fn forgive_close(self) {
        self._angle_debt = 0
    }

    /// \brief is a `>` owed? Settles nothing.
    pub inline fn owes_close(self) -> bool {
        return self._angle_debt != 0
    }

    /// Kinds that start a type: the primitive `@`-types, the builtins,
    /// identifiers and `self`. A match rather than a per-parser `std::set`
    /// (see ExprParse::_is_expr_ident_kind).
    static fn _is_type_tok_kind(k: TokenKind) -> bool {
        match k {
            case TokenKind::AtVoid,   TokenKind::AtBool,        TokenKind::AtByte,
                 TokenKind::AtChar,   TokenKind::AtUsize,       TokenKind::AtIsize,
                 TokenKind::AtF8,     TokenKind::AtF8E4M3,      TokenKind::AtF8E5M2,
                 TokenKind::AtBf16,   TokenKind::AtF16,         TokenKind::AtF32,
                 TokenKind::AtF64,    TokenKind::AtF80,         TokenKind::AtF128,
                 TokenKind::AtF256,   TokenKind::AtF512,        TokenKind::AtU8,
                 TokenKind::AtU16,    TokenKind::AtU32,         TokenKind::AtU64,
                 TokenKind::AtU128,   TokenKind::AtU256,        TokenKind::AtU512,
                 TokenKind::AtI8,     TokenKind::AtI16,         TokenKind::AtI32,
                 TokenKind::AtI64,    TokenKind::AtI128,        TokenKind::AtI256,
                 TokenKind::AtI512,   TokenKind::BiFile,        TokenKind::BiLine,
                 TokenKind::BiColumn, TokenKind::BiFunction,    TokenKind::BiModule,
                 TokenKind::BiSelf,   TokenKind::LitIdentifier, TokenKind::KwSelf {
                return true
            } default {
                return false
            }
        }
    }

    enum TypeSyncCtx derives u8 {
        TopLevel, // sync to newline, ;, EOF
        Paren,    // sync to ) at depth 0
        Square,   // sync to ] at depth 0
        Brace,    // sync to } at depth 0
        Comma,    // sync to , or the closing delimiter
    }

    /// \brief attempts to recover from a parse error by skipping tokens until a
    ///        stable
    ///        type-position boundary is reached.
    ///
    /// \details this method implements a heuristic sync strategy to prevent
    ///          error
    ///          cascades. it tracks the nesting depth of `()`, `[]`, and `{}`
    ///          to ensure it does not stop on a delimiter that belongs to a
    ///          sub-expression. it stops when it encounters a token that
    ///          canonically terminates or separates types in the current `ctx`.
    ///
    /// recovery stops immediately if:
    ///   1. `MAX_SYNC` (64) tokens are consumed, to prevent runaway skipping in
    ///      heavily malformed files.
    ///   2. a closing delimiter is found while the corresponding depth counter
    ///      is 0.
    ///   3. a synchronization token (e.g., `,`, `;`, `->`) is found at depth 0.
    ///
    /// \param ctx             the syntactic context where the error occurred.
    /// \param paren_depth initial `()` nesting level, usually 0 unless recovery
    ///                        starts inside a partially parsed parameter list.
    /// \param square_depth initial `[]` nesting level, usually 0 unless
    ///        recovery
    ///                        starts inside an array or slice type.
    /// \param brace_depth     initial `{}` nesting level.
    /// \param stop_at_newline if true, the first `TkNewLine` encountered at
    ///        depth 0
    ///                        will terminate recovery regardless of `ctx`.
    inline fn _sync_type(self,
                         ctx:             Self::TypeSyncCtx,
                         paren_depth:     i32  = 0,
                         square_depth:    i32  = 0,
                         brace_depth:     i32  = 0,
                         stop_at_newline: bool = false) {
        var   balance_paren:   i32 = paren_depth
        var   balance_square:  i32 = square_depth
        var   balance_brace:   i32 = brace_depth
        var   tokens_consumed: u32 = 0
        const MAX_SYNC:        u32 = 64

        while !self.dyn()->is_eof() {
            if tokens_consumed >= MAX_SYNC {
                return
            }

            ++tokens_consumed

            var k = self.dyn()->ig_kind()

            // hard stop: caller is recovering from an unclosed delimiter and
            // wants us to bail at the next newline rather than eat the next
            // top-level construct.
            if stop_at_newline
                && k == TokenKind::TkNewLine
                && balance_paren == 0
                && balance_square == 0
                && balance_brace == 0 {
                return
            }

            if k == TokenKind::OpLParen {
                ++balance_paren
            } else if k == TokenKind::OpLSquare {
                ++balance_square
            } else if k == TokenKind::OpLBrace {
                ++balance_brace
            } else if k == TokenKind::OpRParen {
                if balance_paren == 0 {
                    // closing delimiter at our level always stops us; caller
                    // owns the decision of whether to consume it.
                    return
                }

                --balance_paren
            } else if k == TokenKind::OpRSquare {
                if balance_square == 0 {
                    return
                }

                --balance_square
            } else if k == TokenKind::OpRBrace {
                if balance_brace == 0 {
                    return
                }

                --balance_brace
            } else if balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                // at depth zero across all delimiter kinds: stop on tokens
                // that end a type-position production.
                if k == TokenKind::OpComma {
                    if ctx == Self::TypeSyncCtx::Comma
                        || ctx == Self::TypeSyncCtx::Paren
                        || ctx == Self::TypeSyncCtx::Square {
                        return
                    }
                }

                if k == TokenKind::TkNewLine && ctx == Self::TypeSyncCtx::TopLevel {
                    return
                }

                if k == TokenKind::OpSemicolon {
                    return
                }

                if k == TokenKind::OpArrow {
                    return
                }
            }

            self.dyn()->advance()
        }
    }

    /// Sync, then guarantee the cursor moved. For use inside recovery LOOPS:
    /// _sync_type stops ON a boundary token without consuming it, which is
    /// correct positioning but spins a caller that retries from the same spot.
    priv fn _sync_type_progress(self,
                                ctx:             Self::TypeSyncCtx,
                                paren_depth:     i32  = 0,
                                square_depth:    i32  = 0,
                                brace_depth:     i32  = 0,
                                stop_at_newline: bool = false) {
        var before = self.dyn()->c_idx
        self._sync_type(ctx, paren_depth, square_depth, brace_depth, stop_at_newline)
        if self.dyn()->c_idx == before {
            self.dyn()->advance()
        }
    }

    /// \brief performs a static downcast of `self` to the generic parser type
    ///        `T`.
    ///
    /// \details this is a CRTP helper that allows `TypeParse` to access the
    ///          full
    ///          state and methods of the concrete parser implementation
    ///          (usually `ASTParse`) without virtual dispatch overhead.
    ///
    /// \return a pointer to the derived `T` instance.
    inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// \brief creates a placeholder error type for failed type resolutions.
    ///
    /// \details constructs a `ChainType` in the error state via
    ///          `ChainType::create_error`.
    ///          this node serves as a sentinel in the AST to prevent further
    ///          cascading errors during semantic analysis after a primary parse
    ///          failure.
    ///
    /// \param range  the source location where the type resolution failed.
    /// \return a pointer to the newly allocated error-state type node.
    inline fn _error_type(self, range: SourceRange) -> *Type {
        return Types::ChainType::create_error(self.dyn()->ctx, range)
    }

    /// \brief top-level entry point for parsing a type expression.
    ///
    /// \details handles the full lifecycle of type parsing, including
    ///          annotation processing,
    ///          qualifier application, and primary type resolution.
    ///
    /// examples:
    /// ```
    /// var x: *const u32; // parses '*const u32' fn foo(a: [i32; 10]);
    /// // parses '[i32; 10]'
    /// ```
    ///
    /// the method first strips leading annotations (e.g., `@maybe_unused`) and
    /// qualifiers (e.g., `const`, `unsafe`), then descends into primary type
    /// parsing.
    ///
    /// \param is_inferred if true, skips parsing and creates an `InferredType`
    ///        node.
    ///                     used for `var` declarations without explicit types.
    /// \param skip_newline if true, the parser will ignore leading newlines
    ///        before the
    ///                     type tokens.
    /// \return a pointer to the parsed `Type` node, or `null` on exhaustion or
    ///         error.
    /// \p no_nullable leaves a trailing `?` for the caller: a pointer's
    /// pointee is parsed that way, so `*T?` is a nullable POINTER, `(*T)?`,
    /// as nullables.md and pointers.md write it. A pointer to a nullable is
    /// spelled `*(T?)`.
    fn parse_type(self,
                  is_inferred:  bool = false,
                  skip_newline: bool = false,
                  gen_arg:      bool = false,
                  no_nullable:  bool = false) -> unsafe *Type {
        if self.dyn()->is_eof() {
            return &null
        }

        if !self.dyn()->enter_depth() {
            return &null
        }

        if is_inferred {
            var prev_tok = self.dyn()->prev()

            if prev_tok.kind == TokenKind::TkUnknown {
                var cur_ptr = self.dyn()->current_ptr()
                var loc = if (cur_ptr != &null) => (cur_ptr->range.start) else => SourceLocation()

                self.dyn()->diag->report(
                    DiagID::S053E,
                    loc,
                    "unexpected start of input, expected type",
                ).emit()
                self.dyn()->exit_depth()
                return &null
            }

            var rt = Types::InferredType::create(
                self.dyn()->ctx,
                prev_tok.range,
                self.inferred_type_counter,
            )

            ++self.inferred_type_counter

            self.dyn()->exit_depth()
            return rt
        }

        // A passing mode is not part of a type. Asked BEFORE the annotation
        // scan below: `@inout` is `@` + identifier, which it would otherwise
        // swallow as an attribute and never report. Consumed so the type
        // that follows still parses. The fn-pointer parameter list takes its
        // modes itself (_parse_fn_ptr_params) and never lets one reach here.
        if self.dyn()->_peek_mode() != ParamMode::Value {
            var mr = self.dyn()->_consume_mode()
            self.dyn()->diag->report(
                DiagID::S069E,
                mr.start,
                "a passing mode is not part of a type; write it on the parameter "
                "('@inout x: T'); in a function pointer type the mode goes before "
                "the parameter type ('fn(@inout T)')",
            ).first(mr)->emit()
        }

        var annot: T::PendingAnnotations
        var quals: T::PendingQuals

        self.dyn()->consume_leading_annotations(&annot)
        self.dyn()->consume_leading_quals(&quals)

        var unsafe *ty = self.parse_primary_type(skip_newline, gen_arg)
        if ty == &null {
            self.dyn()->exit_depth()
            return &null
        }

        // secondary pass
        if !no_nullable
            && (self.dyn()->check(TokenKind::OpQuestion)
                || self.dyn()->check(TokenKind::OpQuestionQuestion)) {
            ty = self._parse_nullable_type(ty)
        } else if self.dyn()->check(TokenKind::OpEllipsis) {
            ty = self._parse_pack_expansion_type(ty)
        }

        self.dyn()->apply_quals(ty, &quals)
        self.dyn()->apply_annotations_to_node(ty, &annot)

        // `unsafe` on a pointer is not just a qualifier bit: `unsafe *T` is a
        // distinct canonical from `*T`, and the store keys on the field rather
        // than on flags. The bit stays in `flags` for the printer.
        if ty->kind == TypeKind::PointerType && ty->is_unsafe() {
            cast<Types::PointerType>(ty)->is_unsafe = true
        }

        // Likewise `unsafe fn(A) -> R`: the raw function pointer, a canonical
        // of its own (CanonicalTypeStore::func), not the `fn` value.
        if ty->kind == TypeKind::FunctionPointerType && ty->is_unsafe() {
            cast<Types::FunctionPointerType>(ty)->is_raw = true
        }

        self.dyn()->exit_depth()
        return ty
    }

    /// \brief dispatches the current token to the correct primary type
    ///        production.
    ///
    /// \details this is the central recursion point for type parsing after any
    ///          leading
    ///          qualifiers (like `const` or `unsafe`) or annotations have been
    ///          consumed by `parse_type`. it handles structural types
    ///          (pointers, arrays, functions) and leaf types (built-ins,
    ///          identifiers).
    ///
    /// \param skip_newline if true, leading `TkNewLine` tokens are consumed and
    ///        ignored.
    ///                      useful in contexts where a type is expected across
    ///                      a line boundary, such as after an assignment
    ///                      operator.
    ///
    /// \return a pointer to the parsed `Type` node, or `_error_type` if no
    ///         valid
    ///         type production could be matched. returns null only on `is_eof`.
    fn parse_primary_type(self, skip_newline: bool = false, gen_arg: bool = false) -> unsafe *Type {
        if self.dyn()->is_eof() {
            return &null
        }

        if skip_newline {
            while self.dyn()->check(TokenKind::TkNewLine) {
                self.dyn()->advance() // consume newlines
                if self.dyn()->is_eof() {
                    return &null
                }
            }
        }

        var cur_ptr = self.dyn()->current_ptr()
        if cur_ptr == &null {
            return &null
        }

        var cur_range = cur_ptr->range

        // pointer types: `*T`, `*const T`, etc.
        if self.dyn()->check(TokenKind::OpStar) {
            return self._parse_pointer_type()
        }

        // braced types: currently used for structural records or inline unions.
        if self.dyn()->check(TokenKind::OpLBrace) {
            return self._parse_braced_type()
        }

        // parenthesized types: `(T)` or tuple types `(T, U)`.
        if self.dyn()->check(TokenKind::OpLParen) {
            return self._parse_paren_type()
        }

        // square bracket types: arrays `[T; N]` or slices `[T]`.
        if self.dyn()->check(TokenKind::OpLSquare) {
            return self._parse_square_type()
        }

        // function pointer types: `fn(args) -> Ret`.
        if self.dyn()->check(TokenKind::KwFn) {
            return unsafe (self._parse_fn_ptr_type() as unsafe *Type)
        }

        if self.dyn()->check(TokenKind::OpEllipsis) {
            return self._parse_variadic_type()
        }

        // `Self` alone is a SelfType. `Self::Inner` is a chain whose head is
        // the enclosing type; only T can step into it, so hand it the chain.
        if self.dyn()->check(TokenKind::BiSelf) {
            if self.dyn()->check_peek(TokenKind::OpColonColon) {
                return self._parse_qual_type()
            }

            return self._parse_self_type()
        }

        if self.dyn()->check(TokenKind::KwTypeOf) {
            return self._parse_typeof_type()
        }

        if self.dyn()->check(TokenKind::TkCodeComplete) {
            self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
            self.dyn()->advance(T::SkipNL::After) // consume code complete token and any newlines after it
            return self._error_type(cur_range)
        }

        // leaf types: built-ins (u32, f64, etc.), `Self`, or identifiers.
        if self.dyn()->check(
            fn(k: TokenKind) -> bool {
                return Self::_is_type_tok_kind(k)
            },
        ) {
            return self._parse_qual_type()
        }

        // no type production matched. in a generic-argument position a value
        // expression is legal (const/value generic args like `Array<i32, 12>`),
        // so fall through to parsing the token as a value expression wrapped in
        // a TypeExpr. StopAngle|StopComma keeps `parse_expr` from swallowing the
        // `>`/`>>` closer or the `,` separator as binary operators. Outside
        // generic args (sizeof/alignof/typeof operands, param/tuple types, ...)
        // a bare value is still an error, so the diagnostic below stands.
        if gen_arg {
            return self._parse_type_expr(
                self.dyn()->stop_on(T::ExprStopKind::StopAngle).plus(T::ExprStopKind::StopComma),
            )
        }

        // no production matched; report error and attempt recovery.
        var resolved_kind = self.dyn()->resolve_kind_deep(cur_ptr)
        self.dyn()->report_tok(
            DiagID::S053E,
            cur_ptr,
            f"expected type, found '{token_kind_to_readable_string(resolved_kind)}'",
        )

        self.dyn()->advance() // skip offending token to prevent infinite loops during recovery.
        return self._error_type(cur_range)
    }

    inline fn _parse_self_type(self) -> unsafe *Types::SelfType {
        var tok = self.dyn()->current()
        var ty  = Types::SelfType::create(self.dyn()->ctx, tok.range)
        self.dyn()->advance() // consume `Self`
        return ty
    }

    inline fn _parse_typeof_type(self) -> unsafe *Types::TypeOfType {
        var tok         = self.dyn()->current()
        var start_range = tok.range

        self.dyn()->advance() // consume `typeof`

        // A prefix-level operand: the `=` of `var y: typeof x = 100` is the
        // declaration's, not an assignment inside the typeof. No struct
        // literal: the `{` of `-> typeof x { ... }` opens the body.
        var inner = self.dyn()->parse_typeof_operand(
            self.dyn()->stop_on(T::ExprStopKind::NoStructLiteral),
        )

        if inner == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                start_range.start,
                "expected type after 'typeof'",
            ).first(start_range)->emit()

            return Types::TypeOfType::create_error(self.dyn()->ctx, start_range)
        }

        var ty = Types::TypeOfType::create(self.dyn()->ctx, start_range | inner->range, inner)
        return ty
    }

    /// \brief parses parenthesized type constructs including groupings `(T)`
    ///        and tuples `(T1, T2, ...)`.
    ///
    /// \details entry point for types starting with `(`. if only one type is
    ///          present, it is
    ///          treated as a grouping expression and the inner type is returned
    ///          unwrapped. if a comma follows the first type, it transitions to
    ///          tuple parsing.
    ///
    /// \note empty tuples `()` are syntactically valid but semantically illegal
    ///       in Kairo;
    ///       this method emits a diagnostic suggesting `void` and returns a
    ///       recovery type.
    ///
    /// FIXME: handle the case where `parse_type` returns an error type
    /// (recovery node) instead of null by using `isa_recovery(...)`.
    inline fn _parse_paren_type(self) -> unsafe *Type {
        // precondition: current token is `(`
        var lparen_ptr  = self.dyn()->current_ptr()
        var start_range = lparen_ptr->range

        self.dyn()->advance(T::SkipNL::After) // consume `(`

        // empty tuple: `()`
        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->advance() // consume `)`
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "empty tuple types are not allowed, did you mean 'void'?",
            ).first(start_range)->emit()

            var tt = Types::TupleType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return tt
        }

        var unsafe *first = self.parse_type(false, true)
        if first == &null || is_recovery(first) {
            self.dyn()->diag->report(
                DiagID::S053E,
                start_range.start,
                "expected type after '('",
            ).first(start_range)->emit()

            self._sync_type(Self::TypeSyncCtx::Paren, 1, 0, 0, true)
            return self._error_type(start_range | self.dyn()->prev().range)
        }

        // tuple: `(T1, T2, ...)`
        if self.dyn()->check(TokenKind::OpComma) {
            return self._finish_tuple_type(start_range, first)
        }

        // grouping: `(T)` just unwrap
        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->advance() // consume `)`
            return first
        }

        // missing `)` emit diagnostic but still return what we parsed
        self.dyn()->diag->report(
            DiagID::S055E,
            start_range.start,
            "expected ')' after type in grouping expression ",
        ).first(start_range)->emit()

        return first
    }

    /// \brief completes the parsing of a tuple type after the first element.
    ///
    /// \details called when `parse_type` encounters a comma after an initial
    ///          type within
    ///          parentheses, e.g., `(T,`. this method handles subsequent
    ///          elements, trailing commas, and closing delimiter verification.
    ///
    /// for a single parenthesized type like `(int)`, the parser never enters
    /// this method. a tuple must have at least two elements, such as `(int,
    /// void)`.
    ///
    /// \param start_range  source range starting from the opening `(`.
    /// \param first        the already-parsed first element of the tuple.
    /// \return a `TupleType` node, or a `TupleType` error node if parsing fails
    ///         or
    ///         arity constraints are violated.
    inline fn _finish_tuple_type(self,
                                 start_range: SourceRange,
                                 first:       unsafe *Type) -> *Types::TupleType {
        if !self.dyn()->enter_depth() {
            self.dyn()->diag->report(
                DiagID::S063E,
                start_range.start,
                "exceeded maximum nesting depth in tuple type",
            ).first(start_range)->emit()

            return Types::TupleType::create_error(self.dyn()->ctx, start_range)
        }

        var vals: kairo::std::StackBuf<unsafe *Type, 8>
        vals.push_back(first)

        while self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->advance(T::SkipNL::After) // consume `,`

            if self.dyn()->check(TokenKind::OpRParen) {
                break
            }

            if self.dyn()->check(TokenKind::TkNewLine) {
                // allow newlines between tuple elements for readability
                continue
            }

            if self.dyn()->check(TokenKind::TkCodeComplete) {
                self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
                self.dyn()->advance(T::SkipNL::After) // consume code complete token and any newlines after it
                break
            }

            var unsafe *elem = self.parse_type(false, true)
            if elem == &null || is_recovery(elem) {
                // no stop_at_newline we're mid-tuple, newlines are legal
                self._sync_type_progress(Self::TypeSyncCtx::Comma, 1)
                continue
            }

            vals.push_back(elem)
        }

        var full_range = start_range | self.dyn()->prev().range

        var comma_range: SourceRange
        if self.dyn()->check_prev(TokenKind::OpComma) {
            comma_range = self.dyn()->prev().range

            if self.dyn()->check(TokenKind::TkCodeComplete) {
                self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
                self.dyn()->advance(T::SkipNL::After)
            }
        }

        self.dyn()->advance(T::SkipNL::Only) // consume any trailing newlines after the last element

        if self.dyn()->check(TokenKind::OpRParen) {
            full_range = full_range | self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::Before) // consume `)`
        } else {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "expected ')' to close tuple type",
            ).first(start_range)->emit()
        }

        /// \note Kairo requires tuples to have N >= 2 elements. single-element
        ///       parenthesized expressions are desugared to their inner type.
        if vals.size() == 1 {
            self.dyn()->diag->report(
                DiagID::S055E,
                full_range.start,
                "tuple types must contain at least two elements or more, did you "
                "mean to write '(T)' without the comma for a parenthesised type? ",
            ).first(comma_range)->fix(
                comma_range,
                "remove",
                "remove this comma to make it a parenthesised type",
            )->emit()

            return Types::TupleType::create_error(
                self.dyn()->ctx,
                full_range | self.dyn()->prev().range,
            )
        }

        // The cap is the flag's, under the compiler's own
        // (LangItems::TUPLE_MAX_ARITY: a tuple is the record of its arity,
        // and TupleRecords mints none wider). 0 means "no flag cap" (the
        // flag's documented meaning); comparing against 0 directly rejected
        // every tuple. Past the compiler's cap the fix-it does not offer the
        // flag, which cannot raise it.
        var flag_cap = self.dyn()->ctx->ci->frontend.max_tuple_arity
        var cap      = TUPLE_MAX_ARITY
        if flag_cap > 0 && (flag_cap as usize) < cap {
            cap = (flag_cap as usize)
        }

        if (vals.size() as usize) > cap {
            var range = vals[(cap as u32)]->range
            var endr  = vals[vals.size() - 1]->range
            var hint  = "reduce the number of elements in this tuple type"
            if cap < TUPLE_MAX_ARITY {
                hint += " or increase the limit with --cmax-tuple-arity"
            }

            self.dyn()->diag->report(
                DiagID::S055E,
                range.start,
                f"tuple arity exceeds the maximum of {cap} (got {vals.size()})",
            ).first(range)->fix(range | endr, "remove", hint)->strike(
                SourceRange::from_bounds(range.end, full_range.end),
            )->emit()

            return Types::TupleType::create_error(self.dyn()->ctx, full_range)
        }

        var tt = Types::TupleType::create(self.dyn()->ctx, full_range)
        tt->elements.from_buf(vals.data(), vals.size(), self.dyn()->ctx)

        /// verify and merge type qualifiers/effects from child elements into
        /// the tuple node.
        for var i: usize = 0; i < tt->elements.size(); ++i {
            Types::propagate_flags(tt, tt->elements[i])
        }

        self.dyn()->exit_depth()
        return tt
    }

    /// \brief parses types delimited by square brackets, including vectors
    ///        `[T]` and arrays `[T; N]`.
    ///
    /// \details this method handles the logic for constructing sequence-based
    ///          types after an opening `[`
    ///          is encountered. the parser distinguishes between two primary
    ///          forms:
    ///          - `VectorType`: a dynamically sized or slice-like sequence,
    ///            written as `[T]`.
    ///          - `ArrayType`: a fixed-size sequence, written as `[T; N]`,
    ///            delegated to `_finish_array_type`.
    ///
    /// \note if a comma is encountered (e.g., `[T, U]`), the parser emits a
    ///       diagnostic suggesting
    ///       tuple syntax `(T, U)` but recovers by treating it as an erroneous
    ///       array type.
    ///
    /// \return a `VectorType`, an `ArrayType`, or a recovery error node. never
    ///         returns `&null`
    ///         unless a fatal internal inconsistency occurs during element
    ///         parsing.
    inline fn _parse_square_type(self) -> unsafe *Type {
        // precondition: current token is `[`
        var lsquare_ptr = self.dyn()->current_ptr()
        var start_range = lsquare_ptr->range
        self.dyn()->advance(T::SkipNL::After) // consume `[`

        if self.dyn()->check(TokenKind::OpRSquare) {
            self.dyn()->advance() // consume `]`
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "empty arrays/vector types are not allowed, expected a type `[T]` or `[T; N]`",
            ).first(start_range)->emit()
            var vt = Types::VectorType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return vt
        }

        if self.dyn()->check(TokenKind::TkCodeComplete) {
            self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
            self.dyn()->advance(T::SkipNL::After) // consume code complete token and any newlines after it
            var vt = Types::VectorType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return vt
        }

        var unsafe *elem_type = self.parse_type()
        self.dyn()->advance(T::SkipNL::Only) // consume any newlines after the element type

        if elem_type == &null {
            // this should never get called since we should
            // always be making a fully valid tree (even with broken nodes)
            self.dyn()->diag->report(
                DiagID::S053E,
                start_range.start,
                "expected type after '['",
            ).first(start_range)->emit()
            return &null
        }

        if is_recovery(elem_type) {
            var err_st = Types::VectorType::create_error(
                self.dyn()->ctx,
                start_range | elem_type->range,
            )

            Types::propagate_flags(err_st, elem_type)
            return err_st
        }

        // common error, if we have a , in here this is invalid syntax, maybe they
        // meant to write a tuple type with parentheses instead of square brackets?
        if self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "unexpected ',' in square bracket type, did you mean to use parentheses for a tuple type?",
            ).first(start_range)->emit()
            return self._finish_array_type(start_range, elem_type, true) // in error state
        }

        if self.dyn()->check(TokenKind::OpColon) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "unexpected ':' in square bracket type, did you mean ';' for an array type with size '[T; N]'?",
            ).first(start_range)->emit()
            return self._finish_array_type(start_range, elem_type, true) // in error state
        }

        if self.dyn()->check(TokenKind::OpSemicolon) {
            return self._finish_array_type(start_range, elem_type)
        }

        if !self.dyn()->check(TokenKind::OpRSquare) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "expected ']' after type in square brackets",
            ).first(start_range)->emit()
            // try to sync to ']' to continue parsing
            self._sync_type(Self::TypeSyncCtx::Square, 0, 1, 0, true)
            return Types::VectorType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )
        }

        self.dyn()->advance(T::SkipNL::Before) // consume `]`
        var full_range = start_range | self.dyn()->prev().range

        var st = Types::VectorType::create(self.dyn()->ctx, full_range, elem_type)
        Types::propagate_flags(st, elem_type)
        return st
    }

    /// \brief completes the parsing of a `FixedArrayType` after the element
    ///        type has been consumed.
    ///
    /// \details handles the trailing portion of the array type syntax `[T; N]`.
    ///          this method is
    ///          invoked when the parser is positioned at the semicolon
    ///          separating the element type from the size expression. it
    ///          supports three primary outcomes:
    ///            1. a complete array type with a constant size expression `[T;
    ///               42]`.
    ///            2. an incomplete array type `[T; ]`, typically used in
    ///               contexts where the
    ///               size is inferred or provided later.
    ///            3. an error node for recovery when the size expression is
    ///               missing or invalid.
    ///
    /// \param start_range the source range of the opening `[` and possibly
    ///        preceding tokens.
    /// \param elem_type    the already-parsed element type `T`.
    /// \param is_error if true, indicates a grammar violation was already
    ///        detected prior
    ///                     to calling this method; the method will continue to
    ///                     sync and return an error node rather than a valid
    ///                     type.
    /// \return a pointer to the constructed `FixedArrayType`, or `&null` on
    ///         fatal failure.
    inline fn _finish_array_type(self,
                                 start_range: SourceRange,
                                 elem_type:   *Type,
                                 is_error:    bool = false) -> unsafe *Types::FixedArrayType {
        // we are sitting on the `;` after parsing the element type in an array type like `[T; N]`
        // or we got here in error recovery after seeing a `,` which is not valid syntax for array types
        var semicolon_ptr   = self.dyn()->current_ptr()
        var semicolon_range = semicolon_ptr->range
        self.dyn()->advance(T::SkipNL::After) // consume `;`

        if self.dyn()->check(TokenKind::OpRSquare) {
            if is_error {
                self.dyn()->diag->report(
                    DiagID::S055E,
                    semicolon_range.start,
                    "expected array size expression after ';' in array type",
                ).first(semicolon_range)->emit()
                self.dyn()->advance()
                return Types::FixedArrayType::create_error(
                    self.dyn()->ctx,
                    start_range | semicolon_range,
                )
            }

            var rsquare_range = self.dyn()->current_ptr()->range
            self.dyn()->advance()
            var arr = Types::FixedArrayType::create_incomplete(
                self.dyn()->ctx,
                start_range | rsquare_range,
                elem_type,
            )

            Types::propagate_flags(arr, elem_type)
            return arr
        }

        var unsafe *size_expr = self._parse_const_expr()
        self.dyn()->advance(T::SkipNL::Only)

        if size_expr == &null {
            self.dyn()->diag->report(
                DiagID::S055E,
                semicolon_range.start,
                "expected constant expression for array size after ';' in array type",
            ).first(semicolon_range)->emit()
            return &null
        }

        // if we have a , here this is invalid syntax, maybe they meant to write a tuple type with parentheses instead of square brackets?
        if self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->diag->report(
                DiagID::S055E,
                semicolon_range.start,
                "unexpected ',' in array type, did you mean to use parentheses for a tuple type?",
            ).first(semicolon_range)->emit()
            self._sync_type(Self::TypeSyncCtx::Square, 0, 1) // sync to closing `]` to continue parsing
            return Types::FixedArrayType::create_error(
                self.dyn()->ctx,
                start_range | size_expr->range,
            )
        }

        // check for ']'
        if !self.dyn()->check(TokenKind::OpRSquare) {
            self.dyn()->diag->report(
                DiagID::S055E,
                semicolon_range.start,
                "expected ']' after array size expression in array type",
            ).first(semicolon_range)->emit()
            // try to sync to ']' to continue parsing
            self._sync_type(Self::TypeSyncCtx::Square, 0, 1, 0, true)
            return Types::FixedArrayType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )
        }

        self.dyn()->advance(T::SkipNL::Before) // consume `]`
        var full_range = start_range | self.dyn()->prev().range

        if is_error {
            var err_at = Types::FixedArrayType::create_error(self.dyn()->ctx, full_range)
            err_at->element   = elem_type
            err_at->size_expr = size_expr
            Types::propagate_flags(err_at, elem_type)
            return err_at
        }

        var at = Types::FixedArrayType::create(self.dyn()->ctx, full_range, elem_type, size_expr)
        Types::propagate_flags(at, elem_type)
        return at
    }

    /// \brief parses types enclosed in braces, primarily `SetType` and
    ///        `MapType`.
    ///
    /// \details handles the syntactic disambiguation between set types `{T}`
    ///          and
    ///          map types `{K: V}`. the parser first attempts to parse a single
    ///          type; if followed by a colon `:`, it transitions to map-type
    ///          parsing.
    ///
    /// \example
    /// ```kairo
    /// var s: {u32}; // SetType var m: {string: i32}; // MapType
    /// ```
    ///
    /// \note empty braced types `{}` are prohibited to avoid ambiguity with
    ///       empty blocks or future syntax; `void` should be used if a
    ///       unit-like type is intended in a braced context.
    inline fn _parse_braced_type(self) -> unsafe *Type {
        // precondition: current token is `{`
        var lbrace_ptr  = self.dyn()->current_ptr()
        var start_range = lbrace_ptr->range

        self.dyn()->advance(T::SkipNL::After) // consume `{`

        // empty braced type: `{}`
        if self.dyn()->check(TokenKind::OpRBrace) {
            var r = start_range | self.dyn()->current_ptr()->range

            self.dyn()->advance() // consume `}`
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "empty braced types are not allowed, use 'void' for empty or '{T}' for a set type",
            ).first(start_range)->emit()

            return Types::MapType::create_error(self.dyn()->ctx, r)
        }

        if self.dyn()->check(TokenKind::TkCodeComplete) {
            self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
            self.dyn()->advance(T::SkipNL::After) // consume code complete token and any newlines after it

            var r      = start_range | self.dyn()->prev().range
            var err_mt = Types::MapType::create_error(self.dyn()->ctx, r)

            return err_mt
        }

        var unsafe *key_type = self.parse_type(false, true)
        self.dyn()->advance(T::SkipNL::Only)

        if key_type == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                start_range.start,
                "expected type after '{'",
            ).first(start_range)->emit()

            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1, true)
            return self._error_type(start_range)
        }

        if is_recovery(key_type) {
            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1, true)

            var err = Types::SetType::create_error(self.dyn()->ctx, start_range | key_type->range)
            Types::propagate_flags(err, key_type)

            return err
        }

        // `{K: V}` map type
        if self.dyn()->check(TokenKind::OpColon) {
            return self._finish_map_type(start_range, key_type)
        }

        // common error: `{K; V}` semicolon instead of colon
        if self.dyn()->check(TokenKind::OpSemicolon) {
            self.dyn()->report_tok(
                DiagID::S055E,
                self.dyn()->current_ptr(),
                "unexpected ';' in braced type, did you mean ':' for a map type '{K: V}'?",
            )

            return self._finish_map_type(start_range, key_type, true)
        }

        // common error: `{K, V}` comma instead of colon, probably confused with tuple
        if self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->report_tok(
                DiagID::S055E,
                self.dyn()->current_ptr(),
                "unexpected ',' in braced type, did you mean ':' for a map type '{K: V}'"
                "or '(' for a tuple type?",
            )

            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1)
            return Types::SetType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )
        }

        // `{T}` set type
        if self.dyn()->check(TokenKind::OpRBrace) {
            var full_range = start_range | self.dyn()->current_ptr()->range
            self.dyn()->advance(T::SkipNL::Before) // consume `}`

            // FIXME: instead of having a custom node for set types, we could
            // directly desugar into kairo::core::Set<T> here in the parser.
            var st = Types::SetType::create(self.dyn()->ctx, full_range, key_type)
            return st
        }

        // missing `}` or `:`
        self.dyn()->diag->report(
            DiagID::S055E,
            start_range.start,
            "expected '}' to close set type or ':' to begin map type value",
        ).first(start_range)->emit()

        self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1, true)

        return Types::SetType::create_error(self.dyn()->ctx, start_range | self.dyn()->prev().range)
    }

    /// \details completes the parsing of a map type literal `{K: V}`
    ///          after the
    ///          key type and the colon separator have been identified.
    ///
    /// \param start_range  range starting from the opening `{`.
    /// \param key_type     the already-parsed key type `K`.
    /// \param is_error if true, forces the return of an error-kind
    ///        `MapType`
    ///                     regardless of whether the value type parses
    ///                     successfully.
    ///
    /// \note expects the lexer to be positioned at the `:` separator.
    ///       handles
    ///       recovery for missing value types, extraneous commas, and
    ///       nested colons.
    inline fn _finish_map_type(self,
                               start_range: SourceRange,
                               key_type:    *Type,
                               is_error:    bool = false) -> *Types::MapType {
        // precondition: sitting on `:` (or `;` in error case, already diagnosed)
        var sep_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `:` or `;`

        // `{K:}` missing value type
        if self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->diag->report(
                DiagID::S053E,
                sep_range.start,
                "expected value type after ':' in map type '{K: V}'",
            ).first(sep_range)->emit()
            self.dyn()->advance() // consume `}`
            var err = Types::MapType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            Types::propagate_flags(err, key_type)
            return err
        }

        if self.dyn()->check(TokenKind::TkCodeComplete) {
            self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
            self.dyn()->advance(T::SkipNL::After) // consume code complete token and any newlines after it
            var err = Types::MapType::create_error(self.dyn()->ctx, start_range | sep_range)
            Types::propagate_flags(err, key_type)
            return err
        }

        var unsafe *val_type = self.parse_type(false, true)
        self.dyn()->advance(T::SkipNL::Only)

        if val_type == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                sep_range.start,
                "expected value type after ':' in map type '{K: V}'",
            ).first(sep_range)->emit()
            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1)
            var err = Types::MapType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            Types::propagate_flags(err, key_type)
            return err
        }

        if is_recovery(val_type) {
            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1)
            var err = Types::MapType::create_error(self.dyn()->ctx, start_range | val_type->range)
            Types::propagate_flags(err, key_type)
            Types::propagate_flags(err, val_type)
            return err
        }

        // common error: `{K: V, ...}`
        if self.dyn()->check(TokenKind::OpComma) {
            self.dyn()->report_tok(
                DiagID::S055E,
                self.dyn()->current_ptr(),
                "unexpected ',' in map type, map types take exactly one key and one value type '{K: V}'",
            )

            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1)
            var err = Types::MapType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            Types::propagate_flags(err, key_type)
            Types::propagate_flags(err, val_type)
            return err
        }

        // common error: `{K: V: W}` double colon
        if self.dyn()->check(TokenKind::OpColon) {
            self.dyn()->report_tok(
                DiagID::S055E,
                self.dyn()->current_ptr(),
                "unexpected ':' in map type, expected '}' after value type",
            )

            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1)
            var err = Types::MapType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            Types::propagate_flags(err, key_type)
            Types::propagate_flags(err, val_type)
            return err
        }

        if !self.dyn()->check(TokenKind::OpRBrace) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "expected '}' to close map type",
            ).first(start_range)->emit()
            self._sync_type(Self::TypeSyncCtx::Brace, 0, 0, 1)
            var err = Types::MapType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            Types::propagate_flags(err, key_type)
            Types::propagate_flags(err, val_type)
            return err
        }

        var full_range = start_range | self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::Before) // consume `}`

        if is_error {
            var err = Types::MapType::create_error(self.dyn()->ctx, full_range)
            err->key   = key_type
            err->value = val_type
            Types::propagate_flags(err, key_type)
            Types::propagate_flags(err, val_type)
            return err
        }

        var mt = Types::MapType::create(self.dyn()->ctx, full_range, key_type, val_type)
        return mt
    }

    /// \brief parses a pointer type declaration starting with the `*`
    ///        sigil.
    ///
    /// \details handles simple pointers `*T`, multi-level pointers `**T`, and
    ///          qualified
    ///          pointers such as `*const T`. because `parse_type` is called
    ///          recursively for the pointee, qualifier associativity is
    ///          naturally handled by the descent: `*const T` is parsed as a
    ///          pointer to a `const T`.
    ///
    /// \return a `PointerType` node. if parsing fails or hits a code completion
    ///         token,
    ///          returns a `PointerType` marked with error flags to suppress
    ///          redundant diagnostics during sema.
    inline fn _parse_pointer_type(self) -> unsafe *Types::PointerType {
        // precondition: current token is `*`
        var star_ptr    = self.dyn()->current_ptr()
        var start_range = star_ptr->range
        self.dyn()->advance() // consume `*`

        if self.dyn()->check(TokenKind::TkCodeComplete) {
            self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
            var err_pt = Types::PointerType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )

            return err_pt
        }

        // parse_type() recurses handles `**T`, `*const T`, etc.
        // because parse_type() will see `const` as a qualifier and `*` as another pointer.
        // The `?` is left for the parse_type this pointer is the primary of:
        // `*T?` is `(*T)?`, and `**T?` is `(**T)?`.
        var unsafe *pointee = self.parse_type(false, false, false, true)
        if pointee == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                start_range.start,
                "expected type after '*'",
            ).first(start_range)->emit()

            return Types::PointerType::create_error(self.dyn()->ctx, start_range)
        }

        var end_range = if (pointee != &null) => (pointee->range) else => start_range
        if is_recovery(pointee) {
            var err_pt = Types::PointerType::create_error(self.dyn()->ctx, start_range | end_range)
            Types::propagate_flags(err_pt, pointee)
            return err_pt
        }

        var pty = Types::PointerType::create(self.dyn()->ctx, start_range | end_range, pointee)

        return pty
    }

    /// \brief parses a function pointer type such as `fn(i32) -> bool`.
    ///
    /// \details entry point for the `fn` keyword in a type context. handles
    ///          optional
    ///          generic parameter placeholders (currently skipped), the
    ///          parameter list, trailing function qualifiers (e.g., `const`,
    ///          `panic`, `async`), and the optional return type arrow.
    ///
    /// ```kairo
    /// var callback: fn(u32, u32) -> bool; var worker: fn() async panic;
    /// ```
    ///
    /// \note does not support named parameters; only types are permitted within
    ///       the
    ///       parentheses. if a name is detected immediately following `fn`, the
    ///       parser assumes a declaration was intended and attempts to recover.
    inline fn _parse_fn_ptr_type(self) -> unsafe *Types::FunctionPointerType {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `fn`

        if self.dyn()->check(TokenKind::OpLess) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "unexpected '<' after 'fn' in function pointer type, generic parameters are not supported here",
            ).first(start_range)->emit()
            self._sync_type(Self::TypeSyncCtx::TopLevel, 0, 0, 0, true)
            return Types::FunctionPointerType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )
        }

        if self.dyn()->check(
            fn (k: TokenKind) -> bool {
                return Self::_is_type_tok_kind(k)
            },
        ) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "unexpected identifier after 'fn' in function pointer type, "
                "did you mean to write a function declaration?",
            ).first(start_range)->emit()
            self._sync_type(Self::TypeSyncCtx::TopLevel, 0, 0, 0, true)
            return Types::FunctionPointerType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )
        }

        // require `(`
        if !self.dyn()->check(TokenKind::OpLParen) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "expected '(' after 'fn' in function pointer type",
            ).first(start_range)->emit()
            self._sync_type(Self::TypeSyncCtx::TopLevel, 0, 0, 0, true)
            return Types::FunctionPointerType::create_error(
                self.dyn()->ctx,
                start_range | self.dyn()->prev().range,
            )
        }

        self.dyn()->advance(T::SkipNL::After) // consume `(`

        var param_types: kairo::std::StackBuf<*Type, 8>
        var param_modes: kairo::std::StackBuf<ParamMode, 8> // parallel to param_types.

        if !self.dyn()->check(TokenKind::OpRParen) {
            self._parse_fn_ptr_params(&param_types, &param_modes, start_range)
        }

        // consume `)`
        if self.dyn()->check(TokenKind::OpRParen) {
            self.dyn()->advance()
        } else {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "expected ')' to close function pointer parameter list",
            ).first(start_range)->emit()
            self._sync_type(Self::TypeSyncCtx::Paren, 1, 0, 0, true)
        }

        // `fn(A) @preserve_most -> R`: the calling convention, right after
        // the parameter list (FunctionPointerType::call_conv). Only the three
        // convention names are taken; any other `@x` here is not this type's
        // and is left where it is.
        var fn_cc: u8 = 0
        if self.dyn()->check(TokenKind::OpAt) && self.dyn()->check_peek(TokenKind::LitIdentifier) {
            var an = self.dyn()->ctx->hoisted->intern_tok(self.dyn()->peek())
            if an == self.dyn()->ctx->hoisted->intern(LangAttrs::preserve_most()) {
                fn_cc = 1
            } else if an == self.dyn()->ctx->hoisted->intern(LangAttrs::preserve_all()) {
                fn_cc = 2
            } else if an == self.dyn()->ctx->hoisted->intern(LangAttrs::preserve_none()) {
                fn_cc = 3
            }

            if fn_cc != 0 {
                self.dyn()->advance() // `@`
                self.dyn()->advance() // the name
            }
        }

        // trailing qualifiers: fn(T) const panic async -> U. A `(` right
        // after `panic`, on its line, is the declared set (Compiler/Spec/Panic.md#declared-sets):
        // nothing else can follow a qualifier here, so the set is never a
        // tuple. Qualifiers may continue after it (`panic(E) async`).
        var fn_quals: T::PendingQuals
        self.dyn()->consume_leading_quals(&fn_quals)
        var pset:       kairo::std::StackBuf<unsafe *Type, 4>
        var more_quals: T::PendingQuals
        // The LAST qualifier, as consume_leading_quals resolved it (a
        // `panic` from a macro expansion included), not the raw prev token.
        var nq = fn_quals.spans.size()
        var last_is_panic = nq > 0
            && fn_quals.spans[nq - 1].qual_flag == (TypeQual<Type>::Flags::IsPanic as u16)
        if last_is_panic && self.dyn()->check(TokenKind::OpLParen) {
            self.parse_panic_set(unsafe &pset)
            self.dyn()->consume_leading_quals(&more_quals)
        }

        // optional return type
        var return_type: unsafe *Type = &null
        if self.dyn()->check(TokenKind::OpArrow) {
            self.dyn()->advance() // consume `->`
            // `!` is the never type, a builtin spelled by punctuation. It is
            // deliberately not in _is_type_tok_kind (`!x` must stay an expression
            // everywhere else), so the one place it is a type, a return
            // position, takes it here the way a function decl's `-> !` does.
            if self.dyn()->check(TokenKind::OpExclaim) {
                return_type = self._parse_qual_type()
            } else {
                return_type = self.parse_type()
            }

            if return_type == &null || is_recovery(return_type) {
                var err = Types::FunctionPointerType::create_error(
                    self.dyn()->ctx,
                    start_range | self.dyn()->prev().range,
                )

                if return_type != &null {
                    Types::propagate_flags(err, return_type)
                }

                return err
            }
        }

        var fpt = Types::FunctionPointerType::create(
            self.dyn()->ctx,
            start_range | self.dyn()->prev().range,
            return_type,
        )

        fpt->params.from_buf(param_types.data(), param_types.size(), self.dyn()->ctx)
        // Always, even when empty: TypeResolution ICEs on a count mismatch.
        // The create_error / create_unprototyped nodes populate neither, so
        // they are parallel at zero.
        fpt->modes.from_buf(param_modes.data(), param_modes.size(), self.dyn()->ctx)
        fpt->panic_set.from_buf(pset.data(), pset.size(), self.dyn()->ctx)
        fpt->call_conv = fn_cc
        for var i: usize = 0; i < (pset.size() as usize); ++i {
            Types::propagate_flags(fpt, pset[(i as u32)])
        }

        self.dyn()->apply_quals(fpt, &fn_quals)
        self.dyn()->apply_quals(fpt, &more_quals)
        return fpt
    }

    /// \brief parses the declared panic set `(E1, E2)` after a `panic`
    ///        specifier (Compiler/Spec/Panic.md#declared-sets) into \p out.
    ///
    /// \details the caller has consumed `panic` and calls this only when `(`
    ///          is the very next token, on the same line. That position is
    ///          where the specifier can be, never a statement, so the list is
    ///          always the set and never a tuple or a `panic (expr)`
    ///          statement: in a function header, a closure header (both after
    ///          the parameter list, before `->` and the body), and a `fn`
    ///          type. `panic` then a newline then `(` is NOT a set: a
    ///          bodiless declaration ends at the newline, as everywhere.
    ///
    ///          Each element is a type. One that fails to parse is dropped
    ///          and the list recovers at the next `,` / `)`. `panic()` names
    ///          no type, which no set can be: S055E with a fix-it removing
    ///          the parentheses, and it parses as a bare `panic` (inferred).
    pub fn parse_panic_set(self, out: unsafe *kairo::std::StackBuf<unsafe *Type, 4>) {
        var open = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `(`

        // set once something in the list was diagnosed, so a missing `)`
        // after it is not reported a second time.
        var failed = false
        while !self.dyn()->is_eof() {
            if self.dyn()->check(TokenKind::OpRParen) {
                break
            }

            var unsafe *ty = self.parse_type()
            if ty != &null && !is_recovery(ty) {
                out->push_back(ty)
                if self.dyn()->check(TokenKind::OpComma) {
                    self.dyn()->advance(T::SkipNL::After)
                    continue
                }

                if self.dyn()->check(TokenKind::OpRParen) {
                    break
                }

                self.dyn()->report_tok(
                    DiagID::S055E,
                    self.dyn()->current_ptr(),
                    "expected ',' or ')' after a type in the panic set",
                )
            }

            failed = true
            self._sync_panic_set()
            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            break
        }

        if !self.dyn()->check(TokenKind::OpRParen) {
            if !failed {
                self.dyn()->diag->report(
                    DiagID::S055E,
                    open.start,
                    "expected ')' to close the panic set",
                ).first(open, "opened here")->emit()
            }

            return
        }

        var close = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume `)`

        if out->size() == 0 && !failed {
            var b = self.dyn()->diag->report(
                DiagID::S055E,
                open.start,
                "an explicit panic set names at least one error type; a bare 'panic' has its set inferred",
            )

            b.first(open | close, "empty panic set")
            b.remove(open | close, "remove the empty list")
            b.emit()
        }
    }

    /// Recovery inside a panic set: skip to the next `,` or the closing `)`
    /// at this level, never past the rest of the header (`->`, the body's
    /// `{` or `=`, the end of the line), which the caller still parses.
    priv fn _sync_panic_set(self) {
        var depth: i32 = 0
        while !self.dyn()->is_eof() {
            var k = self.dyn()->ig_kind()
            if depth == 0 {
                if k == TokenKind::OpRParen
                    || k == TokenKind::OpComma
                    || k == TokenKind::OpArrow
                    || k == TokenKind::OpLBrace
                    || k == TokenKind::OpEqual
                    || k == TokenKind::OpSemicolon
                    || k == TokenKind::TkNewLine {
                    return
                }
            }

            if k == TokenKind::OpLParen || k == TokenKind::OpLSquare {
                ++depth
            } else if (k == TokenKind::OpRParen || k == TokenKind::OpRSquare) && depth > 0 {
                --depth
            }

            self.dyn()->advance()
        }
    }

    /// \brief parses the parameter type list for a function pointer type.
    ///
    /// \details handles the comma-separated list of types within `fn(...)`
    ///          pointer
    ///          syntax. unlike formal function declarations, function pointer
    ///          types do not support named parameters or default values.
    ///
    /// \param out buffer to collect successfully parsed parameter types.
    /// \param start_range the source location of the opening parenthesis, used
    ///        for
    ///                     error context if the list is never closed.
    ///
    /// \note if an `=` token is encountered, it is treated as a syntax error
    ///       (default
    ///       values are illegal in function pointer signatures) and the parser
    ///       synchronizes to the next parameter or the end of the list.
    ///
    /// \param modes parallel to \p out: one entry pushed with every type, so a
    ///        parameter dropped in recovery drops its mode too.
    inline fn _parse_fn_ptr_params(self,
                                   out:         unsafe *kairo::std::StackBuf<unsafe *Type, 8>,
                                   modes:       unsafe *kairo::std::StackBuf<ParamMode, 8>,
                                   start_range: SourceRange) {
        while !self.dyn()->is_eof() {
            if self.dyn()->check(TokenKind::OpRParen) {
                return
            }

            if self.dyn()->check(TokenKind::TkCodeComplete) {
                self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
                return
            }

            // function pointer types cannot have default values (e.g., `fn(u32 = 0)` is invalid).
            if self.dyn()->check(TokenKind::OpEqual) {
                self.dyn()->report_tok(
                    DiagID::S055E,
                    self.dyn()->current_ptr(),
                    "unexpected '=' in function pointer type parameter list, default values are not allowed here",
                )

                self._sync_type_progress(Self::TypeSyncCtx::Paren, 1, 0, 0, true)
                continue
            }

            // `fn(@inout T)`: the one type-shaped place a mode is legal. Taken
            // here so parse_type's mode-in-type rejection never sees it.
            var m = self.dyn()->_peek_mode()
            if m != ParamMode::Value {
                self.dyn()->_consume_mode()
            }

            var unsafe *param_ty = self.parse_type(false, true)
            if param_ty == &null || is_recovery(param_ty) {
                self._sync_type_progress(Self::TypeSyncCtx::Paren, 1, 0, 0)
                continue
            }

            out->push_back(param_ty)
            modes->push_back(m)

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After)
                continue
            }

            if !self.dyn()->check(TokenKind::OpRParen) {
                self.dyn()->report_tok(
                    DiagID::S055E,
                    self.dyn()->current_ptr(),
                    "expected ',' or ')' after parameter type in function pointer type",
                )

                self._sync_type(Self::TypeSyncCtx::Paren, 1, 0, 0, true)
            }
        }
    }

    inline fn _parse_variadic_type(self) -> unsafe *Types::VariadicPackType {
        // ...T, const ...T
        // cur token == `...`
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() // consume '...'

        if !self.dyn()->check(
            fn(k: TokenKind) -> bool {
                return Self::_is_type_tok_kind(k)
            },
        ) {
            self.dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "expected type parameter name after '...' for variadic pack type",
            ).first(start_range)->emit()
            return Types::VariadicPackType::create_error(self.dyn()->ctx, start_range)
        }

        var unsafe *chain = self._parse_qual_type()

        if chain == &null {
            self.dyn()->diag->report(
                DiagID::S053E,
                start_range.start,
                "expected type after '...' for variadic pack type",
            ).first(start_range)->emit()
            return Types::VariadicPackType::create_error(self.dyn()->ctx, start_range)
        }

        if is_recovery(chain) {
            return Types::VariadicPackType::create_error(
                self.dyn()->ctx,
                start_range | chain->range,
            )
        }

        // variadic pack must be a single unqualified name no generics, no scoping
        if !chain->is_simple() {
            self.dyn()->diag->report(
                DiagID::S055E,
                chain->range.start,
                "variadic pack type must be a single type parameter name, "
                "not a qualified or generic type path",
            ).first(chain->range)->emit()
            return Types::VariadicPackType::create_error(
                self.dyn()->ctx,
                start_range | chain->range,
            )
        }

        if chain->has_generic_args() {
            self.dyn()->diag->report(
                DiagID::S055E,
                chain->range.start,
                "variadic pack type cannot have generic arguments",
            ).first(chain->range)->emit()
            return Types::VariadicPackType::create_error(
                self.dyn()->ctx,
                start_range | chain->range,
            )
        }

        // wrap the identifier as a GenericParamType
        // param_index is 0 here sema resolves the actual index during
        // generic parameter binding when it matches this name against the
        // enclosing generic parameter list
        var unsafe *name_expr = chain->trailing_name()
        var gpt = Types::GenericParamType::create(
            self.dyn()->ctx,
            chain->range,
            name_expr,
            0,     // param_index placeholder, sema resolves
            true   // is_pack
        )

        var vpt = Types::VariadicPackType::create(self.dyn()->ctx, start_range | chain->range, gpt)
        return vpt
    }

    inline fn _parse_pack_expansion_type(self,
                                         ty: unsafe *Type) -> unsafe *Types::PackExpansionType {
        // current token is `...`
        if ty == &null {
            self.dyn()->report_tok(
                DiagID::I002F,
                self.dyn()->current_ptr(),
                "Fatal compiler bug, please raise an issue on our github at "
                "https://github.com/kairolang/kairo/issues "
                "along with the code to reproduce it",
            )

            return &null
        }

        var end_range = self.dyn()->current_ptr()->range
        self.dyn()->advance() //consume '...'

        if isa<Types::PackExpansionType>(ty) { // `T......` is not valid syntax
            self.dyn()->diag->report(
                DiagID::S055E,
                ty->range.start,
                "unexpected '...' after type in pack expansion type, '...' can only "
                "appear once in a pack expansion type declaration",
            ).first(ty->range)->emit()
            return Types::PackExpansionType::create_error(self.dyn()->ctx, ty->range)
        }

        if isa<Types::VariadicPackType>(ty) { // `...T...` is not valid syntax
            self.dyn()->diag->report(
                DiagID::S055E,
                ty->range.start,
                "unexpected '...' before type in pack expansion type, '...' can only "
                "appear once in a pack expansion type declaration",
            ).first(ty->range)->emit()
            return Types::PackExpansionType::create_error(self.dyn()->ctx, ty->range)
        }

        var pt = Types::PackExpansionType::create(self.dyn()->ctx, ty->range | end_range, ty)
        return pt
    }


    /// \brief parses a chain type starting from an identifier or builtin token.
    ///
    /// \details builds a `ChainType` with one or more segments. handles:
    ///   - simple names: `i32`, `Foo`
    ///   - scoped paths: `std::vec`, `Foo::Bar::Baz`
    ///   - generic instantiations: `Vec<i32>`, `Map<K, V>`
    ///   - named generic arguments: `Map<Key: str, Value: i32>`
    ///   - mixed chains: `std::Map<K, V>::Iterator<const K>`
    ///
    /// \return a new `ChainType` node. single-segment chains with no generics
    ///         will have `is_simple() == true` for sema fast-pathing.
    inline fn _parse_qual_type(self) -> unsafe *Types::ChainType {
        var start_range = self.dyn()->current_ptr()->range

        var segments: kairo::std::StackBuf<Types::ChainType::ChainSegment, 4>

        var seg = self._parse_chain_segment(Types::ChainType::SegmentSeparator::None)
        if seg.name == &null {
            return Types::ChainType::create_error(self.dyn()->ctx, start_range)
        }

        segments.push_back(seg)

        while self.dyn()->check(TokenKind::OpColonColon) {
            if self.owes_close() {
                break
            }

            var sep_range = self.dyn()->current_ptr()->range
            self.dyn()->advance() // consume `::`

            if self.dyn()->check(TokenKind::TkCodeComplete) {
                self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
                self.dyn()->advance(T::SkipNL::After)
                break
            }

            if !self.dyn()->check(
                fn(k: TokenKind) -> bool {
                    return Self::_is_type_tok_kind(k)
                },
            ) {
                self.dyn()->diag->report(
                    DiagID::S053E,
                    sep_range.start,
                    "expected identifier after '::' in type path",
                ).first(sep_range)->emit()
                break
            }

            var next_seg = self._parse_chain_segment(Types::ChainType::SegmentSeparator::ColonColon)
            if next_seg.name == &null {
                break
            }

            segments.push_back(next_seg)
        }

        var end_range  = self.dyn()->prev().range
        var full_range = start_range | end_range

        var ct = Types::ChainType::create(self.dyn()->ctx, full_range)
        ct->segments.from_buf(segments.data(), segments.size(), self.dyn()->ctx)

        return ct
    }

    /// \brief parses a single segment of a chain type: identifier + optional
    ///        generic argument list.
    ///
    /// \param sep  the separator that preceded this segment (`None` for first,
    ///             `ColonColon` for subsequent).
    /// \return a populated `ChainSegment`. `.name` is null on failure.
    inline fn _parse_chain_segment(self,
                                   sep: Types::ChainType::SegmentSeparator) -> Types::ChainType::ChainSegment {
        var result = Types::ChainType::ChainSegment{}
        result.sep           = sep
        result.seg_kind      = Types::ChainType::SegmentKind::Named
        result.resolved_type = &null
        result.resolved_decl = &null

        var id_ptr   = self.dyn()->current_ptr()
        var id_range = id_ptr->range
        // A builtin primitive takes no generic arguments, so a `<` after one
        // is never their opener: in `sizeof usize < 8` the operand is
        // `usize` and `<` compares (Compiler/Spec/Eval.md#deferred-conditions).
        var prim = sep == Types::ChainType::SegmentSeparator::None
            && builtin_for_token(self.dyn()->resolve_kind_deep(id_ptr)) != BuiltinKind::COUNT
        self.dyn()->advance() // consume identifier

        var nte = NamedIdentExpr::create(self.dyn()->ctx, id_range, *id_ptr)
        result.name  = nte
        result.range = id_range

        if !prim && self.dyn()->check(TokenKind::OpLess) {
            var generic_args: kairo::std::StackBuf<Types::ChainType::GenericArg, 4>
            self._parse_generic_args(unsafe &generic_args)

            result.generic_args.from_buf(generic_args.data(), generic_args.size(), self.dyn()->ctx)
            result.range = id_range | self.dyn()->prev().range

            if !generic_args.is_empty() {
                result.seg_kind = Types::ChainType::SegmentKind::GenericApp
            }
        }

        return result
    }

    /// \brief parses a generic argument list `<T1, T2, ..., TN>` with optional
    ///        named bindings `<Key: str, Value: i32>`.
    ///
    /// \details each argument is either:
    ///   - positional: a bare type like `i32` or `Vec<u8>`
    ///   - named: `Name: Type` matching a generic parameter name
    ///
    /// named and positional can be mixed; sema enforces ordering.
    ///
    /// \param out  buffer to collect parsed generic arguments.
    /// \return true if the argument list closed successfully.
    inline fn _parse_generic_args(
        self,
        out: unsafe *kairo::std::StackBuf<Types::ChainType::GenericArg, 4>,
    ) -> bool {
        var start_range = self.dyn()->current_ptr()->range
        self.dyn()->advance(T::SkipNL::After) // consume `<`
        self.dyn()->nl_push()                 // suppress newlines inside `< >`

        // a prior nested generic consumed >> and left one > for us
        if self.pay_close() {
            self.dyn()->nl_pop()
            return true
        }

        if self.dyn()->check(TokenKind::OpGreater) {
            self.dyn()->diag->report(
                DiagID::S049E,
                start_range.start,
                "expected at least one type argument in generic parameter list",
            ).first(start_range)->emit()
            self.dyn()->nl_pop()
            self.dyn()->advance_raw() // consume `>`
            return false
        }

        var angle_depth: u32 = 1

        while !self.dyn()->is_eof() && angle_depth > 0 {
            if self.dyn()->check(TokenKind::TkCodeComplete) {
                self.dyn()->maybe_complete(CompletionContextKind::TypeRef)
                self.dyn()->advance(T::SkipNL::After)
                self.dyn()->nl_pop()
                return false
            }

            // closers
            if self.dyn()->check(TokenKind::OpGreaterGreater) {
                if angle_depth == 1 {
                    self.owe_close()
                    self.dyn()->nl_pop()
                    self.dyn()->advance_raw()
                    return true
                }

                if angle_depth >= 2 {
                    angle_depth -= 2
                    self.dyn()->nl_pop()
                    self.dyn()->advance_raw()
                    return true
                }
            }

            if self.dyn()->check(TokenKind::OpGreater) {
                angle_depth -= 1
                self.dyn()->nl_pop()
                self.dyn()->advance_raw()
                return true
            }

            var arg = Types::ChainType::GenericArg{}
            arg.name       = &null
            arg.name_range = SourceRange::invalid()

            // named argument: `Ident :` but NOT `Ident ::` (which starts a scoped path)
            if self.dyn()->check(TokenKind::LitIdentifier)
                && self.dyn()->check_peek(TokenKind::OpColon)
                && !self.dyn()->check_peek(TokenKind::OpColonColon) {
                var name_ptr   = self.dyn()->current_ptr()
                var name_range = name_ptr->range
                self.dyn()->advance()                 // consume identifier
                self.dyn()->advance(T::SkipNL::After) // consume `:`

                arg.name       = NamedIdentExpr::create(self.dyn()->ctx, name_range, *name_ptr)
                arg.name_range = name_range
            }

            // speculatively parse the argument as a type. if it parses cleanly
            // but stops on an operator/postfix (not a `,`/`>`/`>>` terminator),
            // the argument was actually a value expression that merely begins
            // with a type-shaped token (`foo()`, `N + 1`); rewind and reparse it
            // as a value. literals/prefix-op values are already handled inside
            // parse_type via the gen_arg fall-through, so this only catches
            // identifier-led value exprs. a clean name parse emits no
            // diagnostics, so the rollback is side-effect free.
            var        saved = self.dyn()->tentative_begin()
            var unsafe *ty   = self.parse_type(false, true, true)
            if ty == &null {
                self.dyn()->diag->report(
                    DiagID::S049E,
                    start_range.start,
                    "expected type argument in generic parameter list",
                ).first(start_range)->emit()
                self._sync_generic_args(angle_depth)
                self.dyn()->nl_pop()
                return false
            }

            if is_recovery(ty) {
                self._sync_generic_args(angle_depth)
                self.dyn()->nl_pop()
                return false
            }

            // parse_type can leave the cursor parked ON a newline. check()
            // does NOT see through newlines even with nl_depth > 0 (only
            // advance() skips them), so without this the comma/closer checks
            // below test the newline token and wrongly fall through to the
            // "expected ',' or '>'" error -> whole generic list bails -> the
            // tentative guard rolls back -> `Lookup < string` reparses as `<`.
            self.dyn()->advance(T::SkipNL::Only) // skip NLs, do not move past real tokens

            // skip the value-continuation check when a nested generic already
            // consumed our closing `>>` (owes_close()): the list is
            // closing, so a trailing operator like the `=` of a var initializer
            // (`var v: Array<Foo<i32>> = ...`) is NOT part of this argument.
            if !self.owes_close() && self.dyn()->at_value_expr_continuation() {
                self.dyn()->tentative_rollback(saved)
                ty = self._parse_type_expr(
                    self.dyn()->stop_on(T::ExprStopKind::StopAngle).plus(
                        T::ExprStopKind::StopComma,
                    ),
                )

                if ty == &null || is_recovery(ty) {
                    self._sync_generic_args(angle_depth)
                    self.dyn()->nl_pop()
                    return false
                }

                self.dyn()->advance(T::SkipNL::Only) // skip NLs after the value expr
            }

            arg.ty = ty
            out->push_back(arg)

            // a nested generic consumed `>>` and with it our `>`: the list
            // is closed, so a `,` after it belongs to whatever holds the
            // type. Asked BEFORE the comma, or `f(k: *vec<vec<u8>>, b:
            // *vec<u8>)` read `, b: *vec<u8>` as more arguments of the
            // outer `vec` (S049E).
            if self.pay_close() {
                self.dyn()->nl_pop()
                return true
            }

            if self.dyn()->check(TokenKind::OpComma) {
                self.dyn()->advance(T::SkipNL::After) // consume `,`

                // trailing comma before closer
                if self.dyn()->check(TokenKind::OpGreater) {
                    angle_depth -= 1
                    self.dyn()->nl_pop()
                    self.dyn()->advance_raw()
                    return true
                }

                if self.dyn()->check(TokenKind::OpGreaterGreater) {
                    if angle_depth == 1 {
                        self.owe_close()
                        self.dyn()->nl_pop()
                        self.dyn()->advance_raw()
                        return true
                    }

                    if angle_depth >= 2 {
                        angle_depth -= 2
                        self.dyn()->nl_pop()
                        self.dyn()->advance_raw()
                        return true
                    }
                }

                continue
            }

            // a nested generic consumed >> and left a > for us
            if self.pay_close() {
                self.dyn()->nl_pop()
                return true
            }

            if !self.dyn()->check(TokenKind::OpGreater)
                && !self.dyn()->check(TokenKind::OpGreaterGreater) {
                self.dyn()->diag->report(
                    DiagID::S049E,
                    self.dyn()->prev().range.start,
                    "expected ',' or '>' after type argument in generic parameter list",
                ).first(self.dyn()->prev().range)->emit()
                self._sync_generic_args(angle_depth)
                self.dyn()->nl_pop()
                return false
            }
        }

        self.dyn()->nl_pop()
        return angle_depth == 0
    }

    /// \brief synchronizes past a malformed generic argument list.
    ///
    /// \details skips tokens tracking nested `<`/`>` pairs until a closer
    ///          or statement-level delimiter is found.
    ///
    /// \param angle_depth  current nesting depth of angle brackets.
    inline fn _sync_generic_args(self, angle_depth: u32) {
        var depth = angle_depth

        // No token budget: the scan ends at the closer, at a statement-level
        // delimiter or at EOF. A token cap is not safe: it parks the cursor
        // mid-construct, and a caller loop then makes no progress (a 30-deep
        // `A<A<...>>` list followed by a second one hangs that way).
        while !self.dyn()->is_eof() {
            var k = self.dyn()->ig_kind()

            if k == TokenKind::OpLess {
                ++depth
            } else if k == TokenKind::OpGreater {
                if depth <= 1 {
                    self.dyn()->advance()
                    return
                }

                --depth
            } else if k == TokenKind::OpGreaterGreater {
                if depth <= 2 {
                    self.dyn()->advance()
                    return
                }

                depth -= 2
            } else if k == TokenKind::OpSemicolon
                || k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare
                || k == TokenKind::OpRBrace {
                return // don't consume caller owns these
            }

            self.dyn()->advance()
        }
    }

    /// \brief parses a constant-expression for an array bound, e.g. the `N` in
    ///        `[T; N]`.
    ///
    /// \details delegates to the full expression parser so any value expression
    ///          is accepted as a bound: integer literals (`[T; 4]`), const names
    ///          (`[T; N]`), and folded operands (`[T; sizeof i32]`,
    ///          `[T; N + 1]`). `StopSquare|StopComma` keeps `parse_expr` from
    ///          consuming the closing `]` or a stray `,` (the caller diagnoses
    ///          the comma case). Whether the bound is a compile-time constant is
    ///          a semantic question deferred to sema; the parser only builds the
    ///          expression node.
    ///
    /// \return the size expression node, or `&null` if no expression could be
    ///         parsed.
    inline fn _parse_const_expr(self) -> unsafe *Expr {
        var expr = self.dyn()->parse_expr(
            self.dyn()->stop_on(T::ExprStopKind::StopSquare).plus(T::ExprStopKind::StopComma),
        )

        if expr == &null {
            self.dyn()->report_tok(
                DiagID::S055E,
                self.dyn()->current_ptr(),
                "expected constant expression for array size",
            )

            return &null
        }

        return expr
    }

    // The set's type spelled out, not T::ExprStop: a signature naming a
    // member of T is instantiated while T (the CRTP parser) is incomplete.
    inline fn _parse_type_expr(self, stop: FlagSet<ExprStopBit, u8>) -> unsafe *Types::TypeExpr {
        var expr = self.dyn()->parse_expr(stop)
        if expr == &null {
            self.dyn()->report_tok(
                DiagID::S053E,
                self.dyn()->current_ptr(),
                "expected a type or value expression",
            )

            return &null
        }

        if is_recovery(expr) {
            // the wrapped expr is itself a recovery node; create_error already
            // marks the TypeExpr as an error type. (no propagate_flags here: it
            // takes *Type/*Type and the child is an *Expr.)
            return Types::TypeExpr::create_error(self.dyn()->ctx, expr->range)
        }

        var te = Types::TypeExpr::create(self.dyn()->ctx, expr->range, expr)
        return te
    }

    inline fn _parse_nullable_type(self, ty: unsafe *Type) -> unsafe *Types::NullableType {
        // cur token is `?`
        var end_range = self.dyn()->current_ptr()->range
        if self.dyn()->check(TokenKind::OpQuestionQuestion) {
            self.dyn()->diag->report(
                DiagID::S055E,
                end_range.start,
                "unexpected '??' after type, did you mean to write a nullable type with a single '?'?",
            ).first(end_range)->emit()
            self._sync_type(Self::TypeSyncCtx::TopLevel, 0, 0, 0, true)
            return Types::NullableType::create_error(self.dyn()->ctx, end_range)
        }

        self.dyn()->advance() // consume '?'

        if ty == &null {
            self.dyn()->diag->report(
                DiagID::I002F,
                end_range.start,
                "Fatal compiler bug, please raise an issue on our github at "
                "https://github.com/kairolang/kairo/issues "
                "along with the code to reproduce it",
            ).emit()
            return &null
        }

        if is_recovery(ty) {
            var err_nt = Types::NullableType::create_error(self.dyn()->ctx, ty->range | end_range)
            Types::propagate_flags(err_nt, ty)
            return err_nt
        }

        // `(T?)?` is a real type, Nullable<Nullable<T>> (Compiler/Spec/Nullables.md#nested-nullables):
        // it is warned about, never collapsed -- a collapse here would make
        // the written type disagree with the same type reached by generic
        // substitution (`V?` with `V = T?`), which never collapses.
        if isa<Types::NullableType>(ty) {
            var b = self.dyn()->diag->report(
                DiagID::S055W,
                end_range.start,
                "nested nullable '(T?)?': legal and distinct from 'T?', but rarely what you want",
            )

            b.first(end_range)
            b.note(
                ty->range.start,
                "outside generic code this is usually a mistake; a single '?' is one level of null",
            )

            b.emit()
        }

        var nt = Types::NullableType::create(self.dyn()->ctx, ty->range | end_range, ty)
        return nt
    }
}




/*
[x] ChainType
[ ] GenericParamType
[ ] SubstGenericParamType
[x] TypeOfType // typeof TypeExpr
[x] VariadicPackType
[x] PackExpansionType
[x] PointerType
[x] TupleType
[x] FixedArrayType
[x] VectorType
[x] MapType
[x] SetType
[x] FunctionPointerType
[ ] InferredType
[ ] CXXLValueRefType
[ ] CXXRValueRefType
[ ] OpaqueFFIType
[ ] TypeExpr
[ ] SelfType
*/
