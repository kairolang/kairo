/// --- The Kairo Project ---------------- Sema/Expand/EvalIfFolding.k --- ///
///
///   \brief `eval if` folded like `#if`: the untaken branches are discarded,
///          the taken branch's declarations are hoisted into the enclosing
///          scope -- before name resolution, or, for a declaration-scope
///          condition that reads a type fact, once types are resolved.
///
///   \detail
///     EVAL.md §4. One writer, two evaluators, two slots:
///
///       run()       first in phase E: after I (an imported `eval` constant
///                   is reachable through the overlay) and before V and N,
///                   so no later pass sees an untaken branch. Those may name
///                   what does not exist on this target; they are never
///                   resolved.
///       run_late()  EvalIfLateFolding, in the T stage right after
///                   TypeResolve and RedeclMerge, before InterfaceComposition,
///                   ConstraintExtraction and ChainBinding (EVAL.md 4.2b):
///                   the `eval if`s run() deferred (Type facts, below).
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
///     \par Type facts (EVAL.md 4.2b)
///       `sizeof`, `alignof`, `is_trivially_copyable!` and
///       `is_trivially_destructible!` -- directly, or in the initializer of
///       an `eval` constant the condition reads -- need resolved types, which
///       phase E does not have. At declaration scope such an `eval if` is
///       DEFERRED: it stays where it is with every branch indexed, marked
///       eval_deferred and filed in sc->eval_branches. Its branches are
///       walked now (a nested `eval if` that folds does, and every
///       `defined!` becomes its literal), a class branch's `var` becomes its
///       FieldDecl now (N then binds the field), and a branch may not
///       declare a type, which T would resolve before anything decides
///       whether it exists. A condition naming an `eval` constant that only
///       a deferred branch declares is deferred with it. N, T and
///       RedeclMerge see every branch; two declarations in sibling branches
///       never conflict (EvalBranchTable::exclusive). In a function body
///       nothing is deferred: the condition is C++'s `if constexpr`, which
///       clang decides with its own layouts.
///
///       run_late() answers the facts: `sizeof` / `alignof` from the layout
///       Sema predicts for the target (EnumLayoutQuery::size_of: builtins,
///       pointers, arrays, plain enums and plain records of them), the two
///       triviality facts from ClassLifecycle (facts_of_type_concrete). A
///       fact about a record whose own member set another deferred `eval if`
///       still decides -- or a name only such branches declare -- waits: the
///       walk repeats while a round folds something, the lifecycle memo is
///       forgotten after each round that changed a member set, and whatever
///       still waits when a round folds nothing is an error (two `eval if`s
///       that decide each other). Last, every name N bound to a declaration
///       the fold discarded is bound again to the one that survived under
///       that name (LateFoldRebind).
///
///   Phase: EXPAND (first), and RESOLVE (EvalIfLateFolding)
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
import Sema::Check::ClassLifecycle::*;
import Sema::Lower::EnumLayoutLowering::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import AST::Visitor::ASTWriter::*;
import AST::Visitor::RecursiveASTVisitor::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
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
    /// Not decided yet: a type fact E cannot answer, or (late) a fact or a
    /// name another deferred `eval if` still decides. `ok` is false with it;
    /// it is not a failure.
    var deferred: bool;
}

/// After the late fold (file header, Type facts): every name N bound to a
/// declaration the fold discarded is bound again, to the one that survived
/// under that name in that scope -- a sibling branch's -- or reported as
/// undeclared, which it now is. N bound such names before anything could
/// say which branch stays: `W` with `eval W` in both branches was a cell of
/// two (candidate_cell, into the table the fold replaced), and a name only
/// one branch declares was bound to it.
class LateFoldRebind derives RecursiveASTVisitor::<LateFoldRebind> {
    pub var sc: *SemaContext;
    priv var _dropped: *vec::<*Decl> = &null;

    fn LateFoldRebind(self, sc: *SemaContext, dropped: *vec::<*Decl>) {
        self.sc       = sc;
        self._dropped = dropped;
    }

    fn run(self) {
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

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if (n == &null) || n->is_poisoned() { return true; }
        if n->resolved_decl != &null {
            if self._gone(n->resolved_decl) { self._rebind(n, n->resolved_decl); }
            return true;
        }
        var cell = n->candidate_cell;
        if cell == &null { return true; }
        for var i: usize = 0; i < cell->size(); ++i {
            var d = cell->get(i);
            if (d != &null) && self._gone(d) {
                self._rebind(n, d);
                return true;
            }
        }
        return true;
    }

