/// --- The Kairo Project ---------------- AST/Node/PrimaryExpressions.k --- ///
///
///   Primary expression AST nodes: names, member chains and literals.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// -------------------------------------------------------------------------- ///

ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "Native/Types.hh"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::ASTContext::ASTContext
import AST::Context::SymbolTable::OverloadCell
import AST::Kind::ExprKind::ExprKind
import AST::LangItems::FormatKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Types::ChainType
import Lexer::ImmBig::{
    ImmBigFloat,
    ImmBigInt,
}
import Lexer::Immediate::Immediate
import Location::SourceRange::SourceRange
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer
import Token::TokenText::TokenText

///
///  NamedIdentExpr
///  A single identifier in expression position, optionally carrying generic
///  arguments for bare generic usage like `Bar<i32>(x)`.
///
///  `self` is represented as a NamedIdentExpr   sema identifies it by name.
///
///  examples:
///    foo            bare identifier, no generics
///    Bar<i32>       generic instantiation on a bare name
///    self           self reference, sema resolves contextually
///
pub class NamedIdentExpr derives Expr {
    pub var name:         Token
    pub var generic_args: FrozenList<ChainType::GenericArg>
    pub var ctx:          unsafe *ASTContext                ///< for TokenText::get_name()

    /// Name-resolution result. Exactly three legal states after phase N:
    ///   unique binding:  resolved_decl set, candidate_cell null.
    ///   overload set:    candidate_cell set (points INTO the frozen
    ///                    SymbolTable never a copy), resolved_decl null
    ///                    until type-directed overload resolution picks the
    ///                    winner and promotes it.
    ///   failure:         both null, node poisoned, one diagnostic (N(b)).
    /// One-writer rule: N writes these; inference promotes cell -> decl;
    /// nobody else touches them.
    pub var resolved_decl:  unsafe *Decl         = &null
    pub var candidate_cell: unsafe *OverloadCell = &null

    /// The EnumVariantDecl this name builds: a payload-less ADT variant named
    /// bare as a value (`None` inside its enum), which is a construction. Null
    /// everywhere else, a plain enum's variant included: that is the value
    /// `resolved_decl` already names. One writer: X (ControlTyping); read
    /// through variant_decl_of (Expressions.k).
    pub var variant_decl: unsafe *Decl = &null

    /// A narrowed read (Compiler/Spec/Nullables.md#narrowed-reads): this use names a `T?` place the
    /// nullness analysis proved non-null where the value is needed, so it
    /// is typed `T` and this holds the `T?` it was. Null for every other
    /// use. One writer: X (NullnessFlow::read_value); one reader that acts
    /// on it, NarrowedAccessLowering, which makes the use `x.__value()`.
    pub var narrowed_from: unsafe *Type = &null

    /// This use names a variable an enclosing closure captures by pointer
    /// (`|*x|`, `|*|`), so it is typed as that pointer (ExprTyper::
    /// _capture_view): the name is the pointer, no nullness place, and `*x`
    /// is the place of the variable it points at (null_place_of, Compiler/Spec/Nullables.md
    /// 3.7). One writer: X (ExprTyper::_type_ident).
    pub var capture_ptr: bool = false

    pub fn is_bound(self) -> bool {
        return self.resolved_decl != &null
    }

    pub fn is_deferred(self) -> bool {
        return self.resolved_decl == &null && self.candidate_cell != &null
    }

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         name:  Token) -> unsafe *NamedIdentExpr {
        var unsafe *node = ctx->alloc<NamedIdentExpr>()
        node->kind          = ExprKind::NamedIdentExpr
        node->range         = range
        node->name          = name
        node->ctx           = ctx
        node->variant_decl  = &null
        node->narrowed_from = &null
        node->capture_ptr   = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx:   unsafe *ASTContext,
                           range: SourceRange,
                           name:  Token) -> unsafe *NamedIdentExpr {
        var unsafe *node = Self::create(ctx, range, name)
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::NamedIdentExpr
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::NamedIdentExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::NamedIdentExpr
    }

    fn get_name(self) -> TokenText {
        return self.ctx->get_token_text(self.name)
    }
}

