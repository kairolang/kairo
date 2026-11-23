/// --- The Kairo Project ------- Scripts/LlvmEraseCheck/erase_check.k --- ///
///
///   Finds an erase on an LLVM hash container inside a loop over that same
///   container.
///
///   From LLVM 23 an erase on llvm::DenseMap, DenseSet, SmallDenseMap,
///   SmallDenseSet, StringMap or StringSet invalidates every iterator of
///   the container, not only the erased one. A loop that erases from the
///   container it walks (`for *e in m { m.erase(..) }`, or a `while` /
///   indexed `for` holding one of its iterators) then reads a dead
///   iterator, and llvm::make_early_inc_range does not save it: the
///   iterator it holds is invalidated too.
///
///   The checker is a separate program over the compiler's own modules,
///   not a compiler pass. It runs the compiler's front end to Sema on one
///   entry file with the flags a build passes (`kairo <entry.k> <flags>`),
///   walks every checked file under the roots it is given, and reports:
///
///     HIT   an erase-like call on the loop's container, in the loop body
///           or in a function the body calls (one level), where the
///           container reaches the function as an argument or as a field
///           of the same `self`;
///     PASS  the container handed by reference to a function the checker
///           cannot follow (no body in the graph);
///     CALL  every erase-like call it saw, with its receiver class
///           (`target`, `other`, `unresolved`), so a quiet run can be told
///           from one that looked at nothing;
///     FILE  every file it walked;
///     UNCHECKED  a file whose Sema stopped before its checks (no walk);
///     DIAG  an error the front end reported.
///
///   The receiver of a call and the loop's container are compared by their
///   access path (`self._map`, a local, a parameter), built from resolved
///   declarations, so two spellings of one path match and two locals of the
///   same name do not.
///
///   usage: erase_check <entry.k> <kairo flags...>
///     ERASE_CHECK_ROOTS  ':'-separated path prefixes of the files to walk
///                        (default: every file of the graph).
///   Exit 1 when there is a HIT, 2 when the front end did not run.
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
ffi "c++" import "Native/Log.hh"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "cstdlib"
ffi "c++" import "cstring"

import AST::Context::ASTContext::ASTContext
import AST::DeclFacts::decl_name
import AST::ExprFacts::strip_parens
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    QualifiedType,
    RecordType,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl,
    ParamDecl,
    VariableDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CallExpr,
    ImplicitBoundaryCastExpr,
    NamedArgExpr,
    TypeCastExpr,
    UnaryOperatorExpr,
    UnsafeExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
    IndexedForStmt,
    RangedForStmt,
    WhileLoopStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    PointerType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Driver::CompilerInstance::CompilerInstance
import Driver::Runtime::init_runtime
import Driver::TUStage::TUStage
import Location::SourceLocation::SourceLocation
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Support::FileIO::Path::Path
import Token::TokenKind::TokenKind
import Tooling::ParseAPI::{
    ParseOptions,
    parse_file,
}
import Tooling::SemaObserver::SemaObserver
import std::c_char
import std::io

/// # Containers and calls

/// The record names whose erase invalidates every iterator from LLVM 23.
/// DenseMapBase and DenseSetImpl are the bases the members are declared
/// in; a receiver is typed as the derived template, but a `*DenseMapBase`
/// parameter is the same container.
fn is_target_record(const n: string) -> bool {
    return n == "DenseMap"
        || n == "SmallDenseMap"
        || n == "DenseMapBase"
        || n == "DenseSet"
        || n == "SmallDenseSet"
        || n == "DenseSetImpl"
        || n == "StringMap"
        || n == "StringSet"
}

/// Members that remove entries. `clear` and `shrink_and_clear` empty the
/// container, which invalidates as an erase does.
fn is_erase_name(const n: string) -> bool {
    return n == "erase"
        || n == "remove"
        || n == "erase_if"
        || n == "remove_if"
        || n == "extract"
        || n == "clear"
        || n == "shrink_and_clear"
}

