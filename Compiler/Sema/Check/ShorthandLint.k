/// --- The Kairo Project ---------------------- Sema/Check/ShorthandLint.k --- ///
///
///   \brief Warn when an inferred binding is nullable or a pointer and its
///          declaration does not say so (NULLABLE.md 1.8).
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
///     the outermost pointer's, which is what G20's shorthand checks
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
///     - `eval` bindings: NULLABLE.md 1.8 names var, const and static.
///
///   \par Library code
///     Sema runs once per file of the build, the builtin root and std
///     included. Those are written in Stage 1 syntax and follow the rule
///     like any user file, so they are linted too: a warning there is
///     fixed in the library, not hidden.
///
///   SC001W is the placeholder until the monthly sweep gives the lint a
///   code.
///
///   Phase: CHECK (after ExprTyper; reads inferred types only)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

///
/// \class ShorthandLint
/// \brief The pass. Read-only: emits warnings, writes nothing to the AST.
///
class ShorthandLint derives RecursiveASTVisitor::<ShorthandLint> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;

    fn ShorthandLint(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    /// The initializer first: a closure in it holds decls of its own.
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n == &null { return n; }
        var out = RecursiveASTVisitor::<ShorthandLint>::traverse_variable_decl(n);
        self._check(n);
        return out;
    }

    priv fn _check(self, v: *VariableDecl) {
        if v->is_poisoned() || v->is_implicit { return; }
        if (v->init == &null) || (v->type_ == &null) { return; }
        if v->storage == StorageClass::Eval { return; }
        if v->nullable_shorthand || (v->pointer_depth > 0) { return; }
        if v->type_->range.is_valid() { return; }   // annotated: the type is written.
        if !v->name.range.is_valid() { return; }

        var c = canon_unqual(v->type_->canonical);
        if (c == &null) || c->is_dependent() { return; }

        var base     = c;
        var inner    = self._tu.nullable_inner(c);
        var nullable = inner != &null;
        if nullable { base = canon_unqual(inner); }

        var depth = u32(0);
        var outer_unsafe = false;
        var p = base;
        while (p != &null) && isa::<PointerType>(p) {
            if depth == 0 { outer_unsafe = cast::<PointerType>(p)->is_unsafe; }
            depth += 1;
            p = canon_unqual(cast::<PointerType>(p)->pointee);
        }
        if (!nullable) && (depth == 0) { return; }

        var nm    = self.sc->ctx->get_spelling(v->name);
        var stars = pointer_shorthand_spelling(depth, outer_unsafe);
        var q     = ("?") if (nullable) else ("");
        var msg: string = "";
        if depth == 0 {
            msg = f"'{nm}' is nullable; write '{nm}?' so it reads as one";
        } else if nullable {
            msg = f"'{nm}' is a nullable pointer; write '{stars}{nm}?' so it reads as one";
        } else {
            msg = f"'{nm}' is a pointer; write '{stars}{nm}\x27";
        }
        var b = self.sc->diag->report(DiagID::SC001W, v->name.range.start, msg);
        b.first(v->name.range);
        b.second(v->init->range, f"this has type '{self._tu.str(c)}\x27");
        if depth > 0 { b.insert(v->name.range.start, stars, f"mark '{nm}' a pointer"); }
        if nullable  { b.insert(v->name.range.end, q, f"mark '{nm}' nullable"); }
        b.emit();
    }
}
