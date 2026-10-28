/// --- The Kairo Project -------------------- Sema/Type/MemberTyping.k --- ///
///
///   \brief Chains and subscripts: the value each step of `a.b->c::d` yields.
///
///   \detail
///     ChainBinding already bound every step whose left side had a DECLARED
///     type. What it left as NeedsInference -- a step after a call, after an
///     inferred `var`, after an overload set -- is bound here, by handing
///     ChainBinding the anchor this pass can now compute
///     (`ChainBinding::bind_step`, see spec). One binder, two callers.
///
///     What a step yields:
///       field / var / param      its declared type, seen through the
///                                receiver's generic args   -- LValue
///       enum variant             the enum                   -- RValue
///       method / overload set    nothing: callable; only legal as a callee
///       nested type / alias      nothing: a type; legal as a ctor callee or
///                                initializer head
///       module                   nothing
///       tuple index `.0`         the element                 -- LValue
///       operator step            callable
///     `?.` peels the nullable and the whole chain's result is re-wrapped.
///
///     The chain's shape (receiver before the last step, whether the last
///     step is callable/type) is recorded in ExprTyper::_chains so CallTyping
///     does not re-walk it.
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
import Sema::Resolve::NameLookup::*;
import AST::Context::TranslationUnit::*;
import Sema::Resolve::ChainBinding::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import Sema::Type::ArgumentDeduction::*;
import Sema::Type::NullnessFlow::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::OperatorFacts::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::LangItems::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

/// \class ChainInfo
/// \brief What the typer learned about one ChainExpr, for CallTyping.
class ChainInfo {
    pub var receiver:       *Type = &null;    ///< value type before the last step, if any.
    pub var has_receiver:   bool  = false;    ///< last step was reached through `.`/`->`/`?.`/`?->` on a value.
    pub var last_is_type:   bool  = false;    ///< last step names a type.
    pub var callable_cands: vec::<*Decl>;     ///< last step is a method / set / operator.
    pub var unknown:        bool  = false;    ///< dependent or foreign; nothing to say.
    fn ChainInfo(self) { }
}

class <T> MemberTyping {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    /// Step \p i of \p n is `?.` / `?->` on \p val, which is not nullable:
    /// SC001E, with the fix-it that drops the `?`.
    priv fn _not_nullable_step(self, n: *ChainExpr, i: usize, val: *Type) {
        var st  = n->steps.get(i);
        var sep = ("?->") if (st->access_kind == ChainExpr::AccessKind::QuestionArrow) else ("?.");
        var to  = ("->") if (st->access_kind == ChainExpr::AccessKind::QuestionArrow) else (".");
        var end = (n->base->range.end) if (i == 0) else (n->steps.get(i - 1)->range.end);
        var r   = SourceRange(n->range.start, end);
        var text = dyn()->sc->ctx->get_spelling(r);
        var b = dyn()->sc->diag->report(DiagID::SC001E, st->range.start,
            f"'{text}' is not nullable ('{dyn()->tu.str(val)}'); '{sep}' guards a null it cannot hold, write '{to}\x27");
        b.first(SourceRange(st->range.start, st->range.start.with_offset(1)));
        // The declaration that gave it the non-nullable type.
        var d: *Decl = &null;
        if i > 0 { d = n->steps.get(i - 1)->resolved_decl; }
        else if isa::<NamedIdentExpr>(dyn()->tu.strip_parens(n->base)) { d = cast::<NamedIdentExpr>(dyn()->tu.strip_parens(n->base))->resolved_decl; }
        if (d != &null) && d->range.is_valid() { b.note(d->range.start, f"'{dyn()->tu.decl_name(d)}' is declared '{dyn()->tu.str(val)}' here"); }
        b.remove(SourceRange(st->range.start, st->range.start.with_offset(1)), f"write '{to}\x27");
        b.emit();
        dyn()->poison_only(n);
    }

    /// A member of an associated type (`x.show()` on `x: T::Item`, or
    /// `T::Item::make()`): lookup through the associated type's own bounds
    /// is not built (MONO.md G5), so it is SC116E rather than unknown.
    priv fn _assoc_member_unsupported(self, n: *ChainExpr, st: *ChainExpr::Step, t: *Type) {
        var a = cast::<AssocType>(canon_unqual(t));
        var ts = dyn()->tu.str(t);
        var b = dyn()->sc->diag->report(DiagID::SC116E, st->range.start,
            f"a member of associated type '{ts}' cannot be used yet; lookup through an associated type's bounds is not supported");
        b.first(st->range);
        if (a->assoc != &null) && a->assoc->range.is_valid() { b.note(DiagID::SC116N, a->assoc->range.start, "the associated type is declared here").first(a->assoc->range); }
        b.emit();
        dyn()->poison_only(n);
    }

