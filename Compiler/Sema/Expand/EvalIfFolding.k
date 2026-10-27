/// --- The Kairo Project ---------------- Sema/Expand/EvalIfFolding.k --- ///
///
///   \brief `eval if` folded like `#if`: the untaken branches are discarded
///          before name resolution, the taken branch's declarations are
///          hoisted into the enclosing scope.
///
///   \detail
///     EVAL.md §4. Runs first in phase E: after I (an imported `eval`
///     constant is reachable through the overlay) and before V and N, so no
///     later pass sees an untaken branch. Those may name what does not
///     exist on this target; they are never resolved.
///
///       eval if WIDE { eval LINE = 64  fn f() {} } else { eval LINE = 128 }
///     ->
///       eval LINE = 64
///       fn f() {}
///
///     Where the `eval if` stands decides what hoisting means:
///       file scope    the taken statements replace the item; a declaration
///                     other than a variable becomes a Decl item, as the
///                     parser would have made it (EmitPlan reads dc_decls).
///       module body   the carrier EvalBlockDecl is replaced by the taken
///                     declarations in the module's dc_decls.
///       class body    likewise, and each `var` (statement grammar parsed
///                     it, so it is a VariableDecl) becomes a FieldDecl of
///                     the class, each `fn` one of its methods.
///       function body the taken statements are spliced into the enclosing
///                     block: a fold has no scope of its own, as `#if` has
///                     none. An untaken branch's local fn / class leaves the
///                     function's dc_decls.
///
///     \par Tables
///       Frozen tables are never mutated. The parser indexed EVERY branch's
///       declarations into the enclosing table (ASTParse::_index_eval_branches),
///       so each one has its member table and dc links already; this pass
///       builds a new frozen table for every scope it folded in, without
///       the discarded declarations and with each class branch's
///       VariableDecl replaced by its FieldDecl, and swaps it in (the TU's
///       and its module_self's together). ImportResolution::_bind_cxx is
///       the precedent.
///
///     \par Conditions
///       Literals, `!` `&&` `||`, comparisons, the integer arithmetic
///       ConstEval does, parentheses, and an `eval` name (looked up as N
///       would, minus what this pass already discarded) whose initializer
///       folds. `defined!(X)` reaches here as the preprocessor's literal.
///       A condition that does not fold is an error at declaration scope,
///       where the branches decide which declarations exist; in a function
///       body the statement stays and is C++ `if constexpr`.
///
///   Phase: EXPAND (first)
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
import Sema::Check::ConstEval::*;
import Sema::Resolve::NameLookup::*;
import AST::Visitor::ASTWriter::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::StmtKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;
import Sema::Foreign::BuiltinImport::*;
import Interop::Clang::HeaderSet::*;

/// A folded condition's value: a bool, or an integer (a `defined!` is the
/// literal `1` / `0`; an integer is true when it is not zero).
struct FoldVal {
    var ok:     bool;
    var is_int: bool;
    var b:      bool;
    var i:      IntConst;
}

class EvalIfFolding derives ASTWriter::<EvalIfFolding> {
    pub var sc: *SemaContext;
    priv var _ce: ConstEval;

    /// The scopes a name in a condition is looked up from, innermost last.
    priv var _dcs: vec::<*DeclContext>;
    /// > 0 inside a function or closure body.
    priv var _body_depth: u32 = 0;
    /// Every declaration in an untaken branch.
    priv var _dropped: vec::<*Decl>;
    /// A class branch's VariableDecl and the FieldDecl it became.
    priv var _from: vec::<*Decl>;
    priv var _to:   vec::<*Decl>;
    /// Scopes whose table holds a branch's declarations (to rebuild).
    priv var _dirty: vec::<*DeclContext>;
    /// Why the last condition did not fold, and where.
    priv var _why: string;
    priv var _why_at: *Expr = &null;
    /// The declaration the reason is about (a non-eval name), for a note.
    priv var _why_decl: *Decl = &null;
    /// The branch the last _choose took.
    priv var _taken: *CompoundStmt = &null;

    fn EvalIfFolding(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
        self._ce = ConstEval(sc);
    }

    fn run(self) {
        if self.sc->tu == &null { return; }
        if !self._has_eval_if() { return; }
        self._dcs.push_back(static_cast::<*DeclContext>(self.sc->tu));
        ASTWriter::<EvalIfFolding>::run(self.sc->tu);
        for var i: usize = 0; i < self._dirty.size(); ++i { self._rebuild_table(self._dirty[i]); }
    }

