/// --- The Kairo Project ----------------------- AST/Node/Expressions.k --- ///
///
///   Compound expression AST nodes: calls, operators, literals with elements,
///   control-flow, casts, closures and the like.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// \invariant Recovery node casting contract:
///
/// When kind == ExprKind::RecoveryExpr and recovery_kind == ExprKind::X,
/// the node was allocated as X and it is ALWAYS safe to cast:
///
///   static_cast<X*>(recovery_expr_ptr)
///
/// This is guaranteed by create_error() on every concrete node class.
/// Sema relies on this invariant for partial recovery type checking.
/// Codegen relies on this to emit defaults for broken nodes.
///
/// DO NOT allocate a bare Expr and set recovery_kindthe cast will
/// read out of bounds. Always use the concrete node's create_error().
///
ffi "c++" import "Native/Types.hh"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::ASTContext::ASTContext
import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
}
import AST::Kind::ExprKind::ExprKind
import AST::LangItems::LangIntrinsics
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::{
    FnBodyKind,
    FnModifier,
    GenericParamDecl,
    PanicSetState,
    ParamDecl,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    MatchCase,
}
import Location::SourceRange::SourceRange
import Token::Token::Token
import Token::TokenKind::TokenKind

///
///  CallExpr
///  expr(args) function call, method call, constructor call.
///  Callee is any expression. Separate from ChainExpr so sema can resolve
///  the callee expression independently from overload resolution on the args.
///
///  examples:
///    foo(x, y)                callee=NamedIdentExpr("foo")
///    foo.bar(x)               callee=ChainExpr(foo.bar)
///    foo::bar::<T>(x)         callee=ChainExpr(foo::bar::<T>)
///    (get_fn())(x)            callee=CallExpr(get_fn, [])
///    arr[0](x)                callee=SubscriptExpr(arr, 0)
///
pub class CallExpr derives Expr {
    /// the expression being called.
    pub var callee: unsafe *Expr

    /// the argument list. empty for no-arg calls like `foo()`.
    pub var args: FrozenList<unsafe *Expr>

    /// Parallel to the CALLEE'S PARAMETERS (`f->params`, `self` included and
    /// occupying slot 0 on a method): the index into `args` of the argument
    /// bound to that parameter, or -1 for "use the parameter's default".
    /// For the pack parameter it is the index of the FIRST pack argument, and
    /// `pack_len` says how many follow it.
    ///
    /// Written once by CallTyping at Selected, and it is the fact CallLowering
    /// reorders from -- the argument order at the call site is the user's, the
    /// order C++ needs is the parameter list's, and nothing downstream should
    /// have to re-derive the mapping between them.
    pub var arg_map:  FrozenList<i32>
    pub var pack_len: u32             = 0

    /// A generic callee's registry entry: written by CallTyping at Selected, copied by
    /// OperatorLowering onto the calls it mints. EmitIR spells the instance's
    /// arguments explicitly from it: clang deducing them from the emitted
    /// argument expressions is headroom, and an argument whose C++ type is not
    /// its Kairo type (an int literal typed i64) deduces an instance nobody
    /// homed.
    pub var instance: unsafe *InstanceEntry = &null

    /// A constructor call's selected constructor. The callee names the TYPE
    /// (EmitIR spells the type from `type_`), so without this nothing after X
    /// knows which ctor `arg_map` is parallel to. Written by
    /// CallTyping::_ctor_call at Selected.
    pub var ctor_decl: unsafe *Decl = &null

    /// A call of a C++ function object, `f(args)` with `f` a value whose
    /// class has `operator()`: the selected operator, which `arg_map` is
    /// parallel to (its `self` is the callee object). EmitIR writes the
    /// call as written and clang picks the same operator. Written by
    /// CallTyping::_functor_call at Selected.
    pub var functor_op: unsafe *Decl = &null

    /// The record a static-member callee is named THROUGH, when that record
    /// is a generic one's instance, so EmitIR spells `Box<int>::zero()`
    /// rather than the bare class template `Box::zero()`, which names no
    /// class. Two writers: CallTyping on a `::` call through `Box<i32>`
    /// (the instance's arguments are on the qualifier and nowhere else), and
    /// CallLowering on a default-thunk call whose owner is generic
    /// (`Box<int>::__kairo_default_m_x()`). Null everywhere else.
    pub var qualifier: unsafe *Type = &null

    /// An f-string hole whose value's type only an instance knows
    /// (FormatHole::deferred): `::__kairo_fmt_put(buf, value, name, len,
    /// spec)`, the preamble template that picks the put per instance
    /// (LowerTargets::fmt_dyn). The callee is a placeholder name bound to
    /// nothing. One writer, FStringLowering; one reader, EmitIR.
    pub var fmt_dyn: bool = false

    /// A call bound to an interface REQUIREMENT (its callee's `semantic_dc`
    /// owner an InterfaceDecl) goes through that interface's witness,
    /// `::N::I_witness<Self, A...>::m(recv, ...)` (Compiler/Spec/Witnesses.md#call-sites).
    /// Written by ExtensionLowering when it puts the receiver in front:
    /// `witness_iface` is the canonical instance of the DECLARING interface,
    /// `witness_self` the canonical Self (a dependent `T` in a generic body).
    /// EmitIR spells the witness from both. Null on every other call.
    /// A qualified call (`Container<i32>::m(x)`) has `witness_iface` earlier:
    /// CallTyping writes the qualifier there, the only place a generic
    /// interface's arguments are, and ConformanceChecking narrows it to the
    /// bound it names before ExtensionLowering reads it.
    pub var witness_iface: unsafe *Type = &null
    pub var witness_self:  unsafe *Type = &null
    /// A qualified requirement call on a CONCRETE Self (`I::m(x)` with x a
    /// Metric) names no instance to carry its row, so the call carries it.
    /// Written by ConformanceChecking; EmitPlan admits its specialization
    /// from it.
    pub var witness_row: unsafe *ConformanceRow = &null

    /// A generic callee's arguments when they are still DEPENDENT, so no
    /// instance exists yet (`inner(Wrap<T>{...})` inside `outer<T>`): what
    /// ConformanceChecking substitutes with each instance of the enclosing
    /// generic, to reach the instances its body needs (M1's transitive
    /// registry, for the witness rows). Written by CallTyping; empty
    /// whenever `instance` is set.
    pub var dep_args: FrozenList<unsafe *Type>

    /// `x?.f(args)` (Compiler/Spec/Nullables.md#safe-access): the call's OWN result `R`, while the
    /// node is typed what the whole expression is (`R?`, or `R` when it is
    /// already nullable; `void` for a `void` or `-> !` method). Written by
    /// CallTyping; read by CoalesceLowering, whose then-arm is the call
    /// typed `R`. Null on every other call.
    pub var safe_result: unsafe *Type = &null

    /// `x in xs` through a user `op in`: the call's operand zero (`xs`, the
    /// receiver, or a free operator's first argument) is the source's RIGHT
    /// operand, evaluated after the other. Written by OperatorLowering;
    /// SequenceLowering binds `x` first when the order is observable.
    pub var recv_last: bool = false

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         callee: unsafe *Expr) -> unsafe *CallExpr {
        var unsafe *node = ctx->alloc<CallExpr>()
        node->kind          = ExprKind::CallExpr
        node->range         = range
        node->callee        = callee
        node->pack_len      = 0
        node->arg_map       = create_empty_frozen_list<i32>() // a minted call is positional; nothing may read an unset list.
        node->instance      = &null
        node->ctor_decl     = &null
        node->functor_op    = &null
        node->qualifier     = &null
        node->witness_iface = &null
        node->witness_self  = &null
        node->witness_row   = &null
        node->dep_args      = create_empty_frozen_list<unsafe *Type>()
        node->safe_result   = &null
        node->recv_last     = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *CallExpr {
        var unsafe *node = ctx->alloc<CallExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::CallExpr
        node->range         = range
        node->callee        = &null
        node->pack_len      = 0
        node->arg_map       = create_empty_frozen_list<i32>() // a minted call is positional; nothing may read an unset list.
        node->instance      = &null
        node->ctor_decl     = &null
        node->functor_op    = &null
        node->qualifier     = &null
        node->witness_iface = &null
        node->witness_self  = &null
        node->witness_row   = &null
        node->dep_args      = create_empty_frozen_list<unsafe *Type>()
        node->recv_last     = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::CallExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::CallExpr
    }

    fn arg_count(self) -> usize {
        return self.args.size()
    }
}

///
///  NamedArgExpr
///  `name: value` in an argument list.
///
/// A label is not an expression, so this is not an operator node: a `:`
/// operator token would force every reader of an argument list to recognise
/// that shape and step around the lhs.
/// Placement (CallTyping) reads `name`; everything else reads `value`.
///
pub class NamedArgExpr derives Expr {
    /// the parameter name written at the call site.
    pub var name: Token

    /// the argument value.
    pub var value: unsafe *Expr

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         name:  Token,
                         value: unsafe *Expr) -> unsafe *NamedArgExpr {
        var unsafe *node = ctx->alloc<NamedArgExpr>()
        node->kind  = ExprKind::NamedArgExpr
        node->range = range
        node->name  = name
        node->value = value
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *NamedArgExpr {
        var unsafe *node = ctx->alloc<NamedArgExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::NamedArgExpr
        node->range         = range
        node->value         = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::NamedArgExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::NamedArgExpr
    }
}

