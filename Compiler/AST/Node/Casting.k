/// --- The Kairo Project --------------------------- AST/Node/Casting.k --- ///
///
///   isa, cast and dyn_cast over Expr, Stmt, Decl, Type and Pattern, using the
///   nodes' kind tags instead of RTTI.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::PatternKind::PatternKind
import AST::Kind::StmtKind::StmtKind
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}

///
/// \brief RTTI casting system for Kairo AST nodes.
///
/// All casts are based on the kind field at offset 0 of every node.
/// No vtable, no dynamic_cast, no typeid.
///
/// Three cast functions per hierarchy:
///   isa<T>(ptr)     check if ptr is a T, no cast
///   cast<T>(ptr)    assert + static_cast, crashes in debug if wrong
///   dyn_cast<T>(ptr)returns null if not a T, T* if it is
///
/// The kind field is always valid even on RecoveryExpr nodes because
/// create_error() always allocates the full concrete node and sets
/// recovery_kind. See the recovery casting contract in Expr.
///
/// Recovery casting:
///   isa_recovery<T>(ptr)     checks recovery_kind instead of kind
///   cast_recovery<T>(ptr)    cast via recovery_kind, debug assert
///   dyn_cast_recovery<T>(ptr)safe cast via recovery_kind
///
/// Safe pointers (decided 2026-11-08): for a non-null `*B`,
/// `isa` tests the kind, `cast` returns a non-null `*T` (the
/// reinterpretation is the helper's own `unsafe`: AST nodes have no vtable,
/// so `as *D` cannot check it; a DEBUG build checks the kind with classof
/// and ICEs on a wrong one, a release build trusts the caller), and
/// `dyn_cast` returns `*T?`, null when the kind differs, so its caller
/// narrows it (`if x? { ... }`) before use. Each also keeps its `unsafe *B`
/// overload for the raw pointers that remain; those still answer raw.
/// `isa` and `dyn_cast` still test for null: while most of the tree is raw,
/// a value typed `*B` can be null at run time (a C++ container's default,
/// an arena slot), and both helpers have always answered false/null for it.
///
/// C++ sees `*B`, `*B?` and `unsafe *B` as the same `B*`, so a safe and a
/// raw overload with otherwise equal parameters would be one C++ function
/// twice (a redefinition). Each safe overload therefore carries a defaulted
/// SafePtrTag parameter, which no caller writes, until the raw family has
/// no callers left and can be deleted.
///
/// Usage:
///   if isa::<IntegerLiteralExpr>(e) { ... }
///   var lit = cast::<IntegerLiteralExpr>(e);
///   if var lit = dyn_cast::<IntegerLiteralExpr>(e) { ... }
///
/// Disambiguates the safe overloads from the raw ones in C++ (see above).
pub struct SafePtrTag { }

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: *const Expr, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(ptr)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: unsafe *const Expr) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(unsafe (ptr as *const Expr))
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: *const Stmt, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(ptr)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: unsafe *const Stmt) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(unsafe (ptr as *const Stmt))
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: *const Decl, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(ptr)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: unsafe *const Decl) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(unsafe (ptr as *const Decl))
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: *const Type, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(ptr)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: unsafe *const Type) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(unsafe (ptr as *const Type))
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: *const Pattern, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(ptr)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa(ptr: unsafe *const Pattern) -> bool {
    if ptr == &null {
        return false
    }

    return T::classof(unsafe (ptr as *const Pattern))
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *const Expr, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *const Expr) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *const Expr)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *Expr, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *Expr) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *Expr)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *const Stmt, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *const Stmt) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *const Stmt)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *Stmt, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *Stmt) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *Stmt)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *const Decl, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *const Decl) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *const Decl)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *Decl, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *Decl) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *Decl)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *const Type, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *const Type) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *const Type)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *Type, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *Type) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *Type)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *const Pattern, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *const Pattern) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *const Pattern)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: *Pattern, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(ptr) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast(ptr: unsafe *Pattern) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !T::classof(unsafe (ptr as *Pattern)) {
            kairo::std::ice_fail(r"cast<>: incorrect type")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: *Expr, tag: SafePtrTag = SafePtrTag()) -> *T? {
    if ptr != &null && T::classof(ptr) {
        return unsafe (ptr as unsafe *T as *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *Expr) -> unsafe *T {
    if ptr != &null && T::classof(unsafe (ptr as *Expr)) {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *const Expr) -> unsafe *const T {
    if ptr != &null && T::classof(unsafe (ptr as *const Expr)) {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: *Stmt, tag: SafePtrTag = SafePtrTag()) -> *T? {
    if ptr != &null && T::classof(ptr) {
        return unsafe (ptr as unsafe *T as *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *Stmt) -> unsafe *T {
    if ptr != &null && T::classof(unsafe (ptr as *Stmt)) {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *const Stmt) -> unsafe *const T {
    if ptr != &null && T::classof(unsafe (ptr as *const Stmt)) {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: *Decl, tag: SafePtrTag = SafePtrTag()) -> *T? {
    if ptr != &null && T::classof(ptr) {
        return unsafe (ptr as unsafe *T as *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *Decl) -> unsafe *T {
    if ptr != &null && T::classof(unsafe (ptr as *Decl)) {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *const Decl) -> unsafe *const T {
    if ptr != &null && T::classof(unsafe (ptr as *const Decl)) {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: *Type, tag: SafePtrTag = SafePtrTag()) -> *T? {
    if ptr != &null && T::classof(ptr) {
        return unsafe (ptr as unsafe *T as *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *Type) -> unsafe *T {
    if ptr != &null && T::classof(unsafe (ptr as *Type)) {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *const Type) -> unsafe *const T {
    if ptr != &null && T::classof(unsafe (ptr as *const Type)) {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: *Pattern, tag: SafePtrTag = SafePtrTag()) -> *T? {
    if ptr != &null && T::classof(ptr) {
        return unsafe (ptr as unsafe *T as *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *Pattern) -> unsafe *T {
    if ptr != &null && T::classof(unsafe (ptr as *Pattern)) {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses classof. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast(ptr: unsafe *const Pattern) -> unsafe *const T {
    if ptr != &null && T::classof(unsafe (ptr as *const Pattern)) {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

/// # Recovery casting
///
/// Used by sema to cast a RecoveryExpr/RecoveryStmt/RecoveryDecl/RecoveryType
/// back to its concrete allocated type.
///
/// Safe because create_error() on every concrete node allocates the FULL
/// concrete node and then overwrites kind with Recovery*.
/// recovery_kind always matches the actual allocationthe cast is valid.
///
/// Each concrete node must define:
///   static fn expr_kind() -> ExprKind   (or stmt_kind, decl_kind, type_kind)
/// so the recovery cast can verify the recovery_kind matches T.

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *Expr) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != ExprKind::RecoveryExpr {
        return false
    }

    return ptr->recovery_kind == T::expr_kind()
}

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *Expr) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == ExprKind::RecoveryExpr) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::expr_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *Expr) -> unsafe *T {
    if ptr != &null && ptr->kind == ExprKind::RecoveryExpr && ptr->recovery_kind == T::expr_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// const overloads for Expr recovery
// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *const Expr) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != ExprKind::RecoveryExpr {
        return false
    }

    return ptr->recovery_kind == T::expr_kind()
}

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *const Expr) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == ExprKind::RecoveryExpr) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::expr_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *const Expr) -> unsafe *const T {
    if ptr != &null && ptr->kind == ExprKind::RecoveryExpr && ptr->recovery_kind == T::expr_kind() {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *Stmt) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != StmtKind::RecoveryStmt {
        return false
    }

    return ptr->recovery_kind == T::stmt_kind()
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *Stmt) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == StmtKind::RecoveryStmt) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::stmt_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *Stmt) -> unsafe *T {
    if ptr != &null && ptr->kind == StmtKind::RecoveryStmt && ptr->recovery_kind == T::stmt_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *const Stmt) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != StmtKind::RecoveryStmt {
        return false
    }

    return ptr->recovery_kind == T::stmt_kind()
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *const Stmt) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == StmtKind::RecoveryStmt) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::stmt_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *const Stmt) -> unsafe *const T {
    if ptr != &null && ptr->kind == StmtKind::RecoveryStmt && ptr->recovery_kind == T::stmt_kind() {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *Decl) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != DeclKind::RecoveryDecl {
        return false
    }

    return ptr->recovery_kind == T::decl_kind()
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *Decl) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == DeclKind::RecoveryDecl) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::decl_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *Decl) -> unsafe *T {
    if ptr != &null && ptr->kind == DeclKind::RecoveryDecl && ptr->recovery_kind == T::decl_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *const Decl) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != DeclKind::RecoveryDecl {
        return false
    }

    return ptr->recovery_kind == T::decl_kind()
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *const Decl) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == DeclKind::RecoveryDecl) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::decl_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *const Decl) -> unsafe *const T {
    if ptr != &null && ptr->kind == DeclKind::RecoveryDecl && ptr->recovery_kind == T::decl_kind() {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *Type) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != TypeKind::RecoveryType {
        return false
    }

    return ptr->recovery_kind == T::type_kind()
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *Type) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == TypeKind::RecoveryType) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::type_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *Type) -> unsafe *T {
    if ptr != &null && ptr->kind == TypeKind::RecoveryType && ptr->recovery_kind == T::type_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *const Type) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != TypeKind::RecoveryType {
        return false
    }

    return ptr->recovery_kind == T::type_kind()
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *const Type) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == TypeKind::RecoveryType) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::type_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *const Type) -> unsafe *const T {
    if ptr != &null && ptr->kind == TypeKind::RecoveryType && ptr->recovery_kind == T::type_kind() {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *Pattern) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != PatternKind::RecoveryPattern {
        return false
    }

    return ptr->recovery_kind == T::pattern_kind()
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *Pattern) -> unsafe *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == PatternKind::RecoveryPattern) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::pattern_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T)
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *Pattern) -> unsafe *T {
    if ptr != &null
        && ptr->kind == PatternKind::RecoveryPattern
        && ptr->recovery_kind == T::pattern_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: unsafe *const Pattern) -> bool {
    if ptr == &null {
        return false
    }

    if ptr->kind != PatternKind::RecoveryPattern {
        return false
    }

    return ptr->recovery_kind == T::pattern_kind()
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: unsafe *const Pattern) -> unsafe *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == PatternKind::RecoveryPattern) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::pattern_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T)
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: unsafe *const Pattern) -> unsafe *const T {
    if ptr != &null
        && ptr->kind == PatternKind::RecoveryPattern
        && ptr->recovery_kind == T::pattern_kind() {
        return unsafe (ptr as unsafe *const T)
    }

    return &null
}

