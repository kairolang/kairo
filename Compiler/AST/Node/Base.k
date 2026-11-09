/// --- The Kairo Project ------------------------------ AST/Node/Base.k --- ///
///
///   The AST base classes: Expr, Stmt, Decl, Type and Pattern.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::DeclContext::DeclContext
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::PatternKind::PatternKind
import AST::Kind::StmtKind::StmtKind
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::Annotation::{
    Annotation,
    VisibilityAnnotation,
}
import AST::Mixin::TypeQual::TypeQual
import Location::SourceRange::SourceRange
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}

pub class Expr derives Annotation<Expr> {
    pub var kind:  ExprKind    = ExprKind::RecoveryExpr
    pub var range: SourceRange = SourceRange::invalid()
    // for error nodes, the kind of expr we were trying to parse (for better error messages)
    pub var recovery_kind: ExprKind = ExprKind::RecoveryExpr

    pub enum ValueCategory derives u8 {
        Unknown, // not yet resolved by sema
        LValue,  // has address, assignable
        RValue,  // temporary, not assignable
        XValue,  // expiring value (move semantics)needed for C++ interop
    }

    /// Dependence bits, mirroring Type::TypeFlags. Expressions in generic
    /// bodies are exactly as dependent as types are (`sizeof(T)`, `x + y`
    /// with x: T) and sema defers them the same way (Compiler/Spec/Pipeline.md hard
    /// invariant #5: dependent = deferred, not failed).
    /// The bits; a combination is a FlagSet (Support/FlagSet.k), so this
    /// enum stays closed and names only single bits.
    pub enum ExprFlags derives u8 {
        /// Value/type depends on a generic parameter; checking deferred to
        /// instantiation (M2).
        IsDependent = 1 << 0,
        /// Affects instantiation without necessarily changing meaning
        /// (e.g. sizeof(T)). Superset of IsDependent.
        IsInstantiationDependent = 1 << 1,
        /// Contains an unexpanded pack (...Ts).
        ContainsUnexpandedPack = 1 << 2,
    }

    pub var value_category: Self::ValueCategory          = Self::ValueCategory::Unknown
    pub var type_:          unsafe *Type                 = &null
    pub var expr_flags:     FlagSet<Self::ExprFlags, u8>
    pub var poisoned:       bool                         = false

    pub fn poison(self) {
        self.poisoned = true
    }

    pub fn is_poisoned(self) -> bool {
        return self.poisoned
    }

    fn get_type(self) -> unsafe *Type {
        return self.type_
    }

    fn set_type(self, t: unsafe *Type) {
        self.type_ = t
    }

    pub fn adopt_sema(self, other: unsafe *Expr) {
        if other == &null {
            return
        }

        self.type_          = other->type_
        self.expr_flags     = other->expr_flags
        self.poisoned       = other->poisoned
        self.value_category = other->value_category
    }

    pub fn is_dependent(self) -> bool {
        return self.expr_flags.has(Self::ExprFlags::IsDependent)
    }

    pub fn is_instantiation_dependent(self) -> bool {
        return self.expr_flags.has(Self::ExprFlags::IsInstantiationDependent)
    }

    fn contains_unexpanded_pack(self) -> bool {
        return self.expr_flags.has(Self::ExprFlags::ContainsUnexpandedPack)
    }

    fn is_valid(self) -> bool {
        return self.kind != ExprKind::RecoveryExpr
    }

    fn is_error(self) -> bool {
        return self.kind == ExprKind::RecoveryExpr
    }

    fn get_expected(self) -> ExprKind {
        if self.is_error() {
            return self.recovery_kind
        }

        return self.kind
    }

    static fn classof(ptr: *const Expr) -> bool {
        return true // all Expr* are valid for classof(Expr)
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::RecoveryExpr // default, overridden by concrete nodes
    }

    pub fn is_lvalue(self) -> bool {
        return self.value_category == Self::ValueCategory::LValue
    }

    fn is_rvalue(self) -> bool {
        return self.value_category == Self::ValueCategory::RValue
    }

    fn is_xvalue(self) -> bool {
        return self.value_category == Self::ValueCategory::XValue
    }
}

