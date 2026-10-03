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
            // The materialized-temporary helper: the one place it is spelled.
            // A forwarding reference binds the prvalue, so the address is the
            // temporary's, which lives to the end of the full-expression.
            sink->spell(self._tu_at(),
                "template <class T> auto* " + LowerTargets::tmp_addr() + "(T&& t) { return __builtin_addressof(t); }");
            sink->brk();
        }

        var i: usize = 0;
        var n = self._plan->entries.size();

        // tier 0: consecutive same-namespace entries share one wrapper.
        while (i < n) && (self._plan->entries[i].tier == PlanTier::FwdDecls) {
            var e = &(self._plan->entries[i]);
            var ns = self._entry_ns(e);
            // The unnamed nesting is part of the wrapper, so a run shares one
            // only if it agrees on that too: grouping on the segments alone
            // would put a `priv` decl in a `pub` decl's namespace.
            var anon = self._entry_anon(e);
            var opened = self._ns_open(e->decl, ns, anon);
            while (i < n) && (self._plan->entries[i].tier == PlanTier::FwdDecls) {
                var f = &(self._plan->entries[i]);
                var fns = self._entry_ns(f);
                if !self._same_ns(ns, fns) { break; }
                if self._entry_anon(f) != anon { break; }
                if header && (!f->own) && (f->need == PlanNeed::Complete) { i += 1; continue; }   // included.
                if f->scope != &null {
                    sink->spell(self._at(f->decl), "struct " + f->scope->name + ";");
                } else {
                    self._fwd_decl(f->decl);
                }
                i += 1;
            }
            self._ns_close(opened);
        }

        // tier 1
        while (i < n) && (self._plan->entries[i].tier == PlanTier::Definitions) {
            var e = &(self._plan->entries[i]);
            i += 1;
            if header && (!e->own) { continue; }   // its header was included.
            if e->scope != &null {
                var opened = self._ns_open(e->decl, e->scope->ns, false);
                self._scope_def(e->scope);
                self._ns_close(opened);
                continue;
            }
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
            self._wrapped(e->decl, fn () { self._free_fn_decl(cast::<FunctionDecl>(e->decl), &null); });
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

    /// A plan entry's namespace: an extension scope's own, else its decl's.
    priv fn _entry_ns(self, e: *PlanEntry) -> vec::<string> {
        if e->scope != &null { return e->scope->ns; }
        return self._spell->ns_segments(e->decl);
    }

    /// An extension scope is never in the unnamed namespace: its members
    /// are reached as `::N::__kairo_ext_X::m` from other TUs' preambles,
    /// and a priv member is AccessCheck's to hide, not linkage's.
    priv fn _entry_anon(self, e: *PlanEntry) -> bool {
        if e->scope != &null { return false; }
        return CXXSpell::is_anon(e->decl);
    }

    priv fn _scope_qual(self, s: *ExtScope) -> string {
        var q = "";
        for var i: usize = 0; i < s->ns.size(); ++i { q += "::"; q += s->ns[i]; }
        return q + "::" + s->name;
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
        // Unreachable for an empty TU (the driver skips it on EmitPlan::
        // is_empty), but a zero-byte file has no byte 0: anchor at the end
        // position instead, which a zero-length range may name.
        var fid = self._cg->tu->fid;
        if self._cg->ctx->sm->get_file_size(fid) == 0 { return self._cg->ctx->sm->get_range(fid, 0, 0); }
        return self._cg->ctx->sm->get_range(fid, 0, 1);
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
        // public unless marked; in a class only the VARIABLES are private
        // unless marked, and methods, constructors and nested types are
        // public (classes.md, Default visibility).
        var cur_access = (VIS_PRIV()) if (is_class) else (VIS_PUB());

        // Nested types first: a field may name one.
        var dc = CXXSpell::dc_of(d);
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var nd = *(dc->dc_decls.get(i));
                if nd == &null { continue; }
                if isa::<VisibilityGroupDecl>(nd) { continue; }   // members are pointers back into the lists below.
                if !self._is_type(nd) { continue; }
                cur_access = self._access(cur_access, CXXSpell::vis_of(nd), false, at);
                self._type_def(CXXSpell::rep(nd));
            }

            // Member aliases, in declaration order, before any field or
            // method: an alias is usually named in the record's own
            // signatures (`promise_type`, which <coroutine>'s primary reads as
            // `typename R::promise_type`), and a C++ declaration cannot use a
            // member declared below it -- only a body sees the whole class.
            // After the nested types, because an alias may name one. An alias
            // can only refer to what the record itself can name, and Kairo
            // does not let it name a later field, so hoisting is safe.
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var nd = *(dc->dc_decls.get(i));
                if (nd == &null) || (!isa::<TypeAliasDecl>(nd)) { continue; }
                var ta = cast::<TypeAliasDecl>(nd);
                if ta->aliased == &null { continue; }
                cur_access = self._access(cur_access, CXXSpell::vis_of(nd), false, at);
                var us = self._spell->template_head(nd);
                us += "using " + self._spell->leaf(nd) + " = " + self._spell->_type(ta->aliased) + ";";
                sink->spell(self._at(nd), us);
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
            cur_access = self._access(cur_access, CXXSpell::vis_of(static_cast::<*Decl>(m)), false, at);
            sink->spell(self._at(static_cast::<*Decl>(m)), self._method_decl(m, d));
        }

        // Friends: every same-file extension scope, so an extension member
        // written beside the type can reach its privates. One line per scope
        // covers every member, generic or not, and each struct was declared
        // in tier 0, so its qualified name needs no other prior declaration.
        var fs = vec::<*ExtScope>();
        self._plan->friend_scopes_of(d, &fs);
        for var i: usize = 0; i < fs.size(); ++i {
            sink->spell(self._at(static_cast::<*Decl>(fs[i]->anchor)), "friend struct " + self._scope_qual(fs[i]) + ";");
        }
        if (fs.size() > 0) && self._cg->opts.extension_member_wrappers {
            ICE_FAIL("InterfaceEmitter: extension_member_wrappers is on but wrapper emission is not written; leave it off");
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
    /// \p default_priv: an unmarked member of this kind is private (a class's
    /// variables, and nothing else).
    priv fn _access(self, cur: u8, want_in: u8, default_priv: bool, at: SourceRange) -> u8 {
        var want = want_in;
        if want == VIS_NONE() { want = (VIS_PRIV()) if (default_priv) else (VIS_PUB()); }
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
        if m->no_unwind { s += " noexcept"; }
        if m->abi == AbiKind::Override { s += " override"; }
        s += self._body_suffix(m);
        s += ";";
        return s;
    }

    priv fn _free_fn_decl(self, f: *FunctionDecl, ext: *ExtensionDecl) {
        sink->spell(self._at(static_cast::<*Decl>(f)), self._free_fn_text(f, ext));
    }

    /// A function declaration. With \p ext, an extension member: a static
    /// member of its scope, its receiver an explicit first parameter
    /// (`Self*` / `const Self*`), its template head the merged one (the
    /// extension's, then its own).
    priv fn _free_fn_text(self, f: *FunctionDecl, ext: *ExtensionDecl) -> string {
        var s = self._spell->template_head(static_cast::<*Decl>(f));
        // The attribute leads the decl-specifiers; between `static` and the
        // type it is ill-formed.
        if f->is_noreturn { s += "[[noreturn]] "; }
        if ext != &null { s += "static "; }
        s += self._ret(f);
        s += " ";
        s += self._fn_name(f);
        s += "(";
        s += self._params(f, ext != &null, ext);
        s += ")";
        if f->no_unwind { s += " noexcept"; }
        s += ";";
        return s;
    }

    // --- Extension scopes ----------------------------------------------------------

    /// `struct __kairo_ext_X { static ...; };`, every member declared, then
    /// the operator forwarders. Inside the scope's namespace wrapper. All
    /// members are public: Kairo's visibility is AccessCheck's, not C++
    /// access control's, and the struct must be one text everywhere.
    priv fn _scope_def(self, sc: *ExtScope) {
        var at = self._at(static_cast::<*Decl>(sc->anchor));
        sink->spell(at, "struct " + sc->name + " {");
        for var i: usize = 0; i < sc->members.size(); ++i {
            var m = sc->members[i];
            sink->spell(self._at(static_cast::<*Decl>(m)), self._free_fn_text(m, sc->exts[i]));
        }
        sink->spell(at, "};");
        sink->brk();
        for var i: usize = 0; i < sc->members.size(); ++i {
            var m = sc->members[i];
            if !m->is_operator { continue; }
            self._forwarder(sc, m, sc->exts[i]);
        }
    }

    /// `inline RET operator+(X& __kairo_a0, Y __kairo_a1) { return
    /// ::N::__kairo_ext_X::__kairo_op_plus(__kairo_a0, ...); }`: the C++
    /// operator an extension operator is, for C++ callers. Kairo calls the
    /// static member directly. Every operand is forwarded as its own
    /// declared type (`static_cast<decltype(a)&&>`), so a by-value or
    /// `@move` operand moves on and an `@inout` one stays an lvalue; the
    /// postfix dummy is passed as is.
    priv fn _forwarder(self, sc: *ExtScope, f: *FunctionDecl, ext: *ExtensionDecl) {
        var _op = self._spell->ext_forwarder_name(f);
        if _op.size() == 0 { return; }   // `in`, `^^`, ...: no C++ operator to forward from.
        var fid = CXXSpell::fid_of(static_cast::<*Decl>(f));
        var s = self._spell->template_head(static_cast::<*Decl>(f));
        s += "inline ";
        s += self._ret(f);
        s += " ";
        s += _op;
        s += "(";
        var call = "";
        var k: usize = 0;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            var nm = f"__kairo_a{k}";
            if k > 0 { s += ", "; call += ", "; }
            if p->is_self {
                s += self._spell->ext_receiver(f, ext) + " " + nm;
                call += nm;
            } else {
                s += self._spell->param_decl(p, nm);
                call += "static_cast<decltype(" + nm + ")&&>(" + nm + ")";
            }
            k += 1;
        }
        if CXXSpell::op_is_postfix(f) {
            var nm = f"__kairo_a{k}";
            if k > 0 { s += ", "; call += ", "; }
            s += "int " + nm;
            call += nm;
        }
        // Explicit template arguments: the forwarder's own parameters are the
        // static member's, so nothing is left for deduction to choose.
        var targs = "";
        var tps = CXXSpell::template_params(static_cast::<*Decl>(f));
        for var i: usize = 0; i < tps.size(); ++i {
            targs += (("<") if (i == 0) else (", "));
            targs += self._spell->imm_name(tps[i]->name.imm, fid);
            if tps[i]->is_pack { targs += "..."; }
        }
        if tps.size() > 0 { targs += ">"; }
        s += ")";
        if f->no_unwind { s += " noexcept"; }
        s += " { return " + self._scope_qual(sc) + "::" + self._spell->leaf(static_cast::<*Decl>(f)) + targs + "(" + call + "); }";
        sink->spell(self._at(static_cast::<*Decl>(f)), s);
    }

    priv fn _params(self, f: *FunctionDecl, with_self: bool, ext: *ExtensionDecl) -> string {
        var s = "";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if p->is_self {
                if !with_self { continue; }
                ICE_IF(ext == &null, "InterfaceEmitter: `self` outside a type or extension");
                if !first { s += ", "; }
                first = false;
                // An extension operator is a real non-member C++ operator, and
                // [over.oper]/7 wants a class-typed parameter: the receiver is
                // `X&`. Unnamed here; EmitIR's definition names it.
                s += self._spell->ext_receiver(f, ext);
                if !f->is_operator { s += " self"; }   // just the type for an operator; EmitIR names it.
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
            // The declarator-id is parenthesized, always: after a
            // class-template return, `Cell<double> ::test::f<...>` lexes as
            // ONE nested-name-specifier, so clang looks for a member `test`
            // inside Cell<double> ("no member named 'test'", "does not refer
            // to a function template"). `long (::test::get<long>)(...)` is
            // equally valid, so there is no case to special.
            s += " (";
            s += self._spell->qual_name(d);
            s += self._spell->args_str(&(ie->args));
            s += ")(";
            // An extension member's receiver is a real first parameter; a
            // method's `self` is `this` and has no slot.
            var ext = decl_extension_of(d);
            var first = true;
            for var i: usize = 0; i < f->params.size(); ++i {
                var p = f->params[i];
                if p == &null { continue; }
                if p->is_self && (ext == &null) { continue; }
                if !first { s += ", "; }
                first = false;
                if p->is_self { s += self._spell->ext_receiver(f, ext, ie); continue; }
                s += self._spell->param_decl(p, "", ie);
            }
            s += ")";
            // A const member template's instantiation names the const member:
            // without the qualifier it matches no declaration ("does not refer
            // to a function template"). An extension member is static.
            if (ext == &null) && f->is_method() && f->is_const() { s += " const"; }
            s += ";";
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