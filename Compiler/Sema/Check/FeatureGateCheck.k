/// --- The Kairo Project ---------------- Sema/Check/FeatureGateCheck.k --- ///
///
///   \brief Reports constructs that type-check but have no lowering yet,
///          as one error each: "<construct> is not yet supported" (SC116E).
///
///   \detail
///     A lowering pass has no diagnostics of its own: by the time it runs,
///     every rejection has been made, and what it cannot render it ICEs on.
///     That is right for an invariant and wrong for a feature that is
///     simply unfinished, because lowering also runs under
///     --type-check-only and a well-typed program then aborts the compiler.
///     This pass is where "unfinished" is said to the user. An error here
///     stops the schedule before the lowerings, so the ICE in the lowering
///     stays an invariant: reaching it means this gate has a hole.
///
///     Gated:
///       - `for x in e` where X classified `e` as Vector, Set, Map or
///         String (RangedForStmt::iter_kind). IterLowering renders the
///         other kinds.
///       - `label!` / `jump!` in user code: EmitIR renders them (they are the
///         lowerings' labels and gotos), but nothing yet proves a user jump
///         crosses no initialization, which C++ rejects and Kairo must
///         report first.
///       - a non-generic ADT enum one of whose lifecycle facts is Unknown (a
///         payload that is an instance of a generic record reads its
///         pattern's facts until they are computed per instance):
///         EnumLayoutLowering picks its special members from those facts.
///         Reported at the enum, with a note at the payload field that left
///         the fact open.
///       - an initializer on an eval array-typed field.
///         FieldInitLowering turns every other one into a C++ default member
///         initializer (or, for a static or eval field, the initializer of
///         its out-of-line definition), an array's one thunk per leaf
///         element; an eval field's constexpr definition is written after a
///         single consteval thunk, so an eval array keeps its initializer
///         and codegen would ICE on it.
///       - a generic record's field default that reads another field.
///         InitCheck reports it (SC116E too): it is the pass that walks what
///         a default reads.
///       - `var {a, b} = s`, destructuring a struct by field name.
///         TupleLowering renders the positional form only; a struct's
///         reaching EmitIR is its ICE.
///       - an attribute applied to an expression (`@align(16) x`,
///         AttributedExpr): it parses, but no attribute has an expression
///         meaning yet. X leaves the node and its operand untyped. The
///         exception is `@create` / `@destroy` in their call shapes, which
///         AllocSugarDesugar rewrote to alloc.k calls before N; one left
///         here (`@create Point{ x: 1 }`) is gated like any other.
///       - an `eval for` directly in a module or class body
///         (EvalBlockDecl::stmt): it parses, but nothing unrolls it there.
///         (An `eval if` there is folded away by EvalIfFolding.)
///       - a generic closure, `fn <T>(x: T) -> T { ... }`. X types neither
///         its parameters (no canonical for `T`) nor a call of it, so there
///         is no signature for EmitIR to spell; a C++ generic lambda is the
///         target once both are typed.
///       - a `fn`, class, struct, union or enum declared in a body that
///         names a generic parameter of a declaration around it (the
///         function's `T`, or its class's). Codegen emits a local
///         declaration at namespace scope (CXXSpell::is_hoisted_local),
///         where that parameter is not in scope; it would have to become a
///         template over it, and every use in the body pass it. One that
///         names no outer parameter -- generic in its own right or not --
///         is emitted, in a generic function as anywhere else.
///       - an `extend` in a body: nothing emits one there.
///
///     Reads the same guard IterLowering does: a poisoned or untyped
///     iterable is already diagnosed or dependent, and is not reported.
///
///     A gate is removed in the commit that lands its lowering.
///
///   Phase: CHECKS (last; needs X's iter_kind)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import AST::DeclFacts::{
    decl_generic_params,
    decl_is_instance,
    decl_name_tok,
}
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,  EnumDecl,  EvalBlockDecl, ExtensionDecl, FieldDecl, FunctionDecl, GenericParamDecl,
    StructDecl, UnionDecl,
}
import AST::Node::Expressions::{
    AttributedExpr,
    ClosureExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    ConditionalStmt, DeclStmt,          DestructureKind,    DestructuringDeclStmt, EvalBlockStmt,
    IterKind,        JumpIntrinsicStmt, LabelIntrinsicStmt, RangedForStmt,
}
import AST::Node::Types::{
    FixedArrayType,
    GenericParamType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::CallConvCheck::call_conv_of_attr
import Sema::Check::ClassLifecycle::{
    lifecycle_of,
    lifecycle_open,
}
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil

/// The first generic parameter \p local names that belongs to a declaration
/// AROUND it, not to \p local or to anything declared in it. Types (a
/// written `T`, `*T`, `Box<T>`: every node the walk reaches, by its
/// canonical) and value parameters (a bare `N`) both count.
pub class OuterGenericScan derives RecursiveASTVisitor<OuterGenericScan> {
    pub var local: unsafe *Decl             = &null
    pub var hit:   unsafe *GenericParamDecl = &null

    fn OuterGenericScan(self) { }

    /// \p owner is \p local itself or declared somewhere inside it.
    priv fn _inside(self, owner: unsafe *Decl) -> bool {
        var unsafe *d = owner
        while d != &null {
            if d == self.local {
                return true
            }

            var unsafe *dc = d->semantic_dc
            if dc == &null {
                return false
            }

            d = dc->dc_owner
        }

        return false
    }

    priv fn _check(self, gp: unsafe *GenericParamDecl) {
        if gp == &null || self.hit != &null {
            return
        }

        if self._inside(gp->owner) {
            return
        }

        self.hit = gp
    }

    fn visit_type(self, t: unsafe *Type) -> bool {
        if t == &null || self.hit != &null {
            return true
        }

        var unsafe *c = if (t->canonical != &null) => (t->canonical) else => t
        var unsafe *g = dyn_cast<GenericParamType>(c)
        if g == &null || g->owner == &null {
            return true
        }

        var ps = decl_generic_params(g->owner)
        var i  = (g->param_index as usize)
        if i < ps.size() {
            self._check(ps[i])
        }

        return true
    }

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if n != &null && n->resolved_decl != &null {
            self._check(dyn_cast<GenericParamDecl>(n->resolved_decl))
        }

        return true
    }
}