///
///  ChainExpr
///  Pure access chain: field access, scope resolution, pointer member access,
///  safe-navigation, and generic instantiation on accessed names.
///
///  No calls, no subscripts those are separate nodes (CallExpr, SubscriptExpr)
///  that wrap this as their base/callee.
///
///  examples:
///    foo.bar         base=NamedIdentExpr("foo"), 1 step (Dot, "bar")
///    foo::bar::baz   base=NamedIdentExpr("foo"), 2 steps (ColonColon)
///    foo::bar::<T>   base=NamedIdentExpr("foo"), 1 step with generic_args
///    foo?.bar->baz   base=NamedIdentExpr("foo"), 2 steps (QuestionDot, Arrow)
///    ::std::print    base=null (global root), 2 steps (ColonColon)
///    (expr).field    base=any Expr, 1 step (Dot)
///
pub class ChainExpr derives Expr {
    /// \enum AccessKind
    /// \brief the separator/operator for an access step.
    ///
    /// \note the pointer-to-member family (`.*` `->*` `?.*` `?->*`) is NOT
    ///       here. Those are binary operators at their own precedence level
    ///       (Precedence::PtrToMember), not access separators: they take a
    ///       full cast-expression on the right, not an id-expression, so they
    ///       lower to BinaryOperatorExpr and never reach a Step.
    pub enum AccessKind derives u8 {
        Dot,           ///< `.`
        Arrow,         ///< `->`
        ColonColon,    ///< `::`
        QuestionDot,   ///< `?.`
        QuestionArrow, ///< `?->`
    }

    /// \enum StepTarget
    /// \brief what this step names. `access_kind` is the separator; this is
    ///        the thing on the right of it.
    pub enum StepTarget derives u8 {
        Name,       ///< an identifier `name` is set
        Operator,   ///< an overloaded operator `op_tokens` is set
        TupleIndex, ///< a tuple element ordinal `index` is set
    }

    /// \class Step
    /// \brief a single access operation in the chain.
    pub class Step {
        /// the identifier being accessed. set only when `target` is `Name`;
        /// null for an operator step (`Foo::op+` / `a->op[]`) and for a tuple
        /// index (`t.0`), neither of which names an identifier.
        pub var name: unsafe *NamedIdentExpr

        /// what this step names. selects which of `name` / `op_tokens` /
        /// `index` carries the target; never says anything about the separator.
        pub var target: StepTarget = StepTarget::Name

        /// the operator spelling tokens when `target` is `Operator`. up to two
        /// tokens (e.g. `[` `]`, `l` `++`). empty otherwise. mirrors
        /// FunctionDecl::op_token.
        pub var op_tokens: FrozenList<Token>

        /// generic arguments on this step, e.g. `bar::<i32, bool>`.
        /// empty if no generic args. reuses GenericArg from ChainType.
        pub var generic_args: FrozenList<ChainType::GenericArg>

        /// source range covering the separator and the identifier.
        pub var range: SourceRange

        /// the access operator used to reach this step.
        pub var access_kind: AccessKind

        /// tuple element ordinal when `target` is `TupleIndex`. meaningless
        /// otherwise.
        pub var index: u32 = 0

        /// A pack-expanded variant's payload member (EnumLayoutQuery::
        /// payload_ref): the pack element this step reads, which EmitIR
        /// spells after the member as its getter; -1 on every other step.
        pub var pack_index: i32 = -1

        /// resolved type of this step's result. set by sema, null before.
        pub var resolved_type: unsafe *Type

        /// resolved declaration this step refers to. set by sema, null before.
        pub var resolved_decl: unsafe *Decl

        /// deferred overload set for this step: points INTO the frozen
        /// SymbolTable when overload resolution needs type info to pick.
        /// Same three-state contract as NamedIdentExpr::candidate_cell.
        pub var candidate_cell: unsafe *OverloadCell = &null

        /// The step's `T?` when the field path up to and including this
        /// step is a narrowed read (Compiler/Spec/Nullables.md#narrowed-reads, as on NamedIdentExpr):
        /// `resolved_type` is then the `T`, and NarrowedAccessLowering
        /// splits the chain after this step around a `__value()` call.
        pub var narrowed_from: unsafe *Type = &null

