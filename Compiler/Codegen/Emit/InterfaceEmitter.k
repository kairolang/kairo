/// --- The Kairo Project ---------------- Codegen/Emit/InterfaceEmitter.k --- ///
///
///   \brief Emit an EmitPlan as C++ declarations. Two callers, one emitter
///          (IMPORTS.md §6.6): Backend for a TU's preamble (TokenSink),
///          EmitCXXHeader for the module's interop header (TextSink).
///
///   \par Text fragments, one per declaration
///     Every declaration is built as a C++ string and landed through
///     EmitSink::spell() anchored on the decl's name span. The string is a
///     pure function of the decl, so the same class is the same bytes in
///     every TU and in the header. That is the whole ODR argument, and it
///     is why nothing here is per-sink.
///
///   \par What is NOT emitted (each an ICE naming its owner)
///     ADT enums (EnumLayoutLowering), unions (later), interfaces (no
///     entity; witnesses MISSING), parameter defaults and field
///     initializers (expression emission across TUs), packs in expansion
///     position, structural containers (the container migration).
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
import Codegen::EmitPlan::*;
import Codegen::Emit::CXXSpell::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Kind::ExprKind::*;
import Location::SourceRange::*;
import Token::TokenKind::*;

__inline_cpp("
#define sink this->_cg->sink
");

class InterfaceEmitter {
    priv var _cg:    obs::<CodegenContext>;
    priv var _plan:  obs::<EmitPlan>;
    priv var _spell: obs::<CXXSpell>;

    fn InterfaceEmitter(self, cg: *CodegenContext, plan: *EmitPlan) {
        self._cg    = cg;
        self._plan  = plan;
        self._spell = plan->spell();
    }

    // --- Entry point -------------------------------------------------------------

    fn run(self) {
        var header = (self._plan->mode() == PlanMode::Header);
        if header {
            self._header_prologue();
        } else {
            // The array-prvalue alias, once per TU, ahead of every body that
            // can name it. A header carries no bodies and needs none.
            sink->spell(self._tu_at(),
                "template <class T, decltype(sizeof(0)) N> using " + LowerTargets::array_alias() + " = T[N];");
            sink->brk();
        }

        var i: usize = 0;
        var n = self._plan->entries.size();

        // tier 0: consecutive same-namespace entries share one wrapper.
        while (i < n) && (self._plan->entries[i].tier == PlanTier::FwdDecls) {
            var e = &(self._plan->entries[i]);
            var ns = self._spell->ns_segments(e->decl);
            // The unnamed nesting is part of the wrapper, so a run shares one
            // only if it agrees on that too: grouping on the segments alone
            // would put a `priv` decl in a `pub` decl's namespace.
            var anon = CXXSpell::is_anon(e->decl);
            var opened = self._ns_open(e->decl, ns, anon);
            while (i < n) && (self._plan->entries[i].tier == PlanTier::FwdDecls) {
                var f = &(self._plan->entries[i]);
                var fns = self._spell->ns_segments(f->decl);
                if !self._same_ns(ns, fns) { break; }
                if CXXSpell::is_anon(f->decl) != anon { break; }
                if header && (!f->own) && (f->need == PlanNeed::Complete) { i += 1; continue; }   // included.
                self._fwd_decl(f->decl);
                i += 1;
            }
            self._ns_close(opened);
        }

        // tier 1
        while (i < n) && (self._plan->entries[i].tier == PlanTier::Definitions) {
            var e = &(self._plan->entries[i]);
            i += 1;
            if header && (!e->own) { continue; }   // its header was included.
            self._wrapped(e->decl, fn () { self._type_def(e->decl); });
        }

        // tier 2
        while (i < n) && (self._plan->entries[i].tier == PlanTier::Functions) {
            var e = &(self._plan->entries[i]);
            i += 1;
            if header && (!e->own) { continue; }
            // EmitIR defines main at global scope as `int main`; a prior
            // declaration buys nothing, and inside the file's namespace it
            // would declare a different function.
            if self._is_entry_main(e->decl) { continue; }
            self._wrapped(e->decl, fn () { self._free_fn_decl(cast::<FunctionDecl>(e->decl), e->ext); });
        }

        // tier 3
        while (i < n) && (self._plan->entries[i].tier == PlanTier::Instantiations) {
            var e = &(self._plan->entries[i]);
            i += 1;
            if e->is_home { continue; }        // definitions come after the bodies; see emit_home_instantiations
            self._instantiation(e);
        }
    }

    /// Explicit instantiation DEFINITIONS, emitted by the backend after every
    /// body: an explicit instantiation only instantiates members defined
    /// before it.
    fn emit_home_instantiations(self) {
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if (e->tier != PlanTier::Instantiations) || (!e->is_home) { continue; }
            self._instantiation(e);
        }
    }

    // --- Header prologue -----------------------------------------------------------

    /// `#pragma once`, then one `#include` per foreign module reached at
    /// Complete. Kairo forbids import cycles, so the include graph is a DAG.
    priv fn _header_prologue(self) {
        var at = self._tu_at();
        sink->directive(at, "#pragma once");
        var seen = vec::<string>();
        for var i: usize = 0; i < self._plan->entries.size(); ++i {
            var e = &(self._plan->entries[i]);
            if e->own { continue; }
            if e->need != PlanNeed::Complete { continue; }
            if e->tier == PlanTier::Instantiations { continue; }
            var p = self._spell->header_path(CXXSpell::tu_of(e->decl));
            var dup = false;
            for var j: usize = 0; j < seen.size(); ++j { if seen[j] == p { dup = true; break; } }
            if dup { continue; }
            seen.push_back(p);
            var line = "#include \x22";
            line += p;
            line += "\x22";
            sink->directive(at, line);
        }
    }

    // --- Namespace wrapping ----------------------------------------------------------

    priv fn _same_ns(self, a: ref!(vec::<string>), b: ref!(vec::<string>)) -> bool {
        if a.size() != b.size() { return false; }
        for var i: usize = 0; i < a.size(); ++i { if a[i] != b[i] { return false; } }
        return true;
    }

    /// Returns how many braces were opened: the named namespace, plus an
    /// unnamed one nested in it for a decl with no linkage outside its file.
    priv fn _ns_open(self, d: *Decl, ns: ref!(vec::<string>), anon: bool) -> u32 {
        var at = self._at(d);
        var n: u32 = 0;
        if ns.size() > 0 {
            var s = "namespace ";
            s += self._spell->ns_join(ns);
            s += " {";
            sink->spell(at, s);
            n += 1;
        }
        if anon { sink->spell(at, "namespace {"); n += 1; }
        return n;
    }

    priv fn _ns_close(self, n: u32) {
        // Closing braces anchored on nothing better than the TU: the wrapper
        // has no bytes of its own.
        for var i: u32 = 0; i < n; ++i { sink->spell(self._tu_at(), "}"); }
        if n > 0 { sink->brk(); }
    }

    priv fn _wrapped(self, d: *Decl, body: fn()) {
        var ns = self._spell->ns_segments(d);
        var opened = self._ns_open(d, ns, CXXSpell::is_anon(d));
        body();
        self._ns_close(opened);
    }

    priv fn _is_entry_main(self, d: *Decl) -> bool {
        if !isa::<FunctionDecl>(d) { return false; }
        if !CXXSpell::is_entry_tu(CXXSpell::tu_of(d)) { return false; }
        return self._spell->leaf(d) == "main";
    }

    priv fn _at(self, d: *Decl) -> SourceRange {
        return CXXSpell::at(d);
    }

    /// Byte 0 of the TU: the anchor for tokens that have no bytes of their
    /// own (a directive, a namespace's closing brace).
    priv fn _tu_at(self) -> SourceRange {
        return self._cg->ctx->sm->get_range(self._cg->tu->fid, 0, 1);
    }

    // --- Tier 0 ----------------------------------------------------------------------

    priv fn _fwd_decl(self, d: *Decl) {
        var s = self._spell->template_head(d);
        switch d->kind {
            case DeclKind::ClassDecl  { s += "class ";  }
            case DeclKind::StructDecl { s += "struct "; }
            case DeclKind::UnionDecl  { ICE_FAIL("InterfaceEmitter: union emission is not implemented yet"); }
            case DeclKind::EnumDecl {
                var en = cast::<EnumDecl>(d);
                ICE_IF(en->is_adt, "InterfaceEmitter: ADT enum reached codegen; EnumLayoutLowering must reduce it to a record first");
                s += "enum class ";
                s += self._spell->leaf(d);
                s += " : ";
                s += self._enum_underlying(en);
                s += ";";
                sink->spell(self._at(d), s);
                return;
            }
            default { ICE_FAIL("InterfaceEmitter: not a type decl"); }
        }
        s += self._spell->leaf(d);
        s += ";";
        sink->spell(self._at(d), s);
    }

    priv fn _enum_underlying(self, en: *EnumDecl) -> string {
        if en->underlying != &null { return self._spell->_type(en->underlying); }
        return builtin_info(BuiltinKind::U32)->cxx;   // Kairo's default enum width.
    }

    // --- Tier 1 ----------------------------------------------------------------------

    priv fn _type_def(self, d: *Decl) {
        switch d->kind {
            case DeclKind::ClassDecl  { self._record_def(d, "class");  }
            case DeclKind::StructDecl { self._record_def(d, "struct"); }
            case DeclKind::EnumDecl   { self._enum_def(cast::<EnumDecl>(d)); }
            case DeclKind::UnionDecl  { ICE_FAIL("InterfaceEmitter: union emission is not implemented yet"); }
            default { ICE_FAIL("InterfaceEmitter: not a type decl"); }
        }
    }

    /// The definition, body-less (invariant 12): bases, nested types,
    /// fields, method declarations, friends. Field initializers and
    /// parameter defaults are not emitted; see the file header.
    priv fn _record_def(self, d: *Decl, kw: string) {
        var at = self._at(d);
        var is_class = (d->kind == DeclKind::ClassDecl);
        var s = self._spell->template_head(d);
        s += kw;
        s += " ";
        s += self._spell->leaf(d);

        if is_class {
            var n = cast::<ClassDecl>(d);
            for var i: usize = 0; i < n->derives_list.size(); ++i {
                var e = n->derives_list.get(i);
                if e == &null { continue; }
                s += (" : ") if (i == 0) else (", ");
                if e->is_virtual { s += "virtual "; }
                s += self._base_access(e->visibility);
                s += " ";
                s += self._spell->_type(e->base);
            }
        }
        s += " {";
        sink->spell(at, s);

        // Default access follows the keyword: a Kairo struct's members are
        // public unless marked, a class's private unless marked.
        var cur_access = (VIS_PRIV()) if (is_class) else (VIS_PUB());

        // Nested types first: a field may name one.
        var dc = CXXSpell::dc_of(d);
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var nd = *(dc->dc_decls.get(i));
                if nd == &null { continue; }
                if isa::<VisibilityGroupDecl>(nd) { continue; }   // members are pointers back into the lists below.
                if !self._is_type(nd) { continue; }
                cur_access = self._access(cur_access, CXXSpell::vis_of(nd), is_class, at);
                self._type_def(CXXSpell::rep(nd));
            }
        }

        var fields  = (cast::<ClassDecl>(d)->fields)  if (is_class) else (cast::<StructDecl>(d)->fields);
        var methods = (cast::<ClassDecl>(d)->methods) if (is_class) else (cast::<StructDecl>(d)->methods);

        for var i: usize = 0; i < fields.size(); ++i {
            var f = fields[i];
            if f == &null { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(f)), is_class, at);
            var fs = "";
            if f->is_static()  { fs += "static "; }
            if f->is_mutable   { fs += "mutable "; }
            if f->is_const()   { fs += "const "; }
            fs += self._spell->decl(f->type_, self._spell->leaf(static_cast::<*Decl>(f)));
            fs += ";";
            sink->spell(f->name.range, fs);
        }

        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if m == &null { continue; }
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(m)), is_class, at);
            sink->spell(self._at(static_cast::<*Decl>(m)), self._method_decl(m, d));
        }

        // Friends: same-file extension members, so a free function written
        // beside the type can reach its privates. Only where the extension's
        // namespace is the type's own; a differently-scoped friend would need
        // a prior declaration the plan does not order for.
        var fr = vec::<*FunctionDecl>();
        self._plan->friends_of(d, fr);
        var my_ns = self._spell->ns_segments(d);
        for var i: usize = 0; i < fr.size(); ++i {
            var f = fr[i];
            var fns = self._spell->ns_segments(static_cast::<*Decl>(f));
            if !self._same_ns(my_ns, fns) { continue; }
            var x = reinterpret_cast::<*DeclContext>(f->lexical_dc);
            var xd = dyn_cast::<ExtensionDecl>(x->dc_owner);
            sink->spell(self._at(static_cast::<*Decl>(f)), "friend " + self._free_fn_text(f, xd));
            if self._cg->opts.extension_member_wrappers {
                ICE_FAIL("InterfaceEmitter: extension_member_wrappers is on but wrapper emission is not written; leave it off");
            }
        }

        sink->spell(at, "};");
        sink->brk();
    }

    priv fn _is_type(self, d: *Decl) -> bool {
        return (d->kind == DeclKind::ClassDecl) || (d->kind == DeclKind::StructDecl)
            || (d->kind == DeclKind::EnumDecl)  || (d->kind == DeclKind::UnionDecl);
    }

    /// Emit an access specifier when the member's visibility differs from
    /// the running one. `prot` is `protected`.
    priv fn _access(self, cur: u8, want_in: u8, is_class: bool, at: SourceRange) -> u8 {
        var want = want_in;
        if want == VIS_NONE() { want = (VIS_PRIV()) if (is_class) else (VIS_PUB()); }
        if want == cur { return cur; }
        if want == VIS_PUB()  { sink->spell(at, "public:"); }
        if want == VIS_PROT() { sink->spell(at, "protected:"); }
        if want == VIS_PRIV() { sink->spell(at, "private:"); }
        sink->brk();
        return want;
    }

    priv fn _base_access(self, v: u8) -> string {
        if v == VIS_PRIV() { return "private"; }
        if v == VIS_PROT() { return "protected"; }
        return "public";
    }

    priv fn _enum_def(self, en: *EnumDecl) {
        ICE_IF(en->is_adt, "InterfaceEmitter: ADT enum reached codegen; EnumLayoutLowering must reduce it to a record first");
        var at = self._at(static_cast::<*Decl>(en));
        var s = "enum class ";
        s += self._spell->leaf(static_cast::<*Decl>(en));
        s += " : ";
        s += self._enum_underlying(en);
        s += " {";
        sink->spell(at, s);
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v == &null { continue; }
            var vs = self._spell->leaf(static_cast::<*Decl>(v));
            if v->discriminant != &null {
                // A NEGATIVE discriminant is a prefix `-` over the literal, not
                // a literal -- `Ordering::Less = -1` in the builtin root is the
                // first one to reach here. The sign is emitted ahead of the
                // token; anything else still needs the constant evaluator.
                var dexpr = v->discriminant;
                var sign  = "";
                if isa::<UnaryOperatorExpr>(dexpr) {
                    var u = cast::<UnaryOperatorExpr>(dexpr);
                    if u->fix == UnaryOperatorExpr::Fix::Prefix {
                        if u->op_token.kind == TokenKind::OpMinus { sign  = "-"; dexpr = u->operand; }
                        else if u->op_token.kind == TokenKind::OpPlus { dexpr = u->operand; }
                    }
                }
                var lit = dyn_cast::<IntegerLiteralExpr>(dexpr);
                ICE_IF(lit == &null, "InterfaceEmitter: non-literal enum discriminant; needs the constant evaluator");
                vs += " = " + sign;
                sink->spell(v->name.range, vs);
                sink->literal(lit->token.range, clang::tok::numeric_constant);
                sink->spell(v->name.range, ",");
                continue;
            }
            vs += ",";
            sink->spell(v->name.range, vs);
        }
        sink->spell(at, "};");
        sink->brk();
    }

    // --- Functions ---------------------------------------------------------------------

    /// A method declaration inside its class. `self` is dropped (it is
    /// `this`); a function without `self` is `static`.
    priv fn _method_decl(self, m: *FunctionDecl, owner: *Decl) -> string {
        ICE_IF(m->is_variadic, "InterfaceEmitter: variadic pack parameters are not emitted yet");
        var s = self._spell->template_head(static_cast::<*Decl>(m));
        var is_ctor = self._is_ctor(m, owner);
        // One spelling, computed once. `op delete` comes back from leaf() as
        // `~Owner` already, so the leading `~` IS the destructor test -- there
        // is no second place that knows how a destructor is named.
        var nm = self._spell->leaf(m);
        var is_dtor = m->is_operator && (nm[0] == '~');
        // `op as` spells `operator T`; C++ gives a conversion no return type.
        var is_conv = m->is_operator && (m->op_token[0].kind == TokenKind::KwAs);
        var is_method = m->is_method();

        if (!is_method) && (!is_ctor) && !is_dtor { s += "static "; }
        if (m->abi == AbiKind::Virtual) || (m->abi == AbiKind::Override) || (m->body_kind == FnBodyKind::Virtual) { s += "virtual "; }
        if m->is_noreturn { s += "[[noreturn]] "; }

        if is_ctor {
            s += self._spell->leaf(owner);
        } else if is_dtor || is_conv {
            s += nm;
        } else {
            s += self._ret(m);
            s += " ";
            s += nm;
        }
        s += "(";
        s += self._params(m, false, &null);
        s += ")";
        if is_method && m->is_const() { s += " const"; }
        if m->abi == AbiKind::Override { s += " override"; }
        s += self._body_suffix(m);
        s += ";";
        return s;
    }

    priv fn _free_fn_decl(self, f: *FunctionDecl, ext: *ExtensionDecl) {
        sink->spell(self._at(static_cast::<*Decl>(f)), self._free_fn_text(f, ext));
    }

    /// A namespace-scope declaration. An extension member keeps its receiver
    /// as an explicit first parameter (`Self*` / `const Self*`).
    priv fn _free_fn_text(self, f: *FunctionDecl, ext: *ExtensionDecl) -> string {
        ICE_IF(f->is_variadic, "InterfaceEmitter: variadic pack parameters are not emitted yet");
        var s = "";
        if ext != &null { s += self._spell->template_head(static_cast::<*Decl>(ext)); }
        s += self._spell->template_head(static_cast::<*Decl>(f));
        if f->is_noreturn { s += "[[noreturn]] "; }
        s += self._ret(f);
        s += " ";
        s += self._fn_name(f);
        s += "(";
        s += self._params(f, ext != &null, ext);
        s += ");";
        return s;
    }

    priv fn _params(self, f: *FunctionDecl, with_self: bool, ext: *ExtensionDecl) -> string {
        var s = "";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            ICE_IF(p->default_val != &null, "InterfaceEmitter: parameter default values are not emitted yet");
            if p->is_self {
                if !with_self { continue; }
                ICE_IF(ext == &null, "InterfaceEmitter: `self` outside a type or extension");
                if !first { s += ", "; }
                first = false;
                if f->is_const() { s += "const "; }
                s += self._spell->_type(ext->target);
                s += "* self";
                continue;
            }
            if !first { s += ", "; }
            first = false;
            var nm = "";
            if !p->unname { nm = self._spell->imm_name(p->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(f))); }
            s += self._spell->param_decl(p, nm);
        }
        // C++ distinguishes postfix `++`/`--` from prefix by an unnamed `int`
        // parameter. Kairo says `op r++`, so the dummy is invented here.
        if CXXSpell::op_is_postfix(f) {
            if !first { s += ", "; }
            s += "int";
        }
        return s;
    }

    priv fn _ret(self, f: *FunctionDecl) -> string {
        if f->is_noreturn || (f->return_type == &null) { return "void"; }
        return self._spell->return_spelling(f, &null);
    }

    priv fn _fn_name(self, f: *FunctionDecl) -> string {
        return self._spell->leaf(static_cast::<*Decl>(f));
    }

    priv fn _is_ctor(self, m: *FunctionDecl, owner: *Decl) -> bool {
        if m->is_operator { return false; }
        return self._spell->leaf(static_cast::<*Decl>(m)) == self._spell->leaf(owner);
    }

    priv fn _body_suffix(self, f: *FunctionDecl) -> string {
        switch f->body_kind {
            case FnBodyKind::Virtual { return " = 0"; }
            case FnBodyKind::Delete  { return " = delete"; }
            case FnBodyKind::Default { return " = default"; }
            default { return ""; }
        }
        return "";
    }

    // --- Tier 3 -----------------------------------------------------------------------

    /// `template class X<A>;` in the home TU, `extern template ...` elsewhere.
    /// A function instance spells its signature with the args substituted.
    priv fn _instantiation(self, e: *PlanEntry) {
        var d  = e->decl;
        var ie = e->inst;
        var s  = ("") if (e->is_home) else ("extern ");
        s += "template ";
        if isa::<FunctionDecl>(d) {
            var f = cast::<FunctionDecl>(d);
            s += self._ret_subst(f, ie);
            s += " ";
            s += self._spell->qual_name(d);
            s += self._spell->args_str(&(ie->args));
            s += "(";
            var first = true;
            for var i: usize = 0; i < f->params.size(); ++i {
                var p = f->params[i];
                if (p == &null) || p->is_self { continue; }
                if !first { s += ", "; }
                first = false;
                s += self._spell->param_decl(p, "", ie);
            }
            s += ");";
        } else {
            s += ("class ") if (d->kind == DeclKind::ClassDecl) else ("struct ");
            s += self._spell->qual_name(d);
            s += self._spell->args_str(&(ie->args));
            s += ";";
        }
        sink->spell(self._at(d), s);
        sink->brk();
    }

    priv fn _ret_subst(self, f: *FunctionDecl, ie: *InstanceEntry) -> string {
        if f->is_noreturn || (f->return_type == &null) { return "void"; }
        return self._spell->return_spelling(f, ie);
    }
}

__inline_cpp("
#undef sink
");