pub class FeatureGateCheck derives RecursiveASTVisitor<FeatureGateCheck> {
    pub var sc: unsafe *SemaContext

    fn FeatureGateCheck(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
    }

    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        if n->iterable == &null {
            return true
        }

        if n->iterable->is_poisoned() || n->iterable->type_ == &null {
            return true
        }

        // IterLowering counts an array by its extent, which for `[T; N]` over
        // a generic value parameter is the parameter (Compiler/Spec/Eval.md#generic-value-parameters).
        var unsafe *at = canon_unqual(n->iterable->type_)
        if at != &null
            && isa<FixedArrayType>(at)
            && cast<FixedArrayType>(at)->extent_param != &null {
            self._gate(
                n->iterable->range,
                "iterating an array whose length is a generic value parameter",
            )

            return true
        }

        var what = ""
        match n->iter_kind {
            case IterKind::Vector {
                what = "iterating a vector"
            } case IterKind::Set {
                what = "iterating a set"
            } case IterKind::Map {
                what = "iterating a map"
            } case IterKind::String {
                what = "iterating a string"
            } default {
                return true
            }
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            n->iterable->range.start,
            f"{what} is not yet supported",
        )

        b.first(n->iterable->range)
        b.emit()
        return true
    }

    fn visit_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> bool {
        if n->kind_ == DestructureKind::Struct {
            self._gate(n->range, "destructuring a struct by field name")
        }

        return true
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        if n->generic_params.size() > 0 {
            self._gate(SourceRange::from_bounds(n->range.start, 2 as u32), "a generic closure")
        }

        return true
    }

    fn visit_attributed_expr(self, n: *AttributedExpr) -> bool {
        var nm = self.sc->ctx->get_spelling(n->name)
        // A calling convention on a closure is an error of its own, with
        // its reason (CallConvCheck), not a feature still to come.
        if n->operand != &null && isa<ClosureExpr>(n->operand) && call_conv_of_attr(nm) != 0 {
            return true
        }

        self._gate(
            SourceRange::from_bounds(n->range.start, 1 as u32) | n->name.range,
            f"the expression attribute '@{nm}'",
        )

        return true
    }

    /// An `eval for` directly in a module or class body parses
    /// (EvalBlockDecl::stmt), but nothing unrolls it into declarations:
    /// nothing would emit it. Reported at `eval for`; the statement's
    /// contents are still resolved and typed. An `eval if` there never gets
    /// here: EvalIfFolding replaced its carrier by the taken declarations.
    fn visit_eval_block_decl(self, n: *EvalBlockDecl) -> bool {
        if n->stmt == &null {
            return true
        }

        var what = "an 'eval for'"
        if isa<ConditionalStmt>(n->stmt) {
            what = "an 'eval if'"
        }

        self._gate(
            SourceRange::from_bounds(n->range.start, 4 as u32),
            f"{what} in a module or class body",
        )

        return true
    }

    /// `eval { ... }` in a function body: no meaning is built for it (a
    /// module or class body's eval block holds declarations, which are
    /// emitted as any others).
    fn visit_eval_block_stmt(self, n: *EvalBlockStmt) -> bool {
        self._gate(
            SourceRange::from_bounds(n->range.start, 4 as u32),
            "an 'eval' block in a function body",
        )

        return true
    }

    fn visit_label_intrinsic_stmt(self, n: *LabelIntrinsicStmt) -> bool {
        self._gate(n->range, "'label!'")
        return true
    }

    fn visit_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> bool {
        self._gate(n->range, "'jump!'")
        return true
    }

    /// A non-generic ADT has no flags for clang to pick its special members
    /// by: EnumLayoutLowering picks one form of each from its lifecycle
    /// facts, and ICEs when one of them is Unknown. A generic ADT leaves the
    /// choice to clang and is never reported. Asked once per entity, as the
    /// lowering builds once: an instance shares its pattern's record, and a
    /// redeclaration is its representative's.
    fn visit_enum_decl(self, n: *EnumDecl) -> bool {
        if !n->is_adt && !n->is_poisoned() && n->generic_params.size() > 0 {
            self._generic_plain_enum(n)
            return true
        }

        if !n->is_adt || n->is_poisoned() || n->generic_params.size() > 0 {
            return true
        }

        var unsafe *d = unsafe (n as unsafe *Decl)
        if decl_is_instance(d) || NameLookup::representative(d) != d {
            return true
        }

        var unsafe *lc = lifecycle_of(self.sc)
        if !lifecycle_open(lc->facts_of(d)) {
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            n->name.range.start,
            "an enum whose payload's lifecycle is not known until instantiation is not yet supported",
        )

        b.first(n->name.range)
        // The first payload field whose own facts are open: the generic
        // instance the enum's copy, move and destruction wait on.
        var tu    = TypeUtil(self.sc)
        var noted = false
        for var i: usize = 0; i < n->variants.size(); ++i {
            if noted {
                break
            }

            var unsafe *v = n->variants[i]
            if v == &null {
                continue
            }

            for var j: usize = 0; j < v->payload.size(); ++j {
                var unsafe *fd = v->payload[j]
                if fd == &null || fd->type_ == &null || fd->type_->canonical == &null {
                    continue
                }

                var pf = lc->facts_of_type(fd->type_->canonical)
                if !lifecycle_open(unsafe &pf) {
                    continue
                }

                var fname = self.sc->ctx->get_spelling(fd->name)
                var vname = self.sc->ctx->get_spelling(v->name)
                var tn    = tu.str(fd->type_->canonical)
                b.note(
                    DiagCode(DiagID::SC116N),
                    fd->range.start,
                    f"'{fname}' of variant '{vname}' has type '{tn}', whose copy, move and destruction are not known until instantiation",
                )->first(fd->range)
                noted = true
                break
            }
        }

        b.emit()
        return true
    }

    /// The initializers FieldInitLowering leaves on the field (its file
    /// header, Not lowered). Reported at the initializer, once: an instance
    /// shares its pattern's fields.
    fn visit_field_decl(self, n: unsafe *FieldDecl) -> bool {
        if n->init == &null || n->is_poisoned() || n->init->is_poisoned() || n->type_ == &null {
            return true
        }

        var unsafe *odc   = n->semantic_dc
        var unsafe *owner = if (odc != &null) => (odc->owner_decl()) else => &null
        if owner != &null && decl_is_instance(owner) {
            return true
        }

        // An instance or static array field's list literal is lowered leaf
        // by leaf (FieldInitLowering, Arrays), nested lists included; one
        // that copies an array is the typer's SC083E. What stays is an eval
        // array field: its constexpr definition follows one consteval thunk.
        var unsafe *c = canon_unqual(n->type_->canonical)
        if c == &null || c->kind != TypeKind::FixedArrayType {
            return true
        }

        var tu = TypeUtil(self.sc)
        if tu.array_field_list(n) != &null {
            return true
        }

        if tu.array_init_poisoned(n->init) {
            return true
        }

        var what = "an initializer on an array-typed field that is not a list literal"
        if n->is_eval() {
            what = "an initializer on an eval array-typed field"
        }

        self._gate(n->init->range, what)
        return true
    }

    /// # local declarations

    /// A local declaration that needs a generic parameter of a declaration
    /// around it: the first one it names is reported, at the local's name,
    /// with a note at that parameter.
    fn visit_decl_stmt(self, n: unsafe *DeclStmt) -> bool {
        if n == &null || n->decl == &null || n->decl->is_poisoned() || n->decl->is_implicit {
            return true
        }

        var unsafe *d = n->decl
        if isa<ExtensionDecl>(d) {
            self._gate(d->range, "an 'extend' in a function body")
            return true
        }

        if (!isa<FunctionDecl>(d))
            && (!isa<ClassDecl>(d))
            && (!isa<StructDecl>(d))
            && (!isa<UnionDecl>(d))
            && !isa<EnumDecl>(d) {
            return true
        }

        var scan = OuterGenericScan()
        scan.local = d
        scan.dispatch_decl(d)
        if scan.hit == &null {
            return true
        }

        var unsafe *gp = scan.hit
        var        tu  = TypeUtil(self.sc)
        var        gn  = self.sc->ctx->get_spelling(gp->name)
        var own = if (gp->owner == &null) => ("the declaration around it")
                  else => f"'{tu.decl_name(gp->owner)}'"
        var at = decl_name_tok(d).range
        if !at.is_valid() {
            at = d->range
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            at.start,
            f"'{tu.decl_name(d)}' is declared in a body and uses '{gn}', a generic parameter of {own}; that is not yet supported",
        )

        b.first(at)
        b.note(
            gp->range.start,
            f"'{gn}' is declared here; a local declaration is emitted outside the generic function, where '{gn}' is not in scope -- declare it at file scope with its own '<{gn}>'",
        )

        b.emit()
        return true
    }

    /// `enum <T> Plain { A, B }`: enums-plain.mdx says a plain enum cannot be
    /// generic -- no variant carries a payload for T to type. Not a gate but
    /// the rule, reported here because nothing earlier rejects it: the parser
    /// takes generic parameters on any enum, and without this the C++ was a
    /// `template` head on an `enum class`, which clang refuses (six CL001E
    /// in generated code). Once per declaration: an instance shares its
    /// pattern's, and a redeclaration is its representative's.
    priv fn _generic_plain_enum(self, n: *EnumDecl) {
        var unsafe *d = unsafe (n as unsafe *Decl)
        if decl_is_instance(d) || NameLookup::representative(d) != d {
            return
        }

        var unsafe *first = n->generic_params[0]
        var unsafe *last  = n->generic_params[n->generic_params.size() - 1]
        if first == &null || last == &null {
            return
        }

        var params = SourceRange(first->range.start, last->range.end)
        var nm     = self.sc->ctx->get_spelling(n->name)
        var b = self.sc->diag->report(
            DiagID::SC197E,
            params.start,
            f"plain enum '{nm}' cannot be generic: no variant carries a payload for a type parameter to type",
        )

        b.first(params)
        b.note(
            DiagCode(DiagID::SC197N),
            n->name.range.start,
            "give a variant a payload to make it an ADT enum, or remove the generic parameters",
        )->first(n->name.range)
        b.emit()
    }

    priv fn _gate(self, at: SourceRange, const what: string) {
        var b = self.sc->diag->report(DiagID::SC116E, at.start, f"{what} is not yet supported")
        b.first(at)
        b.emit()
    }
}
