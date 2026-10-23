/// --- The Kairo Project --------------------- Sema/Check/CtorInitCheck.k --- ///
///
///   \brief A const field is initialized exactly once, by its record's
///          constructor, before the object is used; and the constructor's
///          body is cut where that happens (FunctionDecl::ci_split).
///
///   \detail
///     classes.md: a `const` member with no initializer at its declaration
///     gets exactly one assignment, in the constructor; one with an
///     initializer gets none. C++ has no assignment to a const member at
///     all -- its value must exist at the mem-initializer list, before the
///     first statement runs. So the body is read in two parts:
///
///       S_pre    every top-level statement up to and including the LAST one
///                that assigns a const field (the frontier). It runs before
///                the object exists, against slots (CODEGEN.md §6).
///       S_post   the rest, in the built object.
///
///     The rules follow from "the object does not exist during S_pre":
///
///       - every const field with no declared initializer is assigned on
///         every path to the end of S_pre, and no const field is assigned
///         on a path where it may already be (so never inside a loop);
///       - in S_pre, `self` appears only as `self.f = e` or as a read of a
///         field already assigned on every path: no method call, no `self`
///         passed or returned, no `&self.f`, no field S_pre never writes;
///       - no `return` in S_pre (it would leave a half-built object).
///
///     Any non-const field S_pre assigns, and any top-level local of S_pre
///     that S_post reads, rides across in a slot too. Those are the facts
///     written on the constructor for CtorInitLowering and the emitters:
///     ci_split, ci_index, ci_slots, ci_dense.
///
///     Structural, as ReturnPathCheck is: `if`/`else` intersect, a branch
///     without `else` assigns nothing, a loop body may run zero times, a
///     `return` / `panic` / `break` / `continue` / `-> !` call ends its path.
///
///     Separately, any assignment to a const field that is not `self.f = e`
///     in a constructor of the field's own record is an error wherever it is
///     (classes.md: "cfg.MAX_RETRIES = 5 // compile error").
///
///     Codes: SC001E (placeholder) for every rule; SC116E for the shapes the
///     lowering cannot render yet (a generic constructor, `try` / `finally` /
///     `inline` / `jump!` in S_pre, a static or array-typed local carried
///     across).
///
///   Phase: CHECKS, after InitCheck, before FeatureGateCheck. Reads
///          resolved_decl and expression types (`-> !`).
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
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::StmtKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

/// `self` as a ParamDecl, the one place the question is answered.
fn ctor_init_is_self(e: *Expr) -> bool {
    var ni = dyn_cast::<NamedIdentExpr>(e);
    if (ni == &null) || (ni->resolved_decl == &null) { return false; }
    var p = dyn_cast::<ParamDecl>(ni->resolved_decl);
    return (p != &null) && p->is_self;
}

/// The field \p e names when it is exactly `self.f` (one step), else null.
fn ctor_init_self_field(e: *Expr) -> *FieldDecl {
    var c = dyn_cast::<ChainExpr>(e);
    if (c == &null) || (c->steps.size() != 1) || (!ctor_init_is_self(c->base)) { return &null; }
    var st = c->steps.get(0);
    if (st->resolved_decl == &null) || (!isa::<FieldDecl>(st->resolved_decl)) { return &null; }
    var f = cast::<FieldDecl>(st->resolved_decl);
    if f->is_static() { return &null; }
    return f;
}

/// Is any const field of the record assigned anywhere under a statement?
/// The frontier search.
class CtorConstWriteFind derives RecursiveASTVisitor::<CtorConstWriteFind> {
    pub var found: bool = false;

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        var f = ctor_init_self_field(n->lhs);
        if (f != &null) && f->is_const() { self.found = true; self.stop = true; }
        return true;
    }
}

/// Every field written as `self.f = ...` under a statement, and where first.
class CtorFieldWriteFind derives RecursiveASTVisitor::<CtorFieldWriteFind> {
    pub var fields: vec::<*FieldDecl>;
    pub var at:     vec::<SourceRange>;

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        var f = ctor_init_self_field(n->lhs);
        if f == &null { return true; }
        for var i: usize = 0; i < self.fields.size(); ++i {
            if self.fields[i] == f { return true; }
        }
        self.fields.push_back(f);
        self.at.push_back(n->range);
        return true;
    }
}