pub class Stmt derives Annotation<Stmt> {
    pub var kind:  StmtKind    = StmtKind::RecoveryStmt
    pub var range: SourceRange = SourceRange::invalid()
    // for error nodes, the kind of stmt we were trying to parse (for better error messages)
    pub var recovery_kind: StmtKind = StmtKind::RecoveryStmt

    fn is_valid(self) -> bool {
        return self.kind != StmtKind::RecoveryStmt
    }

    pub fn is_error(self) -> bool {
        return self.kind == StmtKind::RecoveryStmt
    }

    fn get_expected(self) -> StmtKind {
        if self.is_error() {
            return self.recovery_kind
        }

        return self.kind
    }

    static fn classof(ptr: *const Stmt) -> bool {
        return true // all Stmt* are valid for classof(Stmt)
    }

    static fn stmt_kind() -> StmtKind {
        return StmtKind::RecoveryStmt // default, overridden by concrete nodes
    }
}

pub class Decl derives VisibilityAnnotation<Decl>, Annotation<Decl> {
    pub var kind:  DeclKind    = DeclKind::RecoveryDecl
    pub var range: SourceRange = SourceRange::invalid()
    // for error nodes, the kind of stmt we were trying to parse (for better error messages)
    pub var recovery_kind: DeclKind = DeclKind::RecoveryDecl

    /// Sema poison bit; see Expr::poisoned for the contract. A decl that
    /// fails sema (bad type ref, redefinition loser) is poisoned so uses
    /// degrade gracefully instead of cascading.
    pub var poisoned: bool = false

    /// Compiler-generated decl (synthesized member, monomorphized
    /// instantiation, implicit ctor). Walkers that mirror user source
    /// (printer round-trip, LSP listings) skip implicit decls.
    pub var is_implicit: bool = false

    /// Dual-context links, Clang's lexical-vs-semantic DeclContext model.
    /// lexical_dc  = the scope this decl was WRITTEN in (an ExtensionDecl
    ///               body, an anonymous module, the TU).
    /// semantic_dc = the scope this decl BELONGS to for lookup (the scope
    ///               whose SymbolTable holds it).
    /// They differ for extension members, anonymous-module members, and
    /// (post name-res) out-of-line `fn Class::method` definitions.
    /// "declared in an extend" == (lexical_dc != semantic_dc).
    /// Set by ASTParse::_build_symbols; rewritten by sema when it attaches
    /// out-of-line defs / folds extensions.
    pub var lexical_dc:  unsafe *DeclContext = &null
    pub var semantic_dc: unsafe *DeclContext = &null

    pub fn poison(self) {
        self.poisoned = true
    }

    pub fn is_poisoned(self) -> bool {
        return self.poisoned
    }

    /// True iff this decl was introduced through an `extend` block or other
    /// context where its written home differs from its lookup home. Only
    /// meaningful after _build_symbols has run.
    fn is_lexically_displaced(self) -> bool {
        return self.lexical_dc != &null && self.lexical_dc != self.semantic_dc
    }

    /// Copy sema-owned slots from \p other. See Expr::adopt_sema. For decl
    /// splits/splices in ASTWriter where the replacement stands for the
    /// same declared entity.
    pub fn adopt_sema(self, other: unsafe *Decl) {
        if other == &null {
            return
        }

        self.poisoned    = other->poisoned
        self.is_implicit = other->is_implicit
        self.lexical_dc  = other->lexical_dc
        self.semantic_dc = other->semantic_dc
    }

    fn is_valid(self) -> bool {
        return self.kind != DeclKind::RecoveryDecl
    }

    fn is_error(self) -> bool {
        return self.kind == DeclKind::RecoveryDecl
    }

    fn get_expected(self) -> DeclKind {
        if self.is_error() {
            return self.recovery_kind
        }

        return self.kind
    }

    static fn classof(ptr: *const Decl) -> bool {
        return true // all Decl* are valid for classof(Decl)
    }

    static fn decl_kind() -> DeclKind {
        return DeclKind::RecoveryDecl // default, overridden by concrete nodes
    }
}

