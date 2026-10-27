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
import Sema::Type::TypeUtil::*;
import Sema::Check::ConstEval::*;
import AST::Context::DeclContext::*;
import AST::Context::InstantiationRegistry::*;
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
    /// (InstanceEntry::args keeps packs flat, at the tail).
    fn bind_from_record(self, rec: *Type) {
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
                // The effect survives substitution; a `panic` in a generic
                // signature is gated (PANIC.md §2.6), so its set is concrete.
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
                if (!v->is_value) || v->is_exact() { return t; }
                var ops = vec::<*Type>();
                for var i: usize = 0; i < v->vops.size(); ++i {
                    var o = self.substitute(v->vops[i]);
                    if o == &null { return &null; }
                    ops.push_back(o);
                }
                var ce = ConstEval(self.sc);
                return ce.value_node(v->vop, v->vtok, v->vdecl, &ops, v->vty);
            } default { return &null; }
        }
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
                s.bind_from_record(d);
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
