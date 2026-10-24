/// --- The Kairo Project ---------------------- Codegen/Emit/EmitIR.k ----- ///
///
///   \brief The body emitter. Declarations are InterfaceEmitter's; this
///          writes what goes between the braces, plus the out-of-line
///          headers those braces hang off (`double Circle::area() {`).
///
///   \par The core, and nothing else
///     This emitter knows the C++-shaped core: names, chains, calls,
///     literals, primitive operators, casts, if/while/for/return/break/
///     continue, locals, blocks, initializers, sizeof/alignof/delete. Every
///     other node ICEs NAMING THE LOWERING THAT OWNS IT. Lower/ reduces into
///     the core; the core never grows an arm for a node Lower/ removes.
///
///   \par No headroom
///     Sema decided everything. This file renders decisions and never lets
///     clang re-make one:
///       - every non-local name is spelled fully qualified from
///         `resolved_decl` (invariant 10: an alias never appears);
///       - `.` vs `->` comes from the base's canonical, not the source;
///       - a callee is the PROMOTED decl; a candidate_cell here is an X
///         gate failure;
///       - an argument whose type differs from the parameter's canonical is
///         cast to it, so every emitted call is Exact under C++'s ranking
///         and there is nothing left for overload resolution to choose;
///       - every compound expression is parenthesized, so Kairo's
///         precedence is the tree's and C++'s table never applies;
///       - a user operator is a CALL, and BinaryOperatorExpr carries no
///         callee. OperatorLowering rewrites it; a record operand here ICEs.
///
///   \par `self`
///     Bound to the `is_self` ParamDecl. Inside a method it is `this`; inside
///     an extension member it is the explicit first parameter and stays
///     `self`. Either way it is a pointer, so a step off it is `->`.
///
///   \par Where bodies land
///     Own functions and methods: this TU, inside the same namespace wrapper
///     InterfaceEmitter declared them in (an out-of-line definition names
///     the entity only if the scopes match). Template member bodies: this
///     TU if it owns the template, and every TU whose plan HOMES an instance
///     of it (IMPORTS.md §7). Extension members: out-of-line definitions
///     of their scope's static members, in its namespace, receiver first.
///
///   \par Constructors that initialize a const field
///     C++ wants a const member's value at the mem-initializer list, so a
///     constructor CtorInitCheck split (FunctionDecl::ci_split; the body is
///     `{ {S_pre} {S_post} }` after CtorInitLowering) becomes four
///     definitions (_split_ctor):
///
///       struct R::__kairo_ciK { ::__kairo_slot<T> x; ... };
///       auto R::__kairo_ctor_preK(__kairo_ciK&& __kairo_s, P& p) -> __kairo_ciK& { S_pre; return __kairo_s; }
///       R::R(__kairo_ciK& __kairo_s, P& p) : x(__kairo_s.x.take()) { S_post }
///       R::R(P p) : R(__kairo_ctor_preK(__kairo_ciK(), p), p) {}
///
///     S_pre runs before any object exists, so in it `self.x = e` fills a
///     slot (`__kairo_s.x.init(e)`, `.put(e)` for a `var` field) and `self.x`
///     reads one; CtorInitCheck allows `self` nowhere else there. A local of
///     S_pre that S_post reads is a slot in both halves. The slot record is
///     the public constructor's temporary, alive to the end of its
///     mem-initializer, which encloses the whole slot constructor; nothing
///     copies or moves it. A field S_pre assigns on every path is built from
///     its slot by mem-initializer, in declaration order; one it assigns on
///     some paths keeps its default and is assigned from the slot, if set,
///     before S_post. Parameters reach both halves by reference
///     (`__kairo_lref`), so what S_pre does to one S_post sees.
///
///   Import law: CodegenContext only. clang::tok is visible transitively.
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
import AST::Node::Program::*;
import AST::Node::Declarations::*;
import AST::Node::Statements::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::StmtKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import AST::ParamMode::*;
import Location::SourceRange::*;
import Codegen::CodegenICE::*;
import Token::TokenKind::*;
import Lexer::Immediate::*;

class EmitIR {
    priv var _cg:    obs::<CodegenContext>;
    priv var _spell: CXXSpell;
    /// The function whose body is being emitted. Decides what `self` means.
    priv var _cur_fn:  *FunctionDecl  = &null;
    priv var _cur_ext: *ExtensionDecl = &null;   ///< non-null inside an extension member.
    /// A split constructor whose slots are live (file header), and whether
    /// this is its S_pre, where there is no object and `self.x` is a slot.
    priv var _ci_fn:  *FunctionDecl = &null;
    priv var _ci_pre: bool = false;

    fn EmitIR(self, cg: *CodegenContext) {
        self._cg    = cg;
        self._spell = CXXSpell(cg);
    }

    // ----------------------------------------------------------------- //
    // Entry
    // ----------------------------------------------------------------- //