///
///  SubscriptExpr
///  expr[index] element access or slice.
///  For slices, index is a RangeExpr (e.g. arr[1..3]).
///
///  examples:
///    arr[0]       element access
///    arr[1..3]    slice (index is RangeExpr)
///    arr[..3]     slice from start
///    mat[i][j]    nested: base is another SubscriptExpr
///
pub class SubscriptExpr derives Expr {
    /// the expression being indexed.
    pub var base: unsafe *Expr

    /// the index or range expression inside the brackets.
    pub var index: unsafe *Expr

    /// The user operator overload resolution selected, or null for a builtin
    /// operator. Written by X (OperatorTyping / MemberTyping / CastTyping),
    /// read by OperatorLowering, which rewrites the node into the call.
    pub var resolved_op: unsafe *Decl = &null
    pub var op_via_free: bool         = false ///< a free `op` found by ADL (every operand is an argument).
    /// The registry entry of a GENERIC `op []`'s instance (a member
    /// template's, or a bound's generic requirement), as on
    /// BinaryOperatorExpr.
    pub var op_instance: unsafe *InstanceEntry = &null
    /// What the use does with the element, set by its consumer before it
    /// types the subscript: which form a SPLIT subscript (a type that
    /// declares `op []=`) selects. One of MemberTyping's SUB_CTX_* values;
    /// 0 is a read. A type with no `op []=` ignores it. Written by X only.
    pub var place_ctx: u8 = 0

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         base:  unsafe *Expr,
                         index: unsafe *Expr) -> unsafe *SubscriptExpr {
        var unsafe *node = ctx->alloc<SubscriptExpr>()
        node->kind        = ExprKind::SubscriptExpr
        node->range       = range
        node->base        = base
        node->index       = index
        node->resolved_op = &null
        node->op_via_free = false
        node->op_instance = &null
        node->place_ctx   = 0
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SubscriptExpr {
        var unsafe *node = ctx->alloc<SubscriptExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::SubscriptExpr
        node->range         = range
        node->base          = &null
        node->index         = &null
        node->resolved_op   = &null
        node->op_via_free   = false
        node->op_instance   = &null
        node->place_ctx     = 0
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::SubscriptExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::SubscriptExpr
    }
}

/// Where a Slice-typed list literal's backing array lives. X decides;
/// ListLiteralLowering renders.
pub enum ListStorage derives u8 {
    FullExpr = 0, ///< a temporary: dies at the end of the full-expression.
    Extended,     ///< a named local in the scope of the `var` it initializes.
}

///
///  ListLiteralExpr
///  [1, 2, 3]
///
pub class ListLiteralExpr derives Expr {
    pub var elements: FrozenList<unsafe *Expr>

    /// Written by X (LiteralTyping / StmtTyping), read by ListLiteralLowering.
    /// The TARGET is `type_` itself: `[T; N]`, Slice or Vector.
    pub var storage:    ListStorage  = ListStorage::FullExpr
    pub var slice_ctor: unsafe *Decl = &null ///< Slice(data, len); set for a Slice or non-empty Vector target.
    pub var owner_ctor: unsafe *Decl = &null ///< Vector(items), or Vector() when empty; set for a Vector target.

