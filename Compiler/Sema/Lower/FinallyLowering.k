/// --- The Kairo Project ------------------- Sema/Lower/FinallyLowering.k --- ///
///
///   \brief `finally { body }` becomes a record declared in the function
///          body whose destructor is the body, and one local of it declared
///          where the `finally` stood. C++ then owns every exit path.
///
///   \detail
///       fn drain(self, a: i32) {
///           var n = 0
///           finally { self.live -= n; log(a) }
///           ...
///       }
///     becomes
///       {
///           var n = 0
///           struct __kairo_Fin0 {
///               var __kairo_owner: *Pool
///               var n: *i32
///               var a: *i32
///               fn op delete(self) { (*self.__kairo_owner).live -= *self.n; log(*self.a) }
///           }
///           var __kairo_fin0: __kairo_Fin0 = __kairo_Fin0 { __kairo_owner: self, n: &n, a: &a }
///           ...
///       }
///
///     The record is LOCAL to the function body (a C++ local class):
///       - its local is destroyed at the end of its block, in reverse
///         declaration order with the block's other locals, on every exit --
///         fallthrough, return, break, continue, a panic's return, a C++
///         exception unwinding through -- which is control-flow.md's finally,
///         every clause of it, from C++'s own rule for locals;
///       - inside a generic function it is templated with it;
///       - it has the access the enclosing function has ([class.local]), so
///         the body may touch what the function may.
///
///   \par Captures
///     By ADDRESS, every one. The body runs at scope exit and must read the
///     variable's value THEN (`var n = 1; finally { log(n) }; n = 7` logs 7),
///     a write through the pointer writes the variable, and every captured
///     local outlives the guard by construction: it is declared above it in
///     the same or an enclosing block. The enclosing `self` is a pointer
///     already and is captured as one, `*const Owner` in a const method.
///     Statics and namespace-scope variables are not captured; a local
///     class names them directly.
///
///     Capture = every binding FreeVarScan (Sema/Check/CaptureAnalysis.k)
///     reports free in the body that is an automatic VariableDecl or a
///     parameter of the enclosing function. Fields are named after the
///     variable, in order of first use, which is source order and so the
///     same in every TU. Each use is rewritten to `(*self.<field>)`, an
///     lvalue of the variable's type with its cv.
///
///   \par Nested
///     Children are lowered first, so an inner `finally` is already a record
///     and a local when the outer body is scanned: the scan sees the inner
///     initializer's `&x` and captures `x`, and the inner record's own
///     `self` is declared inside the body and is never free.
///
///   \par What V guarantees
///     LoopContextCheck rejected `return`, `break`, `continue`, `yield` and
///     `panic` in a finally body and JumpLabelCheck a `jump!` out of one,
///     so the body is a destructor body.
///
///   \par In a closure
///     A `finally` in a closure body is the same record, declared in the
///     lambda's body (a C++ local class may sit in one) and homed in the
///     enclosing function for its name. What differs is what its names
///     are THERE: a closure's own parameters are captured like the
///     function's, and a binding the closure holds by pointer (`|*x|`,
///     `|*|`; ClosureCaptures) is that pointer inside it, so the guard's
///     field points at the pointer and a use reads back the `*T` the body
///     was typed with. `self` is the enclosing method's, which the lambda
///     captured as `this`.
///
///   \par Codegen
///     EmitIR emits the DeclStmt(StructDecl) in place as `struct N {
///     fields; ~N() { body } };` (EmitIR::_local_record) and the local as
///     any local; CXXSpell names a function-scope record by its leaf
///     (CXXSpell::in_function_scope); EmitPlan admits none of it, since it
///     is part of a body, not of the interface.
///
///   Phase: LOWER, after CopyMoveLowering (its `T&&` cast wraps the node
///   rewritten here; the cast's operand slot is rebound) and before every
///   other body rewrite, so each of them meets the body as a method body.
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
import Sema::Type::TypeUtil::*;
import Sema::Lower::LowerSynth::*;
import Sema::Check::CaptureAnalysis::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