/// The record `t` names through qualifiers, pointers and references, or
/// null.
fn record_of(t: unsafe *Type) -> unsafe *RecordType {
    var unsafe *x    = t
    var        guard = 0
    while x != &null && guard < 32 {
        ++guard
        if x->canonical != &null && x->canonical != x {
            x = x->canonical
            continue
        }

        var unsafe *rt = dyn_cast<RecordType>(x)
        if rt != &null {
            return rt
        }

        var unsafe *qt = dyn_cast<QualifiedType>(x)
        if qt != &null {
            x = qt->inner
            continue
        }

        var unsafe *pt = dyn_cast<PointerType>(x)
        if pt != &null {
            x = pt->pointee
            continue
        }

        var unsafe *lr = dyn_cast<CXXLValueRefType>(x)
        if lr != &null {
            x = lr->referee
            continue
        }

        var unsafe *rr = dyn_cast<CXXRValueRefType>(x)
        if rr != &null {
            x = rr->referee
            continue
        }

        return &null
    }

    return &null
}

/// The target container's record name, or "" when `t` is not one.
fn target_name(t: unsafe *Type) -> string {
    var unsafe *rt = record_of(t)
    if rt == &null || rt->decl == &null {
        return ""
    }

    var n = decl_name(rt->decl)
    if is_target_record(n) {
        return n
    }

    return ""
}

/// `e` without the wrappers that do not change which object it names:
/// parentheses, `unsafe`, casts, `&` / `*`, a mode marker, a named
/// argument's label.
fn strip_place(e: unsafe *Expr) -> unsafe *Expr {
    var unsafe *x    = e
    var        guard = 0
    while x != &null && guard < 64 {
        ++guard
        x = strip_parens(x)
        if x == &null {
            return x
        }

        var unsafe *u = dyn_cast<UnsafeExpr>(x)
        if u != &null {
            x = u->operand
            continue
        }

        var unsafe *tc = dyn_cast<TypeCastExpr>(x)
        if tc != &null {
            x = tc->operand
            continue
        }

        var unsafe *bc = dyn_cast<ImplicitBoundaryCastExpr>(x)
        if bc != &null {
            x = bc->original
            continue
        }

        var unsafe *na = dyn_cast<NamedArgExpr>(x)
        if na != &null {
            x = na->value
            continue
        }

        var unsafe *un = dyn_cast<UnaryOperatorExpr>(x)
        if un != &null
            && (un->is_mode_marker
                || un->op_token.kind == TokenKind::OpAmp
                || un->op_token.kind == TokenKind::OpStar) {
            x = un->operand
            continue
        }

        return x
    }

    return x
}

/// What a call is, read off its callee.
class CallShape {
    /// The called member's or function's name; "" for an expression callee.
    pub var name: string = ""
    /// The called declaration, or null.
    pub var decl: unsafe *Decl = &null
    /// A member call's receiver (`m` in `m.erase(k)`), or null.
    pub var recv: unsafe *Expr = &null
    /// The receiver's access path when the receiver is a chain prefix
    /// (`self._map` in `self._map.erase(k)`); "" for a receiver that is an
    /// expression of its own (recv set).
    pub var recv_path: string = ""
    /// The receiver's type.
    pub var recv_type: unsafe *Type = &null
    /// True for `a.f()` / `a->f()`; false for `f()` and `ns::f()`.
    pub var is_member: bool = false

    fn CallShape(self) = default
}

/// # Locations and paths

class Where {
    pub var file: string = ""
    pub var line: usize  = 0
    pub var col:  usize  = 0

    fn Where(self) = default

    fn str(self) -> string {
        return f"{self.file}:{self.line}:{self.col}"
    }
}

fn where_of(ctx: unsafe *ASTContext, loc: SourceLocation) -> Where {
    var w = Where()
    if ctx == &null || ctx->sm == &null {
        return w
    }

    w.file = ctx->sm->get_filename(loc)
    var lc = ctx->sm->get_line_col(loc)
    w.line = lc.line
    w.col  = lc.column
    return w
}

/// The root of an access path: `$self`, `$p<index>` for a parameter (its
/// position in the parameter list, `self` included), or `name@line:col` of
/// any other declaration, so two locals of one name are two roots.
fn root_key(ctx: unsafe *ASTContext, n: unsafe *NamedIdentExpr) -> string {
    var        name = n->ctx->get_spelling(n->name)
    var unsafe *d   = n->resolved_decl
    if d == &null {
        return f"?{name}"
    }

    var unsafe *p = dyn_cast<ParamDecl>(d)
    if p != &null {
        if p->is_self {
            return "$self"
        }

        return f"$p{p->index}"
    }

    var w = where_of(ctx, d->range.start)
    return f"{name}@{w.line}:{w.col}"
}

