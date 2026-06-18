/// --- The Kairo Project ---------------- Compiler/Parser/TypeParse.k ----- ///
///
///   \brief Type expression parsing mixin.
///
///   \detail
///     Handles: *T, atomic T, Foo, Foo<T>, (T1, T2), (T) -> U
///     (const/atomic/unsafe/eval/async are TypeQual flags, not wrapper nodes)
///     Derives from ASTParse which provides: check, match_tok, expect, advance,
///     ctx, diag, is_eof, current, peek, prev, current_ptr,
///     consume_leading_quals, apply_quals, consume_leading_annotations,
///     apply_annotations_to_node, depth, etc.
///     --------------------------------------
///
///   Part of the Kairo Project, under the Apache License v2.0 with the Kairo
///   Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt SPDX-License-Identifier:
///   Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION Copyright (c) 2026 Kairo Software
///   Foundation
///
/// ----------------------------------------------------------------------- ///

import ASTNode::Base::*;
import ASTNode::Types::*;
import ASTNode::Casting::*;
import ASTNode::PrimaryExpressions::*;
import AST::CodeCompleteConsumer::*;
import AST::ASTContext::*;
import AST::Mixin::TypeQual::*;
import Diag::DiagEngine::*;
import Diag::DiagRegistry::*;
import Source::SourceRange::*;
import TokenKind::*;

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
class <T> TypeParse {
    var inferred_type_counter: u32 = 0;
    pub var _pending_close_angle: bool = false;
    
    const var TYPE_TOK_TBL: set::<TokenKind> = {
        TokenKind::AtVoid,
        TokenKind::AtBool,
        TokenKind::AtUsize,
        TokenKind::AtIsize,
        TokenKind::AtF16,
        TokenKind::AtF32,
        TokenKind::AtF64,
        TokenKind::AtF80,
        TokenKind::AtF128,
        TokenKind::AtF256,
        TokenKind::AtU8,
        TokenKind::AtU16,
        TokenKind::AtU32,
        TokenKind::AtU64,
        TokenKind::AtU128,
        TokenKind::AtU256,
        TokenKind::AtU512,
        TokenKind::AtI8,
        TokenKind::AtI16,
        TokenKind::AtI32,
        TokenKind::AtI64,
        TokenKind::AtI128,
        TokenKind::AtI256,
        TokenKind::AtI512,
        TokenKind::BiFile,
        TokenKind::BiLine,
        TokenKind::BiColumn,
        TokenKind::BiFunction,
        TokenKind::BiModule,
        TokenKind::LitIdentifier,
        TokenKind::KwSelf
    };

