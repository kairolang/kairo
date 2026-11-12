/// --- The Kairo Project ------------------------ AST/Node/Statements.k --- ///
///
///   Statement-position AST nodes.
///
///   Every concrete Stmt subclass sets `kind` to its StmtKind and provides
///   `create` / `create_error` factories plus `classof` / `stmt_kind` for
///   the RTTI-free casting system (see Casting.k).
///
///   NOTE: ASTContext::alloc does NOT run constructors. Every field a node
///         relies on must be assigned explicitly in `create`. FrozenList
///         members are left untouched here and MUST be populated by the
///         parser via `from_buf(..., ctx)` even when empty (size 0).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------------- ///

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Kind::StmtKind::StmtKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::Declarations::VariableDecl
import AST::Node::PrimaryExpressions::NamedIdentExpr
import Location::SourceRange::SourceRange
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}
import Token::Token::Token

///
///  Binding shorthand qualifiers
///
///  The declaration shorthands documented under Variables, one bit each; a
///  binding's set of them is a FlagSet (Support/FlagSet.k), empty for none:
///    `var *x`         -> Pointer
///    `var unsafe *x`  -> Pointer, Unsafe
///    `var x?`         -> Nullable
///    `var unsafe *x?` -> Pointer, Unsafe, Nullable
///
///  These reshape the *inferred* type of the binding; sema applies them after
///  inferring the underlying type from the destructured/iterated source.
///
pub enum BindingShorthand derives u8 {
    Pointer  = 1 << 0, ///< `*x`        leading star.
    Unsafe   = 1 << 1, ///< `unsafe *x` raw pointer; only valid with Pointer.
    Nullable = 1 << 2, ///< `x?`        nullable suffix.
}

/// BindingShorthand's variants are its FlagSet's bits (Support/FlagSet.k).
extend BindingShorthand impl FlagBit<u8> {
    inline fn bit(const self) -> u8 {
        return self as u8
    }
}

///
///  Binding
///
///  A single introduced name in a binding position. Shared by:
///    - DestructuringDeclStmt   `var (a, const b) = t`
///    - RangedForStmt           `for var (k, const v) in m`
///    - ContextBindingStmt      `f() as var (handle, const status) { }`
///
///  Mutability rule (resolved by the parser, stored here): the leading
///  keyword (`var`/`const`) sets the default; a per-element `var`/`const`
///  overrides it. `is_const` is the RESOLVED value. `is_explicit` records
///  whether this element wrote its own keyword (for redundant-qualifier
///  diagnostics). `_` produces a discard with `is_discard = true` and a null
///  `name`.
///
pub struct Binding {
    pub var name:        unsafe *NamedIdentExpr ///< null when is_discard.
    pub var is_const:    bool ///< resolved mutability (default + override).
    pub var is_explicit: bool ///< this element wrote its own var/const.
    pub var is_discard:  bool ///< `_` placeholder; name is null.
    pub var shorthand:   FlagSet<BindingShorthand, u8> ///< *, unsafe *, ? shorthands.
    pub var type_:       unsafe *Type                  = &null ///< explicit `: T` ascription; null if none.
    pub var range:       SourceRange ///< span of this binding element.

    /// The DECLARATION this binder introduces (`for x in xs` declares `x`).
    /// Synthesized by the parser alongside `name`, null for a discard.
    ///
    /// A binder is a declaration, so uses of it must have something to bind
    /// to: NameResolution pushes this decl onto its lexical stack and writes
    /// it into each use's `resolved_decl`. Without it every `for` body that
    /// mentions its loop variable reported unresolved-ident. TypeResolution
    /// later hangs the inferred element type here.
    ///
    /// NOT in any symbol table and NOT reachable from dc_decls: locals are
    /// excluded from tables by design, and the RAV does not dispatch it
    /// (which would double-declare it).
    pub var decl: unsafe *VariableDecl = &null
}

///
///  CatchArm
///
///  One arm of a `try`/`catch` statement:
///    `catch e: std::Error::IO { }`  -> filter + binding
///    `catch e { }`                  -> binding, no filter
///    `catch { }`                    -> bare catch-all, neither
///
pub struct CatchArm {
    pub var filter:  unsafe *Type           ///< panic-type filter; null for bare catch-all.
    pub var binding: unsafe *NamedIdentExpr ///< bound error name; null if unbound.
    pub var body:    unsafe *CompoundStmt
    pub var range:   SourceRange
    /// Declaration introduced by `binding`; see Binding::decl. Null when the
    /// arm binds no name.
    pub var decl: unsafe *Decl = &null
    /// Its type is not in the `try` body's set: the arm never runs, and
    /// PanicLowering emits no tag compare for it (Compiler/Spec/Panic.md#try-and-arms). A C++
    /// exception arm (its type is not in the set and is a C++ type) is
    /// never dead. One writer: PanicEffectChecking.
    pub var is_dead: bool = false
    /// The arm catches a C++ exception (Compiler/Spec/Panic.md#c-exception-arms): its type is a C++
    /// type not in the set. PanicLowering keeps it as a C++ `catch`. One
    /// writer: PanicEffectChecking.
    pub var is_cxx: bool = false
}

///
///  Destructure kind discriminator for DestructuringDeclStmt.
///
pub enum DestructureKind derives u8 {
    Tuple,  ///< `var (a, b) = t`   positional.
    Struct, ///< `var {a, b} = s`   by field name.
}

