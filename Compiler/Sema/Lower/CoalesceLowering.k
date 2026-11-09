/// --- The Kairo Project ---------------- Sema/Lower/CoalesceLowering.k --- ///
///
///   \brief The nullable operators that choose a value, and a `match` on a
///          `T?`, become the if-expressions Compiler/Spec/Nullables.md#operator-typing / 3.6 write.
///
///   \detail
///     Compiler/Spec/Nullables.md#coalesce-2.6, §5 step 1:
///
///       x ?? y        ->  if x? => x else y
///       x?.m          ->  if x? => x.m else null       (`?->` alike; a chain
///       x?.f(args)    ->  if x? => x.f(args) else null  tests left to right)
///       unwrap!(x)    ->  if x? => x else <abort>      (a statement, see
///                                                       transform_unwrap_expr)
///       a === b       ->  (a? && b?) && a == b         (`*a == *b` through
///                                                       nullable pointers)
///       match x { case null { A } arms }
///                     ->  if !x? { A } else { match <x> { arms } }   (3.6)
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::LangItems::WellKnownType
import AST::Node::Base::{
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    QUAL_CONST,
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::VariableDecl
import AST::Node::Expressions::{
    BinaryOperatorExpr, CallExpr, IfExpr, MatchExpr, TypeCastExpr, UnaryOperatorExpr, UnwrapExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    ConditionalStmt,
    ExpressionStmt,
    MatchCase,
    MatchStmt,
}
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Location::SourceRange::SourceRange
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// The operand of an expansion, ready to be read twice: \p test is what the
/// null test asks, \p value the marked read for the then-arm. \p decl is the
/// local a non-place operand was bound to (null for a place), whose DeclStmt
/// the caller places in front of the expansion.
pub struct CoalesceOperand {
    var #test: unsafe *Expr         = &null
    var value: unsafe *Expr         = &null
    var decl:  unsafe *VariableDecl = &null
}

pub class CoalesceLowering derives ASTWriter<CoalesceLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var synth: LowerSynth
    priv var tu:    TypeUtil

    fn CoalesceLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.synth = LowerSynth(sc)
        self.tu    = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        // No builtin root: no `T?` was typed, so there is nothing to expand.
        if self.sc->well_known->get(WellKnownType::Nullable) == &null {
            return
        }

        ASTWriter<CoalesceLowering>::run(self, self.sc->tu)
    }

    /// # `??`

    /// `x ?? y`, its operands lowered first (`a ?? b ?? c` is `a ?? (b ?? c)`,
    /// and `x?.m ?? y` holds an expansion of its own on the left).
    fn transform_binary_operator_expr(self, n: unsafe *BinaryOperatorExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<CoalesceLowering>::transform_binary_operator_expr(self, n)
        if n->op_token.kind == TokenKind::OpEqualEqualEqual {
            return self._identity(n, out)
        }

        if n->op_token.kind != TokenKind::OpQuestionQuestion {
            return out
        }

        if n->is_poisoned() || n->type_ == &null || n->resolved_op != &null {
            return out
        }

        var unsafe *lt = n->lhs->type_
        // A C++ reference to a `T?` (`v[0] ?? 1` of a `vector<i32?>`) is
        // read as the nullable it refers to, as _operand reads it.
        if lt == &null || self.tu.nullable_inner(self.tu.as_value(lt)) == &null {
            // SC065W: a left side that is never null is the value, and the
            // right side is never evaluated.
            if lt != &null && !lt->is_dependent() {
                return n->lhs
            }

            return out
        }

        var        stmts = self.list_builder<unsafe *Stmt>()
        var        opd   = self._operand(n->lhs, unsafe &stmts, "coal")
        var unsafe *ie   = self._select(n->range, opd.#test, opd.value, n->rhs, n->type_)
        return self._wrap(n, opd, unsafe &stmts, ie)
    }

    /// # `===`

    /// `a === b` -> `(a? && b?) && a == b` (Compiler/Spec/Nullables.md#identity), its operands
    /// already lowered. Only a nullable side is tested (`a === 5` is
    /// `a? && a == 5`); each `a` after its test is the marked read, so the
    /// `==` compares the VALUES, with the operator typing recorded on the
    /// `===` (OperatorTyping::_identity_eq) moved onto it for
    /// OperatorLowering. A nullable pointer compares pointees: both values
    /// are dereferenced, `*p == *q`. An operand that is no place is bound
    /// first, as for `??`, so each is evaluated once, left to right.
    priv fn _identity(self, n: unsafe *BinaryOperatorExpr, out: unsafe *Expr) -> unsafe *Expr {
        if n->is_poisoned() || n->type_ == &null {
            return out
        }

        var unsafe *lt = n->lhs->type_
        var unsafe *rt = n->rhs->type_
        if lt == &null || rt == &null {
            return out
        }

        var        deref = self.tu.identity_derefs(lt, rt)
        var        stmts = self.list_builder<unsafe *Stmt>()
        var        tests = cxx::std::vector<unsafe *Expr>()
        var        bound = false
        var unsafe *lv   = self._identity_side(n->lhs, deref, unsafe &stmts, &tests, unsafe &bound)
        var unsafe *rv   = self._identity_side(n->rhs, deref, unsafe &stmts, &tests, unsafe &bound)

        var unsafe *eq = BinaryOperatorExpr::create(
            self.ctx,
            n->range,
            lv,
            rv,
            self.synth.punct(n->range, TokenKind::OpEqualEqual),
        )

        eq->resolved_op    = n->resolved_op
        eq->op_via_free    = n->op_via_free
        eq->op_instance    = n->op_instance
        eq->op_rewrite     = n->op_rewrite
        eq->tag_eq         = n->tag_eq
        eq->type_          = n->type_
        eq->value_category = Expr::ValueCategory::RValue

        var cond: unsafe *Expr = &null
        for var i: usize = 0; i < tests.size(); ++i {
            cond = self._and(n->range, cond, tests[i])
        }

        cond = self._and(n->range, cond, eq)
        if !bound {
            cond->expr_flags = n->expr_flags
            return cond
        }

        stmts.push(ExpressionStmt::create(self.ctx, n->range, cond))
        return self.synth.stmt_expr(unsafe (n as unsafe *Expr), &stmts, n->type_)
    }

    /// One operand of `===`: its test (when nullable) pushed on \p tests, and
    /// the value the `==` reads returned, dereferenced when \p deref.
    priv fn _identity_side(self,
                           e:            unsafe *Expr,
                           deref:        bool,
                           stmts:        unsafe *ListBuilder<unsafe *Stmt>,
                           @inout tests: cxx::std::vector<unsafe *Expr>,
                           bound:        unsafe *bool) -> unsafe *Expr {
        var unsafe *v = e
        if self.tu.nullable_inner(self.tu.as_value(e->type_)) != &null {
            var opd = self._operand(e, stmts, "coal")
            if opd.decl != &null {
                *bound = true
            }

            tests.push_back(self._test(e->range, opd.#test))
            v = opd.value
        }

        if !deref {
            return v
        }

        var unsafe *pt = self.tu.pointee(self.tu.as_value(v->type_))
        if pt == &null {
            kairo::std::ice_fail(
                "CoalesceLowering: `===` through pointers on a side that is no pointer; OperatorTyping::_type_identity gate failure",
            )
        }

        var unsafe *d = UnaryOperatorExpr::create(
            self.ctx,
            e->range,
            v,
            self.synth.punct(e->range, TokenKind::OpStar),
            UnaryOperatorExpr::Fix::Prefix,
        )

        d->type_          = pt
        d->value_category = Expr::ValueCategory::LValue
        return d
    }

    /// `l && r`, typed bool; just \p r when \p l is null.
    priv fn _and(self, at: SourceRange, l: unsafe *Expr, r: unsafe *Expr) -> unsafe *Expr {
        if l == &null {
            return r
        }

        var unsafe *both = BinaryOperatorExpr::create(
            self.ctx,
            at,
            l,
            r,
            self.synth.punct(at, TokenKind::OpAmpAmp),
        )

        both->type_          = self.sc->builtin(BuiltinKind::Bool)
        both->value_category = Expr::ValueCategory::RValue
        return both
    }

    /// # `match` on a `T?`

    /// `match x { case null { A } arms }` -> `if !x? { A } else { match <x> {
    /// arms } }` (Compiler/Spec/Nullables.md#match), where `<x>` is the marked read, so the
    /// match runs on the value. PatternCompilation built the match's tree
    /// over the arms after `case null` with the column `T` (null_arm); the
    /// arm stays in the list, unreached and emptied, so its index and every
    /// other arm's are what the tree names. A scrutinee that is no place is
    /// bound once and its value moved into the match.
    fn transform_match_stmt(self, n: unsafe *MatchStmt) -> cxx::std::vector<unsafe *Stmt> {
        var out = ASTWriter<CoalesceLowering>::transform_match_stmt(self, n)
        if !n->null_arm
            || n->scrutinee == &null
            || n->scrutinee->is_poisoned()
            || n->cases.size() == 0 {
            return out
        }

        var        stmts = self.list_builder<unsafe *Stmt>()
        var        opd   = self._operand(n->scrutinee, unsafe &stmts, "coal")
        var unsafe *arm0 = n->cases.get(0)
        var unsafe *none = self._take_null_arm(arm0, n->range)
        n->scrutinee = opd.value

        var unsafe *some = CompoundStmt::create(self.ctx, n->range)
        var        sb    = self.list_builder<unsafe *Stmt>()
        sb.push(unsafe (n as unsafe *Stmt))
        sb.freeze_into(&some->body)
        stmts.push(
            (unsafe ((ConditionalStmt::create(self.ctx, n->range, self._absent(n->range, opd.#test), none,
                                                                    unsafe (some as unsafe *Stmt))) as unsafe *Stmt)),
        )

        var unsafe *blk = CompoundStmt::create(self.ctx, n->range)
        stmts.freeze_into(&blk->body)
        return self._one_stmt(unsafe (blk as unsafe *Stmt))
    }

    /// The value form: `if x? => match <x> { arms } else A` (a value arm is
    /// always `=> expr`, S073E). An if-expression, as `??` is.
    fn transform_match_expr(self, n: unsafe *MatchExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<CoalesceLowering>::transform_match_expr(self, n)
        if !n->null_arm
            || n->scrutinee == &null
            || n->scrutinee->is_poisoned()
            || n->cases.size() == 0
            || n->type_ == &null {
            return out
        }

        var unsafe *arm0 = n->cases.get(0)
        if arm0->expression == &null {
            return out
        }

        var        stmts = self.list_builder<unsafe *Stmt>()
        var        opd   = self._operand(n->scrutinee, unsafe &stmts, "coal")
        var unsafe *a0   = arm0->expression
        arm0->expression = &null
        n->scrutinee     = opd.value
        var unsafe *ie = self._select(n->range, opd.#test, (unsafe (n as unsafe *Expr)), a0, n->type_)
        return self._wrap(n, opd, unsafe &stmts, ie)
    }

    /// Arm 0's code as a block of its own, the arm left empty: one node is
    /// never reachable from two places, or every later pass would rewrite
    /// it twice.
    priv fn _take_null_arm(self, arm0: unsafe *MatchCase, at: SourceRange) -> unsafe *CompoundStmt {
        var unsafe *blk = arm0->body
        if blk == &null {
            blk = CompoundStmt::create(self.ctx, arm0->range)
            if arm0->expression != &null {
                var b = self.list_builder<unsafe *Stmt>()
                b.push(ExpressionStmt::create(self.ctx, arm0->range, arm0->expression))
                b.freeze_into(&blk->body)
            }
        }

        arm0->body       = CompoundStmt::create(self.ctx, arm0->range)
        arm0->expression = &null
        return blk
    }

    /// `!test?`, typed bool.
    priv fn _absent(self, at: SourceRange, #test: unsafe *Expr) -> unsafe *Expr {
        var unsafe *no = UnaryOperatorExpr::create(
            self.ctx,
            at,
            self._test(at, #test),
            self.synth.punct(at, TokenKind::OpExclaim),
            UnaryOperatorExpr::Fix::Prefix,
        )

        no->type_          = self.sc->builtin(BuiltinKind::Bool)
        no->value_category = Expr::ValueCategory::RValue
        return no
    }

    /// # `?.` / `?->`

    /// `x?.m`, a field path through one or more `?.` / `?->` steps. Its base
    /// is lowered first; the steps name fields, never calls.
    fn transform_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<CoalesceLowering>::transform_chain_expr(self, n)
        if !n->has_optional_chaining() || n->is_poisoned() || n->type_ == &null {
            return out
        }

        return self._safe(n, &null)
    }

    /// `x?.f(args)`: the call, arguments included, is the then-arm, so the
    /// callee chain is NOT expanded on its own; its base and the arguments
    /// are lowered first.
    fn transform_call_expr(self, n: unsafe *CallExpr) -> unsafe *Expr {
        var unsafe *callee = self.tu.strip_parens(n->callee)
        var unsafe *ce     = dyn_cast<ChainExpr>(callee)
        if ce == &null
            || !ce->has_optional_chaining()
            || n->is_poisoned()
            || ce->is_poisoned()
            || n->safe_result == &null {
            return ASTWriter<CoalesceLowering>::transform_call_expr(self, n)
        }

        if ce->base != &null {
            ce->base = self.dyn()->transform_expr(ce->base)
        }

        self.dyn()->rebuild_expr_list(&n->args)
        return self._safe(ce, n)
    }

    /// Compiler/Spec/Nullables.md#safe-access for the chain \p c (the callee of \p call, when not
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
    priv fn _safe(self, c: unsafe *ChainExpr, call: unsafe *CallExpr) -> unsafe *Expr {
        var orig: unsafe *Expr = if (call != &null) => (unsafe (call as unsafe *Expr))
                                 else => unsafe (c as unsafe *Expr)
        var stmts = self.list_builder<unsafe *Stmt>()

        // The base, readable once per test and once in the then-arm.
        var        bvd: unsafe *VariableDecl = &null
        var unsafe *bx                       = self.tu.strip_parens(c->base)
        if bx != &null && !isa<NamedIdentExpr>(bx) {
            bvd = self.synth.bind(
                c->base->range,
                "safe",
                self.tu.as_value(c->base->type_),
                c->base,
                unsafe &stmts,
            )
        }

        var base_marked = false

        var acc   = cxx::std::vector<ChainExpr::Step>()
        var tests = cxx::std::vector<unsafe *Expr>()
        for var i: usize = 0; i < c->steps.size(); ++i {
            var st = *c->steps.get(i)
            var qd = st.access_kind == ChainExpr::AccessKind::QuestionDot
            var qa = st.access_kind == ChainExpr::AccessKind::QuestionArrow
            if qd || qa {
                if i == 0 {
                    tests.push_back(self._test(st.range, self._base_read(c, bvd, false)))
                    base_marked = true
                } else {
                    var unsafe *held = acc[i - 1].resolved_type
                    tests.push_back(
                        self._test(st.range, self._prefix(c, bvd, base_marked, acc, i, held)),
                    )

                    acc[i - 1].narrowed_from = held
                    acc[i - 1].resolved_type = self._inner(held)
                }

                st.access_kind = if (qa) => (ChainExpr::AccessKind::Arrow)
                                 else => ChainExpr::AccessKind::Dot
            }

            acc.push_back(st)
        }

        var then_ty: unsafe *Type = &null
        if call == &null {
            then_ty = acc[acc.size() - 1].resolved_type
        }

        var unsafe *path              = self._prefix(c, bvd, base_marked, acc, acc.size(), then_ty)
        var        then: unsafe *Expr = path
        if call != &null {
            path->type_          = c->type_
            path->value_category = c->value_category
            path->expr_flags     = c->expr_flags
            call->callee         = path
            then                 = unsafe (call as unsafe *Expr)
            then_ty              = call->safe_result
        }

        var cond: unsafe *Expr = &null
        for var i: usize = 0; i < tests.size(); ++i {
            cond = self._and(orig->range, cond, tests[i])
        }

        var unsafe *ty = orig->type_
        if self.tu.is_builtin(ty, BuiltinKind::Void) {
            // A statement: `if c { call }`. The call keeps its own type.
            then->type_ = then_ty
            var unsafe *blk = CompoundStmt::create(self.ctx, orig->range)
            var        body = self.list_builder<unsafe *Stmt>()
            body.push(ExpressionStmt::create(self.ctx, orig->range, then))
            body.freeze_into(&blk->body)
            stmts.push(ConditionalStmt::create(self.ctx, orig->range, cond, blk, &null))
            return self.synth.stmt_expr(orig, &stmts, ty)
        }

        then->type_ = then_ty
        var unsafe *none = NullLiteralExpr::create(self.ctx, orig->range, false)
        none->type_          = ty
        none->value_category = Expr::ValueCategory::RValue
        var unsafe *ie = IfExpr::create(self.ctx, orig->range, cond, then, none)
        ie->type_          = ty
        ie->value_category = Expr::ValueCategory::RValue
        var unsafe *result = unsafe (ie as unsafe *Expr)
        if bvd == &null {
            result->expr_flags = orig->expr_flags
            return result
        }

        stmts.push(ExpressionStmt::create(self.ctx, orig->range, result))
        return self.synth.stmt_expr(orig, &stmts, ty)
    }

    /// A new read of \p c's base: the bound local, or the name again.
    /// \p marked reads it as the value a `?.` on it proved.
    priv fn _base_read(self,
                       c:      unsafe *ChainExpr,
                       bvd:    unsafe *VariableDecl,
                       marked: bool) -> unsafe *Expr {
        var e: unsafe *Expr = &null
        if bvd != &null {
            e = self.synth.use_of(bvd, c->base->range, Expr::ValueCategory::LValue)
        } else {
            e = self._copy_name(cast<NamedIdentExpr>(self.tu.strip_parens(c->base)))
        }

        if marked {
            var unsafe *id = cast<NamedIdentExpr>(e)
            var unsafe *t  = self.tu.as_value(e->type_)
            id->narrowed_from = t
            e->type_          = self._inner(t)
            e->value_category = Expr::ValueCategory::LValue
        }

        return e
    }

    /// \p c's base and its first \p k steps of \p acc (separators already
    /// made plain, earlier reads marked), as a new chain typed \p ty; the
    /// base alone when \p k is 0.
    priv fn _prefix(self,
                    c:           unsafe *ChainExpr,
                    bvd:         unsafe *VariableDecl,
                    base_marked: bool,
                    const acc:   cxx::std::vector<ChainExpr::Step>,
                    k:           usize,
                    ty:          unsafe *Type) -> unsafe *Expr {
        var unsafe *base = self._base_read(c, bvd, base_marked)
        if k == 0 {
            return base
        }

        var        end   = (acc)[k - 1].range.end
        var unsafe *pc   = ChainExpr::create(self.ctx, SourceRange(c->range.start, end), base)
        var        steps = ListBuilder<ChainExpr::Step>(self.ctx)
        for var i: usize = 0; i < k; ++i {
            steps.push((acc)[i])
        }

        steps.freeze_into(&pc->steps)
        var unsafe *pe = unsafe (pc as unsafe *Expr)
        pe->type_          = ty
        pe->value_category = Expr::ValueCategory::LValue
        return pe
    }

    /// `T?` -> `T`, keeping a `const` on the nullable.
    priv fn _inner(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *inner = self.tu.nullable_inner(t)
        if inner == &null {
            return t
        }

        if canon_has_const(t) {
            return self.sc->types->qualified(inner, QUAL_CONST)
        }

        return inner
    }

    /// # `unwrap!`

    /// `unwrap!(x)` -> `if x? => x else <abort>` (Compiler/Spec/Nullables.md#unwrap). Not as an
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
    fn transform_unwrap_expr(self, n: unsafe *UnwrapExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<CoalesceLowering>::transform_unwrap_expr(self, n)
        if n->is_poisoned()
            || n->type_ == &null
            || n->operand == &null
            || n->operand->type_ == &null {
            return out
        }

        var unsafe *inner = self._inner(self.tu.as_value(n->operand->type_))
        var        stmts  = self.list_builder<unsafe *Stmt>()
        var        opd    = self._operand(n->operand, unsafe &stmts, "unwrap")
        stmts.push(self._abort_unless(n, opd.#test))

        if opd.decl == &null {
            var unsafe *addr = self.synth.addr_of(opd.value)
            stmts.push(ExpressionStmt::create(self.ctx, n->range, addr))
            var unsafe *se = self.synth.stmt_expr(unsafe (n as unsafe *Expr), &stmts, addr->type_)
            var unsafe *d = UnaryOperatorExpr::create(
                self.ctx,
                n->range,
                se,
                self.synth.punct(n->range, TokenKind::OpStar),
                UnaryOperatorExpr::Fix::Prefix,
            )

            d->adopt_sema(unsafe (n as unsafe *Expr))
            d->type_          = inner
            d->value_category = Expr::ValueCategory::LValue
            return d
        }

        stmts.push(ExpressionStmt::create(self.ctx, n->range, opd.value))
        return self.synth.stmt_expr(unsafe (n as unsafe *Expr), &stmts, canon_unqual(inner))
    }

    /// `if !test? { unwrap_failed("<message>", <len>) }` for \p n.
    priv fn _abort_unless(self, n: unsafe *UnwrapExpr, #test: unsafe *Expr) -> unsafe *Stmt {
        // The message, whole: the expression as written and where it is.
        var at   = n->range
        var full = self.ctx->sm->get_line_col(at.start)
        var text = f"{self.ctx->get_spelling(at)} on null at {self.ctx->sm->get_filename(at.start)}:{full.line}:{full.column}"
        var unsafe *call = self.synth.crash_call(at, text, "CoalesceLowering")
        return self.synth.crash_if(at, self._absent(at, #test), call)
    }

    /// # the shared pieces

    /// \p e, a nullable, made readable twice: a place is read again (a
    /// fresh node per use), anything else is bound to a `__kairo_<hint>K`
    /// local first and its value moved out.
    priv fn _operand(self,
                     e:          unsafe *Expr,
                     stmts:      unsafe *ListBuilder<unsafe *Stmt>,
                     const hint: string) -> CoalesceOperand {
        var        out    = CoalesceOperand{}
        var unsafe *nt    = self.tu.as_value(e->type_)
        var unsafe *inner = self.tu.nullable_inner(nt)
        var unsafe *x     = self.tu.strip_parens(e)
        if LowerSynth::pure(x) && (isa<NamedIdentExpr>(x) || isa<ChainExpr>(x)) {
            out.#test = x
            out.value = self._marked_copy(x, nt, inner)
            return out
        }

        var unsafe *vd = self.synth.bind(e->range, hint, nt, e, stmts)
        out.decl  = vd
        out.#test = self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue)
        var unsafe *use = self._marked_copy(
            self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue),
            nt,
            inner,
        )

        // The local is this expansion's own: its value moves out.
        var unsafe *mv = TypeCastExpr::create(
            self.ctx,
            e->range,
            use,
            self.sc->types->cxx_rref(canon_unqual(inner)),
        )

        mv->type_          = canon_unqual(inner)
        mv->value_category = Expr::ValueCategory::RValue
        out.value          = mv
        return out
    }

    /// A NEW read of the place \p x (a name or a pure field path), marked
    /// as the nullness analysis marks a proven read: typed \p inner, its
    /// `T?` in narrowed_from (on the name, or on the chain's last step).
    priv fn _marked_copy(self,
                         x:     unsafe *Expr,
                         nt:    unsafe *Type,
                         inner: unsafe *Type) -> unsafe *Expr {
        if isa<NamedIdentExpr>(x) {
            var unsafe *src = cast<NamedIdentExpr>(x)
            var unsafe *id  = NamedIdentExpr::create(self.ctx, x->range, src->name)
            id->resolved_decl = src->resolved_decl
            id->adopt_sema(x)
            id->narrowed_from  = nt
            id->type_          = inner
            id->value_category = Expr::ValueCategory::LValue
            return id
        }

        var unsafe *c    = cast<ChainExpr>(x)
        var unsafe *base = c->base
        if base != &null && isa<NamedIdentExpr>(self.tu.strip_parens(base)) {
            base = self._copy_name(cast<NamedIdentExpr>(self.tu.strip_parens(base)))
        }

        var unsafe *cc   = ChainExpr::create(self.ctx, x->range, base)
        var        steps = ListBuilder<ChainExpr::Step>(self.ctx)
        for var i: usize = 0; i < c->steps.size(); ++i {
            var st = *c->steps.get(i)
            if i + 1 == c->steps.size() {
                st.narrowed_from = nt
                st.resolved_type = inner
            }

            steps.push(st)
        }

        steps.freeze_into(&cc->steps)
        cc->variant_decl = c->variant_decl
        var unsafe *ce = unsafe (cc as unsafe *Expr)
        ce->adopt_sema(x)
        ce->type_          = inner
        ce->value_category = Expr::ValueCategory::LValue
        return ce
    }

    /// One more node naming what \p n names.
    priv fn _copy_name(self, n: unsafe *NamedIdentExpr) -> unsafe *Expr {
        var unsafe *id = NamedIdentExpr::create(self.ctx, n->range, n->name)
        id->resolved_decl = n->resolved_decl
        id->narrowed_from = n->narrowed_from
        var unsafe *e = unsafe (id as unsafe *Expr)
        e->adopt_sema(n)
        return e
    }

    /// `test?`: the null test NullTestLowering lowers, typed as the typer
    /// types it (bool, no user operator).
    priv fn _test(self, at: SourceRange, operand: unsafe *Expr) -> unsafe *Expr {
        var unsafe *q = UnaryOperatorExpr::create(
            self.ctx,
            at,
            operand,
            self.synth.punct(at, TokenKind::OpQuestion),
            UnaryOperatorExpr::Fix::Postfix,
        )

        q->type_          = self.sc->builtin(BuiltinKind::Bool)
        q->value_category = Expr::ValueCategory::RValue
        return q
    }

    /// `if test? => then else other`, typed \p ty.
    priv fn _select(self,
                    at:    SourceRange,
                    #test: unsafe *Expr,
                    then:  unsafe *Expr,
                    other: unsafe *Expr,
                    ty:    unsafe *Type) -> unsafe *Expr {
        var unsafe *ie = IfExpr::create(self.ctx, at, self._test(at, #test), then, other)
        ie->type_          = ty
        ie->value_category = Expr::ValueCategory::RValue
        return ie
    }

    /// \p e in place of \p orig: alone when the operand was a place, else
    /// after the local it was bound to, as a statement expression.
    priv fn _wrap(self,
                  orig:  unsafe *Expr,
                  opd:   CoalesceOperand,
                  stmts: unsafe *ListBuilder<unsafe *Stmt>,
                  e:     unsafe *Expr) -> unsafe *Expr {
        if opd.decl == &null {
            e->expr_flags = orig->expr_flags
            return e
        }

        stmts->push(ExpressionStmt::create(self.ctx, orig->range, e))
        return self.synth.stmt_expr(orig, &*stmts, e->type_)
    }
}
