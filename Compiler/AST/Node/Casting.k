/// --- The Kairo Project --------------------------- AST/Node/Casting.k --- ///
///
///   isa, cast and dyn_cast over Expr, Stmt, Decl, Type and AstPattern, using the
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
    AstPattern,
    Decl,
    Expr,
    Stmt,
    Type,
}

/// RTTI casting system for Kairo AST nodes.
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
///   dyn_cast_recovery<T>(ptr)safe cast via recovery_kind; like dyn_cast,
///                            `*T?` for a safe `*B`
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

/// Recovery casting: a Recovery node is cast back to the concrete class it
/// was allocated as. create_error() on every concrete node allocates the
/// full concrete node and then sets kind to the family's Recovery kind, so
/// recovery_kind always names the allocation and the cast is valid. Each
/// concrete node defines `static fn expr_kind() -> ExprKind` (or stmt_kind,
/// decl_kind, type_kind, pattern_kind), which the recovery casts compare
/// recovery_kind with.
///
/// One family's functions, for the node base `Base_` whose kind enum is
/// `Kind_`, whose recovery kind is `Kind_::Recovery_` and whose concrete
/// classes answer `kind_fn_()`. The five families are the five invocations
/// below.
// TODO(DUCK-GENERIC): T uses classof and the family's kind function. Bound it or keep `: type`.
macro node_casts!(Base_, Kind_, Recovery_, kind_fn_) {
    pub fn <T: type> isa(ptr: *const Base_, tag: SafePtrTag = SafePtrTag()) -> bool {
        if ptr == &null {
            return false
        }

        return T::classof(ptr)
    }

    pub fn <T: type> isa(ptr: unsafe *const Base_) -> bool {
        if ptr == &null {
            return false
        }

        return T::classof(unsafe (ptr as *const Base_))
    }

    pub fn <T: type> cast(ptr: *const Base_, tag: SafePtrTag = SafePtrTag()) -> *const T {
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

    pub fn <T: type> cast(ptr: unsafe *const Base_) -> unsafe *const T {
        eval if defined!(DEBUG) {
            if !(ptr != &null) {
                kairo::std::ice_fail(r"cast<>: null pointer")
            }
        }

        eval if defined!(DEBUG) {
            if !T::classof(unsafe (ptr as *const Base_)) {
                kairo::std::ice_fail(r"cast<>: incorrect type")
            }
        }

        return unsafe (ptr as unsafe *const T)
    }

    pub fn <T: type> cast(ptr: *Base_, tag: SafePtrTag = SafePtrTag()) -> *T {
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

    pub fn <T: type> cast(ptr: unsafe *Base_) -> unsafe *T {
        eval if defined!(DEBUG) {
            if !(ptr != &null) {
                kairo::std::ice_fail(r"cast<>: null pointer")
            }
        }

        eval if defined!(DEBUG) {
            if !T::classof(unsafe (ptr as *Base_)) {
                kairo::std::ice_fail(r"cast<>: incorrect type")
            }
        }

        return unsafe (ptr as unsafe *T)
    }

    pub fn <T: type> dyn_cast(ptr: *Base_, tag: SafePtrTag = SafePtrTag()) -> *T? {
        if ptr != &null && T::classof(ptr) {
            return unsafe (ptr as unsafe *T as *T)
        }

        return &null
    }

    pub fn <T: type> dyn_cast(ptr: unsafe *Base_) -> unsafe *T {
        if ptr != &null && T::classof(unsafe (ptr as *Base_)) {
            return unsafe (ptr as unsafe *T)
        }

        return &null
    }

    pub fn <T: type> dyn_cast(ptr: unsafe *const Base_) -> unsafe *const T {
        if ptr != &null && T::classof(unsafe (ptr as *const Base_)) {
            return unsafe (ptr as unsafe *const T)
        }

        return &null
    }

    pub fn <T: type> isa_recovery(ptr: unsafe *Base_) -> bool {
        if ptr == &null {
            return false
        }

        if ptr->kind != Kind_::Recovery_ {
            return false
        }

        return ptr->recovery_kind == T::kind_fn_()
    }

    pub fn <T: type> cast_recovery(ptr: unsafe *Base_) -> unsafe *T {
        eval if defined!(DEBUG) {
            if !(ptr != &null) {
                kairo::std::ice_fail(r"cast_recovery<>: null pointer")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->kind == Kind_::Recovery_) {
                kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->recovery_kind == T::kind_fn_()) {
                kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
            }
        }

        return unsafe (ptr as unsafe *T)
    }

    pub fn <T: type> dyn_cast_recovery(ptr: unsafe *Base_) -> unsafe *T {
        if ptr != &null && ptr->kind == Kind_::Recovery_ && ptr->recovery_kind == T::kind_fn_() {
            return unsafe (ptr as unsafe *T)
        }

        return &null
    }

    pub fn <T: type> isa_recovery(ptr: unsafe *const Base_) -> bool {
        if ptr == &null {
            return false
        }

        if ptr->kind != Kind_::Recovery_ {
            return false
        }

        return ptr->recovery_kind == T::kind_fn_()
    }

    pub fn <T: type> cast_recovery(ptr: unsafe *const Base_) -> unsafe *const T {
        eval if defined!(DEBUG) {
            if !(ptr != &null) {
                kairo::std::ice_fail(r"cast_recovery<>: null pointer")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->kind == Kind_::Recovery_) {
                kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->recovery_kind == T::kind_fn_()) {
                kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
            }
        }

        return unsafe (ptr as unsafe *const T)
    }

    pub fn <T: type> dyn_cast_recovery(ptr: unsafe *const Base_) -> unsafe *const T {
        if ptr != &null && ptr->kind == Kind_::Recovery_ && ptr->recovery_kind == T::kind_fn_() {
            return unsafe (ptr as unsafe *const T)
        }

        return &null
    }

    pub fn is_recovery(ptr: unsafe *Base_) -> bool {
        return ptr != &null && ptr->kind == Kind_::Recovery_
    }

    pub fn is_recovery(ptr: unsafe *const Base_) -> bool {
        return ptr != &null && ptr->kind == Kind_::Recovery_
    }

    pub fn <T: type> isa_recovery(ptr: *const Base_, tag: SafePtrTag = SafePtrTag()) -> bool {
        if ptr == &null {
            return false
        }

        var p: *const Base_ = ptr
        if p->kind != Kind_::Recovery_ {
            return false
        }

        return p->recovery_kind == T::kind_fn_()
    }

    pub fn <T: type> cast_recovery(ptr: *const Base_, tag: SafePtrTag = SafePtrTag()) -> *const T {
        eval if defined!(DEBUG) {
            if !(ptr != &null) {
                kairo::std::ice_fail(r"cast_recovery<>: null pointer")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->kind == Kind_::Recovery_) {
                kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->recovery_kind == T::kind_fn_()) {
                kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
            }
        }

        return unsafe (ptr as unsafe *const T as *const T)
    }

    pub fn <T: type> cast_recovery(ptr: *Base_, tag: SafePtrTag = SafePtrTag()) -> *T {
        eval if defined!(DEBUG) {
            if !(ptr != &null) {
                kairo::std::ice_fail(r"cast_recovery<>: null pointer")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->kind == Kind_::Recovery_) {
                kairo::std::ice_fail(r"cast_recovery<>: not a recovery node")
            }
        }

        eval if defined!(DEBUG) {
            if !(ptr->recovery_kind == T::kind_fn_()) {
                kairo::std::ice_fail(r"cast_recovery<>: wrong recovery_kind")
            }
        }

        return unsafe (ptr as unsafe *T as *T)
    }

    pub fn <T: type> dyn_cast_recovery(ptr: *Base_, tag: SafePtrTag = SafePtrTag()) -> *T? {
        if ptr != &null && ptr->kind == Kind_::Recovery_ && ptr->recovery_kind == T::kind_fn_() {
            return unsafe (ptr as unsafe *T as *T)
        }

        return &null
    }
}

node_casts!(Expr, ExprKind, RecoveryExpr, expr_kind)
node_casts!(Stmt, StmtKind, RecoveryStmt, stmt_kind)
node_casts!(Decl, DeclKind, RecoveryDecl, decl_kind)
node_casts!(Type, TypeKind, RecoveryType, type_kind)
node_casts!(AstPattern, PatternKind, RecoveryPattern, pattern_kind)