///
///  Foreign-block language for InlineBlockStmt.
///
pub enum FFILang derives u8 {
    None,   ///< wrong language; parser error.
    Asm,    ///< inline "asm" { }
    C,      ///< inline "c"   { }
    Cpp,    ///< inline "c++" { }
    Cuda,   ///< inline "cuda" { }
    Hip,    ///< inline "hip" { }
    OpenCL, ///< inline "opencl" { }
    Hlsl,   ///< inline "hlsl" { }
    Metal,  ///< inline "metal" { }
    SpirV,  ///< inline "spirv" { }
    Wgsl,   ///< inline "wgsl" { }
    Glsl,   ///< inline "glsl" { }
    Kairo,  ///< inline "kairo" { }
}

/// The language a word after `ffi` / `inline` names, matched without case
/// (`"C"` is `"c"`); None for a word that names none. \p word is the
/// string literal's contents. The one table (the parser stamps from it);
/// C++ is also every C++ source and header extension, written as the
/// language.
pub fn ffi_lang_of(const word: string) -> FFILang {
    var s: string
    s.reserve(word.size())
    for var i: usize = 0; i < word.size(); ++i {
        var c = word[i]
        s.push_back(c | ((c >= ('A' as u8) && c <= ('Z' as u8)) as u8) << 5)
    }

    if s == "asm" {
        return FFILang::Asm
    }

    if s == "cuda" {
        return FFILang::Cuda
    }

    if s == "hip" {
        return FFILang::Hip
    }

    if s == "opencl" {
        return FFILang::OpenCL
    }

    if s == "hlsl" {
        return FFILang::Hlsl
    }

    if s == "metal" {
        return FFILang::Metal
    }

    if s == "spirv" {
        return FFILang::SpirV
    }

    if s == "wgsl" {
        return FFILang::Wgsl
    }

    if s == "glsl" {
        return FFILang::Glsl
    }

    if s == "kairo" {
        return FFILang::Kairo
    }

    if s == "c" {
        return FFILang::C
    }

    if s == "cpp" || s == "cxx" || s == "c++" || s == "cc" || s == "cp" || s == "h" || s == "hpp"
        || s == "hxx" || s == "h++" || s == "hh" || s == "inl" || s == "tcc" || s == "ipp"
        || s == "ixx" || s == "cppm" || s == "cxxm" || s == "ccm" {
        return FFILang::Cpp
    }

    return FFILang::None
}

/// ffi_lang_of for a string token's spelling, which keeps its quotes: the
/// readers that see the token rather than the parsed literal (the
/// preprocessor, FlagGates) classify the same word the parser does.
pub fn ffi_lang_of_literal(const text: string) -> FFILang {
    if text.size() < 2 || text[0] != ('"' as u8) || text[text.size() - 1] != ('"' as u8) {
        return ffi_lang_of(text)
    }

    var w: string
    w.reserve(text.size() - 2)
    for var i: usize = 1; i + 1 < text.size(); ++i {
        w.push_back(text[i])
    }

    return ffi_lang_of(w)
}

///
///  ExpressionStmt
///  Grammar:  expr
///
///  An expression in statement position; its value is discarded.
///
pub class ExpressionStmt derives Stmt {
    pub var expr: unsafe *Expr

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         expr:  unsafe *Expr) -> unsafe *ExpressionStmt {
        var unsafe *node = ctx->alloc<ExpressionStmt>()
        node->kind  = StmtKind::ExpressionStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->expr = expr
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ExpressionStmt {
        var unsafe *node = ctx->alloc<ExpressionStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::ExpressionStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::ExpressionStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::ExpressionStmt
    }
}

///
///  DeclStmt
///  Grammar:  decl    (var/const/fn/class/struct/enum/... at stmt scope)
///
///  Wraps a declaration appearing inside a function body.
///
pub class DeclStmt derives Stmt {
    pub var decl: unsafe *Decl

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         decl:  unsafe *Decl) -> unsafe *DeclStmt {
        var unsafe *node = ctx->alloc<DeclStmt>()
        node->kind  = StmtKind::DeclStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->decl = decl
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *DeclStmt {
        var unsafe *node = ctx->alloc<DeclStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::DeclStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::DeclStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::DeclStmt
    }
}

///
///  ReturnStmt
///  Grammar:  'return' | 'return' expr
///
pub class ReturnStmt derives Stmt {
    pub var value: unsafe *Expr ///< null for a bare `return`.

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         value: unsafe *Expr) -> unsafe *ReturnStmt {
        var unsafe *node = ctx->alloc<ReturnStmt>()
        node->kind  = StmtKind::ReturnStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->value = value
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ReturnStmt {
        var unsafe *node = ctx->alloc<ReturnStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::ReturnStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::ReturnStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::ReturnStmt
    }
}

///
///  BreakStmt
///  Grammar:  'break' | 'break' identifier
///
pub class BreakStmt derives Stmt {
    pub var has_label: bool  ///< true if a loop label follows.
    pub var label:     Token ///< meaningful only when has_label.

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         has_label: bool,
                         label:     Token) -> unsafe *BreakStmt {
        var unsafe *node = ctx->alloc<BreakStmt>()
        node->kind  = StmtKind::BreakStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->has_label = has_label
        node->label     = label
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *BreakStmt {
        var unsafe *node = ctx->alloc<BreakStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::BreakStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::BreakStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::BreakStmt
    }
}

