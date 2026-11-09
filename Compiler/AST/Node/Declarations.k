/// --- The Kairo Project ---------------------- AST/Node/Declarations.k --- ///
///
///   Declaration-position AST nodes.
///
///   Every concrete Decl subclass sets `kind` to its DeclKind and provides
///   `create` / `create_error` factories plus `classof` / `decl_kind` for the
///   RTTI-free casting system (see Casting.k).
///
///   Scope-owning decls (ModuleDecl, ClassDecl, StructDecl, EnumDecl,
///   UnionDecl, InterfaceDecl, ExtensionDecl, FunctionDecl) derive DeclContext
///   and call init_dc() in create(). Redeclarable decls (functions, the five
///   type kinds, modules) derive Redeclarable::<Self> and call init_redecl().
///   Generic-carrying decls derive TemplateParams::<Self>.
///
///   NOTE: ASTContext::alloc does NOT run constructors. Every field a node
///         relies on must be assigned explicitly in `create`. FrozenList
///         members are populated by the parser via from_buf(..., ctx) even
///         when empty (size 0).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Kind::DeclKind::DeclKind
import AST::Mixin::FFILinkage::FFILinkage
import AST::Mixin::Redeclarable::Redeclarable
import AST::Mixin::TemplateParams::TemplateParams
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Statements::CompoundStmt
import AST::ParamMode::ParamMode
import Location::SourceRange::SourceRange
import Resolution::ModulePath::ModulePath
import Token::Token::Token

/// Specialization form of a generic declaration. Drives disambiguation and
/// sema template selection. See issue #68.
///
///   None      plain decl, no `<...>` involvement            `fn foo`
///   Primary   `<>`-introduced primary generic template      `class <> Box<T>`
///             (also the classic `class <T> Box` primary form)
///   Explicit  full explicit specialization                  `fn <> sum<i32>`
///   Partial   partial specialization (class/struct/union)   `class <> Box<[T]>`
///
/// \note Only Primary declarations *own* the generic-ness of a name for
///       parser disambiguation. Explicit/Partial are specializations OF an
///       existing primary and must not, by themselves, mark a name generic;
///       if no primary exists, sema (type resolve) reports the error.
pub enum SpecKind derives u8 {
    None = 0,
    Primary,
    Explicit,
    Partial,
    ///   Instantiated  implicit instantiation node minted by the registry on
    ///                 first concrete mention. Never written by the user, never
    ///                 in a table, never a lookup answer. RecordType::decl for
    ///                 a concrete instance with no explicit spec.
    Instantiated,
}

///
///  Shared small enums
///

/// Linkage / dispatch modifier on a callable. Mirrors the abi_mod grammar
/// production (ffi "c"/"c++", static, virtual, override) plus the plain case.
pub enum AbiKind derives u8 {
    None = 0, ///< no abi modifier; default Kairo linkage.
    Static,   ///< internal linkage, no vtable slot.
    Virtual,  ///< vtable dispatch.
    Override, ///< overrides a base virtual; implies virtual.
}

/// Storage class for VariableDecl / FieldDecl.
pub enum StorageClass derives u8 {
    Var = 0, ///< var      mutable, automatic.
    Const,   ///< const    immutable.
    Static,  ///< static   static storage duration.
    Eval,    ///< eval     compile-time constant.
}

/// Function effect/qualifier bitmask. These mirror the function_mods grammar
/// (const/volatile/unsafe/eval/async/final/panic/inline). Stored as a bitset
/// so a method can be e.g. `const inline`.
@open pub enum FnModifier derives u16 {
    None       = 0,
    IsConst    = 1 << 0,
    IsVolatile = 1 << 1,
    IsUnsafe   = 1 << 2,
    IsEval     = 1 << 3,
    IsAsync    = 1 << 4,
    IsFinal    = 1 << 5,
    IsPanic    = 1 << 6,
    IsInline   = 1 << 7,
    /// Compiler-set only: C++ `constexpr` (usable at compile time AND at
    /// run time), for a field default's thunk in an eval class, which an
    /// eval (consteval) constructor runs (Compiler/Spec/Eval.md#eval-classes), and for the builtin
    /// string's literal and empty constructors, which build compile-time
    /// strings (2a; NameResolution::_literal_ctor_constexpr). Always with
    /// IsInline.
    IsConstexpr = 1 << 8,
}

// Bitset operators. Module-scope Kairo operators, so every module that
// imports this one sees them (the inline C++ definition here was one
// non-inline C++ definition: a duplicate symbol once two TUs include it).
// `|=` returns nothing: every use is a statement, and a returned reference
// has no Stage 1 spelling on a free function.
pub fn op | (a: FnModifier, b: FnModifier) -> FnModifier {
    return ((a as u16) | (b as u16)) as FnModifier
}

pub fn op & (a: FnModifier, b: FnModifier) -> FnModifier {
    return ((a as u16) & (b as u16)) as FnModifier
}


/// How a function body is provided. Drives codegen and the redeclaration
/// "definition wins" merge.
pub enum FnBodyKind derives u8 {
    None = 0, ///< forward declaration / FFI import no body.
    Block,    ///< `{ ... }` a CompoundStmt body.
    Expr,     ///< `= expr` expression-bodied.
    Default,  ///< `= default` compiler-generated.
    Delete,   ///< `= delete` deleted.
    Virtual,  ///< `= virtual` pure virtual (abstract).
}

/// Whether a function's or closure's final panic set (`panic_eff`) can be
/// read yet (Compiler/Spec/Panic.md#declared-sets: sets are final only past the whole-program
/// barrier).
pub enum PanicSetState derives u8 {
    None = 0, ///< not solved yet (or the function never reached the solve).
    Final,    ///< panic_eff is the set; empty means it does not panic.
    Unknown,  ///< its TU stopped before typing finished: say nothing about it.
    /// A generic body's inferred set that grows without bound: a recursive
    /// call at ever-larger type arguments (`f<Box<T>>` inside `f<T>`) adds
    /// a deeper type each round. Reported at the function; read as Unknown.
    Diverged,
}

/// Lifecycle attribute on a transfer constructor (@copy / @move).
pub enum TransferKind derives u8 {
    NotTransfer = 0, ///< not a transfer ctor.
    Copy,            ///< @copy fn T(self, other: Self)
    Move,            ///< @move fn T(self, other: Self)
}

/// What a function minted for an ADT's layout record is
/// (FunctionDecl::adt_role). None of them has a Kairo spelling, so none has
/// a Kairo body: InterfaceEmitter renders each from its role and form.
pub enum AdtRole derives u8 {
    None = 0,    ///< an ordinary function.
    VariantCtor, ///< builds one variant: `E(__kairo_vt<I>, F&& payload)`.
    CopyCtor,
    MoveCtor,
    CopyAssign,
    MoveAssign,
    Dtor,
    Destroy,       ///< destroys the active payload: `__kairo_destroy()`.
    ConstructFrom, ///< builds a payload from another value's: `__kairo_construct_from(o)`.
    Which,         ///< the variant held, as the tag enum: `__kairo_which()`, in either layout.

    // The Nullable lang item's C++ surface (Compiler/Spec/Nullables.md#the-library-type); only that
    // enum's record has them. Every implicit `T -> T?` / `null -> T?` is one
    // of the four constructors, so none is `explicit`. Kept last:
    // adt_role_is_nullable is the range from NullDefault on.
    NullDefault, ///< `Nullable()`: null.
    NullFrom,  ///< `Nullable(null_t)`: null. Its one parameter carries null_t's type.
    ValueCopy, ///< `Nullable(const T&)`: present, the payload copied in place.
    ValueMove, ///< `Nullable(T&&)`: present, the payload moved in place.
    IsNull,    ///< `bool is_null() const`.
    ValueRef,  ///< `T& __value()`, UNCHECKED: the desugars call it only where non-null is proven.
    ValueCref, ///< `const T& __value() const`, the same.
    Equal,     ///< `operator==`, when T has one: null == null, null != a value. C++20 derives `!=`.
}

/// How an ADT variant with a payload is constructed in C++
/// (EnumVariantDecl::adt_ctor). EnumLayoutLowering decides it; InterfaceEmitter
/// declares the constructor(s) it names and EmitIR calls one.
///
///   Fields   `E(__kairo_vt<I>, F0 f0, F1 f1)`: one non-template constructor
///            taking each field by value. Every field is trivially copied
///            and destroyed, so the move out of the parameter and its
///            destruction run no code: the same program as the lambda form.
///   Lambda   `template <class F> E(__kairo_vt<I>, F&& f)`: the payload is
///            the callable's prvalue, so a field that cannot move is still
///            built in place.
///   Both     a generic ADT, whose fields' movability C++ learns per
///            instance: the field constructor, constrained on it, beside the
///            lambda one. A site picks (VariantInitExpr::field_ctor).
pub enum AdtCtorForm derives u8 {
    Lambda = 0,
    Fields,
    Both,
}

/// \p r is one of the Nullable lang item's surface roles, which
/// InterfaceEmitter renders apart from every other ADT member.
pub fn adt_role_is_nullable(r: AdtRole) -> bool {
    return (r as u8) >= (AdtRole::NullDefault as u8)
}

/// Which of the three forms of an ADT special member a role function is
/// (FunctionDecl::adt_form). A generic ADT declares all three, constrained
/// so that exactly one is selected; a non-generic one only the form its
/// lifecycle facts select.
pub enum AdtForm derives u8 {
    Trivial = 0, ///< `= default`.
    Body,        ///< written out: the payload is destroyed and built by hand.
    Deleted,     ///< `= delete`.
}

/// How a record's `op =` reaches C++ (ClassDecl / StructDecl::assign_form).
/// Assignment is never written in Kairo: it is derived from the transfer
/// constructor. ClassLifecycle decides the derivation and InterfaceEmitter
/// writes it, in the class, since no Kairo decl stands behind it.
pub enum AssignForm derives u8 {
    Implicit = 0, ///< no transfer constructor written: C++'s implicit assignment is the derived one; nothing is declared.
    Default, ///< `= default`: member by member, from a defaulted transfer constructor.
    Body, ///< destroy the old value, then build the new one in place through the transfer constructor.
    Deleted, ///< `= delete`: a deleted transfer, a polymorphic record with a transfer body, or a part that cannot be assigned.
    Constrained, ///< a Body that an instance of a generic record may not allow: Body and Deleted, each under a C++ constraint.
}

/// Inheritance edge: base type + how its members are re-exposed + virtual.
pub struct InheritEdge {
    pub var base:       unsafe *Type ///< the base/interface type reference.
    pub var visibility: u8           ///< 0 None / pub / prot / priv (matches VisibilityKind).
    pub var is_virtual: bool         ///< `derives virtual A`.
    pub var range:      SourceRange
}

