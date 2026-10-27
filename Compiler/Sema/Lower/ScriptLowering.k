/// --- The Kairo Project ---------------------- Sema/Lower/ScriptLowering.k --- ///
///
///   \brief A root file with top-level statements and no `fn main` is a
///          script: its statements become the body of a synthesized
///          `fn main() -> i32`, and the bindings among them stay globals.
///
///   \detail
///     SCRIPT.md holds the design; in short:
///
///       var cfg = load()          ->  var cfg: Config? = null      (global)
///       print(cfg.name)               fn main() -> i32 {
///       return                            finally { cfg = null }
///                                         cfg = load()
///                                         print(cfg.name)   // a narrowed read
///                                         return 0
///                                     }
///
///     A top-level binding (`var`, `const`, `static`, `thread`, `eval`) is a
///     GLOBAL, never a local of main: a function in the file names it. Its
///     initializer runs where it is written only when that order is
///     observable: a constant one (a literal, an integer ConstEval folds)
///     stays the C++ static initializer, `eval` is always constant, and a
///     `thread` one keeps C++'s per-thread first-use initialization. Every
///     other one is DEFERRED: its storage becomes `T?` (the Nullable lang
///     item), null until main assigns it at the statement's position.
///
///     Reads of a deferred global:
///
///       in main, after its line    a read marked narrowed, as NullnessFlow
///                                  marks a proven one (NarrowedAccessLowering
///                                  makes it `g.__value()`): no check, the
///                                  order of main's own statements proves it;
///       in main, at or before it   a compile error (SC001E): main's
///                                  statements run in order, so the read is
///                                  of a value that does not exist yet;
///       anywhere else              CHECKED: `*({ if !g? { unwrap_failed(m,
///                                  n) } &g })`, the `unwrap!` place form
///                                  (CoalesceLowering), aborting with
///                                  "script variable 'g' used before its line
///                                  ran (file:line)". In every build mode: the
///                                  call graph cannot prove the order.
///
///     A whole-object `g = e` statement is a write of the storage, not a
///     read, wherever it is: `T -> T?` converts. A direct call from main,
///     made before g's line, of a function in this file whose body reads g
///     on every path is the same compile error as a read in main.
///
///     Destruction: main's first statement is one `finally` that sets every
///     deferred global back to null in REVERSE declaration order, so the
///     values are destroyed at main's exit, last-constructed first, on every
///     exit (FinallyLowering). A top-level `return` returns from main; a
///     bare one, and the end of the file, return 0.
///
///     Errors (placeholder codes until the monthly sweep): a top-level
///     statement in a file that is not the root (an imported module), or in
///     a root file that also has `fn main`; a read before its line; a
///     deferred binding whose own type is nullable (its storage would be a
///     `(T?)?` whose reads carry two marks, which NarrowedAccessLowering does
///     not take yet); a top-level destructuring; a `return` whose value is no
///     integer. A redeclaration (`var x` and `static x` at file scope) never
///     reaches here: NameResolution reports it (R029E) and the pipeline stops.
///
///     Which file is a script, and which initializers are constant, is
///     ScriptRules' answer (Sema/Check/ScriptRules.k), shared with the
///     checks that ask the same of the tree before this pass runs.
///
///   Phase: LOWER, between CopyMoveLowering and FinallyLowering. The root
///   is the driver's (SemaContext::script_root). After CopyMoveLowering, so
///   the `e as T&&` it stamped on a moved initializer is carried into main
///   with the initializer. Before FinallyLowering, which lowers the
///   `finally` this pass mints. Before the nullable block: NullTestLowering
///   lowers the `g?` tests, NarrowedAccessLowering the marked reads, and
///   NullableTypeLowering gives every `T?` minted here its record, since it
///   walks the canonical table when it runs.
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
import Sema::Check::ScriptRules::*;
import Sema::Resolve::NameLookup::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::Visitor::RecursiveASTVisitor::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Mixin::Annotation::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import AST::Kind::DeclKind::*;
import Memory::ArenaList::*;
import Diagnostic::Registry::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

/// One read of a variable, or one direct call of a function, that
/// ScriptUseScan saw. \p definite: reached on every path through the walked
/// code (no branch, loop or closure above it, and no exit before it).
struct ScriptUse {
    var decl:     *Decl       = &null;
    var range:    SourceRange = SourceRange::invalid();
    var definite: bool        = false;
}