/// Expr::ExprFlags' variants are its FlagSet's bits (Support/FlagSet.k).
extend Expr::ExprFlags impl FlagBit<u8> {
    inline fn bit(const self) -> u8 {
        return self as u8
    }
}

pub class Type derives TypeQual<Type>, Annotation<Type> { // all types have qualifiers
    /// The bits; a combination is a FlagSet (Support/FlagSet.k), so this
    /// enum stays closed and names only single bits.
    pub enum TypeFlags derives u8 {
        /// Type contains a template type parameter meaning changes per instantiation.
        /// Set on GenericParamType itself and propagates up through any type that
        /// contains one. Sema defers checking of dependent types until instantiation.
        IsDependent = 1 << 0,
        /// Dependent on a template parameter in a way that affects instantiation
        /// but not necessarily the type's meaning. Superset of IsDependent.
        /// Example: sizeof(T) is instantiation-dependent even if T is known size.
        IsInstantiationDependent = 1 << 1,
        /// Contains a pack parameter (...Ts) that has not yet been expanded.
        /// Sema uses this to validate where pack expansion is legal.
        /// Must be cleared after a PackExpansionType consumes the pack.
        ContainsUnexpandedPack = 1 << 2,
        /// Type involves a runtime-variable size (VLA or similar).
        /// You said no VLAs so this is future-proofing / FFI import only.
        IsVariablyModified = 1 << 3,
        /// A record nested (at any depth) in a generic record, named as its
        /// owner's CURRENT instantiation (`P` inside `class <K> L`): the
        /// owner's parameters are implicit in it, so a substitution that
        /// binds them must reach it (`P` read through `L<i32>` is
        /// `L<i32>::P`, RecordType::outer) although nothing in it is a
        /// parameter. Not dependence: the type is checked as written in
        /// the owner's body, as it always was. Propagates up like the rest.
        InGenericOwner = 1 << 4,
    }

    // for error nodes, the kind of stmt we were trying to parse (for better error messages)
    pub var size_bits:  usize = 0
    pub var align_bits: usize = 0
    /// INVARIANT (enforced by TypeResolution, relied on by everything after):
    /// canonical always points to the fully-desugared type, cv-qualifiers
    /// INCLUDED: `const Foo` canonicalizes to qualified(CONST, Foo), a node
    /// distinct from Foo's. Type identity is (a->canonical == b->canonical)
    /// and nothing else; "identical ignoring qualifiers" is
    /// canon_unqual(a->canonical) == canon_unqual(b->canonical). The
    /// syntax node's `flags` say what was WRITTEN; the canonical says what
    /// it MEANS. Uniquing and instantiation caches key on the canonical, so
    /// `W<const i32>` and `W<i32>` are two instances, as in C++.
    pub var canonical:     unsafe *Type                 = &null // for types that are qualified by another type, e.g. associated types like T::Item or pointer types like *T
    pub var kind:          TypeKind                     = TypeKind::RecoveryType
    pub var range:         SourceRange                  = SourceRange::invalid()
    pub var recovery_kind: TypeKind                     = TypeKind::RecoveryType
    pub var type_flags:    FlagSet<Self::TypeFlags, u8>

    /// Sema poison bit; see Expr::poisoned for the contract.
    pub var poisoned: bool = false

    pub fn poison(self) {
        self.poisoned = true
    }

    pub fn is_poisoned(self) -> bool {
        return self.poisoned
    }

    /// Copy sema-owned slots from \p other. See Expr::adopt_sema. For Type
    /// this carries the canonical link + layout a post-sema rewrite that
    /// substitutes an equivalent type keeps its resolved identity. If the
    /// rewrite CHANGES the type's meaning, do not call this; let
    /// TypeResolution recompute.
    fn adopt_sema(self, other: *Type?) {
        if other == &null {
            return
        }

        self.canonical  = other->canonical
        self.size_bits  = other->size_bits
        self.align_bits = other->align_bits
        self.type_flags = other->type_flags
        self.poisoned   = other->poisoned
    }

    fn is_valid(self) -> bool {
        return self.kind != TypeKind::RecoveryType
    }

