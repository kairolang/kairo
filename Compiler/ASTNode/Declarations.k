/// --- The Kairo Project ------------- Compiler/ASTNode/Declarations.k ----- ///
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

import ASTNode::Base::*;
import ASTNode::PrimaryExpressions::*;
import AST::ASTContext::*;
import AST::DeclContext::*;
import AST::Support::*;
import AST::Mixin::Redeclarable::*;
import AST::Mixin::TemplateParams::*;
import Source::SourceRange::*;
import Lexer::Token::*;

/// Forward decls for cross-references between decl nodes.
class FieldDecl;     // enum-variant payloads, struct/class members
class ParamDecl;     // function parameters
class GenericParamDecl;

/// CRTP mixin: a decl `T` derives TemplateParams::<T> to carry generic
/// parameters. Non-generic decls leave `params` empty (count 0) and
/// `requires_clause` null; is_generic() is the cheap gate.
class <T> TemplateParams {
    pub var generic_params: FrozenList::<*GenericParamDecl>;
    pub var requires_clause: *Expr = &null; ///< `requires <expr>`; null if none.

    fn is_generic(self) -> bool {
        return !self.generic_params.is_empty();
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
    FfiC,        ///< ffi "c"   no mangling.
    FfiCpp,      ///< ffi "c++" Itanium/MSVC mangling.
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
    None     = 0,
    IsConst    = 1 << 0,
    IsVolatile = 1 << 1,
    IsUnsafe   = 1 << 2,
    IsEval     = 1 << 3,
    IsAsync    = 1 << 4,
    IsFinal    = 1 << 5,
    IsPanic    = 1 << 6,
    IsInline   = 1 << 7,
}

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
///  Owned by a TemplateParams-carrying decl. `kind_constraint` is the
///  `: class/struct/enum/union` kind bound; `bounds` holds impl/derives
///  constraint types. `is_const_param` marks a value parameter (`const N: T`),
///  whose type is `value_type`. `is_pack` marks `...T`.
///
enum GenericParamKindBound derives u8 {
    Any = 0,   ///< no `: kind` bound.
    Class,
    Struct,
    Enum,
    Union,
}

class GenericParamDecl derives Decl {
    pub var name:           Token;                  ///< the parameter identifier (T, N, ...).
    pub var kind_bound:     GenericParamKindBound = GenericParamKindBound::Any;
    pub var bounds:         FrozenList::<*Type>;    ///< impl/derives constraint types.
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
        node->annotations.set_allocator(&(ctx->nodes));
        node->name  = name;
        node->index = index;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *GenericParamDecl {
        var node            = ctx->alloc::<GenericParamDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::GenericParamDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
    pub var index:       u32 = 0;          ///< position in the parameter list.
    pub var unname:      bool = false;     ///< true for the `unnamed` parameter.
    
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
        node->annotations.set_allocator(&(ctx->nodes));
        node->name   = name;
        node->type_  = type_;
        node->index  = index;
        node->unname = unname;
        return node;
    }