///
///  GenericParamDecl
///  <T> | <T impl Foo> | <T derives Base> | <T: class> | <const N: i32>
///  | <...T>
///
///  Owned by a TemplateParams-carrying decl. `kind_bound` is the
///  `: class/struct/enum/union/type` kind bound; `: type` (Duck) is the opt-in
///  to C++-style duck typing, where every member access through the parameter
///  is deferred to instantiation. Without a kind bound and without an
///  impl/derives bound the parameter is OPAQUE: it has no members at all. `impl_bounds` holds the `impl`
///  (structural interface) constraints; `derives_bounds` holds the `derives`
///  (nominal base-class / interface-inheritance) constraints. The two are kept
///  physically separate like ClassDecl's implements/derives_list because
///  they carry different resolution semantics (structural method-set vs nominal
///  lineage + vtable dispatch). `is_const_param` marks a value parameter
///  (`const N: T`), whose type is `value_type`. `is_pack` marks `...T`.
///
pub enum GenericParamKindBound derives u8 {
    Any = 0, ///< no `: kind` bound: T is OPAQUE. No members, no `::`.
    Class,
    Struct,
    Enum,
    Union,
    Duck, ///< `: type`: C++ duck typing, every member access left to clang per instance (-fduck-generics; Compiler/Spec/Generics.md#duck-regime).
}

pub class GenericParamDecl derives Decl {
    pub var name: Token ///< the parameter identifier (T, N, ...).
    /// The decl that DECLARES this parameter (the class/fn/alias/extension),
    /// as its redecl representative. A generic param sits in no symbol table
    /// -- it is a template parameter, not a member -- so `semantic_dc` is null
    /// on it and there is no other way back. T stamps this when it pushes the
    /// param's frame, with exactly the owner the canonical GenericParamType is
    /// uniqued on, so `param -> canonical` and `canonical -> param` agree.
    /// Null for a closure's params (a closure is not a decl) and before T.
    pub var owner:      unsafe *Decl          = &null
    pub var kind_bound: GenericParamKindBound = GenericParamKindBound::Any
    /// `: class` ... `: type` as written, colon through keyword; invalid when
    /// there is no kind bound. FlagGates labels and deletes `: type` by it.
    pub var kind_bound_range: SourceRange             = SourceRange::invalid()
    pub var impl_bounds:      FrozenList<InheritEdge> ///< `impl` interface bounds (structural).
    pub var derives_bounds:   FrozenList<InheritEdge> ///< `derives` base bounds (nominal, vtable).
    pub var is_pack:          bool                    = false ///< `...T` variadic pack.
    pub var is_const_param:   bool                    = false ///< `const N: T` value parameter.
    pub var value_type:       unsafe *Type            = &null ///< type of a const value param; null for type params.
    pub var default_type:     unsafe *Type            = &null ///< `<T = i32>` default; null if none.
    /// Imported only: C++ declares a default, which default_type may not
    /// hold (`enable_if_t<...> = 0` depends on the other parameters). A
    /// function template's parameter like that is C++'s to fill, so
    /// deduction does not require it (Deduction::is_complete).
    pub var ffi_has_default: bool = false
    pub var index:           u32  = 0     ///< position in the param list.

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         name:  Token,
                         index: u32) -> unsafe *GenericParamDecl {
        var unsafe *node = ctx->alloc<GenericParamDecl>()
        node->kind  = DeclKind::GenericParamDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->name             = name
        node->index            = index
        node->kind_bound_range = SourceRange::invalid()
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *GenericParamDecl {
        var unsafe *node = ctx->alloc<GenericParamDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::GenericParamDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::GenericParamDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::GenericParamDecl
    }
}

///
///  ParamDecl
///  `name: Type` | `name: Type = default`
///
///  A single function/closure/method parameter. Binding shorthands (`*x`,
///  `unsafe *x`, `x?`) are folded into the parsed `type` by the parser, so
///  ParamDecl only stores the resolved type + optional default.
///
pub class ParamDecl derives Decl {
    pub var name:        Token ///< parameter name.
    pub var type_:       unsafe *Type ///< declared type (never inferred for params).
    pub var default_val: unsafe *Expr = &null ///< default value expr; null if none.
    pub var is_self:     bool         = false ///< true for the `self` parameter.
    pub var is_const:    bool         = false ///< true for a `const` parameter; on `const self` it also marks the method FnModifier::IsConst.
    pub var index:       u32          = 0 ///< position in the parameter list.
    pub var unname:      bool         = false ///< true for the `unnamed` parameter.
    pub var has_default: bool         = false ///< imported C++ param with a default arg; no Kairo expr to carry.
    /// Imported C++ param whose C integer type maps to the same Kairo integer
    /// as another C type but is not the one the target spells that width
    /// with (`long` on LLP64 is i32, as `int` is). TypeImport::is_int_alias
    /// sets it; OverloadResolution's integer tiebreak reads it.
    pub var cxx_int_alias: bool = false
    /// Imported C++ param that is a pointer (or non-const lvalue reference)
    /// to such an alias: `unsigned long*` on i686, where Kairo's `u32`
    /// spells `unsigned int`. TypeImport::is_alias_indirect sets it; EmitIR
    /// casts the argument to the parameter's C++ spelling.
    pub var cxx_alias_ptr: bool = false

    /// This parameter carries the `...`. Set by DeclParse on the marked
    /// parameter, which need not be the last one. `FunctionDecl::is_variadic`
    /// and `ClosureExpr::is_variadic` are DERIVED from this (true iff some
    /// parameter has it) and are never written directly -- the list is the
    /// truth about which parameter is the pack, and a flag on the function
    /// cannot say that.
    pub var is_pack: bool = false
    /// A non-pack parameter that follows the pack. It can only be supplied by
    /// name, because every remaining positional argument belongs to the pack.
    /// Set by DeclParse when it closes the list.
    pub var keyword_only: bool = false

    /// The nullary function CallLowering minted for this parameter's default,
    /// stamped on the parameter at this index in EVERY link of the redecl
    /// chain: overload resolution may select any link, and defaults
    /// accumulate across links (RedeclMerge admits one per index). Null when
    /// the parameter has no default, or has an imported C++ one (has_default),
    /// which is omitted from the call and never has a thunk.
    pub var default_thunk: unsafe *Decl = &null
    /// This parameter WROTE the default default_thunk was minted from
    /// (CallLowering places the thunk beside it), and whether it has been.
    pub var default_thunk_home:   bool = false
    pub var default_thunk_placed: bool = false

    /// is_pack only: the parameter's C++ type, `Slice<E>` by value, E being
    /// the canonical `type_` names. Stamped by CallLowering when it visits
    /// the function (or first lowers a call to it); read by CXXSpell and
    /// EmitIR. Null for a pack over a dependent element (not lowered yet).
    pub var pack_type: unsafe *Type = &null

    /// Passing mode. Legal only here (and on a fn-pointer type's parameter
    /// positions); the parser rejects it everywhere else. See AST/ParamMode.k.
    /// Never set on `self`: the receiver is already a reference parameter.
    pub var mode:       ParamMode   = ParamMode::Value
    pub var mode_range: SourceRange = SourceRange::invalid() ///< the `@inout` / `@move` tokens.
    /// A by-value COPY record parameter its function never mutates:
    /// passed as `const T&`, as a written `const` is. One writer,
    /// ParamPassInference, after the last lowering, on every link of the
    /// function's redeclaration chain; read only by codegen
    /// (CXXSpell::_param_type, EmitIR's fn-value adapter). The Kairo type
    /// and every Sema fact stay the by-value parameter's.
    pub var inferred_const: bool = false

    pub fn is_inout(self) -> bool {
        return self.mode == ParamMode::Inout
    }

    fn is_move(self) -> bool {
        return self.mode == ParamMode::Move
    }

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         type_:  unsafe *Type,
                         index:  u32,
                         unname: bool = false) -> unsafe *ParamDecl {
        var unsafe *node = ctx->alloc<ParamDecl>()
        node->kind  = DeclKind::ParamDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->mode          = ParamMode::Value
        node->mode_range    = SourceRange::invalid()
        node->name          = name
        node->type_         = type_
        node->index         = index
        node->unname        = unname
        node->is_pack       = false
        node->cxx_int_alias = false
        node->cxx_alias_ptr = false
        node->keyword_only  = false
        node->default_thunk = &null
        node->pack_type     = &null
        return node
    }

    /// `self` parameter: no type (resolved to the enclosing type by sema).
    pub static fn create_self(ctx:   unsafe *ASTContext,
                              range: SourceRange,
                              name:  Token) -> unsafe *ParamDecl {
        var unsafe *node = ctx->alloc<ParamDecl>()
        node->kind  = DeclKind::ParamDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->mode          = ParamMode::Value
        node->mode_range    = SourceRange::invalid()
        node->name          = name
        node->type_         = &null
        node->is_self       = true
        node->index         = 0
        node->is_pack       = false
        node->cxx_int_alias = false
        node->cxx_alias_ptr = false
        node->keyword_only  = false
        node->default_thunk = &null
        node->pack_type     = &null
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ParamDecl {
        var unsafe *node = ctx->alloc<ParamDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::ParamDecl
        node->range         = range
        node->type_         = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->mode          = ParamMode::Value
        node->mode_range    = SourceRange::invalid()
        node->is_pack       = false
        node->cxx_int_alias = false
        node->cxx_alias_ptr = false
        node->keyword_only  = false
        node->default_thunk = &null
        node->pack_type     = &null
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::ParamDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::ParamDecl
    }
}

