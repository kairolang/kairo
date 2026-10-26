/// --- The Kairo Project -------------------- Sema/Lower/CoalesceLowering.k --- ///
///
///   \brief The nullable operators that choose a value become the
///          if-expressions NULLABLE.md §2 writes for them.
///
///   \detail
///     NULLABLE.md 2.4-2.6, §5 step 1:
///
///       x ?? y        ->  if x? => x else y
///       x?.m          ->  if x? => x.m else null       (`?->` alike; a chain
///       x?.f(args)    ->  if x? => x.f(args) else null  tests left to right)
///       unwrap!(x)    ->  if x? => x else <abort>      (a statement, see
///                                                       transform_unwrap_expr)
///       a === b       ->  (a? && b?) && a == b         (`*a == *b` through
///                                                       nullable pointers)
///
///     The expansion is built TYPED, in the exact shape the typer gives the
///     same code written by hand, so the passes after this one lower it
///     with no knowledge of where it came from:
///
///       - the test is a postfix `x?` (bool, no resolved_op) whose operand
///         is the nullable: `null_test_of` classifies it, NullTestLowering
///         makes it `!x.is_null()`;
///       - the read of `x` in the then-arm is MARKED narrowed (narrowed_from
///         holds the `T?`, the node is typed `T`), as NullnessFlow::
///         read_value marks a proven read: NarrowedAccessLowering makes it
///         `x.__value()`;
///       - the if-expression is typed as the operator was, which EmitIR
///         spells as `(c ? a : b)`, each arm converted to that type.
///
///     The operand appears twice in the expansion, so it must be evaluated
///     once (SequenceLowering's rule). A place (`x`, `o.cache`, `p->c`:
///     LowerSynth::pure) is simply read twice. Anything else (a call, a
///     moved value, a nested expansion) is bound first to a `__kairo_coalK`
///     local in a statement expression, and the then-arm MOVES the value out
///     of it: CopyMoveLowering ran before this pass and never saw the
///     local, and a copy there would duplicate a move-only payload or run
///     its destructor one time too many.
///
///   Phase: LOWER, immediately before NullTestLowering (Sema.k). Before it
///   and NarrowedAccessLowering, which lower the test and the marked read
///   it builds; before NullableTypeLowering, so every type it reads is still
///   a NullableType. After CopyMoveLowering, whose `x as T?&&` on a last use
///   it finds as a non-place operand and binds.
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
import Sema::Resolve::NameLookup::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;

/// The operand of an expansion, ready to be read twice: \p test is what the
/// null test asks, \p value the marked read for the then-arm. \p decl is the
/// local a non-place operand was bound to (null for a place), whose DeclStmt
/// the caller places in front of the expansion.
struct CoalesceOperand {
    var test:  *Expr          = &null;
    var value: *Expr          = &null;
    var decl:  *VariableDecl  = &null;
}