/// The access path of a place expression, or "" when it is not one (a
/// call result, a literal). Steps are joined with `.` whatever their
/// separator: `p->m` and `(*p).m` are one path.
fn path_of(ctx: unsafe *ASTContext, e: unsafe *Expr) -> string {
    var unsafe *x = strip_place(e)
    if x == &null {
        return ""
    }

    var unsafe *ni = dyn_cast<NamedIdentExpr>(x)
    if ni != &null {
        return root_key(ctx, ni)
    }

    var unsafe *ch = dyn_cast<ChainExpr>(x)
    if ch != &null {
        return chain_prefix(ctx, ch, ch->steps.size())
    }

    return ""
}

/// The path of `ch`'s base and its first `n` steps; "" when a step is not
/// a named member access.
fn chain_prefix(ctx: unsafe *ASTContext, ch: unsafe *ChainExpr, n: usize) -> string {
    if ch->base == &null {
        return ""
    }

    var s = path_of(ctx, ch->base)
    if s.size() == 0 {
        return ""
    }

    for var i: usize = 0; i < n; ++i {
        var unsafe *st = ch->steps.get(i)
        if st->name == &null
            || (st->access_kind != ChainExpr::AccessKind::Dot
                && st->access_kind != ChainExpr::AccessKind::Arrow) {
            return ""
        }

        s += "." + st->name->ctx->get_spelling(st->name->name)
    }

    return s
}

/// A path for display: roots without their disambiguating location.
fn show_path(const p: string) -> string {
    var out: string = ""
    var skip        = false
    for var i: usize = 0; i < p.size(); ++i {
        var c = p.data()[i]
        if c == ('@' as u8) {
            skip = true
            continue
        }

        if c == ('.' as u8) {
            skip = false
        }

        if !skip {
            out.push(c)
        }
    }

    return out
}

fn shape_of(ctx: unsafe *ASTContext, c: unsafe *CallExpr) -> CallShape {
    var        s       = CallShape()
    var unsafe *callee = strip_parens(c->callee)
    if callee == &null {
        return s
    }

    var unsafe *ni = dyn_cast<NamedIdentExpr>(callee)
    if ni != &null {
        s.name = ni->ctx->get_spelling(ni->name)
        s.decl = ni->resolved_decl
        return s
    }

    var unsafe *ch = dyn_cast<ChainExpr>(callee)
    if ch == &null || ch->steps.size() == 0 {
        return s
    }

    var        n     = ch->steps.size()
    var unsafe *last = ch->steps.get(n - 1)
    if last->name == &null {
        return s
    }

    s.name = last->name->ctx->get_spelling(last->name->name)
    s.decl = last->resolved_decl
    if last->access_kind != ChainExpr::AccessKind::Dot
        && last->access_kind != ChainExpr::AccessKind::Arrow {
        return s
    }

    s.is_member = true
    if n == 1 {
        s.recv      = ch->base
        s.recv_path = path_of(ctx, ch->base)
        if ch->base != &null {
            s.recv_type = ch->base->type_
        }
    } else {
        s.recv_type = ch->steps.get(n - 2)->resolved_type
        s.recv_path = chain_prefix(ctx, ch, n - 1)
    }

    return s
}

/// The key a function is known by across files: where it is declared and
/// its name. A call's resolved declaration and the definition the walk
/// visits are the same node, but the key is a string so it can be compared
/// after every file's Sema has finished.
fn fn_key(d: unsafe *Decl, ctx: unsafe *ASTContext) -> string {
    if d == &null {
        return ""
    }

    var w = where_of(ctx, d->range.start)
    return f"{w.file}:{w.line}:{w.col}:{decl_name(d)}"
}

/// # What the walk records

/// An erase-like call on a target container.
class EraseRec {
    pub var at:     Where
    pub var method: string = ""
    pub var cont:   string = "" ///< the record name (DenseMap, ...).
    pub var path:   string = "" ///< the receiver's access path; "" for an expression receiver.

    fn EraseRec(self) = default
}

