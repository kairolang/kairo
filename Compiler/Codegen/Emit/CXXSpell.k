/// --- The Kairo Project -------------------- Codegen/Emit/CXXSpell.k ----- ///
///
///   \brief The ONE C++ speller: canonical type -> text, decl -> qualified
///          name, decl -> namespace path. Both emitters call it; there is
///          no second copy anywhere, because two spellers drift and the
///          drift is a silent link error.
///
///   \par Everything is derived, nothing is stored per use
///     A decl's namespace is its semantic DeclContext chain -- `module X`
///     names on the way up, then the owning TU's module_base at the root
///     (IMPORTS.md invariant 9). An alias never appears (invariant 10).
///
///   \par Input is CANONICAL
///     type() reads `t->canonical` and refuses a null one. A syntax node
///     with no canonical reaching codegen is a sema gate failure.
///
///   Import law: CodegenContext only.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::ParamMode::*;
import AST::LangItems::*;
import Token::TokenKind::*;
import Location::SourceManager::*;

/// VisibilityKind enumerator values (AST/Mixin/Annotation.k): None,
/// Private, Protected, Public, Internal. Read through vis_of() and nowhere
/// else. InheritEdge's comment claims 0 none / pub / prot / priv; that
/// order is wrong, and trusting it inverted the header's pub filter.
eval fn VIS_NONE() -> u8 { return 0; }
eval fn VIS_PRIV() -> u8 { return 1; }
eval fn VIS_PROT() -> u8 { return 2; }
eval fn VIS_PUB()  -> u8 { return 3; }

class CXXSpell {
    priv var _cg: obs::<CodegenContext>;

    fn CXXSpell(self) { self._cg = &null; }
    fn CXXSpell(self, cg: *CodegenContext) { self._cg = cg; }

    // --- Decl facts ------------------------------------------------------------

    /// THE visibility read. One line to fix if the mixin spells it otherwise.
    static fn vis_of(d: *Decl) -> u8 {
        if d == &null { return VIS_NONE(); }
        return static_cast::<u8>(d->visibility);
    }

    /// The entity's representative (redecl canonical).
    static fn rep(d: *Decl) -> *Decl {
        if d == &null { return &null; }
        switch d->kind {
            case DeclKind::ClassDecl     { return static_cast::<*Decl>(cast::<ClassDecl>(d)->canonical_decl());     }
            case DeclKind::StructDecl    { return static_cast::<*Decl>(cast::<StructDecl>(d)->canonical_decl());    }
            case DeclKind::UnionDecl     { return static_cast::<*Decl>(cast::<UnionDecl>(d)->canonical_decl());     }
            case DeclKind::EnumDecl      { return static_cast::<*Decl>(cast::<EnumDecl>(d)->canonical_decl());      }
            case DeclKind::InterfaceDecl { return static_cast::<*Decl>(cast::<InterfaceDecl>(d)->canonical_decl()); }
            case DeclKind::FunctionDecl  { return static_cast::<*Decl>(cast::<FunctionDecl>(d)->canonical_decl());  }
            case DeclKind::ModuleDecl    { return static_cast::<*Decl>(cast::<ModuleDecl>(d)->canonical_decl());    }
            default { return d; }
        }
        return d;
    }

    /// The DeclContext a scope-owning decl IS, or null.
    static fn dc_of(d: *Decl) -> *DeclContext {
        if d == &null { return &null; }
        switch d->kind {
            case DeclKind::ClassDecl     { return static_cast::<*DeclContext>(cast::<ClassDecl>(d));     }
            case DeclKind::StructDecl    { return static_cast::<*DeclContext>(cast::<StructDecl>(d));    }
            case DeclKind::UnionDecl     { return static_cast::<*DeclContext>(cast::<UnionDecl>(d));     }
            case DeclKind::EnumDecl      { return static_cast::<*DeclContext>(cast::<EnumDecl>(d));      }
            case DeclKind::InterfaceDecl { return static_cast::<*DeclContext>(cast::<InterfaceDecl>(d)); }
            case DeclKind::FunctionDecl  { return static_cast::<*DeclContext>(cast::<FunctionDecl>(d));  }
            case DeclKind::ModuleDecl    { return static_cast::<*DeclContext>(cast::<ModuleDecl>(d));    }
            case DeclKind::ExtensionDecl { return static_cast::<*DeclContext>(cast::<ExtensionDecl>(d)); }
            default { return &null; }
        }
        return &null;
    }