///
///  ContinueStmt
///  Grammar:  'continue' | 'continue' identifier
///
pub class ContinueStmt derives Stmt {
    pub var has_label: bool
    pub var label:     Token

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         has_label: bool,
                         label:     Token) -> unsafe *ContinueStmt {
        var unsafe *node = ctx->alloc<ContinueStmt>()
        node->kind  = StmtKind::ContinueStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->has_label = has_label
        node->label     = label
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ContinueStmt {
        var unsafe *node = ctx->alloc<ContinueStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::ContinueStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::ContinueStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::ContinueStmt
    }
}

///
///  PanicStmt
///  Grammar:  'panic' expr
///
///  Only legal in functions carrying the `panic` specifier (sema-checked).
///
pub class PanicStmt derives Stmt {
    pub var payload: unsafe *Expr
    /// `panic e` of a catch arm's binding: a re-panic of the caught error,
    /// which keeps its ORIGINAL site (Compiler/Spec/Panic.md#inference) -- PanicLowering
    /// forwards word 0 as it is instead of writing a new site. The arm's
    /// binding decl; null for a fresh panic. One writer:
    /// PanicEffectChecking.
    pub var repanic: unsafe *Decl = &null

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         payload: unsafe *Expr) -> unsafe *PanicStmt {
        var unsafe *node = ctx->alloc<PanicStmt>()
        node->kind  = StmtKind::PanicStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->payload = payload
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *PanicStmt {
        var unsafe *node = ctx->alloc<PanicStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::PanicStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::PanicStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::PanicStmt
    }
}

///
///  YieldStmt
///  Grammar:  'yield' expr
///
///  Only legal in functions returning a `yield T` type (sema-checked).
///
pub class YieldStmt derives Stmt {
    pub var value: unsafe *Expr

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         value: unsafe *Expr) -> unsafe *YieldStmt {
        var unsafe *node = ctx->alloc<YieldStmt>()
        node->kind  = StmtKind::YieldStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->value = value
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *YieldStmt {
        var unsafe *node = ctx->alloc<YieldStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::YieldStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::YieldStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::YieldStmt
    }
}

///
///  RuntimeAssertStmt
///  Grammar:  'assert' expr (',' expr)?
///
///  Runtime assertion. Behavior controlled by -fassert-mode. `message` is the
///  optional second operand.
///
pub class RuntimeAssertStmt derives Stmt {
    pub var condition: unsafe *Expr
    pub var message:   unsafe *Expr ///< null if no message operand.

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         condition: unsafe *Expr,
                         message:   unsafe *Expr) -> unsafe *RuntimeAssertStmt {
        var unsafe *node = ctx->alloc<RuntimeAssertStmt>()
        node->kind  = StmtKind::RuntimeAssertStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->condition = condition
        node->message   = message
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *RuntimeAssertStmt {
        var unsafe *node = ctx->alloc<RuntimeAssertStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::RuntimeAssertStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::RuntimeAssertStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::RuntimeAssertStmt
    }
}

///
///  StaticAssertStmt
///  Grammar:  'assert' 'static' expr (',' expr)?
///
///  Compile-time assertion. `condition` must be const-evaluable; failure is a
///  compile error. `message` is the optional second operand.
///
pub class StaticAssertStmt derives Stmt {
    pub var condition: unsafe *Expr
    pub var message:   unsafe *Expr ///< null if no message operand.

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         condition: unsafe *Expr,
                         message:   unsafe *Expr) -> unsafe *StaticAssertStmt {
        var unsafe *node = ctx->alloc<StaticAssertStmt>()
        node->kind  = StmtKind::StaticAssertStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->condition = condition
        node->message   = message
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *StaticAssertStmt {
        var unsafe *node = ctx->alloc<StaticAssertStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::StaticAssertStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::StaticAssertStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::StaticAssertStmt
    }
}

///
///  LabelIntrinsicStmt
///  Grammar:  'label' '!' '(' identifier ')'
///
///  Declares a raw branch target. Distinct from a structured loop label
///  (LabeledStmt). Surfaced as macro syntax, parsed as a first-class node.
///  Also the lowerings' labels and gotos (MatchLowering, LabelLowering);
///  EmitIR spells both. User-written ones are SC116E (FeatureGateCheck) until
///  a crossing-initialization check exists.
///
pub class LabelIntrinsicStmt derives Stmt {
    pub var name: Token

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         name:  Token) -> unsafe *LabelIntrinsicStmt {
        var unsafe *node = ctx->alloc<LabelIntrinsicStmt>()
        node->kind  = StmtKind::LabelIntrinsicStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->name = name
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *LabelIntrinsicStmt {
        var unsafe *node = ctx->alloc<LabelIntrinsicStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::LabelIntrinsicStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::LabelIntrinsicStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::LabelIntrinsicStmt
    }
}