/// The reads and direct calls in one subtree, written nowhere. What the
/// read-before-init check asks of a statement of main (its calls) and of a
/// callee's body (its definite reads). Conservative toward NO error: a read
/// that might not run is not definite, so a function that reads a global
/// only on some path is left to the runtime guard.
class ScriptUseScan derives RecursiveASTVisitor::<ScriptUseScan> {
    pub var reads: vec::<ScriptUse>;
    pub var calls: vec::<ScriptUse>;
    priv var _tu:      TypeUtil;
    priv var _cond:    u32  = 0;       ///< branches, loops and short-circuits above the cursor.
    priv var _closure: u32  = 0;       ///< closure bodies above the cursor: they run later, if at all.
    priv var _exited:  bool = false;   ///< a return / panic / jump came before the cursor.

    fn ScriptUseScan(self, sc: *SemaContext) {
        self._tu = TypeUtil(sc);
    }

    priv fn _definite(self) -> bool {
        return (self._cond == 0) && (self._closure == 0) && (!self._exited);
    }

    fn traverse_named_ident_expr(self, n: *NamedIdentExpr) -> *NamedIdentExpr {
        if (n->resolved_decl != &null) && isa::<VariableDecl>(n->resolved_decl) {
            var u = ScriptUse{};
            u.decl     = n->resolved_decl;
            u.range    = n->range;
            u.definite = self._definite();
            self.reads.push_back(u);
        }
        return RecursiveASTVisitor::<ScriptUseScan>::traverse_named_ident_expr(n);
    }

    /// A call of a named free function. One in a closure is not a call of
    /// the walked code: the closure may run at any time.
    fn traverse_call_expr(self, n: *CallExpr) -> *CallExpr {
        var c = self._tu.strip_parens(n->callee);
        if (self._closure == 0) && (c != &null) && isa::<NamedIdentExpr>(c) {
            var d = cast::<NamedIdentExpr>(c)->resolved_decl;
            if (d != &null) && isa::<FunctionDecl>(d) {
                var u = ScriptUse{};
                u.decl     = d;
                u.range    = n->range;
                u.definite = self._definite();
                self.calls.push_back(u);
            }
        }
        return RecursiveASTVisitor::<ScriptUseScan>::traverse_call_expr(n);
    }

    fn traverse_closure_expr(self, n: *ClosureExpr) -> *ClosureExpr {
        self._closure += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_closure_expr(n);
        self._closure -= 1;
        return out;
    }

    // Every construct that runs part of itself only on some paths. Its
    // condition is counted with it: that loses an error, never adds one.