    fn is_error(self) -> bool {
        return self.kind == TypeKind::RecoveryType
    }

    fn get_expected(self) -> TypeKind {
        if self.is_error() {
            return self.recovery_kind
        }

        return self.kind
    }

    fn get_canonical_type(self) -> unsafe *Type {
        return self.canonical
    }

    pub fn is_dependent(self) -> bool {
        return self.type_flags.has(Self::TypeFlags::IsDependent)
    }

    pub fn is_instantiation_dependent(self) -> bool {
        return self.type_flags.has(Self::TypeFlags::IsInstantiationDependent)
    }

    pub fn contains_unexpanded_pack(self) -> bool {
        return self.type_flags.has(Self::TypeFlags::ContainsUnexpandedPack)
    }

    fn is_variably_modified(self) -> bool {
        return self.type_flags.has(Self::TypeFlags::IsVariablyModified)
    }

    pub fn in_generic_owner(self) -> bool {
        return self.type_flags.has(Self::TypeFlags::InGenericOwner)
    }

    static fn classof(ptr: *const Type) -> bool {
        return true // all Type* are valid for classof(Type)
    }

    static fn type_kind() -> TypeKind {
        return TypeKind::RecoveryType // default, overridden by concrete nodes
    }
}

pub class Pattern derives Annotation<Pattern> {
    pub var kind:          PatternKind = PatternKind::RecoveryPattern
    pub var range:         SourceRange = SourceRange::invalid()
    pub var recovery_kind: PatternKind = PatternKind::RecoveryPattern

    /// The type this pattern matches. Written by pattern checking (the vars
    /// a pattern binds take their types from here); null until then.
    pub var type_: unsafe *Type = &null

    /// What a constructor-shaped pattern names: the EnumVariantDecl, the
    /// StructDecl / ClassDecl of a struct pattern, or the const / eval
    /// VariableDecl of `case MAX`. Null on every other pattern. One writer:
    /// PatternTyping (ExprTyper).
    pub var resolved_decl: unsafe *Decl = &null

    /// On a subpattern of a variant or struct pattern: the FieldDecl it
    /// destructures. Null otherwise. One writer: PatternTyping (ExprTyper).
    pub var field_decl: unsafe *Decl = &null

    /// On a pattern naming a pack-expanded variant (`.Err(var e: f64)`): the
    /// pack element it picked, by payload type; -1 otherwise. Its expanded
    /// index (adt_variant_at) is the variant's position plus this. One
    /// writer: PatternTyping.
    pub var pack_index: i32 = -1

    /// Sema poison bit; see Expr::poisoned for the contract.
    pub var poisoned: bool = false

    pub fn poison(self) {
        self.poisoned = true
    }

    pub fn is_poisoned(self) -> bool {
        return self.poisoned
    }

    fn get_type(self) -> unsafe *Type {
        return self.type_
    }

    fn set_type(self, t: unsafe *Type) {
        self.type_ = t
    }

    /// Copy sema-owned slots from \p other. See Expr::adopt_sema.
    fn adopt_sema(self, other: unsafe *Pattern) {
        if other == &null {
            return
        }

        self.type_         = other->type_
        self.resolved_decl = other->resolved_decl
        self.field_decl    = other->field_decl
        self.pack_index    = other->pack_index
        self.poisoned      = other->poisoned
    }

    static fn classof(ptr: *const Pattern) -> bool {
        return true // all Pattern* are valid for classof(Pattern)
    }

    static fn pattern_kind() -> PatternKind {
        return PatternKind::RecoveryPattern // default, overridden by concrete nodes
    }

    fn is_valid(self) -> bool {
        return self.kind != PatternKind::RecoveryPattern
    }

    pub fn is_error(self) -> bool {
        return self.kind == PatternKind::RecoveryPattern
    }

    fn get_expected(self) -> PatternKind {
        if self.is_error() {
            return self.recovery_kind
        }

        return self.kind
    }
}

/// Type::TypeFlags' variants are its FlagSet's bits (Support/FlagSet.k).
extend Type::TypeFlags impl FlagBit<u8> {
    inline fn bit(const self) -> u8 {
        return self as u8
    }
}