        /// The record a `::` step's member is named THROUGH, when that
        /// record is a generic one's instance (`Box<i32>::count`,
        /// `L<i32>::P::k`) or a pattern used dependently (`Box<T>::count`
        /// in a generic body); null otherwise. The member's decl is the
        /// pattern's (an instance shell has no members of its own), so the
        /// decl alone spells `Box::count`, a class template with no
        /// arguments. The value-chain counterpart of CallExpr::qualifier.
        /// One writer: X (MemberTyping); EmitIR spells the step through it
        /// and EmitPlan admits it Complete.
        pub var through: unsafe *Type = &null

        /// A `::` step naming a STATIC requirement through a bounded head
        /// (`A::make` as a value, A impl I): the declaring interface's
        /// canonical instance and Self, as CallExpr::witness_iface /
        /// witness_self are for a call. The requirement is no C++ function;
        /// EmitIR spells the witness's member. One writer: ExtensionLowering.
        pub var witness_iface: unsafe *Type = &null
        pub var witness_self:  unsafe *Type = &null

        pub fn is_operator(self) -> bool {
            return self.target == StepTarget::Operator
        }

        pub fn is_tuple_index(self) -> bool {
            return self.target == StepTarget::TupleIndex
        }
    }

    /// the root expression of the chain. any primary expression.
    /// null only for global-root paths (`::std::print`).
    pub var base: unsafe *Expr
    pub var ctx:  unsafe *ASTContext

    /// zero or more postfix access operations.
    pub var steps: FrozenList<Self::Step>

