/// --- The Kairo Project --------------- Sema/Check/EvalUsageChecking.k --- ///
///
///   \brief What an eval context may contain (Compiler/Spec/Eval.md#eval-for, §6).
///
///   \detail
///     C++ computes every eval value (Compiler/Spec/Eval.md#c-computes), so a mistake left to it is
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
///         by design (Compiler/Spec/Eval.md#evaluable-values), with no compile-time C++ form yet. A
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::DeclFacts::{
    decl_is_imported,
    decl_is_instance,
    decl_requires_clause,
}
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    QUAL_CONST,
    RecordType,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    ConditionalStmt,
    IndexedForStmt,
    LabeledStmt,
    PanicStmt,
    RangedForStmt,
    ReturnStmt,
}
import AST::Node::Types::{
    FixedArrayType,
    GenericParamType,
    NullableType,
    PointerType,
    TypeExpr,
    ValueOp,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Diagnostic::NoteText::{
    declared_here,
    named_declared_here,
}
import Location::SourceRange::SourceRange
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

/// The first `return` with a value in a statement, not counting closures'.
pub class ReturnFinder derives RecursiveASTVisitor<ReturnFinder> {
    pub var found: unsafe *ReturnStmt = &null
    fn ReturnFinder(self) { }
    fn visit_return_stmt(self, n: unsafe *ReturnStmt) -> bool {
        if self.found == &null && n->value != &null {
            self.found = n
        }

        return true
    }

    fn traverse_closure_expr(self, n: *Expressions::ClosureExpr) -> *Expressions::ClosureExpr {
        return n
    }
}

/// Marks every string literal under an expression as read by C++ at
/// compile time (StringLiteralExpr::const_eval, Compiler/Spec/Eval.md#strings-at-compile-time): the arguments
/// of an eval call made from run-time code, an eval class's field default.
/// A closure's body is its own context.
pub class ConstEvalStrings derives RecursiveASTVisitor<ConstEvalStrings> {
    fn ConstEvalStrings(self) { }
    fn visit_string_literal_expr(self, n: *StringLiteralExpr) -> bool {
        if !n->is_format() {
            n->const_eval = true
        }

        return true
    }

    fn traverse_closure_expr(self, n: *Expressions::ClosureExpr) -> *Expressions::ClosureExpr {
        return n
    }
}

/// What one eval item -- an eval fn's body, an eval binding's or eval
/// field's initializer -- needs before C++ can evaluate it (Compiler/Spec/Eval.md#value-nodes):
/// the eval items it reads (each DEFINED first) and the records it lays out
/// or looks into (each COMPLETE first). The Sema side of EmitPlan's early
/// items (EmitPlan::_early), read by EvalUsageChecking::_check_order.
pub class EvalNeeds derives RecursiveASTVisitor<EvalNeeds> {
    pub var items: cxx::std::vector<unsafe *Decl>
    pub var recs:  cxx::std::vector<unsafe *Decl>
    /// Parallel to recs: where the body needs it, for the note.
    pub var  at:  cxx::std::vector<SourceRange>
    priv var _tu: unsafe *TypeUtil              = &null

    fn EvalNeeds(self, tu: unsafe *TypeUtil) {
        self._tu = tu
    }

    /// \p d named at \p r: an eval item, and a member's owner (C++ looks
    /// into a complete class only).
    fn named(self, d: unsafe *Decl, r: SourceRange) {
        if d == &null {
            return
        }

        var unsafe *dc = d->semantic_dc
        if dc != &null && dc->is_type_scope() && dc->dc_kind != DeclContextKind::Extension {
            self.rec(dc->owner_decl(), r)
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f != &null && f->is_eval() {
            self._item(d)
            return
        }

        var unsafe *v = dyn_cast<Declarations::VariableDecl>(d)
        if v != &null
            && v->is_eval()
            && v->init != &null
            && dc != &null
            && (dc->dc_kind == DeclContextKind::TranslationUnit
                || dc->dc_kind == DeclContextKind::Module) {
            self._item(d)
            return
        }

        var unsafe *fd = dyn_cast<Declarations::FieldDecl>(d)
        if fd != &null && fd->is_eval() && fd->init != &null {
            self._item(d)
        }
    }

    priv fn _item(self, d: unsafe *Decl) {
        for var i: usize = 0; i < self.items.size(); ++i {
            if self.items[i] == d {
                return
            }
        }

        self.items.push_back(d)
    }

    /// Record \p d needed complete (its outermost record: a nested one is
    /// defined inside it), once.
    fn rec(self, d0: unsafe *Decl, r: SourceRange) {
        if d0 == &null {
            return
        }

        var unsafe *d = d0
        if decl_is_instance(d) {
            d = self._tu->pattern_of(d)
        }

        var unsafe *dc = d->semantic_dc
        while dc != &null
            && dc->is_type_scope()
            && dc->dc_kind != DeclContextKind::Extension
            && dc->owner_decl() != &null {
            d  = dc->owner_decl()
            dc = d->semantic_dc
        }

        if (!isa<Declarations::ClassDecl>(d))
            && (!isa<Declarations::StructDecl>(d))
            && (!isa<Declarations::UnionDecl>(d))
            && !isa<Declarations::EnumDecl>(d) {
            return
        }

        for var i: usize = 0; i < self.recs.size(); ++i {
            if self.recs[i] == d {
                return
            }
        }

        self.recs.push_back(d)
        self.at.push_back(r)
    }

    /// The records \p t holds by value: laid out wherever a value of it is.
    fn rec_type(self, t: unsafe *Type, r: SourceRange) {
        if t == &null {
            return
        }

        var unsafe *c = canon_unqual(if (t->canonical != &null) => (t->canonical) else => t)
        if c == &null {
            return
        }

        match c->kind {
            case TypeKind::RecordType {
                var unsafe *rt = cast<RecordType>(c)
                // An instance at dependent arguments names no one record:
                // which it is, and so whether it closes a cycle, is per
                // instance (_check_record).
                if !c->is_dependent() {
                    self.rec(rt->decl, r)
                }

                for var i: usize = 0; i < rt->args.size(); ++i {
                    self.values(*rt->args.get(i), r)
                }
            } case TypeKind::FixedArrayType {
                self.rec_type(cast<FixedArrayType>(c)->element, r)
                self.values(cast<FixedArrayType>(c)->extent_param, r)
            } case TypeKind::NullableType {
                self.rec_type(cast<NullableType>(c)->inner, r)
            } case TypeKind::TypeExpr {
                self.values(c, r)
            } default { }
        }
    }

    /// The eval items computed value \p t names (Compiler/Spec/Eval.md#value-nodes): an eval
    /// fn or an eval class's constructor it calls, an eval constant it
    /// reads. A class it constructs is needed complete.
    fn values(self, t: unsafe *Type, r: SourceRange) {
        var unsafe *v = dyn_cast<TypeExpr>(t)
        if v == &null || !v->is_value || v->is_exact() {
            return
        }

        if v->vdecl != &null {
            if v->vop == ValueOp::Call
                && (isa<Declarations::ClassDecl>(v->vdecl)
                    || isa<Declarations::StructDecl>(v->vdecl)) {
                self.rec(v->vdecl, r)
                var ms: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
                if isa<Declarations::ClassDecl>(v->vdecl) {
                    ms = unsafe &cast<Declarations::ClassDecl>(v->vdecl)->methods
                } else {
                    ms = unsafe &cast<Declarations::StructDecl>(v->vdecl)->methods
                }

                for var i: usize = 0; i < ms->size(); ++i {
                    var unsafe *m = (*ms)[i]
                    if m != &null && m->is_eval() {
                        self._item(m)
                    }
                }
            } else if v->vop == ValueOp::Call || v->vop == ValueOp::Decl {
                self.named(v->vdecl, r)
            }
        }

        for var i: usize = 0; i < v->vops.size(); ++i {
            self.values(v->vops[i], r)
        }
    }

    fn visit_expr(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return true
        }

        if e->type_ != &null {
            self.rec_type(e->type_, e->range)
        }

        if isa<NamedIdentExpr>(e) {
            self.named(cast<NamedIdentExpr>(e)->resolved_decl, e->range)
        } else if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            for var i: usize = 0; i < ch->steps.size(); ++i {
                var unsafe *st = ch->steps.get(i)
                if st == &null {
                    continue
                }

                var unsafe *d = st->resolved_decl
                if d == &null && st->name != &null {
                    d = st->name->resolved_decl
                }

                self.named(d, e->range)
            }
        } else if isa<Expressions::CallExpr>(e) {
            self.named(cast<Expressions::CallExpr>(e)->ctor_decl, e->range)
        } else if isa<Expressions::BinaryOperatorExpr>(e) {
            self.named(cast<Expressions::BinaryOperatorExpr>(e)->resolved_op, e->range)
        } else if isa<Expressions::UnaryOperatorExpr>(e) {
            self.named(cast<Expressions::UnaryOperatorExpr>(e)->resolved_op, e->range)
        } else if isa<Expressions::SizeOfExpr>(e) {
            self.rec_type(cast<Expressions::SizeOfExpr>(e)->type_arg, e->range)
        } else if isa<Expressions::AlignOfExpr>(e) {
            self.rec_type(cast<Expressions::AlignOfExpr>(e)->type_arg, e->range)
        } else if isa<Expressions::TypeTraitExpr>(e) {
            self.rec_type(cast<Expressions::TypeTraitExpr>(e)->type_arg, e->range)
        }

        return true
    }

    fn visit_decl(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return true
        }

        if isa<Declarations::VariableDecl>(d) {
            self.rec_type(cast<Declarations::VariableDecl>(d)->type_, d->range)
        } else if isa<Declarations::ParamDecl>(d) {
            var unsafe *p = cast<Declarations::ParamDecl>(d)
            if !p->is_self {
                self.rec_type(p->type_, d->range)
            }
        } else if isa<Declarations::FunctionDecl>(d) {
            self.rec_type(cast<Declarations::FunctionDecl>(d)->return_type, d->range)
        }

        return true
    }

    fn visit_type(self, t: unsafe *Type) -> bool {
        if t != &null && t->canonical != &null {
            self.values(t->canonical, t->range)
        }

        return true
    }
}