pub fn is_recovery(ptr: unsafe *Expr) -> bool {
    return ptr != &null && ptr->kind == ExprKind::RecoveryExpr
}

pub fn is_recovery(ptr: unsafe *Stmt) -> bool {
    return ptr != &null && ptr->kind == StmtKind::RecoveryStmt
}

pub fn is_recovery(ptr: unsafe *Type) -> bool {
    return ptr != &null && ptr->kind == TypeKind::RecoveryType
}

pub fn is_recovery(ptr: unsafe *Decl) -> bool {
    return ptr != &null && ptr->kind == DeclKind::RecoveryDecl
}

pub fn is_recovery(ptr: unsafe *Pattern) -> bool {
    return ptr != &null && ptr->kind == PatternKind::RecoveryPattern
}

pub fn is_recovery(ptr: unsafe *const Expr) -> bool {
    return ptr != &null && ptr->kind == ExprKind::RecoveryExpr
}

pub fn is_recovery(ptr: unsafe *const Stmt) -> bool {
    return ptr != &null && ptr->kind == StmtKind::RecoveryStmt
}

pub fn is_recovery(ptr: unsafe *const Type) -> bool {
    return ptr != &null && ptr->kind == TypeKind::RecoveryType
}

pub fn is_recovery(ptr: unsafe *const Decl) -> bool {
    return ptr != &null && ptr->kind == DeclKind::RecoveryDecl
}