///
///  FunctionDecl
///  fn foo(...) -> T { } | fn op+(...) | override fn bar() | fn Class::method
///
///  Derives DeclContext (owns params + nested decls), Redeclarable (forward
///  decl, out-of-line def), TemplateParams (generics + requires).
///
///  Operators: is_operator + op_token carry the overloaded operator. Out-of-
///  line defs: qualifier holds the `Class::` (or `Class::Inner::`) path as a
///  ChainExpr; null for in-line / free functions.
///
pub class FunctionDecl
  derives Decl,
          DeclContext,
          Redeclarable<FunctionDecl>,
          TemplateParams<FunctionDecl>,
          FFILinkage<FunctionDecl> {
    /// Function name (or ctor = type name). INVARIANT: exactly one of `name`
    /// and `op_token` is set. An operator (`is_operator`) has `name` =
    /// Token(), the default-constructed empty token, and its spelling lives in
    /// `op_token`; spelling that `name` (decl_name, get_spelling, an f-string
    /// in an ICE message) asserts in TokenText::resolve. Every other function
    /// has a real `name` and an empty `op_token`. Check is_operator before
    /// reading `name`.
    pub var name:        Token
    pub var params:      FrozenList<unsafe *ParamDecl>
    pub var return_type: unsafe *Type                  = &null ///< null => void (or inferred for expr body).
    pub var abi:         AbiKind                       = AbiKind::None
    pub var modifiers:   FnModifier                    = FnModifier::None
    /// The declared set of `panic(E1, E2)` (Compiler/Spec/Panic.md#declared-sets), as written: one
    /// type per element, resolved by T like any written type. Empty for a
    /// bare `panic` (the set is inferred) and for a function that does not
    /// panic; `panic()` is a parse error and parses as bare `panic`, so a
    /// non-empty list is exactly "the set was declared". Nothing checks it
    /// yet; it is recorded for them.
    pub var panic_set: FrozenList<unsafe *Type>
    /// The `panic` specifier as written, its set's `)` included; invalid
    /// when there is none. `params_end` is the parameter list's `)`. Both
    /// are the parser's, for fix-its: one removes the specifier, the other
    /// inserts one (PanicEffectChecking).
    pub var panic_range: SourceRange
    pub var params_end:  SourceRange
    /// The function's FINAL panic set (Compiler/Spec/Panic.md#effect-sets): canonical, deduplicated,
    /// in the canonical order (EffectPropagation::canonical_set). The
    /// declared set canonicalized, or the inferred one. Empty for a function
    /// that does not panic. `panic_state` says whether it can be read:
    /// PanicSetState::Final once EffectPropagation solved it, Unknown when
    /// the function's TU stopped before typing finished (a call to it then
    /// reports nothing). One writer: EffectPropagation, onto every link of
    /// the redeclaration chain, as no_unwind is.
    pub var panic_eff:   FrozenList<unsafe *Type>
    pub var panic_state: PanicSetState            = PanicSetState::None
    /// What C++ sees the function return when it panics: `Panic<T, E...>`
    /// over `panic_eff` (Compiler/Spec/Panic.md#paniclowering), formed by PanicLowering in the
    /// function's own TU, on every link of the chain. `return_type` stays T:
    /// an importer's typing reads it after this TU lowered, and a call's
    /// value is T. Null for a function that does not panic. Codegen spells
    /// the signature from this when it is set (CXXSpell::return_spelling).
    pub var panic_result: unsafe *Type = &null
    /// The panic result types PanicLowering formed for this function's body
    /// that are still DEPENDENT (a generic body, Compiler/Spec/Panic.md#generic-bodies): its result,
    /// each `try`'s slot, each held call's result, each bare binder. Each
    /// instance needs them formed at its arguments (InstanceEntry::
    /// panic_types) so their elements get their type ids in C++. Written in
    /// the function's own TU; empty everywhere else.
    pub var panic_deps: FrozenList<unsafe *Type>
    /// A generic body's `try`s whose typed arms could name ONE type at an
    /// instance (`catch e: T` beside `catch e: A`): each such `try`'s arm
    /// types, then a null, flat; `panic_arm_at` the arms' ranges, parallel
    /// (an invalid range at each null). PanicEffectChecking records them at
    /// the definition; the instance check (§3.1's duplicate arm) reads
    /// them once the body is lowered.
    pub var panic_arms:   FrozenList<unsafe *Type>
    pub var panic_arm_at: FrozenList<SourceRange>
    /// A generic body's transfers whose binding is read again after them
    /// (MoveCheck, a demoted pending move): `move_reuse_site[i]` -- a
    /// transfer of a dependent value, or a `xs...` expansion -- is followed
    /// by the read `move_reuse_read[i]`, parallel. The pattern leaves each a
    /// copy; an instance at which the value cannot be copied is the
    /// use-after-move the pattern could not see (ConformanceChecking::
    /// _check_reuse). Recorded at the definition, in its own TU.
    pub var move_reuse_site: FrozenList<unsafe *Expr>
    pub var move_reuse_read: FrozenList<unsafe *Expr>
    pub var body_kind:       FnBodyKind               = FnBodyKind::None
    pub var body_block:      unsafe *CompoundStmt     = &null ///< when body_kind == Block.
    pub var body_expr:       unsafe *Expr             = &null ///< when body_kind == Expr.
    pub var is_operator:     bool                     = false ///< `fn op <x>`.
    pub var op_token:        FrozenList<Token> ///< the operator token(s) when is_operator; empty otherwise (see `name`).
    pub var is_variadic:     bool                     = false ///< trailing `...name: T` pack param.
    pub var is_noreturn:     bool                     = false ///< return type is `!`.
    /// A Kairo definition of a C++-declared function that returns `T&` /
    /// `const T&` -- an override of an imported virtual, or an out-of-line
    /// definition of an imported member -- written `-> *T` / `-> *const T`
    /// (raw or safe). C++ sees the reference, as for a place `op []`: the
    /// return type is spelled `T&`, `return &x` returns `x`, and a Kairo
    /// call takes the reference's address back (OperatorFacts::returns_place).
    /// Writers: RedeclMerge (out-of-line), CallConvCheck (override).
    pub var cxx_ref_return: bool         = false
    pub var transfer:       TransferKind = TransferKind::NotTransfer ///< @copy/@move on a transfer ctor.
    /// Written `-> yield T`: a C++ coroutine. Writer: X (StmtTyping::
    /// traverse_function_decl), before the body is typed. The WRITTEN
    /// qualifier, never the canonical: a spelled-out `-> Yield<T>` is an
    /// ordinary record return (`get_return_object` is one).
    pub var is_generator: bool = false
    /// A generator whose body has a `yield`. Writer: X, at each yield it
    /// accepts. EmitIR reads it to give an empty generator the `co_return;`
    /// that makes it a coroutine at all, rather than walking the body itself.
    pub var has_yield: bool = false
    /// The C++ spelling carries `noexcept`: every Kairo function by default,
    /// not one marked `@unwind` or built with -funwind, always one marked
    /// `@no_unwind` (StmtTyping::_stamp_no_unwind has the rule). Writer: X
    /// (StmtTyping::traverse_function_decl), onto EVERY link of the
    /// redeclaration chain, because C++ requires each declaration of a
    /// function to agree on it and an attribute may be written on only one
    /// of them. A function X never types (one a lowering mints) stays
    /// false, on its declaration and definition alike.
    pub var no_unwind:    bool         = false
    pub var qualifier:    unsafe *Expr = &null ///< out-of-line `Class::` path (ChainExpr); null otherwise.
    pub var where_clause: unsafe *Expr = &null ///< `where <expr>` runtime-dispatch guard; functions only, null otherwise.
    /// The function a `where` dispatch group is called through, stamped on
    /// every member of the group (itself included), null on every other
    /// function. A group is the same-signature overloads of one name in one
    /// scope that differ only by their guards; RedeclMerge links them into
    /// one chain and writes this, its first-declared link, which
    /// WhereDispatchLowering turns into the dispatcher. OverloadResolution
    /// binds a call to it, so every call site names the one function C++
    /// will see.
    pub var where_lead: unsafe *FunctionDecl = &null
    /// On a group's lead only: every member, in dispatch order, the lead
    /// included (WhereGuardCheck files them). The dispatcher's panic set is
    /// the union of theirs (Compiler/Spec/Panic.md#crashes-are-not-panics, where.mdx): EffectPropagation
    /// reads it, here and in every importing TU.
    pub var where_group:    FrozenList<unsafe *FunctionDecl>
    pub var ffi_builtin_id: u32                              = 0 ///< clang builtin ID; 0 for every other function.
    pub var ffi_ice_mask:   u32                              = 0 ///< bit i: parameter i takes an integer constant.
    /// The Expect lang item (`__builtin_expect`, base/intrinsics.k): every
    /// call is clang's builtin, spelled at the call site (EmitIR::_call).
    /// One writer, NameResolution::fill_lang_items, on the canonical decl;
    /// codegen has no route to the lang item table, so it reads this.
    pub var lowers_to_expect: bool = false
    /// The Assume lang item (`__builtin_assume`, base/intrinsics.k): every
    /// call is clang's builtin, spelled at the call site (EmitIR::_call).
    /// One writer, NameResolution::fill_lang_items, as for lowers_to_expect.
    pub var lowers_to_assume: bool = false
    /// The DynamicSize (1) / DynamicAlign (2) lang item, else 0: EmitIR
    /// writes its body (EmitIR::_dynamic_layout_body), reading T's hidden
    /// `__kairo_layout()` when T has one. One writer, as for lowers_to_expect.
    pub var dynamic_layout: u8 = 0
    /// A class's own allocator, which Kairo does not allow
    /// (decided 2026-11-02, reaffirmed 2026-11-08): 1 `static fn op new(...)`
    /// (or any `op new`), 2 `static fn op delete(...)`, 0 anything else. The
    /// parser still declares them under `alloc` / `free` (AllocNames) so the
    /// head hoists like any member; ClassAllocatorCheck rejects every one
    /// (SC149E). One writer: the parser.
    pub var class_alloc_op: u8 = 0
    /// The destructor written with its pre-0.2.0 spelling, `fn op
    /// delete(self)`: the range of `delete`, else invalid. The parser keys
    /// the destructor as `op finally` either way (op_token is KwFinally), so
    /// nothing downstream sees the old spelling; ClassAllocatorCheck reports
    /// it (S090E, fix-it to `finally`) outside the builtin / std library.
    pub var old_dtor_at: SourceRange = SourceRange::invalid()
    /// Function attributes (attributes.mdx, "Function hints"). Writer: the
    /// parser (apply_annotations_to_decl), where every decl's annotations
    /// land; codegen reads the fields so it never re-resolves attribute
    /// names, and the declaration and definition heads agree on them.
    pub var hot_path:  bool = false ///< `@hot_path`: `[[gnu::hot]]`.
    pub var no_inline: bool = false ///< `@no_inline`: `__attribute__((noinline))`.
    pub var cold_path: bool = false ///< `@cold_path`: `[[gnu::cold]]`.
    pub var is_pure:   bool = false ///< `@pure`: `[[gnu::pure]]`; FnPurityCheck.
    /// The calling convention (functions-declarations.mdx, "Calling
    /// conventions"): 0 the default (C), 1 `@preserve_most`, 2
    /// `@preserve_all`, 3 `@preserve_none` (LangAttrs::call_conv_name).
    /// Writer: the parser, as for hot_path. Every C++ declaration spells it
    /// (CXXSpell::fn_attrs); CallConvCheck says where it may stand, and
    /// RedeclMerge holds a chain to one value.
    pub var call_conv: u8 = 0
    /// Written `const fn f()` at file or module scope: reads only its own
    /// inputs, `[[gnu::const]]`; FnPurityCheck enforces it. NOT the same as
    /// is_const(), which is `const self` on a method.
    pub var is_const_fn: bool = false
    /// The written promise, `const` (after the parameters, or the leading
    /// misspelling) or the `@pure` annotation: FnPurityCheck's fix-it
    /// removes it where the promise cannot stand. Writer: the parser.
    pub var purity_at: SourceRange = SourceRange::invalid()
    /// -finfer-purity's verdict for a function that made no promise: 0
    /// none, 1 const (`[[gnu::const]]`), 2 pure (`[[gnu::pure]]`). Writer:
    /// FnPurityCheck::infer, on every link of the chain, in the defining
    /// TU's Sema; readers: CXXSpell::fn_attrs, ParamPassInference (an
    /// inferred-const function keeps its by-value parameters), and the
    /// callers' own inference (a callee counts as a promise once decided).
    pub var inferred_purity: u8 = 0
    /// A function EnumLayoutLowering minted for an ADT's layout record, or
    /// None. It has no Kairo body and never a requires_clause: InterfaceEmitter
    /// writes its C++ from adt_role and adt_form, constraints included.
    /// adt_variant is the position, in the enum's variants, of the variant a
    /// VariantCtor builds; 0 for every other role. One writer for all three:
    /// EnumLayoutLowering.
    pub var adt_role:    AdtRole = AdtRole::None
    pub var adt_form:    AdtForm = AdtForm::Trivial
    pub var adt_variant: u32     = 0
    /// A constructor that initializes a const field. C++ wants a const
    /// member's value at the mem-initializer list, before any statement
    /// runs, so the body is split: S_pre, every top-level statement up to
    /// and including the last one that assigns a const field, runs before
    /// the object exists, against slots; the rest runs in it. `ci_split` is
    /// the number of statements in S_pre, 0 for a constructor emitted as
    /// written. `ci_index` numbers the split constructors of one record
    /// (LowerTargets::ctor_slots / ctor_pre). `ci_slots` is what S_pre
    /// writes that outlives it: every field it assigns, in declaration
    /// order, then every top-level local of S_pre the rest of the body
    /// reads (FieldDecl or VariableDecl). `ci_dense` is parallel: assigned
    /// on every path through S_pre (a const field and a local always are).
    /// One writer: CtorInitCheck, onto the in-class declaration and its
    /// definition alike. CtorInitLowering splits the body on `ci_split` and
    /// sets `ci_cut` (the body is then exactly `{ {S_pre} {S_post} }`);
    /// InterfaceEmitter and EmitIR render the rest (Compiler/Spec/Codegen.md#interfaceemitter, §6).
    pub var ci_split: u32                      = 0
    pub var ci_index: u32                      = 0
    pub var ci_slots: FrozenList<unsafe *Decl>
    pub var ci_dense: FrozenList<bool>
    pub var ci_cut:   bool                     = false

    pub fn has_where(self) -> bool {
        return self.where_clause != &null
    }

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *FunctionDecl {
        var unsafe *node = ctx->alloc<FunctionDecl>()
        node->kind  = DeclKind::FunctionDecl
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Function, ctx, parent, node)
        node->init_redecl()
        node->adt_role         = AdtRole::None
        node->adt_form         = AdtForm::Trivial
        node->adt_variant      = 0
        node->ci_split         = 0
        node->ci_index         = 0
        node->ci_cut           = false
        node->lowers_to_expect = false
        node->lowers_to_assume = false
        node->dynamic_layout   = 0
        node->class_alloc_op   = 0
        node->old_dtor_at      = SourceRange::invalid()
        node->hot_path         = false
        node->no_inline        = false
        node->cold_path        = false
        node->is_pure          = false
        node->call_conv        = 0
        node->is_const_fn      = false
        node->purity_at        = SourceRange::invalid()
        node->inferred_purity  = 0
        return node
    }

    pub static fn create_error(ctx:   unsafe *ASTContext,
                               range: SourceRange) -> unsafe *FunctionDecl {
        var unsafe *node = ctx->alloc<FunctionDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::FunctionDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Function, ctx, &null, node)
        node->init_redecl()
        node->adt_role         = AdtRole::None
        node->adt_form         = AdtForm::Trivial
        node->adt_variant      = 0
        node->lowers_to_expect = false
        node->lowers_to_assume = false
        node->dynamic_layout   = 0
        node->class_alloc_op   = 0
        node->old_dtor_at      = SourceRange::invalid()
        node->hot_path         = false
        node->no_inline        = false
        node->cold_path        = false
        node->is_pure          = false
        node->call_conv        = 0
        node->is_const_fn      = false
        node->purity_at        = SourceRange::invalid()
        node->inferred_purity  = 0
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::FunctionDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::FunctionDecl
    }

    /// # modifier queries

    pub fn is_const(self) -> bool {
        return (self.modifiers & FnModifier::IsConst) != FnModifier::None
    }

    pub fn is_unsafe(self) -> bool {
        return (self.modifiers & FnModifier::IsUnsafe) != FnModifier::None
    }

    pub fn is_eval(self) -> bool {
        return (self.modifiers & FnModifier::IsEval) != FnModifier::None
    }

    pub fn is_async(self) -> bool {
        return (self.modifiers & FnModifier::IsAsync) != FnModifier::None
    }

    pub fn is_panic(self) -> bool {
        return (self.modifiers & FnModifier::IsPanic) != FnModifier::None
    }

    pub fn has_panic_set(self) -> bool {
        return !self.panic_set.is_empty()
    }

    fn is_final(self) -> bool {
        return (self.modifiers & FnModifier::IsFinal) != FnModifier::None
    }

    pub fn is_inline(self) -> bool {
        return (self.modifiers & FnModifier::IsInline) != FnModifier::None
    }

    pub fn is_constexpr(self) -> bool {
        return (self.modifiers & FnModifier::IsConstexpr) != FnModifier::None
    }

    pub fn is_method(self) -> bool {
        return self.params.size() > 0 && self.params[0]->is_self
    }

    pub fn is_out_of_line(self) -> bool {
        return self.qualifier != &null
    }

    pub fn has_body(self) -> bool {
        return self.body_kind != FnBodyKind::None
    }

    fn param_count(self) -> usize {
        return self.params.size()
    }
}