    /// The EnumVariantDecl this path builds when its last step names a
    /// payload-less ADT variant as a value (`Opt::None`, `Opt<i32>::None`).
    /// Null for a head (`Shape::Rect` before its braces) and for a plain
    /// enum's variant, which is the value it names. One writer: X
    /// (ControlTyping); read through variant_decl_of (Expressions.k).
    pub var variant_decl: unsafe *Decl = &null

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         base:  unsafe *Expr) -> unsafe *ChainExpr {
        var unsafe *node = ctx->alloc<ChainExpr>()
        node->kind         = ExprKind::ChainExpr
        node->range        = range
        node->base         = base
        node->ctx          = ctx
        node->variant_decl = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /// global-root chain: `::std::print` no base expression.
    pub static fn create_global(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *ChainExpr {
        var unsafe *node = ctx->alloc<ChainExpr>()
        node->kind         = ExprKind::ChainExpr
        node->range        = range
        node->base         = &null
        node->ctx          = ctx
        node->variant_decl = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *ChainExpr {
        var unsafe *node = ctx->alloc<ChainExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::ChainExpr
        node->range         = range
        node->base          = &null
        node->ctx           = ctx
        node->variant_decl  = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ChainExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ChainExpr
    }

    /// true if the chain has no base (global-root path `::foo`).
    fn is_global_root(self) -> bool {
        return self.base == &null && !self.steps.is_empty()
    }

    /// true if any step uses optional chaining operators.
    pub fn has_optional_chaining(self) -> bool {
        return self.steps.any(
            fn(s: unsafe *Self::Step) -> bool {
                return s->access_kind == Self::AccessKind::QuestionDot
                    || s->access_kind == Self::AccessKind::QuestionArrow
            },
        )
    }

    /// true if the chain is purely scope resolution (`::` only).
    fn is_scope_path(self) -> bool {
        return self.steps.all(
            fn(s: unsafe *Self::Step) -> bool {
                return s->access_kind == Self::AccessKind::ColonColon
            },
        )
    }

    /// true if any step carries generic arguments.
    fn has_generic_args(self) -> bool {
        return self.steps.any(
            fn(s: unsafe *Self::Step) -> bool {
                return !s->generic_args.is_empty()
            },
        )
    }

    /// returns the identifier of the final step, or null if steps is empty.
    fn trailing_name(self) -> unsafe *NamedIdentExpr {
        if self.steps.is_empty() {
            return &null
        }

        return self.steps.get(self.steps.size() - 1)->name
    }

    /// returns the base as a NamedIdentExpr if it is one, or null.
    pub fn leading_name(self) -> unsafe *NamedIdentExpr {
        if self.base == &null {
            return &null
        }

        if isa<NamedIdentExpr>(self.base) {
            return cast<NamedIdentExpr>(self.base)
        }

        return &null
    }
}

///
///  IntegerLiteralExpr
///  42 | 0xFF | 0b1010 | 0o77 | 1_000_000
///
pub class IntegerLiteralExpr derives Expr {
    pub var token: Token
    pub var imm:   unsafe *Immediate::IntData = &null ///< pointer to the immediate table entry
    pub var ctx:   unsafe *ASTContext
    /// A BuiltinKind the literal IS, as a suffix would make it, or 255: a
    /// literal minted with no source text behind it (PrimitiveLimitDesugar's
    /// `u64::MAX`), which has no suffix to read. Stored as u8 because
    /// CanonicalNodes sits above this file. One writer: the minting pass.
    pub var pinned_kind: u8 = 255

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         token: Token) -> unsafe *IntegerLiteralExpr {
        var unsafe *node = ctx->alloc<IntegerLiteralExpr>()
        node->kind  = ExprKind::IntegerLiteralExpr
        node->range = range
        node->token = token
        node->ctx   = ctx
        // A literal from a macro body (or a literal argument substituted
        // into one) is wrapped: its imm is the expansion record, and its
        // payload sits in the table of the file that wrote it.
        node->imm = ctx->get_payload_table(token)->get<Immediate::IntData>(
            ctx->unwrap_token(token).imm,
        )

        node->pinned_kind = 255
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *IntegerLiteralExpr {
        var unsafe *node = ctx->alloc<IntegerLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::IntegerLiteralExpr
        node->range         = range
        node->pinned_kind   = 255
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::IntegerLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::IntegerLiteralExpr
    }

    pub fn get_spelling(self) -> string {
        return self.ctx->get_spelling(self.token)
    }

    /// \brief the literal's text for a diagnostic, as written. get_spelling
    ///        formats the stored 64-bit value: for a literal wider than 64
    ///        bits that is its low word only (a 2^200 literal read '0'), and
    ///        for `0x100` it is the decimal '256', which names a number the
    ///        user never typed (P809).
    pub fn get_source_text(self) -> string {
        return self.ctx->get_spelling(self.token.range)
    }

    pub fn is_pinned(self) -> bool {
        return self.pinned_kind != 255
    }

    fn get_body_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_body_range: imm pointer is null")
            }
        }

        return self.imm->body
    }

    fn get_prefix_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_prefix_range: imm pointer is null")
            }
        }

        return self.imm->prefix
    }

    fn get_suffix_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_suffix_range: imm pointer is null")
            }
        }

        return self.imm->suffix
    }

    fn get_body_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_body_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_body_range())
    }

    fn get_prefix_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_prefix_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_prefix_range())
    }

    pub fn get_suffix_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_suffix_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_suffix_range())
    }

    pub fn get_value_lo(self) -> u64 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_value_lo: imm pointer is null")
            }
        }

        return self.imm->value_lo
    }

    pub fn get_value_hi(self) -> u64 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_value_hi: imm pointer is null")
            }
        }

        return self.imm->value_hi
    }

    fn get_big(self) -> unsafe *ImmBigInt {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_big: imm pointer is null")
            }
        }

        return self.imm->big
    }

    pub fn get_bits(self) -> u16 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_bits: imm pointer is null")
            }
        }

        return self.imm->bits
    }

    fn get_base(self) -> u8 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::get_base: imm pointer is null")
            }
        }

        return self.imm->base
    }

    pub fn is_unsigned(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::is_unsigned: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00000001) != 0
    }

    pub fn is_negative(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::is_negative: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00000010) != 0
    }

    pub fn is_big(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::is_big: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00000100) != 0
    }

    /// \brief the magnitude of a literal wider than 128 bits, for the range
    ///        check: its bit width, with bit 31 set when it is a power of two.
    ///        0 when the literal is not big (lo/hi are then the whole value).
    pub fn big_bits(self) -> u32 {
        if !self.is_big() || self.imm->big == &null {
            return 0
        }

        var w = self.imm->big->bit_width() as u32
        if self.imm->big->is_pow2() {
            w |= 0x80000000
        }

        return w
    }

    pub fn has_suffix(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::has_suffix: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00001000) != 0
    }

    /// `usize` / `isize`: suffixed, but with the target's pointer width
    /// rather than a width of its own (is_unsigned tells which).
    pub fn is_pointer_sized(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::is_pointer_sized: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00100000) != 0
    }

    fn has_prefix(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"IntegerLiteralExpr::has_prefix: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00010000) != 0
    }
}