///
///  JumpIntrinsicStmt
///  Grammar:  'jump' '!' '(' identifier ')'
///
///  Unconditional jump to a `label!`-declared target in the same function.
///  Bypasses destructors and finally blocks.
///  Also the lowerings' labels and gotos (MatchLowering, LabelLowering);
///  EmitIR spells both. User-written ones are SC116E (FeatureGateCheck) until
///  a crossing-initialization check exists.
///
pub class JumpIntrinsicStmt derives Stmt {
    pub var target: Token
    /// The target is outside the `eval for` / pack `for` copy this jump
    /// sits in (PanicLowering, a delivery to a `try` around the loop): a
    /// copy is a C++ lambda, which no goto leaves, so EmitIR stops the
    /// copy's fold instead, and the jump PanicLowering placed after the
    /// expansion, on the flag this one's site set, goes on.
    pub var ef_leave: bool = false

    pub static fn create(ctx:    unsafe *ASTContext,
                         range:  SourceRange,
                         target: Token) -> unsafe *JumpIntrinsicStmt {
        var unsafe *node = ctx->alloc<JumpIntrinsicStmt>()
        node->kind  = StmtKind::JumpIntrinsicStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->target   = target
        node->ef_leave = false
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *JumpIntrinsicStmt {
        var unsafe *node = ctx->alloc<JumpIntrinsicStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::JumpIntrinsicStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->ef_leave = false
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::JumpIntrinsicStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::JumpIntrinsicStmt
    }
}

///
///  SwitchDispatchStmt
///  Lowering-only: never parsed. MatchLowering's multiway jump:
///    switch (value) { case lo: goto L; case lo ... hi: goto L; default: goto D; }
///  or, with `default_stmt`, `default: <stmt>` (UnmatchedPolicy's call).
///  The cases hold only gotos, so no user statement ever sits inside a C++
///  switch. `hi` null: a single value; otherwise GNU `case lo ... hi:`.
///
pub struct DispatchCase {
    pub var lo:     unsafe *Expr = &null
    pub var hi:     unsafe *Expr = &null
    pub var target: Token
}

pub class SwitchDispatchStmt derives Stmt {
    pub var value:          unsafe *Expr
    pub var cases:          FrozenList<DispatchCase> ///< filled by the lowering that mints it.
    pub var default_target: Token ///< meaningful when default_stmt is null.
    pub var default_stmt:   unsafe *Stmt             = &null ///< emitted in place of `goto default_target`.

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         value: unsafe *Expr) -> unsafe *SwitchDispatchStmt {
        var unsafe *node = ctx->alloc<SwitchDispatchStmt>()
        node->kind  = StmtKind::SwitchDispatchStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->value          = value
        node->default_target = Token()
        node->default_stmt   = &null
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SwitchDispatchStmt {
        var unsafe *node = ctx->alloc<SwitchDispatchStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::SwitchDispatchStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->value        = &null
        node->default_stmt = &null
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::SwitchDispatchStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::SwitchDispatchStmt
    }
}

/// \enum EvalTaken
/// \brief The side of an `eval if typeof T == U` X decided
///        (ConditionalStmt::eval_taken). Undecided includes every statement
///        that is no such `eval if`, and one decided only per instance.
pub enum EvalTaken derives u8 {
    Undecided = 0,
    Then,          ///< the else side was dropped.
    Else,          ///< the then branch was emptied.
}

///
///  ConditionalStmt
///  Grammar:  'if' expr block ('else' 'if' expr block)* ('else' block)?
///
///  `then_` is always a block. `else_` is nullable and is either the next
///  ConditionalStmt (an `else if`) or a CompoundStmt (the final `else`).
///  (Deviates from the doc-2 comment that says both branches are CompoundStmt;
///   *Stmt avoids wrapping else-if chains in throwaway blocks.)
///
pub class ConditionalStmt derives Stmt {
    pub var cond:  unsafe *Expr
    pub var then_: unsafe *CompoundStmt
    pub var else_: unsafe *Stmt         ///< null, a ConditionalStmt (else-if), or a CompoundStmt.
    /// `eval if`, and every `else if` of its chain: folded by EvalIfFolding
    /// where its condition folds, else C++ `if constexpr` (Compiler/Spec/Eval.md#folding-eval-if).
    pub var is_eval: bool
    /// The head of a declaration-scope `eval if` whose condition reads a
    /// type fact: E left it in place for EvalIfLateFolding (Compiler/Spec/Eval.md#deferred-conditions).
    /// One writer: EvalIfFolding.
    pub var eval_deferred: bool
    /// `@likely` / `@unlikely` written between the previous branch's `}` and
    /// the `else` of this statement's else_ (0 none, 1 likely, 2 unlikely):
    /// the hint for the else branch, as the statement's own attribute is for
    /// the then branch. EmitIR::_if reads it.
    pub var else_hint: u8
    /// An `eval if` over `typeof T == U` that X decided, and which side it
    /// took. The untaken branch is already emptied or dropped;
    /// ControlFlowAnalysis reads the taken one alone, as the emptied branch
    /// is never run. One writer: StmtTyping.
    pub var eval_taken: EvalTaken

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         cond:  unsafe *Expr,
                         then_: unsafe *CompoundStmt,
                         else_: unsafe *Stmt) -> unsafe *ConditionalStmt {
        var unsafe *node = ctx->alloc<ConditionalStmt>()
        node->kind  = StmtKind::ConditionalStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->cond          = cond
        node->then_         = then_
        node->else_         = else_
        node->is_eval       = false
        node->eval_deferred = false
        node->else_hint     = 0
        node->eval_taken    = EvalTaken::Undecided
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ConditionalStmt {
        var unsafe *node = ctx->alloc<ConditionalStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::ConditionalStmt
        node->is_eval       = false
        node->eval_deferred = false
        node->else_hint     = 0
        node->eval_taken    = EvalTaken::Undecided
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::ConditionalStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::ConditionalStmt
    }
}

///
///  WhileLoopStmt
///  Grammar:  'while' expr block
///
pub class WhileLoopStmt derives Stmt {
    pub var cond: unsafe *Expr
    pub var body: unsafe *CompoundStmt

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         cond:  unsafe *Expr,
                         body:  unsafe *CompoundStmt) -> unsafe *WhileLoopStmt {
        var unsafe *node = ctx->alloc<WhileLoopStmt>()
        node->kind  = StmtKind::WhileLoopStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->cond = cond
        node->body = body
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *WhileLoopStmt {
        var unsafe *node = ctx->alloc<WhileLoopStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::WhileLoopStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::WhileLoopStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::WhileLoopStmt
    }
}

///
///  LoopStmt
///  Grammar:  'loop' block
///
///  Unconditional infinite loop. Runs until `break` or `return`.
///
pub class LoopStmt derives Stmt {
    pub var body: unsafe *CompoundStmt

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         body:  unsafe *CompoundStmt) -> unsafe *LoopStmt {
        var unsafe *node = ctx->alloc<LoopStmt>()
        node->kind  = StmtKind::LoopStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->body = body
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *LoopStmt {
        var unsafe *node = ctx->alloc<LoopStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::LoopStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::LoopStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::LoopStmt
    }
}

///
///  How IterLowering walks an iterable. Written by X (StmtTyping) when it
///  types the loop; IterLowering renders the shape and decides nothing.
///
pub enum IterKind derives u8 {
    None = 0, ///< untyped, poisoned, or dependent: not lowered.
    RangeLit, ///< `a..b` / `a..=b` written as the iterable.
    RangeValue, ///< a Range-typed value (`var r = 0..3; for i in r`).
    Array, ///< `[T; N]`.
    Slice, ///< `[T;]`.
    Vector, ///< `[T]`.
    Set, ///< `{T}`.
    Map, ///< `{K: V}`.
    String, ///< `string`, by `char`.
    User, ///< a record's `fn op in (self) -> yield T`, or a Yield<T> value itself (iter_op null).
    Cxx, ///< an imported C++ class, by C++'s range protocol ([stmt.ranged]).
    Pack, ///< a type pack parameter (`fn <...T> f(...xs: T)`): unrolled, one copy per element; iter_elem is the pack.
}

///
///  RangedForStmt
///  Grammar:  'eval'? 'for' binding_spec 'in' expr block
///    binding_spec := ('var'|'const')? (binding | '(' binding (',' binding)* ')')
///
///  `bindings` holds the loop bindings (1 for `for var x in`, N for a tuple
///  destructure `for var (k, const v) in`). `is_eval` marks the compile-time
///  unroll form. `iterable` is a range, a container, a record with
///  `fn op in (self) -> yield T`, or an imported C++ class C++ can range over
///  (member or free `begin`/`end`; a Kairo class's begin/end never count,
///  `op in` is its one protocol); X records which in `iter_kind`.
///
///  For Cxx, X also mints the two hidden iterator locals and types the three
///  loop operations over them, so overload resolution -- const `begin()`,
///  ADL, C++20's `!=` from `==` -- happens in X like any other expression;
///  IterLowering only places them. The `cxx_*` fields are not children: no
///  walker visits them before IterLowering puts them in the tree.
///
pub class RangedForStmt derives Stmt {
    pub var bindings: FrozenList<Binding>
    pub var iterable: unsafe *Expr
    pub var body:     unsafe *CompoundStmt
    pub var is_eval:  bool
    /// An `eval for` over `lo..hi` / `lo..=hi`: the bounds, moved here by
    /// IterLowering (the RangeExpr would otherwise become a Range record),
    /// for EmitIR's expansion (Compiler/Spec/Eval.md#eval-for). Null otherwise.
    pub var ev_lo:     unsafe *Expr
    pub var ev_hi:     unsafe *Expr
    pub var ev_incl:   bool
    pub var iter_kind: IterKind              = IterKind::None
    pub var iter_op:   unsafe *Decl          = &null ///< User: the selected `op in (self)`; null when the iterable is a Yield<T> itself.
    pub var iter_elem: unsafe *Type          = &null ///< the element type, canonical and unqualified.
    pub var iter_inst: unsafe *InstanceEntry = &null ///< User: a generic `op in`'s instance (an extension's on `[T]`), as CallExpr::instance.
    // Cxx only.
    pub var cxx_begin_fn:   unsafe *Decl          = &null ///< `begin`, a member or (cxx_free) a free function.
    pub var cxx_end_fn:     unsafe *Decl          = &null
    pub var cxx_free:       bool                  = false ///< begin/end are free functions found by ADL: `begin(r)`.
    pub var cxx_begin_inst: unsafe *InstanceEntry = &null ///< a generic free begin's instance, as CallExpr::instance.
    pub var cxx_end_inst:   unsafe *InstanceEntry = &null
    pub var cxx_it:         unsafe *VariableDecl  = &null ///< `__it`, of begin's type; init left to IterLowering.
    pub var cxx_end:        unsafe *VariableDecl  = &null ///< `__end`, of end's type (a sentinel may differ).
    pub var cxx_cond:       unsafe *Expr          = &null ///< `__it != __end`, typed.
    pub var cxx_deref:      unsafe *Expr          = &null ///< `*__it`, typed: the element place.
    pub var cxx_next:       unsafe *Expr          = &null ///< `++__it`, typed.
    /// The iterable is an imported C++ template instance over the generic's
    /// own parameter (`cxx::std::vector<T>`): its begin()/end() are C++'s to
    /// pick per instance, as any member call on it is, so EmitIR spells a C++
    /// range-for and the binder stays untyped (P476). No other Cxx piece is set.
    pub var cxx_dependent: bool = false

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         iterable: unsafe *Expr,
                         body:     unsafe *CompoundStmt,
                         is_eval:  bool) -> unsafe *RangedForStmt {
        var unsafe *node = ctx->alloc<RangedForStmt>()
        node->kind  = StmtKind::RangedForStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->iterable  = iterable
        node->body      = body
        node->is_eval   = is_eval
        node->ev_lo     = &null
        node->ev_hi     = &null
        node->ev_incl   = false
        node->iter_kind = IterKind::None
        node->iter_op   = &null
        node->iter_elem = &null
        node->iter_inst = &null
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *RangedForStmt {
        var unsafe *node = ctx->alloc<RangedForStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::RangedForStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->iter_kind = IterKind::None
        node->iter_op   = &null
        node->iter_elem = &null
        node->iter_inst = &null
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::RangedForStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::RangedForStmt
    }
}

///
///  IndexedForStmt
///  Grammar:  'eval'? 'for' decl_stmt ';' expr ';' expr block
///
///  C-style three-part for. `init` declares a loop-scoped variable (a
///  DeclStmt). `cond` and `update` are bare expressions. `is_eval` marks the
///  compile-time unroll form.
///
pub class IndexedForStmt derives Stmt {
    pub var init:    unsafe *Stmt         ///< the loop-variable declaration (DeclStmt).
    pub var cond:    unsafe *Expr
    pub var update:  unsafe *Expr
    pub var body:    unsafe *CompoundStmt
    pub var is_eval: bool

