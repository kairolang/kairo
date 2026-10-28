/// --- The Kairo Project ------------------------ Sema/Type/TypeUtil.k --- ///
///
///   \brief Read-only queries over canonical types and decls that every typer
///          mixin needs and that belong to none of them. A component held by
///          value on ExprTyper; no state beyond the SemaContext handle.
///
///   Nothing here diagnoses, allocates, or writes a slot.
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
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::CanonicalTypes::*;
import AST::Context::SymbolTable::*;
import AST::Mixin::TypeQual::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Kind::ExprKind::*;
import AST::ParamMode::*;
import Token::TokenKind::*;

/// The pointer levels of a canonical type (TypeUtil::pointer_shape): how
/// many, whether the outermost is `unsafe`, and what is under the last.
struct PointerShape {
    var depth:        u32   = 0;
    var outer_unsafe: bool  = false;
    var leaf:         *Type = &null;
}

class TypeUtil {
    pub var sc: *SemaContext;

    fn TypeUtil(self) { self.sc = &null; }
    fn TypeUtil(self, sc: *SemaContext) { self.sc = sc; }

    // === builtins ===========================================================

    fn builtin(self, b: BuiltinKind) -> *Type { return self.sc->builtin(b); }

    /// COUNT when \p t is not a builtin.
    fn kind_of(self, t: *Type) -> BuiltinKind {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<BuiltinType>(u)) { return BuiltinKind::COUNT; }
        return cast::<BuiltinType>(u)->builtin;
    }

    fn is_builtin(self, t: *Type, b: BuiltinKind) -> bool { return self.kind_of(t) == b; }
    fn is_void(self, t: *Type)  -> bool { return self.is_builtin(t, BuiltinKind::Void);  }
    fn is_bool(self, t: *Type)  -> bool { return self.is_builtin(t, BuiltinKind::Bool);  }
    fn is_never(self, t: *Type) -> bool { return self.is_builtin(t, BuiltinKind::Never); }

    fn is_integer(self, t: *Type) -> bool {
        var k = self.kind_of(t);
        if k == BuiltinKind::COUNT { return false; }
        return builtin_info(k)->is_integer();
    }

    fn is_float(self, t: *Type) -> bool {
        var k = self.kind_of(t);
        if k == BuiltinKind::COUNT { return false; }
        return builtin_info(k)->is_float();
    }

    fn is_numeric(self, t: *Type) -> bool { return self.is_integer(t) || self.is_float(t); }

    fn is_signed_int(self, t: *Type) -> bool {
        var k = self.kind_of(t);
        if k == BuiltinKind::COUNT { return false; }
        return builtin_info(k)->is_integer() && builtin_info(k)->is_signed();
    }

    /// Width of an integer builtin, target width for usize/isize, 0 otherwise.
    fn int_bits(self, t: *Type) -> usize {
        if !self.is_integer(t) { return 0; }
        return t->size_bits;
    }

    // === structural shapes ==================================================
    //
    // Cv is not shape. Every query here answers for the unqualified type; a
    // caller that wants the qualifier asks quals().

    fn pointee(self, t: *Type) -> *Type {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<PointerType>(u)) { return &null; }
        return cast::<PointerType>(u)->pointee;
    }

    /// Requires PointerType::is_unsafe on canonical nodes (see spec).
    fn is_unsafe_ptr(self, t: *Type) -> bool {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<PointerType>(u)) { return false; }
        return cast::<PointerType>(u)->is_unsafe;
    }

    fn nullable_inner(self, t: *Type) -> *Type {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<NullableType>(u)) { return &null; }
        return cast::<NullableType>(u)->inner;
    }

    /// `T?` -> `T`, `T` -> `T`.
    fn strip_nullable(self, t: *Type) -> *Type {
        var i = self.nullable_inner(t);
        return (i) if (i != &null) else (t);
    }

    /// \p t's pointer levels, each pointee read canonical and unqualified:
    /// `unsafe **i32` is {2, true, i32}, a non-pointer {0, false, \p t}. What
    /// a pointer shorthand (`var *y = e`, NULLABLE.md 1.7) states, so its
    /// check and its lint count the same stars.
    fn pointer_shape(self, t: *Type) -> PointerShape {
        var out = PointerShape{};
        var p = t;
        while (p != &null) && isa::<PointerType>(p) {
            if out.depth == 0 { out.outer_unsafe = cast::<PointerType>(p)->is_unsafe; }
            out.depth += 1;
            p = canon_unqual(cast::<PointerType>(p)->pointee);
        }
        out.leaf = p;
        return out;
    }

    /// Whether `a === b` compares POINTEES (NULLABLE.md 2.3): when a
    /// nullable operand holds a pointer, `==` would compare addresses, and
    /// `===` goes one level down. Asked by OperatorTyping, which types the
    /// compare, and CoalesceLowering, which builds it: one rule for both.
    fn identity_derefs(self, a: *Type, b: *Type) -> bool {
        var an = self.nullable_inner(self.as_value(a));
        var bn = self.nullable_inner(self.as_value(b));
        if (an != &null) && (self.pointee(an) != &null) { return true; }
        return (bn != &null) && (self.pointee(bn) != &null);
    }

    /// A type read as a VALUE: a C++ reference is its referee ([expr.type]/1,
    /// the lvalue-to-rvalue read), and top-level cv is gone. What every
    /// operator classification wants; Conversion::implicit already does the
    /// same on its own path.
    fn as_value(self, t: *Type) -> *Type {
        var u = t;
        if u == &null { return &null; }
        if isa::<CXXLValueRefType>(u)      { u = cast::<CXXLValueRefType>(u)->referee; }
        else if isa::<CXXRValueRefType>(u) { u = cast::<CXXRValueRefType>(u)->referee; }
        return canon_unqual(u);
    }

    fn record_decl(self, t: *Type) -> *Decl {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<RecordType>(u)) { return &null; }
        return cast::<RecordType>(u)->decl;
    }

    /// The interfaces a bounded generic parameter \p t promises, as their
    /// canonical instances (`T impl Same`, `T impl Container<U>`), or none
    /// when \p t is not a bare parameter or has no interface bound. Here and
    /// not in a typer because overload resolution needs it too: a call
    /// through the bound reads the requirement at the bound's arguments.
    fn bound_ifaces(self, t: *Type) -> vec::<*Type> {
        var out = vec::<*Type>();
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<GenericParamType>(c)) { return out; }
        var g = cast::<GenericParamType>(c);
        var it = self.sc->bounds.find(reinterpret_cast::<u64>(g->owner));
        if it == self.sc->bounds.end() { return out; }
        var _set = &(it->second);
        for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
            var k = _set->impl_constraints[i];
            var id = dyn_cast::<NamedIdentExpr>(k->lhs);
            if id == &null { continue; }
            var gp = dyn_cast::<GenericParamDecl>(id->resolved_decl);
            if (gp == &null) || (gp->index != g->param_index) { continue; }
            if NameLookup::representative(gp->owner) != NameLookup::representative(g->owner) { continue; }
            if (k->rhs == &null) || (k->rhs->canonical == &null) { continue; }
            out.push_back(canon_unqual(k->rhs->canonical));
        }
        return out;
    }

    /// The bases a generic parameter \p t's `derives` bounds promise
    /// (`X derives Mixin<X>`), as canonicals, in clause order; none when
    /// \p t is not a bare parameter. bound_ifaces' twin over the other half
    /// of the bound table: what lets a CRTP base cast itself down to X.
    fn bound_bases(self, t: *Type) -> vec::<*Type> {
        var out = vec::<*Type>();
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<GenericParamType>(c)) { return out; }
        var g = cast::<GenericParamType>(c);
        var it = self.sc->bounds.find(reinterpret_cast::<u64>(g->owner));
        if it == self.sc->bounds.end() { return out; }
        var _set = &(it->second);
        for var i: usize = 0; i < _set->derives_constraints.size(); ++i {
            var k = _set->derives_constraints[i];
            var id = dyn_cast::<NamedIdentExpr>(k->lhs);
            if id == &null { continue; }
            var gp = dyn_cast::<GenericParamDecl>(id->resolved_decl);
            if (gp == &null) || (gp->index != g->param_index) { continue; }
            if NameLookup::representative(gp->owner) != NameLookup::representative(g->owner) { continue; }
            if (k->rhs == &null) || (k->rhs->canonical == &null) { continue; }
            out.push_back(canon_unqual(k->rhs->canonical));
        }
        return out;
    }

    /// The declaration of \p t when it is a generic parameter whose body is
    /// checked against its bounds (MONO.md D0): a bare, non-pack parameter,
    /// no `: type` (the C++-checked regime, D1), and no `derives` bound (a
    /// base class's operators are C++ members the bound table does not
    /// list, so that case still defers). Null for anything else, including
    /// a dependent composite (`*T`, `Rep<T>`), whose own rules apply. What
    /// such a parameter can do is exactly what bound_ifaces grants: an
    /// operator, a conversion, an interpolation or a pattern its bounds do
    /// not declare is an error at the definition (opaque_param_ops.k).
    fn checked_param(self, t: *Type) -> *GenericParamDecl {
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<GenericParamType>(c)) { return &null; }
        var g = cast::<GenericParamType>(c);
        if g->is_pack || (g->owner == &null) { return &null; }
        var gps = decl_generic_params(g->owner);
        if static_cast::<usize>(g->param_index) >= gps.size() { return &null; }
        var gp = gps[static_cast::<usize>(g->param_index)];
        if (gp == &null) || (gp->kind_bound == GenericParamKindBound::Duck) { return &null; }
        var it = self.sc->bounds.find(reinterpret_cast::<u64>(g->owner));
        if it == self.sc->bounds.end() { return gp; }
        var _set = &(it->second);
        for var i: usize = 0; i < _set->derives_constraints.size(); ++i {
            var k = _set->derives_constraints[i];
            var id = dyn_cast::<NamedIdentExpr>(k->lhs);
            if (id != &null) && (id->resolved_decl == static_cast::<*Decl>(gp)) { return &null; }
        }
        return gp;
    }

    /// The interface instance an AssocType for requirement \p td carries
    /// when it is named through \p through (a bound, or the Self of the
    /// interface it is named in): its DECLARING interface, so one entity has
    /// one canonical however it was reached -- `G::Node` through `G impl
    /// Big`, `Big derives Graph`, and Graph's `first() -> Self::Node`
    /// through the same G are the same type. \p through itself when it is
    /// the declaring interface (its arguments are then exact); the plain
    /// record of a non-generic declaring interface; null for one inherited
    /// from a GENERIC interface, whose arguments as seen from \p through
    /// are not computed (SC116E at the use).
    fn assoc_iface(self, through: *Type, td: *Decl) -> *Type {
        if (through == &null) || (td == &null) || (td->semantic_dc == &null) { return &null; }
        var home = reinterpret_cast::<*DeclContext>(td->semantic_dc)->owner_decl();
        if (home == &null) || (!isa::<InterfaceDecl>(home)) { return &null; }
        home = NameLookup::representative(home);
        var td0 = self.record_decl(canon_unqual(through));
        if (td0 != &null) && (NameLookup::representative(self.pattern_of(td0)) == home) { return canon_unqual(through); }
        if decl_generic_params(home).size() > 0 { return &null; }
        var none = vec::<*Type>();
        return self.sc->types->record(home, &none);
    }

    /// `T::name` in expression position (`T::Node { }`, `T::Node()`): the
    /// associated type the first of \p t's interface bounds that declares
    /// \p name gives, or null. Type position resolves it in T, which also
    /// reports the ambiguity of two bounds declaring it; this reads the same
    /// composed requirement lists.
    fn assoc_named(self, t: *Type, name: string) -> *Type {
        var bs = self.bound_ifaces(t);
        for var i: usize = 0; i < bs.size(); ++i {
            var d = self.record_decl(bs[i]);
            if d == &null { continue; }
            var idecl = dyn_cast::<InterfaceDecl>(NameLookup::representative(self.pattern_of(d)));
            if (idecl == &null) || (idecl->compose_state != 2) { continue; }
            for var j: usize = 0; j < idecl->requirements.size(); ++j {
                var ta = dyn_cast::<TypeAliasDecl>(idecl->requirements.get(j)->decl);
                if (ta == &null) || (ta->generic_params.size() > 0) { continue; }
                if self.decl_name(static_cast::<*Decl>(ta)) != name { continue; }
                var ai = self.assoc_iface(bs[i], static_cast::<*Decl>(ta));
                if ai == &null { return &null; }
                return self.sc->types->assoc(canon_unqual(t), ai, NameLookup::representative(static_cast::<*Decl>(ta)));
            }
        }
        return &null;
    }

    /// Associated type \p t's own bounds (`type Node impl Default`) promise a
    /// constructor taking \p arity arguments: the one thing that lets a
    /// generic body build a value of it (interfaces.md, Generic Bodies).
    fn assoc_has_ctor(self, t: *Type, arity: usize) -> bool {
        var a = dyn_cast::<AssocType>(canon_unqual(t));
        if a == &null { return false; }
        var ta = dyn_cast::<TypeAliasDecl>(a->assoc);
        if ta == &null { return false; }
        var cs = vec::<*ConstraintExpr>();
        self._conjuncts(ta->requires_clause, &cs);
        for var i: usize = 0; i < cs.size(); ++i {
            var c = cs[i];
            if c->is_derives() || (c->rhs == &null) || (c->rhs->canonical == &null) { continue; }
            var d = self.record_decl(canon_unqual(c->rhs->canonical));
            if d == &null { continue; }
            var idecl = dyn_cast::<InterfaceDecl>(NameLookup::representative(self.pattern_of(d)));
            if idecl == &null { continue; }
            var ms = vec::<*FunctionDecl>();
            if idecl->compose_state == 2 {
                for var j: usize = 0; j < idecl->requirements.size(); ++j {
                    var m = dyn_cast::<FunctionDecl>(idecl->requirements.get(j)->decl);
                    if m != &null { ms.push_back(m); }
                }
            } else {
                for var j: usize = 0; j < idecl->methods.size(); ++j { ms.push_back(idecl->methods[j]); }
            }
            for var j: usize = 0; j < ms.size(); ++j {
                var m = ms[j];
                if !decl_is_ctor_requirement(m) { continue; }
                var n: usize = 0;
                for var k: usize = 0; k < m->params.size(); ++k { if (m->params[k] != &null) && (!m->params[k]->is_self) { n += 1; } }
                if n == arity { return true; }
            }
        }
        return false;
    }

    priv fn _conjuncts(self, e: *Expr, out: *vec::<*ConstraintExpr>) {
        if e == &null { return; }
        if e->kind == ExprKind::BinaryOperatorExpr {
            var b = cast::<BinaryOperatorExpr>(e);
            if (b->op_token.kind == TokenKind::OpAmpAmp) || (b->op_token.kind == TokenKind::KwAnd) {
                self._conjuncts(b->lhs, out);
                self._conjuncts(b->rhs, out);
            }
            return;
        }
        if e->kind == ExprKind::ConstraintExpr { out->push_back(cast::<ConstraintExpr>(e)); }
    }

    fn record_args(self, t: *Type) -> FrozenList::<*Type> {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<RecordType>(u)) { return create_empty_frozen_list::<*Type>(); }
        return cast::<RecordType>(u)->args;
    }

    /// `[T; N]` only -- the one container that is still structural. Vector,
    /// HashSet and Slice are lang records; their element comes out of
    /// container_elem, off the record's arguments.
    fn element_of(self, t: *Type) -> *Type {
        var u = canon_unqual(t);
        if u == &null { return &null; }
        if isa::<FixedArrayType>(u) { return cast::<FixedArrayType>(u)->element; }
        return &null;
    }

    fn is_type_decl(self, d: *Decl) -> bool {
        if d == &null { return false; }
        switch d->kind {
            case DeclKind::ClassDecl     { return true; }
            case DeclKind::StructDecl    { return true; }
            case DeclKind::UnionDecl     { return true; }
            case DeclKind::EnumDecl      { return true; }
            case DeclKind::InterfaceDecl { return true; }
            case DeclKind::TypeAliasDecl { return true; }
            default                      { return false; }
        }
    }

    fn is_record_decl(self, d: *Decl) -> bool {
        if d == &null { return false; }
        switch d->kind {
            case DeclKind::ClassDecl     { return true; }
            case DeclKind::StructDecl    { return true; }
            case DeclKind::UnionDecl     { return true; }
            case DeclKind::EnumDecl      { return true; }
            case DeclKind::InterfaceDecl { return true; }
            default                      { return false; }
        }
    }

    // === decl helpers =======================================================

    fn generic_params_of(self, d: *Decl) -> FrozenList::<*GenericParamDecl> {
        return decl_generic_params(d);
    }

    /// The pattern a record decl is an instance of, or the decl itself.
    fn pattern_of(self, d: *Decl) -> *Decl {
        return decl_pattern(d);
    }

    /// Spelled with the decl's OWN context (hard invariant #2).
    fn decl_name(self, d: *Decl) -> string {
        if d == &null { return "<null>"; }
        var ctx = NameLookup::ctx_of(d);
        if ctx == &null { ctx = self.sc->ctx; }
        if isa::<ClassDecl>(d)        { return ctx->get_spelling(cast::<ClassDecl>(d)->name);        }
        if isa::<StructDecl>(d)       { return ctx->get_spelling(cast::<StructDecl>(d)->name);       }
        if isa::<UnionDecl>(d)        { return ctx->get_spelling(cast::<UnionDecl>(d)->name);        }
        if isa::<InterfaceDecl>(d)    { return ctx->get_spelling(cast::<InterfaceDecl>(d)->name);    }
        if isa::<EnumDecl>(d)         { return ctx->get_spelling(cast::<EnumDecl>(d)->name);         }
        if isa::<TypeAliasDecl>(d)    { return ctx->get_spelling(cast::<TypeAliasDecl>(d)->name);    }
        if isa::<ModuleDecl>(d)       { return ctx->get_spelling(cast::<ModuleDecl>(d)->name);       }
        if isa::<FunctionDecl>(d)     { return ctx->get_spelling(cast::<FunctionDecl>(d)->name);     }
        if isa::<ParamDecl>(d)        { return ctx->get_spelling(cast::<ParamDecl>(d)->name);        }
        if isa::<VariableDecl>(d)     { return ctx->get_spelling(cast::<VariableDecl>(d)->name);     }
        if isa::<FieldDecl>(d)        { return ctx->get_spelling(cast::<FieldDecl>(d)->name);        }
        if isa::<EnumVariantDecl>(d)  { return ctx->get_spelling(cast::<EnumVariantDecl>(d)->name);  }
        if isa::<GenericParamDecl>(d) { return ctx->get_spelling(cast::<GenericParamDecl>(d)->name); }
        return "<decl>";
    }

    /// Spelling of a param name in the param's own interner.
    fn param_name(self, p: *ParamDecl) -> string {
        var ctx = NameLookup::ctx_of(static_cast::<*Decl>(p));
        if ctx == &null { ctx = self.sc->ctx; }
        return ctx->get_spelling(p->name);
    }

    fn fid_of(self, d: *Decl) -> u32 {
        var c = NameLookup::ctx_of(d);
        if c == &null { return self.sc->ctx->fid; }
        return c->fid;
    }

    fn is_foreign(self, d: *Decl) -> bool {
        var c = NameLookup::ctx_of(d);
        return (c != &null) && (c != self.sc->ctx);
    }

    // === inheritance ========================================================
    //
    // Derived-to-base is Substitution::derives_from: it is a question about
    // TYPES, since an instance's bases are its pattern's read through its
    // arguments, and the substitution that reads them sits above this file.

    /// The first pure virtual method (FnBodyKind::Virtual: a bodyless
    /// `virtual fn`, or an imported C++ `= 0`) that `d` or one of its bases
    /// declares and nothing between it and `d` overrides; null when `d` is
    /// not abstract. A derived class that overrides some but not all of its
    /// base's pure methods stays abstract, as in C++. An override is matched
    /// by name and arity: overload resolution on the receiver is not this
    /// question's, and two same-named, same-arity methods in one chain are
    /// an override in practice (C++ would make a differing one a hide).
    fn first_pure_left(self, d: *Decl) -> *FunctionDecl {
        if d == &null { return &null; }
        var chain  = vec::<*Decl>();
        var depths = vec::<u32>();
        self._chain_walk(NameLookup::representative(d), &chain, &depths, 0);
        for var i: usize = 0; i < chain.size(); ++i {
            var cd = dyn_cast::<ClassDecl>(chain[i]);
            if cd == &null { continue; }
            for var j: usize = 0; j < cd->methods.size(); ++j {
                var p = cd->methods[j];
                if (p == &null) || (p->body_kind != FnBodyKind::Virtual) { continue; }
                if !self._overridden_below(p, &chain, &depths, depths[i]) { return p; }
            }
        }
        return &null;
    }

    priv fn _overridden_below(self, p: *FunctionDecl, chain: *vec::<*Decl>, depths: *vec::<u32>, depth: u32) -> bool {
        var pname = self.decl_name(static_cast::<*Decl>(p));
        for var i: usize = 0; i < chain->size(); ++i {
            if (*depths)[i] >= depth { continue; }
            var cd = dyn_cast::<ClassDecl>((*chain)[i]);
            if cd == &null { continue; }
            for var j: usize = 0; j < cd->methods.size(); ++j {
                var m = cd->methods[j];
                if (m == &null) || (m->body_kind == FnBodyKind::Virtual) { continue; }
                if m->params.size() != p->params.size() { continue; }
                if self.decl_name(static_cast::<*Decl>(m)) == pname { return true; }
            }
        }
        return false;
    }

    priv fn _chain_walk(self, d: *Decl, out: *vec::<*Decl>, depths: *vec::<u32>, depth: u32) {
        if depth > 64 { return; }
        for var i: usize = 0; i < out->size(); ++i { if (*out)[i] == d { return; } }
        out->push_back(d);
        depths->push_back(depth);
        var cd = dyn_cast::<ClassDecl>(d);
        if cd == &null { return; }
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var e = cd->derives_list.get(i);
            if (e == &null) || (e->base == &null) { continue; }
            var bd = self.record_decl(e->base->canonical);
            if bd != &null { self._chain_walk(NameLookup::representative(bd), out, depths, depth + 1); }
        }
        // an instance's methods and bases are its pattern's.
        var pat = self.pattern_of(d);
        if pat != d { self._chain_walk(pat, out, depths, depth); }
    }

    /// Any virtual/override/pure method here or in a base: a vtable exists.
    fn is_polymorphic(self, d: *Decl) -> bool {
        if d == &null { return false; }
        var seen = vec::<*Decl>();
        return self._poly_walk(NameLookup::representative(d), &seen, 0);
    }

    priv fn _poly_walk(self, d: *Decl, seen: *vec::<*Decl>, depth: u32) -> bool {
        if depth > 64 { return false; }
        for var i: usize = 0; i < seen->size(); ++i { if (*seen)[i] == d { return false; } }
        seen->push_back(d);
        var cd = dyn_cast::<ClassDecl>(d);
        if cd == &null { return false; }
        for var i: usize = 0; i < cd->methods.size(); ++i {
            var m = cd->methods[i];
            if m == &null { continue; }
            if (m->abi == AbiKind::Virtual) || (m->abi == AbiKind::Override) { return true; }
            if m->body_kind == FnBodyKind::Virtual { return true; }
        }
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var e = cd->derives_list.get(i);
            if (e == &null) || (e->base == &null) { continue; }
            var bd = self.record_decl(e->base->canonical);
            if (bd != &null) && self._poly_walk(NameLookup::representative(bd), seen, depth + 1) { return true; }
        }
        var pat = self.pattern_of(d);
        if pat != d { return self._poly_walk(pat, seen, depth + 1); }
        return false;
    }

    // === lang items =========================================================

    /// `record(lang item decl, args)` or null when the item is unbound.
    /// SemaContext owns the builder: TypeResolve reaches the same one, so a
    /// written `[T;]` and one a literal takes share an identity AND a registry
    /// entry (without which the instance has no home TU and its bodies are
    /// emitted nowhere).
    fn lang_record(self, k: WellKnownType, args: *vec::<*Type>) -> *Type {
        return self.sc->lang_record(k, args);
    }

    /// A container canonical is the lang RECORD or nothing. There is no
    /// structural fallback: two spellings of one written type would be two
    /// identities, and null is the poisoned-component answer every caller
    /// already handles.
    fn vector_of(self, elem: *Type) -> *Type {
        if elem == &null { return &null; }
        var a = vec::<*Type>(); a.push_back(elem);
        return self.lang_record(WellKnownType::Vector, &a);
    }

    fn slice_of(self, elem: *Type) -> *Type {
        if elem == &null { return &null; }
        var a = vec::<*Type>(); a.push_back(elem);
        return self.lang_record(WellKnownType::Slice, &a);
    }

    /// The slice an array is viewed as: `[T; N]` -> `[T;]`, and a const
    /// array -> `[const T;]` so the view keeps the qualifier. Null for
    /// anything that is not an array, or with no Slice lang item.
    fn array_view(self, t: *Type) -> *Type {
        var elem = self.element_of(t);
        if elem == &null { return &null; }
        if canon_has_const(t) && (!canon_has_const(elem)) { elem = self.sc->types->qualified(elem, QUAL_CONST()); }
        return self.slice_of(elem);
    }

    fn set_of(self, elem: *Type) -> *Type {
        if elem == &null { return &null; }
        var a = vec::<*Type>(); a.push_back(elem);
        return self.lang_record(WellKnownType::HashSet, &a);
    }

    fn map_of(self, k: *Type, v: *Type) -> *Type {
        if (k == &null) || (v == &null) { return &null; }
        var a = vec::<*Type>(); a.push_back(k); a.push_back(v);
        return self.lang_record(WellKnownType::HashMap, &a);
    }

    fn string_type(self) -> *Type {
        var a = vec::<*Type>();
        return self.lang_record(WellKnownType::String, &a);
    }

    /// Is \p t the vector/set/map/string lang record, or its structural form.
    fn is_lang(self, t: *Type, k: WellKnownType) -> bool {
        var d = self.sc->well_known->get(k);
        if d == &null { return false; }
        var rd = self.record_decl(t);
        if rd == &null { return false; }
        return self.pattern_of(rd) == NameLookup::representative(d);
    }

    /// A generator's declared return: `-> yield T`, as WRITTEN (the
    /// qualifier is not on the canonical). It types each yielded value.
    /// A spelled-out `-> Yield<T>` is NOT one: it is an ordinary record
    /// return, which the coroutine machinery itself relies on
    /// (`get_return_object` returns a Yield<T> by value).
    fn is_generator_return(self, t: *Type) -> bool {
        if t == &null { return false; }
        return t->is_yield();
    }

    fn is_vector_like(self, t: *Type) -> bool { return self.is_lang(t, WellKnownType::Vector);  }
    fn is_map_like(self, t: *Type)    -> bool { return self.is_lang(t, WellKnownType::HashMap); }
    fn is_set_like(self, t: *Type)    -> bool { return self.is_lang(t, WellKnownType::HashSet); }
    fn is_slice(self, t: *Type)       -> bool { return self.is_lang(t, WellKnownType::Slice);   }

    fn is_string(self, t: *Type) -> bool { return self.is_lang(t, WellKnownType::String); }

    // === tuples =============================================================
    //
    // `(A, B, ..)` is the record `TupleN<A, B, ..>` (TupleRecords): no
    // canonical is a TupleType after T. Tuple-ness is the pattern's
    // `tuple_arity`, by identity -- a user's own `Tuple2` is not one.

    /// The tuple record decl \p d is (its pattern has an arity), else false.
    fn is_tuple_decl(self, d: *Decl) -> bool {
        if d == &null { return false; }
        var s = dyn_cast::<StructDecl>(self.pattern_of(NameLookup::representative(d)));
        return (s != &null) && (s->tuple_arity > 0);
    }

    /// The arity of a tuple canonical, 0 for anything else.
    fn tuple_arity(self, t: *Type) -> usize {
        var d = self.record_decl(t);
        if d == &null { return 0; }
        var s = dyn_cast::<StructDecl>(self.pattern_of(NameLookup::representative(d)));
        if s == &null { return 0; }
        return static_cast::<usize>(s->tuple_arity);
    }

    fn is_tuple(self, t: *Type) -> bool { return self.tuple_arity(t) > 0; }

    /// The element types of a tuple canonical: the record's arguments, in
    /// element order (the pattern's field `_i` is typed `Ti`, which is
    /// args[i] in the instance -- by construction, no substitution needed).
    fn tuple_elems(self, t: *Type) -> FrozenList::<*Type> { return self.record_args(t); }

    /// `record(TupleN, elems)`, or null when there is no record for that
    /// arity (no builtin root, or past TUPLE_MAX_ARITY; the caller diagnoses
    /// -- TypeParse already rejects it at a written type).
    fn tuple_of(self, elems: *vec::<*Type>) -> *Type {
        return self.sc->tuple_record(elems);
    }

    /// Field \p i of a tuple canonical, read off the PATTERN (an instance
    /// shell has no fields until M2); null when out of range.
    fn tuple_field(self, t: *Type, i: usize) -> *FieldDecl {
        var d = self.record_decl(t);
        if d == &null { return &null; }
        var s = dyn_cast::<StructDecl>(self.pattern_of(NameLookup::representative(d)));
        if (s == &null) || (s->tuple_arity == 0) || (i >= s->fields.size()) { return &null; }
        return s->fields[i];
    }

    /// Element type of a vector/set/array/slice, whichever canonical form.
    fn container_elem(self, t: *Type) -> *Type {
        var e = self.element_of(t);
        if e != &null { return e; }
        if self.is_vector_like(t) || self.is_set_like(t) || self.is_slice(t) {
            var args = self.record_args(t);
            if args.size() > 0 { return args[0]; }
        }
        return &null;
    }

    fn map_key_value(self, t: *Type, k: *(*Type), v: *(*Type)) -> bool {
        var u = canon_unqual(t);
        if u == &null { return false; }
        if self.is_lang(t, WellKnownType::HashMap) {
            var args = self.record_args(t);
            if args.size() >= 2 { (*k) = args[0]; (*v) = args[1]; return true; }
        }
        return false;
    }

    // === calls ==============================================================

    /// The parameter at \p i across \p f's WHOLE redeclaration chain that
    /// specifies a default -- a Kairo expression, the thunk CallLowering made
    /// of one, or an imported C++ default -- or null. Defaults accumulate
    /// across a chain and RedeclMerge admits one per index, so no single link
    /// is authoritative and every reader asks here.
    fn param_default(self, f: *FunctionDecl, i: usize) -> *ParamDecl {
        if f == &null { return &null; }
        var links = vec::<*Decl>();
        NameLookup::collect_chain(static_cast::<*Decl>(f), links);
        if links.size() == 0 { links.push_back(static_cast::<*Decl>(f)); }
        for var k: usize = 0; k < links.size(); ++k {
            var g = dyn_cast::<FunctionDecl>(links[k]);
            if (g == &null) || (i >= g->params.size()) { continue; }
            var p = g->params[i];
            if p == &null { continue; }
            if (p->default_val != &null) || (p->default_thunk != &null) || p->has_default { return p; }
        }
        return &null;
    }

    /// The type a USE of \p p has inside its function. A pack `...xs: T` is
    /// `[T;]` (Slice<T>, by value); every other parameter is its declared
    /// canonical. Null when the pack's element is dependent (a generic pack;
    /// not modelled yet) or the type never resolved. The declared `type_`
    /// stays the element: overload resolution ranks each pack argument
    /// against it, and CallLowering builds the slice from it.
    fn param_value_type(self, p: *ParamDecl) -> *Type {
        if (p == &null) || (p->type_ == &null) || (p->type_->canonical == &null) { return &null; }
        var c = p->type_->canonical;
        if !p->is_pack { return c; }
        var elem = canon_unqual(c);
        if (elem == &null) || elem->is_dependent() { return &null; }
        return self.slice_of(elem);
    }

    /// \p p's index in \p f->params, `self` included; usize(-1) if absent.
    fn param_index(self, f: *FunctionDecl, p: *ParamDecl) -> usize {
        for var i: usize = 0; i < f->params.size(); ++i { if f->params[i] == p { return i; } }
        return usize(-1);
    }

    /// A lang record's constructor BY SHAPE: \p nparams non-self parameters,
    /// and for \p from_slice the single one is a Slice. Found through the lang
    /// item, never by name. LiteralTyping binds literals through it and
    /// CallLowering binds a pack's slice through it: one lookup, one answer.
    fn lang_ctor(self, k: WellKnownType, nparams: usize, from_slice: bool) -> *Decl {
        var d = self.sc->well_known->get(k);
        if d == &null { return &null; }
        var body = self.pattern_of(NameLookup::representative(d));
        var dc   = NameLookup::context_of(body);
        if dc == &null { return &null; }
        var cell = self.sc->lookup.in_context(dc, DeclName::ctor());
        if !cell.found() { return &null; }
        for var i: usize = 0; i < cell.cell->size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cell.cell->get(i));
            if f == &null { continue; }
            var n: usize = 0;
            var only: *ParamDecl = &null;
            for var p: usize = 0; p < f->params.size(); ++p {
                var pd = f->params[p];
                if (pd == &null) || pd->is_self { continue; }
                n += 1;
                only = pd;
            }
            if n != nparams { continue; }
            if from_slice {
                if (only == &null) || (only->type_ == &null) || (!self.is_slice(only->type_->canonical)) { continue; }
            }
            return cell.cell->get(i);
        }
        return &null;
    }

    // === qualifiers =========================================================

    fn quals(self, t: *Type)        -> u8    { return canon_quals(t); }
    fn unqual(self, t: *Type)       -> *Type { return canon_unqual(t); }
    fn has_const(self, t: *Type)    -> bool  { return canon_has_const(t); }
    fn has_volatile(self, t: *Type) -> bool  { return canon_has_volatile(t); }

    // === syntax quals =======================================================
    //
    // Quals are excluded from canonicals by design; these read the SYNTAX
    // node, through the TypeQual mixin every Type derives (AST/Mixin/
    // TypeQual.k) rather than through the parser's PendingQuals accumulator,
    // which is not visible from Sema.

    fn syntax_is_const(self, t: *Type) -> bool {
        if t == &null { return false; }
        return t->is_const();
    }

    fn syntax_is_unsafe(self, t: *Type) -> bool {
        if t == &null { return false; }
        return t->is_unsafe();
    }

    // === default values =====================================================

    /// Empty when a value of \p t can be built from nothing; otherwise why
    /// not, phrased to follow "and" ("'x' is declared without an
    /// initializer, and ..."). variables.mdx: a number or a pointer is 0 /
    /// null, a nullable is null, a record with a usable constructor callable
    /// on `self` alone is that, an array is its elements'. `bool` has no zero
    /// state to assume, a record without such a constructor -- none at all,
    /// or one deleted -- is never built, and an enum with payloads has no
    /// variant to pick. Imported C++ types and dependent ones answer empty:
    /// clang and instantiation decide them. One answer for every binding
    /// that has no initializer: a local, a static (InitCheck) and a field a
    /// constructor must build (CtorInitCheck).
    fn why_no_default(self, t: *Type) -> string {
        return self._why_no_default(t, 0);
    }

    /// \p depth bounds the walk into fields: a by-value cycle is
    /// TypeCycleCheck's error, but this question may be asked before it
    /// poisons the cycle, and must not recurse forever meanwhile.
    priv fn _why_no_default(self, t: *Type, depth: u32) -> string {
        if depth > 16 { return ""; }
        var el = self.element_of(t);
        if el != &null { return self._why_no_default(canon_unqual(el), depth + 1); }
        if self.is_bool(t) { return "'bool' has no zero state: a default would have to guess true or false"; }
        if self.nullable_inner(t) != &null { return ""; }
        var en = self.payload_enum(t);
        if en != &null {
            var en_nm = self.sc->ctx->get_spelling(en->name);
            return f"'{en_nm}' is an enum with payloads, so no variant is its default";
        }
        var rd = self.default_record(t);
        if rd == &null { return ""; }
        var nm = self.decl_name(rd);
        if decl_only_forward(rd) { return f"'{nm}' is only forward-declared, so there is nothing to build"; }
        var dc = self.default_ctor_of(rd);
        if (dc == &null) && (!self.declares_ctor(rd)) { return self._why_no_implicit(rd, depth); }
        if dc == &null { return f"'{nm}' has no default constructor (declare 'fn {nm}(self)')"; }
        if dc->body_kind == FnBodyKind::Delete { return f"the default constructor of '{nm}' is deleted"; }
        return "";
    }

    /// A record that declares no constructor has the implicit default one
    /// (interfaces-requirements.mdx: "A type that declares no constructor at
    /// all has the implicit one"), and it builds every base and field from
    /// nothing, so it exists exactly when each of them can be: a field with
    /// an initializer, or whose type has a default. A `const` field without
    /// an initializer cannot (a constructor must give it its one value,
    /// classes.mdx), nor can a C++ value-initialization of one. Empty when
    /// it exists; otherwise why not, naming the first base or field that
    /// stops it. A dependent field (`var v: T`) answers empty, as every
    /// dependent type does: the instance decides.
    priv fn _why_no_implicit(self, rd: *Decl, depth: u32) -> string {
        var nm = self.decl_name(rd);
        if isa::<ClassDecl>(rd) {
            var bases = &(cast::<ClassDecl>(rd)->derives_list);
            for var i: usize = 0; i < bases->size(); ++i {
                var e = bases->get(i);
                if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
                var bw = self._why_no_default(canon_unqual(e->base->canonical), depth + 1);
                if !bw.empty() {
                    return f"'{nm}' has no default constructor: the implicit one cannot build its base ({bw})";
                }
            }
        }
        var fs = (&(cast::<ClassDecl>(rd)->fields)) if (isa::<ClassDecl>(rd)) else (&(cast::<StructDecl>(rd)->fields));
        for var i: usize = 0; i < fs->size(); ++i {
            var f = (*fs)[i];
            if (f == &null) || f->is_anonymous_union { continue; }
            if (f->storage == StorageClass::Static) || (f->storage == StorageClass::Eval) { continue; }
            if (f->init != &null) || (f->init_thunk != &null) || (f->init_fold != FieldFold::None) { continue; }
            var fnm = self.sc->ctx->get_spelling(f->name);
            if f->storage == StorageClass::Const {
                return f"'{nm}' has no default constructor: the implicit one cannot give const field '{fnm}' a value, and it has no initializer";
            }
            if (f->type_ == &null) || (f->type_->canonical == &null) { continue; }
            var fw = self._why_no_default(canon_unqual(f->type_->canonical), depth + 1);
            if !fw.empty() {
                return f"'{nm}' has no default constructor: the implicit one cannot build field '{fnm}', which has no initializer ({fw})";
            }
        }
        return "";
    }

    /// \p d (class or struct) declares a constructor of any kind: one named
    /// after it, a transfer (`@copy` / `@move`) included, deleted included.
    /// Any of them suppresses the implicit default constructor, as a
    /// user-declared constructor of any kind does in C++ -- which is what
    /// the emitted class has to agree with.
    fn declares_ctor(self, d: *Decl) -> bool {
        var nm = self.decl_name(d);
        var ms = (cast::<ClassDecl>(d)->methods) if (isa::<ClassDecl>(d)) else (cast::<StructDecl>(d)->methods);
        for var i: usize = 0; i < ms.size(); ++i {
            var m = ms[i];
            if (m == &null) || m->is_operator || (m->adt_role != AdtRole::None) { continue; }
            if self.decl_name(static_cast::<*Decl>(m)) == nm { return true; }
        }
        return false;
    }

    /// The Kairo enum with payloads \p t names (its pattern), else null.
    fn payload_enum(self, t: *Type) -> *EnumDecl {
        var rd = self.record_decl(t);
        if rd == &null { return &null; }
        if decl_is_instance(rd) { rd = decl_pattern(rd); }
        if (rd == &null) || (!isa::<EnumDecl>(rd)) || decl_is_imported(rd) { return &null; }
        var en = cast::<EnumDecl>(rd);
        return (en) if (en->is_adt) else (&null);
    }

    /// A Kairo class or struct, pattern side, as the default-value question
    /// sees it. Null for an imported C++ record (clang decides), an enum, a
    /// dependent type.
    fn default_record(self, t: *Type) -> *Decl {
        var rd = self.record_decl(t);
        if rd == &null { return &null; }
        if decl_is_instance(rd) { rd = decl_pattern(rd); }
        if (rd == &null) || decl_is_imported(rd) { return &null; }
        if (!isa::<ClassDecl>(rd)) && (!isa::<StructDecl>(rd)) { return &null; }
        return rd;
    }

    /// The constructor of class or struct \p d callable with no arguments:
    /// not an operator, not a transfer (`@copy`/`@move` build from another
    /// value, not from none), every parameter but `self` defaulted.
    fn default_ctor_of(self, d: *Decl) -> *FunctionDecl {
        var nm = self.decl_name(d);
        var ms = (cast::<ClassDecl>(d)->methods) if (isa::<ClassDecl>(d)) else (cast::<StructDecl>(d)->methods);
        for var i: usize = 0; i < ms.size(); ++i {
            var m = ms[i];
            if (m == &null) || m->is_operator || (m->adt_role != AdtRole::None) { continue; }
            if (m->transfer != TransferKind::NotTransfer) || (self.decl_name(static_cast::<*Decl>(m)) != nm) { continue; }
            var ok = true;
            for var j: usize = 0; j < m->params.size(); ++j {
                var p = m->params[j];
                if p->is_self { continue; }
                if (p->default_val == &null) && (!p->has_default) && (!p->is_pack) { ok = false; break; }
            }
            if ok { return m; }
        }
        return &null;
    }

    /// The list literal an instance array field is initialized with, when
    /// FieldInitLowering lowers it one element at a time (a thunk each);
    /// null for every other initializer, which keeps the SC116E gate: a
    /// static (defined out of the class, where no element list helps), an
    /// array of arrays (an element cannot be initialized from an array),
    /// anything but a list literal.
    fn array_field_list(self, f: *FieldDecl) -> *ListLiteralExpr {
        if (f == &null) || (f->init == &null) || f->is_static() || (f->type_ == &null) { return &null; }
        var c = canon_unqual(f->type_->canonical);
        if (c == &null) || (!isa::<FixedArrayType>(c)) { return &null; }
        var el = canon_unqual(cast::<FixedArrayType>(c)->element);
        if (el == &null) || (el->kind == TypeKind::FixedArrayType) { return &null; }
        var e = self.strip_parens(f->init);
        if (e == &null) || (!isa::<ListLiteralExpr>(e)) { return &null; }
        return cast::<ListLiteralExpr>(e);
    }

    // === expr helpers =======================================================

    fn strip_parens(self, e: *Expr) -> *Expr {
        var x = e;
        while (x != &null) && isa::<ParenExpr>(x) { x = cast::<ParenExpr>(x)->inner; }
        return x;
    }

    // === rendering ==========================================================

    /// A computed value's binary operator, as written (TypeResolve keeps the
    /// symbol form).
    priv fn _value_op(self, k: TokenKind) -> string {
        if k == TokenKind::OpPlus  { return "+"; }
        if k == TokenKind::OpMinus { return "-"; }
        if k == TokenKind::OpStar  { return "*"; }
        if k == TokenKind::OpSlash { return "/"; }
        if k == TokenKind::OpPercent { return "%"; }
        if k == TokenKind::OpPipe  { return "|"; }
        if k == TokenKind::OpAmp   { return "&"; }
        if k == TokenKind::OpCaret { return "^"; }
        if k == TokenKind::OpLessLess { return "<<"; }
        if k == TokenKind::OpGreaterGreater { return ">>"; }
        return "?";
    }

    fn str(self, t: *Type) -> string {
        if t == &null { return "<unknown>"; }
        switch t->kind {
            case TypeKind::BuiltinType { return cast::<BuiltinType>(t)->spelling(); }
            case TypeKind::RecordType {
                // A lang container prints as the SUGAR it was written as:
                // `[i32]`, not `Vector<i32>`. Every diagnostic quotes this, so
                // the spelling a user sees is the one they typed.
                if self.is_slice(t) {
                    var sa = self.record_args(t);
                    if sa.size() > 0 { return "[" + self.str(sa[0]) + ";]"; }
                }
                if self.is_vector_like(t) {
                    var va = self.record_args(t);
                    if va.size() > 0 { return "[" + self.str(va[0]) + "]"; }
                }
                if self.is_set_like(t) {
                    var ea = self.record_args(t);
                    if ea.size() > 0 { return "{" + self.str(ea[0]) + "}"; }
                }
                if self.is_map_like(t) {
                    var ma = self.record_args(t);
                    if ma.size() >= 2 { return "{" + self.str(ma[0]) + ": " + self.str(ma[1]) + "}"; }
                }
                if self.is_string(t) { return to_string(WellKnownType::String); }
                // A tuple prints as it is written, `(i32, f64)`: every
                // golden and every message that quotes one reads so.
                if self.is_tuple(t) {
                    var ta = self.record_args(t);
                    var s = "(";
                    for var i: usize = 0; i < ta.size(); ++i {
                        if i > 0 { s += ", "; }
                        s += self.str(ta[i]);
                    }
                    return s + ")";
                }

                var r = cast::<RecordType>(t);
                var s = self.decl_name(r->decl);
                // `L<i32>::P`: named through its enclosing instance.
                if r->outer != &null { s = self.str(r->outer) + "::" + s; }
                if r->args.size() > 0 {
                    s += "<";
                    for var i: usize = 0; i < r->args.size(); ++i {
                        if i > 0 { s += ", "; }
                        s += self.str(r->args[i]);
                    }
                    s += ">";
                }
                return s;
            }
            case TypeKind::PointerType {
                var p = cast::<PointerType>(t);
                var pre = ("unsafe *") if (p->is_unsafe) else ("*");
                // `*T?` reads as a nullable pointer, so a pointer TO a
                // nullable is written the only way that parses back to it.
                if isa::<NullableType>(p->pointee) { return pre + "(" + self.str(p->pointee) + ")"; }
                return pre + self.str(p->pointee);
            }
            // `T??` is the `??` operator, so a nested nullable is written
            // the only way that parses back to it.
            case TypeKind::NullableType {
                var inner = cast::<NullableType>(t)->inner;
                if isa::<NullableType>(canon_unqual(inner)) { return "(" + self.str(inner) + ")?"; }
                return self.str(inner) + "?";
            }
            case TypeKind::VectorType     { return "[" + self.str(cast::<VectorType>(t)->element) + "]"; }
            case TypeKind::SetType        { return "{" + self.str(cast::<SetType>(t)->element) + "}"; }
            case TypeKind::MapType {
                var m = cast::<MapType>(t);
                return "{" + self.str(m->key) + ": " + self.str(m->value) + "}";
            }
            case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(t);
                if a->is_incomplete { return "[" + self.str(a->element) + ";]"; }
                if a->extent_param != &null { return "[" + self.str(a->element) + "; " + self.str(a->extent_param) + "]"; }
                return f"[{self.str(a->element)}; {a->size_bits}]";
            }
            // A generic VALUE argument (`4` of `Ring<4, i32>`).
            case TypeKind::TypeExpr {
                var v = cast::<TypeExpr>(t);
                if !v->is_value { return "<value>"; }
                if v->is_exact() { return (f"-{v->vmag}") if (v->vneg) else (f"{v->vmag}"); }
                // A computed value (EVAL.md 0.2), as Kairo would write it.
                switch v->vop {
                    case ValueOp::Decl { return self.decl_name(v->vdecl); }
                    case ValueOp::Call {
                        var s = self.decl_name(v->vdecl) + "(";
                        for var i: usize = 0; i < v->vops.size(); ++i {
                            if i > 0 { s += ", "; }
                            s += self.str(v->vops[i]);
                        }
                        return s + ")";
                    }
                    case ValueOp::Unary { return ((("~") if (v->vtok == TokenKind::OpTilde) else ("-"))) + self.str(v->vops[0]); }
                    case ValueOp::Binary { return "(" + self.str(v->vops[0]) + " " + self._value_op(v->vtok) + " " + self.str(v->vops[1]) + ")"; }
                    case ValueOp::Cast { return "(" + self.str(v->vops[0]) + " as " + self.str(v->vty) + ")"; }
                    case ValueOp::Str {
                        // The bytes as a literal: printable ASCII as is, the
                        // rest (and `"` / `\`) escaped as `\xNN`.
                        var digits = "0123456789abcdef";
                        var s = "\"";
                        for var i: usize = 0; i < static_cast::<usize>(v->vmag); ++i {
                            var b = v->vbytes[i];
                            if (b >= u8(0x20)) && (b < u8(0x7f)) && (b != u8(0x22)) && (b != u8(0x5c)) { s += static_cast::<char>(b); continue; }
                            s += "\\x";
                            s += digits[static_cast::<usize>(b >> u8(4))];
                            s += digits[static_cast::<usize>(b & u8(15))];
                        }
                        return s + "\"";
                    }
                    default { return "<value>"; }
                }
                return "<value>";
            }
            // No TupleType arm: a tuple canonical is its record (above);
            // a syntax TupleType falls to the default and prints its canonical.
            case TypeKind::FunctionPointerType {
                var f = cast::<FunctionPointerType>(t);
                var s = "fn (";
                for var i: usize = 0; i < f->params.size(); ++i {
                    if i > 0 { s += ", "; }
                    // the mode is in the canonical, so it is in the spelling:
                    // `fn(@inout i32)` and `fn(i32)` must not render alike.
                    if i < f->modes.size() { s += param_mode_prefix(f->modes[i]); }
                    s += self.str(f->params[i]);
                }
                s += ")";
                // The effect is part of the type: `fn () panic(E1, E2)`.
                if f->canon_panics {
                    s += " panic";
                    if f->panic_set.size() > 0 {
                        s += "(";
                        for var i: usize = 0; i < f->panic_set.size(); ++i {
                            if i > 0 { s += ", "; }
                            s += self.str(f->panic_set[i]);
                        }
                        s += ")";
                    }
                }
                if (f->return_type != &null) && (!self.is_void(f->return_type)) {
                    s += " -> " + self.str(f->return_type);
                }
                return s;
            }
            case TypeKind::GenericParamType {
                var g = cast::<GenericParamType>(t);
                var gps = self.generic_params_of(g->owner);
                if (g->owner != &null) && (static_cast::<usize>(g->param_index) < gps.size()) {
                    var gp = gps[static_cast::<usize>(g->param_index)];
                    if gp != &null { return self.decl_name(static_cast::<*Decl>(gp)); }
                }
                return "<T>";
            }
            case TypeKind::OpaqueFFIType  { return "<ffi type>"; }
            // `T::Node`; `Self::Node` while the base is the interface's own
            // Self (it is then the interface record itself).
            case TypeKind::AssocType {
                var a = cast::<AssocType>(t);
                var nm = self.decl_name(a->assoc);
                if a->base == a->iface { return "Self::" + nm; }
                return self.str(a->base) + "::" + nm;
            }
            case TypeKind::QualifiedType {
                var q = cast::<QualifiedType>(t);
                var s = "";
                if (q->quals & QUAL_CONST())    != 0 { s += "const ";    }
                if (q->quals & QUAL_VOLATILE()) != 0 { s += "volatile "; }
                return s + self.str(q->inner);
            }
            case TypeKind::CXXLValueRefType {
                return self.str(cast::<CXXLValueRefType>(t)->referee) + "&";
            }
            case TypeKind::CXXRValueRefType {
                return self.str(cast::<CXXRValueRefType>(t)->referee) + "&&";
            }
            case TypeKind::SelfType       { return (self.str(t->canonical)) if (t->canonical != &null) else ("Self"); }
            default {
                if (t->canonical != &null) && (t->canonical != t) { return self.str(t->canonical); }
                return "<type>";
            }
        }
    }
}