    enum TypeSyncCtx derives u8 {
        TopLevel,   // sync to newline, ;, EOF
        Paren,      // sync to ) at depth 0
        Square,     // sync to ] at depth 0
        Brace,      // sync to } at depth 0
        Comma,      // sync to , or the closing delimiter
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
    inline fn _sync_type(
        self,
        ctx:             TypeSyncCtx,
        paren_depth:     i32  = 0,
        square_depth:    i32  = 0,
        brace_depth:     i32  = 0,
        stop_at_newline: bool = false
    ) {
        var balance_paren:   i32 = paren_depth;
        var balance_square:  i32 = square_depth;
        var balance_brace:   i32 = brace_depth;
        var tokens_consumed: u32 = 0;
        const var MAX_SYNC:  u32 = 64;

        while !dyn()->is_eof() {
            if tokens_consumed >= MAX_SYNC { return; }
            ++tokens_consumed;

            var k = dyn()->current().kind;

            // hard stop: caller is recovering from an unclosed delimiter and
            // wants us to bail at the next newline rather than eat the next
            // top-level construct.
            if stop_at_newline && k == TokenKind::TkNewLine
            && balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                return;
            }

            if k == TokenKind::OpLParen {
                ++balance_paren;
            }
            else if k == TokenKind::OpLSquare {
                ++balance_square;
            }
            else if k == TokenKind::OpLBrace {
                ++balance_brace;
            }
            else if k == TokenKind::OpRParen {
                if balance_paren == 0 {
                    // closing delimiter at our level always stops us; caller
                    // owns the decision of whether to consume it.
                    return;
                }
                --balance_paren;
            }
            else if k == TokenKind::OpRSquare {
                if balance_square == 0 { return; }
                --balance_square;
            }
            else if k == TokenKind::OpRBrace {
                if balance_brace == 0 { return; }
                --balance_brace;
            }
            else if balance_paren == 0 && balance_square == 0 && balance_brace == 0 {
                // at depth zero across all delimiter kinds: stop on tokens
                // that end a type-position production.
                if k == TokenKind::OpComma {
                    if ctx == TypeSyncCtx::Comma
                    || ctx == TypeSyncCtx::Paren
                    || ctx == TypeSyncCtx::Square { return; }
                }
                if k == TokenKind::TkNewLine && ctx == TypeSyncCtx::TopLevel { return; }
                if k == TokenKind::OpSemicolon                               { return; }
                if k == TokenKind::OpArrow                                   { return; }
            }

            dyn()->advance();
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
    inline fn dyn(self) -> *T {
        return static_cast::<*T>(&self);
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
        return static_cast::<*Type>(ChainType::create_error(dyn()->ctx, range));
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
    fn parse_type(self, is_inferred: bool = false, skip_newline: bool = false, gen_arg: bool = false) -> *Type {
        if dyn()->is_eof() {
            return &null;
        }

        if !dyn()->enter_depth() {
            return &null;
        }

        if is_inferred {
            var prev_tok = dyn()->prev();

            if prev_tok.kind == TokenKind::TkUnknown {
                var cur_ptr = dyn()->current_ptr();
                var loc     = (cur_ptr->range.start) if (cur_ptr != &null) else SourceLocation();

                dyn()->diag->report(DiagID::S053E, loc, "unexpected start of input, expected expression").emit();
                dyn()->exit_depth();
                return &null;
            }

            var rt = InferredType::create(dyn()->ctx, prev_tok.range, inferred_type_counter);
            ++inferred_type_counter;

            dyn()->exit_depth();
            return rt;
        }

        inline "c++" {
            typename T::PendingAnnotations annot;
            typename T::PendingQuals       quals;
        }

        dyn()->consume_leading_annotations(&annot);
        dyn()->consume_leading_quals(&quals);

        var ty = self.parse_primary_type(skip_newline, gen_arg);
        if ty == &null {
            dyn()->exit_depth();
            return &null;
        }

        // secondary pass
        if (dyn()->check(TokenKind::OpQuestion)) || (dyn()->check(TokenKind::OpQuestionQuestion)) {
            ty = self._parse_nullable_type(ty);
        }

        else if dyn()->check(TokenKind::OpEllipsis) {
            ty = self._parse_pack_expansion_type(ty);
        }

        dyn()->apply_quals(ty, &quals);
        dyn()->apply_annotations_to_node(ty, &annot);

        dyn()->exit_depth();
        return ty;
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
    fn parse_primary_type(self, skip_newline: bool = false, gen_arg: bool = false) -> *Type {
        if dyn()->is_eof() { return &null; }

        if skip_newline {
            while dyn()->check(TokenKind::TkNewLine) {
                dyn()->advance(); // consume newlines
                if dyn()->is_eof() { return &null; }
            }
        }

        var cur_ptr = dyn()->current_ptr();
        if cur_ptr == &null { return &null; }

        var cur_range = cur_ptr->range;

        // pointer types: `*T`, `*const T`, etc.
        if dyn()->check(TokenKind::OpStar) {
            return self._parse_pointer_type();
        }

        // braced types: currently used for structural records or inline unions.
        if dyn()->check(TokenKind::OpLBrace) {
            return self._parse_braced_type();
        }

        // parenthesized types: `(T)` or tuple types `(T, U)`.
        if dyn()->check(TokenKind::OpLParen) {
            return self._parse_paren_type();
        }

        // square bracket types: arrays `[T; N]` or slices `[T]`.
        if dyn()->check(TokenKind::OpLSquare) {
            return self._parse_square_type();
        }

        // function pointer types: `fn(args) -> Ret`.
        if dyn()->check(TokenKind::KwFn) {
            return self._parse_fn_ptr_type();
        }

        if dyn()->check(TokenKind::OpEllipsis) {
            return self._parse_variadic_type();
        }

        if dyn()->check(TokenKind::BiSelf) {
            return self._parse_self_type();
        }

        if dyn()->check(TokenKind::KwTypeOf) {
            return self._parse_typeof_type();
        }

        if dyn()->check(TokenKind::TkCodeComplete) {
            dyn()->maybe_complete(CompletionContextKind::TypeRef);
            dyn()->advance(T::SkipNL::After); // consume code complete token and any newlines after it
            return self._error_type(cur_range);
        }

        // leaf types: built-ins (u32, f64, etc.), `Self`, or identifiers.
        if dyn()->check(fn(k: TokenKind) -> bool {
            return TYPE_TOK_TBL.contains(k);
        }) {
            return self._parse_qual_type();
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
                static_cast::<u8>(T::ExprStopKind::StopAngle)
              | static_cast::<u8>(T::ExprStopKind::StopComma)
            );
        }

        // no production matched; report error and attempt recovery.
        var resolved_kind = dyn()->resolve_kind_deep(cur_ptr);
        dyn()->diag->report(
            DiagID::S053E,
            cur_range.start,
            f"expected type, found '{token_kind_to_readable_string(resolved_kind)}\x27"
        ).first(cur_range).emit();

        dyn()->advance(); // skip offending token to prevent infinite loops during recovery.
        return _error_type(cur_range);
    }

    inline fn _parse_self_type(self) -> *SelfType {
        var tok = dyn()->current();
        var ty = SelfType::create(dyn()->ctx, tok.range);
        dyn()->advance(); // consume `Self`
        return ty;
    }

    inline fn _parse_typeof_type(self) -> *TypeOfType {
        var tok = dyn()->current();
        var start_range = tok.range;

        dyn()->advance(); // consume `typeof`

        var inner = dyn()->parse_expr();
        if inner == &null {
            dyn()->diag->report(DiagID::S053E, start_range.start,
                "expected type after 'typeof\x27"
            ).first(start_range).emit();

            return TypeOfType::create_error(dyn()->ctx, start_range);
        }

        var ty = TypeOfType::create(dyn()->ctx, start_range | inner->range, inner);
        return ty;
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
    inline fn _parse_paren_type(self) -> *Type {
        // precondition: current token is `(`
        var lparen_ptr  = dyn()->current_ptr();
        var start_range = lparen_ptr->range;

        dyn()->advance(T::SkipNL::After); // consume `(`

        // empty tuple: `()`
        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance(); // consume `)`
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "empty tuple types are not allowed, did you mean 'void'?"
            ).first(start_range).emit();

            var tt = TupleType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return tt;
        }

        var first = self.parse_type(false, true);
        if (first == &null) || (is_recovery(first)) {
            dyn()->diag->report(DiagID::S053E, start_range.start,
                "expected type after '(\x27"
            ).first(start_range).emit();

            self._sync_type(TypeSyncCtx::Paren, 1, 0, 0, true);
            return _error_type(start_range | dyn()->prev().range);
        }

        // tuple: `(T1, T2, ...)`
        if dyn()->check(TokenKind::OpComma) {
            return self._finish_tuple_type(start_range, first);
        }

        // grouping: `(T)` just unwrap
        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance(); // consume `)`
            return first;
        }

        // missing `)` emit diagnostic but still return what we parsed
        dyn()->diag->report(DiagID::S055E, start_range.start,
            "expected ')' after type in grouping expression "
        ).first(start_range).emit();

        return first;
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
    inline fn _finish_tuple_type(self, start_range: SourceRange, first: *Type) -> *TupleType {
        if !dyn()->enter_depth() {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "exceeded maximum nesting depth in tuple type"
            ).first(start_range).emit();

            return TupleType::create_error(dyn()->ctx, start_range);
        }

        var vals: std::StackBuf::<*Type, 8>;
        vals.push_back(first);

        while dyn()->check(TokenKind::OpComma) {
            dyn()->advance(T::SkipNL::After); // consume `,`

            if dyn()->check(TokenKind::OpRParen) {
                break;
            }

            if dyn()->check(TokenKind::TkNewLine) {
                // allow newlines between tuple elements for readability
                continue;
            }

            if dyn()->check(TokenKind::TkCodeComplete) {
                dyn()->maybe_complete(CompletionContextKind::TypeRef);
                dyn()->advance(T::SkipNL::After); // consume code complete token and any newlines after it
                break;
            }

            var elem = self.parse_type(false, true);
            if (elem == &null) || is_recovery(elem) {
                // no stop_at_newline we're mid-tuple, newlines are legal
                self._sync_type(TypeSyncCtx::Comma, 1);
                continue;
            }

            vals.push_back(elem);
        }

        var full_range = start_range | dyn()->prev().range;

        var comma_range: SourceRange;
        if dyn()->check_prev(TokenKind::OpComma) {
            comma_range = dyn()->prev().range;

            if dyn()->check(TokenKind::TkCodeComplete) {
                dyn()->maybe_complete(CompletionContextKind::TypeRef);
                dyn()->advance(T::SkipNL::After);
            }
        }

        dyn()->advance(T::SkipNL::Only); // consume any trailing newlines after the last element

        if dyn()->check(TokenKind::OpRParen) {
            full_range = full_range | dyn()->current_ptr()->range;
            dyn()->advance(T::SkipNL::Before); // consume `)`
        } else {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "expected ')' to close tuple type"
            ).first(start_range).emit();
        }