    pub static fn create(ctx:     *ASTContext,
                         range:   SourceRange,
                         init:    unsafe *Stmt,
                         cond:    unsafe *Expr,
                         update:  unsafe *Expr,
                         body:    unsafe *CompoundStmt,
                         is_eval: bool) -> unsafe *IndexedForStmt {
        var unsafe *node = ctx->alloc<IndexedForStmt>()
        node->kind  = StmtKind::IndexedForStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->init    = init
        node->cond    = cond
        node->update  = update
        node->body    = body
        node->is_eval = is_eval
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *IndexedForStmt {
        var unsafe *node = ctx->alloc<IndexedForStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::IndexedForStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::IndexedForStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::IndexedForStmt
    }
}

///
///  MatchStmt
///  Grammar:  'match' expr '{' match_case* '}'
///    match_case := 'case' pattern (',' pattern)* ('where' expr)? block
///                | 'default' block
///
///  Statement-position match. Exhaustive like the expression form
///  (PatternChecking).
///
pub class MatchStmt derives Stmt {
    pub var scrutinee: unsafe *Expr
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
                         scrutinee: unsafe *Expr) -> unsafe *MatchStmt {
        var unsafe *node = ctx->alloc<MatchStmt>()
        node->kind  = StmtKind::MatchStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->scrutinee     = scrutinee
        node->is_exhaustive = true
        node->covering_arm  = -1
        node->open_tail     = false
        node->decision      = &null
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *MatchStmt {
        var unsafe *node = ctx->alloc<MatchStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::MatchStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->is_exhaustive = true
        node->covering_arm  = -1
        node->open_tail     = false
        node->decision      = &null
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::MatchStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::MatchStmt
    }
}

///
///  LabeledStmt
///  Grammar:  identifier ':' (while_stmt | ranged_for | indexed_for | loop_stmt)
///
///  Only legal on loop statements. Provides the target for `break label` /
///  `continue label`.
///
pub class LabeledStmt derives Stmt {
    pub var label: Token
    pub var inner: unsafe *Stmt ///< the labeled loop statement.

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         label: Token,
                         inner: unsafe *Stmt) -> unsafe *LabeledStmt {
        var unsafe *node = ctx->alloc<LabeledStmt>()
        node->kind  = StmtKind::LabeledStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->label = label
        node->inner = inner
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *LabeledStmt {
        var unsafe *node = ctx->alloc<LabeledStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::LabeledStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::LabeledStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::LabeledStmt
    }
}

///
///  TryCatchStmt
///  Grammar:  'try' block ('catch' catch_filter? block)+
///    catch_filter := identifier (':' type)?
///
///  `finally` is NOT a clause here; `try { } finally { }` parses as a
///  TryCatchStmt followed by a separate FinallyStmt. `arms` holds the catch
///  arms; a bare `catch { }` arm has both filter and binding null.
///
pub class TryCatchStmt derives Stmt {
    pub var try_body: unsafe *CompoundStmt
    pub var arms:     FrozenList<CatchArm>
    /// The body's panic set (Compiler/Spec/Panic.md#try-and-arms): everything that reaches this
    /// `try` from its body, canonical. The arms discharge it; PanicLowering
    /// sizes the slot from it. One writer: PanicEffectChecking.
    pub var reach: FrozenList<unsafe *Type>
    /// PanicLowering's C++ `try` (Compiler/Spec/Panic.md#c-exception-arms, §4.5a H): every arm is a C++
    /// exception arm, its body the lowered `try` body. EmitIR writes it as
    /// `try { } catch (T& e) { }`; any other TryCatchStmt is PanicLowering's.
    pub var cxx: bool = false