    // === scopes =============================================================

    fn transform_module_decl(self, n: *ModuleDecl) -> vec::<*Decl> {
        self._dcs.push_back(static_cast::<*DeclContext>(n));
        var out = ASTWriter::<EvalIfFolding>::transform_module_decl(n);
        self._dcs.pop_back();
        return out;
    }

    fn transform_class_decl(self, n: *ClassDecl) -> vec::<*Decl> {
        self._dcs.push_back(static_cast::<*DeclContext>(n));
        var out = ASTWriter::<EvalIfFolding>::transform_class_decl(n);
        self._dcs.pop_back();
        self._members_from_branches(static_cast::<*Decl>(n), &(n->fields), &(n->methods));
        return out;
    }

    fn transform_struct_decl(self, n: *StructDecl) -> vec::<*Decl> {
        self._dcs.push_back(static_cast::<*DeclContext>(n));
        var out = ASTWriter::<EvalIfFolding>::transform_struct_decl(n);
        self._dcs.pop_back();
        self._members_from_branches(static_cast::<*Decl>(n), &(n->fields), &(n->methods));
        return out;
    }

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        self._dcs.push_back(static_cast::<*DeclContext>(n));
        self._body_depth += 1;
        var out = ASTWriter::<EvalIfFolding>::transform_function_decl(n);
        self._body_depth -= 1;
        self._dcs.pop_back();
        self._drop_from_dc(static_cast::<*DeclContext>(n));
        return out;
    }

    fn transform_closure_expr(self, n: *ClosureExpr) -> *Expr {
        self._body_depth += 1;
        var out = ASTWriter::<EvalIfFolding>::transform_closure_expr(n);
        self._body_depth -= 1;
        return out;
    }

    // === the fold ===========================================================

    /// A file-scope or function-body `eval if`.
    fn transform_conditional_stmt(self, n: *ConditionalStmt) -> vec::<*Stmt> {
        if !n->is_eval { return ASTWriter::<EvalIfFolding>::transform_conditional_stmt(n); }
        if !self._choose(n) {
            if self._body_depth > 0 {
                // `if constexpr`: both branches stay, and are resolved and typed.
                return ASTWriter::<EvalIfFolding>::transform_conditional_stmt(n);
            }
            return self._one_stmt(n);   // reported; E stops before N.
        }
        var taken = self._taken;
        if self._body_depth == 0 { self._mark_dirty(self._dcs[self._dcs.size() - 1]); }
        var out = vec::<*Stmt>();
        if taken == &null { return out; }
        for var i: usize = 0; i < taken->body.size(); ++i {
            var rs = self.dyn()->transform_stmt(taken->body[i]);
            for var j: usize = 0; j < rs.size(); ++j { out.push_back(rs[j]); }
        }
        return out;
    }

    /// A module- or class-body `eval if` (the carrier holds it). An `eval
    /// for` there stays for FeatureGateCheck.
    fn transform_eval_block_decl(self, n: *EvalBlockDecl) -> vec::<*Decl> {
        if (n->stmt == &null) || (!isa::<ConditionalStmt>(n->stmt)) {
            return ASTWriter::<EvalIfFolding>::transform_eval_block_decl(n);
        }
        var c = cast::<ConditionalStmt>(n->stmt);
        if !self._choose(c) { return self._one_decl(n); }
        var taken = self._taken;
        self._mark_dirty(self._dcs[self._dcs.size() - 1]);
        var out = vec::<*Decl>();
        if taken == &null { return out; }
        for var i: usize = 0; i < taken->body.size(); ++i {
            var rs = self.dyn()->transform_stmt(taken->body[i]);
            for var j: usize = 0; j < rs.size(); ++j {
                var ds = dyn_cast::<DeclStmt>(rs[j]);
                if (ds != &null) && (ds->decl != &null) { out.push_back(ds->decl); continue; }
                self._not_a_member(rs[j]);
            }
        }
        return out;
    }

    /// File scope: a hoisted declaration other than a variable is a Decl
    /// item, as the parser makes it, so the TU's dc_decls holds it.
    fn rebuild_toplevel_items(self, items: *ArenaList::<TopLevelItem>) {
        ASTWriter::<EvalIfFolding>::rebuild_toplevel_items(items);
        var buf = ArenaList::<TopLevelItem>();
        buf.set_allocator(&(self.ctx->ast_alloc));
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            if item.kind == TopLevelKind::Stmt {
                var ds = dyn_cast::<DeclStmt>(item.as_stmt());
                // Only a fold puts a non-variable DeclStmt at file scope: the
                // parser makes every other declaration a Decl item.
                if (ds != &null) && (ds->decl != &null) && (!isa::<VariableDecl>(ds->decl)) {
                    buf.push(TopLevelItem::from_decl(ds->decl));
                    continue;
                }
            }
            buf.push(item);
        }
        (*items) = buf;
    }

    /// Which branch \p n takes, into `_taken` (null: none). False when the
    /// condition does not fold; reported unless in a function body.
    priv fn _choose(self, n: *ConditionalStmt) -> bool {
        var c = n;
        var chosen: *CompoundStmt = &null;
        var found = false;
        while (c != &null) && (!found) {
            self._why      = "";
            self._why_at   = &null;
            self._why_decl = &null;
            var v = self._fold(c->cond, 0);
            if !v.ok {
                if self._body_depth == 0 { self._report(c); }
                return false;
            }
            if self._truth(v) {
                chosen = c->then_;
                found  = true;
                break;
            }
            if c->else_ == &null { break; }
            if isa::<ConditionalStmt>(c->else_) { c = cast::<ConditionalStmt>(c->else_); continue; }
            chosen = dyn_cast::<CompoundStmt>(c->else_);
            found  = true;
        }
        self._drop_untaken(static_cast::<*Stmt>(n), chosen);
        self._taken = chosen;
        return true;
    }

    priv fn _truth(self, v: FoldVal) -> bool {
        if v.is_int { return v.i.mag != u64(0); }
        return v.b;
    }

    priv fn _report(self, c: *ConditionalStmt) {
        var at = (self._why_at) if (self._why_at != &null) else (c->cond);
        var why = (self._why) if (self._why.size() > 0) else ("it is not a compile-time constant");
        var b = self.sc->diag->report(DiagID::SC001E, at->range.start,
            f"the condition of an 'eval if' outside a function body must fold before names are resolved; {why}");
        b.first(at->range);
        var vd = (dyn_cast::<VariableDecl>(self._why_decl)) if (self._why_decl != &null) else (&null);
        if vd != &null {
            var nm = self.ctx->get_spelling(vd->name);
            b.note(DiagID::SC001N, vd->name.range.start, f"'{nm}' is declared here").first(vd->name.range);
            // A `const` that folds is one keyword from usable (EVAL.md 3).
            if (vd->storage == StorageClass::Const) && (!vd->const_binding) && vd->storage_kw.is_valid() {
                b.fix(vd->storage_kw, "eval", f"declare '{nm}' as 'eval\x27");
            }
        }
        b.emit();
    }

    // === defined! ===========================================================

    /// Every `defined!` the preprocessor passed on, wherever it stands, is a
    /// bool literal from here on: nothing after this pass sees one.
    fn transform_defined_expr(self, n: *DefinedExpr) -> *Expr {
        var b = BooleanLiteralExpr::create(self.ctx, n->range, self._macro(n->name));
        return static_cast::<*Expr>(b);
    }

    /// Clang's answer for \p name (EVAL.md §4.3): the TU's HeaderSet when
    /// it has ffi headers (its preprocessor holds the target's predefines
    /// and every header's #defines), else the target's predefines alone.
    /// Kairo's own macros never get here: the preprocessor answered those.
    priv fn _macro(self, name: Token) -> bool {
        var nm = self.ctx->get_spelling(name);
        var tu = self.sc->tu;
        if tu->header_set != &null {
            var hs = reinterpret_cast::<*HeaderSet>(tu->header_set);
            if hs->alive() { return hs->macro_defined(nm); }
        }
        if self.sc->builtins != &null { return self.sc->builtins->macro_predefined(nm); }
        return false;
    }

    // === conditions =========================================================

    priv fn _no(self, at: *Expr, why: string) -> FoldVal {
        if self._why_at == &null {
            self._why_at = at;
            self._why    = why;
        }
        var v = FoldVal{};
        v.ok = false;
        return v;
    }

    priv fn _bool(self, b: bool) -> FoldVal {
        var v = FoldVal{};
        v.ok = true;
        v.is_int = false;
        v.b = b;
        return v;
    }

    priv fn _int(self, c: IntConst) -> FoldVal {
        var v = FoldVal{};
        v.ok = c.ok && (!c.overflow);
        v.is_int = true;
        v.i = c;
        return v;
    }

    priv fn _fold(self, e0: *Expr, depth: u32) -> FoldVal {
        if e0 == &null { return self._no(e0, "it is empty"); }
        var e = e0;
        while (e != &null) && isa::<ParenExpr>(e) { e = cast::<ParenExpr>(e)->inner; }
        if isa::<BooleanLiteralExpr>(e) { return self._bool(cast::<BooleanLiteralExpr>(e)->value); }
        if isa::<DefinedExpr>(e) { return self._bool(self._macro(cast::<DefinedExpr>(e)->name)); }
        if isa::<IntegerLiteralExpr>(e) {
            var r = self._ce.eval_int(e);
            if !r.ok { return self._no(e, "this literal has no value"); }
            return self._int(r);
        }
        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            var k = u->op_token.kind;
            var x = self._fold(u->operand, depth);
            if !x.ok { return x; }
            if (k == TokenKind::OpExclaim) || (k == TokenKind::KwNot) { return self._bool(!self._truth(x)); }
            if (k == TokenKind::OpMinus) && x.is_int { return self._int(self._ce.negate(x.i)); }
            if (k == TokenKind::OpPlus) && x.is_int { return x; }
            return self._no(e, f"'{self.ctx->get_spelling(u->op_token)}' does not fold here");
        }
        if isa::<BinaryOperatorExpr>(e) { return self._binary(cast::<BinaryOperatorExpr>(e), depth); }
        if isa::<NamedIdentExpr>(e) {
            var d = self._lookup(cast::<NamedIdentExpr>(e)->name, e);
            if d == &null { return self._no(e, self._why); }
            return self._ref(e, d, depth);
        }
        if isa::<ChainExpr>(e) {
            var d = self._chain(cast::<ChainExpr>(e));
            if d == &null { return self._no(e, "this name is not an 'eval' constant reachable here"); }
            return self._ref(e, d, depth);
        }
        if isa::<CallExpr>(e) { return self._no(e, "a call is computed by C++ after names are resolved; use an 'eval' constant, a literal or 'defined!' here"); }
        return self._no(e, "this does not fold before names are resolved");
    }

    priv fn _binary(self, b: *BinaryOperatorExpr, depth: u32) -> FoldVal {
        var e = static_cast::<*Expr>(b);
        var k = b->op_token.kind;
        var l = self._fold(b->lhs, depth);
        if !l.ok { return l; }
        if (k == TokenKind::OpAmpAmp) || (k == TokenKind::KwAnd) {
            if !self._truth(l) { return self._bool(false); }
            var r = self._fold(b->rhs, depth);
            if !r.ok { return r; }
            return self._bool(self._truth(r));
        }
        if (k == TokenKind::OpPipePipe) || (k == TokenKind::KwOr) {
            if self._truth(l) { return self._bool(true); }
            var r = self._fold(b->rhs, depth);
            if !r.ok { return r; }
            return self._bool(self._truth(r));
        }
        var r = self._fold(b->rhs, depth);
        if !r.ok { return r; }
        if (k == TokenKind::OpEqualEqual) || (k == TokenKind::OpExclaimEqual) {
            var eq = false;
            if l.is_int && r.is_int { eq = self._cmp(l.i, r.i) == 0; }
            else if (!l.is_int) && (!r.is_int) { eq = l.b == r.b; }
            else { return self._no(e, "it compares a bool with an integer"); }
            return self._bool((eq) if (k == TokenKind::OpEqualEqual) else (!eq));
        }
        if (!l.is_int) || (!r.is_int) { return self._no(e, f"'{self.ctx->get_spelling(b->op_token)}' needs integer operands"); }
        if k == TokenKind::OpLess         { return self._bool(self._cmp(l.i, r.i) < 0); }
        if k == TokenKind::OpLessEqual    { return self._bool(self._cmp(l.i, r.i) <= 0); }
        if k == TokenKind::OpGreater      { return self._bool(self._cmp(l.i, r.i) > 0); }
        if k == TokenKind::OpGreaterEqual { return self._bool(self._cmp(l.i, r.i) >= 0); }
        if k == TokenKind::OpPlus  { return self._int(self._ce.add(l.i, r.i)); }
        if k == TokenKind::OpMinus { return self._int(self._ce.sub(l.i, r.i)); }
        if k == TokenKind::OpStar  { return self._int(self._ce.mul(l.i, r.i)); }
        if (k == TokenKind::OpPipe)  || (k == TokenKind::KwBitor)  { return self._int(self._ce.bitop(l.i, r.i, u8(0))); }
        if (k == TokenKind::OpAmp)   || (k == TokenKind::KwBitand) { return self._int(self._ce.bitop(l.i, r.i, u8(1))); }
        if (k == TokenKind::OpCaret) || (k == TokenKind::KwXor)    { return self._int(self._ce.bitop(l.i, r.i, u8(2))); }
        if k == TokenKind::OpLessLess       { return self._int(self._ce.shl(l.i, r.i)); }
        if k == TokenKind::OpGreaterGreater { return self._int(self._ce.shr(l.i, r.i)); }
        return self._no(e, f"'{self.ctx->get_spelling(b->op_token)}' does not fold here");
    }

    /// -1, 0, 1 as \p a is below, equal to, above \p b.
    priv fn _cmp(self, a: IntConst, b: IntConst) -> i32 {
        if a.neg != b.neg { return (i32(-1)) if (a.neg) else (i32(1)); }
        if a.mag == b.mag { return 0; }
        var below = a.mag < b.mag;
        if a.neg { below = !below; }
        return (i32(-1)) if (below) else (i32(1));
    }

    /// An `eval` variable or field: its initializer, folded where IT stands.
    priv fn _ref(self, at: *Expr, d: *Decl, depth: u32) -> FoldVal {
        if depth > 16 { return self._no(at, "its initializer refers back to itself"); }
        var init: *Expr = &null;
        var nm = "";
        var vd = dyn_cast::<VariableDecl>(d);
        var fd = dyn_cast::<FieldDecl>(d);
        if vd != &null {
            nm = self.ctx->get_spelling(vd->name);
            if !vd->is_eval() {
                if self._why_at == &null { self._why_decl = d; }
                return self._no(at, f"'{nm}' is not an 'eval' constant");
            }
            init = vd->init;
        } else if fd != &null {
            nm = self.ctx->get_spelling(fd->name);
            if !fd->is_eval() { return self._no(at, f"'{nm}' is not an 'eval' constant"); }
            init = fd->init;
        } else {
            return self._no(at, "this name is not an 'eval' constant");
        }
        if init == &null { return self._no(at, f"'{nm}' has no initializer"); }
        var home = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if home != &null { self._dcs.push_back(home); }
        var v = self._fold(init, depth + 1);
        if home != &null { self._dcs.pop_back(); }
        if !v.ok {
            self._why_at = at;
            self._why    = f"the initializer of '{nm}' does not fold: {self._why}";
        }
        return v;
    }

    /// \p tok looked up from the innermost scope, as N would, skipping what
    /// this pass discarded. A body local is in no table, so it is not found.
    priv fn _lookup(self, tok: Token, at: *Expr) -> *Decl {
        var nm  = self.ctx->get_spelling(tok);
        var imm = self.ctx->get_ident_imm(tok);
        if imm == u32(-1) { self._why = f"'{nm}' is not a name"; return &null; }
        var dc = self._dcs[self._dcs.size() - 1];
        var r  = self.sc->lookup.unqualified(dc, DeclName::ident(imm));
        if !r.found() {
            self._why = f"'{nm}' is not an 'eval' constant declared outside a function body";
            return &null;
        }
        return self._one_live(r.cell, nm);
    }

    priv fn _one_live(self, cell: *OverloadCell, nm: string) -> *Decl {
        var hit: *Decl = &null;
        for var i: usize = 0; i < cell->size(); ++i {
            var d = cell->get(i);
            if (d == &null) || self._is_dropped(d) { continue; }
            if hit != &null {
                self._why = f"'{nm}' names more than one declaration";
                return &null;
            }
            hit = d;
        }
        if hit == &null { self._why = f"'{nm}' is declared only in a branch that is not taken"; }
        return hit;
    }

    /// `m::K`: the head looked up, then each `::` step in the scope before it.
    priv fn _chain(self, ch: *ChainExpr) -> *Decl {
        if (ch->base == &null) || (!isa::<NamedIdentExpr>(ch->base)) { return &null; }
        var d = self._lookup(cast::<NamedIdentExpr>(ch->base)->name, ch->base);
        for var i: usize = 0; i < ch->steps.size(); ++i {
            var st = ch->steps.get(i);
            if (d == &null) || (st->access_kind != ChainExpr::AccessKind::ColonColon) || (st->name == &null) { return &null; }
            var imm = self.ctx->get_ident_imm(st->name->name);
            if imm == u32(-1) { return &null; }
            var nm      = self.ctx->get_spelling(st->name->name);
            var scopes  = vec::<*DeclContext>();
            if isa::<ModuleDecl>(d) { NameLookup::module_scopes(d, scopes); }
            else {
                var sdc = NameLookup::context_of(d);
                if sdc != &null { scopes.push_back(sdc); }
            }
            var next: *Decl = &null;
            for var k: usize = 0; k < scopes.size(); ++k {
                var r = self.sc->lookup.in_context(scopes[k], DeclName::ident(imm), nm);
                if !r.found() { continue; }
                var one = self._one_live(r.cell, nm);
                if one == &null { continue; }
                if next != &null { return &null; }
                next = one;
            }
            d = next;
        }
        return d;
    }

    // === discarding =========================================================

    /// Every declaration in \p s's branches other than \p keep, nested
    /// `eval if`s included.
    priv fn _drop_untaken(self, s: *Stmt, keep: *CompoundStmt) {
        if s == &null { return; }
        if isa::<ConditionalStmt>(s) {
            var c = cast::<ConditionalStmt>(s);
            if c->then_ != keep { self._drop_all(static_cast::<*Stmt>(c->then_)); }
            if c->else_ == &null { return; }
            if isa::<ConditionalStmt>(c->else_) { self._drop_untaken(c->else_, keep); return; }
            if c->else_ != static_cast::<*Stmt>(keep) { self._drop_all(c->else_); }
        }
    }

    priv fn _drop_all(self, s: *Stmt) {
        if s == &null { return; }
        if isa::<DeclStmt>(s) {
            var d = cast::<DeclStmt>(s)->decl;
            if d != &null { self._dropped.push_back(d); }
            return;
        }
        if isa::<CompoundStmt>(s) {
            var b = cast::<CompoundStmt>(s);
            for var i: usize = 0; i < b->body.size(); ++i { self._drop_all(b->body[i]); }
            return;
        }
        if isa::<ConditionalStmt>(s) {
            var c = cast::<ConditionalStmt>(s);
            self._drop_all(static_cast::<*Stmt>(c->then_));
            self._drop_all(c->else_);
        }
    }

    priv fn _is_dropped(self, d: *Decl) -> bool {
        for var i: usize = 0; i < self._dropped.size(); ++i { if self._dropped[i] == d { return true; } }
        return false;
    }

    priv fn _mark_dirty(self, dc: *DeclContext) {
        if dc == &null { return; }
        for var i: usize = 0; i < self._dirty.size(); ++i { if self._dirty[i] == dc { return; } }
        self._dirty.push_back(dc);
    }

    /// The untaken branches' local fns and classes leave \p dc's list
    /// (StmtParse::_attach_local_decl put every branch's there).
    priv fn _drop_from_dc(self, dc: *DeclContext) {
        if self._dropped.size() == 0 { return; }
        var any = false;
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            if self._is_dropped(*(dc->dc_decls.get(i))) { any = true; break; }
        }
        if !any { return; }
        var buf = ArenaList::<*Decl>();
        buf.set_allocator(&(self.ctx->ast_alloc));
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if (d == &null) || self._is_dropped(d) { continue; }
            buf.push(d);
        }
        dc->dc_decls = buf;
    }

    // === class members ======================================================

    /// A class branch's statements were spliced into the class's dc_decls:
    /// a `var` becomes a FieldDecl at the end of `fields`, a `fn` joins
    /// `methods`; nested types stay in dc_decls, where the parser keeps them.
    priv fn _members_from_branches(self, owner: *Decl, fields: *FrozenList::<*FieldDecl>, methods: *FrozenList::<*FunctionDecl>) {
        var dc = NameLookup::context_of(owner);
        if dc == &null { return; }
        var moved = false;
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if (d != &null) && (isa::<VariableDecl>(d) || isa::<FunctionDecl>(d)) { moved = true; break; }
        }
        if !moved { return; }

        var fb = ArenaList::<*FieldDecl>();
        fb.set_allocator(&(self.ctx->ast_alloc));
        for var i: usize = 0; i < fields->size(); ++i { fb.push((*fields)[i]); }
        var mb = ArenaList::<*FunctionDecl>();
        mb.set_allocator(&(self.ctx->ast_alloc));
        for var i: usize = 0; i < methods->size(); ++i { mb.push((*methods)[i]); }
        var rest = ArenaList::<*Decl>();
        rest.set_allocator(&(self.ctx->ast_alloc));

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            if isa::<FunctionDecl>(d) { mb.push(cast::<FunctionDecl>(d)); continue; }
            if isa::<VariableDecl>(d) {
                var f = self._as_field(cast::<VariableDecl>(d), u32(fb.size()));
                if f != &null { fb.push(f); }
                continue;
            }
            rest.push(d);
        }
        fields->from_list(&fb, &(self.ctx->ast_alloc));
        methods->from_list(&mb, &(self.ctx->ast_alloc));
        dc->dc_decls = rest;
    }

    /// The FieldDecl a class branch's `var` / `eval` / `static` binding is.
    /// A field declares its type (variables.mdx), so one without is an error.
    priv fn _as_field(self, vd: *VariableDecl, index: u32) -> *FieldDecl {
        if vd->type_ == &null {
            var nm = self.ctx->get_spelling(vd->name);
            var b = self.sc->diag->report(DiagID::SC001E, vd->name.range.start,
                f"a field declares its type; '{nm}' has none");
            b.first(vd->name.range);
            b.emit();
            return &null;
        }
        var f = FieldDecl::create(self.ctx, vd->range, vd->name, vd->storage, vd->type_, index);
        f->init          = vd->init;
        f->is_thread     = vd->is_thread;
        f->const_binding = vd->const_binding;
        f->visibility    = vd->visibility;
        f->adopt_sema(static_cast::<*Decl>(vd));
        self._from.push_back(static_cast::<*Decl>(vd));
        self._to.push_back(static_cast::<*Decl>(f));
        return f;
    }

    priv fn _not_a_member(self, s: *Stmt) {
        if s == &null { return; }
        var b = self.sc->diag->report(DiagID::SC001E, s->range.start,
            "an 'eval if' in a module or class body holds declarations only");
        b.first(s->range);
        b.emit();
    }

    // === tables =============================================================

    /// \p dc's table without the discarded declarations, and with each class
    /// branch's VariableDecl replaced by its FieldDecl; frozen and swapped in.
    priv fn _rebuild_table(self, dc: *DeclContext) {
        var old = dc->dc_symbols;
        if old == &null { return; }
        var es = vec::<SymbolTable::Entry>();
        old->collect_entries(es);
        var nt = self.ctx->alloc_init_cleanup::<SymbolTable>(self.ctx);
        for var i: usize = 0; i < es.size(); ++i {
            var cell = es[i].cell;
            if cell == &null { continue; }
            for var k: usize = 0; k < cell->size(); ++k {
                var d = cell->get(k);
                if (d == &null) || self._is_dropped(d) { continue; }
                nt->append(es[i].name, self._mapped(d));
            }
        }
        nt->freeze();
        dc->set_symbols(nt);
        var tu = self.sc->tu;
        if (static_cast::<*DeclContext>(tu) == dc) && (tu->module_self != &null) {
            var ms = NameLookup::context_of(tu->module_self);
            if (ms != &null) && (ms->dc_symbols == old) { ms->set_symbols(nt); }
        }
    }

    priv fn _mapped(self, d: *Decl) -> *Decl {
        for var i: usize = 0; i < self._from.size(); ++i { if self._from[i] == d { return self._to[i]; } }
        return d;
    }

    /// Nothing to do in a TU with no `eval if` (the parser's flag): the
    /// common case costs no rewrite.
    priv fn _has_eval_if(self) -> bool {
        return self.sc->tu->has_eval_if;
    }
}
