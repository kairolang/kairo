/// --- The Kairo Project ---------------------- Sema/Type/PatternTyping.k --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h";
import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::VariadicEnum::*;
import Sema::Check::PatternSpace::*;
import AST::Context::ASTContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Patterns::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::PatternKind::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class <T> PatternTyping {
    /// Binder decls already typed by an earlier alternative, by address.
    priv var _binder_seen: llvm::DenseSet::<u64>;

    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === entry ==============================================================

    fn type_pattern(self, p: *Pattern, scrutinee: *Type) {
        if p == &null { return; }
        if p->is_poisoned() { return; }
        var st = self._column(scrutinee);
        if (st != &null) && (p->type_ == &null) { p->type_ = st; }

        // A value of a bounds-checked parameter (MONO.md D0) has no
        // variants, no fields and no values a literal could equal; nothing
        // in a bound declares them. It can be bound, guarded, or ignored.
        if (st != &null) && (p->kind != PatternKind::WildcardPattern) && (p->kind != PatternKind::BindingPattern)
        && (p->kind != PatternKind::AlternationPattern) && (p->kind != PatternKind::RecoveryPattern) {
            var cg = dyn()->tu.checked_param(st);
            if cg != &null {
                var pname = dyn()->sc->ctx->get_spelling(cg->name);
                var b = dyn()->sc->diag->report(DiagID::SC001E, p->range.start,
                    f"a value of type '{pname}' can only be matched by a binding, '_' or 'default' (with a 'where' guard)");
                b.first(p->range);
                b.note(cg->range.start, f"'{pname}' is a generic parameter: no bound gives it variants, fields or values a pattern could test");
                b.emit();
                p->poison();
                return;
            }
        }

        switch p->kind {
            case PatternKind::BindingPattern {
                self._type_binder(cast::<BindingPattern>(p), st);
            }
            case PatternKind::LiteralPattern {
                var l = cast::<LiteralPattern>(p);
                if l->value != &null {
                    dyn()->type_of(l->value, st);
                    if st != &null { dyn()->check_convertible(l->value, st); }
                    if l->value->is_poisoned() { p->poison(); }
                }
            }
            case PatternKind::RangePattern {
                self._type_range(cast::<RangePattern>(p), st);
            }
            case PatternKind::TupleDestructurePattern {
                var tp = cast::<TupleDestructurePattern>(p);
                var have  = (st != &null) && dyn()->tu.is_tuple(st);
                var elems = dyn()->tu.tuple_elems(st);
                if (st != &null) && (!have) && (!st->is_dependent()) {
                    dyn()->sc->diag->report(DiagID::SC041E, p->range.start,
                        f"a tuple pattern cannot match a value of type '{dyn()->tu.str(st)}\x27"
                    ).first(p->range).emit();
                    p->poison();
                }
                if have && (elems.size() != tp->elements.size()) {
                    dyn()->sc->diag->report(DiagID::SC042E, p->range.start,
                        f"tuple pattern has {tp->elements.size()} element(s) but '{dyn()->tu.str(st)}' has {elems.size()}"
                    ).first(p->range).emit();
                    p->poison();
                    have = false;
                }
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    self.type_pattern(tp->elements[i], (elems[i]) if (have) else (&null));
                }
            }
            case PatternKind::AlternationPattern {
                var a = cast::<AlternationPattern>(p);
                for var i: usize = 0; i < a->alternatives.size(); ++i { self.type_pattern(a->alternatives[i], st); }
            }
            case PatternKind::SlicePattern {
                var s = cast::<SlicePattern>(p);
                var elem = dyn()->tu.container_elem(st);
                for var i: usize = 0; i < s->prefix.size(); ++i { self.type_pattern(s->prefix[i], elem); }
                for var i: usize = 0; i < s->suffix.size(); ++i { self.type_pattern(s->suffix[i], elem); }
                if s->rest_binding != &null { self.type_pattern(s->rest_binding, st); }
            }
            case PatternKind::ConstructorPattern {
                var c = cast::<ConstructorPattern>(p);
                self._type_ctor(p, c->head, c->is_dotted, c->dotted_name, c->has_parens, c->subpatterns, st);
            }
            case PatternKind::UnresolvedConstructorPattern {
                var c = cast::<UnresolvedConstructorPattern>(p);
                self._type_ctor(p, c->head, false, Token(), c->has_parens, c->subpatterns, st);
            }
            default { 0; }
        }
    }

    /// The column type: the value's type, references and top-level cv gone.
    priv fn _column(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        return canon_unqual(dyn()->tu.as_value(t));
    }

    // === binders ============================================================

    priv fn _type_binder(self, b: *BindingPattern, st: *Type) {
        var vd = dyn_cast::<VariableDecl>(b->decl);
        if vd == &null { return; }

        var t = st;
        if (b->type_ != &null) && (b->type_->canonical != &null) {
            t = canon_unqual(b->type_->canonical);
            if (st != &null) && (!dyn()->conv.convertible(st, b->type_->canonical)) {
                dyn()->sc->diag->report(DiagID::SC041E, b->range.start,
                    f"pattern type '{dyn()->tu.str(b->type_->canonical)}' does not match the scrutinee type '{dyn()->tu.str(st)}\x27"
                ).first(b->range).emit();
                b->poison();
                return;
            }
        }
        if t == &null { return; }

        var key = reinterpret_cast::<u64>(vd);
        if self._binder_seen.insert(key).second {
            vd->type_ = t;
            return;
        }

        // A later alternative reaching the first alternative's decl.
        var nm = dyn()->sc->ctx->get_spelling(b->name);
        if b->is_const != vd->is_const() {
            var first = ("const") if (vd->is_const()) else ("var");
            var here  = ("const") if (b->is_const) else ("var");
            dyn()->sc->diag->report(DiagID::SC125E, b->range.start,
                f"'{nm}' is bound with '{here}' here but with '{first}' in an earlier alternative"
            ).first(b->range)
             .note(vd->range.start, "every alternative must bind a name with the same mutability")
             .emit();
            b->poison();
            return;
        }
        if (vd->type_ != &null) && (canon_unqual(vd->type_) != canon_unqual(t)) {
            dyn()->sc->diag->report(DiagID::SC125E, b->range.start,
                f"'{nm}' has type '{dyn()->tu.str(t)}' here but '{dyn()->tu.str(vd->type_)}' in an earlier alternative"
            ).first(b->range)
             .note(vd->range.start, "every alternative must bind a name with the same type")
             .emit();
            b->poison();
        }
    }

    // === ranges =============================================================

    priv fn _type_range(self, r: *RangePattern, st: *Type) {
        var p = static_cast::<*Pattern>(r);
        var is_char = (st != &null) && dyn()->tu.is_builtin(st, BuiltinKind::Char);
        if (st != &null) && (!st->is_dependent()) && (!dyn()->tu.is_integer(st)) && (!is_char) {
            dyn()->sc->diag->report(DiagID::SC126E, r->range.start,
                f"a range pattern needs an integer or 'char' value, not '{dyn()->tu.str(st)}\x27"
            ).first(r->range).emit();
            p->poison();
            return;
        }

        if r->lo != &null {
            dyn()->type_of(r->lo, st);
            if st != &null { dyn()->check_convertible(r->lo, st); }
            if r->lo->is_poisoned() { p->poison(); return; }
        }
        if r->hi != &null {
            dyn()->type_of(r->hi, st);
            if st != &null { dyn()->check_convertible(r->hi, st); }
            if r->hi->is_poisoned() { p->poison(); return; }
        }
        if st == &null { return; }

        var ps = PatternSpace(dyn()->sc);
        var ok = true;
        ok = self._const_bound(&ps, r->lo, is_char) && ok;
        ok = self._const_bound(&ps, r->hi, is_char) && ok;
        if !ok { p->poison(); return; }
        if is_char { return; }

        // Empty: compare as signed values (sign-magnitude).
        if (r->lo == &null) || (r->hi == &null) { return; }
        var lo = ps.eval_int(r->lo);
        var hi = ps.eval_int(r->hi);
        var c = self._cmp(lo, hi);
        if (c > 0) || ((c == 0) && (!r->is_inclusive)) {
            dyn()->sc->diag->report(DiagID::SC126E, r->range.start,
                "this range pattern matches no value"
            ).first(r->range)
             .note(r->range.start, ("its lower bound is above its upper bound") if (c > 0) else ("'..' excludes its upper bound, so 'a..a' is empty; write 'a' or 'a..=a\x27"))
             .emit();
            p->poison();
        }
    }

    priv fn _const_bound(self, ps: *PatternSpace, e: *Expr, is_char: bool) -> bool {
        if e == &null { return true; }
        if is_char && isa::<CharacterLiteralExpr>(dyn()->tu.strip_parens(e)) { return true; }
        if ps->eval_int(e).ok { return true; }
        dyn()->sc->diag->report(DiagID::SC126E, e->range.start,
            "a range pattern bound must be a constant: a literal, or a 'const' / 'eval' name"
        ).first(e->range).emit();
        return false;
    }

    /// -1 / 0 / 1 for a < b / a == b / a > b.
    priv fn _cmp(self, a: IntConst, b: IntConst) -> i32 {
        if a.neg && (!b.neg) { return -1; }
        if (!a.neg) && b.neg { return 1; }
        if a.mag == b.mag { return 0; }
        var less = a.mag < b.mag;
        if a.neg { less = !less; }
        return (-1) if (less) else (1);
    }

    // === constructor heads ==================================================

    priv fn _type_ctor(self, p: *Pattern, head: *Expr, is_dotted: bool, dotted: Token,
                       has_parens: bool, subs: FrozenList::<*Pattern>, st: *Type) {
        var ps = PatternSpace(dyn()->sc);

        // Unknown or dependent column: nothing to resolve against. Binders
        // still get typed (as unknown) so the body has decls to bind to.
        // A generic ADT's instance at dependent arguments is the exception:
        // its variants are its pattern's, known here, and a payload field's
        // type reads through the instance (`v: T` of `Rep<T>`), so the
        // pattern resolves like any other (MONO.md G11).
        if (st == &null) || (st->is_dependent() && (!self.dependent_adt(st))) {
            if head != &null { dyn()->type_head(head); }
            self._type_subs_unknown(subs);
            // A variadic enum's constructors are per instance: which tag a
            // pattern tests is unknown in a generic body (M2).
            var den = (self._enum_of(st)) if (st != &null) else (&null);
            var pv  = (adt_pack_variant(den)) if ((den != &null) && den->is_adt) else (&null);
            var hits = false;
            if pv != &null {
                if is_dotted { hits = dyn()->sc->ctx->get_spelling(dotted) == dyn()->tu.decl_name(static_cast::<*Decl>(pv)); }
                else { hits = self._head_decl(head) == static_cast::<*Decl>(pv); }
            }
            if hits {
                dyn()->sc->diag->report(DiagID::SC116E, p->range.start,
                    f"matching pack-expanded variant '{dyn()->tu.decl_name(static_cast::<*Decl>(pv))}' at a type that depends on a generic parameter is not supported yet"
                ).first(p->range).emit();
                p->poison();
            }
            return;
        }

        var rd: *Decl = &null;
        var owner = "";

        if is_dotted {
            var nm = dyn()->sc->ctx->get_spelling(dotted);
            var en = self._enum_of(st);
            if en == &null {
                dyn()->sc->diag->report(DiagID::SC123E, p->range.start,
                    f"'.{nm}' names an enum variant, but the matched value is '{dyn()->tu.str(st)}', not an enum"
                ).first(p->range).emit();
                p->poison();
                self._type_subs_unknown(subs);
                return;
            }
            for var i: usize = 0; i < en->variants.size(); ++i {
                var v = en->variants[i];
                if (v != &null) && (dyn()->tu.decl_name(static_cast::<*Decl>(v)) == nm) { rd = static_cast::<*Decl>(v); break; }
            }
            if rd == &null {
                dyn()->sc->diag->report(DiagID::SC123E, p->range.start,
                    f"'{dyn()->tu.str(st)}' has no variant named '{nm}\x27"
                ).first(p->range).emit();
                p->poison();
                self._type_subs_unknown(subs);
                return;
            }
            owner = nm;
        } else {
            if head == &null { p->poison(); return; }
            dyn()->type_head(head);   // the variant a head names is matched, not built.
            if head->is_poisoned() { p->poison(); self._type_subs_unknown(subs); return; }

            var den = dyn()->denoted_type(head);
            if den != &null {
                // `Response(...)`: a struct pattern over the scrutinee's record.
                var hd = dyn()->tu.record_decl(den);
                var sd = dyn()->tu.record_decl(st);
                var hp = (dyn()->tu.pattern_of(hd)) if (hd != &null) else (&null);
                var sp = (dyn()->tu.pattern_of(sd)) if (sd != &null) else (&null);
                if (hp == &null) || ((!isa::<StructDecl>(hp)) && (!isa::<ClassDecl>(hp))) {
                    var what = ("an enum; name one of its variants") if ((hp != &null) && isa::<EnumDecl>(hp)) else ("not a struct or class");
                    dyn()->sc->diag->report(DiagID::SC123E, head->range.start,
                        f"'{dyn()->tu.str(den)}' is {what}"
                    ).first(head->range).emit();
                    p->poison();
                    self._type_subs_unknown(subs);
                    return;
                }
                if hp != sp {
                    dyn()->sc->diag->report(DiagID::SC123E, head->range.start,
                        f"this pattern matches '{dyn()->tu.str(den)}', but the matched value is '{dyn()->tu.str(st)}\x27"
                    ).first(head->range).emit();
                    p->poison();
                    self._type_subs_unknown(subs);
                    return;
                }
                rd = hp;
                owner = dyn()->tu.decl_name(hp);
            } else {
                var d = self._head_decl(head);
                var nm = self._head_spelling(head);
                var v = dyn_cast::<EnumVariantDecl>(d);
                var vd = dyn_cast::<VariableDecl>(d);
                if v != &null {
                    var en = self._enum_of(st);
                    if (en == &null) || (ps.variant_index(en, v) < 0) {
                        dyn()->sc->diag->report(DiagID::SC123E, head->range.start,
                            f"'{nm}' is a variant of another enum; the matched value is '{dyn()->tu.str(st)}\x27"
                        ).first(head->range).emit();
                        p->poison();
                        self._type_subs_unknown(subs);
                        return;
                    }
                    rd = static_cast::<*Decl>(v);
                    owner = nm;
                } else if (vd != &null) && (vd->is_const() || vd->is_eval()) {
                    if has_parens || (subs.size() > 0) {
                        dyn()->sc->diag->report(DiagID::SC124E, head->range.start,
                            f"'{nm}' is a constant; it takes no payload"
                        ).first(p->range).emit();
                        p->poison();
                        return;
                    }
                    dyn()->type_of(head, st);
                    if !dyn()->check_convertible(head, st) { p->poison(); return; }
                    p->resolved_decl = d;
                    return;
                } else {
                    dyn()->sc->diag->report(DiagID::SC123E, head->range.start,
                        f"'{nm}' is not a variant, a constant or a type, so it cannot be matched against; to bind the value to a new name, write 'var {nm}\x27"
                    ).first(head->range).emit();
                    p->poison();
                    self._type_subs_unknown(subs);
                    return;
                }
            }
        }

        p->resolved_decl = rd;
        self._map_payload(p, rd, owner, has_parens, subs, st, &ps);
    }

    /// Names first, then positions; see the file header.
    priv fn _map_payload(self, p: *Pattern, rd: *Decl, owner: string, has_parens: bool,
                         subs: FrozenList::<*Pattern>, st: *Type, ps: *PatternSpace) {
        var fields = ps->fields_of_resolved(rd);
        var v = dyn_cast::<EnumVariantDecl>(rd);
        if (v != &null) && (fields.size() == 0) && (subs.size() > 0) {
            dyn()->sc->diag->report(DiagID::SC124E, p->range.start,
                f"'{owner}' carries no payload"
            ).first(p->range).emit();
            p->poison();
            self._type_subs_unknown(subs);
            return;
        }

        // A pack-expanded variant: which element this pattern matches is its
        // payload's type, written on a binder of the pack field.
        var ve = VariadicEnum(dyn()->sc);
        var pick: i32 = -1;
        var pes = vec::<*Type>();
        if (v != &null) && v->is_pack_expansion {
            pick = self._pat_pick_element(p, v, owner, subs, st, &ve, &pes);
            if pick < 0 { p->poison(); self._type_subs_unknown(subs); return; }
            p->pack_index = pick;
        }

        var used = vec::<bool>();
        for var k: usize = 0; k < fields.size(); ++k { used.push_back(false); }

        for var i: usize = 0; i < subs.size(); ++i {
            var sp = subs[i];
            if sp == &null { continue; }

            var idx: i32 = -1;
            if sp->kind == PatternKind::BindingPattern {
                var bp = cast::<BindingPattern>(sp);
                var want = dyn()->sc->ctx->get_spelling(bp->name);
                for var k: usize = 0; k < fields.size(); ++k {
                    if dyn()->tu.decl_name(static_cast::<*Decl>(fields[k])) == want { idx = i32(k); break; }
                }
                if idx < 0 {
                    dyn()->sc->diag->report(DiagID::SC124E, sp->range.start,
                        f"'{owner}' has no field named '{dyn()->sc->ctx->get_spelling(bp->name)}'; a binder takes the field of its own name"
                    ).first(sp->range).emit();
                    sp->poison();
                    p->poison();
                    continue;
                }
            } else {
                if i >= fields.size() {
                    dyn()->sc->diag->report(DiagID::SC124E, sp->range.start,
                        f"'{owner}' has {fields.size()} field(s); this is subpattern {i + 1}"
                    ).first(sp->range).emit();
                    sp->poison();
                    p->poison();
                    continue;
                }
                idx = i32(i);
            }

            var fd = fields[usize(idx)];
            if used[usize(idx)] {
                dyn()->sc->diag->report(DiagID::SC124E, sp->range.start,
                    f"field '{dyn()->tu.decl_name(static_cast::<*Decl>(fd))}' of '{owner}' is matched twice"
                ).first(sp->range)
                 .note(sp->range.start, "a binder takes the field of its own name; any other subpattern takes the field at its position")
                 .emit();
                sp->poison();
                p->poison();
                continue;
            }
            used[usize(idx)] = true;
            sp->field_decl = static_cast::<*Decl>(fd);

            var ft: *Type = &null;
            if pick >= 0 {
                ft = ve.field_at(st, fd, usize(pick));
            } else if (fd->type_ != &null) && (fd->type_->canonical != &null) {
                ft = dyn()->ded_scratch()->member_through(st, fd->type_->canonical);
            }
            self.type_pattern(sp, ft);
        }
    }

    /// The element of pack-expanded \p v a pattern matches at \p st: the one
    /// a binder of a pack field names as its type (`.Err(var e: f64)`), or
    /// the only one; -1 after reporting why there is none.
    priv fn _pat_pick_element(self, p: *Pattern, v: *EnumVariantDecl, owner: string, subs: FrozenList::<*Pattern>,
                          st: *Type, ve: *VariadicEnum, pes: *vec::<*Type>) -> i32 {
        var stn = dyn()->tu.str(st);
        if !ve->elems(st, pes) {
            dyn()->sc->diag->report(DiagID::SC116E, p->range.start,
                f"matching pack-expanded variant '{owner}' at a type that depends on a generic parameter is not supported yet"
            ).first(p->range).emit();
            return -1;
        }
        if pes->size() == 0 {
            var b = dyn()->sc->diag->report(DiagID::SC001E, p->range.start,
                f"'{stn}' has no '{owner}' variant: its pack is empty");
            b.first(p->range);
            b.note(v->range.start, "one variant per element of the pack").first(v->range);
            b.emit();
            return -1;
        }
        var pick: i32 = -1;
        var named: *BindingPattern = &null;     // a binder of a pack field, typed or not.
        for var i: usize = 0; i < subs.size(); ++i {
            var bp = dyn_cast::<BindingPattern>(subs[i]);
            if bp == &null { continue; }
            var want = dyn()->sc->ctx->get_spelling(bp->name);
            var fd: *FieldDecl = &null;
            for var k: usize = 0; k < v->payload.size(); ++k {
                if dyn()->tu.decl_name(static_cast::<*Decl>(v->payload[k])) == want { fd = v->payload[k]; break; }
            }
            if (fd == &null) || (!ve->is_pack_field(fd)) { continue; }
            if named == &null { named = bp; }
            if (bp->type_ == &null) || (bp->type_->canonical == &null) { continue; }
            var k = ve->exact(st, bp->type_->canonical);
            if k < 0 {
                var b = dyn()->sc->diag->report(DiagID::SC001E, bp->type_->range.start,
                    f"no '{owner}' of '{stn}' holds a '{dyn()->tu.str(bp->type_->canonical)}\x27");
                b.first(bp->type_->range, "the payload's type picks the variant");
                b.note(v->range.start, f"its variants here: {ve->describe(st, v)}").first(v->range);
                b.emit();
                return -1;
            }
            if (pick >= 0) && (k != pick) {
                dyn()->sc->diag->report(DiagID::SC001E, bp->type_->range.start,
                    f"these binders name two different '{owner}' variants of '{stn}\x27"
                ).first(bp->type_->range).emit();
                return -1;
            }
            pick = k;
        }
        if pick >= 0 { return pick; }
        if pes->size() == 1 { return 0; }
        var b = dyn()->sc->diag->report(DiagID::SC001E, p->range.start,
            f"'{owner}' is one variant per element of a pack in '{stn}'; name the payload's type to pick one");
        b.first(p->range, "matches which?");
        if named != &null {
            b.insert(named->range.end, ": " + dyn()->tu.str((*pes)[0]), "name the payload type");
        }
        b.note(v->range.start, f"its variants here: {ve->describe(st, v)}").first(v->range);
        b.emit();
        return -1;
    }

    priv fn _type_subs_unknown(self, subs: FrozenList::<*Pattern>) {
        for var i: usize = 0; i < subs.size(); ++i { self.type_pattern(subs[i], &null); }
    }

    /// The enum a column ranges over, or null. ControlTyping reads the enum
    /// of a variant construction's type through it too.
    /// \p st is an instance of a Kairo generic ADT at dependent arguments
    /// whose variants are one list for every instance (no pack-expanded
    /// variant): a match on it is typed, checked and compiled at the
    /// definition, and C++ picks the layout (EnumLayoutQuery's Opaque).
    fn dependent_adt(self, st: *Type) -> bool {
        var en = self._enum_of(st);
        if (en == &null) || (!en->is_adt) || en->is_imported() { return false; }
        return adt_pack_variant(en) == &null;
    }

    fn _enum_of(self, st: *Type) -> *EnumDecl {
        var rd = dyn()->tu.record_decl(st);
        if rd == &null { return &null; }
        return dyn_cast::<EnumDecl>(dyn()->tu.pattern_of(rd));
    }

    /// The declaration a typed head names: an ident's binding, or a path's
    /// last step. ControlTyping classifies an initializer's head with it.
    fn _head_decl(self, e: *Expr) -> *Decl {
        if e == &null { return &null; }
        if isa::<NamedIdentExpr>(e) { return cast::<NamedIdentExpr>(e)->resolved_decl; }
        if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() == 0 { return self._head_decl(ch->base); }
            return ch->steps.get(ch->steps.size() - 1)->resolved_decl;
        }
        return &null;
    }

    priv fn _head_spelling(self, e: *Expr) -> string {
        if e == &null { return "?"; }
        return dyn()->sc->ctx->get_spelling(e->range);
    }
}