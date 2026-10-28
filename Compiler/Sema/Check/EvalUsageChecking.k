/// --- The Kairo Project ------------------ Sema/Check/EvalUsageChecking.k --- ///
///
///   \brief What an eval context may contain (EVAL.md §5, §6).
///
///   \detail
///     C++ computes every eval value (EVAL.md §0), so a mistake left to it is
///     a clang error on the emitted text. This pass reports the ones Kairo
///     can name first, at the Kairo source.
///
///     `eval for`:
///       - iterates a range whose bounds are eval-able, an eval-able array
///         (an `eval` constant, a list literal of eval-able elements), or a
///         call of an eval generator (`eval fn g() -> yield T`). Anything
///         else is an error; a non-eval generator gets a fix-it adding
///         `eval` to it.
///       - has one binding, no label, and no C-style form;
///       - may `return` a value only of a type the expansion's return slot
///         can default-construct (a scalar, pointer or enum).
///       Inside an `eval fn` an `eval for` is an ordinary loop (IterLowering;
///       the function already runs at compile time), so none of this
///       applies there.
///     An eval generator is called only as an `eval for`'s iterable: it
///     returns a compile-time buffer, not a Yield<T>.
///     A function-body `eval if` EvalIfFolding could not fold is C++ `if
///     constexpr`: its condition must still be eval-able.
///
///     The restriction table (eval.mdx, Restrictions), in an eval CONTEXT --
///     an `eval fn`'s body, an `eval` binding's or field's initializer:
///       - a call only of an `eval fn` / eval constructor / eval operator
///         (fix-it: `eval` on the callee, when it is the user's); this is
///         also what keeps IO out;
///       - no pointer types or operations (`&x`, `*p`, `->`, a pointer
///         parameter);
///       - a vector, set or map value, or an f-string, is SC116E: eval-able
///         by design (EVAL.md §2), with no compile-time C++ form yet. A
///         string literal has one (2a): this pass marks every literal C++
///         reads at compile time (StringLiteralExpr::const_eval), here and
///         in the arguments of an eval call made from run-time code;
///       - no `await`, `spawn`, `thread`, `panic`;
///       - no mutable global, static or thread variable, and no non-eval
///         global at all (a `const` global is initialized at run time);
///         in an initializer outside an eval fn, no run-time local either;
///       - no local of a type with a user-written destructor;
///       - an `eval fn` has no `where` clause (eval.mdx: `requires` only).
///
///     Eval-able: literals; `sizeof` / `alignof` / `typeof`; builtin
///     operators and casts over eval-able operands; an `eval` variable or
///     field; a generic value parameter; an enclosing `eval for`'s binding
///     (a constant in each copy); a call of an `eval fn` with eval-able
///     arguments.
///
///   Phase: CHECKS (after X: reads callee bindings and iter_kind)
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
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Types::*;
import AST::Kind::StmtKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

/// The first `return` with a value in a statement, not counting closures'.
class ReturnFinder derives RecursiveASTVisitor::<ReturnFinder> {
    pub var found: *ReturnStmt = &null;
    fn ReturnFinder(self) { }
    fn visit_return_stmt(self, n: *ReturnStmt) -> bool {
        if (self.found == &null) && (n->value != &null) { self.found = n; }
        return true;
    }
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr { return n; }
}

/// Marks every string literal under an expression as read by C++ at
/// compile time (StringLiteralExpr::const_eval, EVAL.md 2a): the arguments
/// of an eval call made from run-time code, an eval class's field default.
/// A closure's body is its own context.
class ConstEvalStrings derives RecursiveASTVisitor::<ConstEvalStrings> {
    fn ConstEvalStrings(self) { }
    fn visit_string_literal_expr(self, n: *StringLiteralExpr) -> bool {
        if !n->is_format() { n->const_eval = true; }
        return true;
    }
    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr { return n; }
}

/// What one eval item -- an eval fn's body, an eval binding's or eval
/// field's initializer -- needs before C++ can evaluate it (EVAL.md §11):
/// the eval items it reads (each DEFINED first) and the records it lays out
/// or looks into (each COMPLETE first). The Sema side of EmitPlan's early
/// items (EmitPlan::_early), read by EvalUsageChecking::_check_order.
class EvalNeeds derives RecursiveASTVisitor::<EvalNeeds> {
    pub var items: vec::<*Decl>;
    pub var recs:  vec::<*Decl>;
    /// Parallel to recs: where the body needs it, for the note.
    pub var at:    vec::<SourceRange>;
    priv var _tu:  *TypeUtil = &null;

    fn EvalNeeds(self, tu: *TypeUtil) { self._tu = tu; }

    /// \p d named at \p r: an eval item, and a member's owner (C++ looks
    /// into a complete class only).
    fn named(self, d: *Decl, r: SourceRange) {
        if d == &null { return; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) { self.rec(dc->owner_decl(), r); }
        var f = dyn_cast::<FunctionDecl>(d);
        if (f != &null) && f->is_eval() { self._item(d); return; }
        var v = dyn_cast::<VariableDecl>(d);
        if (v != &null) && v->is_eval() && (v->init != &null) && (dc != &null)
            && ((dc->dc_kind == DeclContextKind::TranslationUnit) || (dc->dc_kind == DeclContextKind::Module)) { self._item(d); return; }
        var fd = dyn_cast::<FieldDecl>(d);
        if (fd != &null) && fd->is_eval() && (fd->init != &null) { self._item(d); }
    }

    priv fn _item(self, d: *Decl) {
        for var i: usize = 0; i < self.items.size(); ++i { if self.items[i] == d { return; } }
        self.items.push_back(d);
    }

    /// Record \p d needed complete (its outermost record: a nested one is
    /// defined inside it), once.
    fn rec(self, d0: *Decl, r: SourceRange) {
        if d0 == &null { return; }
        var d = d0;
        if decl_is_instance(d) { d = self._tu->pattern_of(d); }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        while (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) && (dc->owner_decl() != &null) {
            d  = dc->owner_decl();
            dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        }
        if (!isa::<ClassDecl>(d)) && (!isa::<StructDecl>(d)) && (!isa::<UnionDecl>(d)) && (!isa::<EnumDecl>(d)) { return; }
        for var i: usize = 0; i < self.recs.size(); ++i { if self.recs[i] == d { return; } }
        self.recs.push_back(d);
        self.at.push_back(r);
    }

    /// The records \p t holds by value: laid out wherever a value of it is.
    fn rec_type(self, t: *Type, r: SourceRange) {
        if t == &null { return; }
        var c = canon_unqual((t->canonical) if (t->canonical != &null) else (t));
        if c == &null { return; }
        switch c->kind {
            case TypeKind::RecordType {
                var rt = cast::<RecordType>(c);
                self.rec(rt->decl, r);
                for var i: usize = 0; i < rt->args.size(); ++i { self.values(*(rt->args.get(i)), r); }
            }
            case TypeKind::FixedArrayType {
                self.rec_type(cast::<FixedArrayType>(c)->element, r);
                self.values(cast::<FixedArrayType>(c)->extent_param, r);
            }
            case TypeKind::NullableType { self.rec_type(cast::<NullableType>(c)->inner, r); }
            case TypeKind::TypeExpr { self.values(c, r); }
            default { break; }
        }
    }

