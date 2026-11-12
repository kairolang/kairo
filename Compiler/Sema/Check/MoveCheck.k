/// --- The Kairo Project ----------------------- Sema/Check/MoveCheck.k --- ///
///
///   \brief Moves: the type must be movable, and a moved-from binding may
///          not be read again until it is reassigned.
///
///   \detail
///     (a) At a call whose parameter is `@move`, the argument's type must be
///         movable (lifecycle_of(sc)->facts_of). Error naming the type and why.
///
///     (b) What moves. An argument to a `@move` parameter, whatever its
///         type. And a MOVE value (moves_on_pass) wherever it is
///         transferred (Doc: Ownership, Function Parameters): passed to a
///         by-value parameter or a C++ `T&&`, initializing a variable,
///         assigned, or returned when it is not a bare local. A C++ `T&` or
///         `const T&` borrows; a const value cannot be moved from; a
///         temporary is moved by C++ on its own. Each transfer is recorded in
///         SemaContext::move_sites, and CopyMoveLowering casts exactly those
///         to `T&&`: what C++ moves is what this pass counts. A user
///         operator's operands are its arguments -- binary, compound
///         assignment and subscript alike -- and an expression body's value
///         is returned.
///
///     (b') Pending. Two transfers move only if the binding is not read
///         again (PendingMove): one of a value whose category its generic
///         instance decides (`var y = x`, `x: T`), and an expansion `xs...`
///         of a forwarding pack. A later read on any path, the next
///         iteration of a loop included, leaves the earlier one a copy.
///         Neither marks the binding moved-from: the pattern does not know
///         whether the instance is MOVE. Neither moves a binding whose
///         address is taken anywhere in the body (`&x`, `&x.f`, a pointer
///         capture, a C++ `T&` or `@inout` argument, `&a` of a `for` binding
///         over it): a read through that pointer is no read of the binding.
///
///     (c) Use after move. A moved bare local or parameter, or a part of one
///         (`p.a`, `p.a.b`), is MOVED-FROM from that point: a later READ that
///         touches it -- the part, something inside it, or the whole binding
///         -- in the same function body is an error; an assignment to it, or
///         to something enclosing it, clears it; at a join, moved on either
///         path means moved. A `var` declaration starts a new binding.
///
///     Intraprocedural only, bindings only: a move through a pointer, out
///     of `self`, a capture, or into another function is not tracked and
///     stays AMT's (Stage 2), though the cast is still made.
///
///     Path-insensitive by design: the right operand of `&&` moves on one
///     path only, so after `if a && f(x) { return }` x is maybe-moved, and a
///     read under `if !a` is reported. Proving it unreachable would need the
///     values of conditions, which this dataflow does not track.
///
///   \par Flow
///     The walk is the RAV's, with dispatch_expr / dispatch_stmt overridden
///     for the constructs that fork or end a path: if/match/try (stmt and
///     expr forms), `&&`/`||`, loops, return/break/continue/panic, and a
///     call typed `!` (`-> !`, `__builtin_trap()`, an imported
///     `[[noreturn]]`). Everything else falls through to the base
///     traversal, whose children route back here. A loop body is walked
///     TWICE, the second time with the back edge joined in, so a move on
///     iteration one that is read on iteration two is seen; diagnostics are
///     deduplicated by (binding, use). A path that has returned is `dead`
///     and contributes nothing to a join.
///
///     A `finally` body is NOT walked where it is written. It runs when its
///     block is LEFT, so it is recorded as pending on that block and walked
///     at every exit of it over the state at that exit: the block's end,
///     and each return, break, continue or panic that leaves it (return and
///     panic after their operand; every open block, innermost first; break
///     and continue down to the loop body's). A call that does not return
///     leaves no block -- the process ends and no destructor runs -- so no
///     body is walked on that path. The body's own moves and clears persist
///     past a fallthrough, break or continue, which is where they happen.
///
///   \par Which parameter is `@move`
///     The callee is the promoted decl (CallTyping wrote it) or a
///     fn-pointer type. Arguments map positionally, skipping a bound
///     receiver, by name for named arguments; a pack tail is by value.
///
///   Phase: CHECK, after ClassLifecycle, which it reads.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::DeclFacts::decl_is_imported
import AST::Kind::ExprKind::ExprKind
import AST::Kind::StmtKind::StmtKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    FieldDecl,
    FnBodyKind,
    FunctionDecl,
    ParamDecl,
    StructDecl,
    TransferKind,
    VariableDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::{
    RecursiveASTVisitor,
    named_call_arg_value,
}
import Diagnostic::Registry::DiagID
import Diagnostic::NoteText::type_declared_here
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::{
    LifecycleCategory,
    LifecycleTri,
    lifecycle_of,
    moves_on_pass,
}
import Sema::Check::ConformanceChecking::ConformanceChecking
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

/// One moved part: a binding, and the field path under it that was moved
/// out ("" for the whole binding, "a.b" for `p.a.b`).
pub class MovedPart {
    pub var d:    unsafe *Decl
    pub var path: string       = ""
    pub var at:   SourceRange       ///< where it was moved.
    pub var how:  string       = "" ///< where it went, for the note.
    fn MovedPart(self) { }
}

/// A transfer that moves only if nothing reads the binding again: a value
/// whose type is a generic parameter's (its category is the instance's,
/// ClassLifecycle Unknown), or an expansion `xs...` of a forwarding pack.
/// A later read of the binding on any path makes the site a copy -- the
/// expression left as it is -- and a site never read again moves.
pub class PendingMove {
    pub var d:       unsafe *Decl
    pub var path:    string       = ""
    pub var site:    unsafe *Expr
    pub var is_pack: bool         = false ///< site is a PackExpansionExpr.
    fn PendingMove(self) { }
}

/// \p inner is \p outer or a part of it.
pub fn path_within(const inner: string, const outer: string) -> bool {
    if outer.size() == 0 || inner == outer {
        return true
    }

    return inner.starts_with(outer + ".")
}

/// \p a and \p b name overlapping storage: one is the other or a part of it.
pub fn path_overlaps(const a: string, const b: string) -> bool {
    return path_within(a, b) || path_within(b, a)
}

/// The moved-from set on one path. `dead` after return/break/continue/panic
/// or a call that does not return: the path has left the block and
/// contributes nothing to a join.
pub class MoveState {
    pub var moved: cxx::std::vector<MovedPart>
    pub var dead:  bool                        = false
    /// Bindings already reported used-after-move on this path. One error per
    /// BINDING, not per read: three reads of one moved `e` in a loop are one
    /// mistake, and three errors for it is the cascade the poison rule exists
    /// to prevent. Travels with the flow state -- so a reassignment (clear)
    /// re-arms it, a join unions it, and a loop's back edge carries it.
    pub var reported: cxx::std::vector<unsafe *Decl>
    /// Transfers still waiting to learn whether a read follows (PendingMove).
    pub var pend: cxx::std::vector<PendingMove>
    fn MoveState(self) { }

    fn add_pending(self, const p: PendingMove) {
        for var i: usize = 0; i < self.pend.size(); ++i {
            if self.pend[i].site == p.site {
                return
            }
        }

        self.pend.push_back(p)
    }

    fn was_reported(self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self.reported.size(); ++i {
            if self.reported[i] == d {
                return true
            }
        }

        return false
    }

    fn index_of(self, d: unsafe *Decl, const path: string) -> usize {
        for var i: usize = 0; i < self.moved.size(); ++i {
            if self.moved[i].d == d && self.moved[i].path == path {
                return i
            }
        }

        return usize::MAX
    }

    /// The first moved part a read of \p path under \p d touches.
    fn overlap_of(self, d: unsafe *Decl, const path: string) -> usize {
        for var i: usize = 0; i < self.moved.size(); ++i {
            if self.moved[i].d == d && path_overlaps(self.moved[i].path, path) {
                return i
            }
        }

        return usize::MAX
    }

    /// First move wins: the note points at where it happened first.
    fn mark(self, const p: MovedPart) {
        if self.index_of(p.d, p.path) != usize::MAX {
            return
        }

        self.moved.push_back(p)
    }

    /// An assignment to \p path under \p d: that storage, and every part
    /// of it, holds a live value again, and a later move-then-use of it is a
    /// NEW mistake that must be reported, so the binding's report is dropped
    /// along with the move.
    fn clear(self, d: unsafe *Decl, const path: string) {
        for var r: usize = 0; r < self.reported.size(); ++r {
            if self.reported[r] == d {
                self.reported.erase(self.reported.cbegin() + (r as isize))
                break
            }
        }

        var i: usize = 0
        while i < self.moved.size() {
            if self.moved[i].d == d && path_within(self.moved[i].path, path) {
                self.moved.erase(self.moved.cbegin() + (i as isize))
                continue
            }

            i += 1
        }

        // A pending transfer out of the old value is that value's last use:
        // the new one is not the storage it read.
        var k: usize = 0
        while k < self.pend.size() {
            if self.pend[k].d == d && path_within(self.pend[k].path, path) {
                self.pend.erase(self.pend.cbegin() + (k as isize))
                continue
            }

            k += 1
        }
    }
}