        /// \note Kairo requires tuples to have N >= 2 elements. single-element
        ///       parenthesized expressions are desugared to their inner type.
        if vals.size() == 1 {
            dyn()->diag->report(DiagID::S055E, full_range.start,
                "tuple types must contain at least two elements or more, did you "
                "mean to write '(T)' without the comma for a parenthesised type? "
            ).first(comma_range).fix(comma_range, "remove", "remove this comma to make it a parenthesised type")
            .emit();

            return TupleType::create_error(dyn()->ctx, full_range | dyn()->prev().range);
        }

        if vals.size() > dyn()->ctx->ci->frontend.max_tuple_arity {
            var range = vals[(dyn()->ctx->ci->frontend.max_tuple_arity)]->range;
            var endr  = vals[vals.size() - 1]->range;

            dyn()->diag->report(DiagID::S055E, range.start,
                f"tuple arity exceeds the maximum of {dyn()->ctx->ci->frontend.max_tuple_arity} (got {vals.size()})"
            ).first(range)
            .fix(range | endr, "remove", "reduce the number of elements in "
                                "this tuple type or increase the limit with "
                                "--cmax-tuple-arity")
            .strike(SourceRange::from_bounds(range.end, full_range.end))
            .emit();

            return TupleType::create_error(dyn()->ctx, full_range);
        }

        var tt = TupleType::create(dyn()->ctx, full_range);
        tt->elements.from_buf(vals.data(), vals.size(), dyn()->ctx);

        /// verify and merge type qualifiers/effects from child elements into
        /// the tuple node.
        for var i: usize = 0; i < tt->elements.size(); ++i {
            propagate_flags(tt, tt->elements[i]);
        }

        dyn()->exit_depth();
        return tt;
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
    inline fn _parse_square_type(self) -> *Type {
        // precondition: current token is `[`
        var lsquare_ptr = dyn()->current_ptr();
        var start_range = lsquare_ptr->range;
        dyn()->advance(T::SkipNL::After); // consume `[`

        if dyn()->check(TokenKind::OpRSquare) {
            dyn()->advance(); // consume `]`
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "empty arrays/vector types are not allowed, expected a type `[T]` or `[T; N]`"
            ).first(start_range).emit();
            var vt = VectorType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return vt;
        }

        if dyn()->check(TokenKind::TkCodeComplete) {
            dyn()->maybe_complete(CompletionContextKind::TypeRef);
            dyn()->advance(T::SkipNL::After); // consume code complete token and any newlines after it
            var vt = VectorType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return vt;
        }

        var elem_type = self.parse_type();
        dyn()->advance(T::SkipNL::Only); // consume any newlines after the element type

        if elem_type == &null {
            // this should never get called since we should
            // always be making a fully valid tree (even with broken nodes)
            dyn()->diag->report(DiagID::S053E, start_range.start,
                "expected type after '[\x27"
            ).first(start_range).emit();
            return &null;
        }

        if is_recovery(elem_type) {
            var err_st = VectorType::create_error(dyn()->ctx, start_range | elem_type->range);
            propagate_flags(err_st, elem_type);
            return err_st;
        }