/// What a needs row names: an item the key reads (an eval fn or binding),
/// or a record whose layout it needs complete.
pub enum EvalNeedKind derives u8 {
    Item,
    Record,
}

/// One row of EvalUsageChecking's needs table: item `key` needs `val`
/// (as `kind` says), at `at`.
pub struct EvalNeedRow {
    pub var key:  unsafe *Decl = &null
    pub var kind: EvalNeedKind     = EvalNeedKind::Item
    pub var val:  unsafe *Decl = &null
    pub var at:   SourceRange  = SourceRange::invalid()
}

pub class EvalUsageChecking derives RecursiveASTVisitor<EvalUsageChecking> {
    pub var  sc: unsafe *SemaContext
    priv var tu: TypeUtil

    /// The function whose body is walked (innermost), or null.
    priv var _fns: cxx::std::vector<unsafe *Declarations::FunctionDecl>
    /// Bindings of the `eval for`s around the walk: constants in each copy.
    priv var _ef_binds: cxx::std::vector<unsafe *Decl>
    /// The iterables of those `eval for`s: the one place an eval generator
    /// may be called.
    priv var _ef_iters: cxx::std::vector<unsafe *Expr>
    /// `eval for` bodies around the walk (outside an eval fn).
    priv var _ef_depth: u32 = 0
    /// > 0 inside an eval CONTEXT (file header): an eval fn's body or an
    /// eval initializer. `_ctx_fn` > 0 when one of them is an eval fn's,
    /// where the function's own locals and parameters are compile-time too.
    priv var _ctx:    u32 = 0
    priv var _ctx_fn: u32 = 0

    fn EvalUsageChecking(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
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

        self._check_order()
    }

    /// # scopes

    fn traverse_function_decl(self,
                              n: unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
        self._fns.push_back(n)
        var sd = self._ef_depth
        self._ef_depth = 0
        self._check_requires(n->requires_clause)
        var ev = n->is_eval() && !n->is_implicit
        if ev {
            self._check_eval_fn(n)
            self._ctx += 1
            self._ctx_fn += 1
        }

        var unsafe *r = RecursiveASTVisitor<EvalUsageChecking>::traverse_function_decl(self, n)
        if ev {
            self._ctx -= 1
            self._ctx_fn -= 1
        }

        self._ef_depth = sd
        self._fns.pop_back()
        return r
    }

    /// A generic value parameter's type: an integer (a value argument folds
    /// to one, or is an expression C++ computes, Compiler/Spec/Eval.md#value-nodes), or an eval
    /// class, a C++20 class-type parameter, when it is structural (7e), or a
    /// plain enum. Anything else (`bool`, a float) is not built.
    fn visit_generic_param_decl(self, n: *Declarations::GenericParamDecl) -> bool {
        if !n->is_const_param || n->value_type == &null || n->value_type->canonical == &null {
            return true
        }

        var unsafe *c = canon_unqual(n->value_type->canonical)
        if self.tu.is_integer(c) {
            return true
        }

        // An eval class (Compiler/Spec/Eval.md#eval-classes): a C++20 class-type template
        // parameter, which C++ allows only for a structural type.
        var unsafe *rd = self.tu.record_decl(c)
        if rd != &null && (isa<Declarations::ClassDecl>(rd) || isa<Declarations::StructDecl>(rd)) {
            self._check_structural(n, rd)
            return true
        }

        // A plain enum (`<eval T: FlagKind>`): a C++ enumeration
        // template parameter, whose argument is a variant (`FlagKind::Bool`).
        // An ADT is a class with payloads, not structural, so not here.
        if rd != &null
            && isa<Declarations::EnumDecl>(rd)
            && !cast<Declarations::EnumDecl>(rd)->is_adt {
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            n->value_type->range.start,
            f"a generic value parameter of type '{self.tu.str(c)}' is not yet supported; only an integer type or an eval class is",
        )

        b.first(n->value_type->range)
        b.emit()
        return true
    }

    /// \p rd as the type of value parameter \p n (Compiler/Spec/Eval.md#eval-classes, USER): every
    /// field `pub`, none a pointer to mutable memory, every field's type
    /// structural in turn, every constructor `eval`, no destructor written.
    /// C++ compares template arguments of class type member by member, and
    /// only a structural class may be one. The first field (or
    /// constructor) that is not is the error, with a note at it.
    priv fn _check_structural(self, n: *Declarations::GenericParamDecl, rd: unsafe *Decl) {
        var why              = ""
        var at: unsafe *Decl = &null
        self._structural(rd, unsafe &why, unsafe &at, 0)
        if why.size() == 0 {
            return
        }

        var tn = self.tu.decl_name(rd)
        var b = self.sc->diag->report(
            DiagID::SC183E,
            n->value_type->range.start,
            f"'{tn}' cannot be the type of a generic value parameter: {why}",
        )

        b.first(n->value_type->range)
        if at != &null {
            b.note(DiagCode(DiagID::SC183N), at->range.start, declared_here())->child_first(at->range)
        }

        b.emit()
    }

    /// The first reason \p rd is not structural, into \p why / \p at.
    priv fn _structural(self,
                        rd:    unsafe *Decl,
                        why:   unsafe *string,
                        at:    unsafe *(unsafe *Decl),
                        depth: u32) {
        if depth > (8 as u32) {
            return
        }

        var tn                                                              = self.tu.decl_name(rd)
        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        if isa<Declarations::ClassDecl>(rd) {
            fields  = unsafe &cast<Declarations::ClassDecl>(rd)->fields
            methods = unsafe &cast<Declarations::ClassDecl>(rd)->methods
        } else if isa<Declarations::StructDecl>(rd) {
            fields  = unsafe &cast<Declarations::StructDecl>(rd)->fields
            methods = unsafe &cast<Declarations::StructDecl>(rd)->methods
        } else {
            return
        }

        var unsafe *dt = self._user_dtor(rd)
        if dt != &null {
            *why = f"'{tn}' has a destructor"
            *at  = unsafe (dt as unsafe *Decl)
            return
        }

        // The parameter's own class is built at compile time, so its
        // constructors are `eval`; a field's class needs only to be
        // structural (the builtin string's are constexpr).
        var on = tn
        for var i: usize = 0; depth == (0 as u32) && i < methods->size(); ++i {
            var unsafe *m = (*methods)[i]
            if m == &null || m->is_operator || m->is_implicit {
                continue
            }

            if self.tu.decl_name(unsafe (m as unsafe *Decl)) != on {
                continue
            }

            if !m->is_eval() {
                *why = f"a constructor of '{tn}' is not 'eval'"
                *at  = unsafe (m as unsafe *Decl)
                return
            }
        }

        for var i: usize = 0; i < fields->size(); ++i {
            var unsafe *f = (*fields)[i]
            if f == &null || f->is_static() || f->is_eval() {
                continue
            }

            var fnm = self.sc->ctx->get_spelling(f->name)
            // Unmarked: a struct's field is public, a class's private (as
            // InterfaceEmitter::_access spells them).
            var vis = f->visibility
            if vis == VisibilityKind::None {
                vis = if (isa<Declarations::ClassDecl>(rd)) => (VisibilityKind::Private)
                      else => VisibilityKind::Public
            }

            if vis != VisibilityKind::Public {
                *why = f"its field '{fnm}' is not 'pub'"
                *at  = unsafe (f as unsafe *Decl)
                return
            }

            if f->is_mutable {
                *why = f"its field '{fnm}' is 'mutable'"
                *at  = unsafe (f as unsafe *Decl)
                return
            }

            if f->type_ == &null || f->type_->canonical == &null {
                continue
            }

            var unsafe *ft = canon_unqual(f->type_->canonical)
            var unsafe *pt = dyn_cast<PointerType>(ft)
            if pt != &null && (canon_quals(pt->pointee) & QUAL_CONST) == 0 {
                *why = f"its field '{fnm}' points to mutable memory"
                *at  = unsafe (f as unsafe *Decl)
                return
            }

            var unsafe *frd = self.tu.record_decl(ft)
            if frd != &null && pt == &null {
                self._structural(frd, why, at, depth + (1 as u32))
                if why->size() > 0 {
                    var inner = *why
                    *why = f"its field '{fnm}' is a '{self.tu.decl_name(frd)}', and " + inner
                    return
                }
            }
        }
    }