    priv fn _gone(self, d: *Decl) -> bool {
        for var i: usize = 0; i < self._dropped->size(); ++i { if (*self._dropped)[i] == d { return true; } }
        return false;
    }

    /// \p n's name looked up again in the scope \p was (a discarded
    /// declaration) was declared in: its new table holds the survivors only.
    /// One is bound as N binds one; several stay a cell, as N leaves an
    /// overload set; none is the undeclared name it now is.
    priv fn _rebind(self, n: *NamedIdentExpr, was: *Decl) {
        n->resolved_decl  = &null;
        n->candidate_cell = &null;
        var dc  = reinterpret_cast::<*DeclContext>(was->semantic_dc);
        var imm = self.sc->ctx->get_ident_imm(n->name);
        var nm  = self.sc->ctx->get_spelling(n->name);
        if (dc != &null) && (imm != u32(-1)) {
            var r = self.sc->lookup.in_context(dc, DeclName::ident(imm), nm);
            if r.single() {
                n->resolved_decl = NameLookup::representative(r.first());
                return;
            }
            if r.found() {
                n->candidate_cell = r.cell;
                return;
            }
        }
        var b = self.sc->diag->report(DiagID::R020E, n->range.start,
            f"use of undeclared identifier '{nm}\x27");
        b.first(n->range);
        b.note(DiagID::R001N, was->range.start,
            f"'{nm}' is declared only in a branch of an 'eval if' that is not taken").first(was->range);
        b.emit();
        n->poison();
    }
}

class EvalIfFolding derives ASTWriter::<EvalIfFolding> {
    pub var sc: *SemaContext;
    priv var _ce: ConstEval;
    priv var _tu: TypeUtil;

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
    /// The last lookup found only declarations a deferred `eval if` may
    /// still discard: the condition waits for it rather than fails.
    priv var _pending_name: bool = false;
    /// run_late(): the type facts are answered, not deferred.
    priv var _late: bool = false;
    /// The last late round: nothing may wait any more, so a wait is a
    /// failure, reported with its reason.
    priv var _force: bool = false;
    /// This late round folded something / left something waiting.
    priv var _progress: bool = false;
    priv var _waiting: bool = false;
    /// The failure _report is about is a fact about a type parameter
    /// (SC132E), not a condition that does not fold.
    priv var _dep: bool = false;
    /// Type-fact leaves the late fold has answered so far: _ref compares it
    /// around an initializer to know whether a constant read one (_pin).
    priv var _leaves: u32 = 0;

    fn EvalIfFolding(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
        self._ce = ConstEval(sc);
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        if self.sc->tu == &null { return; }
        if !self._has_eval_if() { return; }
        self._dcs.push_back(static_cast::<*DeclContext>(self.sc->tu));
        ASTWriter::<EvalIfFolding>::run(self.sc->tu);
        for var i: usize = 0; i < self._dirty.size(); ++i { self._rebuild_table(self._dirty[i]); }
    }

