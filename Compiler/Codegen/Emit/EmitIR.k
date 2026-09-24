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
///     of it (IMPORTS.md §7). Extension members: free functions with the
///     receiver first.
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
import Token::TokenKind::*;
import Lexer::Immediate::*;

__inline_cpp("
#define sink this->_cg->sink
");

class EmitIR {
    priv var _cg:    obs::<CodegenContext>;
    priv var _spell: CXXSpell;
    /// The function whose body is being emitted. Decides what `self` means.
    priv var _cur_fn:  *FunctionDecl  = &null;
    priv var _cur_ext: *ExtensionDecl = &null;   ///< non-null inside an extension member.

    fn EmitIR(self, cg: *CodegenContext) {
        self._cg    = cg;
        self._spell = CXXSpell(cg);
    }

    // ----------------------------------------------------------------- //
    // Entry
    // ----------------------------------------------------------------- //

    /// Every body this TU defines: its own decls in source order, then the
    /// member bodies of foreign templates whose instances are homed here.
    fn emit_tu(self, plan: *EmitPlan) {
        var tu = self._cg->tu;
        ICE_IF(tu == &null, "EmitIR: no TU");
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.emit(item.as_decl()); }
                default { ICE_FAIL("EmitIR: top-level statements are not emittable C++"); }
            }
        }

        // Member bodies of FOREIGN templates this TU homes an instance of.
        // The template's own TU emitted its bodies in the walk above; a
        // template homed twice here (two instances) gets its bodies once.
        var emitted = vec::<*Decl>();
        for var i: usize = 0; i < plan->entries.size(); ++i {
            var e = &(plan->entries[i]);
            if e->tier != PlanTier::Instantiations { continue; }
            if !e->is_home { continue; }
            if CXXSpell::fid_of(e->decl) == tu->fid { continue; }
            var done = false;
            for var k: usize = 0; k < emitted.size(); ++k { if emitted[k] == e->decl { done = true; break; } }
            if done { continue; }
            emitted.push_back(e->decl);
            self._template_bodies(e->decl);
        }
    }

    // ----------------------------------------------------------------- //
    // Declarations
    // ----------------------------------------------------------------- //

    fn emit(self, d: *Decl) {
        ICE_IF(d == &null, "EmitIR: null decl reached codegen");
        ICE_IF(d->kind == DeclKind::RecoveryDecl, "EmitIR: poisoned decl reached codegen; sema gate failure");
        if d->is_poisoned() { return; }

        switch d->kind {
            case DeclKind::FunctionDecl { self._free_fn(cast::<FunctionDecl>(d), &null); }
            case DeclKind::ClassDecl    { self._record_bodies(d); }
            case DeclKind::StructDecl   { self._record_bodies(d); }
            case DeclKind::UnionDecl    { self._record_bodies(d); }
            case DeclKind::EnumDecl      { return; }
            case DeclKind::TypeAliasDecl { return; }
            case DeclKind::InterfaceDecl { return; }
            case DeclKind::ModuleDecl {
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
                ICE_FAIL("EmitIR: namespace-scope variables are not emitted yet (storage/linkage rules pending)");
            }
            default { ICE_FAIL(f"EmitIR: decl kind {to_string(d->kind)} has no body to emit"); }
        }
    }

    /// The methods of a record, out of line, then its nested records'.
    priv fn _record_bodies(self, d: *Decl) {
        var methods = self._methods_of(d);
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if m != &null { self._method(m, d); }
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

    /// Bodies of a FOREIGN template this TU homes an instance of. The tokens
    /// live in the template's file; the sink maps every registered fid.
    priv fn _template_bodies(self, prim: *Decl) {
        if isa::<FunctionDecl>(prim) { self._free_fn(cast::<FunctionDecl>(prim), &null); return; }
        self._record_bodies(prim);
    }

    // --- Namespace wrapper ------------------------------------------------------

    /// Open the wrapper InterfaceEmitter declared \p d in.
    /// The named namespace, plus an unnamed one nested in it for a decl with
    /// no linkage outside its file. Returns how many braces to close.
    priv fn _open_ns(self, d: *Decl, at: SourceRange) -> u32 {
        var n: u32 = 0;
        var ns = self._spell.ns_segments(d);
        if ns.size() > 0 {
            sink->spell(at, "namespace " + self._spell.ns_join(ns) + " {");
            n += 1;
        }
        if CXXSpell::is_anon(d) { sink->spell(at, "namespace {"); n += 1; }
        return n;
    }

    priv fn _close_ns(self, at: SourceRange, n: u32) {
        for var i: u32 = 0; i < n; ++i { sink->spell(at, "}"); }
        if n > 0 { sink->brk(); }
    }

    // --- Functions ------------------------------------------------------------------

    /// A free function, or an extension member (\p ext non-null) as a free
    /// function with the receiver first.
    priv fn _free_fn(self, n: *FunctionDecl, ext: *ExtensionDecl) {
        if !n->has_body() { return; }
        if n->body_kind != FnBodyKind::Block { self._unsupported_body(n); return; }
        ICE_IF(n->is_operator && (ext == &null), "EmitIR: free operator function; OperatorLowering must rename it");
        ICE_IF(n->is_variadic, "EmitIR: variadic pack parameters are not emitted yet");
        if n->is_method() && (ext == &null) { return; }   // a method reached the free path; its owner emits it.

        var is_main = (ext == &null) && CXXSpell::is_entry_tu(self._cg->tu) && (self._spell.leaf(n) == "main");
        var wrap: u32 = 0;
        if !is_main { wrap = self._open_ns(n, n->name.range); }

        var head = "";
        if ext != &null { head += self._spell.template_head(static_cast::<*Decl>(ext)); }
        head += self._spell.template_head(static_cast::<*Decl>(n));
        head += (("int") if (is_main) else (self._ret(n)));
        head += " ";
        head += self._spell.leaf(n);
        head += "(";
        head += self._params_text(n, ext);
        head += ")";
        sink->spell(n->name.range, head);

        self._body(n, ext);
        self._close_ns(n->range, wrap);
    }

    /// `RET Owner::name(params) [const] { body }`, inside the owner's wrapper.
    priv fn _method(self, m: *FunctionDecl, owner: *Decl) {
        if !m->has_body() { return; }
        if m->body_kind != FnBodyKind::Block { self._unsupported_body(m); return; }
        ICE_IF(m->is_variadic, "EmitIR: variadic pack parameters are not emitted yet");

        var wrap = self._open_ns(owner, m->name.range);

        var head = self._owner_template_head(owner);
        head += self._spell.template_head(static_cast::<*Decl>(m));
        var is_ctor = (self._spell.leaf(m) == self._spell.leaf(owner));
        var nm = self._spell.leaf(m);
        var qual = self._owner_qual(owner);
        if is_ctor {
            head += qual + "::" + self._spell.leaf(owner);
        } else if nm[0] == '~' {
            // A destructor definition takes no return type, and leaf() has
            // already spelled the `~`.
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
        sink->spell(m->name.range, head);

        self._body(m, &null);
        self._close_ns(m->range, wrap);
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
        return self._spell._type(f->return_type);
    }

    /// Parameter text for a DEFINITION: names always, `self` only for an
    /// extension member (as the receiver pointer).
    priv fn _params_text(self, f: *FunctionDecl, ext: *ExtensionDecl) -> string {
        var s = "";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            ICE_IF(p->default_val != &null, "EmitIR: parameter defaults are not emitted yet");
            if p->is_self {
                if ext == &null { continue; }
                if !first { s += ", "; }
                first = false;
                if f->is_const() { s += "const "; }
                s += self._spell._type(ext->target);
                s += "* self";
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
        self.emit_block(f->body_block);
        self._cur_fn  = saved_fn;
        self._cur_ext = saved_ext;
    }

    priv fn _unsupported_body(self, f: *FunctionDecl) {
        switch f->body_kind {
            case FnBodyKind::Expr    { ICE_FAIL("EmitIR: expression-bodied function; Lower/ must wrap it in a return block"); }
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
        ICE_IF(s->kind == StmtKind::RecoveryStmt, "EmitIR: poisoned stmt reached codegen; sema gate failure");

        switch s->kind {
            case StmtKind::CompoundStmt    { self.emit_block(cast::<CompoundStmt>(s)); }
            case StmtKind::ReturnStmt      { self._return(cast::<ReturnStmt>(s)); }
            case StmtKind::ExpressionStmt {
                var n = cast::<ExpressionStmt>(s);
                self.emit(n->expr);
                sink->synth_at_end(n->range, clang::tok::semi);
            }
            case StmtKind::DeclStmt        { self._decl(cast::<DeclStmt>(s)); }
            case StmtKind::ConditionalStmt { self._if(cast::<ConditionalStmt>(s)); }
            case StmtKind::WhileLoopStmt   { self._while(cast::<WhileLoopStmt>(s)); }
            case StmtKind::LoopStmt {
                var n = cast::<LoopStmt>(s);
                sink->spell(n->range, "for (;;)");
                self.emit_block(n->body);
            }
            case StmtKind::IndexedForStmt  { self._for(cast::<IndexedForStmt>(s)); }
            case StmtKind::BreakStmt {
                var n = cast::<BreakStmt>(s);
                ICE_IF(n->has_label, "EmitIR: labeled break; needs the label lowering (JumpLabelCheck's successor)");
                sink->spell(n->range, "break;");
            }
            case StmtKind::ContinueStmt {
                var n = cast::<ContinueStmt>(s);
                ICE_IF(n->has_label, "EmitIR: labeled continue; needs the label lowering");
                sink->spell(n->range, "continue;");
            }
            case StmtKind::UnsafeBlockStmt { self.emit_block(cast::<UnsafeBlockStmt>(s)->body); }
            case StmtKind::RangedForStmt          { ICE_FAIL("EmitIR: ranged for; IterLowering owns it"); }
            case StmtKind::MatchStmt              { ICE_FAIL("EmitIR: match; MatchLowering / PatternCompilation own it"); }
            case StmtKind::TryCatchStmt           { ICE_FAIL("EmitIR: try/catch; PanicLowering owns it"); }
            case StmtKind::FinallyStmt            { ICE_FAIL("EmitIR: finally; FinallyLowering owns it"); }
            case StmtKind::PanicStmt              { ICE_FAIL("EmitIR: panic; PanicLowering owns it"); }
            case StmtKind::YieldStmt              { ICE_FAIL("EmitIR: yield; YieldLowering owns it"); }
            case StmtKind::RuntimeAssertStmt      { ICE_FAIL("EmitIR: assert; PanicLowering owns it"); }
            case StmtKind::StaticAssertStmt       { ICE_FAIL("EmitIR: static assert; the Evaluator owns it"); }
            case StmtKind::ContextBindingStmt     { ICE_FAIL("EmitIR: context binding; ContextLowering owns it"); }
            case StmtKind::DestructuringDeclStmt  { ICE_FAIL("EmitIR: destructuring; its lowering owns it"); }
            case StmtKind::LabeledStmt            { ICE_FAIL("EmitIR: labeled loop; the label lowering owns it"); }
            case StmtKind::LabelIntrinsicStmt     { ICE_FAIL("EmitIR: label!; the label lowering owns it"); }
            case StmtKind::JumpIntrinsicStmt      { ICE_FAIL("EmitIR: jump!; the label lowering owns it"); }
            case StmtKind::InlineBlockStmt        { ICE_FAIL("EmitIR: inline foreign block; not emitted yet"); }
            case StmtKind::EvalBlockStmt          { ICE_FAIL("EmitIR: eval block; EvalLowering owns it"); }
            default { ICE_FAIL(f"EmitIR: statement kind {to_string(s->kind)} is not in the core"); }
        }
    }

    fn emit_block(self, n: *CompoundStmt) {
        ICE_IF(n == &null, "EmitIR: null block reached codegen");
        sink->synth_at_start(n->range, clang::tok::l_brace);
        for var i: usize = 0; i < n->body.size(); ++i { self.emit(n->body[i]); }
        sink->synth_at_end(n->range, clang::tok::r_brace);
    }

    priv fn _decl(self, n: *DeclStmt) {
        ICE_IF(n->decl == &null, "EmitIR: DeclStmt with no decl");
        switch n->decl->kind {
            case DeclKind::VariableDecl { self._var_decl(cast::<VariableDecl>(n->decl)); }
            default { ICE_FAIL("EmitIR: statement-scope named decls (local fn/class/type) are not emitted yet"); }
        }
        sink->synth_at_end(n->range, clang::tok::semi);
    }

    /// `[const|static|constexpr] TYPE name [= init]`; no trailing `;`.
    /// After X `type_` is never null on a checked tree; `auto` is the
    /// pre-X fallback and is a bug if it ever prints for real code.
    priv fn _var_decl(self, n: *VariableDecl) {
        ICE_IF(n->kind == DeclKind::RecoveryDecl, "EmitIR: poisoned VariableDecl reached codegen");
        switch n->storage {
            case StorageClass::Const  { sink->kw_const(n->name);     }
            case StorageClass::Static { sink->kw_static(n->name);    }
            case StorageClass::Eval   { sink->kw_constexpr(n->name); }
            default { }
        }
        var c: *Type = &null;
        if (n->type_ != &null) && (n->type_->canonical != &null) { c = canon_unqual(n->type_->canonical); }
        if (c != &null) && (c->kind == TypeKind::FixedArrayType) {
            // `T name[N]`: the name sits inside the declarator.
            var nm = self._cg->ctx->get_imm_table()->get_ident(n->name.imm);
            sink->spell(n->name.range, self._spell.decl(n->type_, nm));
        } else {
            if n->type_ == &null {
                var nm = self._cg->ctx->get_spelling(n->name);
                self._cg->ctx->diag_sink.report(DiagCode(DiagID::I001W), n->name.range.start,
                    f"internal: '{nm}' reached codegen with no inferred type; This is a compiler bug; please report it with the source that triggered it"
                ).first(n->name.range).emit();
                sink->kw_auto(n->name);
            } else if n->type_->range.is_valid() {
                self.emit(n->type_);
            } else {
                sink->spell(n->name.range, self._spell._type(n->type_));
            }
            self._name(n->name);
        }
        if n->init != &null {
            sink->synth_at_end(n->name.range, clang::tok::equal);
            var il = dyn_cast::<InitListExpr>(n->init);
            if (il != &null) && (c != &null) && (c->kind == TypeKind::FixedArrayType) {
                self._init_list(il, true);     // a declarator's initializer: the one place bare braces are legal.
            } else {
                self._value(n->init, n->type_);
            }
        }
    }

    /// The `return` keyword borrows the statement's first six bytes; correct
    /// only because Kairo spells it `return` too. TODO(ast): retain the token.
    priv fn _return(self, n: *ReturnStmt) {
        sink->synth(SourceRange::from_bounds(n->range.start, u32(6)), clang::tok::kw_return);
        if n->value != &null {
            var rt: *Type = &null;
            if self._cur_fn != &null { rt = self._cur_fn->return_type; }
            self._value(n->value, rt);
        }
        sink->synth_at_end(n->range, clang::tok::semi);
    }

    priv fn _if(self, n: *ConditionalStmt) {
        sink->spell(SourceRange::from_bounds(n->range.start, u32(2)), "if (");
        self.emit(n->cond);
        sink->spell(n->cond->range, ")");
        self.emit_block(n->then_);
        if n->else_ != &null {
            sink->spell(n->else_->range, "else");
            self.emit(n->else_);   // a ConditionalStmt (else-if) or a CompoundStmt.
        }
    }

    priv fn _while(self, n: *WhileLoopStmt) {
        sink->spell(SourceRange::from_bounds(n->range.start, u32(5)), "while (");
        self.emit(n->cond);
        sink->spell(n->cond->range, ")");
        self.emit_block(n->body);
    }

    priv fn _for(self, n: *IndexedForStmt) {
        ICE_IF(n->is_eval, "EmitIR: eval for; EvalLowering owns it");
        sink->spell(SourceRange::from_bounds(n->range.start, u32(3)), "for (");
        if n->init != &null {
            var ds = dyn_cast::<DeclStmt>(n->init);
            ICE_IF(ds == &null, "EmitIR: for-init is not a DeclStmt");
            ICE_IF(!isa::<VariableDecl>(ds->decl), "EmitIR: for-init is not a variable");
            self._var_decl(cast::<VariableDecl>(ds->decl));
        }
        sink->spell(n->range, ";");
        if n->cond != &null { self.emit(n->cond); }
        sink->spell(n->range, ";");
        if n->update != &null { self.emit(n->update); }
        sink->spell(n->range, ")");
        self.emit_block(n->body);
    }

    // ----------------------------------------------------------------- //
    // Expressions
    // ----------------------------------------------------------------- //

    fn emit(self, e: *Expr) {
        ICE_IF(e == &null, "EmitIR: null expr reached codegen");
        ICE_IF(e->kind == ExprKind::RecoveryExpr, "EmitIR: poisoned expr reached codegen; sema gate failure");
        ICE_IF(e->is_poisoned(), "EmitIR: poisoned expr reached codegen; sema gate failure");

        switch e->kind {
            case ExprKind::IntegerLiteralExpr   { self._int_lit(cast::<IntegerLiteralExpr>(e)->token); }
            case ExprKind::FloatingLiteralExpr  { sink->synth(cast::<FloatingLiteralExpr>(e)->token, clang::tok::numeric_constant); }
            case ExprKind::CharacterLiteralExpr { sink->synth(cast::<CharacterLiteralExpr>(e)->token, clang::tok::char_constant); }
            case ExprKind::BooleanLiteralExpr   { sink->spell(e->range, (("true") if (cast::<BooleanLiteralExpr>(e)->value) else ("false"))); }
            case ExprKind::NullLiteralExpr      { sink->spell(e->range, "nullptr"); }
            case ExprKind::StringLiteralExpr    { self._string(cast::<StringLiteralExpr>(e)); }
            case ExprKind::NamedIdentExpr       { self._name(cast::<NamedIdentExpr>(e)); }
            case ExprKind::ChainExpr            { self._chain(cast::<ChainExpr>(e)); }
            case ExprKind::CallExpr             { self._call(cast::<CallExpr>(e)); }
            case ExprKind::ParenExpr {
                sink->spell(e->range, "(");
                self.emit(cast::<ParenExpr>(e)->inner);
                sink->spell(e->range, ")");
            }
            case ExprKind::UnaryOperatorExpr    { self._unary(cast::<UnaryOperatorExpr>(e)); }
            case ExprKind::BinaryOperatorExpr   { self._binary(cast::<BinaryOperatorExpr>(e)); }
            case ExprKind::AssignOperatorExpr   { self._assign(cast::<AssignOperatorExpr>(e)); }
            case ExprKind::TypeCastExpr         { self._cast(cast::<TypeCastExpr>(e)); }
            case ExprKind::ImplicitBoundaryCastExpr {
                var n = cast::<ImplicitBoundaryCastExpr>(e);
                self._cast_to(n->target_type, n->original, "static_cast");
            }
            case ExprKind::NamedInitializerExpr { self._init(e, cast::<NamedInitializerExpr>(e)->fields); }
            case ExprKind::AnonInitializerExpr  { self._init(e, cast::<AnonInitializerExpr>(e)->fields); }
            case ExprKind::IfExpr               { self._if_expr(cast::<IfExpr>(e)); }
            case ExprKind::SizeOfExpr           { sink->spell(e->range, "sizeof(" + self._spell._type(cast::<SizeOfExpr>(e)->type_arg) + ")"); }
            case ExprKind::AlignOfExpr          { sink->spell(e->range, "alignof(" + self._spell._type(cast::<AlignOfExpr>(e)->type_arg) + ")"); }
            case ExprKind::DeleteExpr {
                var n = cast::<DeleteExpr>(e);
                sink->spell(e->range, (("delete[]") if (n->is_array) else ("delete")));
                self.emit(n->operand);
            }
            case ExprKind::UnsafeExpr           { self.emit(cast::<UnsafeExpr>(e)->operand); }
            case ExprKind::SubscriptExpr        { self._subscript(cast::<SubscriptExpr>(e)); }
            case ExprKind::NamedArgExpr         { ICE_FAIL("EmitIR: named argument; CallLowering owns it"); }
            case ExprKind::MatchExpr            { ICE_FAIL("EmitIR: match expression; MatchLowering owns it"); }
            case ExprKind::TryCatchExpr         { ICE_FAIL("EmitIR: try expression; PanicLowering owns it"); }
            case ExprKind::RangeExpr            { ICE_FAIL("EmitIR: range; IterLowering owns it"); }
            case ExprKind::ClosureExpr          { ICE_FAIL("EmitIR: closure; lambda emission is not written yet"); }
            case ExprKind::AwaitExpr            { ICE_FAIL("EmitIR: await; the async lowering owns it"); }
            case ExprKind::SpawnExpr            { ICE_FAIL("EmitIR: spawn; the async lowering owns it"); }
            case ExprKind::ThreadExpr           { ICE_FAIL("EmitIR: thread; the async lowering owns it"); }
            case ExprKind::EvalExpr             { ICE_FAIL("EmitIR: eval; EvalLowering owns it"); }
            case ExprKind::PackExpansionExpr    { ICE_FAIL("EmitIR: pack expansion; not emitted yet"); }
            case ExprKind::ListLiteralExpr      { ICE_FAIL("EmitIR: list literal; ListLiteralLowering owns it"); }
            case ExprKind::InitListExpr         { self._init_list(cast::<InitListExpr>(e), false); }
            case ExprKind::StmtExpr {
                // `({ ... })`: clang's statement expression. The block is
                // emitted as any block; the parens make it a value.
                sink->spell(e->range, "(");
                self.emit_block(cast::<StmtExpr>(e)->body);
                sink->spell(e->range, ")");
            }
            case ExprKind::SetLiteralExpr       { ICE_FAIL("EmitIR: set literal; the container migration owns it"); }
            case ExprKind::MapLiteralExpr       { ICE_FAIL("EmitIR: map literal; the container migration owns it"); }
            case ExprKind::TupleLiteralExpr     { ICE_FAIL("EmitIR: tuple literal; no lowering yet"); }
            case ExprKind::TypeOfExpr           { ICE_FAIL("EmitIR: typeof; TypeQueryLowering owns it"); }
            case ExprKind::ImplConformanceExpr  { ICE_FAIL("EmitIR: impl test; TypeQueryLowering owns it"); }
            case ExprKind::DerivesRelationExpr  { ICE_FAIL("EmitIR: derives test; TypeQueryLowering owns it"); }
            case ExprKind::ConstraintExpr       { ICE_FAIL("EmitIR: constraint in expression position; RequiresDesugar owns it"); }
            case ExprKind::VerbatimExpr         { ICE_FAIL("EmitIR: verbatim span; tooling-only node"); }
            default { ICE_FAIL(f"EmitIR: expression kind {to_string(e->kind)} is not in the core"); }
        }
    }

    /// Emit \p e where a value of \p want is required: the exactness cast
    /// if the canonicals differ. Initializers, returns and arguments all go
    /// through here.
    priv fn _value(self, e: *Expr, want: *Type, subst: *InstanceEntry = &null) {
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
            var g = cast::<GenericParamType>(canon_unqual(w));
            if (g->owner != &null) && (CXXSpell::rep(g->owner) == CXXSpell::rep(subst->primary))
            && (static_cast::<usize>(g->param_index) < subst->args.size()) {
                w = subst->args[static_cast::<usize>(g->param_index)];
            }
        }
        if have->is_dependent() || w->is_dependent() { return false; }
        if have->is_instantiation_dependent() || w->is_instantiation_dependent() { return false; }
        // A record by value is copy-constructed; `static_cast<Rec>(x)` is a
        // temporary and changes value category. Records go as they are.
        if canon_unqual(w)->kind == TypeKind::RecordType { return false; }
        return canon_unqual(have) != canon_unqual(w);
    }

    priv fn _cast_to(self, t: *Type, e: *Expr, kind: string, subst: *InstanceEntry = &null) {
        sink->spell(e->range, kind + "<" + self._spell._type(t, subst) + ">(");
        self.emit(e);
        sink->spell(e->range, ")");
    }

    priv fn _string(self, n: *StringLiteralExpr) {
        ICE_IF(n->has_next(), "EmitIR: multi-part string literal; Lower/ must concatenate it");
        ICE_IF(n->is_format(), "EmitIR: f-string; FStringLowering owns it");
        var final_str = std::string_to_nstring(n->get_spelling());
        sink->create_str(n->token, final_str);
    }

    // --- Names -------------------------------------------------------------------

    /// A local (param, body var, binder, generic param) is bare: unique by
    /// construction. `self` is `this` or the receiver parameter. Everything
    /// else is qualified from its decl; an overload set here is an X gate
    /// failure.
    priv fn _name(self, n: *NamedIdentExpr) {
        var d = n->resolved_decl;
        ICE_IF((d == &null) && (n->candidate_cell != &null), "EmitIR: unpromoted overload set reached codegen; ExprTyper gate failure");
        ICE_IF(d == &null, "EmitIR: unbound name reached codegen; NameResolution gate failure");

        if self._is_self_decl(d) {
            sink->spell(n->range, (("self") if (self._cur_ext != &null) else ("this")));
            return;
        }
        if self._is_local(d) { self._name(n->name); return; }
        sink->spell(n->range, self._spell.qual_name(d));
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
    /// canonical. A UFCS step (extension member) is only meaningful as a
    /// callee and is handled in _call.
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
            ICE_IF(st->resolved_decl == &null, "EmitIR: unbound `::` step reached codegen; ChainBinding gate failure");
            sink->spell(st->range, self._spell.qual_name(st->resolved_decl));
            is_ptr = self._type_is_pointer(st->resolved_type);
            i = k + 1;
        } else {
            ICE_IF(n->base == &null, "EmitIR: global-root chain with no `::` step");
            self.emit(n->base);
            is_ptr = self._base_is_self(n->base) || self._is_pointer(n->base);
        }
        for var j: usize = i; j < upto; ++j {
            var st = n->steps.get(j);
            ICE_IF(st->access_kind == ChainExpr::AccessKind::ColonColon, "EmitIR: `::` after a value step");
            ICE_IF((st->access_kind == ChainExpr::AccessKind::QuestionDot) || (st->access_kind == ChainExpr::AccessKind::QuestionArrow),
                "EmitIR: optional chaining; NullTestLowering owns it");
            if st->is_operator() {
                sink->spell(st->range, (("->") if (is_ptr) else (".")) + self._spell.leaf(st->resolved_decl));
                is_ptr = false;
                continue;
            }
            ICE_IF(st->is_tuple_index(), "EmitIR: tuple index; no lowering yet");
            ICE_IF(st->is_ufcs || self._is_extension_member(st->resolved_decl), "EmitIR: extension member used as a value; only a call form exists");
            ICE_IF(st->resolved_decl == &null, "EmitIR: unbound member step reached codegen; gate failure");
            sink->spell(st->range, (("->") if (is_ptr) else (".")));
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

    /// The receiver of a UFCS callee: the chain minus its last step, as a
    /// pointer -- itself if it already is one, `(&...)` otherwise.
    priv fn _receiver(self, ch: *ChainExpr) {
        var last = ch->steps.size() - 1;
        if last == 0 {
            var b = ch->base;
            if self._base_is_self(b) || self._is_pointer(b) { self.emit(b); return; }
            ICE_IF(!b->is_lvalue(), "EmitIR: extension call on a prvalue receiver; ExtensionLowering must materialize a temporary");
            sink->spell(b->range, "(&");
            self.emit(b);
            sink->spell(b->range, ")");
            return;
        }
        // A field path off an lvalue is an lvalue; off a pointer it is too.
        var prev = ch->steps.get(last - 1);
        if self._type_is_pointer(prev->resolved_type) {
            self._chain_prefix(ch, last);
            return;
        }
        sink->spell(ch->range, "(&");
        self._chain_prefix(ch, last);
        sink->spell(ch->range, ")");
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
        ICE_IF(callee == &null, "EmitIR: unbound callee reached codegen; ExprTyper gate failure");

        // Extension member through a receiver: `x.len()` -> `::ns::len(&x)`.
        var ch = dyn_cast::<ChainExpr>(n->callee);
        var ext_call = false;
        if (ch != &null) && (ch->steps.size() > 0) {
            var last = ch->steps.get(ch->steps.size() - 1);
            if last->is_ufcs || self._is_extension_member(last->resolved_decl) {
                ICE_IF(last->access_kind == ChainExpr::AccessKind::ColonColon, "EmitIR: extension member called through `::`; ExtensionLowering owns the qualified form");
                ext_call = true;
            }
        }

        var f    = dyn_cast::<FunctionDecl>(callee);
        var inst = reinterpret_cast::<*InstanceEntry>(n->instance);
        if ext_call {
            ICE_IF(f == &null, "EmitIR: UFCS step that is not a function");
            sink->spell(n->callee->range, self._spell.qual_name(callee) + "(");
            self._receiver(ch);
            self._args(n, f, true, inst);
            sink->synth_at_end(n->range, clang::tok::r_paren);
            return;
        }

        // A constructor call names the TYPE being built, from the call's own
        // canonical (`Slice<int>(...)`), never the ctor decl's owner template.
        if self._is_ctor(f) || self._is_type_decl(callee) {
            ICE_IF(n->type_ == &null, "EmitIR: untyped constructor call; ExprTyper gate failure");
            sink->spell(n->callee->range, self._spell._type(n->type_));
        } else if (inst != &null) && (f != &null) && (f->generic_params.size() > 0) && self._plain_callee(n->callee) {
            // A generic free function: the instance's arguments are spelled
            // out. Left to clang, they would be deduced from the emitted
            // argument EXPRESSIONS, and an argument whose C++ type is not its
            // Kairo type (an int literal typed i64) deduces an instance no TU
            // homed, so nothing defines it.
            sink->spell(n->callee->range, self._spell.qual_name(callee) + self._spell.args_str(&(inst->args)));
        } else {
            self.emit(n->callee);
        }
        sink->synth_at_end(n->callee->range, clang::tok::l_paren);
        self._args(n, f, false, inst);
        sink->synth_at_end(n->range, clang::tok::r_paren);
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
    /// \p have_recv: a receiver was already emitted, so a comma precedes.
    priv fn _args(self, n: *CallExpr, f: *FunctionDecl, have_recv: bool, inst: *InstanceEntry) {
        var params = self._value_params(f);
        if have_recv && (n->args.size() > 0) { sink->spell(n->range, ","); }
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            if i > 0 { sink->synth_at_end(n->args[i - 1]->range, clang::tok::comma); }
            var p: *ParamDecl = &null;
            if i < params.size() { p = params[i]; }
            self._arg(a, p, inst);
        }
    }

    priv fn _arg(self, a: *Expr, p: *ParamDecl, inst: *InstanceEntry) {
        // `&x` bound to an @inout parameter is the mode marker, not address-of.
        var u = dyn_cast::<UnaryOperatorExpr>(a);
        if (u != &null) && u->is_mode_marker { self.emit(u->operand); return; }
        if p == &null { self.emit(a); return; }
        if p->mode == ParamMode::Move {
            // An lvalue must be moved explicitly; a prvalue already is.
            if a->is_lvalue() {
                sink->spell(a->range, "static_cast<" + self._spell._type(p->type_, inst) + "&&>(");
                self.emit(a);
                sink->spell(a->range, ")");
                return;
            }
            self.emit(a);
            return;
        }
        if p->mode == ParamMode::Inout { self.emit(a); return; }   // an lvalue binds to T& as is.
        self._value(a, p->type_, inst);
    }

    /// The parameters an argument list maps onto: `self` excluded.
    priv fn _value_params(self, f: *FunctionDecl) -> vec::<*ParamDecl> {
        var out = vec::<*ParamDecl>();
        if f == &null { return out; }
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if (p == &null) || p->is_self { continue; }
            out.push_back(p);
        }
        return out;
    }

    priv fn _callee_decl(self, c: *Expr) -> *Decl {
        var ni = dyn_cast::<NamedIdentExpr>(c);
        if ni != &null {
            ICE_IF((ni->resolved_decl == &null) && (ni->candidate_cell != &null), "EmitIR: unpromoted callee; ExprTyper gate failure");
            return ni->resolved_decl;
        }
        var ch = dyn_cast::<ChainExpr>(c);
        if (ch != &null) && (ch->steps.size() > 0) {
            var last = ch->steps.get(ch->steps.size() - 1);
            ICE_IF((last->resolved_decl == &null) && (last->candidate_cell != &null), "EmitIR: unpromoted callee step; ExprTyper gate failure");
            return last->resolved_decl;
        }
        return &null;   // a fn-pointer expression; no decl to consult.
    }

    priv fn _is_extension_member(self, d: *Decl) -> bool {
        if (d == &null) || (!isa::<FunctionDecl>(d)) { return false; }
        var lex = reinterpret_cast::<*DeclContext>(d->lexical_dc);
        return (lex != &null) && (lex->dc_kind == DeclContextKind::Extension);
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
        var fid = self._cg->tu->fid;
        if self._cur_fn != &null { fid = CXXSpell::fid_of(static_cast::<*Decl>(self._cur_fn)); }
        var spelled = self._spell.imm_name(t.imm, fid);
        ICE_IF(spelled == "<?>", "EmitIR: identifier token with no spelling in its owning file's table");
        sink->create_ident(t.range, spelled);
    }

    /// Same rule for a numeric constant: a minted IntData carries no source
    /// body, so it is spelled from its value instead of borrowed.
    priv fn _int_lit(self, t: Token) {
        var d = self._cg->ctx->get_imm_table()->get::<Immediate::IntData>(t.imm);
        if (d != &null) && (!d->body.is_valid()) {
            var cxx = std::string_to_nstring(f"{d->value_lo}");
            sink->create_int(t.range, cxx);
            return;
        }
        sink->synth(t, clang::tok::numeric_constant);
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
        var k = n->op_token.kind;
        var addr_or_deref = (k == TokenKind::OpAmp) || (k == TokenKind::OpStar);
        ICE_IF(self._record_operand(n->operand) && (!addr_or_deref), "EmitIR: user operator; OperatorLowering must rewrite it into a call");
        sink->spell(n->range, "(");
        if n->is_prefix() { sink->create(n->op_token); }
        self.emit(n->operand);
        if n->is_postfix() { sink->create(n->op_token); }
        sink->spell(n->range, ")");
    }

    priv fn _binary(self, n: *BinaryOperatorExpr) {
        ICE_IF(n->op_token.kind == TokenKind::OpEqualEqualEqual, "EmitIR: `===`; NullTestLowering owns it");
        ICE_IF(self._record_operand(n->lhs) || self._record_operand(n->rhs), "EmitIR: user operator; OperatorLowering must rewrite it into a call");
        sink->spell(n->range, "(");
        self.emit(n->lhs);
        sink->create(n->op_token);
        self.emit(n->rhs);
        sink->spell(n->range, ")");
    }

    priv fn _assign(self, n: *AssignOperatorExpr) {
        // Plain `=` on records is copy/move assignment; CopyMoveLowering
        // decides which. Compound assignment on a record is a user operator.
        if (n->op_token.kind != TokenKind::OpEqual) {
            ICE_IF(self._record_operand(n->lhs) || self._record_operand(n->rhs), "EmitIR: compound assignment on a record; OperatorLowering owns it");
        }
        sink->spell(n->range, "(");
        self.emit(n->lhs);
        sink->create(n->op_token);
        self._value(n->rhs, n->lhs->type_);
        sink->spell(n->range, ")");
    }

    /// The written target is the result type (invariant 15). Which C++ cast:
    /// `as const` -> const_cast, `as unsafe` -> reinterpret_cast, otherwise
    /// static_cast. A checked/asserting downcast is PanicLowering's; a user
    /// `op as` or a converting ctor is OperatorLowering's.
    priv fn _cast(self, n: *TypeCastExpr) {
        // A lowering's move: `x as T&&`. Never written by the user (Kairo has
        // no reference types), always a record, always static_cast.
        if (n->target != &null) && (n->target->canonical != &null) && isa::<CXXRValueRefType>(n->target->canonical) {
            self._cast_to(n->target, n->operand, "static_cast");
            return;
        }
        var src_rec = self._record_operand(n->operand);
        ICE_IF(src_rec && (!self._type_is_pointer(n->operand->type_)), "EmitIR: `as` on a record value; OperatorLowering owns op as / ctor casts");
        var kind = "static_cast";
        if n->mode == CastMode::Const  { kind = "const_cast"; }
        if n->mode == CastMode::Unsafe { kind = "reinterpret_cast"; }
        self._cast_to(n->target, n->operand, kind);
    }

    priv fn _subscript(self, n: *SubscriptExpr) {
        ICE_IF(self._record_operand(n->base), "EmitIR: `[]` on a record; OperatorLowering owns it");
        ICE_IF(isa::<RangeExpr>(n->index), "EmitIR: slice; IterLowering owns it");
        self.emit(n->base);
        sink->spell(n->range, "[");
        self.emit(n->index);
        sink->spell(n->range, "]");
    }

    priv fn _if_expr(self, n: *IfExpr) {
        // (c ? a : (c2 ? b : e)) -- every arm converts to the join type X
        // recorded on the node.
        sink->spell(n->range, "(");
        self.emit(n->condition);
        sink->spell(n->range, "?");
        self._value(n->then_expr, n->type_);
        sink->spell(n->range, ":");
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var arm = n->else_ifs.get(i);
            sink->spell(arm->range, "(");
            self.emit(arm->condition);
            sink->spell(arm->range, "?");
            self._value(arm->body, n->type_);
            sink->spell(arm->range, ":");
        }
        self._value(n->else_expr, n->type_);
        for var i: usize = 0; i < n->else_ifs.size(); ++i { sink->spell(n->range, ")"); }
        sink->spell(n->range, ")");
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
        ICE_IF(n->type_ == &null, "EmitIR: untyped init list reached codegen; ListLiteralLowering must type it");
        var c = canon_unqual(n->type_);
        ICE_IF((c == &null) || (c->kind != TypeKind::FixedArrayType),
            "EmitIR: init list that is not an array; the initializer_list constructor form is not written yet");
        var at   = cast::<FixedArrayType>(c);
        var elem = at->element;

        if bare {
            sink->spell(n->range, "{");
        } else {
            sink->spell(n->range, "::" + LowerTargets::array_alias() + "<" + self._spell._type(elem) + ", " + f"{at->size_bits}" + ">{");
        }
        for var i: usize = 0; i < n->elements.size(); ++i {
            if i > 0 { sink->spell(n->range, ","); }
            var el = n->elements[i];
            if isa::<InitListExpr>(el) { self._init_list(cast::<InitListExpr>(el), true); }
            else { self._value(el, elem); }
        }
        sink->spell(n->range, "}");
    }

    /// `T{ .a = x, .b = y }` in declaration order. Designated init needs an
    /// aggregate; a record with a user constructor is a ctor call and is
    /// OperatorLowering/CopyMoveLowering's to rewrite.
    priv fn _init(self, e: *Expr, fields: FrozenList::<InitField>) {
        ICE_IF(e->type_ == &null, "EmitIR: untyped initializer reached codegen; ExprTyper gate failure");
        var c = canon_unqual(e->type_);
        ICE_IF(c->kind != TypeKind::RecordType, "EmitIR: initializer of a non-record type");
        var rd = CXXSpell::rep(cast::<RecordType>(c)->decl);
        var layout = self._layout_of(rd);
        ICE_IF(self._has_user_ctor(layout), "EmitIR: initializer on a record with a constructor; must be lowered to a ctor call");

        sink->spell(e->range, self._spell._type(e->type_) + "{");
        // Declaration order: C++ designated initializers may not reorder.
        var decl_fields = self._fields_of(layout);
        var first = true;
        for var fi: usize = 0; fi < decl_fields.size(); ++fi {
            var fd = decl_fields[fi];
            if fd == &null { continue; }
            var fname = self._spell.leaf(static_cast::<*Decl>(fd));
            for var i: usize = 0; i < fields.size(); ++i {
                var f = fields.get(i);
                if self._cg->ctx->get_spelling(f->name) != fname { continue; }
                if !first { sink->spell(f->range, ","); }
                first = false;
                sink->spell(f->range, "." + fname + " =");
                self._value(f->value, fd->type_);
            }
        }
        sink->spell(e->range, "}");
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
        ICE_IF(t->canonical == &null, "EmitIR: unresolved type reached codegen; sema gate failure");
        sink->spell(t->range, self._spell._type(t));
    }
}

__inline_cpp("
#undef sink
");