///
///  VariableDecl
///  var/const/static/eval binding at local or namespace scope.
///  NOT a class/struct member (that is FieldDecl).
///
///  `type_` is null when inferred. `is_eval` is derived from storage == Eval
///  but kept explicit for the `eval var` stmt path.
///
pub class VariableDecl derives Decl, FFILinkage<VariableDecl> {
    pub var name:      Token
    pub var storage:   StorageClass = StorageClass::Var
    pub var type_:     unsafe *Type = &null ///< null => inferred from init.
    pub var init:      unsafe *Expr = &null ///< initializer; null for `var x: T` default-init.
    pub var is_thread: bool         = false ///< `thread` (or `static thread`): thread_local storage; `storage` is Static.
    /// Raw storage for a value of `type_` that is built later and read once
    /// (PanicOpExpr SlotPut / SlotTake): EmitIR declares it as
    /// `::__kairo_raw<T>`, a union with an empty constructor and destructor,
    /// so nothing is built on the path that never fills it. Only
    /// PanicLowering's `try` slots; never written by the user.
    pub var raw_slot: bool = false
    /// A place bound once (SequenceLowering): EmitIR declares it `auto&&`, a
    /// reference to the object whatever its cv and value category, so the
    /// name reads and writes the place itself. `type_` is the object's Kairo
    /// type, for the uses. Never written by the user.
    pub var place_ref: bool = false
    /// A value copied once (SequenceLowering) whose type C++ deduces: EmitIR
    /// declares it `auto`. For a type Kairo cannot spell where the copy is
    /// made (an enum nested in a generic pattern, a dependent type).
    pub var auto_copy: bool = false
    /// `static const x` / `const static x` (or `thread const`): the binding
    /// of a Static-storage variable is const. `storage` stays the storage
    /// keyword so every is_static() reader is unchanged; is_const() folds
    /// this in, so every const reader is too. Never set with Const or Eval
    /// storage (`eval const` is plain `eval`).
    pub var const_binding: bool = false
    /// `var x? = e`, the nullable shorthand (variables.md, Declaration
    /// Shorthands): the type is inferred from `init` and then made nullable,
    /// once (`typeof(e)?`, or `typeof(e)` when that is already nullable).
    /// The parser sets it only when `type_` is null: `var x?: T` is refused
    /// there and recovered as `var x: T?`, so a set flag always means
    /// "infer, then wrap" and StmtTyping has one case to handle.
    pub var nullable_shorthand: bool = false
    /// `var *y = e` / `var **y = e` / `var unsafe *y = e`, the pointer
    /// shorthand (Compiler/Spec/Nullables.md#declaration-shorthands): the number of stars written before the
    /// name, 0 when there are none. A readability marker, never a
    /// conversion: StmtTyping infers `typeof(e)` as for a plain `var y = e`
    /// and checks the stars against it (depth, and the outermost pointer's
    /// safety against `pointer_unsafe`). Like `nullable_shorthand`, set only
    /// when `type_` is null; the parser refuses `var *y: T`.
    pub var pointer_depth:  u32  = 0
    pub var pointer_unsafe: bool = false ///< `unsafe` before the first star.
    /// `unsafe`/first `*` through the last `*`: what a depth or safety
    /// fix-it rewrites. Kept on the node because that fix-it is Sema's.
    pub var pointer_range: SourceRange = SourceRange::invalid()
    /// The storage keyword as written (`const` of `const N = 3`), for a
    /// fix-it that rewrites it (`const` -> `eval` where a value must be
    /// eval-able, Compiler/Spec/Eval.md#generic-value-parameters). Invalid when the parser did not record it.
    pub var storage_kw: SourceRange = SourceRange::invalid()
    /// What EvalIfLateFolding read this `eval` constant as, when an `eval
    /// if` it decided read it through a type fact (Compiler/Spec/Eval.md#deferred-conditions): 0 none,
    /// 1 false, 2 true, 3 the integer fold_pin_mag (negative when
    /// fold_pin_neg). Codegen asserts it after the C++ definition, so clang
    /// computing another value fails the build instead of the two keeping
    /// different branches. One writer: EvalIfLateFolding; decl_fold_pin reads.
    pub var fold_pin:     u8   = 0
    pub var fold_pin_neg: bool = false
    pub var fold_pin_mag: u64  = 0

