/// --- The Kairo Project -------------------- Sema/Type/ControlTyping.k --- ///
///
///   \brief Every expression kind that is neither an operator, a call, a
///          member access, a cast nor a literal: value-producing control
///          flow, closures, initializers, and the keyword unaries that
///          desugar through lang items.
///
///   \detail
///     Branch joins (if / match / try) use Conversion::join: identical or
///     one-way-W or Never on one side; anything else is an error at the arm
///     that broke it, naming both types.
///
///     A closure is typed as its function-pointer canonical. Parameters must
///     be annotated (the docs say so); the return type is declared or inferred
///     from the body through the same frame machinery a function uses.
///
///     An enum variant construction -- `Shape::Rect { w: 1, h: 2 }`,
///     `Opt<i32>::Some { .. }`, `.Rect { .. }`, `.Empty`, and an ADT variant
///     without a payload named as a value -- is checked against the
///     variant's own payload. X records what it found, the node's
///     `variant_decl` and each field's `field_decl`, and builds nothing:
///     VariantInitLowering makes the node. `.V` takes its enum from the
///     expected type, as a `.V` pattern takes it from the scrutinee; as a call
///     argument it waits, like an untyped literal, for the parameter overload
///     resolution picks (dotted_variant_shape).
///
///     Lang-item desugars (`a..b` -> Range, `await` -> Future<T>, `spawn`)
///     are typed against the lang record and error when the item is unbound
///     -- that is the "error at USE" the SemaContext header promises.
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

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::DeclContext::DeclContextKind
import AST::Context::SymbolTable::DeclName
import AST::Kind::DeclKind::to_string
import AST::Kind::ExprKind::to_string
import AST::Kind::PatternKind::{
    PatternKind,
    to_string,
}
import AST::LangItems::{
    LangAttrs,
    WellKnownType,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    EnumVariantDecl,
    FieldDecl,
    FnModifier,
    ParamDecl,
    VariableDecl,
}
import AST::Node::Expressions
import AST::Node::Patterns::{
    AlternationPattern,
    ConstructorPattern,
    LiteralPattern,
    UnresolvedConstructorPattern,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Statements::{
    ExpressionStmt,
    MatchCase,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FixedArrayType,
}
import AST::ParamMode::ParamMode
import Diagnostic::Code::DiagCode
import Diagnostic::NoteText::declared_here
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::CaptureAnalysis::FreeVarScan
import Sema::Check::EffectPropagation::canonical_set
import Sema::Resolve::NameLookup::NameLookup
import Sema::Type::NullnessFlow::{
    NullEnv,
    Nullness,
    null_literal_of,
}
import Sema::Type::OverloadResolution::{
    ArgInfo,
    LitKind,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::VariadicEnum::VariadicEnum
import Token::TokenKind::TokenKind

// TODO(DUCK-GENERIC): T uses _enum_of, _head_decl, check_convertible, conv, ded_scratch, denoted_type, discr_enum, dispatch_stmt, fail, flow, frame_inferred_return, is_untyped_literal, ... (33). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> ControlTyping {
    @move
    fn ControlTyping(self, other: Self) = default
    fn ControlTyping(self) = default
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// # joins

    /// Join \p t into \p acc; on failure diagnose at \p at and return false.
    priv fn _join_into(self,
                       acc:        unsafe *(unsafe *Type),
                       t:          unsafe *Type,
                       at:         unsafe *Expr,
                       const what: string) -> bool {
        if t == &null { // unknown/poisoned arm: nothing to join, already reported.
            return true
        }

        // An arm is a value: an imported `T&`/`T&&` arm (an element accessor
        // beside a `T` arm) joins as the T it refers to, as a tuple element's
        // reference does; the reference type itself never unifies with T.
        var unsafe *cu = canon_unqual(t)
        if cu != &null && (isa<CXXLValueRefType>(cu) || isa<CXXRValueRefType>(cu)) {
            t = self.dyn()->tu.as_value(cu)
        }

        var j = self.dyn()->conv.join(*acc, t)
        if j == &null {
            self.dyn()->sc->diag->report(
                DiagID::SC039E,
                at->range.start,
                f"{what} has type '{self.dyn()->tu.str(t)}', which does not unify with the earlier '{self.dyn()->tu.str(*acc)}'",
            ).first(at->range)->note(
                at->range.start,
                "every branch of a value-producing construct must convert to one type",
            )->emit()
            return false
        }

        *acc = j
        return true
    }

    fn require_bool(self, e: unsafe *Expr, const what: string) -> bool {
        var t = self.dyn()->type_of(
            e,
            self.dyn()->tu.builtin(BuiltinKind::Bool),
        )

        if t == &null {
            return !e->is_poisoned()
        }

        if self.dyn()->tu.is_bool(t) {
            return true
        }

        // A C++ `bool&` (`flags[i]` on an `array<bool, N>`) is read as the
        // bool it refers to, as `!`, `&&` and C++ itself read it.
        var cu = canon_unqual(t)
        if cu != &null
            && (isa<CXXLValueRefType>(cu) || isa<CXXRValueRefType>(cu))
            && self.dyn()->tu.is_bool(self.dyn()->tu.as_value(cu)) {
            return true
        }

        // A `bool?` place as the condition reads its value (Compiler/Spec/Nullables.md#narrowed-reads).
        if self.dyn()->tu.is_bool(self.dyn()->tu.strip_nullable(t)) {
            t = self.dyn()->read_value(e)
            if t == &null {
                return false
            }

            if self.dyn()->tu.is_bool(t) {
                return true
            }
        }

        // A C++ class with `operator bool`: C++ converts it in a condition,
        // Kairo does not (control-flow: the condition must be bool), but the
        // cast reaches it, explicit or not -- say so, with the edit.
        var ts = self.dyn()->tu.str(t)
        if (!e->is_poisoned())
            && self.dyn()->conv.cxx_conversion_op(
                self.dyn()->tu.as_value(t),
                self.dyn()->tu.builtin(BuiltinKind::Bool),
                true,
            ) != &null {
            var b = self.dyn()->sc->diag->report(
                DiagID::SC084E,
                e->range.start,
                f"{what} must be 'bool', not '{ts}'",
            )

            b.first(e->range)
            b.insert(
                e->range.end,
                " as bool",
                "convert through the C++ class operator bool",
            )

            b.emit()
            e->poison()
            return false
        }

        self.dyn()->fail(
            e,
            DiagID::SC084E,
            f"{what} must be 'bool', not '{ts}'",
        )

        return false
    }

    /// # if / match / try as expressions

    /// A bare `&null` arm with nothing to take its pointer type from: no
    /// expected type, and every arm before it still instantiation-dependent
    /// (`f(if c => (dep_list[i]) else => &null)` in a generic class). It goes
    /// out as `nullptr`, which converts to whichever pointer the other arm
    /// turns out to be, so it is left untyped as `_type_args_dependent` does
    /// for a bare `&null` argument, rather than SC076E "cannot infer".
    priv fn _dependent_null_arm(self,
                                e:        unsafe *Expr,
                                expected: unsafe *Type,
                                acc:      unsafe *Type,
                                dep_seen: bool) -> bool {
        if !dep_seen || expected != &null || acc != &null {
            return false
        }

        var nl = dyn_cast<NullLiteralExpr>(self.dyn()->tu.strip_parens(e))
        if nl == &null || !nl->is_ref {
            return false
        }

        self.dyn()->mark_unknown(e)
        return true
    }

    /// Each arm is typed under its condition's true set, the next
    /// condition under the false sets before it (Compiler/Spec/Nullables.md#definitions-and-conditions); after
    /// the expression, the join of every arm's end.
    fn type_if_expr(self, n: unsafe *Expressions::IfExpr, expected: unsafe *Type) -> unsafe *Type {
        self.require_bool(n->condition, "the 'if' condition")
        var c                 = self.dyn()->flow.cond_of(n->condition)
        var acc: unsafe *Type = &null
        var ok                = true
        self.dyn()->flow.env = c.t
        var unsafe *t       = self._arm_value(n->then_expr, expected)
        var        dep_seen = t == &null && !n->then_expr->is_poisoned()
        var        out      = self.dyn()->flow.env
        var        rest     = c.f
        ok = self._join_into(unsafe &acc, t, n->then_expr, "the 'if' branch") && ok
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var unsafe *arm = n->else_ifs.get(i)
            self.dyn()->flow.env = rest
            self.require_bool(arm->condition, "the 'else if' condition")
            var ac = self.dyn()->flow.cond_of(arm->condition)
            self.dyn()->flow.env = ac.t
            var at: unsafe *Type = &null
            if self._dependent_null_arm(arm->body, expected, acc, dep_seen) {
                dep_seen = true
            } else {
                at = self._arm_value(
                    arm->body,
                    if (expected != &null) => (expected) else => acc,
                )
            }

            if at == &null && !arm->body->is_poisoned() {
                dep_seen = true
            }

            var arm_end = self.dyn()->flow.env
            out  = self.dyn()->flow.join(&out, &arm_end)
            rest = ac.f
            ok = self._join_into(unsafe &acc, at, arm->body, "this 'else if' branch") && ok
        }

        self.dyn()->flow.env = rest
        var et: unsafe *Type = &null
        if !self._dependent_null_arm(n->else_expr, expected, acc, dep_seen) {
            et = self._arm_value(
                n->else_expr,
                if (expected != &null) => (expected) else => acc,
            )
        }

        var else_end = self.dyn()->flow.env
        self.dyn()->flow.env = self.dyn()->flow.join(&out, &else_end)
        ok = self._join_into(unsafe &acc, et, n->else_expr, "the 'else' branch") && ok
        if !ok {
            self.dyn()->poison_only(n)
            return &null
        }

        if acc == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        // every branch must actually convert to the join.
        self.dyn()->check_convertible(n->then_expr, acc)
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            self.dyn()->check_convertible(n->else_ifs.get(i)->body, acc)
        }

        self.dyn()->check_convertible(n->else_expr, acc)
        return acc
    }

    /// An arm of a value-producing `if`: a nullable place its condition
    /// proved is its value (`if a? => a else 0` is an `i32`, the `??`
    /// expansion of Compiler/Spec/Nullables.md#coalesce); one not proven stays the nullable,
    /// which the join may well want.
    priv fn _arm_value(self, e: unsafe *Expr, expected: unsafe *Type) -> unsafe *Type {
        return self.dyn()->value_if_proven(e, self.dyn()->type_of(e, expected))
    }

    /// # match on a nullable (Compiler/Spec/Nullables.md#match)

    /// \p p is the `null` literal pattern.
    priv fn _null_pattern(self, p: unsafe *Pattern) -> bool {
        if p == &null || p->kind != PatternKind::LiteralPattern {
            return false
        }

        return null_literal_of(cast<LiteralPattern>(p)->value) != &null
    }

    /// \p p is, or has as an alternative, the `null` literal pattern.
    priv fn _has_null_pattern(self, p: unsafe *Pattern) -> bool {
        if self._null_pattern(p) {
            return true
        }

        if p == &null || p->kind != PatternKind::AlternationPattern {
            return false
        }

        var unsafe *a = cast<AlternationPattern>(p)
        for var i: usize = 0; i < a->alternatives.size(); ++i {
            if self._has_null_pattern(a->alternatives[i]) {
                return true
            }
        }

        return false
    }

    priv fn _arm_has_null(self, mc: unsafe *MatchCase) -> bool {
        for var j: usize = 0; j < mc->patterns.size(); ++j {
            if self._has_null_pattern(mc->patterns[j]) {
                return true
            }
        }

        return false
    }

    /// The `null_arm` of a match on \p st: whether its first arm is `case
    /// null`, alone and unguarded, so every later arm, `default` included,
    /// matches only a value. A match on a `T?` that does not answer null
    /// first is an error (DECIDED, Compiler/Spec/Nullables.md#match): with a fix-it inserting
    /// the arm when the match has none (statement form; an expression arm
    /// needs a value the fix-it cannot invent), else a note at the
    /// `case null` that is out of place. The scrutinee is then poisoned, so
    /// the pattern checks after typing do not judge a match whose arms were
    /// typed for a shape it does not have.
    fn match_null_first(self,
                        scrutinee: *Expr,
                        cases:     *FrozenList<MatchCase>,
                        st:        unsafe *Type,
                        at:        SourceRange,
                        stmt_form: bool) -> bool {
        if st == &null {
            return false
        }

        var nt = self.dyn()->tu.as_value(st)
        if self.dyn()->tu.nullable_inner(nt) == &null {
            return false
        }

        if cases->size() == 0 {
            return false
        }

        var unsafe *first = cases->get(0)
        if !first->is_default
            && first->patterns.size() == 1
            && self._null_pattern(first->patterns[0])
            && first->guard == &null {
            return true
        }

        var ts = self.dyn()->tu.str(nt)
        var b = self.dyn()->sc->diag->report(
            DiagID::SC254E,
            at.start,
            f"a match on '{ts}' must answer null first",
        )

        b.first(scrutinee->range)
        var late: usize = cases->size()
        for var i: usize = 0; i < cases->size(); ++i {
            if self._arm_has_null(cases->get(i)) {
                late = i
                break
            }
        }

        if late == 0 && first->guard != &null {
            b.note(
                first->guard->range.start,
                "'case null' takes no 'where' guard: null is answered once, by the first arm",
            )
        } else if late == 0 {
            b.note(
                first->range.start,
                "write 'case null' as an arm of its own: every arm after it matches only a value",
            )
        } else if late < cases->size() {
            b.note(
                cases->get(late)->range.start,
                "move this arm to the top: every arm after the first matches only a value",
            )
        } else if stmt_form {
            var lc  = self.dyn()->sc->ctx->sm->get_line_col(first->range.start)
            var pad = ""
            for var c: u32 = 1; c < lc.column; ++c {
                pad = pad + " "
            }

            b.insert(
                first->range.start,
                "case null { }\n" + pad,
                "answer null in the first arm",
            )
        } else {
            b.note(
                first->range.start,
                "add 'case null => <value>' as the first arm",
            )
        }

        b.emit()
        return false
    }

    /// The match on \p st is on a `T?` and does not answer null first: the
    /// error match_null_first reported. Its scrutinee is poisoned once the
    /// arms are typed.
    fn match_null_missed(self, null_arm: bool, st: unsafe *Type) -> bool {
        return !null_arm
            && st != &null
            && self.dyn()->tu.nullable_inner(self.dyn()->tu.as_value(st)) != &null
    }

    /// Arm \p i of a match on \p st enters: sets the nullness state its body
    /// starts from (out of \p entry) and returns the column its patterns are
    /// typed against. A `T?` scrutinee: the `case null` arm sees the place
    /// Null and matches the `T?`; every other arm sees it NonNull and matches
    /// the unwrapped `T` (`case var v` binds a `T`, `1..=3` is an integer
    /// range). A `case null` after the first arm is an error when \p null_arm
    /// already answered null (unless `T` is itself nullable: then it is
    /// `T`'s own null).
    fn match_arm_enter(self,
                       null_arm:  bool,
                       scrutinee: *Expr,
                       mc:        unsafe *MatchCase,
                       i:         usize,
                       st:        unsafe *Type,
                       entry:     *NullEnv) -> unsafe *Type {
        self.dyn()->flow.env = *entry
        if st == &null {
            return st
        }

        var nt    = self.dyn()->tu.as_value(st)
        var inner = self.dyn()->tu.nullable_inner(nt)
        if inner == &null {
            return st
        }

        if self._arm_has_null(mc) {
            if null_arm && i > 0 && self.dyn()->tu.nullable_inner(inner) == &null {
                for var j: usize = 0; j < mc->patterns.size(); ++j {
                    var unsafe *p = mc->patterns[j]
                    if !self._has_null_pattern(p) {
                        continue
                    }

                    self.dyn()->sc->diag->report(
                        DiagID::SC254E,
                        p->range.start,
                        f"'null' is answered by the first arm; this arm matches only a '{self.dyn()->tu.str(inner)}' value",
                    ).first(p->range)->emit()
                    p->poison()
                }

                self.dyn()->flow.put_state(
                    &self.dyn()->flow.env,
                    scrutinee,
                    Nullness::NonNull,
                    mc->range,
                )

                return inner
            }

            if i == 0 && null_arm {
                self.dyn()->flow.put_state(
                    &self.dyn()->flow.env,
                    scrutinee,
                    Nullness::Null,
                    mc->range,
                )
            }

            return st
        }

        self.dyn()->flow.put_state(
            &self.dyn()->flow.env,
            scrutinee,
            Nullness::NonNull,
            mc->range,
        )

        return inner
    }

    /// A `where` guard: bool, and its true set refines the arm (3.6).
    fn match_guard(self, mc: unsafe *MatchCase) {
        if mc->guard == &null {
            return
        }

        self.require_bool(mc->guard, "a 'where' guard")
        self.dyn()->flow.env = self.dyn()->flow.cond_of(mc->guard).t
    }

    /// A scrutinee typed only through a dependent call (`self.dyn()->kind()`
    /// in a duck-generic mixin) has no type here, so its arms were typed
    /// against nothing (a head left unresolved) and PatternChecking,
    /// PatternCompilation and MatchLowering all skipped the match: EmitIR met
    /// a MatchStmt nothing lowered. When an arm names a constant of a
    /// non-dependent enum, that enum is the column: the instance either
    /// yields it or the lowered `==` fails in C++, as the written test would.
    /// Returns \p st untouched when it is known or nothing names an enum.
    fn match_infer_column(self,
                          scrutinee: unsafe *Expr,
                          cases:     unsafe *FrozenList<MatchCase>,
                          st:        unsafe *Type) -> unsafe *Type {
        if st != &null {
            return st
        }

        if scrutinee == &null
            || scrutinee->is_poisoned()
            || !scrutinee->is_instantiation_dependent() {
            return st
        }

        for var i: usize = 0; i < cases->size(); ++i {
            var unsafe *mc = cases->get(i)
            for var j: usize = 0; j < mc->patterns.size(); ++j {
                var unsafe *et = self._enum_head_type(mc->patterns[j])
                if et != &null {
                    scrutinee->type_          = et
                    scrutinee->value_category = Expr::ValueCategory::RValue // ValueCategoryPass ICEs on a typed expr with none.
                    return et
                }
            }
        }

        return st
    }

    priv fn _enum_head_type(self, p: unsafe *Pattern) -> unsafe *Type {
        if p == &null {
            return &null
        }

        var t: unsafe *Type = &null
        match p->kind {
            case PatternKind::AlternationPattern {
                var unsafe *a = cast<AlternationPattern>(p)
                for var i: usize = 0; i < a->alternatives.size(); ++i {
                    t = self._enum_head_type(a->alternatives[i])
                    if t != &null {
                        return t
                    }
                }

                return &null
            } case PatternKind::LiteralPattern {
                var unsafe *l = cast<LiteralPattern>(p)
                if l->value != &null {
                    t = self.dyn()->type_of(l->value, &null)
                }
            } case PatternKind::ConstructorPattern {
                var unsafe *c = cast<ConstructorPattern>(p)
                if !c->is_dotted {
                    t = self.type_head(c->head)
                }
            } case PatternKind::UnresolvedConstructorPattern {
                t = self.type_head(cast<UnresolvedConstructorPattern>(p)->head)
            } default {
                return &null
            }
        }

        if t == &null {
            return &null
        }

        var u = canon_unqual(self.dyn()->tu.as_value(t))
        if u == &null || u->is_dependent() || !isa<RecordType>(u) {
            return &null
        }

        if dyn_cast<EnumDecl>(
            self.dyn()->tu.pattern_of(cast<RecordType>(u)->decl),
        ) == &null {
            return &null
        }

        return u
    }

    fn type_match_expr(self,
                       n:        unsafe *Expressions::MatchExpr,
                       expected: unsafe *Type) -> unsafe *Type {
        var st = self.dyn()->type_of(n->scrutinee, &null)
        st = self.match_infer_column(n->scrutinee, &n->cases, st)
        var acc: unsafe *Type = &null
        var ok                = true
        // As the statement form (StmtTyping::traverse_match_stmt).
        var entry = self.dyn()->flow.env
        n->null_arm = self.match_null_first(
            n->scrutinee,
            &n->cases,
            st,
            n->range,
            false,
        )

        var bad_null = self.match_null_missed(n->null_arm, st)
        var fl       = self.dyn()->flow.dead_env()
        for var i: usize = 0; i < n->cases.size(); ++i {
            var unsafe *mc = n->cases.get(i)
            if i > 0 {
                var end = self.dyn()->flow.env
                fl = self.dyn()->flow.join(&fl, &end)
            }

            var col = self.match_arm_enter(
                n->null_arm,
                n->scrutinee,
                mc,
                i,
                st,
                &entry,
            )

            for var j: usize = 0; j < mc->patterns.size(); ++j {
                self.dyn()->type_pattern(mc->patterns[j], col)
            }

            self.match_guard(mc)
            if mc->expression != &null {
                var t = self.dyn()->type_of(
                    mc->expression,
                    if (expected != &null) => (expected) else => acc,
                )

                ok = self._join_into(&acc, t, mc->expression, "this 'case' value") && ok
            } else if mc->body != &null {
                self.dyn()->dispatch_stmt(mc->body)
            }
        }

        if n->cases.size() > 0 {
            var last = self.dyn()->flow.env
            fl = self.dyn()->flow.join(&fl, &last)
        }

        self.dyn()->flow.env = fl
        if bad_null {
            n->scrutinee->poison()
        }

        if !ok {
            self.dyn()->poison_only(n)
            return &null
        }

        if acc == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        for var i: usize = 0; i < n->cases.size(); ++i {
            var unsafe *mc = n->cases.get(i)
            if mc->expression != &null {
                self.dyn()->check_convertible(mc->expression, acc)
            }
        }

        return acc
    }

    fn type_try_expr(self,
                     n:        unsafe *Expressions::TryCatchExpr,
                     expected: unsafe *Type) -> unsafe *Type {
        var acc: unsafe *Type = &null
        var ok                = true
        // A catch arm may start after any part of the `try` value ran: from
        // the state before it, with every global forgotten (calls).
        var entry     = self.dyn()->flow.env
        var arm_entry = self.dyn()->flow.try_entry(&entry, &null, n->try_expr)
        var t         = self.dyn()->type_of(n->try_expr, expected)
        var fl        = self.dyn()->flow.env
        ok = self._join_into(&acc, t, n->try_expr, "the 'try' value") && ok
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var unsafe *arm = n->catch_arms.get(i)
            if arm->decl != &null {
                var unsafe *vd = dyn_cast<VariableDecl>(arm->decl)
                if vd != &null && vd->type_ == &null {
                    var ft: unsafe *Type = &null
                    if arm->filter != &null && arm->filter->canonical != &null {
                        ft = arm->filter->canonical
                    }

                    if ft == &null {
                        var a = cxx::std::vector<*Type>()
                        ft = self.dyn()->tu.lang_record(
                            WellKnownType::Panic,
                            &a,
                        )
                    }

                    if ft != &null {
                        vd->type_ = canon_unqual(ft)
                    }
                }
            }

            self.dyn()->flow.env = arm_entry
            var at = self.dyn()->type_of(
                arm->body,
                if (expected != &null) => (expected) else => acc,
            )

            var arm_end = self.dyn()->flow.env
            fl = self.dyn()->flow.join(&fl, &arm_end)
            ok = self._join_into(&acc, at, arm->body, "this 'catch' value") && ok
        }

        self.dyn()->flow.env = fl
        if !ok {
            self.dyn()->poison_only(n)
            return &null
        }

        if acc == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        self.dyn()->check_convertible(n->try_expr, acc)
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            self.dyn()->check_convertible(n->catch_arms.get(i)->body, acc)
        }

        return acc
    }

    /// # ranges, async

    fn type_range(self, n: unsafe *Expressions::RangeExpr, expected: unsafe *Type) -> unsafe *Type {
        if (n->begin == &null || n->end == &null) && !n->as_index {
            self.dyn()->fail(
                n,
                DiagID::SC085E,
                "an open range is only valid as a slice index; give it both bounds",
            )

            return &null
        }

        var bt: unsafe *Type = &null
        var et: unsafe *Type = &null
        var b_lit = n->begin != &null && self.dyn()->is_untyped_literal(n->begin)
        var e_lit = n->end != &null && self.dyn()->is_untyped_literal(n->end)
        // An index range's literal bounds are usize, not i32: every `op []`
        // taking a range takes `Range<usize>` (and the open forms), and a
        // `Range<i32>` from `s[1..3]` would match none of them. Only a
        // literal takes the hint; a typed bound keeps its own type.
        var lit_t: unsafe *Type = &null
        if n->as_index {
            lit_t = self.dyn()->tu.builtin(BuiltinKind::USize)
        }

        if b_lit && !e_lit {
            if n->end != &null {
                et = self.dyn()->type_of(n->end, &null)
            }

            var unsafe *b_hint = et
            if b_hint == &null {
                b_hint = lit_t
            }

            bt = self.dyn()->type_of(n->begin, b_hint)
        } else {
            var b_hint: unsafe *Type = &null
            if b_lit {
                b_hint = lit_t
            }

            if n->begin != &null {
                bt = self.dyn()->type_of(n->begin, b_hint)
            }

            var unsafe *e_hint = bt
            if e_hint == &null && e_lit {
                e_hint = lit_t
            }

            if n->end != &null {
                et = self.dyn()->type_of(n->end, e_hint)
            }
        }

        if n->begin != &null && self.dyn()->propagate(n, n->begin)
            || n->end != &null && self.dyn()->propagate(n, n->end) {
            return &null
        }

        var unsafe *elem = if (bt != &null) => (bt) else => et
        if bt != &null && et != &null {
            elem = self.dyn()->unify_operands(bt, et)
            if elem == &null {
                self.dyn()->fail(
                    n,
                    DiagID::SC085E,
                    f"range bounds '{self.dyn()->tu.str(bt)}' and '{self.dyn()->tu.str(et)}' do not unify",
                )

                return &null
            }
        }

        if elem == &null { // `..`: the whole index space.
            elem = self.dyn()->tu.builtin(BuiltinKind::USize)
        }

        if !self.dyn()->tu.is_integer(elem) {
            self.dyn()->fail(
                n,
                DiagID::SC085E,
                f"range bounds must be integers, not '{self.dyn()->tu.str(elem)}'",
            )

            return &null
        }

        // An open range (only reachable as an index, gated above) is the
        // record of the bound it has: `a..` and `..` start somewhere and run
        // to the end, `..b` / `..=b` run from the start.
        var k = WellKnownType::Range
        if n->end == &null {
            k = WellKnownType::RangeFrom
        } else if n->begin == &null {
            k = WellKnownType::RangeTo
        }

        var a = cxx::std::vector<unsafe *Type>()
        a.push_back(elem)
        var r = self.dyn()->tu.lang_record(k, &a)
        if r == &null {
            self.dyn()->missing_lang_item(n, to_string(k))
            return &null
        }

        return r
    }

    fn type_await(self, n: unsafe *Expressions::AwaitExpr, expected: unsafe *Type) -> unsafe *Type {
        var ot = self.dyn()->type_of(n->operand, &null)
        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        if ot == &null {
            return &null
        }

        if !self.dyn()->tu.is_lang(ot, WellKnownType::Future) {
            if self.dyn()->sc->well_known->get(WellKnownType::Future) == &null {
                self.dyn()->missing_lang_item(
                    n,
                    to_string(WellKnownType::Future),
                )

                return &null
            }

            self.dyn()->fail(
                n,
                DiagID::SC086E,
                f"'await' requires a 'Future', not '{self.dyn()->tu.str(ot)}'",
            )

            return &null
        }

        var args = self.dyn()->tu.record_args(ot)
        if args.size() == 0 {
            return self.dyn()->tu.builtin(BuiltinKind::Void)
        }

        return args[0]
    }

    fn type_spawn(self,
                  n:        unsafe *Expr,
                  operand:  unsafe *Expr,
                  expected: unsafe *Type) -> unsafe *Type {
        var ot = self.dyn()->type_of(operand, &null)
        if self.dyn()->propagate(n, operand) {
            return &null
        }

        if ot == &null {
            return &null
        }

        var a = cxx::std::vector<*Type>()
        a.push_back(ot)
        var f = self.dyn()->tu.lang_record(WellKnownType::Future, &a)
        if f == &null {
            self.dyn()->missing_lang_item(n, to_string(WellKnownType::Future))
            return &null
        }

        return f
    }

    /// # closures

    fn type_closure(self,
                    n:        unsafe *Expressions::ClosureExpr,
                    expected: unsafe *Type) -> unsafe *Type {
        // parameter types are required; the frame gives `return` its target.
        // Modes ride parallel: a closure's type IS the fn-pointer canonical,
        // so a mode not collected here does not exist for closures.
        var params = cxx::std::vector<unsafe *Type>()
        var modes  = cxx::std::vector<ParamMode>()
        var ok     = true
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null {
                continue
            }

            if p->type_ == &null || p->type_->canonical == &null {
                if p->type_ != &null && p->type_->is_dependent() {
                    self.dyn()->mark_unknown(n)
                } else {
                    self.dyn()->fail(
                        n,
                        DiagID::SC087E,
                        f"closure parameter '{self.dyn()->tu.param_name(p)}' needs a type annotation",
                    )
                }

                ok = false
                continue
            }

            // a function type has no top-level cv on its parameters ([dcl.fct]/5)
            params.push_back(canon_unqual(p->type_->canonical))
            modes.push_back(p->mode)
            if p->default_val != &null {
                self.dyn()->push_null_target(p->default_val, p->type_, p)
                self.dyn()->type_of(p->default_val, p->type_->canonical)
                self.dyn()->pop_null_target()
                self.dyn()->check_convertible(
                    p->default_val,
                    p->type_->canonical,
                )
            }
        }

        for var i: usize = 0; i < n->captures.size(); ++i {
            var unsafe *c = n->captures.get(i)
            if c->name != &null {
                self.dyn()->type_of(c->name, &null)
                self.dyn()->flow.consumed(c->name) // the closure holds it: closure_made.
            }
        }

        // What calling it may write (Compiler/Spec/Nullables.md#aliases-and-closures).
        self.dyn()->flow.closure_made(n)

        var declared: unsafe *Type = &null
        if n->return_type != &null {
            declared = n->return_type->canonical
        }

        if n->is_noreturn {
            declared = self.dyn()->tu.builtin(BuiltinKind::Never)
        }

        self.dyn()->push_closure_frame(n, declared)
        var inferred: unsafe *Type = &null
        if n->body_expr != &null {
            var bt = self.dyn()->type_of(n->body_expr, declared)
            if declared != &null {
                self.dyn()->check_convertible(n->body_expr, declared)
            } else {
                inferred = bt
            }
        } else if n->body_block != &null {
            self.dyn()->dispatch_stmt(n->body_block)
            inferred = self.dyn()->frame_inferred_return()
        }

        self.dyn()->pop_frame()
        if !ok {
            return &null
        }

        var unsafe *ret = declared
        if ret == &null {
            ret = if (inferred != &null) => (canon_unqual(inferred))
                  else => self.dyn()->tu.builtin(BuiltinKind::Void)
            if n->return_type == &null { // inferred slot := canonical (self-canonical).
                n->return_type = ret
            }
        }

        if n->body_expr != &null && n->body_expr->type_ == &null && !n->body_expr->is_poisoned() {
            self.dyn()->mark_unknown(n)
            return &null
        }

        // The effect is part of the type (Compiler/Spec/Panic.md#declared-sets): the declared set,
        // which a closure must write; a bare `panic` closure is the
        // error PanicEffectChecking reports, and its type has no set.
        var panics = ((n->modifiers as u16) & (FnModifier::IsPanic as u16)) != 0
        var pset   = cxx::std::vector<*Type>()
        if panics {
            canonical_set(&self.dyn()->tu, &n->panic_set, &pset)
        }

        // A closure that captures nothing IS a function: its type is the raw
        // `unsafe fn`, so it goes where a C function pointer is wanted, and
        // widens to a `fn` value anywhere else (Conversion's fn rung). A
        // `var` it initializes is a `fn` value (StmtTyping::_fn_value_decay).
        var raw = self._captures_nothing(n)
        return self.dyn()->sc->types->func(
            &params,
            &modes,
            canon_unqual(ret),
            panics,
            &pset,
            raw,
        )
    }

    /// \p n's free bindings (FreeVarScan, the scan ClosureCaptures decides
    /// from) hold no local, parameter or `self` of a function around it:
    /// the lambda would have an empty capture list.
    priv fn _captures_nothing(self, n: unsafe *Expressions::ClosureExpr) -> bool {
        var scan = FreeVarScan()
        scan.run_closure(n)
        for var i: usize = 0; i < scan.free.size(); ++i {
            var unsafe *d = scan.free[i]
            if isa<ParamDecl>(d) {
                return false
            }

            var unsafe *v = dyn_cast<VariableDecl>(d)
            if v == &null || v->is_static() {
                continue
            }

            // A script's top-level `var` the closure copies: a
            // capture, as ClosureCaptures will record it.
            if self.dyn()->script_copy_capture(n, d) || self.dyn()->script_local_capture(n, d) {
                return false
            }

            var unsafe *dc = v->semantic_dc
            if dc == &null {
                return false
            }

            if dc->is_function()
                || dc->dc_kind == DeclContextKind::Block
                || dc->dc_kind == DeclContextKind::Lambda {
                return false
            }
        }

        return true
    }

    /// # initializers

    /// `Point { x: 1, y: 2 }`; and an enum variant built with its payload,
    /// `Shape::Rect { w: 1, h: 2 }` / `Opt<i32>::Some { v: 1 }`, or written
    /// dotted, `.Rect { .. }` / `.Empty`, with the expected type's enum.
    fn type_named_init(self,
                       n:        unsafe *Expressions::NamedInitializerExpr,
                       expected: unsafe *Type) -> unsafe *Type {
        if n->is_dotted {
            return self._type_dotted_init(n, expected)
        }

        // A head, not a value: a variant it names is the one this initializer
        // builds, not a construction of its own.
        self.type_head(n->type_expr)
        var rec = self.dyn()->denoted_type(n->type_expr)
        if rec == &null {
            if n->type_expr->is_poisoned() {
                self.dyn()->poison_only(n)
                return &null
            }

            var v = dyn_cast<EnumVariantDecl>(
                self.dyn()->_head_decl(n->type_expr),
            )

            if v != &null {
                return self._type_variant_head(n, v)
            }

            self.dyn()->fail(
                n,
                DiagID::SC088E,
                "initializer head does not name a type",
            )

            return &null
        }

        return self._init_fields(n, rec, n->fields)
    }

    /// `{ .x: 1, .y: 2 }` -- the type comes from context.
    fn type_anon_init(self,
                      n:        unsafe *Expressions::AnonInitializerExpr,
                      expected: unsafe *Type) -> unsafe *Type {
        var rec = self.dyn()->tu.strip_nullable(expected)
        if rec == &null || self.dyn()->tu.record_decl(rec) == &null {
            for var i: usize = 0; i < n->fields.size(); ++i {
                self.dyn()->type_of(n->fields.get(i)->value, &null)
            }

            self.dyn()->fail(
                n,
                DiagID::SC088E,
                "cannot infer the type of an anonymous initializer here; name the type or annotate the target",
            )

            return &null
        }

        return self._init_fields(n, rec, n->fields)
    }

    /// A dependent head that can be NAMED -- `Cell<T>`, `Box<U>`, `Self` in a
    /// generic body -- is a type, not unknown: the node is typed with that
    /// dependent canonical and its fields are checked against the record's
    /// declared fields, read through the head's arguments. MemberLookup keys
    /// on the decl, so the names resolve exactly as `self.x` does in
    /// `class <T> Foo`. Only a head with no record to name (an unbounded
    /// `T::Inner`, a duck-typed `T`) stays unknown; codegen ICEs on an
    /// untyped initializer, so this is the line between the two.
    priv fn _init_fields(self,
                         n:      *Expr,
                         rec:    unsafe *Type,
                         fields: FrozenList<Expressions::InitField>) -> unsafe *Type {
        if isa<AssocType>(canon_unqual(rec)) {
            return self._assoc_init(n, rec, fields)
        }

        var d = self.dyn()->tu.record_decl(rec)
        if d == &null && rec->is_dependent() {
            for var i: usize = 0; i < fields.size(); ++i {
                self.dyn()->type_of(fields.get(i)->value, &null)
            }

            self.dyn()->mark_unknown(n)
            return &null
        }

        if d == &null {
            self.dyn()->fail(
                n,
                DiagID::SC088E,
                f"'{self.dyn()->tu.str(rec)}' is not an aggregate",
            )

            return &null
        }

        if !rec->is_dependent() && self.dyn()->reject_abstract(n, d) {
            for var i: usize = 0; i < fields.size(); ++i {
                self.dyn()->type_of(fields.get(i)->value, &null)
            }

            return &null
        }

        // The table the fields live in: a partial specialization's, for an
        // instance (or a dependent `Pair<X, i32>`) its args select.
        var body = self.dyn()->sc->record_body(rec)
        if body == &null {
            body = self.dyn()->tu.pattern_of(d)
        }

        var dc = NameLookup::context_of(body)
        var ok = true
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f      = fields.get(i)
            var        spelled = self.dyn()->sc->ctx->get_spelling(f->name)
            var        imm     = self.dyn()->sc->ctx->get_ident_imm(f->name)
            var cell = self.dyn()->sc->lookup.in_context(
                dc,
                DeclName::ident(imm),
                spelled,
            )

            var fd: unsafe *FieldDecl = &null
            if cell.found() {
                fd = dyn_cast<FieldDecl>(cell.first())
            }

            if fd == &null {
                self.dyn()->type_of(f->value, &null)
                self.dyn()->sc->diag->report(
                    DiagID::SC040E,
                    f->range.start,
                    f"'{self.dyn()->tu.decl_name(d)}' has no field named '{spelled}'",
                ).first(f->range)->emit()
                ok = false
                continue
            }

            var unsafe *ft = if (fd->type_ != &null) => (fd->type_->canonical) else => &null
            if ft != &null {
                ft = self.dyn()->ded_scratch()->member_through(rec, ft)
            }

            self.dyn()->push_null_target(f->value, fd->type_, fd)
            self.dyn()->type_of(f->value, ft)
            self.dyn()->pop_null_target()
            if self.dyn()->reject_slice_literal(f->value, "stored in a field") {
                ok = false
                continue
            }

            // `Full{ buf: self.buf }` reached clang as an array copy.
            if ft != &null && self.dyn()->reject_array_copy(f->value, ft) {
                ok = false
                continue
            }

            // Either side dependent: whether `v: T` converts to `.x: T` is the
            // instance's question, asked again once T is known.
            var unsafe *vt = f->value->type_
            if ft != &null && ft->is_dependent() {
                continue
            }

            if vt != &null && vt->is_dependent() {
                continue
            }

            if ft != &null && !self.dyn()->check_convertible(f->value, ft) {
                ok = false
            }
        }

        if !ok {
            self.dyn()->poison_only(n)
            return &null
        }

        return rec
    }

    /// `T::Node { }`: a generic body builds an associated type only through
    /// a constructor its bounds promise (interfaces.md, Generic Bodies: a
    /// body uses exactly what the bounds declare), so `{ }` needs a bound
    /// with a no-argument constructor requirement, `type Node impl Default`.
    /// Its fields are no bound's, so a field list is never allowed.
    priv fn _assoc_init(self,
                        n:      *Expr,
                        rec:    unsafe *Type,
                        fields: FrozenList<Expressions::InitField>) -> unsafe *Type {
        for var i: usize = 0; i < fields.size(); ++i {
            self.dyn()->type_of(fields.get(i)->value, &null)
        }

        var unsafe *a = cast<AssocType>(canon_unqual(rec))
        var        ts = self.dyn()->tu.str(rec)
        var        an = self.dyn()->tu.decl_name(a->assoc)
        if fields.size() > 0 {
            var b = self.dyn()->sc->diag->report(
                DiagID::SC088E,
                n->range.start,
                f"'{ts}' is an associated type: a generic body knows none of its fields",
            )

            b.first(n->range)
            b.note(
                a->assoc->range.start,
                f"'{an}' is declared here; build it through a constructor bound ('type {an} impl ...')",
            )->child_first(a->assoc->range)
            b.emit()
            self.dyn()->poison_only(n)
            return &null
        }

        if !Substitution(self.dyn()->sc).bounds_construct(rec, 0) {
            var b = self.dyn()->sc->diag->report(
                DiagID::SC251E,
                n->range.start,
                f"cannot construct '{ts}': no bound of associated type '{an}' requires a constructor taking no arguments",
            )

            b.first(n->range)
            b.note(
                a->assoc->range.start,
                f"'{an}' is declared here; bound it with an interface that declares a constructor requirement",
            )->child_first(a->assoc->range)
            b.emit()
            self.dyn()->poison_only(n)
            return &null
        }

        n->value_category = Expr::ValueCategory::RValue
        return rec
    }

    /// # enum variants

    /// Type \p e as a head -- the path before an initializer's braces or a
    /// pattern's payload -- rather than as a value. A variant it names is
    /// what the initializer builds or the pattern matches, so it must not
    /// become a construction of its own (type_variant_value).
    fn type_head(self, e: unsafe *Expr) -> unsafe *Type {
        if e == &null {
            return &null
        }

        var outer = self.dyn()->variant_head
        self.dyn()->variant_head = e
        var t = self.dyn()->type_of(e, &null)
        self.dyn()->variant_head = outer
        return t
    }

    /// A variant named as a value -- `Opt::None`, `Opt<i32>::None`, or a bare
    /// `None` inside its enum -- already typed \p t, the enum, by MemberTyping
    /// or _type_ident. An ADT's variant is a construction, checked as `.None`
    /// is: only one without a payload may be written without braces. A plain
    /// enum's stays the value it names; so does a head (type_head), and a
    /// variant read inside its enum's discriminants, where it is an integer.
    fn type_variant_value(self,
                          at: unsafe *Expr,
                          v:  unsafe *EnumVariantDecl,
                          t:  unsafe *Type) -> unsafe *Type {
        if t == &null || at == self.dyn()->variant_head || self.dyn()->discr_enum != &null {
            return t
        }

        var en = self.dyn()->_enum_of(t)
        if en == &null || !en->is_adt {
            return t
        }

        var idx = self._variant_index(en, self.dyn()->tu.decl_name(v))
        if idx < 0 {
            return t
        }

        return self._check_variant(
            at,
            en,
            idx as usize,
            t,
            false,
            create_empty_frozen_list<Expressions::InitField>(),
        )
    }

    /// `.V` as a call argument. Nothing gives it a type until the call is
    /// resolved, so, like an untyped literal, it is ranked by its shape --
    /// viable against a parameter whose enum has a variant of that name -- and
    /// typed against the parameter selection picked (finish_call_args).
    fn dotted_variant_shape(self, e_in: *Expr, a: *ArgInfo) -> bool {
        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null || !isa<Expressions::NamedInitializerExpr>(e) {
            return false
        }

        var n = cast<Expressions::NamedInitializerExpr>(e)
        if !n->is_dotted || n->type_ != &null || n->is_poisoned() {
            return false
        }

        a->lit      = LitKind::Variant
        a->lit_name = self.dyn()->sc->ctx->get_spelling(n->dotted_name)
        return true
    }

    /// `Shape::Rect { .. }` / `Opt<i32>::Some { .. }`. The head is typed as the
    /// enum -- its instance when it has arguments -- and that is the type the
    /// construction has. The variant is found again by name in the enum's own
    /// list: its position there is its tag, and its payload is the one the
    /// enum's layout holds.
    priv fn _type_variant_head(self,
                               n: *Expressions::NamedInitializerExpr,
                               v: *EnumVariantDecl) -> unsafe *Type {
        var unsafe *rec                  = n->type_expr->type_
        var        en:  unsafe *EnumDecl = &null
        if rec != &null {
            en = self.dyn()->_enum_of(rec)
        }

        var idx: i32 = -1
        if en != &null {
            idx = self._variant_index(en, self.dyn()->tu.decl_name(v))
        }

        if idx < 0 {
            // The head's enum is not known here (dependent, or foreign): there
            // is no payload to check the fields against.
            self._type_fields_unknown(n->fields)
            self.dyn()->mark_unknown(n)
            return &null
        }

        return self._check_variant(
            unsafe (n as unsafe *Expr),
            en,
            idx as usize,
            rec,
            true,
            n->fields,
        )
    }

    /// `.Rect { .. }` / `.Empty`. The expected type names the enum, as the
    /// scrutinee does for a `.Rect` pattern, and a failure is the pattern's
    /// SC123E. A nullable target names its inner type. A bare generic
    /// parameter has no enum to resolve against until the instance: unknown,
    /// as an initializer whose head is one is (_init_fields).
    priv fn _type_dotted_init(self,
                              n:        unsafe *Expressions::NamedInitializerExpr,
                              expected: unsafe *Type) -> unsafe *Type {
        var nm               = self.dyn()->sc->ctx->get_spelling(n->dotted_name)
        var st: unsafe *Type = &null
        if expected != &null {
            st = canon_unqual(
                self.dyn()->tu.strip_nullable(self.dyn()->tu.as_value(expected)),
            )
        }

        if st == &null {
            self._type_fields_unknown(n->fields)
            self.dyn()->fail(
                n,
                DiagID::SC123E,
                f"'.{nm}' names an enum variant, but nothing here gives it an enum type; write the enum's name before it",
            )

            return &null
        }

        var en = self.dyn()->_enum_of(st)
        if en == &null {
            self._type_fields_unknown(n->fields)
            if st->is_dependent() && self.dyn()->tu.record_decl(st) == &null {
                self.dyn()->mark_unknown(n)
                return &null
            }

            self.dyn()->fail(
                n,
                DiagID::SC123E,
                f"'.{nm}' names an enum variant, but the expected type is '{self.dyn()->tu.str(st)}', not an enum",
            )

            return &null
        }

        var idx = self._variant_index(en, nm)
        if idx < 0 {
            self._type_fields_unknown(n->fields)
            self.dyn()->fail(
                n,
                DiagID::SC123E,
                f"'{self.dyn()->tu.str(st)}' has no variant named '{nm}'",
            )

            return &null
        }

        return self._check_variant(
            n,
            en,
            idx as usize,
            st,
            n->has_braces,
            n->fields,
        )
    }

    /// Check one variant construction, written as \p n, and record it: the
    /// variant on \p n (`variant_decl`) and on each field the payload field
    /// it fills (`field_decl`). VariantInitLowering builds the node from
    /// those. \p rec is the enum type the construction has: the head's, or
    /// the expected type for `.V`.
    ///
    /// The payload FieldDecls are read off the variant itself, not looked up
    /// in a scope: they are the variant's own, and the enum's layout and the
    /// match lowering both key on their identity. Each written field is
    /// matched by name and typed against its field seen through \p rec, as
    /// _init_fields does for a generic record. A field the payload lacks is
    /// _init_fields' SC040E; a field given twice, a field left out, braces on
    /// a variant without a payload and none on one with a payload are SC131E.
    priv fn _check_variant(self,
                           n:      unsafe *Expr,
                           en:     unsafe *EnumDecl,
                           idx:    usize,
                           rec:    unsafe *Type,
                           braces: bool,
                           fields: FrozenList<Expressions::InitField>) -> unsafe *Type {
        var unsafe *v = en->variants[idx]
        var nm = self.dyn()->tu.decl_name(en) + "::" + self.dyn()->tu.decl_name(
            v,
        )

        var np = v->payload.size()

        if np == 0 && braces {
            self._type_fields_unknown(fields)
            self.dyn()->sc->diag->report(
                DiagID::SC131E,
                n->range.start,
                f"'{nm}' carries no payload; write it without braces",
            ).first(n->range)->note(
                DiagCode(DiagID::SC131N),
                v->range.start,
                "declared here without a payload",
            )->emit()
            self.dyn()->poison_only(n)
            return &null
        }

        if np > 0 && !braces {
            self.dyn()->sc->diag->report(
                DiagID::SC131E,
                n->range.start,
                f"'{nm}' carries a payload; give its fields in braces after the name",
            ).first(n->range)->note(
                DiagCode(DiagID::SC131N),
                v->range.start,
                "declared here with its payload",
            )->emit()
            self.dyn()->poison_only(n)
            return &null
        }

        // A pack-expanded variant is one variant per element at a concrete
        // instance; which one is built is the payload's type (VariadicEnum).
        var ve  = VariadicEnum(self.dyn()->sc)
        var pes = cxx::std::vector<unsafe *Type>()
        if v->is_pack_expansion {
            var vn = self.dyn()->tu.decl_name(v)
            if rec == &null || !ve.elems(rec, unsafe &pes) {
                self._type_fields_unknown(fields)
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC116E,
                    n->range.start,
                    f"building pack-expanded variant '{nm}' at a type that depends on a generic parameter is not supported yet",
                )

                b.first(
                    n->range,
                    "which element this builds is known only per instance",
                )

                b.note(
                    DiagCode(DiagID::SC116N),
                    v->range.start,
                    "the variant is expanded over the pack here",
                )->child_first(v->range)
                b.emit()
                self.dyn()->poison_only(n)
                return &null
            }

            if pes.size() == 0 {
                self._type_fields_unknown(fields)
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC255E,
                    n->range.start,
                    f"'{self.dyn()->tu.str(rec)}' has no '{vn}' variant: its pack is empty",
                )

                b.first(n->range)
                b.note(v->range.start, "one variant per element of the pack")->child_first(
                    v->range,
                )

                b.emit()
                self.dyn()->poison_only(n)
                return &null
            }
        }

        // Per payload field: the initializer written for it.
        var given = cxx::std::vector<unsafe *Expressions::InitField>()
        for var k: usize = 0; k < np; ++k {
            given.push_back(&null)
        }

        var ok = true
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f          = fields.get(i)
            var        spelled     = self.dyn()->sc->ctx->get_spelling(f->name)
            var        k:      i32 = -1
            for var j: usize = 0; j < np; ++j {
                if self.dyn()->tu.decl_name(v->payload[j]) == spelled {
                    k = (j as i32)
                    break
                }
            }

            if k < 0 {
                self.dyn()->type_of(f->value, &null)
                self.dyn()->sc->diag->report(
                    DiagID::SC040E,
                    f->range.start,
                    f"'{nm}' has no field named '{spelled}'",
                ).first(f->range)->emit()
                ok = false
                continue
            }

            var uk = (k as usize)
            if given[uk] != &null {
                self.dyn()->type_of(f->value, &null)
                self.dyn()->sc->diag->report(
                    DiagID::SC131E,
                    f->range.start,
                    f"field '{spelled}' of '{nm}' is given twice",
                ).first(f->range)->note(
                    DiagCode(DiagID::SC131N),
                    given[uk]->range.start,
                    "first given here",
                )->emit()
                ok = false
                continue
            }

            given[uk] = f

            var unsafe *fd = v->payload[uk]
            // A field naming the pack is typed on its own; its type picks the
            // element, against which it is checked below.
            if v->is_pack_expansion && ve.is_pack_field(fd) {
                self.dyn()->type_of(f->value, &null)
                continue
            }

            var unsafe *ft = if (fd->type_ != &null) => (fd->type_->canonical) else => &null
            if ft != &null {
                ft = self.dyn()->ded_scratch()->member_through(rec, ft)
            }

            self.dyn()->push_null_target(f->value, fd->type_, fd)
            self.dyn()->type_of(f->value, ft)
            self.dyn()->pop_null_target()
            if self.dyn()->reject_slice_literal(f->value, "stored in a field") {
                ok = false
                continue
            }

            if ft != &null && self.dyn()->reject_array_copy(f->value, ft) {
                ok = false
                continue
            }

            // Either side dependent: the instance's question, as for a record.
            var unsafe *vt = f->value->type_
            if ft != &null && ft->is_dependent() {
                continue
            }

            if vt != &null && vt->is_dependent() {
                continue
            }

            if ft != &null && !self.dyn()->check_convertible(f->value, ft) {
                ok = false
            }
        }

        for var k: usize = 0; k < np; ++k {
            if given[k] != &null {
                continue
            }

            var unsafe *fd   = v->payload[k]
            var        fname = self.dyn()->tu.decl_name(fd)
            self.dyn()->sc->diag->report(
                DiagID::SC131E,
                n->range.start,
                f"'{nm}' is missing field '{fname}'",
            ).first(n->range)->note(
                DiagCode(DiagID::SC131N),
                fd->range.start,
                declared_here(),
            )->emit()
            ok = false
        }

        if !ok {
            self.dyn()->poison_only(n)
            return &null
        }

        var pick: i32 = -1
        if v->is_pack_expansion {
            pick = self._init_pick_element(n, v, rec, nm, given, &ve, pes)
            if pick < 0 {
                self.dyn()->poison_only(n)
                return &null
            }
        }

        // Only now, every field matched exactly once: a failed construction
        // carries no fact for a later pass to build from.
        for var k: usize = 0; k < np; ++k {
            given[k]->field_decl = unsafe (v->payload[k] as unsafe *Decl)
        }

        self._set_variant_decl(n, v)
        if isa<Expressions::NamedInitializerExpr>(n) {
            cast<Expressions::NamedInitializerExpr>(n)->variant_pack = pick
        }

        n->value_category = Expr::ValueCategory::RValue
        return rec
    }

    /// The element of pack-expanded \p v a construction builds: the one
    /// whose type every pack-typed field's value has exactly, else the one
    /// they all convert to; -1 after reporting none or several. Each value
    /// is then checked against the element picked.
    priv fn _init_pick_element(self,
                               n:           *Expr,
                               v:           unsafe *EnumVariantDecl,
                               rec:         unsafe *Type,
                               const nm:    string,
                               const given: cxx::std::vector<*Expressions::InitField>,
                               ve:          *VariadicEnum,
                               const pes:   cxx::std::vector<*Type>) -> i32 {
        var pick: i32 = -1
        var vals      = cxx::std::vector<unsafe *Expr>()
        for var k: usize = 0; k < v->payload.size(); ++k {
            if !ve->is_pack_field(v->payload[k]) {
                continue
            }

            var unsafe *e = (given)[k]->value
            if e->is_poisoned() {
                return -1
            }

            if e->type_ == &null {
                self.dyn()->sc->diag->report(
                    DiagID::SC256E,
                    e->range.start,
                    f"the type of this value decides which '{nm}' is built, and it is not known here",
                ).first(e->range)->emit()
                return -1
            }

            vals.push_back(e)
        }

        if vals.size() == 0 { // PackChecking: a pack-expanded payload names the pack.
            return if (pes.size() == 1) => (0) else => -1
        }

        // Exact: every value's own type is the one element.
        for var i: usize = 0; i < vals.size(); ++i {
            var k = ve->exact(rec, vals[i]->type_)
            if k < 0 || pick >= 0 && k != pick {
                pick = -1
                break
            }

            pick = k
        }

        // Else the one element every value converts to.
        if pick < 0 {
            var hits: usize = 0
            for var k: usize = 0; k < pes.size(); ++k {
                var all = true
                for var i: usize = 0; i < vals.size(); ++i {
                    if !self.dyn()->conv.convertible(vals[i]->type_, (pes)[k]) {
                        all = false
                        break
                    }
                }

                if all {
                    hits += 1
                    pick = (k as i32)
                }
            }

            if hits != 1 {
                var what = self.dyn()->tu.str(vals[0]->type_)
                var msg = if (hits == 0) => (f"no '{nm}' of '{self.dyn()->tu.str(rec)}' holds a '{what}'")
                          else => f"a '{what}' fits more than one '{nm}' of '{self.dyn()->tu.str(rec)}'; the payload's type must pick one"
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC256E,
                    vals[0]->range.start,
                    msg,
                )

                b.first(vals[0]->range, "the payload's type picks the variant")
                b.note(
                    v->range.start,
                    f"its variants here: {ve->describe(rec, v)}",
                )->child_first(v->range)

                b.emit()
                return -1
            }
        }

        for var i: usize = 0; i < vals.size(); ++i {
            if !self.dyn()->check_convertible(vals[i], (pes)[pick as usize]) {
                return -1
            }
        }

        return pick
    }

    /// The one writer of `variant_decl`, on whichever node the construction
    /// was written as.
    priv fn _set_variant_decl(self, n: unsafe *Expr, v: unsafe *Decl) {
        if isa<Expressions::NamedInitializerExpr>(n) {
            cast<Expressions::NamedInitializerExpr>(n)->variant_decl = v
            return
        }

        if isa<ChainExpr>(n) {
            cast<ChainExpr>(n)->variant_decl = v
            return
        }

        if isa<NamedIdentExpr>(n) {
            cast<NamedIdentExpr>(n)->variant_decl = v
            return
        }

        kairo::std::ice_fail(
            "ControlTyping: a variant construction written as neither an initializer nor a name",
        )
    }

    /// The position of the variant named \p name in \p en, or -1.
    priv fn _variant_index(self, en: *EnumDecl, const name: string) -> i32 {
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v != &null && self.dyn()->tu.decl_name(v) == name {
                return i as i32
            }
        }

        return -1
    }

    /// Every field value typed with nothing expected: the construction failed
    /// before its fields could be matched, and each value still needs a
    /// terminal state.
    priv fn _type_fields_unknown(self, fields: FrozenList<Expressions::InitField>) {
        for var i: usize = 0; i < fields.size(); ++i {
            self.dyn()->type_of(fields.get(i)->value, &null)
        }
    }

    /// # keyword expressions

    fn type_sizeof(self,
                   n:        unsafe *Expressions::SizeOfExpr,
                   expected: unsafe *Type) -> unsafe *Type {
        if n->type_arg != &null && n->type_arg->is_poisoned() {
            self.dyn()->poison_only(n)
            return &null
        }

        return self.dyn()->tu.builtin(BuiltinKind::USize)
    }

    fn type_alignof(self,
                    n:        unsafe *Expressions::AlignOfExpr,
                    expected: unsafe *Type) -> unsafe *Type {
        if n->type_arg != &null && n->type_arg->is_poisoned() {
            self.dyn()->poison_only(n)
            return &null
        }

        return self.dyn()->tu.builtin(BuiltinKind::USize)
    }

    /// `is_trivially_copyable!(T)` and its kin: a bool C++ computes (Compiler/Spec/Eval.md
    /// 4.2b); a dependent T is fine, the instance's C++ answers it.
    fn type_type_trait(self,
                       n:        unsafe *Expressions::TypeTraitExpr,
                       expected: unsafe *Type) -> unsafe *Type {
        if n->type_arg != &null && n->type_arg->is_poisoned() {
            self.dyn()->poison_only(n)
            return &null
        }

        return self.dyn()->tu.builtin(BuiltinKind::Bool)
    }

    /// `typeof x` in expression position yields a TypeInfo value; the docs
    /// route that through the reflection library. Until it exists the
    /// operand is typed, `resolved_type` is written, and the expression is
    /// a type-denoting head (usable as `typeof(x)::Foo` or a ctor).
    fn type_typeof(self,
                   n:        unsafe *Expressions::TypeOfExpr,
                   expected: unsafe *Type) -> unsafe *Type {
        var t = self.dyn()->type_of(n->operand, &null)
        if t == &null {
            // A type operand (`typeof T`, `typeof Foo`) has no value type by
            // design but denotes one: `typeof T` names T. Returning with no
            // note left the node in no terminal state, which finish() reports
            // as an internal error (`eval if typeof T == X`). Asked
            // before propagate: a bare primitive (`typeof u32`) is
            // "unknown" to N on purpose, yet names its builtin.
            var d = self.dyn()->denoted_type(n->operand)
            if d != &null {
                n->resolved_type = d
                self.dyn()->note_type_expr(n, d)
                return &null
            }
        }

        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        if t == &null {
            return &null
        }

        n->resolved_type = t
        self.dyn()->note_type_expr(n, t)
        return &null
    }

    fn type_eval(self, n: unsafe *Expressions::EvalExpr, expected: unsafe *Type) -> unsafe *Type {
        var t = self.dyn()->type_of(n->operand, expected)
        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        return t
    }

    fn type_unsafe(self,
                   n:        unsafe *Expressions::UnsafeExpr,
                   expected: unsafe *Type) -> unsafe *Type {
        self.dyn()->unsafe_depth += 1
        var t = self.dyn()->type_of(n->operand, expected)
        self.dyn()->unsafe_depth -= 1
        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        // `unsafe &x` is how a safe binding becomes a raw pointer (c-c++.md):
        // the address leaves AMT, so its type is `unsafe *T`, not the `*T`
        // plain `&x` makes. Without this a C `T *` parameter, which imports
        // as `unsafe *T`, could not be reached from a safe binding at all.
        var unsafe *u = dyn_cast<Expressions::UnaryOperatorExpr>(n->operand)
        if u != &null
            && u->is_prefix()
            && u->op_token.kind == TokenKind::OpAmp
            && t != &null
            && self.dyn()->tu.pointee(t) != &null
            && !self.dyn()->tu.is_unsafe_ptr(t) {
            return self.dyn()->sc->types->pointer(
                self.dyn()->tu.pointee(t),
                true,
            )
        }

        return t
    }

    /// `({ s0; s1; e })`: a prvalue of the last statement's expression.
    ///
    /// The leading statements go through the ordinary statement typer, in
    /// order, BEFORE the value: `e` may read a local whose type they infer.
    /// The value is typed here rather than by dispatching the whole block,
    /// because only this arm can hand it \p expected -- `var x: u8 = ({ 5 })`
    /// must type the literal as u8, and type_of is memoized, so a later
    /// dispatch could not correct it.
    ///
    /// Prvalue, like the GNU extension it emits as: a reference-typed value
    /// (an imported `T&` call) yields its referent, and top-level cv drops. A
    /// fixed array is rejected: it would be a copy out of the block, which
    /// Kairo does not do implicitly (see reject_array_copy).
    fn type_stmt_expr(self,
                      n:        unsafe *Expressions::StmtExpr,
                      expected: unsafe *Type) -> unsafe *Type {
        var unsafe *body = n->body
        var        count = if (body != &null) => (body->body.size()) else => 0
        // A `try` arm that leaves (`=> return v`, Compiler/Spec/Panic.md#try-and-arms): the jump is
        // typed as the statement it is, and the arm is `!`, so it fits beside
        // arms of any type and the flow after it is dead.
        if n->is_jump {
            for var i: usize = 0; i < count; ++i {
                self.dyn()->dispatch_stmt(body->body[i])
            }

            n->value_category = Expr::ValueCategory::RValue
            return self.dyn()->tu.builtin(BuiltinKind::Never)
        }

        // The parser guarantees a trailing ExpressionStmt for source forms and
        // SequenceLowering builds one; anything else is a malformed tree.
        var last_stmt: unsafe *Stmt = if (count > 0) => (body->body[count - 1]) else => &null
        if last_stmt == &null || !isa<ExpressionStmt>(last_stmt) {
            self.dyn()->fail(
                n,
                DiagID::SC089E,
                "statement expression has no trailing value expression",
            )

            return &null
        }

        for var i: usize = 0; i + 1 < count; ++i {
            self.dyn()->dispatch_stmt(body->body[i])
        }

        var unsafe *value = cast<ExpressionStmt>(last_stmt)->expr
        var        t      = self.dyn()->type_of(value, expected)
        if self.dyn()->propagate(n, value) {
            return &null
        }

        if t == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        if isa<CXXLValueRefType>(t) {
            t = cast<CXXLValueRefType>(t)->referee
        } else if isa<CXXRValueRefType>(t) {
            t = cast<CXXRValueRefType>(t)->referee
        }

        t = canon_unqual(t)

        if isa<FixedArrayType>(t) {
            self.dyn()->fail(
                n,
                DiagID::SC089E,
                f"a statement expression cannot yield an array ('{self.dyn()->tu.str(t)}'); an array is not copied implicitly",
            )

            return &null
        }

        n->value_category = Expr::ValueCategory::RValue
        return t
    }

    fn type_delete(self,
                   n:        unsafe *Expressions::DeleteExpr,
                   expected: unsafe *Type) -> unsafe *Type {
        var t = self.dyn()->type_of(n->operand, &null)
        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        // `delete v[i]` on a `vector<*T>`: the operand is an imported
        // `T*&`, read as its value (as_value), a pointer like any other.
        if t != &null
            && self.dyn()->tu.pointee(
                self.dyn()->tu.strip_nullable(self.dyn()->tu.as_value(t)),
            ) == &null {
            self.dyn()->fail(
                n,
                DiagID::SC090E,
                f"'delete' requires a pointer, not '{self.dyn()->tu.str(t)}'",
            )

            return &null
        }

        return self.dyn()->tu.builtin(BuiltinKind::Void)
    }

    /// `@cxx::new T(args)` / `@cxx::new [T; n]`: an `unsafe *T` (c-cpp-memory.mdx).
    /// The single form's `T(args)` is typed as any construction, so the
    /// constructor is the one `T(args)` would call; the array form's count is
    /// any integer, as C++'s `new T[n]` takes.
    fn type_cxx_new(self,
                    n:        unsafe *Expressions::CxxNewExpr,
                    expected: unsafe *Type) -> unsafe *Type {
        var elem: unsafe *Type = &null
        if n->is_array() {
            self.dyn()->type_of(n->elem_size, &null)
            if self.dyn()->propagate(n, n->elem_size) {
                return &null
            }

            var unsafe *et = n->elem_type()
            if et == &null || et->canonical == &null {
                self.dyn()->mark_unknown(n)
                return &null
            }

            elem = et->canonical
            var ct = self.dyn()->type_of(
                n->count,
                self.dyn()->tu.builtin(BuiltinKind::USize),
            )

            if self.dyn()->propagate(n, n->count) {
                return &null
            }

            if ct != &null && !self.dyn()->tu.is_integer(self.dyn()->tu.as_value(ct)) {
                self.dyn()->fail(
                    n,
                    DiagID::SC090E,
                    f"the count of '{LangAttrs::at(LangAttrs::cxx_mem())}::{LangAttrs::cxx_new()} [T; n]' is an integer, not '{self.dyn()->tu.str(ct)}'",
                )

                return &null
            }
        } else {
            var t = self.dyn()->type_of(n->init, &null)
            if self.dyn()->propagate(n, n->init) {
                return &null
            }

            if t == &null {
                self.dyn()->mark_unknown(n)
                return &null
            }

            elem = canon_unqual(self.dyn()->tu.as_value(t))
        }

        n->value_category = Expr::ValueCategory::RValue
        return self.dyn()->sc->types->pointer(elem, true)
    }

    fn type_constraint(self, n: unsafe *Expr, expected: unsafe *Type) -> unsafe *Type {
        // `T impl I` / `T derives B` in a requires clause: bool at compile time.
        // The operands are types (already T-resolved) or a lhs expr naming one.
        if isa<Expressions::ConstraintExpr>(n) {
            var unsafe *c = cast<Expressions::ConstraintExpr>(n)
            if c->lhs != &null {
                self.dyn()->type_of(c->lhs, &null)
            }
        }

        return self.dyn()->tu.builtin(BuiltinKind::Bool)
    }
}