/// A call to a function other than an erase, made in a loop body.
class CallRec {
    pub var at:     Where
    pub var callee: string   = "" ///< fn_key of the called declaration.
    pub var name:   string   = ""
    pub var base:   string   = "" ///< a member call's receiver path; "" otherwise.
    pub var args:   [string]      ///< each argument's access path, in order; "" for a non-place.

    fn CallRec(self) = default
}

/// The erase-like calls a function body makes on target containers.
class FnSummary {
    pub var key:      string     = ""
    pub var has_self: bool       = false
    pub var erases:   [EraseRec]

    fn FnSummary(self) = default
}

/// A loop over a target container.
class LoopRec {
    pub var at:     Where
    pub var kind:   string     = "" ///< for, while, indexed for.
    pub var cont:   string     = ""
    pub var path:   string     = ""
    pub var erases: [EraseRec]
    pub var calls:  [CallRec]

    fn LoopRec(self) = default
}

/// Collects a body's erase-like calls on target containers and its other
/// calls.
class BodyScan derives RecursiveASTVisitor<BodyScan> {
    pub var sctx:   unsafe *ASTContext = &null
    pub var erases: unsafe *[EraseRec] = &null
    pub var calls:  unsafe *[CallRec]  = &null ///< null: calls are not recorded.

    fn BodyScan(self,
                ctx:    unsafe *ASTContext,
                erases: unsafe *[EraseRec],
                calls:  unsafe *[CallRec]) {
        self.sctx   = ctx
        self.erases = erases
        self.calls  = calls
    }

    pub fn scan(self, s: unsafe *Stmt) {
        if s != &null {
            self.dyn()->dispatch_stmt(s)
        }
    }

    pub fn scan_expr(self, e: unsafe *Expr) {
        if e != &null {
            self.dyn()->dispatch_expr(e)
        }
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var unsafe *c = unsafe (n as unsafe *CallExpr)
        var        sh = shape_of(self.sctx, c)
        if sh.is_member && is_erase_name(sh.name) {
            var tn = target_name(sh.recv_type)
            if tn.size() > 0 {
                self.erases->push(EraseRec())
                var *r = &(*self.erases)[self.erases->size() - 1]
                r->at     = where_of(self.sctx, n->range.start)
                r->method = sh.name.copy()
                r->cont   = tn.copy()
                r->path   = sh.recv_path.copy()
                return true
            }
        }

        if sh.decl == &null || self.calls == &null {
            return true
        }

        self.calls->push(CallRec())
        var *cr = &(*self.calls)[self.calls->size() - 1]
        cr->at     = where_of(self.sctx, n->range.start)
        cr->callee = fn_key(sh.decl, self.sctx)
        cr->name   = sh.name.copy()
        if sh.is_member {
            cr->base = sh.recv_path.copy()
        }

        for var i: usize = 0; i < n->args.size(); ++i {
            cr->args.push(path_of(self.sctx, *n->args.get(i)))
        }

        return true
    }
}

/// The first subexpression of `e` (itself included) whose type is a target
/// container, searched through calls (`m.keys()`, `make_early_inc_range(m)`)
/// and chains; null when there is none.
fn find_container(e: unsafe *Expr) -> unsafe *Expr {
    var unsafe *x = strip_place(e)
    if x == &null {
        return &null
    }

    if target_name(x->type_).size() > 0 {
        return x
    }

    var unsafe *c = dyn_cast<CallExpr>(x)
    if c != &null {
        var unsafe *callee                   = strip_parens(c->callee)
        var        ch:     unsafe *ChainExpr = &null
        if callee != &null {
            ch = dyn_cast<ChainExpr>(callee)
        }

        if ch != &null {
            var unsafe *b = find_container(ch->base)
            if b != &null {
                return b
            }

            // `self._m.keys()`: the receiver is a chain prefix, whose
            // type is the step before the call's.
            var n = ch->steps.size()
            if n >= 2 && target_name(ch->steps.get(n - 2)->resolved_type).size() > 0 {
                return callee
            }
        }

        for var i: usize = 0; i < c->args.size(); ++i {
            var unsafe *a = find_container(*c->args.get(i))
            if a != &null {
                return a
            }
        }

        return &null
    }

    var unsafe *bin = dyn_cast<BinaryOperatorExpr>(x)
    if bin != &null {
        var unsafe *l = find_container(bin->lhs)
        if l != &null {
            return l
        }

        return find_container(bin->rhs)
    }

    var unsafe *bo = dyn_cast<ChainExpr>(x)
    if bo != &null {
        return find_container(bo->base)
    }

    return &null
}

