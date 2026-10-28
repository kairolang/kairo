/// --- The Kairo Project ---------------------- Sema/Type/Substitution.k --- ///
///
///   \brief Generic-parameter bindings and their substitution into a type:
///          `Foo<i32>` seeds T := i32, and `[T]` then reads `[i32]`.
///
///   \detail
///     The half of deduction that needs no argument: an instance's own
///     arguments (bind_from_record) say what its pattern's parameters are,
///     and substitute() rewrites a pattern-side canonical with them. A
///     concrete record result goes through the registry, so it IS the
///     instance decl.
///
///     Split out of Deduction so the layer below it can substitute too:
///     Conversion is what Deduction ranks with, so it cannot import
///     Deduction, yet a derived-to-base test between two instances needs
///     the derived instance's bases read through its arguments
///     (derives_from). Deduction derives this class and adds unification.
///
///     Facts only (MONO.md D0): nothing here re-types a body. What an
///     instance means is the pattern's declared data with the arguments
///     substituted in.
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
import Sema::Resolve::MemberLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Check::ConstEval::*;
import AST::Context::DeclContext::*;
import AST::Context::InstantiationRegistry::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::TypeKind::*;
import AST::ParamMode::*;

class DeducedBinding {
    pub var owner: *Decl = &null;
    pub var index: u32   = 0;
    pub var ty:    *Type = &null;
    fn DeducedBinding(self) { }
}

class Substitution {
    pub var sc:       *SemaContext;
    pub var tu:       TypeUtil;
    pub var bindings: vec::<DeducedBinding>;
    /// Type packs: one `ty == null` row OPENS a pack (owner, index) -- it is
    /// bound, possibly to nothing -- and each later row with a type is one
    /// element, in argument order. A pack is one parameter with many types,
    /// which `bindings` (one type per parameter) cannot hold.
    pub var packs: vec::<DeducedBinding>;

    fn Substitution(self) { self.sc = &null; }
    fn Substitution(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
    }

    fn lookup(self, owner: *Decl, index: u32) -> *Type {
        for var i: usize = 0; i < self.bindings.size(); ++i {
            var b = &(self.bindings[i]);
            if (b->owner == owner) && (b->index == index) { return b->ty; }
        }
        return &null;
    }

    /// False on a conflicting rebind.
    fn bind(self, owner: *Decl, index: u32, ty: *Type) -> bool {
        if ty == &null { return false; }
        var prev = self.lookup(owner, index);
        if prev != &null { return prev == ty; }
        var b = DeducedBinding{};
        b.owner = owner; b.index = index; b.ty = ty;
        self.bindings.push_back(b);
        return true;
    }

    /// Bind \p from's generic parameters to \p to's, position by position,
    /// so substitute() reads a type written over \p from's parameters as one
    /// over \p to's: two same-shape generic declarations compared up to the
    /// names of their parameters (a generic `where` group, MONO.md G12).
    /// False when the lists differ in length or a position differs in kind
    /// (`: class` against none, a value parameter, a pack: none of those is
    /// compared, so none is alpha-equal).
    fn bind_alpha(self, to: *Decl, from: *Decl) -> bool {
        var tp = decl_generic_params(to);
        var fp = decl_generic_params(from);
        if (tp.size() == 0) || (tp.size() != fp.size()) { return false; }
        var tr = NameLookup::representative(to);
        var fr = NameLookup::representative(from);
        for var i: usize = 0; i < tp.size(); ++i {
            var a = tp[i];
            var b = fp[i];
            if (a == &null) || (b == &null) { return false; }
            if a->is_pack || b->is_pack || a->is_const_param || b->is_const_param { return false; }
            if a->kind_bound != b->kind_bound { return false; }
            if !self.bind(fr, u32(i), self.sc->types->generic_param(tr, u32(i), false)) { return false; }
        }
        return true;
    }

