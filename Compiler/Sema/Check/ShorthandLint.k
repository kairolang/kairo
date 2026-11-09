/// --- The Kairo Project ------------------- Sema/Check/ShorthandLint.k --- ///
///
///   \brief Warn when an inferred binding is nullable or a pointer and its
///          declaration does not say so (Compiler/Spec/Nullables.md#declaration-shorthands).
///
///   \detail
///     `var x = find()` with `find() -> i32?` gives `x: i32?`, and nothing on
///     the line shows it: the reader learns that `x` may be null at the
///     first error about reading it. The declaration shorthands exist to put
///     that on the name, so an inferred binding that could use one is
///     warned, with the fix-it that writes it:
///
///         var x = find()      // 'x' is nullable; write 'x?' so it reads as one
///         var p = &n          // 'p' is a pointer; write '*p'
///         var r = raw()       // 'r' is a pointer; write 'unsafe *r'
///         var q = maybe()     // 'q' is a nullable pointer; write '*q?' ...
///
///     The depth is the type's (`var pp = &p` is `**pp`), and `unsafe` is
///     the outermost pointer's, which is what the shorthand checks
///     (StmtTyping::_check_pointer_shorthand), so the fix-it always
///     produces a declaration that check accepts.
///
///   \par What is NOT warned
///     - An annotated binding: `var x: i32? = find()` already says it. The
///       tell is SemaDump's: an inferred slot holds a canonical node, and
///       canonicals have no source range.
///     - A binding that already uses a shorthand, even partly (`var p? =
///       &n` is `(*i32)?` with no star): the rule is "no annotation and no
///       shorthand"; a half-written shorthand is a choice, not an omission.
///     - Destructuring, `for` and pattern binders: their decls carry no
///       initializer and RAV never reaches them as VariableDecls.
///     - A dependent type in a generic body: `var a = t` is `T`, and
///       whether `T` is a pointer is not known here.
///     - Implicit (compiler-made) decls; this pass runs before every
///       lowering, so the tree is the user's.
///     - `eval` bindings: Compiler/Spec/Nullables.md#declaration-shorthands names var, const and static.
///
///   \par Library code
///     Sema runs once per file of the build, the builtin root and std
///     included. Those are written in Stage 1 syntax and follow the rule
///     like any user file, so they are linted too: a warning there is
///     fixed in the library, not hidden.
///
///   The lint is SC226W.
///
///   Phase: CHECK (after ExprTyper; reads inferred types only)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::{
    StorageClass,
    VariableDecl,
    pointer_shorthand_spelling,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

///
/// \class ShorthandLint
/// \brief The pass. Read-only: emits warnings, writes nothing to the AST.
///
pub class ShorthandLint derives RecursiveASTVisitor<ShorthandLint> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil

    fn ShorthandLint(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// The initializer first: a closure in it holds decls of its own.
    fn traverse_variable_decl(self, n: unsafe *VariableDecl) -> unsafe *VariableDecl {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<ShorthandLint>::traverse_variable_decl(self, n)
        self._check(n)
        return out
    }

    priv fn _check(self, v: unsafe *VariableDecl) {
        if v->is_poisoned() || v->is_implicit {
            return
        }

        if v->init == &null || v->type_ == &null {
            return
        }

        if v->storage == StorageClass::Eval {
            return
        }

        if v->nullable_shorthand || v->pointer_depth > 0 {
            return
        }

        if v->type_->range.is_valid() { // annotated: the type is written.
            return
        }

        if !v->name.range.is_valid() {
            return
        }

        var unsafe *c = canon_unqual(v->type_->canonical)
        if c == &null || c->is_dependent() {
            return
        }

        // A C++ reference is its referee: `var p = ptrs.at(0)` holds the
        // `*Node` the `*Node&` refers to, and is named like one.
        if isa<CXXLValueRefType>(c) {
            c = canon_unqual(cast<CXXLValueRefType>(c)->referee)
        } else if isa<CXXRValueRefType>(c) {
            c = canon_unqual(cast<CXXRValueRefType>(c)->referee)
        }

        if c == &null {
            return
        }

        var unsafe *base    = c
        var unsafe *inner   = self._tu.nullable_inner(c)
        var        nullable = inner != &null
        if nullable {
            base = canon_unqual(inner)
        }

        var shape        = self._tu.pointer_shape(base)
        var depth        = shape.depth
        var outer_unsafe = shape.outer_unsafe
        if !nullable && depth == 0 {
            return
        }

        var nm           = self.sc->ctx->get_spelling(v->name)
        var stars        = pointer_shorthand_spelling(depth, outer_unsafe)
        var q            = if (nullable) => ("?") else => ""
        var msg:  string = ""
        if depth == 0 {
            msg = f"'{nm}' is nullable; write '{nm}?' so it reads as one"
        } else if nullable {
            msg = f"'{nm}' is a nullable pointer; write '{stars}{nm}?' so it reads as one"
        } else {
            msg = f"'{nm}' is a pointer; write '{stars}{nm}'"
        }

        var b = self.sc->diag->report(DiagID::SC226W, v->name.range.start, msg)
        b.first(v->name.range)
        b.second(v->init->range, f"this has type '{self._tu.str(c)}'")
        if depth > 0 {
            b.insert(v->name.range.start, stars, f"mark '{nm}' a pointer")
        }

        if nullable {
            b.insert(v->name.range.end, q, f"mark '{nm}' nullable")
        }

        b.emit()
    }
}