    pub static fn create(ctx:     unsafe *ASTContext,
                         range:   SourceRange,
                         name:    Token,
                         storage: StorageClass) -> unsafe *VariableDecl {
        var unsafe *node = ctx->alloc<VariableDecl>()
        node->kind  = DeclKind::VariableDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->name    = name
        node->storage = storage
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *VariableDecl {
        var unsafe *node = ctx->alloc<VariableDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::VariableDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::VariableDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::VariableDecl
    }

    /// An `eval` binding is implicitly const (eval.mdx): it is never
    /// assigned and only `const self` methods are called on it.
    pub fn is_const(self) -> bool {
        return self.storage == StorageClass::Const
            || self.storage == StorageClass::Eval
            || self.const_binding
    }

    pub fn is_static(self) -> bool {
        return self.storage == StorageClass::Static
    }

    pub fn is_eval(self) -> bool {
        return self.storage == StorageClass::Eval
    }

    fn is_inferred(self) -> bool {
        return self.type_ == &null
    }
}

/// The pointer shorthand as written before a binding's name: `*`, `**`,
/// `unsafe *`. What every message and fix-it about it spells (the parser's
/// refusals, StmtTyping's depth check, the shorthand lint, the printers).
pub fn pointer_shorthand_spelling(depth: u32, is_unsafe: bool) -> string {
    var s: string = ""
    if is_unsafe {
        s = "unsafe "
    }

    for var i: u32 = 0; i < depth; ++i {
        s += "*"
    }

    return s
}

/// What FieldInitLowering made of a field's initializer, for the emitter's
/// default member initializer. None: no initializer was lowered (none was
/// written, or a gate kept it). Int / True / False / Null: a constant the
/// emitter spells itself, the value in FieldDecl::init_neg / init_mag for
/// Int. Thunk: anything else, a call of FieldDecl::init_thunk. Elems: an
/// array field's list literal, one thunk per element (FieldDecl::init_elems),
/// since no C++ function returns an array.
pub enum FieldFold derives u8 {
    None = 0,
    Int,
    True,
    False,
    Null,
    Thunk,
    Elems,
}

///
///  FieldDecl
///  Class/struct/union member: var/const/static/eval, optionally `mutable`.
///  Also used for ADT enum-variant payload fields.
///
///  Distinct from VariableDecl: lives in a type scope, carries `is_mutable`,
///  and `init` is the at-declaration default used by aggregate init / ctor
///  one-shot assignment.
///
pub class FieldDecl derives Decl {
    pub var name:          Token
    pub var storage:       StorageClass = StorageClass::Var
    pub var type_:         unsafe *Type = &null ///< field type; null only in recovery.
    pub var init:          unsafe *Expr = &null ///< at-decl default; null if none, or once FieldInitLowering has consumed it.
    pub var is_mutable:    bool         = false ///< `mutable var` escapes const-self.
    pub var is_thread:     bool         = false ///< `thread` (or `static thread`): thread_local storage; `storage` is Static.
    pub var const_binding: bool         = false ///< `static const` member; see VariableDecl::const_binding.
    pub var index:         u32          = 0 ///< declaration order in the owning type.
    /// As VariableDecl::fold_pin, for an `eval` field.
    pub var fold_pin:     u8   = 0
    pub var fold_pin_neg: bool = false
    pub var fold_pin_mag: u64  = 0
    /// An imported C / C++ bit-field (DeclImport): no reference can bind it,
    /// so a place written through it is re-read through its object instead
    /// (EmitIR's compound forms, SequenceLowering). Kairo declares none.
    pub var is_bitfield: bool = false
    /// `type_` is the record type of an anonymous UnionDecl (`is_anonymous`),
    /// and this field is that union's one and only declaration: C++ gets
    /// `union { ... };` in its place, with no name. Unlike C++, the union's
    /// members are NOT injected into the owner's member table -- nothing
    /// looks them up by name. Compiler-minted field_of chains carry the
    /// member FieldDecl itself and name it directly on the owner, as C++
    /// does (`s.__kairo_Some`). This field is in no chain: it has no name to
    /// spell, and exists only so the emitter writes the union. `name` is the
    /// empty token, so test this flag before spelling the field. One writer:
    /// EnumLayoutLowering, which mints the field together with its union;
    /// the parser never sets it.
    pub var is_anonymous_union: bool = false
    /// The C++ default member initializer FieldInitLowering made of `init`,
    /// which is null afterwards. A constant (`init_fold` Int, True, False,
    /// Null) is spelled in the class as it is; any other initializer became
    /// the body of `init_thunk`, a member function the default calls. One
    /// writer: FieldInitLowering.
    pub var init_fold:  FieldFold    = FieldFold::None
    pub var init_neg:   bool         = false
    pub var init_mag:   u64          = 0
    pub var init_thunk: unsafe *Decl = &null
    /// `init_fold` Elems: the thunk of each element, in order.
    pub var init_elems: FrozenList<unsafe *Decl>

    pub static fn create(ctx:     unsafe *ASTContext,
                         range:   SourceRange,
                         name:    Token,
                         storage: StorageClass,
                         type_:   unsafe *Type,
                         index:   u32) -> unsafe *FieldDecl {
        var unsafe *node = ctx->alloc<FieldDecl>()
        node->kind  = DeclKind::FieldDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->name               = name
        node->storage            = storage
        node->type_              = type_
        node->index              = index
        node->is_anonymous_union = false
        node->init_fold          = FieldFold::None
        node->init_thunk         = &null
        node->init_elems         = create_empty_frozen_list<unsafe *Decl>()
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *FieldDecl {
        var unsafe *node = ctx->alloc<FieldDecl>()
        node->kind               = DeclKind::RecoveryDecl
        node->recovery_kind      = DeclKind::FieldDecl
        node->range              = range
        node->type_              = &null
        node->is_anonymous_union = false
        node->init_fold          = FieldFold::None
        node->init_thunk         = &null
        node->init_elems         = create_empty_frozen_list<unsafe *Decl>()
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::FieldDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::FieldDecl
    }

    /// An `eval` field is static: one compile-time value per class, not a
    /// slot in every object (Compiler/Spec/Eval.md#eval-bindings), so every reader that asks "is
    /// this per object?" gets the same answer for both.
    pub fn is_static(self) -> bool {
        return self.storage == StorageClass::Static || self.storage == StorageClass::Eval
    }

    pub fn is_eval(self) -> bool {
        return self.storage == StorageClass::Eval
    }

    pub fn is_const(self) -> bool {
        return self.storage == StorageClass::Const || self.const_binding
    }
}

///
///  StructDecl
///  struct Foo<T> impl Bar { var x: T ... }
///
///  Owns fields (FieldDecl) and nested type decls via DeclContext. Structs
///  cannot have methods in-body (extends add those), so dc_decls holds fields
///  and nested types only. `implements` lists interface conformances.
///
pub class StructDecl
  derives Decl,
          DeclContext,
          Redeclarable<StructDecl>,
          TemplateParams<StructDecl>,
          FFILinkage<StructDecl> {
    pub var name:   Token
    pub var fields: FrozenList<unsafe *FieldDecl>
    /// Constructors and operator overloads only - a struct body admits no
    /// named methods (the parser rejects those); see _parse_member_body.
    pub var methods:    FrozenList<unsafe *FunctionDecl>
    pub var implements: FrozenList<InheritEdge>          ///< `impl` interface list.
    /// The payload of one ADT variant: its fields are that variant's own
    /// payload FieldDecls, and InterfaceEmitter gives it a placement
    /// operator new, so `new (&member) P(...)` needs no <new>. One writer:
    /// EnumLayoutLowering.
    pub var is_adt_payload: bool = false
    /// A pack-expanded variant's payload struct: a template over one pack
    /// element, inside which the enum's pack parameter (this) spells as that
    /// element (InterfaceEmitter). Null for every other struct.
    pub var adt_pack_param: unsafe *GenericParamDecl = &null
    /// The ADT enum this record is the layout of (EnumDecl::adt_layout), or
    /// null. One writer: EnumLayoutLowering.
    pub var adt_of: unsafe *Decl = &null
    /// The transfer constructor this record's `op =` is derived from, or
    /// null (AssignForm::Implicit). One writer: ClassLifecycle.
    pub var assign_from: unsafe *FunctionDecl = &null
    /// How that `op =` is given to C++. One writer: ClassLifecycle.
    pub var assign_form: AssignForm = AssignForm::Implicit
    /// N > 0: this record IS the tuple of arity N -- `(A, B)` is
    /// `Tuple2<A, B>` -- minted by TupleRecords, never parsed from source
    /// and in no symbol table. Tuple-ness is this flag on the PATTERN, by
    /// identity, never the name `TupleN` (a user may declare one). One
    /// writer: TupleRecords.
    pub var tuple_arity: u32 = 0
    /// This record is the `null_t` lang item: InterfaceEmitter writes the
    /// one constant of it, `null`, after its definition, for C++ hosts
    /// (`null` is a Kairo keyword, so no Kairo declaration can name it).
    /// Codegen has no route to well_known, hence a flag. One writer:
    /// NameResolution::fill_lang_items.
    pub var is_null_type: bool = false

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *StructDecl {
        var unsafe *node = ctx->alloc<StructDecl>()
        node->kind  = DeclKind::StructDecl
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Struct, ctx, parent, node)
        node->init_redecl()
        node->is_adt_payload = false
        node->adt_pack_param = &null
        node->adt_of         = &null
        node->assign_from    = &null
        node->assign_form    = AssignForm::Implicit
        node->is_null_type   = false
        return node
    }

    pub static fn create_error(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *StructDecl {
        var unsafe *node = ctx->alloc<StructDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::StructDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Struct, ctx, &null, node)
        node->init_redecl()
        node->is_adt_payload = false
        node->adt_pack_param = &null
        node->adt_of         = &null
        node->assign_from    = &null
        node->assign_form    = AssignForm::Implicit
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::StructDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::StructDecl
    }