/// Every use of a captured binding in ONE finally body -> `(*self.<field>)`,
/// `self` being the guard's own. The map is FinallyLowering's; this only
/// renders it. A step name in a chain resolves to a member, never to a
/// binding, so a chain's steps pass through untouched and only its base
/// (and bare uses) are rewritten.
class CaptureRewrite derives ASTWriter::<CaptureRewrite> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;
    pub var decls:      vec::<*Decl>;        ///< captured bindings, the enclosing `self` among them.
    pub var fields:     vec::<*FieldDecl>;   ///< parallel: the guard field holding its address.
    pub var pointees:   vec::<*Type>;        ///< parallel: the field's pointee, cv kept.
    pub var guard_self: *ParamDecl = &null;
    pub var guard_ty:   *Type      = &null;

    fn CaptureRewrite(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
    }

    fn transform_named_ident_expr(self, n: *NamedIdentExpr) -> *Expr {
        var d = n->resolved_decl;
        if d == &null { return static_cast::<*Expr>(n); }
        for var i: usize = 0; i < self.decls.size(); ++i {
            if self.decls[i] != d { continue; }
            var s = NamedIdentExpr::create(self.ctx, n->range, self.guard_self->name);
            s->resolved_decl  = static_cast::<*Decl>(self.guard_self);
            s->type_          = self.guard_ty;
            s->value_category = Expr::ValueCategory::LValue;
            var fld = self.fields[i];
            var ptr = self.synth.field_of(n->range, static_cast::<*Expr>(s), static_cast::<*Decl>(fld), fld->type_);
            var de  = UnaryOperatorExpr::create(self.ctx, n->range, ptr, self.synth.punct(n->range, TokenKind::OpStar),
                                                UnaryOperatorExpr::Fix::Prefix);
            de->type_          = self.pointees[i];
            de->value_category = Expr::ValueCategory::LValue;
            return static_cast::<*Expr>(de);
        }
        return static_cast::<*Expr>(n);
    }
}

class FinallyLowering derives ASTWriter::<FinallyLowering> {
    pub var sc: *SemaContext;
    priv var tu:    TypeUtil;
    priv var synth: LowerSynth;
    /// Enclosing functions and closures, innermost last, parallel: a
    /// function frame has a null closure, a closure frame a null function.
    priv var _fns:   vec::<*FunctionDecl>;
    priv var _cls:   vec::<*ClosureExpr>;
    priv var _count: u32 = 0;