///
///  FloatingLiteralExpr
///  1.2 | 1.2e-3 | 0x1.8p+1 | .5f32
///
pub class FloatingLiteralExpr derives Expr {
    pub var token: Token
    pub var ctx:   unsafe *ASTContext                   ///< for TokenText::get_name()
    pub var imm:   unsafe *Immediate::FloatData = &null ///< pointer to the immediate table entry
    /// As IntegerLiteralExpr::pinned_kind: the float type a minted literal
    /// is, or 255.
    pub var pinned_kind: u8 = 255
    /// The PrimLimit (AST/PrimitiveLimits.k) a minted literal stands for,
    /// or 0: `f32::MAX`, `f64::NAN`. EmitIR spells it from the limit, since
    /// no source digits exist and INFINITY / NAN have none at all.
    pub var limit: u8 = 0

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         token: Token) -> unsafe *FloatingLiteralExpr {
        var unsafe *node = ctx->alloc<FloatingLiteralExpr>()
        node->kind  = ExprKind::FloatingLiteralExpr
        node->range = range
        node->token = token
        node->ctx   = ctx
        // Same as the integer literal above: every get_* accessor on this
        // node asserts on a null imm, so the table entry is attached at
        // construction, not on first use.
        node->imm = ctx->get_payload_table(token)->get<Immediate::FloatData>(
            ctx->unwrap_token(token).imm,
        )

        node->pinned_kind = 255
        node->limit       = 0
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx:   unsafe *ASTContext,
                           range: SourceRange) -> unsafe *FloatingLiteralExpr {
        var unsafe *node = ctx->alloc<FloatingLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::FloatingLiteralExpr
        node->range         = range
        node->ctx           = ctx
        node->pinned_kind   = 255
        node->limit         = 0
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::FloatingLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::FloatingLiteralExpr
    }

    fn get_spelling(self) -> string {
        return self.ctx->get_spelling(self.token)
    }

    fn get_body_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_body_range: imm pointer is null")
            }
        }

        return self.imm->body
    }

    fn get_prefix_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_prefix_range: imm pointer is null")
            }
        }

        return self.imm->prefix
    }

    fn get_suffix_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_suffix_range: imm pointer is null")
            }
        }

        return self.imm->suffix
    }

    fn get_body_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_body_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_body_range())
    }

    fn get_prefix_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_prefix_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_prefix_range())
    }

    pub fn get_suffix_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_suffix_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_suffix_range())
    }

    pub fn is_pinned(self) -> bool {
        return self.pinned_kind != 255
    }

    fn get_bits(self) -> u32 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_bits: imm pointer is null")
            }
        }

        return self.imm->bits
    }

    fn get_base(self) -> u8 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_base: imm pointer is null")
            }
        }

        return self.imm->base
    }

    /// f64, not the lexer's ImmFloat: an alias declared in an `eval if` block, named as
    /// a return type from another module, reached codegen with no canonical type (I003E).
    /// Nothing calls this yet.
    fn get_value_ieee(self) -> f64 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_value_ieee: imm pointer is null")
            }
        }

        return self.imm->value_ieee as f64
    }

    fn get_big_float(self) -> unsafe *ImmBigFloat {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::get_big_float: imm pointer is null")
            }
        }

        return self.imm->big_float
    }

    fn is_negative(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::is_negative: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00000010) != 0
    }

    fn is_hex(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::is_hex: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00000100) != 0
    }

    fn is_big(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::is_big: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00001000) != 0
    }

    fn has_exponent(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::has_exponent: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00000001) != 0
    }

    pub fn has_suffix(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"FloatingLiteralExpr::has_suffix: imm pointer is null")
            }
        }

        return (self.imm->flags & 0b00010000) != 0
    }
}

