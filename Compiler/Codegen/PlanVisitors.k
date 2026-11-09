/// --- The Kairo Project ----------------------- Codegen/PlanVisitors.k --- ///
///
///   Read-only tree walks EmitPlan and EmitIR run over a TU: HoistedLocals,
///   EarlyNeeds (what a compile-time item needs first) and GlobalInitReach
///   (whether a global's initializer needs a befriended thunk).
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

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::DeclContextKind
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::decl_is_imported
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    QualifiedType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, FieldDecl, FieldFold, FnBodyKind, FunctionDecl, ParamDecl, StructDecl, VariableDecl,
}
import AST::Node::Expressions::{
    AlignOfExpr,  AssignOperatorExpr, BinaryOperatorExpr, CallExpr, SizeOfExpr, SubscriptExpr,
    TypeCastExpr, TypeTraitExpr,      UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::DeclStmt
import AST::Node::Types::{
    FixedArrayType,
    NullableType,
    TypeExpr,
    ValueOp,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Codegen::Emit::CXXSpell::{
    CXXSpell,
    VIS_PUB,
}

/// Every hoisted local declaration (CXXSpell::is_hoisted_local) a TU's
/// program holds, in source order, an enclosing one before those nested in
/// it. The plan roots each one as an own declaration and EmitIR emits each
/// one's bodies at namespace scope, so both walk the same list.
pub class HoistedLocals derives RecursiveASTVisitor<HoistedLocals> {
    pub var found: cxx::std::vector<unsafe *Decl>

    fn HoistedLocals(self) { }

    fn run(self, tu: unsafe *TranslationUnit) {
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
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

    fn visit_decl_stmt(self, n: unsafe *DeclStmt) -> bool {
        if n == &null || n->decl == &null || n->decl->is_poisoned() {
            return true
        }

        if CXXSpell::is_hoisted_local(n->decl) {
            self.found.push_back(n->decl)
        }

        return true
    }
}

/// What one compile-time item needs before C++ evaluates it (Compiler/Spec/Eval.md
/// §11): an `eval` / `constexpr` body, or an eval binding's initializer.
/// `items`: the compile-time bodies it calls (eval fns, eval and constexpr
/// constructors and operators, an eval field's thunk) and the eval bindings
/// it reads, each needed DEFINED before the item is evaluated. `const_items`:
/// the subset C++ evaluates where the item is DEFINED (what a type inside
/// it computes, an eval local's initializer), each needed defined before
/// the item's own definition. `recs`: the records it lays out or looks
/// into, needed COMPLETE before its definition. EmitPlan::_early reads
/// these on the lowered tree; EvalUsageChecking::EvalNeeds is the Sema
/// side, which reports what no order satisfies.
pub class EarlyNeeds derives RecursiveASTVisitor<EarlyNeeds> {
    pub var items:       cxx::std::vector<unsafe *Decl>
    pub var const_items: cxx::std::vector<unsafe *Decl>
    pub var recs:        cxx::std::vector<unsafe *Decl>
    /// > 0 inside an eval local's initializer: what it reads is a const item.
    priv var _const: u32 = 0

    fn EarlyNeeds(self) { }

    /// A compile-time body or an eval binding, as an item: the defining
    /// link of a function (what EmitIR emits), an eval field as its thunk;
    /// null for anything else.
    static fn item_of(d: unsafe *Decl) -> unsafe *Decl {
        if d == &null {
            return &null
        }

        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f != &null {
            if !f->is_eval() && !f->is_constexpr() {
                return &null
            }

            var unsafe *def = f
            if !def->has_body() {
                def = f->definition()
            }

            if def == &null || def->is_poisoned() || def->body_kind != FnBodyKind::Block {
                return &null
            }

            return def
        }

        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v != &null && v->is_eval() && v->init != &null && !v->is_poisoned() {
            var unsafe *dc = v->semantic_dc
            if dc != &null
                && (dc->dc_kind == DeclContextKind::TranslationUnit
                    || dc->dc_kind == DeclContextKind::Module) {
                return d
            }

            return &null
        }

        var unsafe *fd = dyn_cast<FieldDecl>(d)
        if fd != &null && fd->is_eval() && fd->init_fold == FieldFold::Thunk {
            return EarlyNeeds::item_of(fd->init_thunk)
        }

        return &null
    }

    fn named(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        var unsafe *dc = d->semantic_dc
        if dc != &null
            && dc->is_type_scope()
            && dc->dc_kind != DeclContextKind::Extension
            && dc->owner_decl() != &null {
            self._rec(dc->owner_decl())
        }

        var unsafe *it = EarlyNeeds::item_of(d)
        if it == &null {
            return
        }

        EarlyNeeds::_once(&self.items, it)
        if self._const > 0 {
            EarlyNeeds::_once(&self.const_items, it)
        }
    }

    static fn _once(@inout v: cxx::std::vector<unsafe *Decl>, d: unsafe *Decl) {
        for var i: usize = 0; i < v.size(); ++i {
            if (v)[i] == d {
                return
            }
        }

        v.push_back(d)
    }

    priv fn _rec(self, d: unsafe *Decl) {
        if d != &null {
            EarlyNeeds::_once(&self.recs, d)
        }
    }

    /// The records \p t holds by value (raw: EmitPlan maps each to its
    /// plan entry), and the items its computed values name.
    fn rec_type(self, t: unsafe *Type) {
        if t == &null {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                self.rec_type(cast<QualifiedType>(c)->inner)
            } case TypeKind::RecordType {
                var unsafe *rt = cast<RecordType>(c)
                self._rec(rt->decl)
                for var i: usize = 0; i < rt->args.size(); ++i {
                    self.values(*rt->args.get(i))
                }

                // `L<i32>::P` is laid out inside L<i32>'s instantiation.
                if rt->outer != &null {
                    self.rec_type(rt->outer)
                }
            } case TypeKind::FixedArrayType {
                self.rec_type(cast<FixedArrayType>(c)->element)
                self.values(cast<FixedArrayType>(c)->extent_param)
            } case TypeKind::NullableType {
                var unsafe *lw = cast<NullableType>(c)->lowered
                if lw != &null {
                    self.rec_type(lw)
                } else {
                    self.rec_type(cast<NullableType>(c)->inner)
                }
            } case TypeKind::TypeExpr {
                self.values(c)
            } default { }
        }
    }

    /// The items a computed value (Compiler/Spec/Eval.md#value-nodes) names: C++ evaluates it
    /// where it is spelled, so they are const items. An eval class it
    /// constructs is needed complete, with every compile-time member (its
    /// constructor, its field defaults' thunks).
    fn values(self, t: unsafe *Type) {
        var unsafe *v = dyn_cast<TypeExpr>(t)
        if v == &null || !v->is_value || v->is_exact() {
            return
        }

        self._const += 1
        if v->vop == ValueOp::Str {
            self.rec_type(v->vty)
            var unsafe *sr = dyn_cast<RecordType>(canon_unqual(v->vty))
            if sr != &null {
                self._members(sr->decl)
            }
        } else if v->vdecl != &null && (v->vop == ValueOp::Call || v->vop == ValueOp::Decl) {
            if isa<ClassDecl>(v->vdecl) || isa<StructDecl>(v->vdecl) {
                self._rec(v->vdecl)
                self._members(v->vdecl)
            } else {
                var local = v->vdecl->semantic_dc == &null || CXXSpell::in_function_scope(v->vdecl)
                if !local {
                    self.named(v->vdecl)
                }
            }
        }

        for var i: usize = 0; i < v->vops.size(); ++i {
            self.values(v->vops[i])
        }

        self._const -= 1
    }

    /// Every compile-time member of record \p d with a body, as items.
    priv fn _members(self, d: unsafe *Decl) {
        var ms: unsafe *FrozenList<unsafe *FunctionDecl> = &null
        if isa<ClassDecl>(d) {
            ms = unsafe &cast<ClassDecl>(d)->methods
        } else if isa<StructDecl>(d) {
            ms = unsafe &cast<StructDecl>(d)->methods
        }

        if ms == &null {
            return
        }

        for var i: usize = 0; i < ms->size(); ++i {
            var unsafe *m = (*ms)[i]
            if m == &null {
                continue
            }

            var unsafe *it = EarlyNeeds::item_of(unsafe (m as unsafe *Decl))
            if it == &null {
                continue
            }

            EarlyNeeds::_once(&self.items, it)
            if self._const > 0 {
                EarlyNeeds::_once(&self.const_items, it)
            }
        }
    }

    fn visit_expr(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return true
        }

        if e->type_ != &null {
            self.rec_type(e->type_)
        }

        match e->kind {
            case ExprKind::NamedIdentExpr {
                self.named(cast<NamedIdentExpr>(e)->resolved_decl)
            } case ExprKind::ChainExpr {
                var unsafe *ch = cast<ChainExpr>(e)
                for var i: usize = 0; i < ch->steps.size(); ++i {
                    var unsafe *st = ch->steps.get(i)
                    if st != &null {
                        self.named(st->resolved_decl)
                    }
                }
            } case ExprKind::CallExpr {
                self.named(cast<CallExpr>(e)->ctor_decl)
            } case ExprKind::BinaryOperatorExpr {
                var unsafe *bo = cast<BinaryOperatorExpr>(e)
                self.named(bo->resolved_op)
                // `typeof T == U`: EmitIR spells both types (__is_same).
                if bo->type_cmp_lhs != &null {
                    self.rec_type(bo->type_cmp_lhs)
                    self.rec_type(bo->type_cmp_rhs)
                }
            } case ExprKind::UnaryOperatorExpr {
                self.named(cast<UnaryOperatorExpr>(e)->resolved_op)
            } case ExprKind::SizeOfExpr {
                self.rec_type(cast<SizeOfExpr>(e)->type_arg)
            } case ExprKind::AlignOfExpr {
                self.rec_type(cast<AlignOfExpr>(e)->type_arg)
            } case ExprKind::TypeTraitExpr {
                self.rec_type(cast<TypeTraitExpr>(e)->type_arg)
            } default { }
        }

        return true
    }

    fn visit_decl(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return true
        }

        match d->kind {
            case DeclKind::VariableDecl {
                self.rec_type(cast<VariableDecl>(d)->type_)
            } case DeclKind::ParamDecl {
                var unsafe *p = cast<ParamDecl>(d)
                if !p->is_self {
                    self.rec_type(p->type_)
                }
            } case DeclKind::FunctionDecl {
                self.rec_type(cast<FunctionDecl>(d)->return_type)
            } default { }
        }

        return true
    }

    /// An eval local's initializer is a constant expression C++ evaluates
    /// at the definition (`constexpr T k = g(1);`).
    fn traverse_variable_decl(self, n: unsafe *VariableDecl) -> unsafe *VariableDecl {
        var ev = n->is_eval()
            && n->semantic_dc != &null
            && CXXSpell::in_function_scope(unsafe (n as unsafe *Decl))
        if ev {
            self._const += 1
        }

        var unsafe *r = RecursiveASTVisitor<EarlyNeeds>::traverse_variable_decl(self, n)
        if ev {
            self._const -= 1
        }

        return r
    }

    fn visit_type(self, t: unsafe *Type) -> bool {
        if t != &null && t->canonical != &null {
            self.values(t->canonical)
        }

        return true
    }
}