    fn field_count(self) -> usize {
        return self.fields.size()
    }
}

///
///  ClassDecl
///  class Foo<T> derives Bar impl Baz { var x: T; fn m(self) { } }
///
///  Owns fields + methods + nested types via DeclContext. `derives_list`
///  holds base classes (with per-edge visibility + virtual), `implements`
///  holds interface conformances. is_final / is_abstract drive sema checks.
///
pub class ClassDecl
  derives Decl,
          DeclContext,
          Redeclarable<ClassDecl>,
          TemplateParams<ClassDecl>,
          FFILinkage<ClassDecl> {
    pub var name:         Token
    pub var fields:       FrozenList<unsafe *FieldDecl>
    pub var methods:      FrozenList<unsafe *FunctionDecl>
    pub var derives_list: FrozenList<InheritEdge>                  ///< base classes.
    pub var implements:   FrozenList<InheritEdge>                  ///< interfaces.
    pub var is_final:     bool                             = false ///< `final class`.
    pub var is_abstract:  bool                             = false ///< has a `= virtual` method.
    /// The transfer constructor this class's `op =` is derived from, or
    /// null (AssignForm::Implicit). One writer: ClassLifecycle.
    pub var assign_from: unsafe *FunctionDecl = &null
    /// How that `op =` is given to C++. One writer: ClassLifecycle.
    pub var assign_form: AssignForm = AssignForm::Implicit
    /// An imported C++ class: every name a `using Base::name;` in its
    /// definition brings in. C++ lookup stops at a class that declares a
    /// name unless such a declaration merges the base's in; MemberLookup
    /// hides by this. One writer: DeclImport.
    pub var ffi_usings: cxx::std::vector<string>

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *ClassDecl {
        var unsafe *node = ctx->alloc<ClassDecl>()
        node->kind  = DeclKind::ClassDecl
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Class, ctx, parent, node)
        node->init_redecl()
        node->assign_from = &null
        node->assign_form = AssignForm::Implicit
        return node
    }

    pub static fn create_error(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *ClassDecl {
        var unsafe *node = ctx->alloc<ClassDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::ClassDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Class, ctx, &null, node)
        node->init_redecl()
        node->assign_from = &null
        node->assign_form = AssignForm::Implicit
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::ClassDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::ClassDecl
    }

    pub fn has_bases(self) -> bool {
        return !self.derives_list.is_empty()
    }
}

///
///  InterfaceDecl
///  interface Printable<T> derives Other { fn draw(self) const -> string }
///
///  Body holds only method/operator/ctor/static SIGNATURES (no bodies). Stored
///  as FunctionDecl with body_kind == None. `derives_list` is interface
///  inheritance (additive, no state).
///
/// One requirement of an interface AFTER composition (InterfaceComposition):
/// the interface normalized into a plain list, as if written out by hand.
pub struct Requirement {
    pub var decl:       unsafe *Decl ///< the ORIGINAL member: a FunctionDecl, or an associated TypeAliasDecl.
    pub var source:     unsafe *Type ///< the canonical interface instance it came through (`Y<i32>`); its own interface's for an own member.
    pub var leaf:       u32 ///< the derives_list index it came through (provenance); u32(-1) for an own member.
    pub var bounds:     unsafe *Expr ///< an associated type's bounds after `+` / `&` merged them (requires-style `&&`); else its own clause.
    pub var default_ty: unsafe *Type ///< an associated type's kept default, or null.
}

pub class InterfaceDecl
  derives Decl,
          DeclContext,
          Redeclarable<InterfaceDecl>,
          TemplateParams<InterfaceDecl>,
          FFILinkage<InterfaceDecl> {
    pub var name:         Token
    pub var methods:      FrozenList<unsafe *FunctionDecl> ///< requirement signatures.
    pub var derives_list: FrozenList<InheritEdge>          ///< parent interfaces.
    /// The `derives` clause as written, when it is an EXPRESSION over
    /// interfaces (`X + (Y - Z)`, `A, B` as `A + B`): BinaryOperatorExpr
    /// nodes, op `+` / `-` / `&`, over the leaves as the expression parser
    /// read them (names, `::` chains, generic applications). Leaf i, in
    /// source order, is `derives_list[i]`'s type: the leaves are resolved
    /// as types there, and nothing walks this tree but InterfaceComposition.
    /// Null for no `derives`.
    pub var derives_expr: unsafe *Expr = &null
    /// The clause uses `-` or `&`: not a plain union. Until composition is
    /// compiled such an interface is rejected (InterfaceComposition).
    pub var derives_composed: bool = false
    /// End of the derives clause: where an LSP shows the derived body.
    pub var derives_end: SourceRange
    /// Every requirement, own and derived, deduplicated: what binding,
    /// conformance and witnesses read. Written once by InterfaceComposition.
    pub var requirements: FrozenList<Requirement>
    /// InterfaceComposition's progress: 0 not yet, 1 in progress (a cycle
    /// reaching it again is an error), 2 done.
    pub var compose_state: u8 = 0

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *InterfaceDecl {
        var unsafe *node = ctx->alloc<InterfaceDecl>()
        node->kind             = DeclKind::InterfaceDecl
        node->range            = range
        node->name             = name
        node->derives_expr     = &null
        node->derives_composed = false
        node->compose_state    = 0
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Interface, ctx, parent, node)
        node->init_redecl()
        return node
    }

    pub static fn create_error(ctx:   unsafe *ASTContext,
                               range: SourceRange) -> unsafe *InterfaceDecl {
        var unsafe *node = ctx->alloc<InterfaceDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::InterfaceDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Interface, ctx, &null, node)
        node->init_redecl()
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::InterfaceDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::InterfaceDecl
    }
}

///
///  ExtensionDecl
///  extend Foo<T> impl Bar { fn m(self) { } }
///
///  Adds methods/operators/statics/conformance to an existing type. `target`
///  is the extended type reference. Owns the methods written in the body via
///  DeclContext. Not Redeclarable (each extend block is its own decl; multiple
///  blocks are allowed and merged by sema, not by the redecl chain).
///
pub class ExtensionDecl
  derives Decl,
          DeclContext,
          TemplateParams<ExtensionDecl> {
    pub var target:     unsafe *Type                     ///< the type being extended.
    pub var methods:    FrozenList<unsafe *FunctionDecl>
    pub var implements: FrozenList<InheritEdge>          ///< `extend X impl Y`.

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         target: unsafe *Type,
                         parent: unsafe *DeclContext) -> unsafe *ExtensionDecl {
        var unsafe *node = ctx->alloc<ExtensionDecl>()
        node->kind   = DeclKind::ExtensionDecl
        node->range  = range
        node->target = target
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Extension, ctx, parent, node)
        return node
    }

    pub static fn create_error(ctx:   unsafe *ASTContext,
                               range: SourceRange) -> unsafe *ExtensionDecl {
        var unsafe *node = ctx->alloc<ExtensionDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::ExtensionDecl
        node->range         = range
        node->target        = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Extension, ctx, &null, node)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::ExtensionDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::ExtensionDecl
    }
}

/// An integer constant: what Sema's constant evaluator (Sema/Check/
/// ConstEval.k) computes, kept here as plain data so a decl can carry one.
/// Sign-magnitude over u64, so u64's 2^64 - 1 and i64's -2^63 are both
/// exact and no wider type is needed. `ok` false: not a constant.
/// `overflow`: a constant whose magnitude needs more than 64 bits, so no
/// 64-bit type holds it.
pub struct IntConst {
    pub var ok:       bool = false
    pub var neg:      bool = false
    pub var mag:      u64  = 0
    pub var overflow: bool = false
}

///
///  EnumVariantDecl
///  North | Ok = 2 | Found { key: K, value: V }
///
///  A single variant. Plain variants carry an optional explicit `discriminant`
///  expr. ADT variants carry `payload` fields (FieldDecl). Owned by EnumDecl;
///  not independently looked up, so no DeclContext.
///
pub class EnumVariantDecl derives Decl {
    pub var name:          Token
    pub var discriminant:  unsafe *Expr                  = &null ///< `= <const expr>`; null if implicit.
    pub var payload:       FrozenList<unsafe *FieldDecl> ///< ADT fields; empty for plain variants.
    pub var index:         u32                           = 0 ///< declaration order.
    pub var adt_member:    unsafe *FieldDecl             = &null ///< the union member holding this variant's payload; null when it has none or before EnumLayoutLowering.
    pub var adt_ctor:      AdtCtorForm                   = AdtCtorForm::Lambda ///< how C++ builds it (AdtCtorForm); one writer, EnumLayoutLowering.
    pub var adt_tag_value: u64                           = 0 ///< the tag this ADT variant is stored as: its position (a pack-expanded variant's, element 0's unless EnumDecl::adt_explicit_tags).
    /// `V { e: E }...`: one variant per element of the type pack its payload
    /// names (Compiler/Spec/Panic.md#the-result-type). Element k's tag is adt_tag_value + k, or with
    /// EnumDecl::adt_explicit_tags its type id (EnumLayoutQuery::tag_value);
    /// the payload's fields are the pattern's, read at element k's type.
    pub var is_pack_expansion: bool        = false
    pub var pack_range:        SourceRange         ///< the `...`, when is_pack_expansion.
    /// The variant's value: its discriminant's, else the previous variant's
    /// plus one, else 0 for the first, so an ADT's variants are their
    /// positions. One writer: StmtTyping::traverse_enum_variant_decl, in
    /// declaration order, which is what lets a discriminant read the
    /// variants above it. Not ok when the value failed (and was reported),
    /// and never written for an imported C++ enum: clang owns those values,
    /// and codegen never emits the enum.
    pub var value: IntConst

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         name:  Token,
                         index: u32) -> unsafe *EnumVariantDecl {
        var unsafe *node = ctx->alloc<EnumVariantDecl>()
        node->kind  = DeclKind::EnumVariantDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->name              = name
        node->index             = index
        node->adt_member        = &null
        node->adt_ctor          = AdtCtorForm::Lambda
        node->adt_tag_value     = (index)
        node->is_pack_expansion = false
        node->pack_range        = range
        node->value             = IntConst{}
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *EnumVariantDecl {
        var unsafe *node = ctx->alloc<EnumVariantDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::EnumVariantDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->adt_member        = &null
        node->is_pack_expansion = false
        node->pack_range        = range
        node->value             = IntConst{}
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::EnumVariantDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::EnumVariantDecl
    }

    pub fn is_adt(self) -> bool {
        return !self.payload.is_empty()
    }

    fn has_value(self) -> bool {
        return self.discriminant != &null
    }
}