///
///  FormatHole
///  What X decided about one f-string hole, so FStringLowering mints
///  without a lookup. Field for field the FormatSeg row fmt_buf.k declares,
///  plus the conversion to apply to the hole's expression.
///
pub struct FormatHole {
    pub var kind:    FormatKind ///< the put_* row; never None.
    pub var spec:    u64 ///< packed; 0 = defaults (fmt_pack_spec).
    pub var put:     unsafe *Decl ///< FmtBuf::put_<kind>, bound by X.
    pub var conv:    unsafe *Decl ///< the `repr` / `op as -> string` applied first, or null.
    pub var cast_to: unsafe *Type ///< a cast applied to the value first (usize for Ptr, the underlying int for a plain enum), or null.
    pub var by_addr: bool ///< Ptr with no pointer: the value's ADDRESS is printed.
    /// `put` is the VALUE's method, called `v.put(&buf, spec)`: f256 / f512,
    /// whose classes format themselves (F256::fmt_put_), so FmtBuf never
    /// names them (P723).
    pub var on_value: bool
    pub var doc:      SourceRange ///< `{x=}`: source bytes printed before the value; invalid otherwise.
    /// The value's type is a generic body's (a `T`, or a member result
    /// through a `: type` parameter): no put is chosen here. FStringLowering
    /// mints a `fmt_dyn` call and C++ picks the put per instance
    /// (LowerTargets::fmt_dyn). `kind` is None and `put` null.
    pub var deferred: bool
}

///
///  StringLiteralExpr
///  "hello" | r"raw \n" | f"hi {name}!"
///
pub class StringLiteralExpr derives Expr {
    /// One bit per prefix; a literal's kind is a FlagSet of them
    /// (Support/FlagSet.k): empty for a plain "hello", both for `rf"..."`.
    pub enum StringKind derives u8 {
        Raw    = 1 << 0, ///< r"raw \n"
        Format = 1 << 1, ///< f"hi {name}!"
    }

    pub var token:       Token
    pub var string_kind: FlagSet<Self::StringKind, u8>
    pub var parts:       FrozenList<unsafe *Expr> ///< interpolation exprs for Format strings, empty otherwise.
    pub var ctx:         unsafe *ASTContext
    pub var imm:         unsafe *Immediate::StringData = &null ///< pointer to the immediate table entry

    /// Written by X (LiteralTyping), read by the lowerings; nobody else.
    pub var string_ctor: unsafe *Decl           = &null ///< string(data, len, cp_len). Every literal.
    pub var fmt_ctor:    unsafe *Decl           = &null ///< FmtBuf(cap).            Format literals.
    pub var fmt_text:    unsafe *Decl           = &null ///< FmtBuf::text.
    pub var fmt_finish:  unsafe *Decl           = &null ///< FmtBuf::finish.
    pub var fmt_len:     unsafe *Decl           = &null ///< string::length, the method (the capacity sum calls it).
    pub var fmt_holes:   FrozenList<FormatHole>
    /// C++ reads this literal at compile time (Compiler/Spec/Eval.md#strings-at-compile-time): it stands in an
    /// eval context, or in an argument of an eval call made from run-time
    /// code (an immediate invocation). Written by EvalUsageChecking. On the
    /// byte literal StringLowering mints from it, EmitIR spells the bytes as
    /// `__kairo_estr<...>` rather than a `"..."` that needs a cast.
    pub var const_eval: bool = false
    /// The C string parameter type this literal is passed as: set by
    /// CallTyping when the literal is an argument of an imported function
    /// at a `const char *` / `*const u8` parameter or its C `...` tail.
    /// StringLowering then passes the static bytes themselves, and no
    /// `string` is made. The node stays typed `string` until then.
    pub var c_string: unsafe *Type = &null
    /// The imported C++ `operator""_x` a suffixed literal (`"hi"_x`) calls:
    /// written by LiteralTyping, read by StringLowering, which makes the
    /// literal that call. Null for a plain literal.
    pub var udl_op: unsafe *Decl = &null

