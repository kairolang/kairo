/// --- The Kairo Project ---------------------- Codegen/Plan/Visitors.k --- ///
///
///   Read-only tree walks EmitPlan and EmitIR run over a TU: HoistedLocals,
///   EarlyNeeds (what a compile-time item needs first), GlobalInitReach
///   (whether a global's initializer needs a befriended thunk),
///   CaptureWrites (whether a closure's body can change its own captures),
///   and the two walks behind a generator's push form: GenBodyScan with
///   generator_push_form (which generators have one) and PushBodyScan (what
///   a loop body holds that decides how the loop is written).
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

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContextKind
import AST::Context::InstantiationRegistry::InstantiationRegistry
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_extension_of,
    decl_is_imported,
    decl_methods,
}
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
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
    AbiKind,
    ClassDecl,
    FieldDecl,
    FieldFold,
    FnBodyKind,
    FunctionDecl,
    ParamDecl,
    StructDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    AlignOfExpr,
    AssignOperatorExpr,
    AwaitExpr,
    BinaryOperatorExpr,
    CallExpr,
    CaptureMode,
    ClosureExpr,
    IfExpr,
    ParenExpr,
    SizeOfExpr,
    SubscriptExpr,
    TypeCastExpr,
    TypeTraitExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    ConditionalStmt,
    DeclStmt,
    IterKind,
    JumpIntrinsicStmt,
    LabelIntrinsicStmt,
    RangedForStmt,
    ReturnStmt,
    TryCatchStmt,
    WhileLoopStmt,
    YieldStmt,
}
import AST::Node::Types::{
    FixedArrayType,
    FunctionPointerType,
    GenericParamType,
    NullableType,
    PointerType,
    TypeExpr,
    ValueOp,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Codegen::Spell::Spell::{
    Speller,
    VIS_PUB,
}
import Token::TokenKind::TokenKind

/// Every hoisted local declaration (Speller::is_hoisted_local) a TU's
/// program holds, in source order, an enclosing one before those nested in
/// it. The plan roots each one as an own declaration and EmitIR emits each
/// one's bodies at namespace scope, so both walk the same list.
pub class HoistedLocals derives RecursiveASTVisitor<HoistedLocals> {
    pub var found: cxx::std::vector<unsafe *Decl>

    fn HoistedLocals(self) { }

    fn visit_decl_stmt(self, n: unsafe *DeclStmt) -> bool {
        if n == &null || n->decl == &null || n->decl->is_poisoned() {
            return true
        }

        if Speller::is_hoisted_local(n->decl) {
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

    /// The records `t` holds by value (raw: EmitPlan maps each to its
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
                var local = v->vdecl->semantic_dc == &null || Speller::in_function_scope(v->vdecl)
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

    /// Every compile-time member of record `d` with a body, as items.
    priv fn _members(self, d: unsafe *Decl) {
        var ms = decl_methods(d)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
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
            && Speller::in_function_scope(unsafe (n as unsafe *Decl))
        if ev {
            self._const += 1
        }

        var unsafe *r = RecursiveASTVisitor<EarlyNeeds>::traverse_variable_decl(
            self,
            n,
        )

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
/// will see non-public (Speller::cxx_access): a field, method, static,
/// constructor or operator of a record. Such a variable is initialized
/// through a befriended thunk (EmitIR::_global_var), since a C++ variable
/// initializer is checked in the variable's own context, which nothing can
/// befriend. Read off the typed tree, which every TU holding the file has.
pub class GlobalInitReach derives RecursiveASTVisitor<GlobalInitReach> {
    pub var spell: unsafe *Speller = &null
    pub var hit:   bool            = false

    fn GlobalInitReach(self) { }

    static fn needs_thunk(spell: unsafe *Speller, v: unsafe *VariableDecl) -> bool {
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

/// Whether a closure's body can change one of the closure's own captures:
/// the variable a by-copy capture is, or the pointer a by-pointer capture
/// is (what it points at is not the closure's). EmitIR holds a closure that
/// changes none in the `fn` value's own words, as a lambda that is not
/// `mutable` (EmitIR::_closure_small), so the answer must never be a wrong
/// "no": every use of a capture counts as a write unless it is one of the
/// reads listed here, each of which takes the capture's value and nothing
/// else. A read this walk does not know keeps the closure on the heap,
/// which is always correct; and a write it missed would not compile, since
/// C++ rejects a write to a capture of a lambda that is not `mutable`.
///
/// The reads, of a capture `x` (through any parentheses):
///   - an operand of a builtin binary operator, the right side of a
///     builtin assignment, the operand of builtin `*x`, `-x`, `+x`, `~x`,
///     `!x`, the operand of a builtin cast;
///   - `x->m`, the index of a subscript, the base of a builtin subscript;
///   - an argument of a call whose callee is a Kairo function, or a `fn`
///     value, that takes every parameter by value;
///   - a returned value, an `if` / `while` condition, an `if` expression's
///     condition or arm, the initializer of a variable that does not
///     borrow.
/// A closure nested in the body is not entered: its uses are of its own
/// captures. Its capture of `x` is a write when it takes a by-copy `x` by
/// mutable pointer or moves it.
pub class CaptureWrites derives RecursiveASTVisitor<CaptureWrites> {
    pub var  written: bool                           = false
    priv var _held:   cxx::std::vector<unsafe *Decl>
    priv var _mode:   cxx::std::vector<CaptureMode>
    priv var _reads:  cxx::std::vector<unsafe *Expr>
    /// A call's callee is a read (run_var).
    priv var _calls: bool = false

    fn CaptureWrites(self) { }

    fn run(self, c: unsafe *ClosureExpr) {
        for var i: usize = 0; i < c->held.size(); ++i {
            if c->held[i].mode == CaptureMode::Receiver {
                continue
            }

            self._held.push_back(c->held[i].decl)
            self._mode.push_back(c->held[i].mode)
        }

        if c->body_block != &null {
            self.dispatch_stmt(unsafe (c->body_block as unsafe *Stmt))
        }
    }

    /// The same question of one local, `d`, over `body`, the statements
    /// that can name it: whether anything there can change `d` itself. A
    /// call THROUGH `d` (a `fn` value) reads it. EmitIR asks this of a
    /// local bound to a small closure (EmitIR::_direct_closure).
    fn run_var(self, d: unsafe *Decl, body: unsafe *Stmt) {
        self._held.push_back(d)
        self._mode.push_back(CaptureMode::Copy)
        self._calls = true
        if body != &null {
            self.dispatch_stmt(body)
        }
    }

    priv fn _slot(self, d: unsafe *Decl) -> usize {
        for var i: usize = 0; i < self._held.size(); ++i {
            if self._held[i] == d {
                return i
            }
        }

        return usize::MAX
    }

    priv fn _read(self, e: unsafe *Expr) {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        if x != &null && isa<NamedIdentExpr>(x) {
            self._reads.push_back(x)
        }
    }

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if n->resolved_decl == &null || self._slot(n->resolved_decl) == usize::MAX {
            return true
        }

        for var i: usize = 0; i < self._reads.size(); ++i {
            if self._reads[i] == unsafe (n as unsafe *Expr) {
                return true
            }
        }

        self.written = true
        self.stop    = true
        return false
    }

    fn visit_closure_expr(self, n: unsafe *ClosureExpr) -> bool {
        for var i: usize = 0; i < n->held.size(); ++i {
            var k = self._slot(n->held[i].decl)
            if k == usize::MAX {
                continue
            }

            var m = n->held[i].mode
            if self._mode[k] == CaptureMode::Copy
                && (m == CaptureMode::Ptr || m == CaptureMode::Move) {
                self.written = true
                self.stop    = true
            }
        }

        return false
    }

    fn visit_binary_operator_expr(self, n: unsafe *BinaryOperatorExpr) -> bool {
        if n->resolved_op == &null {
            self._read(n->lhs)
            self._read(n->rhs)
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: unsafe *AssignOperatorExpr) -> bool {
        if n->resolved_op == &null {
            self._read(n->rhs)
        }

        return true
    }

    fn visit_unary_operator_expr(self, n: unsafe *UnaryOperatorExpr) -> bool {
        var k = n->op_token.kind
        if n->resolved_op == &null
            && (k == TokenKind::OpStar
                || k == TokenKind::OpMinus
                || k == TokenKind::OpPlus
                || k == TokenKind::OpTilde
                || k == TokenKind::OpExclaim) {
            self._read(n->operand)
        }

        return true
    }

    fn visit_type_cast_expr(self, n: unsafe *TypeCastExpr) -> bool {
        if n->resolved_op == &null && n->resolved_ctor == &null && n->disarms == &null {
            self._read(n->operand)
        }

        return true
    }

    fn visit_chain_expr(self, n: unsafe *ChainExpr) -> bool {
        if n->steps.size() > 0 && n->steps.get(0)->access_kind == ChainExpr::AccessKind::Arrow {
            self._read(n->base)
        }

        return true
    }

    fn visit_subscript_expr(self, n: unsafe *SubscriptExpr) -> bool {
        self._read(n->index)
        if n->resolved_op == &null {
            self._read(n->base)
        }

        return true
    }

    fn visit_call_expr(self, n: unsafe *CallExpr) -> bool {
        if self._calls {
            self._read(n->callee)
        }

        if !self._by_value_callee(n) {
            return true
        }

        for var i: usize = 0; i < n->args.size(); ++i {
            self._read(*n->args.get(i))
        }

        return true
    }

    /// The call's callee takes every argument by value: a Kairo function
    /// with no `@inout` / `@move` parameter and no pack, or a `fn` value
    /// whose type has none.
    priv fn _by_value_callee(self, n: unsafe *CallExpr) -> bool {
        if n->callee == &null || n->ctor_decl != &null || n->functor_op != &null {
            return false
        }

        var        d:  unsafe *Decl = &null
        var unsafe *ni              = dyn_cast<NamedIdentExpr>(n->callee)
        if ni != &null {
            d = ni->resolved_decl
        }

        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        if ch != &null && ch->steps.size() > 0 {
            d = ch->steps.get(ch->steps.size() - 1)->resolved_decl
        }

        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f != &null {
            if decl_is_imported(d) {
                return false
            }

            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p == &null || p->is_pack || p->mode != ParamMode::Value {
                    return false
                }
            }

            return true
        }

        if d != &null && !isa<VariableDecl>(d) && !isa<ParamDecl>(d) {
            return false
        }

        var unsafe *ct = n->callee->type_
        if ct == &null || ct->canonical == &null {
            return false
        }

        var unsafe *fp = dyn_cast<FunctionPointerType>(
            canon_unqual(ct->canonical),
        )

        if fp == &null {
            return false
        }

        for var i: usize = 0; i < fp->modes.size(); ++i {
            if fp->modes[i] != ParamMode::Value {
                return false
            }
        }

        return true
    }

    fn visit_return_stmt(self, n: unsafe *ReturnStmt) -> bool {
        self._read(n->value)
        return true
    }

    fn visit_conditional_stmt(self, n: unsafe *ConditionalStmt) -> bool {
        self._read(n->cond)
        return true
    }

    fn visit_while_loop_stmt(self, n: unsafe *WhileLoopStmt) -> bool {
        self._read(n->cond)
        return true
    }

    fn visit_if_expr(self, n: unsafe *IfExpr) -> bool {
        self._read(n->condition)
        self._read(n->then_expr)
        self._read(n->else_expr)
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            self._read(n->else_ifs.get(i)->condition)
            self._read(n->else_ifs.get(i)->body)
        }

        return true
    }

    fn visit_variable_decl(self, n: unsafe *VariableDecl) -> bool {
        // A local that is a reference to its initializer (a borrowing
        // binder, a bound place) reads nothing: writes can follow through it.
        if !n->borrows && !n->borrow_inst && !n->snap_inst && !n->place_ref {
            self._read(n->init)
        }

        return true
    }
}

/// What the body of a `for` over a generator holds that decides whether
/// EmitIR writes the loop in push form, where the body is a C++ lambda
/// (Codegen/Emit/Push.k): a `return` or a `yield` (each leaves the lambda
/// through a flag), and what a lambda cannot hold at all -- an `await`, an
/// `eval for` or a `for` over a pack (their own expansion protocol), a C++
/// `try`, a jump to a label outside the body. A closure in the body is not
/// entered: its statements are its own.
pub class PushBodyScan derives RecursiveASTVisitor<PushBodyScan> {
    pub var  has_return: bool                     = false
    pub var  has_yield:  bool                     = false
    pub var  blocked:    bool                     = false
    priv var _ctx:       unsafe *ASTContext
    priv var _labels:    cxx::std::vector<string>
    priv var _jumps:     cxx::std::vector<string>

    fn PushBodyScan(self, ctx: unsafe *ASTContext) {
        self._ctx = ctx
    }

    fn run(self, s: unsafe *Stmt) {
        if s != &null {
            self.dispatch_stmt(s)
        }
    }

    /// Every jump of the walked tree lands on one of its own labels.
    fn jumps_stay(self) -> bool {
        for var i: usize = 0; i < self._jumps.size(); ++i {
            var found = false
            for var k: usize = 0; k < self._labels.size(); ++k {
                if self._labels[k] == self._jumps[i] {
                    found = true
                    break
                }
            }

            if !found {
                return false
            }
        }

        return true
    }

    fn visit_closure_expr(self, n: unsafe *ClosureExpr) -> bool {
        return false
    }

    fn visit_return_stmt(self, n: unsafe *ReturnStmt) -> bool {
        self.has_return = true
        return true
    }

    fn visit_yield_stmt(self, n: unsafe *YieldStmt) -> bool {
        self.has_yield = true
        return true
    }

    fn visit_await_expr(self, n: unsafe *AwaitExpr) -> bool {
        self.blocked = true
        return true
    }

    fn visit_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> bool {
        self.blocked = true
        return true
    }

    fn visit_try_catch_stmt(self, n: unsafe *TryCatchStmt) -> bool {
        self.blocked = true
        return true
    }

    fn visit_label_intrinsic_stmt(self, n: unsafe *LabelIntrinsicStmt) -> bool {
        self._labels.push_back(self._ctx->get_spelling(n->name))
        return true
    }

    fn visit_jump_intrinsic_stmt(self, n: unsafe *JumpIntrinsicStmt) -> bool {
        if n->ef_leave {
            self.blocked = true
        } else {
            self._jumps.push_back(self._ctx->get_spelling(n->target))
        }

        return true
    }
}

/// What a generator's body holds that a second C++ function written from
/// the same statements (its push form) cannot repeat: a `static` local or
/// a local function or type (each copy would have its own), an `eval for`,
/// a `for` over a pack or over a dependent C++ range, an `await`, a C++
/// `try`.
pub class GenBodyScan derives RecursiveASTVisitor<GenBodyScan> {
    pub var blocked: bool = false

    fn GenBodyScan(self) { }

    fn visit_closure_expr(self, n: unsafe *ClosureExpr) -> bool {
        return false
    }

    fn visit_decl_stmt(self, n: unsafe *DeclStmt) -> bool {
        if n == &null || n->decl == &null {
            return true
        }

        var unsafe *vd = dyn_cast<VariableDecl>(n->decl)
        if vd != &null && vd->is_static() || Speller::is_hoisted_local(n->decl) {
            self.blocked = true
        }

        return true
    }

    fn visit_await_expr(self, n: unsafe *AwaitExpr) -> bool {
        self.blocked = true
        return true
    }

    // Only the loops and the `try` that reach EmitIR as they are, so the
    // answer is the same before and after the body is lowered.
    fn visit_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> bool {
        if n->is_eval || n->iter_kind == IterKind::Pack || n->cxx_dependent {
            self.blocked = true
        }

        return true
    }

    fn visit_try_catch_stmt(self, n: unsafe *TryCatchStmt) -> bool {
        if n->cxx {
            self.blocked = true
        }

        return true
    }
}

/// `T` of generator `f`'s `Yield<T>` result, or null.
pub fn generator_elem(f: unsafe *FunctionDecl) -> unsafe *Type {
    if f == &null || f->return_type == &null || f->return_type->canonical == &null {
        return &null
    }

    var unsafe *r = dyn_cast<RecordType>(
        canon_unqual(f->return_type->canonical),
    )

    if r == &null || r->args.size() == 0 {
        return &null
    }

    return r->args[0]
}

/// A parameter the push form takes exactly as the coroutine does: by
/// reference (`@inout`, `@move`, a `const` record or type parameter), or a
/// pointer or a builtin value. A record taken by value is not one: the
/// coroutine moves it into its frame, a move the push form has no place
/// for.
fn _push_param(p: unsafe *ParamDecl) -> bool {
    if p->is_pack || p->type_ == &null || p->type_->canonical == &null {
        return false
    }

    if p->mode != ParamMode::Value {
        return true
    }

    var unsafe *c = canon_unqual(p->type_->canonical)
    if c == &null {
        return false
    }

    if isa<PointerType>(c) {
        return true
    }

    var unsafe *b = dyn_cast<BuiltinType>(c)
    if b != &null {
        return b->builtin != BuiltinKind::Void && b->builtin != BuiltinKind::Never
    }

    if !p->is_const {
        return false
    }

    var unsafe *g = dyn_cast<GenericParamType>(c)
    return isa<RecordType>(c) || g != &null && !g->is_pack
}

/// Generator `f` has a push form (Codegen/Emit/Push.k): a second C++
/// function, `bool f(params..., __kairo_each<T>)`, written from the same
/// body, that a `for` over a call of `f` calls in place of making the
/// coroutine. InterfaceEmitter declares it wherever it declares `f`,
/// EmitIR defines it wherever it defines `f` and calls it where `f`'s body
/// is visible, so the answer depends on `f`'s own declaration and body and
/// on nothing of the TU that asks.
///
/// Not one: a virtual, imported, `@no_inline`, unwinding, `async` or `eval`
/// generator; an explicit specialization, or a method that has member
/// specializations (its body starts with their dispatch); a member of a
/// conditional extension block; one with a pack, or a parameter the push
/// form cannot take as the coroutine does (_push_param); one whose body
/// cannot be written twice (GenBodyScan).
pub fn generator_push_form(f0: unsafe *FunctionDecl, reg: unsafe *InstantiationRegistry) -> bool {
    if f0 == &null {
        return false
    }

    var unsafe *f = f0
    if !f->has_body() {
        f = f->definition()
    }

    if f == &null
        || f->is_poisoned()
        || f->body_kind != FnBodyKind::Block
        || f->body_block == &null {
        return false
    }

    if !f->is_generator || f->is_eval() || f->is_async() || !f->no_unwind || f->no_inline {
        return false
    }

    var unsafe *c = f->canonical_decl()
    if c != &null && c->no_inline {
        return false
    }

    if f->abi == AbiKind::Virtual || f->abi == AbiKind::Override || f->overrides_virtual {
        return false
    }

    var unsafe *d = unsafe (f as unsafe *Decl)
    if decl_is_imported(d) || f->call_conv != 0 || f->ci_split > 0 || f->dynamic_layout != 0 {
        return false
    }

    if Speller::is_fn_spec(d) || Speller::c_linkage(f).size() > 0 {
        return false
    }

    var unsafe *x = decl_extension_of(d)
    if x != &null && x->gate != &null {
        return false
    }

    if generator_elem(f) == &null {
        return false
    }

    for var i: usize = 0; i < f->params.size(); ++i {
        var unsafe *p = f->params[i]
        if p == &null || p->is_self {
            continue
        }

        if !_push_param(p) {
            return false
        }
    }

    var specs = cxx::std::vector<unsafe *Decl>()
    Speller::member_specs_of(d, unsafe &specs, reg)
    if !specs.empty() {
        return false
    }

    var scan = GenBodyScan()
    scan.dispatch_stmt(unsafe (f->body_block as unsafe *Stmt))
    return !scan.blocked
}