    /// The TU a DeclContext chain bottoms out in.
    static fn tu_of_dc(dc: *DeclContext) -> *TranslationUnit {
        var c = dc;
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit {
                return static_cast::<*TranslationUnit>(c);
            }
            c = c->dc_parent;
        }
        return &null;
    }

    static fn tu_of(d: *Decl) -> *TranslationUnit {
        if d == &null { return &null; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if dc == &null { dc = reinterpret_cast::<*DeclContext>(d->lexical_dc); }
        if dc == &null {
            // A scope owner with no parent link (an ExtensionDecl has no
            // semantic_dc): use its own chain, or fid_of answers u32(-1)
            // and friends_of rejects every extension member.
            var own = CXXSpell::dc_of(d);
            if own != &null { dc = own->dc_parent; }
        }
        return CXXSpell::tu_of_dc(dc);
    }

    static fn fid_of(d: *Decl) -> u32 {
        var tu = CXXSpell::tu_of(d);
        if tu == &null { return u32(-1); }
        return tu->fid;
    }

    /// A decl's name imm indexes ITS OWN TU's table (hard invariant #2).
    fn imm_name(self, imm: u32, fid: u32) -> string {
        if imm == u32(-1) { return "<?>"; }
        var tcm = self._cg->ctx->tcm;
        if tcm == &null { return "<?>"; }
        var tbl = tcm->get_imm_table_for_fid(fid);
        if tbl == &null { return "<?>"; }
        return tbl->get_ident(imm);
    }

    fn leaf(self, d: *Decl) -> string {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f != &null) && f->is_operator { return self.operator_name(f); }
        var t = decl_name_tok(d);
        return self.imm_name(t.imm, CXXSpell::fid_of(d));
    }

    /// `operator+`, `operator[]`, `operator<=>`; `op as` -> `operator T`;
    /// `op delete` -> `~Owner`; operators C++ cannot spell -> LowerTargets.
    /// l/r on ++/-- is fixity, not part of the name (see op_is_postfix).
    fn operator_name(self, f: *FunctionDecl) -> string {
        var ctx = CXXSpell::tu_of(static_cast::<*Decl>(f))->ctx;
        var sym = "";
        for var i: usize = 0; i < f->op_token.size(); ++i {
            var t = f->op_token[i];
            var s = ctx->get_spelling(t);
            if (i == 0) && (f->op_token.size() == 2) && ((s == "l") || (s == "r")) { continue; }
            sym += self._op_sym(t, ctx);
        }
        if sym == "delete" { return "~" + self.leaf(self.operator_owner(f)); }
        if sym == "as" {
            ICE_IF(f->return_type == &null, "CXXSpell: `op as` with no target type");
            return "operator " + self._type(f->return_type);
        }
        var named = CXXSpell::named_operator(sym, f);
        if named.size() > 0 { return named; }
        return "operator" + sym;
    }

    static fn named_operator(sym: string, f: *FunctionDecl) -> string {
        if sym == "in"    { return (LowerTargets::op_contains()) if (f->params.size() > 1) else (LowerTargets::op_iter()); }
        if sym == "^^"    { return LowerTargets::op_pow(); }
        if sym == "==="   { return LowerTargets::op_deep_eq(); }
        if sym == ".*"    { return LowerTargets::op_dotstar(); }
        if sym == "await" { return LowerTargets::op_await(); }
        return "";
    }

    /// `op r++` / `op r--`: the postfix form, which C++ declares with an
    /// `int` dummy parameter.
    static fn op_is_postfix(f: *FunctionDecl) -> bool {
        if (!f->is_operator) || (f->op_token.size() != 2) { return false; }
        var ctx = CXXSpell::tu_of(static_cast::<*Decl>(f))->ctx;
        return ctx->get_spelling(f->op_token[0]) == "r";
    }

    /// The type an operator belongs to: its class, or its extension's target.
    fn operator_owner(self, f: *FunctionDecl) -> *Decl {
        var lex = reinterpret_cast::<*DeclContext>(f->lexical_dc);
        if (lex != &null) && (lex->dc_kind == DeclContextKind::Extension) {
            var x = cast::<ExtensionDecl>(lex->dc_owner);
            var c = x->target->canonical;
            ICE_IF((c == &null) || (c->kind != TypeKind::RecordType), "CXXSpell: extension operator on a non-record target");
            return CXXSpell::rep(cast::<RecordType>(c)->decl);
        }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        ICE_IF((dc == &null) || (!dc->is_type_scope()), "CXXSpell: operator with no owning type");
        return CXXSpell::rep(dc->dc_owner);
    }

    priv fn _op_sym(self, t: Token, ctx: *ASTContext) -> string {
        switch t.kind {
            case TokenKind::KwAnd    { return "&&"; }
            case TokenKind::KwOr     { return "||"; }
            case TokenKind::KwNot    { return "!";  }
            case TokenKind::KwXor    { return "^";  }
            case TokenKind::KwBitand { return "&";  }
            case TokenKind::KwBitor  { return "|";  }
            case TokenKind::KwCompl  { return "~";  }
            case TokenKind::KwNotEq  { return "!="; }
            case TokenKind::KwAndEq  { return "&="; }
            case TokenKind::KwOrEq   { return "|="; }
            case TokenKind::KwXorEq  { return "^="; }
            default { return ctx->get_spelling(t); }
        }
    }

    /// The module path of a TU as strings: root name + directories + file.
    fn module_segments(self, tu: *TranslationUnit) -> vec::<string> {
        var out = vec::<string>();
        if (tu == &null) || (tu->ctx == &null) { return out; }
        ICE_IF(self._cg->psym == &null, "CXXSpell: no PreprocessorSymbolTable on the CodegenContext");
        // Resolve the SymbolID directly: module_base segments are
        // synthesized and carry no token, so as_string() falls back to a
        // debug rendering that is not a C++ identifier.
        var mb = &(tu->ctx->module_base);
        for var i: usize = 0; i < mb->segments.size(); ++i {
            var p = self._cg->psym->resolve(mb->segments[i].name);
            ICE_IF(p == &null, "CXXSpell: module_base segment is not in the PP symbol table");
            out.push_back(*p);
        }
        return out;
    }

    static fn is_entry_tu(tu: *TranslationUnit) -> bool {
        if (tu == &null) || (tu->ctx == &null) { return true; }
        return tu->ctx->module_base.segments.size() == 0;
    }

    /// The scope a decl's C++ name is qualified from: for an extension
    /// member the extension's parent (an extension is transparent, its
    /// members are free functions in the enclosing module), otherwise the
    /// decl's semantic scope.
    priv fn _home_dc(self, d: *Decl) -> *DeclContext {
        var lex = reinterpret_cast::<*DeclContext>(d->lexical_dc);
        if (lex != &null) && (lex->dc_kind == DeclContextKind::Extension) { return lex->dc_parent; }
        return reinterpret_cast::<*DeclContext>(d->semantic_dc);
    }

    /// Namespace segments (modules only) enclosing \p d, outermost first.
    fn ns_segments(self, d: *Decl) -> vec::<string> {
        var mods = vec::<string>();
        var dc = self._home_dc(d);
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit { break; }
            if dc->dc_kind == DeclContextKind::Module {
                var m = cast::<ModuleDecl>(dc->dc_owner);
                if (m != &null) && (!m->is_anonymous) {
                    mods.push_back(self.imm_name(m->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(m))));
                }
            }
            dc = dc->dc_parent;
        }
        var out = self.module_segments(CXXSpell::tu_of_dc(self._home_dc(d)));
        for var i: usize = 0; i < mods.size(); ++i { out.push_back(mods[mods.size() - 1 - i]); }
        return out;
    }

    /// Enclosing TYPE names for a nested decl, outermost first.
    fn owner_types(self, d: *Decl) -> vec::<string> {
        var rev = vec::<string>();
        var dc = self._home_dc(d);
        while (dc != &null) && dc->is_type_scope() {
            if dc->dc_kind != DeclContextKind::Extension {
                rev.push_back(self.leaf(CXXSpell::rep(dc->dc_owner)));
            }
            dc = dc->dc_parent;
        }
        var out = vec::<string>();
        for var i: usize = 0; i < rev.size(); ++i { out.push_back(rev[rev.size() - 1 - i]); }
        return out;
    }

    /// `::ns::Outer::Inner`. Entry-TU decls have no namespace: `::Name`
    /// resolves inside the unnamed namespace the emitter wraps them in.
    fn qual_name(self, d: *Decl) -> string {
        var r = CXXSpell::rep(d);
        if decl_is_imported(r) { return decl_cxx_spelling(r); }
        var s = "";
        var ns = self.ns_segments(r);
        for var i: usize = 0; i < ns.size(); ++i { s += "::"; s += ns[i]; }
        var ow = self.owner_types(r);
        for var i: usize = 0; i < ow.size(); ++i { s += "::"; s += ow[i]; }
        s += "::";
        s += self.leaf(r);
        return s;
    }

    /// `ns::a::b {` as `namespace a::b`, or "" for the entry TU.
    fn ns_join(self, segs: ref!(vec::<string>)) -> string {
        var s = "";
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 { s += "::"; }
            s += segs[i];
        }
        return s;
    }

    /// `geo/vec.hh` for the TU's module path.
    fn header_path(self, tu: *TranslationUnit) -> string {
        var segs = self.module_segments(tu);
        var s = "";
        for var i: usize = 0; i < segs.size(); ++i {
            if i > 0 { s += "/"; }
            s += segs[i];
        }
        s += ".hh";
        return s;
    }

    // --- Types -------------------------------------------------------------------

    /// C++ spelling of a canonical type. \p subst substitutes the primary's
    /// generic parameters with an instance's args (tier 3). Declarator
    /// shapes (arrays, function pointers) need a name to wrap; use decl().
    fn _type(self, t: *Type, subst: *InstanceEntry = &null) -> string {
        return self.decl(t, "", subst);
    }

    /// `type name` with the declarator folded in: `int x`, `int (*f)(int)`.
    /// Empty \p name gives the abstract form.
    fn decl(self, t_in: *Type, name: string, subst: *InstanceEntry = &null) -> string {
        if t_in == &null { return self._join("void", name); }
        var t = t_in->canonical;
        ICE_IF(t == &null, "CXXSpell: type with no canonical reached codegen (sema gate failure)");

        switch t->kind {
            case TypeKind::QualifiedType {
                var q = cast::<QualifiedType>(t);
                var pfx = "";
                if (q->quals & QUAL_CONST())    != 0 { pfx += "const "; }
                if (q->quals & QUAL_VOLATILE()) != 0 { pfx += "volatile "; }
                return pfx + self.decl(q->inner, name, subst);
            }
            case TypeKind::BuiltinType {
                var b = cast::<BuiltinType>(t);
                if b->builtin == BuiltinKind::Never { return self._join("void", name); }
                return self._join(b->cxx_emission(), name);
            }
            case TypeKind::RecordType {
                return self._join(self._record(cast::<RecordType>(t), subst), name);
            }
            case TypeKind::PointerType {
                return self.decl(cast::<PointerType>(t)->pointee, "*" + name, subst);
            }
            case TypeKind::CXXLValueRefType {
                return self.decl(cast::<CXXLValueRefType>(t)->referee, "&" + name, subst);
            }
            case TypeKind::CXXRValueRefType {
                return self.decl(cast::<CXXRValueRefType>(t)->referee, "&&" + name, subst);
            }
            case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(t);
                var ext = "";
                if !a->is_incomplete { ext = f"{a->size_bits}"; }
                return self.decl(a->element, f"{name}[{ext}]", subst);
            }
            case TypeKind::FunctionPointerType {
                var f = cast::<FunctionPointerType>(t);
                var ps = "";
                for var i: usize = 0; i < f->params.size(); ++i {
                    if i > 0 { ps += ", "; }
                    ps += self._param_type(f->params[i], f->modes[i], false, subst);
                }
                return self.decl(f->return_type, f"(*{name})({ps})", subst);
            }
            case TypeKind::GenericParamType {
                return self._join(self._gparam(cast::<GenericParamType>(t), subst), name);
            }
            case TypeKind::OpaqueFFIType {
                var o = cast::<OpaqueFFIType>(t);
                return self._join(self.imm_name(o->name, self._cg->tu->fid), name);
            }
            case TypeKind::NullableType { ICE_FAIL("CXXSpell: T? reached codegen; NullableTypeLowering must reduce it first"); }
            case TypeKind::TupleType  { ICE_FAIL("CXXSpell: tuple type reached codegen; no lowering exists yet"); }
            default {
                ICE_FAIL(f"CXXSpell: {to_string(t->kind)} is not a canonical kind");
            }
        }
        return "";
    }

    /// A parameter's C++ type from its mode (AST/ParamMode.k rules, as
    /// EmitIR documents them). \p is_const is the `const x: T` marker.
    fn param_type(self, p: *ParamDecl, subst: *InstanceEntry = &null) -> string {
        return self._param_type(p->type_, p->mode, p->is_const, subst);
    }

    priv fn _param_type(self, t: *Type, mode: ParamMode, is_const: bool, subst: *InstanceEntry) -> string {
        if mode == ParamMode::Inout { return self._type(t, subst) + "&"; }
        if mode == ParamMode::Move  { return self._type(t, subst) + "&&"; }
        if is_const {
            // `const T&` iff a non-generic record; `const T` otherwise.
            var c = t->canonical;
            if (c != &null) && (c->kind == TypeKind::RecordType) && (!c->is_dependent()) {
                return "const " + self._type(t, subst) + "&";
            }
            return "const " + self._type(t, subst);
        }
        return self._type(t, subst);
    }

    /// `<a, b>` from an instance's args or a pattern's own params.
    fn args_str(self, args: *vec::<*Type>, subst: *InstanceEntry = &null) -> string {
        var s = "<";
        for var i: usize = 0; i < args->size(); ++i {
            if i > 0 { s += ", "; }
            s += self._type((*args)[i], subst);
        }
        s += ">";
        return s;
    }

    /// `template <class T, class... Ts, int N>` for a generic decl; "" otherwise.
    fn template_head(self, d: *Decl) -> string {
        var gps = decl_generic_params(d);
        if gps.size() == 0 { return ""; }
        var s = "template <";
        for var i: usize = 0; i < gps.size(); ++i {
            var gp = gps[i];
            if i > 0 { s += ", "; }
            if gp->is_const_param {
                s += self._type(gp->value_type);
            } else {
                s += "class";
            }
            if gp->is_pack { s += "..."; }
            s += " ";
            s += self.imm_name(gp->name.imm, CXXSpell::fid_of(d));
        }
        s += "> ";
        return s;
    }

    // --- internals ---------------------------------------------------------------

    priv fn _join(self, ty: string, name: string) -> string {
        if name.size() == 0 { return ty; }
        // A declarator that starts with `*`/`&`/`(` binds without a space.
        var c = name[0];
        if (c == '*') || (c == '&') || (c == '(') || (c == '[') { return ty + name; }
        return ty + " " + name;
    }

    priv fn _record(self, r: *RecordType, subst: *InstanceEntry) -> string {
        var d = r->decl;
        ICE_IF(d == &null, "CXXSpell: RecordType with no decl");
        ICE_IF(isa::<InterfaceDecl>(d), "CXXSpell: an interface has no C++ type; witnesses are not emitted yet");
        if decl_is_imported(d) { return decl_cxx_spelling(d); }

        // An instance shell names its PRIMARY plus the registry's args.
        if decl_is_instance(d) {
            var e = self._cg->instances->entry_of(d);
            ICE_IF(e == &null, "CXXSpell: instance shell with no registry entry");
            return self.qual_name(e->primary) + self.args_str(&(e->args), subst);
        }
        var s = self.qual_name(d);
        if r->args.size() > 0 {
            var v = vec::<*Type>();
            for var i: usize = 0; i < r->args.size(); ++i { v.push_back(r->args[i]); }
            s += self.args_str(&v, subst);
        }
        return s;
    }

    priv fn _gparam(self, g: *GenericParamType, subst: *InstanceEntry) -> string {
        ICE_IF(g->owner == &null, "CXXSpell: canonical generic param with no owner");
        var owner = CXXSpell::rep(g->owner);
        if (subst != &null) && (CXXSpell::rep(subst->primary) == owner) {
            ICE_IF(static_cast::<usize>(g->param_index) >= subst->args.size(),
                "CXXSpell: instance args shorter than the primary's parameter list");
            return self._type(subst->args[static_cast::<usize>(g->param_index)], &null);
        }
        ICE_IF(g->is_pack, "CXXSpell: pack parameter in a non-expansion position");
        var gps = decl_generic_params(owner);
        ICE_IF(static_cast::<usize>(g->param_index) >= gps.size(), "CXXSpell: generic param index out of range");
        return self.imm_name(gps[static_cast::<usize>(g->param_index)]->name.imm, CXXSpell::fid_of(owner));
    }
}