    pub static fn create(ctx:         unsafe *ASTContext,
                         range:       SourceRange,
                         token:       Token,
                         string_kind: FlagSet<Self::StringKind, u8>) -> unsafe *StringLiteralExpr {
        var unsafe *node = ctx->alloc<StringLiteralExpr>()
        node->kind        = ExprKind::StringLiteralExpr
        node->range       = range
        node->token       = token
        node->string_kind = string_kind
        node->ctx         = ctx
        node->string_ctor = &null
        node->fmt_ctor    = &null
        node->fmt_text    = &null
        node->fmt_finish  = &null
        node->fmt_len     = &null
        node->fmt_holes   = create_empty_frozen_list<FormatHole>() // read only when is_format; an unset list must still be readable.
        node->const_eval  = false
        node->c_string    = &null
        node->udl_op      = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx:   unsafe *ASTContext,
                           range: SourceRange) -> unsafe *StringLiteralExpr {
        var unsafe *node = ctx->alloc<StringLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::StringLiteralExpr
        node->range         = range
        node->ctx           = ctx
        node->string_ctor   = &null
        node->fmt_ctor      = &null
        node->fmt_text      = &null
        node->fmt_finish    = &null
        node->fmt_len       = &null
        node->fmt_holes     = create_empty_frozen_list<FormatHole>() // read only when is_format; an unset list must still be readable.
        node->const_eval    = false
        node->c_string      = &null
        node->udl_op        = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::StringLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::StringLiteralExpr
    }

    fn get_spelling(self) -> string {
        return self.ctx->get_spelling(self.token)
    }

    fn get_body_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_body_range: imm pointer is null")
            }
        }

        return self.imm->body
    }

    fn get_body_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_body_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_body_range())
    }

    fn get_prefix(self) -> Token {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_prefix: imm pointer is null")
            }
        }

        return self.imm->prefix
    }

    pub fn get_suffix(self) -> Token {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_suffix: imm pointer is null")
            }
        }

        return self.imm->suffix
    }

    fn get_prefix_kind(self) -> FlagSet<Immediate::TextPrefixKind, u8> {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_prefix_kind: imm pointer is null")
            }
        }

        return self.imm->prefix_kind
    }

    fn get_next(self) -> u32 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_next: imm pointer is null")
            }
        }

        return self.imm->next
    }

    pub fn has_next(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::has_next: imm pointer is null")
            }
        }

        return self.imm->next != ((-1) as i32 as u32)
    }

    fn has_interpolation(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::has_interpolation: imm pointer is null")
            }
        }

        return self.imm->exprs.size() > 0
    }

    fn get_exprs(self) -> unsafe *llvm::SmallVector<(unsafe *TokenBuffer<16>, SourceRange), 4> {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_exprs: imm pointer is null")
            }
        }

        return unsafe &self.imm->exprs
    }

    /// The spec and `=` facts the lexer recorded per hole; parallel to get_exprs().
    pub fn get_holes(self) -> unsafe *llvm::SmallVector<Immediate::HoleSpec, 4> {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::get_holes: imm pointer is null")
            }
        }

        return unsafe &self.imm->holes
    }

    fn interpolation_count(self) -> usize {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"StringLiteralExpr::interpolation_count: imm pointer is null")
            }
        }

        return self.imm->exprs.size()
    }

    pub fn is_format(self) -> bool {
        return self.string_kind.has(Self::StringKind::Format)
    }

    pub fn is_raw(self) -> bool {
        return self.string_kind.has(Self::StringKind::Raw)
    }

    fn is_plain(self) -> bool {
        return self.string_kind.empty()
    }
}