    /// `self` parameter: no type (resolved to the enclosing type by sema).
    static fn create_self(ctx: *ASTContext, range: SourceRange, name: Token) -> *ParamDecl {
        var node     = ctx->alloc::<ParamDecl>();
        node->kind    = DeclKind::ParamDecl;
        node->range   = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->name    = name;
        node->type_   = &null;
        node->is_self = true;
        node->index   = 0;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ParamDecl {
        var node            = ctx->alloc::<ParamDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ParamDecl;
        node->range         = range;
        node->type_         = &null;
        node->annotations.set_allocator(&(ctx->nodes));
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
          TemplateParams::<FunctionDecl> {
    pub var name:        Token;                 ///< function name (or ctor = type name).
    pub var params:      FrozenList::<*ParamDecl>;
    pub var return_type: *Type = &null;         ///< null => void (or inferred for expr body).
    pub var abi:         AbiKind   = AbiKind::None;
    pub var modifiers:   FnModifier = FnModifier::None;
    pub var body_kind:   FnBodyKind = FnBodyKind::None;
    pub var body_block:  *CompoundStmt = &null; ///< when body_kind == Block.
    pub var body_expr:   *Expr         = &null; ///< when body_kind == Expr.
    pub var is_operator: bool = false;          ///< `fn op <x>`.
    pub var op_token:    Token;                 ///< the operator token when is_operator.
    pub var is_variadic: bool = false;          ///< trailing `...name: T` pack param.
    pub var is_noreturn: bool = false;          ///< return type is `!`.
    pub var transfer:    TransferKind = TransferKind::NotTransfer; ///< @copy/@move on a transfer ctor.
    pub var qualifier:   *Expr = &null;         ///< out-of-line `Class::` path (ChainExpr); null otherwise.

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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Function, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *FunctionDecl {
        var node            = ctx->alloc::<FunctionDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::FunctionDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Function, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
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
        var by_ref: bool;             ///< true if `|&captured|`, false if `|captured|`.
    }
    pub var body_kind:   FnBodyKind = FnBodyKind::None;
    pub var body_block: *CompoundStmt = &null;
    pub var body_expr:  *Expr         = &null;
    pub var params:      FrozenList::<*ParamDecl>;
    pub var modifiers:   FnModifier = FnModifier::None;
    pub var return_type: *Type;  ///< null if inferred.
    pub var is_variadic: bool = false;          ///< trailing `...name: T` pack param.
    pub var is_noreturn: bool = false;
    pub var captures:    FrozenList::<Capture>; ///< captured variables, in source order.
    // params and generics stored as FrozenLists once DeclParse defines ParamDecl.

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
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ClosureExpr {
        var node            = ctx->alloc::<ClosureExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::ClosureExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
class VariableDecl derives Decl {
    pub var name:    Token;
    pub var storage: StorageClass = StorageClass::Var;
    pub var type_:   *Type = &null;   ///< null => inferred from init.
    pub var init:    *Expr = &null;   ///< initializer; null for `var x: T` default-init.

    static fn create(
        ctx:     *ASTContext,
        range:   SourceRange,
        name:    Token,
        storage: StorageClass
    ) -> *VariableDecl {
        var node     = ctx->alloc::<VariableDecl>();
        node->kind    = DeclKind::VariableDecl;
        node->range   = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->name    = name;
        node->storage = storage;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *VariableDecl {
        var node            = ctx->alloc::<VariableDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::VariableDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
    pub var init:       *Expr = &null;   ///< at-decl default; null if none.
    pub var is_mutable: bool = false;    ///< `mutable var` escapes const-self.
    pub var index:      u32 = 0;         ///< declaration order in the owning type.

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
        node->annotations.set_allocator(&(ctx->nodes));
        node->name    = name;
        node->storage = storage;
        node->type_   = type_;
        node->index   = index;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *FieldDecl {
        var node            = ctx->alloc::<FieldDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::FieldDecl;
        node->range         = range;
        node->type_         = &null;
        node->annotations.set_allocator(&(ctx->nodes));
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
          TemplateParams::<StructDecl> {
    pub var name:       Token;
    pub var fields:     FrozenList::<*FieldDecl>;
    pub var implements: FrozenList::<InheritEdge>;   ///< `impl` interface list.

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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Struct, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *StructDecl {
        var node            = ctx->alloc::<StructDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::StructDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Struct, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
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
          TemplateParams::<ClassDecl> {
    pub var name:         Token;
    pub var fields:       FrozenList::<*FieldDecl>;
    pub var methods:      FrozenList::<*FunctionDecl>;
    pub var derives_list: FrozenList::<InheritEdge>;  ///< base classes.
    pub var implements:   FrozenList::<InheritEdge>;  ///< interfaces.
    pub var is_final:     bool = false;               ///< `final class`.
    pub var is_abstract:  bool = false;               ///< has a `= virtual` method.

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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Class, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ClassDecl {
        var node            = ctx->alloc::<ClassDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ClassDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Class, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
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
class InterfaceDecl
  derives Decl,
          DeclContext,
          Redeclarable::<InterfaceDecl>,
          TemplateParams::<InterfaceDecl> {
    pub var name:         Token;
    pub var methods:      FrozenList::<*FunctionDecl>;  ///< requirement signatures.
    pub var derives_list: FrozenList::<InheritEdge>;    ///< parent interfaces.

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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Interface, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *InterfaceDecl {
        var node            = ctx->alloc::<InterfaceDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::InterfaceDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Extension, ctx, parent, static_cast::<*Decl>(node));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ExtensionDecl {
        var node            = ctx->alloc::<ExtensionDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ExtensionDecl;
        node->range         = range;
        node->target        = &null;
        node->annotations.set_allocator(&(ctx->nodes));
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

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        name:  Token,
        index: u32
    ) -> *EnumVariantDecl {
        var node    = ctx->alloc::<EnumVariantDecl>();
        node->kind   = DeclKind::EnumVariantDecl;
        node->range  = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->name   = name;
        node->index  = index;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EnumVariantDecl {
        var node            = ctx->alloc::<EnumVariantDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::EnumVariantDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
          TemplateParams::<EnumDecl> {
    pub var name:       Token;
    pub var underlying: *Type = &null;                  ///< `derives u8` etc; null if default/ADT.
    pub var variants:   FrozenList::<*EnumVariantDecl>;
    pub var is_adt:     bool = false;                   ///< any variant carries a payload.

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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Enum, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EnumDecl {
        var node            = ctx->alloc::<EnumDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::EnumDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Enum, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
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
          TemplateParams::<UnionDecl> {
    pub var name:   Token;
    pub var fields: FrozenList::<*FieldDecl>;

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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Union, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *UnionDecl {
        var node            = ctx->alloc::<UnionDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::UnionDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Union, ctx, &null, static_cast::<*Decl>(node));
        node->init_redecl();
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
class TypeAliasDecl derives Decl, TemplateParams::<TypeAliasDecl> {
    pub var name:    Token;
    pub var aliased: *Type;   ///< the right-hand-side type.

    static fn create(
        ctx:     *ASTContext,
        range:   SourceRange,
        name:    Token,
        aliased: *Type
    ) -> *TypeAliasDecl {
        var node     = ctx->alloc::<TypeAliasDecl>();
        node->kind    = DeclKind::TypeAliasDecl;
        node->range   = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->name    = name;
        node->aliased = aliased;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TypeAliasDecl {
        var node            = ctx->alloc::<TypeAliasDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::TypeAliasDecl;
        node->range         = range;
        node->aliased       = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::TypeAliasDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::TypeAliasDecl;
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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Module, ctx, parent, static_cast::<*Decl>(node));
        node->init_redecl();
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ModuleDecl {
        var node            = ctx->alloc::<ModuleDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ModuleDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
    SourceOnly,   ///< import module foo (disallow library resolution)
    FfiC,         ///< ffi "c"   import "h.h"   (produced by the ffi path)
    FfiCpp,       ///< ffi "c++" import "h.hh"  (produced by the ffi path)
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
    var has_alias:   bool;
    var is_wildcard: bool;                ///< `*` inside the brace list.
    var range:       SourceRange;
}

class ImportDecl derives Decl {
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

    static fn create(ctx: *ASTContext, range: SourceRange, import_kind: ImportKind) -> *ImportDecl {
        var node         = ctx->alloc::<ImportDecl>();
        node->kind        = DeclKind::ImportDecl;
        node->range       = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->import_kind = import_kind;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ImportDecl {
        var node            = ctx->alloc::<ImportDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ImportDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Decl) -> bool {
        return ptr->kind == DeclKind::ImportDecl;
    }
    /* OVERRIDE */ static fn decl_kind() -> DeclKind {
        return DeclKind::ImportDecl;
    }

    fn is_ffi(self) -> bool {
        return self.import_kind == ImportKind::FfiC || self.import_kind == ImportKind::FfiCpp;
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
        node->annotations.set_allocator(&(ctx->nodes));
        node->group_visibility = vis;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *VisibilityGroupDecl {
        var node            = ctx->alloc::<VisibilityGroupDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::VisibilityGroupDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EvalBlockDecl {
        var node            = ctx->alloc::<EvalBlockDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::EvalBlockDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Function, ctx, parent, static_cast::<*Decl>(node));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TestDecl {
        var node            = ctx->alloc::<TestDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::TestDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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

///
///  MacroDecl
///  macro foo!(x) { ... } token-level macro.
///
///  Params are bare identifier tokens (typeless). `body_span` covers the raw
///  token run between braces; the macro engine re-lexes/substitutes it.
///
class MacroDecl derives Decl {
    pub var name:      Token;
    pub var params:    FrozenList::<Token>;   ///< typeless macro params.
    pub var body_span: SourceRange;           ///< raw body token span.
    pub var is_variadic: bool = false;        ///< `macro f!(...args)`.

    static fn create(ctx: *ASTContext, range: SourceRange, name: Token) -> *MacroDecl {
        var node   = ctx->alloc::<MacroDecl>();
        node->kind  = DeclKind::MacroDecl;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->name  = name;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *MacroDecl {
        var node            = ctx->alloc::<MacroDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::MacroDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_dc(DeclContextKind::Function, ctx, parent, static_cast::<*Decl>(node));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ProcedureMacroDecl {
        var node            = ctx->alloc::<ProcedureMacroDecl>();
        node->kind          = DeclKind::RecoveryDecl;
        node->recovery_kind = DeclKind::ProcedureMacroDecl;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
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