    fn type_chain(self, n: *ChainExpr, expected: *Type) -> *Type {
        var info = dyn()->new_chain_info(n);

        // -- base ------------------------------------------------------------
        var cur:      *Type = &null;      // value type of the current position
        var cur_kind: u8 = 0;             // 0 value, 1 type, 2 module, 3 callable, 4 unknown
        var cur_type: *Type = &null;      // when cur_kind == 1
        var saw_optional = false;
        var last_variant: *EnumVariantDecl = &null;   // the chain ends naming this variant

        if n->base == &null {
            cur_kind = 2;
        } else if self._is_cxx_head(n->base) {
            // `cxx` as a chain HEAD is the overlay's scope, which is what it
            // is for; _type_ident's R053E is for `cxx` standing alone, and
            // typing the head through it rejected `cxx::std::vector<i32>()`.
            dyn()->note_module_expr(n->base);
            cur_kind = 2;
        } else {
            var bt = dyn()->type_of(n->base, &null);
            if n->base->is_poisoned() { dyn()->poison_only(n); return &null; }
            // `p->f` goes where p points: the pointer is no escape (NULLABLE.md 3.7).
            if (n->steps.size() > 0)
            && ((n->steps.get(0)->access_kind == ChainExpr::AccessKind::Arrow) || (n->steps.get(0)->access_kind == ChainExpr::AccessKind::QuestionArrow)) {
                dyn()->flow.consumed(n->base);
            }
            var denoted = dyn()->denoted_type(n->base);
            if denoted != &null {
                cur_kind = 1; cur_type = denoted;
            } else if dyn()->denotes_module(n->base) {
                cur_kind = 2;
            } else if bt == &null {
                cur_kind = 4;
            } else {
                cur_kind = 0; cur = bt;
            }
        }

        // -- steps -----------------------------------------------------------
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if st == &null { break; }
            var is_last = (i + 1 == n->steps.size());

            if cur_kind == 4 { info->unknown = true; dyn()->mark_unknown(n); return &null; }
            if cur_kind == 3 {
                dyn()->fail(n, DiagID::SC100E, "cannot access a member of a function; call it first");
                return &null;
            }

            // `.` / `->` on a nullable reads its value (NULLABLE.md §4): the
            // base, or the field path so far, narrowed when its place is
            // proven non-null here, else the nullness error. ChainBinding
            // left the step unbound for this (its anchor was nullable), so
            // it binds below on the narrowed type. A nullable that is no
            // place (`f().v`) keeps the old answer, "no member in 'T?'".
            if (cur_kind == 0) && (cur != &null)
            && ((st->access_kind == ChainExpr::AccessKind::Dot) || (st->access_kind == ChainExpr::AccessKind::Arrow))
            && (dyn()->tu.nullable_inner(dyn()->ml.peel_ref(cur)) != &null) {
                var o = dyn()->flow.read_prefix(n, i);
                if o == NULL_READ_REFUSED() { dyn()->poison_only(n); return &null; }
                if (o == NULL_READ_NONE()) && dyn()->flow.refuse_unplaced(n, i) { return &null; }
                if o == NULL_READ_NARROWED() { cur = (n->base->type_) if (i == 0) else (n->steps.get(i - 1)->resolved_type); }
            }

            // NeedsInference: bind now with the anchor T could not see.
            if (st->resolved_decl == &null) && (st->candidate_cell == &null)
            && ((st->name == &null) || (!st->name->is_poisoned())) && (!st->is_tuple_index()) {
                // A value of an associated type (`x.show()`, `x: T::Item`)
                // binds through the associated type's own bounds: the
                // anchor is Dependent on it, and ChainBinding reads them.
                if (cur_kind == 0) && (cur != &null) {
                    var a = dyn()->cb.anchor_for_value(&null, cur);
                    dyn()->cb.bind_step(n, st, a);
                } else if cur_kind == 1 {
                    // A step ChainBinding left unbound on a type PARAMETER is
                    // dependent by its decision (`: type`, or no bound
                    // answered): M2's, not a lookup to retry on T here.
                    if isa::<GenericParamType>(canon_unqual(cur_type)) {
                        // `T::Node` naming an associated type of T's bounds
                        // is that type (as in type position), not unknown.
                        var at: *Type = &null;
                        if (st->access_kind == ChainExpr::AccessKind::ColonColon) && (st->name != &null) && st->generic_args.is_empty() {
                            at = dyn()->tu.assoc_named(cur_type, dyn()->sc->ctx->get_spelling(st->name->name));
                        }
                        if at != &null {
                            cur_type = at;
                            st->resolved_type = at;
                            if is_last {
                                info->receiver     = at;
                                info->has_receiver = false;
                            }
                            continue;
                        }
                        info->unknown = true;
                        dyn()->mark_unknown(n);
                        return &null;
                    }
                    if isa::<AssocType>(canon_unqual(cur_type)) {
                        self._assoc_member_unsupported(n, st, cur_type);
                        return &null;
                    }
                    var a = dyn()->cb.anchor_for_type(cur_type);
                    dyn()->cb.bind_step(n, st, a);
                }
            }
            if (st->name != &null) && st->name->is_poisoned() { dyn()->poison_only(n); return &null; }

            // separators on a value: `?.`/`?->` peel the nullable, `->` the pointer.
            // A C++ reference is transparent to every separator, so it goes
            // first -- the same helper ChainBinding binds with.
            var val = cur;
            // The receiver OBJECT's cv, read before peel_ref strips it:
            // `s.data()` on a const `s` must rank `data() const` alone.
            var recv_q: u8 = 0;
            if cur_kind == 0 {
                recv_q = self._object_quals(val);
                val = dyn()->ml.peel_ref(val);
                if (st->access_kind == ChainExpr::AccessKind::QuestionDot)
                || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) {
                    var inner = dyn()->tu.nullable_inner(val);
                    if inner != &null { val = inner; saw_optional = true; }
                    else if (val != &null) && (!val->is_dependent()) && (!val->is_instantiation_dependent()) {
                        // `?.` guards a null that cannot happen: the value is
                        // read as it is (NULLABLE.md 2.5), so say which
                        // separator was meant rather than make it `M?`.
                        self._not_nullable_step(n, i, val);
                        return &null;
                    }
                }
                if (st->access_kind == ChainExpr::AccessKind::Arrow)
                || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) {
                    var p = dyn()->tu.pointee(val);
                    if p != &null { val = p; recv_q = self._object_quals(p); }
                }
                // The pointee of a `*const T` is `const T`; peel_ref now
                // peels quals too.
                val = dyn()->ml.peel_ref(val);
            }

            if is_last {
                // Qualified with the object's cv: OverloadResolution ranks
                // the receiver on it and strips it for everything else. A
                // `::` call off a type has that type as its receiver, so a
                // static on `Vec<i64>::` seeds the extension's parameters.
                var recv_ty = (cur_type) if (cur_kind == 1) else (val);
                info->receiver     = (dyn()->sc->types->qualified(recv_ty, recv_q)) if (recv_ty != &null) else (&null);
                info->has_receiver = (cur_kind == 0) && (st->access_kind != ChainExpr::AccessKind::ColonColon);
            }

            // -- tuple index --
            if st->is_tuple_index() {
                if (cur_kind != 0) || (val == &null) || (!dyn()->tu.is_tuple(val)) {
                    dyn()->fail(n, DiagID::SC101E, "tuple index on a non-tuple");
                    return &null;
                }
                var elems = dyn()->tu.tuple_elems(val);
                if static_cast::<usize>(st->index) >= elems.size() {
                    dyn()->fail(n, DiagID::SC101E, f"tuple index {st->index} is out of range for '{dyn()->tu.str(val)}\x27");
                    return &null;
                }
                // The element is the record's argument at that position: the
                // pattern's field `_i` is typed `Ti`, which is args[i] in
                // this instance by construction. The step is bound to the
                // field so TupleLowering has a name to spell for it.
                cur = elems[static_cast::<usize>(st->index)];
                st->resolved_type = cur;
                st->resolved_decl = static_cast::<*Decl>(dyn()->tu.tuple_field(val, static_cast::<usize>(st->index)));
                cur_kind = 0;
                n->value_category = Expr::ValueCategory::LValue;   // a field: `t.0 = x` assigns through.
                continue;
            }

            // -- operator step: `x.op+` / `Foo::op[]` --
            if st->is_operator() {
                var owner_ty: *Type = (cur_type) if (cur_kind == 1) else (val);
                if owner_ty == &null { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                var k0 = TokenKind::TkUnknown; var k1 = TokenKind::TkUnknown;
                if st->op_tokens.size() > 0 { k0 = st->op_tokens[0].kind; }
                if st->op_tokens.size() > 1 { k1 = st->op_tokens[1].kind; }
                info->callable_cands.clear();
                dyn()->ml.lookup(dyn()->tu.strip_nullable(owner_ty), DeclName::op_name(k0, k1), &(info->callable_cands));
                if info->callable_cands.size() == 0 {
                    dyn()->fail(n, DiagID::SC102E, f"no such operator on '{dyn()->tu.str(owner_ty)}\x27");
                    return &null;
                }
                cur_kind = 3;
                continue;
            }

            // -- named step --
            var d = st->resolved_decl;
            if (d == &null) && (st->candidate_cell != &null) {
                info->callable_cands.clear();
                for var j: usize = 0; j < st->candidate_cell->size(); ++j { info->callable_cands.push_back(st->candidate_cell->get(j)); }
                cur_kind = 3;
                continue;
            }
            if d == &null {
                // ChainBinding recorded a reason: dependent / foreign / inference hole.
                info->unknown = true;
                dyn()->mark_unknown(n);
                return &null;
            }

            switch d->kind {
                case DeclKind::FieldDecl {
                    var f = cast::<FieldDecl>(d);
                    var ft = (f->type_->canonical) if (f->type_ != &null) else (&null);
                    if ft == &null { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                    // Reached through a `T derives Base` bound, `seen` is the
                    // PARAMETER, not a record: member_through then binds
                    // nothing and hands back the base's declared field type,
                    // which is the right answer. Do not "fix" this into
                    // resolving the base record -- the field is not seen
                    // through Base's generic args, it is seen through T's.
                    var seen = (val) if (cur_kind == 0) else (cur_type);
                    cur = dyn()->ded_scratch()->member_through(seen, ft);
                    cur_kind = 0;
                    st->resolved_type = cur;
                    n->value_category = Expr::ValueCategory::LValue;
                }
                case DeclKind::VariableDecl {
                    var v = cast::<VariableDecl>(d);
                    cur = dyn()->var_type(v);
                    if cur == &null { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                    // A const binding is a const object; see ExprTyper::_type_ident.
                    if v->is_const() { cur = dyn()->sc->types->qualified(cur, QUAL_CONST()); }
                    cur_kind = 0; st->resolved_type = cur;
                    n->value_category = Expr::ValueCategory::LValue;
                }
                case DeclKind::ParamDecl {
                    // A pack reads as its Slice<E>; see ExprTyper::param_value_type.
                    cur = dyn()->param_value_type(cast::<ParamDecl>(d));
                    if cur == &null { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                    cur_kind = 0; st->resolved_type = cur;
                    n->value_category = Expr::ValueCategory::LValue;
                }
                case DeclKind::EnumVariantDecl {
                    var edc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
                    var ed  = (edc->owner_decl()) if (edc != &null) else (&null);
                    if ed == &null { dyn()->fail(n, DiagID::SC093E, "enum variant has no owning enum"); return &null; }
                    cur = dyn()->variant_value_type(ed);
                    if (cur_kind == 1) && (dyn()->discr_enum == &null) { cur = cur_type; }   // `Foo<i32>::V` keeps the instance
                    cur_kind = 0; st->resolved_type = cur;
                    n->value_category = Expr::ValueCategory::RValue;
                    if is_last { last_variant = cast::<EnumVariantDecl>(d); }
                }
                case DeclKind::FunctionDecl {
                    info->callable_cands.clear();
                    info->callable_cands.push_back(d);
                    cur_kind = 3;
                }
                case DeclKind::ModuleDecl { cur_kind = 2; }
                case DeclKind::GenericParamDecl { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                default {
                    // `T::Node` that ChainBinding bound through T's bound to
                    // the requirement itself: the associated type of T.
                    if isa::<TypeAliasDecl>(d) && cast::<TypeAliasDecl>(d)->is_associated {
                        var at: *Type = &null;
                        if (cur_kind == 1) && (cur_type != &null) {
                            var ct0 = canon_unqual(cur_type);
                            if isa::<GenericParamType>(ct0) {
                                at = dyn()->tu.assoc_named(ct0, dyn()->tu.decl_name(d));
                            } else if (dyn()->tu.record_decl(ct0) != &null)
                                   && isa::<InterfaceDecl>(NameLookup::representative(dyn()->tu.pattern_of(dyn()->tu.record_decl(ct0)))) {
                                var ai = dyn()->tu.assoc_iface(ct0, d);
                                if ai != &null { at = dyn()->sc->types->assoc(ct0, ai, NameLookup::representative(d)); }
                            }
                        }
                        if at == &null { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                        if !is_last { self._assoc_member_unsupported(n, n->steps.get(i + 1), at); return &null; }
                        cur_type = at;
                        cur_kind = 1;
                        st->resolved_type = at;
                        info->receiver     = at;
                        info->has_receiver = false;
                        continue;
                    }
                    if dyn()->tu.is_type_decl(d) {
                        var outer_t = (cur_type) if (cur_kind == 1) else (&null);
                        cur_type = dyn()->type_from_type_decl(d, st->generic_args, n);
                        if cur_type == &null { dyn()->poison_only(n); return &null; }
                        // `L<i32>::P { .. }` / `L<i32>::Color::Red`: a member
                        // type named through an instance is that instance's
                        // (GH#91), as in type position (TypeResolve).
                        if (outer_t != &null) && (cur_type->in_generic_owner() || cur_type->is_dependent())
                        && isa::<RecordType>(canon_unqual(outer_t)) {
                            var sd = Deduction(dyn()->sc, &null);
                            sd.bind_from_record(canon_unqual(outer_t));
                            var sub = sd.substitute(cur_type);
                            if sub != &null { cur_type = sub; }
                        }
                        cur_kind = 1;
                        st->resolved_type = cur_type;
                    } else {
                        dyn()->fail(n, DiagID::SC094E, f"'{dyn()->tu.decl_name(d)}' is not a value");
                        return &null;
                    }
                }
            }
        }

        // -- result ----------------------------------------------------------
        switch cur_kind {
            case 0 {
                if cur == &null { return &null; }
                // `Opt::None` as a value is a construction (ControlTyping).
                if last_variant != &null { return dyn()->type_variant_value(static_cast::<*Expr>(n), last_variant, cur); }
                // `x?.m` is `if x? => x.m else null` (NULLABLE.md 2.5): an
                // rvalue `M?`, never `(M?)?`. CoalesceLowering expands it.
                if saw_optional {
                    n->value_category = Expr::ValueCategory::RValue;
                    return dyn()->sc->types->nullable(dyn()->tu.strip_nullable(cur));
                }
                // A nullable field path is a use of its place, as a name is
                // (ExprTyper::_note_place_read).
                if null_flow_type_is_nullable(cur) {
                    var place = null_place_of(static_cast::<*Expr>(n));
                    if place.size() > 0 { dyn()->flow.note_read(static_cast::<*Expr>(n), &place); }
                }
                return cur;
            }
            case 1 { info->last_is_type = true; dyn()->note_type_expr(static_cast::<*Expr>(n), cur_type); return &null; }
            case 2 { dyn()->note_module_expr(static_cast::<*Expr>(n)); return &null; }
            case 3 {
                // a unique non-method function named through a path is a value.
                if (info->callable_cands.size() == 1) && (!info->has_receiver) {
                    var f = dyn_cast::<FunctionDecl>(info->callable_cands[0]);
                    if (f != &null) && (!f->is_method()) && (f->generic_params.size() == 0) {
                        n->value_category = Expr::ValueCategory::RValue;
                        return dyn()->fn_pointer_type(f);
                    }
                }
                return &null;   // callable; CallTyping reads info.
            }
            default { info->unknown = true; dyn()->mark_unknown(n); return &null; }
        }
    }

    // === subscript ==========================================================

    /// The cv of the object \p t denotes: through any C++ reference (a
    /// reference is its referee), not through a pointer.
    /// \p e is the bare identifier `cxx`, bound to this TU's std overlay.
    priv fn _is_cxx_head(self, e: *Expr) -> bool {
        if !isa::<NamedIdentExpr>(e) { return false; }
        var id = cast::<NamedIdentExpr>(e);
        if (!id->is_bound()) || (!id->generic_args.is_empty()) { return false; }
        var tu = dyn()->sc->tu;
        return (tu != &null) && (tu->cxx_module != &null) && (id->resolved_decl == tu->cxx_module);
    }

    priv fn _object_quals(self, t: *Type) -> u8 {
        var c = t;
        while c != &null {
            if isa::<CXXLValueRefType>(c) { c = cast::<CXXLValueRefType>(c)->referee; continue; }
            if isa::<CXXRValueRefType>(c) { c = cast::<CXXRValueRefType>(c)->referee; continue; }
            break;
        }
        return canon_quals(c);
    }

    /// `b[i]` through the record's own `op []`: \p cands is what the
    /// lookup on \p recv (the receiver, or an array's slice view) found.
    priv fn _type_subscript_op(self, n: *SubscriptExpr, bt: *Type, recv: *Type, cands: *vec::<*Decl>) -> *Type {
        if cands->size() == 0 {
            dyn()->type_of(n->index, &null);
            dyn()->fail(n, DiagID::SC103E, f"'{dyn()->tu.str(bt)}' has no subscript operator");
            return &null;
        }
        var args = vec::<ArgInfo>();
        args.push_back(dyn()->arg_info(n->index));
        var r = dyn()->ovl.resolve(cands, &args, true, n->range, "op []", recv);
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        // Member-only resolution, so via_free is false here by
        // construction; assigned from r anyway so the two never drift.
        n->resolved_op = r.decl;
        n->op_via_free = r.via_free;
        r.ded.bind_from_record(recv);
        dyn()->finish_call_args(r.decl, &args, &r);
        // Already through the receiver's generic args: bind_from_record
        // seeded r.ded, and call_result_type substitutes a dependent
        // result through it.
        var rt = dyn()->call_result_type(r.decl, &r);
        // call_result_type registers a generic winner's instance, so
        // EmitIR spells its arguments rather than leaving them to
        // C++ deduction (resolve_user_op's order).
        n->op_instance = reinterpret_cast::<*void>(r.instance);
        if rt == &null { return &null; }
        // A C++ `operator[]` (std::unordered_map, ...) already returns
        // the place as `T&`, and one returning a real `T*` means the
        // pointer: its result is taken as declared. Decided by the
        // declaring TU, not by the result's shape, for that reason.
        var oc  = NameLookup::ctx_of(r.decl);
        var otu = (reinterpret_cast::<*TranslationUnit>(oc->tu)) if (oc != &null) else (&null);
        if (otu != &null) && otu->is_foreign {
            n->value_category = Expr::ValueCategory::LValue;
            return rt;
        }
        // A Kairo place returns `*T` / `*const T` and the subscript IS
        // the T it points to, an lvalue, const if the pointer was. Any
        // other result is a value operator: the subscript is that
        // value, an rvalue, so `&b[0..1]` is the ordinary
        // address-of-rvalue error.
        var fd = cast::<FunctionDecl>(r.decl);
        if OperatorFacts::is_place(fd) {
            n->value_category = Expr::ValueCategory::LValue;
            var place = dyn()->tu.pointee(rt);
            ICE_IF(place == &null, "MemberTyping: place `op []` without a pointee; OperatorFacts::is_place disagrees");
            return place;
        }
        n->value_category = Expr::ValueCategory::RValue;
        return rt;
    }

    fn type_subscript(self, n: *SubscriptExpr, expected: *Type) -> *Type {
        var bt = dyn()->type_of(n->base, &null);
        if dyn()->propagate(n, n->base) { return &null; }
        if bt == &null { return &null; }
        // `xs[i]` on a nullable reads its value (NULLABLE.md §4).
        if dyn()->tu.nullable_inner(bt) != &null {
            bt = dyn()->read_value(n->base);
            if bt == &null { dyn()->poison_only(n); dyn()->type_of(n->index, &null); return &null; }
        }
        // A C++ reference is its referee. `m[2][1]` subscripts what the
        // inner `op []` returned, `array<i32, 2>&`, and member lookup has no
        // table for a reference type: unstripped, every chained subscript
        // into an imported container was SC103E "has no subscript operator".
        while true {
            var u = canon_unqual(bt);
            if isa::<CXXLValueRefType>(u) { bt = cast::<CXXLValueRefType>(u)->referee; continue; }
            if isa::<CXXRValueRefType>(u) { bt = cast::<CXXRValueRefType>(u)->referee; continue; }
            break;
        }
        bt = canon_unqual(bt);

        var ri = dyn_cast::<RangeExpr>(dyn()->tu.strip_parens(n->index));
        if ri != &null { ri->as_index = true; }
        var is_range = (n->index != &null) && isa::<RangeExpr>(dyn()->tu.strip_parens(n->index));
        var usize_t  = dyn()->tu.builtin(BuiltinKind::USize);

        // `a[i..j]` on an array is the slice's: the array is viewed as
        // `[T;]` (the conversion an argument would take) and Slice's range
        // `op []` does the rest. OperatorLowering wraps the base in the view.
        var recv = dyn()->tu.strip_nullable(bt);
        var array_range = is_range && (dyn()->tu.element_of(bt) != &null);
        if array_range {
            var view = dyn()->tu.array_view(n->base->type_);
            if view == &null { dyn()->missing_lang_item(n, to_string(WellKnownType::Slice)); return &null; }
            recv = view;
        }

        // user `op []`. A builtin container's own `op []` wins as any
        // record's does: the shapes below are only what a vector, map or
        // string that declares NO `op []` falls back to. One that declares
        // some, none of which takes the index, gets the ordinary overload
        // error rather than the shape: a declared set is the type's whole
        // subscript surface, and a silent fallback would hide the mistake.
        // An array, tuple or pointer has no members to ask.
        if dyn()->tu.kind_of(bt) == BuiltinKind::COUNT {
            var has_shape = dyn()->tu.is_vector_like(bt) || dyn()->tu.is_map_like(bt) || dyn()->tu.is_string(bt);
            var no_members = (dyn()->tu.element_of(bt) != &null) || dyn()->tu.is_tuple(bt) || (dyn()->tu.pointee(bt) != &null);
            if (!no_members) || array_range {
                var cands = vec::<*Decl>();
                var sub_name = DeclName::op_name(TokenKind::OpLSquare, TokenKind::OpRSquare);
                // A bounded parameter has no members of its own: its `op []`
                // is a bound's requirement, as a binary operator's is
                // (OperatorTyping::_gather), which sends the call through the
                // interface's witness (CODEGEN.md §7b.5).
                var bound = dyn()->bound_ifaces(recv);
                if bound.size() > 0 {
                    for var i: usize = 0; i < bound.size(); ++i { dyn()->ml.lookup(bound[i], sub_name, &cands); }
                } else {
                    dyn()->ml.lookup(recv, sub_name, &cands);
                }
                if (cands.size() > 0) || (!has_shape) || array_range {
                    return self._type_subscript_op(n, bt, recv, &cands);
                }
            }
        }

        // builtin shapes
        if dyn()->tu.is_tuple(bt) {
            dyn()->type_of(n->index, &null);
            dyn()->fail(n, DiagID::SC103E, "tuples are indexed with '.0', '.1', ..., not '[]\x27");
            return &null;
        }
        var kt: *Type = &null; var vt: *Type = &null;
        if dyn()->tu.map_key_value(bt, &kt, &vt) {
            dyn()->type_of(n->index, kt);
            if !dyn()->check_convertible(n->index, kt) { dyn()->poison_only(n); return &null; }
            n->value_category = Expr::ValueCategory::LValue;
            return vt;
        }
        var elem = dyn()->tu.container_elem(bt);
        if (elem == &null) && (dyn()->tu.pointee(bt) != &null) { elem = dyn()->tu.pointee(bt); }
        if (elem == &null) && dyn()->tu.is_string(bt) { elem = dyn()->tu.builtin(BuiltinKind::Char); }
        if elem == &null {
            dyn()->type_of(n->index, &null);
            dyn()->fail(n, DiagID::SC103E, f"'{dyn()->tu.str(bt)}' cannot be indexed");
            return &null;
        }
        if is_range {
            dyn()->type_of(n->index, &null);
            // a slice of a container is the container type (the runtime views
            // it): a new value, not storage.
            n->value_category = Expr::ValueCategory::RValue;
            return bt;
        }
        var it = dyn()->type_of(n->index, usize_t);
        if dyn()->propagate(n, n->index) { return &null; }
        if (it != &null) && (!dyn()->tu.is_integer(it)) {
            dyn()->fail(n->index, DiagID::SC103E, f"index must be an integer, not '{dyn()->tu.str(it)}\x27");
            dyn()->poison_only(n);
            return &null;
        }
        n->value_category = Expr::ValueCategory::LValue;
        return elem;
    }
}