/// StringLiteralExpr::StringKind's variants are its FlagSet's bits
/// (Support/FlagSet.k).
extend StringLiteralExpr::StringKind impl FlagBit<u8> {
    inline fn bit(const self) -> u8 {
        return self as u8
    }
}

///
///  CharacterLiteralExpr
///  'a' | '\n' | '\u{1F600}'
///
pub class CharacterLiteralExpr derives Expr {
    pub var token: Token
    pub var ctx:   *ASTContext                         ///< for TokenText::get_name()
    pub var imm:   unsafe *Immediate::CharData = &null ///< pointer to the immediate table entry

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         token: Token) -> unsafe *CharacterLiteralExpr {
        var unsafe *node = ctx->alloc<CharacterLiteralExpr>()
        node->kind  = ExprKind::CharacterLiteralExpr
        node->range = range
        node->token = token
        node->ctx   = ctx
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *CharacterLiteralExpr {
        var unsafe *node = ctx->alloc<CharacterLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::CharacterLiteralExpr
        node->range         = range
        node->ctx           = ctx
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::CharacterLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::CharacterLiteralExpr
    }

    fn get_spelling(self) -> string {
        return self.ctx->get_spelling(self.token)
    }

    fn get_body_range(self) -> SourceRange {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::get_body_range: imm pointer is null")
            }
        }

        return self.imm->body
    }

    fn get_body_text(self) -> string {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::get_body_text: imm pointer is null")
            }
        }

        return self.ctx->get_spelling(self.get_body_range())
    }

    fn get_prefix(self) -> Token {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::get_prefix: imm pointer is null")
            }
        }

        return self.imm->prefix
    }

    fn get_suffix(self) -> Token {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::get_suffix: imm pointer is null")
            }
        }

        return self.imm->suffix
    }

    fn get_prefix_kind(self) -> FlagSet<Immediate::TextPrefixKind, u8> {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::get_prefix_kind: imm pointer is null")
            }
        }

        return self.imm->prefix_kind
    }

    fn get_next(self) -> u32 {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::get_next: imm pointer is null")
            }
        }

        return self.imm->next
    }

    fn has_next(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::has_next: imm pointer is null")
            }
        }

        return self.imm->next != ((-1) as i32 as u32)
    }

    fn has_interpolation(self) -> bool {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(
                    r"CharacterLiteralExpr::has_interpolation: imm pointer is null",
                )
            }
        }

        return self.imm->exprs.size() > 0
    }

    fn get_exprs(self) -> unsafe *llvm::SmallVector<(unsafe *TokenBuffer<16>, SourceRange), 4> {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(r"CharacterLiteralExpr::get_exprs: imm pointer is null")
            }
        }

        return unsafe &self.imm->exprs
    }

    fn interpolation_count(self) -> usize {
        eval if defined!(DEBUG) {
            if !(self.imm != &null) {
                kairo::std::ice_fail(
                    r"CharacterLiteralExpr::interpolation_count: imm pointer is null",
                )
            }
        }

        return self.imm->exprs.size()
    }
}

///
///  BooleanLiteralExpr
///  true | false
///
pub class BooleanLiteralExpr derives Expr {
    pub var value: bool

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         value: bool) -> unsafe *BooleanLiteralExpr {
        var unsafe *node = ctx->alloc<BooleanLiteralExpr>()
        node->kind  = ExprKind::BooleanLiteralExpr
        node->range = range
        node->value = value
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *BooleanLiteralExpr {
        var unsafe *node = ctx->alloc<BooleanLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::BooleanLiteralExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::BooleanLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::BooleanLiteralExpr
    }
}

///
///  NullLiteralExpr
///  null | &null
///
pub class NullLiteralExpr derives Expr {
    pub var is_ref: bool ///< true for &null (null pointer literal).

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         is_ref: bool) -> unsafe *NullLiteralExpr {
        var unsafe *node = ctx->alloc<NullLiteralExpr>()
        node->kind   = ExprKind::NullLiteralExpr
        node->range  = range
        node->is_ref = is_ref
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *NullLiteralExpr {
        var unsafe *node = ctx->alloc<NullLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::NullLiteralExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::NullLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::NullLiteralExpr
    }
}