    /// bind_alpha for two declarations of ONE generic function (a forward
    /// declaration and its definition, RedeclMerge): the same, plus value
    /// parameters, which are alpha-equal when their declared types are one
    /// canonical (`<eval N: usize>` against `<eval M: usize>`). Each decl's
    /// parameters are keyed on the DECL ITSELF, not its representative: T
    /// built them before R linked anything, when every function was its own
    /// representative, and a chain linked since would point elsewhere.
    /// Packs still answer false. Bounds are not compared: a disagreement
    /// there is the caller's error, not a different entity.
    fn bind_redecl(self, to: *Decl, from: *Decl) -> bool {
        var tp = decl_generic_params(to);
        var fp = decl_generic_params(from);
        if (tp.size() == 0) || (tp.size() != fp.size()) { return false; }
        for var i: usize = 0; i < tp.size(); ++i {
            var a = tp[i];
            var b = fp[i];
            if (a == &null) || (b == &null) { return false; }
            if a->is_pack || b->is_pack { return false; }
            if a->is_const_param != b->is_const_param { return false; }
            if a->kind_bound != b->kind_bound { return false; }
            if a->is_const_param {
                if (a->value_type == &null) || (b->value_type == &null) { return false; }
                var va = a->value_type->canonical;
                var vb = b->value_type->canonical;
                if (va == &null) || (vb == &null) || (canon_unqual(va) != canon_unqual(vb)) { return false; }
            }
            if !self.bind(from, u32(i), self.sc->types->generic_param(to, u32(i), false)) { return false; }
        }
        return true;
    }

    /// Open the type pack (owner, index): it is bound from here on, to the
    /// elements push_pack adds (none is an empty pack).
    fn open_pack(self, owner: *Decl, index: u32) {
        if self.pack_open(owner, index) { return; }
        var b = DeducedBinding{};
        b.owner = owner; b.index = index; b.ty = &null;
        self.packs.push_back(b);
    }

    fn pack_open(self, owner: *Decl, index: u32) -> bool {
        for var i: usize = 0; i < self.packs.size(); ++i {
            var b = &(self.packs[i]);
            if (b->owner == owner) && (b->index == index) && (b->ty == &null) { return true; }
        }
        return false;
    }

    /// One more element of the open pack (owner, index).
    fn push_pack(self, owner: *Decl, index: u32, ty: *Type) {
        if ty == &null { return; }
        self.open_pack(owner, index);
        var b = DeducedBinding{};
        b.owner = owner; b.index = index; b.ty = ty;
        self.packs.push_back(b);
    }

    /// The elements of pack (owner, index), appended to \p out in order;
    /// false when the pack was never opened.
    fn pack_elems(self, owner: *Decl, index: u32, out: *vec::<*Type>) -> bool {
        if !self.pack_open(owner, index) { return false; }
        for var i: usize = 0; i < self.packs.size(); ++i {
            var b = &(self.packs[i]);
            if (b->owner == owner) && (b->index == index) && (b->ty != &null) { out->push_back(b->ty); }
        }
        return true;
    }

    /// Seed from an instance: `Foo<i32>` binds Foo's params positionally,
    /// and a pack parameter takes every argument from its position on
    /// (InstanceEntry::args keeps packs flat, at the tail). Its bases'
    /// parameters too, as the instance sees them: a member a generic BASE
    /// declares (`class Seven derives Mixin<Seven>`, Mixin's `fn me(self)
    /// -> *X`) reads through the receiver as X := Seven, where it used to
    /// stay X and reach codegen unbound. Bindings are keyed by the declaring
    /// pattern, so a base's never collide with the record's own; the same
    /// template reached twice at different arguments keeps the first (C++
    /// finds such a member ambiguous anyway).
    fn bind_from_record(self, rec: *Type) {
        self.bind_own(rec);
        self._bind_bases(rec, 0);
    }

