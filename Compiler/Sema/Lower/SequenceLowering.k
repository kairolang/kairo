/// --- The Kairo Project ---------------- Sema/Lower/SequenceLowering.k --- ///
///
///   \brief Make evaluation order explicit.
///
///   \detail
///     Kairo evaluates left to right: a call's receiver, then its arguments
///     as written; a binary operator's left operand, then its right; a
///     subscript's base, then its index; an assignment's place, then its
///     value, then the store; an initializer's fields as written. C++ does
///     not promise any of that (`=` even runs its right side first), and
///     clang and gcc disagree in practice (`f(g(), g())` is 1020 on one and
///     2010 on the other). Nothing is asked of clang: the order is written
///     into the tree.
///
///       f(g(), x, h())
///     ->
///       ({ T0 __kairo_ord0 = g(); f(__kairo_ord0, x, h()); })
///
///     Every operand before the last one with an effect that has an effect,
///     or reads state the effect could change, is bound in order (_plan);
///     the last effectful operand and the rest stay in place.
///
///     A statement expression, not hoisted statements: it sits where the call
///     sat, so `c && f(g(), h())` still short-circuits and a call in a loop
///     header still runs per iteration. Its block is also the scope of every
///     temporary an argument needs, which is what lets a slice literal be
///     hoisted at all (see _mark_extended).
///
///     A literal, an eval constant, a local nothing else can reach and `&x`
///     never need binding, so almost every node is untouched. The receiver
///     of `x.m(...)` is operand zero for a member call, and argument zero for
///     an extension call after ExtensionLowering. A place is bound as
///     `auto&&` (VariableDecl::place_ref), a value by value.
///
///   \par Not rewritten
///     A call whose result is an lvalue (an imported `T&` return) or a record
///     value: a statement expression yields a prvalue, which would change the
///     category or force a copy the type may not have. Those calls keep C++'s
///     order. A panic result is the exception: it is always movable, so a
///     panicking call's arguments are ordered too. An integer compound
///     assignment is EmitIR's: its wrap form binds the place before it reads
///     the value.
///
///   \par Variant payloads
///     An enum variant's payload is built from a braced list, which C++
///     evaluates in declaration order; Kairo runs the fields in the order they
///     were written. When the two differ and a field has side effects, every
///     field is bound first, in written order, and the payload reads the
///     locals. The construction is a prvalue of the enum that clang builds in
///     place, so unlike a call's record result it may end the statement
///     expression: nothing is copied or moved out of the block.
///
///   Phase: LOWER, after OperatorLowering (user operators are calls by then)
///   and before ListLiteralLowering (a hoisted slice literal is marked
///   Extended here and given its backing there).
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
import Sema::Lower::LowerSynth::*;
import Sema::Type::PanicSets::*;
import AST::Visitor::ASTWriter::*;
import AST::Visitor::RecursiveASTVisitor::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

/// The locals a function's body can change other than by assigning them by
/// name: their address is taken (`&x`, `&x.f`, `&x[i]`, an `inout` marker)
/// or a closure names them. Conservative: one such use anywhere counts for
/// the whole function.
class SeqAddrScan derives RecursiveASTVisitor::<SeqAddrScan> {
    pub var out: vec::<*Decl>;
    priv var _closures: u32 = 0;

    fn SeqAddrScan(self) { }

    priv fn _add(self, d: *Decl) {
        if d == &null { return; }
        for var i: usize = 0; i < self.out.size(); ++i { if self.out[i] == d { return; } }
        self.out.push_back(d);
    }