/// The path and record name of a container `find_container` returned.
/// A callee chain (`self._m.keys`) names the container by its prefix.
fn container_path(ctx: unsafe *ASTContext, e: unsafe *Expr, @inout name: string) -> string {
    var unsafe *ch = dyn_cast<ChainExpr>(e)
    if ch != &null && target_name(e->type_).size() == 0 {
        var n = ch->steps.size()
        name = target_name(ch->steps.get(n - 2)->resolved_type)
        return chain_prefix(ctx, ch, n - 1)
    }

    name = target_name(e->type_)
    return path_of(ctx, e)
}

/// # The per-file walk


class FileWalk derives RecursiveASTVisitor<FileWalk> {
    pub var wctx:  unsafe *ASTContext = &null
    pub var loops: [LoopRec]
    pub var fns:   [FnSummary]
    pub var inv:   [string]

    fn FileWalk(self, ctx: unsafe *ASTContext) {
        self.wctx = ctx
    }

    /// Records the loop and scans its body (and an indexed for's update).
    /// Nothing else pushes to `loops` while the record is filled: the
    /// body's own loops are visited after this returns.
    fn _loop(self,
             const kind: string,
             cont:       unsafe *Expr,
             at:         SourceLocation,
             body:       unsafe *Stmt,
             extra:      unsafe *Expr) {
        if cont == &null {
            return
        }

        self.loops.push(LoopRec())
        var *r = &self.loops[self.loops.size() - 1]
        r->at   = where_of(self.wctx, at)
        r->kind = kind.copy()
        var cname: string = ""
        r->path = container_path(self.wctx, cont, &cname)
        r->cont = cname.copy()
        var sc = BodyScan(self.wctx, unsafe &r->erases, unsafe &r->calls)
        sc.scan(body)
        sc.scan_expr(extra)
    }

    fn visit_ranged_for_stmt(self, n: *RangedForStmt) -> bool {
        self._loop(
            "for",
            find_container(n->iterable),
            n->range.start,
            unsafe (n->body as unsafe *Stmt),
            &null,
        )

        return true
    }

    fn visit_while_loop_stmt(self, n: *WhileLoopStmt) -> bool {
        self._loop(
            "while",
            find_container(n->cond),
            n->range.start,
            unsafe (n->body as unsafe *Stmt),
            &null,
        )

        return true
    }

    fn visit_indexed_for_stmt(self, n: *IndexedForStmt) -> bool {
        var unsafe *c = find_container(n->cond)
        if c == &null && n->init != &null {
            var unsafe *ds = dyn_cast<DeclStmt>(n->init)
            if ds != &null && ds->decl != &null {
                var unsafe *vd = dyn_cast<VariableDecl>(ds->decl)
                if vd != &null {
                    c = find_container(vd->init)
                }
            }
        }

        self._loop(
            "indexed for",
            c,
            n->range.start,
            unsafe (n->body as unsafe *Stmt),
            n->update,
        )

        return true
    }

    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if n->body_block == &null {
            return true
        }

        self.fns.push(FnSummary())
        var *s = &self.fns[self.fns.size() - 1]
        s->key = fn_key(unsafe (n as unsafe *Decl), self.wctx)
        for var i: usize = 0; i < n->params.size(); ++i {
            if (*n->params.get(i))->is_self {
                s->has_self = true
            }
        }

        var sc = BodyScan(self.wctx, unsafe &s->erases, &null)
        sc.scan(unsafe (n->body_block as unsafe *Stmt))
        return true
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var sh = shape_of(self.wctx, unsafe (n as unsafe *CallExpr))
        if !sh.is_member || !is_erase_name(sh.name) {
            return true
        }

        var cls: string = "target"
        var tn          = target_name(sh.recv_type)
        if sh.recv_type == &null {
            cls = "unresolved"
        } else if tn.size() == 0 {
            cls = "other"
            var unsafe *rt = record_of(sh.recv_type)
            if rt != &null && rt->decl != &null {
                tn = decl_name(rt->decl)
            }
        }

        var at = where_of(self.wctx, n->range.start)
        self.inv.push(
            f"CALL {at.str()}: {cls} {tn} .{sh.name} on '{show_path(sh.recv_path)}'",
        )