    /// Every body this TU defines: its own decls in source order, then every
    /// foreign template and `inline` body visible here.
    fn emit_tu(self, plan: *EmitPlan) {
        var tu = self._cg->tu;
        ICE_IF(tu == &null, "EmitIR: no TU");
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.emit(item.as_decl()); }
                case TopLevelKind::Stmt {
                    // File-scope `var`/`const`/`static`/`eval` parse as a
                    // DeclStmt (ASTParse::_build_symbols); the decl is the
                    // namespace-scope variable. Nothing else at file scope
                    // has a C++ form.
                    var s = item.as_stmt();
                    var ds = dyn_cast::<DeclStmt>(s);
                    if ((ds == &null) || (ds->decl == &null) || (!isa::<VariableDecl>(ds->decl))) { self._ice(s->range, f"EmitIR: top-level {to_string(s->kind)} is not emittable C++ (only variable declarations are)"); }
                    self.emit(ds->decl);
                }
                default { self._ice(item.as_expr()->range, "EmitIR: top-level expressions are not emittable C++"); }
            }
        }

        self.emit_visible(plan);
    }

    /// Every template and inline definition visible here (EmitPlan::
    /// visible_bodies): FOREIGN ones in a preamble, the module's own in a
    /// header. A template's definition must be visible in every TU that can
    /// instantiate it, and clang instantiates some Kairo never names; an
    /// inline body is part of the interface by declaration. The list is the
    /// plan's, the same one it walked for dependencies, so nothing emitted
    /// here goes unplanned, and each body comes once.
    fn emit_visible(self, plan: *EmitPlan) {
        self.emit_bodies(plan->visible_bodies());
    }

    /// Bodies from a list the plan made (EmitPlan::include_bodies, pruned by
    /// the caller), each emitted as emit_visible emits one.
    fn emit_bodies(self, list: vec::<*FunctionDecl>) {
        for var i: usize = 0; i < list.size(); ++i { self._visible_body(list[i]); }
    }

    // ----------------------------------------------------------------- //
    // Declarations
    // ----------------------------------------------------------------- //

    fn emit(self, d: *Decl) {
        ICE_IF(d == &null, "EmitIR: null decl reached codegen");
        if (d->kind == DeclKind::RecoveryDecl) { self._ice(d->range, "EmitIR: poisoned decl reached codegen; sema gate failure"); }
        if d->is_poisoned() { return; }

        switch d->kind {
            case DeclKind::FunctionDecl  { self._free_fn(cast::<FunctionDecl>(d), &null); }
            case DeclKind::ClassDecl     { self._record_bodies(d); }
            case DeclKind::StructDecl    { self._record_bodies(d); }
            case DeclKind::UnionDecl     { self._record_bodies(d); }
            case DeclKind::EnumDecl      { return; }
            case DeclKind::TypeAliasDecl { return; }
            case DeclKind::InterfaceDecl { return; }
            case DeclKind::ModuleDecl    {
                var dc = static_cast::<*DeclContext>(cast::<ModuleDecl>(d));
                for var i: usize = 0; i < dc->dc_decls.size(); ++i { self.emit(*(dc->dc_decls.get(i))); }
            }
            case DeclKind::VisibilityGroupDecl {
                var g = cast::<VisibilityGroupDecl>(d);
                for var i: usize = 0; i < g->members.size(); ++i { self.emit(g->members[i]); }
            }
            case DeclKind::ExtensionDecl {
                var x = cast::<ExtensionDecl>(d);
                for var i: usize = 0; i < x->methods.size(); ++i {
                    var m = x->methods[i];
                    if m != &null { self._free_fn(m, x); }
                }
            }
            case DeclKind::VariableDecl { self._global_var(cast::<VariableDecl>(d)); }
            default { self._ice(d->range, f"EmitIR: decl kind {to_string(d->kind)} has no body to emit"); }
        }
    }

    /// The methods of a record, out of line, then its nested records'.
    priv fn _record_bodies(self, d: *Decl) {
        var methods = self._methods_of(d);
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if m == &null { continue; }
            // An out-of-line definition is in no member list: the in-class
            // declaration is, and the chain leads to the body.
            if !m->has_body() {
                var def = m->definition();
                if (def != &null) && (!def->is_poisoned()) { m = def; }
            }
            self._method(m, d);
        }
        var dc = CXXSpell::dc_of(d);
        if dc == &null { return; }
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if nd == &null { continue; }
            if isa::<ClassDecl>(nd) || isa::<StructDecl>(nd) || isa::<UnionDecl>(nd) { self._record_bodies(nd); }
        }
    }

    priv fn _methods_of(self, d: *Decl) -> FrozenList::<*FunctionDecl> {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->methods;  }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->methods; }
        if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->methods;  }
        return create_empty_frozen_list::<*FunctionDecl>();
    }

    /// One foreign template or inline body, in its owner's wrapper. The tokens live in
    /// the template's file; the sink maps every registered fid. A member
    /// goes out of line on its record (\p f is already the defining link);
    /// an extension member still needs its extension (the receiver
    /// parameter and the extension's template parameters).
    priv fn _visible_body(self, f: *FunctionDecl) {
        var x = decl_extension_of(static_cast::<*Decl>(f));
        if x != &null { self._free_fn(f, x); return; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc != &null) && dc->is_type_scope() && (dc->dc_owner != &null) {
            self._method(f, CXXSpell::rep(dc->dc_owner));
            return;
        }
        self._free_fn(f, &null);
    }

    // --- Namespace wrapper ------------------------------------------------------

    /// Open the wrapper InterfaceEmitter declared \p d in.
    /// The named namespace, plus an unnamed one nested in it for a decl with
    /// no linkage outside its file -- never for an extension member, whose
    /// scope struct lives in the named one whatever its visibility. Returns
    /// how many braces to close.
    priv fn _open_ns(self, d: *Decl, at: SourceRange) -> u32 {
        var n: u32 = 0;
        var ns = self._spell.ns_segments(d);
        if ns.size() > 0 {
            self._cg->sink->spell(at, "namespace " + self._spell.ns_join(ns) + " {");
            n += 1;
        }
        if CXXSpell::is_anon(d) && (decl_extension_of(d) == &null) { self._cg->sink->spell(at, "namespace {"); n += 1; }
        return n;
    }

    priv fn _close_ns(self, at: SourceRange, n: u32) {
        for var i: u32 = 0; i < n; ++i { self._cg->sink->spell(at, "}"); }
        if n > 0 { self._cg->sink->brk(); }
    }

    // --- Functions ------------------------------------------------------------------

    /// A free function, or an extension member (\p ext non-null): the
    /// out-of-line definition of its scope's static member, receiver first
    /// (`void __kairo_ext_Vec::push(Vec* self, ...)`; no `static` out of line).
    priv fn _free_fn(self, n: *FunctionDecl, ext: *ExtensionDecl) {
        if !n->has_body() { return; }
        if n->body_kind != FnBodyKind::Block { self._unsupported_body(n); return; }
        if n->is_method() && (ext == &null) { return; }   // a method reached the free path; its owner emits it.

        var at = CXXSpell::at(static_cast::<*Decl>(n));
        var is_main = (ext == &null) && CXXSpell::is_entry_tu(self._cg->tu) && (self._spell.leaf(n) == "main");
        var wrap: u32 = 0;
        if !is_main { wrap = self._open_ns(n, at); }

        // One merged list: the extension's parameters, then the member's.
        var head = self._spell.template_head(static_cast::<*Decl>(n));
        // Spelled on the definition too, not left to the interface's
        // declaration: the definition alone must say what symbol it is.
        if (ext == &null) && (!is_main) { head += CXXSpell::c_linkage(n); }
        // `inline` puts the body in the interface (EmitPlan::visible_bodies):
        // every TU that declares it defines it, its own TU included, with the
        // same text, and the linker keeps one.
        if n->is_inline() && (!is_main) { head += "inline "; }
        head += (("int") if (is_main) else (self._ret(n)));
        head += " ";
        if ext != &null { head += self._spell.ext_scope_name(ext) + "::"; }
        head += self._spell.leaf(n);
        head += "(";
        head += self._params_text(n, ext);
        head += ")";
        if n->no_unwind { head += " noexcept"; }
        self._cg->sink->spell(at, head);

        self._body(n, ext);
        self._close_ns(n->range, wrap);
    }

    /// `RET Owner::name(params) [const|noexcept] { body }`, inside the owner's wrapper.
    priv fn _method(self, m: *FunctionDecl, owner: *Decl) {
        if !m->has_body() { return; }
        if m->body_kind != FnBodyKind::Block { self._unsupported_body(m); return; }
        if m->ci_split > 0 { self._split_ctor(m, owner); return; }

        var at = CXXSpell::at(static_cast::<*Decl>(m));
        var wrap = self._open_ns(owner, at);

        var head = self._owner_template_head(owner);
        head += self._spell.template_head(static_cast::<*Decl>(m));
        // Out of line, so the class definition stays the same bytes in every
        // TU (invariant 11); see _free_fn.
        if m->is_inline() { head += "inline "; }
        var is_ctor = (self._spell.leaf(m) == self._spell.leaf(owner));
        var nm = self._spell.leaf(m);
        // `op as` spells `operator T`; C++ gives a conversion no return type.
        var is_conv = m->is_operator && (m->op_token[0].kind == TokenKind::KwAs);
        var qual = self._owner_qual(owner);
        if is_ctor {
            head += qual + "::" + self._spell.leaf(owner);
        } else if (nm[0] == '~') || is_conv {
            // A destructor or conversion definition takes no return type, and
            // leaf() has already spelled the `~` / `operator T`.
            head += qual + "::" + nm;
        } else {
            head += self._ret(m);
            head += " ";
            head += qual + "::" + nm;
        }
        head += "(";
        head += self._params_text(m, &null);
        head += ")";
        if m->is_method() && m->is_const() { head += " const"; }
        if m->no_unwind { head += " noexcept"; }
        self._cg->sink->spell(at, head);

        self._body(m, &null);
        self._close_ns(m->range, wrap);
    }

    // --- Constructors that initialize a const field (file header) ----------------

    /// The slot record's definition, the pre-function, the slot constructor
    /// and the public constructor that delegates to it, for \p m, whose body
    /// CtorInitLowering cut into `{ {S_pre} {S_post} }`.
    priv fn _split_ctor(self, m: *FunctionDecl, owner: *Decl) {
        var b = m->body_block;
        if ((!m->ci_cut) || (b == &null) || (b->body.size() != 2)) { self._ice(m->range, "EmitIR: a constructor CtorInitCheck split reached codegen uncut; CtorInitLowering owns it"); }
        var pre  = dyn_cast::<CompoundStmt>(b->body[0]);
        var post = dyn_cast::<CompoundStmt>(b->body[1]);
        if ((pre == &null) || (post == &null)) { self._ice(m->range, "EmitIR: a split constructor's body is not its two blocks; CtorInitLowering owns it"); }

        var at   = CXXSpell::at(static_cast::<*Decl>(m));
        var wrap = self._open_ns(owner, at);
        var oh   = self._owner_template_head(owner);
        var q    = self._owner_qual(owner);
        var inl  = ("inline ") if (m->is_inline()) else ("");
        var ci   = LowerTargets::ctor_slots(m->ci_index);
        var sa   = LowerTargets::ctor_slot_arg();
        var leaf = self._spell.leaf(owner);
        var ps   = self._lref_params(m);
        var args = self._param_names(m);

        // The slot record. Its members' types are complete here, which they
        // need not be where only the class is (InterfaceEmitter declares it).
        var r = oh + "struct " + q + "::" + ci + " {";
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            r += " ::" + LowerTargets::ctor_slot() + "<" + self._slot_type(i) + "> " + self._slot_name(i) + ";";
        }
        r += " };";
        self._cg->sink->spell(at, r);
        self._cg->sink->brk();

        var saved_fn  = self._cur_fn;
        var saved_ext = self._cur_ext;
        var saved_ci  = self._ci_fn;
        var saved_pre = self._ci_pre;
        self._cur_fn  = m;
        self._cur_ext = &null;
        self._ci_fn   = m;

        // S_pre, against the slots.
        self._cg->sink->spell(at, oh + inl + "auto " + q + "::" + LowerTargets::ctor_pre(m->ci_index)
            + "(" + ci + "&& " + sa + ps + ") -> " + ci + "&");
        self._ci_pre = true;
        self._cg->sink->synth_at_start(pre->range, clang::tok::l_brace);
        for var i: usize = 0; i < pre->body.size(); ++i { self.emit(pre->body[i]); }
        self._cg->sink->spell(pre->range, "return " + sa + ";");
        self._cg->sink->synth_at_end(pre->range, clang::tok::r_brace);
        self._ci_pre = false;
        self._cg->sink->brk();

        // The object, built from the slots; then S_post in it.
        var h = oh + inl + q + "::" + leaf + "(" + ci + "& " + sa + ps + ")";
        var first = true;
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            var f = dyn_cast::<FieldDecl>(m->ci_slots[i]);
            if (f == &null) || (!m->ci_dense[i]) { continue; }
            h += (" : ") if (first) else (", ");
            first = false;
            h += self._spell.leaf(static_cast::<*Decl>(f)) + "(" + sa + "." + self._slot_name(i) + ".take())";
        }
        self._cg->sink->spell(at, h);
        self._cg->sink->synth_at_start(post->range, clang::tok::l_brace);
        // A `var` field S_pre assigned on some paths only kept its default;
        // the slot's value replaces it where there is one.
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            var f = dyn_cast::<FieldDecl>(m->ci_slots[i]);
            if (f == &null) || m->ci_dense[i] { continue; }
            var nm = self._slot_name(i);
            self._cg->sink->spell(post->range, "if (" + sa + "." + nm + ".set) { this->" + self._spell.leaf(static_cast::<*Decl>(f)) + " = " + sa + "." + nm + ".take(); }");
        }
        for var i: usize = 0; i < post->body.size(); ++i { self.emit(post->body[i]); }
        self._cg->sink->synth_at_end(post->range, clang::tok::r_brace);
        self._cg->sink->brk();

        self._cur_fn  = saved_fn;
        self._cur_ext = saved_ext;
        self._ci_fn   = saved_ci;
        self._ci_pre  = saved_pre;

        // The constructor Kairo declared: fill a fresh slot record, then
        // delegate. The temporary lives to the end of this mem-initializer.
        var pub_h = oh + inl + q + "::" + leaf + "(" + self._params_text(m, &null) + ")";
        if m->no_unwind { pub_h += " noexcept"; }
        pub_h += " : " + leaf + "(" + LowerTargets::ctor_pre(m->ci_index) + "(" + ci + "()" + args + ")" + args + ") {}";
        self._cg->sink->spell(at, pub_h);
        self._close_ns(m->range, wrap);
    }

    /// Index of \p d in the live split constructor's slots, or usize(-1). A
    /// field counts only when \p fields: after S_pre the object exists.
    priv fn _slot_of(self, d: *Decl, fields: bool) -> usize {
        if (self._ci_fn == &null) || (d == &null) { return usize(-1); }
        if isa::<FieldDecl>(d) && (!fields) { return usize(-1); }
        var sl = self._ci_fn->ci_slots;
        for var i: usize = 0; i < sl.size(); ++i {
            if sl[i] == d { return i; }
        }
        return usize(-1);
    }

    /// A field's slot is named as the field; a carried local's by its
    /// position too (LowerTargets::ctor_local_slot).
    priv fn _slot_name(self, i: usize) -> string {
        var d = self._ci_fn->ci_slots[i];
        if isa::<FieldDecl>(d) { return self._spell.leaf(d); }
        var v = cast::<VariableDecl>(d);
        return LowerTargets::ctor_local_slot(i, self._spell.imm_name(v->name.imm, self._owning_fid()));
    }

    priv fn _slot_type(self, i: usize) -> string {
        var d = self._ci_fn->ci_slots[i];
        if isa::<FieldDecl>(d) { return self._spell._type(cast::<FieldDecl>(d)->type_); }
        return self._spell._type(cast::<VariableDecl>(d)->type_);
    }

    /// `var n = e` in S_pre, for a local S_post reads: its slot, built.
    /// `var n: T` alone is `T{}`, the default every local gets (_var_init).
    priv fn _slot_local_init(self, v: *VariableDecl) {
        var si = self._slot_of(static_cast::<*Decl>(v), false);
        self._cg->sink->spell(v->name.range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(si) + ".init(");
        if v->init == &null {
            self._cg->sink->spell(v->name.range, self._spell._type(v->type_) + "{}");
        } else {
            self._value(v->init, v->type_);
        }
        self._cg->sink->spell(v->name.range, ")");
    }

    /// The field \p e names when it is exactly `self.f`, else null.
    priv fn _self_field(self, e: *Expr) -> *FieldDecl {
        var c = dyn_cast::<ChainExpr>(e);
        if (c == &null) || (c->steps.size() != 1) || (!self._base_is_self(c->base)) { return &null; }
        var d = c->steps.get(0)->resolved_decl;
        if (d == &null) || (!isa::<FieldDecl>(d)) { return &null; }
        return cast::<FieldDecl>(d);
    }

    /// `, __kairo_lref<P> p` per parameter but `self`: the same text
    /// InterfaceEmitter::_lref_params declares, spelled for a definition.
    priv fn _lref_params(self, m: *FunctionDecl) -> string {
        var s = "";
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            s += ", ::" + LowerTargets::lref() + "<" + self._spell.param_type(p) + "> ";
            s += self._spell.imm_name(p->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(m)));
        }
        return s;
    }

    /// `, p` per parameter but `self`: the public constructor's own, passed
    /// on as lvalues.
    priv fn _param_names(self, m: *FunctionDecl) -> string {
        var s = "";
        for var i: usize = 0; i < m->params.size(); ++i {
            var p = m->params[i];
            if (p == &null) || p->is_self { continue; }
            s += ", " + self._spell.imm_name(p->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(m)));
        }
        return s;
    }

    /// `template <class T>` for each generic owner, outermost first.
    priv fn _owner_template_head(self, owner: *Decl) -> string {
        var chain = self._owner_chain(owner);
        var s = "";
        for var i: usize = 0; i < chain.size(); ++i { s += self._spell.template_head(chain[i]); }
        return s;
    }

    /// `Outer<T>::Inner<U>` -- the definition qualifier, with each generic
    /// owner's own parameters as its arguments.
    priv fn _owner_qual(self, owner: *Decl) -> string {
        var chain = self._owner_chain(owner);
        var s = "";
        for var i: usize = 0; i < chain.size(); ++i {
            if i > 0 { s += "::"; }
            s += self._spell.leaf(chain[i]);
            var gps = decl_generic_params(chain[i]);
            if gps.size() > 0 {
                s += "<";
                for var j: usize = 0; j < gps.size(); ++j {
                    if j > 0 { s += ", "; }
                    s += self._spell.imm_name(gps[j]->name.imm, CXXSpell::fid_of(chain[i]));
                }
                s += ">";
            }
        }
        return s;
    }

    /// Type owners from outermost to \p owner inclusive.
    priv fn _owner_chain(self, owner: *Decl) -> vec::<*Decl> {
        var rev = vec::<*Decl>();
        rev.push_back(CXXSpell::rep(owner));
        var dc = reinterpret_cast::<*DeclContext>(owner->semantic_dc);
        while (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) {
            rev.push_back(CXXSpell::rep(dc->dc_owner));
            dc = dc->dc_parent;
        }
        var out = vec::<*Decl>();
        for var i: usize = 0; i < rev.size(); ++i { out.push_back(rev[rev.size() - 1 - i]); }
        return out;
    }

    priv fn _ret(self, f: *FunctionDecl) -> string {
        if f->is_noreturn || (f->return_type == &null) { return "void"; }
        return self._spell.return_spelling(f, &null);
    }

    /// Parameter text for a DEFINITION: names always, `self` only for an
    /// extension member (as the receiver pointer).
    priv fn _params_text(self, f: *FunctionDecl, ext: *ExtensionDecl) -> string {
        var s = "";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if p->is_self {
                if ext == &null { continue; }
                if !first { s += ", "; }
                first = false;
                // An extension operator takes its receiver by reference (see
                // InterfaceEmitter::_params); _body rebinds `self` from it.
                s += self._spell.ext_receiver(f, ext);
                s += (" " + LowerTargets::ext_self()) if (f->is_operator) else (" self");
                continue;
            }
            if !first { s += ", "; }
            first = false;
            s += self._spell.param_decl(p, self._spell.imm_name(p->name.imm, CXXSpell::fid_of(static_cast::<*Decl>(f))));
        }
        // The postfix `int` dummy, same rule as the declaration side.
        if CXXSpell::op_is_postfix(f) {
            if !first { s += ", "; }
            s += "int";
        }
        return s;
    }

    priv fn _body(self, f: *FunctionDecl, ext: *ExtensionDecl) {
        var saved_fn  = self._cur_fn;
        var saved_ext = self._cur_ext;
        self._cur_fn  = f;
        self._cur_ext = ext;
        // Opened here rather than through emit_block: an extension operator's
        // body starts with `X* self = &__kairo_self;`, so everything below it
        // -- `self->v`, the receiver passed on -- is the pointer form every
        // other extension member uses, and the body emits unchanged.
        var b = f->body_block;
        if (b == &null) { self._ice(f->range, "EmitIR: null block reached codegen"); }
        self._cg->sink->synth_at_start(b->range, clang::tok::l_brace);
        if (ext != &null) && f->is_operator {
            var pro = ("const ") if (f->is_const()) else ("");
            pro += self._spell._type(ext->target) + "* self = &" + LowerTargets::ext_self() + ";";
            self._cg->sink->spell(b->range, pro);
        }
        for var i: usize = 0; i < b->body.size(); ++i { self.emit(b->body[i]); }
        // A function is a coroutine only when its body holds a coroutine
        // keyword, and a generator with no `yield` (or only a bare `return`
        // the emitter already spelled `co_return`) may have none. X's
        // has_yield says which; EmitIR does not walk the body to find out.
        if f->is_generator && (!f->has_yield) { self._cg->sink->spell(b->range, "co_return;"); }
        self._cg->sink->synth_at_end(b->range, clang::tok::r_brace);
        self._cur_fn  = saved_fn;
        self._cur_ext = saved_ext;
    }

    priv fn _unsupported_body(self, f: *FunctionDecl) {
        switch f->body_kind {
            case FnBodyKind::Expr    { self._ice(f->range, "EmitIR: expression-bodied function; Lower/ must wrap it in a return block"); }
            case FnBodyKind::Default { return; }   // declared `= default`; nothing to define.
            case FnBodyKind::Delete  { return; }
            case FnBodyKind::Virtual { return; }
            default { return; }
        }
    }

    // ----------------------------------------------------------------- //
    // Statements
    // ----------------------------------------------------------------- //

    fn emit(self, s: *Stmt) {
        ICE_IF(s == &null, "EmitIR: null stmt reached codegen");
        if (s->kind == StmtKind::RecoveryStmt) { self._ice(s->range, "EmitIR: poisoned stmt reached codegen; sema gate failure"); }

        switch s->kind {
            case StmtKind::CompoundStmt    { self.emit_block(cast::<CompoundStmt>(s)); }
            case StmtKind::ReturnStmt      { self._return(cast::<ReturnStmt>(s)); }
            case StmtKind::ExpressionStmt {
                var n = cast::<ExpressionStmt>(s);
                self.emit(n->expr);
                self._cg->sink->synth_at_end(n->range, clang::tok::semi);
            }
            case StmtKind::DeclStmt        { self._decl(cast::<DeclStmt>(s)); }
            case StmtKind::ConditionalStmt { self._if(cast::<ConditionalStmt>(s)); }
            case StmtKind::WhileLoopStmt   { self._while(cast::<WhileLoopStmt>(s)); }
            case StmtKind::LoopStmt {
                var n = cast::<LoopStmt>(s);
                self._cg->sink->spell(n->range, "for (;;)");
                self.emit_block(n->body);
            }
            case StmtKind::IndexedForStmt  { self._for(cast::<IndexedForStmt>(s)); }
            case StmtKind::BreakStmt {
                var n = cast::<BreakStmt>(s);
                if (n->has_label) { self._ice(s->range, "EmitIR: labeled break; LabelLowering must have rewritten it"); }
                self._cg->sink->spell(n->range, "break;");
            }
            case StmtKind::ContinueStmt {
                var n = cast::<ContinueStmt>(s);
                if (n->has_label) { self._ice(s->range, "EmitIR: labeled continue; LabelLowering must have rewritten it"); }
                self._cg->sink->spell(n->range, "continue;");
            }
            case StmtKind::UnsafeBlockStmt        { self.emit_block(cast::<UnsafeBlockStmt>(s)->body); }
            case StmtKind::RangedForStmt          { self._ice(s->range, "EmitIR: ranged for; IterLowering owns it"); }
            case StmtKind::MatchStmt              { self._ice(s->range, "EmitIR: match MatchLowering left in place"); }
            case StmtKind::TryCatchStmt           { self._ice(s->range, "EmitIR: try/catch; PanicLowering owns it"); }
            case StmtKind::FinallyStmt            { self._ice(s->range, "EmitIR: finally; FinallyLowering owns it"); }
            case StmtKind::PanicStmt              { self._ice(s->range, "EmitIR: panic; PanicLowering owns it"); }
            case StmtKind::YieldStmt              { self._yield(cast::<YieldStmt>(s)); }
            case StmtKind::RuntimeAssertStmt      { self._ice(s->range, "EmitIR: assert; PanicLowering owns it"); }
            case StmtKind::StaticAssertStmt       { self._ice(s->range, "EmitIR: static assert; the Evaluator owns it"); }
            case StmtKind::ContextBindingStmt     { self._ice(s->range, "EmitIR: context binding; ContextLowering owns it"); }
            case StmtKind::DestructuringDeclStmt  { self._ice(s->range, "EmitIR: destructuring; TupleLowering owns a tuple's, FeatureGateCheck rejects a struct's"); }
            case StmtKind::LabeledStmt            { self._ice(s->range, "EmitIR: labeled loop; the label lowering owns it"); }
            case StmtKind::LabelIntrinsicStmt {
                var n = cast::<LabelIntrinsicStmt>(s);
                self._name(n->name);
                self._cg->sink->spell(n->range, ":;");
            }
            case StmtKind::JumpIntrinsicStmt {
                var n = cast::<JumpIntrinsicStmt>(s);
                self._cg->sink->spell(n->range, "goto");
                self._name(n->target);
                self._cg->sink->synth_at_end(n->range, clang::tok::semi);
            }
            case StmtKind::SwitchDispatchStmt { self._switch_dispatch(cast::<SwitchDispatchStmt>(s)); }
            case StmtKind::InlineBlockStmt        { self._ice(s->range, "EmitIR: inline foreign block; not emitted yet"); }
            case StmtKind::EvalBlockStmt          { self._ice(s->range, "EmitIR: eval block; EvalLowering owns it"); }
            default { self._ice(s->range, f"EmitIR: statement kind {to_string(s->kind)} is not in the core"); }
        }
    }

    fn emit_block(self, n: *CompoundStmt) {
        ICE_IF(n == &null, "EmitIR: null block reached codegen");
        self._cg->sink->synth_at_start(n->range, clang::tok::l_brace);
        for var i: usize = 0; i < n->body.size(); ++i { self.emit(n->body[i]); }
        self._cg->sink->synth_at_end(n->range, clang::tok::r_brace);
    }

    priv fn _decl(self, n: *DeclStmt) {
        if (n->decl == &null) { self._ice(n->range, "EmitIR: DeclStmt with no decl"); }
        switch n->decl->kind {
            case DeclKind::VariableDecl {
                // A local S_post reads is its slot's first assignment.
                if self._slot_of(n->decl, false) != usize(-1) {
                    self._slot_local_init(cast::<VariableDecl>(n->decl));
                } else {
                    self._var_decl(cast::<VariableDecl>(n->decl));
                }
            }
            case DeclKind::StructDecl   { self._local_record(cast::<StructDecl>(n->decl)); }
            default { self._ice(n->range, "EmitIR: statement-scope named decls (local fn/class/type) are not emitted yet"); }
        }
        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
    }

    /// `[const|static|constexpr] TYPE name [= init]`; no trailing `;`.
    /// After X `type_` is never null on a checked tree; `auto` is the
    /// pre-X fallback and is a bug if it ever prints for real code.
    priv fn _var_decl(self, n: *VariableDecl) {
        if (n->kind == DeclKind::RecoveryDecl) { self._ice(n->range, "EmitIR: poisoned VariableDecl reached codegen"); }
        switch n->storage {
            case StorageClass::Const  { self._cg->sink->kw_const(n->name);     }
            case StorageClass::Static { self._cg->sink->kw_static(n->name);    }
            case StorageClass::Eval   { self._cg->sink->kw_constexpr(n->name); }
            default { }
        }
        var c: *Type = &null;
        if (n->type_ != &null) && (n->type_->canonical != &null) { c = canon_unqual(n->type_->canonical); }
        if (c != &null) && (c->kind == TypeKind::FixedArrayType) {
            // `T name[N]`: the name sits inside the declarator.
            var nm = self._spell.imm_name(n->name.imm, self._owning_fid());
            self._cg->sink->spell(n->name.range, self._spell.decl(n->type_, nm));
        } else {
            if n->type_ == &null {
                var nm = self._cg->ctx->get_spelling(n->name);
                self._cg->ctx->diag_sink.report(DiagCode(DiagID::I011W), n->name.range.start,
                    f"internal: '{nm}' reached codegen with no inferred type; This is a compiler bug; please report it with the source that triggered it"
                ).first(n->name.range).emit();
                self._cg->sink->kw_auto(n->name);
            } else if n->type_->range.is_valid() {
                self.emit(n->type_);
            } else {
                self._cg->sink->spell(n->name.range, self._spell._type(n->type_));
            }
            self._name(n->name);
        }
        self._var_init(n, c);
    }

    /// A record declared in a function body: FinallyLowering's scope guard.
    /// `struct N { T* a; ~N() { body } }`, the destructor's body IN the
    /// class: a local class's members can be defined nowhere else
    /// ([class.local]), so invariant 12 does not reach here -- the whole
    /// struct is body text already. Nothing is planned for it (EmitPlan
    /// skips function-scope records), CXXSpell names it by leaf, and every
    /// member is public: Kairo visibility is AccessCheck's. Only the shape
    /// the lowering mints is accepted: plain fields and one `op delete`.
    priv fn _local_record(self, n: *StructDecl) {
        var d  = static_cast::<*Decl>(n);
        var at = CXXSpell::at(d);
        var nm = self._spell.leaf(d);
        self._cg->sink->spell(at, "struct " + nm + " {");
        for var i: usize = 0; i < n->fields.size(); ++i {
            var f = n->fields[i];
            if f == &null { continue; }
            if (f->is_static() || (f->init != &null)) { self._ice(f->range, "EmitIR: a function-scope record with a static or initialized field; FinallyLowering mints neither"); }
            self._cg->sink->spell(f->name.range, self._spell.decl(f->type_, self._spell.leaf(static_cast::<*Decl>(f))) + ";");
        }
        for var i: usize = 0; i < n->methods.size(); ++i {
            var m = n->methods[i];
            if m == &null { continue; }
            if ((!m->is_operator) || (m->op_token.size() == 0) || (m->op_token[0].kind != TokenKind::KwDelete) || (m->body_kind != FnBodyKind::Block)) {
                self._ice(m->range, "EmitIR: a function-scope record with a member that is not a destructor with a body; FinallyLowering mints only that");
            }
            self._cg->sink->spell(CXXSpell::at(static_cast::<*Decl>(m)), "~" + nm + "()");
            self._body(m, &null);
        }
        self._cg->sink->spell(at, "}");
    }

    /// `= init` for a variable whose declarator is already out; \p c is its
    /// unqualified canonical, or null.
    priv fn _var_init(self, n: *VariableDecl, c: *Type) {
        // `var x: T` is default-constructed (InitCheck proved T has one):
        // `T x{}` value-initializes -- a number or pointer to zero, an array
        // element-wise, a record through its default constructor. A bare
        // `T x;` would leave a local scalar indeterminate.
        if n->init == &null {
            self._cg->sink->synth_at_end(n->name.range, clang::tok::l_brace);
            self._cg->sink->synth_at_end(n->name.range, clang::tok::r_brace);
            return;
        }
        self._cg->sink->synth_at_end(n->name.range, clang::tok::equal);
        var il = dyn_cast::<InitListExpr>(n->init);
        if (il != &null) && (c != &null) && (c->kind == TypeKind::FixedArrayType) {
            self._init_list(il, true);     // a declarator's initializer: the one place bare braces are legal.
        } else {
            self._value(n->init, n->type_);
        }
    }

    /// A namespace-scope variable's definition, in its module's wrapper:
    /// `[constexpr] T const x = init;`. The declarator is CXXSpell::global_var,
    /// the same text the interface's `extern` declaration used, so the two
    /// agree and a `const` keeps the external linkage that prior `extern`
    /// gave it. Definitions come in source order, which is C++'s dynamic
    /// initialization order within a TU: `B = A + 1` after `A` sees it set.
    priv fn _global_var(self, n: *VariableDecl) {
        if (n->type_ == &null) { self._ice(n->range, "EmitIR: namespace-scope variable with no type reached codegen; X gate failure"); }
        var d = static_cast::<*Decl>(n);
        var at = CXXSpell::at(d);
        var wrap = self._open_ns(d, at);
        var head = ("constexpr ") if (n->is_eval()) else ("");
        self._cg->sink->spell(at, head + self._spell.global_var(n));
        var c: *Type = &null;
        if n->type_->canonical != &null { c = canon_unqual(n->type_->canonical); }
        self._var_init(n, c);
        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
        self._close_ns(n->range, wrap);
    }

    /// The `return` keyword borrows the statement's first six bytes; correct
    /// only because Kairo spells it `return` too. TODO(ast): retain the token.
    priv fn _return(self, n: *ReturnStmt) {
        // A generator's `return` is bare (X rejects a value) and ends the
        // sequence: `co_return;`. A plain `return` in a coroutine is ill-formed.
        if (self._cur_fn != &null) && self._cur_fn->is_generator {
            if (n->value != &null) { self._ice(n->range, "EmitIR: generator 'return' with a value; X gate failure"); }
            self._cg->sink->spell(n->range, "co_return");
            self._cg->sink->synth_at_end(n->range, clang::tok::semi);
            return;
        }
        self._cg->sink->synth(SourceRange::from_bounds(n->range.start, u32(6)), clang::tok::kw_return);
        if n->value != &null {
            var rt: *Type = &null;
            if self._cur_fn != &null { rt = self._cur_fn->return_type; }
            // A place operator's decl still says `*T` (importers' X reads it),
            // but the C++ function returns `T&`: `return x;` binds the
            // reference, and a conversion to `T*` here would be wrong.
            if CXXSpell::is_place_operator(self._cur_fn) && (rt != &null) && (rt->canonical != &null) {
                rt = cast::<PointerType>(canon_unqual(rt->canonical))->pointee;
            }
            self._value(n->value, rt);
        }
        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
    }

    /// `co_yield (e);`. The operand is emitted bare when its canonical is the
    /// element's: `co_yield` on an lvalue binds the promise's `T&` overload,
    /// which is the zero-copy path, and an exactness cast would turn it into
    /// a prvalue. A differing type is cast to the element and binds the
    /// prvalue overload.
    priv fn _yield(self, n: *YieldStmt) {
        if ((self._cur_fn == &null) || (!self._cur_fn->is_generator)) { self._ice(n->range, "EmitIR: yield outside a generator; X gate failure"); }
        if (n->value == &null) { self._ice(n->range, "EmitIR: yield with no value reached codegen"); }
        self._cg->sink->spell(n->range, "co_yield");
        self._cg->sink->spell(n->range, "(");
        self._value(n->value, self._yield_elem(self._cur_fn));
        self._cg->sink->spell(n->range, ")");
        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
    }

    /// `T` of a generator's Yield<T> return canonical, or null (nothing to
    /// cast to; the operand goes bare).
    priv fn _yield_elem(self, f: *FunctionDecl) -> *Type {
        if (f->return_type == &null) || (f->return_type->canonical == &null) { return &null; }
        var rt = canon_unqual(f->return_type->canonical);
        if (rt == &null) || (!isa::<RecordType>(rt)) { return &null; }
        var r = cast::<RecordType>(rt);
        return (r->args[0]) if (r->args.size() > 0) else (&null);
    }

    priv fn _if(self, n: *ConditionalStmt) {
        var own = isa::<BinaryOperatorExpr>(n->cond);   // `(a == b)` brings its own parens; a second pair is C786W.
        self._cg->sink->spell(SourceRange::from_bounds(n->range.start, u32(2)), ("if") if (own) else ("if ("));
        self.emit(n->cond);
        if !own { self._cg->sink->spell(n->cond->range, ")"); }
        self.emit_block(n->then_);
        if n->else_ != &null {
            self._cg->sink->spell(n->else_->range, "else");
            self.emit(n->else_);   // a ConditionalStmt (else-if) or a CompoundStmt.
        }
    }

    priv fn _while(self, n: *WhileLoopStmt) {
        var own = isa::<BinaryOperatorExpr>(n->cond);   // `(a == b)` brings its own parens; a second pair is C786W.
        self._cg->sink->spell(SourceRange::from_bounds(n->range.start, u32(5)), ("while") if (own) else ("while ("));
        self.emit(n->cond);
        if !own { self._cg->sink->spell(n->cond->range, ")"); }
        self.emit_block(n->body);
    }

    /// `switch (v) { case lo: goto L; case lo ... hi: goto L; default: goto D; }`:
    /// MatchLowering's dispatch. The cases hold only gotos, so a user
    /// `break` never meets this switch. `...` is clang's case range.
    priv fn _switch_dispatch(self, n: *SwitchDispatchStmt) {
        self._cg->sink->spell(n->range, "switch (");
        self.emit(n->value);
        self._cg->sink->spell(n->range, ") {");
        for var i: usize = 0; i < n->cases.size(); ++i {
            var c = n->cases.get(i);
            self._cg->sink->spell(n->range, "case");
            self.emit(c->lo);
            if c->hi != &null {
                self._cg->sink->spell(n->range, " ... ");
                self.emit(c->hi);
            }
            self._cg->sink->spell(n->range, ": goto");
            self._name(c->target);
            self._cg->sink->spell(n->range, ";");
        }
        self._cg->sink->spell(n->range, "default:");
        if n->default_stmt != &null {
            self.emit(n->default_stmt);
        } else {
            self._cg->sink->spell(n->range, "goto");
            self._name(n->default_target);
            self._cg->sink->spell(n->range, ";");
        }
        self._cg->sink->spell(n->range, "}");
    }

    priv fn _for(self, n: *IndexedForStmt) {
        if (n->is_eval) { self._ice(n->range, "EmitIR: eval for; EvalLowering owns it"); }
        self._cg->sink->spell(SourceRange::from_bounds(n->range.start, u32(3)), "for (");
        if n->init != &null {
            var ds = dyn_cast::<DeclStmt>(n->init);
            if (ds == &null) { self._ice(n->range, "EmitIR: for-init is not a DeclStmt"); }
            if (!isa::<VariableDecl>(ds->decl)) { self._ice(n->range, "EmitIR: for-init is not a variable"); }
            self._var_decl(cast::<VariableDecl>(ds->decl));
        }
        self._cg->sink->spell(n->range, ";");
        if n->cond != &null { self.emit(n->cond); }
        self._cg->sink->spell(n->range, ";");
        if n->update != &null { self.emit(n->update); }
        self._cg->sink->spell(n->range, ")");
        self.emit_block(n->body);
    }

    // ----------------------------------------------------------------- //
    // Expressions
    // ----------------------------------------------------------------- //

    fn emit(self, e: *Expr) {
        ICE_IF(e == &null, "EmitIR: null expr reached codegen");
        if (e->kind == ExprKind::RecoveryExpr) { self._ice(e->range, "EmitIR: poisoned expr reached codegen; sema gate failure"); }
        if (e->is_poisoned()) { self._ice(e->range, "EmitIR: poisoned expr reached codegen; sema gate failure"); }

        switch e->kind {
            case ExprKind::IntegerLiteralExpr   { self._int_lit(cast::<IntegerLiteralExpr>(e)); }
            case ExprKind::FloatingLiteralExpr  { self._cg->sink->synth(cast::<FloatingLiteralExpr>(e)->token, clang::tok::numeric_constant); }
            case ExprKind::CharacterLiteralExpr { self._cg->sink->synth(cast::<CharacterLiteralExpr>(e)->token, clang::tok::char_constant); }
            case ExprKind::BooleanLiteralExpr   { self._cg->sink->spell(e->range, (("true") if (cast::<BooleanLiteralExpr>(e)->value) else ("false"))); }
            case ExprKind::NullLiteralExpr      { self._cg->sink->spell(e->range, "nullptr"); }
            case ExprKind::StringLiteralExpr    { self._string(cast::<StringLiteralExpr>(e)); }
            case ExprKind::NamedIdentExpr       { self._name(cast::<NamedIdentExpr>(e)); }
            case ExprKind::ChainExpr            { self._chain(cast::<ChainExpr>(e)); }
            case ExprKind::CallExpr             { self._call(cast::<CallExpr>(e)); }
            case ExprKind::ParenExpr {
                self._cg->sink->spell(e->range, "(");
                self.emit(cast::<ParenExpr>(e)->inner);
                self._cg->sink->spell(e->range, ")");
            }
            case ExprKind::UnaryOperatorExpr    { self._unary(cast::<UnaryOperatorExpr>(e)); }
            case ExprKind::BinaryOperatorExpr   { self._binary(cast::<BinaryOperatorExpr>(e)); }
            case ExprKind::AssignOperatorExpr   { self._assign(cast::<AssignOperatorExpr>(e)); }
            case ExprKind::TypeCastExpr         { self._cast(cast::<TypeCastExpr>(e)); }
            case ExprKind::ImplicitBoundaryCastExpr {
                var n = cast::<ImplicitBoundaryCastExpr>(e);
                if !self._array_view(n->original, n->target_type, &null) {
                    self._cast_to(n->target_type, n->original, "static_cast");
                }
            }
            case ExprKind::NamedInitializerExpr { self._init(e, cast::<NamedInitializerExpr>(e)->fields); }
            case ExprKind::AnonInitializerExpr  { self._init(e, cast::<AnonInitializerExpr>(e)->fields); }
            case ExprKind::IfExpr               { self._if_expr(cast::<IfExpr>(e)); }
            case ExprKind::SizeOfExpr           { self._cg->sink->spell(e->range, "sizeof(" + self._spell._type(cast::<SizeOfExpr>(e)->type_arg) + ")"); }
            case ExprKind::AlignOfExpr          { self._cg->sink->spell(e->range, "alignof(" + self._spell._type(cast::<AlignOfExpr>(e)->type_arg) + ")"); }
            case ExprKind::DeleteExpr {
                var n = cast::<DeleteExpr>(e);
                self._cg->sink->spell(e->range, (("delete[]") if (n->is_array) else ("delete")));
                self.emit(n->operand);
            }
            case ExprKind::UnsafeExpr           { self.emit(cast::<UnsafeExpr>(e)->operand); }
            case ExprKind::SubscriptExpr        { self._subscript(cast::<SubscriptExpr>(e)); }
            case ExprKind::NamedArgExpr         { self._ice(e->range, "EmitIR: named argument; CallLowering owns it"); }
            case ExprKind::MatchExpr            { self._ice(e->range, "EmitIR: match MatchLowering left in place"); }
            case ExprKind::TryCatchExpr         { self._ice(e->range, "EmitIR: try expression; PanicLowering owns it"); }
            case ExprKind::RangeExpr            { self._ice(e->range, "EmitIR: range; RangeLowering owns it (IterLowering for a loop's iterable)"); }
            case ExprKind::ClosureExpr          { self._ice(e->range, "EmitIR: closure; lambda emission is not written yet"); }
            case ExprKind::AwaitExpr            { self._ice(e->range, "EmitIR: await; the async lowering owns it"); }
            case ExprKind::SpawnExpr            { self._ice(e->range, "EmitIR: spawn; the async lowering owns it"); }
            case ExprKind::ThreadExpr           { self._ice(e->range, "EmitIR: thread; the async lowering owns it"); }
            case ExprKind::EvalExpr             { self._ice(e->range, "EmitIR: eval; EvalLowering owns it"); }
            case ExprKind::PackExpansionExpr    { self._ice(e->range, "EmitIR: pack expansion; not emitted yet"); }
            case ExprKind::ListLiteralExpr      { self._ice(e->range, "EmitIR: list literal; ListLiteralLowering owns it"); }
            case ExprKind::InitListExpr         { self._init_list(cast::<InitListExpr>(e), false); }
            case ExprKind::VariantInitExpr      { self._variant_init(cast::<VariantInitExpr>(e)); }
            case ExprKind::StmtExpr {
                // `({ ... })`: clang's statement expression. The block is
                // emitted as any block; the parens make it a value.
                self._cg->sink->spell(e->range, "(");
                self.emit_block(cast::<StmtExpr>(e)->body);
                self._cg->sink->spell(e->range, ")");
            }
            case ExprKind::SetLiteralExpr       { self._ice(e->range, "EmitIR: set literal; the container migration owns it"); }
            case ExprKind::MapLiteralExpr       { self._ice(e->range, "EmitIR: map literal; the container migration owns it"); }
            case ExprKind::TupleLiteralExpr     { self._ice(e->range, "EmitIR: tuple literal; TupleLowering owns it"); }
            case ExprKind::TypeOfExpr           { self._ice(e->range, "EmitIR: typeof; TypeQueryLowering owns it"); }
            case ExprKind::ImplConformanceExpr  { self._ice(e->range, "EmitIR: impl test; TypeQueryLowering owns it"); }
            case ExprKind::DerivesRelationExpr  { self._ice(e->range, "EmitIR: derives test; TypeQueryLowering owns it"); }
            case ExprKind::ConstraintExpr       { self._ice(e->range, "EmitIR: constraint in expression position; RequiresDesugar owns it"); }
            case ExprKind::VerbatimExpr         { self._ice(e->range, "EmitIR: verbatim span; tooling-only node"); }
            default { self._ice(e->range, f"EmitIR: expression kind {to_string(e->kind)} is not in the core"); }
        }
    }

    /// Emit \p e where a value of \p want is required: the exactness cast
    /// if the canonicals differ. Initializers, returns and arguments all go
    /// through here.
    priv fn _value(self, e: *Expr, want: *Type, subst: *InstanceEntry = &null) {
        if self._array_view(e, want, subst) { return; }
        if self._needs_cast(e, want, subst) {
            self._cast_to(want, e, "static_cast", subst);
            return;
        }
        self.emit(e);
    }

    /// True when clang would see a conversion Kairo already decided. Both
    /// sides concrete; identity is by canonical with top-level cv ignored. A
    /// parameter that IS one of \p subst's generic parameters is read as the
    /// instance's argument for it; any other dependent parameter is left to
    /// the instantiation.
    priv fn _needs_cast(self, e: *Expr, want: *Type, subst: *InstanceEntry) -> bool {
        if (e == &null) || (want == &null) { return false; }
        var have = e->type_;
        var w = want->canonical;
        if (have == &null) || (w == &null) { return false; }
        if (subst != &null) && (canon_unqual(w) != &null) && (canon_unqual(w)->kind == TypeKind::GenericParamType) {
            var s = self._spell.subst_for(cast::<GenericParamType>(canon_unqual(w)), subst);
            if s != &null { w = s; }
        }
        if have->is_dependent() || w->is_dependent() { return false; }
        if have->is_instantiation_dependent() || w->is_instantiation_dependent() { return false; }
        // A reference bound to its own referee (`const T& x = path`): no conversion.
        var wu = canon_unqual(w);
        if (wu != &null) && isa::<CXXLValueRefType>(wu) {
            if canon_unqual(have) == canon_unqual(cast::<CXXLValueRefType>(wu)->referee) { return false; }
        }
        // `T&&` from a prvalue of T binds as it is. Only an lvalue Sema let
        // bind there (a MOVE value: CallTyping::arg_info) needs the cast.
        if (wu != &null) && isa::<CXXRValueRefType>(wu) && (e->value_category == Expr::ValueCategory::RValue) {
            if canon_unqual(have) == canon_unqual(cast::<CXXRValueRefType>(wu)->referee) { return false; }
        }
        // A record by value is copy-constructed; `static_cast<Rec>(x)` is a
        // temporary and changes value category. Records go as they are.
        if canon_unqual(w)->kind == TypeKind::RecordType { return false; }
        return canon_unqual(have) != canon_unqual(w);
    }

    /// `[T; N]` where a record is wanted: Sema's array -> slice view
    /// (Conversion::array_views_as), the only way an array meets a record.
    /// Spelled as the record's `(data, len)` construction over the array's
    /// own storage; `&(a)[0]` is the first element whichever way the array
    /// was declared. True when it emitted.
    priv fn _array_view(self, e: *Expr, want: *Type, subst: *InstanceEntry) -> bool {
        if (e == &null) || (want == &null) || (e->type_ == &null) || (want->canonical == &null) { return false; }
        var have = canon_unqual(e->type_);
        var w    = canon_unqual(want->canonical);
        if (have == &null) || (w == &null) { return false; }
        if (have->kind != TypeKind::FixedArrayType) || (w->kind != TypeKind::RecordType) { return false; }
        if have->is_dependent() || w->is_dependent() { return false; }
        self._cg->sink->spell(e->range, self._spell._type(want, subst) + "(&(");
        self.emit(e);
        self._cg->sink->spell(e->range, ")[0], " + f"{have->size_bits}" + ")");
        return true;
    }

    priv fn _cast_to(self, t: *Type, e: *Expr, kind: string, subst: *InstanceEntry = &null) {
        self._cg->sink->spell(e->range, kind + "<" + self._spell._type(t, subst) + ">(");
        self.emit(e);
        self._cg->sink->spell(e->range, ")");
    }

    /// What reaches here is the BYTE literal StringLowering or FStringLowering
    /// minted, typed as a pointer, spelled from its decoded bytes. Octal for
    /// every byte outside printable ASCII: C++'s `\x` is greedy, octal is not.
    priv fn _string(self, n: *StringLiteralExpr) {
        if (n->is_format()) { self._ice(n->range, "EmitIR: f-string; FStringLowering owns it"); }
        if (n->has_next()) { self._ice(n->range, "EmitIR: multi-part string literal; StringLowering owns it"); }
        var c = canon_unqual(n->type_);
        if ((c == &null) || (c->kind != TypeKind::PointerType)) { self._ice(n->range, "EmitIR: string literal typed `string`; StringLowering owns it"); }
        if ((n->imm == &null) || (!n->imm->has_owned_text())) { self._ice(n->range, "EmitIR: byte literal with no minted bytes; LowerSynth::bytes_literal owns it"); }
        var p = n->imm->owned_ptr;
        var len = static_cast::<usize>(n->imm->owned_len);
        var s = "\"";
        for var i: usize = 0; i < len; ++i {
            var b = p[i];
            if b == 0x22 { s += "\\\""; continue; }
            if b == 0x5c { s += "\\\\"; continue; }
            if (b >= 0x20) && (b < 0x7f) { s += static_cast::<char>(b); continue; }
            s += "\\";
            s += static_cast::<char>('0' + ((b >> 6) & 7));
            s += static_cast::<char>('0' + ((b >> 3) & 7));
            s += static_cast::<char>('0' + (b & 7));
        }
        s += "\"";
        var cxx = s;
        self._cg->sink->create_str(n->token, cxx);
    }

    // --- Names -------------------------------------------------------------------

    /// A local (param, body var, binder, generic param) is bare: unique by
    /// construction. `self` is the OBJECT in Kairo and `this` / the receiver
    /// parameter is a POINTER in C++, so a value use is `(*this)` /
    /// `(*self)`: bare, `return self` would not compile and `self * 2` in
    /// `extend i32` would be pointer arithmetic. Bare only where the tree
    /// asks for the pointer: a pointer-typed read (ExtensionLowering's
    /// receiver) here, and a chain base in _chain_prefix (`this->x`).
    /// Everything else is qualified from its decl; an overload set here is
    /// an X gate failure.
    priv fn _name(self, n: *NamedIdentExpr) {
        var d = n->resolved_decl;
        if ((d == &null) && (n->candidate_cell != &null)) { self._ice(n->range, "EmitIR: unpromoted overload set reached codegen; ExprTyper gate failure"); }
        if (d == &null) { self._ice(n->range, "EmitIR: unbound name reached codegen; NameResolution gate failure"); }

        // A slot of a split constructor: a carried local in either half, a
        // field (named bare) only in S_pre, where the object does not exist.
        var si = self._slot_of(d, self._ci_pre);
        if si != usize(-1) {
            self._cg->sink->spell(n->range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(si) + ".get()");
            return;
        }
        if self._ci_pre && self._is_self_decl(d) { self._ice(n->range, "EmitIR: `self` before every const field is initialized; CtorInitCheck gate failure"); }

        if self._is_self_decl(d) {
            if self._is_pointer(static_cast::<*Expr>(n)) { self._self_ptr(n); return; }
            self._cg->sink->spell(n->range, "(*");
            self._self_ptr(n);
            self._cg->sink->spell(n->range, ")");
            return;
        }
        if self._is_local(d) { self._name(n->name); return; }
        self._cg->sink->spell(n->range, self._spell.qual_name(d));
    }

    /// `self` as C++ has it: `this` in a method, the receiver parameter in an
    /// extension member. Always the pointer.
    priv fn _self_ptr(self, n: *NamedIdentExpr) {
        self._cg->sink->spell(n->range, (("self") if (self._cur_ext != &null) else ("this")));
    }

    priv fn _is_self_decl(self, d: *Decl) -> bool {
        var p = dyn_cast::<ParamDecl>(d);
        return (p != &null) && p->is_self;
    }

    /// Params, body locals, binders, generic params, and statement-scope
    /// decls: everything with no symbol-table home.
    priv fn _is_local(self, d: *Decl) -> bool {
        if isa::<ParamDecl>(d) || isa::<GenericParamDecl>(d) { return true; }
        var v = dyn_cast::<VariableDecl>(d);
        if v != &null {
            var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
            if dc == &null { return true; }
            return dc->is_function() || (dc->dc_kind == DeclContextKind::Block) || (dc->dc_kind == DeclContextKind::Lambda);
        }
        return false;
    }

    // --- Chains ------------------------------------------------------------------------

    /// `::` steps collapse to the qualified name of the last scope-resolved
    /// entity (aliases vanish); value steps emit `.`/`->` from the base's
    /// canonical. An extension member arrives as a plain call, receiver
    /// first; a step naming one here ICEs.
    priv fn _chain(self, n: *ChainExpr) {
        self._chain_prefix(n, n->steps.size());
    }

    /// Emit the chain up to (not including) step \p upto. Returns true when
    /// the emitted value is a pointer (the next step would be `->`).
    priv fn _chain_prefix(self, n: *ChainExpr, upto: usize) -> bool {
        var k = self._last_scope_step(n, upto);
        var i: usize = 0;
        var is_ptr = false;
        if k != usize(-1) {
            var st = n->steps.get(k);
            if (st->resolved_decl == &null) { self._ice(st->range, "EmitIR: unbound `::` step reached codegen; ChainBinding gate failure"); }
            self._cg->sink->spell(st->range, self._spell.qual_name(st->resolved_decl));
            is_ptr = self._type_is_pointer(st->resolved_type);
            i = k + 1;
        } else {
            if (n->base == &null) { self._ice(n->range, "EmitIR: global-root chain with no `::` step"); }
            // `self.x` is `this->x`: the base is the pointer, not _name's
            // value form `(*this)`. In a split constructor's S_pre there is
            // no `this`: `self.x` is x's slot (file header).
            if self._ci_pre && self._base_is_self(n->base) {
                if upto == 0 { self._ice(n->range, "EmitIR: `self` before every const field is initialized; CtorInitCheck gate failure"); }
                var st0 = n->steps.get(0);
                var s0 = self._slot_of(st0->resolved_decl, true);
                if s0 == usize(-1) { self._ice(st0->range, "EmitIR: a field S_pre never assigns read before the object exists; CtorInitCheck gate failure"); }
                self._cg->sink->spell(st0->range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(s0) + ".get()");
                is_ptr = self._type_is_pointer(st0->resolved_type);
                i = 1;
            } else {
                if self._base_is_self(n->base) {
                    self._self_ptr(cast::<NamedIdentExpr>(n->base));
                } else {
                    self.emit(n->base);
                }
                is_ptr = self._base_is_self(n->base) || self._is_pointer(n->base);
            }
        }
        for var j: usize = i; j < upto; ++j {
            var st = n->steps.get(j);
            if (st->access_kind == ChainExpr::AccessKind::ColonColon) { self._ice(st->range, "EmitIR: `::` after a value step"); }
            if ((st->access_kind == ChainExpr::AccessKind::QuestionDot) || (st->access_kind == ChainExpr::AccessKind::QuestionArrow)) { self._ice(st->range, "EmitIR: optional chaining; NullTestLowering owns it"); }
            if st->is_operator() {
                self._cg->sink->spell(st->range, (("->") if (is_ptr) else (".")) + self._spell.leaf(st->resolved_decl));
                is_ptr = false;
                continue;
            }
            if (st->is_tuple_index()) { self._ice(st->range, "EmitIR: tuple index step; TupleLowering owns it"); }
            if (self._is_extension_member(st->resolved_decl)) { self._ice(st->range, "EmitIR: extension member used as a value; ExtensionLowering rewrites the call form"); }
            if (st->resolved_decl == &null) { self._ice(st->range, "EmitIR: unbound member step reached codegen; gate failure"); }
            self._cg->sink->spell(st->range, (("->") if (is_ptr) else (".")));
            self._name(st->name->name);
            is_ptr = self._type_is_pointer(st->resolved_type);
        }
        return is_ptr;
    }

    /// Index of the last `::` step before \p upto, or usize(-1).
    priv fn _last_scope_step(self, n: *ChainExpr, upto: usize) -> usize {
        var last = usize(-1);
        for var j: usize = 0; j < upto; ++j {
            if n->steps.get(j)->access_kind == ChainExpr::AccessKind::ColonColon { last = j; }
        }
        return last;
    }

    priv fn _base_is_self(self, e: *Expr) -> bool {
        var ni = dyn_cast::<NamedIdentExpr>(e);
        if ni == &null { return false; }
        return self._is_self_decl(ni->resolved_decl);
    }

    priv fn _is_pointer(self, e: *Expr) -> bool {
        if e == &null { return false; }
        return self._type_is_pointer(e->type_);
    }

    priv fn _type_is_pointer(self, t: *Type) -> bool {
        if t == &null { return false; }
        var c = t->canonical;
        if c == &null { c = t; }
        return canon_unqual(c)->kind == TypeKind::PointerType;
    }

    // --- Calls -----------------------------------------------------------------------

    priv fn _call(self, n: *CallExpr) {
        var callee = self._callee_decl(n->callee);
        if (callee == &null) { self._ice(n->range, "EmitIR: unbound callee reached codegen; ExprTyper gate failure"); }

        var ch = dyn_cast::<ChainExpr>(n->callee);
        var last: *ChainExpr::Step = &null;
        if (ch != &null) && (ch->steps.size() > 0) { last = ch->steps.get(ch->steps.size() - 1); }
        if ((last != &null) && self._is_extension_member(last->resolved_decl)) { self._ice(n->range, "EmitIR: an extension member called through a chain reached codegen; ExtensionLowering rewrites it to a free call"); }

        // The constructor, not the type the callee names: its parameters are
        // what the arguments are cast to.
        var f = dyn_cast::<FunctionDecl>(callee);
        if n->ctor_decl != &null { f = dyn_cast::<FunctionDecl>(n->ctor_decl); }
        var inst  = reinterpret_cast::<*InstanceEntry>(n->instance);
        var bound = (n->ctor_decl != &null) || self._is_type_decl(callee) || self._is_ctor(f)
                 || ((last != &null) && (last->access_kind != ChainExpr::AccessKind::ColonColon));
        self._check_arity(n, f, bound);

        if self._is_ctor(f) || self._is_type_decl(callee) {
            if n->type_ == &null { self._ice_untyped(static_cast::<*Expr>(n), "EmitIR: untyped constructor call; ExprTyper gate failure"); }
            self._cg->sink->spell(n->callee->range, self._spell._type(n->type_));
        } else if n->qualifier != &null {
            // A default thunk of a generic type's method: a static member of a
            // class template, named through the receiver's record so the
            // owner's arguments are spelled.
            var s = self._spell._type(n->qualifier) + "::";
            if (inst != &null) && (f != &null) && (f->generic_params.size() > 0) {
                if n->qualifier->is_dependent() { s += "template "; }
                s += self._spell.leaf(callee) + self._spell.args_str(&(inst->args));
            } else {
                s += self._spell.leaf(callee);
            }
            self._cg->sink->spell(n->callee->range, s);
        } else if (f != &null) && f->is_operator && (!f->is_method()) && decl_is_imported(callee) && self._plain_callee(n->callee) {
            // A free imported operator is spelled as C++ looks `a == b` up:
            // unqualified, so ADL finds it, and with no template arguments.
            // Qualified, `std::operator==` misses a hidden friend (found only
            // by ADL); and an operator's arguments are always deduced, so
            // clang deduces them again from the operands' real types --
            // spelling Kairo's would round-trip them, and C++ `char` comes
            // back as `i8`'s `signed char`: a std::string iterator's `==`
            // named `operator==<signed char*>`.
            self._cg->sink->spell(n->callee->range, self._spell.leaf(callee));
        } else if (inst != &null) && (CXXSpell::template_params(callee).size() > 0) && self._plain_callee(n->callee) {
            // A generic extension member's instance is `<ext args..., member args...>`.
            self._cg->sink->spell(n->callee->range, self._spell.qual_name(callee) + self._spell.args_str(&(inst->args)));
        } else {
            self.emit(n->callee);
        }
        self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren);
        self._args(n, f, bound, inst);
        self._cg->sink->synth_at_end(n->range, clang::tok::r_paren);
    }

    /// CallLowering's postcondition, checked where it matters: every
    /// parameter has an argument. The one exception is decision 6: trailing
    /// imported C++ defaults are omitted and clang supplies them -- the one
    /// place this layer gives clang headroom, on purpose. A dependent call is
    /// as written until M2 and is not checked.
    priv fn _check_arity(self, n: *CallExpr, f: *FunctionDecl, bound: bool) {
        if (f == &null) || n->is_instantiation_dependent() { return; }
        var want: usize = 0;
        var tail: usize = 0;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if p->is_self && bound { continue; }
            want += 1;
            if p->has_default && (p->default_thunk == &null) { tail += 1; } else { tail = 0; }
        }
        // `x.op++(0)`: C++'s postfix dummy, minted by OperatorLowering and
        // declared by no Kairo parameter (CXXSpell::op_is_postfix).
        if CXXSpell::op_is_postfix(f) { want += 1; }
        var have = n->args.size();
        if (have + tail < want) { self._ice(n->range, "EmitIR: a call short of arguments reached codegen; CallLowering owns defaults"); }
        if ((have > want) && (!f->ffi_c_variadic)) { self._ice(n->range, "EmitIR: a call with more arguments than parameters reached codegen"); }
    }

    /// A callee whose name is spelled whole: a bare name or a `::` path. A
    /// generic METHOD through `.` needs `.template m<...>` and is still
    /// RESOLUTION.md item r.
    priv fn _plain_callee(self, c: *Expr) -> bool {
        if isa::<NamedIdentExpr>(c) { return true; }
        var ch = dyn_cast::<ChainExpr>(c);
        if (ch == &null) || (ch->steps.size() == 0) { return false; }
        return ch->steps.get(ch->steps.size() - 1)->access_kind == ChainExpr::AccessKind::ColonColon;
    }

    /// Arguments, each cast to its parameter's canonical where it differs.
    /// \p bound: the callee carries its receiver, so `self` takes no argument.
    priv fn _args(self, n: *CallExpr, f: *FunctionDecl, bound: bool, inst: *InstanceEntry) {
        var params = self._call_params(f, bound);
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            if i > 0 { self._cg->sink->synth_at_end(n->args[i - 1]->range, clang::tok::comma); }
            var p: *ParamDecl = &null;
            if i < params.size() { p = params[i]; }
            self._arg(a, p, inst);
        }
    }

    priv fn _arg(self, a: *Expr, p: *ParamDecl, inst: *InstanceEntry) {
        // `&x` bound to an @inout parameter is the mode marker, not address-of.
        var u = dyn_cast::<UnaryOperatorExpr>(a);
        if (u != &null) && u->is_mode_marker { self.emit(u->operand); return; }
        // An extension call's receiver: its pointer or object form was decided
        // in the tree (ExtensionLowering), so it is emitted as it stands.
        if (p != &null) && p->is_self { self.emit(a); return; }
        if p == &null { self.emit(a); return; }
        var pt = p->type_;
        if p->is_pack {
            if (p->pack_type == &null) { self._ice(a->range, "EmitIR: pack parameter with no slice type; CallLowering stamps it"); }
            pt = p->pack_type;
        }
        if p->mode == ParamMode::Move {
            // An lvalue must be moved explicitly; a prvalue already is.
            if a->is_lvalue() {
                self._cg->sink->spell(a->range, "static_cast<" + self._spell._type(pt, inst) + "&&>(");
                self.emit(a);
                self._cg->sink->spell(a->range, ")");
                return;
            }
            self.emit(a);
            return;
        }
        if p->mode == ParamMode::Inout { self.emit(a); return; }   // an lvalue binds to T& as is.
        self._value(a, pt, inst);
    }

    /// The parameters an argument list maps onto: `self` excluded only when
    /// \p bound -- an extension call passes its receiver as argument zero.
    priv fn _call_params(self, f: *FunctionDecl, bound: bool) -> vec::<*ParamDecl> {
        var out = vec::<*ParamDecl>();
        if f == &null { return out; }
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if p->is_self && bound { continue; }
            out.push_back(p);
        }
        return out;
    }

    priv fn _callee_decl(self, c: *Expr) -> *Decl {
        var ni = dyn_cast::<NamedIdentExpr>(c);
        if ni != &null {
            if ((ni->resolved_decl == &null) && (ni->candidate_cell != &null)) { self._ice(ni->range, "EmitIR: unpromoted callee; ExprTyper gate failure"); }
            return ni->resolved_decl;
        }
        var ch = dyn_cast::<ChainExpr>(c);
        if (ch != &null) && (ch->steps.size() > 0) {
            var last = ch->steps.get(ch->steps.size() - 1);
            if ((last->resolved_decl == &null) && (last->candidate_cell != &null)) { self._ice(c->range, "EmitIR: unpromoted callee step; ExprTyper gate failure"); }
            return last->resolved_decl;
        }
        return &null;   // a fn-pointer expression; no decl to consult.
    }

    priv fn _is_extension_member(self, d: *Decl) -> bool {
        return decl_extension_of(d) != &null;
    }

    priv fn _is_type_decl(self, d: *Decl) -> bool {
        return isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d) || isa::<EnumDecl>(d);
    }

    /// An identifier is spelled from its IMM, never borrowed: TokenSink takes
    /// an identifier's spelling from the IdentifierInfo and its length is
    /// caret geometry, so the bytes at the range buy nothing -- and a token a
    /// lowering minted sits on bytes that are something else entirely. The imm
    /// indexes the table of the file that owns the body being emitted, which
    /// for a foreign template homed here is not this TU's.
    priv fn _name(self, t: Token) {
        var spelled = self._spell.imm_name(t.imm, self._owning_fid());
        if (spelled == "<?>") { self._ice(t.range, "EmitIR: identifier token with no spelling in its owning file's table"); }
        self._cg->sink->create_ident(t.range, spelled);
    }

    /// An untyped \p e reached codegen: I011W at its source (CodegenICE).
    priv fn _ice_untyped(self, e: *Expr, msg: string) {
        codegen_ice(self._cg->ctx, DiagID::I011W, e->range, f"{msg} ({to_string(e->kind)})");
    }

    /// ICE naming the Kairo source at \p at (CodegenICE).
    priv fn _ice(self, at: SourceRange, msg: string) {
        codegen_ice(self._cg->ctx, at, msg);
    }

    /// The file whose tables the body being emitted indexes: its function's,
    /// which for a foreign template or inline body is not this TU's.
    priv fn _owning_fid(self) -> u32 {
        if self._cur_fn != &null { return CXXSpell::fid_of(static_cast::<*Decl>(self._cur_fn)); }
        return self._cg->tu->fid;
    }

    /// Same rule for a numeric constant: a minted IntData carries no source
    /// body, so it is spelled from its value instead of borrowed.
    ///
    /// The table is the owning file's too. Reading this TU's instead found
    /// some other IntData (or none) for a foreign inline body's minted
    /// constant, and the fallback below then borrowed whatever bytes the
    /// token's range covered -- `"true"` spelled as a numeric constant.
    ///
    /// A value of 2^64 or more is never borrowed either: C++ has no integer
    /// literal wider than unsigned long long, so clang rejects the bytes
    /// whatever the target type. It is built from its two halves in
    /// `unsigned __int128` and cast to the literal's type. Multiplication,
    /// not `<<`: spell() fuses `<<` only after `operator`.
    priv fn _int_lit(self, n: *IntegerLiteralExpr) {
        var t = n->token;
        if n->is_big() { self._ice(t.range, "EmitIR: integer literal wider than 128 bits; limb composition is not emitted yet"); }

        var hi = n->get_value_hi();
        if hi != 0 {
            if (n->type_ == &null) { self._ice(t.range, "EmitIR: untyped wide integer literal reached codegen; ExprTyper gate failure"); }
            var lo = n->get_value_lo();
            self._cg->sink->spell(t.range,
                f"(static_cast<{self._spell._type(n->type_)}>("
                + f"static_cast<unsigned __int128>({hi}ULL) * 4294967296ULL * 4294967296ULL + {lo}ULL))");
            return;
        }

        var tbl = self._cg->ctx->tcm->get_imm_table_for_fid(self._owning_fid());
        if (tbl == &null) { self._ice(t.range, "EmitIR: no immediate table for the file that owns this body"); }
        var d = tbl->get::<Immediate::IntData>(t.imm);
        if (d != &null) && (!d->body.is_valid()) {
            var cxx = f"{d->value_lo}";
            self._cg->sink->create_int(t.range, cxx);
            return;
        }
        self._cg->sink->synth(t, clang::tok::numeric_constant);
    }

    priv fn _is_ctor(self, f: *FunctionDecl) -> bool {
        if (f == &null) || (!f->is_method()) { return false; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) { return false; }
        return self._spell.leaf(static_cast::<*Decl>(f)) == self._spell.leaf(CXXSpell::rep(dc->dc_owner));
    }

    // --- Operators ---------------------------------------------------------------------

    /// A class, struct or union operand: a user operator that OperatorLowering
    /// must have rewritten. A plain enum is a RecordType too, and is NOT one:
    /// `==`, `<` and `as` on an `enum class` are C++'s own.
    priv fn _record_operand(self, e: *Expr) -> bool {
        if (e == &null) || (e->type_ == &null) { return false; }
        var c = canon_unqual(e->type_);
        if (c == &null) || (c->kind != TypeKind::RecordType) { return false; }
        var d = cast::<RecordType>(c)->decl;
        var en = dyn_cast::<EnumDecl>(d);
        if en != &null { return en->is_adt; }
        return !isa::<InterfaceDecl>(d);
    }

    priv fn _unary(self, n: *UnaryOperatorExpr) {
        if n->is_mode_marker { self.emit(n->operand); return; }
        if n->materialize {
            self._cg->sink->spell(n->range, "::" + LowerTargets::tmp_addr() + "(");
            self.emit(n->operand);
            self._cg->sink->spell(n->range, ")");
            return;
        }
        var k = n->op_token.kind;
        var addr_or_deref = (k == TokenKind::OpAmp) || (k == TokenKind::OpStar);
        if (self._record_operand(n->operand) && (!addr_or_deref)) { self._ice(n->range, "EmitIR: user operator; OperatorLowering must rewrite it into a call"); }
        self._cg->sink->spell(n->range, "(");
        if n->is_prefix() { self._cg->sink->create(n->op_token); }
        self.emit(n->operand);
        if n->is_postfix() { self._cg->sink->create(n->op_token); }
        self._cg->sink->spell(n->range, ")");
    }

    priv fn _binary(self, n: *BinaryOperatorExpr) {
        if (n->op_token.kind == TokenKind::OpEqualEqualEqual) { self._ice(n->range, "EmitIR: `===`; NullTestLowering owns it"); }
        if (self._record_operand(n->lhs) || self._record_operand(n->rhs)) { self._ice(n->range, "EmitIR: user operator; OperatorLowering must rewrite it into a call"); }
        self._cg->sink->spell(n->range, "(");
        self.emit(n->lhs);
        self._cg->sink->create(n->op_token);
        self.emit(n->rhs);
        self._cg->sink->spell(n->range, ")");
    }

    priv fn _assign(self, n: *AssignOperatorExpr) {
        // S_pre's `self.x = e` fills x's slot: `init` for a const field (its
        // one assignment, CtorInitCheck), `put` for a `var` one, which S_pre
        // may assign again.
        if self._ci_pre && (n->op_token.kind == TokenKind::OpEqual) {
            var f = self._self_field(n->lhs);
            if f != &null {
                var si = self._slot_of(static_cast::<*Decl>(f), true);
                if si == usize(-1) { self._ice(n->range, "EmitIR: S_pre assigns a field with no slot; CtorInitCheck gate failure"); }
                var put_fn = (".init(") if (f->is_const()) else (".put(");
                self._cg->sink->spell(n->range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(si) + put_fn);
                self._value(n->rhs, f->type_);
                self._cg->sink->spell(n->range, ")");
                return;
            }
        }
        // Plain `=` on records is copy/move assignment; CopyMoveLowering
        // decides which. Compound assignment on a record is a user operator.
        if (n->op_token.kind != TokenKind::OpEqual) {
            if (self._record_operand(n->lhs) || self._record_operand(n->rhs)) { self._ice(n->range, "EmitIR: compound assignment on a record; OperatorLowering owns it"); }
        }
        self._cg->sink->spell(n->range, "(");
        self.emit(n->lhs);
        self._cg->sink->create(n->op_token);
        self._value(n->rhs, n->lhs->type_);
        self._cg->sink->spell(n->range, ")");
    }

    /// The written target is the result type (invariant 15). Which C++ cast:
    /// `as const` -> const_cast, `as unsafe` -> reinterpret_cast (a C-style
    /// cast when it drops a pointee qualifier), otherwise static_cast. A
    /// checked/asserting downcast is PanicLowering's; a user
    /// `op as` or a converting ctor is OperatorLowering's.
    priv fn _cast(self, n: *TypeCastExpr) {
        // A lowering's move: `x as T&&`. Never written by the user (Kairo has
        // no reference types), always a record, always static_cast.
        if (n->target != &null) && (n->target->canonical != &null) && isa::<CXXRValueRefType>(n->target->canonical) {
            self._cast_to(n->target, n->operand, "static_cast");
            return;
        }
        // `a as [T;]` on an array: the same view an implicit site gets.
        if self._array_view(n->operand, n->target, &null) { return; }
        var src_rec = self._record_operand(n->operand);
        if (src_rec && (!self._type_is_pointer(n->operand->type_))) { self._ice(n->range, "EmitIR: `as` on a record value; OperatorLowering owns op as / ctor casts"); }
        var kind = "static_cast";
        if n->mode == CastMode::Const  { kind = "const_cast"; }
        if n->mode == CastMode::Unsafe { kind = "reinterpret_cast"; }
        // reinterpret_cast cannot cast away qualifiers, and `as unsafe *` is
        // the one Kairo spelling that drops them (the written cast already
        // passed the unsafe-context check). A C-style cast is the one C++
        // cast that both retypes and drops cv. Between two classes it would
        // pick static_cast and move the pointer to a base at a nonzero
        // offset, which `as unsafe *` never does, so that pair goes through
        // `const volatile void *` first: from there only the bits survive.
        if (n->mode == CastMode::Unsafe) && self._drops_quals(n->operand->type_, n->target) {
            var bridge = self._record_pointee(n->operand->type_) && self._record_pointee(n->target);
            self._cg->sink->spell(n->operand->range, "(" + self._spell._type(n->target, &null) + ")(");
            if bridge { self._cg->sink->spell(n->operand->range, "(const volatile void *)("); }
            self.emit(n->operand);
            if bridge { self._cg->sink->spell(n->operand->range, ")"); }
            self._cg->sink->spell(n->operand->range, ")");
            return;
        }
        self._cast_to(n->target, n->operand, kind);
    }

    /// True when some pointee level of \p src carries a qualifier the same
    /// level of \p dst lacks. Walks while both sides are pointers, so
    /// `*const u8 -> *void` is a drop at the first level although the
    /// pointees differ, and an integer source never is.
    priv fn _drops_quals(self, src: *Type, dst: *Type) -> bool {
        if (src == &null) || (dst == &null) { return false; }
        var s = (src->canonical) if (src->canonical != &null) else (src);
        var d = (dst->canonical) if (dst->canonical != &null) else (dst);
        while true {
            var su = canon_unqual(s);
            var du = canon_unqual(d);
            if (su == &null) || (du == &null) { return false; }
            if (su->kind != TypeKind::PointerType) || (du->kind != TypeKind::PointerType) { return false; }
            s = cast::<PointerType>(su)->pointee;
            d = cast::<PointerType>(du)->pointee;
            if (canon_quals(s) & (~canon_quals(d))) != 0 { return true; }
        }
        return false;
    }

    /// \p t is a pointer whose pointee is a record.
    priv fn _record_pointee(self, t: *Type) -> bool {
        if t == &null { return false; }
        var c = canon_unqual((t->canonical) if (t->canonical != &null) else (t));
        if (c == &null) || (c->kind != TypeKind::PointerType) { return false; }
        var p = canon_unqual(cast::<PointerType>(c)->pointee);
        return (p != &null) && (p->kind == TypeKind::RecordType);
    }

    priv fn _subscript(self, n: *SubscriptExpr) {
        if (self._record_operand(n->base)) { self._ice(n->range, "EmitIR: `[]` on a record; OperatorLowering owns it"); }
        self.emit(n->base);
        self._cg->sink->spell(n->range, "[");
        self.emit(n->index);
        self._cg->sink->spell(n->range, "]");
    }

    priv fn _if_expr(self, n: *IfExpr) {
        // (c ? a : (c2 ? b : e)) -- every arm converts to the join type X
        // recorded on the node.
        self._cg->sink->spell(n->range, "(");
        self.emit(n->condition);
        self._cg->sink->spell(n->range, "?");
        self._value(n->then_expr, n->type_);
        self._cg->sink->spell(n->range, ":");
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var arm = n->else_ifs.get(i);
            self._cg->sink->spell(arm->range, "(");
            self.emit(arm->condition);
            self._cg->sink->spell(arm->range, "?");
            self._value(arm->body, n->type_);
            self._cg->sink->spell(arm->range, ":");
        }
        self._value(n->else_expr, n->type_);
        for var i: usize = 0; i < n->else_ifs.size(); ++i { self._cg->sink->spell(n->range, ")"); }
        self._cg->sink->spell(n->range, ")");
    }

    // --- Initializers -------------------------------------------------------------

    /// A braced-init-list of array type. \p bare is the declarator form:
    /// `= { a, b }` on a variable, and an array nested directly inside another
    /// (C++ cannot initialize an array element from an array prvalue).
    /// Everywhere else it is the array PRVALUE `::__kairo_array<T, N>{ a, b }`,
    /// alive until the end of the full-expression. Valid C++17; GCC rejects the
    /// decay of one ("taking address of temporary array"), clang does not, and
    /// bodies only ever go through clang.
    priv fn _init_list(self, n: *InitListExpr, bare: bool) {
        if (n->type_ == &null) { self._ice(n->range, "EmitIR: untyped init list reached codegen; ListLiteralLowering must type it"); }
        var c = canon_unqual(n->type_);
        if ((c == &null) || (c->kind != TypeKind::FixedArrayType)) { self._ice(n->range, "EmitIR: init list that is not an array; the initializer_list constructor form is not written yet"); }
        var at   = cast::<FixedArrayType>(c);
        var elem = at->element;

        if bare {
            self._cg->sink->spell(n->range, "{");
        } else {
            self._cg->sink->spell(n->range, "::" + LowerTargets::array_alias() + "<" + self._spell._type(elem) + ", " + f"{at->size_bits}" + ">{");
        }
        for var i: usize = 0; i < n->elements.size(); ++i {
            if i > 0 { self._cg->sink->spell(n->range, ","); }
            var el = n->elements[i];
            if isa::<InitListExpr>(el) { self._init_list(cast::<InitListExpr>(el), true); }
            else { self._value(el, elem); }
        }
        self._cg->sink->spell(n->range, "}");
    }

    /// `T{ .a = x, .b = y }` in declaration order. Designated init needs an
    /// aggregate; a record with a user constructor is a ctor call and is
    /// OperatorLowering/CopyMoveLowering's to rewrite.
    priv fn _init(self, e: *Expr, fields: FrozenList::<InitField>) {
        // A dependent initializer whose head X could name is typed with the
        // dependent record (ControlTyping::_init_fields); reaching here
        // untyped AND dependent means that path fell back to unknown.
        if (e->type_ == &null) && e->is_instantiation_dependent() {
            self._ice_untyped(e, "EmitIR: dependent initializer reached codegen untyped; ExprTyper's named-initializer path (ControlTyping::type_named_init / _init_fields) left it unknown instead of typing it with the dependent record");
        }
        if e->type_ == &null { self._ice_untyped(e, "EmitIR: untyped initializer reached codegen; ExprTyper gate failure"); }
        var c = canon_unqual(e->type_);
        if (c->kind != TypeKind::RecordType) { self._ice(e->range, "EmitIR: initializer of a non-record type"); }
        var rd = CXXSpell::rep(cast::<RecordType>(c)->decl);
        var layout = self._layout_of(rd);
        if (self._has_user_ctor(layout)) { self._ice(e->range, "EmitIR: initializer on a record with a constructor; must be lowered to a ctor call"); }

        self._cg->sink->spell(e->range, self._spell._type(e->type_) + "{");
        // Declaration order: C++ designated initializers may not reorder.
        var decl_fields = self._fields_of(layout);
        var first = true;
        for var fi: usize = 0; fi < decl_fields.size(); ++fi {
            var fd = decl_fields[fi];
            if fd == &null { continue; }
            var fname = self._spell.leaf(static_cast::<*Decl>(fd));
            for var i: usize = 0; i < fields.size(); ++i {
                var f = fields.get(i);
                if self._spell.imm_name(f->name.imm, self._owning_fid()) != fname { continue; }
                if !first { self._cg->sink->spell(f->range, ","); }
                first = false;
                self._cg->sink->spell(f->range, "." + fname + " =");
                // An array member takes bare braces, as a declarator does
                // (_var_decl): C++ cannot initialize one from the
                // `__kairo_array<T, N>{...}` prvalue _value would spell.
                var fc: *Type = &null;
                if (fd->type_ != &null) && (fd->type_->canonical != &null) { fc = canon_unqual(fd->type_->canonical); }
                var il = dyn_cast::<InitListExpr>(f->value);
                if (il != &null) && (fc != &null) && (fc->kind == TypeKind::FixedArrayType) {
                    self._init_list(il, true);
                } else {
                    self._value(f->value, fd->type_);
                }
            }
        }
        self._cg->sink->spell(e->range, "}");
    }

    /// An ADT variant built in place: the enum's tagged constructor,
    /// `T(::__kairo_vt<I>{})` for a variant without a payload, and otherwise
    ///
    ///   T(::__kairo_vt<I>{}, [&]() -> P { return { f0, f1 }; })
    ///
    /// with P the variant's payload struct named through T. The union member
    /// is initialized from the lambda's prvalue, so the payload is built in
    /// place: no copy or move is asked of it. The fields are in declaration
    /// order, which a braced list runs left to right; where the written order
    /// differs and matters, SequenceLowering has bound them to locals.
    priv fn _variant_init(self, n: *VariantInitExpr) {
        if (n->type_ == &null) { self._ice(n->range, "EmitIR: untyped variant construction reached codegen; ControlTyping types it"); }
        var en = dyn_cast::<EnumDecl>(n->en);
        if (en == &null) { self._ice(n->range, "EmitIR: variant construction with no enum"); }
        if (!en->is_adt) { self._ice(n->range, "EmitIR: VariantInitExpr of a plain enum; VariantInitLowering spells a plain variant as its enumerator"); }
        var v   = en->variants[usize(n->variant)];
        var t   = self._spell._type(n->type_);
        var tag = "::" + LowerTargets::adt_variant_tag() + "<" + f"{n->variant}" + ">{}";
        if v->payload.size() == 0 {
            self._cg->sink->spell(n->range, t + "(" + tag + ")");
            return;
        }
        var leaf = LowerTargets::adt_payload_type(self._spell.leaf(static_cast::<*Decl>(v)));
        var pt   = self._spell.dependent_member_type(n->type_, leaf);
        self._cg->sink->spell(n->range, t + "(" + tag + ", [&]() -> " + pt + " { return {");
        for var i: usize = 0; i < n->fields.size(); ++i {
            if i > 0 { self._cg->sink->spell(n->range, ","); }
            var fd = v->payload[i];
            var f  = n->fields[i];
            // An array member takes bare braces, as in _init.
            var fc: *Type = &null;
            if (fd->type_ != &null) && (fd->type_->canonical != &null) { fc = canon_unqual(fd->type_->canonical); }
            var il = dyn_cast::<InitListExpr>(f);
            if (il != &null) && (fc != &null) && (fc->kind == TypeKind::FixedArrayType) {
                self._init_list(il, true);
            } else {
                self._value(f, fd->type_);
            }
        }
        self._cg->sink->spell(n->range, "}; })");
    }

    priv fn _layout_of(self, d: *Decl) -> *Decl {
        if decl_is_instance(d) { return CXXSpell::rep(decl_pattern(d)); }
        return d;
    }

    priv fn _fields_of(self, d: *Decl) -> FrozenList::<*FieldDecl> {
        if isa::<ClassDecl>(d)  { return cast::<ClassDecl>(d)->fields;  }
        if isa::<StructDecl>(d) { return cast::<StructDecl>(d)->fields; }
        if isa::<UnionDecl>(d)  { return cast::<UnionDecl>(d)->fields;  }
        return create_empty_frozen_list::<*FieldDecl>();
    }

    priv fn _has_user_ctor(self, d: *Decl) -> bool {
        var ms = self._methods_of(d);
        var nm = self._spell.leaf(d);
        for var i: usize = 0; i < ms.size(); ++i {
            var m = ms[i];
            if (m != &null) && (!m->is_operator) && (self._spell.leaf(m) == nm) { return true; }
        }
        return false;
    }

    // ----------------------------------------------------------------- //
    // Types
    // ----------------------------------------------------------------- //

    fn emit(self, t: *Type) {
        ICE_IF(t == &null, "EmitIR: null type reached codegen");
        if (t->canonical == &null) { self._ice(t->range, "EmitIR: unresolved type reached codegen; sema gate failure"); }
        self._cg->sink->spell(t->range, self._spell._type(t));
    }
}