/// Moved on either path means moved. A dead path defers to the live one.
pub fn move_join(a: MoveState, b: MoveState) -> MoveState {
    if a.dead {
        return b
    }

    if b.dead {
        return a
    }

    var out = a
    for var i: usize = 0; i < b.moved.size(); ++i {
        out.mark(b.moved[i])
    }

    // Reported on either path stays reported: re-reporting after the join
    // would be the second error for the mistake one branch already named.
    for var i: usize = 0; i < b.reported.size(); ++i {
        if !out.was_reported(b.reported[i]) {
            out.reported.push_back(b.reported[i])
        }
    }

    // Pending on either path: a read after the join demotes it either way.
    for var i: usize = 0; i < b.pend.size(); ++i {
        out.add_pending(b.pend[i])
    }

    return out
}

/// One enclosing loop: the states at each `break` / `continue` inside it.
pub class LoopFrame {
    pub var breaks:      cxx::std::vector<MoveState>
    pub var continues:   cxx::std::vector<MoveState>
    pub var block_depth: usize                       = 0 ///< _blocks.size() when the loop was entered; its body's block sits at this index.
    pub var has_label:   bool                        = false ///< written `label: loop`; a labeled break/continue finds its frame by it.
    pub var label:       Token
    fn LoopFrame(self) { }
}

/// What one body's walk carries and a nested body (a function, a closure)
/// starts without: saved and restored as one value (MoveCheck::_enter_body /
/// _leave_body), so neither walker can restore part of it.
pub struct BodyFlow {
    pub var st:     MoveState
    pub var loops:  cxx::std::vector<LoopFrame>
    pub var blocks: cxx::std::vector<cxx::std::vector<unsafe *Statements::FinallyStmt>>
}

pub class MoveCheck derives RecursiveASTVisitor<MoveCheck> {
    pub var  sc:     unsafe *SemaContext
    priv var _tu:    TypeUtil
    priv var _st:    MoveState
    priv var _loops: cxx::std::vector<LoopFrame>
    /// Pending finally bodies per open block, innermost block last (file
    /// header, Flow). Per body: saved and cleared across a nested function
    /// or closure like _st is.
    priv var _blocks: cxx::std::vector<cxx::std::vector<unsafe *Statements::FinallyStmt>>
    /// The label of the LabeledStmt being entered, for the loop it wraps
    /// to take onto its frame (_loop); cleared there.
    /// The transfer being checked is an assignment's right-hand side
    /// (_uncopyable_place leaves a Kairo NON_TRANSFER record to SC071E).
    priv var _assigning: bool = false
    priv var _pending_has_label: bool  = false
    priv var _pending_label:     Token
    pub var  n_moves:            usize = 0
    pub var  n_errored:          usize = 0
    /// Every non-pack PendingMove site seen, in order, and the ones a later
    /// read demoted. What is left once every body is walked moves (run).
    priv var _tentative:      cxx::std::vector<unsafe *Expr>
    priv var _demoted:        llvm::DenseSet<u64>
    priv var _tentative_decl: cxx::std::vector<unsafe *Decl> ///< parallel to _tentative: the binding moved from.
    /// Every forwarding-pack expansion seen, and its pack.
    priv var _pack_sites: cxx::std::vector<unsafe *Expr>
    priv var _pack_decl:  cxx::std::vector<unsafe *Decl>
    /// Bindings whose address is taken somewhere (`&x`, `&x.f`, `&x[i]`, a
    /// pointer capture, a C++ `T&` / `@inout` argument). A pending move out
    /// of one stays a copy whatever the order: a pointer taken before the
    /// transfer and read after it is no read of the BINDING, so the
    /// last-use test cannot see it. Decided at the end of run, over the
    /// whole body.
    priv var _addr: llvm::DenseSet<u64>
    /// `for a in xs`: the binding (a) and what it iterates (xs), so an
    /// address of an element makes the iterated binding aliased too.
    priv var _for_bind: cxx::std::vector<unsafe *Decl>
    priv var _for_over: cxx::std::vector<unsafe *Decl>
    /// The current function body's demoted pending moves, one per binding:
    /// the transfer, the read that followed it, and the binding. Written to
    /// the function (FunctionDecl::move_reuse_site) when its walk ends, for
    /// each instance to judge: the pattern does not know whether the value
    /// can be copied, an instance does.
    priv var _reuse_site: cxx::std::vector<unsafe *Expr>
    priv var _reuse_read: cxx::std::vector<unsafe *Expr>
    priv var _reuse_decl: cxx::std::vector<unsafe *Decl>