    fn traverse_conditional_stmt(self, n: *ConditionalStmt) -> *ConditionalStmt {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_conditional_stmt(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_while_loop_stmt(self, n: *WhileLoopStmt) -> *WhileLoopStmt {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_while_loop_stmt(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_loop_stmt(self, n: *LoopStmt) -> *LoopStmt {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_loop_stmt(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_ranged_for_stmt(self, n: *RangedForStmt) -> *RangedForStmt {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_ranged_for_stmt(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_indexed_for_stmt(self, n: *IndexedForStmt) -> *IndexedForStmt {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_indexed_for_stmt(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_match_stmt(self, n: *MatchStmt) -> *MatchStmt {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_match_stmt(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_try_catch_stmt(self, n: *TryCatchStmt) -> *TryCatchStmt {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_try_catch_stmt(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_if_expr(self, n: *IfExpr) -> *IfExpr {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_if_expr(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_match_expr(self, n: *MatchExpr) -> *MatchExpr {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_match_expr(n);
        self._cond -= 1;
        return out;
    }

    fn traverse_try_catch_expr(self, n: *TryCatchExpr) -> *TryCatchExpr {
        self._cond += 1;
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_try_catch_expr(n);
        self._cond -= 1;
        return out;
    }

    /// `a && b`, `a || b`, `a ?? b`: the right side may not run.
    fn traverse_binary_operator_expr(self, n: *BinaryOperatorExpr) -> *BinaryOperatorExpr {
        var k = n->op_token.kind;
        var is_short = (k == TokenKind::OpAmpAmp) || (k == TokenKind::OpPipePipe) || (k == TokenKind::OpQuestionQuestion);
        if is_short { self._cond += 1; }
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_binary_operator_expr(n);
        if is_short { self._cond -= 1; }
        return out;
    }

    // An exit makes everything after it in source order conditional: in
    // `if done { return } read(g)` the read does not run on every path.

    fn traverse_return_stmt(self, n: *ReturnStmt) -> *ReturnStmt {
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_return_stmt(n);
        self._exited = true;
        return out;
    }

    fn traverse_panic_stmt(self, n: *PanicStmt) -> *PanicStmt {
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_panic_stmt(n);
        self._exited = true;
        return out;
    }

    fn traverse_jump_intrinsic_stmt(self, n: *JumpIntrinsicStmt) -> *JumpIntrinsicStmt {
        var out = RecursiveASTVisitor::<ScriptUseScan>::traverse_jump_intrinsic_stmt(n);
        self._exited = true;
        return out;
    }
}

class ScriptLowering derives ASTWriter::<ScriptLowering> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;
    priv var tu:    TypeUtil;
    /// Which file is a script and which bindings defer: shared with
    /// JumpLabelCheck and ControlFlowAnalysis, so all three see one set
    /// of lines.
    priv var rules: ScriptRules;
    /// The program's root file (SemaContext::script_root, the driver's
    /// answer). Top-level statements anywhere else are an error.
    priv var _root: bool = true;

    // The deferred globals, three parallel lists in declaration order.
    priv var _deferred: vec::<*VariableDecl>;
    priv var _storage:  vec::<*Type>;    ///< each one's `T?`.
    priv var _line:     vec::<usize>;    ///< the ordinal of its assignment among main's statements.

    // Where the rewrite walk is.
    priv var _in_main: bool  = false;    ///< walking a statement that moves into main.
    priv var _pos:     usize = 0;        ///< that statement's ordinal.
    priv var _closure: u32   = 0;        ///< closure bodies above the cursor.

    fn ScriptLowering(self, sc: *SemaContext, root: bool) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
        self.tu    = TypeUtil(sc);
        self.rules = ScriptRules(sc);
        self._root = root;
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        var t = self.sc->tu;
        if (t == &null) || (t->program == &null) { return; }
        var items = &(t->program->items);

        // Is this a script at all? A file of declarations and bindings only
        // (a library, or a program with `fn main`) is left exactly as it is.
        var first = self.rules.first_statement();
        if !first.is_valid() { return; }
        var main_fn = self.rules.main_of();

        if !self._root {
            var b = self.sc->diag->report(DiagID::SC001E, first.start,
                "a top-level statement runs only in the program's root file; this file is imported as a module");
            b.first(first);
            b.note(DiagID::SC001N, first.start, "move it into a function, or into the file the program starts from");
            b.emit();
            return;
        }
        if main_fn != &null {
            var b = self.sc->diag->report(DiagID::SC001E, first.start,
                "a file with 'fn main' cannot also have top-level statements; 'main' is where the program starts");
            b.first(first);
            b.note(DiagID::SC001N, main_fn->range.start, "'main' is declared here").first(main_fn->range);
            b.emit();
            return;
        }

        if !self._classify(items) { return; }
        self._check_calls(items);
        self._assemble(items);
        // For the driver: a second script in the same link is an error
        // naming both, and this is where this one starts.
        self.sc->script_at = first;
    }

    // --- classification -------------------------------------------------------------

    /// Every deferred binding, with its storage type and its ordinal among
    /// main's statements; the errors that stop the rewrite. False when one
    /// was reported.
    priv fn _classify(self, items: *ArenaList::<TopLevelItem>) -> bool {
        var ok = true;
        var ord: usize = 0;
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            var v = self.rules.binding_of(item);
            if v != &null {
                if !self.rules.defers(v) { continue; }
                var c = canon_unqual(v->type_->canonical);
                if self.tu.nullable_inner(c) != &null {
                    var b = self.sc->diag->report(DiagID::SC001E, v->range.start,
                        "a script variable of nullable type with an initializer that is not constant is not supported yet");
                    b.first(v->range);
                    b.note(DiagID::SC001N, v->range.start, "give it a constant initializer (null) and assign it on the next line");
                    b.emit();
                    ok = false;
                    continue;
                }
                self._deferred.push_back(v);
                self._storage.push_back(self.sc->types->nullable(c));
                self._line.push_back(ord);
                ord += 1;
                continue;
            }
            if item.kind == TopLevelKind::Decl { continue; }
            if (item.kind == TopLevelKind::Stmt) && isa::<DestructuringDeclStmt>(item.as_stmt()) {
                var s = item.as_stmt();
                var b = self.sc->diag->report(DiagID::SC001E, s->range.start,
                    "a destructuring declaration at the top level of a script is not supported yet");
                b.first(s->range);
                b.emit();
                ok = false;
                continue;
            }
            ord += 1;
        }
        if ok && (self._deferred.size() > 0) {
            ICE_IF(!self.sc->well_known->has(WellKnownType::Nullable),
                   "ScriptLowering: a deferred script variable needs the Nullable lang item; the builtin root declares it");
        }
        return ok;
    }

    /// The deferred global \p d is, as an index into the three lists; -1
    /// when it is none.
    priv fn _index_of(self, d: *Decl) -> i64 {
        if d == &null { return -1; }
        for var i: usize = 0; i < self._deferred.size(); ++i {
            var v = static_cast::<*Decl>(self._deferred[i]);
            if v == d { return static_cast::<i64>(i); }
        }
        return -1;
    }

    // --- read before init, through a direct call --------------------------------

    /// A call made by main's statement at ordinal p, of a function in this
    /// file that reads a deferred global g on every path, before g's line
    /// (line(g) >= p): the read cannot see a value, so it is the error a
    /// read in main is. One level: what the callee's own callees read is
    /// left to the runtime guard (SCRIPT.md [OPEN]).
    priv fn _check_calls(self, items: *ArenaList::<TopLevelItem>) {
        var ord: usize = 0;
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            var v = self.rules.binding_of(item);
            var scan = ScriptUseScan(self.sc);
            if v != &null {
                if self._index_of(static_cast::<*Decl>(v)) < 0 { continue; }
                scan.dispatch_expr(v->init);
            } else if item.kind == TopLevelKind::Decl {
                continue;
            } else if item.kind == TopLevelKind::Stmt {
                scan.dispatch_stmt(item.as_stmt());
            } else {
                scan.dispatch_expr(item.as_expr());
            }
            for var j: usize = 0; j < scan.calls.size(); ++j {
                self._check_callee(scan.calls[j], ord);
            }
            ord += 1;
        }
    }

    priv fn _check_callee(self, call: ScriptUse, ord: usize) {
        var f = dyn_cast::<FunctionDecl>(call.decl);
        if (f == &null) || f->is_method() || (f->body_block == &null) { return; }
        var body = ScriptUseScan(self.sc);
        body.dispatch_stmt(static_cast::<*Stmt>(f->body_block));
        for var k: usize = 0; k < body.reads.size(); ++k {
            var r = body.reads[k];
            if !r.definite { continue; }
            var gi = self._index_of(r.decl);
            if gi < 0 { continue; }
            var g = static_cast::<usize>(gi);
            if self._line[g] < ord { continue; }
            var name = self.tu.decl_name(r.decl);
            var fname = self.tu.decl_name(call.decl);
            var b = self.sc->diag->report(DiagID::SC001E, call.range.start,
                f"'{fname}' reads script variable '{name}' before the line that gives it a value has run");
            b.first(call.range);
            b.note(DiagID::SC001N, r.range.start, f"'{fname}' reads '{name}' here").first(r.range);
            var v = self._deferred[g];
            var when = ("by this line, once the call returns") if (self._line[g] == ord) else ("here, later");
            b.note(DiagID::SC001N, v->range.start, f"'{name}' is given its value " + when).first(v->range);
            b.emit();
            return;   // one error per call
        }
    }

    // --- the rewrite ------------------------------------------------------------------

    /// The new item list: every declaration and binding kept where it was
    /// (each binding the global it names), main's statements moved into
    /// `main`, which goes last. Bodies of everything that is not main walk
    /// in "elsewhere" mode, so a read of a deferred global there is guarded.
    priv fn _assemble(self, items: *ArenaList::<TopLevelItem>) {
        var at = SourceRange::invalid();
        var kept = ArenaList::<TopLevelItem>();
        kept.set_allocator(&(self.ctx->ast_alloc));
        var body = self.list_builder::<*Stmt>();
        if self._deferred.size() > 0 {
            body.push(self._teardown(self._deferred[0]->range));
        }

        var ord: usize = 0;
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            var v = self.rules.binding_of(item);
            if v != &null {
                var gi = self._index_of(static_cast::<*Decl>(v));
                if gi >= 0 {
                    var g = static_cast::<usize>(gi);
                    if !at.is_valid() { at = v->range; }
                    body.push(self._initialize(v, g, ord));
                    self._store(v, g);
                    kept.push(item);
                    ord += 1;
                    continue;
                }
            }
            if item.kind == TopLevelKind::Decl {
                var ds = self.dyn()->transform_decl(item.as_decl());
                for var j: usize = 0; j < ds.size(); ++j { kept.push(TopLevelItem::from_decl(ds[j])); }
                continue;
            }
            if v != &null {
                // A binding that is not deferred: its initializer is a
                // static one and stays with it.
                var ss = self.dyn()->transform_stmt(item.as_stmt());
                for var j: usize = 0; j < ss.size(); ++j { kept.push(TopLevelItem::from_stmt(ss[j])); }
                continue;
            }
            var s: *Stmt = &null;
            if item.kind == TopLevelKind::Stmt {
                s = item.as_stmt();
            } else {
                var e = item.as_expr();
                s = static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, e->range, e));
            }
            if !at.is_valid() { at = s->range; }
            self._in_main = true;
            self._pos     = ord;
            var ms = self.dyn()->transform_stmt(s);
            self._in_main = false;
            for var j: usize = 0; j < ms.size(); ++j { body.push(ms[j]); }
            ord += 1;
        }

        // The end of the file returns 0 (the end of a `-> i32` body would
        // not; C++ only excuses `main` itself, and this keeps the tree
        // honest for every pass after this one).
        var zero = self.synth.int_literal(at, 0, BuiltinKind::I32);
        body.push(static_cast::<*Stmt>(ReturnStmt::create(self.ctx, at, zero)));

        var m = self._main(at, &body);
        kept.push(TopLevelItem::from_decl(static_cast::<*Decl>(m)));
        (*items) = kept;
        self._resync(self.sc->tu);
    }

    /// `g = <init>`, the deferred initializer at its line: walked as main's
    /// statement at ordinal \p ord, so a read in it of g itself or of a
    /// later global is the before-init error. The node is the initializer
    /// itself, moved: one node, one parent, and CopyMoveLowering's `T&&`
    /// cast on it comes along.
    priv fn _initialize(self, v: *VariableDecl, g: usize, ord: usize) -> *Stmt {
        var at = v->range;
        self._in_main = true;
        self._pos     = ord;
        var init = self.dyn()->transform_expr(v->init);
        self._in_main = false;
        var asg = AssignOperatorExpr::create(self.ctx, at, self._storage_use(g, at), init,
                                             self.synth.punct(at, TokenKind::OpEqual));
        asg->type_          = self._storage[g];
        asg->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, static_cast::<*Expr>(asg)));
    }

    /// The global itself becomes its storage: `T?`, starting null. A
    /// `const` one is assigned by main, so its storage is not const; the
    /// typer already rejected every write the source makes to it, and its
    /// reads still carry the `const T` they were typed with.
    priv fn _store(self, v: *VariableDecl, g: usize) {
        var t = self._storage[g];
        v->type_ = t;
        v->init  = self._null(v->range, t);
        if v->storage == StorageClass::Const { v->storage = StorageClass::Var; }
        v->const_binding = false;
    }

    /// `finally { gN = null ... g1 = null }`: main's first statement, so it
    /// runs at main's every exit, after everything else main did. Reverse
    /// order: the last value made is the first destroyed, as C++ destroys
    /// statics. A global whose line never ran is null already; the
    /// assignment is a no-op.
    priv fn _teardown(self, at: SourceRange) -> *Stmt {
        var blk = CompoundStmt::create(self.ctx, at);
        var b = self.list_builder::<*Stmt>();
        var i = self._deferred.size();
        while i > 0 {
            i -= 1;
            var r = self._deferred[i]->range;
            var asg = AssignOperatorExpr::create(self.ctx, r, self._storage_use(i, r), self._null(r, self._storage[i]),
                                                 self.synth.punct(r, TokenKind::OpEqual));
            asg->type_          = self._storage[i];
            asg->value_category = Expr::ValueCategory::LValue;
            b.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, r, static_cast::<*Expr>(asg))));
        }
        b.freeze_into(&(blk->body));
        return static_cast::<*Stmt>(FinallyStmt::create(self.ctx, at, blk));
    }

    /// `fn main() -> i32 { body }` at file scope. Every field set, as
    /// FieldInitLowering::_new_fn sets a thunk's; CXXSpell::is_main makes it
    /// the C++ `int main`.
    priv fn _main(self, at: SourceRange, body: *ListBuilder::<*Stmt>) -> *FunctionDecl {
        var dc = self._tu_dc(self.sc->tu);
        var n = self.ctx->alloc::<FunctionDecl>();
        libcxx::memset(static_cast::<*void>(n), 0, sizeof(FunctionDecl));
        n->kind  = DeclKind::FunctionDecl;
        n->range = at;
        n->name  = self.synth.ident(at, "main");
        n->init_annotations(&(self.ctx->ast_alloc));
        n->init_dc(DeclContextKind::Function, self.ctx, dc, static_cast::<*Decl>(n));
        n->init_redecl();
        n->params          = create_empty_frozen_list::<*ParamDecl>();
        n->generic_params  = create_empty_frozen_list::<*GenericParamDecl>();
        n->op_token        = create_empty_frozen_list::<Token>();
        n->spec_args       = create_empty_frozen_list::<*Type>();
        n->abi             = AbiKind::None;
        n->modifiers       = FnModifier::None;
        n->body_kind       = FnBodyKind::Block;
        n->spec_kind       = SpecKind::None;
        n->requires_clause = &null;
        n->where_clause    = &null;
        n->qualifier       = &null;
        n->semantic_dc     = reinterpret_cast::<*void>(dc);
        n->lexical_dc      = reinterpret_cast::<*void>(dc);
        n->visibility      = VisibilityKind::Public;
        n->is_implicit     = true;
        n->return_type     = self.sc->builtin(BuiltinKind::I32);
        // TODO(panic): PANIC.md §2.4 -- top-level code handles every panic.
        // The synthesized main is the place that catches what escapes the
        // script's statements; nothing to catch until PanicLowering lands.
        var blk = CompoundStmt::create(self.ctx, at);
        body->freeze_into(&(blk->body));
        n->body_block = blk;
        return n;
    }

    priv fn _tu_dc(self, t: *TranslationUnit) -> *DeclContext {
        return static_cast::<*DeclContext>(t);
    }

    /// tu->dc_decls from the new item list: its Decl entries in order
    /// (ASTWriter::_resync_tu_decls' rule), so EmitPlan sees `main`.
    priv fn _resync(self, t: *TranslationUnit) {
        var dc  = self._tu_dc(t);
        var buf = ArenaList::<*Decl>();
        buf.set_allocator(&(self.ctx->ast_alloc));
        var items = &(t->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            if item.kind != TopLevelKind::Decl { continue; }
            var d = item.as_decl();
            if d != &null { buf.push(d); }
        }
        dc->dc_decls = buf;
    }

    // --- reads --------------------------------------------------------------------------

    /// A read of a deferred global, by where it is (file header).
    fn transform_named_ident_expr(self, n: *NamedIdentExpr) -> *Expr {
        var out = ASTWriter::<ScriptLowering>::transform_named_ident_expr(n);
        var gi = self._index_of(n->resolved_decl);
        if gi < 0 { return out; }
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        var g = static_cast::<usize>(gi);
        if self._in_main && (self._closure == 0) {
            if self._line[g] < self._pos { return self._marked(n, g); }
            self._early_read(n, g);
            return out;
        }
        return self._guarded(n, g);
    }

    /// A closure's body runs whenever the closure is called, which main's
    /// order does not decide: its reads are guarded, even in main.
    fn transform_closure_expr(self, n: *ClosureExpr) -> *Expr {
        self._closure += 1;
        var out = ASTWriter::<ScriptLowering>::transform_closure_expr(n);
        self._closure -= 1;
        return out;
    }

    /// `g = e` as a statement writes the storage whole: `T -> T?` converts,
    /// and no value is read, so it needs no guard and is no early read.
    /// The left side is retyped to the storage it now names.
    fn transform_expression_stmt(self, n: *ExpressionStmt) -> vec::<*Stmt> {
        var a = dyn_cast::<AssignOperatorExpr>(n->expr);
        if (a != &null) && (a->op_token.kind == TokenKind::OpEqual) && (a->resolved_op == &null) {
            var l = self.tu.strip_parens(a->lhs);
            var li = dyn_cast::<NamedIdentExpr>(l);
            var gi: i64 = -1;
            if li != &null { gi = self._index_of(li->resolved_decl); }
            if gi >= 0 {
                var g = static_cast::<usize>(gi);
                a->rhs = self.dyn()->transform_expr(a->rhs);
                l->type_ = self._storage[g];
                a->type_ = self._storage[g];
                return self._one_stmt(static_cast::<*Stmt>(n));
            }
        }
        return ASTWriter::<ScriptLowering>::transform_expression_stmt(n);
    }

    /// A top-level `return` returns from main: bare, it is `return 0`; with
    /// a value, that value is the exit status and must be an integer.
    fn transform_return_stmt(self, n: *ReturnStmt) -> vec::<*Stmt> {
        var out = ASTWriter::<ScriptLowering>::transform_return_stmt(n);
        if (!self._in_main) || (self._closure > 0) { return out; }
        if n->value == &null {
            n->value = self.synth.int_literal(n->range, 0, BuiltinKind::I32);
            return out;
        }
        var t = n->value->type_;
        if (t != &null) && (!t->is_dependent()) && (!self.tu.is_integer(t)) && (!n->value->is_poisoned()) {
            var b = self.sc->diag->report(DiagID::SC001E, n->value->range.start,
                f"a top-level 'return' gives the program's exit status, an integer; this value is a '{self.tu.str(t)}\x27");
            b.first(n->value->range);
            b.emit();
        }
        return out;
    }

    /// SC001E: a read in main at or before the line that gives the global
    /// its value.
    priv fn _early_read(self, n: *NamedIdentExpr, g: usize) {
        var v = self._deferred[g];
        var name = self.tu.decl_name(static_cast::<*Decl>(v));
        var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
            f"script variable '{name}' is read before the line that gives it a value has run");
        b.first(n->range);
        b.note(DiagID::SC001N, v->range.start, f"'{name}' is given its value here").first(v->range);
        b.emit();
    }

    /// A NEW read of g marked as the nullness analysis marks a proven one:
    /// typed as the use was (`T`, its cv kept), its `T?` in narrowed_from.
    priv fn _marked(self, n: *NamedIdentExpr, g: usize) -> *Expr {
        var id = NamedIdentExpr::create(self.ctx, n->range, n->name);
        id->resolved_decl = n->resolved_decl;
        var e = static_cast::<*Expr>(id);
        e->adopt_sema(static_cast::<*Expr>(n));
        id->narrowed_from  = self._storage[g];
        e->type_           = n->type_;
        e->value_category  = Expr::ValueCategory::LValue;
        return e;
    }

    /// `*({ if !g? { unwrap_failed("<message>", <len>) }  &g })`: the
    /// `unwrap!` place form (CoalesceLowering::transform_unwrap_expr), an
    /// lvalue of the global's value, so `g.v = 4` from a function writes it.
    priv fn _guarded(self, n: *NamedIdentExpr, g: usize) -> *Expr {
        var at = n->range;
        var stmts = self.list_builder::<*Stmt>();
        stmts.push(self._abort_unless(at, g, self._storage_use(g, at)));
        var addr = self._addr(self._marked(n, g));
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, addr)));
        var se = self.synth.stmt_expr(static_cast::<*Expr>(n), &stmts, addr->type_);
        var d = UnaryOperatorExpr::create(self.ctx, at, se, self.synth.punct(at, TokenKind::OpStar),
                                          UnaryOperatorExpr::Fix::Prefix);
        var de = static_cast::<*Expr>(d);
        de->adopt_sema(static_cast::<*Expr>(n));
        de->type_          = n->type_;
        de->value_category = Expr::ValueCategory::LValue;
        return de;
    }

