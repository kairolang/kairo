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
///   \par Constructors that initialize a field in place
///     C++ wants a const member's value at the mem-initializer list, and a
///     member with no default constructor built there too, so a
///     constructor CtorInitCheck split (FunctionDecl::ci_split; the body is
///     `{ {S_pre} {S_post} }` after CtorInitLowering) becomes four
///     definitions (_split_ctor):
///
///       struct R::__kairo_ciK { ::__kairo_slot<T> x; ... };
///       auto R::__kairo_ctor_preK(__kairo_ciK&& __kairo_s, P& p) -> __kairo_ciK& { S_pre; return static_cast<__kairo_ciK&>(__kairo_s); }
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
import Token::TokenText::*;
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
    /// The closure whose body is being emitted, innermost: a `return` in it
    /// returns from the lambda, with the closure's type. `_cur_fn` stays
    /// the enclosing function, which still decides what `self` is.
    priv var _closure: *ClosureExpr = &null;
    /// emit_tu's first pass: only compile-time bodies are emitted (eval free
    /// functions, then records' eval and constexpr methods), and the second
    /// pass skips them (EVAL.md 1.1, _eval_done).
    priv var _eval_pass: bool = false;
    /// The eval pass's second round: records' compile-time methods.
    priv var _eval_records: bool = false;
    /// `eval for` copies the current statement is inside (EVAL.md §5), and
    /// the runtime loops opened inside the innermost copy: a `break` /
    /// `continue` with none is the eval for's own (the copy's `return`).
    priv var _ef_depth: u32 = 0;
    priv var _ef_loops: u32 = 0;
    /// Eval generator iterables in the function, for unique names.
    priv var _ef_gens: usize = 0;
    priv var _eval_done: vec::<*FunctionDecl>;
    /// The eval bindings emit_tu defined ahead of the program walk.
    priv var _hoisted_vars: vec::<*VariableDecl>;
    /// The eval bindings InterfaceEmitter had defined as early items
    /// (EmitPlan::early, EVAL.md §11); their bodies are in _eval_done.
    priv var _early_vars: vec::<*VariableDecl>;
    /// The namespace-scope variable whose initializer is being emitted.
    priv var _cur_global: *VariableDecl = &null;

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

        // Every consteval body first, foreign then own: a constant
        // expression may call a consteval function only where it is already
        // DEFINED, and Kairo declarations have no order (EVAL.md 1.1). A
        // consteval body only names other consteval bodies and declarations,
        // so it can always go first.
        // A constexpr body (the string literal constructor, an eval class's
        // field default, EVAL.md 2a / 7b) goes with them: a constant
        // expression needs it defined as much.
        var vis = plan->visible_bodies();
        for var i: usize = 0; i < vis.size(); ++i { if self._compile_time(vis[i]) && (!self._done(vis[i])) { self._visible_body(vis[i]); } }
        // Free functions first, then records' compile-time methods: an eval
        // field's definition follows its thunk's body and is evaluated right
        // there, so what the thunk calls must already be defined.
        self._eval_pass = true;
        for var round: u32 = 0; round < 2; ++round {
            self._eval_records = (round == 1);
            for var i: usize = 0; i < items->size(); ++i {
                var item = *(items->get(i));
                if item.kind == TopLevelKind::Decl { self.emit(item.as_decl()); }
            }
        }
        self._eval_records = false;
        self._eval_pass = false;
        // Then every eval binding's definition, foreign (EVAL.md 1.2b) and
        // own, dependencies first: each reads those bodies, and one may read
        // another declared below it or in another file. The own ones are
        // skipped where the program walk below reaches them.
        self._hoisted_vars = plan->include_eval_vars();
        self._eval_vars(self._hoisted_vars);

        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.emit(item.as_decl()); }
                case TopLevelKind::Stmt {
                    // File-scope `var`/`const`/`static`/`eval` parse as a
                    // DeclStmt (ASTParse::_build_symbols); the decl is the
                    // namespace-scope variable. Nothing else at file scope
                    // has a C++ form: ScriptLowering moves a script's
                    // statements into its `main`, and Sema rejects them in
                    // any other file, so reaching here means it did not run.
                    var s = item.as_stmt();
                    var ds = dyn_cast::<DeclStmt>(s);
                    if ((ds == &null) || (ds->decl == &null) || (!isa::<VariableDecl>(ds->decl))) { self._ice(s->range, f"EmitIR: a top-level {to_string(s->kind)} reached codegen; ScriptLowering should have moved it into the script's 'main' (only variable declarations stay at file scope)"); }
                    self.emit(ds->decl);
                }
                default { self._ice(item.as_expr()->range, "EmitIR: a top-level expression reached codegen; ScriptLowering should have moved it into the script's \x27main\x27"); }
            }
        }

        // The bodies of what the program's functions declare locally,
        // hoisted to namespace scope (CXXSpell::is_hoisted_local); the plan
        // declared each, so order among them does not matter.
        var hl = HoistedLocals();
        hl.run(tu);
        for var i: usize = 0; i < hl.found.size(); ++i { self.emit(hl.found[i]); }

        for var i: usize = 0; i < vis.size(); ++i { if !self._compile_time(vis[i]) { self._visible_body(vis[i]); } }
        self._panic_sites(tu);
    }

    /// The TU's panic site table (PANIC.md §1.4; TranslationUnit::
    /// panic_sites): one `__kairo_panic_site {id, line, col, file}` per site
    /// in the linker-collected `__kairo_panic_sites` section, which the
    /// lookup searches by id. Internal and `used`: every TU keeps its own
    /// records, so a `.k` that kcc includes into several TUs has its sites
    /// written once per TU, as identical records -- the lookup treats equal
    /// records as one site, and only differing records with one id as the
    /// ambiguity it prints in full.
    priv fn _panic_sites(self, tu: *TranslationUnit) {
        if tu->panic_sites.size() == 0 { return; }
        var at  = self._cg->ctx->sm->get_range(tu->fid, 0, 1);   // a TU with a site has a byte 0.
        var st  = LowerTargets::panic_site_type();   // InterfaceEmitter defines it.
        var sec = LowerTargets::panic_sites_section();
        var ci  = self._cg->ctx->ci;
        if (ci != &null) && (ci->target.object_format == "Mach-O") { sec = LowerTargets::panic_sites_section_macho(); }
        var sm = self._cg->ctx->sm;
        for var i: usize = 0; i < tu->panic_sites.size(); ++i {
            var r = tu->panic_sites[i];
            var lc = sm->get_line_col(r.at);
            var lit = CXXSpell::c_string(sm->get_filename(r.at));
            self._cg->sink->spell(at, "[[gnu::used, gnu::section(\"" + sec + "\")]] static const ::" + st + " " + LowerTargets::panic_site_record(r.key)
                + " = { " + f"{r.id}" + "u, " + f"{lc.line}" + "u, " + f"{lc.column}" + "u, " + lit + " };");
        }
        self._cg->sink->brk();
    }

    /// A body a constant expression may run: `consteval` or `constexpr`.
    priv fn _compile_time(self, f: *FunctionDecl) -> bool { return f->is_eval() || f->is_constexpr(); }

    /// Eval bindings' `inline constexpr` definitions, in the plan's order
    /// (dependencies first), each in its namespace (EVAL.md 1.2b).
    priv fn _eval_vars(self, list: vec::<*VariableDecl>) {
        for var i: usize = 0; i < list.size(); ++i {
            var early = false;
            for var k: usize = 0; k < self._early_vars.size(); ++k { if self._early_vars[k] == list[i] { early = true; break; } }
            if !early { self._global_var(list[i]); }
        }
    }

    /// Whether compile-time body \p f is already written (the eval pass, or
    /// an early item).
    priv fn _done(self, f: *FunctionDecl) -> bool {
        for var i: usize = 0; i < self._eval_done.size(); ++i { if self._eval_done[i] == f { return true; } }
        return false;
    }

    /// One early item (EmitPlan::early, EVAL.md §11), defined where
    /// InterfaceEmitter's tier 1 stands: a compile-time body (in its
    /// owner's wrapper, a method out of line, an eval field's definition
    /// after its thunk), or an eval binding's `inline constexpr`
    /// definition. Recorded, so emit_tu / emit_bodies do not write it again.
    fn early(self, d: *Decl) {
        var f = dyn_cast::<FunctionDecl>(d);
        if f != &null {
            if self._done(f) { return; }
            self._eval_done.push_back(f);
            self._visible_body(f);
            return;
        }
        var v = dyn_cast::<VariableDecl>(d);
        if v == &null { return; }
        for var k: usize = 0; k < self._early_vars.size(); ++k { if self._early_vars[k] == v { return; } }
        self._early_vars.push_back(v);
        self._global_var(v);
    }

    /// Every template and inline definition visible here (EmitPlan::
    /// visible_bodies): FOREIGN ones in a preamble, the module's own in a
    /// header. A template's definition must be visible in every TU that can
    /// instantiate it, and clang instantiates some Kairo never names; an
    /// inline body is part of the interface by declaration. The list is the
    /// plan's, the same one it walked for dependencies, so nothing emitted
    /// here goes unplanned, and each body comes once.
    fn emit_visible(self, plan: *EmitPlan) {
        self.emit_bodies(plan->visible_bodies(), plan->visible_eval_vars());
    }

    /// Bodies and eval bindings from lists the plan made (EmitPlan::
    /// include_bodies / include_eval_vars, pruned by the caller), each
    /// emitted as emit_visible emits one: the compile-time bodies, then the
    /// eval bindings that read them, then the rest (as emit_tu orders them).
    fn emit_bodies(self, list: vec::<*FunctionDecl>, vars: vec::<*VariableDecl>) {
        for var i: usize = 0; i < list.size(); ++i { if self._compile_time(list[i]) && (!self._done(list[i])) { self._visible_body(list[i]); } }
        self._eval_vars(vars);
        for var i: usize = 0; i < list.size(); ++i { if !self._compile_time(list[i]) { self._visible_body(list[i]); } }
    }

    // ----------------------------------------------------------------- //
    // Declarations
    // ----------------------------------------------------------------- //

    fn emit(self, d: *Decl) {
        ICE_IF(d == &null, "EmitIR: null decl reached codegen");
        if (d->kind == DeclKind::RecoveryDecl) { self._ice(d->range, "EmitIR: poisoned decl reached codegen; sema gate failure"); }
        if d->is_poisoned() { return; }

        // The eval pass reaches free functions and records' compile-time
        // methods (_record_bodies), through modules and visibility groups
        // (emit_tu): the eval bindings defined after it call them.
        if self._eval_pass {
            if d->kind == DeclKind::FunctionDecl {
                if cast::<FunctionDecl>(d)->is_eval() && (!self._eval_records) && (!self._done(cast::<FunctionDecl>(d))) {
                    self._free_fn(cast::<FunctionDecl>(d), &null);
                    self._eval_done.push_back(cast::<FunctionDecl>(d));
                }
                return;
            }
            var rec = (d->kind == DeclKind::ClassDecl) || (d->kind == DeclKind::StructDecl) || (d->kind == DeclKind::UnionDecl);
            if (d->kind != DeclKind::ModuleDecl) && (d->kind != DeclKind::VisibilityGroupDecl) && (!rec) { return; }
            if rec && (!self._eval_records) { return; }
        } else if (d->kind == DeclKind::FunctionDecl) && cast::<FunctionDecl>(d)->is_eval() {
            for var i: usize = 0; i < self._eval_done.size(); ++i {
                if self._eval_done[i] == cast::<FunctionDecl>(d) { return; }
            }
        }

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
            case DeclKind::VariableDecl {
                var gv = cast::<VariableDecl>(d);
                for var i: usize = 0; i < self._hoisted_vars.size(); ++i {
                    if self._hoisted_vars[i] == gv { return; }   // emit_tu wrote it, in dependency order.
                }
                self._global_var(gv);
            }
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
            // The eval pass writes the compile-time ones; the second pass
            // the rest (emit).
            var done = false;
            for var k: usize = 0; k < self._eval_done.size(); ++k { if self._eval_done[k] == m { done = true; break; } }
            if done { continue; }
            if self._eval_pass {
                if !self._compile_time(m) { continue; }
                self._eval_done.push_back(m);
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
        var is_main = (ext == &null) && self._spell.is_main(static_cast::<*Decl>(n));
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
        // EVAL.md 1.1: the definition repeats the interface's `consteval`.
        if n->is_eval() && (!is_main) { head += "consteval "; }
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
        if m->is_eval()   { head += "consteval "; }   // EVAL.md 1.1
        else if m->is_constexpr() { head += "constexpr "; }   // an eval class's field default (7b).
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
        if is_ctor { self._mem_inits(m, owner, &(m->body_block->body), true); }

        self._body(m, &null);
        self._eval_field_def(m, owner, at);
        self._close_ns(m->range, wrap);
    }

    /// `inline constexpr T const R::k = R::__kairo_init_k();` for the eval
    /// field whose consteval thunk \p m is, right after the thunk's body: a
    /// constant expression may call a consteval function only once it is
    /// defined, so InterfaceEmitter, which writes the other statics after
    /// the class, leaves this one here. The thunk is an eval fn, so its body
    /// (and with it this definition) is in every TU that sees the class.
    priv fn _eval_field_def(self, m: *FunctionDecl, owner: *Decl, at: SourceRange) {
        if (!m->is_eval()) || (!m->is_implicit) { return; }
        var fields: *FrozenList::<*FieldDecl> = &null;
        if isa::<ClassDecl>(owner)       { fields = &(cast::<ClassDecl>(owner)->fields);  }
        else if isa::<StructDecl>(owner) { fields = &(cast::<StructDecl>(owner)->fields); }
        if fields == &null { return; }
        for var i: usize = 0; i < fields->size(); ++i {
            var f = (*fields)[i];
            if (f == &null) || (!f->is_eval()) || (f->init_fold != FieldFold::Thunk) { continue; }
            if f->init_thunk != static_cast::<*Decl>(m) { continue; }
            var q  = self._owner_qual(owner);
            var nm = q + "::" + self._spell.leaf(static_cast::<*Decl>(f));
            var s  = self._owner_template_head(owner) + "inline constexpr const ";
            s += self._spell.decl(f->type_, nm);
            s += " = " + q + "::" + self._spell.leaf(m) + "();";
            self._cg->sink->spell(at, s);
            return;
        }
    }

    // --- Constructors that initialize a field in place (file header) ------------

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
        // An eval constructor is `consteval` in the class (EVAL.md 1.1), and
        // so are its halves (InterfaceEmitter::_split_ctor_decls): every
        // definition repeats it, or clang reads a run-time redeclaration.
        // The slots then live inside one constant evaluation (the ctor
        // slot helpers' `if consteval` arm).
        if m->is_eval() { inl += "consteval "; }
        else if m->is_constexpr() { inl += "constexpr "; }
        var ci   = LowerTargets::ctor_slots(m->ci_index);
        var sa   = LowerTargets::ctor_slot_arg();
        var leaf = self._spell.leaf(owner);
        var ps   = self._lref_params(m);
        var args = self._param_names(m);

        // Before anything below: _slot_name and _slot_type read the slots
        // through _ci_fn, and the slot record is the first thing they spell.
        var saved_fn  = self._cur_fn;
        var saved_ext = self._cur_ext;
        var saved_ci  = self._ci_fn;
        var saved_pre = self._ci_pre;
        self._cur_fn  = m;
        self._cur_ext = &null;
        self._ci_fn   = m;

        // The slot record. Its members' types are complete here, which they
        // need not be where only the class is (InterfaceEmitter declares it).
        var r = oh + "struct " + q + "::" + ci + " {";
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            r += " ::" + LowerTargets::ctor_slot() + "<" + self._slot_type(i) + "> " + self._slot_name(i) + ";";
        }
        r += " };";
        self._cg->sink->spell(at, r);
        self._cg->sink->brk();

        // S_pre, against the slots.
        self._cg->sink->spell(at, oh + inl + "auto " + q + "::" + LowerTargets::ctor_pre(m->ci_index)
            + "(" + ci + "&& " + sa + ps + ") -> " + ci + "&");
        self._ci_pre = true;
        self._cg->sink->synth_at_start(pre->range, clang::tok::l_brace);
        // The base initializers lead S_pre and belong to the slot
        // constructor's mem-initializers, below.
        var lead = self._lead_base_inits(&(pre->body));
        for var i: usize = lead; i < pre->body.size(); ++i { self.emit(pre->body[i]); }
        // Cast, not `return __kairo_s;`: since C++23 a returned rvalue
        // reference parameter is an xvalue (P2266), which the `&` return
        // type cannot bind.
        self._cg->sink->spell(pre->range, "return static_cast<" + ci + "&>(" + sa + ");");
        self._cg->sink->synth_at_end(pre->range, clang::tok::r_brace);
        self._ci_pre = false;
        self._cg->sink->brk();

        // The object, built from the slots; then S_post in it. Its bases
        // first, as C++ builds them: from the leading `Base::Base(self,
        // ...)` calls, whose arguments are the parameters this constructor
        // takes by reference too -- so a base is built after S_pre ran,
        // and sees what S_pre did to a parameter.
        var h = oh + inl + q + "::" + leaf + "(" + ci + "& " + sa + ps + ")";
        self._cg->sink->spell(at, h);
        h = "";
        var first = !self._mem_inits(m, owner, &(pre->body), false);
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            var f = dyn_cast::<FieldDecl>(m->ci_slots[i]);
            if (f == &null) || (!m->ci_dense[i]) { continue; }
            h += (" : ") if (first) else (", ");
            first = false;
            var take = sa + "." + self._slot_name(i) + "." + LowerTargets::ctor_slot_take() + "()";
            var ext  = self._array_extent(f->type_);
            if ext == usize(-1) {
                h += self._spell.leaf(static_cast::<*Decl>(f)) + "(" + take + ")";
            } else {
                // A member array cannot be initialized from an array, only
                // from its elements, each moved out of the slot's.
                h += self._spell.leaf(static_cast::<*Decl>(f)) + "{";
                for var k: usize = 0; k < ext; ++k {
                    if k > 0 { h += ", "; }
                    h += take + f"[{k}]";
                }
                h += "}";
            }
        }
        if h.size() > 0 { self._cg->sink->spell(at, h); }
        self._cg->sink->synth_at_start(post->range, clang::tok::l_brace);
        // A `var` field S_pre assigned on some paths only kept its default;
        // the slot's value replaces it where there is one.
        for var i: usize = 0; i < m->ci_slots.size(); ++i {
            var f = dyn_cast::<FieldDecl>(m->ci_slots[i]);
            if (f == &null) || m->ci_dense[i] { continue; }
            var nm = self._slot_name(i);
            self._cg->sink->spell(post->range, "if (" + sa + "." + nm + "." + LowerTargets::ctor_slot_set() + ") { this->" + self._spell.leaf(static_cast::<*Decl>(f)) + " = " + sa + "." + nm + "." + LowerTargets::ctor_slot_take() + "(); }");
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

    /// The length of \p t when it is a fixed array of known length (the one
    /// kind of field whose slot hands its value over element by element),
    /// else usize(-1). CtorInitCheck gated a generic length.
    priv fn _array_extent(self, t: *Type) -> usize {
        if (t == &null) || (t->canonical == &null) { return usize(-1); }
        var c = canon_unqual(t->canonical);
        if (c == &null) || (!isa::<FixedArrayType>(c)) { return usize(-1); }
        var a = cast::<FixedArrayType>(c);
        if a->is_incomplete || (a->extent_param != &null) { return usize(-1); }
        return static_cast::<usize>(a->size_bits);
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
        self._cg->sink->spell(v->name.range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(si) + "." + LowerTargets::ctor_slot_init() + "(");
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
            s += self._spell.owner_segment(chain[i]);
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
        if f->panic_result != &null { return self._spell._type(f->panic_result); }
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
                s += (" " + LowerTargets::ext_self()) if (f->is_operator) else (" " + LowerTargets::ext_receiver_name());
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
            pro += self._spell._type(ext->target) + "* " + LowerTargets::ext_receiver_name() + " = &" + LowerTargets::ext_self() + ";";
            self._cg->sink->spell(b->range, pro);
        }
        // The value predicates of the function's `requires` (EVAL.md §8,
        // E10): asserted where C++ can evaluate them, per instance in a
        // template. EvalUsageChecking already refused a run-time one.
        var vps = vec::<*Expr>();
        CXXSpell::value_predicates(f->requires_clause, &vps);
        for var i: usize = 0; i < vps.size(); ++i {
            self._cg->sink->spell(vps[i]->range, "static_assert(");
            self.emit(vps[i]);
            self._cg->sink->spell(vps[i]->range, ", \"requires clause of \x27" + self._spell.leaf(static_cast::<*Decl>(f)) + "' not satisfied\");");
        }
        var egen = f->is_generator && f->is_eval();
        var saved_gens = self._ef_gens;
        self._ef_gens = 0;
        if egen {
            var et = self._yield_elem(f);
            if (et == &null) { self._ice(f->range, "EmitIR: an eval generator with no element type"); }
            self._cg->sink->spell(b->range, "::" + LowerTargets::eval_buf() + "<" + self._spell._type(et) + "> " + LowerTargets::eval_yield_buf() + ";");
        }
        // A constructor's leading `Base::Base(self, ...)` calls went out as
        // its mem-initializers (_mem_inits).
        var from: usize = 0;
        if self._is_ctor(f) { from = self._lead_base_inits(&(b->body)); }
        for var i: usize = from; i < b->body.size(); ++i { self.emit(b->body[i]); }
        // A function is a coroutine only when its body holds a coroutine
        // keyword, and a generator with no `yield` (or only a bare `return`
        // the emitter already spelled `co_return`) may have none. X's
        // has_yield says which; EmitIR does not walk the body to find out.
        if egen { self._cg->sink->spell(b->range, "return " + LowerTargets::eval_yield_buf() + ";"); }
        else if f->is_generator && (!f->has_yield) { self._cg->sink->spell(b->range, "co_return;"); }
        self._ef_gens = saved_gens;
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
            case StmtKind::WhileLoopStmt   { self._ef_loops += 1; self._while(cast::<WhileLoopStmt>(s)); self._ef_loops -= 1; }
            case StmtKind::LoopStmt {
                var n = cast::<LoopStmt>(s);
                self._cg->sink->spell(n->range, "for (;;)");
                self._ef_loops += 1;
                self.emit_block(n->body);
                self._ef_loops -= 1;
            }
            case StmtKind::IndexedForStmt  { self._ef_loops += 1; self._for(cast::<IndexedForStmt>(s)); self._ef_loops -= 1; }
            case StmtKind::BreakStmt {
                var n = cast::<BreakStmt>(s);
                if (n->has_label) { self._ice(s->range, "EmitIR: labeled break; LabelLowering must have rewritten it"); }
                // An `eval for`'s own break ends the `&&` fold (EVAL.md §5).
                if (self._ef_depth > 0) && (self._ef_loops == 0) { self._cg->sink->spell(n->range, "return false;"); }
                else { self._cg->sink->spell(n->range, "break;"); }
            }
            case StmtKind::ContinueStmt {
                var n = cast::<ContinueStmt>(s);
                if (n->has_label) { self._ice(s->range, "EmitIR: labeled continue; LabelLowering must have rewritten it"); }
                if (self._ef_depth > 0) && (self._ef_loops == 0) { self._cg->sink->spell(n->range, "return true;"); }
                else { self._cg->sink->spell(n->range, "continue;"); }
            }
            case StmtKind::UnsafeBlockStmt        { self.emit_block(cast::<UnsafeBlockStmt>(s)->body); }
            case StmtKind::RangedForStmt {
                var rf = cast::<RangedForStmt>(s);
                if rf->iter_kind == IterKind::Pack { self._pack_for(rf); }
                else {
                    if (!rf->is_eval) { self._ice(s->range, "EmitIR: ranged for; IterLowering owns it"); }
                    self._eval_for(rf);
                }
            }
            case StmtKind::MatchStmt              { self._ice(s->range, "EmitIR: match MatchLowering left in place"); }
            case StmtKind::TryCatchStmt {
                var t = cast::<TryCatchStmt>(s);
                if !t->cxx { self._ice(s->range, "EmitIR: try/catch; PanicLowering owns it"); }
                self._cxx_try(t);
            }
            case StmtKind::FinallyStmt            { self._ice(s->range, "EmitIR: finally; FinallyLowering owns it"); }
            case StmtKind::PanicStmt              { self._ice(s->range, "EmitIR: panic; PanicLowering owns it"); }
            case StmtKind::YieldStmt              { self._yield(cast::<YieldStmt>(s)); }
            case StmtKind::RuntimeAssertStmt      { self._ice(s->range, "EmitIR: assert; not emitted yet (a crash-family check, PANIC.md §2.4a)"); }
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
            case StmtKind::EvalBlockStmt          { self._ice(s->range, "EmitIR: an eval block in a function body; FeatureGateCheck rejects it"); }
            default { self._ice(s->range, f"EmitIR: statement kind {to_string(s->kind)} is not in the core"); }
        }
    }

    /// PanicLowering's C++ `try` (PANIC.md §3.5, §4.5a H): `try { body }
    /// catch (T& e) { arm } ...`, each arm's binding a reference to the
    /// exception (PanicLowering typed it), or the type alone when the arm
    /// binds nothing.
    priv fn _cxx_try(self, n: *TryCatchStmt) {
        self._cg->sink->spell(n->range, "try");
        self.emit_block(n->try_body);
        for var i: usize = 0; i < n->arms.size(); ++i {
            var a = n->arms.get(i);
            self._cg->sink->spell(a->range, "catch (");
            // Not _var_decl: a handler's parameter has no initializer, and a
            // local without one is value-initialized there.
            var vd = dyn_cast::<VariableDecl>(a->decl);
            if vd != &null {
                self._cg->sink->spell(vd->name.range, self._spell._type(vd->type_));
                self._name(vd->name);
            } else {
                self._cg->sink->spell(a->range, self._spell._type(a->filter->canonical) + "&");
            }
            self._cg->sink->spell(a->range, ")");
            self.emit_block(a->body);
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
            // A `fn`, class or enum the user wrote here was hoisted to
            // namespace scope (CXXSpell::is_hoisted_local): emit_tu defines
            // it there, and nothing of it stays in the body.
            default {
                if CXXSpell::is_hoisted_local(n->decl) { return; }
                // An alias has no C++ entity: every use is spelled through
                // its canonical, as a file-scope one's is (emit()).
                if n->decl->kind == DeclKind::TypeAliasDecl { return; }
                if n->decl->kind == DeclKind::StructDecl { self._local_record(cast::<StructDecl>(n->decl)); }
                else {
                    var sdc = reinterpret_cast::<*DeclContext>(n->decl->semantic_dc);
                    var scope_s = ("no semantic scope") if (sdc == &null) else (f"semantic scope kind {static_cast::<u32>(static_cast::<u8>(sdc->dc_kind))}");
                    self._ice(n->range, f"EmitIR: a statement-scope {to_string(n->decl->kind)} that is neither hoisted nor a lowering's record ({scope_s}, implicit={n->decl->is_implicit})");
                }
            }
        }
        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
    }

    /// `[const|static|constexpr] TYPE name [= init]`; no trailing `;`.
    /// After X `type_` is never null on a checked tree; `auto` is the
    /// pre-X fallback and is a bug if it ever prints for real code.
    priv fn _var_decl(self, n: *VariableDecl) {
        if (n->kind == DeclKind::RecoveryDecl) { self._ice(n->range, "EmitIR: poisoned VariableDecl reached codegen"); }
        // A `try`'s raw slot (PanicLowering): storage only, built by a
        // SlotPut and read once by a SlotTake. No initializer: nothing is
        // built until a failing site builds it.
        if n->raw_slot {
            if ((n->type_ == &null) || (n->init != &null)) { self._ice(n->range, "EmitIR: a raw slot with no type or with an initializer; PanicLowering mints neither"); }
            self._cg->sink->spell(n->name.range, "::" + LowerTargets::raw_slot() + "<" + self._spell._type(n->type_) + ">");
            self._name(n->name);
            return;
        }
        switch n->storage {
            case StorageClass::Const  { self._cg->sink->kw_const(n->name);     }
            case StorageClass::Static { self._cg->sink->kw_static(n->name);    }
            case StorageClass::Eval   { self._cg->sink->kw_constexpr(n->name); }
            default { }
        }
        // A function-local `thread` is `static thread_local`: one instance
        // per thread that keeps its value across calls (variables.mdx).
        // Left as plain `static`, every thread would share it.
        if n->is_thread { self._cg->sink->kw_thread_local(n->name); }
        // `static const x` (either order): the const is the binding's, so
        // C++ gets `static const T x`, which is what a const local would add.
        if n->const_binding { self._cg->sink->kw_const(n->name); }
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
        // `inline` (EVAL.md 1.2b): every TU that reads an eval binding
        // writes this same definition (EmitPlan::visible_eval_vars), since
        // an `extern const` is no constant expression to an importer.
        var head = ("inline constexpr ") if (n->is_eval()) else ("");
        var c: *Type = &null;
        if n->type_->canonical != &null { c = canon_unqual(n->type_->canonical); }
        var saved = self._cur_global;
        self._cur_global = n;
        // An initializer that reaches a private member is checked by C++ in
        // the variable's context, which no record can befriend: it becomes
        // the body of a thunk its file's records do befriend
        // (GlobalInitReach, FileFriends::globals), and the variable calls it.
        if GlobalInitReach::needs_thunk(&(self._spell), n) {
            self._cg->sink->spell(at, self._spell.ginit_decl(n) + " { return");
            self._value(n->init, n->type_);
            self._cg->sink->spell(at, "; }");
            self._cg->sink->brk();
            self._cg->sink->spell(at, head + self._spell.global_var(n) + " = "
                + LowerTargets::global_init_thunk(self._spell.leaf(d)) + "()");
            self._cur_global = saved;
            self._cg->sink->synth_at_end(n->range, clang::tok::semi);
            self._close_ns(n->range, wrap);
            return;
        }
        self._cg->sink->spell(at, head + self._spell.global_var(n));
        self._var_init(n, c);
        self._cur_global = saved;
        self._cg->sink->synth_at_end(n->range, clang::tok::semi);
        self._close_ns(n->range, wrap);
    }

    /// The `return` keyword borrows the statement's first six bytes; correct
    /// only because Kairo spells it `return` too. TODO(ast): retain the token.
    priv fn _return(self, n: *ReturnStmt) {
        // In a closure: the lambda's own return, to the closure's type.
        if self._closure != &null {
            self._cg->sink->synth(SourceRange::from_bounds(n->range.start, u32(6)), clang::tok::kw_return);
            var crt = self._closure->return_type;
            if self._closure->panic_result != &null { crt = self._closure->panic_result; }
            if n->value != &null { self._value(n->value, crt); }
            self._cg->sink->synth_at_end(n->range, clang::tok::semi);
            return;
        }
        // Out of an `eval for` copy: the function's return slot, then stop
        // the fold; the code after the expansion returns (EVAL.md §5).
        if self._ef_depth > 0 {
            self._cg->sink->spell(n->range, "{ " + LowerTargets::eval_for_ret_flag() + " = true;");
            if n->value != &null {
                self._cg->sink->spell(n->range, LowerTargets::eval_for_ret_val() + " =");
                var vrt: *Type = &null;
                if self._cur_fn != &null { vrt = self._cur_fn->return_type; }
                if (self._cur_fn != &null) && (self._cur_fn->panic_result != &null) { vrt = self._cur_fn->panic_result; }
                self._value(n->value, vrt);
                self._cg->sink->spell(n->range, ";");
            }
            self._cg->sink->spell(n->range, "return false; }");
            return;
        }
        // An eval generator's `return` hands back what it yielded.
        if (self._cur_fn != &null) && self._cur_fn->is_generator && self._cur_fn->is_eval() {
            self._cg->sink->spell(n->range, "return " + LowerTargets::eval_yield_buf() + ";");
            return;
        }
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
            // A panicking function returns its Panic result (PanicLowering
            // built every returned value as one).
            if (self._cur_fn != &null) && (self._cur_fn->panic_result != &null) { rt = self._cur_fn->panic_result; }
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
        // An eval generator pushes into its buffer (EVAL.md §5).
        if self._cur_fn->is_eval() {
            self._cg->sink->spell(n->range, LowerTargets::eval_yield_buf() + "." + LowerTargets::eval_buf_push() + "(");
            self._value(n->value, self._yield_elem(self._cur_fn));
            self._cg->sink->spell(n->range, ");");
            return;
        }
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
        // An `eval if` EvalIfFolding could not fold (a function body only):
        // C++ chooses, and discards the other branch in a template.
        var kw = ("if constexpr") if (n->is_eval) else ("if");
        self._cg->sink->spell(SourceRange::from_bounds(n->range.start, u32(2)), (kw) if (own) else (kw + " ("));
        self.emit(n->cond);
        if !own { self._cg->sink->spell(n->cond->range, ")"); }
        self.emit_block(n->then_);
        if n->else_ != &null {
            self._cg->sink->spell(n->else_->range, "else");
            self.emit(n->else_);   // a ConditionalStmt (else-if) or a CompoundStmt.
        }
    }

    /// `eval for i in X { body }` (EVAL.md §5): the body expanded once per
    /// value with an index pack, so in each copy `i` is a constant:
    ///
    ///   { [&]<usize... K>(::__kairo_iseq<usize, K...>) {
    ///       (... && [&]<usize I>() -> bool { constexpr T i = VAL(I); body; return true; }
    ///                .template operator()<K>());
    ///     }(__make_integer_seq<::__kairo_iseq, usize, COUNT>{}); }
    ///
    /// The `&&` fold is the unrolled loop: `continue` is `return true` from a
    /// copy, `break` `return false`, which stops the fold. A `return` sets
    /// the function's flag (and value slot) and stops it, and the code after
    /// the outermost expansion returns; an inner one stops its enclosing
    /// copy. VAL / COUNT: a range is `LO + I` and `HI - LO` (`+ 1` when
    /// inclusive); an array its elements; an eval generator's values are
    /// computed once, into `static constexpr` locals, ahead of the expansion.
    priv fn _eval_for(self, n: *RangedForStmt) {
        var sz   = "decltype(sizeof(0))";
        var at   = n->range;
        var elem = n->iter_elem;
        if (elem == &null) { self._ice(at, "EmitIR: an eval for with no element type; X gate failure"); }
        if (n->bindings.size() != 1) { self._ice(at, "EmitIR: an eval for with other than one binding; EvalUsageChecking rejects it"); }
        var bd = n->bindings[0];
        var vd = dyn_cast::<VariableDecl>(bd.decl);
        var et = self._spell._type(elem);
        var outer = (self._ef_depth == 0);
        var rt: *Type = &null;
        if (self._cur_fn != &null) && (!self._cur_fn->is_noreturn) { rt = self._cur_fn->return_type; }
        if (self._cur_fn != &null) && (self._cur_fn->panic_result != &null) { rt = self._cur_fn->panic_result; }   // what its `return`s now carry.
        var has_val = (rt != &null) && (rt->canonical != &null) && (!self.tu_is_void(rt->canonical));

        self._cg->sink->spell(at, "{");
        if outer {
            self._cg->sink->spell(at, "bool " + LowerTargets::eval_for_ret_flag() + " = false;");
            if has_val { self._cg->sink->spell(at, self._spell._type(rt) + " " + LowerTargets::eval_for_ret_val() + "{};"); }
        }

        var gk: usize = 0;
        var is_range = (n->ev_lo != &null) && (n->ev_hi != &null);
        var is_gen   = (!is_range) && (n->iter_kind == IterKind::User);
        if is_gen {
            gk = self._ef_gens;
            self._ef_gens += 1;
            var gn = LowerTargets::eval_for_gen_n(gk);
            self._cg->sink->spell(at, "static constexpr " + sz + " " + gn + " = (");
            self.emit(n->iterable);
            self._cg->sink->spell(at, ")." + LowerTargets::eval_buf_count() + ";");
            self._cg->sink->spell(at, "static constexpr auto " + LowerTargets::eval_for_gen(gk) + " = []() consteval { ::"
                + LowerTargets::eval_arr() + "<" + et + ", " + gn + "> a{}; auto b = (");
            self.emit(n->iterable);
            self._cg->sink->spell(at, "); for (" + sz + " k = 0; k < " + gn + "; ++k) a." + LowerTargets::eval_arr_values() + "[k] = b." + LowerTargets::eval_buf_data() + "[k]; return a; }();");
        }

        var K = LowerTargets::eval_for_pack(self._ef_depth);
        var I = LowerTargets::eval_for_index(self._ef_depth);
        self._cg->sink->spell(at, "[&]<" + sz + "... " + K + ">(::" + LowerTargets::eval_iseq() + "<" + sz + ", " + K + "...>) { (... && [&]<" + sz + " " + I + ">() -> bool {");
        // The binding: a constant in each copy.
        var nm = (self._spell.imm_name(vd->name.imm, self._owning_fid())) if (vd != &null) else (LowerTargets::eval_for_unused());
        self._cg->sink->spell(at, "[[maybe_unused]] constexpr " + et + " " + nm + " = ");
        if is_range {
            self._cg->sink->spell(at, "static_cast<" + et + ">((");
            self.emit(n->ev_lo);
            self._cg->sink->spell(at, ") + static_cast<" + et + ">(" + I + "));");
        } else if is_gen {
            self._cg->sink->spell(at, LowerTargets::eval_for_gen(gk) + "." + LowerTargets::eval_arr_values() + "[" + I + "];");
        } else {
            self._cg->sink->spell(at, "(");
            self.emit(n->iterable);
            self._cg->sink->spell(at, ")[" + I + "];");
        }

        var sd = self._ef_depth;
        var sl = self._ef_loops;
        self._ef_depth += 1;
        self._ef_loops = 0;
        for var i: usize = 0; i < n->body->body.size(); ++i { self.emit(n->body->body[i]); }
        self._ef_depth = sd;
        self._ef_loops = sl;

        self._cg->sink->spell(at, "return true; }.template operator()<" + K + ">()); }(__make_integer_seq<::" + LowerTargets::eval_iseq() + ", " + sz + ", ");
        if is_range {
            self._cg->sink->spell(at, "static_cast<" + sz + ">((");
            self.emit(n->ev_hi);
            self._cg->sink->spell(at, ") - (");
            self.emit(n->ev_lo);
            self._cg->sink->spell(at, ")" + ((" + 1") if (n->ev_incl) else ("")) + ")");
        } else if is_gen {
            self._cg->sink->spell(at, LowerTargets::eval_for_gen_n(gk));
        } else {
            var arr = dyn_cast::<FixedArrayType>(canon_unqual(n->iterable->type_));
            if (arr == &null) { self._ice(at, "EmitIR: an eval for over something that is not a range, an array or an eval generator; EvalUsageChecking rejects it"); }
            var ext = (self._spell._type(arr->extent_param)) if (arr->extent_param != &null) else (f"{arr->size_bits}");
            self._cg->sink->spell(at, ext);
        }
        self._cg->sink->spell(at, ">{});");

        var flag = LowerTargets::eval_for_ret_flag();
        if outer {
            if has_val { self._cg->sink->spell(at, "if (" + flag + ") { return " + LowerTargets::eval_for_ret_val() + "; }"); }
            else       { self._cg->sink->spell(at, "if (" + flag + ") { return; }"); }
        } else {
            self._cg->sink->spell(at, "if (" + flag + ") { return false; }");
        }
        self._cg->sink->spell(at, "}");
    }

    /// `for x in xs` over a type pack (`...xs: T`): the body once per
    /// element, each copy a lambda the `&&` fold calls with that element,
    ///
    ///   { (... && [&](auto& x) -> bool { body; return true; }(xs)); }
    ///
    /// under `_eval_for`'s protocol, which this shares: `continue` is
    /// `return true` from a copy, `break` `return false`, a `return` sets
    /// the function's flag (and value slot) and stops the fold, and the
    /// code after the outermost expansion returns.
    priv fn _pack_for(self, n: *RangedForStmt) {
        var at = n->range;
        if (n->bindings.size() != 1) { self._ice(at, "EmitIR: a for over a pack with other than one binding; X gate failure"); }
        var pk = dyn_cast::<NamedIdentExpr>(n->iterable);
        if (pk == &null) { self._ice(at, "EmitIR: a for over a pack whose iterable is not the pack's name; StmtTyping classifies only that"); }
        var vd = dyn_cast::<VariableDecl>(n->bindings[0].decl);
        var outer = (self._ef_depth == 0);
        var rt: *Type = &null;
        if (self._cur_fn != &null) && (!self._cur_fn->is_noreturn) { rt = self._cur_fn->return_type; }
        if (self._cur_fn != &null) && (self._cur_fn->panic_result != &null) { rt = self._cur_fn->panic_result; }   // what its `return`s now carry.
        var has_val = (rt != &null) && (rt->canonical != &null) && (!self.tu_is_void(rt->canonical));

        self._cg->sink->spell(at, "{");
        if outer {
            self._cg->sink->spell(at, "bool " + LowerTargets::eval_for_ret_flag() + " = false;");
            if has_val { self._cg->sink->spell(at, self._spell._type(rt) + " " + LowerTargets::eval_for_ret_val() + "{};"); }
        }
        var nm = (self._spell.imm_name(vd->name.imm, self._owning_fid())) if (vd != &null) else (LowerTargets::eval_for_unused());
        self._cg->sink->spell(at, "(... && [&]([[maybe_unused]] auto& " + nm + ") -> bool {");
        var sd = self._ef_depth;
        var sl = self._ef_loops;
        self._ef_depth += 1;
        self._ef_loops = 0;
        for var i: usize = 0; i < n->body->body.size(); ++i { self.emit(n->body->body[i]); }
        self._ef_depth = sd;
        self._ef_loops = sl;
        self._cg->sink->spell(at, "return true; }(");
        self.emit(n->iterable);
        self._cg->sink->spell(at, "));");

        var flag = LowerTargets::eval_for_ret_flag();
        if outer {
            if has_val { self._cg->sink->spell(at, "if (" + flag + ") { return " + LowerTargets::eval_for_ret_val() + "; }"); }
            else       { self._cg->sink->spell(at, "if (" + flag + ") { return; }"); }
        } else {
            self._cg->sink->spell(at, "if (" + flag + ") { return false; }");
        }
        self._cg->sink->spell(at, "}");
    }

    priv fn tu_is_void(self, t: *Type) -> bool {
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<BuiltinType>(c)) { return false; }
        var k = cast::<BuiltinType>(c)->builtin;
        return (k == BuiltinKind::Void) || (k == BuiltinKind::Never);
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
        if (n->is_eval) { self._ice(n->range, "EmitIR: a C-style eval for; EvalUsageChecking rejects it"); }
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
            case ExprKind::FloatingLiteralExpr  { self._float_lit(cast::<FloatingLiteralExpr>(e)); }
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
            case ExprKind::TypeTraitExpr {
                var tt = cast::<TypeTraitExpr>(e);
                self._cg->sink->spell(e->range, type_trait_cxx(tt->fact) + "(" + self._spell._type(tt->type_arg) + ")");
            }
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
            case ExprKind::ClosureExpr          { self._closure_expr(cast::<ClosureExpr>(e)); }
            case ExprKind::AwaitExpr            { self._ice(e->range, "EmitIR: await; the async lowering owns it"); }
            case ExprKind::UnwrapExpr           { self._ice(e->range, "EmitIR: unwrap!; CoalesceLowering owns it"); }
            case ExprKind::DefinedExpr          { self._ice(e->range, "EmitIR: defined!; EvalIfFolding owns it"); }
            case ExprKind::AttributedExpr       { self._ice(e->range, "EmitIR: expression attribute; FeatureGateCheck gates every one"); }
            case ExprKind::PanicOpExpr          { self._panic_op(cast::<PanicOpExpr>(e)); }
            case ExprKind::SpawnExpr            { self._ice(e->range, "EmitIR: spawn; the async lowering owns it"); }
            case ExprKind::ThreadExpr           { self._ice(e->range, "EmitIR: thread; the async lowering owns it"); }
            // `eval e`: computed by C++ at compile time, in place (EVAL.md
            // §0); EvalUsageChecking made sure `e` can be.
            case ExprKind::EvalExpr {
                self._cg->sink->spell(e->range, "[&]() consteval { return (");
                self.emit(cast::<EvalExpr>(e)->operand);
                self._cg->sink->spell(e->range, "); }()");
            }
            // `xs...` (or `...xs`): C++'s own pack expansion, in an argument
            // list.
            case ExprKind::PackExpansionExpr {
                self.emit(cast::<PackExpansionExpr>(e)->operand);
                self._cg->sink->spell(e->range, "...");
            }
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
        if self._fn_effect_value(e, want) { return; }
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

    /// A `fn` value converted to a `fn` type with a wider panic effect (P4:
    /// a set S into S' with S a subset, or no set into one; PANIC.md
    /// §2.10). The two C++ results differ, so the value is wrapped: a
    /// lambda holding it, whose result is `__kairo_pcall<R'>` of the call
    /// (the panic result forwarded, or the plain value as Ok). True when it
    /// emitted.
    ///
    ///   ::__kairo_fn<R'(A)>::own(new auto([__kairo_w = ::__kairo_fn<R(A)>(e)]
    ///       (A __kairo_a0) noexcept -> R' { return ::__kairo_pcall<R'>(__kairo_w, a0); }))
    priv fn _fn_effect_value(self, e: *Expr, want: *Type) -> bool {
        if (e == &null) || (want == &null) || (e->type_ == &null) || (want->canonical == &null) { return false; }
        var w = dyn_cast::<FunctionPointerType>(canon_unqual(want->canonical));
        var h = dyn_cast::<FunctionPointerType>(canon_unqual(e->type_));
        if (w == &null) || (h == &null) || (w == h) || (w->panic_result == &null) { return false; }
        if h->panic_result == w->panic_result { return false; }
        var rw = self._spell._type(w->panic_result);
        var ps = "";
        var fa = "";
        for var i: usize = 0; i < w->params.size(); ++i {
            var m = (w->modes[i]) if (i < w->modes.size()) else (ParamMode::Value);
            var an = LowerTargets::panic_wrap_arg(i);
            if i > 0 { ps += ", "; }
            ps += self._spell.param_named(w->params[i], m, an);
            fa += ", static_cast<decltype(" + an + ")&&>(" + an + ")";
        }
        var nx = ("") if (self._cg->opts.unwind) else (" noexcept");
        var fv = "::" + LowerTargets::fn_value();
        var wn = LowerTargets::panic_wrapped();
        self._cg->sink->spell(e->range, fv + "<" + self._spell.fn_signature(w) + ">::" + LowerTargets::fn_value_own() + "(new auto([" + wn + " = " + fv + "<" + self._spell.fn_signature(h) + ">(");
        self.emit(e);
        self._cg->sink->spell(e->range, ")](" + ps + ") mutable" + nx + " -> " + rw + " { return ::" + LowerTargets::panic_call_as() + "<" + rw + ">(" + wn + fa + "); }))");
        return true;
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
        // Read at compile time (EVAL.md 2a): the bytes as template
        // arguments of `__kairo_estr`, a `const unsigned char` array with the
        // NUL appended, which needs no cast to reach the string's `data`.
        if n->const_eval {
            // A long one is a named array instead (EVAL.md §11), which
            // InterfaceEmitter defined at global scope ahead of every body
            // (EmitPlan::big_strs collected it from this body).
            if len > LowerTargets::eval_str_inline_max() {
                self._cg->sink->spell(n->range, "::" + LowerTargets::eval_str_hashed(LowerTargets::eval_str_hash(p, len), len));
                return;
            }
            var t = "::" + LowerTargets::eval_str() + "<";
            for var i: usize = 0; i < len; ++i {
                if i > 0 { t += ", "; }
                t += f"{static_cast::<u32>(p[i])}";
            }
            t += ">";
            self._cg->sink->spell(n->range, t);
            return;
        }
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
            self._cg->sink->spell(n->range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(si) + "." + LowerTargets::ctor_slot_get() + "()");
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
        self._cg->sink->spell(n->range, ((LowerTargets::ext_receiver_name()) if (self._cur_ext != &null) else ("this")));
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
        if (k != usize(-1)) && (n->base != &null) && (n->steps.get(k)->resolved_decl == &null) && self._dependent_step(n, n->steps.get(k)) {
            // `T::classof(n)` under `<T: type>`: a static member of a type
            // only the instance knows, written through the parameter. As
            // written, `T::f`, and clang looks it up per instance.
            self.emit(n->base);
            for var j: usize = 0; j <= k; ++j {
                self._dependent_member_named(n->steps.get(j), "::");
            }
            i = k + 1;
        } else if k != usize(-1) {
            var st = n->steps.get(k);
            if (st->resolved_decl == &null) { self._ice(st->range, "EmitIR: unbound `::` step reached codegen; ChainBinding gate failure"); }
            // A member of a type named through a generic instance
            // (`L<i32>::Color::Green`, GH#91): qualified through that
            // type, since the plain qualified name `::ns::L::Color` names
            // the template without its arguments.
            // A static member named through an instance (`Box<i32>::count`)
            // has it on the step (ChainExpr::Step::through), which also
            // covers a head with no earlier step to read it from.
            var pt: *Type = &null;
            if k > 0 { pt = n->steps.get(k - 1)->resolved_type; }
            var pr = (dyn_cast::<RecordType>(canon_unqual(pt->canonical))) if ((pt != &null) && (pt->canonical != &null)) else (&null);
            if st->through != &null {
                self._cg->sink->spell(st->range, self._spell._type(st->through, &null) + "::" + self._spell.leaf(st->resolved_decl));
            } else if (pr != &null) && (pr->outer != &null) {
                self._cg->sink->spell(st->range, self._spell._type(pt, &null) + "::" + self._spell.leaf(st->resolved_decl));
            } else {
                self._cg->sink->spell(st->range, self._spell.qual_name(st->resolved_decl));
            }
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
                self._cg->sink->spell(st0->range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(s0) + "." + LowerTargets::ctor_slot_get() + "()");
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
            if ((st->access_kind == ChainExpr::AccessKind::QuestionDot) || (st->access_kind == ChainExpr::AccessKind::QuestionArrow)) { self._ice(st->range, "EmitIR: optional chaining; CoalesceLowering owns it"); }
            if st->is_operator() {
                var onm = self._spell.leaf(st->resolved_decl);
                // A generic `op as -> T` called through an instance: the
                // target OperatorLowering bound (the template's `operator T`
                // has no T here).
                var ocf = dyn_cast::<FunctionDecl>(st->resolved_decl);
                if (ocf != &null) && ocf->is_operator && (ocf->op_token.size() > 0) && (ocf->op_token[0].kind == TokenKind::KwAs) && (st->resolved_type != &null) {
                    onm = "operator " + self._spell._type(st->resolved_type);
                }
                self._cg->sink->spell(st->range, (("->") if (is_ptr) else (".")) + onm);
                is_ptr = false;
                continue;
            }
            if (st->is_tuple_index()) { self._ice(st->range, "EmitIR: tuple index step; TupleLowering owns it"); }
            if (self._is_extension_member(st->resolved_decl)) { self._ice(st->range, "EmitIR: extension member used as a value; ExtensionLowering rewrites the call form"); }
            if (st->resolved_decl == &null) && self._dependent_step(n, st) {
                self._dependent_member(st, is_ptr);
                is_ptr = false;
                continue;
            }
            if (st->resolved_decl == &null) { self._ice(st->range, "EmitIR: unbound member step reached codegen; gate failure"); }
            self._cg->sink->spell(st->range, (("->") if (is_ptr) else (".")));
            self._name(st->name->name);
            // A pack-expanded variant's member holds one payload per element:
            // element K is its getter's (EnumLayoutQuery::payload_ref).
            if st->pack_index >= 0 {
                self._cg->sink->spell(st->range, ".template " + LowerTargets::adt_pack_get() + "<" + f"{st->pack_index}" + ">()");
            }
            is_ptr = self._type_is_pointer(st->resolved_type);
        }
        return is_ptr;
    }

    /// A member step Sema left unbound ON PURPOSE: the chain is dependent
    /// and its first unbound step goes through a `<T: type>` parameter, so
    /// the step names a member of a type only the instance knows (MONO.md
    /// D1). Anything else unbound still ICEs: a bounded body is Kairo's to
    /// check (D0), and an unbound step there (a bound call's dependent
    /// result, `c.get(1).w`) is a Sema gap, not a request for clang.
    priv fn _dependent_step(self, n: *ChainExpr, st: *ChainExpr::Step) -> bool {
        if !n->is_instantiation_dependent() { return false; }
        if (st->candidate_cell != &null) || (st->name == &null) || st->name->is_poisoned() { return false; }
        var k = st->access_kind;
        if (k != ChainExpr::AccessKind::Dot) && (k != ChainExpr::AccessKind::Arrow) && (k != ChainExpr::AccessKind::ColonColon) { return false; }
        return self._duck_rooted(n);
    }

    /// Whether \p n's first unbound step is reached through a `: type`
    /// parameter: the base names the parameter itself (`T::f`), or the
    /// receiver of that step has the parameter's type, or points to it
    /// (`t.f`, `d->f`). Steps after it hang off a result only the instance
    /// knows, so they go with it.
    priv fn _duck_rooted(self, n: *ChainExpr) -> bool {
        var recv: *Type = &null;
        if n->base != &null {
            var ni = dyn_cast::<NamedIdentExpr>(n->base);
            if (ni != &null) && (ni->resolved_decl != &null) && isa::<GenericParamDecl>(ni->resolved_decl) {
                return cast::<GenericParamDecl>(ni->resolved_decl)->kind_bound == GenericParamKindBound::Duck;
            }
            recv = n->base->type_;
        }
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if st->resolved_decl == &null {
                // `t.inner().w`: the base is itself an unknown duck call, so
                // `.w` hangs off it like a later step of one chain.
                if (i == 0) && (recv == &null) && (n->base != &null) { return self._duck_rooted_expr(n->base); }
                return self._is_duck_param_type(recv);
            }
            recv = st->resolved_type;
        }
        return false;
    }

    /// An unknown expression that is a duck chain, or a call through one.
    priv fn _duck_rooted_expr(self, e: *Expr) -> bool {
        var c = dyn_cast::<CallExpr>(e);
        if c != &null { e = c->callee; }
        var ch = dyn_cast::<ChainExpr>(e);
        if ch == &null { return false; }
        return ch->is_instantiation_dependent() && self._duck_rooted(ch);
    }

    /// \p t is a `: type` parameter, or a pointer to one.
    priv fn _is_duck_param_type(self, t: *Type) -> bool {
        if t == &null { return false; }
        var c = t->canonical;
        if c == &null { c = t; }
        c = canon_unqual(c);
        if (c != &null) && (c->kind == TypeKind::PointerType) {
            var pt = cast::<PointerType>(c)->pointee;
            if pt == &null { return false; }
            c = pt->canonical;
            if c == &null { c = pt; }
            c = canon_unqual(c);
        }
        if c == &null { return false; }
        var g = dyn_cast::<GenericParamType>(c);
        if (g == &null) || (g->owner == &null) { return false; }
        var gps = decl_generic_params(g->owner);
        if static_cast::<usize>(g->param_index) >= gps.size() { return false; }
        var gp = gps[static_cast::<usize>(g->param_index)];
        return (gp != &null) && (gp->kind_bound == GenericParamKindBound::Duck);
    }

    /// A dependent member step spelled as written, for clang to look up in
    /// each instance (MONO.md D1): `.f` / `->f`, and `.template f<A...>` when
    /// it carries generic arguments, since the object's type is dependent.
    /// The separator is the receiver's when its type is known to be a
    /// pointer, else the one the user wrote; past the first unbound step the
    /// type is the instance's, so a later step can only go by the spelling.
    priv fn _dependent_member(self, st: *ChainExpr::Step, is_ptr: bool) {
        var arrow = is_ptr || (st->access_kind == ChainExpr::AccessKind::Arrow);
        self._dependent_member_named(st, (("->") if (arrow) else (".")));
    }

    /// \p sep, then the step's name as written, `template name<A...>` when it
    /// carries generic arguments (the scope is dependent, so C++ needs the
    /// keyword to read `<` as an argument list).
    priv fn _dependent_member_named(self, st: *ChainExpr::Step, sep: string) {
        self._cg->sink->spell(st->range, sep);
        if (st->name == &null) { self._ice(st->range, "EmitIR: a dependent member step with no name"); }
        if st->generic_args.size() == 0 {
            self._name(st->name->name);
            return;
        }
        self._cg->sink->spell(st->range, "template ");
        self._name(st->name->name);
        var s = "<";
        for var i: usize = 0; i < st->generic_args.size(); ++i {
            if i > 0 { s += ", "; }
            var ga = st->generic_args.get(i);
            if (ga->ty == &null) { self._ice(st->range, "EmitIR: a dependent member's generic argument with no type"); }
            s += self._spell._type(ga->ty);
        }
        s += ">";
        self._cg->sink->spell(st->range, s);
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
        c = canon_unqual(c);
        // A C++ reference to a pointer is that pointer: `ptrs[0]->id` on a
        // `vector<*Node>` steps through `reference` (`Node*&`), and `.` there
        // is clang's "is a pointer; did you mean '->'" (CL001E).
        if isa::<CXXLValueRefType>(c) { c = canon_unqual(cast::<CXXLValueRefType>(c)->referee); }
        else if isa::<CXXRValueRefType>(c) { c = canon_unqual(cast::<CXXRValueRefType>(c)->referee); }
        return (c != &null) && (c->kind == TypeKind::PointerType);
    }

    priv fn _type_is_builtin_int(self, t: *Type) -> bool {
        if t == &null { return false; }
        var c = t->canonical;
        if c == &null { c = t; }
        var u = canon_unqual(c);
        if (u == &null) || (!isa::<BuiltinType>(u)) { return false; }
        return cast::<BuiltinType>(u)->info()->is_integer();
    }

    // --- Calls -----------------------------------------------------------------------

    priv fn _call(self, n: *CallExpr) {
        // An overload set of imported templates that only an instance can
        // split (`on_default(x)` with `x: T`: which `enable_if` holds is
        // T's question -- OverloadResolution::_sfinae_pending). Left
        // unpromoted by decision; it goes out as the dependent call it is,
        // by the set's one C++ name, and clang resolves it per instance.
        var dset = self._dependent_imported_set(n->callee);
        if dset.size() > 0 {
            var wa = self._written_targs(n->callee);
            if wa.size() > 0 { dset += self._spell.args_str(&wa); }
            self._cg->sink->spell(n->callee->range, dset);
            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren);
            self._args(n, &null, true, &null);
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren);
            return;
        }
        var callee = self._callee_decl(n->callee);
        // A call through a `fn` value: a local, a parameter, a field, or any
        // expression of `fn` type (`make()(4)`). Its parameters are the
        // type's; an operand that names a function is a plain call below.
        var fv = self._fn_value_type(n->callee, callee);
        if fv != &null {
            self.emit(n->callee);
            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren);
            self._fn_value_args(n, fv);
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren);
            return;
        }
        if callee == &null {
            // A member call on a dependent receiver (`t.value()` under
            // `<T: type>`): Sema typed it as written and bound nothing, by
            // decision (MONO.md D1). It goes out as written, receiver chain
            // and arguments untouched, and clang resolves and checks it in
            // each instance. No parameter to convert to, no arity to check.
            if self._dependent_member_call(n) {
                self.emit(n->callee);
                self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren);
                self._args(n, &null, true, &null);
                self._cg->sink->synth_at_end(n->range, clang::tok::r_paren);
                return;
            }
            self._ice(n->range, "EmitIR: unbound callee reached codegen; ExprTyper gate failure");
        }

        var ch = dyn_cast::<ChainExpr>(n->callee);
        var last: *ChainExpr::Step = &null;
        if (ch != &null) && (ch->steps.size() > 0) { last = ch->steps.get(ch->steps.size() - 1); }
        if ((last != &null) && self._is_extension_member(last->resolved_decl)) { self._ice(n->range, "EmitIR: an extension member called through a chain reached codegen; ExtensionLowering rewrites it to a free call"); }
        // A requirement is no C++ function: the call goes through its
        // interface's witness, which ExtensionLowering records (CODEGEN.md
        // §7b.5). `T::make()` and `I::m(a)` are not rewritten yet.
        if self._is_requirement(callee) && (n->witness_iface == &null) {
            self._ice(n->range, "EmitIR: a call bound to an interface requirement with no recorded witness; ExtensionLowering rewrites `a.m()` through a bound (a `::` form is not built)");
        }

        // The constructor, not the type the callee names: its parameters are
        // what the arguments are cast to.
        var f = dyn_cast::<FunctionDecl>(callee);
        if n->ctor_decl != &null { f = dyn_cast::<FunctionDecl>(n->ctor_decl); }
        var inst  = reinterpret_cast::<*InstanceEntry>(n->instance);
        // `T::Node(args)`: the callee is the requirement, the type is the
        // witness's member type, constructed as any type is (CallTyping
        // admitted it through a constructor bound).
        var assoc_ctor = isa::<TypeAliasDecl>(callee) && (n->type_ != &null) && isa::<AssocType>(canon_unqual(n->type_));
        var bound = (n->ctor_decl != &null) || self._is_type_decl(callee) || self._is_ctor(f) || assoc_ctor
                 || ((last != &null) && (last->access_kind != ChainExpr::AccessKind::ColonColon));
        self._check_arity(n, f, bound);

        // `Base::m(obj)`: a record's own method named by its qualified name,
        // the object as argument zero (classes-inheritance.md, Calling base
        // class methods). C++ has no such call; its spelling is
        // `obj.Base::m(...)`, which is also the NON-virtual call the
        // qualified name asks for. An extension member, a witness call and
        // a constructor have their own forms above and below.
        if (!bound) && (f != &null) && f->is_method() && (n->args.size() > 0) && (last != &null)
        && (n->witness_iface == &null) && (!self._is_extension_member(callee)) {
            self._cg->sink->spell(n->args[0]->range, "(");
            self._arg(n->args[0], f->params[0], inst);
            self._cg->sink->spell(n->args[0]->range, ").");
            var qt = n->qualifier;
            if (qt == &null) && (CXXSpell::template_params(CXXSpell::rep(reinterpret_cast::<*DeclContext>(f->semantic_dc)->dc_owner)).size() > 0) {
                qt = self._qualifying_instance(n->args[0], f);
            }
            if qt != &null {
                // Through a generic record's instance, `Box<int>::get`: the
                // arguments are on the qualifier (CallExpr::qualifier), or on
                // the object's base list (`IntBox derives Box<i32>`).
                var s = self._spell._type(qt) + "::";
                if (inst != &null) && (f->generic_params.size() > 0) {
                    s += "template " + self._spell.leaf(callee) + self._spell.args_str(&(inst->args));
                } else {
                    s += self._spell.leaf(callee);
                }
                self._cg->sink->spell(n->callee->range, s);
            } else {
                self.emit(n->callee);
            }
            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren);
            self._args(n, f, bound, inst, true);
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren);
            return;
        }

        if self._is_ctor(f) || self._is_type_decl(callee) || assoc_ctor {
            if n->type_ == &null { self._ice_untyped(static_cast::<*Expr>(n), "EmitIR: untyped constructor call; ExprTyper gate failure"); }
            self._cg->sink->spell(n->callee->range, self._spell._type(n->type_));
        } else if n->witness_iface != &null {
            // `::ring::Scalable_witness<T>::scale(`: the receiver is argument
            // zero already, in the form the witness member takes it.
            var wi = canon_unqual(n->witness_iface);
            if (!isa::<RecordType>(wi)) { self._ice(n->range, "EmitIR: a witness that is not an interface instance"); }
            var idecl = CXXSpell::rep(decl_pattern(CXXSpell::rep(cast::<RecordType>(wi)->decl)));
            var s = self._spell.witness_name(idecl) + self._spell.witness_args(self._spell._type(n->witness_self), wi);
            s += "::";
            // A generic requirement's arguments, when the call has concrete
            // ones, spelled with `template`: the witness is a dependent type.
            // A dependent call (no instance) leaves them to deduction.
            if (f->generic_params.size() > 0) && (inst != &null) {
                s += "template " + self._spell.witness_member_name(f) + self._spell.args_str(&(inst->args));
            } else {
                s += self._spell.witness_member_name(f);
            }
            self._cg->sink->spell(n->callee->range, s);
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
        } else if (f != &null) && (f->generic_params.size() > 0) && decl_is_imported(callee) && self._plain_callee(n->callee) {
            // An imported function template is called as C++ calls it: the
            // generic arguments the call WROTE, and clang deduces the rest
            // from the arguments -- which Sema already had clang do
            // (OverloadResolution::_clang_substitute). Kairo's instance args
            // are the wrong spelling for the rest: a forwarding pack's
            // elements are value types (`Args&&` against an lvalue needs
            // `T&`, which only deduction produces), and a parameter only
            // C++ fills (`enable_if_t<...> = 0`) has no instance arg at all,
            // so the instance is null and `make_unique<i32>(5)` lost its
            // `<int>` along with it.
            var wa = self._written_targs(n->callee);
            var s = self._spell.qual_name(callee);
            if wa.size() > 0 { s += self._spell.args_str(&wa); }
            self._cg->sink->spell(n->callee->range, s);
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

    /// \p n calls a member Sema left unbound because its receiver is
    /// dependent (_dependent_step): the callee is a value chain whose LAST
    /// step is that member.
    priv fn _dependent_member_call(self, n: *CallExpr) -> bool {
        var ch = dyn_cast::<ChainExpr>(n->callee);
        if (ch == &null) || (ch->steps.size() == 0) { return false; }
        var last = ch->steps.get(ch->steps.size() - 1);
        if last->resolved_decl != &null { return false; }
        return self._dependent_step(ch, last);
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
        // A type pack takes any number of arguments, none included.
        var tpack = false;
        for var i: usize = 0; i < f->params.size(); ++i { if param_is_type_pack(f->params[i]) { tpack = true; break; } }
        if tpack { want -= 1; if have >= want { return; } }
        if (have + tail < want) { self._ice(n->range, "EmitIR: a call short of arguments reached codegen; CallLowering owns defaults"); }
        if ((have > want) && (!f->ffi_c_variadic)) { self._ice(n->range, "EmitIR: a call with more arguments than parameters reached codegen"); }
    }

    /// A callee whose name is spelled whole: a bare name or a `::` path. A
    /// generic METHOD through `.` needs `.template m<...>` and is still
    /// RESOLUTION.md item r.
    /// The one C++ name of an UNPROMOTED plain callee whose candidates are
    /// all imported functions spelled alike, or "" for any other callee.
    priv fn _dependent_imported_set(self, c: *Expr) -> string {
        if !self._plain_callee(c) { return ""; }
        var cell: *OverloadCell = &null;
        var ni = dyn_cast::<NamedIdentExpr>(c);
        if (ni != &null) && (ni->resolved_decl == &null) { cell = ni->candidate_cell; }
        var ch = dyn_cast::<ChainExpr>(c);
        if (ch != &null) && (ch->steps.size() > 0) {
            var last = ch->steps.get(ch->steps.size() - 1);
            if last->resolved_decl == &null { cell = last->candidate_cell; }
        }
        if (cell == &null) || (cell->size() == 0) { return ""; }
        var name = "";
        for var i: usize = 0; i < cell->size(); ++i {
            var d = cell->get(i);
            if (d == &null) || (!isa::<FunctionDecl>(d)) || (!decl_is_imported(d)) { return ""; }
            var s = self._spell.qual_name(d);
            if i == 0 { name = s; }
            else if s != name { return ""; }
        }
        return name;
    }

    /// The generic arguments written on a plain callee (`f<A>` or
    /// `ns::f<A>`), as canonicals in order; empty when none were written.
    priv fn _written_targs(self, c: *Expr) -> vec::<*Type> {
        var out = vec::<*Type>();
        var gl: *FrozenList::<ChainType::GenericArg> = &null;
        if isa::<NamedIdentExpr>(c) { gl = &(cast::<NamedIdentExpr>(c)->generic_args); }
        var ch = dyn_cast::<ChainExpr>(c);
        if (ch != &null) && (ch->steps.size() > 0) { gl = &(ch->steps.get(ch->steps.size() - 1)->generic_args); }
        if gl == &null { return out; }
        for var i: usize = 0; i < gl->size(); ++i {
            var ga = gl->get(i);
            if (ga->ty == &null) || (ga->ty->canonical == &null) { self._ice(c->range, "EmitIR: a written generic argument with no type"); }
            out.push_back(ga->ty->canonical);
        }
        return out;
    }

    priv fn _plain_callee(self, c: *Expr) -> bool {
        if isa::<NamedIdentExpr>(c) { return true; }
        var ch = dyn_cast::<ChainExpr>(c);
        if (ch == &null) || (ch->steps.size() == 0) { return false; }
        return ch->steps.get(ch->steps.size() - 1)->access_kind == ChainExpr::AccessKind::ColonColon;
    }

    /// Arguments, each cast to its parameter's canonical where it differs.
    /// \p bound: the callee carries its receiver, so `self` takes no argument.
    /// \p skip_object: argument zero is the object of a qualified method
    /// call, already written in front of the callee.
    priv fn _args(self, n: *CallExpr, f: *FunctionDecl, bound: bool, inst: *InstanceEntry, skip_object: bool = false) {
        var params = self._call_params(f, bound);
        // A type pack's run (CallLowering leaves it one argument per
        // element): every argument from the pack's slot to the surplus is the
        // pack's, and goes as written -- the instance's elements ARE those
        // arguments' types (CallTyping), so there is nothing to convert to.
        var pk  = usize(-1);
        var run: usize = 0;
        for var i: usize = 0; i < params.size(); ++i {
            if param_is_type_pack(params[i]) { pk = i; break; }
        }
        if (pk != usize(-1)) && (n->args.size() + 1 >= params.size()) { run = n->args.size() + 1 - params.size(); }
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            if skip_object && (i == 0) { continue; }
            var first: usize = (1) if (skip_object) else (0);
            if i > first { self._cg->sink->synth_at_end(n->args[i - 1]->range, clang::tok::comma); }
            if (pk != usize(-1)) && (i >= pk) && (i < pk + run) { self.emit(a); continue; }
            var p: *ParamDecl = &null;
            var pi = i;
            if (pk != usize(-1)) && (i >= pk + run) { pi = (i + 1) - run; }
            if pi < params.size() { p = params[pi]; }
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

    /// The `fn` type of a callee that is a VALUE, not a function: one whose
    /// decl (if any) is not a function or a type and whose canonical is a
    /// `fn(...)`. Null otherwise.
    priv fn _fn_value_type(self, c: *Expr, d: *Decl) -> *FunctionPointerType {
        if (d != &null) && (isa::<FunctionDecl>(d) || self._is_type_decl(d)) { return &null; }
        if (c == &null) || (c->type_ == &null) { return &null; }
        var t = canon_unqual(c->type_);
        if (t == &null) || (!isa::<FunctionPointerType>(t)) { return &null; }
        return cast::<FunctionPointerType>(t);
    }

    /// Arguments of a call through a `fn` value, each as its parameter in
    /// the type: `@inout` bare, `@move` cast to `T&&` from an lvalue, the
    /// rest through the exactness cast, as for a function's (_arg).
    priv fn _fn_value_args(self, n: *CallExpr, f: *FunctionPointerType) {
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            if i > 0 { self._cg->sink->synth_at_end(n->args[i - 1]->range, clang::tok::comma); }
            if i >= f->params.size() { self.emit(a); continue; }
            var pt = *(f->params.get(i));
            var m  = *(f->modes.get(i));
            var u = dyn_cast::<UnaryOperatorExpr>(a);
            if (u != &null) && u->is_mode_marker { self.emit(u->operand); continue; }
            if m == ParamMode::Inout { self.emit(a); continue; }
            if (m == ParamMode::Move) && a->is_lvalue() {
                self._cg->sink->spell(a->range, "static_cast<" + self._spell._type(pt) + "&&>(");
                self.emit(a);
                self._cg->sink->spell(a->range, ")");
                continue;
            }
            self._value(a, pt);
        }
    }

    // --- Closures ------------------------------------------------------------------

    /// A closure is a C++ lambda (CODEGEN.md §6, Closures), wrapped in the
    /// `fn` value its type is:
    ///   captures nothing  `::__kairo_fn<R(A)>(+[](A a) -> R { ... })`
    ///   captures          `::__kairo_fn<R(A)>::own(new auto([c...](A a) mutable -> R { ... }))`
    /// The capture list is ClosureCaptures' decision (_capture_list). A
    /// capturing lambda is `mutable`: a by-copy capture is the closure's
    /// own variable, which its body may assign and which keeps its value
    /// from one call to the next. `new auto(prvalue)` builds the lambda in
    /// its heap slot directly, so no temporary lambda copies a capture.
    priv fn _closure_expr(self, n: *ClosureExpr) {
        if (!n->caps_resolved) { self._ice(n->range, "EmitIR: a closure with no capture decision; ClosureCaptures must run"); }
        if (n->body_block == &null) { self._ice(n->range, "EmitIR: an expression-bodied closure; ExprBodyDesugar wraps it in a block"); }
        if (n->generic_params.size() > 0) { self._ice(n->range, "EmitIR: a generic closure; FeatureGateCheck rejects it"); }
        var fp: *FunctionPointerType = &null;
        if n->type_ != &null {
            var t = canon_unqual(n->type_);
            if (t != &null) && isa::<FunctionPointerType>(t) { fp = cast::<FunctionPointerType>(t); }
        }
        if (fp == &null) { self._ice_untyped(static_cast::<*Expr>(n), "EmitIR: a closure with no fn type; ExprTyper gate failure"); }

        var caps = self._capture_list(n);
        var head = "[" + caps + "](";
        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if i > 0 { head += ", "; }
            head += self._spell.param_decl(p, self._spell.imm_name(p->name.imm, self._owning_fid()));
        }
        head += ")";
        if caps.size() > 0 { head += " mutable"; }
        // A closure is a Kairo frame like any function: noexcept unless
        // -funwind. A closure cannot carry `@unwind` yet (an attribute
        // before `fn` in expression position is an expression attribute).
        if !self._cg->opts.unwind { head += " noexcept"; }
        var ret = "void";
        if (!n->is_noreturn) && (n->return_type != &null) { ret = self._spell._type(n->return_type); }
        if n->panic_result != &null { ret = self._spell._type(n->panic_result); }
        head += " -> " + ret;

        var wrap = "::" + LowerTargets::fn_value() + "<" + self._spell.fn_signature(fp) + ">";
        if caps.size() == 0 {
            self._cg->sink->spell(n->range, wrap + "(+" + head);
        } else {
            self._cg->sink->spell(n->range, wrap + "::" + LowerTargets::fn_value_own() + "(new auto(" + head);
        }

        var saved = self._closure;
        var sd = self._ef_depth;
        var sl = self._ef_loops;
        self._closure = n;
        self._ef_depth = 0;      // a closure's statements are its own, not a copy's.
        self._ef_loops = 0;
        self.emit_block(n->body_block);
        self._closure = saved;
        self._ef_depth = sd;
        self._ef_loops = sl;

        if caps.size() == 0 { self._cg->sink->spell(n->range, ")"); }
        else                { self._cg->sink->spell(n->range, "))"); }
    }

    /// The lambda's capture list, from ClosureCaptures' modes:
    ///   Copy      `x`                                (the closure's own copy)
    ///   Move      `x = static_cast<T&&>(x)`          (a MOVE value, moved in)
    ///   Ptr       `x = &x`                           (`x` IS the `*T` the body reads)
    ///   ConstPtr  `x = static_cast<const T*>(&x)`    (`x` when it is a pointer already)
    ///   Self      `this`, or `self` in an extension member (a pointer already)
    /// Init-captures keep the Kairo name, so the body is emitted unchanged:
    /// a `|*x|` closure's `*x = 1` is C++'s `*x = 1` on the captured pointer.
    priv fn _capture_list(self, n: *ClosureExpr) -> string {
        var s = "";
        for var i: usize = 0; i < n->cap_decls.size(); ++i {
            var d   = n->cap_decls[i];
            var m   = n->cap_modes[i];
            var via = n->cap_via_ptr[i];
            if s.size() > 0 { s += ", "; }
            if m == CaptureMode::Self {
                s += (LowerTargets::ext_receiver_name()) if (self._cur_ext != &null) else ("this");
                continue;
            }
            var nm = self._spell.imm_name(decl_name_tok(d).imm, self._owning_fid());
            switch m {
                case CaptureMode::Copy { s += nm; }
                case CaptureMode::Move {
                    s += nm + " = static_cast<" + self._spell._type(self._capture_type(d)) + "&&>(" + nm + ")";
                }
                case CaptureMode::Ptr { s += nm + " = &" + nm; }
                case CaptureMode::ConstPtr {
                    var src = (nm) if (via) else ("&" + nm);
                    s += nm + " = static_cast<const " + self._spell._type(self._capture_type(d)) + "*>(" + src + ")";
                }
                default { self._ice(n->range, "EmitIR: a capture mode with no spelling"); }
            }
        }
        return s;
    }

    /// The captured binding's own type, top-level cv dropped (a capture's
    /// spelling adds what it needs).
    priv fn _capture_type(self, d: *Decl) -> *Type {
        var t: *Type = &null;
        var p = dyn_cast::<ParamDecl>(d);
        if p != &null { t = (p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_); }
        else          { t = cast::<VariableDecl>(d)->type_; }
        if ((t == &null) || (t->canonical == &null)) { self._ice(d->range, "EmitIR: a captured binding with no type; X gate failure"); }
        return canon_unqual(t->canonical);
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

    /// \p d is declared in an interface: a requirement, never a C++ function.
    priv fn _is_requirement(self, d: *Decl) -> bool {
        if (d == &null) || (!isa::<FunctionDecl>(d)) || (d->semantic_dc == &null) { return false; }
        var home = reinterpret_cast::<*DeclContext>(d->semantic_dc)->owner_decl();
        return (home != &null) && isa::<InterfaceDecl>(home);
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
        // A name that came through a macro (a `crash!(why)` argument) is a
        // TkMacroExpand token: its imm is the expansion record, and read as
        // an identifier against the owning file's table it is some other
        // name (`why` printed as `io`). Unwrap the chain to the spelling.
        if static_cast::<u32>(t.kind) == static_cast::<u32>(TokenKind::TkMacroExpand) {
            var txt = TokenText::resolve(t, self._cg->ctx->tcm).text;
            self._cg->sink->create_ident(t.range, txt);
            return;
        }
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
    /// which for a foreign template or inline body is not this TU's; or the
    /// namespace-scope variable's whose initializer is emitted (a foreign
    /// eval binding's, EVAL.md 1.2b).
    priv fn _owning_fid(self) -> u32 {
        if self._cur_fn != &null { return CXXSpell::fid_of(static_cast::<*Decl>(self._cur_fn)); }
        if self._cur_global != &null { return CXXSpell::fid_of(static_cast::<*Decl>(self._cur_global)); }
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
    /// A SUFFIXED literal is spelled exactly typed, `static_cast<T>(v)`: the
    /// suffix is a declaration (`1u8` is a u8 wherever it stands), and C++
    /// re-reads a bare `1` as an int -- an overload set, a deduced template
    /// argument or `auto` then picks a different entity than Sema did.
    ///
    /// The others borrow their bytes unless C++ cannot read them: a `_`
    /// separator (a user-defined-literal suffix to clang), the `0o` prefix
    /// (C++ octal is a bare leading 0), or a top-bit value (too large for a
    /// signed literal; ULL). Those are respelled from the value, untyped, so
    /// the contextual type still converts them where it did.
    ///
    /// A value of 2^64 or more is never borrowed either: C++ has no integer
    /// literal wider than unsigned long long, so clang rejects the bytes
    /// whatever the target type. _int_text builds it from its halves.
    priv fn _int_lit(self, n: *IntegerLiteralExpr) {
        var t = n->token;
        if n->is_big() { self._ice(t.range, "EmitIR: integer literal wider than 128 bits; limb composition is not emitted yet"); }

        var hi = n->get_value_hi();
        if hi != 0 {
            if (n->type_ == &null) { self._ice(t.range, "EmitIR: untyped wide integer literal reached codegen; ExprTyper gate failure"); }
            self._cg->sink->spell(t.range, self._int_text(n->type_, hi, n->get_value_lo(), false));
            return;
        }

        var tbl = self._cg->ctx->tcm->get_imm_table_for_fid(self._owning_fid());
        if (tbl == &null) { self._ice(t.range, "EmitIR: no immediate table for the file that owns this body"); }
        var d = tbl->get::<Immediate::IntData>(t.imm);
        if d == &null { self._cg->sink->synth(t, clang::tok::numeric_constant); return; }
        // IntData flag bit 3: a Kairo suffix (`0xFFu8`).
        var suffixed = (d->flags & 8) != 0;
        if suffixed && (n->type_ != &null) {
            self._cg->sink->spell(t.range, self._int_text(n->type_, 0, d->value_lo, false));
            return;
        }
        if (!d->body.is_valid()) || suffixed || ((d->value_lo >> 63) != 0) || (!self._int_bytes_are_cxx(d)) {
            var cxx = self._int_text(&null, 0, d->value_lo, false);
            self._cg->sink->create_int(t.range, cxx);
            return;
        }
        self._cg->sink->synth(t, clang::tok::numeric_constant);
    }

    /// Whether a literal's own bytes are a C++ integer literal: no `_`
    /// separator and no `0o` prefix. Hex and binary prefixes are C++'s too.
    priv fn _int_bytes_are_cxx(self, d: *Immediate::IntData) -> bool {
        var sm = self._cg->ctx->sm;
        var body = sm->get_text(d->body);
        for var i: usize = 0; i < body.size(); ++i {
            if body[i] == '_' { return false; }
        }
        if ((d->flags & 16) != 0) && d->prefix.is_valid() {
            var pre = sm->get_text(d->prefix);
            if (pre.size() == 2) && ((pre[1] == 'o') || (pre[1] == 'O')) { return false; }
        }
        return true;
    }

    /// The C++ for the integer `hi:lo` (negated when \p neg), cast to \p ty
    /// when one is given. Every piece is a literal C++ reads at its full
    /// width: a magnitude of 2^64 or more is composed in `unsigned
    /// __int128` (multiplication, not `<<`: spell() fuses `<<` only after
    /// `operator`), and a negative one is negated where that cannot
    /// overflow -- `-2^63` as `(-9223372036854775807LL - 1)`, anything wider
    /// in the unsigned 128-bit type, whose wrap the cast turns back into the
    /// signed value. Negating the magnitude in the target type instead is
    /// the signed overflow clang reported for the i128 minimum.
    priv fn _int_text(self, ty: *Type, hi: u64, lo: u64, neg: bool) -> string {
        var one: u64 = 1;
        var top = one << 63;
        var v = "";
        if hi != 0 {
            v = f"static_cast<unsigned __int128>({hi}ULL) * 4294967296ULL * 4294967296ULL + {lo}ULL";
            if neg { v = "static_cast<unsigned __int128>(0) - (" + v + ")"; }
        } else if neg {
            if lo < top { v = f"-{lo}"; }
            else if lo == top { v = "(-9223372036854775807LL - 1)"; }
            else { v = f"static_cast<unsigned __int128>(0) - {lo}ULL"; }
        } else {
            v = f"{lo}";
            if (lo >> 63) != 0 { v += "ULL"; }
        }
        if ty == &null { return v; }
        return f"(static_cast<{self._spell._type(ty)}>({v}))";
    }

    /// `-L` for an integer literal L that is suffixed or 2^63 or more: the
    /// negated value itself, exactly typed, instead of a negation C++ does
    /// in its own type. `-128i8` negated after the cast is the int 128, and
    /// initializing an i8 with it is a constant-conversion warning; the i64
    /// and i128 minimums overflow outright. Null when \p n is not that.
    priv fn _negated_int_lit(self, n: *UnaryOperatorExpr) -> *IntegerLiteralExpr {
        if (!n->is_prefix()) || (n->op_token.kind != TokenKind::OpMinus) { return &null; }
        var opnd = n->operand;
        while (opnd != &null) && isa::<ParenExpr>(opnd) { opnd = cast::<ParenExpr>(opnd)->inner; }
        if (opnd == &null) || (!isa::<IntegerLiteralExpr>(opnd)) { return &null; }
        var lit = cast::<IntegerLiteralExpr>(opnd);
        if (lit->imm == &null) || lit->is_big() || (lit->type_ == &null) { return &null; }
        var c = canon_unqual(lit->type_);
        if (c == &null) || (!isa::<BuiltinType>(c)) { return &null; }
        var info = cast::<BuiltinType>(c)->info();
        if (!info->is_integer()) || (!info->is_signed()) { return &null; }
        if lit->has_suffix() || (lit->get_value_hi() != 0) || ((lit->get_value_lo() >> 63) != 0) { return lit; }
        return &null;
    }

    /// A float literal, spelled so clang parses it AT its Kairo type: the
    /// source digits (separators dropped) with the C++ suffix of that type.
    /// The decimal text is re-read, never printed from value_ieee, so the
    /// rounding is clang's correctly-rounded one per format. The borrowed
    /// bytes of `1.5f32` were "invalid suffix 'f32'", and an unsuffixed
    /// `var q: f128 = 0.1` was the double 0.1 widened, 0.10000000000000000555.
    ///
    ///   f16 `f16`, f32 `f`, f64 none, f80 `L`, f128 `Q`
    ///   bf16 has no literal suffix: `static_cast<__bf16>(<digits>f)`.
    ///   f8* / f256 / f512 are library classes: the double literal, as before.
    ///
    /// An unsuffixed f64 literal with no separator keeps its own bytes.
    priv fn _float_lit(self, n: *FloatingLiteralExpr) {
        var t = n->token;
        var tbl = self._cg->ctx->tcm->get_imm_table_for_fid(self._owning_fid());
        var d: *Immediate::FloatData = &null;
        if tbl != &null { d = tbl->get::<Immediate::FloatData>(t.imm); }
        if (d == &null) || (!d->body.is_valid()) { self._cg->sink->synth(t, clang::tok::numeric_constant); return; }

        var k = BuiltinKind::COUNT;
        var c = canon_unqual(n->type_);
        if (c != &null) && isa::<BuiltinType>(c) { k = cast::<BuiltinType>(c)->builtin; }

        var sm = self._cg->ctx->sm;
        var body = sm->get_text(d->body);
        var hex = (d->flags & 4) != 0;
        var digits = "";
        var sep = false;
        var point = false;
        for var i: usize = 0; i < body.size(); ++i {
            var ch = body[i];
            if ch == '_' { sep = true; continue; }
            if ch == '.' { point = true; }
            if (!hex) && ((ch == 'e') || (ch == 'E')) { point = true; }
            if hex && ((ch == 'p') || (ch == 'P')) { point = true; }
            digits += ch;
        }
        var suffixed = (d->flags & 16) != 0;
        if (!suffixed) && (!sep) && ((k == BuiltinKind::F64) || (k == BuiltinKind::COUNT)) {
            self._cg->sink->synth(t, clang::tok::numeric_constant);
            return;
        }

        // `5f32` is a float in Kairo; `5f` is not a C++ floating literal,
        // and a hex one needs its binary exponent.
        if hex {
            var pre = "0x";
            if d->prefix.is_valid() { pre = sm->get_text(d->prefix); }
            digits = pre + digits;
            if !point { digits += "p0"; }
        } else if !point {
            digits += ".0";
        }

        switch k {
            case BuiltinKind::F16  { digits += "f16"; }
            case BuiltinKind::F32  { digits += "f"; }
            case BuiltinKind::F80  { digits += "L"; }
            case BuiltinKind::F128 { digits += "Q"; }
            case BuiltinKind::BF16 {
                digits += "f";
                self._cg->sink->spell(t.range, f"static_cast<{self._spell._type(n->type_)}>(");
                self._cg->sink->create_int(t.range, digits);
                self._cg->sink->spell(t.range, ")");
                return;
            }
            default { }
        }
        self._cg->sink->create_int(t.range, digits);
    }

    // --- Base initializers ------------------------------------------------------------

    /// The constructor a statement calls by qualified name to initialize a
    /// base -- `Animal::Animal(self, 4);` -- or null. BaseInitCheck admits
    /// such a call only as one of a constructor's leading statements, so
    /// the shape alone identifies it here.
    priv fn _base_init_ctor(self, s: *Stmt) -> *FunctionDecl {
        var es = dyn_cast::<ExpressionStmt>(s);
        if (es == &null) || (es->expr == &null) { return &null; }
        var n = dyn_cast::<CallExpr>(es->expr);
        if (n == &null) || (n->ctor_decl != &null) { return &null; }
        var ch = dyn_cast::<ChainExpr>(n->callee);
        if (ch == &null) || (ch->steps.size() == 0) { return &null; }
        var last = ch->steps.get(ch->steps.size() - 1);
        if last->access_kind != ChainExpr::AccessKind::ColonColon { return &null; }
        var f = dyn_cast::<FunctionDecl>(last->resolved_decl);
        if !self._is_ctor(f) { return &null; }
        return f;
    }

    /// How many of \p stmts, from the first, are base initializers.
    priv fn _lead_base_inits(self, stmts: *FrozenList::<*Stmt>) -> usize {
        var k: usize = 0;
        while (k < stmts->size()) && (self._base_init_ctor((*stmts)[k]) != &null) { k += 1; }
        return k;
    }

    /// ` : Animal(4), ...` after constructor \p m's head, from the base
    /// initializers leading \p stmts; true when there was one. C++ builds a
    /// base before the body runs and has no way to construct one from a
    /// statement, so the call becomes its mem-initializer, which is also
    /// what makes a virtual base's initializer in an intermediate class
    /// ignored (classes-inheritance.md, Diamond and virtual inheritance).
    priv fn _mem_inits(self, m: *FunctionDecl, owner: *Decl, stmts: *FrozenList::<*Stmt>, colon: bool) -> bool {
        var k = self._lead_base_inits(stmts);
        if k == 0 { return false; }
        var saved_fn  = self._cur_fn;
        var saved_ext = self._cur_ext;
        self._cur_fn  = m;
        self._cur_ext = &null;
        for var i: usize = 0; i < k; ++i {
            var f = self._base_init_ctor((*stmts)[i]);
            var n = cast::<CallExpr>(cast::<ExpressionStmt>((*stmts)[i])->expr);
            var lead = (", ") if (i > 0) else ((" : ") if (colon) else (": "));
            self._cg->sink->spell(n->range, lead + self._base_init_type(owner, f, n->range) + "(");
            self._args(n, f, false, reinterpret_cast::<*InstanceEntry>(n->instance), true);
            self._cg->sink->spell(n->range, ")");
        }
        self._cur_fn  = saved_fn;
        self._cur_ext = saved_ext;
        return true;
    }

    /// The instance of generic method \p f's class that object \p obj is,
    /// or has as a base -- what `Box<i32>::get(obj)` names, which the bare
    /// callee spells as the template. Null when neither (clang then
    /// reports the template, as before).
    priv fn _qualifying_instance(self, obj: *Expr, f: *FunctionDecl) -> *Type {
        if (obj == &null) || (obj->type_ == &null) { return &null; }
        var want = CXXSpell::rep(decl_pattern(CXXSpell::rep(reinterpret_cast::<*DeclContext>(f->semantic_dc)->dc_owner)));
        var r = dyn_cast::<RecordType>(canon_unqual(obj->type_));
        if (r == &null) || (r->decl == &null) { return &null; }
        if CXXSpell::rep(decl_pattern(CXXSpell::rep(r->decl))) == want { return static_cast::<*Type>(r); }
        var seen = vec::<*Decl>();
        return self._base_edge_to(CXXSpell::rep(decl_pattern(CXXSpell::rep(r->decl))), want, &seen, 0);
    }

    /// The base \p f constructs, spelled as \p owner's base list names it
    /// (`GB<int>`, not the template); a virtual base further up is found
    /// through the bases in between.
    priv fn _base_init_type(self, owner: *Decl, f: *FunctionDecl, at: SourceRange) -> string {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        var want = CXXSpell::rep(decl_pattern(CXXSpell::rep(dc->dc_owner)));
        var seen = vec::<*Decl>();
        var t = self._base_edge_to(CXXSpell::rep(owner), want, &seen, 0);
        if (t == &null) { self._ice(at, "EmitIR: a base initializer whose class is no base of the constructor's; BaseInitCheck admits only bases"); }
        return self._spell._type(t);
    }

    priv fn _base_edge_to(self, d: *Decl, want: *Decl, seen: *vec::<*Decl>, depth: u32) -> *Type {
        if (d == &null) || (depth > 64) || (!isa::<ClassDecl>(d)) { return &null; }
        for var i: usize = 0; i < seen->size(); ++i { if (*seen)[i] == d { return &null; } }
        seen->push_back(d);
        var cd = cast::<ClassDecl>(d);
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var e = cd->derives_list.get(i);
            if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
            var r = dyn_cast::<RecordType>(canon_unqual(e->base->canonical));
            if (r == &null) || (r->decl == &null) { continue; }
            if CXXSpell::rep(decl_pattern(CXXSpell::rep(r->decl))) == want { return e->base; }
        }
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var e = cd->derives_list.get(i);
            if (e == &null) || (e->base == &null) || (e->base->canonical == &null) { continue; }
            var r = dyn_cast::<RecordType>(canon_unqual(e->base->canonical));
            if (r == &null) || (r->decl == &null) { continue; }
            var t = self._base_edge_to(CXXSpell::rep(decl_pattern(CXXSpell::rep(r->decl))), want, seen, depth + 1);
            if t != &null { return t; }
        }
        return &null;
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
        var neg_lit = self._negated_int_lit(n);
        if neg_lit != &null {
            self._cg->sink->spell(n->range, self._int_text(neg_lit->type_, neg_lit->get_value_hi(), neg_lit->get_value_lo(), true));
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
        if (n->op_token.kind == TokenKind::OpEqualEqualEqual) { self._ice(n->range, "EmitIR: `===`; CoalesceLowering owns it"); }
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
        if self._ci_pre && (n->op_token.kind == TokenKind::OpEqual) && n->ci_elem_init {
            // `self.f[k] = e` that builds element k of an array field built
            // element by element (CtorInitCheck): the element does not exist
            // yet, so it is constructed in the slot, not assigned. In place,
            // so e runs exactly where it is written.
            var sub = dyn_cast::<SubscriptExpr>(n->lhs);
            var esi = usize(-1);
            if sub != &null {
                var ef = self._self_field(sub->base);
                if ef != &null { esi = self._slot_of(static_cast::<*Decl>(ef), true); }
            }
            if esi == usize(-1) { self._ice(n->range, "EmitIR: an element write that builds a field with no slot; CtorInitCheck gate failure"); return; }
            self._cg->sink->spell(n->range, LowerTargets::ctor_slot_arg() + "." + self._slot_name(esi) + "." + LowerTargets::ctor_slot_init_at() + "(");
            self.emit(sub->index);
            self._cg->sink->spell(n->range, ", ");
            self._value(n->rhs, n->lhs->type_);
            self._cg->sink->spell(n->range, ")");
            return;
        }
        if self._ci_pre && (n->op_token.kind == TokenKind::OpEqual) {
            var f = self._self_field(n->lhs);
            if f != &null {
                var si = self._slot_of(static_cast::<*Decl>(f), true);
                if si == usize(-1) { self._ice(n->range, "EmitIR: S_pre assigns a field with no slot; CtorInitCheck gate failure"); }
                // An array is written once (CtorInitCheck), and its slot has
                // no `put`: an array has no `=`.
                var once   = f->is_const() || (self._array_extent(f->type_) != usize(-1));
                var put_fn = "." + ((LowerTargets::ctor_slot_init()) if (once) else (LowerTargets::ctor_slot_put())) + "(";
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
        // Through a C++ reference (`v[0] = x` of an imported container,
        // whose `operator[]` returns `T&`) the value written is a T: a
        // converted right side is cast to the referee, never to the
        // reference, which a temporary cannot bind.
        var want = n->lhs->type_;
        if (want != &null) && (want->canonical != &null) && isa::<CXXLValueRefType>(want->canonical) {
            want = cast::<CXXLValueRefType>(want->canonical)->referee;
        }
        self._cg->sink->spell(n->range, "(");
        self.emit(n->lhs);
        self._cg->sink->create(n->op_token);
        self._value(n->rhs, want);
        self._cg->sink->spell(n->range, ")");
    }

    /// The written target is the result type (invariant 15). Which C++ cast:
    /// `as const` -> const_cast, `as unsafe` -> reinterpret_cast (a C-style
    /// cast when it drops a pointee qualifier), otherwise static_cast. The
    /// checked downcast is _checked_downcast's; the asserting one arrives
    /// expanded by OperatorLowering (PANIC.md §5) around a `dynamic_only`
    /// cast, spelled `dynamic_cast` as is; a user `op as` or a converting
    /// ctor is OperatorLowering's.
    priv fn _cast(self, n: *TypeCastExpr) {
        if n->checked_downcast { self._checked_downcast(n); return; }
        if n->asserting_downcast { self._ice(n->range, "EmitIR: an asserting downcast reached codegen unexpanded; OperatorLowering owns its check"); return; }
        if n->dynamic_only { self._cast_to(n->target, n->operand, "dynamic_cast"); return; }
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
        // `p as usize` reads the address (casting.mdx). static_cast from a
        // pointer to an integer is ill-formed C++; reinterpret_cast is the
        // one cast that takes it, whatever the pointee's cv (CastTyping lets
        // only usize through, so the target always holds the whole address).
        if self._type_is_pointer(n->operand->type_) && self._type_is_builtin_int(n->target) { kind = "reinterpret_cast"; }
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

    /// `p as (*D)?` (casting.md, the checked downcast): `dynamic_cast<D*>`,
    /// and its null pointer is the NULL nullable, not a present one holding
    /// nullptr (Stage 1 storage is tagged, NULLABLE.md 1.2). A lambda called
    /// on the spot binds the result once and is an expression everywhere a
    /// cast is, a namespace-scope initializer included:
    ///
    ///   [](D* __kairo_dc) noexcept -> N { return __kairo_dc ? N(__kairo_dc) : N(); }(dynamic_cast<D*>(p))
    ///
    /// `N()` is Nullable's null (AdtRole::NullDefault). With the pointer
    /// niche (G2b) this becomes the dynamic_cast alone.
    priv fn _checked_downcast(self, n: *TypeCastExpr) {
        var tc = n->target->canonical;
        var nt = (cast::<NullableType>(canon_unqual(tc))) if ((tc != &null) && (canon_unqual(tc) != &null) && isa::<NullableType>(canon_unqual(tc))) else (&null);
        if (nt == &null) { self._ice(n->range, "EmitIR: a checked downcast whose target is no nullable; CastTyping gate failure"); return; }
        var big = self._spell._type(n->target, &null);
        var ptr = self._spell._type(nt->inner, &null);
        var v   = LowerTargets::checked_downcast_value();
        var nx  = ("") if (self._cg->opts.unwind) else (" noexcept");
        self._cg->sink->spell(n->range, "[](" + ptr + " " + v + ")" + nx + " -> " + big + " { return " + v + " ? " + big + "(" + v + ") : " + big + "(); }(dynamic_cast<" + ptr + ">(");
        self.emit(n->operand);
        self._cg->sink->spell(n->range, "))");
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
            var ext = (self._spell._type(at->extent_param)) if (at->extent_param != &null) else (f"{at->size_bits}");
            self._cg->sink->spell(n->range, "::" + LowerTargets::array_alias() + "<" + self._spell._type(elem) + ", " + ext + ">{");
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
        // `T::Node { }`: ControlTyping admits it with no fields only, through
        // a constructor bound; C++ value-initializes the witness's member type.
        if c->kind == TypeKind::AssocType {
            self._cg->sink->spell(e->range, self._spell._type(e->type_) + "{}");
            return;
        }
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

    /// PanicLowering's C++ with no Kairo spelling (PanicOpExpr):
    ///   Fwd / FwdAll  `::__kairo_fwd<R, A>(operand)`, R the node's type;
    ///   SlotPut       `new (&slot.__kairo_b) ::__kairo_rbox<T>{operand}`,
    ///                 the slot built from the prvalue in place;
    ///   SlotTake      `slot.__kairo_take()`: the value moved out, the
    ///                 slot destroyed.
    /// The slot is a raw_slot local, read by its name.
    priv fn _panic_op(self, n: *PanicOpExpr) {
        if (n->which == PanicOp::Fwd) || (n->which == PanicOp::FwdAll) {
            if ((n->type_ == &null) || (n->operand == &null)) { self._ice(n->range, "EmitIR: a panic fwd with no result type or operand; PanicLowering mints both"); }
            var all = ("true") if (n->which == PanicOp::FwdAll) else ("false");
            self._cg->sink->spell(n->range, "::" + LowerTargets::panic_fwd() + "<" + self._spell._type(n->type_) + ", " + all + ">(");
            self.emit(n->operand);
            self._cg->sink->spell(n->range, ")");
            return;
        }
        switch n->which {
            case PanicOp::SlotPut {
                if ((n->slot == &null) || (n->operand == &null) || (n->slot->type_ == &null)) { self._ice(n->range, "EmitIR: a slot put with no slot or value; PanicLowering mints both"); }
                self._cg->sink->spell(n->range, "new (&");
                self.emit(n->slot);
                self._cg->sink->spell(n->range, "." + LowerTargets::raw_box_member() + ") ::" + LowerTargets::raw_box() + "<" + self._spell._type(n->slot->type_) + ">{");
                self._value(n->operand, n->slot->type_);
                self._cg->sink->spell(n->range, "}");
            }
            case PanicOp::SlotTake {
                if (n->slot == &null) { self._ice(n->range, "EmitIR: a slot take with no slot; PanicLowering mints it"); }
                self.emit(n->slot);
                self._cg->sink->spell(n->range, "." + LowerTargets::raw_take() + "()");
            }
            // A dependent set's test and read (PANIC.md P10): the C++ view's
            // `is<E>` / `error<E>`, which find E's id and its place in the
            // set C++ ordered at the instance.
            case PanicOp::Holds {
                if ((n->operand == &null) || (n->elem == &null)) { self._ice(n->range, "EmitIR: a panic holds-test with no value or type; EnumLayoutQuery mints both"); }
                self._cg->sink->spell(n->range, "::" + LowerTargets::panic_api_ns() + "::" + LowerTargets::panic_api_is() + "<" + self._spell._type(n->elem) + ">(");
                self.emit(n->operand);
                self._cg->sink->spell(n->range, ")");
            }
            case PanicOp::ErrorRef {
                if ((n->operand == &null) || (n->elem == &null)) { self._ice(n->range, "EmitIR: a panic error read with no value or type; EnumLayoutQuery mints both"); }
                self._cg->sink->spell(n->range, "::" + LowerTargets::panic_api_ns() + "::" + LowerTargets::panic_api_error() + "<" + self._spell._type(n->elem) + ">(");
                self.emit(n->operand);
                self._cg->sink->spell(n->range, ")");
            }
            default { 0; }
        }
    }

    /// An ADT variant built in place: the enum's tagged constructor,
    /// `T(::__kairo_vt<I>{})` for a variant without a payload, the field
    /// constructor `T{::__kairo_vt<I>{}, f0, f1}` where the variant's
    /// AdtCtorForm gives one, and otherwise
    ///
    ///   T(::__kairo_vt<I>{}, [&]() noexcept -> P { return { f0, f1 }; })
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
        // The field constructor, braced: a braced list runs its clauses left
        // to right even when it calls a constructor, so the payload's order
        // is the lambda form's (SequenceLowering's contract).
        if (v->adt_ctor == AdtCtorForm::Fields) || ((v->adt_ctor == AdtCtorForm::Both) && n->field_ctor) {
            self._cg->sink->spell(n->range, t + "{" + tag);
            for var i: usize = 0; i < n->fields.size(); ++i {
                self._cg->sink->spell(n->range, ",");
                self._value(n->fields[i], v->payload[i]->type_);
            }
            self._cg->sink->spell(n->range, "}");
            return;
        }
        var leaf = LowerTargets::adt_payload_type(self._spell.leaf(static_cast::<*Decl>(v)));
        var pt   = self._spell.dependent_member_type(n->type_, leaf);
        // A pack-expanded variant's element K: the constructor takes the
        // variant's tag, then K's, and the payload is the member template at
        // the element (InterfaceEmitter writes both). Always at a concrete
        // instance (ControlTyping refuses a dependent one).
        if n->pack_index >= 0 {
            if (n->pack_elem == &null) { self._ice(n->range, "EmitIR: a pack-expanded variant built with no element type; VariantInitLowering records it"); }
            var el = self._spell._type(n->pack_elem);
            if n->type_->is_dependent() || n->type_->is_instantiation_dependent() {
                // An error built at a dependent panic result (a generic body,
                // PANIC.md P10): its place in the set is the one C++ ordered
                // at the instance, `__kairo_pidx<E>`, never Sema's.
                tag += ", ::" + LowerTargets::adt_variant_tag() + "<::" + LowerTargets::panic_elem_index() + "<" + el + ">(static_cast<" + t + "*>(nullptr))>{}";
                pt = "typename " + t + "::template " + leaf + "<" + el + ">";
            } else {
                tag += ", ::" + LowerTargets::adt_variant_tag() + "<" + f"{n->pack_index}" + ">{}";
                pt = t + "::" + leaf + "<" + el + ">";
            }
            // A site slot's pack constructor takes the site id (PANIC.md
            // §1.4; InterfaceEmitter writes it): 0 for none.
            if en->adt_site_field != &null { tag += ", " + f"{n->site}" + "u"; }
        }
        // noexcept unless -funwind, as the constructor it is passed to is
        // (InterfaceEmitter::_adt_noexcept): the lambda is a Kairo frame.
        var nx = ("") if (self._cg->opts.unwind) else (" noexcept");
        self._cg->sink->spell(n->range, t + "(" + tag + ", [&]()" + nx + " -> " + pt + " { return {");
        for var i: usize = 0; i < n->fields.size(); ++i {
            if i > 0 { self._cg->sink->spell(n->range, ","); }
            var fd = v->payload[i];
            var f  = n->fields[i];
            // An array member takes bare braces, as in _init.
            var fc: *Type = &null;
            if (fd->type_ != &null) && (fd->type_->canonical != &null) { fc = canon_unqual(fd->type_->canonical); }
            var il = dyn_cast::<InitListExpr>(f);
            var pg = dyn_cast::<GenericParamType>(fc);
            if (il != &null) && (fc != &null) && (fc->kind == TypeKind::FixedArrayType) {
                self._init_list(il, true);
            } else if (n->pack_index >= 0) && (pg != &null) && pg->is_pack {
                self._value(f, n->pack_elem);   // the pack field holds the element.
            } else {
                self._value(f, fd->type_);
            }
        }
        self._cg->sink->spell(n->range, "}; })");
    }

    /// The declaration whose members an instance's C++ has: the partial
    /// specialization the registry selected for it (InstanceEntry::pattern,
    /// the same body Sema typed the instance against), else the primary.
    /// Reading the primary for a partial's instance dropped every field of
    /// an initializer the partial declares (`Store<*i64> { wide: p }`
    /// emitted `{}`).
    priv fn _layout_of(self, d: *Decl) -> *Decl {
        if decl_is_instance(d) {
            var e = self._cg->instances->entry_of(d);
            if (e != &null) && (e->pattern != &null) { return CXXSpell::rep(e->pattern); }
            return CXXSpell::rep(decl_pattern(d));
        }
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