///
///  EnumDecl
///  enum Direction derives u8 { } | enum <T> Result { Ok { value: T }, Err }
///
///  `underlying` is the `derives <int>` type; null when defaulted (u32 for a
///  plain enum; for an ADT, the narrowest tag EnumLayoutLowering picks). On
///  an ADT it is the tag's type. Generic enums (TemplateParams) must be
///  ADT (a plain enum has nothing to parameterize). Owns variants via the
///  `variants` list; DeclContext holds nested type decls.
///
pub class EnumDecl
  derives Decl,
          DeclContext,
          Redeclarable<EnumDecl>,
          TemplateParams<EnumDecl>,
          FFILinkage<EnumDecl> {
    pub var name:       Token
    pub var underlying: unsafe *Type                        = &null ///< `derives u8` etc; null if defaulted.
    pub var variants:   FrozenList<unsafe *EnumVariantDecl>
    pub var is_adt:     bool                                = false ///< any variant carries a payload.
    /// `@open` (LangAttrs::open_enum): this plain enum may hold any value of
    /// its underlying type, not only its variants' -- clang's
    /// `enum_extensibility(open)`. A closed one (the default) has a niche
    /// past its values (EnumNiche) and a checked `as` from its underlying
    /// type (CastTyping). Writers: the parser stamps it, TypeResolve ORs it
    /// over a forward declaration's chain, DeclImport sets it on every
    /// imported C/C++ enum (clang owns those values). Never set on an ADT
    /// (the parser rejects `@open` there).
    pub var is_open: bool = false
    /// ADT enums: the record EnumLayoutLowering builds, and its `__kairo_tag`
    /// field (tags are variant positions, in the narrowest unsigned word
    /// that holds them unless `derives` names one). One writer:
    /// EnumLayoutLowering; null until it runs, always null on a plain enum.
    pub var adt_layout:    unsafe *Decl      = &null
    pub var adt_tag_field: unsafe *FieldDecl = &null
    /// Niche layout (spec ENUMLAYOUT §5; EnumLayoutLowering's header). One
    /// writer, EnumLayoutLowering. `adt_niche_shape`: the declaration could
    /// be laid out without a tag -- one variant carries a payload, of one
    /// field, beside at least one without -- so a generic one gets the
    /// niche-filled partial specialization beside its tagged primary.
    /// `adt_niche`: a non-generic one IS laid out that way. `adt_which`: the
    /// AdtRole::Which member, on a generic ADT and a niche-filled one.
    pub var adt_niche_shape: bool                 = false
    pub var adt_niche:       bool                 = false
    pub var adt_which:       unsafe *FunctionDecl = &null
    /// Lang-item layout overrides (EnumLayoutLowering::_knobs, spec
    /// ENUMLAYOUT §7), all off by default: a pack-expanded variant's
    /// elements are tagged by type id (Compiler/Spec/Panic.md#canonical-sets) instead of position,
    /// so tags are not dense; the payload union is aligned to at least
    /// `adt_union_align` (and its payloads'), which `adt_payload_offset`,
    /// a compile-time member, states in C++; `adt_site_field` is a u32
    /// slot between the tag and the union; a payload field whose type is a
    /// bare parameter holds an empty struct for `void` (`adt_void_unit`).
    /// One writer, EnumLayoutLowering.
    pub var adt_explicit_tags:  bool              = false
    pub var adt_union_align:    u32               = 0
    pub var adt_site_field:     unsafe *FieldDecl = &null
    pub var adt_payload_offset: unsafe *FieldDecl = &null
    pub var adt_void_unit:      bool              = false
    /// The tag in the payloads' common prefix (spec ENUMLAYOUT §6;
    /// EnumLayoutLowering's header): `adt_tag_member` is the union's
    /// tag-only member `__kairo_t`, `adt_prefix_tag` its one field, which
    /// every payload struct also starts with. Null for the external tag.
    pub var adt_tag_member: unsafe *FieldDecl = &null
    pub var adt_prefix_tag: unsafe *FieldDecl = &null

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *EnumDecl {
        var unsafe *node = ctx->alloc<EnumDecl>()
        node->kind  = DeclKind::EnumDecl
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Enum, ctx, parent, node)
        node->init_redecl()
        node->adt_layout         = &null
        node->adt_tag_field      = &null
        node->adt_niche_shape    = false
        node->adt_niche          = false
        node->adt_which          = &null
        node->adt_explicit_tags  = false
        node->adt_union_align    = 0
        node->adt_site_field     = &null
        node->adt_payload_offset = &null
        node->adt_void_unit      = false
        node->adt_tag_member     = &null
        node->adt_prefix_tag     = &null
        return node
    }

    pub static fn create_error(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *EnumDecl {
        var unsafe *node = ctx->alloc<EnumDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::EnumDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Enum, ctx, &null, node)
        node->init_redecl()
        node->adt_layout         = &null
        node->adt_tag_field      = &null
        node->adt_niche_shape    = false
        node->adt_niche          = false
        node->adt_which          = &null
        node->adt_explicit_tags  = false
        node->adt_union_align    = 0
        node->adt_site_field     = &null
        node->adt_payload_offset = &null
        node->adt_void_unit      = false
        node->adt_tag_member     = &null
        node->adt_prefix_tag     = &null
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::EnumDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::EnumDecl
    }

    fn variant_count(self) -> usize {
        return self.variants.size()
    }

    fn has_explicit_underlying(self) -> bool {
        return self.underlying != &null
    }
}

///
///  UnionDecl
///  union Register { var as_u32: u32; var as_bytes: [u8; 4] }
///
///  Trivial-field overlay. Fields stored as FieldDecl. Unsafe by default
///  (type-punning); DeclContext holds nested type decls.
///
pub class UnionDecl
  derives Decl,
          DeclContext,
          Redeclarable<UnionDecl>,
          TemplateParams<UnionDecl>,
          FFILinkage<UnionDecl> {
    pub var name:   Token
    pub var fields: FrozenList<unsafe *FieldDecl>
    /// Constructors and operator overloads only - same rule as StructDecl.
    pub var methods: FrozenList<unsafe *FunctionDecl>
    /// No name (`name` is the empty token): the union exists only as the type
    /// of one FieldDecl with `is_anonymous_union`, and codegen emits it there,
    /// inline, never as a type of its own. Its members join no lookup table
    /// (see FieldDecl::is_anonymous_union). Kairo source cannot write one;
    /// one writer: EnumLayoutLowering, for an ADT's payload storage.
    pub var is_anonymous: bool = false

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *UnionDecl {
        var unsafe *node = ctx->alloc<UnionDecl>()
        node->kind  = DeclKind::UnionDecl
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Union, ctx, parent, node)
        node->init_redecl()
        node->is_anonymous = false
        return node
    }

    pub static fn create_error(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *UnionDecl {
        var unsafe *node = ctx->alloc<UnionDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::UnionDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Union, ctx, &null, node)
        node->init_redecl()
        node->is_anonymous = false
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::UnionDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::UnionDecl
    }
}

///
///  TypeAliasDecl
///  type Meters = f64 | type <T> Matrix = [[T]]
///
///  Transparent alias by default (opaque under -fno-type-aliasing, a sema
///  concern). TemplateParams for generic aliases; not a scope owner.
///
pub class TypeAliasDecl derives Decl, TemplateParams<TypeAliasDecl>, FFILinkage<TypeAliasDecl> {
    pub var name:    Token
    pub var aliased: unsafe *Type ///< the right-hand-side type; an associated type's DEFAULT, or null.
    /// An interface's associated type (`type N`, `type N impl X`, `type N =
    /// D`; interfaces.md "Associated Types"). Its bounds are its
    /// requires_clause, `N impl X && N impl Y`, as any requires clause is.
    pub var is_associated: bool = false

    pub static fn create(ctx:     unsafe *ASTContext,
                         range:   SourceRange,
                         name:    Token,
                         aliased: unsafe *Type) -> unsafe *TypeAliasDecl {
        var unsafe *node = ctx->alloc<TypeAliasDecl>()
        node->kind  = DeclKind::TypeAliasDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->name          = name
        node->aliased       = aliased
        node->is_associated = false
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TypeAliasDecl {
        var unsafe *node = ctx->alloc<TypeAliasDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::TypeAliasDecl
        node->range         = range
        node->aliased       = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::TypeAliasDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::TypeAliasDecl
    }
}

/// \brief Groups declarations inside an `ffi "lang" { ... }` block.
///
/// Exists for ASTPrinter round-tripping and so sema can walk FFI blocks
/// as a unit. The children carry their own FfiLinkage mixin stamps; this
/// node holds the language token for the block as a whole.
///
/// Not a DeclContext, the children are top-level decls scoped to the
/// enclosing module/file, not to the ffi block itself.
pub class FFIBlockDecl derives Decl {
    pub var lang_token: Token                    ///< the string literal ("c" / "c++")
    pub var body:       FrozenList<unsafe *Decl> ///< child declarations

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         lang:  Token) -> unsafe *FFIBlockDecl {
        var unsafe *node = ctx->alloc<FFIBlockDecl>()
        node->kind       = DeclKind::FFIBlockDecl
        node->range      = range
        node->lang_token = lang
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *FFIBlockDecl {
        var unsafe *node = ctx->alloc<FFIBlockDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::FFIBlockDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::FFIBlockDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::FFIBlockDecl
    }
}

///
///  ModuleDecl
///  module Foo { } | inline module Foo { } | module { } (anonymous)
///
///  Owns its declarations via DeclContext. Redeclarable: modules reopen
///  (must match visibility, sema-checked). `is_anonymous` => no name token.
///
pub class ModuleDecl
  derives Decl,
          DeclContext,
          Redeclarable<ModuleDecl> {
    pub var name:         Token
    pub var is_inline:    bool  = false ///< `inline module`.
    pub var is_anonymous: bool  = false ///< `module { }`.

    /// FULL module path of this module (e.g. `foo::bar`), not just the leaf
    /// `name`. For a synthetic per-file module this is the file's module_base.
    ///
    /// NOT YET READ by mangling/codegen, which key off `name` (the leaf) today.
    /// That is a KNOWN limitation: two files sharing a leaf (foo/bar.k and
    /// baz/bar.k both named `bar`) would emit two `namespace bar` blocks that
    /// C++ MERGES  distinct modules would fuse. When that case is hit, switch
    /// mangling/codegen to reconstruct the qualified name from `module_path`
    /// (or the DC parent chain); this field is stored now precisely so that fix
    /// is a one-consumer bolt-on, not an AST reshape.
    pub var module_path: ModulePath

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *ModuleDecl {
        var unsafe *node = ctx->alloc<ModuleDecl>()
        node->kind  = DeclKind::ModuleDecl
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Module, ctx, parent, node)
        node->init_redecl()
        return node
    }

    pub static fn create_error(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *ModuleDecl {
        var unsafe *node = ctx->alloc<ModuleDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::ModuleDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Module, ctx, &null, node)
        node->init_redecl()
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::ModuleDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::ModuleDecl
    }
}

///
///  ImportDecl
///  import a::b::c | import x as y | import self::foo | import module::foo | ffi "c++" import "h" as z
///
///  `path_segments` holds the dotted/scoped path tokens. `alias` is the `as`
///  rename (empty token if none). `ffi_lang` distinguishes a native import
///  (empty) from ffi "c"/"c++" header imports, whose `header` literal is set.
///
/// The kind is the path's ANCHOR, the one place it is looked for; the
/// anchor keyword itself is never in `path_segments`.
pub enum ImportKind derives u8 {
    Native = 0,     ///< import a::b::c         -- the search roots
    SelfRelative,   ///< import self::a::b      -- the importing file's directory
    ModuleRelative, ///< import module::a::b    -- its module root (nearest module.k)
}