/// Every decl a name under a statement resolves to: what S_post reads.
class CtorNameFind derives RecursiveASTVisitor::<CtorNameFind> {
    pub var decls: vec::<*Decl>;

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n->resolved_decl != &null { self.decls.push_back(n->resolved_decl); }
        return true;
    }
}

/// Any `self` at all under a closure: inside S_pre a closure may outlive
/// the slots it would read, so it gets no `self`.
class CtorSelfFind derives RecursiveASTVisitor::<CtorSelfFind> {
    pub var at: SourceRange;
    pub var found: bool = false;

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if ctor_init_is_self(static_cast::<*Expr>(n)) { self.found = true; self.at = n->range; self.stop = true; }
        return true;
    }
}

/// Definitely- and maybe-assigned, per field of the record (index = the
/// field's position in the record's field list). `dead`: no path reaches
/// here, so the state is every field assigned (the identity of the meet).
struct CtorFlow {
    pub var def:   vec::<bool>;
    pub var maybe: vec::<bool>;
    pub var dead:  bool = false;
}

/// One thing the expression scan saw `self` do, in evaluation order.
enum CtorEventKind derives u8 {
    Write = 0,      ///< `self.f = e`, after e's own events.
    CompoundWrite,  ///< `self.f op= e`: a read, then a write.
    Read,           ///< `self.f` / `self.f.<more>`.
    SelfUse,        ///< `self` as a whole: a call, an argument, `&self.f`.
}

struct CtorEvent {
    pub var kind:  CtorEventKind = CtorEventKind::Read;
    pub var field: *FieldDecl = &null;
    pub var at:    SourceRange;
}

/// The expression-level half of the walk: every `self` under an expression
/// (or a statement the walk does not take apart) as an event, in
/// evaluation order -- the right side of an assignment before its target.
/// It records and never judges: CtorInitCheck replays the events against
/// the flow state, so this class needs nothing from that one.
class CtorExprScan derives RecursiveASTVisitor::<CtorExprScan> {
    pub var events: vec::<CtorEvent>;

    priv fn _push(self, k: CtorEventKind, f: *FieldDecl, at: SourceRange) {
        var e = CtorEvent{};
        e.kind  = k;
        e.field = f;
        e.at    = at;
        self.events.push_back(e);
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        var f = ctor_init_self_field(n->lhs);
        if f == &null { return true; }
        if n->rhs != &null { self.dispatch_expr(n->rhs); }
        var k = (CtorEventKind::Write) if (n->op_token.kind == TokenKind::OpEqual) else (CtorEventKind::CompoundWrite);
        self._push(k, f, n->range);
        return false;
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if !ctor_init_is_self(n->base) { return true; }
        var f: *FieldDecl = &null;
        if n->steps.size() > 0 {
            var st = n->steps.get(0);
            if (st->resolved_decl != &null) && isa::<FieldDecl>(st->resolved_decl) && (!cast::<FieldDecl>(st->resolved_decl)->is_static()) {
                f = cast::<FieldDecl>(st->resolved_decl);
            }
        }
        if f == &null { self._push(CtorEventKind::SelfUse, &null, n->range); return false; }
        self._push(CtorEventKind::Read, f, n->range);
        return false;
    }

    /// Bare `self`, and a field named bare: a read like `self.f` (the check
    /// ignores a field of another record).
    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if ctor_init_is_self(static_cast::<*Expr>(n)) { self._push(CtorEventKind::SelfUse, &null, n->range); return true; }
        var d = n->resolved_decl;
        if (d != &null) && isa::<FieldDecl>(d) && (!cast::<FieldDecl>(d)->is_static()) {
            self._push(CtorEventKind::Read, cast::<FieldDecl>(d), n->range);
        }
        return true;
    }

    /// `&self.f`: the slot's address, which dies with S_pre.
    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if (n->op_token.kind == TokenKind::OpAmp) && (ctor_init_self_field(n->operand) != &null) {
            self._push(CtorEventKind::SelfUse, &null, n->range);
            return false;
        }
        return true;
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        var f = CtorSelfFind();
        if n->body_block != &null { f.dispatch_stmt(static_cast::<*Stmt>(n->body_block)); }
        if n->body_expr != &null { f.dispatch_expr(n->body_expr); }
        if f.found { self._push(CtorEventKind::SelfUse, &null, f.at); }
        return false;
    }
}

