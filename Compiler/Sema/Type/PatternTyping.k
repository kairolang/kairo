/// --- The Kairo Project -------------------- Sema/Type/PatternTyping.k --- ///
///
///   \brief Typing a pattern against the column it matches: what each head
///          names, which field each payload subpattern destructures, and the
///          type of every binder.
///
///   \detail
///     This is X's half of patterns, and it has to be X's: an arm body is
///     typed right after its patterns, and `.Found(var key)` hands the body a
///     `key` whose type only the variant's payload knows. Coverage and dead
///     arms are PatternChecking's, after X, over what this writes.
///
///     Writes (one writer, this mixin):
///       Pattern::type_         the column type, on every pattern typed.
///       Pattern::resolved_decl what a constructor-shaped head names: an
///                              EnumVariantDecl, a StructDecl / ClassDecl
///                              (struct pattern), or a const / eval
///                              VariableDecl (`case MAX`).
///       Pattern::field_decl    on each subpattern of a variant or struct
///                              pattern, the field it destructures.
///       VariableDecl::type_    on every binder's decl.
///
///   \par Heads
///     `.V` resolves against the scrutinee's enum. Any other head was bound
///     by N like an ordinary name (a bare identifier is never a binder:
///     binders are written `var x` / `const x`), so here it is typed and its
///     declaration classified: variant, record type, or constant. Anything
///     else is an error that says how to write a binder.
///
///   \par Payload subpatterns: names first, then positions
///     A binder destructures the field of its own name. Any other subpattern
///     destructures the field at its position in the declaration:
///     `.Found(0..=9, var value)` tests `key` (field 0) and binds `value`.
///     A field reached twice -- `.Found(0..=9, var key)` -- is an error.
///     Fields left out are not tested.
///
///   \par Alternatives share binders
///     N gives every alternative of an arm the FIRST alternative's binder
///     decl for each name, so the body sees one `x`. The first alternative
///     to reach a decl types it; every later one must bind the same type and
///     the same mutability.
///
///   \par Range patterns
///     Integer or `char` columns only. Bounds must be constants: an integer
///     literal, a negated one, a `const` / `eval` name whose initializer is
///     one, or a character literal. An integer range that holds no value
///     (`5..=1`, `3..3`) is an error.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::DeclFacts::adt_pack_variant
import AST::Kind::PatternKind::PatternKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Type,
}
import AST::Node::CanonicalNodes::{
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
    ClassDecl,    EnumDecl, EnumVariantDecl, FieldDecl, IntConst, StructDecl, TypeAliasDecl,
    VariableDecl,
}
import AST::Node::Expressions::BinaryOperatorExpr
import AST::Node::Patterns::{
    AlternationPattern,
    BindingPattern,
    ConstructorPattern,
    LiteralPattern,
    RangePattern,
    SlicePattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    CharacterLiteralExpr,
    NamedIdentExpr,
}
import Diagnostic::Registry::DiagID
import Sema::Check::PatternSpace::PatternSpace
import Sema::Type::VariadicEnum::VariadicEnum
import Token::Token::Token
import Token::TokenKind::TokenKind