class CoalesceLowering derives ASTWriter::<CoalesceLowering> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;
    priv var tu:    TypeUtil;

    fn CoalesceLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
        self.tu    = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        // No builtin root: no `T?` was typed, so there is nothing to expand.
        if self.sc->well_known->get(WellKnownType::Nullable) == &null { return; }
        ASTWriter::<CoalesceLowering>::run(self.sc->tu);
    }

    // --- `??` -------------------------------------------------------------------

    /// `x ?? y`, its operands lowered first (`a ?? b ?? c` is `a ?? (b ?? c)`,
    /// and `x?.m ?? y` holds an expansion of its own on the left).
    fn transform_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *Expr {
        var out = ASTWriter::<CoalesceLowering>::transform_binary_operator_expr(n);
        if n->op_token.kind == TokenKind::OpEqualEqualEqual { return self._identity(n, out); }
        if n->op_token.kind != TokenKind::OpQuestionQuestion { return out; }
        if n->is_poisoned() || (n->type_ == &null) || (n->resolved_op != &null) { return out; }
        var lt = n->lhs->type_;
        if (lt == &null) || (self.tu.nullable_inner(lt) == &null) {
            // SC065W: a left side that is never null is the value, and the
            // right side is never evaluated.
            if (lt != &null) && (!lt->is_dependent()) { return n->lhs; }
            return out;
        }
        var stmts = self.list_builder::<*Stmt>();
        var opd = self._operand(n->lhs, &stmts);
        var ie = self._select(n->range, opd.test, opd.value, n->rhs, n->type_);
        return self._wrap(static_cast::<*Expr>(n), opd, &stmts, ie);
    }

    // --- `===` -----------------------------------------------------------------------

    /// `a === b` -> `(a? && b?) && a == b` (NULLABLE.md 2.3), its operands
    /// already lowered. Only a nullable side is tested (`a === 5` is
    /// `a? && a == 5`); each `a` after its test is the marked read, so the
    /// `==` compares the VALUES, with the operator typing recorded on the
    /// `===` (OperatorTyping::_identity_eq) moved onto it for
    /// OperatorLowering. A nullable pointer compares pointees: both values
    /// are dereferenced, `*p == *q`. An operand that is no place is bound
    /// first, as for `??`, so each is evaluated once, left to right.
    priv fn _identity(self, n: *BinaryOperatorExpr, out: *Expr) -> *Expr {
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        var lt = n->lhs->type_;
        var rt = n->rhs->type_;
        if (lt == &null) || (rt == &null) { return out; }
        var deref = self.tu.identity_derefs(lt, rt);
        var stmts = self.list_builder::<*Stmt>();
        var tests = vec::<*Expr>();
        var bound = false;
        var lv = self._identity_side(n->lhs, deref, &stmts, &tests, &bound);
        var rv = self._identity_side(n->rhs, deref, &stmts, &tests, &bound);

        var eq = BinaryOperatorExpr::create(self.ctx, n->range, lv, rv, self.synth.punct(n->range, TokenKind::OpEqualEqual));
        eq->resolved_op = n->resolved_op;
        eq->op_via_free = n->op_via_free;
        eq->op_instance = n->op_instance;
        eq->op_rewrite  = n->op_rewrite;
        eq->tag_eq      = n->tag_eq;
        eq->type_          = n->type_;
        eq->value_category = Expr::ValueCategory::RValue;

        var cond: *Expr = &null;
        for var i: usize = 0; i < tests.size(); ++i { cond = self._and(n, cond, tests[i]); }
        cond = self._and(n, cond, static_cast::<*Expr>(eq));
        if !bound {
            cond->expr_flags = n->expr_flags;
            return cond;
        }
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, cond)));
        return self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, n->type_);
    }

    /// One operand of `===`: its test (when nullable) pushed on \p tests, and
    /// the value the `==` reads returned, dereferenced when \p deref.
    priv fn _identity_side(self, e: *Expr, deref: bool, stmts: *ListBuilder::<*Stmt>,
                           tests: *vec::<*Expr>, bound: *bool) -> *Expr {
        var v = e;
        if self.tu.nullable_inner(self.tu.as_value(e->type_)) != &null {
            var opd = self._operand(e, stmts);
            if opd.decl != &null { (*bound) = true; }
            tests->push_back(self._test(e->range, opd.test));
            v = opd.value;
        }
        if !deref { return v; }
        var pt = self.tu.pointee(self.tu.as_value(v->type_));
        ICE_IF(pt == &null, "CoalesceLowering: `===` through pointers on a side that is no pointer; OperatorTyping::_type_identity gate failure");
        var d = UnaryOperatorExpr::create(self.ctx, e->range, v, self.synth.punct(e->range, TokenKind::OpStar),
                                          UnaryOperatorExpr::Fix::Prefix);
        d->type_          = pt;
        d->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(d);
    }

    /// `l && r`, typed bool; just \p r when \p l is null.
    priv fn _and(self, n: *BinaryOperatorExpr, l: *Expr, r: *Expr) -> *Expr {
        if l == &null { return r; }
        var both = BinaryOperatorExpr::create(self.ctx, n->range, l, r, self.synth.punct(n->range, TokenKind::OpAmpAmp));
        both->type_          = self.sc->builtin(BuiltinKind::Bool);
        both->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(both);
    }

    // --- `?.` / `?->` --------------------------------------------------------------

    /// `x?.m`, a field path through one or more `?.` / `?->` steps. Its base
    /// is lowered first; the steps name fields, never calls.
    fn transform_chain_expr(self, n: *ChainExpr) -> *Expr {
        var out = ASTWriter::<CoalesceLowering>::transform_chain_expr(n);
        if (!n->has_optional_chaining()) || n->is_poisoned() || (n->type_ == &null) { return out; }
        return self._safe(n, &null);
    }

    /// `x?.f(args)`: the call, arguments included, is the then-arm, so the
    /// callee chain is NOT expanded on its own; its base and the arguments
    /// are lowered first.
    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        var callee = self.tu.strip_parens(n->callee);
        var ce = dyn_cast::<ChainExpr>(callee);
        if (ce == &null) || (!ce->has_optional_chaining()) || n->is_poisoned() || ce->is_poisoned() || (n->safe_result == &null) {
            return ASTWriter::<CoalesceLowering>::transform_call_expr(n);
        }
        if ce->base != &null { ce->base = self.dyn()->transform_expr(ce->base); }
        self.dyn()->rebuild_expr_list(&(n->args));
        return self._safe(ce, n);
    }

    /// NULLABLE.md 2.5 for the chain \p c (the callee of \p call, when not
    /// null): every `?.` / `?->` step tests the value before it, left to
    /// right, and the then-arm is the chain with each of those reads marked
    /// narrowed and its separator made `.` / `->`:
    ///
    ///   a?.b?.c     ->  if a? && a.b? => a.b.c else null
    ///   p?->f(x)    ->  if p? => p->f(x) else null
    ///
    /// `&&` keeps each test on the path where the one before it held, so
    /// `a.b` is read only when `a` has a value, and the call and its
    /// arguments run only when every test held. The prefixes are places
    /// read again (a field path off a name is pure); a base that is no name
    /// is bound once. A `void` call becomes `if c { call }`.
    priv fn _safe(self, c: *ChainExpr, call: *CallExpr) -> *Expr {
        var orig: *Expr = (static_cast::<*Expr>(call)) if (call != &null) else (static_cast::<*Expr>(c));
        var stmts = self.list_builder::<*Stmt>();

        // The base, readable once per test and once in the then-arm.
        var bvd: *VariableDecl = &null;
        var bx = self.tu.strip_parens(c->base);
        if (bx != &null) && (!isa::<NamedIdentExpr>(bx)) {
            bvd = self.synth.local(c->base->range, "safe", self.tu.as_value(c->base->type_), c->base);
            stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, c->base->range, static_cast::<*Decl>(bvd))));
        }
        var base_marked = false;

        var acc   = vec::<ChainExpr::Step>();
        var tests = vec::<*Expr>();
        for var i: usize = 0; i < c->steps.size(); ++i {
            var st = *(c->steps.get(i));
            var qd = st.access_kind == ChainExpr::AccessKind::QuestionDot;
            var qa = st.access_kind == ChainExpr::AccessKind::QuestionArrow;
            if qd || qa {
                if i == 0 {
                    tests.push_back(self._test(st.range, self._base_read(c, bvd, false)));
                    base_marked = true;
                } else {
                    var held = acc[i - 1].resolved_type;
                    tests.push_back(self._test(st.range, self._prefix(c, bvd, base_marked, &acc, i, held)));
                    acc[i - 1].narrowed_from = held;
                    acc[i - 1].resolved_type = self._inner(held);
                }
                st.access_kind = (ChainExpr::AccessKind::Arrow) if (qa) else (ChainExpr::AccessKind::Dot);
            }
            acc.push_back(st);
        }

        var then_ty: *Type = &null;
        if call == &null {
            then_ty = acc[acc.size() - 1].resolved_type;
        }
        var path = self._prefix(c, bvd, base_marked, &acc, acc.size(), then_ty);
        var then: *Expr = path;
        if call != &null {
            path->type_ = c->type_;
            path->value_category = c->value_category;
            path->expr_flags = c->expr_flags;
            call->callee = path;
            then = static_cast::<*Expr>(call);
            then_ty = call->safe_result;
        }

        var cond = tests[0];
        for var i: usize = 1; i < tests.size(); ++i {
            var both = BinaryOperatorExpr::create(self.ctx, orig->range, cond, tests[i], self.synth.punct(orig->range, TokenKind::OpAmpAmp));
            both->type_          = self.sc->builtin(BuiltinKind::Bool);
            both->value_category = Expr::ValueCategory::RValue;
            cond = static_cast::<*Expr>(both);
        }

        var ty = orig->type_;
        if self.tu.is_builtin(ty, BuiltinKind::Void) {
            // A statement: `if c { call }`. The call keeps its own type.
            then->type_ = then_ty;
            var blk = CompoundStmt::create(self.ctx, orig->range);
            var body = self.list_builder::<*Stmt>();
            body.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, orig->range, then)));
            body.freeze_into(&(blk->body));
            stmts.push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, orig->range, cond, blk, &null)));
            return self.synth.stmt_expr(orig, &stmts, ty);
        }
        then->type_ = then_ty;
        var none = NullLiteralExpr::create(self.ctx, orig->range, false);
        none->type_          = ty;
        none->value_category = Expr::ValueCategory::RValue;
        var ie = IfExpr::create(self.ctx, orig->range, cond, then, static_cast::<*Expr>(none));
        ie->type_          = ty;
        ie->value_category = Expr::ValueCategory::RValue;
        var result = static_cast::<*Expr>(ie);
        if bvd == &null {
            result->expr_flags = orig->expr_flags;
            return result;
        }
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, orig->range, result)));
        return self.synth.stmt_expr(orig, &stmts, ty);
    }

    /// A new read of \p c's base: the bound local, or the name again.
    /// \p marked reads it as the value a `?.` on it proved.
    priv fn _base_read(self, c: *ChainExpr, bvd: *VariableDecl, marked: bool) -> *Expr {
        var e: *Expr = &null;
        if bvd != &null {
            e = self.synth.use_of(bvd, c->base->range, Expr::ValueCategory::LValue);
        } else {
            e = self._copy_name(cast::<NamedIdentExpr>(self.tu.strip_parens(c->base)));
        }
        if marked {
            var id = cast::<NamedIdentExpr>(e);
            var t  = self.tu.as_value(e->type_);
            id->narrowed_from = t;
            e->type_          = self._inner(t);
            e->value_category = Expr::ValueCategory::LValue;
        }
        return e;
    }

    /// \p c's base and its first \p k steps of \p acc (separators already
    /// made plain, earlier reads marked), as a new chain typed \p ty; the
    /// base alone when \p k is 0.
    priv fn _prefix(self, c: *ChainExpr, bvd: *VariableDecl, base_marked: bool,
                    acc: *vec::<ChainExpr::Step>, k: usize, ty: *Type) -> *Expr {
        var base = self._base_read(c, bvd, base_marked);
        if k == 0 { return base; }
        var end = (*acc)[k - 1].range.end;
        var pc = ChainExpr::create(self.ctx, SourceRange(c->range.start, end), base);
        var steps = ListBuilder::<ChainExpr::Step>(self.ctx);
        for var i: usize = 0; i < k; ++i { steps.push((*acc)[i]); }
        steps.freeze_into(&(pc->steps));
        var pe = static_cast::<*Expr>(pc);
        pe->type_          = ty;
        pe->value_category = Expr::ValueCategory::LValue;
        return pe;
    }

    /// `T?` -> `T`, keeping a `const` on the nullable.
    priv fn _inner(self, t: *Type) -> *Type {
        var inner = self.tu.nullable_inner(t);
        if inner == &null { return t; }
        if canon_has_const(t) { return self.sc->types->qualified(inner, QUAL_CONST()); }
        return inner;
    }

    // --- `unwrap!` ------------------------------------------------------------------

    /// `unwrap!(x)` -> `if x? => x else <abort>` (NULLABLE.md 2.6). Not as an
    /// if-expression: C++'s `?:` takes no `void` arm that is not a `throw`,
    /// so the abort is a statement in front of the read:
    ///
    ///   place      `*({ if !x? { unwrap_failed(m, n) }  &x })`   an lvalue
    ///   otherwise  `({ var t = e; if !t? { unwrap_failed(m, n) }  t as T&& })`
    ///
    /// A place is read through its address so the result is the place
    /// itself (`unwrap!(f).v = 4` writes `f`'s payload); anything else is
    /// bound once and its value moved out. `m` is the whole message, built
    /// here: "unwrap!(x) on null at file.k:12:9" and a newline.
    fn transform_unwrap_expr(self, n: *UnwrapExpr) -> *Expr {
        var out = ASTWriter::<CoalesceLowering>::transform_unwrap_expr(n);
        if n->is_poisoned() || (n->type_ == &null) || (n->operand == &null) || (n->operand->type_ == &null) { return out; }
        var val   = n->operand;
        var nt    = self.tu.as_value(val->type_);
        var inner = self._inner(nt);
        var stmts = self.list_builder::<*Stmt>();
        var x = self.tu.strip_parens(val);

        if LowerSynth::pure(x) && (isa::<NamedIdentExpr>(x) || isa::<ChainExpr>(x)) {
            stmts.push(self._abort_unless(n, x));
            var addr = self.synth.addr_of(self._marked_copy(x, nt, inner));
            stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, addr)));
            var se = self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, addr->type_);
            var d = UnaryOperatorExpr::create(self.ctx, n->range, se, self.synth.punct(n->range, TokenKind::OpStar),
                                              UnaryOperatorExpr::Fix::Prefix);
            d->adopt_sema(static_cast::<*Expr>(n));
            d->type_          = inner;
            d->value_category = Expr::ValueCategory::LValue;
            return static_cast::<*Expr>(d);
        }

        var vd = self.synth.local(val->range, "unwrap", nt, val);
        stmts.push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, val->range, static_cast::<*Decl>(vd))));
        stmts.push(self._abort_unless(n, self.synth.use_of(vd, val->range, Expr::ValueCategory::LValue)));
        var use = self._marked_copy(self.synth.use_of(vd, val->range, Expr::ValueCategory::LValue), nt, inner);
        var mv  = TypeCastExpr::create(self.ctx, val->range, use, self.sc->types->cxx_rref(canon_unqual(inner)));
        mv->type_          = canon_unqual(inner);
        mv->value_category = Expr::ValueCategory::RValue;
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(mv))));
        return self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, canon_unqual(inner));
    }

    /// `if !test? { unwrap_failed("<message>", <len>) }` for \p n.
    priv fn _abort_unless(self, n: *UnwrapExpr, test: *Expr) -> *Stmt {
        var d = self.sc->well_known->get(WellKnownType::UnwrapFailed);
        ICE_IF(d == &null, "CoalesceLowering: the 'unwrap_failed' lang item is unbound; Lib/builtin/module.k declares it");
        var f = dyn_cast::<FunctionDecl>(NameLookup::representative(d));
        ICE_IF(f == &null, "CoalesceLowering: the 'unwrap_failed' lang item is not a function");

        // The message, whole: the expression as written and where it is.
        var at   = n->range;
        var full = self.ctx->sm->get_line_col(at.start);
        var text = f"{self.ctx->get_spelling(at)} on null at {self.ctx->sm->get_filename(at.start)}:{full.line}:{full.column}";
        var bytes = vec::<u8>();
        for var i: usize = 0; i < text.size(); ++i { bytes.push_back(static_cast::<u8>(text[i])); }   // MIGRATE(raw_string)
        bytes.push_back(10);

        var u8t  = self.sc->types->qualified(self.sc->builtin(BuiltinKind::U8), QUAL_CONST());
        var pu8  = self.sc->types->pointer(u8t);
        var lit  = self.synth.bytes_literal(at, &bytes, pu8);
        var args = self.list_builder::<*Expr>();
        args.push(self.synth.cast_to(at, lit, pu8, CastMode::Unsafe));   // `"..."` is const char*; the parameter is const unsigned char*.
        args.push(self.synth.int_literal(at, static_cast::<u64>(bytes.size()), BuiltinKind::USize));

        var callee = NamedIdentExpr::create(self.ctx, at, self.synth.ident(at, self.tu.decl_name(static_cast::<*Decl>(f))));
        callee->resolved_decl = static_cast::<*Decl>(f);
        var call = CallExpr::create(self.ctx, at, static_cast::<*Expr>(callee));
        args.freeze_into(&(call->args));
        call->type_          = self.sc->builtin(BuiltinKind::Never);
        call->value_category = Expr::ValueCategory::RValue;

        var no = UnaryOperatorExpr::create(self.ctx, at, self._test(at, test), self.synth.punct(at, TokenKind::OpExclaim),
                                           UnaryOperatorExpr::Fix::Prefix);
        no->type_          = self.sc->builtin(BuiltinKind::Bool);
        no->value_category = Expr::ValueCategory::RValue;

        var blk  = CompoundStmt::create(self.ctx, at);
        var body = self.list_builder::<*Stmt>();
        body.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, call)));
        body.freeze_into(&(blk->body));
        return static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, static_cast::<*Expr>(no), blk, &null));
    }

    // --- the shared pieces ------------------------------------------------------

    /// \p e, a nullable, made readable twice: a place is read again (a
    /// fresh node per use), anything else is bound to a local first.
    priv fn _operand(self, e: *Expr, stmts: *ListBuilder::<*Stmt>) -> CoalesceOperand {
        var out = CoalesceOperand{};
        var nt  = self.tu.as_value(e->type_);
        var inner = self.tu.nullable_inner(nt);
        var x = self.tu.strip_parens(e);
        if LowerSynth::pure(x) && (isa::<NamedIdentExpr>(x) || isa::<ChainExpr>(x)) {
            out.test  = x;
            out.value = self._marked_copy(x, nt, inner);
            return out;
        }
        var vd = self.synth.local(e->range, "coal", nt, e);
        stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(vd))));
        out.decl = vd;
        out.test = self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue);
        var use  = self._marked_copy(self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue), nt, inner);
        // The local is this expansion's own: its value moves out.
        var mv = TypeCastExpr::create(self.ctx, e->range, use, self.sc->types->cxx_rref(canon_unqual(inner)));
        mv->type_          = canon_unqual(inner);
        mv->value_category = Expr::ValueCategory::RValue;
        out.value = static_cast::<*Expr>(mv);
        return out;
    }

    /// A NEW read of the place \p x (a name or a pure field path), marked
    /// as the nullness analysis marks a proven read: typed \p inner, its
    /// `T?` in narrowed_from (on the name, or on the chain's last step).
    priv fn _marked_copy(self, x: *Expr, nt: *Type, inner: *Type) -> *Expr {
        if isa::<NamedIdentExpr>(x) {
            var src = cast::<NamedIdentExpr>(x);
            var id  = NamedIdentExpr::create(self.ctx, x->range, src->name);
            id->resolved_decl  = src->resolved_decl;
            id->adopt_sema(x);
            id->narrowed_from  = nt;
            id->type_          = inner;
            id->value_category = Expr::ValueCategory::LValue;
            return static_cast::<*Expr>(id);
        }
        var c  = cast::<ChainExpr>(x);
        var base = c->base;
        if (base != &null) && isa::<NamedIdentExpr>(self.tu.strip_parens(base)) {
            base = self._copy_name(cast::<NamedIdentExpr>(self.tu.strip_parens(base)));
        }
        var cc = ChainExpr::create(self.ctx, x->range, base);
        var steps = ListBuilder::<ChainExpr::Step>(self.ctx);
        for var i: usize = 0; i < c->steps.size(); ++i {
            var st = *(c->steps.get(i));
            if i + 1 == c->steps.size() {
                st.narrowed_from = nt;
                st.resolved_type = inner;
            }
            steps.push(st);
        }
        steps.freeze_into(&(cc->steps));
        cc->variant_decl = c->variant_decl;
        var ce = static_cast::<*Expr>(cc);
        ce->adopt_sema(x);
        ce->type_          = inner;
        ce->value_category = Expr::ValueCategory::LValue;
        return ce;
    }

    /// One more node naming what \p n names.
    priv fn _copy_name(self, n: *NamedIdentExpr) -> *Expr {
        var id = NamedIdentExpr::create(self.ctx, n->range, n->name);
        id->resolved_decl = n->resolved_decl;
        id->narrowed_from = n->narrowed_from;
        var e = static_cast::<*Expr>(id);
        e->adopt_sema(static_cast::<*Expr>(n));
        return e;
    }

    /// `test?`: the null test NullTestLowering lowers, typed as the typer
    /// types it (bool, no user operator).
    priv fn _test(self, at: SourceRange, operand: *Expr) -> *Expr {
        var q = UnaryOperatorExpr::create(self.ctx, at, operand, self.synth.punct(at, TokenKind::OpQuestion),
                                          UnaryOperatorExpr::Fix::Postfix);
        q->type_          = self.sc->builtin(BuiltinKind::Bool);
        q->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(q);
    }

    /// `if test? => then else other`, typed \p ty.
    priv fn _select(self, at: SourceRange, test: *Expr, then: *Expr, other: *Expr, ty: *Type) -> *Expr {
        var ie = IfExpr::create(self.ctx, at, self._test(at, test), then, other);
        ie->type_          = ty;
        ie->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(ie);
    }

    /// \p e in place of \p orig: alone when the operand was a place, else
    /// after the local it was bound to, as a statement expression.
    priv fn _wrap(self, orig: *Expr, opd: CoalesceOperand, stmts: *ListBuilder::<*Stmt>, e: *Expr) -> *Expr {
        if opd.decl == &null {
            e->expr_flags = orig->expr_flags;
            return e;
        }
        stmts->push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, orig->range, e)));
        return self.synth.stmt_expr(orig, stmts, e->type_);
    }
}