    fn MoveCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    /// PRE: TypesResolved (ExprTyper has run in this stage: callees promoted,
    /// arguments typed).
    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }

        // Decided only now: a loop's second pass, or a read in a later
        // branch, can still demote a site recorded early, and an address
        // taken anywhere in the body demotes every pending move out of it.
        for var i: usize = 0; i < self._for_bind.size(); ++i {
            if self._addr.count(self._for_bind[i] as usize as u64) != 0 {
                self._addr.insert(self._for_over[i] as usize as u64)
            }
        }

        for var i: usize = 0; i < self._pack_sites.size(); ++i {
            if self._addr.count(self._pack_decl[i] as usize as u64) != 0 {
                cast<Expressions::PackExpansionExpr>(self._pack_sites[i])->reread = true
            }
        }

        for var i: usize = 0; i < self._tentative.size(); ++i {
            var key = (self._tentative[i] as usize as u64)
            if self._addr.count(self._tentative_decl[i] as usize as u64) != 0 {
                continue
            }

            if self._demoted.count(key) != 0 || self.sc->move_sites.count(key) != 0 {
                continue
            }

            self.sc->move_sites.insert(key)
            self.n_moves += 1
        }
    }

    /// # bodies

    /// A function body starts clean and leaves nothing behind.
    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        if n == &null {
            return n
        }

        var saved    = self._enter_body()
        var saved_rs = self._reuse_site
        var saved_rr = self._reuse_read
        var saved_rd = self._reuse_decl
        self._reuse_site.clear()
        self._reuse_read.clear()
        self._reuse_decl.clear()
        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_function_decl(self, n)
        // `fn f(p: Pair) -> Str = p.a` is `{ return p.a }` (ExprBodyDesugar,
        // which keeps the node and reads the same written-signature test),
        // so its value is transferred out exactly as that return's is.
        if n->body_kind == FnBodyKind::Expr
            && n->body_expr != &null
            && !n->is_noreturn
            && n->return_type != &null {
            self._return_value(n->body_expr)
        }

        self._leave_body(saved)
        if self._reuse_site.size() > 0 {
            n->move_reuse_site.from_vec(unsafe &self._reuse_site, self.sc->ctx)
            n->move_reuse_read.from_vec(unsafe &self._reuse_read, self.sc->ctx)
        }

        self._reuse_site = saved_rs
        self._reuse_read = saved_rr
        self._reuse_decl = saved_rd
        return out
    }

    /// Captures are reads in the ENCLOSING body (a moved-from binding cannot
    /// be captured); the closure body is its own body. The captures are
    /// ClosureCaptures' list, the implicit ones included, each read at its
    /// first use (a named one at its name in the list); a Move capture
    /// (ownership.md: a MOVE value captured by copy is moved in) then
    /// leaves the binding moved-from here.
    fn traverse_closure_expr(self,
                             n: unsafe *Expressions::ClosureExpr) -> unsafe *Expressions::ClosureExpr {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_closure_expr(n) == false {
            return n
        }

        if n->caps_resolved {
            for var i: usize = 0; i < n->cap_decls.size(); ++i {
                var        m   = n->cap_modes[i]
                var unsafe *at = n->cap_uses[i]
                if m == Expressions::CaptureMode::Receiver || at == &null {
                    continue
                }

                self._read(at)
            }

            for var i: usize = 0; i < n->cap_decls.size(); ++i {
                var cm = n->cap_modes[i]
                if (cm == Expressions::CaptureMode::Ptr || cm == Expressions::CaptureMode::ConstPtr)
                    && n->cap_decls[i] != &null {
                    self._addr.insert(n->cap_decls[i] as usize as u64)
                }
            }

            for var i: usize = 0; i < n->cap_decls.size(); ++i {
                if n->cap_modes[i] != Expressions::CaptureMode::Move {
                    continue
                }

                var unsafe *d = n->cap_decls[i]
                if !self._tracked(d) {
                    continue
                }

                var mp = MovedPart()
                mp.d    = d
                mp.path = ""
                mp.at   = n->cap_uses[i]->range
                mp.how  = "into the closure that captures it"
                self._st.mark(mp)
            }
        } else {
            for var i: usize = 0; i < n->captures.size(); ++i {
                var unsafe *cap = n->captures.get(i)
                if cap->name != &null {
                    self.dispatch_expr(cap->name)
                }
            }
        }

        // A closure's demoted moves stay on the enclosing function's reuse
        // rows: the function, not the closure, is what an instance judges.
        var saved = self._enter_body()
        for var i: usize = 0; i < n->params.size(); ++i {
            self.dyn()->dispatch_decl(*n->params.get(i))
        }

        if n->body_block != &null {
            self.dyn()->traverse_block(n->body_block)
        }

        if n->body_expr != &null {
            self.dispatch_expr(n->body_expr)
            // ExprBodyDesugar's closure test: the resolved return type.
            if !n->is_noreturn && !self._is_void(n->return_type) {
                self._return_value(n->body_expr)
            }
        }

        self._leave_body(saved)
        return n
    }

    /// A body starts clean: the enclosing body's flow, handed back for
    /// _leave_body, and a fresh one in its place.
    priv fn _enter_body(self) -> BodyFlow {
        var saved = BodyFlow{}
        saved.st     = self._st
        saved.loops  = self._loops
        saved.blocks = self._blocks
        self._st     = MoveState()
        self._loops  = cxx::std::vector<LoopFrame>()
        self._blocks = cxx::std::vector<cxx::std::vector<unsafe *Statements::FinallyStmt>>()
        return saved
    }

    /// ...and leaves nothing behind: \p saved, _enter_body's, back.
    priv fn _leave_body(self, const saved: BodyFlow) {
        if !self._blocks.empty() {
            kairo::std::ice_fail("MoveCheck: a block frame outlived its body")
        }

        self._st     = saved.st
        self._loops  = saved.loops
        self._blocks = saved.blocks
    }

    /// `var b = a` moves a MOVE `a` into `b`. The declaration also makes `b`
    /// a new, live binding: in a loop body, last iteration's move of it
    /// says nothing about this one.
    fn traverse_variable_decl(self, n: unsafe *VariableDecl) -> unsafe *VariableDecl {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_variable_decl(self, n)
        if n->init != &null {
            self._transfer(n->init, f"into '{self.sc->ctx->get_spelling(n->name)}'")
        }

        self._st.clear(n, "")
        return out
    }

    /// A field of a struct literal or a variant's payload is initialized
    /// from its value, as a variable is.
    fn traverse_named_initializer_expr(self,
                                       n: unsafe *Expressions::NamedInitializerExpr) -> unsafe *Expressions::NamedInitializerExpr {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_named_initializer_expr(self, n)
        for var i: usize = 0; i < n->fields.size(); ++i {
            var unsafe *fl = n->fields.get(i)
            if fl->value != &null {
                self._transfer(
                    fl->value,
                    f"into the field '{self.sc->ctx->get_spelling(fl->name)}'",
                )
            }
        }

        return out
    }

    fn traverse_anon_initializer_expr(self,
                                      n: unsafe *Expressions::AnonInitializerExpr) -> unsafe *Expressions::AnonInitializerExpr {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_anon_initializer_expr(self, n)
        for var i: usize = 0; i < n->fields.size(); ++i {
            var unsafe *fl = n->fields.get(i)
            if fl->value != &null {
                self._transfer(fl->value, "into a field")
            }
        }

        return out
    }

    /// # expressions

    fn dispatch_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        if e == &null {
            return e
        }

        if self.stop {
            return e
        }

        match e->kind {
            case ExprKind::NamedIdentExpr {
                self._read(cast<NamedIdentExpr>(e))
                return RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
            } case ExprKind::ChainExpr {
                // `p.a.b` reads the part `a.b` of `p`, not all of it: a moved
                // `p.c` leaves it readable. The root is checked here and not
                // walked again, or it would read as the whole binding. What
                // is left of the chain after the base is names and type
                // arguments, which read nothing.
                var unsafe *c   = cast<ChainExpr>(e)
                var        path = ""
                var        all  = false
                var unsafe *d   = self._chain_root(c, &path, unsafe &all)
                if d == &null {
                    return RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
                }

                self._read_part(cast<NamedIdentExpr>(self._tu.strip_parens(c->base)), d, path)
                return e
            } case ExprKind::AssignOperatorExpr {
                var unsafe *asn = cast<Expressions::AssignOperatorExpr>(e)
                // `x = e` / `p.a = e`: the value first (it may read x, or move
                // it: `x = f(x)`), then that storage is whole again.
                if asn->op_token.kind == TokenKind::OpEqual
                    && asn->lhs != &null
                    && asn->rhs != &null {
                    var        path = ""
                    var unsafe *d   = self._place_root(asn->lhs, unsafe &path)
                    if d != &null {
                        self.dispatch_expr(asn->rhs)
                        self._assigning = true
                        self._transfer(asn->rhs, f"into '{self._spelled(asn->lhs)}'")
                        self._assigning = false
                        self._st.clear(d, path)
                        return e
                    }

                    self.dispatch_expr(asn->lhs)
                    self.dispatch_expr(asn->rhs)
                    self._assigning = true
                    self._transfer(asn->rhs, f"into '{self._spelled(asn->lhs)}'")
                    self._assigning = false
                    return e
                }

                // `acc += s` through a user `op +=` is a call taking `s`.
                var unsafe *cout = RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
                if asn->resolved_op != &null {
                    self._operator_operands(asn->resolved_op, asn->op_via_free, asn->lhs, asn->rhs)
                }

                return cout
            } case ExprKind::BinaryOperatorExpr {
                var unsafe *bo = cast<Expressions::BinaryOperatorExpr>(e)
                var        k   = bo->op_token.kind
                if k == TokenKind::OpAmpAmp || k == TokenKind::OpPipePipe {
                    // The right operand runs on one path only.
                    if bo->lhs != &null {
                        self.dispatch_expr(bo->lhs)
                    }

                    var before = self._st
                    if bo->rhs != &null {
                        self.dispatch_expr(bo->rhs)
                    }

                    self._st = move_join(before, self._st)
                    return e
                }

                var unsafe *out = RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
                if bo->resolved_op != &null {
                    self._operator_operands(bo->resolved_op, bo->op_via_free, bo->lhs, bo->rhs)
                }

                return out
            } case ExprKind::UnaryOperatorExpr {
                var unsafe *u = cast<Expressions::UnaryOperatorExpr>(e)
                if u->op_token.kind == TokenKind::OpAmp && u->operand != &null {
                    self._mark_addr(u->operand)
                }

                return RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
            } case ExprKind::SubscriptExpr {
                var unsafe *sx  = cast<Expressions::SubscriptExpr>(e)
                var unsafe *out = RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
                if sx->resolved_op != &null {
                    self._operator_operands(sx->resolved_op, sx->op_via_free, sx->base, sx->index)
                }

                return out
            } case ExprKind::PackExpansionExpr {
                // `xs...` of a pack parameter forwards each element
                // (EmitIR::_pack_expansion), which moves it: pending,
                // so a later read of the pack -- a second expansion, a `for`
                // over it, the same expansion on a loop's next iteration --
                // leaves this one a plain copy.
                var unsafe *out = RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
                var unsafe *x = self._tu.strip_parens(
                    cast<Expressions::PackExpansionExpr>(e)->operand,
                )

                if x != &null && isa<NamedIdentExpr>(x) {
                    var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
                    if d != &null && isa<ParamDecl>(d) && self._tracked(d) && !self._st.dead {
                        var pm = PendingMove()
                        pm.d       = d
                        pm.path    = ""
                        pm.site    = e
                        pm.is_pack = true
                        self._st.add_pending(pm)
                        self._pack_sites.push_back(e)
                        self._pack_decl.push_back(d)
                    }
                }

                return out
            } case ExprKind::CallExpr {
                self._call(cast<Expressions::CallExpr>(e))
                return e
            } case ExprKind::IfExpr {
                self._if_expr(cast<Expressions::IfExpr>(e))
                return e
            } case ExprKind::MatchExpr {
                var unsafe *m = cast<Expressions::MatchExpr>(e)
                if m->scrutinee != &null {
                    self.dispatch_expr(m->scrutinee)
                }

                self._arms_start()
                for var i: usize = 0; i < m->cases.size(); ++i {
                    self._arm_begin()
                    self.dyn()->traverse_match_case(m->cases.get(i))
                    self._arm_end()
                }

                self._arms_finish(false)
                return e
            } case ExprKind::TryCatchExpr {
                var unsafe *t     = cast<Expressions::TryCatchExpr>(e)
                var        before = self._st
                if t->try_expr != &null {
                    self.dispatch_expr(t->try_expr)
                }

                var after_try = self._st
                // A catch arm may run after any prefix of the try: its entry
                // is the join of before and after.
                var entry = move_join(before, after_try)
                var acc   = after_try
                for var i: usize = 0; i < t->catch_arms.size(); ++i {
                    var unsafe *arm = t->catch_arms.get(i)
                    self._st = entry
                    if arm->body != &null {
                        self.dispatch_expr(arm->body)
                    }

                    acc = move_join(acc, self._st)
                }

                self._st = acc
                return e
            } default {
                return RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
            }
        }
    }

    priv fn _if_expr(self, n: unsafe *Expressions::IfExpr) {
        if n->condition != &null {
            self.dispatch_expr(n->condition)
        }

        self._arms_start()
        self._arm_begin()
        if n->then_expr != &null {
            self.dispatch_expr(n->then_expr)
        }

        self._arm_end()
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var unsafe *arm = n->else_ifs.get(i)
            self._arm_begin()
            if arm->condition != &null {
                self.dispatch_expr(arm->condition)
            }

            if arm->body != &null {
                self.dispatch_expr(arm->body)
            }

            self._arm_end()
        }

        var has_else = n->else_expr != &null
        if has_else {
            self._arm_begin()
            self.dispatch_expr(n->else_expr)
            self._arm_end()
        }

        self._arms_finish(!has_else)
    }

    /// ## arm bookkeeping: N alternatives from one entry state

    priv var _arm_entry: cxx::std::vector<MoveState> ///< stack: entry state per open arm set.
    priv var _arm_acc:   cxx::std::vector<MoveState> ///< stack: accumulated exit per open arm set.
    priv var _arm_any:   cxx::std::vector<u8>

    priv fn _arms_start(self) {
        self._arm_entry.push_back(self._st)
        var dead = MoveState()
        dead.dead = true
        self._arm_acc.push_back(dead)
        self._arm_any.push_back(0)
    }

    priv fn _arm_begin(self) {
        self._st = self._arm_entry[self._arm_entry.size() - 1]
    }

    priv fn _arm_end(self) {
        var top = self._arm_acc.size() - 1
        self._arm_acc[top] = move_join(self._arm_acc[top], self._st)
        self._arm_any[top] = 1
    }

    /// \p fallthrough: the construct may run no arm at all (an `if` with no
    /// `else`), so the entry state is one of the paths.
    priv fn _arms_finish(self, fallthrough: bool) {
        var top   = self._arm_acc.size() - 1
        var acc   = self._arm_acc[top]
        var entry = self._arm_entry[top]
        var any   = self._arm_any[top] != 0
        self._arm_acc.pop_back()
        self._arm_entry.pop_back()
        self._arm_any.pop_back()
        if fallthrough || !any {
            acc = move_join(acc, entry)
        }

        self._st = acc
    }

    /// # statements

    fn dispatch_stmt(self, s: unsafe *Stmt) -> unsafe *Stmt {
        if s == &null {
            return s
        }

        if self.stop {
            return s
        }

        match s->kind {
            case StmtKind::CompoundStmt {
                var unsafe *n = cast<Statements::CompoundStmt>(s)
                self._blocks.push_back(cxx::std::vector<unsafe *Statements::FinallyStmt>())
                for var i: usize = 0; i < n->body.size(); ++i {
                    if self.stop {
                        break
                    }

                    self.dispatch_stmt(n->body[i])
                }

                // Fallthrough off the end: the block's bodies run here. A
                // dead path left the block through a jump that ran them.
                if !self._st.dead {
                    self._run_block_finallys(self._blocks.size() - 1)
                }

                self._blocks.pop_back()
                return s
            } case StmtKind::FinallyStmt {
                // Recorded, not walked: the body runs when its block is left
                // (_run_block_finallys), never at its statement.
                if self._blocks.empty() {
                    kairo::std::ice_fail("MoveCheck: `finally` outside a block")
                }

                self._blocks[self._blocks.size() - 1].push_back(cast<Statements::FinallyStmt>(s))
                return s
            } case StmtKind::ConditionalStmt {
                var unsafe *n = cast<Statements::ConditionalStmt>(s)
                if n->cond != &null {
                    self.dispatch_expr(n->cond)
                }

                self._arms_start()
                self._arm_begin()
                self.dyn()->traverse_block(n->then_)
                self._arm_end()
                var has_else = n->else_ != &null
                if has_else {
                    self._arm_begin()
                    self.dispatch_stmt(n->else_)
                    self._arm_end()
                }

                self._arms_finish(!has_else)
                return s
            } case StmtKind::WhileLoopStmt {
                var unsafe *n = cast<Statements::WhileLoopStmt>(s)
                self._loop(n->cond, n->body, &null, !self._is_true_literal(n->cond), &null)
                return s
            } case StmtKind::LoopStmt {
                var unsafe *n = cast<Statements::LoopStmt>(s)
                self._loop(&null, n->body, &null, false, &null)
                return s
            } case StmtKind::RangedForStmt {
                var unsafe *n = cast<Statements::RangedForStmt>(s)
                if n->iterable != &null {
                    self.dispatch_expr(n->iterable)
                    // An element's address is an address into what is iterated.
                    var unsafe *it = self._tu.strip_parens(n->iterable)
                    if it != &null
                        && isa<NamedIdentExpr>(it)
                        && cast<NamedIdentExpr>(it)->resolved_decl != &null {
                        for var i: usize = 0; i < n->bindings.size(); ++i {
                            var unsafe *bd = n->bindings.get(i)->decl
                            if bd == &null {
                                continue
                            }

                            self._for_bind.push_back(bd)
                            self._for_over.push_back(cast<NamedIdentExpr>(it)->resolved_decl)
                        }
                    }
                }

                self._loop(&null, n->body, &null, true, n)
                return s
            } case StmtKind::IndexedForStmt {
                var unsafe *n = cast<Statements::IndexedForStmt>(s)
                if n->init != &null {
                    self.dispatch_stmt(n->init)
                }

                self._loop(
                    n->cond,
                    n->body,
                    n->update,
                    n->cond != &null && !self._is_true_literal(n->cond),
                    &null,
                )

                return s
            } case StmtKind::MatchStmt {
                var unsafe *n = cast<Statements::MatchStmt>(s)
                if n->scrutinee != &null {
                    self.dispatch_expr(n->scrutinee)
                }

                self._arms_start()
                for var i: usize = 0; i < n->cases.size(); ++i {
                    self._arm_begin()
                    self.dyn()->traverse_match_case(n->cases.get(i))
                    self._arm_end()
                }

                self._arms_finish(false)
                return s
            } case StmtKind::TryCatchStmt {
                var unsafe *n     = cast<Statements::TryCatchStmt>(s)
                var        before = self._st
                self.dyn()->traverse_block(n->try_body)
                var after_try = self._st
                var entry     = move_join(before, after_try)
                var acc       = after_try
                for var i: usize = 0; i < n->arms.size(); ++i {
                    var unsafe *arm = n->arms.get(i)
                    self._st = entry
                    if arm->body != &null {
                        self.dispatch_stmt(arm->body)
                    }

                    acc = move_join(acc, self._st)
                }

                self._st = acc
                return s
            } case StmtKind::ReturnStmt {
                var unsafe *n = cast<Statements::ReturnStmt>(s)
                if n->value != &null {
                    self.dispatch_expr(n->value)
                    self._return_value(n->value)
                }

                self._run_finallys_to(0)
                self._st.dead = true
                return s
            } case StmtKind::PanicStmt {
                var unsafe *n = cast<Statements::PanicStmt>(s)
                if n->payload != &null {
                    self.dispatch_expr(n->payload)
                }

                self._run_finallys_to(0)
                self._st.dead = true
                return s
            } case StmtKind::LabeledStmt {
                var unsafe *n = cast<Statements::LabeledStmt>(s)
                self._pending_has_label = true
                self._pending_label     = n->label
                if n->inner != &null {
                    self.dispatch_stmt(n->inner)
                }

                self._pending_has_label = false
                return s
            } case StmtKind::BreakStmt {
                var unsafe *n = cast<Statements::BreakStmt>(s)
                var        f  = self._target_frame(n->has_label, n->label)
                if f != usize::MAX {
                    self._run_finallys_to(self._loops[f].block_depth)
                    self._loops[f].breaks.push_back(self._st)
                }

                self._st.dead = true
                return s
            } case StmtKind::ContinueStmt {
                var unsafe *n = cast<Statements::ContinueStmt>(s)
                var        f  = self._target_frame(n->has_label, n->label)
                if f != usize::MAX {
                    self._run_finallys_to(self._loops[f].block_depth)
                    self._loops[f].continues.push_back(self._st)
                }

                self._st.dead = true
                return s
            } default {
                return RecursiveASTVisitor<MoveCheck>::dispatch_stmt(self, s)
            }
        }
    }

    /// Two passes over the body: the second starts from the join of the
    /// entry state and the first pass's exit, so a move on iteration one is
    /// visible to a read on iteration two. `continue` states join the back
    /// edge; `break` states join the exit. The exit is reachable without
    /// entering the body at all (a false condition), so the entry state is
    /// a path too -- when \p finite. An infinite loop (`loop`, `while
    /// true`, a C-style `for` with no condition; ReturnPathCheck's rule) is
    /// left only by a `break`, so its exit is the join of the breaks alone:
    /// neither the entry state nor the back edge reaches past it, and with
    /// no break the code after it is dead.
    priv fn _loop(self,
                  cond:   unsafe *Expr,
                  body:   unsafe *Statements::CompoundStmt,
                  update: unsafe *Expr,
                  finite: bool,
                  rf:     unsafe *Statements::RangedForStmt) {
        var entry = self._st
        // The body CompoundStmt is dispatched next and lands at exactly this
        // index: cond and update are expressions, an IndexedForStmt init a
        // DeclStmt, and none opens a block.
        var frame = LoopFrame()
        frame.block_depth       = self._blocks.size()
        frame.has_label         = self._pending_has_label
        frame.label             = self._pending_label
        self._pending_has_label = false
        self._loops.push_back(frame)

        var exit1 = self._loop_pass(cond, body, update, rf)
        self._st = move_join(entry, exit1)
        var head  = self._st
        var exit2 = self._loop_pass(cond, body, update, rf)

        var fr = self._loops[self._loops.size() - 1]
        self._loops.pop_back()

        var out = MoveState()
        out.dead = true
        if finite {
            out = move_join(head, exit2)
            out = move_join(out, entry)
        }

        for var i: usize = 0; i < fr.breaks.size(); ++i {
            out = move_join(out, fr.breaks[i])
        }

        self._st = out
    }

    /// Walk the pending bodies of block \p i, last declared first -- LIFO
    /// with the block's locals -- over the current state. Each body is a
    /// block of its own and opens its own frame on top; block \p i stays
    /// open, since the caller is still inside it structurally.
    priv fn _run_block_finallys(self, i: usize) {
        var k = self._blocks[i].size()
        while k > 0 {
            k = k - 1
            var unsafe *fin = self._blocks[i][k]
            if fin != &null && fin->body != &null {
                self.dispatch_stmt(fin->body)
            }
        }
    }

    /// A jump out of every block from the innermost down to index \p to:
    /// their pending bodies run, innermost block first.
    priv fn _run_finallys_to(self, to: usize) {
        var i = self._blocks.size()
        while i > to {
            i = i - 1
            self._run_block_finallys(i)
        }
    }

    /// The frame a break/continue jumps to: the innermost loop, or the one
    /// its label names. A label that names none was LoopContextCheck's
    /// SC012E; usize(-1) then, and the jump only ends the path.
    priv fn _target_frame(self, has_label: bool, label: Token) -> usize {
        var i = self._loops.size()
        if !has_label {
            return if (i > 0) => (i - 1) else => usize::MAX
        }

        while i > 0 {
            i = i - 1
            if self._loops[i].has_label && self._loops[i].label.imm == label.imm {
                return i
            }
        }

        return usize::MAX
    }

    priv fn _is_true_literal(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        if !isa<BooleanLiteralExpr>(e) {
            return false
        }

        return cast<BooleanLiteralExpr>(e)->value
    }

    /// One walk of cond -> body -> update, from the current state; returns
    /// the back-edge state (body exit joined with every `continue`).
    priv fn _loop_pass(self,
                       cond:   unsafe *Expr,
                       body:   unsafe *Statements::CompoundStmt,
                       update: unsafe *Expr,
                       rf:     unsafe *Statements::RangedForStmt) -> MoveState {
        var top = self._loops.size() - 1
        self._loops[top].continues.clear()
        if cond != &null {
            self.dispatch_expr(cond)
        }

        // A `for` binding is a new binding each iteration, bound to the next
        // element: last iteration's move out of it says nothing about this
        // one, as a `var` in the body says nothing (traverse_variable_decl).
        if rf != &null {
            for var i: usize = 0; i < rf->bindings.size(); ++i {
                var unsafe *bd = rf->bindings.get(i)->decl
                if bd != &null {
                    self._st.clear(bd, "")
                }
            }
        }

        self.dyn()->traverse_block(body)
        var back = self._st
        for var i: usize = 0; i < self._loops[top].continues.size(); ++i {
            back = move_join(back, self._loops[top].continues[i])
        }

        self._st = back
        if update != &null {
            self.dispatch_expr(update)
        }

        return self._st
    }

    /// # calls

    priv fn _call(self, n: unsafe *Expressions::CallExpr) {
        if n->callee != &null {
            self.dispatch_expr(n->callee)
        }

        var unsafe *f = self._callee_decl(n->callee)
        // A constructor call's callee names the TYPE; the constructor X
        // selected is on the call. Its parameters are what `@move` (stamped
        // onto a transfer constructor's `other` by ClassLifecycle) is read
        // from, so without this `X(h)` through `@move fn X` never moves `h`.
        var is_ctor = n->ctor_decl != &null && isa<FunctionDecl>(n->ctor_decl)
        if is_ctor {
            f = cast<FunctionDecl>(n->ctor_decl)
        }

        var fp: unsafe *FunctionPointerType = &null
        if f == &null && n->callee != &null && n->callee->type_ != &null {
            var unsafe *t = canon_unqual(self._tu.strip_nullable(n->callee->type_))
            if t != &null && isa<FunctionPointerType>(t) {
                fp = cast<FunctionPointerType>(t)
            }
        }

        // The parameter view a positional argument indexes: the declared
        // params minus a receiver bound through `obj.m(...)`.
        var view = cxx::std::vector<unsafe *ParamDecl>()
        if f != &null {
            // A constructor's `self` is the object being built, never an argument.
            var bound_recv = is_ctor || f->is_method() && self._callee_binds_receiver(n->callee)
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if p == &null {
                    continue
                }

                if p->is_self && bound_recv {
                    continue
                }

                view.push_back(p)
            }
        }

        var pos: usize = 0
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            if a == &null {
                continue
            }

            var unsafe *value = named_call_arg_value(a)
            var unsafe *e     = if (value != &null) => (value) else => a

            var mode                   = ParamMode::Value
            var p:   unsafe *ParamDecl = &null
            if f != &null {
                if value != &null {
                    // The label is on the NamedArgExpr itself. This read
                    // predates that node -- a named argument was an
                    // AssignOperatorExpr whose operator was `:` -- and the
                    // stale cast was reinterpreting `name`'s bytes as an lhs
                    // pointer, which UBSan catches as a misaligned downcast.
                    var nm = self.sc->ctx->get_spelling(cast<Expressions::NamedArgExpr>(a)->name)
                    for var j: usize = 0; j < view.size(); ++j {
                        if self._tu.param_name(view[j]) == nm {
                            p = view[j]
                            break
                        }
                    }
                } else if pos < view.size() {
                    p = view[pos]
                    pos += 1
                } else if view.size() > 0 { // an imported pack leaves FunctionDecl::is_variadic false (DeclImport), so look at the params.
                    // The pack tail: every argument past the pack's own position is the
                    // pack's (it forwards, see _pass), so name the pack parameter.
                    for var j: usize = 0; j < view.size(); ++j {
                        if view[j]->is_pack {
                            p = view[j]
                        }
                    }
                }

                if p != &null {
                    mode = p->mode
                }
            } else if fp != &null {
                if i < fp->modes.size() {
                    mode = fp->modes[i]
                }
            }

            // `&x` committed as the `@inout` marker (a Kairo `@inout`, or a
            // C++ `T&` read as one) borrows; it moves nothing.
            var unsafe *mk = dyn_cast<Expressions::UnaryOperatorExpr>(self._tu.strip_parens(e))
            if mk != &null && mk->is_mode_marker {
                mode = ParamMode::Inout
            }

            self.dispatch_expr(e) // reads inside the argument, in order.
            // A call Sema could not resolve (SC064E ambiguous, no viable candidate)
            // has no selected parameter to bind: its by-value default would
            // report a copy that no parameter makes.
            if n->is_poisoned() && f == &null && fp == &null {
                continue
            }

            self._pass(e, p, mode)
        }

        // `-> !`, `__builtin_trap()`, an imported `[[noreturn]]`: nothing
        // after the call runs, so whatever it moved is never read.
        if n->type_ != &null && self._tu.is_never(n->type_) {
            self._st.dead = true
        }
    }

    /// \p e passed to \p p (null for a pack tail) in \p mode. By value
    /// means a Kairo `x: T`, a C++ `T`, a pack tail, or a C++ `T&&`, which a
    /// MOVE argument binds as an xvalue (CallTyping::arg_info). A C++
    /// `const T&` / `T&` borrows. A COPY argument is copied, or against a
    /// forwarding reference deduces `T&`; _transfer passes over it.
    priv fn _pass(self, e: unsafe *Expr, p: unsafe *ParamDecl, mode: ParamMode) {
        if mode == ParamMode::Move {
            self._move_arg(e)
            return
        }

        if mode == ParamMode::Inout {
            self._mark_addr(e)
            return
        }

        if mode != ParamMode::Value {
            return
        }

        // A receiver passed as written (`Scalable::scale(a, 2)`) is the
        // object the method runs on, by address: nothing leaves it.
        if p != &null && p->is_self {
            return
        }

        if p != &null && self._lref_param(p) {
            self._mark_addr(e)
            return
        }

        var rref = p != &null && self._rref_param(p)
        // A Kairo `const x: T` is a reference to the caller's object for the
        // whole call (Doc: Functions, Parameter passing modes): a MOVE
        // argument is borrowed, not moved, and stays live.
        if !rref && p != &null && p->is_const && !p->is_pack && moves_on_pass(self.sc, e->type_) {
            return
        }

        // A C++ `T&&` binds an xvalue (`std::move(x)`), and a Kairo `const x: T`
        // is a `const T&`, and a pack forwards (`create<T>(...args)`): none copies, so a deleted copy constructor is
        // not in play (only a plain by-value parameter copies its argument).
        var borrows = rref || p != &null && (p->is_const || p->is_pack)
        self._transfer_checked(
            e,
            if (rref) => ("into a '@move' parameter") else => "into a by-value parameter",
            !borrows,
        )
    }

    /// The value a function returns, already walked. C++ already moves a
    /// returned local or parameter, and a cast there would cost it the
    /// elision. Anything else -- a field, a dereference -- is a copy unless
    /// cast.
    priv fn _return_value(self, v: unsafe *Expr) {
        if !isa<NamedIdentExpr>(self._tu.strip_parens(v)) {
            self._transfer(v, "out of the function")
            return
        }

        // C++'s implicit move of a returned name still needs a constructor
        // that takes it, and a record whose only transfer is a `@copy` its
        // instance dropped has none (`return a` with `a: [Mv]`, P308).
        if v != &null && (!v->is_poisoned()) && (!moves_on_pass(self.sc, v->type_)) {
            var unsafe *c  = self._tu.as_value(v->type_)
            var unsafe *rd = self._tu.record_decl(c)
            if rd != &null && !self._tu.is_tuple(c) {
                self._dropped_copy_place(v, c, rd, "out of the function")
            }
        }
    }

    /// No return type at all, or `void` / `!` (ExprBodyDesugar::_is_void).
    priv fn _is_void(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return true
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        var k = cast<BuiltinType>(c)->builtin
        return k == BuiltinKind::Void || k == BuiltinKind::Never
    }

    /// A user operator is a call: its operands are its arguments, the left
    /// one the receiver when the operator is a member. Binary operators,
    /// compound assignments (`acc += s`) and subscripts (`acc[t]`, the base
    /// the left operand) alike.
    priv fn _operator_operands(self,
                               opd:      unsafe *Decl,
                               via_free: bool,
                               lhs:      unsafe *Expr,
                               rhs:      unsafe *Expr) {
        var unsafe *f = dyn_cast<FunctionDecl>(opd)
        if f == &null {
            return
        }

        var view = cxx::std::vector<unsafe *ParamDecl>()
        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && !f->params[i]->is_self {
                view.push_back(f->params[i])
            }
        }

        var ops = cxx::std::vector<unsafe *Expr>()
        if via_free || !f->is_method() {
            ops.push_back(lhs)
        }

        ops.push_back(rhs)
        for var i: usize = 0; i < ops.size() && i < view.size(); ++i {
            if ops[i] != &null {
                self._pass(ops[i], view[i], view[i]->mode)
            }
        }
    }

    /// \p p is a C++ `T&` or `const T&` parameter.
    priv fn _lref_param(self, p: unsafe *ParamDecl) -> bool {
        if p->type_ == &null {
            return false
        }

        var unsafe *t = if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_
        return isa<CXXLValueRefType>(canon_unqual(t))
    }

    /// \p p is a C++ `T&&` parameter (a forwarding reference included).
    priv fn _rref_param(self, p: unsafe *ParamDecl) -> bool {
        if p->type_ == &null {
            return false
        }

        var unsafe *t = if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_
        return isa<CXXRValueRefType>(canon_unqual(t))
    }

    /// The FunctionDecl a callee denotes after CallTyping's promotion, or null.
    priv fn _callee_decl(self, callee: unsafe *Expr) -> unsafe *FunctionDecl {
        var unsafe *c = self._tu.strip_parens(callee)
        if c == &null {
            return &null
        }

        if isa<NamedIdentExpr>(c) {
            return dyn_cast<FunctionDecl>(cast<NamedIdentExpr>(c)->resolved_decl)
        }

        if isa<ChainExpr>(c) {
            var unsafe *ce = cast<ChainExpr>(c)
            if ce->steps.size() == 0 {
                return &null
            }

            var unsafe *last = ce->steps.get(ce->steps.size() - 1)
            return dyn_cast<FunctionDecl>(last->resolved_decl)
        }

        return &null
    }

    /// `obj.m(...)` / `p->m(...)` bind the receiver; `Type::m(obj, ...)` does not.
    priv fn _callee_binds_receiver(self, callee: unsafe *Expr) -> bool {
        var unsafe *c = self._tu.strip_parens(callee)
        if c == &null || !isa<ChainExpr>(c) {
            return false
        }

        var unsafe *ce = cast<ChainExpr>(c)
        if ce->steps.size() == 0 {
            return false
        }

        var unsafe *last = ce->steps.get(ce->steps.size() - 1)
        return last->access_kind != ChainExpr::AccessKind::ColonColon
    }

    /// (a) movability of the type; (b) the binding becomes moved-from.
    priv fn _move_arg(self, e: unsafe *Expr) {
        if e->is_poisoned() {
            return
        }

        self.n_moves += 1

        if e->type_ != &null {
            var unsafe *c  = canon_unqual(e->type_)
            var unsafe *rd = self._tu.record_decl(c)
            if rd != &null {
                // A tuple's facts are its elements' folded (ClassLifecycle::
                // facts_of_type); its pattern's hang on the parameters.
                var is_tup = self._tu.is_tuple(c)
                var tf     = lifecycle_of(self.sc)->facts_of_type(c)
                var unsafe *facts = if (is_tup) => (unsafe &tf)
                                    else => lifecycle_of(self.sc)->facts_of(rd)
                // A definite No only. An instance has facts of its own (ClassLifecycle, Instances); only a pattern reads Unknown.
                if facts->movable == LifecycleTri::No {
                    var b = self.sc->diag->report(
                        DiagID::SC051E,
                        e->range.start,
                        f"cannot move a value of type '{self._tu.str(c)}': {facts->why_not_movable}",
                    )

                    b.first(e->range)
                    if !is_tup { // a tuple is declared nowhere.
                        b.note(rd->range.start, type_declared_here())->first(rd->range)
                    }

                    b.emit()
                    e->poison()
                    self.n_errored += 1
                    return
                }
            }
        }

        self._mark(e, "into a '@move' parameter")
    }

    /// A transfer of \p e (passed by value, initialized from, assigned,
    /// returned): a MOVE value moves (Doc: Ownership, Function Parameters).
    /// Only an lvalue is recorded -- C++ moves a temporary on its own --
    /// and not a const one, which cannot be moved from. The site goes to
    /// SemaContext::move_sites, where CopyMoveLowering casts it, and the
    /// binding, or the part of it, is moved-from.
    priv fn _transfer(self, e: unsafe *Expr, const how: string) {
        self._transfer_checked(e, how, true)
    }

    /// _transfer; \p copies is false when the receiving slot is a reference
    /// (no copy happens, so _uncopyable_place has nothing to reject).
    priv fn _transfer_checked(self, e: unsafe *Expr, const how: string, copies: bool) {
        if e == &null || e->is_poisoned() {
            return
        }

        if !moves_on_pass(self.sc, e->type_) {
            if copies && self._uncopyable_place(e, how) {
                return
            }

            self._dependent_transfer(e)
            return
        }

        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return
        }

        if self._const_place(x) || self._const_root(e) {
            return
        }

        self.sc->move_sites.insert(e as usize as u64)
        self.n_moves += 1
        self._mark(e, how)
    }

    /// A transfer of an lvalue of a record whose copy constructor is
    /// deleted -- an imported C++ one (`var o = llvm::outs()`,
    /// `take(get_nc())`), or a Kairo class whose `@copy` is `= delete`
    /// (P306): clang rejects the copy at codegen, so Kairo refuses it first
    /// (the semantic-independence rule). A prvalue is elided, never copied,
    /// and a reference parameter takes no transfer, so neither reaches here;
    /// a MOVE record moves (moves_on_pass) and never asks.
    priv fn _uncopyable_place(self, e: unsafe *Expr, const how: string) -> bool {
        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return false
        }

        // An imported `T&` return types as the reference (the referee is
        // the object copied).
        var unsafe *c  = self._tu.as_value(e->type_)
        var unsafe *rd = self._tu.record_decl(c)
        if rd == &null || self._tu.is_tuple(c) {
            return false
        }

        var unsafe *facts = lifecycle_of(self.sc)->facts_of(rd)
        if facts->copyable != LifecycleTri::No {
            return self._dropped_copy_place(e, c, rd, how)
        }

        // A Kairo record's deleted `@copy` is where the fix goes. Such a
        // record transfers no way at all (NON_TRANSFER), so assigning one is
        // already SC071E ("its transfer constructor is deleted"): not twice.
        var unsafe *del = self._deleted_copy_ctor(rd)
        if del != &null && self._assigning {
            return false
        }

        if del != &null {
            var kb = self.sc->diag->report(
                DiagID::SC182E,
                e->range.start,
                f"cannot copy a value of type '{self._tu.str(c)}': {facts->why_not_copyable}",
            )

            kb.first(e->range)
            kb.note(del->range.start, "the copy constructor is deleted here")->first(del->range)
            kb.emit()
            e->poison()
            self.n_errored += 1
            return true
        }

        if !decl_is_imported(rd) {
            return false
        }

        var b = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            f"cannot copy a value of type '{self._tu.str(c)}': {facts->why_not_copyable}",
        )

        b.first(e->range)
        b.note(rd->range.start, type_declared_here())->first(rd->range)
        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// A copy of an lvalue of a Kairo generic record whose declared `@copy`
    /// constructor its instance loses to that constructor's `requires`
    /// (`[Mv]`: Vector's copy needs T's, vector.k). ClassLifecycle reads
    /// the declaration, so the type is COPY and the transfer is a copy, but
    /// C++ drops the constructor from the instance and clang rejected the
    /// copy (P308). A class declares one transfer constructor (SC057E), so
    /// such a record has no move to fall back on either. An assignment is
    /// reported too: the derived `op =` is constrained the same way, and no
    /// other check sees it.
    priv fn _dropped_copy_place(self,
                                e:          unsafe *Expr,
                                c:          unsafe *Type,
                                rd:         unsafe *Decl,
                                const how:  string) -> bool {
        if decl_is_imported(rd) || !self._has_constrained_copy(rd) {
            return false
        }

        var dc = ConformanceChecking(self.sc).dropped_copy(c)
        if dc.ctor == &null {
            return false
        }

        var ts  = self._tu.str(c)
        var msg = f"cannot copy a value of type '{ts}': its copy constructor's requirements do not hold for it"
        if dc.element != &null {
            var es = self._tu.str(dc.element)
            msg = f"cannot copy a value of type '{ts}': copying it copies each '{es}', and '{es}' cannot be copied"
        }

        var b = self.sc->diag->report(DiagID::SC182E, e->range.start, msg)
        b.first(e->range)
        b.note(
            e->range.start,
            f"'{ts}' is a copy type, so the transfer {how} copies it, and it has no move to fall back on (its one transfer constructor is '@copy'): take it as a 'const' parameter or through a pointer, or build it in place",
        )
        b.note(dc.ctor->range.start, "the copy constructor is constrained here")->first(dc.ctor->range)
        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// \p rd declares a `@copy` constructor with a `requires` clause: the
    /// only shape _dropped_copy_place has to evaluate, checked first so
    /// every other copy skips the evaluation.
    priv fn _has_constrained_copy(self, rd: unsafe *Decl) -> bool {
        var unsafe *pd = self._tu.pattern_of(rd)
        var unsafe *cd = dyn_cast<ClassDecl>(pd)
        var unsafe *sd = dyn_cast<StructDecl>(pd)
        var ms: unsafe *FrozenList<unsafe *FunctionDecl> = &null
        if cd != &null {
            ms = unsafe &cd->methods
        } else if sd != &null {
            ms = unsafe &sd->methods
        } else {
            return false
        }

        for var i: usize = 0; i < ms->size(); ++i {
            var unsafe *m = (*ms)[i]
            if m != &null && m->transfer == TransferKind::Copy && m->requires_clause != &null {
                return true
            }
        }

        return false
    }

    /// The `@copy ... = delete` a Kairo class or struct \p rd declares
    /// itself, or null (an imported record, or one not copyable for another
    /// reason -- a field, a base, a move constructor alone -- which keeps
    /// the old path).
    priv fn _deleted_copy_ctor(self, rd: unsafe *Decl) -> unsafe *FunctionDecl {
        if decl_is_imported(rd) {
            return &null
        }

        var unsafe *cd = dyn_cast<ClassDecl>(rd)
        if cd != &null {
            return self._deleted_copy_in(unsafe &cd->methods)
        }

        var unsafe *sd = dyn_cast<StructDecl>(rd)
        if sd != &null {
            return self._deleted_copy_in(unsafe &sd->methods)
        }

        return &null
    }

    priv fn _deleted_copy_in(self, methods: unsafe *FrozenList<unsafe *FunctionDecl>) -> unsafe *FunctionDecl {
        for var i: usize = 0; i < methods->size(); ++i {
            var unsafe *m = (*methods)[i]
            if m != &null && m->transfer == TransferKind::Copy && m->body_kind == FnBodyKind::Delete {
                return m
            }
        }

        return &null
    }

    /// A transfer of a value whose category its generic instance decides
    /// (`var y = x` with `x: T`): MOVE for `relay<Str>`, COPY for
    /// `relay<i32>`, and one C++ template body serves both. It is cast to
    /// `T&&` when nothing reads the binding again (PendingMove), which moves
    /// a MOVE instance and, at a COPY instance's last use, moves where the
    /// copy could not be observed (Doc: Ownership, COPY types). Left a copy
    /// when it is read again. The pattern does not know the category
    /// (ClassLifecycle, Unknown), so it marks nothing; the read is kept with
    /// the site (_demote_pending) and an instance that cannot copy the value
    /// reports the use after move (ConformanceChecking::_check_reuse).
    /// Bindings only: a part of `self` or of a pointee is never moved from.
    priv fn _dependent_transfer(self, e: unsafe *Expr) {
        if e->type_ == &null || self._st.dead {
            return
        }

        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || isa<Expressions::PackExpansionExpr>(x) {
            return
        }

        if x->value_category != Expr::ValueCategory::LValue {
            return
        }

        if self._const_place(x) {
            return
        }

        var unsafe *c = canon_unqual(e->type_)
        if c == &null || !c->is_dependent() && !c->is_instantiation_dependent() {
            return
        }

        // An element of a pack (`for a in args`): EmitIR's per-element
        // lambda has no `T` to spell a `T&&` with.
        if c->contains_unexpanded_pack() || e->type_->contains_unexpanded_pack() {
            return
        }

        if lifecycle_of(self.sc)->facts_of_type(c).category != LifecycleCategory::Unknown {
            return
        }

        var        path = ""
        var unsafe *d   = self._place_root(e, unsafe &path)
        if d == &null {
            return
        }

        // Only storage this body owns: not a part of a const binding, and
        // not a parameter that refers to the caller's object.
        if self._const_root(e) {
            return
        }

        if isa<ParamDecl>(d) {
            var unsafe *pd = cast<ParamDecl>(d)
            if pd->mode != ParamMode::Value && pd->mode != ParamMode::Move {
                return
            }
        }

        var pm = PendingMove()
        pm.d    = d
        pm.path = path
        pm.site = e
        self._st.add_pending(pm)
        self._tentative.push_back(e)
        self._tentative_decl.push_back(d)
    }

    /// A read of \p path under \p d: every pending transfer out of storage
    /// it overlaps was not the last use, so it stays a copy.
    /// \p at is the read, kept with the site for the instance check
    /// (_reuse_site): at a MOVE instance the read is a use after move.
    priv fn _demote_pending(self, d: unsafe *Decl, const path: string, at: unsafe *Expr) {
        var k: usize = 0
        while k < self._st.pend.size() {
            var pm = self._st.pend[k]
            if pm.d != d || !path_overlaps(pm.path, path) {
                k += 1
                continue
            }

            var seen = false
            for var r: usize = 0; r < self._reuse_decl.size(); ++r {
                if self._reuse_decl[r] == d {
                    seen = true
                }
            }

            if !seen && at != &null {
                self._reuse_site.push_back(pm.site)
                self._reuse_read.push_back(at)
                self._reuse_decl.push_back(d)
            }

            if pm.is_pack {
                cast<Expressions::PackExpansionExpr>(pm.site)->reread = true
            } else {
                self._demoted.insert(pm.site as usize as u64)
            }

            self._st.pend.erase(self._st.pend.cbegin() + (k as isize))
        }
    }

    /// \p e is a part of a const binding (`other.v` in a copy constructor's
    /// `const other`): its fields are not typed const, but C++ makes them
    /// so, and a `T&&` cast of one does not compile.
    priv fn _const_root(self, e: unsafe *Expr) -> bool {
        var        path = ""
        var unsafe *d   = self._place_root(e, unsafe &path)
        if d == &null {
            return false
        }

        if isa<VariableDecl>(d) {
            return cast<VariableDecl>(d)->is_const()
        }

        if isa<ParamDecl>(d) {
            return cast<ParamDecl>(d)->is_const
        }

        return false
    }

    /// \p e, or the binding it is a part of (`x`, `x.f`, `x[i]`, through
    /// any steps), has its address taken: see _addr.
    priv fn _mark_addr(self, e: unsafe *Expr) {
        var unsafe *x = self._tu.strip_parens(e)
        while x != &null {
            if isa<Expressions::UnaryOperatorExpr>(x)
                && cast<Expressions::UnaryOperatorExpr>(x)->is_mode_marker {
                x = self._tu.strip_parens(cast<Expressions::UnaryOperatorExpr>(x)->operand)
                continue
            }

            if isa<ChainExpr>(x) {
                x = self._tu.strip_parens(cast<ChainExpr>(x)->base)
                continue
            }

            if isa<Expressions::SubscriptExpr>(x) {
                x = self._tu.strip_parens(cast<Expressions::SubscriptExpr>(x)->base)
                continue
            }

            break
        }

        if x == &null || !isa<NamedIdentExpr>(x) {
            return
        }

        var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
        if d != &null {
            self._addr.insert(d as usize as u64)
        }
    }

    /// A const binding, or a place typed const.
    priv fn _const_place(self, x: unsafe *Expr) -> bool {
        if x->type_ != &null && canon_has_const(x->type_) {
            return true
        }

        if !isa<NamedIdentExpr>(x) {
            return false
        }

        var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
        if d == &null {
            return false
        }

        if isa<VariableDecl>(d) {
            return cast<VariableDecl>(d)->is_const()
        }

        if isa<ParamDecl>(d) {
            return cast<ParamDecl>(d)->is_const
        }

        return false
    }

    /// The binding \p e is, or the part of one (`p.a.b`), becomes moved-from.
    /// Anything else -- a temporary, `self`, a dereference -- records nothing.
    priv fn _mark(self, e: unsafe *Expr, const how: string) {
        var        path = ""
        var unsafe *d   = self._place_root(e, unsafe &path)
        if d == &null {
            return
        }

        var mp = MovedPart()
        mp.d    = d
        mp.path = path
        mp.at   = e->range
        mp.how  = how
        self._st.mark(mp)
    }

    /// The tracked binding \p e names, whole or by a field path written in
    /// full (`p.a.b`, path "a.b"), or null.
    priv fn _place_root(self, e: unsafe *Expr, path: unsafe *string) -> unsafe *Decl {
        var unsafe *x = self._tu.strip_parens(e)
        if x == &null {
            return &null
        }

        if isa<NamedIdentExpr>(x) {
            var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
            if d == &null || !self._tracked(d) {
                return &null
            }

            *path = ""
            return d
        }

        if !isa<ChainExpr>(x) {
            return &null
        }

        var        all = false
        var unsafe *d  = self._chain_root(cast<ChainExpr>(x), &*path, unsafe &all)
        return if (all) => (d) else => &null
    }

    /// The tracked binding at the base of \p c and the field path of the
    /// `.field` steps that lead it (\p all: every step is one). Null when
    /// the base is not a tracked binding.
    priv fn _chain_root(self,
                        c:           unsafe *ChainExpr,
                        @inout path: string,
                        all:         unsafe *bool) -> unsafe *Decl {
        if c->base == &null {
            return &null
        }

        var unsafe *b = self._tu.strip_parens(c->base)
        if b == &null || !isa<NamedIdentExpr>(b) {
            return &null
        }

        var unsafe *d = cast<NamedIdentExpr>(b)->resolved_decl
        if d == &null || !self._tracked(d) {
            return &null
        }

        var p        = ""
        var i: usize = 0
        while i < c->steps.size() {
            var unsafe *st = c->steps.get(i)
            if st->access_kind != ChainExpr::AccessKind::Dot {
                break
            }

            var unsafe *fd = dyn_cast<FieldDecl>(st->resolved_decl)
            if fd == &null || fd->is_static() {
                break
            }

            if p.size() > 0 {
                p += "."
            }

            // `t.1` is bound to the tuple's field `_1` but has no name node
            // (an ordinal is not an identifier): the path spells the ordinal.
            if st->is_tuple_index() {
                p += f"{st->index}"
            } else {
                p += self.sc->ctx->get_spelling(st->name->name)
            }

            i += 1
        }

        (path) = p
        *all   = i == c->steps.size()
        return d
    }

    /// The source text of \p e, for a note.
    priv fn _spelled(self, e: unsafe *Expr) -> string {
        return self.sc->ctx->get_spelling(e->range)
    }

    /// Locals and value parameters. Not `self`, not fields, not statics.
    priv fn _tracked(self, d: unsafe *Decl) -> bool {
        if isa<ParamDecl>(d) {
            return !cast<ParamDecl>(d)->is_self
        }

        if isa<VariableDecl>(d) {
            return !cast<VariableDecl>(d)->is_static()
        }

        return false
    }

    /// # reads

    priv fn _read(self, n: unsafe *NamedIdentExpr) {
        var unsafe *d = n->resolved_decl
        if d == &null {
            return
        }

        self._read_part(n, d, "")
    }

    /// A read of \p path under \p d, through the name \p n. An error when
    /// it touches a moved part: the part itself, something inside it, or the
    /// whole binding while a part of it is gone.
    priv fn _read_part(self, n: unsafe *NamedIdentExpr, d: unsafe *Decl, const path: string) {
        if self._st.dead { // unreachable: nothing to say.
            return
        }

        self._demote_pending(d, path, n)
        // One error per USE as well: a loop body's second pass, or a finally
        // body walked once per exit of its block, reaches the same node again
        // after a redeclaration re-armed the binding's report.
        if n->is_poisoned() {
            return
        }

        var i = self._st.overlap_of(d, path)
        if i == usize::MAX {
            return
        }

        // Keyed on the BINDING alone (MoveState::reported): the first read
        // after the move is the error; later reads stay quiet until a
        // reassignment clears it.
        if self._st.was_reported(d) {
            return
        }

        self._st.reported.push_back(d)

        var mp   = self._st.moved[i]
        var root = self.sc->ctx->get_spelling(n->name)
        var gone = if (mp.path.size() == 0) => (root) else => root + "." + mp.path
        var read = if (path.size() == 0) => (root) else => root + "." + path
        var msg  = f"'{gone}' is used after being moved"
        if !path_within(path, mp.path) {
            msg = f"'{read}' is used after its part '{gone}' was moved"
        }

        var b = self.sc->diag->report(DiagID::SC052E, n->range.start, msg)
        b.first(n->range)
        b.note(mp.at.start, f"'{gone}' was moved here, {mp.how}")->first(mp.at)
        b.note(n->range.start, f"assign a new value to '{gone}' before using it again")
        b.emit()
        n->poison()
        self.n_errored += 1
    }
}