    pub static fn create(ctx:      unsafe *ASTContext,
                         range:    SourceRange,
                         try_body: unsafe *CompoundStmt) -> unsafe *TryCatchStmt {
        var unsafe *node = ctx->alloc<TryCatchStmt>()
        node->kind  = StmtKind::TryCatchStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->try_body = try_body
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *TryCatchStmt {
        var unsafe *node = ctx->alloc<TryCatchStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::TryCatchStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::TryCatchStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::TryCatchStmt
    }
}

///
///  FinallyStmt
///  Grammar:  'finally' block
///
///  Standalone deferred cleanup. Runs at function exit in reverse declaration
///  order (LIFO).
///
pub class FinallyStmt derives Stmt {
    pub var body: unsafe *CompoundStmt

    pub static fn create(ctx:   unsafe *ASTContext,
                         range: SourceRange,
                         body:  unsafe *CompoundStmt) -> unsafe *FinallyStmt {
        var unsafe *node = ctx->alloc<FinallyStmt>()
        node->kind  = StmtKind::FinallyStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->body = body
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *FinallyStmt {
        var unsafe *node = ctx->alloc<FinallyStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::FinallyStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::FinallyStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::FinallyStmt
    }
}

///
///  UnsafeBlockStmt
///  Grammar:  'unsafe' block
///
///  Introduces an UnsafeContext. Suspends AMT tracking for the body.
///
pub class UnsafeBlockStmt derives Stmt {
    pub var body: unsafe *CompoundStmt

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         body:  unsafe *CompoundStmt) -> unsafe *UnsafeBlockStmt {
        var unsafe *node = ctx->alloc<UnsafeBlockStmt>()
        node->kind  = StmtKind::UnsafeBlockStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->body = body
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *UnsafeBlockStmt {
        var unsafe *node = ctx->alloc<UnsafeBlockStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::UnsafeBlockStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::UnsafeBlockStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::UnsafeBlockStmt
    }
}

///
///  ContextBindingStmt
///  Grammar:  expr 'as' binding_spec block
///    binding_spec := ('var'|'const') (binding | '(' binding (',' binding)* ')')
///
///  Scope-bound resource (Python `with` / C# `using`). The expr parser, on
///  seeing `as` followed by `var`/`const`, rolls back and leaves `as`
///  unconsumed; the statement parser owns this production from there. The
///  binding(s) live for the body block. Sema lowers via conformance to the
///  context protocol (enter/exit). `bindings` is populated by the parser.
///
///  A binding_spec with no following block is a hard error (it is neither a
///  valid cast nor a valid context block).
///
pub class ContextBindingStmt derives Stmt {
    pub var value:    unsafe *Expr
    pub var bindings: FrozenList<Binding>
    pub var body:     unsafe *CompoundStmt

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         value: unsafe *Expr,
                         body:  unsafe *CompoundStmt) -> unsafe *ContextBindingStmt {
        var unsafe *node = ctx->alloc<ContextBindingStmt>()
        node->kind  = StmtKind::ContextBindingStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->value = value
        node->body  = body
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ContextBindingStmt {
        var unsafe *node = ctx->alloc<ContextBindingStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::ContextBindingStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::ContextBindingStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::ContextBindingStmt
    }
}

///
///  DestructuringDeclStmt
///  Grammar:  ('var'|'const') (tuple_pat | struct_pat) '=' expr
///    tuple_pat  := '(' binding (',' binding)* ')'
///    struct_pat := '{' binding (',' binding)* '}'
///
///  `kind` distinguishes positional (tuple) from by-field-name (struct)
///  destructuring. `leading_is_const` records the lead keyword (each Binding
///  also carries its own resolved `is_const`). `bindings` is parser-populated.
///
pub class DestructuringDeclStmt derives Stmt {
    pub var kind_:            DestructureKind ///< Tuple vs Struct. (kind_ to avoid Stmt::kind clash.)
    pub var bindings:         FrozenList<Binding>
    pub var value:            unsafe *Expr
    pub var leading_is_const: bool