    /// `&e`, typed `*T` with \p e's cv kept: a `const T` read is a
    /// `const T*` in C++, and LowerSynth::addr_of drops the cv.
    priv fn _addr(self, e: *Expr) -> *Expr {
        var c = e->type_;
        if c->canonical != &null { c = c->canonical; }
        var u = UnaryOperatorExpr::create(self.ctx, e->range, e, self.synth.punct(e->range, TokenKind::OpAmp),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = self.sc->types->pointer(c);
        u->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(u);
    }

    /// `if !test? { unwrap_failed("<message>", <len>) }`. The message names
    /// the global and its line; the UnwrapFailed lang item writes it to fd 2
    /// and aborts (Lib/rt/unwrap.c), in every build mode.
    priv fn _abort_unless(self, at: SourceRange, g: usize, test: *Expr) -> *Stmt {
        var d = self.sc->well_known->get(WellKnownType::UnwrapFailed);
        ICE_IF(d == &null, "ScriptLowering: the \x27" + to_string(WellKnownType::UnwrapFailed) + "\x27 lang item is unbound; Lib/builtin/module.k declares it");
        var f = dyn_cast::<FunctionDecl>(NameLookup::representative(d));
        ICE_IF(f == &null, "ScriptLowering: the \x27" + to_string(WellKnownType::UnwrapFailed) + "\x27 lang item is not a function");

        var v    = self._deferred[g];
        var name = self.tu.decl_name(static_cast::<*Decl>(v));
        var full = self.ctx->sm->get_line_col(v->range.start);
        var file = self.ctx->sm->get_filename(v->range.start);
        var text = f"script variable '{name}' used before its line ran ({file}:{full.line})";
        var bytes = vec::<u8>();
        LowerSynth::push_string(text, &bytes);
        LowerSynth::push_string("\n", &bytes);

        var u8t  = self.sc->types->qualified(self.sc->builtin(BuiltinKind::U8), QUAL_CONST());
        var pu8  = self.sc->types->pointer(u8t);
        var lit  = self.synth.bytes_literal(at, &bytes, pu8);
        var args = self.list_builder::<*Expr>();
        args.push(self.synth.cast_to(at, lit, pu8, CastMode::Unsafe));   // `"..."` is const char*; the parameter is const unsigned char*.
        args.push(self.synth.int_literal(at, static_cast::<u64>(bytes.size()), BuiltinKind::USize));
        var call = self.synth.free_call(at, static_cast::<*Decl>(f), &args, self.sc->builtin(BuiltinKind::Never));

        var q = UnaryOperatorExpr::create(self.ctx, at, test, self.synth.punct(at, TokenKind::OpQuestion),
                                          UnaryOperatorExpr::Fix::Postfix);
        q->type_          = self.sc->builtin(BuiltinKind::Bool);
        q->value_category = Expr::ValueCategory::RValue;
        var no = UnaryOperatorExpr::create(self.ctx, at, static_cast::<*Expr>(q), self.synth.punct(at, TokenKind::OpExclaim),
                                           UnaryOperatorExpr::Fix::Prefix);
        no->type_          = self.sc->builtin(BuiltinKind::Bool);
        no->value_category = Expr::ValueCategory::RValue;

        var blk  = CompoundStmt::create(self.ctx, at);
        var body = self.list_builder::<*Stmt>();
        body.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, call)));
        body.freeze_into(&(blk->body));
        return static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, static_cast::<*Expr>(no), blk, &null));
    }

    /// The storage of global \p g read whole: typed `T?`, an lvalue. One
    /// node per use.
    priv fn _storage_use(self, g: usize, at: SourceRange) -> *Expr {
        var v  = self._deferred[g];
        var id = NamedIdentExpr::create(self.ctx, at, v->name);
        id->resolved_decl = static_cast::<*Decl>(v);
        var e = static_cast::<*Expr>(id);
        e->type_          = self._storage[g];
        e->value_category = Expr::ValueCategory::LValue;
        return e;
    }

    /// `null` typed \p t: NullableTypeLowering makes it that record's null.
    priv fn _null(self, at: SourceRange, t: *Type) -> *Expr {
        var z = NullLiteralExpr::create(self.ctx, at, false);
        var e = static_cast::<*Expr>(z);
        e->type_          = t;
        e->value_category = Expr::ValueCategory::RValue;
        return e;
    }
}
