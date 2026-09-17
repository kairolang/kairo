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

    fn record_decl(self, t: *Type) -> *Decl {
        var u = canon_unqual(t);
        if (u == &null) || (!isa::<RecordType>(u)) { return &null; }
        return cast::<RecordType>(u)->decl;
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

    /// True when \p derived is \p base or reaches it through `derives`
    /// edges. Works on representatives; instances walk their pattern.
    fn derives_from(self, derived: *Decl, base: *Decl) -> bool {
        if (derived == &null) || (base == &null) { return false; }
        var d = NameLookup::representative(derived);
        var b = NameLookup::representative(base);
        var seen = vec::<*Decl>();
        return self._derives_walk(d, b, &seen, 0);
    }

    priv fn _derives_walk(self, d: *Decl, b: *Decl, seen: *vec::<*Decl>, depth: u32) -> bool {
        if d == b { return true; }
        if depth > 64 { return false; }
        for var i: usize = 0; i < seen->size(); ++i { if (*seen)[i] == d { return false; } }
        seen->push_back(d);
        var bases = self._bases_of(d);
        for var i: usize = 0; i < bases.size(); ++i {
            var e = bases.get(i);
            if (e == &null) || (e->base == &null) { continue; }
            var c = e->base->canonical;
            var bd = self.record_decl(c);
            if bd == &null { continue; }
            if self._derives_walk(NameLookup::representative(bd), b, seen, depth + 1) { return true; }
        }
        // an instance inherits its pattern's bases.
        var pat = self.pattern_of(d);
        if pat != d { return self._derives_walk(pat, b, seen, depth + 1); }
        return false;
    }

    priv fn _bases_of(self, d: *Decl) -> FrozenList::<InheritEdge> {
        if isa::<ClassDecl>(d)     { return cast::<ClassDecl>(d)->derives_list;     }
        if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->derives_list; }
        return create_empty_frozen_list::<InheritEdge>();
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
    fn lang_record(self, k: WellKnownType, args: *vec::<*Type>) -> *Type {
        var d = self.sc->well_known->get(k);
        if d == &null { return &null; }
        var rep = NameLookup::representative(d);
        var gps = self.generic_params_of(rep);
        var trimmed = vec::<*Type>();
        for var i: usize = 0; (i < gps.size()) && (i < args->size()); ++i { trimmed.push_back((*args)[i]); }
        return self.sc->types->record(rep, &trimmed);
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

    fn is_vector_like(self, t: *Type) -> bool { return self.is_lang(t, WellKnownType::Vector);  }
    fn is_map_like(self, t: *Type)    -> bool { return self.is_lang(t, WellKnownType::HashMap); }
    fn is_set_like(self, t: *Type)    -> bool { return self.is_lang(t, WellKnownType::HashSet); }
    fn is_slice(self, t: *Type)       -> bool { return self.is_lang(t, WellKnownType::Slice);   }

    fn is_string(self, t: *Type) -> bool { return self.is_lang(t, WellKnownType::String); }

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

    // === expr helpers =======================================================

    fn strip_parens(self, e: *Expr) -> *Expr {
        var x = e;
        while (x != &null) && isa::<ParenExpr>(x) { x = cast::<ParenExpr>(x)->inner; }
        return x;
    }

    // === rendering ==========================================================

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
                if self.is_string(t) { return "string"; }

                var r = cast::<RecordType>(t);
                var s = self.decl_name(r->decl);
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
                return pre + self.str(p->pointee);
            }
            case TypeKind::NullableType   { return self.str(cast::<NullableType>(t)->inner) + "?"; }
            case TypeKind::VectorType     { return "[" + self.str(cast::<VectorType>(t)->element) + "]"; }
            case TypeKind::SetType        { return "{" + self.str(cast::<SetType>(t)->element) + "}"; }
            case TypeKind::MapType {
                var m = cast::<MapType>(t);
                return "{" + self.str(m->key) + ": " + self.str(m->value) + "}";
            }
            case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(t);
                if a->is_incomplete { return "[" + self.str(a->element) + ";]"; }
                return f"[{self.str(a->element)}; {a->size_bits}]";
            }
            case TypeKind::TupleType {
                var tt = cast::<TupleType>(t);
                var s = "(";
                for var i: usize = 0; i < tt->elements.size(); ++i {
                    if i > 0 { s += ", "; }
                    s += self.str(tt->elements[i]);
                }
                return s + ")";
            }
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