        return true
    }
}

/// Every file's walk, kept whole: the records are filled in place and
/// never copied.
class Collected {
    pub var mu:        kairo::std::Mutex
    pub var files:     [string]
    pub var unchecked: [string]
    pub var walks:     [unsafe *FileWalk]

    fn Collected(self) = default

    fn op finally (self) {
        for *w in self.walks {
            @destroy unsafe (*w as *FileWalk)
        }
    }
}

/// Holds its state by pointer: an observer stays copyable, as its base is.
class Observer derives SemaObserver {
    pub var roots: unsafe *[string]  = &null
    pub var out:   unsafe *Collected = &null

    fn Observer(self) = default

    fn _wanted(self, const f: string) -> bool {
        if self.roots->size() == 0 {
            return true
        }

        for *r in *self.roots {
            if f.starts_with(r->copy()) {
                return true
            }
        }

        return false
    }

    override fn on_checked(self, sc: unsafe *SemaContext) {
        if sc == &null || sc->ctx == &null || sc->ctx->sm == &null {
            return
        }

        var f = sc->ctx->sm->get_filename(sc->ctx->fid)
        if !self._wanted(f) {
            return
        }

        if (sc->phase as u8) < (SemaPhase::Checked as u8) || sc->tu == &null {
            var lock = kairo::std::LockGuard(self.out->mu)
            self.out->unchecked.push(f"{f} (phase {(sc->phase as u8) as u32})")
            return
        }

        var unsafe *w = unsafe (@create FileWalk(sc->ctx) as unsafe *FileWalk)
        w->run(sc->tu)

        var lock = kairo::std::LockGuard(self.out->mu)
        self.out->files.push(f)
        self.out->walks.push(w)
    }
}

/// # After every file: the report

fn find_fn(c: *Collected, const key: string) -> unsafe *FnSummary {
    for *w in c->walks {
        for var i: usize = 0; i < (*w)->fns.size(); ++i {
            if (*w)->fns[i].key == key {
                return unsafe &(*w)->fns[i]
            }
        }
    }

    return &null
}

/// The caller's path for a path written in the callee: `$self...` becomes
/// the call's receiver path, `$p<i>...` the i-th argument's; "" when it
/// maps to nothing the caller can name.
fn map_path(const p: string, cr: *CallRec, has_self: bool) -> string {
    var head: string = ""
    var rest: string = ""
    var dot          = false
    for var i: usize = 0; i < p.size(); ++i {
        var ch = p.data()[i]
        if !dot && ch == ('.' as u8) {
            dot = true
        }

        if dot {
            rest.push(ch)
        } else {
            head.push(ch)
        }
    }

    if head == "$self" {
        if cr->base.size() == 0 {
            return ""
        }

        return cr->base.copy() + rest
    }

    if head.size() < 3 || head.data()[0] != ('$' as u8) || head.data()[1] != ('p' as u8) {
        return ""
    }

    var idx: usize = 0
    for var i: usize = 2; i < head.size(); ++i {
        idx = idx * 10 + ((head.data()[i] - ('0' as u8)) as usize)
    }

    // A parameter's index counts `self`; the call's arguments do not.
    if has_self {
        if idx == 0 {
            return ""
        }

        idx -= 1
    }

    if idx >= cr->args.size() || cr->args[idx].size() == 0 {
        return ""
    }

    return cr->args[idx].copy() + rest
}

/// True when `owner` is a proper prefix of the path `p`: `p` is a field
/// reached through it.
fn owner_of(const owner: string, const p: string) -> bool {
    if owner.size() == 0 || owner.size() >= p.size() {
        return false
    }

    return p.starts_with(owner.copy()) && p.data()[owner.size()] == ('.' as u8)
}