    pub static fn create(ctx:              *ASTContext,
                         range:            SourceRange,
                         destructure_kind: DestructureKind,
                         value:            unsafe *Expr,
                         leading_is_const: bool) -> unsafe *DestructuringDeclStmt {
        var unsafe *node = ctx->alloc<DestructuringDeclStmt>()
        node->kind  = StmtKind::DestructuringDeclStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->kind_            = destructure_kind
        node->value            = value
        node->leading_is_const = leading_is_const
        return node
    }

    pub static fn create_error(ctx:   *ASTContext,
                               range: SourceRange) -> unsafe *DestructuringDeclStmt {
        var unsafe *node = ctx->alloc<DestructuringDeclStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::DestructuringDeclStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::DestructuringDeclStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::DestructuringDeclStmt
    }
}

///
///  InlineBlockStmt
///  Grammar:  'inline' string_literal '{' <opaque body> '}'
///
///  Foreign block. The body is opaque to the Kairo parser and handed to the
///  foreign backend unmodified; `body_span` covers the raw inner text.
///
pub class InlineBlockStmt derives Stmt {
    pub var lang:      FFILang
    pub var body_span: SourceRange ///< raw inner body, excluding braces.

    pub static fn create(ctx:       *ASTContext,
                         range:     SourceRange,
                         lang:      FFILang,
                         body_span: SourceRange) -> unsafe *InlineBlockStmt {
        var unsafe *node = ctx->alloc<InlineBlockStmt>()
        node->kind  = StmtKind::InlineBlockStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        node->lang      = lang
        node->body_span = body_span
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *InlineBlockStmt {
        var unsafe *node = ctx->alloc<InlineBlockStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::InlineBlockStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::InlineBlockStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::InlineBlockStmt
    }
}

///
///  EvalBlockStmt
///  Grammar:  'eval' '{' decl* '}'
///
///  Decl-only compile-time block. Statements inside are a sema error (parser
///  still recovers). `eval if` / `eval for` / `eval var` are handled by their
///  own stmt/decl nodes with `is_eval = true`, NOT by this kind.
///
pub class EvalBlockStmt derives Stmt {
    pub var body: FrozenList<unsafe *Decl>

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *EvalBlockStmt {
        var unsafe *node = ctx->alloc<EvalBlockStmt>()
        node->kind  = StmtKind::EvalBlockStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *EvalBlockStmt {
        var unsafe *node = ctx->alloc<EvalBlockStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::EvalBlockStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::EvalBlockStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::EvalBlockStmt
    }
}

pub enum InlineBlockLang derives u8 {
    /// Clang: -x assembler-with-cpp
    /// inline "asm" { }
    Asm,