    /// The eval items computed value \p t names (EVAL.md 0.2): an eval
    /// fn or an eval class's constructor it calls, an eval constant it
    /// reads. A class it constructs is needed complete.
    fn values(self, t: *Type, r: SourceRange) {
        var v = dyn_cast::<TypeExpr>(t);
        if (v == &null) || (!v->is_value) || v->is_exact() { return; }
        if v->vdecl != &null {
            if (v->vop == ValueOp::Call) && (isa::<ClassDecl>(v->vdecl) || isa::<StructDecl>(v->vdecl)) {
                self.rec(v->vdecl, r);
                var ms: *FrozenList::<*FunctionDecl> = &null;
                if isa::<ClassDecl>(v->vdecl) { ms = &(cast::<ClassDecl>(v->vdecl)->methods); } else { ms = &(cast::<StructDecl>(v->vdecl)->methods); }
                for var i: usize = 0; i < ms->size(); ++i {
                    var m = (*ms)[i];
                    if (m != &null) && m->is_eval() { self._item(static_cast::<*Decl>(m)); }
                }
            } else if (v->vop == ValueOp::Call) || (v->vop == ValueOp::Decl) {
                self.named(v->vdecl, r);
            }
        }
        for var i: usize = 0; i < v->vops.size(); ++i { self.values(v->vops[i], r); }
    }

    fn visit_expr(self, e: *Expr) -> bool {
        if e == &null { return true; }
        if e->type_ != &null { self.rec_type(e->type_, e->range); }
        if isa::<NamedIdentExpr>(e) { self.named(cast::<NamedIdentExpr>(e)->resolved_decl, e->range); }
        else if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            for var i: usize = 0; i < ch->steps.size(); ++i {
                var st = ch->steps.get(i);
                if st == &null { continue; }
                var d = st->resolved_decl;
                if (d == &null) && (st->name != &null) { d = st->name->resolved_decl; }
                self.named(d, e->range);
            }
        } else if isa::<CallExpr>(e) {
            self.named(cast::<CallExpr>(e)->ctor_decl, e->range);
        } else if isa::<BinaryOperatorExpr>(e) {
            self.named(cast::<BinaryOperatorExpr>(e)->resolved_op, e->range);
        } else if isa::<UnaryOperatorExpr>(e) {
            self.named(cast::<UnaryOperatorExpr>(e)->resolved_op, e->range);
        } else if isa::<SizeOfExpr>(e) {
            self.rec_type(cast::<SizeOfExpr>(e)->type_arg, e->range);
        } else if isa::<AlignOfExpr>(e) {
            self.rec_type(cast::<AlignOfExpr>(e)->type_arg, e->range);
        }
        return true;
    }

    fn visit_decl(self, d: *Decl) -> bool {
        if d == &null { return true; }
        if isa::<VariableDecl>(d) { self.rec_type(cast::<VariableDecl>(d)->type_, d->range); }
        else if isa::<ParamDecl>(d) {
            var p = cast::<ParamDecl>(d);
            if !p->is_self { self.rec_type(p->type_, d->range); }
        } else if isa::<FunctionDecl>(d) { self.rec_type(cast::<FunctionDecl>(d)->return_type, d->range); }
        return true;
    }

    fn visit_type(self, t: *Type) -> bool {
        if (t != &null) && (t->canonical != &null) { self.values(t->canonical, t->range); }
        return true;
    }
}