pub fn is_recovery(ptr: unsafe *const Pattern) -> bool {
    return ptr != &null && ptr->kind == PatternKind::RecoveryPattern
}

// Safe-pointer recovery casts: same contracts as the raw ones above.
// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: *const Expr, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    var p: *const Expr = ptr
    if p->kind != ExprKind::RecoveryExpr {
        return false
    }

    return p->recovery_kind == T::expr_kind()
}

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *const Expr, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == ExprKind::RecoveryExpr) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::expr_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *Expr, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == ExprKind::RecoveryExpr) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::expr_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses expr_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: *Expr, tag: SafePtrTag = SafePtrTag()) -> unsafe *T {
    if ptr != &null && ptr->kind == ExprKind::RecoveryExpr && ptr->recovery_kind == T::expr_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: *const Stmt, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    var p: *const Stmt = ptr
    if p->kind != StmtKind::RecoveryStmt {
        return false
    }

    return p->recovery_kind == T::stmt_kind()
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *const Stmt, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == StmtKind::RecoveryStmt) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::stmt_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *Stmt, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == StmtKind::RecoveryStmt) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::stmt_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses stmt_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: *Stmt, tag: SafePtrTag = SafePtrTag()) -> unsafe *T {
    if ptr != &null && ptr->kind == StmtKind::RecoveryStmt && ptr->recovery_kind == T::stmt_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: *const Decl, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    var p: *const Decl = ptr
    if p->kind != DeclKind::RecoveryDecl {
        return false
    }

    return p->recovery_kind == T::decl_kind()
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *const Decl, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == DeclKind::RecoveryDecl) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::decl_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *Decl, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == DeclKind::RecoveryDecl) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::decl_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses decl_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: *Decl, tag: SafePtrTag = SafePtrTag()) -> unsafe *T {
    if ptr != &null && ptr->kind == DeclKind::RecoveryDecl && ptr->recovery_kind == T::decl_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: *const Type, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    var p: *const Type = ptr
    if p->kind != TypeKind::RecoveryType {
        return false
    }

    return p->recovery_kind == T::type_kind()
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *const Type, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == TypeKind::RecoveryType) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::type_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *Type, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == TypeKind::RecoveryType) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::type_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses type_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: *Type, tag: SafePtrTag = SafePtrTag()) -> unsafe *T {
    if ptr != &null && ptr->kind == TypeKind::RecoveryType && ptr->recovery_kind == T::type_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> isa_recovery(ptr: *const Pattern, tag: SafePtrTag = SafePtrTag()) -> bool {
    if ptr == &null {
        return false
    }

    var p: *const Pattern = ptr
    if p->kind != PatternKind::RecoveryPattern {
        return false
    }

    return p->recovery_kind == T::pattern_kind()
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *const Pattern, tag: SafePtrTag = SafePtrTag()) -> *const T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == PatternKind::RecoveryPattern) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::pattern_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *const T as *const T)
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> cast_recovery(ptr: *Pattern, tag: SafePtrTag = SafePtrTag()) -> *T {
    eval if defined!(DEBUG) {
        if !(ptr != &null) {
            kairo::std::ice_fail(r"cast_recovery<>: null pointer")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->kind == PatternKind::RecoveryPattern) {
            kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
        }
    }

    eval if defined!(DEBUG) {
        if !(ptr->recovery_kind == T::pattern_kind()) {
            kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
        }
    }

    return unsafe (ptr as unsafe *T as *T)
}

// TODO(DUCK-GENERIC): T uses pattern_kind. Stage 0 was duck-typed; bound it or keep `: type`.
pub fn <T: type> dyn_cast_recovery(ptr: *Pattern, tag: SafePtrTag = SafePtrTag()) -> unsafe *T {
    if ptr != &null
        && ptr->kind == PatternKind::RecoveryPattern
        && ptr->recovery_kind == T::pattern_kind() {
        return unsafe (ptr as unsafe *T)
    }

    return &null
}