fn report(c: *Collected) -> i32 {
    var lines: [string]
    var inv:   [string]
    var hits            = 0
    var looked          = 0
    var nfns:  usize    = 0
    for *w in c->walks {
        nfns += (*w)->fns.size()
        for *i in (*w)->inv {
            inv.push(i->copy())
        }
    }

    for *w in c->walks {
        for *l in (*w)->loops {
            if l->path.size() == 0 {
                continue
            }

            ++looked
            var loop_at = f"{l->kind} over {l->cont} '{show_path(l->path)}' at {l->at.str()}"
            for *e in l->erases {
                if e->path == l->path {
                    lines.push(
                        f"HIT {e->at.str()}: .{e->method} on the container of the {loop_at}",
                    )

                    ++hits
                }
            }

            for *cr in l->calls {
                // The container itself, or an object it is a field of
                // (`self.forget(k)` inside a loop over `self._map`).
                var passes = cr->base == l->path
                var owns   = owner_of(cr->base, l->path)
                for *a in cr->args {
                    if *a == l->path {
                        passes = true
                    }

                    if owner_of(*a, l->path) {
                        owns = true
                    }
                }

                if !passes && !owns {
                    continue
                }

                var unsafe *s = find_fn(c, cr->callee)
                if s == &null {
                    if !passes {
                        continue
                    }

                    lines.push(
                        f"PASS {cr->at.str()}: '{show_path(l->path)}' handed to {cr->name}, which has no body in the graph, inside the {loop_at}",
                    )

                    continue
                }

                for *e in s->erases {
                    if map_path(e->path, cr, s->has_self) == l->path {
                        lines.push(
                            f"HIT {cr->at.str()}: {cr->name} erases the container of the {loop_at} (.{e->method} at {e->at.str()})",
                        )

                        ++hits
                    }
                }
            }
        }
    }

    lines.sort()
    var last: string = ""
    for *ln in lines {
        if *ln != last {
            io::println(*ln)
        }

        last = ln->copy()
    }

    inv.sort()
    for *i in inv {
        io::println(*i)
    }

    for *f in c->files {
        io::println(f"FILE {*f}")
    }

    for *f in c->unchecked {
        io::println(f"UNCHECKED {*f}")
    }

    io::println(
        f"SUMMARY files={c->files.size()} unchecked={c->unchecked.size()} loops_over_targets={looked} functions={nfns} erase_calls={inv.size()} hits={hits}",
    )

    if hits > 0 {
        return 1
    }

    return 0
}

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    kairo::Logger::init(kairo::Logger::Level::Warn)
    var unsafe *llvm_init = init_runtime(argc, argv)
    finally {
        @cxx::delete llvm_init
    }

    if argc < 2 {
        io::println("usage: erase_check <entry.k> <kairo flags...>")
        return 2
    }

    var col             = Collected()
    var roots: [string]
    var obs             = Observer()
    obs.roots = unsafe &roots
    obs.out   = unsafe &col
    var unsafe *env_roots = cxx::std::getenv(r"ERASE_CHECK_ROOTS")
    if env_roots != &null {
        var all = string(
            unsafe ((env_roots as unsafe *const u8) as *const u8),
            cxx::std::strlen(env_roots),
        )

        var cur: string = ""
        for var i: usize = 0; i < all.size(); ++i {
            var ch = all.data()[i]
            if ch == (':' as u8) {
                if cur.size() > 0 {
                    roots.push(cur.copy())
                }

                cur = ""
            } else {
                cur.push(ch)
            }
        }

        if cur.size() > 0 {
            roots.push(cur.copy())
        }
    }

    var unsafe *ci = unsafe (@create CompilerInstance(argc, argv) as unsafe *CompilerInstance)
    finally {
        @destroy unsafe (ci as *CompilerInstance)
    }

    if !ci->args_ok() || ci->invocation()->input_files.empty() {
        io::println(
            "erase_check: the command line was rejected or names no entry file",
        )

        return 2
    }

    ci->invocation()->frontend.sema_observer = unsafe ((&obs) as unsafe *void)
    ci->initialize(Path::cwd())

    var opts = ParseOptions{}
    opts.stop_at       = TUStage::Sema
    opts.capture_diags = true
    var unit = parse_file(
        ci,
        Path(ci->invocation()->input_files[0].copy()),
        opts,
    )

    for var i: usize = 0; i < unit.diags.size(); ++i {
        var *d = &unit.diags[i]
        if d->code.ends_with("E") || d->code.ends_with("F") {
            io::println(
                f"DIAG {d->file}:{d->line}:{d->column}: [{d->code}] {d->message}",
            )
        }
    }

    if !unit.ok {
        io::println(
            f"erase_check: the front end stopped (errors={unit.errors})",
        )

        report(&col)
        return 2
    }

    return report(&col)
}
