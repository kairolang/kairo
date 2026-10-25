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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::Mixin::Redeclarable::*;
import AST::Mixin::TemplateParams::*;
import AST::Mixin::FFILinkage::*;
import Location::SourceRange::*;
import Token::Token::*;
import Resolution::ModulePath::*;
import AST::ParamMode::*;

/// Forward decls for cross-references between decl nodes.
class FieldDecl;     // enum-variant payloads, struct/class members
class ParamDecl;     // function parameters
class GenericParamDecl;

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
enum SpecKind derives u8 {
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

/// CRTP mixin: a decl `T` derives TemplateParams::<T> to carry generic
/// parameters. Non-generic decls leave `params` empty (count 0) and
/// `requires_clause` null; is_generic() is the cheap gate.
class <T> TemplateParams {
    pub var generic_params: FrozenList::<*GenericParamDecl>;
    pub var requires_clause: *Expr = &null; ///< `requires <expr>`; null if none.

    /// Specialization classification. `spec_kind == None` for ordinary decls.
    pub var spec_kind: SpecKind = SpecKind::None;
    /// The post-name `<...>` argument pattern for a specialization
    /// (`<i32>`, `<[T]>`). Empty for None/Primary-via-`<T>` forms.
    pub var spec_args: FrozenList::<*Type>;

    ///   Instantiated   the primary, always: "an instance of which template".
    ///                  A partial spec whose pattern the args select is the
    ///                  BODY, kept on the registry entry (InstanceEntry::
    ///                  pattern; SemaContext::body_of), never here. Written
    ///                  by the registry.
    ///   Explicit/Partial  the primary. Written by T at registration.
    ///   None/Primary   null.
    pub var instantiated_from: *Decl = &null;
    /// Instantiated only: M2 has filled the body. Until then the node's tables
    /// and base list are EMPTY and lookup walks `instantiated_from`. For an
    /// instance of an IMPORTED template the filler is ForeignInstantiate
    /// (clang's instantiation), not M2.
    pub var instantiated: bool = false;
    /// Instantiated + imported primary only: ForeignInstantiate tried and
    /// clang could not (or Kairo could not ask). Sticky, so a failed instance
    /// costs one attempt per build, not one per member lookup; lookup keeps
    /// walking the pattern.
    pub var foreign_fill_failed: bool = false;

    fn is_specialization(self) -> bool {
        return (self.spec_kind == SpecKind::Explicit)
            || (self.spec_kind == SpecKind::Partial)
            || (self.spec_kind == SpecKind::Instantiated);
    }

    fn is_instance(self) -> bool { return self.spec_kind == SpecKind::Instantiated; }

    /// True if this decl has explicit `<T>` type parameters.
    fn has_type_params(self) -> bool {
        return !self.generic_params.is_empty();
    }

    /// Parser-disambiguation gate: does this decl make its *name* a generic
    /// use-site (`name<...>` parses as generic application)?
    ///
    /// A name is generic iff it carries type parameters OR is a Primary
    /// template. Explicit/Partial specializations do NOT mark the name
    /// generic on their own the primary owns that fact.
    fn is_generic(self) -> bool {
        return self.has_type_params()
            || (self.spec_kind == SpecKind::Primary);
    }

    fn generic_param_count(self) -> usize {
        return self.generic_params.size();
    }