    /// The local an address-of reaches: `x`, `x.f`, `x[i]`, parens aside.
    priv fn _root(self, e: *Expr) {
        var x = e;
        while x != &null {
            if isa::<ParenExpr>(x) { x = cast::<ParenExpr>(x)->inner; continue; }
            if isa::<ChainExpr>(x) { x = cast::<ChainExpr>(x)->base; continue; }
            if isa::<SubscriptExpr>(x) { x = cast::<SubscriptExpr>(x)->base; continue; }
            break;
        }
        if (x != &null) && isa::<NamedIdentExpr>(x) { self._add(cast::<NamedIdentExpr>(x)->resolved_decl); }
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if n->op_token.kind == TokenKind::OpAmp { self._root(n->operand); }
        return true;
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self._closures > 0 { self._add(n->resolved_decl); }
        return true;
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        self._closures += 1;
        var r = RecursiveASTVisitor::<SeqAddrScan>::traverse_closure_expr(n);
        self._closures -= 1;
        return r;
    }
}

class SequenceLowering derives ASTWriter::<SequenceLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn SequenceLowering(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
        self.tu  = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter::<SequenceLowering>::run(self.sc->tu);
    }

    // --- the rewrite ----------------------------------------------------------

    /// The locals of the function being lowered whose value something
    /// other than a plain write can change (SeqAddrScan): a read of one is a
    /// state read.
    priv var _escaped: vec::<*Decl>;
    /// The expression that is a whole statement: an assignment there needs
    /// no address of its result.
    priv var _stmt_top: *Expr = &null;

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        var saved = self._escaped;
        var scan = SeqAddrScan();
        scan.dyn()->dispatch_decl(static_cast::<*Decl>(n));
        self._escaped = scan.out;
        var out = ASTWriter::<SequenceLowering>::transform_function_decl(n);
        self._escaped = saved;
        return out;
    }

    fn transform_expression_stmt(self, n: *ExpressionStmt) -> vec::<*Stmt> {
        var saved = self._stmt_top;
        self._stmt_top = n->expr;
        var out = ASTWriter::<SequenceLowering>::transform_expression_stmt(n);
        self._stmt_top = saved;
        return out;
    }

    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        // Children first: an inner call `f(g(h(), k()))` is sequenced on its
        // own, and this call then sees it as one impure argument.
        var out = ASTWriter::<SequenceLowering>::transform_call_expr(n);
        if n->is_poisoned() || n->is_instantiation_dependent() { return out; }
        if !self._result_sequenceable(n) { return out; }

        // The receiver of `x.m(...)` is operand zero; an extension call's is
        // argument zero, ExtensionLowering having moved it there.
        var recv: *ChainExpr = &null;
        if (n->callee != &null) && isa::<ChainExpr>(n->callee) {
            var ch = cast::<ChainExpr>(n->callee);
            if (ch->base != &null) && (ch->steps.size() > 0)
            && (ch->steps.get(0)->access_kind != ChainExpr::AccessKind::ColonColon) { recv = ch; }
        }
        var ops = vec::<*Expr>();
        var places = vec::<bool>();
        // The receiver object is a place; a pointer it is reached through
        // is a value, read once.
        if recv != &null { ops.push_back(recv->base); places.push_back(recv->base->is_lvalue() && (!self._pointer_typed(recv->base))); }
        for var i: usize = 0; i < n->args.size(); ++i { ops.push_back(n->args[i]); places.push_back(false); }
        var hoist = vec::<bool>();
        if !self._plan(&ops, &hoist, &places) { return out; }

        var stmts = self.list_builder::<*Stmt>();
        var k: usize = 0;
        if recv != &null {
            if hoist[0] { recv->base = self._hoist(recv->base, &stmts, false, places[0]); }
            k = 1;
        }
        var args = self.list_builder::<*Expr>();
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            args.push((self._hoist(a, &stmts, true, false)) if (hoist[k + i]) else (a));
        }
        args.freeze_into(&(n->args));                 // arg_map is empty after CallLowering.

        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
        var body = CompoundStmt::create(self.ctx, n->range);
        stmts.freeze_into(&(body->body));

        var se = StmtExpr::create(self.ctx, n->range, body);
        se->type_          = n->type_;
        se->value_category = Expr::ValueCategory::RValue;
        se->expr_flags     = n->expr_flags;
        return static_cast::<*Expr>(se);
    }

    ///   f() - g()   ->   ({ T __kairo_ord0 = f(); __kairo_ord0 - g(); })
    ///
    /// C++ leaves a binary operator's operands unsequenced; Kairo evaluates
    /// the left first. `&&` and `||` short-circuit and are already ordered.
    fn transform_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *Expr {
        var out = ASTWriter::<SequenceLowering>::transform_binary_operator_expr(n);
        var k = n->op_token.kind;
        if (k == TokenKind::OpAmpAmp) || (k == TokenKind::OpPipePipe) { return out; }
        if n->is_poisoned() || n->is_instantiation_dependent() || (n->type_ == &null) { return out; }
        var ops = vec::<*Expr>();
        ops.push_back(n->lhs);
        ops.push_back(n->rhs);
        var places = vec::<bool>();
        places.push_back(false);
        places.push_back(false);
        var hoist = vec::<bool>();
        if !self._plan(&ops, &hoist, &places) { return out; }
        var stmts = self.list_builder::<*Stmt>();
        n->lhs = self._hoist(n->lhs, &stmts, false, false);
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
        return self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, n->type_);
    }

    ///   a[i()] = v()   ->   ({ auto&& __kairo_ord0 = (a[i()]); __kairo_ord0 = v(); })
    ///
    /// The place first, then the value, then the store: C++17 evaluates the
    /// right side of `=` and `op=` first. A compound assignment on an
    /// integer EmitIR orders itself (its wrap form binds the place before
    /// the value is read), so only `=` and the other compounds come here.
    fn transform_assign_operator_expr(self, n: *AssignOperatorExpr) -> *Expr {
        var out = ASTWriter::<SequenceLowering>::transform_assign_operator_expr(n);
        if n->is_poisoned() || n->is_instantiation_dependent() || (n->lhs->type_ == &null) { return out; }
        if (n->op_token.kind != TokenKind::OpEqual) && self.tu.is_integer(n->lhs->type_) { return out; }
        var ops = vec::<*Expr>();
        ops.push_back(n->lhs);
        ops.push_back(n->rhs);
        var places = vec::<bool>();
        places.push_back(true);
        places.push_back(false);
        var hoist = vec::<bool>();
        if !self._plan(&ops, &hoist, &places) { return out; }
        var stmts = self.list_builder::<*Stmt>();
        n->lhs = self._hoist(n->lhs, &stmts, false, true);
        return self._close_lvalue(static_cast::<*Expr>(n), &stmts, self._stmt_top == static_cast::<*Expr>(n));
    }

    ///   p()[i()]   ->   (*({ T* __kairo_ord0 = p(); &__kairo_ord0[i()]; }))
    fn transform_subscript_expr(self, n: *SubscriptExpr) -> *Expr {
        var out = ASTWriter::<SequenceLowering>::transform_subscript_expr(n);
        if n->is_poisoned() || n->is_instantiation_dependent() || (n->type_ == &null) { return out; }
        if n->resolved_op != &null { return out; }
        var ops = vec::<*Expr>();
        ops.push_back(n->base);
        ops.push_back(n->index);
        var places = vec::<bool>();
        places.push_back((n->base->type_ != &null) && isa::<FixedArrayType>(canon_unqual(n->base->type_)));
        places.push_back(false);
        var hoist = vec::<bool>();
        if !self._plan(&ops, &hoist, &places) { return out; }
        var stmts = self.list_builder::<*Stmt>();
        n->base = self._hoist(n->base, &stmts, false, places[0]);
        if !n->is_lvalue() {
            stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
            return self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, n->type_);
        }
        return self._close_lvalue(static_cast::<*Expr>(n), &stmts, false);
    }

    ///   T { b: f(), a: g() }   (declared a, b)
    /// ->
    ///   ({ B __kairo_ord0 = f(); A __kairo_ord1 = g(); T { a: __kairo_ord1, b: __kairo_ord0 }; })
    ///
    /// EmitIR writes a designated initializer in declaration order, which
    /// C++ evaluates in; Kairo evaluates the fields as written. When the two
    /// differ, every field that has an effect or reads state is bound in
    /// written order.
    fn transform_named_initializer_expr(self, n: *NamedInitializerExpr) -> *Expr {
        var out = ASTWriter::<SequenceLowering>::transform_named_initializer_expr(n);
        if n->is_poisoned() || n->is_instantiation_dependent() || (n->type_ == &null) { return out; }
        var rt = dyn_cast::<RecordType>(canon_unqual(n->type_));
        if (rt == &null) || (rt->decl == &null) { return out; }
        var rd = rt->decl;
        var decl_fields: *FrozenList::<*FieldDecl> = &null;
        if isa::<StructDecl>(rd)     { decl_fields = &(cast::<StructDecl>(rd)->fields); }
        else if isa::<ClassDecl>(rd) { decl_fields = &(cast::<ClassDecl>(rd)->fields); }
        if decl_fields == &null { return out; }
        // Each written field's declaration position; written order is
        // declaration order when those rise.
        var in_order = true;
        var prev: usize = 0;
        var any = false;
        for var i: usize = 0; i < n->fields.size(); ++i {
            var f = n->fields.get(i);
            var nm = self.sc->ctx->get_spelling(f->name);
            var at = usize(-1);
            for var j: usize = 0; j < decl_fields->size(); ++j {
                var fd = (*decl_fields)[j];
                if (fd != &null) && (self.sc->ctx->get_spelling(fd->name) == nm) { at = j; break; }
            }
            if at == usize(-1) { return out; }
            if any && (at < prev) { in_order = false; }
            prev = at;
            any = true;
        }
        if in_order { return out; }
        var impure = false;
        for var i: usize = 0; i < n->fields.size(); ++i {
            var v = n->fields.get(i)->value;
            if v == &null { continue; }
            if v->type_ == &null { return out; }
            if !self.synth.pure_read(v) { impure = true; }
        }
        if !impure { return out; }
        var stmts = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < n->fields.size(); ++i {
            var f = n->fields.get(i);
            if f->value == &null { continue; }
            if self.synth.pure_read(f->value) && (!self._reads_state(f->value)) { continue; }
            f->value = self._hoist(f->value, &stmts, true, false);
        }
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
        return self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, n->type_);
    }

    // --- the hoisting rule ----------------------------------------------------

    /// \p ops in evaluation order; \p hoist gets, per operand, whether it is
    /// bound ahead of the node. False when nothing is: with at most one
    /// operand that has an effect and no state read ahead of it, C++'s
    /// unspecified order cannot be observed. Otherwise every operand before
    /// the last effectful one that has an effect or reads state (the effect
    /// could change what it reads) is bound in order; the last effectful
    /// operand and everything after it stay where they are, which keeps a
    /// lone constructing argument's prvalue elided.
    priv fn _plan(self, ops: *vec::<*Expr>, hoist: *vec::<bool>, places: *vec::<bool>) -> bool {
        var n = ops->size();
        var last = usize(-1);
        var impure: usize = 0;
        for var i: usize = 0; i < n; ++i {
            hoist->push_back(false);
            var e = (*ops)[i];
            if e == &null { return false; }
            if !self.synth.pure_read(e) { last = i; impure += 1; }
        }
        if last == usize(-1) { return false; }
        var any = false;
        for var i: usize = 0; i < last; ++i {
            var e = (*ops)[i];
            var st = (self._place_moves(e)) if ((*places)[i]) else (self._reads_state(e));
            var h = (!self.synth.pure_read(e)) || st;
            if h && (*places)[i] && self._bitfield(e) { return false; }   // C++'s order, rather than a reference that cannot bind.
            if h && (e->type_ == &null) { return false; }   // no type to declare its local with.
            (*hoist)[i] = h;
            if h { any = true; }
        }
        return any;
    }

    /// Pure \p e reads a place an effect elsewhere in the expression could
    /// change: anything but a literal, an eval constant, or a local whose
    /// value only its own writes change (_escaped), its fields and its
    /// array elements included.
    priv fn _reads_state(self, e_in: *Expr) -> bool {
        var e = self.tu.strip_parens(e_in);
        if e == &null { return false; }
        switch e->kind {
            case ExprKind::IntegerLiteralExpr   { return false; }
            case ExprKind::FloatingLiteralExpr  { return false; }
            case ExprKind::CharacterLiteralExpr { return false; }
            case ExprKind::BooleanLiteralExpr   { return false; }
            case ExprKind::NullLiteralExpr      { return false; }
            case ExprKind::StringLiteralExpr    { return false; }
            case ExprKind::SizeOfExpr           { return false; }
            case ExprKind::AlignOfExpr          { return false; }
            case ExprKind::TypeTraitExpr        { return false; }
            case ExprKind::NamedIdentExpr {
                var d = cast::<NamedIdentExpr>(e)->resolved_decl;
                if d == &null { return true; }
                if isa::<FunctionDecl>(d) || isa::<EnumVariantDecl>(d) { return false; }
                var vd = dyn_cast::<VariableDecl>(d);
                if (vd != &null) && vd->is_eval() { return false; }
                return !self._state_free_local(d);
            }
            case ExprKind::TypeCastExpr { return self._reads_state(cast::<TypeCastExpr>(e)->operand); }
            case ExprKind::UnaryOperatorExpr {
                var u = cast::<UnaryOperatorExpr>(e);
                if u->op_token.kind == TokenKind::OpStar { return true; }   // through a pointer: anything may change it.
                if u->op_token.kind == TokenKind::OpAmp { return false; }   // an address is not a read.
                return self._reads_state(u->operand);
            }
            case ExprKind::BinaryOperatorExpr {
                var b = cast::<BinaryOperatorExpr>(e);
                return self._reads_state(b->lhs) || self._reads_state(b->rhs);
            }
            case ExprKind::ChainExpr {
                // A field of a value local; through a pointer (which `.`
                // reaches too) it is memory anything may write.
                var c = cast::<ChainExpr>(e);
                for var i: usize = 0; i < c->steps.size(); ++i {
                    if c->steps.get(i)->access_kind != ChainExpr::AccessKind::Dot { return true; }
                }
                if self._pointer_typed(c->base) || (c->steps.size() > 1) { return true; }
                return self._reads_state(c->base);
            }
            case ExprKind::SubscriptExpr {
                var s = cast::<SubscriptExpr>(e);
                if (s->base->type_ == &null) || (!isa::<FixedArrayType>(canon_unqual(s->base->type_))) { return true; }
                return self._reads_state(s->base) || self._reads_state(s->index);
            }
            case ExprKind::CallExpr {
                // A pure accessor (PureAccessors) reads its object and only
                // that: as stateful as the object, and anything it reaches
                // through a pointer is memory anything may write.
                var r = self.synth.accessor_receiver(e);
                if r == &null { return true; }
                return self._pointer_typed(r) || self._reads_state(r);
            }
            default { return true; }
        }
        return true;
    }

    /// Pure place \p e (bound by address, not read) may name another object
    /// once an effect has run: only through a pointer or an index it reads.
    /// A variable's address is fixed, global or not.
    priv fn _place_moves(self, e_in: *Expr) -> bool {
        var e = self.tu.strip_parens(e_in);
        if e == &null { return false; }
        if isa::<NamedIdentExpr>(e) { return false; }
        if isa::<ChainExpr>(e) {
            // `.` reaches through a pointer base as well (`self.x` is
            // `this->x`): then the pointer's value is read.
            var c = cast::<ChainExpr>(e);
            for var i: usize = 0; i < c->steps.size(); ++i {
                var st = c->steps.get(i);
                if (st->access_kind != ChainExpr::AccessKind::Dot) && (st->access_kind != ChainExpr::AccessKind::Arrow) { return true; }
            }
            if self._pointer_typed(c->base) || (c->steps.size() > 1) { return self._reads_state(c->base) || (c->steps.size() > 1); }
            return self._place_moves(c->base);
        }
        if isa::<SubscriptExpr>(e) {
            var s = cast::<SubscriptExpr>(e);
            if self._reads_state(s->index) { return true; }
            if (s->base->type_ != &null) && isa::<FixedArrayType>(canon_unqual(s->base->type_)) { return self._place_moves(s->base); }
            return self._reads_state(s->base);
        }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            if u->op_token.kind == TokenKind::OpStar { return self._reads_state(u->operand); }
        }
        return true;
    }

    priv fn _pointer_typed(self, e: *Expr) -> bool {
        if (e == &null) || (e->type_ == &null) { return true; }
        var c = canon_unqual(e->type_);
        return (c == &null) || isa::<PointerType>(c) || isa::<CXXLValueRefType>(c) || isa::<CXXRValueRefType>(c);
    }

    /// \p d is a local or parameter of the function being lowered that no
    /// pointer, `inout` argument or closure can reach.
    priv fn _state_free_local(self, d: *Decl) -> bool {
        if (!isa::<ParamDecl>(d)) && (!isa::<VariableDecl>(d)) { return false; }
        // As EmitIR::_is_local: no semantic scope is a body's own local.
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if (dc != &null) && (!isa::<ParamDecl>(d))
        && (!dc->is_function()) && (dc->dc_kind != DeclContextKind::Block) && (dc->dc_kind != DeclContextKind::Lambda) { return false; }
        for var i: usize = 0; i < self._escaped.size(); ++i { if self._escaped[i] == d { return false; } }
        return true;
    }

    /// Operand \p e bound ahead of its node, in \p stmts; returns what reads
    /// it. A \p place (an assignment's target, a receiver, an array a
    /// subscript indexes, an `inout` argument) is bound by reference, so it
    /// is evaluated once and written through; a value is copied, which is
    /// the snapshot a later effect must not change. A record value bound for
    /// an argument or a field (\p consumed) is moved into it.
    priv fn _hoist(self, e: *Expr, stmts: *ListBuilder::<*Stmt>, consumed: bool, place: bool) -> *Expr {
        // `&x` for an `inout` parameter: the marker stays, its place is bound.
        var mk = dyn_cast::<UnaryOperatorExpr>(e);
        if (mk != &null) && mk->is_mode_marker {
            mk->operand = self._hoist(mk->operand, stmts, false, true);
            return e;
        }
        if place && e->is_lvalue() && (!self._materialized(e)) && (e->type_ != &null) && (!self._bitfield(e)) {
            // `auto&& p = (e);`: the place itself, its cv and its reference
            // type kept (an imported `T&` return, a const field), and a
            // prvalue C++ sees (a by-value receiver) extended to the block.
            var vd = self.synth.local(e->range, "ord", e->type_, e);
            vd->place_ref = true;
            stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(vd))));
            return self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue);
        }
        // A value that is no builtin, pointer or record (an enum, an ADT's
        // tag, whose type may only be spelled through a generic pattern), or
        // of a dependent type: copied as `auto`, the type C++ deduces.
        var pv = (e->type_ != &null) && (!self._materialized(e));
        var pc = (canon_unqual(e->type_)) if (pv) else (&null);
        var plain = (pc != &null) && (isa::<BuiltinType>(pc) || isa::<PointerType>(pc) || ((pc->kind == TypeKind::RecordType) && (!isa::<EnumDecl>(cast::<RecordType>(pc)->decl))));
        if pv && ((!plain) || e->type_->is_dependent() || e->type_->is_instantiation_dependent()) && ((pc == &null) || (pc->kind != TypeKind::RecordType) || isa::<EnumDecl>(cast::<RecordType>(pc)->decl)) {
            var dv = self.synth.local(e->range, "ord", e->type_, e);
            dv->auto_copy = true;
            stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(dv))));
            return self.synth.use_of(dv, e->range, Expr::ValueCategory::LValue);
        }
        var use = self._bind(e, stmts);
        if consumed { return self._moved(use); }
        return use;
    }

    /// \p e is a field step that is an imported bit-field: no reference binds
    /// it, so it is never hoisted as a place (_plan leaves its node alone).
    priv fn _bitfield(self, e: *Expr) -> bool {
        var c = dyn_cast::<ChainExpr>(self.tu.strip_parens(e));
        if (c == &null) || (c->steps.size() == 0) { return false; }
        var fd = dyn_cast::<FieldDecl>(c->steps.get(c->steps.size() - 1)->resolved_decl);
        return (fd != &null) && fd->is_bitfield;
    }

    /// `*__kairo_tmp(p)` / `__kairo_tmp(p)`: _bind's own case, never bound by
    /// address (the temporary would end at the declaration's `;`).
    priv fn _materialized(self, e: *Expr) -> bool {
        var x = dyn_cast::<UnaryOperatorExpr>(self.tu.strip_parens(e));
        if x == &null { return false; }
        if x->materialize { return true; }
        if (x->op_token.kind != TokenKind::OpStar) || (!x->is_prefix()) { return false; }
        var inner = dyn_cast::<UnaryOperatorExpr>(self.tu.strip_parens(x->operand));
        return (inner != &null) && inner->materialize;
    }

    /// \p n, an lvalue, after the bindings in \p stmts: as a statement the
    /// node itself ends the block; used as a value or a place, the block
    /// yields its address and is dereferenced, so it stays an lvalue.
    priv fn _close_lvalue(self, n: *Expr, stmts: *ListBuilder::<*Stmt>, as_stmt: bool) -> *Expr {
        if as_stmt {
            stmts->push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, n)));
            return self.synth.stmt_expr(n, stmts, n->type_);
        }
        var pt = self.sc->types->pointer(n->type_);
        var addr = UnaryOperatorExpr::create(self.ctx, n->range, n, self.synth.punct(n->range, TokenKind::OpAmp), UnaryOperatorExpr::Fix::Prefix);
        addr->type_          = pt;
        addr->value_category = Expr::ValueCategory::RValue;
        stmts->push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(addr))));
        var blk = self.synth.stmt_expr(n, stmts, pt);
        var d = UnaryOperatorExpr::create(self.ctx, n->range, blk, self.synth.punct(n->range, TokenKind::OpStar), UnaryOperatorExpr::Fix::Prefix);
        d->type_          = n->type_;
        d->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(d);
    }

    ///   Shape::Rect { h: g(), w: f() }
    /// ->
    ///   ({ i32 __kairo_ord0 = g(); i32 __kairo_ord1 = f(); Shape::Rect { w: __kairo_ord1, h: __kairo_ord0 }; })
    fn transform_variant_init_expr(self, n: *VariantInitExpr) -> *Expr {
        var out = ASTWriter::<SequenceLowering>::transform_variant_init_expr(n);
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        var count = n->fields.size();
        var in_order = true;
        var impure   = false;
        for var i: usize = 0; i < count; ++i {
            if usize(n->source_order[i]) != i { in_order = false; }
            if !self.synth.pure_read(n->fields[i]) { impure = true; }
        }
        if in_order || (!impure) { return out; }
        // Every field must have a type to declare its local with.
        for var i: usize = 0; i < count; ++i {
            if n->fields[i]->type_ == &null { return out; }
        }

        var stmts = self.list_builder::<*Stmt>();
        var bound = vec::<*Expr>();
        for var i: usize = 0; i < count; ++i { bound.push_back(&null); }
        for var k: usize = 0; k < count; ++k {
            for var i: usize = 0; i < count; ++i {
                if usize(n->source_order[i]) != k { continue; }
                bound[i] = self._moved(self._bind(n->fields[i], &stmts));
            }
        }
        var fields = self.list_builder::<*Expr>();
        var order  = self.list_builder::<u32>();
        for var i: usize = 0; i < count; ++i {
            fields.push(bound[i]);
            order.push(u32(i));
        }
        fields.freeze_into(&(n->fields));
        order.freeze_into(&(n->source_order));   // the locals are read in place: written order is declaration order now.

        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
        return self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, n->type_);
    }

    /// A statement expression is a prvalue of its last statement's type. A
    /// call that yields an lvalue, or a record (the copy out of the block may
    /// not exist), keeps C++'s order rather than a changed meaning.
    priv fn _result_sequenceable(self, n: *CallExpr) -> bool {
        if n->value_category == Expr::ValueCategory::LValue { return false; }
        var t = n->type_;
        if t == &null { return true; }                  // void-typed calls have no slot to read.
        if isa::<CXXLValueRefType>(t) || isa::<CXXRValueRefType>(t) { return false; }
        var c = canon_unqual(t);
        // A panic result (PanicLowering's held call, `var __kairo_p = f(..)`)
        // is always movable -- its payloads must be (PANIC.md §1.5) -- and is
        // moved out of the block once: the order of its arguments is worth
        // that, and it is the one record result PanicLowering mints a call for.
        if (c != &null) && (c->kind == TypeKind::RecordType) {
            return PanicSets(self.sc).is_panic(cast::<RecordType>(c)->decl);
        }
        return true;
    }

    /// `T __kairo_ordK = e;` into \p stmts; returns the name that reads it.
    priv fn _bind(self, e: *Expr, stmts: *ListBuilder::<*Stmt>) -> *Expr {
        // `__kairo_tmp(p)` / `*__kairo_tmp(p)`: an extension call's prvalue
        // receiver. A pointer local would end the temporary at its own `;`, so
        // the PRVALUE is bound (elided: no copy or move asked of the type) and
        // its address, or the object, is handed back.
        var x = self.tu.strip_parens(e);
        var u = dyn_cast::<UnaryOperatorExpr>(x);
        var deref = false;
        if (u != &null) && u->is_prefix() && (u->resolved_op == &null) && (u->op_token.kind == TokenKind::OpStar) {
            var inner = dyn_cast::<UnaryOperatorExpr>(self.tu.strip_parens(u->operand));
            u = (inner) if ((inner != &null) && inner->materialize) else (&null);
            deref = true;
        }
        if (u != &null) && u->materialize {
            ICE_IF(u->operand->type_ == &null, "SequenceLowering: untyped materialized receiver");
            var vd = self.synth.local(e->range, "ord", u->operand->type_, u->operand);
            self._mark_extended(u->operand);
            stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(vd))));
            var use = self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue);
            if deref { return use; }
            var a = UnaryOperatorExpr::create(self.ctx, e->range, use, self.synth.punct(e->range, TokenKind::OpAmp), UnaryOperatorExpr::Fix::Prefix);
            a->type_ = u->type_;
            a->value_category = Expr::ValueCategory::RValue;
            return static_cast::<*Expr>(a);
        }

        var t = e->type_;
        var vd = self.synth.local(e->range, "ord", t, e);
        self._mark_extended(e);                         // a slice literal's backing lives in this block.
        stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(vd))));
        return self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue);
    }

    /// A record local bound for one payload field is moved into it: nothing
    /// else reads it. A reference-typed local already names its referent.
    priv fn _moved(self, use: *Expr) -> *Expr {
        var t = use->type_;
        if (t == &null) || isa::<CXXLValueRefType>(t) || isa::<CXXRValueRefType>(t) { return use; }
        var c = canon_unqual(t);
        if (c == &null) || (c->kind != TypeKind::RecordType) { return use; }
        return self.synth.cast_to(use->range, use, self.sc->types->cxx_rref(t), CastMode::Default);
    }

    /// Mirrors LiteralTyping::mark_list_storage: the local this literal now
    /// initializes is a `var`, so its backing array extends to the block.
    priv fn _mark_extended(self, e_in: *Expr) {
        var e = self.tu.strip_parens(e_in);
        if (e == &null) || (!isa::<ListLiteralExpr>(e)) { return; }
        var n = cast::<ListLiteralExpr>(e);
        if (n->type_ == &null) || (!self.tu.is_slice(n->type_)) { return; }
        n->storage = ListStorage::Extended;
        for var i: usize = 0; i < n->elements.size(); ++i { self._mark_extended(n->elements[i]); }
    }
}