// TODO(DUCK-GENERIC): T uses check_convertible, conv, ded_scratch, denoted_type, finish, sc, tu, type_head, type_of. Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> PatternTyping {
    @move
    fn PatternTyping(self, other: Self) = default
    fn PatternTyping(self) = default
    /// Binder decls already typed by an earlier alternative, by address.
    priv var _binder_seen: llvm::DenseSet<u64>

    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// # entry

    fn type_pattern(self, p: unsafe *Pattern, scrutinee: unsafe *Type) {
        if p == &null {
            return
        }

        if p->is_poisoned() {
            return
        }

        var unsafe *st = self._column(scrutinee)
        if st != &null && p->type_ == &null {
            p->type_ = st
        }

        // A value of a bounds-checked parameter (Compiler/Spec/Generics.md#decisions) has no
        // variants, no fields and no values a literal could equal; nothing
        // in a bound declares them. It can be bound, guarded, or ignored.
        if st != &null
            && p->kind != PatternKind::WildcardPattern
            && p->kind != PatternKind::BindingPattern
            && p->kind != PatternKind::AlternationPattern
            && p->kind != PatternKind::RecoveryPattern {
            var cg = self.dyn()->tu.checked_head(st)
            if cg != &null {
                var pname = self.dyn()->tu.head_spelling(st)
                var what = if (isa<TypeAliasDecl>(cg)) => ("an associated type")
                           else => "a generic parameter"
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC257E,
                    p->range.start,
                    f"a value of type '{pname}' can only be matched by a binding, '_' or 'default' (with a 'where' guard)",
                )

                b.first(p->range)
                b.note(
                    cg->range.start,
                    f"'{pname}' is {what}: no bound gives it variants, fields or values a pattern could test",
                )

                b.emit()
                p->poison()
                return
            }
        }

        match p->kind {
            case PatternKind::BindingPattern {
                self._type_binder(cast<BindingPattern>(p), st)
            } case PatternKind::LiteralPattern {
                var unsafe *l = cast<LiteralPattern>(p)
                if l->value != &null {
                    self.dyn()->type_of(l->value, st)
                    if st != &null {
                        self.dyn()->check_convertible(l->value, st)
                    }

                    if l->value->is_poisoned() {
                        p->poison()
                    }

                    self._type_eq_test(p, l->value, st)
                }
            } case PatternKind::RangePattern {
                self._type_range(cast<RangePattern>(p), st)
            } case PatternKind::TupleDestructurePattern {
                var unsafe *tp   = cast<TupleDestructurePattern>(p)
                var        have  = st != &null && self.dyn()->tu.is_tuple(st)
                var        elems = self.dyn()->tu.tuple_elems(st)
                if st != &null && !have && !st->is_dependent() {
                    self.dyn()->sc->diag->report(
                        DiagID::SC041E,
                        p->range.start,
                        f"a tuple pattern cannot match a value of type '{self.dyn()->tu.str(st)}'",
                    ).first(p->range)->emit()
                    p->poison()
                }

                if have && elems.size() != tp->elements.size() {
                    self.dyn()->sc->diag->report(
                        DiagID::SC042E,
                        p->range.start,
                        f"tuple pattern has {tp->elements.size()} element(s) but '{self.dyn()->tu.str(st)}' has {elems.size()}",
                    ).first(p->range)->emit()
                    p->poison()
                    have = false
                }

                for var i: usize = 0; i < tp->elements.size(); ++i {
                    self.type_pattern(tp->elements[i], if (have) => (elems[i]) else => &null)
                }
            } case PatternKind::AlternationPattern {
                var unsafe *a = cast<AlternationPattern>(p)
                for var i: usize = 0; i < a->alternatives.size(); ++i {
                    self.type_pattern(a->alternatives[i], st)
                }
            } case PatternKind::SlicePattern {
                var unsafe *s   = cast<SlicePattern>(p)
                var        elem = self.dyn()->tu.container_elem(st)
                for var i: usize = 0; i < s->prefix.size(); ++i {
                    self.type_pattern(s->prefix[i], elem)
                }

                for var i: usize = 0; i < s->suffix.size(); ++i {
                    self.type_pattern(s->suffix[i], elem)
                }

                if s->rest_binding != &null {
                    self.type_pattern(s->rest_binding, st)
                }
            } case PatternKind::ConstructorPattern {
                var unsafe *c = cast<ConstructorPattern>(p)
                self._type_ctor(
                    p,
                    c->head,
                    c->is_dotted,
                    c->dotted_name,
                    c->has_parens,
                    c->subpatterns,
                    st,
                )
            } case PatternKind::UnresolvedConstructorPattern {
                var unsafe *c = cast<UnresolvedConstructorPattern>(p)
                self._type_ctor(p, c->head, false, Token(), c->has_parens, c->subpatterns, st)
            } default {
                0
            }
        }
    }

    /// # equality tests

    /// A literal or constant head on a record column (struct, class, enum)
    /// tests `<column> == <value>`, and on a record that `==` is a user
    /// operator. Typed here exactly as the expression would be, so the
    /// `op ==` the test calls is picked by the same rules (overloads, a free
    /// operator, `==` derived from `op <=>`) and a type with none is SC066E
    /// at the pattern, never a silently dropped arm. Recorded in
    /// SemaContext::pattern_eqs for MatchLowering, which renders the call
    /// after OperatorLowering has run. The lhs is a stand-in typed as the
    /// column; nothing emits it.
    ///
    /// An ADT that declares no `op ==` compares by variant only: `case K`
    /// would take every value of K's variant whatever its payload, so it is
    /// refused rather than widened.
    priv fn _type_eq_test(self, p: unsafe *Pattern, value: unsafe *Expr, st: unsafe *Type) {
        if p->is_poisoned()
            || value == &null
            || value->is_poisoned()
            || st == &null
            || st->is_dependent() {
            return
        }

        var unsafe *u = canon_unqual(self.dyn()->tu.as_value(st))
        if u == &null || !isa<RecordType>(u) || self.dyn()->tu.is_string(u) {
            return
        }

        var unsafe *sc = self.dyn()->sc
        var unsafe *col = NamedIdentExpr::create(
            sc->ctx,
            p->range,
            sc->ctx->make_token(p->range, TokenKind::LitIdentifier, "$"),
        )

        col->type_          = u
        col->value_category = Expr::ValueCategory::LValue
        self.dyn()->finish(col, u)
        var unsafe *eq = BinaryOperatorExpr::create(
            sc->ctx,
            p->range,
            col,
            value,
            sc->ctx->make_token(p->range, TokenKind::OpEqualEqual, "=="),
        )

        self.dyn()->type_of(eq, &null)
        if eq->is_poisoned() {
            p->poison()
            return
        }

        if eq->tag_eq {
            var nm = self.dyn()->tu.str(u)
            var b = sc->diag->report(
                DiagID::SC066E,
                p->range.start,
                f"no 'op ==' on '{nm}'; a constant pattern compares through the enum's own operator, and comparing variants alone would ignore the payload",
            )

            b.first(p->range)
            var unsafe *rd = self.dyn()->tu.record_decl(u)
            if rd != &null {
                b.note(
                    rd->range.start,
                    f"'{nm}' declares no 'op =='; declare one, or match the variant with a pattern ('.Variant(...)')",
                )
            }

            b.emit()
            p->poison()
            return
        }

        sc->pattern_eqs[(p as usize as u64)] = eq
    }

    /// The column type: the value's type, references and top-level cv gone.
    priv fn _column(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        return canon_unqual(self.dyn()->tu.as_value(t))
    }

    /// # binders

    priv fn _type_binder(self, b: unsafe *BindingPattern, st: unsafe *Type) {
        var unsafe *vd = dyn_cast<VariableDecl>(b->decl)
        if vd == &null {
            return
        }

        var unsafe *t = st
        if b->type_ != &null && b->type_->canonical != &null {
            t = canon_unqual(b->type_->canonical)
            if st != &null && !self.dyn()->conv.convertible(st, b->type_->canonical) {
                self.dyn()->sc->diag->report(
                    DiagID::SC041E,
                    b->range.start,
                    f"pattern type '{self.dyn()->tu.str(b->type_->canonical)}' does not match the scrutinee type '{self.dyn()->tu.str(st)}'",
                ).first(b->range)->emit()
                b->poison()
                return
            }
        }

        if t == &null {
            return
        }

        var key = (vd as usize as u64)
        if self._binder_seen.insert(key).second {
            vd->type_ = t
            return
        }

        // A later alternative reaching the first alternative's decl.
        var nm = self.dyn()->sc->ctx->get_spelling(b->name)
        if b->is_const != vd->is_const() {
            var first = if (vd->is_const()) => ("const") else => "var"
            var here  = if (b->is_const) => ("const") else => "var"
            self.dyn()->sc->diag->report(
                DiagID::SC125E,
                b->range.start,
                f"'{nm}' is bound with '{here}' here but with '{first}' in an earlier alternative",
            ).first(b->range)->note(
                vd->range.start,
                "every alternative must bind a name with the same mutability",
            )->emit()
            b->poison()
            return
        }

        if vd->type_ != &null && canon_unqual(vd->type_) != canon_unqual(t) {
            self.dyn()->sc->diag->report(
                DiagID::SC125E,
                b->range.start,
                f"'{nm}' has type '{self.dyn()->tu.str(t)}' here but '{self.dyn()->tu.str(vd->type_)}' in an earlier alternative",
            ).first(b->range)->note(
                vd->range.start,
                "every alternative must bind a name with the same type",
            )->emit()
            b->poison()
        }
    }

    /// # ranges

    priv fn _type_range(self, r: unsafe *RangePattern, st: unsafe *Type) {
        var unsafe *p      = unsafe (r as unsafe *Pattern)
        var        is_char = st != &null && self.dyn()->tu.is_builtin(st, BuiltinKind::Char)
        if st != &null && !st->is_dependent() && !self.dyn()->tu.is_integer(st) && !is_char {
            self.dyn()->sc->diag->report(
                DiagID::SC126E,
                r->range.start,
                f"a range pattern needs an integer or 'char' value, not '{self.dyn()->tu.str(st)}'",
            ).first(r->range)->emit()
            p->poison()
            return
        }

        if r->lo != &null {
            self.dyn()->type_of(r->lo, st)
            if st != &null {
                self.dyn()->check_convertible(r->lo, st)
            }

            if r->lo->is_poisoned() {
                p->poison()
                return
            }
        }

        if r->hi != &null {
            self.dyn()->type_of(r->hi, st)
            if st != &null {
                self.dyn()->check_convertible(r->hi, st)
            }

            if r->hi->is_poisoned() {
                p->poison()
                return
            }
        }

        if st == &null {
            return
        }

        var ps = PatternSpace(self.dyn()->sc)
        var ok = true
        ok = self._const_bound(&ps, r->lo, is_char) && ok
        ok = self._const_bound(&ps, r->hi, is_char) && ok
        if !ok {
            p->poison()
            return
        }

        if is_char {
            return
        }

        // Empty: compare as signed values (sign-magnitude).
        if r->lo == &null || r->hi == &null {
            return
        }

        var lo = ps.eval_int(r->lo)
        var hi = ps.eval_int(r->hi)
        var c  = self._cmp(lo, hi)
        if c > 0 || c == 0 && !r->is_inclusive {
            self.dyn()->sc->diag->report(
                DiagID::SC126E,
                r->range.start,
                "this range pattern matches no value",
            ).first(r->range)->note(
                r->range.start,
                if (c > 0) => ("its lower bound is above its upper bound")
                else => "'..' excludes its upper bound, so 'a..a' is empty; write 'a' or 'a..=a'",
            )->emit()
            p->poison()
        }
    }

    priv fn _const_bound(self, ps: *PatternSpace, e: unsafe *Expr, is_char: bool) -> bool {
        if e == &null {
            return true
        }

        if is_char && isa<CharacterLiteralExpr>(self.dyn()->tu.strip_parens(e)) {
            return true
        }

        if ps->eval_int(e).ok {
            return true
        }

        self.dyn()->sc->diag->report(
            DiagID::SC126E,
            e->range.start,
            "a range pattern bound must be a constant: a literal, or a 'const' / 'eval' name",
        ).first(e->range)->emit()
        return false
    }

    /// -1 / 0 / 1 for a < b / a == b / a > b.
    priv fn _cmp(self, a: IntConst, b: IntConst) -> i32 {
        if a.neg && !b.neg {
            return -1
        }

        if !a.neg && b.neg {
            return 1
        }

        if a.mag == b.mag {
            return 0
        }

        var less = a.mag < b.mag
        if a.neg {
            less = !less
        }

        return if (less) => (-1) else => 1
    }

    /// # constructor heads

    priv fn _type_ctor(self,
                       p:          unsafe *Pattern,
                       head:       unsafe *Expr,
                       is_dotted:  bool,
                       dotted:     Token,
                       has_parens: bool,
                       subs:       FrozenList<unsafe *Pattern>,
                       st:         unsafe *Type) {
        var ps = PatternSpace(self.dyn()->sc)

        // Unknown or dependent column: nothing to resolve against. Binders
        // still get typed (as unknown) so the body has decls to bind to.
        // A generic ADT's instance at dependent arguments is the exception:
        // its variants are its pattern's, known here, and a payload field's
        // type reads through the instance (`v: T` of `Rep<T>`), so the
        // pattern resolves like any other (Compiler/Spec/Generics.md#body-regimes).
        if st == &null || st->is_dependent() && !self.dependent_adt(st) {
            if head != &null {
                self.dyn()->type_head(head)
            }

            // A constant needs no domain: it is an `==` test like a literal
            // on this column, and the instance's C++ picks the operator.
            // Unresolved, the match had no decision tree and reached EmitIR
            // as an ICE.
            if st != &null && !is_dotted && !has_parens && subs.size() == 0 {
                var unsafe *vd = dyn_cast<VariableDecl>(self._head_decl(head))
                if vd != &null && (vd->is_const() || vd->is_eval()) {
                    p->resolved_decl = unsafe (vd as unsafe *Decl)
                    return
                }
            }

            self._type_subs_unknown(subs)
            // A variadic enum's constructors are per instance: which tag a
            // pattern tests is unknown in a generic body (M2).
            var unsafe *den = if (st != &null) => (self._enum_of(st)) else => &null
            var unsafe *pv = if (den != &null && den->is_adt) => (adt_pack_variant(den))
                             else => &null
            var hits = false
            if pv != &null {
                if is_dotted {
                    hits = self.dyn()->sc->ctx->get_spelling(dotted) == self.dyn()->tu.decl_name(pv)
                } else {
                    hits = self._head_decl(head) == pv
                }
            }

            if hits {
                self.dyn()->sc->diag->report(
                    DiagID::SC116E,
                    p->range.start,
                    f"matching pack-expanded variant '{self.dyn()->tu.decl_name((unsafe (pv as unsafe *Decl)))}' at a type that depends on a generic parameter is not supported yet",
                ).first(p->range)->emit()
                p->poison()
            }

            return
        }

        var rd:   unsafe *Decl = &null
        var owner              = ""

        if is_dotted {
            var        nm  = self.dyn()->sc->ctx->get_spelling(dotted)
            var unsafe *en = self._enum_of(st)
            if en == &null {
                self.dyn()->sc->diag->report(
                    DiagID::SC123E,
                    p->range.start,
                    f"'.{nm}' names an enum variant, but the matched value is '{self.dyn()->tu.str(st)}', not an enum",
                ).first(p->range)->emit()
                p->poison()
                self._type_subs_unknown(subs)
                return
            }

            for var i: usize = 0; i < en->variants.size(); ++i {
                var unsafe *v = en->variants[i]
                if v != &null && self.dyn()->tu.decl_name(v) == nm {
                    rd = unsafe (v as unsafe *Decl)
                    break
                }
            }

            if rd == &null {
                self.dyn()->sc->diag->report(
                    DiagID::SC123E,
                    p->range.start,
                    f"'{self.dyn()->tu.str(st)}' has no variant named '{nm}'",
                ).first(p->range)->emit()
                p->poison()
                self._type_subs_unknown(subs)
                return
            }

            owner = nm
        } else {
            if head == &null {
                p->poison()
                return
            }

            self.dyn()->type_head(head) // the variant a head names is matched, not built.
            if head->is_poisoned() {
                p->poison()
                self._type_subs_unknown(subs)
                return
            }

            var den = self.dyn()->denoted_type(head)
            if den != &null {
                // `Response(...)`: a struct pattern over the scrutinee's record.
                var hd = self.dyn()->tu.record_decl(den)
                var sd = self.dyn()->tu.record_decl(st)
                var hp = if (hd != &null) => (self.dyn()->tu.pattern_of(hd)) else => &null
                var sp = if (sd != &null) => (self.dyn()->tu.pattern_of(sd)) else => &null
                if hp == &null || (!isa<StructDecl>(hp)) && !isa<ClassDecl>(hp) {
                    var what = if (hp != &null
                                   && isa<EnumDecl>(hp)) => ("an enum; name one of its variants")
                               else => "not a struct or class"
                    self.dyn()->sc->diag->report(
                        DiagID::SC123E,
                        head->range.start,
                        f"'{self.dyn()->tu.str(den)}' is {what}",
                    ).first(head->range)->emit()
                    p->poison()
                    self._type_subs_unknown(subs)
                    return
                }

                if hp != sp {
                    self.dyn()->sc->diag->report(
                        DiagID::SC123E,
                        head->range.start,
                        f"this pattern matches '{self.dyn()->tu.str(den)}', but the matched value is '{self.dyn()->tu.str(st)}'",
                    ).first(head->range)->emit()
                    p->poison()
                    self._type_subs_unknown(subs)
                    return
                }

                rd    = hp
                owner = self.dyn()->tu.decl_name(hp)
            } else {
                var unsafe *d  = self._head_decl(head)
                var        nm  = self._head_spelling(head)
                var unsafe *v  = dyn_cast<EnumVariantDecl>(d)
                var unsafe *vd = dyn_cast<VariableDecl>(d)
                if v != &null {
                    var unsafe *en = self._enum_of(st)
                    if en == &null || ps.variant_index(en, v) < 0 {
                        self.dyn()->sc->diag->report(
                            DiagID::SC123E,
                            head->range.start,
                            f"'{nm}' is a variant of another enum; the matched value is '{self.dyn()->tu.str(st)}'",
                        ).first(head->range)->emit()
                        p->poison()
                        self._type_subs_unknown(subs)
                        return
                    }

                    rd    = unsafe (v as unsafe *Decl)
                    owner = nm
                } else if vd != &null && (vd->is_const() || vd->is_eval()) {
                    if has_parens || subs.size() > 0 {
                        self.dyn()->sc->diag->report(
                            DiagID::SC124E,
                            head->range.start,
                            f"'{nm}' is a constant; it takes no payload",
                        ).first(p->range)->emit()
                        p->poison()
                        return
                    }

                    self.dyn()->type_of(head, st)
                    if !self.dyn()->check_convertible(head, st) {
                        p->poison()
                        return
                    }

                    p->resolved_decl = d
                    self._type_eq_test(p, head, st)
                    return
                } else {
                    self.dyn()->sc->diag->report(
                        DiagID::SC123E,
                        head->range.start,
                        f"'{nm}' is not a variant, a constant or a type, so it cannot be matched against; to bind the value to a new name, write 'var {nm}'",
                    ).first(head->range)->emit()
                    p->poison()
                    self._type_subs_unknown(subs)
                    return
                }
            }
        }

        p->resolved_decl = rd
        self._map_payload(p, rd, owner, has_parens, subs, st, unsafe &ps)
    }

    /// Names first, then positions; see the file header.
    priv fn _map_payload(self,
                         p:           unsafe *Pattern,
                         rd:          unsafe *Decl,
                         const owner: string,
                         has_parens:  bool,
                         subs:        FrozenList<unsafe *Pattern>,
                         st:          unsafe *Type,
                         ps:          unsafe *PatternSpace) {
        var        fields = ps->fields_of_resolved(rd)
        var unsafe *v     = dyn_cast<EnumVariantDecl>(rd)
        if v != &null && fields.size() == 0 && subs.size() > 0 {
            self.dyn()->sc->diag->report(
                DiagID::SC124E,
                p->range.start,
                f"'{owner}' carries no payload",
            ).first(p->range)->emit()
            p->poison()
            self._type_subs_unknown(subs)
            return
        }

        // A pack-expanded variant: which element this pattern matches is its
        // payload's type, written on a binder of the pack field.
        var ve        = VariadicEnum(self.dyn()->sc)
        var pick: i32 = -1
        var pes       = cxx::std::vector<unsafe *Type>()
        if v != &null && v->is_pack_expansion {
            pick = self._pat_pick_element(p, v, owner, subs, st, &ve, unsafe &pes)
            if pick < 0 {
                p->poison()
                self._type_subs_unknown(subs)
                return
            }

            p->pack_index = pick
        }

        var used = cxx::std::vector<u8>()
        for var k: usize = 0; k < fields.size(); ++k {
            used.push_back(0)
        }

        for var i: usize = 0; i < subs.size(); ++i {
            var unsafe *sp = subs[i]
            if sp == &null {
                continue
            }

            var idx: i32 = -1
            if sp->kind == PatternKind::BindingPattern {
                var unsafe *bp  = cast<BindingPattern>(sp)
                var        want = self.dyn()->sc->ctx->get_spelling(bp->name)
                for var k: usize = 0; k < fields.size(); ++k {
                    if self.dyn()->tu.decl_name(fields[k]) == want {
                        idx = (k as i32)
                        break
                    }
                }

                if idx < 0 {
                    self.dyn()->sc->diag->report(
                        DiagID::SC124E,
                        sp->range.start,
                        f"'{owner}' has no field named '{self.dyn()->sc->ctx->get_spelling(bp->name)}'; a binder takes the field of its own name",
                    ).first(sp->range)->emit()
                    sp->poison()
                    p->poison()
                    continue
                }
            } else {
                if i >= fields.size() {
                    self.dyn()->sc->diag->report(
                        DiagID::SC124E,
                        sp->range.start,
                        f"'{owner}' has {fields.size()} field(s); this is subpattern {i + 1}",
                    ).first(sp->range)->emit()
                    sp->poison()
                    p->poison()
                    continue
                }

                idx = (i as i32)
            }

            var unsafe *fd = fields[idx as usize]
            if used[idx as usize] != 0 {
                self.dyn()->sc->diag->report(
                    DiagID::SC124E,
                    sp->range.start,
                    f"field '{self.dyn()->tu.decl_name((unsafe (fd as unsafe *Decl)))}' of '{owner}' is matched twice",
                ).first(sp->range)->note(
                    sp->range.start,
                    "a binder takes the field of its own name; any other subpattern takes the field at its position",
                )->emit()
                sp->poison()
                p->poison()
                continue
            }

            used[idx as usize] = 1
            sp->field_decl     = unsafe (fd as unsafe *Decl)

            var ft: unsafe *Type = &null
            if pick >= 0 {
                ft = ve.field_at(st, fd, pick as usize)
            } else if fd->type_ != &null && fd->type_->canonical != &null {
                ft = self.dyn()->ded_scratch()->member_through(st, fd->type_->canonical)
            }

            self.type_pattern(sp, ft)
        }
    }

    /// The element of pack-expanded \p v a pattern matches at \p st: the one
    /// a binder of a pack field names as its type (`.Err(var e: f64)`), or
    /// the only one; -1 after reporting why there is none.
    priv fn _pat_pick_element(self,
                              p:           unsafe *Pattern,
                              v:           unsafe *EnumVariantDecl,
                              const owner: string,
                              subs:        FrozenList<unsafe *Pattern>,
                              st:          unsafe *Type,
                              ve:          *VariadicEnum,
                              pes:         unsafe *cxx::std::vector<unsafe *Type>) -> i32 {
        var stn = self.dyn()->tu.str(st)
        if !ve->elems(st, pes) {
            self.dyn()->sc->diag->report(
                DiagID::SC116E,
                p->range.start,
                f"matching pack-expanded variant '{owner}' at a type that depends on a generic parameter is not supported yet",
            ).first(p->range)->emit()
            return -1
        }

        if pes->size() == 0 {
            var b = self.dyn()->sc->diag->report(
                DiagID::SC255E,
                p->range.start,
                f"'{stn}' has no '{owner}' variant: its pack is empty",
            )

            b.first(p->range)
            b.note(v->range.start, "one variant per element of the pack")->child_first(v->range)
            b.emit()
            return -1
        }

        var pick:  i32                    = -1
        var named: unsafe *BindingPattern = &null // a binder of a pack field, typed or not.
        for var i: usize = 0; i < subs.size(); ++i {
            var unsafe *bp = dyn_cast<BindingPattern>(subs[i])
            if bp == &null {
                continue
            }

            var want                   = self.dyn()->sc->ctx->get_spelling(bp->name)
            var fd:  unsafe *FieldDecl = &null
            for var k: usize = 0; k < v->payload.size(); ++k {
                if self.dyn()->tu.decl_name(v->payload[k]) == want {
                    fd = v->payload[k]
                    break
                }
            }

            if fd == &null || !ve->is_pack_field(fd) {
                continue
            }

            if named == &null {
                named = bp
            }

            if bp->type_ == &null || bp->type_->canonical == &null {
                continue
            }

            var k = ve->exact(st, bp->type_->canonical)
            if k < 0 {
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC256E,
                    bp->type_->range.start,
                    f"no '{owner}' of '{stn}' holds a '{self.dyn()->tu.str(bp->type_->canonical)}'",
                )

                b.first(bp->type_->range, "the payload's type picks the variant")
                b.note(v->range.start, f"its variants here: {ve->describe(st, v)}")->child_first(v->range)
                b.emit()
                return -1
            }

            if pick >= 0 && k != pick {
                self.dyn()->sc->diag->report(
                    DiagID::SC256E,
                    bp->type_->range.start,
                    f"these binders name two different '{owner}' variants of '{stn}'",
                ).first(bp->type_->range)->emit()
                return -1
            }

            pick = k
        }

        if pick >= 0 {
            return pick
        }

        if pes->size() == 1 {
            return 0
        }

        var b = self.dyn()->sc->diag->report(
            DiagID::SC256E,
            p->range.start,
            f"'{owner}' is one variant per element of a pack in '{stn}'; name the payload's type to pick one",
        )

        b.first(p->range, "matches which?")
        if named != &null {
            b.insert(
                named->range.end,
                ": " + self.dyn()->tu.str((*pes)[0]),
                "name the payload type",
            )
        }

        b.note(v->range.start, f"its variants here: {ve->describe(st, v)}")->child_first(v->range)
        b.emit()
        return -1
    }

    priv fn _type_subs_unknown(self, subs: FrozenList<unsafe *Pattern>) {
        for var i: usize = 0; i < subs.size(); ++i {
            self.type_pattern(subs[i], &null)
        }
    }

    /// The enum a column ranges over, or null. ControlTyping reads the enum
    /// of a variant construction's type through it too.
    /// \p st is an instance of a Kairo generic ADT at dependent arguments
    /// whose variants are one list for every instance (no pack-expanded
    /// variant): a match on it is typed, checked and compiled at the
    /// definition, and C++ picks the layout (EnumLayoutQuery's Opaque).
    fn dependent_adt(self, st: unsafe *Type) -> bool {
        var unsafe *en = self._enum_of(st)
        if en == &null || !en->is_adt || en->is_imported() {
            return false
        }

        return adt_pack_variant(en) == &null
    }

    fn _enum_of(self, st: unsafe *Type) -> unsafe *EnumDecl {
        var rd = self.dyn()->tu.record_decl(st)
        if rd == &null {
            return &null
        }

        return dyn_cast<EnumDecl>(self.dyn()->tu.pattern_of(rd))
    }

    /// The declaration a typed head names: an ident's binding, or a path's
    /// last step. ControlTyping classifies an initializer's head with it.
    fn _head_decl(self, e: unsafe *Expr) -> unsafe *Decl {
        if e == &null {
            return &null
        }

        if isa<NamedIdentExpr>(e) {
            return cast<NamedIdentExpr>(e)->resolved_decl
        }

        if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            if ch->steps.size() == 0 {
                return self._head_decl(ch->base)
            }

            return ch->steps.get(ch->steps.size() - 1)->resolved_decl
        }

        return &null
    }

    priv fn _head_spelling(self, e: unsafe *Expr) -> string {
        if e == &null {
            return "?"
        }

        return self.dyn()->sc->ctx->get_spelling(e->range)
    }
}