    pub static fn create(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *ListLiteralExpr {
        var unsafe *node = ctx->alloc<ListLiteralExpr>()
        node->kind       = ExprKind::ListLiteralExpr
        node->range      = range
        node->storage    = ListStorage::FullExpr
        node->slice_ctor = &null
        node->owner_ctor = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ListLiteralExpr {
        var unsafe *node = ctx->alloc<ListLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::ListLiteralExpr
        node->range         = range
        node->storage       = ListStorage::FullExpr
        node->slice_ctor    = &null
        node->owner_ctor    = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ListLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ListLiteralExpr
    }
}

///
///  InitListExpr
///  { a, b, c }   -- the C++ braced-init-list. Lower/ mints it; nothing parses into it.
///
pub class InitListExpr derives Expr {
    pub var elements: FrozenList<unsafe *Expr>

    pub static fn create(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *InitListExpr {
        var unsafe *node = ctx->alloc<InitListExpr>()
        node->kind  = ExprKind::InitListExpr
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::InitListExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::InitListExpr
    }
}

///
///  StmtExpr
///  ({ s0; s1; e; })   -- the value is the last statement, an ExpressionStmt.
///
pub class StmtExpr derives Expr {
    pub var body: unsafe *CompoundStmt
    /// A `try` expression's arm that LEAVES instead of producing a value:
    /// `catch => return v`, `=> break`, `=> continue` (Compiler/Spec/Panic.md#try-and-arms). The
    /// body is exactly that one jump statement, with no trailing value; the
    /// expression has type `!`, so it fits beside arms of any type. The
    /// parser writes it (ExprParse::_parse_jump_arm); PanicLowering renders
    /// it (a `return` inside a GNU statement expression returns from the
    /// enclosing function, §4.5a E).
    pub var is_jump: bool = false

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         body:  unsafe *CompoundStmt) -> unsafe *StmtExpr {
        var unsafe *node = ctx->alloc<StmtExpr>()
        node->kind  = ExprKind::StmtExpr
        node->range = range
        node->body  = body
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::StmtExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::StmtExpr
    }
}

///
///  VariantInitExpr
///  An ADT enum variant built in place. `fields` are the payload in
///  declaration order; `source_order[i]` is the position field i was written
///  at. One writer: VariantInitLowering, which mints it, typed as the enum and
///  an rvalue, in place of the construction X checked. EmitIR spells it as the
///  tagged constructor the variant's AdtCtorForm names: the fields passed
///  in order, or a lambda that returns the payload struct. A
///  plain enum's variant never becomes one: it is a value, and its `.V` is
///  lowered to the enumerator's name.
///
pub class VariantInitExpr derives Expr {
    /// The pattern EnumDecl: a `*Decl`, as every decl link in this file is.
    pub var en:           unsafe *Decl             = &null
    pub var variant:      u32                      = 0 ///< position in en->variants.
    pub var fields:       FrozenList<unsafe *Expr> ///< declaration order; empty for a nullary variant.
    pub var source_order: FrozenList<u32> ///< parallel to fields.
    /// A generic ADT's variant (AdtCtorForm::Both): this site's instance is
    /// concrete and every field moves, so the field constructor is called.
    /// Otherwise the lambda one, which every such variant has. One writer:
    /// EnumLayoutLowering.
    pub var field_ctor: bool = false
    /// A pack-expanded variant's construction: the pack element built
    /// (`variant`'s expanded index is variant + pack_index) and its type,
    /// what the payload's pack-typed fields hold. -1 / null otherwise.
    pub var pack_index: i32          = -1
    pub var pack_elem:  unsafe *Type = &null
    /// A lang item with a site slot (EnumDecl::adt_site_field: the Panic
    /// lang item's u32 beside the tag, Compiler/Spec/Panic.md#site-ids): the site id this
    /// construction stores there, in the same word as the tag. 0 stores
    /// none. One writer: PanicLowering (a `panic X`).
    pub var site: u32 = 0

    pub static fn create(ctx:     unsafe *ASTContext,
                         range:   SourceRange,
                         en:      unsafe *Decl,
                         variant: u32) -> unsafe *VariantInitExpr {
        var unsafe *node = ctx->alloc<VariantInitExpr>()
        node->kind         = ExprKind::VariantInitExpr
        node->range        = range
        node->en           = en
        node->variant      = variant
        node->fields       = create_empty_frozen_list<unsafe *Expr>()
        node->source_order = create_empty_frozen_list<u32>()
        node->field_ctor   = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *VariantInitExpr {
        var unsafe *node = ctx->alloc<VariantInitExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::VariantInitExpr
        node->range         = range
        node->en            = &null
        node->variant       = 0
        node->fields        = create_empty_frozen_list<unsafe *Expr>()
        node->source_order  = create_empty_frozen_list<u32>()
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::VariantInitExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::VariantInitExpr
    }
}

///
///  TupleLiteralExpr
///  (1, "two", 3.0)
///
pub class TupleLiteralExpr derives Expr {
    pub var elements: FrozenList<unsafe *Expr>

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *TupleLiteralExpr {
        var unsafe *node = ctx->alloc<TupleLiteralExpr>()
        node->kind  = ExprKind::TupleLiteralExpr
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TupleLiteralExpr {
        var unsafe *node = ctx->alloc<TupleLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::TupleLiteralExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::TupleLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::TupleLiteralExpr
    }
}

///
///  SetLiteralExpr
///  {1, 2, 3}
///
pub class SetLiteralExpr derives Expr {
    pub var elements: FrozenList<unsafe *Expr>

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *SetLiteralExpr {
        var unsafe *node = ctx->alloc<SetLiteralExpr>()
        node->kind  = ExprKind::SetLiteralExpr
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SetLiteralExpr {
        var unsafe *node = ctx->alloc<SetLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::SetLiteralExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::SetLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::SetLiteralExpr
    }
}

///
///  MapLiteralExpr
///  {"key": value, "other": value2}
///
pub class MapLiteralExpr derives Expr {
    pub struct Entry {
        pub var key:   unsafe *Expr
        pub var value: unsafe *Expr
        pub var range: SourceRange
    }

    pub var entries: FrozenList<Self::Entry>

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *MapLiteralExpr {
        var unsafe *node = ctx->alloc<MapLiteralExpr>()
        node->kind  = ExprKind::MapLiteralExpr
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *MapLiteralExpr {
        var unsafe *node = ctx->alloc<MapLiteralExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::MapLiteralExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::MapLiteralExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::MapLiteralExpr
    }
}

pub struct InitField {
    pub var name:  Token        ///< field name token
    pub var value: unsafe *Expr ///< initializer expression
    pub var range: SourceRange  ///< range covering `name: value`
    /// On a variant construction's field: the payload FieldDecl it fills.
    /// Null on a record's initializer, whose fields EmitIR matches by name.
    /// One writer: X (ControlTyping); read by VariantInitLowering.
    pub var field_decl: unsafe *Decl = &null
}

///
///  NamedInitializerExpr
///  Point { x: 1, y: 2 }
///
pub class NamedInitializerExpr derives Expr {
    /// the type being initialized. ChainExpr or NamedIdentExpr; null for the
    /// dotted form, and for an initializer Lower/ mints (RangeLowering), which
    /// EmitIR spells from `type_`.
    pub var type_expr: unsafe *Expr
    pub var ctx:       unsafe *ASTContext
    /// field initializers in source order.
    pub var fields: FrozenList<InitField>
    /// `.Variant` / `.Variant { .. }`: a variant of the enum the expected type
    /// names, so there is no head to resolve and `dotted_name` is the
    /// variant's name. A null `type_expr` alone does not say this: a minted
    /// initializer has none either. One writer: the parser
    /// (ExprParse::_parse_dotted_variant).
    pub var is_dotted:   bool  = false
    pub var dotted_name: Token
    /// The braces were written. Always true with a head; the dotted form may
    /// stand alone (`.None`), which a variant without a payload must and one
    /// with a payload must not. One writer: the parser.
    pub var has_braces: bool = true
    /// The EnumVariantDecl this initializer builds (`E::V { .. }`,
    /// `.V { .. }`, `.V`), the pattern enum's own, once X has checked the
    /// fields against its payload; null for a record's initializer and for a
    /// construction that failed. One writer: X (ControlTyping); read through
    /// variant_decl_of. VariantInitLowering replaces the node.
    pub var variant_decl: unsafe *Decl = &null
    /// variant_decl is pack-expanded: the element its payload's type picked
    /// (ControlTyping::_check_variant); -1 otherwise.
    pub var variant_pack: i32 = -1

    pub static fn create(ctx:       unsafe *ASTContext,
                         range:     SourceRange,
                         type_expr: unsafe *Expr) -> unsafe *NamedInitializerExpr {
        var unsafe *node = ctx->alloc<NamedInitializerExpr>()
        node->kind         = ExprKind::NamedInitializerExpr
        node->range        = range
        node->type_expr    = type_expr
        node->ctx          = ctx
        node->fields       = create_empty_frozen_list<InitField>() // the bare dotted form has no braces to fill it.
        node->is_dotted    = false
        node->dotted_name  = Token()
        node->has_braces   = true
        node->variant_decl = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx:   unsafe *ASTContext,
                               range: SourceRange) -> unsafe *NamedInitializerExpr {
        var unsafe *node = ctx->alloc<NamedInitializerExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::NamedInitializerExpr
        node->range         = range
        node->type_expr     = &null
        node->ctx           = ctx
        node->fields        = create_empty_frozen_list<InitField>()
        node->is_dotted     = false
        node->dotted_name   = Token()
        node->has_braces    = true
        node->variant_decl  = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::NamedInitializerExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::NamedInitializerExpr
    }
}

/// The EnumVariantDecl X recorded on \p e as the variant it builds, or null.
/// A construction is written as one of three nodes -- an initializer
/// (`E::V { .. }`, `.V`), a path (`Opt::None`), a bare name (`None` inside its
/// enum) -- and each carries the fact as its own `variant_decl`. One reader
/// for the three.
pub fn variant_decl_of(e: unsafe *Expr) -> unsafe *Decl {
    if e == &null {
        return &null
    }

    if isa<NamedInitializerExpr>(e) {
        return cast<NamedInitializerExpr>(e)->variant_decl
    }

    if isa<ChainExpr>(e) {
        return cast<ChainExpr>(e)->variant_decl
    }

    if isa<NamedIdentExpr>(e) {
        return cast<NamedIdentExpr>(e)->variant_decl
    }

    return &null
}

///
///  AnonInitializerExpr
///  { .x: 1, .y: 2 }
///  Sema infers the type from context (assignment target, return type, etc.).
///
pub class AnonInitializerExpr derives Expr {
    pub var fields: FrozenList<InitField>
    pub var ctx:    *ASTContext

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *AnonInitializerExpr {
        var unsafe *node = ctx->alloc<AnonInitializerExpr>()
        node->kind  = ExprKind::AnonInitializerExpr
        node->range = range
        node->ctx   = ctx
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *AnonInitializerExpr {
        var unsafe *node = ctx->alloc<AnonInitializerExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::AnonInitializerExpr
        node->range         = range
        node->ctx           = ctx
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::AnonInitializerExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::AnonInitializerExpr
    }
}

///
///  UnaryOperatorExpr
///  prefix:  !x  -x  ~x  &x  *x  ++x  --x
///  postfix: x++  x--  x...
///
pub class UnaryOperatorExpr derives Expr {
    pub enum Fix derives u8 {
        Prefix,
        Postfix,
    }

    pub var operand:  unsafe *Expr
    pub var op_token: Token        ///< the operator token (!, -, *, &, ++, --, etc.)
    pub var fix:      Self::Fix
    /// `&x` in argument position, bound to an `@inout` parameter: the `&` is
    /// the call-site MARKER, not address-of. Set by CallTyping after overload
    /// selection (the parser cannot know the callee); `type_` is then the
    /// operand's type and the node is an lvalue. Codegen emits the operand
    /// bare. False for every other `&`.
    pub var is_mode_marker: bool = false
    /// `&e` on a prvalue: the address of its materialized temporary, spelled
    /// `::__kairo_tmp(e)`. Written by ExtensionLowering only. SequenceLowering
    /// binds `e`, never the pointer.
    pub var materialize: bool = false
    /// `++`/`--`/`-`/`~` on an integer whose overflow is proven impossible
    /// (IterLowering's induction variable): EmitIR prints C++'s own operator,
    /// whose UB is then unreachable, instead of the wrapping form. Never
    /// inferred by the emitter.
    pub var no_wrap: bool = false

    /// The user operator overload resolution selected, or null for a builtin
    /// operator. Written by X (OperatorTyping / MemberTyping / CastTyping),
    /// read by OperatorLowering, which rewrites the node into the call.
    pub var resolved_op: unsafe *Decl = &null
    pub var op_via_free: bool         = false ///< a free `op` found by ADL (every operand is an argument).
    /// The registry entry of a GENERIC free operator's instance, written by X
    /// with resolved_op. OperatorLowering copies it onto the
    /// call it mints, and EmitIR spells the instance's arguments from it.
    pub var op_instance: unsafe *InstanceEntry = &null
    /// A narrowed `*x` (Compiler/Spec/Nullables.md#aliases-and-closures, §4): `x` is a closure's pointer
    /// capture of a `T?` the nullness analysis proved non-null here, so the
    /// dereference is typed `T` and this holds the `T?` it was. Null for
    /// every other use. One writer: X (NullnessFlow::read_value); one
    /// reader, NarrowedAccessLowering, which makes it `(*x).__value()`.
    pub var narrowed_from: unsafe *Type = &null

    pub static fn create(ctx:      unsafe *ASTContext,
                         range:    SourceRange,
                         operand:  unsafe *Expr,
                         op_token: Token,
                         fix:      Self::Fix) -> unsafe *UnaryOperatorExpr {
        var unsafe *node = ctx->alloc<UnaryOperatorExpr>()
        node->kind    = ExprKind::UnaryOperatorExpr
        node->range   = range
        node->operand = operand
        // Unwrapped: an operator from a macro body arrives as TkMacroExpand,
        // and every reader of op_token.kind (Sema's operator typing, the
        // printer, EmitIR) wants the operator. The range stays the wrapped
        // token's, so diagnostics still point at the invocation.
        node->op_token       = ctx->unwrap_token(op_token)
        node->fix            = fix
        node->is_mode_marker = false
        node->materialize    = false
        node->no_wrap        = false
        node->resolved_op    = &null
        node->op_via_free    = false
        node->op_instance    = &null
        node->narrowed_from  = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *UnaryOperatorExpr {
        var unsafe *node = ctx->alloc<UnaryOperatorExpr>()
        node->kind           = ExprKind::RecoveryExpr
        node->recovery_kind  = ExprKind::UnaryOperatorExpr
        node->range          = range
        node->operand        = &null
        node->is_mode_marker = false
        node->materialize    = false
        node->no_wrap        = false
        node->resolved_op    = &null
        node->op_via_free    = false
        node->op_instance    = &null
        node->narrowed_from  = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::UnaryOperatorExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::UnaryOperatorExpr
    }

    pub fn is_prefix(self) -> bool {
        return self.fix == Self::Fix::Prefix
    }

    pub fn is_postfix(self) -> bool {
        return self.fix == Self::Fix::Postfix
    }
}

/// How a comparison with no operator of its own is rendered from the one it
/// was derived from (C++20's rewritten candidates, minus the reversed ones).
/// Written by X beside `resolved_op`; read by OperatorLowering, which never
/// looks an operator up again.
pub enum OpRewrite derives u8 {
    None = 0, ///< resolved_op is the operator itself.
    Not,      ///< `a != b` from `op ==`:  `!(a.op==(b))`.
    Cmp,      ///< `a < b`, `a == b` and friends from `op <=>`:  `((a.op<=>(b)) as i8) <op> 0`.
}

///
///  BinaryOperatorExpr
///  x + y | x && y | x == y | x << y | x ** y | etc.
///
pub class BinaryOperatorExpr derives Expr {
    pub var lhs:      unsafe *Expr
    pub var rhs:      unsafe *Expr
    pub var op_token: Token

    /// The user operator overload resolution selected, or null for a builtin
    /// operator. Written by X (OperatorTyping / MemberTyping / CastTyping),
    /// read by OperatorLowering, which rewrites the node into the call.
    pub var resolved_op: unsafe *Decl = &null
    pub var op_via_free: bool         = false ///< a free `op` found by ADL (every operand is an argument).
    pub var op_rewrite:  OpRewrite    = OpRewrite::None
    /// `==` / `!=` on two values of one ADT enum that declares no `op ==`:
    /// equal when the variants are, whatever the payloads. resolved_op stays
    /// null -- no operator is bound -- and OperatorLowering rewrites the node
    /// into a builtin compare of the two tag fields. One writer: X
    /// (OperatorTyping).
    pub var tag_eq: bool = false
    /// `+`/`-`/`*` whose overflow is proven impossible: C++'s own operator,
    /// not the wrapping form (see UnaryOperatorExpr::no_wrap). On `<<` /
    /// `>>`: the count is proven in [0, W), so EmitIR leaves its mask out
    /// (SHIFT spec §4); X sets it for a constant or masked count,
    /// IterLowering for a range loop's binder.
    pub var no_wrap: bool = false
    /// The registry entry of a GENERIC free operator's instance, written by X
    /// with resolved_op. OperatorLowering copies it onto the
    /// call it mints, and EmitIR spells the instance's arguments from it.
    pub var op_instance: unsafe *InstanceEntry = &null
    /// `typeof T == U` / `!=` (Compiler/Spec/Eval.md "Type-based branching"): the two
    /// canonical types compared, both set or both null. One writer: X
    /// (OperatorTyping). StmtTyping folds an `eval if` over them and EmitIR
    /// spells `__is_same(L, R)`: the operands are types, never emitted.
    pub var type_cmp_lhs: unsafe *Type = &null
    pub var type_cmp_rhs: unsafe *Type = &null

    pub static fn create(ctx:      unsafe *ASTContext,
                         range:    SourceRange,
                         lhs:      unsafe *Expr,
                         rhs:      unsafe *Expr,
                         op_token: Token) -> unsafe *BinaryOperatorExpr {
        var unsafe *node = ctx->alloc<BinaryOperatorExpr>()
        node->kind  = ExprKind::BinaryOperatorExpr
        node->range = range
        node->lhs   = lhs
        node->rhs   = rhs
        // Unwrapped, as in UnaryOperatorExpr::create.
        node->op_token     = ctx->unwrap_token(op_token)
        node->resolved_op  = &null
        node->op_via_free  = false
        node->op_rewrite   = OpRewrite::None
        node->tag_eq       = false
        node->no_wrap      = false
        node->op_instance  = &null
        node->type_cmp_lhs = &null
        node->type_cmp_rhs = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *BinaryOperatorExpr {
        var unsafe *node = ctx->alloc<BinaryOperatorExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::BinaryOperatorExpr
        node->range         = range
        node->lhs           = &null
        node->rhs           = &null
        node->resolved_op   = &null
        node->op_via_free   = false
        node->op_rewrite    = OpRewrite::None
        node->tag_eq        = false
        node->no_wrap       = false
        node->op_instance   = &null
        node->type_cmp_lhs  = &null
        node->type_cmp_rhs  = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::BinaryOperatorExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::BinaryOperatorExpr
    }
}

///
///  AssignOperatorExpr
///  x = y | x += y | x -= y | x **= y | etc.
///  Right-associative. Distinct from BinaryOperatorExpr for visitor dispatch.
///
pub class AssignOperatorExpr derives Expr {
    pub var lhs: unsafe *Expr
    pub var rhs: unsafe *Expr
    /// Never `:`: a `name: value` argument is a NamedArgExpr, and `create`
    /// rejects that shape.
    pub var op_token: Token

    /// The user operator overload resolution selected, or null for a builtin
    /// operator. Written by X (OperatorTyping / MemberTyping / CastTyping),
    /// read by OperatorLowering, which rewrites the node into the call.
    pub var resolved_op: unsafe *Decl = &null
    pub var op_via_free: bool         = false ///< a free `op` found by ADL (every operand is an argument).
    /// The registry entry of a GENERIC free operator's instance, written by X
    /// with resolved_op. OperatorLowering copies it onto the
    /// call it mints, and EmitIR spells the instance's arguments from it.
    pub var op_instance: unsafe *InstanceEntry = &null
    /// `self.f[k] = e` in a constructor that builds array field f element by
    /// element: this write constructs element k (it did not exist before),
    /// so S_pre spells it `init_at(k, e)` on f's slot, not an assignment.
    /// One writer: CtorInitCheck. Read by EmitIR.
    pub var ci_elem_init: bool = false
    /// `<<=` / `>>=` whose count is proven in [0, W) (SHIFT spec §4): EmitIR
    /// leaves the count mask out (see BinaryOperatorExpr::no_wrap). Written by
    /// X (OperatorTyping, a constant or masked count) and IterLowering.
    pub var no_wrap: bool = false

    pub static fn create(ctx:      unsafe *ASTContext,
                         range:    SourceRange,
                         lhs:      unsafe *Expr,
                         rhs:      unsafe *Expr,
                         op_token: Token) -> unsafe *AssignOperatorExpr {
        if ctx->unwrap_token(op_token).kind == TokenKind::OpColon {
            kairo::std::ice_fail(
                "AssignOperatorExpr: `:` is not an assignment; a named argument is a NamedArgExpr",
            )
        }

        var unsafe *node = ctx->alloc<AssignOperatorExpr>()
        node->kind  = ExprKind::AssignOperatorExpr
        node->range = range
        node->lhs   = lhs
        node->rhs   = rhs
        // Unwrapped, as in UnaryOperatorExpr::create.
        node->op_token    = ctx->unwrap_token(op_token)
        node->resolved_op = &null
        node->op_via_free = false
        node->no_wrap     = false
        node->op_instance = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *AssignOperatorExpr {
        var unsafe *node = ctx->alloc<AssignOperatorExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::AssignOperatorExpr
        node->range         = range
        node->lhs           = &null
        node->rhs           = &null
        node->resolved_op   = &null
        node->op_via_free   = false
        node->no_wrap       = false
        node->op_instance   = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::AssignOperatorExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::AssignOperatorExpr
    }
}

///
///  ImplConformanceExpr
///  T impl Interface produces bool.
///
pub class ImplConformanceExpr derives Expr {
    pub var subject: unsafe *Type ///< the type being tested.
    pub var inter:   unsafe *Type ///< the inter being checked.

    static fn create(ctx:     *ASTContext,
                     range:   SourceRange,
                     subject: unsafe *Type,
                     inter:   unsafe *Type) -> unsafe *ImplConformanceExpr {
        var unsafe *node = ctx->alloc<ImplConformanceExpr>()
        node->kind    = ExprKind::ImplConformanceExpr
        node->range   = range
        node->subject = subject
        node->inter   = inter
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ImplConformanceExpr {
        var unsafe *node = ctx->alloc<ImplConformanceExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::ImplConformanceExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ImplConformanceExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ImplConformanceExpr
    }
}

///
///  DerivesRelationExpr
///  T derives Base produces bool.
///
pub class DerivesRelationExpr derives Expr {
    pub var subject: unsafe *Type
    pub var base:    unsafe *Type

    static fn create(ctx:     *ASTContext,
                     range:   SourceRange,
                     subject: unsafe *Type,
                     base:    unsafe *Type) -> unsafe *DerivesRelationExpr {
        var unsafe *node = ctx->alloc<DerivesRelationExpr>()
        node->kind    = ExprKind::DerivesRelationExpr
        node->range   = range
        node->subject = subject
        node->base    = base
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *DerivesRelationExpr {
        var unsafe *node = ctx->alloc<DerivesRelationExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::DerivesRelationExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::DerivesRelationExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::DerivesRelationExpr
    }
}

///
///  IfExpr
///  Grammar:  'if' expr '{' expr '}'
///            ('else' 'if' expr '{' expr '}')*
///            'else' '{' expr '}'
///
///  Expression-form conditional. Each branch is a SINGLE expression that is the
///  branch's value (Kairo has no implicit tail-return; statement bodies use
///  ConditionalStmt instead). The final `else` is MANDATORY and parser-enforced:
///  an expression must yield a value on every path.
///
///  Flat representation (no nested IfExpr): the primary arm is
///  `condition`/`then_expr`; zero or more `else if` arms live in `else_ifs`;
///  the trailing `else` value is `else_expr`. Sema walks `else_ifs` in order.
///
pub class IfExpr derives Expr {
    pub struct ElseIf {
        pub var condition: unsafe *Expr ///< the `else if` guard.
        pub var body:      unsafe *Expr ///< single-expression value for this arm.
        pub var range:     SourceRange
    }

    pub var condition: unsafe *Expr
    pub var then_expr: unsafe *Expr
    pub var else_ifs:  FrozenList<Self::ElseIf> ///< zero or more `else if` arms, in order.
    pub var else_expr: unsafe *Expr             ///< mandatory final else value.

    pub static fn create(ctx:       unsafe *ASTContext,
                         range:     SourceRange,
                         condition: unsafe *Expr,
                         then_expr: unsafe *Expr,
                         else_expr: unsafe *Expr) -> unsafe *IfExpr {
        var unsafe *node = ctx->alloc<IfExpr>()
        node->kind  = ExprKind::IfExpr
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->condition = condition
        node->then_expr = then_expr
        node->else_expr = else_expr
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *IfExpr {
        var unsafe *node = ctx->alloc<IfExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::IfExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::IfExpr
    }

    /* OVERRIDE */
    static fn expr_kind() -> ExprKind {
        return ExprKind::IfExpr
    }
}

///
///  PanicOpExpr
///  Lowering-only: never parsed. The C++ PanicLowering needs that no Kairo
///  expression spells (Compiler/Spec/Panic.md#preamble-helpers, §4.4):
///
///    Fwd      `::__kairo_fwd<R>(operand)`: the error `operand` (a panic
///             result that is not Ok) as the panic result R, the node's
///             type: the tag and site word copied, the payload moved. Bit
///             for bit when the two layouts agree, else one case per type.
///    FwdAll   the same with Ok forwarded too (a tail `return g()` whose
///             value type is the caller's).
///    SlotPut  the raw slot `slot` (a local marked raw_slot) built from the
///             prvalue `operand`, in place: `new (&slot.b) box{operand}`.
///             void.
///    SlotTake the slot's value moved out into the result and the slot
///             destroyed, a prvalue of the slot's type. Read once, at the
///             `try`'s dispatch.
///    Holds    `operand` holds error `elem` (a bool), where the result's
///             set is dependent (a generic body, Compiler/Spec/Panic.md#generic-bodies): the tag
///             against `elem`'s type id, which only the instance knows.
///    ErrorRef an lvalue of `elem`, the error `operand` holds, read at
///             `elem`'s place in the set C++ ordered, where Sema
///             cannot say which place that is.
///
///  `operand` is an lvalue for Fwd / FwdAll when it names a held result
///  (`__kairo_p0`), which it moves from. EmitIR spells every name through
///  LowerTargets.
///
pub enum PanicOp derives u8 {
    Fwd,
    FwdAll,
    SlotPut,
    SlotTake,
    Holds,
    ErrorRef,
}

pub fn panic_op_name(k: PanicOp) -> string {
    match k {
        case PanicOp::Fwd {
            return "fwd"
        } case PanicOp::FwdAll {
            return "fwd_all"
        } case PanicOp::SlotPut {
            return "slot_put"
        } case PanicOp::SlotTake {
            return "slot_take"
        } case PanicOp::Holds {
            return "holds"
        } case PanicOp::ErrorRef {
            return "error_ref"
        }
    }
}

pub class PanicOpExpr derives Expr {
    pub var which:   PanicOp      = PanicOp::Fwd
    pub var operand: unsafe *Expr = &null
    pub var slot:    unsafe *Expr = &null
    /// Holds / ErrorRef: the error type asked about (dependent).
    pub var elem: unsafe *Type = &null

    pub static fn create(ctx:     unsafe *ASTContext,
                         range:   SourceRange,
                         which:   PanicOp,
                         operand: unsafe *Expr,
                         slot:    unsafe *Expr) -> unsafe *PanicOpExpr {
        var unsafe *node = ctx->alloc<PanicOpExpr>()
        node->kind    = ExprKind::PanicOpExpr
        node->range   = range
        node->which   = which
        node->operand = operand
        node->slot    = slot
        node->elem    = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::PanicOpExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::PanicOpExpr
    }
}

///
///  TryCatchExpr
///  Grammar:  'try' '{' expr '}'
///            ('catch' ('var'|'const')? identifier ':' type '{' expr '}')*
///            ('catch' ('var'|'const')? identifier? '{' expr '}')?
///
///  Expression-form try/catch. The try body and every catch body is a SINGLE
///  expression (the value of that path). At least one catch arm is required
///  (parser-enforced). Catch arms split into:
///    - typed:   `catch e: Error { v }`          (filter != null)
///    - default: `catch { v }` / `catch e { v }` (filter == null)
///  A default arm is terminal: nothing may follow it (parser-enforced, which
///  also rejects multiple defaults). Exhaustiveness is a sema concern.
///
///  Binding mutability follows the usual rule: bare `e` is mutable, `const e`
///  is immutable, `var e` is the explicit mutable form. `has_binding` is false
///  only for the bare `catch { }` default.
///
pub class TryCatchExpr derives Expr {
    pub struct CatchArm {
        pub var has_binding: bool                   ///< false for bare `catch { }`.
        pub var is_const:    bool                   ///< `const e`; false for `e` / `var e`.
        pub var binding:     unsafe *NamedIdentExpr ///< null when !has_binding.
        pub var filter:      unsafe *Type           ///< null for a default (untyped) arm.
        pub var body:        unsafe *Expr           ///< single-expression branch value.
        pub var range:       SourceRange
        /// Declaration introduced by `binding`; see Statements.k Binding::decl.
        /// Null when !has_binding.
        pub var decl: unsafe *Decl = &null ///< always a VariableDecl; see Binding::decl.
        /// The arm never runs (Statements.k CatchArm::is_dead).
        pub var is_dead: bool = false
        /// A C++ exception arm (Statements.k CatchArm::is_cxx).
        pub var is_cxx: bool = false
    }

    pub var try_expr:   unsafe *Expr
    pub var catch_arms: FrozenList<Self::CatchArm>
    /// The operand's panic set (Statements.k TryCatchStmt::reach).
    pub var reach: FrozenList<unsafe *Type>

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         try_expr: unsafe *Expr) -> unsafe *TryCatchExpr {
        var unsafe *node = ctx->alloc<TryCatchExpr>()
        node->kind  = ExprKind::TryCatchExpr
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->try_expr = try_expr
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TryCatchExpr {
        var unsafe *node = ctx->alloc<TryCatchExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::TryCatchExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::TryCatchExpr
    }

    /* OVERRIDE */
    static fn expr_kind() -> ExprKind {
        return ExprKind::TryCatchExpr
    }
}

///  MatchExpr :  match scrutinee { (case pattern.. (where guard)? { expr })+ }
///
///  Expression-form match. Each case yields a single value expression (held in
///  MatchCase.expression; body stays null in expr form). Exhaustiveness is a
///  sema concern. The scrutinee is the matched operand.
pub class MatchExpr derives Expr {
    pub var scrutinee: unsafe *Expr          = &null
    pub var cases:     FrozenList<MatchCase>

    /// Facts about this match. One writer: PatternChecking.
    /// is_exhaustive: every value of the scrutinee type reaches an arm.
    /// covering_arm:  the arm the remainder falls to (the last arm) when
    ///                exhaustive; -1 otherwise.
    /// open_tail:     exhaustive only because a closed enum's variants are all
    ///                listed; an undeclared discriminant reaches no arm, and
    ///                MatchLowering applies UnmatchedPolicy to it.
    pub var is_exhaustive: bool         = true
    pub var covering_arm:  i32          = -1
    pub var open_tail:     bool         = false
    pub var decision:      unsafe *void = &null ///< PatternCompilation's *DecisionTree. One writer: PatternCompilation; read by MatchLowering and SemaDump.
    /// A match on a `T?` whose first arm is `case null` (Compiler/Spec/Nullables.md#match):
    /// every later arm matches the unwrapped `T`. One writer: X (the match
    /// typing, which also reports a `T?` match without it); read by
    /// PatternChecking and PatternCompilation (arm 0 is no row; the column
    /// is `T`), CoalesceLowering (which splits arm 0 off) and SemaDump.
    pub var null_arm: bool = false

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         scrutinee: unsafe *Expr) -> unsafe *MatchExpr {
        var unsafe *node = ctx->alloc<MatchExpr>()
        node->kind      = ExprKind::MatchExpr
        node->range     = range
        node->scrutinee = scrutinee
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->is_exhaustive = true
        node->covering_arm  = -1
        node->open_tail     = false
        node->decision      = &null
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *MatchExpr {
        var unsafe *node = ctx->alloc<MatchExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::MatchExpr
        node->range         = range
        node->scrutinee     = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->is_exhaustive = true
        node->covering_arm  = -1
        node->open_tail     = false
        node->decision      = &null
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::MatchExpr
    }

    /* OVERRIDE */
    static fn expr_kind() -> ExprKind {
        return ExprKind::MatchExpr
    }
}

///
///  RangeExpr
///  x..y | x..=y | ..y | x.. | ..
///
pub class RangeExpr derives Expr {
    pub var begin:        unsafe *Expr ///< null for `..y` or `..`
    pub var end:          unsafe *Expr ///< null for `x..` or `..`
    pub var is_inclusive: bool ///< true for `..=`
    pub var as_index:     bool         = false ///< the index of a subscript (`a[i..j]`); written by X (MemberTyping).

    pub static fn create(ctx:          *ASTContext,
                         range:        SourceRange,
                         begin:        unsafe *Expr,
                         end:          unsafe *Expr,
                         is_inclusive: bool) -> unsafe *RangeExpr {
        var unsafe *node = ctx->alloc<RangeExpr>()
        node->kind         = ExprKind::RangeExpr
        node->range        = range
        node->begin        = begin
        node->end          = end
        node->is_inclusive = is_inclusive
        node->as_index     = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *RangeExpr {
        var unsafe *node = ctx->alloc<RangeExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::RangeExpr
        node->range         = range
        node->as_index      = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::RangeExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::RangeExpr
    }
}

///
///  UnwrapExpr
///  unwrap!(expr)
///
///  The value of a nullable, or the program aborts with a message naming
///  the expression and where it is (Compiler/Spec/Nullables.md#unwrap). Not a panic. `range`
///  covers `unwrap!(...)`; the operand's own range is the text the message
///  quotes.
///
pub class UnwrapExpr derives Expr {
    pub var operand: unsafe *Expr

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *UnwrapExpr {
        var unsafe *node = ctx->alloc<UnwrapExpr>()
        node->kind    = ExprKind::UnwrapExpr
        node->range   = range
        node->operand = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *UnwrapExpr {
        var unsafe *node = ctx->alloc<UnwrapExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::UnwrapExpr
        node->range         = range
        node->operand       = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::UnwrapExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::UnwrapExpr
    }
}

///
///  DefinedExpr
///  `defined!(NAME)` the preprocessor could not answer from Kairo's macro
///  table: a clang macro (predefined, or from an ffi header) or none.
///  EvalIfFolding folds it to a bool literal (Compiler/Spec/Eval.md#defined).
///
pub class DefinedExpr derives Expr {
    pub var name: Token

    pub static fn create(ctx: *ASTContext, range: SourceRange, name: Token) -> unsafe *DefinedExpr {
        var unsafe *node = ctx->alloc<DefinedExpr>()
        node->kind  = ExprKind::DefinedExpr
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::DefinedExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::DefinedExpr
    }
}

///
///  AttributedExpr
///  `@name operand` / `@name(args) operand`: an attribute applied to an
///  expression (`var *cfg = @create Config(8080)`). `name` is the identifier
///  after `@`; `args` the attribute's argument list, empty when none was
///  written (`has_args` tells `@a()` from `@a`); `operand` the unary
///  expression it applies to. `range` covers all three.
///
pub class AttributedExpr derives Expr {
    pub var name:     Token
    pub var args:     FrozenList<unsafe *Expr>
    pub var has_args: bool                     = false
    pub var operand:  unsafe *Expr

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         name:    Token,
                         operand: unsafe *Expr) -> unsafe *AttributedExpr {
        var unsafe *node = ctx->alloc<AttributedExpr>()
        node->kind     = ExprKind::AttributedExpr
        node->range    = range
        node->name     = name
        node->args     = create_empty_frozen_list<unsafe *Expr>()
        node->has_args = false
        node->operand  = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *AttributedExpr {
        var unsafe *node = ctx->alloc<AttributedExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::AttributedExpr
        node->range         = range
        node->args          = create_empty_frozen_list<unsafe *Expr>()
        node->has_args      = false
        node->operand       = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::AttributedExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::AttributedExpr
    }
}

///
///  AwaitExpr
///  await expr
///
pub class AwaitExpr derives Expr {
    pub var operand: unsafe *Expr

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *AwaitExpr {
        var unsafe *node = ctx->alloc<AwaitExpr>()
        node->kind    = ExprKind::AwaitExpr
        node->range   = range
        node->operand = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *AwaitExpr {
        var unsafe *node = ctx->alloc<AwaitExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::AwaitExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::AwaitExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::AwaitExpr
    }
}

///
///  SpawnExpr
///  spawn expr
///
pub class SpawnExpr derives Expr {
    pub var operand: unsafe *Expr

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *SpawnExpr {
        var unsafe *node = ctx->alloc<SpawnExpr>()
        node->kind    = ExprKind::SpawnExpr
        node->range   = range
        node->operand = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SpawnExpr {
        var unsafe *node = ctx->alloc<SpawnExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::SpawnExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::SpawnExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::SpawnExpr
    }
}

///
///  ThreadExpr
///  thread expr
///
pub class ThreadExpr derives Expr {
    pub var operand: unsafe *Expr

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *ThreadExpr {
        var unsafe *node = ctx->alloc<ThreadExpr>()
        node->kind    = ExprKind::ThreadExpr
        node->range   = range
        node->operand = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ThreadExpr {
        var unsafe *node = ctx->alloc<ThreadExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::ThreadExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ThreadExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ThreadExpr
    }
}

///
///  SizeOfExpr
///  sizeof T | sizeof(T)
///
///
///  ConstraintExpr
///  T impl Foo | T derives Base
///
///  A type conformance constraint used inside `requires` clauses. `lhs` is the
///  constrained operand as parsed (a NamedIdentExpr / ChainExpr naming the
///  generic param or type; sema resolves it to a type), `op_token` is `impl` or
///  `derives`, `rhs` is the interface/base type. Bool-typed at compile time.
///  Sema classifies these as conformance conjuncts (feeding the bound table)
///  as opposed to value predicates like `sizeof T > 10`.
///
pub class ConstraintExpr derives Expr {
    pub var lhs:      unsafe *Expr ///< the constrained operand (names a type).
    pub var rhs:      unsafe *Type ///< the interface/base type.
    pub var op_token: Token        ///< KwImpl or KwDerives.

    pub static fn create(ctx:      unsafe *ASTContext,
                         range:    SourceRange,
                         lhs:      unsafe *Expr,
                         rhs:      unsafe *Type,
                         op_token: Token) -> unsafe *ConstraintExpr {
        var unsafe *node = ctx->alloc<ConstraintExpr>()
        node->kind  = ExprKind::ConstraintExpr
        node->range = range
        node->lhs   = lhs
        node->rhs   = rhs
        // Unwrapped, as in UnaryOperatorExpr::create.
        node->op_token = ctx->unwrap_token(op_token)
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ConstraintExpr {
        var unsafe *node = ctx->alloc<ConstraintExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::ConstraintExpr
        node->range         = range
        node->lhs           = &null
        node->rhs           = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /// true if op is `derives` (nominal); false if `impl` (structural).
    pub fn is_derives(self) -> bool {
        return self.op_token.kind == TokenKind::KwDerives
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ConstraintExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ConstraintExpr
    }
}

pub class SizeOfExpr derives Expr {
    pub var type_arg: unsafe *Type

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         type_arg: unsafe *Type) -> unsafe *SizeOfExpr {
        var unsafe *node = ctx->alloc<SizeOfExpr>()
        node->kind     = ExprKind::SizeOfExpr
        node->range    = range
        node->type_arg = type_arg
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SizeOfExpr {
        var unsafe *node = ctx->alloc<SizeOfExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::SizeOfExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::SizeOfExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::SizeOfExpr
    }
}

///
///  AlignOfExpr
///  alignof T | alignof(T)
///
pub class AlignOfExpr derives Expr {
    pub var type_arg: unsafe *Type

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         type_arg: unsafe *Type) -> unsafe *AlignOfExpr {
        var unsafe *node = ctx->alloc<AlignOfExpr>()
        node->kind     = ExprKind::AlignOfExpr
        node->range    = range
        node->type_arg = type_arg
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *AlignOfExpr {
        var unsafe *node = ctx->alloc<AlignOfExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::AlignOfExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::AlignOfExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::AlignOfExpr
    }
}

/// A type fact a condition can read (Compiler/Spec/Eval.md#deferred-conditions). Only the facts Sema has
/// an oracle for exist -- ClassLifecycle's two triviality bits -- so the
/// late `eval if` fold can answer every one of them before C++ does, and C++
/// computes each with the clang builtin of the same name. None is the
/// parser's "this name is not one".
pub enum TypeTraitKind derives u8 {
    None = 0,
    TriviallyCopyable,
    TriviallyDestructible,
}

/// The fact the intrinsic \p name spells (without its `!`), or None.
pub fn type_trait_of(const name: string) -> TypeTraitKind {
    if name == LangIntrinsics::is_trivially_copyable() {
        return TypeTraitKind::TriviallyCopyable
    }

    if name == LangIntrinsics::is_trivially_destructible() {
        return TypeTraitKind::TriviallyDestructible
    }

    return TypeTraitKind::None
}

/// \p k as Kairo spells it, without its `!`.
pub fn type_trait_spelling(k: TypeTraitKind) -> string {
    if k == TypeTraitKind::TriviallyCopyable {
        return LangIntrinsics::is_trivially_copyable()
    }

    if k == TypeTraitKind::TriviallyDestructible {
        return LangIntrinsics::is_trivially_destructible()
    }

    return ""
}

/// The clang builtin that computes \p k: what C++ answers for the same type.
pub fn type_trait_cxx(k: TypeTraitKind) -> string {
    if k == TypeTraitKind::TriviallyCopyable {
        return "__is_trivially_copyable"
    }

    if k == TypeTraitKind::TriviallyDestructible {
        return "__is_trivially_destructible"
    }

    return ""
}

///
///  TypeTraitExpr
///  is_trivially_copyable!(T) | is_trivially_destructible!(T)
///
pub class TypeTraitExpr derives Expr {
    pub var fact:     TypeTraitKind = TypeTraitKind::None
    pub var type_arg: unsafe *Type

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         fact:     TypeTraitKind,
                         type_arg: unsafe *Type) -> unsafe *TypeTraitExpr {
        var unsafe *node = ctx->alloc<TypeTraitExpr>()
        node->kind     = ExprKind::TypeTraitExpr
        node->range    = range
        node->fact     = fact
        node->type_arg = type_arg
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::TypeTraitExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::TypeTraitExpr
    }
}

///
///  TypeOfExpr
///  typeof expr | typeof(expr)
///
pub class TypeOfExpr derives Expr {
    pub var operand:       unsafe *Expr
    pub var resolved_type: *Type?       = &null ///< set by sema.

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *TypeOfExpr {
        var unsafe *node = ctx->alloc<TypeOfExpr>()
        node->kind    = ExprKind::TypeOfExpr
        node->range   = range
        node->operand = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TypeOfExpr {
        var unsafe *node = ctx->alloc<TypeOfExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::TypeOfExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::TypeOfExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::TypeOfExpr
    }
}

///
///  EvalExpr
///  eval expr forces compile-time evaluation.
///
pub class EvalExpr derives Expr {
    pub var operand: unsafe *Expr

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *EvalExpr {
        var unsafe *node = ctx->alloc<EvalExpr>()
        node->kind    = ExprKind::EvalExpr
        node->range   = range
        node->operand = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *EvalExpr {
        var unsafe *node = ctx->alloc<EvalExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::EvalExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::EvalExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::EvalExpr
    }
}

///
///  UnsafeExpr
///  unsafe expr permits otherwise-restricted operations.
///
pub class UnsafeExpr derives Expr {
    pub var operand: unsafe *Expr

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *UnsafeExpr {
        var unsafe *node = ctx->alloc<UnsafeExpr>()
        node->kind    = ExprKind::UnsafeExpr
        node->range   = range
        node->operand = operand
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *UnsafeExpr {
        var unsafe *node = ctx->alloc<UnsafeExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::UnsafeExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::UnsafeExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::UnsafeExpr
    }
}

///
///  DeleteExpr
///  @cxx::delete p | @cxx::delete [] p    (C++'s `delete p` / `delete[] p`)
///
///  Kairo has no `delete` expression (0.2.0): a bare `delete p` is S091E,
///  parsed into this node only for recovery (is_cxx false); `@destroy p`
///  frees Kairo memory. `@cxx::delete` frees memory C++'s own allocation
///  made (c-cpp-memory.mdx, "Memory that belongs to C++").
///
pub class DeleteExpr derives Expr {
    pub var operand:  unsafe *Expr
    pub var is_array: bool
    /// Written `@cxx::delete`: the only form that reaches codegen.
    pub var is_cxx: bool = false

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         operand:  unsafe *Expr,
                         is_array: bool) -> unsafe *DeleteExpr {
        var unsafe *node = ctx->alloc<DeleteExpr>()
        node->kind     = ExprKind::DeleteExpr
        node->range    = range
        node->operand  = operand
        node->is_array = is_array
        node->is_cxx   = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *DeleteExpr {
        var unsafe *node = ctx->alloc<DeleteExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::DeleteExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::DeleteExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::DeleteExpr
    }
}

///
///  CxxNewExpr
///  @cxx::new T(args) | @cxx::new [T; n]    (C++'s `new T(args)` / `new T[n]`)
///
///  An `unsafe *T` from C++'s own allocation, for memory a C++ library will
///  free (c-cpp-memory.mdx). The single form keeps the construction as Kairo
///  types it, `T(args)` (init: the constructor is chosen as for any `T(args)`),
///  and C++ receives `new T(<init>)`, which C++17 initializes in place from
///  the prvalue: no copy or move, so a NON_TRANSFER T is fine. The array form
///  keeps `sizeof T` (elem_size, a SizeOfExpr whose type_arg is T) rather than
///  a bare type, so every pass that plans a sizeof operand complete plans T
///  complete, as `new T[n]` needs; and the count.
///
pub class CxxNewExpr derives Expr {
    pub var init:      unsafe *Expr = &null ///< single form: `T(args)`
    pub var elem_size: unsafe *Expr = &null ///< array form: `sizeof T`
    pub var count:     unsafe *Expr = &null ///< array form: n

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         init:  unsafe *Expr) -> unsafe *CxxNewExpr {
        var unsafe *node = ctx->alloc<CxxNewExpr>()
        node->kind      = ExprKind::CxxNewExpr
        node->range     = range
        node->init      = init
        node->elem_size = &null
        node->count     = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_array(ctx:       *ASTContext,
                               range:     SourceRange,
                               elem_size: unsafe *Expr,
                               count:     unsafe *Expr) -> unsafe *CxxNewExpr {
        var unsafe *node = ctx->alloc<CxxNewExpr>()
        node->kind      = ExprKind::CxxNewExpr
        node->range     = range
        node->init      = &null
        node->elem_size = elem_size
        node->count     = count
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *CxxNewExpr {
        var unsafe *node = ctx->alloc<CxxNewExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::CxxNewExpr
        node->range         = range
        node->init          = &null
        node->elem_size     = &null
        node->count         = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub fn is_array(self) -> bool {
        return self.elem_size != &null
    }

    /// The element type of the array form.
    pub fn elem_type(self) -> unsafe *Type {
        if self.elem_size == &null || !isa<SizeOfExpr>(self.elem_size) {
            return &null
        }

        return cast<SizeOfExpr>(self.elem_size)->type_arg
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::CxxNewExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::CxxNewExpr
    }
}

///
///  PackExpansionExpr
///  foo... variadic unpack expansion.
///
pub class PackExpansionExpr derives Expr {
    pub var operand: unsafe *Expr
    /// The pack is read again after this expansion on some path (MoveCheck),
    /// so it must not forward -- a forward moves each element -- and
    /// EmitIR spells it `xs...`, which copies into a by-value parameter.
    pub var reread: bool = false

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         operand: unsafe *Expr) -> unsafe *PackExpansionExpr {
        var unsafe *node = ctx->alloc<PackExpansionExpr>()
        node->kind    = ExprKind::PackExpansionExpr
        node->range   = range
        node->operand = operand
        node->reread  = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *PackExpansionExpr {
        var unsafe *node = ctx->alloc<PackExpansionExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::PackExpansionExpr
        node->range         = range
        node->reread        = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::PackExpansionExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::PackExpansionExpr
    }
}

/// Which `as` was written. The word after `as` selects a DIFFERENT ladder,
/// not a hint on the same one: `static` disables the dynamic rungs, `const`
/// asserts the const-cast rung and errors on anything else, `unsafe` opens
/// the reinterpret rung. CastTyping dispatches on this before it looks at
/// either type.
pub enum CastMode derives u8 {
    Default = 0, ///< `a as T`
    Static,      ///< `a as static T`
    Const,       ///< `a as const T`
    Unsafe,      ///< `a as unsafe *T`
}

///
///  TypeCastExpr
///  expr as Type
///  expr as unsafe *Derived   (unsafe pointer cast)
///
pub class TypeCastExpr derives Expr {
    pub var operand: unsafe *Expr
    pub var target:  unsafe *Type

    /// Mirrors `mode == CastMode::Unsafe`; the printer and ClangDiagAdapter
    /// still read the bool.
    pub var is_unsafe: bool
    pub var mode:      CastMode = CastMode::Default

    /// The user operator overload resolution selected, or null for a builtin
    /// operator. Written by X (OperatorTyping / MemberTyping / CastTyping),
    /// read by OperatorLowering, which rewrites the node into the call.
    pub var resolved_op: unsafe *Decl = &null
    pub var op_via_free: bool         = false ///< a free `op` found by ADL (every operand is an argument).

    /// The converting constructor rung 5d selected, or null. Separate from
    /// resolved_op: a constructor has no op_token to spell. OperatorLowering
    /// rewrites the cast into the construction.
    pub var resolved_ctor: unsafe *Decl = &null

    /// A widening the implicit rules would also do (a lattice I/W rung or a
    /// pointer upcast). Written by CastTyping; read where the slot's type is
    /// only known after the cast was typed -- a call argument, before
    /// overload resolution picks the parameter -- to decide the
    /// redundant-cast lint there.
    pub var widening: bool = false

    /// `p as (*D)?` from a `*B` with D below B: the CHECKED downcast
    /// (casting.md), null when the dynamic type is not a D. Written by
    /// CastTyping; EmitIR spells it as a dynamic_cast whose null pointer
    /// becomes the null nullable (a static_cast to `Nullable<D*>` would
    /// neither check nor map null).
    pub var checked_downcast: bool = false

    /// `p as *D` from a `*B` with D below B: the ASSERTING downcast
    /// (Compiler/Spec/Panic.md#crashes-are-not-panics), which crashes when the dynamic type is not a D.
    /// Written by CastTyping; OperatorLowering expands it into a
    /// statement expression over a `dynamic_only` cast and a crash call,
    /// and clears it.
    pub var asserting_downcast: bool = false

    /// The bare `dynamic_cast<D*>(p)`, a null pointer on a miss: only
    /// OperatorLowering's expansion of an asserting downcast makes one.
    /// EmitIR spells it as is.
    pub var dynamic_only: bool = false

    /// E, for `v as E` (or `v as E?`) into a CLOSED plain enum (not
    /// `@open`) from an operand that is not a constant, else null: the value
    /// is checked against E's variants at run time and a miss crashes (the crash family, Compiler/Spec/Panic.md#crashes-are-not-panics). Written
    /// by CastTyping once the operand is known not to fold (a constant is
    /// checked there, at compile time); OperatorLowering builds the check.
    pub var enum_check: unsafe *Decl = &null

    /// `p as unsafe *B` between two record pointees one of which derives
    /// from the other: the address moves to (or back from) the base
    /// subobject, as an implicit upcast already does. A reinterpret there
    /// is right only for a first base at offset 0; through any other base
    /// it reads the wrong fields. Written by CastTyping; EmitIR spells it
    /// as static_cast (a C-style cast when it also drops a qualifier).
    pub var base_adjust: bool = false

    pub static fn create(ctx:       unsafe *ASTContext,
                         range:     SourceRange,
                         operand:   unsafe *Expr,
                         target:    unsafe *Type,
                         is_unsafe: bool = false,
                         mode:      CastMode = CastMode::Default) -> unsafe *TypeCastExpr {
        var unsafe *node = ctx->alloc<TypeCastExpr>()
        node->kind          = ExprKind::TypeCastExpr
        node->range         = range
        node->operand       = operand
        node->target        = target
        node->is_unsafe     = is_unsafe
        node->mode          = mode
        node->resolved_op   = &null
        node->op_via_free   = false
        node->resolved_ctor = &null
        node->base_adjust   = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TypeCastExpr {
        var unsafe *node = ctx->alloc<TypeCastExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::TypeCastExpr
        node->range         = range
        node->resolved_op   = &null
        node->op_via_free   = false
        node->resolved_ctor = &null
        node->base_adjust   = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::TypeCastExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::TypeCastExpr
    }
}

///
///  ImplicitBoundaryCastExpr
///  Inserted by sema at FFI call boundaries. Not visible in source.
///  Carries original expr + source type + target ABI type for codegen.
///
pub class ImplicitBoundaryCastExpr derives Expr {
    pub var original:    unsafe *Expr
    pub var source_type: unsafe *Type
    pub var target_type: unsafe *Type

    pub static fn create(ctx:         unsafe *ASTContext,
                         range:       SourceRange,
                         original:    unsafe *Expr,
                         source_type: unsafe *Type,
                         target_type: unsafe *Type) -> unsafe *ImplicitBoundaryCastExpr {
        var unsafe *node = ctx->alloc<ImplicitBoundaryCastExpr>()
        node->kind        = ExprKind::ImplicitBoundaryCastExpr
        node->range       = range
        node->original    = original
        node->source_type = source_type
        node->target_type = target_type
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ImplicitBoundaryCastExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ImplicitBoundaryCastExpr
    }
}

// // free function: is_primary_expr
// eval fn is_primary_expr(expr: *Expr) -> bool {
//     switch expr->kind {
//         case ExprKind::IntegerLiteralExpr:
//         case ExprKind::FloatingLiteralExpr:
//         case ExprKind::StringLiteralExpr:
//         case ExprKind::CharacterLiteralExpr:
//         case ExprKind::BooleanLiteralExpr:
//         case ExprKind::NullLiteralExpr:
//         case ExprKind::ListLiteralExpr:
//         case ExprKind::TupleLiteralExpr:
//         case ExprKind::SetLiteralExpr:
//         case ExprKind::MapLiteralExpr:
//         case ExprKind::ArrayInitializerExpr:
//         case ExprKind::VectorInitializerExpr:
//         case ExprKind::MapInitializerExpr:
//         case ExprKind::SetInitializerExpr:
//         case ExprKind::NamedInitializerExpr: // ambiguous
//         case ExprKind::AnonInitializerExpr:
//         case ExprKind::ChainExpr: // ambiguous
//         case ExprKind::NamedIdentExpr:
//         case ExprKind::SelfExpr:
//         case ExprKind::GroupingExpr:
//         case ExprKind::IfExpr:
//         case ExprKind::InlineTryCatchExpr:
//         case ExprKind::ClosureExpr:
//         case ExprKind::MacroInvocationExpr: // ambiguous
//         case ExprKind::SizeOfExpr:
//         case ExprKind::AlignOfExpr:
//         case ExprKind::TypeOfExpr:
//         case ExprKind::AwaitExpr:
//         case ExprKind::SpawnExpr:
//         case ExprKind::ThreadExpr:
//         case ExprKind::EvalExpr:
//         case ExprKind::UnaryOperatorExpr: // ambiguous
//         case ExprKind::PackExpansionExpr: // ambiguous
//             return true;

//         default:
//             return false;
//     }

//     return false;
// }
///
///  ParenExpr
///  ( expr )
///
///  Source-fidelity only. See ExprKind::ParenExpr.
///
pub class ParenExpr derives Expr {
    pub var inner: unsafe *Expr

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         inner: unsafe *Expr) -> unsafe *ParenExpr {
        var unsafe *node = ctx->alloc<ParenExpr>()
        node->kind  = ExprKind::ParenExpr
        node->range = range
        node->inner = inner
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ParenExpr {
        var unsafe *node = ctx->alloc<ParenExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::ParenExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /// Strips any number of nested ParenExpr layers. What sema/codegen want
    /// whenever a Verbatim-parsed tree reaches them.
    fn strip(self) -> unsafe *Expr {
        var unsafe *e = self.inner
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        return e
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ParenExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ParenExpr
    }
}

///
///  VerbatimExpr
///  an unmodelled source span, reproduced as written
///
///  Source-fidelity only. See ExprKind::VerbatimExpr.
///
pub class VerbatimExpr derives Expr {
    /// The exact source span to reproduce. `range` (from Expr) covers the same
    /// text; `span` is kept separate so a future lowering can rewrite `range`
    /// without losing what to print.
    pub var span: SourceRange

    static fn create(ctx:   *ASTContext,
                     range: SourceRange,
                     span:  SourceRange) -> unsafe *VerbatimExpr {
        var unsafe *node = ctx->alloc<VerbatimExpr>()
        node->kind  = ExprKind::VerbatimExpr
        node->range = range
        node->span  = span
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *VerbatimExpr {
        var unsafe *node = ctx->alloc<VerbatimExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::VerbatimExpr
        node->range         = range
        node->span          = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::VerbatimExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::VerbatimExpr
    }
}

/// How a closure holds one captured binding, as ClosureCaptures decided it
/// (Sema/Check/CaptureAnalysis.k) and EmitIR spells it in the lambda's
/// capture list (Compiler/Spec/Codegen.md#emitir, Closures).
///
///   Copy        its own copy (`x`): no list, or `|x|`.
///   Move        its own value, moved in (`x = static_cast<T&&>(x)`): a by-copy
///               capture of a MOVE type (ownership.md, Default capture).
///   Ptr         a pointer to the original (`x = &x`): `|*x|`, `|*|`.
///   ConstPtr    a `*const T` to it (`x = static_cast<const T*>(&x)`).
///   Self        the enclosing `self`, a pointer already (`this`, or an
///               extension member's receiver parameter).
///
/// A binding an enclosing closure already holds by pointer is that pointer
/// inside it (ExprTyper::_capture_view), so an inner closure copies the
/// pointer (Copy) or converts it (ConstPtr with `via_ptr`), never takes its
/// address again.
pub enum CaptureMode derives u8 {
    Copy,
    Move,
    Ptr,
    ConstPtr,
    Receiver, // `self` (a method's receiver); not `Self`, a Stage 1 keyword
}

///
///  ClosureExpr
///  fn <T> (x: T, y: i32)|captured| -> i32 { x + y + captured }
///  fn (x: i32) { std::print(x) }
///
///  params, generics, captures, return type, and body are all parsed by
///  DeclParse since they share structure with function declarations.
///  The body is a *Stmt (block statement) or *Expr (single expression).
///
pub class ClosureExpr derives Expr {
    pub struct Capture {
        pub var name:     unsafe *NamedIdentExpr ///< the captured variable's name token.
        pub var by_ptr:   bool                   = false ///< true if `|&captured|`, false if `|captured|`.
        pub var is_const: bool                   = false ///< true if `|const &captured|`, false otherwise.
    }

    pub var captures:       FrozenList<Self::Capture> ///< captured variables, in source order.
    pub var params:         FrozenList<unsafe *ParamDecl>
    pub var generic_params: FrozenList<unsafe *GenericParamDecl>
    pub var body_block:     unsafe *CompoundStmt                 = &null
    pub var body_expr:      unsafe *Expr                         = &null
    pub var return_type:    unsafe *Type ///< null if inferred.
    pub var body_kind:      FnBodyKind                           = FnBodyKind::None
    pub var modifiers:      FnModifier                           = FnModifier::None
    /// `fn (x: i32) panic(E) -> T`: the declared set, as on FunctionDecl.
    pub var panic_set: FrozenList<unsafe *Type>
    /// As on FunctionDecl: the specifier as written and the parameter
    /// list's `)`, for fix-its; the final set and whether it is readable.
    pub var panic_range: SourceRange
    pub var params_end:  SourceRange
    pub var panic_eff:   FrozenList<unsafe *Type>
    pub var panic_state: PanicSetState            = PanicSetState::None
    /// As on FunctionDecl: the lambda's C++ result when it panics.
    pub var panic_result:        unsafe *Type = &null
    pub var is_variadic:         bool         = false ///< trailing `...name: T` pack param.
    pub var is_noreturn:         bool         = false
    pub var explicit_no_capture: bool         = false
    /// `|...|` / `||` as written, for a fix-it; invalid when there is none.
    pub var capture_range: SourceRange

    /// What the closure holds, decided once by ClosureCaptures (CHECK) and
    /// read by MoveCheck, FinallyLowering and EmitIR: the captured bindings
    /// in first-use order (a named list's order for a named list), each
    /// with its mode, parallel. `cap_via_ptr[i]`: an enclosing closure holds
    /// `cap_decls[i]` by pointer, so the name is that pointer here.
    /// `caps_resolved` is false until the check has run; EmitIR ICEs on it.
    pub var cap_decls:   FrozenList<unsafe *Decl>
    pub var cap_modes:   FrozenList<CaptureMode>
    pub var cap_via_ptr: FrozenList<bool>
    /// The first use of each capture in the closure (a named capture's own
    /// name in the list), parallel: what MoveCheck reads as the capture's
    /// read. The tree's, before any lowering rebuilds it.
    pub var cap_uses:      FrozenList<unsafe *NamedIdentExpr>
    pub var caps_resolved: bool                               = false

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *ClosureExpr {
        var unsafe *node = ctx->alloc<ClosureExpr>()
        node->kind          = ExprKind::ClosureExpr
        node->range         = range
        node->body_kind     = FnBodyKind::None
        node->body_block    = &null
        node->body_expr     = &null
        node->return_type   = &null
        node->capture_range = SourceRange::invalid()
        node->caps_resolved = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ClosureExpr {
        var unsafe *node = ctx->alloc<ClosureExpr>()
        node->kind          = ExprKind::RecoveryExpr
        node->recovery_kind = ExprKind::ClosureExpr
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn classof(ptr: *const Expr) -> bool {
        return ptr->kind == ExprKind::ClosureExpr
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ClosureExpr
    }
}