    fn has_requires(self) -> bool {
        return self.requires_clause != &null;
    }
}

///
///  Shared small enums
///

/// Linkage / dispatch modifier on a callable. Mirrors the abi_mod grammar
/// production (ffi "c"/"c++", static, virtual, override) plus the plain case.
enum AbiKind derives u8 {
    None = 0,    ///< no abi modifier; default Kairo linkage.
    Static,      ///< internal linkage, no vtable slot.
    Virtual,     ///< vtable dispatch.
    Override,    ///< overrides a base virtual; implies virtual.
}

/// Storage class for VariableDecl / FieldDecl.
enum StorageClass derives u8 {
    Var = 0,  ///< var      mutable, automatic.
    Const,    ///< const    immutable.
    Static,   ///< static   static storage duration.
    Eval,     ///< eval     compile-time constant.
}

/// Function effect/qualifier bitmask. These mirror the function_mods grammar
/// (const/volatile/unsafe/eval/async/final/panic/inline). Stored as a bitset
/// so a method can be e.g. `const inline`.
enum FnModifier derives u16 {
    None       = 0,
    IsConst    = 1 << 0,
    IsVolatile = 1 << 1,
    IsUnsafe   = 1 << 2,
    IsEval     = 1 << 3,
    IsAsync    = 1 << 4,
    IsFinal    = 1 << 5,
    IsPanic    = 1 << 6,
    IsInline   = 1 << 7,
}

// INLINE(cxx-feature: operators on an enum type)
inline "c++" {
    FnModifier  operator|(FnModifier a, FnModifier b) { return static_cast<FnModifier>(static_cast<uint16_t>(a) | static_cast<uint16_t>(b)); }
    FnModifier  operator&(FnModifier a, FnModifier b) { return static_cast<FnModifier>(static_cast<uint16_t>(a) & static_cast<uint16_t>(b)); }
    FnModifier& operator|=(FnModifier& a, FnModifier b) { a = a | b; return a; }
}

/// How a function body is provided. Drives codegen and the redeclaration
/// "definition wins" merge.
enum FnBodyKind derives u8 {
    None = 0,   ///< forward declaration / FFI import no body.
    Block,      ///< `{ ... }` a CompoundStmt body.
    Expr,       ///< `= expr` expression-bodied.
    Default,    ///< `= default` compiler-generated.
    Delete,     ///< `= delete` deleted.
    Virtual,    ///< `= virtual` pure virtual (abstract).
}

/// Lifecycle attribute on a transfer constructor (@copy / @move).
enum TransferKind derives u8 {
    NotTransfer = 0, ///< not a transfer ctor.
    Copy,            ///< @copy fn T(self, other: Self)
    Move,            ///< @move fn T(self, other: Self)
}

/// What a function minted for an ADT's layout record is
/// (FunctionDecl::adt_role). None of them has a Kairo spelling, so none has
/// a Kairo body: InterfaceEmitter renders each from its role and form.
enum AdtRole derives u8 {
    None = 0,        ///< an ordinary function.
    VariantCtor,     ///< builds one variant: `E(__kairo_vt<I>, F&& payload)`.
    CopyCtor,
    MoveCtor,
    CopyAssign,
    MoveAssign,
    Dtor,
    Destroy,         ///< destroys the active payload: `__kairo_destroy()`.
    ConstructFrom,   ///< builds a payload from another value's: `__kairo_construct_from(o)`.
}

/// Which of the three forms of an ADT special member a role function is
/// (FunctionDecl::adt_form). A generic ADT declares all three, constrained
/// so that exactly one is selected; a non-generic one only the form its
/// lifecycle facts select.
enum AdtForm derives u8 {
    Trivial = 0,     ///< `= default`.
    Body,            ///< written out: the payload is destroyed and built by hand.
    Deleted,         ///< `= delete`.
}

/// How a record's `op =` reaches C++ (ClassDecl / StructDecl::assign_form).
/// Assignment is never written in Kairo: it is derived from the transfer
/// constructor. ClassLifecycle decides the derivation and InterfaceEmitter
/// writes it, in the class, since no Kairo decl stands behind it.
enum AssignForm derives u8 {
    Implicit = 0,    ///< no transfer constructor written: C++'s implicit assignment is the derived one; nothing is declared.
    Default,         ///< `= default`: member by member, from a defaulted transfer constructor.
    Body,            ///< destroy the old value, then build the new one in place through the transfer constructor.
    Deleted,         ///< `= delete`: a deleted transfer, a polymorphic record with a transfer body, or a part that cannot be assigned.
    Constrained,     ///< a Body that an instance of a generic record may not allow: Body and Deleted, each under a C++ constraint.
}

/// Inheritance edge: base type + how its members are re-exposed + virtual.
struct InheritEdge {
    var base:       *Type;            ///< the base/interface type reference.
    var visibility: u8;               ///< 0 None / pub / prot / priv (matches VisibilityKind).
    var is_virtual: bool;             ///< `derives virtual A`.
    var range:      SourceRange;
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
enum GenericParamKindBound derives u8 {
    Any = 0,   ///< no `: kind` bound: T is OPAQUE. No members, no `::`.
    Class,
    Struct,
    Enum,
    Union,
    Duck,      ///< `: type`: full C++ duck typing, every member access deferred to M2.
}

class GenericParamDecl derives Decl {
    pub var name:           Token;                  ///< the parameter identifier (T, N, ...).
    /// The decl that DECLARES this parameter (the class/fn/alias/extension),
    /// as its redecl representative. A generic param sits in no symbol table
    /// -- it is a template parameter, not a member -- so `semantic_dc` is null
    /// on it and there is no other way back. T stamps this when it pushes the
    /// param's frame, with exactly the owner the canonical GenericParamType is
    /// uniqued on, so `param -> canonical` and `canonical -> param` agree.
    /// Null for a closure's params (a closure is not a decl) and before T.
    pub var owner:          *Decl = &null;
    pub var kind_bound:     GenericParamKindBound = GenericParamKindBound::Any;
    pub var impl_bounds:    FrozenList::<InheritEdge>;  ///< `impl` interface bounds (structural).
    pub var derives_bounds: FrozenList::<InheritEdge>;  ///< `derives` base bounds (nominal, vtable).
    pub var is_pack:        bool = false;           ///< `...T` variadic pack.
    pub var is_const_param: bool = false;           ///< `const N: T` value parameter.
    pub var value_type:     *Type = &null;          ///< type of a const value param; null for type params.
    pub var default_type:   *Type = &null;          ///< `<T = i32>` default; null if none.
    pub var index:          u32 = 0;                ///< position in the param list.

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        name:  Token,
        index: u32
    ) -> *GenericParamDecl {
        var node   = ctx->alloc::<GenericParamDecl>();
        node->kind  = DeclKind::GenericParamDecl;
        node->range = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->name  = name;
        node->index = index;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *GenericParamDecl {
        var node            = ctx->alloc::<GenericParamDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::GenericParamDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::GenericParamDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::GenericParamDecl;
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
class ParamDecl derives Decl {
    pub var name:        Token;            ///< parameter name.
    pub var type_:       *Type;            ///< declared type (never inferred for params).
    pub var default_val: *Expr = &null;    ///< default value expr; null if none.
    pub var is_self:     bool = false;     ///< true for the `self` parameter.
    pub var is_const:    bool = false;     ///< true for a `const` parameter; on `const self` it also marks the method FnModifier::IsConst.
    pub var index:       u32 = 0;          ///< position in the parameter list.
    pub var unname:      bool = false;     ///< true for the `unnamed` parameter.
    pub var has_default: bool = false;     ///< imported C++ param with a default arg; no Kairo expr to carry.
    /// Imported C++ param whose C integer type maps to the same Kairo integer
    /// as another C type but is not the one the target spells that width
    /// with (`long` on LLP64 is i32, as `int` is). TypeImport::is_int_alias
    /// sets it; OverloadResolution's integer tiebreak reads it.
    pub var cxx_int_alias: bool = false;

    /// This parameter carries the `...`. Set by DeclParse on the marked
    /// parameter, which need not be the last one. `FunctionDecl::is_variadic`
    /// and `ClosureExpr::is_variadic` are DERIVED from this (true iff some
    /// parameter has it) and are never written directly -- the list is the
    /// truth about which parameter is the pack, and a flag on the function
    /// cannot say that.
    pub var is_pack:      bool = false;
    /// A non-pack parameter that follows the pack. It can only be supplied by
    /// name, because every remaining positional argument belongs to the pack.
    /// Set by DeclParse when it closes the list.
    pub var keyword_only: bool = false;

    /// The nullary function CallLowering minted for this parameter's default,
    /// stamped on the parameter at this index in EVERY link of the redecl
    /// chain: overload resolution may select any link, and defaults
    /// accumulate across links (RedeclMerge admits one per index). Null when
    /// the parameter has no default, or has an imported C++ one (has_default),
    /// which is omitted from the call and never has a thunk.
    pub var default_thunk: *Decl = &null;

    /// is_pack only: the parameter's C++ type, `Slice<E>` by value, E being
    /// the canonical `type_` names. Stamped by CallLowering when it visits
    /// the function (or first lowers a call to it); read by CXXSpell and
    /// EmitIR. Null for a pack over a dependent element (not lowered yet).
    pub var pack_type: *Type = &null;

    /// Passing mode. Legal only here (and on a fn-pointer type's parameter
    /// positions); the parser rejects it everywhere else. See AST/ParamMode.k.
    /// Never set on `self`: the receiver is already a reference parameter.
    pub var mode:       ParamMode   = ParamMode::Value;
    pub var mode_range: SourceRange = SourceRange::invalid();  ///< the `@inout` / `@move` tokens.

    fn is_inout(self) -> bool { return self.mode == ParamMode::Inout; }
    fn is_move(self)  -> bool { return self.mode == ParamMode::Move;  }

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        name:  Token,
        type_: *Type,
        index: u32,
        unname: bool = false
    ) -> *ParamDecl {
        var node    = ctx->alloc::<ParamDecl>();
        node->kind   = DeclKind::ParamDecl;
        node->range  = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->mode       = ParamMode::Value;
        node->mode_range = SourceRange::invalid();
        node->name   = name;
        node->type_  = type_;
        node->index  = index;
        node->unname = unname;
        node->is_pack      = false;
        node->keyword_only = false;
        node->default_thunk = &null;
        node->pack_type     = &null;
        return node;
    }

    /// `self` parameter: no type (resolved to the enclosing type by sema).
    static fn create_self(ctx: *ASTContext, range: SourceRange, name: Token) -> *ParamDecl {
        var node     = ctx->alloc::<ParamDecl>();
        node->kind    = DeclKind::ParamDecl;
        node->range   = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->mode       = ParamMode::Value;
        node->mode_range = SourceRange::invalid();
        node->name    = name;
        node->type_   = &null;
        node->is_self = true;
        node->index   = 0;
        node->is_pack      = false;
        node->keyword_only = false;
        node->default_thunk = &null;
        node->pack_type     = &null;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ParamDecl {
        var node            = ctx->alloc::<ParamDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ParamDecl;
        node->range         = range;
        node->type_         = &null;
        node->init_annotations(&(ctx->ast_alloc));;
        node->mode       = ParamMode::Value;
        node->mode_range = SourceRange::invalid();
        node->is_pack      = false;
        node->keyword_only = false;
        node->default_thunk = &null;
        node->pack_type     = &null;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::ParamDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::ParamDecl;
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
class FunctionDecl
  derives Decl,
          DeclContext,
          Redeclarable::<FunctionDecl>,
          TemplateParams::<FunctionDecl>,
          FFILinkage::<FunctionDecl> {
    /// Function name (or ctor = type name). INVARIANT: exactly one of `name`
    /// and `op_token` is set. An operator (`is_operator`) has `name` =
    /// Token(), the default-constructed empty token, and its spelling lives in
    /// `op_token`; spelling that `name` (decl_name, get_spelling, an f-string
    /// in an ICE message) asserts in TokenText::resolve. Every other function
    /// has a real `name` and an empty `op_token`. Check is_operator before
    /// reading `name`.
    pub var name:          Token;
    pub var params:        FrozenList::<*ParamDecl>;
    pub var return_type:  *Type = &null;          ///< null => void (or inferred for expr body).
    pub var abi:           AbiKind    = AbiKind::None;
    pub var modifiers:     FnModifier = FnModifier::None;
    pub var body_kind:     FnBodyKind = FnBodyKind::None;
    pub var body_block:   *CompoundStmt = &null;  ///< when body_kind == Block.
    pub var body_expr:    *Expr         = &null;  ///< when body_kind == Expr.
    pub var is_operator:   bool = false;          ///< `fn op <x>`.
    pub var op_token:      FrozenList::<Token>;   ///< the operator token(s) when is_operator; empty otherwise (see `name`).
    pub var is_variadic:   bool = false;          ///< trailing `...name: T` pack param.
    pub var is_noreturn:   bool = false;          ///< return type is `!`.
    pub var transfer:      TransferKind = TransferKind::NotTransfer; ///< @copy/@move on a transfer ctor.
    /// Written `-> yield T`: a C++ coroutine. Writer: X (StmtTyping::
    /// traverse_function_decl), before the body is typed. The WRITTEN
    /// qualifier, never the canonical: a spelled-out `-> Yield<T>` is an
    /// ordinary record return (`get_return_object` is one).
    pub var is_generator:  bool = false;
    /// A generator whose body has a `yield`. Writer: X, at each yield it
    /// accepts. EmitIR reads it to give an empty generator the `co_return;`
    /// that makes it a coroutine at all, rather than walking the body itself.
    pub var has_yield:     bool = false;
    /// `@no_unwind`: the C++ spelling carries `noexcept`, and that is all it
    /// does. Writer: X (StmtTyping::traverse_function_decl), onto EVERY link
    /// of the redeclaration chain, because C++ requires each declaration of
    /// a function to agree on it and the attribute may be written on only
    /// one of them.
    pub var no_unwind:     bool = false;
    pub var qualifier:    *Expr = &null;          ///< out-of-line `Class::` path (ChainExpr); null otherwise.
    pub var where_clause: *Expr = &null;          ///< `where <expr>` runtime-dispatch guard; functions only, null otherwise.
    pub var ffi_builtin_id: u32 = 0;              ///< clang builtin ID; 0 for every other function.
    pub var ffi_ice_mask:   u32 = 0;              ///< bit i: parameter i takes an integer constant.
    /// A function EnumLayoutLowering minted for an ADT's layout record, or
    /// None. It has no Kairo body and never a requires_clause: InterfaceEmitter
    /// writes its C++ from adt_role and adt_form, constraints included.
    /// adt_variant is the position, in the enum's variants, of the variant a
    /// VariantCtor builds; 0 for every other role. One writer for all three:
    /// EnumLayoutLowering.
    pub var adt_role:      AdtRole = AdtRole::None;
    pub var adt_form:      AdtForm = AdtForm::Trivial;
    pub var adt_variant:   u32     = 0;
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
    /// InterfaceEmitter and EmitIR render the rest (CODEGEN.md §5, §6).
    pub var ci_split:      u32     = 0;
    pub var ci_index:      u32     = 0;
    pub var ci_slots:      FrozenList::<*Decl>;
    pub var ci_dense:      FrozenList::<bool>;
    pub var ci_cut:        bool    = false;

    fn has_where(self) -> bool { return self.where_clause != &null; }

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        name:   Token,
        parent: *DeclContext
    ) -> *FunctionDecl {
        var node    = ctx->alloc::<FunctionDecl>();
        node->kind   = DeclKind::FunctionDecl;
        node->range  = range;
        node->name   = name;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Function, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        node->adt_role    = AdtRole::None;
        node->adt_form    = AdtForm::Trivial;
        node->adt_variant = 0;
        node->ci_split    = 0;
        node->ci_index    = 0;
        node->ci_cut      = false;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *FunctionDecl {
        var node            = ctx->alloc::<FunctionDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::FunctionDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Function, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
        node->adt_role    = AdtRole::None;
        node->adt_form    = AdtForm::Trivial;
        node->adt_variant = 0;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::FunctionDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::FunctionDecl;
    }

    // --- modifier queries ---------------------------------------------------
    fn is_const(self)  -> bool { return (self.modifiers & FnModifier::IsConst)  != FnModifier::None; }
    fn is_unsafe(self) -> bool { return (self.modifiers & FnModifier::IsUnsafe) != FnModifier::None; }
    fn is_eval(self)   -> bool { return (self.modifiers & FnModifier::IsEval)   != FnModifier::None; }
    fn is_async(self)  -> bool { return (self.modifiers & FnModifier::IsAsync)  != FnModifier::None; }
    fn is_panic(self)  -> bool { return (self.modifiers & FnModifier::IsPanic)  != FnModifier::None; }
    fn is_final(self)  -> bool { return (self.modifiers & FnModifier::IsFinal)  != FnModifier::None; }
    fn is_inline(self) -> bool { return (self.modifiers & FnModifier::IsInline) != FnModifier::None; }

    fn is_method(self)      -> bool {
        return (self.params.size() > 0) && (self.params[0]->is_self);
    }
    fn is_out_of_line(self) -> bool { return self.qualifier != &null; }
    fn has_body(self)       -> bool { return self.body_kind != FnBodyKind::None; }
    fn param_count(self)    -> usize { return self.params.size(); }
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
class ClosureExpr derives Expr {
    struct Capture {
        var name:  *NamedIdentExpr; ///< the captured variable's name token.
        var by_ptr: bool;             ///< true if `|&captured|`, false if `|captured|`.
        var is_const: bool = false;             ///< true if `|const &captured|`, false otherwise.
    }

    pub var captures:       FrozenList::<Capture>; ///< captured variables, in source order.
    pub var params:         FrozenList::<*ParamDecl>;
    pub var generic_params: FrozenList::<*GenericParamDecl>;
    pub var body_block:  *CompoundStmt = &null;
    pub var body_expr:   *Expr         = &null;
    pub var return_type: *Type;      ///< null if inferred.
    pub var body_kind:   FnBodyKind = FnBodyKind::None;
    pub var modifiers:   FnModifier = FnModifier::None;
    pub var is_variadic:         bool = false; ///< trailing `...name: T` pack param.
    pub var is_noreturn:         bool = false;
    pub var explicit_no_capture: bool = false;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *ClosureExpr {
        var node    = ctx->alloc::<ClosureExpr>();
        node->kind  = ExprKind::ClosureExpr;
        node->range = range;
        node->body_kind  = FnBodyKind::None;
        node->body_block = &null;
        node->body_expr  = &null;
        node->return_type = &null;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ClosureExpr {
        var node            = ctx->alloc::<ClosureExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::ClosureExpr;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::ClosureExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::ClosureExpr; }
}

///
///  VariableDecl
///  var/const/static/eval binding at local or namespace scope.
///  NOT a class/struct member (that is FieldDecl).
///
///  `type_` is null when inferred. `is_eval` is derived from storage == Eval
///  but kept explicit for the `eval var` stmt path.
///
class VariableDecl derives Decl, FFILinkage::<VariableDecl> {
    pub var name:    Token;
    pub var storage: StorageClass = StorageClass::Var;
    pub var type_:   *Type = &null;   ///< null => inferred from init.
    pub var init:    *Expr = &null;   ///< initializer; null for `var x: T` default-init.
    pub var is_thread: bool = false;  ///< `static thread` thread_local storage.

    static fn create(
        ctx:     *ASTContext,
        range:   SourceRange,
        name:    Token,
        storage: StorageClass
    ) -> *VariableDecl {
        var node     = ctx->alloc::<VariableDecl>();
        node->kind    = DeclKind::VariableDecl;
        node->range   = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->name    = name;
        node->storage = storage;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *VariableDecl {
        var node            = ctx->alloc::<VariableDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::VariableDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::VariableDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::VariableDecl;
    }

    fn is_const(self)  -> bool { return self.storage == StorageClass::Const; }
    fn is_static(self) -> bool { return self.storage == StorageClass::Static; }
    fn is_eval(self)   -> bool { return self.storage == StorageClass::Eval; }
    fn is_inferred(self) -> bool { return self.type_ == &null; }
}

/// What FieldInitLowering made of a field's initializer, for the emitter's
/// default member initializer. None: no initializer was lowered (none was
/// written, or a gate kept it). Int / True / False / Null: a constant the
/// emitter spells itself, the value in FieldDecl::init_neg / init_mag for
/// Int. Thunk: anything else, a call of FieldDecl::init_thunk.
enum FieldFold derives u8 {
    None = 0,
    Int,
    True,
    False,
    Null,
    Thunk,
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
class FieldDecl derives Decl {
    pub var name:       Token;
    pub var storage:    StorageClass = StorageClass::Var;
    pub var type_:      *Type = &null;   ///< field type; null only in recovery.
    pub var init:       *Expr = &null;   ///< at-decl default; null if none, or once FieldInitLowering has consumed it.
    pub var is_mutable: bool = false;    ///< `mutable var` escapes const-self.
    pub var is_thread:  bool = false;    ///< `static thread` thread_local storage.
    pub var index:      u32 = 0;         ///< declaration order in the owning type.
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
    pub var is_anonymous_union: bool = false;
    /// The C++ default member initializer FieldInitLowering made of `init`,
    /// which is null afterwards. A constant (`init_fold` Int, True, False,
    /// Null) is spelled in the class as it is; any other initializer became
    /// the body of `init_thunk`, a member function the default calls. One
    /// writer: FieldInitLowering.
    pub var init_fold:  FieldFold = FieldFold::None;
    pub var init_neg:   bool = false;
    pub var init_mag:   u64 = 0;
    pub var init_thunk: *Decl = &null;

    static fn create(
        ctx:     *ASTContext,
        range:   SourceRange,
        name:    Token,
        storage: StorageClass,
        type_:   *Type,
        index:   u32
    ) -> *FieldDecl {
        var node     = ctx->alloc::<FieldDecl>();
        node->kind    = DeclKind::FieldDecl;
        node->range   = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->name    = name;
        node->storage = storage;
        node->type_   = type_;
        node->index   = index;
        node->is_anonymous_union = false;
        node->init_fold  = FieldFold::None;
        node->init_thunk = &null;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *FieldDecl {
        var node            = ctx->alloc::<FieldDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::FieldDecl;
        node->range         = range;
        node->type_         = &null;
        node->is_anonymous_union = false;
        node->init_fold     = FieldFold::None;
        node->init_thunk    = &null;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::FieldDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::FieldDecl;
    }

    fn is_static(self) -> bool { return self.storage == StorageClass::Static; }
    fn is_const(self)  -> bool { return self.storage == StorageClass::Const; }
}

///
///  StructDecl
///  struct Foo<T> impl Bar { var x: T ... }
///
///  Owns fields (FieldDecl) and nested type decls via DeclContext. Structs
///  cannot have methods in-body (extends add those), so dc_decls holds fields
///  and nested types only. `implements` lists interface conformances.
///
class StructDecl
  derives Decl,
          DeclContext,
          Redeclarable::<StructDecl>,
          TemplateParams::<StructDecl>,
          FFILinkage::<StructDecl> {
    pub var name:       Token;
    pub var fields:     FrozenList::<*FieldDecl>;
    /// Constructors and operator overloads only - a struct body admits no
    /// named methods (the parser rejects those); see _parse_member_body.
    pub var methods:    FrozenList::<*FunctionDecl>;
    pub var implements: FrozenList::<InheritEdge>;   ///< `impl` interface list.
    /// The payload of one ADT variant: its fields are that variant's own
    /// payload FieldDecls, and InterfaceEmitter gives it a placement
    /// operator new, so `new (&member) P(...)` needs no <new>. One writer:
    /// EnumLayoutLowering.
    pub var is_adt_payload: bool  = false;
    /// The ADT enum this record is the layout of (EnumDecl::adt_layout), or
    /// null. One writer: EnumLayoutLowering.
    pub var adt_of:         *Decl = &null;
    /// The transfer constructor this record's `op =` is derived from, or
    /// null (AssignForm::Implicit). One writer: ClassLifecycle.
    pub var assign_from:    *FunctionDecl = &null;
    /// How that `op =` is given to C++. One writer: ClassLifecycle.
    pub var assign_form:    AssignForm    = AssignForm::Implicit;
    /// N > 0: this record IS the tuple of arity N -- `(A, B)` is
    /// `Tuple2<A, B>` -- minted by TupleRecords, never parsed from source
    /// and in no symbol table. Tuple-ness is this flag on the PATTERN, by
    /// identity, never the name `TupleN` (a user may declare one). One
    /// writer: TupleRecords.
    pub var tuple_arity:    u32           = 0;

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        name:   Token,
        parent: *DeclContext
    ) -> *StructDecl {
        var node   = ctx->alloc::<StructDecl>();
        node->kind  = DeclKind::StructDecl;
        node->range = range;
        node->name  = name;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Struct, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        node->is_adt_payload = false;
        node->adt_of         = &null;
        node->assign_from    = &null;
        node->assign_form    = AssignForm::Implicit;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *StructDecl {
        var node            = ctx->alloc::<StructDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::StructDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Struct, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
        node->is_adt_payload = false;
        node->adt_of         = &null;
        node->assign_from    = &null;
        node->assign_form    = AssignForm::Implicit;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::StructDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::StructDecl;
    }

    fn field_count(self) -> usize { return self.fields.size(); }
}

///
///  ClassDecl
///  class Foo<T> derives Bar impl Baz { var x: T; fn m(self) { } }
///
///  Owns fields + methods + nested types via DeclContext. `derives_list`
///  holds base classes (with per-edge visibility + virtual), `implements`
///  holds interface conformances. is_final / is_abstract drive sema checks.
///
class ClassDecl
  derives Decl,
          DeclContext,
          Redeclarable::<ClassDecl>,
          TemplateParams::<ClassDecl>,
          FFILinkage::<ClassDecl> {
    pub var name:         Token;
    pub var fields:       FrozenList::<*FieldDecl>;
    pub var methods:      FrozenList::<*FunctionDecl>;
    pub var derives_list: FrozenList::<InheritEdge>;  ///< base classes.
    pub var implements:   FrozenList::<InheritEdge>;  ///< interfaces.
    pub var is_final:     bool = false;               ///< `final class`.
    pub var is_abstract:  bool = false;               ///< has a `= virtual` method.
    /// The transfer constructor this class's `op =` is derived from, or
    /// null (AssignForm::Implicit). One writer: ClassLifecycle.
    pub var assign_from:  *FunctionDecl = &null;
    /// How that `op =` is given to C++. One writer: ClassLifecycle.
    pub var assign_form:  AssignForm    = AssignForm::Implicit;

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        name:   Token,
        parent: *DeclContext
    ) -> *ClassDecl {
        var node   = ctx->alloc::<ClassDecl>();
        node->kind  = DeclKind::ClassDecl;
        node->range = range;
        node->name  = name;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Class, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        node->assign_from = &null;
        node->assign_form = AssignForm::Implicit;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ClassDecl {
        var node            = ctx->alloc::<ClassDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ClassDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Class, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
        node->assign_from = &null;
        node->assign_form = AssignForm::Implicit;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::ClassDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::ClassDecl;
    }

    fn has_bases(self) -> bool { return !self.derives_list.is_empty(); }
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
struct Requirement {
    var decl:       *Decl;   ///< the ORIGINAL member: a FunctionDecl, or an associated TypeAliasDecl.
    var source:     *Type;   ///< the canonical interface instance it came through (`Y<i32>`); its own interface's for an own member.
    var leaf:       u32;     ///< the derives_list index it came through (provenance); u32(-1) for an own member.
    var bounds:     *Expr;   ///< an associated type's bounds after `+` / `&` merged them (requires-style `&&`); else its own clause.
    var default_ty: *Type;   ///< an associated type's kept default, or null.
}

class InterfaceDecl
  derives Decl,
          DeclContext,
          Redeclarable::<InterfaceDecl>,
          TemplateParams::<InterfaceDecl>,
          FFILinkage::<InterfaceDecl> {
    pub var name:         Token;
    pub var methods:      FrozenList::<*FunctionDecl>;  ///< requirement signatures.
    pub var derives_list: FrozenList::<InheritEdge>;    ///< parent interfaces.
    /// The `derives` clause as written, when it is an EXPRESSION over
    /// interfaces (`X + (Y - Z)`, `A, B` as `A + B`): BinaryOperatorExpr
    /// nodes, op `+` / `-` / `&`, over the leaves as the expression parser
    /// read them (names, `::` chains, generic applications). Leaf i, in
    /// source order, is `derives_list[i]`'s type: the leaves are resolved
    /// as types there, and nothing walks this tree but InterfaceComposition.
    /// Null for no `derives`.
    pub var derives_expr: *Expr = &null;
    /// The clause uses `-` or `&`: not a plain union. Until composition is
    /// compiled such an interface is rejected (InterfaceComposition).
    pub var derives_composed: bool = false;
    /// End of the derives clause: where an LSP shows the derived body.
    pub var derives_end: SourceRange;
    /// Every requirement, own and derived, deduplicated: what binding,
    /// conformance and witnesses read. Written once by InterfaceComposition.
    pub var requirements: FrozenList::<Requirement>;
    /// InterfaceComposition's progress: 0 not yet, 1 in progress (a cycle
    /// reaching it again is an error), 2 done.
    pub var compose_state: u8 = 0;

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        name:   Token,
        parent: *DeclContext
    ) -> *InterfaceDecl {
        var node   = ctx->alloc::<InterfaceDecl>();
        node->kind  = DeclKind::InterfaceDecl;
        node->range = range;
        node->name  = name;
        node->derives_expr     = &null;
        node->derives_composed = false;
        node->compose_state    = 0;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Interface, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *InterfaceDecl {
        var node            = ctx->alloc::<InterfaceDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::InterfaceDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Interface, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::InterfaceDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::InterfaceDecl;
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
class ExtensionDecl
  derives Decl,
          DeclContext,
          TemplateParams::<ExtensionDecl> {
    pub var target:     *Type;                       ///< the type being extended.
    pub var methods:    FrozenList::<*FunctionDecl>;
    pub var implements: FrozenList::<InheritEdge>;    ///< `extend X impl Y`.

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        target: *Type,
        parent: *DeclContext
    ) -> *ExtensionDecl {
        var node    = ctx->alloc::<ExtensionDecl>();
        node->kind   = DeclKind::ExtensionDecl;
        node->range  = range;
        node->target = target;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Extension, ctx, parent, static_cast::<*Decl>(node));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ExtensionDecl {
        var node            = ctx->alloc::<ExtensionDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ExtensionDecl;
        node->range         = range;
        node->target        = &null;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Extension, ctx, &null, static_cast::<*Decl>(node));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::ExtensionDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::ExtensionDecl;
    }
}

/// An integer constant: what Sema's constant evaluator (Sema/Check/
/// ConstEval.k) computes, kept here as plain data so a decl can carry one.
/// Sign-magnitude over u64, so u64's 2^64 - 1 and i64's -2^63 are both
/// exact and no wider type is needed. `ok` false: not a constant.
/// `overflow`: a constant whose magnitude needs more than 64 bits, so no
/// 64-bit type holds it.
struct IntConst {
    var ok:       bool = false;
    var neg:      bool = false;
    var mag:      u64  = 0;
    var overflow: bool = false;
}

///
///  EnumVariantDecl
///  North | Ok = 2 | Found { key: K, value: V }
///
///  A single variant. Plain variants carry an optional explicit `discriminant`
///  expr. ADT variants carry `payload` fields (FieldDecl). Owned by EnumDecl;
///  not independently looked up, so no DeclContext.
///
class EnumVariantDecl derives Decl {
    pub var name:         Token;
    pub var discriminant: *Expr = &null;          ///< `= <const expr>`; null if implicit.
    pub var payload:      FrozenList::<*FieldDecl>; ///< ADT fields; empty for plain variants.
    pub var index:        u32 = 0;                ///< declaration order.
    pub var adt_member:   *FieldDecl = &null;     ///< the union member holding this variant's payload; null when it has none or before EnumLayoutLowering.
    /// The variant's value: its discriminant's, else the previous variant's
    /// plus one, else 0 for the first, so an ADT's variants are their
    /// positions. One writer: StmtTyping::traverse_enum_variant_decl, in
    /// declaration order, which is what lets a discriminant read the
    /// variants above it. Not ok when the value failed (and was reported),
    /// and never written for an imported C++ enum: clang owns those values,
    /// and codegen never emits the enum.
    pub var value:        IntConst;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        name:  Token,
        index: u32
    ) -> *EnumVariantDecl {
        var node    = ctx->alloc::<EnumVariantDecl>();
        node->kind   = DeclKind::EnumVariantDecl;
        node->range  = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->name   = name;
        node->index  = index;
        node->adt_member = &null;
        node->value      = IntConst{};
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EnumVariantDecl {
        var node            = ctx->alloc::<EnumVariantDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::EnumVariantDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->adt_member    = &null;
        node->value         = IntConst{};
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::EnumVariantDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::EnumVariantDecl;
    }

    fn is_adt(self)   -> bool { return !self.payload.is_empty(); }
    fn has_value(self) -> bool { return self.discriminant != &null; }
}

///
///  EnumDecl
///  enum Direction derives u8 { } | enum <T> Result { Ok { value: T }, Err }
///
///  `underlying` is the `derives <int>` type for plain enums; null when
///  defaulted (u32) or for ADT enums. Generic enums (TemplateParams) must be
///  ADT (a plain enum has nothing to parameterize). Owns variants via the
///  `variants` list; DeclContext holds nested type decls.
///
class EnumDecl
  derives Decl,
          DeclContext,
          Redeclarable::<EnumDecl>,
          TemplateParams::<EnumDecl>,
          FFILinkage::<EnumDecl> {
    pub var name:       Token;
    pub var underlying: *Type = &null;                  ///< `derives u8` etc; null if default/ADT.
    pub var variants:   FrozenList::<*EnumVariantDecl>;
    pub var is_adt:     bool = false;                   ///< any variant carries a payload.
    /// ADT enums: the record EnumLayoutLowering builds, and its `__kairo_tag`
    /// field (tags are variant positions, underlying u32). One writer:
    /// EnumLayoutLowering; null until it runs, always null on a plain enum.
    pub var adt_layout:    *Decl      = &null;
    pub var adt_tag_field: *FieldDecl = &null;

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        name:   Token,
        parent: *DeclContext
    ) -> *EnumDecl {
        var node   = ctx->alloc::<EnumDecl>();
        node->kind  = DeclKind::EnumDecl;
        node->range = range;
        node->name  = name;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Enum, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        node->adt_layout    = &null;
        node->adt_tag_field = &null;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EnumDecl {
        var node            = ctx->alloc::<EnumDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::EnumDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Enum, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
        node->adt_layout    = &null;
        node->adt_tag_field = &null;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::EnumDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::EnumDecl;
    }

    fn variant_count(self) -> usize { return self.variants.size(); }
    fn has_explicit_underlying(self) -> bool { return self.underlying != &null; }
}

///
///  UnionDecl
///  union Register { var as_u32: u32; var as_bytes: [u8; 4] }
///
///  Trivial-field overlay. Fields stored as FieldDecl. Unsafe by default
///  (type-punning); DeclContext holds nested type decls.
///
class UnionDecl
  derives Decl,
          DeclContext,
          Redeclarable::<UnionDecl>,
          TemplateParams::<UnionDecl>,
          FFILinkage::<UnionDecl> {
    pub var name:    Token;
    pub var fields:  FrozenList::<*FieldDecl>;
    /// Constructors and operator overloads only - same rule as StructDecl.
    pub var methods: FrozenList::<*FunctionDecl>;
    /// No name (`name` is the empty token): the union exists only as the type
    /// of one FieldDecl with `is_anonymous_union`, and codegen emits it there,
    /// inline, never as a type of its own. Its members join no lookup table
    /// (see FieldDecl::is_anonymous_union). Kairo source cannot write one;
    /// one writer: EnumLayoutLowering, for an ADT's payload storage.
    pub var is_anonymous: bool = false;

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        name:   Token,
        parent: *DeclContext
    ) -> *UnionDecl {
        var node   = ctx->alloc::<UnionDecl>();
        node->kind  = DeclKind::UnionDecl;
        node->range = range;
        node->name  = name;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Union, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        node->is_anonymous = false;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *UnionDecl {
        var node            = ctx->alloc::<UnionDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::UnionDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Union, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
        node->is_anonymous = false;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::UnionDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::UnionDecl;
    }
}

///
///  TypeAliasDecl
///  type Meters = f64 | type <T> Matrix = [[T]]
///
///  Transparent alias by default (opaque under -fno-type-aliasing, a sema
///  concern). TemplateParams for generic aliases; not a scope owner.
///
class TypeAliasDecl derives Decl, TemplateParams::<TypeAliasDecl>, FFILinkage::<TypeAliasDecl> {
    pub var name:    Token;
    pub var aliased: *Type;   ///< the right-hand-side type; an associated type's DEFAULT, or null.
    /// An interface's associated type (`type N`, `type N impl X`, `type N =
    /// D`; interfaces.md "Associated Types"). Its bounds are its
    /// requires_clause, `N impl X && N impl Y`, as any requires clause is.
    pub var is_associated: bool = false;

    static fn create(
        ctx:     *ASTContext,
        range:   SourceRange,
        name:    Token,
        aliased: *Type
    ) -> *TypeAliasDecl {
        var node     = ctx->alloc::<TypeAliasDecl>();
        node->kind    = DeclKind::TypeAliasDecl;
        node->range   = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->name    = name;
        node->aliased = aliased;
        node->is_associated = false;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TypeAliasDecl {
        var node            = ctx->alloc::<TypeAliasDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::TypeAliasDecl;
        node->range         = range;
        node->aliased       = &null;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::TypeAliasDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::TypeAliasDecl;
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
class FFIBlockDecl derives Decl {
    pub var lang_token: Token;               ///< the string literal ("c" / "c++")
    pub var body:       FrozenList::<*Decl>; ///< child declarations

    static fn create(ctx: *ASTContext, range: SourceRange, lang: Token) -> *FFIBlockDecl {
        var node         = ctx->alloc::<FFIBlockDecl>();
        node->kind       = DeclKind::FFIBlockDecl;
        node->range      = range;
        node->lang_token = lang;
        node->init_annotations(&(ctx->ast_alloc));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *FFIBlockDecl {
        var node            = ctx->alloc::<FFIBlockDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::FFIBlockDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::FFIBlockDecl;
    }

    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::FFIBlockDecl;
    }
}

///
///  ModuleDecl
///  module Foo { } | inline module Foo { } | module { } (anonymous)
///
///  Owns its declarations via DeclContext. Redeclarable: modules reopen
///  (must match visibility, sema-checked). `is_anonymous` => no name token.
///
class ModuleDecl
  derives Decl,
          DeclContext,
          Redeclarable::<ModuleDecl> {
    pub var name:         Token;
    pub var is_inline:    bool = false;  ///< `inline module`.
    pub var is_anonymous: bool = false;  ///< `module { }`.

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
    pub var module_path:  ModulePath;

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        name:   Token,
        parent: *DeclContext
    ) -> *ModuleDecl {
        var node   = ctx->alloc::<ModuleDecl>();
        node->kind  = DeclKind::ModuleDecl;
        node->range = range;
        node->name  = name;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Module, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ModuleDecl {
        var node            = ctx->alloc::<ModuleDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ModuleDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Module, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::ModuleDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::ModuleDecl;
    }
}

///
///  ImportDecl
///  import a::b::c | import x as y | import module foo | ffi "c++" import "h" as z
///
///  `path_segments` holds the dotted/scoped path tokens. `alias` is the `as`
///  rename (empty token if none). `ffi_lang` distinguishes a native import
///  (empty) from ffi "c"/"c++" header imports, whose `header` literal is set.
///
enum ImportKind derives u8 {
    Native = 0,   ///< import a::b::c
    ModuleOnly,   ///< import module foo
}

/// A single brought-in item in a selective import list:
///   `std::io::{File as FILE, stat::Status}`
///                ^^^^^^^^^^^  ^^^^^^^^^^^^
/// `sub_path` is the item's path RELATIVE to the import's base path
/// (e.g. ["File"] or ["stat", "Status"]). `alias` renames it (`as FILE`);
/// `has_alias` gates it. A wildcard item (`{ * }`) sets is_wildcard.
struct ImportItem {
    var sub_path:    FrozenList::<Token>; ///< path relative to the base path.
    var alias:       Token;               ///< `as <name>`; meaningful iff has_alias.
    var range:       SourceRange;
    var has_alias:   bool;
    var is_wildcard: bool;                ///< `*` inside the brace list.
    var is_macro:    bool;
}

class ImportDecl derives Decl, FFILinkage::<ImportDecl> {
    pub var import_kind:   ImportKind = ImportKind::Native;

    /// Base path. For `import a::b::c` it is the whole path; for a selective
    /// import `a::b::{x, y}` it is the prefix `a::b`. Empty for ffi imports.
    pub var path_segments: FrozenList::<Token>;

    /// Selective import items. Empty for a plain `import a::b::c`. When
    /// non-empty, the import brings in each item under `path_segments`.
    pub var items:         FrozenList::<ImportItem>;

    pub var header:        Token;                ///< string literal for ffi imports.
    pub var alias:         Token;                ///< top-level `as <name>`; empty if none.
    pub var has_alias:     bool = false;
    pub var is_wildcard:   bool = false;         ///< whole-path wildcard `import x::*`.
    pub var has_items:     bool = false;         ///< true when `items` is populated.
    pub var last_seg_is_macro: bool = false;

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
    pub var is_prelude:    bool = false;

    /// Source-module file id, resolved by the PP walk (FileImportIndex) at the
    /// point the import path resolves. 0 = unresolved. Written ONCE by the PP;
    /// read by the parser disambig fallback (Full mode) and by
    /// Sema/ImportResolution. Never mutated after.
    ///
    /// ffi imports are the exception to "by the PP": a header's fid does not
    /// exist until its HeaderSet is indexed, so the driver writes it
    /// (FrontendAction::_attach_ffi_edges) -- the header's own fid, or 0 when
    /// clang never resolved the spelling.
    pub var resolved_fid: u32 = 0;

    /// How many leading path_segments name the FILE that resolved to
    /// resolved_fid. Segments past this are a symbol path INSIDE that file.
    /// Written by the PP next to resolved_fid. Equals path_segments.size()
    /// for a plain module import; 0 = unresolved / ffi.
    pub var file_seg_count: u32 = 0;

    /// ffi only: the fid of every header in the imported header's transitive
    /// include closure, the header itself first. What phase I folds
    /// (IMPORTS.md §5). Written by the driver next to resolved_fid.
    pub var ffi_closure_fids: vec::<u32>;

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
    static fn create(ctx: *ASTContext, range: SourceRange, import_kind: ImportKind) -> *ImportDecl {
        var node         = ctx->alloc_pp::<ImportDecl>();
        node->kind        = DeclKind::ImportDecl;
        node->range       = range;
        node->init_annotations(&(ctx->pp_alloc));;
        node->import_kind = import_kind;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ImportDecl {
        var node            = ctx->alloc_pp::<ImportDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ImportDecl;
        node->range         = range;
        node->init_annotations(&(ctx->pp_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::ImportDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::ImportDecl;
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
class VisibilityGroupDecl derives Decl {
    pub var group_visibility: u8 = 0;          ///< matches VisibilityKind.
    pub var members:          FrozenList::<*Decl>;

    static fn create(ctx: *ASTContext, range: SourceRange, vis: u8) -> *VisibilityGroupDecl {
        var node             = ctx->alloc::<VisibilityGroupDecl>();
        node->kind            = DeclKind::VisibilityGroupDecl;
        node->range           = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->group_visibility = vis;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *VisibilityGroupDecl {
        var node            = ctx->alloc::<VisibilityGroupDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::VisibilityGroupDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::VisibilityGroupDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::VisibilityGroupDecl;
    }
}

///
///  EvalBlockDecl
///  eval { decl* } at namespace/type scope (decl-only compile-time block).
///  The stmt-position eval block is StmtKind::EvalBlockStmt.
///
class EvalBlockDecl derives Decl {
    pub var body: FrozenList::<*Decl>;

    static fn create(ctx: *ASTContext, range: SourceRange) -> *EvalBlockDecl {
        var node   = ctx->alloc::<EvalBlockDecl>();
        node->kind  = DeclKind::EvalBlockDecl;
        node->range = range;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EvalBlockDecl {
        var node            = ctx->alloc::<EvalBlockDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::EvalBlockDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::EvalBlockDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::EvalBlockDecl;
    }
}

///
///  TestDecl
///  test "should add correctly" { assert 1 + 1 == 2, "" }
///
class TestDecl derives Decl, DeclContext {
    pub var label: *Expr = &null;          ///< StringLiteralExpr label.
    pub var body:  *CompoundStmt = &null;

    static fn create(ctx: *ASTContext, range: SourceRange, parent: *DeclContext) -> *TestDecl {
        var node   = ctx->alloc::<TestDecl>();
        node->kind  = DeclKind::TestDecl;
        node->range = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Function, ctx, parent, static_cast::<*Decl>(node));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TestDecl {
        var node            = ctx->alloc::<TestDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::TestDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Function, ctx, &null, static_cast::<*Decl>(node));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::TestDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::TestDecl;
    }
}

/// structured, klib-visible macro parameter. default token TEXT lives in the
/// runtime MacroEntry's owned storage; the node carries offsets so printing
/// and klib can reconstruct without retaining source buffers.
struct MacroParamSpec {
    var name:        Token;
    var variadic:    u8   = 0;    ///< 0 none / 1 named / 2 unnamed
    var has_default: bool = false;
    var default_off: u32  = 0;    ///< offset into MacroEntry storage
    var default_len: u32  = 0;
}

///
///  MacroDecl
///  macro foo!(x) { ... } token-level macro.
///
///  Params are bare identifier tokens (typeless). `body_span` covers the raw
///  token run between braces; the macro engine re-lexes/substitutes it.
///
class MacroDecl derives Decl {
    pub var name:      Token;
    pub var params_spec: FrozenList::<MacroParamSpec>; ///< structured param info for klib/runtime.
    pub var body_span: SourceRange;                    ///< raw body token span.
    pub var is_variadic: bool = false;                 ///< `macro f!(...args)`.
    pub var accepts_params: bool = false;              ///< `macro f!(x, y) { ... }` vs `macro f! { ... }`.

    static fn create(ctx: *ASTContext, range: SourceRange, name: Token) -> *MacroDecl {
        var node   = ctx->alloc_pp::<MacroDecl>();
        node->kind  = DeclKind::MacroDecl;
        node->range = range;
        node->init_annotations(&(ctx->pp_alloc));;
        node->name  = name;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *MacroDecl {
        var node            = ctx->alloc_pp::<MacroDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::MacroDecl;
        node->range         = range;
        node->init_annotations(&(ctx->pp_alloc));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::MacroDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::MacroDecl;
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
class ProcedureMacroDecl derives Decl, DeclContext {
    pub var name:   Token;                       ///< the `@name` identifier.
    pub var params: FrozenList::<*ParamDecl>;
    pub var body:   *CompoundStmt = &null;

    static fn create(ctx: *ASTContext, range: SourceRange, name: Token, parent: *DeclContext) -> *ProcedureMacroDecl {
        var node   = ctx->alloc::<ProcedureMacroDecl>();
        node->kind  = DeclKind::ProcedureMacroDecl;
        node->range = range;
        node->name  = name;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Function, ctx, parent, static_cast::<*Decl>(node));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ProcedureMacroDecl {
        var node            = ctx->alloc::<ProcedureMacroDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ProcedureMacroDecl;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->init_dc(DeclContextKind::Function, ctx, &null, static_cast::<*Decl>(node));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::ProcedureMacroDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::ProcedureMacroDecl;
    }
}