/// A single brought-in item in a selective import list:
///   `std::io::{File as FILE, stat::Status}`
///                ^^^^^^^^^^^  ^^^^^^^^^^^^
/// `sub_path` is the item's path RELATIVE to the import's base path
/// (e.g. ["File"] or ["stat", "Status"]). `alias` renames it (`as FILE`);
/// `has_alias` gates it. A wildcard item (`{ * }`) sets is_wildcard.
pub struct ImportItem {
    pub var sub_path:    FrozenList<Token> ///< path relative to the base path.
    pub var alias:       Token             ///< `as <name>`; meaningful iff has_alias.
    pub var range:       SourceRange
    pub var has_alias:   bool
    pub var is_wildcard: bool              ///< `*` inside the brace list.
    pub var is_macro:    bool
}

pub class ImportDecl derives Decl, FFILinkage<ImportDecl> {
    pub var import_kind: ImportKind = ImportKind::Native

    /// Base path. For `import a::b::c` it is the whole path; for a selective
    /// import `a::b::{x, y}` it is the prefix `a::b`. Empty for ffi imports.
    pub var path_segments: FrozenList<Token>

    /// Selective import items. Empty for a plain `import a::b::c`. When
    /// non-empty, the import brings in each item under `path_segments`.
    pub var items: FrozenList<ImportItem>

    pub var header:            Token         ///< string literal for ffi imports.
    pub var alias:             Token         ///< top-level `as <name>`; empty if none.
    pub var has_alias:         bool  = false
    pub var is_wildcard:       bool  = false ///< whole-path wildcard `import x::*`.
    pub var has_items:         bool  = false ///< true when `items` is populated.
    pub var last_seg_is_macro: bool  = false

    /// Synthesized by the driver, not written by the user: the implicit
    /// `import builtin::*` every non-builtin TU behaves as though it opened
    /// with. Set next to resolved_fid, which the driver stamps directly --
    /// the PP's path resolution never runs for this node, because there are
    /// no real path_segments to spell.
    ///
    /// Read only where the distinction is user-visible: the AST printer hides
    /// it (printing an import the source does not contain is a lie about the
    /// file), and the sema dump labels it. Phase I treats it as an ordinary
    /// private wildcard import -- which is exactly what it means.
    pub var is_prelude: bool = false

    /// Source-module file id, resolved by the PP walk (FileImportIndex) at the
    /// point the import path resolves. 0 = unresolved. Written ONCE by the PP;
    /// read by the parser disambig fallback (Full mode) and by
    /// Sema/ImportResolution. Never mutated after.
    ///
    /// ffi imports are the exception to "by the PP": a header's fid does not
    /// exist until its HeaderSet is indexed, so the driver writes it
    /// (FrontendAction::_attach_ffi_edges) -- the header's own fid, or 0 when
    /// clang never resolved the spelling.
    pub var resolved_fid: u32 = 0

    /// How many leading path_segments name the FILE that resolved to
    /// resolved_fid. Segments past this are a symbol path INSIDE that file.
    /// Written by the PP next to resolved_fid. Equals path_segments.size()
    /// for a plain module import; 0 = unresolved / ffi.
    pub var file_seg_count: u32 = 0

    /// ffi only: the fid of every header in the imported header's transitive
    /// include closure, the header itself first. What phase I folds
    /// (Compiler/Spec/Interop.md#ffi-imports). Written by the driver next to resolved_fid.
    pub var ffi_closure_fids: cxx::std::vector<u32>

    /// ImportDecl and MacroDecl are PP-stage nodes: the preprocessor consumes
    /// them out of the token stream into tu->imports / tu->macros, which live
    /// in pp_alloc. Their storage MUST live there too   if they sat in
    /// ast_alloc, release_from(Parsing) would free them while those
    /// ArenaLists still pointed at them.
    ///
    /// DeclParse::_parse_import can also build an ImportDecl from the parse
    /// stage (no-PP tooling mode). Keeping it in pp_alloc is still the safe
    /// direction there: the node outlives the AST that references it, which
    /// leaks until release(Preprocessing) rather than dangling.
    pub static fn create(ctx:         unsafe *ASTContext,
                         range:       SourceRange,
                         import_kind: ImportKind) -> unsafe *ImportDecl {
        var unsafe *node = ctx->alloc_pp<ImportDecl>()
        node->kind  = DeclKind::ImportDecl
        node->range = range
        node->init_annotations(unsafe &ctx->pp_alloc)
        node->import_kind = import_kind
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ImportDecl {
        var unsafe *node = ctx->alloc_pp<ImportDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::ImportDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->pp_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::ImportDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::ImportDecl
    }
}

///
///  VisibilityGroupDecl
///  pub { fn foo() {} fn bar() {} }
///
///  A visibility prefix applied to a brace group of decls. Holds the applied
///  visibility and the contained decls. The parser stamps each child's
///  visibility from `group_visibility`; this node is retained for printing /
///  source fidelity.
///
pub class VisibilityGroupDecl derives Decl {
    pub var group_visibility: u8                       = 0 ///< matches VisibilityKind.
    pub var members:          FrozenList<unsafe *Decl>

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         vis:   u8) -> unsafe *VisibilityGroupDecl {
        var unsafe *node = ctx->alloc<VisibilityGroupDecl>()
        node->kind  = DeclKind::VisibilityGroupDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->group_visibility = vis
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *VisibilityGroupDecl {
        var unsafe *node = ctx->alloc<VisibilityGroupDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::VisibilityGroupDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::VisibilityGroupDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::VisibilityGroupDecl
    }
}

///
///  EvalBlockDecl
///  eval { decl* } at namespace/type scope (decl-only compile-time block).
///  The stmt-position eval block is StmtKind::EvalBlockStmt.
///
///  Also the carrier for an `eval if` / `eval for` written directly in a
///  module or class body: `stmt` holds the ConditionalStmt / RangedForStmt /
///  IndexedForStmt exactly as file scope and a function body build it, and
///  `body` stays empty. A module or class body holds declarations only, so
///  the statement needs a declaration to ride in; the branches' declarations
///  are DeclStmts in its blocks and are NOT members of the enclosing body
///  (choosing a branch and hoisting its declarations is eval semantics).
///
pub class EvalBlockDecl derives Decl {
    pub var body: FrozenList<unsafe *Decl>
    pub var stmt: unsafe *Stmt             = &null

    pub static fn create(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *EvalBlockDecl {
        var unsafe *node = ctx->alloc<EvalBlockDecl>()
        node->kind  = DeclKind::EvalBlockDecl
        node->range = range
        node->stmt  = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *EvalBlockDecl {
        var unsafe *node = ctx->alloc<EvalBlockDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::EvalBlockDecl
        node->range         = range
        node->stmt          = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::EvalBlockDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::EvalBlockDecl
    }
}

///
///  TestDecl
///  test "should add correctly" { assert 1 + 1 == 2, "" }
///
pub class TestDecl derives Decl, DeclContext {
    pub var label: unsafe *Expr         = &null ///< StringLiteralExpr label.
    pub var body:  unsafe *CompoundStmt = &null

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         parent: unsafe *DeclContext) -> unsafe *TestDecl {
        var unsafe *node = ctx->alloc<TestDecl>()
        node->kind  = DeclKind::TestDecl
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Function, ctx, parent, node)
        return node
    }

    pub static fn create_error(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *TestDecl {
        var unsafe *node = ctx->alloc<TestDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::TestDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Function, ctx, &null, node)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::TestDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::TestDecl
    }
}

/// structured, klib-visible macro parameter. default token TEXT lives in the
/// runtime MacroEntry's owned storage; the node carries offsets so printing
/// and klib can reconstruct without retaining source buffers.
pub struct MacroParamSpec {
    pub var name:        Token
    pub var variadic:    u8    = 0     ///< 0 none / 1 named / 2 unnamed
    pub var has_default: bool  = false
    pub var default_off: u32   = 0     ///< offset into MacroEntry storage
    pub var default_len: u32   = 0
}

///
///  MacroDecl
///  macro foo!(x) { ... } token-level macro.
///
///  Params are bare identifier tokens (typeless). `body_span` covers the raw
///  token run between braces; the macro engine re-lexes/substitutes it.
///
pub class MacroDecl derives Decl {
    pub var name:           Token
    pub var params_spec:    FrozenList<MacroParamSpec> ///< structured param info for klib/runtime.
    pub var body_span:      SourceRange ///< raw body token span.
    pub var is_variadic:    bool                       = false ///< `macro f!(...args)`.
    pub var accepts_params: bool                       = false ///< `macro f!(x, y) { ... }` vs `macro f! { ... }`.

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         name:  Token) -> unsafe *MacroDecl {
        var unsafe *node = ctx->alloc_pp<MacroDecl>()
        node->kind  = DeclKind::MacroDecl
        node->range = range
        node->init_annotations(unsafe &ctx->pp_alloc)
        node->name = name
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *MacroDecl {
        var unsafe *node = ctx->alloc_pp<MacroDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::MacroDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->pp_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::MacroDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::MacroDecl
    }
}

///
///  ProcedureMacroDecl
///  macro @derive(node: *AST::ClassDecl, ...) { ... } attribute/proc macro.
///
///  Unlike MacroDecl, a proc macro has typed params and a real Kairo body
///  (a CompoundStmt) that runs at compile time over AST nodes. Owns a scope
///  via DeclContext for its params + locals.
///
pub class ProcedureMacroDecl derives Decl, DeclContext {
    pub var name:   Token                                 ///< the `@name` identifier.
    pub var params: FrozenList<unsafe *ParamDecl>
    pub var body:   unsafe *CompoundStmt          = &null

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *ProcedureMacroDecl {
        var unsafe *node = ctx->alloc<ProcedureMacroDecl>()
        node->kind  = DeclKind::ProcedureMacroDecl
        node->range = range
        node->name  = name
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Function, ctx, parent, node)
        return node
    }

    pub static fn create_error(ctx:   unsafe *ASTContext,
                               range: SourceRange) -> unsafe *ProcedureMacroDecl {
        var unsafe *node = ctx->alloc<ProcedureMacroDecl>()
        node->kind          = DeclKind::RecoveryDecl
        node->recovery_kind = DeclKind::ProcedureMacroDecl
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init_dc(DeclContextKind::Function, ctx, &null, node)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Decl) -> bool {
        return ptr->kind == DeclKind::ProcedureMacroDecl
    }

    /* OVERRIDE */
    static fn decl_kind() -> DeclKind {
        return DeclKind::ProcedureMacroDecl
    }
}