    /// EvalIfLateFolding (file header, Type facts). Each round walks the TU
    /// once and folds every deferred `eval if` it can answer; a round that
    /// folds nothing while something waits is followed by one last round
    /// that reports what waits.
    fn run_late(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if self.sc->eval_branches.pending() == 0 { return; }
        // An error above (an unresolved type in a condition, a redefinition)
        // stops the schedule at the end of this stage; folding over it would
        // only add a second error for the same mistake.
        if self.sc->errored() { return; }
        self._late = true;
        var folded = false;
        while true {
            self._progress = false;
            self._waiting  = false;
            self._dcs.clear();
            self._dcs.push_back(static_cast::<*DeclContext>(tu));
            ASTWriter::<EvalIfFolding>::run(tu);
            for var i: usize = 0; i < self._dirty.size(); ++i { self._rebuild_table(self._dirty[i]); }
            self._dirty.clear();
            // A member set changed: a fact computed this round about a record
            // that holds the folded one by value describes the old set.
            if self._progress {
                folded = true;
                lifecycle_of(self.sc)->forget_facts();
            }
            if (!self._waiting) || self._force { break; }
            if !self._progress { self._force = true; }
        }
        if folded {
            var rb = LateFoldRebind(self.sc, &(self._dropped));
            rb.run();
        }
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
        // The late fold decides declaration-scope `eval if`s only: a body's
        // was folded by E or is `if constexpr`.
        if self._late { return self._one_decl(n); }
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
        // The late fold decides only what E deferred.
        if self._late && (!n->eval_deferred) { return ASTWriter::<EvalIfFolding>::transform_conditional_stmt(n); }
        var r = self._choose(n);
        if r != 1 {
            if self._body_depth > 0 {
                // `if constexpr`: both branches stay, and are resolved and typed.
                return ASTWriter::<EvalIfFolding>::transform_conditional_stmt(n);
            }
            // A type fact (r == 2) waits; anything else was reported, and the
            // schedule stops at the end of this stage.
            if r == 2 { self._wait(n, self._record_of_top()); }
            return self._one_stmt(n);
        }
        var taken = self._taken;
        if self._body_depth == 0 { self._mark_dirty(self._dcs[self._dcs.size() - 1]); }
        else { self.sc->folded_eval_ifs.push_back(n->range); }
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
        if self._late && (!c->eval_deferred) { return self._one_decl(n); }
        var r = self._choose(c);
        if r != 1 {
            // A local class's (in a function body) is not deferred, as a
            // body's `eval if` is not: it stays, as it always did.
            if (r == 2) && (self._body_depth == 0) { self._wait(c, self._record_of_top()); }
            return self._one_decl(n);
        }
        var taken = self._taken;
        self._mark_dirty(self._dcs[self._dcs.size() - 1]);
        var out = vec::<*Decl>();
        if taken == &null { return out; }
        for var i: usize = 0; i < taken->body.size(); ++i {
            var rs = self.dyn()->transform_stmt(taken->body[i]);
            for var j: usize = 0; j < rs.size(); ++j {
                var ds = dyn_cast::<DeclStmt>(rs[j]);
                if (ds != &null) && (ds->decl != &null) { out.push_back(ds->decl); continue; }
                // A nested deferred `eval if` that still waits keeps a
                // carrier, as the parser gave it one, for the next round.
                var w = dyn_cast::<ConditionalStmt>(rs[j]);
                if (w != &null) && w->eval_deferred {
                    var carrier = EvalBlockDecl::create(self.ctx, w->range);
                    carrier->stmt = static_cast::<*Stmt>(w);
                    out.push_back(static_cast::<*Decl>(carrier));
                    continue;
                }
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

    /// Which branch \p n takes, into `_taken` (null: none). 1 when decided;
    /// 0 when the condition does not fold (reported, unless in a function
    /// body); 2 when it waits -- for the late fold (E), or for another
    /// deferred `eval if` (a late round). An else-if chain waits at its first
    /// link that does: an earlier link that folded false is seen again.
    priv fn _choose(self, n: *ConditionalStmt) -> i32 {
        var c = n;
        var chosen: *CompoundStmt = &null;
        var found = false;
        while (c != &null) && (!found) {
            self._why          = "";
            self._why_at       = &null;
            self._why_decl     = &null;
            self._pending_name = false;
            self._dep          = false;
            var v = self._fold(c->cond, 0);
            if v.deferred { return 2; }
            if !v.ok {
                if self._body_depth == 0 { self._report(c); }
                // Reported: what waits on it goes on (the error stops the run
                // anyway) rather than add a second error for one mistake. Not
                // in the last round, where each waiting one is reported itself.
                if self._late && (!self._force) { self.sc->eval_branches.retire(static_cast::<*Stmt>(n)); }
                return 0;
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
        if self._late {
            self.sc->eval_branches.retire(static_cast::<*Stmt>(n));
            self._progress = true;
        }
        return 1;
    }

    priv fn _truth(self, v: FoldVal) -> bool {
        if v.is_int { return v.i.mag != u64(0); }
        return v.b;
    }

    priv fn _report(self, c: *ConditionalStmt) {
        var at = (self._why_at) if (self._why_at != &null) else (c->cond);
        if self._dep {
            self._report_dependent(at);
            return;
        }
        var why = (self._why) if (self._why.size() > 0) else ("it is not a compile-time constant");
        var by_when = ("must fold once types are resolved") if (self._late) else ("must fold before names are resolved");
        var b = self.sc->diag->report(DiagID::SC001E, at->range.start,
            f"the condition of an 'eval if' outside a function body {by_when}; {why}");
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
        // A layout the late fold does not predict: in a function body the
        // same condition is C++'s `if constexpr`, which sees every layout.
        if self._late && (isa::<SizeOfExpr>(at) || isa::<AlignOfExpr>(at)) {
            b.note(DiagID::SC001N, at->range.start,
                "in a function body the same condition is 'if constexpr', which C++ decides with the layout it chooses").first(at->range);
        }
        b.emit();
    }

    /// SC132E (EVAL.md 4.2b, MONO.md §2): a generic is one C++ template for
    /// every instance, and C++ has no `if constexpr` at class scope, so the
    /// members of one cannot differ per instance. What can: a partial
    /// specialization per member set, chosen by a requires clause, which C++
    /// selects for each instance. The note spells it on the generic.
    priv fn _report_dependent(self, at: *Expr) {
        var b = self.sc->diag->report(DiagID::SC132E, at->range.start,
            "a declaration-scope 'eval if' cannot depend on a type parameter; select a type instead");
        b.first(at->range);
        var owner = self._generic_owner();
        if owner != &null {
            var nt = decl_name_tok(owner);
            var nm = self.ctx->get_spelling(nt);
            var ps = self._param_list(owner);
            var kw = ("struct") if (isa::<StructDecl>(owner)) else ("class");
            b.note(DiagID::SC132N, nt.range.start,
                f"declare '{kw} <{ps}> {nm}<{ps}> requires <condition>' once per member set: each a partial specialization of '{nm}' whose body holds that set").first(nt.range);
        }
        b.emit();
    }

    /// The innermost generic record around the `eval if` being reported.
    priv fn _generic_owner(self) -> *Decl {
        var i = self._dcs.size();
        while i > 0 {
            i -= 1;
            var dc = self._dcs[i];
            if (dc == &null) || (!dc->is_type_scope()) { continue; }
            var o = dc->owner_decl();
            if (o != &null) && (decl_generic_params(o).size() > 0) { return o; }
        }
        return &null;
    }

    /// `T, U`: \p d's generic parameters as written.
    priv fn _param_list(self, d: *Decl) -> string {
        var gps = decl_generic_params(d);
        var s = "";
        for var i: usize = 0; i < gps.size(); ++i {
            if i > 0 { s += ", "; }
            s += self.ctx->get_spelling(decl_name_tok(static_cast::<*Decl>(gps[i])));
        }
        return s;
    }

    // === deferred (file header, Type facts) =================================

    /// \p head waits: in E it is deferred and filed; in a late round it waits
    /// for the next one. \p record is the class or struct whose body holds
    /// it, or null.
    priv fn _wait(self, head: *ConditionalStmt, record: *Decl) {
        if self._late {
            self._waiting = true;
            return;
        }
        self._defer_node(head, record);
    }

    /// The class or struct whose body is the innermost scope, or null (file
    /// scope, a module body): where a branch's `var` is a field.
    priv fn _record_of_top(self) -> *Decl {
        var dc = self._dcs[self._dcs.size() - 1];
        if (dc == &null) || (!dc->is_type_scope()) { return &null; }
        var o = dc->owner_decl();
        if (o != &null) && (isa::<ClassDecl>(o) || isa::<StructDecl>(o)) { return o; }
        return &null;
    }

    /// E's half of a deferred `eval if` at declaration scope. Its branches
    /// are walked here because nothing else in E reaches them; a class's
    /// (\p record) become members' shapes now; then it is filed, so N(a),
    /// RedeclMerge and the late fold know which declarations exclude each
    /// other.
    priv fn _defer_node(self, head: *ConditionalStmt, record: *Decl) {
        self._walk_branches(head);
        if record != &null {
            self._fieldize(static_cast::<*Stmt>(head));
            self._mark_dirty(self._dcs[self._dcs.size() - 1]);
        }
        self._no_types(static_cast::<*Stmt>(head));
        head->eval_deferred = true;
        var at = self.sc->eval_branches.add_if(static_cast::<*Stmt>(head), self._dcs[self._dcs.size() - 1]);
        self._file_arms(at, static_cast::<*Stmt>(head));
    }

    /// Each link's condition and branch through this writer, but not the
    /// link itself: it is the deferred `eval if`, not a statement to fold.
    priv fn _walk_branches(self, head: *ConditionalStmt) {
        var c = head;
        while c != &null {
            if c->cond != &null { c->cond = self.dyn()->transform_expr(c->cond); }
            if c->then_ != &null { c->then_ = cast::<CompoundStmt>(self.dyn()->transform_stmt_scalar(c->then_)); }
            if c->else_ == &null { break; }
            if isa::<ConditionalStmt>(c->else_) { c = cast::<ConditionalStmt>(c->else_); continue; }
            c->else_ = self.dyn()->transform_stmt_scalar(c->else_);
            break;
        }
    }

    /// A class branch's `var`s become FieldDecls now, a nested `eval if`'s
    /// included: N binds the field, and the late fold hoists FieldDecls.
    /// Each is indexed when it joins `fields` (_members_from_branches).
    priv fn _fieldize(self, s: *Stmt) {
        if s == &null { return; }
        if isa::<ConditionalStmt>(s) {
            var c = cast::<ConditionalStmt>(s);
            self._fieldize(static_cast::<*Stmt>(c->then_));
            self._fieldize(c->else_);
            return;
        }
        if !isa::<CompoundStmt>(s) { return; }
        var b = cast::<CompoundStmt>(s);
        for var i: usize = 0; i < b->body.size(); ++i {
            var st = b->body[i];
            if st == &null { continue; }
            if isa::<ConditionalStmt>(st) { self._fieldize(st); continue; }
            if !isa::<DeclStmt>(st) { continue; }
            var ds = cast::<DeclStmt>(st);
            if (ds->decl == &null) || (!isa::<VariableDecl>(ds->decl)) { continue; }
            var f = self._as_field(cast::<VariableDecl>(ds->decl), u32(0));
            if f != &null { ds->decl = static_cast::<*Decl>(f); }
        }
    }

    /// A deferred branch may not declare a type: T resolves every name of
    /// one before the fold decides whether it exists, and a canonical type
    /// cannot be bound again to the survivor afterwards.
    priv fn _no_types(self, s: *Stmt) {
        if s == &null { return; }
        if isa::<ConditionalStmt>(s) {
            var c = cast::<ConditionalStmt>(s);
            self._no_types(static_cast::<*Stmt>(c->then_));
            self._no_types(c->else_);
            return;
        }
        if !isa::<CompoundStmt>(s) { return; }
        var b = cast::<CompoundStmt>(s);
        for var i: usize = 0; i < b->body.size(); ++i {
            var st = b->body[i];
            if st == &null { continue; }
            if isa::<ConditionalStmt>(st) { self._no_types(st); continue; }
            if !isa::<DeclStmt>(st) { continue; }
            var d = cast::<DeclStmt>(st)->decl;
            if d == &null { continue; }
            var is_type = isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d) || isa::<EnumDecl>(d);
            if isa::<InterfaceDecl>(d) || isa::<TypeAliasDecl>(d) || isa::<ModuleDecl>(d) { is_type = true; }
            if !is_type { continue; }
            var tok = decl_name_tok(d);
            var at  = (tok.range) if (tok.range.is_valid()) else (d->range);
            var nm  = (self.ctx->get_spelling(tok)) if (tok.range.is_valid()) else ("this type");
            var bld = self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{nm}' is declared in an 'eval if' whose condition reads a type fact; such a condition is decided after types are resolved, so its branches may declare only functions, constants and fields");
            bld.first(at);
            bld.emit();
        }
    }

    /// Every declaration under each branch of \p head (filed at \p at), a
    /// nested `eval if`'s included: one row per (declaration, branch).
    priv fn _file_arms(self, at: usize, head: *Stmt) {
        var c = cast::<ConditionalStmt>(head);
        while c != &null {
            self._file_decls(at, static_cast::<*Stmt>(c->then_), static_cast::<*Stmt>(c->then_));
            if c->else_ == &null { break; }
            if isa::<ConditionalStmt>(c->else_) { c = cast::<ConditionalStmt>(c->else_); continue; }
            self._file_decls(at, c->else_, c->else_);
            break;
        }
    }

    priv fn _file_decls(self, at: usize, arm: *Stmt, s: *Stmt) {
        if s == &null { return; }
        if isa::<DeclStmt>(s) {
            var d = cast::<DeclStmt>(s)->decl;
            if d != &null { self.sc->eval_branches.add_decl(at, arm, d); }
            return;
        }
        if isa::<CompoundStmt>(s) {
            var b = cast::<CompoundStmt>(s);
            for var i: usize = 0; i < b->body.size(); ++i { self._file_decls(at, arm, b->body[i]); }
            return;
        }
        if isa::<ConditionalStmt>(s) {
            var c = cast::<ConditionalStmt>(s);
            self._file_decls(at, arm, static_cast::<*Stmt>(c->then_));
            self._file_decls(at, arm, c->else_);
        }
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

    /// Not decided yet (FoldVal::deferred). In the last late round (_force)
    /// nothing may wait any more: it is a failure, with \p why.
    priv fn _defer(self, at: *Expr, why: string) -> FoldVal {
        if self._force { return self._no(at, why); }
        var v = FoldVal{};
        v.ok       = false;
        v.deferred = true;
        return v;
    }

    /// A combination one of whose operands waits: it waits too.
    priv fn _waits(self) -> FoldVal {
        var v = FoldVal{};
        v.ok       = false;
        v.deferred = true;
        return v;
    }

    /// A lookup that found nothing usable: it waits when what it found is a
    /// deferred `eval if`'s to keep or discard (_one_live), else it fails.
    priv fn _no_or_wait(self, at: *Expr) -> FoldVal {
        if self._pending_name {
            self._pending_name = false;
            return self._defer(at, self._why);
        }
        return self._no(at, self._why);
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
            if d == &null { return self._no_or_wait(e); }
            return self._ref(e, d, depth);
        }
        if isa::<ChainExpr>(e) {
            var d = self._chain(cast::<ChainExpr>(e));
            if d == &null {
                if self._pending_name { return self._no_or_wait(e); }
                return self._no(e, "this name is not an 'eval' constant reachable here");
            }
            return self._ref(e, d, depth);
        }
        if isa::<CallExpr>(e) { return self._no(e, "a call is computed by C++ after names are resolved; use an 'eval' constant, a literal or 'defined!' here"); }
        // EVAL.md 4.2b: a type fact. E cannot answer one (types are not
        // resolved), so the `eval if` waits for the late fold, which can.
        if isa::<SizeOfExpr>(e) || isa::<AlignOfExpr>(e) {
            if !self._late { return self._defer(e, ""); }
            var is_size = isa::<SizeOfExpr>(e);
            var ta = (cast::<SizeOfExpr>(e)->type_arg) if (is_size) else (cast::<AlignOfExpr>(e)->type_arg);
            return self._layout_fact(e, ta, is_size);
        }
        if isa::<TypeTraitExpr>(e) {
            if !self._late { return self._defer(e, ""); }
            return self._trait_fact(cast::<TypeTraitExpr>(e));
        }
        return self._no(e, "this does not fold before names are resolved");
    }

    priv fn _binary(self, b: *BinaryOperatorExpr, depth: u32) -> FoldVal {
        var e = static_cast::<*Expr>(b);
        var k = b->op_token.kind;
        var l = self._fold(b->lhs, depth);
        // A failure decides; a side that waits does not, unless the other
        // side fails (reported now) or settles `&&` / `||` by itself.
        if (!l.ok) && (!l.deferred) { return l; }
        if (k == TokenKind::OpAmpAmp) || (k == TokenKind::KwAnd) {
            if l.ok && (!self._truth(l)) { return self._bool(false); }
            var r = self._fold(b->rhs, depth);
            if (!r.ok) && (!r.deferred) { return r; }
            if r.ok && (!self._truth(r)) { return self._bool(false); }
            if l.deferred || r.deferred { return self._waits(); }
            return self._bool(self._truth(r));
        }
        if (k == TokenKind::OpPipePipe) || (k == TokenKind::KwOr) {
            if l.ok && self._truth(l) { return self._bool(true); }
            var r = self._fold(b->rhs, depth);
            if (!r.ok) && (!r.deferred) { return r; }
            if r.ok && self._truth(r) { return self._bool(true); }
            if l.deferred || r.deferred { return self._waits(); }
            return self._bool(self._truth(r));
        }
        var r = self._fold(b->rhs, depth);
        if (!r.ok) && (!r.deferred) { return r; }
        if l.deferred || r.deferred { return self._waits(); }
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

    // === type facts (late) ==================================================

    /// `sizeof` / `alignof` of \p ta, from the layout Sema predicts for the
    /// types whose layout is target arithmetic (EnumLayoutQuery::size_of).
    /// Any other layout is C++'s to choose, so a declaration-scope
    /// condition cannot read it.
    priv fn _layout_fact(self, e: *Expr, ta: *Type, is_size: bool) -> FoldVal {
        var kw = ("sizeof") if (is_size) else ("alignof");
        if (ta == &null) || (ta->canonical == &null) { return self._no(e, f"the type of this '{kw}' is not resolved"); }
        var c = ta->canonical;
        if c->is_dependent() || c->is_instantiation_dependent() { return self._dependent_fact(e); }
        var held = self._held_by_pending(c, u32(0));
        if held != &null { return self._defer(e, self._held_why(held)); }
        var q = EnumLayoutQuery(self.sc);
        var sz: u64 = 0;
        var al: u64 = 0;
        if !q.size_of(ta, &sz, &al) {
            var tn = self._tu.str(c);
            return self._no(e, f"the layout of '{tn}' is C++'s to choose: a declaration-scope condition reads only the layout of builtins, pointers, arrays, and plain enums and records of them");
        }
        self._leaves += 1;
        return self._int(self._ce.make(false, (sz) if (is_size) else (al)));
    }

    /// `is_trivially_copyable!` / `is_trivially_destructible!` of a concrete
    /// type: ClassLifecycle's facts, which C++'s builtins agree with.
    priv fn _trait_fact(self, n: *TypeTraitExpr) -> FoldVal {
        var e  = static_cast::<*Expr>(n);
        var ta = n->type_arg;
        if (ta == &null) || (ta->canonical == &null) { return self._no(e, "the type of this fact is not resolved"); }
        var c = ta->canonical;
        if c->is_dependent() || c->is_instantiation_dependent() { return self._dependent_fact(e); }
        var held = self._held_by_pending(c, u32(0));
        if held != &null { return self._defer(e, self._held_why(held)); }
        var f = lifecycle_of(self.sc)->facts_of_type_concrete(c, "EvalIfLateFolding");
        var t = (f.trivially_copyable) if (n->fact == TypeTraitKind::TriviallyCopyable) else (f.trivial_dtor);
        if t == LifecycleTri::Unknown {
            return self._no(e, f"'{self._tu.str(c)}' has no answer to this before it is instantiated");
        }
        var yes = t == LifecycleTri::Yes;
        // --test-fold-lie: read the fact inverted, as a LifecycleFacts bug
        // would, so a test can show the pin (_pin) failing the build.
        if self.sc->opts.test_fold_lie { yes = !yes; }
        self._leaves += 1;
        return self._bool(yes);
    }

    /// A fact about a type parameter: one answer per instance, while a
    /// declaration-scope `eval if` chooses members once for all of them.
    priv fn _dependent_fact(self, e: *Expr) -> FoldVal {
        if self._why_at == &null { self._dep = true; }
        return self._no(e, "it depends on a type parameter, and the members it chooses are the same for every instance");
    }

    /// The record whose member set a still-deferred `eval if` decides, when
    /// \p t's facts or layout read it: \p t itself, or a record it holds by
    /// value (field, base, array element, type argument). Null when none
    /// does. A pointer stops the walk: what it points at is no part of the
    /// fact. Very deep by-value nesting is cut off and reads as held, which
    /// only costs a wait (and a report if nothing else ever folds).
    priv fn _held_by_pending(self, t: *Type, depth: u32) -> *Decl {
        if t == &null { return &null; }
        var c = canon_unqual(t);
        if c == &null { return &null; }
        if isa::<FixedArrayType>(c) { return self._held_by_pending(cast::<FixedArrayType>(c)->element, depth + 1); }
        if !isa::<RecordType>(c) { return &null; }
        var d = cast::<RecordType>(c)->decl;
        if d == &null { return &null; }
        var body = NameLookup::representative(self._tu.pattern_of(d));
        if body == &null { return &null; }
        if depth > u32(32) { return body; }
        if self.sc->eval_branches.pending_in(NameLookup::context_of(body)) { return body; }
        var args = self._tu.record_args(c);
        for var i: usize = 0; i < args.size(); ++i {
            var h = self._held_by_pending(*(args.get(i)), depth + 1);
            if h != &null { return h; }
        }
        var cd = dyn_cast::<ClassDecl>(body);
        if cd != &null {
            for var i: usize = 0; i < cd->derives_list.size(); ++i {
                var be = cd->derives_list.get(i);
                if (be == &null) || (be->base == &null) { continue; }
                var h = self._held_by_pending(be->base->canonical, depth + 1);
                if h != &null { return h; }
            }
        }
        var fields: *FrozenList::<*FieldDecl> = &null;
        if cd != &null { fields = &(cd->fields); }
        else if isa::<StructDecl>(body) { fields = &(cast::<StructDecl>(body)->fields); }
        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var fd = (*fields)[i];
                if (fd == &null) || fd->is_static() || (fd->type_ == &null) { continue; }
                var h = self._held_by_pending(fd->type_->canonical, depth + 1);
                if h != &null { return h; }
            }
        }
        var en = dyn_cast::<EnumDecl>(body);
        if en != &null {
            for var i: usize = 0; i < en->variants.size(); ++i {
                var v = en->variants[i];
                if v == &null { continue; }
                for var j: usize = 0; j < v->payload.size(); ++j {
                    var pf = v->payload[j];
                    if (pf == &null) || (pf->type_ == &null) { continue; }
                    var h = self._held_by_pending(pf->type_->canonical, depth + 1);
                    if h != &null { return h; }
                }
            }
        }
        return &null;
    }

    priv fn _held_why(self, d: *Decl) -> string {
        return f"it reads the members of '{self._tu.decl_name(d)}', which an 'eval if' that is not decided yet chooses";
    }

    /// \p d's value as this fold read it through a type fact, for codegen to
    /// assert against clang's (VariableDecl::fold_pin, EVAL.md 4.2b): a
    /// disagreement then fails the build instead of Kairo keeping a branch
    /// C++ would not. This TU's constants only: another TU's definition is
    /// not written here, and its own late fold pins what it read.
    priv fn _pin(self, d: *Decl, v: FoldVal) {
        var home = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if home == &null { return; }
        if static_cast::<*DeclContext>(NameLookup::tu_of(home)) != static_cast::<*DeclContext>(self.sc->tu) { return; }
        var k = u8(1);
        if v.is_int { k = u8(3); }
        else if v.b { k = u8(2); }
        var vd = dyn_cast::<VariableDecl>(d);
        var fd = dyn_cast::<FieldDecl>(d);
        if vd != &null {
            vd->fold_pin     = k;
            vd->fold_pin_neg = v.i.neg;
            vd->fold_pin_mag = v.i.mag;
        }
        if fd != &null {
            fd->fold_pin     = k;
            fd->fold_pin_neg = v.i.neg;
            fd->fold_pin_mag = v.i.mag;
        }
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
        var leaves = self._leaves;
        var v = self._fold(init, depth + 1);
        if home != &null { self._dcs.pop_back(); }
        if (!v.ok) && (!v.deferred) {
            self._why_at = at;
            self._why    = f"the initializer of '{nm}' does not fold: {self._why}";
        }
        // A type fact went into this value: codegen pins it (_pin).
        if self._late && v.ok && (self._leaves != leaves) { self._pin(d, v); }
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

    /// The one declaration of \p cell this pass has not discarded. When
    /// every one left sits in a branch of an `eval if` that is not decided
    /// yet, which of them exists is that `eval if`'s to say: null, with
    /// _pending_name set, so the condition waits for it.
    priv fn _one_live(self, cell: *OverloadCell, nm: string) -> *Decl {
        var hit: *Decl = &null;
        var n: usize = 0;
        var waiting = true;
        for var i: usize = 0; i < cell->size(); ++i {
            var d = cell->get(i);
            if (d == &null) || self._is_dropped(d) { continue; }
            n += 1;
            if !self.sc->eval_branches.in_pending(d) { waiting = false; }
            hit = d;
        }
        if (n > 0) && waiting {
            self._pending_name = true;
            self._why = f"'{nm}' is declared in a branch of an 'eval if' that is not decided yet";
            return &null;
        }
        if n > 1 {
            self._why = f"'{nm}' names more than one declaration";
            return &null;
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
            // A deferred `eval if` in a discarded branch goes with it and
            // decides nothing any more.
            self.sc->eval_branches.retire(s);
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
    /// a `var` becomes a FieldDecl at the end of `fields` (a deferred
    /// branch's already is one, _fieldize), a `fn` joins `methods`; nested
    /// types stay in dc_decls, where the parser keeps them.
    priv fn _members_from_branches(self, owner: *Decl, fields: *FrozenList::<*FieldDecl>, methods: *FrozenList::<*FunctionDecl>) {
        var dc = NameLookup::context_of(owner);
        if dc == &null { return; }
        var moved = false;
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if (d != &null) && (isa::<VariableDecl>(d) || isa::<FunctionDecl>(d) || isa::<FieldDecl>(d)) { moved = true; break; }
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
            if isa::<FieldDecl>(d) {
                var fd = cast::<FieldDecl>(d);
                fd->index = u32(fb.size());
                fb.push(fd);
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