class EvalUsageChecking derives RecursiveASTVisitor::<EvalUsageChecking> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;

    /// The function whose body is walked (innermost), or null.
    priv var _fns: vec::<*FunctionDecl>;
    /// Bindings of the `eval for`s around the walk: constants in each copy.
    priv var _ef_binds: vec::<*Decl>;
    /// The iterables of those `eval for`s: the one place an eval generator
    /// may be called.
    priv var _ef_iters: vec::<*Expr>;
    /// `eval for` bodies around the walk (outside an eval fn).
    priv var _ef_depth: u32 = 0;
    /// > 0 inside an eval CONTEXT (file header): an eval fn's body or an
    /// eval initializer. `_ctx_fn` > 0 when one of them is an eval fn's,
    /// where the function's own locals and parameters are compile-time too.
    priv var _ctx:    u32 = 0;
    priv var _ctx_fn: u32 = 0;

    fn EvalUsageChecking(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
    }

    fn run(self) {
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { 0; }
            }
        }
        self._check_order();
    }

    // === scopes =============================================================

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        self._fns.push_back(n);
        var sd = self._ef_depth;
        self._ef_depth = 0;
        self._check_requires(n->requires_clause);
        var ev = n->is_eval() && (!n->is_implicit);
        if ev { self._check_eval_fn(n); self._ctx += 1; self._ctx_fn += 1; }
        var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_function_decl(n);
        if ev { self._ctx -= 1; self._ctx_fn -= 1; }
        self._ef_depth = sd;
        self._fns.pop_back();
        return r;
    }

    /// A generic value parameter's type: an integer (a value argument folds
    /// to one, or is an expression C++ computes, EVAL.md 0.2), or an eval
    /// class, a C++20 class-type parameter, when it is structural (7e).
    /// Anything else (`bool`, a float) is not built.
    fn visit_generic_param_decl(self, n: *GenericParamDecl) -> bool {
        if (!n->is_const_param) || (n->value_type == &null) || (n->value_type->canonical == &null) { return true; }
        var c = canon_unqual(n->value_type->canonical);
        if self.tu.is_integer(c) { return true; }
        // An eval class (EVAL.md 7e): a C++20 class-type template
        // parameter, which C++ allows only for a structural type.
        var rd = self.tu.record_decl(c);
        if (rd != &null) && (isa::<ClassDecl>(rd) || isa::<StructDecl>(rd)) {
            self._check_structural(n, rd);
            return true;
        }
        var b = self.sc->diag->report(DiagID::SC116E, n->value_type->range.start,
            f"a generic value parameter of type '{self.tu.str(c)}' is not yet supported; only an integer type or an eval class is");
        b.first(n->value_type->range);
        b.emit();
        return true;
    }

    /// \p rd as the type of value parameter \p n (EVAL.md 7e, USER): every
    /// field `pub`, none a pointer to mutable memory, every field's type
    /// structural in turn, every constructor `eval`, no destructor written.
    /// C++ compares template arguments of class type member by member, and
    /// only a structural class may be one. The first field (or
    /// constructor) that is not is the error, with a note at it.
    priv fn _check_structural(self, n: *GenericParamDecl, rd: *Decl) {
        var why = "";
        var at: *Decl = &null;
        self._structural(rd, &why, &at, u32(0));
        if why.size() == 0 { return; }
        var tn = self.tu.decl_name(rd);
        var b = self.sc->diag->report(DiagID::SC001E, n->value_type->range.start,
            f"'{tn}' cannot be the type of a generic value parameter: {why}");
        b.first(n->value_type->range);
        if at != &null { b.note(DiagID::SC001N, at->range.start, "declared here").first(at->range); }
        b.emit();
    }

    /// The first reason \p rd is not structural, into \p why / \p at.
    priv fn _structural(self, rd: *Decl, why: *string, at: *(*Decl), depth: u32) {
        if depth > u32(8) { return; }
        var tn = self.tu.decl_name(rd);
        var fields: *FrozenList::<*FieldDecl> = &null;
        var methods: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(rd)       { fields = &(cast::<ClassDecl>(rd)->fields);  methods = &(cast::<ClassDecl>(rd)->methods); }
        else if isa::<StructDecl>(rd) { fields = &(cast::<StructDecl>(rd)->fields); methods = &(cast::<StructDecl>(rd)->methods); }
        else { return; }
        var dt = self._user_dtor(rd);
        if dt != &null {
            (*why) = f"'{tn}' has a destructor";
            (*at) = static_cast::<*Decl>(dt);
            return;
        }
        // The parameter's own class is built at compile time, so its
        // constructors are `eval`; a field's class needs only to be
        // structural (the builtin string's are constexpr).
        var on = tn;
        for var i: usize = 0; (depth == u32(0)) && (i < methods->size()); ++i {
            var m = (*methods)[i];
            if (m == &null) || m->is_operator || m->is_implicit { continue; }
            if self.tu.decl_name(static_cast::<*Decl>(m)) != on { continue; }
            if !m->is_eval() {
                (*why) = f"a constructor of '{tn}' is not 'eval\x27";
                (*at) = static_cast::<*Decl>(m);
                return;
            }
        }
        for var i: usize = 0; i < fields->size(); ++i {
            var f = (*fields)[i];
            if (f == &null) || f->is_static() || f->is_eval() { continue; }
            var fnm = self.sc->ctx->get_spelling(f->name);
            // Unmarked: a struct's field is public, a class's private (as
            // InterfaceEmitter::_access spells them).
            var vis = f->visibility;
            if vis == VisibilityKind::None { vis = (VisibilityKind::Private) if (isa::<ClassDecl>(rd)) else (VisibilityKind::Public); }
            if vis != VisibilityKind::Public {
                (*why) = f"its field '{fnm}' is not 'pub\x27";
                (*at) = static_cast::<*Decl>(f);
                return;
            }
            if f->is_mutable {
                (*why) = f"its field '{fnm}' is 'mutable\x27";
                (*at) = static_cast::<*Decl>(f);
                return;
            }
            if (f->type_ == &null) || (f->type_->canonical == &null) { continue; }
            var ft = canon_unqual(f->type_->canonical);
            var pt = dyn_cast::<PointerType>(ft);
            if (pt != &null) && ((canon_quals(pt->pointee) & QUAL_CONST()) == 0) {
                (*why) = f"its field '{fnm}' points to mutable memory";
                (*at) = static_cast::<*Decl>(f);
                return;
            }
            var frd = self.tu.record_decl(ft);
            if (frd != &null) && (pt == &null) {
                self._structural(frd, why, at, depth + u32(1));
                if why->size() > 0 {
                    var inner = (*why);
                    (*why) = f"its field '{fnm}' is a '{self.tu.decl_name(frd)}\x27, and " + inner;
                    return;
                }
            }
        }
    }

    /// An `eval` binding's initializer is an eval context, and its value is
    /// a constant object: its type has no user-written destructor.
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        if n->is_eval() && (n->type_ != &null) && (n->type_->canonical != &null) {
            var dt = self._user_dtor(self.tu.record_decl(canon_unqual(n->type_->canonical)));
            if dt != &null {
                var nm = self.sc->ctx->get_spelling(n->name);
                var b = self.sc->diag->report(DiagID::SC001E, n->name.range.start,
                    f"'{nm}' is an 'eval' constant of type '{self.tu.str(n->type_->canonical)}', whose destructor is not trivial; a compile-time object is never destroyed");
                b.first(n->name.range);
                b.note(DiagID::SC001N, dt->range.start, "the destructor is declared here").first(dt->range);
                b.emit();
            }
        }
        if n->is_eval() && (n->init == &null) { self._needs_init(n->name, n->range); }
        if n->is_eval() && (n->init != &null) {
            self._ctx += 1;
            var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_variable_decl(n);
            self._ctx -= 1;
            return r;
        }
        if self._ctx_fn > 0 { self._check_local(n); }
        return RecursiveASTVisitor::<EvalUsageChecking>::traverse_variable_decl(n);
    }

    fn traverse_field_decl(self, n: *FieldDecl) -> *FieldDecl {
        if n->is_eval() && (n->init == &null) && (!n->is_implicit) && (n->init_fold == FieldFold::None) { self._needs_init(n->name, n->range); }
        // An eval class's field default runs inside its eval constructor
        // too, at compile time (EVAL.md 7b): its strings are compile-time
        // strings, and the run-time constructors share the same thunk.
        if (!n->is_eval()) && (!n->is_static()) && (n->init != &null) && self._in_eval_class(n) {
            var m = ConstEvalStrings();
            m.dispatch_expr(n->init);
        }
        if n->is_eval() && (n->init != &null) {
            self._ctx += 1;
            var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_field_decl(n);
            self._ctx -= 1;
            return r;
        }
        return RecursiveASTVisitor::<EvalUsageChecking>::traverse_field_decl(n);
    }

    /// `eval e` is an eval context: C++ computes `e` in place.
    fn traverse_eval_expr(self, n: *EvalExpr) -> *EvalExpr {
        self._ctx += 1;
        var r = RecursiveASTVisitor::<EvalUsageChecking>::traverse_eval_expr(n);
        self._ctx -= 1;
        return r;
    }

    /// \p f's record has an eval constructor (an eval class, EVAL.md 7a);
    /// the rule FieldInitLowering::_eval_class makes its defaults' thunks
    /// `constexpr` by.
    priv fn _in_eval_class(self, f: *FieldDecl) -> bool {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        var owner = (dc->owner_decl()) if (dc != &null) else (&null);
        if owner == &null { return false; }
        var ms: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(owner) { ms = &(cast::<ClassDecl>(owner)->methods); }
        else if isa::<StructDecl>(owner) { ms = &(cast::<StructDecl>(owner)->methods); }
        if ms == &null { return false; }
        var on = self.tu.decl_name(owner);
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if (m != &null) && m->is_eval() && (!m->is_operator) && (self.tu.decl_name(static_cast::<*Decl>(m)) == on) { return true; }
        }
        return false;
    }

    /// An `eval` constant is its value: one with none (`eval K: i32`) would
    /// be a zero C++ made up.
    priv fn _needs_init(self, name: Token, at: SourceRange) {
        var nm = self.sc->ctx->get_spelling(name);
        var b = self.sc->diag->report(DiagID::SC001E, name.range.start,
            f"'{nm}' is an 'eval' constant and needs an initializer: its value is computed at compile time");
        b.first(name.range);
        b.emit();
    }

    // === requires ============================================================

    fn visit_class_decl(self, n: *ClassDecl) -> bool { self._check_requires(n->requires_clause); return true; }
    fn visit_struct_decl(self, n: *StructDecl) -> bool { self._check_requires(n->requires_clause); return true; }

    /// A `requires` VALUE predicate (not a `T impl I` / `T derives B`
    /// conjunct) is an eval context: one that reads a run-time value -- a
    /// parameter, a variable -- is requires.mdx's hard error. The predicate
    /// itself is evaluated by C++ (EmitIR's static_assert for a function,
    /// the template head for a record).
    priv fn _check_requires(self, e: *Expr) {
        if (e == &null) || e->is_poisoned() { return; }
        var b = dyn_cast::<BinaryOperatorExpr>(e);
        if (b != &null) && ((b->op_token.kind == TokenKind::OpAmpAmp) || (b->op_token.kind == TokenKind::KwAnd)) {
            self._check_requires(b->lhs);
            self._check_requires(b->rhs);
            return;
        }
        if isa::<ConstraintExpr>(e) { return; }
        var bad = self._first_runtime(e);
        if bad == &null { return; }
        var d = self.sc->diag->report(DiagID::SC001E, e->range.start, "requires expression is not compile-time evaluable");
        var lbl = "depends on a runtime value";
        if isa::<NamedIdentExpr>(bad) { lbl = f"depends on runtime value '{self.sc->ctx->get_spelling(cast::<NamedIdentExpr>(bad)->name)}\x27"; }
        d.first(bad->range, lbl);
        d.note(DiagID::SC001N, e->range.start, "for runtime-conditional dispatch, use 'where\x27").first(e->range);
        d.emit();
    }

    // === the restriction table ==============================================

    /// The signature of an eval fn: no `where`, no pointer parameter.
    priv fn _check_eval_fn(self, n: *FunctionDecl) {
        var nm = self.tu.decl_name(static_cast::<*Decl>(n));
        if n->where_clause != &null {
            var b = self.sc->diag->report(DiagID::SC001E, n->where_clause->range.start,
                f"an 'eval' function cannot have a 'where' clause; bound '{nm}' with 'requires\x27");
            b.first(n->where_clause->range);
            b.emit();
        }
        if (n->return_type != &null) && (n->return_type->canonical != &null) && (!n->is_generator) {
            self._no_eval_form(n->return_type->range, n->return_type->canonical);
        }
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if (p == &null) || p->is_self || (p->type_ == &null) || (p->type_->canonical == &null) { continue; }
            if self._no_eval_form(p->range, p->type_->canonical) { continue; }
            if !isa::<PointerType>(canon_unqual(p->type_->canonical)) { continue; }
            var pn = self.sc->ctx->get_spelling(p->name);
            var b = self.sc->diag->report(DiagID::SC001E, p->range.start,
                f"an 'eval' function cannot take a pointer; '{pn}' is '{self.tu.str(p->type_->canonical)}\x27: there is no addressable memory at compile time");
            b.first(p->range);
            b.emit();
        }
    }

    /// \p t is a collection, which has no compile-time form yet (EVAL.md
    /// 2b): reported at \p at. A string has one (2a).
    priv fn _no_eval_form(self, at: SourceRange, t: *Type) -> bool {
        var what = "";
        if self.tu.is_vector_like(t)      { what = "a vector"; }
        else if self.tu.is_set_like(t)    { what = "a set"; }
        else if self.tu.is_map_like(t)    { what = "a map"; }
        if what.size() == 0 { return false; }
        var b = self.sc->diag->report(DiagID::SC116E, at.start, f"{what} in an eval context is not yet supported");
        b.first(at);
        b.emit();
        return true;
    }

    /// A local of an eval fn: no pointer, no type with a destructor, no
    /// static / thread storage.
    priv fn _check_local(self, n: *VariableDecl) {
        var nm = self.sc->ctx->get_spelling(n->name);
        if n->is_static() || n->is_thread {
            self._err(n->name.range, f"an 'eval' function cannot declare a static or thread variable; '{nm}' outlives the evaluation");
            return;
        }
        if (n->type_ == &null) || (n->type_->canonical == &null) { return; }
        var c = canon_unqual(n->type_->canonical);
        if isa::<PointerType>(c) {
            self._err(n->name.range, f"an 'eval' function cannot hold a pointer; '{nm}' is '{self.tu.str(c)}\x27: there is no addressable memory at compile time");
            return;
        }
        var d = self.tu.record_decl(c);
        var dtor = self._user_dtor(d);
        if dtor != &null {
            var b = self.sc->diag->report(DiagID::SC001E, n->name.range.start,
                f"'{nm}' is a '{self.tu.str(c)}', whose destructor is not trivial; it cannot live in an 'eval' function");
            b.first(n->name.range);
            b.note(DiagID::SC001N, dtor->range.start, "the destructor is declared here").first(dtor->range);
            b.emit();
        }
    }

    /// \p d's user-written `op delete`, or null.
    priv fn _user_dtor(self, d: *Decl) -> *FunctionDecl {
        if d == &null { return &null; }
        var ms: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(d) { ms = &(cast::<ClassDecl>(d)->methods); }
        else if isa::<StructDecl>(d) { ms = &(cast::<StructDecl>(d)->methods); }
        if ms == &null { return &null; }
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if (m == &null) || (!m->is_operator) || (m->op_token.size() == 0) { continue; }
            if m->op_token[0].kind != TokenKind::KwDelete { continue; }
            if m->body_kind == FnBodyKind::Default { continue; }
            return m;
        }
        return &null;
    }

    /// A call in an eval context: of an eval fn, an eval constructor, or a
    /// struct's implicit one.
    priv fn _check_ctx_call(self, n: *CallExpr) {
        var f = self._callee_fn(n);
        if f == &null { return; }      // a constructor no one wrote, or untyped: nothing to say.
        if f->is_eval() { return; }
        var nm  = self.tu.decl_name(static_cast::<*Decl>(f));
        var what = ("constructor") if (n->ctor_decl != &null) else ("function");
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"an eval context can call only 'eval' functions; '{nm}' is a {what} that is not 'eval\x27");
        b.first(n->range);
        b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(f->range);
        if (!self._foreign(static_cast::<*Decl>(f))) && (!f->is_implicit) && (f->body_kind == FnBodyKind::Block) {
            b.insert(f->range.start, "eval ", f"make '{nm}' an 'eval fn\x27");
        }
        b.emit();
    }

    /// A name in an eval context: a compile-time value (_eval_decl), or,
    /// in an eval fn, one of its locals or parameters.
    priv fn _check_ctx_name(self, e: *Expr, d: *Decl) {
        if d == &null { return; }
        if self._eval_decl(d) { return; }
        // An eval fn's parameter is a compile-time value; any other is not.
        if isa::<ParamDecl>(d) && (self._ctx_fn > 0) { return; }
        if isa::<ParamDecl>(d) {
            var pn = self.tu.decl_name(d);
            var pb = self.sc->diag->report(DiagID::SC001E, e->range.start,
                f"an eval context reads only compile-time values; '{pn}' is a run-time parameter");
            pb.first(e->range);
            pb.note(DiagID::SC001N, d->range.start, f"'{pn}' is declared here").first(d->range);
            pb.emit();
            return;
        }
        var vd = dyn_cast::<VariableDecl>(d);
        var fd = dyn_cast::<FieldDecl>(d);
        if (vd == &null) && (fd == &null) { return; }
        var global = (fd != &null) && fd->is_static();
        if vd != &null { global = self._is_global(vd); }
        if (!global) && (self._ctx_fn > 0) { return; }   // the eval fn's own local.
        if (fd != &null) && (!global) { return; }        // a member through `self` of an eval method.
        var nm = self.tu.decl_name(d);
        var why = ("a run-time local") if (!global) else ("a global, static or thread variable that is not 'eval\x27");
        var b = self.sc->diag->report(DiagID::SC001E, e->range.start,
            f"an eval context reads only compile-time values; '{nm}' is {why}");
        b.first(e->range);
        b.note(DiagID::SC001N, d->range.start, f"'{nm}' is declared here").first(d->range);
        if (vd != &null) && (vd->storage == StorageClass::Const) && (!vd->const_binding) && vd->storage_kw.is_valid() && global {
            b.fix(vd->storage_kw, "eval", f"declare '{nm}' as 'eval\x27");
        }
        b.emit();
    }

    priv fn _is_global(self, vd: *VariableDecl) -> bool {
        if vd->is_static() || vd->is_thread { return true; }
        var dc = reinterpret_cast::<*DeclContext>(vd->semantic_dc);
        if dc == &null { return false; }
        if dc->is_translation_unit() { return true; }
        var o = dc->owner_decl();
        return (o != &null) && isa::<ModuleDecl>(o);
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self._ctx == 0 { return true; }
        self._check_ctx_name(static_cast::<*Expr>(n), n->resolved_decl);
        return true;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if self._ctx == 0 { return true; }
        var k = n->op_token.kind;
        if (n->resolved_op == &null) && ((k == TokenKind::OpAmp) || (k == TokenKind::OpStar)) {
            self._err(n->range, "an eval context cannot take an address or dereference a pointer; there is no addressable memory at compile time");
            return true;
        }
        if (n->resolved_op != &null) && isa::<FunctionDecl>(n->resolved_op) && (!cast::<FunctionDecl>(n->resolved_op)->is_eval()) {
            self._op_not_eval(n->range, cast::<FunctionDecl>(n->resolved_op));
        }
        return true;
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if self._ctx == 0 { return true; }
        if (n->resolved_op != &null) && isa::<FunctionDecl>(n->resolved_op) && (!cast::<FunctionDecl>(n->resolved_op)->is_eval()) {
            self._op_not_eval(n->range, cast::<FunctionDecl>(n->resolved_op));
        }
        return true;
    }

    priv fn _op_not_eval(self, at: SourceRange, f: *FunctionDecl) {
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            "an eval context can use only 'eval' operators; this one is not 'eval\x27");
        b.first(at);
        b.note(DiagID::SC001N, f->range.start, "the operator is declared here").first(f->range);
        if !self._foreign(static_cast::<*Decl>(f)) { b.insert(f->range.start, "eval ", "make it 'eval\x27"); }
        b.emit();
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if self._ctx == 0 { return true; }
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if (st->access_kind == ChainExpr::AccessKind::Arrow) || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) {
                self._err(n->range, "an eval context cannot follow a pointer ('->'); there is no addressable memory at compile time");
                return true;
            }
        }
        var d: *Decl = &null;
        if n->steps.size() > 0 {
            var st = n->steps.get(n->steps.size() - 1);
            d = st->resolved_decl;
        }
        if (d != &null) && (isa::<VariableDecl>(d) || (isa::<FieldDecl>(d) && cast::<FieldDecl>(d)->is_static())) {
            self._check_ctx_name(static_cast::<*Expr>(n), d);
        }
        return true;
    }

    fn visit_expr(self, e: *Expr) -> bool {
        if (self._ctx == 0) || (e->type_ == &null) { return true; }
        // A string literal is a compile-time string (EVAL.md 2a): its bytes
        // are a constant array and the literal constructor is constexpr. An
        // f-string is not: it formats into a heap buffer.
        var sl = dyn_cast::<StringLiteralExpr>(e);
        if (sl != &null) && sl->is_format() {
            var fb = self.sc->diag->report(DiagID::SC116E, e->range.start, "an f-string in an eval context is not yet supported");
            fb.first(e->range);
            fb.emit();
            return false;
        }
        if sl != &null { sl->const_eval = true; return true; }
        // The collection literals are eval-able by design (EVAL.md §2) but
        // have no compile-time C++ form yet (2b): vectors, sets and maps do
        // not even compile at run time. Reported once, at the outermost one.
        var t = e->type_;
        var what = "";
        if self.tu.is_vector_like(t)      { what = "a vector"; }
        else if self.tu.is_set_like(t)    { what = "a set"; }
        else if self.tu.is_map_like(t)    { what = "a map"; }
        if what.size() == 0 { return true; }
        var b = self.sc->diag->report(DiagID::SC116E, e->range.start, f"{what} in an eval context is not yet supported");
        b.first(e->range);
        b.emit();
        return false;
    }

    fn visit_await_expr(self, n: *AwaitExpr) -> bool {
        if self._ctx > 0 { self._err(n->range, "an eval context cannot 'await'; there is no scheduler at compile time"); }
        return true;
    }

    fn visit_spawn_expr(self, n: *SpawnExpr) -> bool {
        if self._ctx > 0 { self._err(n->range, "an eval context cannot 'spawn'; there is no scheduler at compile time"); }
        return true;
    }

    fn visit_panic_stmt(self, n: *PanicStmt) -> bool {
        if self._ctx > 0 { self._err(n->range, "an eval context cannot 'panic'; there is no error handler at compile time"); }
        return true;
    }

    priv fn _in_eval_fn(self) -> bool {
        return (self._fns.size() > 0) && self._fns[self._fns.size() - 1]->is_eval();
    }

    // === eval for ===========================================================

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        if (!n->is_eval) || self._in_eval_fn() {
            return RecursiveASTVisitor::<EvalUsageChecking>::traverse_ranged_for_stmt(n);
        }
        self._check_eval_for(n);
        if n->iterable != &null {
            self._ef_iters.push_back(n->iterable);
            n->iterable = self.dyn()->dispatch_expr(n->iterable);
            self._ef_iters.pop_back();
        }
        var pushed = false;
        if (n->bindings.size() == 1) && (n->bindings[0].decl != &null) {
            self._ef_binds.push_back(n->bindings[0].decl);
            pushed = true;
        }
        self._ef_depth += 1;
        n->body = self.dyn()->traverse_block(n->body);
        self._ef_depth -= 1;
        if pushed { self._ef_binds.pop_back(); }
        return n;
    }

    fn visit_indexed_for_stmt(self, n: *IndexedForStmt) -> bool {
        if (!n->is_eval) || self._in_eval_fn() { return true; }
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            "an 'eval for' iterates a range, an eval array or an eval generator; the C-style form is not one: write 'eval for i in lo..hi\x27");
        b.first(SourceRange::from_bounds(n->range.start, u32(8)));
        b.emit();
        return true;
    }

    fn visit_labeled_stmt(self, n: *LabeledStmt) -> bool {
        var rf = dyn_cast::<RangedForStmt>(n->inner);
        if (rf == &null) || (!rf->is_eval) || self._in_eval_fn() { return true; }
        var b = self.sc->diag->report(DiagID::SC116E, n->range.start, "a labeled 'eval for' is not yet supported");
        b.first(n->range);
        b.emit();
        return true;
    }

    priv fn _check_eval_for(self, n: *RangedForStmt) {
        if n->bindings.size() != 1 {
            self._err(n->range, "an 'eval for' binds one name; destructure inside the body");
            return;
        }
        self._check_return_slot(n);
        var it = n->iterable;
        if (it == &null) || it->is_poisoned() || (it->type_ == &null) { return; }
        var e = self.tu.strip_parens(it);

        if isa::<RangeExpr>(e) {
            var r = cast::<RangeExpr>(e);
            if (r->begin == &null) || (r->end == &null) {
                self._err(e->range, "an 'eval for' over a range needs both bounds");
                return;
            }
            self._need_eval(r->begin, "the lower bound of an 'eval for' range");
            self._need_eval(r->end, "the upper bound of an 'eval for' range");
            return;
        }

        // An eval generator: a call of an `eval fn ... -> yield T`.
        var call = dyn_cast::<CallExpr>(e);
        if call != &null {
            var f = self._callee_fn(call);
            if (f != &null) && f->is_generator {
                if !f->is_eval() {
                    var nm = self.tu.decl_name(static_cast::<*Decl>(f));
                    var b = self.sc->diag->report(DiagID::SC001E, e->range.start,
                        f"an 'eval for' iterates an eval generator; '{nm}' is not 'eval\x27");
                    b.first(e->range);
                    b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(f->name.range);
                    if !self._foreign(static_cast::<*Decl>(f)) {
                        b.insert(f->range.start, "eval ", f"make '{nm}' an 'eval fn\x27");
                    }
                    b.emit();
                    return;
                }
                for var i: usize = 0; i < call->args.size(); ++i {
                    self._need_eval(call->args[i], "an argument of an 'eval for' generator");
                }
                return;
            }
        }

        // An array: an eval constant, or a list literal of eval-able elements.
        var at = canon_unqual(it->type_);
        if (at != &null) && isa::<FixedArrayType>(at) && (!cast::<FixedArrayType>(at)->is_incomplete) {
            if isa::<ListLiteralExpr>(e) {
                var ll = cast::<ListLiteralExpr>(e);
                for var i: usize = 0; i < ll->elements.size(); ++i {
                    self._need_eval(ll->elements[i], "an element of an 'eval for' array");
                }
                return;
            }
            if self._eval_able(e) { return; }
        }

        var b = self.sc->diag->report(DiagID::SC001E, e->range.start,
            f"an 'eval for' iterates a range with eval bounds, an eval array or an eval generator; this is '{self.tu.str(it->type_)}\x27");
        b.first(e->range);
        var pv = self._plain_var(e);
        if pv != &null {
            var pn = self.sc->ctx->get_spelling(pv->name);
            b.note(DiagID::SC001N, pv->name.range.start, f"'{pn}' is declared here, not as 'eval\x27").first(pv->name.range);
        }
        b.emit();
    }

    /// A `return` with a value inside an `eval for` goes through a slot the
    /// expansion default-constructs (EmitIR::_eval_for).
    priv fn _check_return_slot(self, n: *RangedForStmt) {
        if self._fns.size() == 0 { return; }
        var f = self._fns[self._fns.size() - 1];
        if (f->return_type == &null) || (f->return_type->canonical == &null) { return; }
        var c = canon_unqual(f->return_type->canonical);
        if (c == &null) || isa::<BuiltinType>(c) || isa::<PointerType>(c) || isa::<GenericParamType>(c) { return; }
        var rd = (cast::<RecordType>(c)->decl) if (isa::<RecordType>(c)) else (&null);
        if (rd != &null) && isa::<EnumDecl>(rd) && (!cast::<EnumDecl>(rd)->is_adt) { return; }
        var rs = ReturnFinder();
        rs.dispatch_stmt(static_cast::<*Stmt>(n->body));
        if rs.found == &null { return; }
        var b = self.sc->diag->report(DiagID::SC116E, rs.found->range.start,
            f"returning a '{self.tu.str(c)}' from inside an 'eval for' is not yet supported; return it after the loop");
        b.first(rs.found->range);
        b.emit();
    }

    // === eval generators ====================================================

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if self._ctx > 0 { self._check_ctx_call(n); }
        var f = self._callee_fn(n);
        // An eval call from run-time code is an immediate invocation: C++
        // evaluates its arguments at compile time, strings included.
        if (self._ctx == 0) && (f != &null) && f->is_eval() {
            var m = ConstEvalStrings();
            for var i: usize = 0; i < n->args.size(); ++i { m.dispatch_expr(n->args[i]); }
        }
        if (f == &null) || (!f->is_eval()) || (!f->is_generator) { return true; }
        var e = static_cast::<*Expr>(n);
        for var i: usize = 0; i < self._ef_iters.size(); ++i {
            if self.tu.strip_parens(self._ef_iters[i]) == e { return true; }
        }
        var nm = self.tu.decl_name(static_cast::<*Decl>(f));
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"'{nm}' is an eval generator; it runs at compile time and can only be iterated by an 'eval for\x27");
        b.first(n->range);
        b.note(DiagID::SC001N, f->range.start, f"'{nm}' is declared here").first(f->name.range);
        b.emit();
        return true;
    }

    // === eval if (a body's, left as `if constexpr`) ============================

    fn visit_conditional_stmt(self, n: *ConditionalStmt) -> bool {
        if (!n->is_eval) || self._in_eval_fn() { return true; }
        if (n->cond == &null) || n->cond->is_poisoned() { return true; }
        self._need_eval(n->cond, "the condition of an 'eval if\x27");
        return true;
    }

    // === eval-able ==========================================================

    /// \p e must be eval-able (file header); reported at its first part that
    /// is not, as \p what.
    priv fn _need_eval(self, e: *Expr, what: string) {
        if (e == &null) || e->is_poisoned() { return; }
        var bad = self._first_runtime(e);
        if bad == &null { return; }
        var b = self.sc->diag->report(DiagID::SC001E, bad->range.start,
            f"{what} must be evaluable at compile time; this is a run-time value");
        b.first(bad->range);
        var pv = self._plain_var(bad);
        if pv != &null {
            var pn = self.sc->ctx->get_spelling(pv->name);
            b.note(DiagID::SC001N, pv->name.range.start, f"'{pn}' is declared here, not as 'eval\x27").first(pv->name.range);
        }
        b.emit();
    }

    priv fn _eval_able(self, e: *Expr) -> bool { return self._first_runtime(e) == &null; }

    /// The first sub-expression of \p e0 that is not eval-able, or null.
    priv fn _first_runtime(self, e0: *Expr) -> *Expr {
        if e0 == &null { return &null; }
        var e = self.tu.strip_parens(e0);
        if e == &null { return &null; }
        if isa::<IntegerLiteralExpr>(e) || isa::<FloatingLiteralExpr>(e) || isa::<BooleanLiteralExpr>(e)
        || isa::<CharacterLiteralExpr>(e) || isa::<StringLiteralExpr>(e) || isa::<NullLiteralExpr>(e) { return &null; }
        if isa::<SizeOfExpr>(e) || isa::<AlignOfExpr>(e) || isa::<TypeOfExpr>(e) { return &null; }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if u->resolved_op != &null { return e; }
            var k = u->op_token.kind;
            if (k == TokenKind::OpAmp) || (k == TokenKind::OpStar) { return e; }   // pointers: no address at compile time.
            return self._first_runtime(u->operand);
        }
        if isa::<BinaryOperatorExpr>(e) {
            var b = cast::<BinaryOperatorExpr>(e);
            if b->resolved_op != &null { return e; }
            var l = self._first_runtime(b->lhs);
            if l != &null { return l; }
            return self._first_runtime(b->rhs);
        }
        if isa::<TypeCastExpr>(e) {
            var c = cast::<TypeCastExpr>(e);
            if (c->resolved_op != &null) || (c->resolved_ctor != &null) { return e; }
            return self._first_runtime(c->operand);
        }
        if isa::<ListLiteralExpr>(e) {
            var ll = cast::<ListLiteralExpr>(e);
            for var i: usize = 0; i < ll->elements.size(); ++i {
                var x = self._first_runtime(ll->elements[i]);
                if x != &null { return x; }
            }
            return &null;
        }
        if isa::<NamedIdentExpr>(e) { return (&null) if (self._eval_decl(cast::<NamedIdentExpr>(e)->resolved_decl)) else (e); }
        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() == 0 { return e; }
            var st = ch->steps.get(ch->steps.size() - 1);
            var d = (st->name->resolved_decl) if (st->name != &null) else (&null);
            if d == &null { d = st->resolved_decl; }
            return (&null) if (self._eval_decl(d)) else (e);
        }
        if isa::<CallExpr>(e) {
            var c = cast::<CallExpr>(e);
            var f = self._callee_fn(c);
            if (f == &null) || (!f->is_eval()) { return e; }
            for var i: usize = 0; i < c->args.size(); ++i {
                var x = self._first_runtime(c->args[i]);
                if x != &null { return x; }
            }
            return &null;
        }
        return e;
    }

    /// A name that is a compile-time constant here.
    priv fn _eval_decl(self, d: *Decl) -> bool {
        if d == &null { return false; }
        var vd = dyn_cast::<VariableDecl>(d);
        if vd != &null {
            if vd->is_eval() { return true; }
            for var i: usize = 0; i < self._ef_binds.size(); ++i { if self._ef_binds[i] == d { return true; } }
            return false;
        }
        var fd = dyn_cast::<FieldDecl>(d);
        if fd != &null { return fd->is_eval(); }
        var gp = dyn_cast::<GenericParamDecl>(d);
        if gp != &null { return gp->is_const_param; }
        if isa::<EnumVariantDecl>(d) { return true; }
        return false;
    }

    // === helpers ============================================================

    /// The function a call selected, or null.
    priv fn _callee_fn(self, c: *CallExpr) -> *FunctionDecl {
        if (c->ctor_decl != &null) && isa::<FunctionDecl>(c->ctor_decl) { return cast::<FunctionDecl>(c->ctor_decl); }
        var e = self.tu.strip_parens(c->callee);
        if e == &null { return &null; }
        var d: *Decl = &null;
        if isa::<NamedIdentExpr>(e) { d = cast::<NamedIdentExpr>(e)->resolved_decl; }
        else if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() > 0 {
                var st = ch->steps.get(ch->steps.size() - 1);
                d = st->resolved_decl;
                if (d == &null) && (st->name != &null) { d = st->name->resolved_decl; }
            }
        }
        return dyn_cast::<FunctionDecl>(d);
    }

    priv fn _foreign(self, d: *Decl) -> bool { return self.tu.is_foreign(d); }

    /// The non-eval variable \p e names, for a note; null if none.
    priv fn _plain_var(self, e: *Expr) -> *VariableDecl {
        if (e == &null) || (!isa::<NamedIdentExpr>(e)) { return &null; }
        return dyn_cast::<VariableDecl>(cast::<NamedIdentExpr>(e)->resolved_decl);
    }

    priv fn _err(self, at: SourceRange, msg: string) {
        var b = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        b.first(at);
        b.emit();
    }

    // === emission order (EVAL.md §11) =======================================
    //
    // A declaration's type may hold a value C++ computes from an eval fn or
    // an eval binding (`[i32; f(3)]`, `Buf<twice(1)>`). EmitPlan defines
    // those items, and what they read, ahead of the declaration (its early
    // items); each needs the records its body lays out complete first. When
    // such a record is the declaration's own -- directly, or through another
    // record that needs it -- no order exists: that is the error here, at
    // the type, rather than a clang error on emitted text or an ordering
    // ICE. So is an eval binding whose value reaches itself through the eval
    // fns and bindings it reads.

    /// Every needs record computed, flattened: for item _nd_key[i], an
    /// item (kind 0) or a record (kind 1) _nd_val[i], needed at _nd_at[i].
    priv var _nd_done: vec::<*Decl>;
    priv var _nd_key:  vec::<*Decl>;
    priv var _nd_kind: vec::<u8>;
    priv var _nd_val:  vec::<*Decl>;
    priv var _nd_at:   vec::<SourceRange>;

    priv fn _needs_of(self, item: *Decl) {
        for var i: usize = 0; i < self._nd_done.size(); ++i { if self._nd_done[i] == item { return; } }
        self._nd_done.push_back(item);
        var n = EvalNeeds(&(self.tu));
        var dc = reinterpret_cast::<*DeclContext>(item->semantic_dc);
        if (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) { n.rec(dc->owner_decl(), item->range); }
        var f = dyn_cast::<FunctionDecl>(item);
        if f != &null {
            var def = f;
            if !def->has_body() { def = f->definition(); }
            if def != &null { n.dispatch_decl(static_cast::<*Decl>(def)); }
        }
        var v = dyn_cast::<VariableDecl>(item);
        if v != &null {
            n.rec_type(v->type_, v->range);
            if v->init != &null { n.dispatch_expr(v->init); }
        }
        var fd = dyn_cast::<FieldDecl>(item);
        if fd != &null {
            n.rec_type(fd->type_, fd->range);
            if fd->init != &null { n.dispatch_expr(fd->init); }
        }
        for var i: usize = 0; i < n.items.size(); ++i {
            if n.items[i] == item { continue; }
            self._nd_key.push_back(item); self._nd_kind.push_back(u8(0)); self._nd_val.push_back(n.items[i]); self._nd_at.push_back(item->range);
        }
        for var i: usize = 0; i < n.recs.size(); ++i {
            self._nd_key.push_back(item); self._nd_kind.push_back(u8(1)); self._nd_val.push_back(n.recs[i]); self._nd_at.push_back(n.at[i]);
        }
    }

    /// \p seeds and every item they read, transitively, into \p out.
    priv fn _closure(self, seeds: *vec::<*Decl>, out: *vec::<*Decl>) {
        for var i: usize = 0; i < seeds->size(); ++i { self._add_once(out, (*seeds)[i]); }
        for var k: usize = 0; k < out->size(); ++k {
            var it = (*out)[k];
            self._needs_of(it);
            for var i: usize = 0; i < self._nd_key.size(); ++i {
                if (self._nd_key[i] == it) && (self._nd_kind[i] == u8(0)) { self._add_once(out, self._nd_val[i]); }
            }
        }
    }

    priv fn _add_once(self, v: *vec::<*Decl>, d: *Decl) {
        for var i: usize = 0; i < v->size(); ++i { if (*v)[i] == d { return; } }
        v->push_back(d);
    }

    /// The items computed values in \p t name (a declaration's type).
    priv fn _type_items(self, t: *Type, out: *vec::<*Decl>) {
        var n = EvalNeeds(&(self.tu));
        n.rec_type(t, SourceRange::invalid());
        if (t != &null) && (t->canonical != &null) { n.values(t->canonical, SourceRange::invalid()); }
        for var i: usize = 0; i < n.items.size(); ++i { self._add_once(out, n.items[i]); }
    }

    /// The types written in \p r's own definition: fields, bases, method
    /// signatures (C++ reads all of them inside the class body).
    priv fn _member_types(self, r: *Decl, out: *vec::<*Type>, spots: *vec::<SourceRange>) {
        var fields: *FrozenList::<*FieldDecl> = &null;
        var methods: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(r) {
            var c = cast::<ClassDecl>(r);
            fields = &(c->fields); methods = &(c->methods);
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var e = c->derives_list.get(i);
                if (e != &null) && (e->base != &null) { out->push_back(e->base); spots->push_back(e->base->range); }
            }
        } else if isa::<StructDecl>(r) { fields = &(cast::<StructDecl>(r)->fields); methods = &(cast::<StructDecl>(r)->methods); }
        else if isa::<UnionDecl>(r)  { fields = &(cast::<UnionDecl>(r)->fields);  methods = &(cast::<UnionDecl>(r)->methods); }
        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var f = (*fields)[i];
                if (f == &null) || (f->type_ == &null) { continue; }
                out->push_back(f->type_); spots->push_back(f->type_->range);
            }
        }
        if methods != &null {
            for var i: usize = 0; i < methods->size(); ++i {
                var m = (*methods)[i];
                if m == &null { continue; }
                for var p: usize = 0; p < m->params.size(); ++p {
                    var pd = m->params[p];
                    if (pd == &null) || pd->is_self || (pd->type_ == &null) { continue; }
                    out->push_back(pd->type_); spots->push_back(pd->type_->range);
                }
                if m->return_type != &null { out->push_back(m->return_type); spots->push_back(m->return_type->range); }
            }
        }
    }

    /// The records \p r needs complete before its definition: by-value
    /// fields and bases, and what the items its types name need.
    priv fn _rec_edges(self, r: *Decl, out: *vec::<*Decl>) {
        var ts = vec::<*Type>();
        var ws = vec::<SourceRange>();
        self._member_types(r, &ts, &ws);
        var seeds = vec::<*Decl>();
        for var i: usize = 0; i < ts.size(); ++i { self._type_items(ts[i], &seeds); }
        // Method signatures name their types; only fields and bases lay
        // them out. Close enough: a by-value cycle through a signature is
        // no definition-order problem, so take fields and bases only.
        var lay = EvalNeeds(&(self.tu));
        var fields: *FrozenList::<*FieldDecl> = &null;
        if isa::<ClassDecl>(r) {
            fields = &(cast::<ClassDecl>(r)->fields);
            var c = cast::<ClassDecl>(r);
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var e = c->derives_list.get(i);
                if e != &null { lay.rec_type(e->base, r->range); }
            }
        } else if isa::<StructDecl>(r) { fields = &(cast::<StructDecl>(r)->fields); }
        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var f = (*fields)[i];
                if (f != &null) && (!f->is_static()) && (!f->is_eval()) { lay.rec_type(f->type_, r->range); }
            }
        }
        for var i: usize = 0; i < lay.recs.size(); ++i { if lay.recs[i] != r { self._add_once(out, lay.recs[i]); } }
        var cl = vec::<*Decl>();
        self._closure(&seeds, &cl);
        for var k: usize = 0; k < cl.size(); ++k {
            for var i: usize = 0; i < self._nd_key.size(); ++i {
                if (self._nd_key[i] == cl[k]) && (self._nd_kind[i] == u8(1)) { self._add_once(out, self._nd_val[i]); }
            }
        }
    }

    /// Whether record \p from reaches \p goal through _rec_edges.
    priv fn _rec_reaches(self, from: *Decl, goal: *Decl, seen: *vec::<*Decl>) -> bool {
        if from == goal { return true; }
        for var i: usize = 0; i < seen->size(); ++i { if (*seen)[i] == from { return false; } }
        seen->push_back(from);
        if seen->size() > 64 { return false; }
        var es = vec::<*Decl>();
        self._rec_edges(from, &es);
        for var i: usize = 0; i < es.size(); ++i { if self._rec_reaches(es[i], goal, seen) { return true; } }
        return false;
    }

    priv fn _check_order(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        var recs = vec::<*Decl>();
        var vars = vec::<*VariableDecl>();
        self._own_decls(static_cast::<*DeclContext>(tu), &recs, &vars);
        for var i: usize = 0; i < recs.size(); ++i { self._check_record(recs[i]); }
        for var i: usize = 0; i < vars.size(); ++i { self._check_var(vars[i]); }
    }

    priv fn _own_decls(self, dc: *DeclContext, recs: *vec::<*Decl>, vars: *vec::<*VariableDecl>) {
        if dc == &null { return; }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if (d == &null) || d->is_poisoned() || decl_is_imported(d) { continue; }
            if isa::<ModuleDecl>(d) { self._own_decls(static_cast::<*DeclContext>(cast::<ModuleDecl>(d)), recs, vars); continue; }
            if isa::<VisibilityGroupDecl>(d) {
                var g = cast::<VisibilityGroupDecl>(d);
                for var k: usize = 0; k < g->members.size(); ++k {
                    var m = g->members[k];
                    if m == &null { continue; }
                    if isa::<ClassDecl>(m) || isa::<StructDecl>(m) || isa::<UnionDecl>(m) { recs->push_back(m); }
                    var gv = dyn_cast::<VariableDecl>(m);
                    if (gv != &null) && gv->is_eval() && (gv->init != &null) { vars->push_back(gv); }
                }
                continue;
            }
            if isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d) {
                recs->push_back(d);
                var rdc: *DeclContext = &null;
                if isa::<ClassDecl>(d) { rdc = static_cast::<*DeclContext>(cast::<ClassDecl>(d)); }
                else if isa::<StructDecl>(d) { rdc = static_cast::<*DeclContext>(cast::<StructDecl>(d)); }
                if rdc != &null {
                    var nested = vec::<*VariableDecl>();
                    self._own_decls(rdc, recs, &nested);
                }
                continue;
            }
            var v = dyn_cast::<VariableDecl>(d);
            if (v != &null) && v->is_eval() && (v->init != &null) { vars->push_back(v); }
        }
    }

    /// \p r's types name a value C++ computes from items that need \p r
    /// complete (or a record that does): SC001E at the first such type.
    priv fn _check_record(self, r: *Decl) {
        if decl_generic_params(r).size() > 0 { return; }   // a template's head reads its items per instance.
        var ts = vec::<*Type>();
        var ws = vec::<SourceRange>();
        self._member_types(r, &ts, &ws);
        for var t: usize = 0; t < ts.size(); ++t {
            var seeds = vec::<*Decl>();
            self._type_items(ts[t], &seeds);
            if seeds.size() == 0 { continue; }
            var cl = vec::<*Decl>();
            self._closure(&seeds, &cl);
            // The first item needing r, or a record that reaches r.
            for var k: usize = 0; k < cl.size(); ++k {
                for var i: usize = 0; i < self._nd_key.size(); ++i {
                    if (self._nd_key[i] != cl[k]) || (self._nd_kind[i] != u8(1)) { continue; }
                    var need = self._nd_val[i];
                    var via: *Decl = &null;
                    if need != r {
                        var seen = vec::<*Decl>();
                        seen.push_back(r);
                        if !self._rec_reaches_from(need, r, &seen) { continue; }
                        via = need;
                    }
                    self._report_cycle(r, ws[t], cl[k], via, self._nd_at[i]);
                    return;
                }
            }
        }
    }

    /// _rec_reaches, with \p seen already holding the start record.
    priv fn _rec_reaches_from(self, from: *Decl, goal: *Decl, seen: *vec::<*Decl>) -> bool {
        for var i: usize = 0; i < seen->size(); ++i { if ((*seen)[i] == from) && (from != goal) { return false; } }
        if from == goal { return true; }
        seen->push_back(from);
        var es = vec::<*Decl>();
        self._rec_edges(from, &es);
        for var i: usize = 0; i < es.size(); ++i {
            if es[i] == goal { return true; }
            if self._rec_reaches(es[i], goal, seen) { return true; }
        }
        return false;
    }

    priv fn _report_cycle(self, r: *Decl, at: SourceRange, item: *Decl, via: *Decl, need_at: SourceRange) {
        var rn = self.tu.decl_name(r);
        var inn = self.tu.decl_name(item);
        var why = f"which needs '{rn}' complete";
        if via != &null { why = f"which needs '{self.tu.decl_name(via)}\x27 complete, and '{self.tu.decl_name(via)}\x27 needs '{rn}\x27"; }
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            f"this type has a value C++ computes from '{inn}', {why}; inside its own definition '{rn}' is not complete yet, so no order of the C++ declarations can compute it");
        b.first(at);
        var nn = (rn) if (via == &null) else (self.tu.decl_name(via));
        if need_at.is_valid() {
            b.note(DiagID::SC001N, need_at.start, f"'{inn}' needs '{nn}\x27 complete here").first(need_at);
        } else {
            b.note(DiagID::SC001N, item->range.start, f"'{inn}' is declared here").first(item->range);
        }
        b.emit();
    }

    /// An eval binding whose value reaches itself through the eval fns and
    /// bindings it reads: no constant at all (C++ would report an
    /// initializer that is not a constant expression).
    priv fn _check_var(self, v: *VariableDecl) {
        var n = EvalNeeds(&(self.tu));
        n.dispatch_expr(v->init);
        var seeds = vec::<*Decl>();
        for var i: usize = 0; i < n.items.size(); ++i { seeds.push_back(n.items[i]); }
        var cl = vec::<*Decl>();
        self._closure(&seeds, &cl);
        var me = static_cast::<*Decl>(v);
        var hit = false;
        for var i: usize = 0; i < cl.size(); ++i { if cl[i] == me { hit = true; break; } }
        if !hit { return; }
        var vn = self.sc->ctx->get_spelling(v->name);
        var via = "";
        if seeds.size() > 0 { via = f" through '{self.tu.decl_name(seeds[0])}\x27"; }
        var b = self.sc->diag->report(DiagID::SC001E, v->name.range.start,
            f"the value of 'eval {vn}' depends on itself{via}; an eval binding cannot be computed from its own value");
        b.first(v->name.range);
        if v->init != &null { b.note(DiagID::SC001N, v->init->range.start, "its initializer, which reads it back").first(v->init->range); }
        b.emit();
    }
}