/// Whether a namespace-scope variable's initializer names a member C++
/// will see non-public (CXXSpell::cxx_access): a field, method, static,
/// constructor or operator of a record. Such a variable is initialized
/// through a befriended thunk (EmitIR::_global_var), since a C++ variable
/// initializer is checked in the variable's own context, which nothing can
/// befriend. Read off the typed tree, which every TU holding the file has.
pub class GlobalInitReach derives RecursiveASTVisitor<GlobalInitReach> {
    pub var spell: unsafe *CXXSpell = &null
    pub var hit:   bool             = false

    fn GlobalInitReach(self) { }

    static fn needs_thunk(spell: unsafe *CXXSpell, v: unsafe *VariableDecl) -> bool {
        if v == &null || v->init == &null || v->is_eval() || v->is_poisoned() {
            return false
        }

        if v->type_ == &null || v->type_->canonical == &null {
            return false
        }

        // No function returns an array: its initializer stays where it is.
        if canon_unqual(v->type_->canonical)->kind == TypeKind::FixedArrayType {
            return false
        }

        var r = GlobalInitReach()
        r.spell = spell
        r.dyn()->dispatch_expr(v->init)
        return r.hit
    }

    priv fn _see(self, d: unsafe *Decl) {
        if d == &null || self.hit || decl_is_imported(d) {
            return
        }

        var unsafe *dc = d->semantic_dc
        if dc == &null || !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return
        }

        if self.spell->cxx_access(d) != VIS_PUB() {
            self.hit  = true
            self.stop = true
        }
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st != &null {
                self._see(st->resolved_decl)
            }
        }

        return true
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        self._see(n->resolved_decl)
        return true
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        self._see(n->ctor_decl)
        return true
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        self._see(n->resolved_op)
        return true
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        self._see(n->resolved_op)
        return true
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        self._see(n->resolved_op)
        return true
    }

    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool {
        self._see(n->resolved_op)
        return true
    }

    fn visit_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        self._see(n->resolved_op)
        self._see(n->resolved_ctor)
        return true
    }
}
