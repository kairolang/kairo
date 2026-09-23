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
import Sema::Resolve::ChainBinding::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import Sema::Type::ArgumentDeduction::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
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

    fn type_chain(self, n: *ChainExpr, expected: *Type) -> *Type {
        var info = dyn()->new_chain_info(n);

        // -- base ------------------------------------------------------------
        var cur:      *Type = &null;      // value type of the current position
        var cur_kind: u8 = 0;             // 0 value, 1 type, 2 module, 3 callable, 4 unknown
        var cur_type: *Type = &null;      // when cur_kind == 1
        var saw_optional = false;

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
                dyn()->fail(n, "cannot access a member of a function; call it first");
                return &null;
            }

            // NeedsInference: bind now with the anchor T could not see.
            if (st->resolved_decl == &null) && (st->candidate_cell == &null)
            && ((st->name == &null) || (!st->name->is_poisoned())) && (!st->is_tuple_index()) {
                if (cur_kind == 0) && (cur != &null) {
                    var a = dyn()->cb.anchor_for_value(&null, cur);
                    dyn()->cb.bind_step(n, st, a);
                } else if cur_kind == 1 {
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
                // the receiver on it and strips it for everything else.
                info->receiver     = dyn()->sc->types->qualified(val, recv_q);
                info->has_receiver = (cur_kind == 0) && (st->access_kind != ChainExpr::AccessKind::ColonColon);
            }

            // -- tuple index --
            if st->is_tuple_index() {
                if (cur_kind != 0) || (val == &null) || (!isa::<TupleType>(val)) {
                    dyn()->fail(n, "tuple index on a non-tuple");
                    return &null;
                }
                var tt = cast::<TupleType>(val);
                if static_cast::<usize>(st->index) >= tt->elements.size() {
                    dyn()->fail(n, f"tuple index {st->index} is out of range for '{dyn()->tu.str(val)}\x27");
                    return &null;
                }
                cur = tt->elements[static_cast::<usize>(st->index)];
                st->resolved_type = cur;
                cur_kind = 0;
                // What the typer has always said (the old blanket default):
                // `t.0 = x` is not assignable today. Making it an lvalue is a
                // tuple-semantics decision, not this one.
                n->value_category = Expr::ValueCategory::RValue;
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
                    dyn()->fail(n, f"no such operator on '{dyn()->tu.str(owner_ty)}\x27");
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
                    var p = cast::<ParamDecl>(d);
                    cur = (p->type_->canonical) if (p->type_ != &null) else (&null);
                    if cur == &null { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                    if p->is_const && (!p->is_self) { cur = dyn()->sc->types->qualified(cur, QUAL_CONST()); }
                    cur_kind = 0; st->resolved_type = cur;
                    n->value_category = Expr::ValueCategory::LValue;
                }
                case DeclKind::EnumVariantDecl {
                    var edc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
                    var ed  = (edc->owner_decl()) if (edc != &null) else (&null);
                    if ed == &null { dyn()->fail(n, "enum variant has no owning enum"); return &null; }
                    var a = vec::<*Type>();
                    cur = dyn()->sc->types->record(NameLookup::representative(ed), &a);
                    if cur_kind == 1 { cur = cur_type; }   // `Foo<i32>::V` keeps the instance
                    cur_kind = 0; st->resolved_type = cur;
                    n->value_category = Expr::ValueCategory::RValue;
                }
                case DeclKind::FunctionDecl {
                    info->callable_cands.clear();
                    info->callable_cands.push_back(d);
                    cur_kind = 3;
                }
                case DeclKind::ModuleDecl { cur_kind = 2; }
                case DeclKind::GenericParamDecl { info->unknown = true; dyn()->mark_unknown(n); return &null; }
                default {
                    if dyn()->tu.is_type_decl(d) {
                        cur_type = dyn()->type_from_type_decl(d, st->generic_args, n);
                        if cur_type == &null { dyn()->poison_only(n); return &null; }
                        cur_kind = 1;
                        st->resolved_type = cur_type;
                    } else {
                        dyn()->fail(n, f"'{dyn()->tu.decl_name(d)}' is not a value");
                        return &null;
                    }
                }
            }
        }

        // -- result ----------------------------------------------------------
        switch cur_kind {
            case 0 {
                if cur == &null { return &null; }
                if saw_optional { return dyn()->sc->types->nullable(dyn()->tu.strip_nullable(cur)); }
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

    fn type_subscript(self, n: *SubscriptExpr, expected: *Type) -> *Type {
        var bt = dyn()->type_of(n->base, &null);
        if dyn()->propagate(n, n->base) { return &null; }
        if bt == &null { return &null; }
        bt = canon_unqual(bt);

        var is_range = (n->index != &null) && isa::<RangeExpr>(dyn()->tu.strip_parens(n->index));
        var usize_t  = dyn()->tu.builtin(BuiltinKind::USize);

        // user `op []`
        if dyn()->tu.kind_of(bt) == BuiltinKind::COUNT {
            var is_container = dyn()->tu.is_vector_like(bt) || dyn()->tu.is_map_like(bt) || dyn()->tu.is_string(bt)
                            || (dyn()->tu.element_of(bt) != &null) || isa::<TupleType>(bt) || (dyn()->tu.pointee(bt) != &null);
            if !is_container {
                var cands = vec::<*Decl>();
                dyn()->ml.lookup(dyn()->tu.strip_nullable(bt), DeclName::op_name(TokenKind::OpLSquare, TokenKind::OpRSquare), &cands);
                if cands.size() == 0 {
                    dyn()->type_of(n->index, &null);
                    dyn()->fail(n, f"'{dyn()->tu.str(bt)}' has no subscript operator");
                    return &null;
                }
                var args = vec::<ArgInfo>();
                args.push_back(dyn()->arg_info(n->index));
                var r = dyn()->ovl.resolve(&cands, &args, true, n->range, "op []",
                                           dyn()->tu.strip_nullable(bt));
                if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
                if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
                // Member-only resolution, so via_free is false here by
                // construction; assigned from r anyway so the two never drift.
                n->resolved_op = r.decl;
                n->op_via_free = r.via_free;
                r.ded.bind_from_record(dyn()->tu.strip_nullable(bt));
                dyn()->finish_call_args(r.decl, &args, &r);
                n->value_category = Expr::ValueCategory::LValue;
                return dyn()->call_result_type(r.decl, &r);
            }
        }

        // builtin shapes
        if isa::<TupleType>(bt) {
            dyn()->type_of(n->index, &null);
            dyn()->fail(n, "tuples are indexed with '.0', '.1', ..., not '[]\x27");
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
            dyn()->fail(n, f"'{dyn()->tu.str(bt)}' cannot be indexed");
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
            dyn()->fail(n->index, f"index must be an integer, not '{dyn()->tu.str(it)}\x27");
            dyn()->poison_only(n);
            return &null;
        }
        n->value_category = Expr::ValueCategory::LValue;
        return elem;
    }
}