    /// An `eval` binding's initializer is an eval context, and its value is
    /// a constant object: its type has no user-written destructor.
    fn traverse_variable_decl(self,
                              n: unsafe *Declarations::VariableDecl) -> unsafe *Declarations::VariableDecl {
        if n->is_eval() && n->type_ != &null && n->type_->canonical != &null {
            var unsafe *dt = self._user_dtor(self.tu.record_decl(canon_unqual(n->type_->canonical)))
            if dt != &null {
                var nm = self.sc->ctx->get_spelling(n->name)
                var b = self.sc->diag->report(
                    DiagID::SC184E,
                    n->name.range.start,
                    f"'{nm}' is an 'eval' constant of type '{self.tu.str(n->type_->canonical)}', whose destructor is not trivial; a compile-time object is never destroyed",
                )

                b.first(n->name.range)
                b.note(
                    DiagCode(DiagID::SC184N),
                    dt->range.start,
                    "the destructor is declared here",
                )->child_first(dt->range)
                b.emit()
            }
        }

        // A slice constant needs a compile-time Slice, and Lib/builtin's has
        // no constexpr constructor: the declaration reached clang ("Slice<int>
        // is not literal"), or an ICE for a file-scope one. Refused at
        // the declaration until the library has one; an array (`[T; N]`) is
        // the compile-time form today.
        if n->is_eval() && n->type_ != &null && n->type_->canonical != &null
            && self.tu.is_slice(n->type_->canonical) {
            var nm = self.sc->ctx->get_spelling(n->name)
            var b = self.sc->diag->report(
                DiagID::SC116E,
                n->name.range.start,
                f"an 'eval' constant of slice type '{self.tu.str(n->type_->canonical)}' is not yet supported: a slice has no compile-time form; declare '{nm}' as a fixed array",
            )

            b.first(n->name.range)
            b.emit()
            n->poison()
            return n
        }

        if n->is_eval() && n->init == &null {
            self._needs_init(n->name, n->range)
        }

        if n->is_eval() && n->init != &null {
            self._ctx += 1
            var unsafe *r = RecursiveASTVisitor<EvalUsageChecking>::traverse_variable_decl(self, n)
            self._ctx -= 1
            return r
        }

        if self._ctx_fn > 0 {
            self._check_local(n)
        }

        return RecursiveASTVisitor<EvalUsageChecking>::traverse_variable_decl(self, n)
    }

    fn traverse_field_decl(self,
                           n: unsafe *Declarations::FieldDecl) -> unsafe *Declarations::FieldDecl {
        if n->is_eval()
            && n->init == &null
            && !n->is_implicit
            && n->init_fold == Declarations::FieldFold::None {
            self._needs_init(n->name, n->range)
        }

        // An eval class's field default runs inside its eval constructor
        // too, at compile time (Compiler/Spec/Eval.md#eval-classes): its strings are compile-time
        // strings, and the run-time constructors share the same thunk.
        if !n->is_eval() && !n->is_static() && n->init != &null && self._in_eval_class(n) {
            var m = ConstEvalStrings()
            m.dispatch_expr(n->init)
        }

        if n->is_eval() && n->init != &null {
            self._ctx += 1
            var unsafe *r = RecursiveASTVisitor<EvalUsageChecking>::traverse_field_decl(self, n)
            self._ctx -= 1
            return r
        }

        return RecursiveASTVisitor<EvalUsageChecking>::traverse_field_decl(self, n)
    }

    /// `eval e` is an eval context: C++ computes `e` in place.
    fn traverse_eval_expr(self, n: *Expressions::EvalExpr) -> *Expressions::EvalExpr {
        self._ctx += 1
        var *r = RecursiveASTVisitor<EvalUsageChecking>::traverse_eval_expr(self, n)
        self._ctx -= 1
        return r
    }

    /// \p f's record has an eval constructor (an eval class, Compiler/Spec/Eval.md#eval-classes);
    /// the rule FieldInitLowering::_eval_class makes its defaults' thunks
    /// `constexpr` by.
    priv fn _in_eval_class(self, f: unsafe *Declarations::FieldDecl) -> bool {
        var unsafe *dc    = f->semantic_dc
        var unsafe *owner = if (dc != &null) => (dc->owner_decl()) else => &null
        if owner == &null {
            return false
        }

        var ms: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        if isa<Declarations::ClassDecl>(owner) {
            ms = unsafe &cast<Declarations::ClassDecl>(owner)->methods
        } else if isa<Declarations::StructDecl>(owner) {
            ms = unsafe &cast<Declarations::StructDecl>(owner)->methods
        }

        if ms == &null {
            return false
        }

        var on = self.tu.decl_name(owner)
        for var i: usize = 0; i < ms->size(); ++i {
            var unsafe *m = (*ms)[i]
            if m != &null
                && m->is_eval()
                && !m->is_operator
                && self.tu.decl_name(unsafe (m as unsafe *Decl)) == on {
                return true
            }
        }

        return false
    }

    /// An `eval` constant is its value: one with none (`eval K: i32`) would
    /// be a zero C++ made up.
    priv fn _needs_init(self, name: Token, at: SourceRange) {
        var nm = self.sc->ctx->get_spelling(name)
        var b = self.sc->diag->report(
            DiagID::SC185E,
            name.range.start,
            f"'{nm}' is an 'eval' constant and needs an initializer: its value is computed at compile time",
        )

        b.first(name.range)
        b.emit()
    }

    /// # requires

    fn visit_class_decl(self, n: *Declarations::ClassDecl) -> bool {
        self._check_requires(n->requires_clause)
        return true
    }

    fn visit_struct_decl(self, n: *Declarations::StructDecl) -> bool {
        self._check_requires(n->requires_clause)
        return true
    }

    fn visit_enum_decl(self, n: *Declarations::EnumDecl) -> bool {
        self._check_requires(n->requires_clause)
        return true
    }

    /// A `requires` VALUE predicate (not a `T impl I` / `T derives B`
    /// conjunct) is an eval context: one that reads a run-time value -- a
    /// parameter, a variable -- is requires.mdx's hard error. The predicate
    /// itself is evaluated by C++ (EmitIR's static_assert for a function,
    /// the template head or a body static_assert for a record).
    priv fn _check_requires(self, e: unsafe *Expr) {
        if e == &null || e->is_poisoned() {
            return
        }

        var unsafe *b = dyn_cast<Expressions::BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            self._check_requires(b->lhs)
            self._check_requires(b->rhs)
            return
        }

        if isa<Expressions::ConstraintExpr>(e) {
            return
        }

        var unsafe *bad = self._first_runtime(e)
        if bad == &null {
            return
        }

        var d = self.sc->diag->report(
            DiagID::SC186E,
            e->range.start,
            "requires expression is not compile-time evaluable",
        )

        var lbl = "depends on a runtime value"
        if isa<NamedIdentExpr>(bad) {
            lbl = f"depends on runtime value '{self.sc->ctx->get_spelling(cast<NamedIdentExpr>(bad)->name)}'"
        }