    /// Clang: -x c
    /// inline "c" { }
    C,

    /// Clang: -x c++
    /// inline "c++" { }
    Cxx,

    /// Clang: -x cuda  (requires CUDA toolkit)
    /// inline "cuda" { }
    Cuda,

    /// Clang: -x hip  (requires ROCm)
    /// inline "hip" { }
    Hip,

    /// Clang: -x opencl
    /// inline "OpenCL" { }
    OpenCL,

    /// Clang: -x hlsl  (Clang 15+)
    /// inline "hlsl" { }
    Hlsl,

    /// Apple metal compiler (xcrun metal), NOT standard Clang
    /// requires Apple toolchain
    /// inline "metal" { }
    Metal,

    /// OpenCL source compiled to SPIR-V via --target=spirv32/spirv64
    /// not a separate language, just OpenCL with a different target
    /// inline "spirv" { }
    SpirV,

    /// naga or tint compiler, NOT Clang
    /// requires separate WGSL toolchain
    /// inline "wgsl" { }
    Wgsl,

    /// glslang or shaderc, NOT Clang
    /// requires separate GLSL toolchain
    /// inline "glsl" { }
    Glsl,

    /// does absolutely nothing, just for fucks and giggles
    /// ACTUALLY MIGHT BE USEFUL FOR ADDING KAIRO DIRECTLY INTO C++ CODE
    /// inline "kairo" { }
    Kairo,
}

///
///  CompoundStmt
///  Grammar:  '{' stmt* '}'
///
///  Introduces a lexical scope. Destructors run at the closing brace in
///  reverse declaration order. `body` is populated by the parser.
///
pub class CompoundStmt derives Stmt {
    pub var body: FrozenList<unsafe *Stmt>

    pub static fn create(ctx: unsafe *ASTContext, range: SourceRange) -> unsafe *CompoundStmt {
        var unsafe *node = ctx->alloc<CompoundStmt>()
        node->kind  = StmtKind::CompoundStmt
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *CompoundStmt {
        var unsafe *node = ctx->alloc<CompoundStmt>()
        node->kind          = StmtKind::RecoveryStmt
        node->recovery_kind = StmtKind::CompoundStmt
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Stmt) -> bool {
        return ptr->kind == StmtKind::CompoundStmt
    }

    /* OVERRIDE */
    static fn stmt_kind() -> StmtKind {
        return StmtKind::CompoundStmt
    }
}

///
///  MatchCase
///
///  One case of a `match` statement:
///    `case 1, 2, 3 { }`                    -> patterns = [1,2,3]
///    `case .Found(var k) where k > 0 { }`  -> one pattern + guard
///    `default { }`                         -> is_default, patterns empty
///
///  `patterns` holds the comma-separated alternatives that share one body
///  (Kairo has no fall-through; comma is the only way to share a body).
///
pub struct MatchCase {
    pub var patterns:   FrozenList<unsafe *Pattern> ///< empty when is_default.
    pub var guard:      unsafe *Expr                ///< optional `where` guard; null if none.
    pub var body:       unsafe *CompoundStmt
    pub var expression: unsafe *Expr                ///< expr only path invalidates the body.
    pub var range:      SourceRange
    pub var is_default: bool
}

/// The first arm of a match that is a row of its pattern matrix: 1 when
/// arm 0 is the `case null` of a match on `T?` (MatchStmt / MatchExpr::
/// null_arm, Compiler/Spec/Nullables.md#match), which is answered before the match and so
/// is no row; else 0. Arm numbers are kept either way.
pub fn match_first_row(null_arm: bool) -> usize {
    if null_arm {
        return 1
    }

    return 0
}