class CtorInitCheck derives RecursiveASTVisitor::<CtorInitCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;

    // The constructor under analysis (one at a time).
    priv var _owner:    *Decl = &null;
    priv var _ctor:     *FunctionDecl = &null;
    priv var _fields:   FrozenList::<*FieldDecl>;
    priv var _st:       CtorFlow;
    priv var _loops:    u32 = 0;
    priv var _failed:   bool = false;
    priv var _frontier: SourceRange;
    priv var _written:  vec::<*FieldDecl>;       ///< every field S_pre writes.
    priv var _first_at: vec::<SourceRange>;      ///< parallel: its first write.
    /// Per field, where it was first assigned on the path being walked
    /// (valid while maybe[i]); the note on a second assignment.
    priv var _assigned_at: vec::<SourceRange>;

    // The function being traversed, for the stray-assignment rule.
    priv var _fn: *FunctionDecl = &null;

    fn CtorInitCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    // === traversal: records, and the function each assignment sits in ======

    fn visit_class_decl(self, n: *ClassDecl) -> bool {
        self._record(static_cast::<*Decl>(n), n->fields, n->methods);
        return true;
    }

    fn visit_struct_decl(self, n: *StructDecl) -> bool {
        self._record(static_cast::<*Decl>(n), n->fields, n->methods);
        return true;
    }

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        var saved = self._fn;
        self._fn = n;
        var r = RecursiveASTVisitor::<CtorInitCheck>::traverse_function_decl(n);
        self._fn = saved;
        return r;
    }

    /// The stray-assignment rule (file header). `self.f = e` in a
    /// constructor of f's record is the analysis's business, not this one's.
    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if n->is_poisoned() { return true; }
        var c = dyn_cast::<ChainExpr>(n->lhs);
        if (c == &null) || (c->steps.size() == 0) { return true; }
        var st = c->steps.get(c->steps.size() - 1);
        if (st->resolved_decl == &null) || (!isa::<FieldDecl>(st->resolved_decl)) { return true; }
        var f = cast::<FieldDecl>(st->resolved_decl);
        if f->is_static() || (!f->is_const()) { return true; }
        if (ctor_init_self_field(n->lhs) == f) && (self._fn != &null) && self._is_ctor(self._fn)
        && (self._fn->semantic_dc == f->semantic_dc) {
            return true;
        }
        var nm = self.sc->ctx->get_spelling(f->name);
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start, f"cannot assign to const field '{nm}\x27");
        b.first(n->range);
        b.note(f->range.start, f"'{nm}' is const: only a constructor of its own record initializes it, once").first(f->name.range);
        b.emit();
        return true;
    }

    // === one record ==========================================================

    priv fn _record(self, d: *Decl, fields: FrozenList::<*FieldDecl>, methods: FrozenList::<*FunctionDecl>) {
        if d->is_poisoned() || decl_is_instance(d) { return; }
        var index: u32 = 0;
        for var i: usize = 0; i < methods.size(); ++i {
            var m = methods[i];
            if (m == &null) || m->is_poisoned() || (!self._is_ctor(m)) { continue; }
            var def = m;
            if !m->has_body() { def = m->definition(); }
            if (def == &null) || def->is_poisoned() { continue; }
            if self._split_ctor(d, fields, def, index) {
                index += 1;
                // The in-class declaration carries the facts too: the class
                // definition is written from it (InterfaceEmitter).
                if def != m {
                    m->ci_split = def->ci_split;
                    m->ci_index = def->ci_index;
                    m->ci_slots = def->ci_slots;
                    m->ci_dense = def->ci_dense;
                }
            }
        }
    }

    /// A method named after the type it is declared in (StmtTyping's rule).
    priv fn _is_ctor(self, f: *FunctionDecl) -> bool {
        if f->is_operator || (!f->is_method()) || (f->adt_role != AdtRole::None) { return false; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_owner == &null) { return false; }
        return self._tu.decl_name(static_cast::<*Decl>(f)) == self._tu.decl_name(dc->dc_owner);
    }

    /// Analyze one constructor body; true when it was split (facts written).
    priv fn _split_ctor(self, owner: *Decl, fields: FrozenList::<*FieldDecl>, f: *FunctionDecl, index: u32) -> bool {
        self._owner  = owner;
        self._ctor   = f;
        self._fields = fields;
        self._failed = false;
        self._loops  = 0;

        var cname = self._tu.decl_name(owner);
        var at    = f->name.range;

        if f->body_kind == FnBodyKind::Delete { return false; }
        if f->body_kind == FnBodyKind::Default {
            for var i: usize = 0; i < fields.size(); ++i {
                var fd = fields[i];
                if !self._required(fd) { continue; }
                var nm = self.sc->ctx->get_spelling(fd->name);
                var b = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"a defaulted constructor of '{cname}' cannot initialize const field '{nm}\x27");
                b.first(at);
                b.note(fd->range.start, f"'{nm}' is declared here without an initializer; give it one, or write the constructor").first(fd->name.range);
                b.emit();
            }
            return false;
        }
        if (f->body_kind != FnBodyKind::Block) || (f->body_block == &null) {
            if self._has_required(fields) {
                self._gate(at, "a constructor with an expression body on a record with a const field");
            }
            return false;
        }

        var stmts = f->body_block->body;
        var frontier = usize(-1);
        for var i: usize = 0; i < stmts.size(); ++i {
            var w = CtorConstWriteFind();
            w.dispatch_stmt(stmts[i]);
            if w.found { frontier = i; }
        }

        if frontier == usize(-1) {
            for var i: usize = 0; i < fields.size(); ++i {
                var fd = fields[i];
                if !self._required(fd) { continue; }
                var nm = self.sc->ctx->get_spelling(fd->name);
                var b = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"constructor of '{cname}' does not initialize const field '{nm}\x27");
                b.first(at);
                b.note(fd->range.start, f"'{nm}' is declared here without an initializer; assign it in every constructor, or give it one").first(fd->name.range);
                b.emit();
            }
            return false;
        }

        if decl_generic_params(static_cast::<*Decl>(f)).size() > 0 {
            self._gate(at, "a generic constructor that initializes a const field");
            return false;
        }

        self._frontier = stmts[frontier]->range;

        // What S_pre writes, anywhere: the slot set, and which reads of a
        // not-yet-assigned field are "later" rather than "never".
        var wf = CtorFieldWriteFind();
        for var i: usize = 0; i <= frontier; ++i { wf.dispatch_stmt(stmts[i]); }
        self._written  = wf.fields;
        self._first_at = wf.at;

        // The walk.
        self._st = CtorFlow{};
        self._assigned_at.clear();
        for var i: usize = 0; i < fields.size(); ++i {
            self._st.def.push_back(false);
            self._st.maybe.push_back(false);
            self._assigned_at.push_back(SourceRange::invalid());
        }
        for var i: usize = 0; i <= frontier; ++i { self._stmt(stmts[i]); }

        if !self._st.dead {
            for var i: usize = 0; i < fields.size(); ++i {
                var fd = fields[i];
                if (!self._required(fd)) || self._st.def[i] { continue; }
                var nm = self.sc->ctx->get_spelling(fd->name);
                var b = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"const field '{nm}' is not initialized on every path through the constructor of '{cname}\x27");
                b.first(at);
                b.note(fd->range.start, f"'{nm}' is declared here; assign it on every branch (an 'if' needs its 'else'), or give it an initializer").first(fd->name.range);
                b.emit();
                self._failed = true;
            }
        }

        // Top-level locals of S_pre that S_post reads ride across in slots.
        var reads = CtorNameFind();
        for var i: usize = frontier + 1; i < stmts.size(); ++i { reads.dispatch_stmt(stmts[i]); }
        var crossing = vec::<*Decl>();
        for var i: usize = 0; i <= frontier; ++i {
            var ds = dyn_cast::<DeclStmt>(stmts[i]);
            if (ds == &null) || (ds->decl == &null) || (!isa::<VariableDecl>(ds->decl)) { continue; }
            var v = cast::<VariableDecl>(ds->decl);
            var used = false;
            for var j: usize = 0; j < reads.decls.size(); ++j {
                if reads.decls[j] == static_cast::<*Decl>(v) { used = true; break; }
            }
            if !used { continue; }
            if v->is_static() {
                self._gate(v->name.range, "a static local declared before a constructor's last const field assignment and used after it");
                continue;
            }
            var vc = (canon_unqual(v->type_->canonical)) if ((v->type_ != &null) && (v->type_->canonical != &null)) else (&null);
            if (vc != &null) && (vc->kind == TypeKind::FixedArrayType) {
                self._gate(v->name.range, "an array local declared before a constructor's last const field assignment and used after it");
                continue;
            }
            crossing.push_back(static_cast::<*Decl>(v));
        }

        if self._failed { return false; }

        // The facts. Fields in declaration order (the mem-initializers'
        // order), then the locals in source order.
        var slots = vec::<*Decl>();
        var dense = vec::<bool>();
        for var i: usize = 0; i < fields.size(); ++i {
            var fd = fields[i];
            if !self._is_written(fd) { continue; }
            slots.push_back(static_cast::<*Decl>(fd));
            dense.push_back(self._st.dead || self._st.def[i]);
        }
        for var i: usize = 0; i < crossing.size(); ++i {
            slots.push_back(crossing[i]);
            dense.push_back(true);
        }
        f->ci_split = static_cast::<u32>(frontier + 1);
        f->ci_index = index;
        f->ci_slots.from_vec(&slots, self.sc->ctx);
        f->ci_dense.from_vec(&dense, self.sc->ctx);
        return true;
    }

    // === the walk over S_pre ==================================================

    priv fn _stmt(self, s: *Stmt) {
        if s == &null { return; }
        switch s->kind {
            case StmtKind::RecoveryStmt { return; }
            case StmtKind::CompoundStmt { self._block(cast::<CompoundStmt>(s)); }
            case StmtKind::UnsafeBlockStmt { self._block(cast::<UnsafeBlockStmt>(s)->body); }
            case StmtKind::ContextBindingStmt {
                var cb = cast::<ContextBindingStmt>(s);
                self._scan_expr(cb->value);
                self._block(cb->body);
            }
            case StmtKind::ExpressionStmt {
                var es = cast::<ExpressionStmt>(s);
                self._scan_expr(es->expr);
                if (es->expr != &null) && (es->expr->type_ != &null) && self._tu.is_never(es->expr->type_) { self._st.dead = true; }
            }
            case StmtKind::ReturnStmt {
                var r = cast::<ReturnStmt>(s);
                self._scan_expr(r->value);
                var b = self.sc->diag->report(DiagID::SC001E, s->range.start,
                    "a constructor cannot return before its last const field is initialized");
                b.first(s->range);
                b.note(self._frontier.start, "the last const field is initialized here; the object exists only after it").first(self._frontier);
                b.emit();
                self._failed = true;
                self._st.dead = true;
            }
            case StmtKind::PanicStmt {
                self._scan_stmt(s);
                self._st.dead = true;
            }
            case StmtKind::BreakStmt    { self._st.dead = true; }
            case StmtKind::ContinueStmt { self._st.dead = true; }
            case StmtKind::ConditionalStmt {
                var c = cast::<ConditionalStmt>(s);
                self._scan_expr(c->cond);
                var before = self._st;
                self._block(c->then_);
                var then_st = self._st;
                self._st = before;
                if c->else_ != &null { self._stmt(c->else_); }
                self._meet(then_st);
            }
            case StmtKind::MatchStmt {
                var m = cast::<MatchStmt>(s);
                self._scan_expr(m->scrutinee);
                var before = self._st;
                var acc = CtorFlow{};
                var first = true;
                for var i: usize = 0; i < m->cases.size(); ++i {
                    var mc = m->cases.get(i);
                    self._st = before;
                    self._scan_expr(mc->guard);
                    if mc->body != &null { self._block(mc->body); } else { self._scan_expr(mc->expression); }
                    if first { acc = self._st; first = false; } else { var cur = self._st; self._st = acc; self._meet(cur); acc = self._st; }
                }
                if first { acc = before; }
                self._st = acc;
                if !m->is_exhaustive { self._meet(before); }
            }
            case StmtKind::LabeledStmt { self._stmt(cast::<LabeledStmt>(s)->inner); }
            case StmtKind::LoopStmt {
                self._loop(cast::<LoopStmt>(s)->body);
            }
            case StmtKind::WhileLoopStmt {
                var w = cast::<WhileLoopStmt>(s);
                self._scan_expr(w->cond);
                self._loop(w->body);
            }
            case StmtKind::IndexedForStmt {
                var fs = cast::<IndexedForStmt>(s);
                if fs->init != &null { self._stmt(fs->init); }
                self._scan_expr(fs->cond);
                self._loop_with_update(fs->body, fs->update);
            }
            case StmtKind::RangedForStmt {
                var rf = cast::<RangedForStmt>(s);
                self._scan_expr(rf->iterable);
                self._loop(rf->body);
            }
            case StmtKind::TryCatchStmt      { self._gate(s->range, "'try' before a constructor's last const field assignment"); }
            case StmtKind::FinallyStmt       { self._gate(s->range, "'finally' before a constructor's last const field assignment"); }
            case StmtKind::InlineBlockStmt   { self._gate(s->range, "an 'inline' block before a constructor's last const field assignment"); }
            case StmtKind::LabelIntrinsicStmt { self._gate(s->range, "'label!' before a constructor's last const field assignment"); }
            case StmtKind::JumpIntrinsicStmt { self._gate(s->range, "'jump!' before a constructor's last const field assignment"); }
            default { self._scan_stmt(s); }
        }
    }

    priv fn _block(self, b: *CompoundStmt) {
        if b == &null { return; }
        for var i: usize = 0; i < b->body.size(); ++i { self._stmt(b->body[i]); }
    }

    /// A body that may run zero times or many: what it assigns is at most
    /// maybe-assigned after it, and a const field may not be assigned in it.
    priv fn _loop(self, body: *CompoundStmt) {
        self._loop_with_update(body, &null);
    }

    priv fn _loop_with_update(self, body: *CompoundStmt, update: *Expr) {
        var before = self._st;
        self._loops += 1;
        self._block(body);
        self._scan_expr(update);
        self._loops -= 1;
        var after = self._st;
        self._st = before;
        for var i: usize = 0; i < self._st.maybe.size(); ++i {
            if (!after.dead) && after.maybe[i] { self._st.maybe[i] = true; }
        }
    }

    /// The meet of two paths: assigned where both assigned it, maybe-assigned
    /// where either may have. A dead path is the identity.
    priv fn _meet(self, other: CtorFlow) {
        if other.dead { return; }
        if self._st.dead { self._st = other; return; }
        for var i: usize = 0; i < self._st.def.size(); ++i {
            self._st.def[i]   = self._st.def[i] && other.def[i];
            self._st.maybe[i] = self._st.maybe[i] || other.maybe[i];
        }
    }

    priv fn _scan_expr(self, e: *Expr) {
        if e == &null { return; }
        var sc = CtorExprScan();
        sc.dispatch_expr(e);
        self._replay(&(sc.events));
    }

    priv fn _scan_stmt(self, s: *Stmt) {
        if s == &null { return; }
        var sc = CtorExprScan();
        sc.dispatch_stmt(s);
        self._replay(&(sc.events));
    }

    priv fn _replay(self, ev: *vec::<CtorEvent>) {
        for var i: usize = 0; i < ev->size(); ++i {
            var e = (*ev)[i];
            switch e.kind {
                case CtorEventKind::Write         { self._on_write(e.field, e.at, false); }
                case CtorEventKind::CompoundWrite { self._on_write(e.field, e.at, true); }
                case CtorEventKind::Read          { self._on_read(e.field, e.at); }
                default                           { self._on_self_use(e.at); }
            }
        }
    }

    // === events replayed from the expression scan =======================================

    /// `self.f = e` (\p compound: `self.f op= e`), after e was scanned.
    priv fn _on_write(self, f: *FieldDecl, at: SourceRange, compound: bool) {
        var i = self._index(f);
        if i == usize(-1) { return; }
        if compound { self._on_read(f, at); }
        if f->is_const() {
            var nm = self.sc->ctx->get_spelling(f->name);
            if f->init != &null {
                var b = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"const field '{nm}' has an initializer at its declaration, so the constructor cannot assign it");
                b.first(at);
                b.note(f->init->range.start, "its initializer is here; remove it, or this assignment").first(f->init->range);
                b.emit();
                self._failed = true;
            } else if self._loops > 0 {
                var b = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"const field '{nm}' is initialized inside a loop, which may run more than once or not at all");
                b.first(at);
                b.emit();
                self._failed = true;
            } else if self._st.maybe[i] {
                var b = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"const field '{nm}' may already be initialized here; a const field is initialized exactly once");
                b.first(at);
                var prev = self._assigned_at[i];
                if prev.is_valid() { b.note(prev.start, "initialized here first").first(prev); }
                b.emit();
                self._failed = true;
            }
        }
        if !self._st.maybe[i] { self._assigned_at[i] = at; }
        self._st.def[i]   = true;
        self._st.maybe[i] = true;
    }

    /// A read of `self.f` (or `self.f.<more>`).
    priv fn _on_read(self, f: *FieldDecl, at: SourceRange) {
        var i = self._index(f);
        if i == usize(-1) { return; }
        if self._st.def[i] { return; }
        var nm = self.sc->ctx->get_spelling(f->name);
        if self._is_written(f) {
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{nm}' is read before it is initialized on every path");
            b.first(at);
            for var j: usize = 0; j < self._written.size(); ++j {
                if self._written[j] != f { continue; }
                b.note(self._first_at[j].start, f"'{nm}' is first assigned here").first(self._first_at[j]);
                break;
            }
            b.emit();
        } else {
            var b = self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{nm}' cannot be read before every const field is initialized: the object does not exist yet");
            b.first(at);
            b.note(self._frontier.start, f"the last const field is initialized here; read '{nm}' after it").first(self._frontier);
            b.emit();
        }
        self._failed = true;
    }

    /// `self` as a whole: a method call, an argument, a return, an address.
    priv fn _on_self_use(self, at: SourceRange) {
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            "'self' is used before every const field is initialized");
        b.first(at);
        b.note(self._frontier.start, "the last const field is initialized here; the object exists only after it, so move this use below it").first(self._frontier);
        b.emit();
        self._failed = true;
    }

    // === helpers ==============================================================

    priv fn _index(self, f: *FieldDecl) -> usize {
        for var i: usize = 0; i < self._fields.size(); ++i {
            if self._fields[i] == f { return i; }
        }
        return usize(-1);
    }

    priv fn _is_written(self, f: *FieldDecl) -> bool {
        for var i: usize = 0; i < self._written.size(); ++i {
            if self._written[i] == f { return true; }
        }
        return false;
    }

    /// A const field the constructor must assign: no declared initializer.
    priv fn _required(self, f: *FieldDecl) -> bool {
        if (f == &null) || f->is_static() || (!f->is_const()) || f->is_anonymous_union { return false; }
        return f->init == &null;
    }

    priv fn _has_required(self, fields: FrozenList::<*FieldDecl>) -> bool {
        for var i: usize = 0; i < fields.size(); ++i {
            if self._required(fields[i]) { return true; }
        }
        return false;
    }

    priv fn _gate(self, at: SourceRange, what: string) {
        var b = self.sc->diag->report(DiagID::SC116E, at.start, f"{what} is not yet supported");
        b.first(at);
        b.emit();
        self._failed = true;
    }
}