        // common error, if we have a , in here this is invalid syntax, maybe they
        // meant to write a tuple type with parentheses instead of square brackets?
        if dyn()->check(TokenKind::OpComma) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "unexpected ',' in square bracket type, did you mean to use parentheses for a tuple type?"
            ).first(start_range).emit();
            return self._finish_array_type(start_range, elem_type, true); // in error state
        }

        if dyn()->check(TokenKind::OpColon) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "unexpected ':' in square bracket type, did you mean ';' for an array type with size '[T; N]'?"
            ).first(start_range).emit();
            return self._finish_array_type(start_range, elem_type, true); // in error state
        }

        if dyn()->check(TokenKind::OpSemicolon) {
            return self._finish_array_type(start_range, elem_type);
        }

        if !dyn()->check(TokenKind::OpRSquare) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "expected ']' after type in square brackets"
            ).first(start_range).emit();
            // try to sync to ']' to continue parsing
            self._sync_type(TypeSyncCtx::Square, 0, 1, 0, true);
            return VectorType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
        }

        dyn()->advance(T::SkipNL::Before); // consume `]`
        var full_range = start_range | dyn()->prev().range;

        var st = VectorType::create(dyn()->ctx, full_range, elem_type);
        propagate_flags(st, elem_type);
        return st;
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
    inline fn _finish_array_type(self, start_range: SourceRange, elem_type: *Type, is_error: bool = false) -> *FixedArrayType {
        // we are sitting on the `;` after parsing the element type in an array type like `[T; N]`
        // or we got here in error recovery after seeing a `,` which is not valid syntax for array types
        var semicolon_ptr   = dyn()->current_ptr();
        var semicolon_range = semicolon_ptr->range;
        dyn()->advance(T::SkipNL::After); // consume `;`

        if dyn()->check(TokenKind::OpRSquare) {
            if is_error {
                dyn()->diag->report(DiagID::S055E, semicolon_range.start,
                    "expected array size expression after ';' in array type"
                ).first(semicolon_range).emit();
                dyn()->advance();
                return FixedArrayType::create_error(dyn()->ctx, start_range | semicolon_range);
            }

            var rsquare_range = dyn()->current_ptr()->range;
            dyn()->advance();
            var arr = FixedArrayType::create_incomplete(
                dyn()->ctx,
                start_range | rsquare_range,
                elem_type
            );
            propagate_flags(arr, elem_type);
            return arr;
        }

        var size_expr = self._parse_const_expr();
        dyn()->advance(T::SkipNL::Only);

        if size_expr == &null {
            dyn()->diag->report(DiagID::S055E, semicolon_range.start,
                "expected constant expression for array size after ';' in array type"
            ).first(semicolon_range).emit();
            return &null;
        }

        // if we have a , here this is invalid syntax, maybe they meant to write a tuple type with parentheses instead of square brackets?
        if dyn()->check(TokenKind::OpComma) {
            dyn()->diag->report(DiagID::S055E, semicolon_range.start,
                "unexpected ',' in array type, did you mean to use parentheses for a tuple type?"
            ).first(semicolon_range).emit();
            self._sync_type(TypeSyncCtx::Square, 0, 1); // sync to closing `]` to continue parsing
            return FixedArrayType::create_error(dyn()->ctx, start_range | size_expr->range);
        }

        // check for ']'
        if !dyn()->check(TokenKind::OpRSquare) {
            dyn()->diag->report(DiagID::S055E, semicolon_range.start,
                "expected ']' after array size expression in array type"
            ).first(semicolon_range).emit();
            // try to sync to ']' to continue parsing
            self._sync_type(TypeSyncCtx::Square, 0, 1, 0, true);
            return FixedArrayType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
        }

        dyn()->advance(T::SkipNL::Before); // consume `]`
        var full_range = start_range | dyn()->prev().range;

        if is_error {
            var err_at        = FixedArrayType::create_error(dyn()->ctx, full_range);
            err_at->element   = elem_type;
            err_at->size_expr = size_expr;
            propagate_flags(err_at, elem_type);
            return err_at;
        }

        var at = FixedArrayType::create(dyn()->ctx, full_range, elem_type, size_expr);
        propagate_flags(at, elem_type);
        return at;
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
    inline fn _parse_braced_type(self) -> *Type {
        // precondition: current token is `{`
        var lbrace_ptr  = dyn()->current_ptr();
        var start_range = lbrace_ptr->range;

        dyn()->advance(T::SkipNL::After); // consume `{`

        // empty braced type: `{}`
        if dyn()->check(TokenKind::OpRBrace) {
            var r = start_range | dyn()->current_ptr()->range;

            dyn()->advance(); // consume `}`
            dyn()->diag->report(
                DiagID::S055E,
                start_range.start,
                "empty braced types are not allowed, use 'void' for empty or '{T}' for a set type"
            ).first(start_range).emit();

            return MapType::create_error(dyn()->ctx, r);
        }

        if dyn()->check(TokenKind::TkCodeComplete) {
            dyn()->maybe_complete(CompletionContextKind::TypeRef);
            dyn()->advance(T::SkipNL::After); // consume code complete token and any newlines after it

            var r      = start_range | dyn()->prev().range;
            var err_mt = MapType::create_error(dyn()->ctx, r);

            return err_mt;
        }

        var key_type = self.parse_type(false, true);
        dyn()->advance(T::SkipNL::Only);

        if key_type == &null {
            dyn()->diag->report(
                DiagID::S053E,
                start_range.start,
                "expected type after '{\x27"
            ).first(start_range).emit();

            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1, true);
            return _error_type(start_range);
        }

        if is_recovery(key_type) {
            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1, true);

            var err = SetType::create_error(dyn()->ctx, start_range | key_type->range);
            propagate_flags(err, key_type);

            return err;
        }

        // `{K: V}` map type
        if dyn()->check(TokenKind::OpColon) {
            return self._finish_map_type(start_range, key_type);
        }

        // common error: `{K; V}` semicolon instead of colon
        if dyn()->check(TokenKind::OpSemicolon) {
            dyn()->diag->report(
                DiagID::S055E,
                dyn()->current_ptr()->range.start,
                "unexpected ';' in braced type, did you mean ':' for a map type '{K: V}'?"
            ).first(dyn()->current_ptr()->range).emit();

            return self._finish_map_type(start_range, key_type, true);
        }

        // common error: `{K, V}` comma instead of colon, probably confused with tuple
        if dyn()->check(TokenKind::OpComma) {
            dyn()->diag->report(
                DiagID::S055E,
                dyn()->current_ptr()->range.start,
                "unexpected ',' in braced type, did you mean ':' for a map type '{K: V}\x27"
                "or '(' for a tuple type?"
            ).first(dyn()->current_ptr()->range).emit();

            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1);
            return SetType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
        }

        // `{T}` set type
        if dyn()->check(TokenKind::OpRBrace) {
            var full_range = start_range | dyn()->current_ptr()->range;
            dyn()->advance(T::SkipNL::Before); // consume `}`

            // FIXME: instead of having a custom node for set types, we could
            // directly desugar into kairo::core::Set<T> here in the parser.
            var st = SetType::create(dyn()->ctx, full_range, key_type);
            return st;
        }

        // missing `}` or `:`
        dyn()->diag->report(
            DiagID::S055E,
            start_range.start,
            "expected '}' to close set type or ':' to begin map type value"
        ).first(start_range).emit();

        self._sync_type(TypeSyncCtx::Brace, 0, 0, 1, true);

        return SetType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
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
    inline fn _finish_map_type(
        self,
        start_range: SourceRange,
        key_type:    *Type,
        is_error:    bool = false
    ) -> *MapType {
        // precondition: sitting on `:` (or `;` in error case, already diagnosed)
        var sep_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `:` or `;`

        // `{K:}` missing value type
        if dyn()->check(TokenKind::OpRBrace) {
            dyn()->diag->report(DiagID::S053E, sep_range.start,
                "expected value type after ':' in map type '{K: V}\x27"
            ).first(sep_range).emit();
            dyn()->advance(); // consume `}`
            var err = MapType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            propagate_flags(err, key_type);
            return err;
        }

        if dyn()->check(TokenKind::TkCodeComplete) {
            dyn()->maybe_complete(CompletionContextKind::TypeRef);
            dyn()->advance(T::SkipNL::After); // consume code complete token and any newlines after it
            var err = MapType::create_error(dyn()->ctx, start_range | sep_range);
            propagate_flags(err, key_type);
            return err;
        }

        var val_type = self.parse_type(false, true);
        dyn()->advance(T::SkipNL::Only);

        if val_type == &null {
            dyn()->diag->report(DiagID::S053E, sep_range.start,
                "expected value type after ':' in map type '{K: V}\x27"
            ).first(sep_range).emit();
            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1);
            var err = MapType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            propagate_flags(err, key_type);
            return err;
        }

        if is_recovery(val_type) {
            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1);
            var err = MapType::create_error(dyn()->ctx, start_range | val_type->range);
            propagate_flags(err, key_type);
            propagate_flags(err, val_type);
            return err;
        }

        // common error: `{K: V, ...}`
        if dyn()->check(TokenKind::OpComma) {
            dyn()->diag->report(DiagID::S055E, dyn()->current_ptr()->range.start,
                "unexpected ',' in map type, map types take exactly one key and one value type '{K: V}\x27"
            ).first(dyn()->current_ptr()->range).emit();
            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1);
            var err = MapType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            propagate_flags(err, key_type);
            propagate_flags(err, val_type);
            return err;
        }

        // common error: `{K: V: W}` double colon
        if dyn()->check(TokenKind::OpColon) {
            dyn()->diag->report(DiagID::S055E, dyn()->current_ptr()->range.start,
                "unexpected ':' in map type, expected '}' after value type"
            ).first(dyn()->current_ptr()->range).emit();
            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1);
            var err = MapType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            propagate_flags(err, key_type);
            propagate_flags(err, val_type);
            return err;
        }

        if !dyn()->check(TokenKind::OpRBrace) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "expected '}' to close map type"
            ).first(start_range).emit();
            self._sync_type(TypeSyncCtx::Brace, 0, 0, 1);
            var err = MapType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            propagate_flags(err, key_type);
            propagate_flags(err, val_type);
            return err;
        }

        var full_range = start_range | dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::Before); // consume `}`

        if is_error {
            var err = MapType::create_error(dyn()->ctx, full_range);
            err->key   = key_type;
            err->value = val_type;
            propagate_flags(err, key_type);
            propagate_flags(err, val_type);
            return err;
        }

        var mt = MapType::create(dyn()->ctx, full_range, key_type, val_type);
        return mt;
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
    inline fn _parse_pointer_type(self) -> *PointerType {
        // precondition: current token is `*`
        var star_ptr    = dyn()->current_ptr();
        var start_range = star_ptr->range;
        dyn()->advance(); // consume `*`

        if dyn()->check(TokenKind::TkCodeComplete) {
            dyn()->maybe_complete(CompletionContextKind::TypeRef);
            var err_pt = PointerType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
            return err_pt;
        }

        // parse_type() recurses handles `**T`, `*const T`, etc.
        // because parse_type() will see `const` as a qualifier and `*` as another pointer
        var pointee = self.parse_type();
        if pointee == &null {
            dyn()->diag->report(DiagID::S053E, start_range.start,
                "expected type after '*\x27"
            ).first(start_range).emit();

            return PointerType::create_error(dyn()->ctx, start_range);
        }

        var end_range = (pointee->range) if (pointee != &null) else start_range;
        if is_recovery(pointee) {
            var err_pt = PointerType::create_error(dyn()->ctx, start_range | end_range);
            propagate_flags(err_pt, pointee);
            return err_pt;
        }

        var pty = PointerType::create(
            dyn()->ctx,
            start_range | end_range,
            pointee
        );

        return pty;
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
    inline fn _parse_fn_ptr_type(self) -> *FunctionPointerType {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume `fn`

        if dyn()->check(TokenKind::OpLess) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "unexpected '<' after 'fn' in function pointer type, generic parameters are not supported here"
            ).first(start_range).emit();
            self._sync_type(TypeSyncCtx::TopLevel, 0, 0, 0, true);
            return FunctionPointerType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
        }

        if dyn()->check(fn (k: TokenKind) -> bool {
            return TYPE_TOK_TBL.contains(k);
        }) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "unexpected identifier after 'fn' in function pointer type, "
                "did you mean to write a function declaration?"
            ).first(start_range).emit();
            self._sync_type(TypeSyncCtx::TopLevel, 0, 0, 0, true);
            return FunctionPointerType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
        }

        // require `(`
        if !dyn()->check(TokenKind::OpLParen) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "expected '(' after 'fn' in function pointer type"
            ).first(start_range).emit();
            self._sync_type(TypeSyncCtx::TopLevel, 0, 0, 0, true);
            return FunctionPointerType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
        }
        dyn()->advance(T::SkipNL::After); // consume `(`

        var param_types: std::StackBuf::<*Type, 8>;

        if !dyn()->check(TokenKind::OpRParen) {
            self._parse_fn_ptr_params(&param_types, start_range);
        }

        // consume `)`
        if dyn()->check(TokenKind::OpRParen) {
            dyn()->advance();
        } else {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "expected ')' to close function pointer parameter list"
            ).first(start_range).emit();
            self._sync_type(TypeSyncCtx::Paren, 1, 0, 0, true);
        }

        // trailing qualifiers: fn(T) const panic async -> U
        inline "c++" { typename T::PendingQuals fn_quals; }
        dyn()->consume_leading_quals(&fn_quals);

        // optional return type
        var return_type: *Type = &null;
        if dyn()->check(TokenKind::OpArrow) {
            dyn()->advance(); // consume `->`
            return_type = self.parse_type();
            if (return_type == &null) || is_recovery(return_type) {
                var err = FunctionPointerType::create_error(dyn()->ctx, start_range | dyn()->prev().range);
                if return_type != &null {
                    propagate_flags(err, return_type);
                }
                return err;
            }
        }

        var fpt = FunctionPointerType::create(dyn()->ctx, start_range | dyn()->prev().range, return_type);
        fpt->params.from_buf(param_types.data(), param_types.size(), dyn()->ctx);
        dyn()->apply_quals(fpt, &fn_quals);
        return fpt;
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
    inline fn _parse_fn_ptr_params(self, out: *std::StackBuf::<*Type, 8>, start_range: SourceRange) {
        while !dyn()->is_eof() {
            if dyn()->check(TokenKind::OpRParen) {
                return;
            }

            if dyn()->check(TokenKind::TkCodeComplete) {
                dyn()->maybe_complete(CompletionContextKind::TypeRef);
                return;
            }

            // function pointer types cannot have default values (e.g., `fn(u32 = 0)` is invalid).
            if dyn()->check(TokenKind::OpEqual) {
                dyn()->diag->report(
                    DiagID::S055E,
                    dyn()->current_ptr()->range.start,
                    "unexpected '=' in function pointer type parameter list, default values are not allowed here"
                ).first(dyn()->current_ptr()->range).emit();

                self._sync_type(TypeSyncCtx::Paren, 1, 0, 0, true);
                continue;
            }

            var param_ty = self.parse_type(false, true);
            if (param_ty == &null) || is_recovery(param_ty) {
                self._sync_type(TypeSyncCtx::Paren, 1, 0, 0);
                continue;
            }
            out->push_back(param_ty);

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After);
                continue;
            }

            if !dyn()->check(TokenKind::OpRParen) {
                dyn()->diag->report(
                    DiagID::S055E,
                    dyn()->current_ptr()->range.start,
                    "expected ',' or ')' after parameter type in function pointer type"
                ).first(dyn()->current_ptr()->range).emit();

                self._sync_type(TypeSyncCtx::Paren, 1, 0, 0, true);
            }
        }
    }

    inline fn _parse_variadic_type(self) -> *VariadicPackType {
        // ...T, const ...T
        // cur token == `...`
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(); // consume '...'

        if !dyn()->check(fn(k: TokenKind) -> bool {
            return TYPE_TOK_TBL.contains(k);
        }) {
            dyn()->diag->report(DiagID::S055E, start_range.start,
                "expected type parameter name after '...' for variadic pack type"
            ).first(start_range).emit();
            return VariadicPackType::create_error(dyn()->ctx, start_range);
        }

        var chain = self._parse_qual_type();

        if chain == &null {
            dyn()->diag->report(DiagID::S053E, start_range.start,
                "expected type after '...' for variadic pack type"
            ).first(start_range).emit();
            return VariadicPackType::create_error(dyn()->ctx, start_range);
        }

        if is_recovery(chain) {
            return VariadicPackType::create_error(dyn()->ctx, start_range | chain->range);
        }

        // variadic pack must be a single unqualified name no generics, no scoping
        if !chain->is_simple() {
            dyn()->diag->report(DiagID::S055E, chain->range.start,
                "variadic pack type must be a single type parameter name, "
                "not a qualified or generic type path"
            ).first(chain->range).emit();
            return VariadicPackType::create_error(dyn()->ctx, start_range | chain->range);
        }

        if chain->has_generic_args() {
            dyn()->diag->report(DiagID::S055E, chain->range.start,
                "variadic pack type cannot have generic arguments"
            ).first(chain->range).emit();
            return VariadicPackType::create_error(dyn()->ctx, start_range | chain->range);
        }

        // wrap the identifier as a GenericParamType
        // param_index is 0 here sema resolves the actual index during
        // generic parameter binding when it matches this name against the
        // enclosing generic parameter list
        var name_expr = chain->trailing_name();
        var gpt = GenericParamType::create(
            dyn()->ctx,
            chain->range,
            name_expr,
            0,     // param_index placeholder, sema resolves
            true   // is_pack
        );

        var vpt = VariadicPackType::create(dyn()->ctx, start_range | chain->range, gpt);
        return vpt;
    }

    inline fn _parse_pack_expansion_type(self, ty: *Type) -> *PackExpansionType {
        // current token is `...`
        if (ty == &null) {
            dyn()->diag->report(DiagID::S055E, dyn()->current_ptr()->range.start,
                "Fatal compiler bug, please raise an issue on our github at "
                "https://github.com/kairolang/kairo/issues "
                "along with the code to reproduce it"
            ).emit();
            return &null;
        }
        
        var end_range = dyn()->current_ptr()->range;
        dyn()->advance(); //consume '...'

        if isa::<PackExpansionType>(ty) { // `T......` is not valid syntax
            dyn()->diag->report(DiagID::S055E, ty->range.start,
                "unexpected '...' after type in pack expansion type, '...' can only "
                "appear once in a pack expansion type declaration"
            ).first(ty->range).emit();
            return PackExpansionType::create_error(dyn()->ctx, ty->range);
        }

        if isa::<VariadicPackType>(ty) { // `...T...` is not valid syntax
            dyn()->diag->report(DiagID::S055E, ty->range.start,
                "unexpected '...' before type in pack expansion type, '...' can only "
                "appear once in a pack expansion type declaration"
            ).first(ty->range).emit();
            return PackExpansionType::create_error(dyn()->ctx, ty->range);
        }
        
        var pt = PackExpansionType::create(dyn()->ctx, ty->range | end_range, ty);
        return pt;
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
    inline fn _parse_qual_type(self) -> *ChainType {
        var start_range = dyn()->current_ptr()->range;

        var segments: std::StackBuf::<ChainType::ChainSegment, 4>;

        var seg = self._parse_chain_segment(ChainType::SegmentSeparator::None);
        if seg.name == &null {
            return ChainType::create_error(dyn()->ctx, start_range);
        }
        segments.push_back(seg);

        while dyn()->check(TokenKind::OpColonColon) {
            if self._pending_close_angle {
                break;
            }

            var sep_range = dyn()->current_ptr()->range;
            dyn()->advance(); // consume `::`

            if dyn()->check(TokenKind::TkCodeComplete) {
                dyn()->maybe_complete(CompletionContextKind::TypeRef);
                dyn()->advance(T::SkipNL::After);
                break;
            }

            if !dyn()->check(fn(k: TokenKind) -> bool {
                return TYPE_TOK_TBL.contains(k);
            }) {
                dyn()->diag->report(DiagID::S053E, sep_range.start,
                    "expected identifier after '::' in type path"
                ).first(sep_range).emit();
                break;
            }

            var next_seg = self._parse_chain_segment(ChainType::SegmentSeparator::ColonColon);
            if next_seg.name == &null {
                break;
            }
            segments.push_back(next_seg);
        }

        var end_range = dyn()->prev().range;
        var full_range = start_range | end_range;

        var ct = ChainType::create(dyn()->ctx, full_range);
        ct->segments.from_buf(segments.data(), segments.size(), dyn()->ctx);

        return ct;
    }

    /// \brief parses a single segment of a chain type: identifier + optional
    ///        generic argument list.
    ///
    /// \param sep  the separator that preceded this segment (`None` for first,
    ///             `ColonColon` for subsequent).
    /// \return a populated `ChainSegment`. `.name` is null on failure.
    inline fn _parse_chain_segment(self, sep: ChainType::SegmentSeparator) -> ChainType::ChainSegment {
        var result = ChainType::ChainSegment{};
        result.sep           = sep;
        result.seg_kind      = ChainType::SegmentKind::Named;
        result.resolved_type = &null;
        result.resolved_decl = &null;

        var id_ptr   = dyn()->current_ptr();
        var id_range = id_ptr->range;
        dyn()->advance(); // consume identifier

        var nte = NamedIdentExpr::create(dyn()->ctx, id_range, *id_ptr);
        result.name  = nte;
        result.range = id_range;

        if dyn()->check(TokenKind::OpLess) {
            var generic_args: std::StackBuf::<ChainType::GenericArg, 4>;
            self._parse_generic_args(&generic_args);

            result.generic_args.from_buf(generic_args.data(), generic_args.size(), dyn()->ctx);
            result.range = id_range | dyn()->prev().range;

            if !generic_args.is_empty() {
                result.seg_kind = ChainType::SegmentKind::GenericApp;
            }
        }

        return result;
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
    inline fn _parse_generic_args(self, out: *std::StackBuf::<ChainType::GenericArg, 4>) -> bool {
        var start_range = dyn()->current_ptr()->range;
        dyn()->advance(T::SkipNL::After); // consume `<`
        dyn()->nl_push();                 // suppress newlines inside `< >`

        // a prior nested generic consumed >> and left one > for us
        if self._pending_close_angle {
            self._pending_close_angle = false;
            dyn()->nl_pop();
            return true;
        }

        if dyn()->check(TokenKind::OpGreater) {
            dyn()->diag->report(DiagID::S049E, start_range.start,
                "expected at least one type argument in generic parameter list"
            ).first(start_range).emit();
            dyn()->nl_pop();
            dyn()->advance_raw(); // consume `>`
            return false;
        }

        var angle_depth: u32 = 1;

        while !dyn()->is_eof() && angle_depth > 0 {
            if  dyn()->check(TokenKind::TkCodeComplete) {
                dyn()->maybe_complete(CompletionContextKind::TypeRef);
                dyn()->advance(T::SkipNL::After);
                dyn()->nl_pop();
                return false;
            }

            // closers
            if dyn()->check(TokenKind::OpGreaterGreater) {
                if angle_depth == 1 {
                    self._pending_close_angle = true;
                    dyn()->nl_pop();
                    dyn()->advance_raw();
                    return true;
                }
                if angle_depth >= 2 {
                    angle_depth -= 2;
                    dyn()->nl_pop();
                    dyn()->advance_raw();
                    return true;
                }
            }

            if dyn()->check(TokenKind::OpGreater) {
                angle_depth -= 1;
                dyn()->nl_pop();
                dyn()->advance_raw();
                return true;
            }

            var arg = ChainType::GenericArg{};
            arg.name       = &null;
            arg.name_range = SourceRange::invalid();

            // named argument: `Ident :` but NOT `Ident ::` (which starts a scoped path)
            if (dyn()->check(TokenKind::LitIdentifier))
            && (dyn()->check_peek(TokenKind::OpColon))
            && (!dyn()->check_peek(TokenKind::OpColonColon)) {
                var name_ptr   = dyn()->current_ptr();
                var name_range = name_ptr->range;
                dyn()->advance(); // consume identifier
                dyn()->advance(T::SkipNL::After); // consume `:`

                arg.name       = NamedIdentExpr::create(dyn()->ctx, name_range, *name_ptr);
                arg.name_range = name_range;
            }

            var ty = self.parse_type(false, true, true);
            if ty == &null {
                dyn()->diag->report(DiagID::S049E, start_range.start,
                    "expected type argument in generic parameter list"
                ).first(start_range).emit();
                self._sync_generic_args(angle_depth);
                dyn()->nl_pop();
                return false;
            }

            if is_recovery(ty) {
                self._sync_generic_args(angle_depth);
                dyn()->nl_pop();
                return false;
            }

            arg.ty = ty;
            out->push_back(arg);

            // parse_type can leave the cursor parked ON a newline. check()
            // does NOT see through newlines even with nl_depth > 0 (only
            // advance() skips them), so without this the comma/closer checks
            // below test the newline token and wrongly fall through to the
            // "expected ',' or '>'" error -> whole generic list bails -> the
            // tentative guard rolls back -> `Lookup < string` reparses as `<`.
            dyn()->advance(T::SkipNL::Only); // skip NLs, do not move past real tokens

            if dyn()->check(TokenKind::OpComma) {
                dyn()->advance(T::SkipNL::After); // consume `,`

                // trailing comma before closer
                if dyn()->check(TokenKind::OpGreater) {
                    angle_depth -= 1;
                    dyn()->nl_pop();
                    dyn()->advance_raw();
                    return true;
                }
                if dyn()->check(TokenKind::OpGreaterGreater) {
                    if angle_depth == 1 {
                        self._pending_close_angle = true;
                        dyn()->nl_pop();
                        dyn()->advance_raw();
                        return true;
                    }
                    if angle_depth >= 2 {
                        angle_depth -= 2;
                        dyn()->nl_pop();
                        dyn()->advance_raw();
                        return true;
                    }
                }

                continue;
            }

            // a nested generic consumed >> and left a > for us
            if self._pending_close_angle {
                self._pending_close_angle = false;
                dyn()->nl_pop();
                return true;
            }

            if (!dyn()->check(TokenKind::OpGreater)) && (!dyn()->check(TokenKind::OpGreaterGreater)) {
                dyn()->diag->report(DiagID::S049E, dyn()->prev().range.start,
                    "expected ',' or '>' after type argument in generic parameter list"
                ).first(dyn()->prev().range).emit();
                self._sync_generic_args(angle_depth);
                dyn()->nl_pop();
                return false;
            }
        }

        dyn()->nl_pop();
        return angle_depth == 0;
    }

    /// \brief synchronizes past a malformed generic argument list.
    ///
    /// \details skips tokens tracking nested `<`/`>` pairs until a closer
    ///          or statement-level delimiter is found.
    ///
    /// \param angle_depth  current nesting depth of angle brackets.
    inline fn _sync_generic_args(self, angle_depth: u32) {
        var depth = angle_depth;
        var tokens_consumed: u32 = 0;
        const var MAX_SYNC: u32 = 64;

        while !dyn()->is_eof() && tokens_consumed < MAX_SYNC {
            ++tokens_consumed;
            var k = dyn()->current().kind;

            if k == TokenKind::OpLess {
                ++depth;
            }
            else if k == TokenKind::OpGreater {
                if depth <= 1 {
                    dyn()->advance();
                    return;
                }
                --depth;
            }
            else if k == TokenKind::OpGreaterGreater {
                if depth <= 2 {
                    dyn()->advance();
                    return;
                }
                depth -= 2;
            }
            else if k == TokenKind::OpSemicolon
                || k == TokenKind::OpRParen
                || k == TokenKind::OpRSquare
                || k == TokenKind::OpRBrace {
                return; // don't consume caller owns these
            }

            dyn()->advance();
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
    inline fn _parse_const_expr(self) -> *Expr {
        var expr = dyn()->parse_expr(static_cast::<T::ExprStopKind>(
            static_cast::<u8>(T::ExprStopKind::StopSquare)
          | static_cast::<u8>(T::ExprStopKind::StopComma)
        ));

        if expr == &null {
            dyn()->diag->report(
                DiagID::S055E,
                dyn()->current_ptr()->range.start,
                "expected constant expression for array size"
            ).first(dyn()->current_ptr()->range).emit();

            return &null;
        }

        return expr;
    }

    inline fn _parse_type_expr(self, stop_bits: u8 = 0) -> *TypeExpr {
        var expr = dyn()->parse_expr(static_cast::<T::ExprStopKind>(stop_bits));
        if expr == &null {
            dyn()->diag->report(
                DiagID::S053E,
                dyn()->current_ptr()->range.start,
                "expected a type or value expression"
            ).first(dyn()->current_ptr()->range).emit();
            return &null;
        }

        if is_recovery(expr) {
            // the wrapped expr is itself a recovery node; create_error already
            // marks the TypeExpr as an error type. (no propagate_flags here: it
            // takes *Type/*Type and the child is an *Expr.)
            return TypeExpr::create_error(dyn()->ctx, expr->range);
        }

        var te = TypeExpr::create(dyn()->ctx, expr->range, expr);
        return te;
    }

    inline fn _parse_nullable_type(self, ty: *Type) -> *NullableType {
        // cur token is `?`
        var end_range = dyn()->current_ptr()->range;
        if dyn()->check(TokenKind::OpQuestionQuestion) {
            dyn()->diag->report(DiagID::S055E, end_range.start,
                "unexpected '??' after type, did you mean to write a nullable type with a single '?'?"
            ).first(end_range).emit();
            self._sync_type(TypeSyncCtx::TopLevel, 0, 0, 0, true);
            return NullableType::create_error(dyn()->ctx, end_range);
        }

        dyn()->advance(); // consume '?'

        if ty == &null {
            dyn()->diag->report(DiagID::S055E, end_range.start,
                "Fatal compiler bug, please raise an issue on our github at "
                "https://github.com/kairolang/kairo/issues "
                "along with the code to reproduce it"
            ).emit();
            return &null;
        }

        if is_recovery(ty) {
            var err_nt = NullableType::create_error(dyn()->ctx, ty->range | end_range);
            propagate_flags(err_nt, ty);
            return err_nt;
        }

        if isa::<NullableType>(ty) {
            dyn()->diag->report(DiagID::S055W, end_range.start,
                "redundant '?': type is already nullable"
            ).first(end_range).emit();
            return cast::<NullableType>(ty);
        }

        var nt = NullableType::create(dyn()->ctx, ty->range | end_range, ty);
        return nt;
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