    /// \p rec's own parameters only (bind_from_record without the bases).
    fn bind_own(self, rec: *Type) {
        var d = self.tu.record_decl(rec);
        if d == &null { return; }
        var pat  = NameLookup::representative(self.tu.pattern_of(d));
        var args = self.tu.record_args(rec);
        var gps  = self.tu.generic_params_of(pat);
        for var i: usize = 0; i < args.size(); ++i {
            if (i < gps.size()) && (gps[i] != &null) && gps[i]->is_pack {
                self.open_pack(pat, gps[i]->index);
                for var k: usize = i; k < args.size(); ++k { self.push_pack(pat, gps[i]->index, args[k]); }
                break;
            }
            self.bind(pat, static_cast::<u32>(i), args[i]);
        }
        if (args.size() < gps.size()) && (gps[args.size()] != &null) && gps[args.size()]->is_pack {
            self.open_pack(pat, gps[args.size()]->index);   // `R<i32>` of `<T, ...E>`: E is empty.
        }
        // A member of a partial specialization is typed over the PARTIAL's
        // parameters, which the args above do not bind: `Store<*i32>` is
        // T := *i32 for the primary but P := i32 for `<P> Store<*P>`.
        var pargs = vec::<*Type>();
        var part = self.sc->record_partial(rec, &pargs);
        if part != &null {
            for var i: usize = 0; i < pargs.size(); ++i { self.bind(part, static_cast::<u32>(i), pargs[i]); }
        }
    }

    /// Every generic base of record \p rec, read through \p rec's arguments
    /// hop by hop (derives_from's walk), binds its pattern's parameters.
    priv fn _bind_bases(self, rec: *Type, depth: u32) {
        if depth > 32 { return; }
        var r = canon_unqual(rec);
        if (r == &null) || (!isa::<RecordType>(r)) { return; }
        var body = self.sc->record_body(r);
        if body == &null { return; }
        var bases = self._bases_of(NameLookup::representative(body));
        for var i: usize = 0; i < bases.size(); ++i {
            var e = bases.get(i);
            if (e == &null) || (e->base == &null) { continue; }
            var c = canon_unqual(e->base->canonical);
            if (c == &null) || (!isa::<RecordType>(c)) { continue; }
            if c->is_dependent() {
                var s = Substitution(self.sc);
                s.bind_own(r);
                var sub = s.substitute(c);
                if (sub != &null) && isa::<RecordType>(canon_unqual(sub)) { c = canon_unqual(sub); }
            }
            if self.tu.record_args(c).size() > 0 { self.bind_own(c); }
            self._bind_bases(c, depth + 1);
        }
    }

    // === substitute =========================================================