        d.first(bad->range, lbl)
        d.note(
            DiagCode(DiagID::SC186N),
            e->range.start,
            "for runtime-conditional dispatch, use 'where'",
        )->child_first(e->range)
        d.emit()
    }

    /// # the restriction table

    /// The signature of an eval fn: no `where`, no pointer parameter.
    priv fn _check_eval_fn(self, n: unsafe *Declarations::FunctionDecl) {
        var nm = self.tu.decl_name(unsafe (n as unsafe *Decl))
        // eval.mdx: a compile-time object is never destroyed, so an eval
        // destructor never runs. C++ rejects a `consteval` destructor, and
        // that clang error on the emitted text was all the user saw.
        if n->is_operator && n->op_token.size() > 0 && n->op_token[0].kind == TokenKind::KwFinally {
            var b = self.sc->diag->report(
                DiagID::SC290E,
                n->range.start,
                "a destructor cannot be 'eval': a compile-time object is never destroyed",
            )

            b.first(n->op_token[0].range, "declared 'eval' here")
            b.emit()
            return
        }

        if n->where_clause != &null {
            var b = self.sc->diag->report(
                DiagID::SC187E,
                n->where_clause->range.start,
                f"an 'eval' function cannot have a 'where' clause; bound '{nm}' with 'requires'",
            )

            b.first(n->where_clause->range)
            b.emit()
        }

        if n->return_type != &null && n->return_type->canonical != &null && !n->is_generator {
            self._no_eval_form(n->return_type->range, n->return_type->canonical)
        }

        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null || p->is_self || p->type_ == &null || p->type_->canonical == &null {
                continue
            }

            if self._no_eval_form(p->range, p->type_->canonical) {
                continue
            }

            if !isa<PointerType>(canon_unqual(p->type_->canonical)) {
                continue
            }

            var pn = self.sc->ctx->get_spelling(p->name)
            var b = self.sc->diag->report(
                DiagID::SC188E,
                p->range.start,
                f"an 'eval' function cannot take a pointer; '{pn}' is '{self.tu.str(p->type_->canonical)}': there is no addressable memory at compile time",
            )

            b.first(p->range)
            b.emit()
        }
    }

    /// \p t is a collection, which has no compile-time form yet (Compiler/Spec/Eval.md
    /// 2b): reported at \p at. A string has one (2a).
    priv fn _no_eval_form(self, at: SourceRange, t: unsafe *Type) -> bool {
        var what = self._wide_float(t)
        if what.size() == 0 {
            if self.tu.is_vector_like(t) {
                what = "a vector"
            } else if self.tu.is_set_like(t) {
                what = "a set"
            } else if self.tu.is_map_like(t) {
                what = "a map"
            }
        }

        if what.size() == 0 {
            return false
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            at.start,
            f"{what} in an eval context is not yet supported",
        )

        b.first(at)
        b.emit()
        return true
    }

    /// "an 'f256' value" / "an 'f512' value" when \p t is one, else "". The
    /// two are library classes whose every operation, literals included,
    /// is a run-time call into num/softfloat.k: C++ has no
    /// compile-time form of them, and clang would say so only about the
    /// emitted text ("non-literal type").
    priv fn _wide_float(self, t: unsafe *Type) -> string {
        if t == &null {
            return ""
        }

        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<BuiltinType>(c) {
            return ""
        }

        var k = cast<BuiltinType>(c)->builtin
        if k == BuiltinKind::F256 {
            return "an 'f256' value"
        }

        if k == BuiltinKind::F512 {
            return "an 'f512' value"
        }

        // The f8 classes (std/rt/Float8.k) are no literal types either.
        if k == BuiltinKind::F8E4M3 {
            return "an 'f8e4m3' value"
        }

        if k == BuiltinKind::F8E5M2 {
            return "an 'f8e5m2' value"
        }

        return ""
    }

    /// A local of an eval fn: no pointer, no type with a destructor, no
    /// static / thread storage.
    priv fn _check_local(self, n: unsafe *Declarations::VariableDecl) {
        var nm = self.sc->ctx->get_spelling(n->name)
        if n->is_static() || n->is_thread {
            self._err(
                n->name.range,
                f"an 'eval' function cannot declare a static or thread variable; '{nm}' outlives the evaluation",
            )

            return
        }

        if n->type_ == &null || n->type_->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(n->type_->canonical)
        if isa<PointerType>(c) {
            self._err(
                n->name.range,
                f"an 'eval' function cannot hold a pointer; '{nm}' is '{self.tu.str(c)}': there is no addressable memory at compile time",
            )

            return
        }

        var unsafe *d    = self.tu.record_decl(c)
        var unsafe *dtor = self._user_dtor(d)
        if dtor != &null {
            var b = self.sc->diag->report(
                DiagID::SC184E,
                n->name.range.start,
                f"'{nm}' is a '{self.tu.str(c)}', whose destructor is not trivial; it cannot live in an 'eval' function",
            )

            b.first(n->name.range)
            b.note(
                DiagCode(DiagID::SC184N),
                dtor->range.start,
                "the destructor is declared here",
            )->child_first(dtor->range)
            b.emit()
        }
    }

    /// \p d's user-written `op delete`, or null.
    priv fn _user_dtor(self, d: unsafe *Decl) -> unsafe *Declarations::FunctionDecl {
        if d == &null {
            return &null
        }

        var ms: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        if isa<Declarations::ClassDecl>(d) {
            ms = unsafe &cast<Declarations::ClassDecl>(d)->methods
        } else if isa<Declarations::StructDecl>(d) {
            ms = unsafe &cast<Declarations::StructDecl>(d)->methods
        }

        if ms == &null {
            return &null
        }

        for var i: usize = 0; i < ms->size(); ++i {
            var unsafe *m = (*ms)[i]
            if m == &null || !m->is_operator || m->op_token.size() == 0 {
                continue
            }

            if m->op_token[0].kind != TokenKind::KwFinally {
                continue
            }

            if m->body_kind == Declarations::FnBodyKind::Default {
                continue
            }

            // A constexpr destructor (the string lang item's; NameResolution::
            // _literal_ctor_constexpr) runs in a constant expression, so a
            // compile-time object of the type is constant-destructible.
            if m->is_constexpr() {
                continue
            }

            return m
        }

        return &null
    }

    /// A call in an eval context: of an eval fn, an eval constructor, or a
    /// struct's implicit one.
    priv fn _check_ctx_call(self, n: unsafe *Expressions::CallExpr) {
        var unsafe *f = self._callee_fn(n)
        if f == &null { // a constructor no one wrote, or untyped: nothing to say.
            return
        }

        if f->is_eval() {
            return
        }

        // A C++ `constexpr` / `consteval` function is C++'s eval fn: clang
        // evaluates it at compile time, which is all an eval context asks.
        if f->ffi_constexpr {
            return
        }

        var nm   = self.tu.decl_name(f)
        var what = if (n->ctor_decl != &null) => ("constructor") else => "function"
        var b = self.sc->diag->report(
            DiagID::SC189E,
            n->range.start,
            f"an eval context can call only 'eval' functions; '{nm}' is a {what} that is not 'eval'",
        )

        b.first(n->range)
        b.note(DiagCode(DiagID::SC189N), f->range.start, named_declared_here(nm))->child_first(
            f->range,
        )

        if !self._foreign(f) && !f->is_implicit && f->body_kind == Declarations::FnBodyKind::Block {
            b.insert(f->range.start, "eval ", f"make '{nm}' an 'eval fn'")
        }

        b.emit()
    }

    /// A name in an eval context: a compile-time value (_eval_decl), or,
    /// in an eval fn, one of its locals or parameters.
    priv fn _check_ctx_name(self, e: *Expr, d: unsafe *Decl) {
        if d == &null {
            return
        }

        if self._eval_decl(d) {
            return
        }

        // An eval fn's parameter is a compile-time value; any other is not.
        if isa<Declarations::ParamDecl>(d) && self._ctx_fn > 0 {
            return
        }

        if isa<Declarations::ParamDecl>(d) {
            var pn = self.tu.decl_name(d)
            var pb = self.sc->diag->report(
                DiagID::SC189E,
                e->range.start,
                f"an eval context reads only compile-time values; '{pn}' is a run-time parameter",
            )

            pb.first(e->range)
            pb.note(DiagCode(DiagID::SC189N), d->range.start, named_declared_here(pn))->child_first(
                d->range,
            )

            pb.emit()
            return
        }

        var unsafe *vd = dyn_cast<Declarations::VariableDecl>(d)
        var unsafe *fd = dyn_cast<Declarations::FieldDecl>(d)
        if vd == &null && fd == &null {
            return
        }

        var global = fd != &null && fd->is_static()
        if vd != &null {
            global = self._is_global(vd)
        }

        if !global && self._ctx_fn > 0 { // the eval fn's own local.
            return
        }

        if fd != &null && !global { // a member through `self` of an eval method.
            return
        }

        var nm = self.tu.decl_name(d)
        var why = if (!global) => ("a run-time local")
                  else => "a global, static or thread variable that is not 'eval'"
        var b = self.sc->diag->report(
            DiagID::SC189E,
            e->range.start,
            f"an eval context reads only compile-time values; '{nm}' is {why}",
        )

        b.first(e->range)
        b.note(DiagCode(DiagID::SC189N), d->range.start, named_declared_here(nm))->child_first(
            d->range,
        )

        if vd != &null
            && vd->storage == Declarations::StorageClass::Const
            && !vd->const_binding
            && vd->storage_kw.is_valid()
            && global {
            b.fix(vd->storage_kw, "eval", f"declare '{nm}' as 'eval'")
        }

        b.emit()
    }

    priv fn _is_global(self, vd: unsafe *Declarations::VariableDecl) -> bool {
        if vd->is_static() || vd->is_thread {
            return true
        }

        var unsafe *dc = vd->semantic_dc
        if dc == &null {
            return false
        }

        if dc->is_translation_unit() {
            return true
        }

        var unsafe *o = dc->owner_decl()
        return o != &null && isa<Declarations::ModuleDecl>(o)
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self._ctx == 0 {
            return true
        }

        self._check_ctx_name(n, n->resolved_decl)
        return true
    }

    fn visit_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        if self._ctx == 0 {
            return true
        }

        var k = n->op_token.kind
        if n->resolved_op == &null && (k == TokenKind::OpAmp || k == TokenKind::OpStar) {
            self._err(
                n->range,
                "an eval context cannot take an address or dereference a pointer; there is no addressable memory at compile time",
            )

            return true
        }

        if n->resolved_op != &null
            && isa<Declarations::FunctionDecl>(n->resolved_op)
            && !cast<Declarations::FunctionDecl>(n->resolved_op)->is_eval() {
            self._op_not_eval(n->range, cast<Declarations::FunctionDecl>(n->resolved_op))
        }

        return true
    }

    fn visit_binary_operator_expr(self, n: *Expressions::BinaryOperatorExpr) -> bool {
        if self._ctx == 0 {
            return true
        }

        if n->resolved_op != &null
            && isa<Declarations::FunctionDecl>(n->resolved_op)
            && !cast<Declarations::FunctionDecl>(n->resolved_op)->is_eval() {
            self._op_not_eval(n->range, cast<Declarations::FunctionDecl>(n->resolved_op))
        }

        return true
    }

    priv fn _op_not_eval(self, at: SourceRange, f: unsafe *Declarations::FunctionDecl) {
        var b = self.sc->diag->report(
            DiagID::SC189E,
            at.start,
            "an eval context can use only 'eval' operators; this one is not 'eval'",
        )

        b.first(at)
        b.note(DiagCode(DiagID::SC189N), f->range.start, "the operator is declared here")->child_first(
            f->range,
        )

        if !self._foreign(f) {
            b.insert(f->range.start, "eval ", "make it 'eval'")
        }

        b.emit()
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if self._ctx == 0 {
            return true
        }

        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st->access_kind == ChainExpr::AccessKind::Arrow
                || st->access_kind == ChainExpr::AccessKind::QuestionArrow {
                self._err(
                    n->range,
                    "an eval context cannot follow a pointer ('->'); there is no addressable memory at compile time",
                )

                return true
            }
        }

        var d: unsafe *Decl = &null
        if n->steps.size() > 0 {
            var unsafe *st = n->steps.get(n->steps.size() - 1)
            d = st->resolved_decl
        }

        if d != &null
            && (isa<Declarations::VariableDecl>(d)
                || isa<Declarations::FieldDecl>(d)
                    && cast<Declarations::FieldDecl>(d)->is_static()) {
            self._check_ctx_name(n, d)
        }

        return true
    }

    fn visit_expr(self, e: *Expr) -> bool {
        if self._ctx == 0 || e->type_ == &null {
            return true
        }

        // A string literal is a compile-time string (Compiler/Spec/Eval.md#strings-at-compile-time): its bytes
        // are a constant array and the literal constructor is constexpr. An
        // f-string is not: it formats into a heap buffer.
        var *sl? = dyn_cast<StringLiteralExpr>(e)
        if sl != &null && sl->is_format() {
            var fb = self.sc->diag->report(
                DiagID::SC116E,
                e->range.start,
                "an f-string in an eval context is not yet supported",
            )

            fb.first(e->range)
            fb.emit()
            return false
        }

        if sl != &null {
            sl->const_eval = true
            return true
        }

        // The collection literals are eval-able by design (Compiler/Spec/Eval.md#evaluable-values) but
        // have no compile-time C++ form yet (2b): vectors, sets and maps do
        // not even compile at run time. Reported once, at the outermost one.
        var unsafe *t   = e->type_
        var        what = self._wide_float(t)
        if what.size() == 0 {
            if self.tu.is_vector_like(t) {
                what = "a vector"
            } else if self.tu.is_set_like(t) {
                what = "a set"
            } else if self.tu.is_map_like(t) {
                what = "a map"
            }
        }

        if what.size() == 0 {
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            e->range.start,
            f"{what} in an eval context is not yet supported",
        )

        b.first(e->range)
        b.emit()
        return false
    }

    fn visit_await_expr(self, n: *Expressions::AwaitExpr) -> bool {
        if self._ctx > 0 {
            self._err(
                n->range,
                "an eval context cannot 'await'; there is no scheduler at compile time",
            )
        }

        return true
    }

    fn visit_spawn_expr(self, n: *Expressions::SpawnExpr) -> bool {
        if self._ctx > 0 {
            self._err(
                n->range,
                "an eval context cannot 'spawn'; there is no scheduler at compile time",
            )
        }

        return true
    }

    fn visit_panic_stmt(self, n: *PanicStmt) -> bool {
        if self._ctx > 0 {
            self._err(
                n->range,
                "an eval context cannot 'panic'; there is no error handler at compile time",
            )
        }

        return true
    }

    priv fn _in_eval_fn(self) -> bool {
        return self._fns.size() > 0 && self._fns[self._fns.size() - 1]->is_eval()
    }

    /// # eval for

    fn traverse_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> unsafe *RangedForStmt {
        if !n->is_eval || self._in_eval_fn() {
            return RecursiveASTVisitor<EvalUsageChecking>::traverse_ranged_for_stmt(self, n)
        }

        self._check_eval_for(n)
        if n->iterable != &null {
            self._ef_iters.push_back(n->iterable)
            n->iterable = self.dyn()->dispatch_expr(n->iterable)
            self._ef_iters.pop_back()
        }

        var pushed = false
        if n->bindings.size() == 1 && n->bindings[0].decl != &null {
            self._ef_binds.push_back(n->bindings[0].decl)
            pushed = true
        }

        self._ef_depth += 1
        n->body = self.dyn()->traverse_block(n->body)
        self._ef_depth -= 1
        if pushed {
            self._ef_binds.pop_back()
        }

        return n
    }

    fn visit_indexed_for_stmt(self, n: *IndexedForStmt) -> bool {
        if !n->is_eval || self._in_eval_fn() {
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC190E,
            n->range.start,
            "an 'eval for' iterates a range, an eval array or an eval generator; the C-style form is not one: write 'eval for i in lo..hi'",
        )

        b.first(SourceRange::from_bounds(n->range.start, 8 as u32))
        b.emit()
        return true
    }

    fn visit_labeled_stmt(self, n: *LabeledStmt) -> bool {
        var unsafe *rf = dyn_cast<RangedForStmt>(n->inner)
        if rf == &null || !rf->is_eval || self._in_eval_fn() {
            return true
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            n->range.start,
            "a labeled 'eval for' is not yet supported",
        )

        b.first(n->range)
        b.emit()
        return true
    }

    priv fn _check_eval_for(self, n: unsafe *RangedForStmt) {
        if n->bindings.size() != 1 {
            self._err(n->range, "an 'eval for' binds one name; destructure inside the body")
            return
        }

        self._check_return_slot(n)
        var unsafe *it = n->iterable
        if it == &null || it->is_poisoned() || it->type_ == &null {
            return
        }

        var unsafe *e = self.tu.strip_parens(it)

        if isa<Expressions::RangeExpr>(e) {
            var unsafe *r = cast<Expressions::RangeExpr>(e)
            if r->begin == &null || r->end == &null {
                self._err(e->range, "an 'eval for' over a range needs both bounds")
                return
            }

            self._need_eval(r->begin, "the lower bound of an 'eval for' range")
            self._need_eval(r->end, "the upper bound of an 'eval for' range")
            return
        }

        // An eval generator: a call of an `eval fn ... -> yield T`.
        var unsafe *call = dyn_cast<Expressions::CallExpr>(e)
        if call != &null {
            var unsafe *f = self._callee_fn(call)
            if f != &null && f->is_generator {
                if !f->is_eval() {
                    var nm = self.tu.decl_name(f)
                    var b = self.sc->diag->report(
                        DiagID::SC190E,
                        e->range.start,
                        f"an 'eval for' iterates an eval generator; '{nm}' is not 'eval'",
                    )

                    b.first(e->range)
                    b.note(
                        DiagCode(DiagID::SC190N),
                        f->range.start,
                        named_declared_here(nm),
                    )->child_first(f->name.range)
                    if !self._foreign(f) {
                        b.insert(f->range.start, "eval ", f"make '{nm}' an 'eval fn'")
                    }

                    b.emit()
                    return
                }

                for var i: usize = 0; i < call->args.size(); ++i {
                    self._need_eval(call->args[i], "an argument of an 'eval for' generator")
                }

                return
            }
        }

        // An array: an eval constant, or a list literal of eval-able elements.
        var unsafe *at = canon_unqual(it->type_)
        if at != &null && isa<FixedArrayType>(at) && !cast<FixedArrayType>(at)->is_incomplete {
            if isa<Expressions::ListLiteralExpr>(e) {
                var unsafe *ll = cast<Expressions::ListLiteralExpr>(e)
                for var i: usize = 0; i < ll->elements.size(); ++i {
                    self._need_eval(ll->elements[i], "an element of an 'eval for' array")
                }

                return
            }

            if self._eval_able(e) {
                return
            }
        }

        var b = self.sc->diag->report(
            DiagID::SC190E,
            e->range.start,
            f"an 'eval for' iterates a range with eval bounds, an eval array or an eval generator; this is '{self.tu.str(it->type_)}'",
        )

        b.first(e->range)
        var unsafe *pv = self._plain_var(e)
        if pv != &null {
            var pn = self.sc->ctx->get_spelling(pv->name)
            b.note(
                DiagCode(DiagID::SC190N),
                pv->name.range.start,
                f"'{pn}' is declared here, not as 'eval'",
            )->child_first(pv->name.range)
        }

        b.emit()
    }

    /// A `return` with a value inside an `eval for` goes through a slot the
    /// expansion default-constructs (EmitIR::_eval_for).
    priv fn _check_return_slot(self, n: unsafe *RangedForStmt) {
        if self._fns.size() == 0 {
            return
        }

        var unsafe *f = self._fns[self._fns.size() - 1]
        if f->return_type == &null || f->return_type->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(f->return_type->canonical)
        if c == &null || isa<BuiltinType>(c) || isa<PointerType>(c) || isa<GenericParamType>(c) {
            return
        }

        var unsafe *rd = if (isa<RecordType>(c)) => (cast<RecordType>(c)->decl) else => &null
        if rd != &null
            && isa<Declarations::EnumDecl>(rd)
            && !cast<Declarations::EnumDecl>(rd)->is_adt {
            return
        }

        var rs = ReturnFinder()
        rs.dispatch_stmt(n->body)
        if rs.found == &null {
            return
        }

        var b = self.sc->diag->report(
            DiagID::SC116E,
            rs.found->range.start,
            f"returning a '{self.tu.str(c)}' from inside an 'eval for' is not yet supported; return it after the loop",
        )

        b.first(rs.found->range)
        b.emit()
    }

    /// # eval generators

    fn visit_call_expr(self, n: unsafe *Expressions::CallExpr) -> bool {
        if self._ctx > 0 {
            self._check_ctx_call(n)
        }

        var unsafe *f = self._callee_fn(n)
        // An eval call from run-time code is an immediate invocation: C++
        // evaluates its arguments at compile time, strings included.
        if self._ctx == 0 && f != &null && f->is_eval() {
            var m = ConstEvalStrings()
            for var i: usize = 0; i < n->args.size(); ++i {
                m.dispatch_expr(n->args[i])
            }
        }

        if f == &null || !f->is_eval() || !f->is_generator {
            return true
        }

        var unsafe *e = unsafe (n as unsafe *Expr)
        for var i: usize = 0; i < self._ef_iters.size(); ++i {
            if self.tu.strip_parens(self._ef_iters[i]) == e {
                return true
            }
        }

        var nm = self.tu.decl_name(f)
        var b = self.sc->diag->report(
            DiagID::SC190E,
            n->range.start,
            f"'{nm}' is an eval generator; it runs at compile time and can only be iterated by an 'eval for'",
        )

        b.first(n->range)
        b.note(DiagCode(DiagID::SC190N), f->range.start, named_declared_here(nm))->child_first(
            f->name.range,
        )

        b.emit()
        return true
    }

    /// # eval if (a body's, left as `if constexpr`)

    fn visit_conditional_stmt(self, n: *ConditionalStmt) -> bool {
        if !n->is_eval || self._in_eval_fn() {
            return true
        }

        if n->cond == &null || n->cond->is_poisoned() {
            return true
        }

        self._impl_tests(n->cond)
        self._need_eval(n->cond, "the condition of an 'eval if'")
        return true
    }

    /// `A impl I` in a body's `eval if`: C++ decides it per
    /// instantiation through I's concept (EmitIR::_constraint), so it is
    /// compile-time -- but only over a generic parameter, the one subject
    /// with a concept argument to spell and a branch ChainBinding narrows.
    /// `derives` has no concept yet. Each other form is reported here;
    /// _first_runtime passes every ConstraintExpr, so none is reported twice.
    priv fn _impl_tests(self, e0: unsafe *Expr) {
        var unsafe *e = self.tu.strip_parens(e0)
        if e == &null || e->is_poisoned() {
            return
        }

        var unsafe *b = dyn_cast<Expressions::BinaryOperatorExpr>(e)
        if b != &null && b->resolved_op == &null {
            self._impl_tests(b->lhs)
            self._impl_tests(b->rhs)
            return
        }

        var unsafe *u = dyn_cast<Expressions::UnaryOperatorExpr>(e)
        if u != &null && u->resolved_op == &null {
            self._impl_tests(u->operand)
            return
        }

        var unsafe *c = dyn_cast<Expressions::ConstraintExpr>(e)
        if c == &null {
            return
        }

        var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
        var on_param = id != &null
            && id->resolved_decl != &null
            && isa<Declarations::GenericParamDecl>(id->resolved_decl)
        if c->is_derives() {
            var d = self.sc->diag->report(
                DiagID::SC191E,
                e->range.start,
                "'derives' in a function-body 'eval if' is not supported yet; test an interface with 'impl'",
            )

            d.first(e->range)
            d.emit()
            return
        }

        if !on_param {
            var d = self.sc->diag->report(
                DiagID::SC191E,
                e->range.start,
                "an 'impl' test in a function-body 'eval if' must name a generic parameter of the function or its class",
            )

            d.first(c->lhs->range)
            d.emit()
        }
    }

    /// # eval-able

    /// \p e must be eval-able (file header); reported at its first part that
    /// is not, as \p what.
    priv fn _need_eval(self, e: unsafe *Expr, const what: string) {
        if e == &null || e->is_poisoned() {
            return
        }

        var unsafe *bad = self._first_runtime(e)
        if bad == &null {
            return
        }

        var b = self.sc->diag->report(
            DiagID::SC192E,
            bad->range.start,
            f"{what} must be evaluable at compile time; this is a run-time value",
        )

        b.first(bad->range)
        var unsafe *pv = self._plain_var(bad)
        if pv != &null {
            var pn = self.sc->ctx->get_spelling(pv->name)
            b.note(
                DiagCode(DiagID::SC192N),
                pv->name.range.start,
                f"'{pn}' is declared here, not as 'eval'",
            )->child_first(pv->name.range)
        }

        b.emit()
    }

    priv fn _eval_able(self, e: unsafe *Expr) -> bool {
        return self._first_runtime(e) == &null
    }

    /// The first sub-expression of \p e0 that is not eval-able, or null.
    priv fn _first_runtime(self, e0: unsafe *Expr) -> unsafe *Expr {
        if e0 == &null {
            return &null
        }

        var unsafe *e = self.tu.strip_parens(e0)
        if e == &null {
            return &null
        }

        // An f256 / f512 value is a run-time call even as a literal.
        if self._wide_float(e->type_).size() > 0 {
            return e
        }

        if isa<IntegerLiteralExpr>(e)
            || isa<FloatingLiteralExpr>(e)
            || isa<BooleanLiteralExpr>(e)
            || isa<CharacterLiteralExpr>(e)
            || isa<StringLiteralExpr>(e)
            || isa<NullLiteralExpr>(e) {
            return &null
        }

        if isa<Expressions::SizeOfExpr>(e)
            || isa<Expressions::AlignOfExpr>(e)
            || isa<Expressions::TypeOfExpr>(e)
            || isa<Expressions::TypeTraitExpr>(e) {
            return &null
        }

        // A type test: its operands are types. _impl_tests reports the forms
        // codegen cannot spell.
        if isa<Expressions::ConstraintExpr>(e) {
            return &null
        }

        if isa<Expressions::UnaryOperatorExpr>(e) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(e)
            if u->resolved_op != &null {
                return e
            }

            var k = u->op_token.kind
            if k == TokenKind::OpAmp || k == TokenKind::OpStar { // pointers: no address at compile time.
                return e
            }

            return self._first_runtime(u->operand)
        }

        if isa<Expressions::BinaryOperatorExpr>(e) {
            var unsafe *b = cast<Expressions::BinaryOperatorExpr>(e)
            if b->resolved_op != &null {
                return e
            }

            // `typeof T == U`: two types compared, never a value.
            if b->type_cmp_lhs != &null {
                return &null
            }

            var unsafe *l = self._first_runtime(b->lhs)
            if l != &null {
                return l
            }

            return self._first_runtime(b->rhs)
        }

        if isa<Expressions::TypeCastExpr>(e) {
            var unsafe *c = cast<Expressions::TypeCastExpr>(e)
            if c->resolved_op != &null || c->resolved_ctor != &null {
                return e
            }

            return self._first_runtime(c->operand)
        }

        if isa<Expressions::ListLiteralExpr>(e) {
            var unsafe *ll = cast<Expressions::ListLiteralExpr>(e)
            for var i: usize = 0; i < ll->elements.size(); ++i {
                var unsafe *x = self._first_runtime(ll->elements[i])
                if x != &null {
                    return x
                }
            }

            return &null
        }

        if isa<NamedIdentExpr>(e) {
            return if (self._eval_decl(cast<NamedIdentExpr>(e)->resolved_decl)) => (&null) else => e
        }

        if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            if ch->steps.size() == 0 {
                return e
            }

            var unsafe *st = ch->steps.get(ch->steps.size() - 1)
            var unsafe *d  = if (st->name != &null) => (st->name->resolved_decl) else => &null
            if d == &null {
                d = st->resolved_decl
            }

            // A qualified name the typer left to each instantiation
            // (`cxx::std::is_trivially_destructible<T>::value`, MemberTyping):
            // C++ checks it per instance -- `if constexpr` refuses a non-
            // constant there -- so here it is no run-time value. `::` steps
            // only: a member read off a value (`x.n`) is never constant.
            if d == &null && e->is_instantiation_dependent() {
                var all_scope = true
                for var i: usize = 0; i < ch->steps.size(); ++i {
                    if ch->steps.get(i)->access_kind != ChainExpr::AccessKind::ColonColon {
                        all_scope = false
                        break
                    }
                }

                if all_scope {
                    return &null
                }
            }

            return if (self._eval_decl(d)) => (&null) else => e
        }

        if isa<Expressions::CallExpr>(e) {
            var unsafe *c = cast<Expressions::CallExpr>(e)
            var unsafe *f = self._callee_fn(c)
            if f == &null || !f->is_eval() {
                return e
            }

            for var i: usize = 0; i < c->args.size(); ++i {
                var unsafe *x = self._first_runtime(c->args[i])
                if x != &null {
                    return x
                }
            }

            return &null
        }

        return e
    }

    /// A name that is a compile-time constant here.
    priv fn _eval_decl(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var unsafe *vd = dyn_cast<Declarations::VariableDecl>(d)
        if vd != &null {
            if vd->is_eval() {
                return true
            }

            for var i: usize = 0; i < self._ef_binds.size(); ++i {
                if self._ef_binds[i] == d {
                    return true
                }
            }

            return false
        }

        var unsafe *fd = dyn_cast<Declarations::FieldDecl>(d)
        if fd != &null {
            return fd->is_eval()
        }

        var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(d)
        if gp != &null {
            return gp->is_const_param
        }

        if isa<Declarations::EnumVariantDecl>(d) {
            return true
        }

        return false
    }

    /// # helpers

    /// The function a call selected, or null.
    priv fn _callee_fn(self,
                       c: unsafe *Expressions::CallExpr) -> unsafe *Declarations::FunctionDecl {
        if c->ctor_decl != &null && isa<Declarations::FunctionDecl>(c->ctor_decl) {
            return cast<Declarations::FunctionDecl>(c->ctor_decl)
        }

        var unsafe *e = self.tu.strip_parens(c->callee)
        if e == &null {
            return &null
        }

        var d: unsafe *Decl = &null
        if isa<NamedIdentExpr>(e) {
            d = cast<NamedIdentExpr>(e)->resolved_decl
        } else if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            if ch->steps.size() > 0 {
                var unsafe *st = ch->steps.get(ch->steps.size() - 1)
                d = st->resolved_decl
                if d == &null && st->name != &null {
                    d = st->name->resolved_decl
                }
            }
        }

        return dyn_cast<Declarations::FunctionDecl>(d)
    }

    priv fn _foreign(self, d: unsafe *Decl) -> bool {
        return self.tu.is_foreign(d)
    }

    /// The non-eval variable \p e names, for a note; null if none.
    priv fn _plain_var(self, e: unsafe *Expr) -> unsafe *Declarations::VariableDecl {
        if e == &null || !isa<NamedIdentExpr>(e) {
            return &null
        }

        return dyn_cast<Declarations::VariableDecl>(cast<NamedIdentExpr>(e)->resolved_decl)
    }

    priv fn _err(self, at: SourceRange, const msg: string) {
        var b = self.sc->diag->report(DiagID::SC194E, at.start, msg)
        b.first(at)
        b.emit()
    }

    /// # emission order (Compiler/Spec/Eval.md#value-nodes)
    ///
    /// A declaration's type may hold a value C++ computes from an eval fn or
    /// an eval binding (`[i32; f(3)]`, `Buf<twice(1)>`). EmitPlan defines
    /// those items, and what they read, ahead of the declaration (its early
    /// items); each needs the records its body lays out complete first. When
    /// such a record is the declaration's own -- directly, or through another
    /// record that needs it -- no order exists: that is the error here, at
    /// the type, rather than a clang error on emitted text or an ordering
    /// ICE. So is an eval binding whose value reaches itself through the eval
    /// fns and bindings it reads.

    /// Every needs record computed, flattened, in the order computed; and
    /// the items whose rows are in it.
    priv var _nd_done: cxx::std::vector<unsafe *Decl>
    priv var _nd:      cxx::std::vector<EvalNeedRow>

    priv fn _needs_of(self, item: unsafe *Decl) {
        for var i: usize = 0; i < self._nd_done.size(); ++i {
            if self._nd_done[i] == item {
                return
            }
        }

        self._nd_done.push_back(item)
        var        n   = EvalNeeds(unsafe &self.tu)
        var unsafe *dc = item->semantic_dc
        if dc != &null && dc->is_type_scope() && dc->dc_kind != DeclContextKind::Extension {
            n.rec(dc->owner_decl(), item->range)
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(item)
        if f != &null {
            var unsafe *def = f
            if !def->has_body() {
                def = f->definition()
            }

            if def != &null {
                n.dispatch_decl(unsafe (def as unsafe *Decl))
            }
        }

        var unsafe *v = dyn_cast<Declarations::VariableDecl>(item)
        if v != &null {
            n.rec_type(v->type_, v->range)
            if v->init != &null {
                n.dispatch_expr(v->init)
            }
        }

        var unsafe *fd = dyn_cast<Declarations::FieldDecl>(item)
        if fd != &null {
            n.rec_type(fd->type_, fd->range)
            if fd->init != &null {
                n.dispatch_expr(fd->init)
            }
        }

        for var i: usize = 0; i < n.items.size(); ++i {
            if n.items[i] == item {
                continue
            }

            var row = EvalNeedRow{}
            row.key  = item
            row.kind = EvalNeedKind::Item
            row.val  = n.items[i]
            row.at   = item->range
            self._nd.push_back(row)
        }

        for var i: usize = 0; i < n.recs.size(); ++i {
            var row = EvalNeedRow{}
            row.key  = item
            row.kind = EvalNeedKind::Record
            row.val  = n.recs[i]
            row.at   = n.at[i]
            self._nd.push_back(row)
        }
    }

    /// \p seeds and every item they read, transitively, into \p out.
    priv fn _closure(self,
                     seeds: unsafe *cxx::std::vector<unsafe *Decl>,
                     out:   unsafe *cxx::std::vector<unsafe *Decl>) {
        for var i: usize = 0; i < seeds->size(); ++i {
            self._add_once(&*out, (*seeds)[i])
        }

        for var k: usize = 0; k < out->size(); ++k {
            var unsafe *it = (*out)[k]
            self._needs_of(it)
            for var i: usize = 0; i < self._nd.size(); ++i {
                if self._nd[i].key == it && self._nd[i].kind == EvalNeedKind::Item {
                    self._add_once(&*out, self._nd[i].val)
                }
            }
        }
    }

    priv fn _add_once(self, @inout v: cxx::std::vector<unsafe *Decl>, d: unsafe *Decl) {
        for var i: usize = 0; i < v.size(); ++i {
            if (v)[i] == d {
                return
            }
        }

        v.push_back(d)
    }

    /// The items computed values in \p t name (a declaration's type).
    priv fn _type_items(self, t: unsafe *Type, out: unsafe *cxx::std::vector<unsafe *Decl>) {
        var n = EvalNeeds(unsafe &self.tu)
        n.rec_type(t, SourceRange::invalid())
        if t != &null && t->canonical != &null {
            n.values(t->canonical, SourceRange::invalid())
        }

        for var i: usize = 0; i < n.items.size(); ++i {
            self._add_once(&*out, n.items[i])
        }
    }

    /// The types written in \p r's own definition: fields, bases, method
    /// signatures (C++ reads all of them inside the class body).
    priv fn _member_types(self,
                          r:            unsafe *Decl,
                          @inout out:   cxx::std::vector<unsafe *Type>,
                          @inout spots: cxx::std::vector<SourceRange>) {
        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        if isa<Declarations::ClassDecl>(r) {
            var unsafe *c = cast<Declarations::ClassDecl>(r)
            fields  = unsafe &c->fields
            methods = unsafe &c->methods
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e = c->derives_list.get(i)
                if e != &null && e->base != &null {
                    out.push_back(e->base)
                    spots.push_back(e->base->range)
                }
            }
        } else if isa<Declarations::StructDecl>(r) {
            fields  = unsafe &cast<Declarations::StructDecl>(r)->fields
            methods = unsafe &cast<Declarations::StructDecl>(r)->methods
        } else if isa<Declarations::UnionDecl>(r) {
            fields  = unsafe &cast<Declarations::UnionDecl>(r)->fields
            methods = unsafe &cast<Declarations::UnionDecl>(r)->methods
        }

        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var unsafe *f = (*fields)[i]
                if f == &null || f->type_ == &null {
                    continue
                }

                out.push_back(f->type_)
                spots.push_back(f->type_->range)
            }
        }

        if methods != &null {
            for var i: usize = 0; i < methods->size(); ++i {
                var unsafe *m = (*methods)[i]
                if m == &null {
                    continue
                }

                for var p: usize = 0; p < m->params.size(); ++p {
                    var unsafe *pd = m->params[p]
                    if pd == &null || pd->is_self || pd->type_ == &null {
                        continue
                    }

                    out.push_back(pd->type_)
                    spots.push_back(pd->type_->range)
                }

                if m->return_type != &null {
                    out.push_back(m->return_type)
                    spots.push_back(m->return_type->range)
                }
            }
        }
    }

    /// The records \p r needs complete before its definition: by-value
    /// fields and bases, and what the items its types name need.
    priv fn _rec_edges(self, r: unsafe *Decl, out: unsafe *cxx::std::vector<unsafe *Decl>) {
        var ts = cxx::std::vector<unsafe *Type>()
        var ws = cxx::std::vector<SourceRange>()
        self._member_types(r, &ts, &ws)
        var seeds = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < ts.size(); ++i {
            self._type_items(ts[i], unsafe &seeds)
        }

        // Method signatures name their types; only fields and bases lay
        // them out. Close enough: a by-value cycle through a signature is
        // no definition-order problem, so take fields and bases only.
        var lay                                                         = EvalNeeds(unsafe &self.tu)
        var fields: unsafe *FrozenList<unsafe *Declarations::FieldDecl> = &null
        if isa<Declarations::ClassDecl>(r) {
            fields = unsafe &cast<Declarations::ClassDecl>(r)->fields
            var unsafe *c = cast<Declarations::ClassDecl>(r)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e = c->derives_list.get(i)
                if e != &null {
                    lay.rec_type(e->base, r->range)
                }
            }
        } else if isa<Declarations::StructDecl>(r) {
            fields = unsafe &cast<Declarations::StructDecl>(r)->fields
        }

        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var unsafe *f = (*fields)[i]
                if f != &null && !f->is_static() && !f->is_eval() {
                    lay.rec_type(f->type_, r->range)
                }
            }
        }

        for var i: usize = 0; i < lay.recs.size(); ++i {
            if lay.recs[i] != r {
                self._add_once(&*out, lay.recs[i])
            }
        }

        var cl = cxx::std::vector<unsafe *Decl>()
        self._closure(unsafe &seeds, unsafe &cl)
        for var k: usize = 0; k < cl.size(); ++k {
            for var i: usize = 0; i < self._nd.size(); ++i {
                if self._nd[i].key == cl[k] && self._nd[i].kind == EvalNeedKind::Record {
                    self._add_once(&*out, self._nd[i].val)
                }
            }
        }
    }

    /// Whether record \p from reaches \p goal through _rec_edges.
    priv fn _rec_reaches(self,
                         from: unsafe *Decl,
                         goal: unsafe *Decl,
                         seen: unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        if from == goal {
            return true
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == from {
                return false
            }
        }

        seen->push_back(from)
        if seen->size() > 64 {
            return false
        }

        var es = cxx::std::vector<unsafe *Decl>()
        self._rec_edges(from, unsafe &es)
        for var i: usize = 0; i < es.size(); ++i {
            if self._rec_reaches(es[i], goal, seen) {
                return true
            }
        }

        return false
    }

    priv fn _check_order(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        var recs = cxx::std::vector<unsafe *Decl>()
        var vars = cxx::std::vector<unsafe *Declarations::VariableDecl>()
        self._own_decls(tu, unsafe &recs, unsafe &vars)
        for var i: usize = 0; i < recs.size(); ++i {
            self._check_record(recs[i])
        }

        for var i: usize = 0; i < vars.size(); ++i {
            self._check_var(vars[i])
        }
    }

    priv fn _own_decls(self,
                       dc:   unsafe *DeclContext,
                       recs: unsafe *cxx::std::vector<unsafe *Decl>,
                       vars: unsafe *cxx::std::vector<unsafe *Declarations::VariableDecl>) {
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null || d->is_poisoned() || decl_is_imported(d) {
                continue
            }

            if isa<Declarations::ModuleDecl>(d) {
                self._own_decls((cast<Declarations::ModuleDecl>(d)), recs, vars)
                continue
            }

            if isa<Declarations::VisibilityGroupDecl>(d) {
                var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
                for var k: usize = 0; k < g->members.size(); ++k {
                    var unsafe *m = g->members[k]
                    if m == &null {
                        continue
                    }

                    if isa<Declarations::ClassDecl>(m)
                        || isa<Declarations::StructDecl>(m)
                        || isa<Declarations::UnionDecl>(m) {
                        recs->push_back(m)
                    }

                    var unsafe *gv = dyn_cast<Declarations::VariableDecl>(m)
                    if gv != &null && gv->is_eval() && gv->init != &null {
                        vars->push_back(gv)
                    }
                }

                continue
            }

            if isa<Declarations::ClassDecl>(d)
                || isa<Declarations::StructDecl>(d)
                || isa<Declarations::UnionDecl>(d) {
                recs->push_back(d)
                var rdc: unsafe *DeclContext = &null
                if isa<Declarations::ClassDecl>(d) {
                    rdc = (cast<Declarations::ClassDecl>(d))
                } else if isa<Declarations::StructDecl>(d) {
                    rdc = (cast<Declarations::StructDecl>(d))
                }

                if rdc != &null {
                    var nested = cxx::std::vector<unsafe *Declarations::VariableDecl>()
                    self._own_decls(rdc, recs, unsafe &nested)
                }

                continue
            }

            var unsafe *v = dyn_cast<Declarations::VariableDecl>(d)
            if v != &null && v->is_eval() && v->init != &null {
                vars->push_back(v)
            }
        }
    }

    /// \p r's types, or the value predicates of its `requires`, name a
    /// value C++ computes from items that need \p r complete (or a record
    /// that does): SC001E at the first one. A generic record is checked on
    /// its primary: an instance its items name (`sizeof R<1>`) is mapped to
    /// the pattern (EvalNeeds::rec), and every instance's definition
    /// evaluates the same items, so a cycle through one is a cycle through
    /// all. A dependent instance (`R<M + 1>` in a generic eval fn) is not a
    /// need (EvalNeeds::rec_type): whether it closes a cycle depends on the
    /// arguments, which is C++'s to report per instance.
    priv fn _check_record(self, r: unsafe *Decl) {
        var ts = cxx::std::vector<unsafe *Type>()
        var ws = cxx::std::vector<SourceRange>()
        self._member_types(r, &ts, &ws)
        for var t: usize = 0; t < ts.size(); ++t {
            var seeds = cxx::std::vector<unsafe *Decl>()
            self._type_items(ts[t], unsafe &seeds)
            if self._check_seeds(r, unsafe &seeds, ws[t], "this type has a value C++ computes") {
                return
            }
        }

        // A record's value predicates are checked inside its definition
        // (InterfaceEmitter::_record_def's static_asserts), after the items
        // they name (EmitPlan::_decl_type_items): the same order problem.
        var vps = cxx::std::vector<unsafe *Expr>()
        EvalUsageChecking::_value_preds(decl_requires_clause(r), unsafe &vps)
        for var i: usize = 0; i < vps.size(); ++i {
            var n = EvalNeeds(unsafe &self.tu)
            n.dispatch_expr(vps[i])
            var seeds = cxx::std::vector<unsafe *Decl>()
            for var k: usize = 0; k < n.items.size(); ++k {
                seeds.push_back(n.items[k])
            }

            if self._check_seeds(
                r,
                unsafe &seeds,
                vps[i]->range,
                "this requires predicate is a value C++ computes",
            ) {
                return
            }
        }
    }

    /// The VALUE conjuncts of requires clause \p e (not `T impl I` / `T
    /// derives B`), as _check_requires splits them.
    static fn _value_preds(e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *Expr>) {
        if e == &null || e->is_poisoned() {
            return
        }

        var unsafe *b = dyn_cast<Expressions::BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            EvalUsageChecking::_value_preds(b->lhs, out)
            EvalUsageChecking::_value_preds(b->rhs, out)
            return
        }

        if isa<Expressions::ConstraintExpr>(e) {
            return
        }

        out->push_back(e)
    }

    /// Whether items \p seeds, read at \p at, reach one that needs \p r
    /// complete (or a record that reaches \p r); reported when they do.
    priv fn _check_seeds(self,
                         r:          unsafe *Decl,
                         seeds:      unsafe *cxx::std::vector<unsafe *Decl>,
                         at:         SourceRange,
                         const what: string) -> bool {
        if seeds->size() == 0 {
            return false
        }

        var cl = cxx::std::vector<unsafe *Decl>()
        self._closure(seeds, unsafe &cl)
        // The first item needing r, or a record that reaches r.
        for var k: usize = 0; k < cl.size(); ++k {
            for var i: usize = 0; i < self._nd.size(); ++i {
                if self._nd[i].key != cl[k] || self._nd[i].kind != EvalNeedKind::Record {
                    continue
                }

                var unsafe *need              = self._nd[i].val
                var        via:  unsafe *Decl = &null
                if need != r {
                    var seen = cxx::std::vector<unsafe *Decl>()
                    seen.push_back(r)
                    if !self._rec_reaches_from(need, r, unsafe &seen) {
                        continue
                    }

                    via = need
                }

                self._report_cycle(r, at, cl[k], via, self._nd[i].at, what)
                return true
            }
        }

        return false
    }

    /// _rec_reaches, with \p seen already holding the start record.
    priv fn _rec_reaches_from(self,
                              from: unsafe *Decl,
                              goal: unsafe *Decl,
                              seen: unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == from && from != goal {
                return false
            }
        }

        if from == goal {
            return true
        }

        seen->push_back(from)
        var es = cxx::std::vector<unsafe *Decl>()
        self._rec_edges(from, unsafe &es)
        for var i: usize = 0; i < es.size(); ++i {
            if es[i] == goal {
                return true
            }

            if self._rec_reaches(es[i], goal, seen) {
                return true
            }
        }

        return false
    }

    priv fn _report_cycle(self,
                          r:          unsafe *Decl,
                          at:         SourceRange,
                          item:       unsafe *Decl,
                          via:        unsafe *Decl,
                          need_at:    SourceRange,
                          const what: string) {
        var rn  = self.tu.decl_name(r)
        var inn = self.tu.decl_name(item)
        var why = f"which needs '{rn}' complete"
        if via != &null {
            why = f"which needs '{self.tu.decl_name(via)}' complete, and '{self.tu.decl_name(via)}' needs '{rn}'"
        }

        var b = self.sc->diag->report(
            DiagID::SC195E,
            at.start,
            f"{what} from '{inn}', {why}; inside its own definition '{rn}' is not complete yet, so no order of the C++ declarations can compute it",
        )

        b.first(at)
        var nn = if (via == &null) => (rn) else => self.tu.decl_name(via)
        if need_at.is_valid() {
            b.note(
                DiagCode(DiagID::SC195N),
                need_at.start,
                f"'{inn}' needs '{nn}' complete here",
            )->child_first(need_at)
        } else {
            b.note(DiagCode(DiagID::SC195N), item->range.start, named_declared_here(inn))->child_first(
                item->range,
            )
        }

        b.emit()
    }

    /// An eval binding whose value reaches itself through the eval fns and
    /// bindings it reads: no constant at all (C++ would report an
    /// initializer that is not a constant expression).
    priv fn _check_var(self, v: unsafe *Declarations::VariableDecl) {
        var n = EvalNeeds(unsafe &self.tu)
        n.dispatch_expr(v->init)
        var seeds = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < n.items.size(); ++i {
            seeds.push_back(n.items[i])
        }

        var cl = cxx::std::vector<unsafe *Decl>()
        self._closure(unsafe &seeds, unsafe &cl)
        var unsafe *me = unsafe (v as unsafe *Decl)
        var        hit = false
        for var i: usize = 0; i < cl.size(); ++i {
            if cl[i] == me {
                hit = true
                break
            }
        }

        if !hit {
            return
        }

        var vn  = self.sc->ctx->get_spelling(v->name)
        var via = ""
        if seeds.size() > 0 {
            via = f" through '{self.tu.decl_name(seeds[0])}'"
        }

        var b = self.sc->diag->report(
            DiagID::SC196E,
            v->name.range.start,
            f"the value of 'eval {vn}' depends on itself{via}; an eval binding cannot be computed from its own value",
        )

        b.first(v->name.range)
        if v->init != &null {
            b.note(
                DiagCode(DiagID::SC196N),
                v->init->range.start,
                "its initializer, which reads it back",
            )->child_first(v->init->range)
        }

        b.emit()
    }
}
