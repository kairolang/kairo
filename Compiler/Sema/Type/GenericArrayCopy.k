/// --- The Kairo Project ----------------- Sema/Type/GenericArrayCopy.k --- ///
///
///   \brief A generic body that copies a value of a type parameter which a
///          call binds to a fixed array.
///
///   \detail
///     An array is not a value type (collections.mdx): it is initialized
///     from a list literal and from nothing else (LiteralTyping::
///     reject_array_copy, SC083E). A generic body is typed once, over its
///     parameters, so `fn <T> f(const a: T) { var b: T = a }` passes there
///     and only the instance `T = [i32; 2]` copies an array, which C++ has
///     no initialization for ("array initializer must be an initializer
///     list"). CallTyping asks this scan at each call whose deduction binds
///     a parameter to an array, and reports the call.
///
///     A copy is a variable initialized from anything but a list literal,
///     or an `=` assignment, of a type that is exactly such a parameter. A
///     by-value parameter of it is SC045E at the argument (CallTyping::
///     _array_by_value) and a result of it is CallTyping's own check; a
///     copy inside a callee the body calls is that callee's call, and a
///     generic record's members are not scanned here (their parameters are
///     the record's, bound by its instance, not by a call).
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
ffi "c++" import "vector"

import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ParamDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    ListLiteralExpr,
    ParenExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types::{
    FixedArrayType,
    GenericParamType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Sema::Type::Substitution::DeducedBinding
import Token::TokenKind::TokenKind

pub class GenericArrayCopyScan derives RecursiveASTVisitor<GenericArrayCopyScan> {
    priv var _bindings: cxx::std::vector<DeducedBinding>

    /// The first copy found, or null; `copied` says what it is.
    pub var site:   unsafe *Expr             = &null
    pub var copied: string                   = ""
    /// The parameter it copies, and the array the call binds it to.
    pub var param:  unsafe *GenericParamType = &null
    pub var array:  unsafe *Type             = &null

    fn GenericArrayCopyScan(self, const bindings: cxx::std::vector<DeducedBinding>) {
        self._bindings = bindings
    }

    /// \p t is exactly a type parameter bound to a fixed array: recorded.
    pub fn array_param(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = if (t->canonical != &null) => (canon_unqual(t->canonical)) else => canon_unqual(t)
        var unsafe *g = dyn_cast<GenericParamType>(c)
        if g == &null || g->is_pack {
            return false
        }

        for var i: usize = 0; i < self._bindings.size(); ++i {
            var *b = &self._bindings[i]
            if b->owner != g->owner || b->index != g->param_index || b->ty == &null {
                continue
            }

            if !isa<FixedArrayType>(canon_unqual(b->ty)) {
                return false
            }

            self.param = g
            self.array = canon_unqual(b->ty)
            return true
        }

        return false
    }

    fn visit_variable_decl(self, n: *VariableDecl) -> bool {
        if self.site != &null || n->init == &null {
            return true
        }

        var unsafe *v = n->init
        while v != &null && isa<ParenExpr>(v) {
            v = cast<ParenExpr>(v)->inner
        }

        if v == &null || isa<ListLiteralExpr>(v) {
            return true
        }

        // `var b = a` before the body is typed: its type is the init's.
        var unsafe *t = if (n->type_ != &null) => (n->type_) else => self._place_type(n->init)
        if self.array_param(t) {
            self.site   = n->init
            self.copied = "this initializer copies"
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if self.site != &null || n->op_token.kind != TokenKind::OpEqual || n->lhs == &null {
            return true
        }

        if self.array_param(self._place_type(n->lhs)) {
            self.site   = unsafe (n as unsafe *Expr)
            self.copied = "this assignment copies"
        }

        return true
    }

    /// The type of the place \p e: its own, or, before the body is typed,
    /// the declared type of the binding it names.
    priv fn _place_type(self, e: unsafe *Expr) -> unsafe *Type {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x == &null {
            return &null
        }

        if x->type_ != &null {
            return x->type_
        }

        if !isa<NamedIdentExpr>(x) {
            return &null
        }

        var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
        if d != &null && isa<ParamDecl>(d) {
            return cast<ParamDecl>(d)->type_
        }

        if d != &null && isa<VariableDecl>(d) {
            return cast<VariableDecl>(d)->type_
        }

        return &null
    }
}