    /// \p t with every bound generic param replaced. Null when a param is
    /// still unbound or a component is not canonical. A concrete record
    /// result goes through the registry so `Foo<i32>` is the instance decl.
    fn substitute(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        if !t->is_dependent() { return t; }

        switch t->kind {
            case TypeKind::GenericParamType {
                var g = cast::<GenericParamType>(t);
                var b = self.lookup(g->owner, g->param_index);
                return b;   // null = unbound, stays dependent for the caller to notice.
            } case TypeKind::PointerType {
                var p = self.substitute(cast::<PointerType>(t)->pointee);
                if p == &null { return &null; }
                return self.sc->types->pointer(p, cast::<PointerType>(t)->is_unsafe);
            } case TypeKind::NullableType {
                var i = self.substitute(cast::<NullableType>(t)->inner);
                if i == &null { return &null; }
                return self.sc->types->nullable(i);
            } case TypeKind::VectorType {
                var e = self.substitute(cast::<VectorType>(t)->element);
                if e == &null { return &null; }
                // null when the lang item is unbound: a poisoned component,
                // which reads here as no-match, exactly like any other.
                return self.tu.vector_of(e);
            } case TypeKind::SetType {
                var e = self.substitute(cast::<SetType>(t)->element);
                if e == &null { return &null; }
                return self.tu.set_of(e);
            } case TypeKind::MapType {
                var k = self.substitute(cast::<MapType>(t)->key);
                var v = self.substitute(cast::<MapType>(t)->value);
                if (k == &null) || (v == &null) { return &null; }
                return self.tu.map_of(k, v);
            } case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(t);
                var e = self.substitute(a->element);
                if e == &null { return &null; }
                // `[T; N]` for a value parameter N: its value is the extent
                // (EVAL.md 3); still a parameter, still dependent.
                if a->extent_param != &null {
                    var x = self.substitute(a->extent_param);
                    if x == &null { return &null; }
                    var v = dyn_cast::<TypeExpr>(x);
                    if (v != &null) && v->is_exact() && (!v->vneg) { return self.sc->types->array(e, v->vmag); }
                    // Still a parameter, or an expression C++ computes
                    // (EVAL.md 0.2): the extent stays that node.
                    if isa::<GenericParamType>(x) || ((v != &null) && v->is_value && (!v->is_exact())) { return self.sc->types->array_of_param(e, x); }
                    return &null;
                }
                return self.sc->types->array(e, static_cast::<u64>(a->size_bits));
            } case TypeKind::FunctionPointerType {
                var f = cast::<FunctionPointerType>(t);
                var ps = vec::<*Type>();
                var ms = vec::<ParamMode>();
                for var i: usize = 0; i < f->params.size(); ++i {
                    var p = self.substitute(f->params[i]);
                    if p == &null { return &null; }
                    ps.push_back(p);
                    ms.push_back(f->modes[i]);      // modes survive substitution unchanged.
                }
                var r: *Type = &null;
                if f->return_type != &null {
                    r = self.substitute(f->return_type);
                    if r == &null { return &null; }
                }
                // The effect survives substitution; a `fn` type whose set
                // names a generic parameter is gated (PanicEffectChecking,
                // past P10 too), so its set is concrete.
                var pset = vec::<*Type>();
                for var i: usize = 0; i < f->panic_set.size(); ++i { pset.push_back(f->panic_set[i]); }
                return self.sc->types->func(&ps, &ms, r, f->canon_panics, &pset);
            } case TypeKind::QualifiedType {
                var q = cast::<QualifiedType>(t);
                var i = self.substitute(q->inner);
                if i == &null { return &null; }
                return self.sc->types->qualified(i, q->quals);
            } case TypeKind::RecordType {
                var r = cast::<RecordType>(t);
                var args = vec::<*Type>();
                var dep  = false;
                for var i: usize = 0; i < r->args.size(); ++i {
                    // `R<i32, E...>`: a pack argument is its expansion, so a
                    // bound pack splices its elements in, none included.
                    var pg = dyn_cast::<GenericParamType>(r->args[i]);
                    if (pg != &null) && pg->is_pack {
                        var els = vec::<*Type>();
                        if !self.pack_elems(pg->owner, pg->param_index, &els) { return &null; }
                        for var k: usize = 0; k < els.size(); ++k {
                            if els[k]->is_dependent() { dep = true; }
                            args.push_back(els[k]);
                        }
                        continue;
                    }
                    var a = self.substitute(r->args[i]);
                    if a == &null { return &null; }
                    if a->is_dependent() { dep = true; }
                    args.push_back(a);
                }
                var primary = NameLookup::representative(self.tu.pattern_of(r->decl));
                if dep || (args.size() == 0) { return self.sc->types->record(primary, &args); }
                var e = self.sc->instances->instance_for(primary, &args, self.sc->ctx->fid,
                                                         NameLookup::ctx_of(primary));
                var inst = (e->decl) if (e != &null) else (primary);
                return self.sc->types->record(inst, &args);
            } case TypeKind::TypeExpr {
                // A computed value (EVAL.md 0.2): its operands substituted,
                // then folded when they all became values (`N + 1` under
                // N := 3 is 4), so an instance's extent is the number.
                var v = cast::<TypeExpr>(t);
                if (!v->is_value) || v->is_exact() || (v->vop == ValueOp::Str) { return t; }   // a string is a leaf.
                var ops = vec::<*Type>();
                for var i: usize = 0; i < v->vops.size(); ++i {
                    var o = self.substitute(v->vops[i]);
                    if o == &null { return &null; }
                    ops.push_back(o);
                }
                var ce = ConstEval(self.sc);
                return ce.value_node(v->vop, v->vtok, v->vdecl, &ops, v->vty);
            } case TypeKind::AssocType {
                // `T::Node` under T := C is C's Node: the instance fact,
                // computed from the conformer's declared alias (MONO.md D0),
                // never by looking at a body.
                var a = cast::<AssocType>(t);
                var b = a->base;
                if b->is_dependent() { b = self.substitute(b); }
                if b == &null { return &null; }
                var i = a->iface;
                if i->is_dependent() { i = self.substitute(i); }
                if i == &null { return &null; }
                if (b == a->base) && (i == a->iface) { return t; }
                return self.assoc_witness(b, i, a->assoc);
            } default { return &null; }
        }
    }

    /// \p own: `I<T...>` over I's OWN parameters is Self too. That is what
    /// `Self` (and `self`) canonicalizes to in a GENERIC interface
    /// (TypeResolve::_self_record), so a member read through its receiver
    /// needs it; a caller comparing already-substituted signatures does not
    /// ask, because there the spelling is an instance like any other.
    fn replace_self(self, t: *Type, iface: *Decl, with: *Type, own: bool = false) -> *Type {
        if (t == &null) || (iface == &null) || (with == &null) { return t; }
        var rep = NameLookup::representative(iface);
        switch t->kind {
            case TypeKind::RecordType {
                var r = cast::<RecordType>(t);
                if NameLookup::representative(self.tu.pattern_of(r->decl)) == rep {
                    if r->args.size() == 0 { return with; }
                    if own && self.own_args(r, rep) { return with; }
                }
                var args    = vec::<*Type>();
                var changed = false;
                for var i: usize = 0; i < r->args.size(); ++i {
                    var a = self.replace_self(r->args[i], iface, with, own);
                    if a != r->args[i] { changed = true; }
                    args.push_back(a);
                }
                if !changed { return t; }
                // Concrete now (`(Self::Index, Self::Index)` read for a
                // conformer): the registry instance, as substitute() makes,
                // or it would not be the type the conformer spelled.
                var dep = false;
                for var i: usize = 0; i < args.size(); ++i { if args[i]->is_dependent() { dep = true; } }
                if dep { return self.sc->types->record(r->decl, &args); }
                var primary = NameLookup::representative(self.tu.pattern_of(r->decl));
                var e = self.sc->instances->instance_for(primary, &args, self.sc->ctx->fid, NameLookup::ctx_of(primary));
                var inst = (e->decl) if (e != &null) else (primary);
                return self.sc->types->record(inst, &args);
            } case TypeKind::PointerType {
                var p = cast::<PointerType>(t);
                var i = self.replace_self(p->pointee, iface, with, own);
                return (t) if (i == p->pointee) else (self.sc->types->pointer(i, p->is_unsafe));
            } case TypeKind::NullableType {
                var nt = cast::<NullableType>(t);
                var i  = self.replace_self(nt->inner, iface, with, own);
                return (t) if (i == nt->inner) else (self.sc->types->nullable(i));
            } case TypeKind::VectorType {
                var vt = cast::<VectorType>(t);
                var i  = self.replace_self(vt->element, iface, with, own);
                return (t) if (i == vt->element) else (self.tu.vector_of(i));
            } case TypeKind::SetType {
                var st = cast::<SetType>(t);
                var i  = self.replace_self(st->element, iface, with, own);
                return (t) if (i == st->element) else (self.tu.set_of(i));
            } case TypeKind::MapType {
                var mt = cast::<MapType>(t);
                var k  = self.replace_self(mt->key, iface, with, own);
                var v  = self.replace_self(mt->value, iface, with, own);
                if (k == mt->key) && (v == mt->value) { return t; }
                return self.tu.map_of(k, v);
            } case TypeKind::QualifiedType {
                  var q = cast::<QualifiedType>(t);
                  var i = self.replace_self(q->inner, iface, with, own);
                  return (t) if (i == q->inner) else (self.sc->types->qualified(i, q->quals));
            } case TypeKind::FunctionPointerType {
                var f       = cast::<FunctionPointerType>(t);
                var ps      = vec::<*Type>();
                var ms      = vec::<ParamMode>();
                var changed = false;
                for var i: usize = 0; i < f->params.size(); ++i {
                    var p = self.replace_self(f->params[i], iface, with, own);
                    if p != f->params[i] { changed = true; }
                    ps.push_back(p);
                    ms.push_back(f->modes[i]);
                }
                var r: *Type = &null;
                if f->return_type != &null {
                    r = self.replace_self(f->return_type, iface, with, own);
                    if r != f->return_type { changed = true; }
                }
                var pset = vec::<*Type>();
                for var i: usize = 0; i < f->panic_set.size(); ++i { pset.push_back(f->panic_set[i]); }
                return (t) if (!changed) else (self.sc->types->func(&ps, &ms, r, f->canon_panics, &pset));
            } case TypeKind::AssocType {
                // `Self::Node` read through a receiver: only the BASE is
                // Self (the interface instance stays the interface), and once
                // it is a conformer the type is that conformer's alias. A
                // conformer that supplies none leaves the requirement's
                // spelling: its conformance is what fails, and reports.
                var a = cast::<AssocType>(t);
                var b = self.replace_self(a->base, iface, with, own);
                if b == a->base { return t; }
                var w = self.assoc_witness(b, a->iface, a->assoc);
                return (w) if (w != &null) else (t);
            } default { return t; }
        }
    }

    /// \p r's arguments are exactly \p rep's own parameters, in order: the
    /// type \p rep's body denotes itself by, not an instance of it.
    fn own_args(self, r: *RecordType, rep: *Decl) -> bool {
        var gps = decl_generic_params(rep);
        if gps.size() != r->args.size() { return false; }
        for var i: usize = 0; i < r->args.size(); ++i {
            var g = dyn_cast::<GenericParamType>(canon_unqual(r->args[i]));
            if (g == &null) || (g->param_index != static_cast::<u32>(i)) { return false; }
            if NameLookup::representative(g->owner) != rep { return false; }
        }
        return true;
    }


    // === associated types ===================================================

    /// What associated type \p assoc, named through interface instance
    /// \p iface, IS for \p x. Still abstract -- an AssocType -- while \p x
    /// is (a generic parameter, another associated type, an interface's own
    /// Self). For a conformer: its own alias of that name (a member,
    /// inherited or added by an extension), read through its arguments;
    /// else, when it conforms EXPLICITLY, the requirement's default with
    /// Self := \p x. Structural conformance never takes a default
    /// (interfaces.md, Defaults). Null when \p x supplies neither:
    /// ConformanceChecking reports that, and a use reads as unknown.
    ///
    /// THE one rule. The conformance match (`-> Self::Node` against
    /// `-> i64`), a call result through a bound, and an instance's
    /// `T::Node := S` all come out of this function, so they cannot drift.
    fn assoc_witness(self, x_in: *Type, iface: *Type, assoc: *Decl) -> *Type {
        var x = canon_unqual(x_in);
        if (x == &null) || (iface == &null) || (assoc == &null) { return &null; }
        var req = NameLookup::representative(assoc);
        var xd  = self.tu.record_decl(x);
        var xpat: *Decl = (NameLookup::representative(self.tu.pattern_of(xd))) if (xd != &null) else (&null);
        if isa::<GenericParamType>(x) || isa::<AssocType>(x) || ((xpat != &null) && isa::<InterfaceDecl>(xpat)) {
            return self.sc->types->assoc(x, iface, req);
        }

        var nm = self.tu.decl_name(req);
        var imms = self.sc->ctx->get_imm_table();
        var ml = MemberLookup(self.sc);
        ml.index_extensions();
        var cands = vec::<*Decl>();
        ml.lookup(x, DeclName::ident(imms->intern_ident_copy(nm)), &cands);
        for var i: usize = 0; i < cands.size(); ++i {
            var ta = dyn_cast::<TypeAliasDecl>(cands[i]);
            if (ta == &null) || ta->is_associated || ta->is_poisoned() { continue; }
            if ta->generic_params.size() > 0 { continue; }   // a generic alias is not the requirement (SC116E at its use).
            if (ta->aliased == &null) || (ta->aliased->canonical == &null) { continue; }
            var c = ta->aliased->canonical;
            if c->is_dependent() && isa::<RecordType>(x) {
                // `class <T> Box impl Graph { type Node = T }` reached as
                // Box<i32>: the alias through the instance's arguments.
                var s = Substitution(self.sc);
                s.bind_from_record(x);
                var r = s.substitute(c);
                if r != &null { c = r; }
            }
            return c;
        }

        // The default: explicit conformance only.
        var td = dyn_cast::<TypeAliasDecl>(req);
        if (td == &null) || (td->aliased == &null) || (td->aliased->canonical == &null) { return &null; }
        if !self.conforms_explicitly(x, iface, &ml) { return &null; }
        var d = td->aliased->canonical;
        if !d->is_dependent() { return d; }
        var home: *Decl = &null;
        if td->semantic_dc != &null { home = reinterpret_cast::<*DeclContext>(td->semantic_dc)->owner_decl(); }
        if home == &null { return &null; }
        home = NameLookup::representative(home);
        var s = Substitution(self.sc);
        // Self first, as _as_conformer does: in a generic interface Self is
        // `I<V>` over its own parameters, which the substitution below
        // would turn into an instance that no longer reads as Self.
        d = s.replace_self(d, home, x, true);
        if d->is_dependent() {
            var idecl = self.tu.record_decl(iface);
            if (idecl != &null) && (NameLookup::representative(self.tu.pattern_of(idecl)) == home) { s.bind_from_record(iface); }
            var r = s.substitute(d);
            if r != &null { d = r; }
        }
        return d;
    }

    /// \p x declares that it conforms to \p iface (or to an interface
    /// deriving it): `impl` on its declaration, or an `extend x impl`. A
    /// conformance only found structurally at a use is not one.
    fn conforms_explicitly(self, x: *Type, iface: *Type, ml: *MemberLookup) -> bool {
        var idecl = self.tu.record_decl(iface);
        if idecl == &null { return false; }
        var want = NameLookup::representative(self.tu.pattern_of(idecl));
        var xd = self.tu.record_decl(x);
        if xd != &null {
            var pat = NameLookup::representative(self.tu.pattern_of(xd));
            if self._impl_list_reaches(pat, want) { return true; }
            var body = self.sc->record_body(x);
            if (body != &null) && (NameLookup::representative(body) != pat) && self._impl_list_reaches(NameLookup::representative(body), want) { return true; }
            var exts = ml->extensions_of_decl(pat);
            if exts != &null {
                for var i: usize = 0; i < exts->size(); ++i {
                    if self._edges_reach(&((*exts)[i]->implements), want) { return true; }
                }
            }
            return false;
        }
        var texts = ml->extensions_of_type(canon_unqual(x));
        if texts != &null {
            for var i: usize = 0; i < texts->size(); ++i {
                if self._edges_reach(&((*texts)[i]->implements), want) { return true; }
            }
        }
        return false;
    }

    priv fn _impl_list_reaches(self, d: *Decl, want: *Decl) -> bool {
        if isa::<ClassDecl>(d)  { return self._edges_reach(&(cast::<ClassDecl>(d)->implements), want); }
        if isa::<StructDecl>(d) { return self._edges_reach(&(cast::<StructDecl>(d)->implements), want); }
        return false;
    }

    priv fn _edges_reach(self, edges: *FrozenList::<InheritEdge>, want: *Decl) -> bool {
        for var i: usize = 0; i < edges->size(); ++i {
            var e = edges->get(i);
            if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
            if self._iface_reaches(canon_unqual(e->base->canonical), want, 0) { return true; }
        }
        return false;
    }

    /// Interface type \p t is \p want or derives it.
    priv fn _iface_reaches(self, t: *Type, want: *Decl, depth: u32) -> bool {
        if depth > 32 { return false; }
        var d = self.tu.record_decl(t);
        if d == &null { return false; }
        var id = dyn_cast::<InterfaceDecl>(NameLookup::representative(self.tu.pattern_of(d)));
        if id == &null { return false; }
        if static_cast::<*Decl>(id) == want { return true; }
        for var i: usize = 0; i < id->derives_list.size(); ++i {
            var e = id->derives_list.get(i);
            if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
            if self._iface_reaches(canon_unqual(e->base->canonical), want, depth + 1) { return true; }
        }
        return false;
    }

    /// Member type \p mt as seen through receiver \p recv (`Foo<i32>`'s
    /// field `var x: T` reads as i32). Non-dependent members pass through.
    fn member_through(self, recv: *Type, mt: *Type) -> *Type {
        if mt == &null { return &null; }
        if !mt->is_dependent() { return mt; }
        self.bind_from_record(recv);
        var s = self.substitute(mt);
        return (s) if (s != &null) else (mt);
    }

    // === derived-to-base ====================================================

    /// True when record type \p derived is \p base or reaches it through
    /// `derives` edges. Types, not decls: an instance's bases are its
    /// pattern's declared list READ THROUGH ITS ARGUMENTS, so `Const<i32>`
    /// of `class <T> Const derives Source<T>` reaches `Source<i32>` and not
    /// `Source<f64>`. Walked on decls, both were "Source" at best, and the
    /// instance's own shell has no bases at all (never filled), so the
    /// upcast was rejected outright.
    fn derives_from(self, derived: *Type, base: *Type) -> bool {
        var d = canon_unqual(derived);
        var b = canon_unqual(base);
        if (d == &null) || (b == &null) || (!isa::<RecordType>(d)) || (!isa::<RecordType>(b)) { return false; }
        var seen = vec::<*Type>();
        return self._derives_walk(d, b, &seen, 0);
    }

    /// One record: same entity and, for a pattern used dependently, the same
    /// arguments. An instance decl already IS its arguments.
    priv fn _same_record(self, a: *Type, b: *Type) -> bool {
        if a == b { return true; }
        var ra = cast::<RecordType>(a);
        var rb = cast::<RecordType>(b);
        if NameLookup::representative(ra->decl) != NameLookup::representative(rb->decl) { return false; }
        if ra->args.size() != rb->args.size() { return false; }
        for var i: usize = 0; i < ra->args.size(); ++i {
            if canon_unqual(ra->args[i]) != canon_unqual(rb->args[i]) { return false; }
        }
        return true;
    }

    priv fn _derives_walk(self, d: *Type, b: *Type, seen: *vec::<*Type>, depth: u32) -> bool {
        if self._same_record(d, b) { return true; }
        if depth > 64 { return false; }
        for var i: usize = 0; i < seen->size(); ++i { if self._same_record((*seen)[i], d) { return false; } }
        seen->push_back(d);
        // The decl whose list applies: a filled (imported) instance's own, an
        // explicit spec's own, else the selected partial's or the pattern's.
        var body = self.sc->record_body(d);
        if body == &null { return false; }
        var bases = self._bases_of(NameLookup::representative(body));
        for var i: usize = 0; i < bases.size(); ++i {
            var e = bases.get(i);
            if (e == &null) || (e->base == &null) { continue; }
            var c = canon_unqual(e->base->canonical);
            if (c == &null) || (!isa::<RecordType>(c)) { continue; }
            if c->is_dependent() {
                // Fresh bindings per hop: each base is read through the
                // record it is a base OF. A parameter nothing binds (a nested
                // record's enclosing one) leaves the base as written, which
                // still names the right entity.
                var s = Substitution(self.sc);
                s.bind_own(d);
                var sub = s.substitute(c);
                if (sub != &null) && isa::<RecordType>(canon_unqual(sub)) { c = canon_unqual(sub); }
            }
            if self._derives_walk(c, b, seen, depth + 1) { return true; }
        }
        return false;
    }

    priv fn _bases_of(self, d: *Decl) -> FrozenList::<InheritEdge> {
        if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->derives_list;     }
        if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->derives_list; }
        return create_empty_frozen_list::<InheritEdge>();
    }
}