    fn FinallyLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter::<FinallyLowering>::run(self.sc->tu);
    }

    // --- scope tracking ---------------------------------------------------------

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        self._fns.push_back(n);
        self._cls.push_back(&null);
        var out = ASTWriter::<FinallyLowering>::transform_function_decl(n);
        self._fns.pop_back();
        self._cls.pop_back();
        return out;
    }

    fn transform_closure_expr(self, n: *ClosureExpr) -> *Expr {
        self._fns.push_back(&null);
        self._cls.push_back(n);
        var out = ASTWriter::<FinallyLowering>::transform_closure_expr(n);
        self._fns.pop_back();
        self._cls.pop_back();
        return out;
    }

    /// The innermost enclosing function: the guard record's home.
    priv fn _home_fn(self) -> *FunctionDecl {
        var i = self._fns.size();
        while i > 0 {
            i = i - 1;
            if self._fns[i] != &null { return self._fns[i]; }
        }
        return &null;
    }

    /// \p p is a parameter of a closure between the home function and here.
    priv fn _closure_param(self, p: *ParamDecl) -> bool {
        var i = self._cls.size();
        while i > 0 {
            i = i - 1;
            var c = self._cls[i];
            if c == &null { return false; }   // the home function's frame.
            for var k: usize = 0; k < c->params.size(); ++k { if c->params[k] == p { return true; } }
        }
        return false;
    }

    /// Inside a closure that holds \p d by pointer (or sees it as one), the
    /// name is that pointer: the type the body's first use \p at_use was
    /// typed with. Null where \p d is the binding itself.
    priv fn _closure_view(self, d: *Decl, at_use: *NamedIdentExpr) -> *Type {
        var i = self._cls.size();
        while i > 0 {
            i = i - 1;
            var c = self._cls[i];
            if c == &null { return &null; }
            if !c->caps_resolved { continue; }
            for var k: usize = 0; k < c->cap_decls.size(); ++k {
                if c->cap_decls[k] != d { continue; }
                var m = c->cap_modes[k];
                var ptr = (m == CaptureMode::Ptr) || (m == CaptureMode::ConstPtr) || c->cap_via_ptr[k];
                if !ptr { return &null; }
                ICE_IF((at_use == &null) || (at_use->type_ == &null), "FinallyLowering: a pointer capture used untyped in a finally body; X gate failure");
                return canon_unqual(at_use->type_);
            }
        }
        return &null;
    }

    // --- the rewrite ----------------------------------------------------------------

    fn transform_finally_stmt(self, n: *FinallyStmt) -> vec::<*Stmt> {
        // Children first: an inner `finally` is a record and a local before
        // this body is scanned (file header, Nested).
        var out = ASTWriter::<FinallyLowering>::transform_finally_stmt(n);
        if n->body == &null { return out; }
        var f = self._home_fn();
        ICE_IF(f == &null, "FinallyLowering: `finally` outside a function body; the parser admits it in statement position only");

        var at = n->range;
        var k  = static_cast::<usize>(self._count);
        self._count += 1;

        // The record, homed in the function: EmitPlan skips it and CXXSpell
        // names it by leaf off this scope (CXXSpell::in_function_scope).
        var fdc = static_cast::<*DeclContext>(f);
        var rec = StructDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::finally_record(k)), fdc);
        self._home(static_cast::<*Decl>(rec), fdc);
        // Implicit: a record the user writes in a body is hoisted to
        // namespace scope (CXXSpell::is_hoisted_local); this one captures
        // the body's locals by address and stays in it.
        rec->is_implicit = true;
        var rdc = static_cast::<*DeclContext>(rec);
        var no_args = vec::<*Type>();
        var rec_ty  = self.sc->types->record(static_cast::<*Decl>(rec), &no_args);
        ICE_IF(rec_ty == &null, "FinallyLowering: no canonical for the guard record");

        // Captures.
        var scan = FreeVarScan();
        scan.run(static_cast::<*Stmt>(n->body));
        var rw     = CaptureRewrite(self.sc);
        var fields = self.list_builder::<*FieldDecl>();
        var inits  = self.list_builder::<InitField>();
        var nf: u32 = 0;
        for var i: usize = 0; i < scan.free.size(); ++i {
            var d = scan.free[i];
            var pointee: *Type = &null;
            var value:   *Expr = &null;
            var name = "";
            var view = self._closure_view(d, scan.free_at[i]);
            if view != &null {
                // Held by pointer in an enclosing closure: the guard points
                // at that pointer (In a closure, above).
                pointee = view;
                value   = self._addr(d, decl_name_tok(d), at, pointee);
                name    = self.tu.decl_name(d);
            } else if isa::<ParamDecl>(d) {
                var p = cast::<ParamDecl>(d);
                ICE_IF((!self._param_of(f, p)) && (!self._closure_param(p)), "FinallyLowering: a parameter of another function is free in a finally body; FreeVarScan missed a declaration");
                if p->is_self {
                    pointee = self._self_pointee(f, p);
                    value   = self._self_ptr(p, at, pointee);
                    name    = LowerTargets::finally_owner();
                } else {
                    var pt = (p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_);
                    pointee = self._pointee(pt, p->is_const, d->range);
                    value   = self._addr(d, p->name, at, pointee);
                    name    = self.tu.decl_name(d);
                }
            } else {
                var v = cast::<VariableDecl>(d);
                if !self._automatic(v) { continue; }   // a static or a global: the local class names it.
                pointee = self._pointee(v->type_, v->is_const(), d->range);
                value   = self._addr(d, v->name, at, pointee);
                name    = self.tu.decl_name(d);
            }
            var fld = FieldDecl::create(self.ctx, d->range, self.synth.ident(d->range, name), StorageClass::Var,
                                        self.sc->types->pointer(pointee), nf);
            self._home(static_cast::<*Decl>(fld), rdc);
            fields.push(fld);
            nf += 1;
            var init = InitField{};
            init.name       = self.synth.ident(at, name);
            init.value      = value;
            init.range      = at;
            init.field_decl = static_cast::<*Decl>(fld);
            inits.push(init);
            rw.decls.push_back(d);
            rw.fields.push_back(fld);
            rw.pointees.push_back(pointee);
        }
        fields.freeze_into(&(rec->fields));
        var no_impl = self.list_builder::<InheritEdge>();
        no_impl.freeze_into(&(rec->implements));

        // `fn op delete(self) { body }`, the body rewritten over its own `self`.
        var selfp = ParamDecl::create_self(self.ctx, at, self.synth.ident(at, "self"));
        selfp->type_ = rec_ty;
        var dtor = FunctionDecl::create(self.ctx, at, Token(), rdc);
        self._home(static_cast::<*Decl>(dtor), rdc);
        self._home(static_cast::<*Decl>(selfp), static_cast::<*DeclContext>(dtor));
        dtor->is_operator = true;
        var toks = self.list_builder::<Token>();
        toks.push(self.synth.punct(at, TokenKind::KwDelete));
        toks.freeze_into(&(dtor->op_token));
        var ps = self.list_builder::<*ParamDecl>();
        ps.push(selfp);
        ps.freeze_into(&(dtor->params));
        rw.guard_self = selfp;
        rw.guard_ty   = rec_ty;
        dtor->body_kind  = FnBodyKind::Block;
        dtor->body_block = cast::<CompoundStmt>(rw.transform_stmt_scalar(static_cast::<*Stmt>(n->body)));
        var ms = self.list_builder::<*FunctionDecl>();
        ms.push(dtor);
        ms.freeze_into(&(rec->methods));

        // The local: `var __kairo_finK: Rec = Rec { f: &x, ... }`. No
        // constructor on the record, so EmitIR renders the initializer as an
        // aggregate's, fields in declaration order.
        var init = NamedInitializerExpr::create(self.ctx, at, &null);
        inits.freeze_into(&(init->fields));
        init->type_          = rec_ty;
        init->value_category = Expr::ValueCategory::RValue;
        var g = VariableDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::finally_local(k)), StorageClass::Var);
        g->type_ = rec_ty;
        g->init  = static_cast::<*Expr>(init);
        self._home(static_cast::<*Decl>(g), fdc);

        var stmts = vec::<*Stmt>();
        stmts.push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(rec))));
        stmts.push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(g))));
        return stmts;
    }

    // --- helpers ----------------------------------------------------------------------

    priv fn _home(self, d: *Decl, dc: *DeclContext) {
        d->semantic_dc = reinterpret_cast::<*void>(dc);
        d->lexical_dc  = reinterpret_cast::<*void>(dc);
    }

    priv fn _param_of(self, f: *FunctionDecl, p: *ParamDecl) -> bool {
        for var i: usize = 0; i < f->params.size(); ++i { if f->params[i] == p { return true; } }
        return false;
    }

    /// An automatic local: not static, and declared in no namespace scope
    /// (EmitIR::_is_local's test). A file-scope variable has a TU or module
    /// home; a body local has none, or a function/block one.
    priv fn _automatic(self, v: *VariableDecl) -> bool {
        if v->is_static() { return false; }
        var dc = reinterpret_cast::<*DeclContext>(v->semantic_dc);
        if dc == &null { return true; }
        return dc->is_function() || (dc->dc_kind == DeclContextKind::Block) || (dc->dc_kind == DeclContextKind::Lambda);
    }

    /// The captured variable's type, cv kept; a const binding points at a
    /// const object whether or not its canonical says so.
    priv fn _pointee(self, t: *Type, is_const: bool, at: SourceRange) -> *Type {
        ICE_IF((t == &null) || (t->canonical == &null), "FinallyLowering: a captured binding with no canonical type; X gate failure");
        var c = t->canonical;
        if is_const && (!canon_has_const(c)) { c = self.sc->types->qualified(canon_unqual(c), QUAL_CONST()); }
        return c;
    }

    priv fn _self_pointee(self, f: *FunctionDecl, p: *ParamDecl) -> *Type {
        ICE_IF((p->type_ == &null) || (p->type_->canonical == &null), "FinallyLowering: untyped `self`; TypeResolution synthesizes it");
        var c = canon_unqual(p->type_->canonical);
        if p->is_const || f->is_const() || canon_has_const(p->type_->canonical) {
            c = self.sc->types->qualified(c, QUAL_CONST());
        }
        return c;
    }

    /// `self` read as the pointer it is in C++ (ExtensionLowering::_self_ptr):
    /// EmitIR spells a pointer-typed `self` as `this`, or as the receiver
    /// parameter inside an extension member.
    priv fn _self_ptr(self, p: *ParamDecl, at: SourceRange, pointee: *Type) -> *Expr {
        var use = NamedIdentExpr::create(self.ctx, at, p->name);
        use->resolved_decl  = static_cast::<*Decl>(p);
        use->type_          = self.sc->types->pointer(pointee);
        use->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(use);
    }

    /// `&x`, typed `*T` with the variable's cv. Not LowerSynth::addr_of,
    /// which drops cv: a `const T&` parameter's address is a `const T*`.
    priv fn _addr(self, d: *Decl, name: Token, at: SourceRange, pointee: *Type) -> *Expr {
        var use = NamedIdentExpr::create(self.ctx, at, name);
        use->resolved_decl  = d;
        use->type_          = pointee;
        use->value_category = Expr::ValueCategory::LValue;
        var u = UnaryOperatorExpr::create(self.ctx, at, static_cast::<*Expr>(use), self.synth.punct(at, TokenKind::OpAmp),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = self.sc->types->pointer(pointee);
        u->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(u);
    }
}