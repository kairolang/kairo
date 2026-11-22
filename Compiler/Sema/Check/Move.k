/// --- The Kairo Project ---------------------------- Sema/Check/Move.k --- ///
///
/// Moves: the type must be movable, and a moved-from binding may
/// not be read again until it is reassigned.
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
///         A transfer of such a value out of storage the body does not own
///         (`*p`, `p->f`, `*f()`, a part of `self` or of a reference
///         parameter) is not pending: it moves at an instance that cannot
///         copy the value and copies at every other (MoveKind::Instance),
///         as the transfer of a MOVE value does in a body that is not
///         generic. A later read of that storage, and a transfer out of a
///         const place, are judged per instance too. So is a transfer of a
///         pack element (`for a in args { one(a) }`), which copies at every
///         instance: one that cannot copy the element reports SC182E. A
///         value of a record over the pack (`o: Outcome<i32, E...>`) is no
///         element and is pending like any other.
///
///     (b'') Match binders. A `case var x` binder of a type that cannot be
///         copied borrows what it matched (PatternTyping). A transfer of
///         one inside a constructor pattern (`case .Found(var x)`) --
///         the arm's value, a return, a by-value argument, an initializer
///         -- takes the payload by move when the match owns its scrutinee:
///         a temporary, or a local or by-value parameter of the body
///         (_owned_scrutinee). That scrutinee is then moved-from, from the
///         transfer on, so a later read of it is a use after move. Over any
///         other scrutinee the transfer is a copy the type cannot make
///         (d). The binder stays read-only either way; once every body is
///         walked it names the payload by `T&` (VariableDecl::moves_payload),
///         and each of its transfers moves the payload out at that point.
///
///     (c) Use after move. A moved local or parameter (`self` included), or
///         a part of one, is MOVED-FROM from that point. A part is a field
///         path (`p.a.b`, `self.r`) or what a pointer on the path points at
///         (`p->r`, `*p`, `h.link->a`). A later READ that touches it -- the
///         part, something inside it, or storage that holds it by value --
///         in the same function body is an error; the pointer itself stays
///         readable. An assignment to it, or to something enclosing it,
///         clears it; at a join, moved on either path means moved. A `var`
///         declaration starts a new binding. A move out of an element
///         (`v[i]`) leaves the container moved-from: which element is gone
///         is not tracked. `p[i]` on a pointer is not tracked at all.
///
///     (d) Copies it cannot make. A transfer that copies a value whose type
///         cannot be copied is SC182E here rather than in clang: a MOVE value
///         out of a place const by its type or root (place_has_const_root:
///         `self.r` in a `const self` method, `p.r` of a `const p`), an
///         element reached through a C++ `T&` (never moved from), a MOVE
///         value reached through a pointer or a reference (`p->f`, `*p`, a
///         reference a call returns: _unowned_move; `cxx::std::move(...)`
///         is the explicit hand-off and moves), a deleted
///         or constraint-dropped `@copy`, `v[i] = v[j]` of a MOVE element (a
///         move out of `x[i]` is not decided), and four copies the language
///         makes on its own: `yield` of a const place, a plain `for` binder,
///         the left operand of an `op +` derived from `op +=`, and the
///         elements of a vector, set or map literal.
///
///     Storage the body does not own (`self`, an `@inout` parameter, what
///     a parameter points at, a `|*x|` capture inside its closure) that is
///     still moved-from at a return is recorded on the function
///     (FunctionDecl::move_out, _exit), and a call marks the same part of
///     its argument moved-from (_call_leaves). Only the called declaration
///     is consulted: a call through an interface, a virtual method, a
///     function pointer or a stored closure marks nothing. A C++ function's
///     body is read instead (_call_cxx): a MOVE argument it moves out of
///     through a `T&` / `T*` is moved-from, and one it cannot be inspected
///     for is an unchecked assumption.
///
///     Each record says on which outcomes of the call the part is
///     moved-from (MoveOut::when), from the exits that leave it so: `return
///     true` / `return false` of a `bool` function, `return null` / a return
///     of a value that cannot be null of a `T?` function, any other return,
///     and a panic that leaves the body (a `panic`, or a call that may panic
///     outside a `try` that catches it). A call that is a condition -- of an
///     `if`, an `else if`, a `while` or a C-style `for`, alone or under `!`,
///     `&&`, `||`, a postfix `?`, or `== null` / `!= null` -- marks each
///     branch with the outcomes that reach it (_cond). A `return` of such
///     a condition from a `bool` function, or of a call of the function's
///     own `T?` type, leaves once per outcome of the call from the state
///     that outcome reaches, so the function's record carries its callee's
///     (_return); an expression body is that `return`. A local
///     initialised from a call (`var ok = q.push(&t)`) holds the call's
///     outcome (CondLink): its marks stand on every outcome until a test of
///     the local, which splits them as a test of the call would, as long as
///     nothing else has used the local or moved the part. A call anywhere
///     else, its result passed on, marks what any return leaves.
///     The path a panic takes from a call marks what a panic leaves: the
///     catch arms of the enclosing `try`, or the caller's own panic exit.
///     A part moved on the way to a panic is recorded with the panic's
///     type when that is known statically (a `panic X`, a call with a
///     declared set, a callee's own record), and the path is taken once
///     per such type: a typed catch arm receives only the panics it
///     catches (_arm_entry_of), and one that catches the type stops it.
///
///     By name only. A second pointer to the same object does not see a
///     move made through the first; that stays AMT's (Stage 2).
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
import AST::Context::DeclContext::DeclContextKind
import AST::DeclFacts::{
    decl_is_ctor,          decl_is_imported,     decl_methods,         decl_name,
    fn_keeps_value_params, param_is_plain_value, place_has_const_root, type_may_be_destructive,
    value_param_rule,
}
import AST::ExprFacts::{
    callee_expr_decl,
    setter_store_target,
}
import AST::Kind::ExprKind::ExprKind
import AST::Kind::StmtKind::StmtKind
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LangAttrs,
    WellKnownType,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    canon_has_const,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,     FieldDecl,        FnBodyKind,   FnModifier,    FunctionDecl,  InterfaceDecl,
    MOVE_ON_FALSE, MOVE_ON_NON_NULL, MOVE_ON_NULL, MOVE_ON_OTHER, MOVE_ON_PANIC, MOVE_ON_RETURN,
    MOVE_ON_TRUE,  MoveOut,          MoveOutState, ParamDecl,     ParamOwner,    StorageClass,
    StructDecl,    TransferKind,     VariableDecl,
}
import AST::Node::Expressions
import AST::Node::Patterns::{
    BindingPattern,
    ConstructorPattern,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    ChainExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements
import AST::Node::Statements::IterKind
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
    GenericParamType,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::{
    RecursiveASTVisitor,
    named_call_arg_value,
}
import Diagnostic::Code::DiagCode
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::NoteText::type_declared_here
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::{
    ClassLifecycle,
    LifecycleCategory,
    LifecycleFacts,
    LifecycleTri,
    lifecycle_of,
    moves_on_pass,
}
import Sema::Check::Conformance::ConformanceChecking
import Sema::Check::EffectPropagation::{
    PanicKnown, panic_bind_call,      panic_call_receiver, panic_call_set, panic_dep,
    panic_home, panic_set_of_fn_type, pset_add,            pset_has,
}
import Sema::Check::LocalDisposition::{
    LocalEnds,            destructive_type,      disarm_refusal,     disarm_storage_refusal,
    local_has_dtor,       names_cxx_member_type, part_moved_refusal, part_record_refusal,
    record_real_transfer, union_storage_refusal,
}
import Sema::Foreign::ForeignInstantiate::{
    CXX_MOVE_DEPTH,
    CxxMoveKind,
    CxxMoveVerdict,
}
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::BinderBorrow::{
    borrowed_binder_of,
    is_borrowing_binder,
    note_borrowed_binder,
}
import Sema::Type::TypeUtil::TypeUtil
import Support::Ascii::rfind_byte
import Token::Token::Token
import Token::TokenKind::TokenKind

/// What made a MovedPart. Every kind is moved-from for use-after-move;
/// only a REAL transfer moved the object out, so only after one may a
/// provider skip the moved-from object's destructor (disarm_local_at,
/// Sema/Check/LocalDisposition.k). Every other kind may leave the object
/// owning its resource, and skipping its destructor would leak it.
pub enum MoveKind derives u8 {
    /// Real: a Kairo move construction (a variable, a field, a by-value
    /// parameter initialized from it), a move assignment, or a return of
    /// its value. The site is in move_sites and C++ moves the object.
    Transfer = 0,
    /// `x.finally()` ended the whole local (CallExpr::finalize): a read is
    /// SC303E, a second `finally()` SC304E, and an assignment does not
    /// revive it (MoveState::clear keeps it; the object is destroyed).
    Finalize,
    /// Not real: a C++ `T&&` parameter or a forwarding pack. The callee
    /// gets a reference and may never take the value.
    RefParam,
    /// Not real: a parameter no declaration names (a call through a
    /// function value, an unresolved or a C variadic callee), whose
    /// passing mode is not known.
    UnknownParam,
    /// Not real: a `@move` parameter, emitted as C++ `T&&`. The callee
    /// holds a reference to the caller's object, not the object.
    MoveParam,
    /// Not real: a function with no readable body, taken to move what it
    /// can reach (_call_unseen). It may as well have kept it in place.
    Unseen,
    /// Not real: a C++ body moves out of the object through a `T&` / `T*`
    /// (_call_cxx). The object stays in the caller's storage, moved-from,
    /// and C++ still destroys a moved-from object.
    CxxBody,
    /// Not real: a C++ call whose body could not be inspected, taken to
    /// move under -fstrict-cxx-moves. Nothing is known to have moved.
    CxxAssumed,
    /// Not real: a part a callee's record leaves moved-from
    /// (_call_leaves, FunctionDecl::move_out). The callee moved out of the
    /// caller's storage, which still holds the moved-from object.
    CalleeLeaves,
    /// Not real: moved into a closure by capture. The closure object owns
    /// the moved value, but the capture is built where the closure is, and
    /// a provider has to prove that closure is built on the path, once.
    Capture,
    /// Not real: what a closure's body leaves moved-from in storage it
    /// captured, applied where the closure is made, not where it runs.
    ClosureLeaves,
    /// A generic body's transfer out of storage it does not own (`*p`,
    /// `p->f`, `self.f`) of a value whose category the instance decides
    /// (_instance_move): a move at an instance that cannot copy the value, a
    /// copy at every other. A read of it is judged per instance
    /// (_reuse_site), never here.
    Instance,
}

/// One moved part: a binding, and the path under it that was moved out
/// ("" for the whole binding, "a.b" for `p.a.b`). A `*` segment is what a
/// pointer points at: "*.a" for `p->a`, "link.*" for `*h.link`.
pub class MovedPart {
    pub var d:     unsafe *Decl
    pub var path:  string       = ""
    pub var shown: string       = "" ///< the storage as source text: `p.a.b`, `p->a`, `*p`.
    pub var elem:  string       = "" ///< the element expression, when one was moved out of this storage.
    pub var at:    SourceRange ///< where it was moved.
    pub var how:   string       = "" ///< where it went, for the note.
    /// `path` step by step: the field per `.field`, null per pointer followed.
    pub var segs: [unsafe *Decl]
    /// Moved by a call: where the callee's body moves it.
    pub var has_via:  bool        = false
    pub var via:      SourceRange
    pub var via_text: string      = "" ///< the note at `via`; empty for the callee's move.
    pub var kind:     MoveKind    = MoveKind::Transfer
    /// The moved expression, for a Transfer, RefParam or MoveParam; null
    /// for every other kind.
    pub var site: unsafe *Expr = &null
    /// Moved because -fstrict-cxx-moves took a C++ call it could not
    /// inspect to move it, here or in a callee (MoveOut::cxx_at): that
    /// call. Invalid otherwise.
    pub var cxx_at: SourceRange = SourceRange::invalid()
    fn MovedPart(self) { }

    fn copy(const self) -> MovedPart {
        var r = MovedPart()
        r.d        = self.d
        r.path     = self.path.copy()
        r.shown    = self.shown.copy()
        r.elem     = self.elem.copy()
        r.at       = self.at
        r.how      = self.how.copy()
        r.segs     = self.segs.copy()
        r.has_via  = self.has_via
        r.via      = self.via
        r.via_text = self.via_text.copy()
        r.kind     = self.kind
        r.site     = self.site
        r.cxx_at   = self.cxx_at
        return r
    }
}

/// An independent copy of `v`.
pub fn copy_parts(const v: [MovedPart]) -> [MovedPart] {
    var out: [MovedPart]
    for var i: usize = 0; i < v.size(); ++i {
        out.push(v[i].copy())
    }

    return out
}

/// What an expression names in a body's bindings: a binding, and the path of
/// `.field`, `->field` and `*` steps under it. A subscript ends the path:
/// which element is not tracked, so the place is the container (`elem`).
pub class MovePlace {
    pub var d:     unsafe *Decl           = &null ///< the root binding; null when the expression names none.
    pub var name:  unsafe *NamedIdentExpr = &null ///< the root's name node.
    pub var path:  string                 = ""
    pub var shown: string                 = ""
    /// Every step of the expression is part of the place. False when a
    /// method, a static or an operator step follows: the path is then the
    /// storage that step reads.
    pub var whole: bool = false
    pub var elem:  bool = false ///< a subscript was crossed: path and shown name the container.
    /// A pointer is followed on the way: `ptr_path` / `ptr_shown` name the
    /// last one, the storage a store through the place reads.
    pub var has_ptr:   bool   = false
    pub var ptr_path:  string = ""
    pub var ptr_shown: string = ""
    /// `shown` ends in a dereference (`*p`), so a field after it is spelled
    /// `p->f`; `starred` when the pointer followed was itself spelled `*q`.
    pub var deref:   bool = false
    pub var starred: bool = false
    /// `path` step by step: the field per `.field`, null per pointer followed.
    pub var segs: [unsafe *Decl]
    /// Steps of the expression that are not part of the place (0 when
    /// `whole`); `opaque` when the first of them is a user `op ->`, whose
    /// result is storage of its own.
    pub var rest:   usize = 0
    pub var opaque: bool  = false
    fn MovePlace(self) { }

    /// The place `self` points at.
    fn through(self) {
        if self.elem {
            return
        }

        self.has_ptr   = true
        self.ptr_path  = self.path.copy()
        self.ptr_shown = self.shown.copy()
        self.starred   = self.deref
        self.path = if (self.path.size() == 0) => ("*") else => self.path.copy() + ".*"
        self.shown = "*" + self.shown
        self.deref = true
        var none: unsafe *Decl = &null
        self.segs.push(none)
    }

    /// The field `f` of `self`, declared by `fd`.
    fn field(self, const f: string, fd: unsafe *Decl) {
        if self.elem {
            return
        }

        self.segs.push(fd)

        self.path = if (self.path.size() == 0) => (f.copy()) else => self.path.copy() + "." + f
        if !self.deref {
            self.shown += "." + f
            return
        }

        self.shown = if (self.starred) => (f"({self.ptr_shown})->{f}")
                     else => f"{self.ptr_shown}->{f}"
        self.deref = false
    }
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
    /// site is the left operand of a derived `op +` (MoveCheck::
    /// _derived_operand): a later read leaves it a copy the type cannot make.
    pub var is_derived: bool = false
    fn PendingMove(self) { }

    fn copy(const self) -> PendingMove {
        var r = PendingMove()
        r.d          = self.d
        r.path       = self.path.copy()
        r.site       = self.site
        r.is_pack    = self.is_pack
        r.is_derived = self.is_derived
        return r
    }
}

/// `inner` is `outer` or a part of it.
pub fn path_within(const inner: string, const outer: string) -> bool {
    if outer.size() == 0 || inner == outer {
        return true
    }

    return inner.starts_with(outer.copy() + ".")
}

/// `a` and `b` name overlapping storage: one is the other or a part of it.
pub fn path_overlaps(const a: string, const b: string) -> bool {
    return path_within(a, b) || path_within(b, a)
}

/// A read of `read` touches the moved part `moved`: it is that part or
/// inside it, or it holds the part by value. Storage that only points at
/// the part (`p`, with `p->a` moved) is read without touching it.
pub fn read_touches(const moved: string, const read: string) -> bool {
    if path_within(read, moved) {
        return true
    }

    if !path_within(moved, read) {
        return false
    }

    var star = rfind_byte(moved, ('*' as u8))
    return star == moved.size() || star < read.size()
}

/// `a` and `b` are the same range.
pub fn same_range(a: SourceRange, b: SourceRange) -> bool {
    return a.start == b.start && a.end == b.end
}

/// A local initialised from a call (`var ok = q.push(&t)`, `var r? =
/// find(&t)`): the parts the call marked moved-from on every outcome, which
/// were whole before it, and the outcomes on which its record moves each.
/// A test of the local as a condition splits them as a test of the call
/// would (MoveCheck::_link_cond). It holds only while the local keeps the
/// call's value and each part keeps the call's mark: any other use of the
/// local drops it (the local may be changed through it), as does an
/// assignment to it, another move of a part (MoveState::mark), and a join
/// whose other side does not hold the same link.
pub class CondLink {
    pub var d:     unsafe *Decl         ///< the local.
    pub var site:  SourceRange          ///< the call: the `at` of every mark it made.
    pub var nul:   bool         = false ///< a `T?` result, tested against null; a `bool` otherwise.
    pub var parts: [MovedPart]
    pub var when:  [u8]
    fn CondLink(self) { }

    fn copy(const self) -> CondLink {
        var r = CondLink()
        r.d     = self.d
        r.site  = self.site
        r.nul   = self.nul
        r.parts = copy_parts(self.parts)
        r.when  = self.when.copy()
        return r
    }

    fn holds(self, const d: unsafe *Decl, const path: string) -> bool {
        for var i: usize = 0; i < self.parts.size(); ++i {
            if self.parts[i].d == d && self.parts[i].path == path {
                return true
            }
        }

        return false
    }

    /// `o` is the same link: the same local, from the same call, over the
    /// same parts.
    fn same(const self, const o: CondLink) -> bool {
        if self.d != o.d
            || self.nul != o.nul
            || !same_range(self.site, o.site)
            || self.parts.size() != o.parts.size() {
            return false
        }

        for var i: usize = 0; i < self.parts.size(); ++i {
            if self.parts[i].d != o.parts[i].d || self.parts[i].path != o.parts[i].path {
                return false
            }
        }

        return true
    }
}

/// The moved-from set on one path. `dead` after return/break/continue/panic
/// or a call that does not return: the path has left the block and
/// contributes nothing to a join.
pub class MoveState {
    pub var moved: [MovedPart]
    pub var dead:  bool        = false
    /// Bindings already reported used-after-move on this path. One error per
    /// BINDING, not per read: three reads of one moved `e` in a loop are one
    /// mistake, and three errors for it is the cascade the poison rule exists
    /// to prevent. Travels with the flow state -- so a reassignment (clear)
    /// re-arms it, a join unions it, and a loop's back edge carries it.
    pub var reported: [unsafe *Decl]
    /// Transfers still waiting to learn whether a read follows (PendingMove).
    pub var pend: [PendingMove]
    /// Locals whose value says which of a call's marks hold (CondLink).
    pub var links: [CondLink]
    /// Locals ended (`finally()`) on EVERY path reaching here: a join keeps
    /// only what both sides hold. The may-side is the MoveKind::Finalize
    /// parts of `moved`. Independent of `links`: a link says which of a
    /// call's marks hold, an ended local has no value to test.
    pub var ended: [unsafe *Decl]
    /// Locals moved by a real transfer a provider may disarm
    /// (LocalEnds::moved_at) on EVERY path reaching here; joined like
    /// `ended`. A whole assignment or a declaration takes the local out.
    /// A site whose evaluation the walk cannot place on every path it
    /// stands on (MoveCheck::_no_must) is not added: the set may say less
    /// than the truth, never more.
    pub var disarmed: [unsafe *Decl]
    /// Parts moved by a real transfer that may be left out of their
    /// local's destruction (LocalEnds::part_moved_at) on EVERY path
    /// reaching here; joined like `disarmed`. An assignment to a part, or
    /// to what holds it, takes it out.
    pub var parts: [MovedPart]
    fn MoveState(self) { }

    fn copy(const self) -> MoveState {
        var r = MoveState()
        r.moved    = copy_parts(self.moved)
        r.dead     = self.dead
        r.reported = self.reported.copy()
        for var i: usize = 0; i < self.pend.size(); ++i {
            r.pend.push(self.pend[i].copy())
        }

        for var i: usize = 0; i < self.links.size(); ++i {
            r.links.push(self.links[i].copy())
        }

        r.ended    = self.ended.copy()
        r.disarmed = self.disarmed.copy()
        r.parts    = copy_parts(self.parts)
        return r
    }

    fn has_part(const self, d: unsafe *Decl, const path: string) -> bool {
        for var i: usize = 0; i < self.parts.size(); ++i {
            if self.parts[i].d == d && self.parts[i].path == path {
                return true
            }
        }

        return false
    }

    fn link_of(self, d: unsafe *Decl) -> usize {
        for var i: usize = 0; i < self.links.size(); ++i {
            if self.links[i].d == d {
                return i
            }
        }

        return usize::MAX
    }

    fn drop_link(self, d: unsafe *Decl) {
        var i: usize = 0
        while i < self.links.size() {
            if self.links[i].d == d {
                self.links.remove(i)
                continue
            }

            i += 1
        }
    }

    fn is_disarmed(const self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self.disarmed.size(); ++i {
            if self.disarmed[i] == d {
                return true
            }
        }

        return false
    }

    fn is_ended(const self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self.ended.size(); ++i {
            if self.ended[i] == d {
                return true
            }
        }

        return false
    }

    /// The MoveKind::Finalize part of `d`, or usize(-1).
    fn finalized_at(self, d: unsafe *Decl) -> usize {
        for var i: usize = 0; i < self.moved.size(); ++i {
            if self.moved[i].d == d && self.moved[i].kind == MoveKind::Finalize {
                return i
            }
        }

        return usize::MAX
    }

    /// A declaration of `d`: a new binding, nothing of the last one left
    /// (a `finally()` of it, and a link, included: clear drops the link).
    fn forget(self, d: unsafe *Decl) {
        self.clear(d, "")
        var i: usize = 0
        while i < self.moved.size() {
            if self.moved[i].d == d {
                self.moved.remove(i)
                continue
            }

            i += 1
        }

        var k: usize = 0
        while k < self.ended.size() {
            if self.ended[k] == d {
                self.ended.remove(k)
                continue
            }

            k += 1
        }

        var m: usize = 0
        while m < self.disarmed.size() {
            if self.disarmed[m] == d {
                self.disarmed.remove(m)
                continue
            }

            m += 1
        }

        var q: usize = 0
        while q < self.parts.size() {
            if self.parts[q].d == d {
                self.parts.remove(q)
                continue
            }

            q += 1
        }
    }

    fn add_pending(self, const p: PendingMove) {
        for var i: usize = 0; i < self.pend.size(); ++i {
            if self.pend[i].site == p.site {
                return
            }
        }

        self.pend.push(p.copy())
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

    /// The first moved part a read of `path` under `d` touches.
    fn overlap_of(self, d: unsafe *Decl, const path: string) -> usize {
        for var i: usize = 0; i < self.moved.size(); ++i {
            if self.moved[i].d == d && read_touches(self.moved[i].path, path) {
                return i
            }
        }

        return usize::MAX
    }

    /// First move wins: the note points at where it happened first. A
    /// second move of a part a link holds, from anywhere but the link's
    /// call, is one a test of the local cannot take back: the link goes.
    fn mark(self, const p: MovedPart) {
        if self.index_of(p.d, p.path) == usize::MAX {
            self.moved.push(p.copy())
            return
        }

        var i: usize = 0
        while i < self.links.size() {
            if self.links[i].holds(p.d, p.path) && !same_range(self.links[i].site, p.at) {
                self.links.remove(i)
                continue
            }

            i += 1
        }
    }

    /// An assignment to `path` under `d`: that storage, and every part
    /// of it, holds a live value again, and a later move-then-use of it is a
    /// NEW mistake that must be reported, so the binding's report is dropped
    /// along with the move.
    fn clear(self, d: unsafe *Decl, const path: string) {
        self.drop_link(d)
        if path.size() == 0 {
            var m: usize = 0
            while m < self.disarmed.size() {
                if self.disarmed[m] == d {
                    self.disarmed.remove(m)
                    continue
                }

                m += 1
            }
        }

        var q: usize = 0
        while q < self.parts.size() {
            if self.parts[q].d == d && path_within(self.parts[q].path, path) {
                self.parts.remove(q)
                continue
            }

            q += 1
        }

        for var r: usize = 0; r < self.reported.size(); ++r {
            if self.reported[r] == d {
                self.reported.remove(r)
                break
            }
        }

        // A finalized local stays so: the store runs on a destroyed object,
        // and the read the caller reports after it names that.
        var i: usize = 0
        while i < self.moved.size() {
            if self.moved[i].d == d
                && self.moved[i].kind != MoveKind::Finalize
                && path_within(self.moved[i].path, path) {
                self.moved.remove(i)
                continue
            }

            i += 1
        }

        // A pending transfer out of the old value is that value's last use:
        // the new one is not the storage it read.
        var k: usize = 0
        while k < self.pend.size() {
            if self.pend[k].d == d && path_within(self.pend[k].path, path) {
                self.pend.remove(k)
                continue
            }

            k += 1
        }
    }
}

/// Moved on either path means moved. A dead path defers to the live one.
pub fn move_join(const a: MoveState, const b: MoveState) -> MoveState {
    if a.dead {
        return b.copy()
    }

    if b.dead {
        return a.copy()
    }

    // A link holds after the join only when it holds on both sides.
    var out = a.copy()
    out.links.clear()
    for var i: usize = 0; i < a.links.size(); ++i {
        for var k: usize = 0; k < b.links.size(); ++k {
            if a.links[i].same(b.links[k]) {
                out.links.push(a.links[i].copy())
                break
            }
        }
    }

    for var i: usize = 0; i < b.moved.size(); ++i {
        out.mark(b.moved[i])
    }

    // Reported on either path stays reported: re-reporting after the join
    // would be the second error for the mistake one branch already named.
    for var i: usize = 0; i < b.reported.size(); ++i {
        if !out.was_reported(b.reported[i]) {
            out.reported.push(b.reported[i])
        }
    }

    // Pending on either path: a read after the join demotes it either way.
    for var i: usize = 0; i < b.pend.size(); ++i {
        out.add_pending(b.pend[i])
    }

    // Ended on every path only when ended on both.
    var both: [unsafe *Decl]
    for var i: usize = 0; i < a.ended.size(); ++i {
        if b.is_ended(a.ended[i]) {
            both.push(a.ended[i])
        }
    }

    out.ended = both
    var moved_both: [unsafe *Decl]
    for var i: usize = 0; i < a.disarmed.size(); ++i {
        if b.is_disarmed(a.disarmed[i]) {
            moved_both.push(a.disarmed[i])
        }
    }

    out.disarmed = moved_both
    var parts_both: [MovedPart]
    for var i: usize = 0; i < a.parts.size(); ++i {
        if b.has_part(a.parts[i].d, a.parts[i].path) {
            parts_both.push(a.parts[i].copy())
        }
    }

    out.parts = parts_both
    return out
}

/// An independent copy of `v`.
pub fn copy_states(const v: [MoveState]) -> [MoveState] {
    var out: [MoveState]
    for var i: usize = 0; i < v.size(); ++i {
        out.push(v[i].copy())
    }

    return out
}

/// An independent copy of `v`.
pub fn copy_loops(const v: [LoopFrame]) -> [LoopFrame] {
    var out: [LoopFrame]
    for var i: usize = 0; i < v.size(); ++i {
        out.push(v[i].copy())
    }

    return out
}

/// An independent copy of `v`.
pub fn copy_tries(const v: [TryFrame]) -> [TryFrame] {
    var out: [TryFrame]
    for var i: usize = 0; i < v.size(); ++i {
        out.push(v[i].copy())
    }

    return out
}

/// One enclosing loop: the states at each `break` / `continue` inside it.
pub class LoopFrame {
    pub var breaks:    [MoveState]
    pub var continues: [MoveState]
    /// The join of the condition's false state at each evaluation: where
    /// the loop is left by its condition.
    pub var done:        MoveState
    pub var block_depth: usize     = 0 ///< _blocks.size() when the loop was entered; its body's block sits at this index.
    pub var has_label:   bool      = false ///< written `label: loop`; a labeled break/continue finds its frame by it.
    pub var label:       Token
    fn LoopFrame(self) { }

    fn copy(const self) -> LoopFrame {
        var r = LoopFrame()
        r.breaks      = copy_states(self.breaks)
        r.continues   = copy_states(self.continues)
        r.done        = self.done.copy()
        r.block_depth = self.block_depth
        r.has_label   = self.has_label
        r.label       = self.label
        return r
    }
}

/// One enclosing `try` body: the state at each point inside it where a
/// panic can leave it for its catch arms.
pub class TryFrame {
    pub var panics: [MoveState]
    /// Parallel to `panics`: the type of the panic that brought each state,
    /// null when it is not known statically.
    pub var panic_ty:    [unsafe *Type]
    pub var block_depth: usize          = 0 ///< _blocks.size() when the `try` was entered.
    /// A bare `catch` arm catches whatever reaches it: no panic passes the
    /// `try` to an enclosing one or out of the body.
    pub var catch_all: bool = false
    /// Per arm, in order: it takes a panic of any type (`arm_any`: a bare
    /// arm, or a filter that is unresolved, names a type parameter or is a
    /// C++ type), or only one of its filter's type (`arm_ty`, a set of one,
    /// as PanicWalk keeps an arm's type).
    pub var arm_any: [u8]
    pub var arm_ty:  cxx::std::vector<cxx::std::vector<unsafe *Type>>
    /// The typed arms' types: a panic of one of them stops here.
    pub var types: cxx::std::vector<unsafe *Type>
    /// A C++ exception arm: a C++ call in the body can leave every block
    /// inside it at a point the walk does not see.
    pub var cxx_arm: bool = false
    fn TryFrame(self) { }

    fn copy(const self) -> TryFrame {
        var r = TryFrame()
        r.panics      = copy_states(self.panics)
        r.panic_ty    = self.panic_ty.copy()
        r.block_depth = self.block_depth
        r.catch_all   = self.catch_all
        r.arm_any     = self.arm_any.copy()
        r.arm_ty      = self.arm_ty
        r.types       = self.types
        r.cxx_arm     = self.cxx_arm
        return r
    }
}

/// The parts a call's callee leaves moved-from in the caller's storage,
/// each with the outcomes on which it does (MoveOut::when). Applied by the
/// context the call is in (MoveCheck::_apply): the condition of an `if` or
/// a loop marks each branch with the outcomes that reach it.
pub struct CallMarks {
    pub var parts: [MovedPart]
    pub var when:  [u8]
    /// Parallel: the panic types on which a part with MOVE_ON_PANIC is
    /// moved-from (MoveOut::pcount); empty for a panic of any type.
    pub var ptys: cxx::std::vector<cxx::std::vector<unsafe *Type>>
}

extend CallMarks {
    fn copy(const self) -> CallMarks {
        var r = CallMarks{}
        r.parts = copy_parts(self.parts)
        r.when  = self.when.copy()
        r.ptys  = self.ptys
        return r
    }
}

/// A condition's state when it is true and when it is false
/// (MoveCheck::_cond).
pub struct CondStates {
    pub var t: MoveState
    pub var f: MoveState
    /// A call's outcome split the two: they differ by what its record
    /// leaves on each outcome. False when they are the same state, or
    /// differ only by an operand of `&&` / `||` run on one path.
    pub var split: bool = false
}

/// What one body's walk carries and a nested body (a function, a closure)
/// starts without: saved and restored as one value (MoveCheck::_enter_body /
/// _leave_body), so neither walker can restore part of it.
pub struct BodyFlow {
    pub var st:     MoveState
    pub var loops:  [LoopFrame]
    pub var blocks: [[unsafe *Statements::FinallyStmt]]
    pub var tries:  [TryFrame]
    pub var locals: [[unsafe *Decl]]
    pub var ends:   LocalEnds
    pub var leaves: usize                               = 0
}

pub class MoveCheck derives RecursiveASTVisitor<MoveCheck> {
    pub var  sc:     unsafe *SemaContext
    priv var _tu:    TypeUtil
    priv var _st:    MoveState
    priv var _loops: [LoopFrame]
    /// Pending finally bodies per open block, innermost block last (file
    /// header, Flow). Per body: saved and cleared across a nested function
    /// or closure like _st is.
    priv var _blocks: [[unsafe *Statements::FinallyStmt]]
    /// The `try` bodies open in this body, innermost last; per body like
    /// _blocks.
    priv var _tries: [TryFrame]
    /// Parallel to _blocks: the locals each open block has declared so far,
    /// whose scope an exit of the block leaves (_exit_check). Per body.
    priv var _block_locals: [[unsafe *Decl]]
    /// The body's locals and what ends them (Sema/Check/LocalDisposition.k).
    /// Per body; settled when its walk ends (_settle_locals).
    priv var _ends: LocalEnds
    /// The DeclStmt being dispatched is a C-style `for`'s init.
    priv var _for_init: bool = false
    /// Finally bodies being walked: a panic met inside one does not walk
    /// the pending bodies again, its own among them.
    priv var _fin_depth: usize = 0
    /// The local a `return` being left returns by a disarmed move
    /// (_return_value), null outside one: at that return's exits the
    /// local is moved, though no mark says so.
    priv var _returning: unsafe *Decl = &null
    /// Why no local of the body being walked may have a move disarmed
    /// ("" when they may): a constructor (CtorInitLowering may carry a local
    /// across its split as a slot), an `eval` or constexpr function (the
    /// union storage's destructor is not constexpr). A closure keeps its
    /// enclosing function's.
    priv var _body_refusal: string = ""
    /// Operands being walked that C++ never evaluates (`typeof e`): a move
    /// there is not made, so none of the local's moves may disarm.
    priv var _uneval: usize = 0
    /// Points met so far, in the body being walked (saved and restored
    /// around a nested one, _enter_body), where the walk leaves the
    /// expression it is in: a
    /// panic that leaves a call, a `return`, `break` or `continue`. A call
    /// whose arguments met one may be left between an argument and the
    /// call itself, so none of them hands its storage over
    /// (SemaContext::hand_sites).
    priv var _leaves: usize = 0
    /// No call of the body being walked hands storage to its callee
    /// (SemaContext::hand_sites): its frame can be destroyed at a point the
    /// walk has no exit for (an `async` function, suspended at an `await`),
    /// a C++ exception can leave it where the walk does not see, or its
    /// temporaries must be constexpr (`eval`). A closure keeps its
    /// enclosing function's.
    priv var _no_hand: bool = false
    /// The call whose argument _pass is binding and its callee, for the
    /// parameter's type as that call instantiates it (_pass_dest); null
    /// for an operator's operands.
    priv var _pass_call: unsafe *Expressions::CallExpr = &null
    priv var _pass_fn:   unsafe *FunctionDecl          = &null
    /// The arguments recorded so far that may hand their storage over
    /// (SemaContext::hand_sites) and name a whole local or parameter, with
    /// that binding: an assignment that builds the binding again from the
    /// call's result takes the hand back (_unhand).
    priv var _hand_log_e: [unsafe *Expr]
    priv var _hand_log_d: [unsafe *Decl]
    /// Arguments whose C++ evaluation order is not the walk's (a call with
    /// a named argument, which C++ evaluates in parameter order) or that run
    /// on some paths only (the arguments of a `?.` call): a real transfer
    /// there is not added to MoveState::disarmed.
    priv var _no_must: usize = 0
    /// Whole assignments met in this run: the first visit clears what an
    /// earlier check wrote (AssignOperatorExpr::remake).
    priv var _remake_seen: llvm::DenseSet<u64>
    /// The body being walked is marked `panic`: a panic that no enclosing
    /// `try` stops leaves it. False at file scope.
    priv var _body_panics: bool = false
    /// The call being dispatched is a condition (_cond): it leaves its
    /// marks in `_split` for the branches instead of applying them, and
    /// sets `_split_done`.
    priv var _split_req:  bool      = false
    priv var _split_done: bool      = false
    priv var _split:      CallMarks
    /// The call that initialises the local being declared, when a test of
    /// the local can split its marks (_link_target); `_link` is what it
    /// marked, filled by _call once `_link_got` is that call.
    priv var _link_call: unsafe *Expressions::CallExpr = &null
    /// The variable whose initializer is being walked: a literal that is
    /// that whole initializer fills it (TypeUtil::literal_fills).
    priv var _init_owner: unsafe *VariableDecl = &null
    /// The tuple literal that is the scrutinee of the match being walked.
    priv var _unbuilt_tuple: unsafe *Expr = &null
    /// The scrutinee of the match whose case patterns are being walked:
    /// each binder they declare inside a constructor pattern
    /// (`.Found(var v)`, `_ctor_depth`) is recorded against it.
    priv var _pattern_scrut: unsafe *Expr = &null
    priv var _ctor_depth:    usize        = 0
    /// A match expression whose value is discarded (an expression
    /// statement): it yields nothing, so no arm transfers its value.
    priv var _discarded_match: unsafe *Expr = &null
    /// Every payload binder seen, to its match's scrutinee (both as u64),
    /// and every match binder seen.
    priv var _binder_scrut:  llvm::DenseMap<u64, u64>
    priv var _match_binders: llvm::DenseSet<u64>
    /// The borrowing binders an arm moves out of a match that owns its
    /// scrutinee (_take_payload). They take the payload by move: written
    /// to the binders once every body is walked (run).
    priv var _taken:    [unsafe *VariableDecl]
    priv var _link_got: unsafe *Expressions::CallExpr = &null
    priv var _link:     CondLink
    /// The expression body of the function being walked, until
    /// dispatch_expr meets it and walks it as the body's return (_return).
    priv var _ret_expr: unsafe *Expr = &null
    /// The label of the LabeledStmt being entered, for the loop it wraps
    /// to take onto its frame (_loop); cleared there.
    /// The transfer being checked is an assignment's right-hand side
    /// (_uncopyable_place leaves a Kairo NON_TRANSFER record to SC071E).
    priv var _assigning: bool = false
    /// The arguments being passed are those of `cxx::std::move` /
    /// `cxx::std::forward`: an explicit hand-off, which may move out of any
    /// place it names (_unowned_move).
    priv var _handoff: bool = false
    /// The variable a transfer initializes (traverse_variable_decl), for the
    /// borrow fix-it of _unowned_move.
    priv var _init_var: unsafe *VariableDecl = &null
    /// Where an implicit copy through a deprecated constructor was reported
    /// (_deprecated_copy): one warning a place, however many checks see it.
    priv var _copy_warned: [SourceLocation]
    /// The function whose body is being walked; null in a closure body and
    /// at file scope. `_caps` is the by-pointer captures of the closure
    /// being walked. `_out` is what the exits met so far leave moved-from
    /// in storage the body does not own (_exit).
    priv var _fn:   unsafe *FunctionDecl = &null
    priv var _caps: [unsafe *Decl]
    priv var _out:  [MovedPart]
    /// Returns of the body met so far, and at how many each `_out` entry
    /// was moved-from (MoveOut::always).
    priv var _exits:    usize   = 0
    priv var _out_hits: [usize]
    /// Parallel to `_out`: the outcomes of the exits it was moved-from at
    /// (MoveOut::when).
    priv var _out_when: [u8]
    /// Parallel to `_out`: the types of the panics it was moved-from at,
    /// and whether one of them was not known statically (MoveOut::pcount).
    priv var _out_pty:  cxx::std::vector<cxx::std::vector<unsafe *Type>>
    priv var _out_pany: [u8]
    /// The bindings of bare catch arms met: `panic e` of one rethrows a
    /// panic whose type is not known statically.
    priv var _bare_binds: llvm::DenseSet<u64>
    /// Functions whose walk has started. A call into one of this TU's not
    /// yet walked walks it first (_walk_callee), so what it leaves
    /// moved-from is known at the call; `_depth` bounds that nesting.
    priv var _walked:            llvm::DenseSet<u64>
    priv var _depth:             usize               = 0
    priv var _pending_has_label: bool                = false
    priv var _pending_label:     Token
    pub var  n_moves:            usize               = 0
    pub var  n_errored:          usize               = 0
    /// Every non-pack PendingMove site seen, in order, and the ones a later
    /// read demoted. What is left once every body is walked moves (run).
    priv var _tentative:      [unsafe *Expr]
    priv var _demoted:        llvm::DenseSet<u64>
    priv var _tentative_decl: [unsafe *Decl] ///< parallel to _tentative: the binding moved from.
    /// Every forwarding-pack expansion seen, and its pack.
    priv var _pack_sites: [unsafe *Expr]
    priv var _pack_decl:  [unsafe *Decl]
    /// Bindings whose address is taken somewhere (`&x`, `&x.f`, `&x[i]`, a
    /// pointer capture, a C++ `T&` / `@inout` argument). A pending move out
    /// of one stays a copy whatever the order: a pointer taken before the
    /// transfer and read after it is no read of the BINDING, so the
    /// last-use test cannot see it. Decided at the end of run, over the
    /// whole body.
    priv var _addr: llvm::DenseSet<u64>
    /// `for a in xs`: the binding (a) and what it iterates (xs), so an
    /// address of an element makes the iterated binding aliased too.
    priv var _for_bind: [unsafe *Decl]
    priv var _for_over: [unsafe *Decl]
    /// The current function body's demoted pending moves, one per binding:
    /// the transfer, the read that followed it, and the binding. Written to
    /// the function (FunctionDecl::move_reuse_site) when its walk ends, for
    /// each instance to judge: the pattern does not know whether the value
    /// can be copied, an instance does.
    priv var _reuse_site: cxx::std::vector<unsafe *Expr>
    priv var _reuse_read: cxx::std::vector<unsafe *Expr>
    priv var _reuse_decl: [unsafe *Decl]
    /// The current body's plain binders whose mode each instance decides
    /// (VariableDecl::borrow_inst): their writes are recorded on the
    /// function when its walk ends (FunctionDecl::binder_write_site).
    priv var _inst_binders: cxx::std::vector<unsafe *Decl>
    /// The derived `a + b` whose left operand moves into the result if
    /// nothing reads it again (_derived_operand), and for each demoted one
    /// the read that followed it (site -> read, as u64).
    priv var _derived_sites: [unsafe *Expressions::BinaryOperatorExpr]
    priv var _derived_read:  llvm::DenseMap<u64, u64>

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

        // Keyed by node address and written afresh by this walk: a second
        // check of the same tree must not read the last one's.
        self.sc->real_moves.clear()
        self.sc->disarm_sites.clear()
        self.sc->hand_sites.clear()
        self._hand_log_e = []
        self._hand_log_d = []
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

        // A binding whose address is taken anywhere keeps its storage to
        // itself: a callee handed it would have a parameter that a pointer
        // to the binding (another argument, a global, a field) still
        // writes through, which no by-value parameter allows.
        for var i: usize = 0; i < self._hand_log_e.size(); ++i {
            if self._addr.count(self._hand_log_d[i] as usize as u64) != 0 {
                self.sc->hand_sites.erase(self._hand_log_e[i] as usize as u64)
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

        self._settle_derived()

        // Written only now: every rule that ran during the walk read these
        // binders as the borrows PatternTyping made them.
        for var i: usize = 0; i < self._taken.size(); ++i {
            self._taken[i]->borrows       = false
            self._taken[i]->moves_payload = true
        }
    }

    /// Each derived `a + b`, and each `x ?? y`, whose left operand waited on
    /// a later read (_derived_operand, _coalesce_operand): never read
    /// again, it moves into the result;
    /// read again on some path, or with its address taken, it is a copy
    /// its type cannot make (SC182E).
    priv fn _settle_derived(self) {
        for var i: usize = 0; i < self._derived_sites.size(); ++i {
            var unsafe *bo = self._derived_sites[i]
            var        key = (bo->lhs as usize as u64)
            var unsafe *x  = self._tu.strip_parens(bo->lhs)
            var unsafe *d  = cast<NamedIdentExpr>(x)->resolved_decl
            if self._demoted.count(key) == 0 && self._addr.count(d as usize as u64) == 0 {
                self.sc->move_sites.insert(key)
                self.n_moves += 1
                continue
            }

            var read: unsafe *Expr = &null
            var it                 = self._derived_read.find(key)
            if it != self._derived_read.end() {
                read = unsafe (it->second as usize as unsafe *Expr)
            }

            var nm = self._spelled(x)
            var why = if (read != &null) => (f"'{nm}' is read again later, so it cannot be moved into the result")
                      else => f"The address of '{nm}' is taken in this function, so it cannot be moved into the result"
            if bo->op_token.kind == TokenKind::OpQuestionQuestion {
                self._coalesce_copy_error(bo, why, read)
            } else {
                self._derived_copy_error(bo, why, read)
            }
        }
    }

    /// # bodies

    /// A function body starts clean and leaves nothing behind.
    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        if n == &null {
            return n
        }

        // Once: a call met earlier may have walked it already.
        if self._walked.count(n as usize as u64) != 0 {
            return n
        }

        self._walked.insert(n as usize as u64)
        var refusal     = self._fn_refusal(n)
        var saved_bp    = self._body_panics
        var saved_fn    = self._fn
        var saved_caps  = move(self._caps)
        var saved_out   = move(self._out)
        var saved_hits  = move(self._out_hits)
        var saved_when  = move(self._out_when)
        var saved_pty   = self._out_pty
        var saved_pany  = move(self._out_pany)
        var saved_exits = self._exits
        var saved_asg   = self._assigning
        var saved_hl    = self._pending_has_label
        var saved_label = self._pending_label
        var saved_ret   = self._ret_expr
        var saved_br    = self._body_refusal.copy()
        var saved_nh    = self._no_hand
        self._body_refusal = refusal
        self._no_hand = n->is_async() || n->is_eval() || n->is_constexpr() || !n->no_unwind
        self._fn          = n
        self._body_panics = n->is_panic()
        self._caps        = []
        self._out         = []
        self._out_hits    = []
        self._out_when    = []
        self._out_pty.clear()
        self._out_pany          = []
        self._exits             = 0
        self._assigning         = false
        self._pending_has_label = false
        self._ret_expr          = &null
        // `fn f(p: Pair) -> Str = p.a` is `{ return p.a }` (ExprBodyDesugar,
        // which keeps the node and reads the same written-signature test),
        // so its value leaves the body exactly as that return's does
        // (_return, where dispatch_expr meets it).
        if n->body_kind == FnBodyKind::Expr
            && n->body_expr != &null
            && !n->is_noreturn
            && n->return_type != &null {
            self._ret_expr = n->body_expr
        }

        var saved    = self._enter_body()
        var saved_rs = self._reuse_site
        var saved_rr = self._reuse_read
        var saved_rd = move(self._reuse_decl)
        var saved_ib = self._inst_binders
        self._reuse_site.clear()
        self._reuse_read.clear()
        self._reuse_decl = []
        self._inst_binders.clear()
        self._declare_params(n)
        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_function_decl(
            self,
            n,
        )

        self._exit(MOVE_ON_RETURN)
        self._record_out(n)
        self._settle_locals(n)
        self._body_refusal      = saved_br
        self._no_hand           = saved_nh
        self._body_panics       = saved_bp
        self._fn                = saved_fn
        self._caps              = saved_caps
        self._out               = saved_out
        self._out_hits          = saved_hits
        self._out_when          = saved_when
        self._out_pty           = saved_pty
        self._out_pany          = saved_pany
        self._exits             = saved_exits
        self._assigning         = saved_asg
        self._pending_has_label = saved_hl
        self._pending_label     = saved_label
        self._ret_expr          = saved_ret
        self._leave_body(saved)
        if self._reuse_site.size() > 0 {
            n->move_reuse_site.from_vec(unsafe &self._reuse_site, self.sc->ctx)
            n->move_reuse_read.from_vec(unsafe &self._reuse_read, self.sc->ctx)
        }

        if self._inst_binders.size() > 0 && n->body_block != &null {
            var scan = BinderWriteScan()
            scan.binders = self._inst_binders
            scan.dyn()->dispatch_stmt(unsafe (n->body_block as unsafe *Stmt))
            if scan.sites.size() > 0 {
                n->binder_write_site.from_vec(unsafe &scan.sites, self.sc->ctx)
                n->binder_write_of.from_vec(unsafe &scan.of, self.sc->ctx)
            }
        }

        self._reuse_site   = saved_rs
        self._reuse_read   = saved_rr
        self._reuse_decl   = saved_rd
        self._inst_binders = saved_ib
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
            for var i: usize = 0; i < n->held.size(); ++i {
                var        m   = n->held[i].mode
                var unsafe *at = n->held[i].first_use
                if m == Expressions::CaptureMode::Receiver || at == &null {
                    continue
                }

                self._read(at)
            }

            for var i: usize = 0; i < n->held.size(); ++i {
                var cm = n->held[i].mode
                if (cm == Expressions::CaptureMode::Ptr || cm == Expressions::CaptureMode::ConstPtr)
                    && n->held[i].decl != &null {
                    self._addr.insert(n->held[i].decl as usize as u64)
                    self._ends.spoil(n->held[i].decl)
                }
            }

            for var i: usize = 0; i < n->held.size(); ++i {
                var unsafe *use = n->held[i].first_use
                if n->held[i].mode == Expressions::CaptureMode::Copy
                    && use != &null
                    && use->type_ != &null {
                    self._deprecated_copy(
                        use->range,
                        use->type_,
                        f"the closure captures '{self.sc->ctx->get_spelling(use->name)}' by copy",
                        &null,
                    )
                }
            }

            for var i: usize = 0; i < n->held.size(); ++i {
                if n->held[i].mode != Expressions::CaptureMode::Move {
                    continue
                }

                var unsafe *d = n->held[i].decl
                n->held.get(i)->disarms = false
                if !self._tracked(d) {
                    continue
                }

                // The capture is move-constructed where the closure is
                // built (the lambda in its heap slot, `new auto(...)`):
                // for a local of this body it is a real transfer. Its site
                // is the capture row, not `first_use`, which is a node of
                // the closure's body (a move of the closure's own member
                // there is not this local's).
                if isa<VariableDecl>(d) && self._ends.is_cand(d) {
                    var ok = self._fin_depth == 0 && self._uneval == 0
                    self._ends.captured_at(d, n, i, ok)
                    self._must_disarm(d, ok)
                }

                var mp = MovedPart()
                mp.d    = d
                mp.path = ""
                mp.shown = self.sc->ctx->get_spelling(
                    n->held[i].first_use->name,
                )

                mp.at   = n->held[i].first_use->range
                mp.how  = "into the closure that captures it"
                mp.kind = MoveKind::Capture
                self._mark_part(mp)
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
        var saved       = self._enter_body()
        var saved_fn    = self._fn
        var saved_caps  = move(self._caps)
        var saved_out   = move(self._out)
        var saved_hits  = move(self._out_hits)
        var saved_when  = move(self._out_when)
        var saved_pty   = self._out_pty
        var saved_pany  = move(self._out_pany)
        var saved_exits = self._exits
        var saved_bp    = self._body_panics
        var saved_cbr   = self._body_refusal.copy()
        self._body_panics = ((n->modifiers as u16) & (FnModifier::IsPanic as u16)) != 0
        // As _fn_refusal: no exit is walked at an `await`.
        if ((n->modifiers as u16) & (FnModifier::IsAsync as u16)) != 0 {
            self._body_refusal = "it is a local of an 'async' closure"
        }

        self._fn       = &null
        self._caps     = []
        self._out      = []
        self._out_hits = []
        self._out_when = []
        self._out_pty.clear()
        self._out_pany = []
        self._exits    = 0
        if n->caps_resolved {
            for var i: usize = 0; i < n->held.size(); ++i {
                var cm = n->held[i].mode
                if (cm == Expressions::CaptureMode::Ptr || cm == Expressions::CaptureMode::Receiver)
                    && n->held[i].decl != &null {
                    self._caps.push(n->held[i].decl)
                }
            }
        }

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

        self._exit(MOVE_ON_RETURN)
        self._returning = &null
        self._settle_locals(&null)
        var left = move(self._out)
        self._fn           = saved_fn
        self._caps         = saved_caps
        self._out          = saved_out
        self._out_hits     = saved_hits
        self._out_when     = saved_when
        self._out_pty      = saved_pty
        self._out_pany     = saved_pany
        self._exits        = saved_exits
        self._body_panics  = saved_bp
        self._body_refusal = saved_cbr
        self._leave_body(saved)
        // The closure may run at any time from here on, and its body leaves
        // these moved-from: the captured storage is moved-from once the
        // closure exists.
        for var i: usize = 0; i < left.size(); ++i {
            var mp = left[i].copy()
            // A `|*x|` capture is a pointer to `x` in the body: what it
            // points at there is `x` here.
            if mp.segs.size() > 0 && mp.segs[0] == &null {
                var pl = MovePlace()
                pl.d     = mp.d
                pl.shown = self._tu.decl_name(mp.d)
                for var k: usize = 1; k < mp.segs.size(); ++k {
                    if mp.segs[k] == &null {
                        pl.through()
                    } else {
                        pl.field(self._tu.decl_name(mp.segs[k]), mp.segs[k])
                    }
                }

                mp.path  = pl.path.copy()
                mp.shown = pl.shown.copy()
                mp.segs  = pl.segs
            }

            mp.has_via = true
            mp.via     = mp.at
            mp.at      = n->range
            mp.elem    = ""
            mp.how     = "by the closure that captures it"
            mp.kind    = MoveKind::ClosureLeaves
            self._mark_part(mp)
        }

        return n
    }

    /// The body leaves here, by the outcome `kind` (a MOVE_ON_* bit, or
    /// several when the outcome is not known): what is moved-from in
    /// storage it does not own (_outlives) stays so for the caller.
    priv fn _exit(self, kind: u8) {
        self._exit_by(kind, &null)
    }

    /// _exit, by a panic of type `ty` when `kind` has MOVE_ON_PANIC
    /// (null: a type not known statically).
    priv fn _exit_by(self, kind: u8, ty: unsafe *Type) {
        if self._st.dead {
            return
        }

        self._leaves += 1
        self._param_exits()
        self._exits += 1
        for var i: usize = 0; i < self._st.moved.size(); ++i {
            if !self._outlives(self._st.moved[i]) {
                continue
            }

            var at = usize::MAX
            for var k: usize = 0; k < self._out.size(); ++k {
                if self._out[k].d == self._st.moved[i].d
                    && self._out[k].path == self._st.moved[i].path {
                    at = k
                }
            }

            if at == usize::MAX {
                at = self._out.size()
                self._out.push(self._st.moved[i].copy())
                self._out_hits.push(1)
                self._out_when.push(kind)
                self._out_pty.push_back(cxx::std::vector<unsafe *Type>())
                self._out_pany.push(0)
            } else {
                self._out_hits[at] += 1
                self._out_when[at] = self._out_when[at] | kind
            }

            if (kind & MOVE_ON_PANIC) != 0 {
                if ty == &null {
                    self._out_pany[at] = 1
                } else {
                    pset_add(unsafe &self._tu, unsafe &self._out_pty[at], ty)
                }
            }
        }
    }

    /// The rows of `n`'s by-value parameters that C++ passes as `T&&`
    /// (LocalEnds::declare_param): a plain by-value parameter of a function
    /// whose signature is Kairo's to choose (fn_keeps_value_params), of a
    /// destructive type or of one an instance may make so. Every parameter
    /// starts as the caller's (ParamOwner::Caller), so a second check of
    /// the tree leaves no stale answer; _settle_locals writes the rows'.
    priv fn _declare_params(self, n: unsafe *FunctionDecl) {
        for var i: usize = 0; i < n->params.size(); ++i {
            if n->params[i] != &null {
                n->params[i]->owner = ParamOwner::Caller
            }
        }

        if !self.sc->opts.destructive_moves
            || n->body_kind != FnBodyKind::Block && n->body_kind != FnBodyKind::Expr {
            return
        }

        if fn_keeps_value_params(n) {
            return
        }

        var ctor = decl_is_ctor(n, self.sc->ctx)
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if !param_is_plain_value(p) || p->unname {
                continue
            }

            var dm = destructive_type(self.sc, p->type_)
            if dm == LifecycleTri::Yes {
                self._ends.declare_param(
                    p,
                    false,
                    !ctor && !n->is_constexpr() && !names_cxx_member_type(p->type_),
                )
            } else if dm == LifecycleTri::Unknown
                && type_may_be_destructive(p->type_)
                && value_param_rule(n, p) == 1 {
                self._ends.declare_param(p, true, false)
            }
        }
    }

    /// `mp` joins the moved set. A mark of a parameter's row that is not
    /// one of the row's own real transfers of the whole of it (another
    /// kind of move, a part, a capture, what a callee leaves) may leave
    /// the object moved-from where no flag says so: its guard could not
    /// tell, so the row is the caller's (LocalEndRow::dirty). Said here,
    /// where the mark is made, since a join keeps only the first mark of
    /// a place. A mark made where a real transfer has moved the parameter
    /// on every path says nothing new: what a callee leaves moved-from in
    /// an argument it was handed is that transfer.
    priv fn _mark_part(self, const mp: MovedPart) {
        if self._ends.is_param(mp.d)
            && !self._st.is_disarmed(mp.d)
            && !(mp.kind == MoveKind::Transfer
                && mp.path.size() == 0
                && self._ends.is_site(mp.d, mp.site)) {
            self._ends.dirty_at_exit(mp.d)
        }

        self._st.mark(mp)
    }

    /// The body is left on the current path: what each parameter row is
    /// there. Moved out by a real transfer of the whole of it on every
    /// path, it needs nothing; anything else is an exit it is alive at
    /// (LocalEnds::alive_unmoved_at_exit), and one where something other
    /// than such a transfer may have moved it, wholly or a part, is one a
    /// guard cannot end it at either (LocalEnds::dirty_at_exit).
    priv fn _param_exits(self) {
        var ps = self._ends.params()
        for var i: usize = 0; i < ps.size(); ++i {
            var unsafe *d = ps[i]
            var moved = self._st.is_disarmed(d)
                && (self._ends.is_dep_param(d)
                    || d == self._returning
                    || self._st.index_of(d, "") != usize::MAX)
            if moved {
                continue
            }

            // Alive on some path here. A guard's flag tells the paths
            // apart only when each move that reaches the exit is one of
            // the row's own sites, which clear it: a mark of any other
            // kind, of a part, or with no site of the row may have left
            // the object moved-from with the flag still set.
            self._ends.alive_unmoved_at_exit(d)
            var touched = self._st.is_disarmed(d) && self._st.index_of(d, "") == usize::MAX
            for var k: usize = 0; k < self._st.moved.size(); ++k {
                var *mp = &self._st.moved[k]
                if mp->d != d {
                    continue
                }

                if mp->kind != MoveKind::Transfer
                    || mp->path.size() > 0
                    || !self._ends.is_site(d, mp->site) {
                    touched = true
                }
            }

            if touched {
                self._ends.dirty_at_exit(d)
            }
        }
    }

    /// `return v`, or an expression body's value `v`: the body leaves
    /// with the outcome `v` is (_return_kind). A value that is a call's
    /// outcome (_forwards) leaves once per outcome of the call, from the
    /// state that outcome reaches (_cond), so the function moves what its
    /// callee moves on the outcome it returns: `return q.push(&v)` leaves
    /// `v` moved-from only on `true` when `push` does.
    priv fn _return(self, v: unsafe *Expr) {
        var kind = self._return_kind(v)
        var nul  = kind == (MOVE_ON_NULL | MOVE_ON_NON_NULL)
        if !self._forwards(v, kind) {
            self.dispatch_expr(v)
            self._return_value(v)
            self._run_finallys_to(0)
            self._exit(kind)
            self._returning = &null
            self._st.dead   = true
            return
        }

        var r = CondStates{}
        if nul {
            r = self._null_cond(v)
        } else {
            r = self._cond(v)
        }

        if !r.split {
            self._st = move_join(r.t, r.f)
            self._return_value(v)
            self._run_finallys_to(0)
            self._exit(kind)
            self._returning = &null
            self._st.dead   = true
            return
        }

        // `v` is a call, a bool or a local holding a result: the value
        // itself moves nothing, so neither path needs it walked again.
        var f = r.f
        self._st = r.t
        self._return_value(v)
        self._run_finallys_to(0)
        self._exit(if (nul) => (MOVE_ON_NON_NULL) else => MOVE_ON_TRUE)
        self._returning = &null
        self._st        = f
        self._run_finallys_to(0)
        self._exit(if (nul) => (MOVE_ON_NULL) else => MOVE_ON_FALSE)
        self._st.dead = true
    }

    /// The function's outcome at `return v` is that of a call in `v`,
    /// whose own outcome `kind` does not settle: in a `bool` function a
    /// condition _cond splits on a call (_splittable); in a `T?` function a
    /// call of the same `T?` type, its result returned as it is.
    priv fn _forwards(self, v: unsafe *Expr, kind: u8) -> bool {
        if self._fn == &null || v == &null {
            return false
        }

        if kind == (MOVE_ON_TRUE | MOVE_ON_FALSE) {
            return self._splittable(v)
        }

        if kind != (MOVE_ON_NULL | MOVE_ON_NON_NULL) || !self._null_tested(v) {
            return false
        }

        var unsafe *x  = self._tu.strip_parens(v)
        var unsafe *rt = self._canon(self._fn->return_type)
        var unsafe *vt = self._canon(x->type_)
        return rt != &null && vt != &null && canon_unqual(rt) == canon_unqual(vt)
    }

    /// `e` is a condition _cond splits on a call's outcome: a call, alone
    /// or under `!`, `&&`, `||`, a postfix `?` or a comparison with `null`.
    priv fn _splittable(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self._tu.strip_parens(e)
        if x == &null {
            return false
        }

        if isa<Expressions::CallExpr>(x) || self._link_index(x, false) != usize::MAX {
            return true
        }

        if isa<Expressions::UnaryOperatorExpr>(x) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
            if u->resolved_op != &null || u->operand == &null {
                return false
            }

            if u->fix == Expressions::UnaryOperatorExpr::Fix::Prefix
                && u->op_token.kind == TokenKind::OpExclaim {
                return self._splittable(u->operand)
            }

            return u->fix == Expressions::UnaryOperatorExpr::Fix::Postfix
                && u->op_token.kind == TokenKind::OpQuestion
                && self._null_tested(u->operand)
        }

        if !isa<Expressions::BinaryOperatorExpr>(x) {
            return false
        }

        var unsafe *bo = cast<Expressions::BinaryOperatorExpr>(x)
        var        k   = bo->op_token.kind
        if bo->resolved_op != &null || bo->lhs == &null || bo->rhs == &null {
            return false
        }

        if k == TokenKind::OpAmpAmp || k == TokenKind::OpPipePipe {
            return self._splittable(bo->lhs) || self._splittable(bo->rhs)
        }

        if k != TokenKind::OpEqualEqual && k != TokenKind::OpExclaimEqual {
            return false
        }

        var unsafe *l  = self._tu.strip_parens(bo->lhs)
        var unsafe *rr = self._tu.strip_parens(bo->rhs)
        return (self._is_null_literal(rr) && self._null_tested(l))
            || (self._is_null_literal(l) && self._null_tested(rr))
    }

    /// `e` is what a test against null splits on (_cond): a call, or a
    /// local holding a `T?` call's link.
    priv fn _null_tested(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self._tu.strip_parens(e)
        return x != &null
            && (isa<Expressions::CallExpr>(x) || self._link_index(x, true) != usize::MAX)
    }

    /// `v`, a `T?` value _null_tested splits on, walked as the value
    /// returned: its state when it is not null, and when it is.
    priv fn _null_cond(self, v: unsafe *Expr) -> CondStates {
        return self._null_split(
            v,
            MOVE_ON_RETURN & ~MOVE_ON_NULL,
            MOVE_ON_RETURN & ~MOVE_ON_NON_NULL,
        )
    }

    /// The outcome a `return` of `v` is (MoveOut::when): read from a
    /// `true` / `false` literal in a `bool` function, and from a `null`
    /// literal, or a value whose type cannot be null, in a `T?` function.
    /// Any other value may be either outcome of its type.
    priv fn _return_kind(self, v: unsafe *Expr) -> u8 {
        if self._fn == &null {
            return MOVE_ON_RETURN
        }

        var unsafe *rt = self._canon(self._fn->return_type)
        var unsafe *x  = self._tu.strip_parens(v)
        if rt == &null {
            return MOVE_ON_OTHER
        }

        if self._tu.is_bool(rt) {
            if x != &null && isa<BooleanLiteralExpr>(x) {
                return if (cast<BooleanLiteralExpr>(x)->value) => (MOVE_ON_TRUE)
                       else => (MOVE_ON_FALSE)
            }

            return MOVE_ON_TRUE | MOVE_ON_FALSE
        }

        if self._tu.nullable_inner(rt) != &null {
            if x != &null && isa<NullLiteralExpr>(x) {
                return if (cast<NullLiteralExpr>(x)->is_ref) => (MOVE_ON_NULL | MOVE_ON_NON_NULL)
                       else => (MOVE_ON_NULL)
            }

            var unsafe *vt = if (x != &null) => (self._canon(x->type_)) else => &null
            if vt != &null && self._tu.nullable_inner(self._tu.as_value(vt)) == &null {
                return MOVE_ON_NON_NULL
            }

            return MOVE_ON_NULL | MOVE_ON_NON_NULL
        }

        return MOVE_ON_OTHER
    }

    /// `t`'s canonical type, or `t` when it has none.
    priv fn _canon(self, t: unsafe *Type) -> unsafe *Type {
        if t != &null && t->canonical != &null {
            return t->canonical
        }

        return t
    }

    /// `mp` is storage the body being walked does not own: a closure's
    /// by-pointer capture, the function's `self` (not a destructor's, which
    /// ends the object), an `@inout` or C++ `T&` parameter, or what any
    /// parameter points at.
    priv fn _outlives(self, const mp: MovedPart) -> bool {
        // The caller sees a move made only at some instances as none: the
        // pattern's record (move_out) is every instance's.
        if mp.kind == MoveKind::Instance {
            return false
        }

        for var i: usize = 0; i < self._caps.size(); ++i {
            if self._caps[i] == mp.d {
                return true
            }
        }

        if self._fn == &null || !isa<ParamDecl>(mp.d) {
            return false
        }

        var unsafe *pd  = cast<ParamDecl>(mp.d)
        var        mine = false
        for var i: usize = 0; i < self._fn->params.size(); ++i {
            if self._fn->params[i] == pd {
                mine = true
            }
        }

        if !mine {
            return false
        }

        if pd->is_self {
            return self._fn->op_token.size() == 0
                || self._fn->op_token.get(0)->kind != TokenKind::KwFinally
        }

        if pd->mode == ParamMode::Inout || self._lref_param(pd) {
            return true
        }

        for var i: usize = 0; i < mp.segs.size(); ++i {
            if mp.segs[i] == &null {
                return true
            }
        }

        return false
    }

    /// Files `_out` on `n` (FunctionDecl::move_out), replacing what an
    /// earlier walk of the same node left.
    priv fn _record_out(self, n: unsafe *FunctionDecl) {
        var outs = cxx::std::vector<MoveOut>()
        var path = cxx::std::vector<unsafe *Decl>()
        var ptys = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < self._out.size(); ++i {
            var idx = usize::MAX
            for var q: usize = 0; q < n->params.size(); ++q {
                if n->params[q] == self._out[i].d {
                    idx = q
                }
            }

            if idx == usize::MAX {
                continue
            }

            var mo = MoveOut{}
            mo.param  = idx as u32
            mo.first  = path.size() as u32
            mo.count  = self._out[i].segs.size() as u32
            mo.always = self._out_hits[i] == self._exits
            mo.when   = self._out_when[i]
            mo.at     = self._out[i].at
            mo.pfirst = ptys.size() as u32
            mo.pcount = 0
            mo.cxx_at = self._out[i].cxx_at
            if (mo.when & MOVE_ON_PANIC) != 0 && self._out_pany[i] == 0 {
                for var k: usize = 0; k < self._out_pty[i].size(); ++k {
                    ptys.push_back(self._out_pty[i][k])
                }

                mo.pcount = self._out_pty[i].size() as u32
            }

            for var k: usize = 0; k < self._out[i].segs.size(); ++k {
                path.push_back(self._out[i].segs[k])
            }

            outs.push_back(mo)
        }

        n->move_out.from_vec(unsafe &outs, self.sc->ctx)
        n->move_out_path.from_vec(unsafe &path, self.sc->ctx)
        n->move_out_panic.from_vec(unsafe &ptys, self.sc->ctx)
        n->move_out_state = MoveOutState::Body
    }

    /// `def`'s body is walked before the call that needs what it leaves
    /// moved-from. Only a body of this TU, and once per run: what an
    /// earlier run left on the node is not read. Another TU's function is
    /// walked by its own TU, which is finished unless the two import each
    /// other; a function already being walked (recursion) says nothing yet.
    priv fn _walk_callee(self, def: unsafe *FunctionDecl) {
        if def->body_kind == FnBodyKind::None
            || def->body_recovered
            || self._depth >= 64
            || self._walked.count(def as usize as u64) != 0
            || !self._tu.in_this_tu(def) {
            return
        }

        self._depth += 1
        self.dyn()->traverse_function_decl(def)
        self._depth -= 1
    }

    /// The call `n` is to `f`, a function declared in Kairo with no
    /// definition Kairo can read (implemented in C or C++). What cannot be
    /// read is taken at its worst: every argument the body could move out
    /// of is moved-from after the call -- a non-const receiver, an `@inout`
    /// argument, what a pointer to non-const points at. The note at the
    /// declaration says how to state what the function does: `@move` when
    /// it takes the value, `const` when it only reads. A function imported
    /// from a header is C++'s to describe (a `T&` parameter borrows, a
    /// `T&&` moves), and an interface method is called through its
    /// conformers.
    priv fn _call_unseen(self,
                         n:        unsafe *Expressions::CallExpr,
                         f:        unsafe *FunctionDecl,
                         is_ctor:  bool,
                         const ps: [unsafe *ParamDecl],
                         const es: [unsafe *Expr]) {
        if f->clang_decl != &null && !f->is_implicit && !is_ctor && !self._st.dead {
            self._call_cxx(n, f, ps, es)
        }

        if f->clang_decl != &null || f->is_implicit || is_ctor || self._st.dead {
            return
        }

        if f->semantic_dc != &null {
            var unsafe *owner = f->semantic_dc->owner_decl()
            if owner != &null && isa<InterfaceDecl>(owner) {
                return
            }
        }

        if f->move_out_state == MoveOutState::None && self._tu.in_this_tu(f) {
            f->move_out_state = MoveOutState::Assumed
        }

        var name = self._tu.decl_name(f)
        var how  = f"by the call to '{name}', whose body cannot be read and is taken to move it"
        if f->is_method() && self._callee_binds_receiver(n->callee) {
            var const_self = false
            for var i: usize = 0; i < f->params.size(); ++i {
                if f->params[i] != &null && f->params[i]->is_self && f->params[i]->is_const {
                    const_self = true
                }
            }

            var pl = self._place(n->callee)
            if !const_self
                && pl.d != &null
                && pl.rest == 1
                && !pl.opaque
                && self._may_be_moved(self._receiver_type(n->callee)) {
                self._mark_place(pl, n->range, how, f)
            }
        }

        for var a: usize = 0; a < ps.size(); ++a {
            var unsafe *p = ps[a]
            if p->is_self || p->is_const {
                continue
            }

            var by_ref = p->mode == ParamMode::Inout || self._lref_param(p)
            var ct: unsafe *Type = &null
            if p->type_ != &null {
                ct = if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_
            }

            var unsafe *pt = if (ct != &null) => (self._tu.pointee(ct)) else => &null
            if !by_ref && (pt == &null || canon_has_const(pt)) {
                continue
            }

            var unsafe *x = self._tu.strip_parens(es[a])
            var unsafe *u = dyn_cast<Expressions::UnaryOperatorExpr>(x)
            var addr = u != &null
                && u->operand != &null
                && u->fix == Expressions::UnaryOperatorExpr::Fix::Prefix
                && (u->is_mode_marker
                    || u->op_token.kind == TokenKind::OpAmp && u->resolved_op == &null)
            if addr {
                x = u->operand
            }

            var pl = self._place(x)
            if pl.d == &null || !pl.whole {
                continue
            }

            // A pointer binding: what it points at, which an element that
            // holds the pointer does not contain.
            if !by_ref && !addr {
                if pl.elem {
                    continue
                }

                pl.through()
            }

            var unsafe *vt = if (by_ref || addr) => (x->type_) else => pt
            if !self._may_be_moved(vt) {
                continue
            }

            self._mark_place(pl, n->range, how, f)
        }
    }

    /// The call `n` is to `f`, a C or C++ function. A MOVE argument bound
    /// to a `T&` / `T*` to non-const, or a MOVE object a non-const method
    /// runs on, is moved-from after the call when the callee's body moves
    /// out of it (ForeignInstantiate::cxx_moves_out). One whose body cannot
    /// be inspected borrows, on an unchecked assumption the TU records
    /// (SemaContext::assume); -fstrict-cxx-moves takes it at its worst
    /// instead, unless what could not be inspected is the toolchain's own
    /// library (CxxMoveKind::Assumed), which borrows on an assumption under
    /// either. A pack parameter is not asked about.
    priv fn _call_cxx(self,
                      n:        unsafe *Expressions::CallExpr,
                      f:        unsafe *FunctionDecl,
                      const ps: [unsafe *ParamDecl],
                      const es: [unsafe *Expr]) {
        if self.sc->foreign == &null {
            return
        }

        var name = self._tu.decl_name(f)
        if f->is_method() && self._callee_binds_receiver(n->callee) {
            var pl = self._place(n->callee)
            if pl.d != &null
                && pl.rest == 1
                && !pl.opaque
                && self._may_be_moved(self._receiver_type(n->callee)) {
                self._cxx_verdict(n, f, name, pl, -1)
            }
        }

        for var a: usize = 0; a < ps.size(); ++a {
            var unsafe *p = ps[a]
            if p->is_self || p->is_pack {
                continue
            }

            var by_ref = p->mode == ParamMode::Inout || self._lref_param(p)
            var ct: unsafe *Type = &null
            if p->type_ != &null {
                ct = if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_
            }

            var unsafe *pt = if (ct != &null) => (self._tu.pointee(ct)) else => &null
            if !by_ref && pt == &null {
                continue
            }

            // `unsafe &h` for a C++ `T*` is the address of `h` as well.
            var unsafe *x = self._tu.strip_parens(es[a])
            while x != &null && isa<Expressions::UnsafeExpr>(x) {
                x = self._tu.strip_parens(
                    cast<Expressions::UnsafeExpr>(x)->operand,
                )
            }

            var unsafe *u = dyn_cast<Expressions::UnaryOperatorExpr>(x)
            var addr = u != &null
                && u->operand != &null
                && u->fix == Expressions::UnaryOperatorExpr::Fix::Prefix
                && (u->is_mode_marker
                    || u->op_token.kind == TokenKind::OpAmp && u->resolved_op == &null)
            if addr {
                x = u->operand
            }

            var pl = self._place(x)
            if pl.d == &null || !pl.whole {
                continue
            }

            if !by_ref && !addr {
                if pl.elem {
                    continue
                }

                pl.through()
            }

            var unsafe *vt = if (by_ref || addr) => (x->type_) else => pt
            if !self._may_be_moved(vt) {
                continue
            }

            // The clang index: the parameters before p, the receiver not counted.
            var idx: i32 = 0
            for var q: usize = 0; q < f->params.size(); ++q {
                if f->params[q] == p {
                    break
                }

                if f->params[q] != &null && !f->params[q]->is_self {
                    idx += 1
                }
            }

            self._cxx_verdict(n, f, name, pl, idx)
        }
    }

    /// What the C++ call `n` to `f` does to `pl`, reached through clang
    /// parameter `idx` (-1 the receiver): moved-from, borrowed, or
    /// borrowed on an assumption.
    priv fn _cxx_verdict(self,
                         n:          unsafe *Expressions::CallExpr,
                         f:          unsafe *FunctionDecl,
                         const name: string,
                         const pl:   MovePlace,
                         idx:        i32) {
        var v = self.sc->foreign->cxx_moves_out(
            f,
            n->cxx_spec,
            n->cxx_spec_set,
            idx,
        )

        if v.kind == CxxMoveKind::None {
            return
        }

        var mp = MovedPart()
        mp.d       = pl.d
        mp.path    = pl.path.copy()
        mp.shown   = pl.shown.copy()
        mp.segs    = pl.segs.copy()
        mp.at      = n->range
        mp.has_via = true
        mp.via     = if (v.at.is_valid()) => (v.at) else => f->range
        if v.kind == CxxMoveKind::Moves {
            mp.how      = f"by the call to '{name}'"
            mp.via_text = f"'{v.in_name}' moves it here"
            if !v.in_top {
                mp.via_text += f", called from '{name}'"
            }

            if !v.at.is_valid() {
                mp.via_text = f"declared here; '{v.in_name}' moves it, in a header with no source this build can show"
            }

            mp.kind = MoveKind::CxxBody
            self._mark_part(mp)
            return
        }

        if v.kind == CxxMoveKind::Assumed {
            self.sc->assume(
                n->range,
                MoveCheck::_library_assumption(v, name, pl.shown),
            )

            return
        }

        var why = self._cxx_unknown(v)
        // A language flag: Lib/builtin and Lib/std keep the default
        // (Compiler/Spec/Driver.md, dialect flags and the library).
        if !self.sc->opts.strict_cxx_moves || self.sc->in_library() {
            self.sc->assume(
                n->range,
                f"'{name}' is assumed not to move out of '{pl.shown}': {why}",
            )

            return
        }

        mp.how = f"by the call to '{name}', whose body cannot be inspected and is taken to move it under -fstrict-cxx-moves"
        mp.via_text = f"not inspected: {why}; with -fno-strict-cxx-moves the call borrows it, on an unchecked assumption"
        mp.kind   = MoveKind::CxxAssumed
        mp.cxx_at = n->range
        self._mark_part(mp)
    }

    /// The assumption a call to `name` makes when what the walk could not
    /// read is library functions with no visible body (CxxMoveKind::
    /// Assumed): it borrows `shown`, under -fstrict-cxx-moves too.
    priv static fn _library_assumption(const v:     CxxMoveVerdict,
                                       const name:  string,
                                       const shown: string) -> string {
        var lib = if (v.why == 2) => ("a C library function")
                  else => "a C++ standard library function"
        if v.blocker_top {
            return f"'{name}' is {lib} whose body is not visible: assumed not to move out of '{shown}'"
        }

        return f"'{name}' passes '{shown}' to '{v.blocker}', {lib} whose body is not visible: assumed not to move out of it"
    }

    /// The note at a C++ call -fstrict-cxx-moves took to move its argument,
    /// when a caller of the function that made it reports the move.
    priv static fn _strict_cxx_note() -> string {
        return "this C++ call could not be inspected and is taken to move it under -fstrict-cxx-moves; with -fno-strict-cxx-moves it borrows, on an unchecked assumption"
    }

    /// Why cxx_moves_out could not decide, for the assumption and the note.
    priv fn _cxx_unknown(self, const v: CxxMoveVerdict) -> string {
        if v.why == 2 {
            return if (v.blocker_top) => ("it is virtual, so an override may run instead")
                   else => f"it passes it to '{v.blocker}', a virtual call"
        }

        if v.why == 3 {
            return f"'{v.in_name}' passes it to a call through a pointer"
        }

        if v.why == 4 {
            return f"the inspection stops {CXX_MOVE_DEPTH} calls deep, in '{v.in_name}'"
        }

        if v.why == 5 {
            return if (v.blocker_top) => ("its body does not compile for this argument")
                   else => f"it passes it to '{v.blocker}', whose body does not compile for this argument"
        }

        if v.why == 6 {
            return "the template instance it calls is not known"
        }

        return if (v.blocker_top) => ("its body is not visible")
               else => f"it passes it to '{v.blocker}', whose body is not visible"
    }

    /// A value of type `t` can be left moved-from: only a MOVE type can,
    /// since taking a COPY value out of its storage copies it.
    priv fn _may_be_moved(self, t: unsafe *Type) -> bool {
        return t != &null && moves_on_pass(self.sc, t)
    }

    /// The type of the object `obj.m(...)` / `p->m(...)` runs on; null when
    /// the callee is not such a chain.
    priv fn _receiver_type(self, callee: unsafe *Expr) -> unsafe *Type {
        var unsafe *c = self._tu.strip_parens(callee)
        if c == &null || !isa<ChainExpr>(c) {
            return &null
        }

        var unsafe *ce = cast<ChainExpr>(c)
        if ce->steps.size() == 0 || ce->base == &null {
            return &null
        }

        var unsafe *t = ce->base->type_
        if ce->steps.size() >= 2 {
            t = ce->steps.get(ce->steps.size() - 2)->resolved_type
        }

        if t != &null
            && ce->steps.get(ce->steps.size() - 1)->access_kind == ChainExpr::AccessKind::Arrow {
            t = self._tu.pointee(t)
        }

        return t
    }

    /// `pl` becomes moved-from at `at`, by a call to `f`, whose body
    /// cannot be read: the note at the declaration says how to state what
    /// it does.
    priv fn _mark_place(self,
                        const pl:  MovePlace,
                        at:        SourceRange,
                        const how: string,
                        f:         unsafe *FunctionDecl) {
        var mp = MovedPart()
        mp.d       = pl.d
        mp.path    = pl.path.copy()
        mp.shown   = pl.shown.copy()
        mp.segs    = pl.segs.copy()
        mp.at      = at
        mp.how     = how.copy()
        mp.has_via = true
        mp.via     = f->range
        var mv = LangAttrs::param_move()
        mp.via_text = f"declared here with no body: write the parameter as '{mv}' if the function takes the value, or 'const' (a pointer to const) if it only reads it"

        mp.kind = MoveKind::Unseen
        self._mark_part(mp)
    }

    /// The call `n` to `f`: each part `f` leaves moved-from
    /// (FunctionDecl::move_out) is that part of the argument it was reached
    /// through, returned with the outcomes on which it is moved-from for
    /// the caller to mark (_apply). `ps` / `es` are the parameters bound
    /// and their arguments. An argument that names no place marks nothing.
    /// A function with no readable body marks its worst case here, on every
    /// outcome (_call_unseen).
    priv fn _call_leaves(self,
                         n:        unsafe *Expressions::CallExpr,
                         f:        unsafe *FunctionDecl,
                         is_ctor:  bool,
                         const ps: [unsafe *ParamDecl],
                         const es: [unsafe *Expr]) -> CallMarks {
        var        cm   = CallMarks{}
        var unsafe *def = f->definition()
        if def == &null || def->body_kind == FnBodyKind::None {
            if def == &null {
                self._call_unseen(n, f, is_ctor, ps, es)
            }

            return cm
        }

        self._walk_callee(def)
        // In this TU the list is this run's only once the walk has ended.
        if self._tu.in_this_tu(def) && self._walked.count(def as usize as u64) == 0 {
            return cm
        }

        if def->move_out_state != MoveOutState::Body || def->move_out.size() == 0 || self._st.dead {
            return cm
        }

        var bound = !is_ctor && f->is_method() && self._callee_binds_receiver(n->callee)
        var name = self._tu.decl_name(def)
        for var k: usize = 0; k < def->move_out.size(); ++k {
            var mo   = def->move_out[k]
            var idx  = mo.param as usize
            var i    = mo.first as usize
            var j    = i + (mo.count as usize)
            var pl   = MovePlace()
            var have = false
            // `&x` for a pointer parameter: the pointee is `x` itself.
            var skip = false
            if idx < f->params.size() && f->params[idx] != &null && j <= def->move_out_path.size() {
                var unsafe *fp = f->params[idx]
                if fp->is_self && bound {
                    pl   = self._place(n->callee)
                    have = pl.d != &null && pl.rest == 1 && !pl.opaque
                } else if !(fp->is_self && is_ctor) {
                    for var a: usize = 0; a < ps.size(); ++a {
                        if ps[a] != fp {
                            continue
                        }

                        var unsafe *x = self._tu.strip_parens(es[a])
                        var unsafe *u = dyn_cast<Expressions::UnaryOperatorExpr>(
                            x,
                        )

                        if u != &null
                            && u->operand != &null
                            && u->fix == Expressions::UnaryOperatorExpr::Fix::Prefix
                            && (u->is_mode_marker
                                || u->op_token.kind == TokenKind::OpAmp
                                    && u->resolved_op == &null) {
                            skip = !u->is_mode_marker
                            x    = u->operand
                        }

                        pl   = self._place(x)
                        have = pl.d != &null && pl.whole
                    }
                }
            }

            if have {
                for var s = i; s < j; ++s {
                    var unsafe *seg = def->move_out_path[s]
                    if seg == &null {
                        if skip {
                            skip = false
                            continue
                        }

                        // Behind a pointer an element holds: the container
                        // only points at it.
                        if pl.elem {
                            have = false
                        }

                        pl.through()
                    } else {
                        pl.field(self._tu.decl_name(seg), seg)
                    }
                }
            }

            if have {
                var mp = MovedPart()
                mp.d       = pl.d
                mp.path    = pl.path.copy()
                mp.shown   = pl.shown.copy()
                mp.segs    = pl.segs
                mp.at      = n->range
                mp.how     = f"by the call to '{name}'"
                mp.has_via = true
                mp.via     = mo.at
                mp.kind    = MoveKind::CalleeLeaves
                mp.cxx_at  = mo.cxx_at
                if mo.cxx_at.is_valid() {
                    mp.how = f"by the call to '{name}', which calls a C++ function that could not be inspected"
                    if mo.at == mo.cxx_at {
                        mp.via_text = MoveCheck::_strict_cxx_note()
                    }
                }

                var tys = cxx::std::vector<unsafe *Type>()
                var pe  = (mo.pfirst as usize) + (mo.pcount as usize)
                for var s = mo.pfirst as usize; s < pe && s < def->move_out_panic.size(); ++s {
                    tys.push_back(def->move_out_panic[s])
                }

                cm.parts.push(mp)
                cm.when.push(mo.when)
                cm.ptys.push_back(tys)
            }
        }

        return cm
    }

    /// Marks each part of `cm` that is moved-from on an outcome in `on`
    /// (MOVE_ON_* bits): the outcomes that reach the current path. The note
    /// names the outcome when only one of them moves it.
    priv fn _apply(self, const cm: CallMarks, on: u8) {
        if self._st.dead {
            return
        }

        for var i: usize = 0; i < cm.parts.size(); ++i {
            var hit = cm.when[i] & on
            if hit == 0 {
                continue
            }

            var mp = cm.parts[i].copy()
            if hit == MOVE_ON_TRUE {
                mp.how += ", when it returns true"
            } else if hit == MOVE_ON_FALSE {
                mp.how += ", when it returns false"
            } else if hit == MOVE_ON_NULL {
                mp.how += ", when it returns null"
            } else if hit == MOVE_ON_NON_NULL {
                mp.how += ", when it does not return null"
            } else if hit == MOVE_ON_PANIC {
                mp.how += ", when it panics"
                mp.via_text = "it is moved here, and not assigned again before the body panics"
            }

            self._mark_part(mp)
        }
    }

    /// The current path may leave by a panic here, with the parts of `cm`
    /// a panic of the call leaves moved-from: the state goes to the catch
    /// arms of each enclosing `try` up to one that catches everything, and
    /// past them out of the body when the body may panic. The current path
    /// itself goes on unchanged.
    priv fn _panic_path(self, const cm: CallMarks) {
        self._panic_path_of(cm, false, cxx::std::vector<unsafe *Type>())
    }

    /// _panic_path for a call that panics only with the types of `set`
    /// when `known` (its declared set), and with any type otherwise. The
    /// path is taken once per type the panic can be known to have, marked
    /// with the parts moved on a panic of that type (MoveOut::pcount), so a
    /// typed catch arm receives only those; with the set not known, once
    /// more for a panic of any other type, marked with the parts moved on a
    /// panic of any type.
    priv fn _panic_path_of(self,
                           const cm:  CallMarks,
                           known:     bool,
                           const set: cxx::std::vector<unsafe *Type>) {
        if self._st.dead {
            return
        }

        if self._tries.is_empty() && !self._body_panics {
            return
        }

        var tys = cxx::std::vector<unsafe *Type>()
        if known {
            for var i: usize = 0; i < set.size(); ++i {
                pset_add(unsafe &self._tu, unsafe &tys, set[i])
            }
        } else {
            for var i: usize = 0; i < cm.parts.size() && i < cm.ptys.size(); ++i {
                if (cm.when[i] & MOVE_ON_PANIC) == 0 {
                    continue
                }

                for var k: usize = 0; k < cm.ptys[i].size(); ++k {
                    pset_add(unsafe &self._tu, unsafe &tys, cm.ptys[i][k])
                }
            }
        }

        var saved = self._st.copy()
        for var i: usize = 0; i < tys.size(); ++i {
            self._st = saved.copy()
            var ty: unsafe *Type = tys[i]
            if panic_dep(ty) {
                ty = &null
            }

            self._apply(self._panic_marks(cm, tys[i]), MOVE_ON_PANIC)
            self._leave_by_panic(ty)
        }

        if !known || tys.empty() {
            self._st = saved.copy()
            self._apply(self._panic_marks(cm, &null), MOVE_ON_PANIC)
            self._leave_by_panic(&null)
        }

        self._st = saved
    }

    /// The parts of `cm` moved-from by a panic of type `ty`: those a
    /// panic of any type moves, and, when `ty` is known, those its type
    /// moves.
    priv fn _panic_marks(self, const cm: CallMarks, ty: unsafe *Type) -> CallMarks {
        var out = CallMarks{}
        for var i: usize = 0; i < cm.parts.size(); ++i {
            if (cm.when[i] & MOVE_ON_PANIC) == 0 {
                continue
            }

            var tys = if (i < cm.ptys.size()) => (cm.ptys[i])
                      else => cxx::std::vector<unsafe *Type>()
            if !tys.empty() && (ty == &null || !pset_has(unsafe &tys, ty)) {
                continue
            }

            out.parts.push(cm.parts[i].copy())
            out.when.push(cm.when[i])
            out.ptys.push_back(tys)
        }

        return out
    }

    /// The type a `panic` of `p` raises, or null when it is not known
    /// statically: a type parameter, or a rethrow of what a bare arm caught.
    priv fn _panic_type(self, p: unsafe *Expr) -> unsafe *Type {
        if p == &null || p->is_poisoned() || p->type_ == &null {
            return &null
        }

        var unsafe *x = self._tu.strip_parens(p)
        if x != &null && isa<NamedIdentExpr>(x) {
            var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
            if d != &null && self._bare_binds.count(d as usize as u64) != 0 {
                return &null
            }
        }

        var unsafe *t = canon_unqual(p->type_)
        if t == &null || panic_dep(t) || self._tu.is_never(t) {
            return &null
        }

        return t
    }

    /// One arm of a `try`, by its filter (null for a bare arm) and its
    /// binding, onto `fr` (TryFrame::arm_any, arm_ty, types).
    priv fn _arm_of(self, @inout fr: TryFrame, filter: unsafe *Type, bind: unsafe *Decl) {
        var one              = cxx::std::vector<unsafe *Type>()
        var c:  unsafe *Type = &null
        if filter != &null {
            c = filter->canonical
        }

        var any = c == &null || panic_dep(c)
        if !any {
            var unsafe *rd = self._tu.record_decl(canon_unqual(c))
            any = rd != &null && decl_is_imported(rd)
        }

        if !any {
            pset_add(unsafe &self._tu, unsafe &one, c)
            pset_add(unsafe &self._tu, unsafe &fr.types, c)
        }

        if filter == &null && bind != &null {
            self._bare_binds.insert(bind as usize as u64)
        }

        fr.arm_any.push(any as u8)
        fr.arm_ty.push_back(one)
    }

    /// A panic of type `ty` (null: not known statically) leaves the
    /// current path (it is dead after): the pending finally bodies of the
    /// blocks it leaves run over it, each enclosing `try` it reaches takes
    /// the state for its catch arms, up to one with a bare arm or an arm of
    /// exactly `ty`, and one that passes them all leaves the body (_exit).
    priv fn _leave_by_panic(self, ty: unsafe *Type) {
        if self._st.dead {
            return
        }

        self._leaves += 1

        // Each block is left once: its bodies run before the first `try`
        // outside it takes the state.
        var open = self._blocks.size()
        var i    = self._tries.size()
        while i > 0 {
            i = i - 1
            if self._fin_depth == 0 {
                self._run_finallys_between(open, self._tries[i].block_depth)
            } else {
                self._exit_check_between(open, self._tries[i].block_depth)
            }

            open = self._tries[i].block_depth

            if self._st.dead {
                return
            }

            self._tries[i].panics.push(self._st.copy())
            self._tries[i].panic_ty.push(ty)
            if self._tries[i].catch_all
                || (ty != &null && pset_has(unsafe &self._tries[i].types, ty)) {
                self._st.dead = true
                return
            }
        }

        if self._fin_depth == 0 {
            self._run_finallys_between(open, 0)
        } else {
            self._exit_check_between(open, 0)
        }

        self._exit_by(MOVE_ON_PANIC, ty)
        self._st.dead = true
    }

    /// A call to `f`, or through a value of type `fp`, can leave by a
    /// panic: either is marked `panic`. A call whose callee is neither is
    /// taken to.
    priv fn _may_panic(self, f: unsafe *FunctionDecl, fp: unsafe *FunctionPointerType) -> bool {
        if f != &null {
            return f->is_panic()
        }

        if fp != &null {
            return fp->canon_panics || fp->is_panic()
        }

        return true
    }

    /// A body starts clean: the enclosing body's flow, handed back for
    /// _leave_body, and a fresh one in its place.
    priv fn _enter_body(self) -> BodyFlow {
        var saved = BodyFlow{}
        saved.st           = cxx::std::move(self._st)
        saved.loops        = move(self._loops)
        saved.blocks       = move(self._blocks)
        saved.tries        = move(self._tries)
        saved.locals       = move(self._block_locals)
        saved.ends         = cxx::std::move(self._ends)
        saved.leaves       = self._leaves
        self._block_locals = []
        self._ends         = LocalEnds()
        self._st           = MoveState()
        self._loops        = []
        self._blocks       = []
        self._tries        = []
        return saved
    }

    /// ...and leaves nothing behind: `saved`, _enter_body's, back.
    priv fn _leave_body(self, saved: BodyFlow) {
        if !self._blocks.is_empty() {
            kairo::std::ice_fail("MoveCheck: a block frame outlived its body")
        }

        self._st           = cxx::std::move(saved.st)
        self._loops        = move(saved.loops)
        self._blocks       = move(saved.blocks)
        self._tries        = move(saved.tries)
        self._block_locals = move(saved.locals)
        self._ends         = cxx::std::move(saved.ends)
        self._leaves       = saved.leaves
    }

    /// The modes of the locals of the body whose walk ends here: a C++
    /// exception may leave it where the walk does not see unless it is
    /// `noexcept`: a function by FunctionDecl::no_unwind, a closure (`f`
    /// null) unless the build is -funwind (EmitIR's closure head).
    priv fn _settle_locals(self, f: unsafe *FunctionDecl) {
        var may_unwind = if (f == &null) => (self.sc->opts.unwind_all) else => !f->no_unwind
        self._ends.settle(self.sc, may_unwind)
    }

    /// MoveCheck::_body_refusal of the function `n`.
    priv fn _fn_refusal(self, n: unsafe *FunctionDecl) -> string {
        if n->is_eval() || n->is_constexpr() {
            return "it is a local of an 'eval' or constexpr function"
        }

        if decl_is_ctor(n, self.sc->ctx) {
            return "it is a local of a constructor"
        }

        // The walk has no exit at an `await`: a frame destroyed while
        // suspended there would hold a local this walk calls moved.
        if n->is_async() {
            return "it is a local of an 'async' function"
        }

        return ""
    }

    /// Block `i` is left on the current path: a local it declared that is
    /// not ended on every path here is alive at an exit of its scope.
    priv fn _exit_check(self, i: usize) {
        if self._st.dead || i >= self._block_locals.size() {
            return
        }

        for var k: usize = 0; k < self._block_locals[i].size(); ++k {
            var unsafe *d = self._block_locals[i][k]
            if !self._st.is_ended(d) {
                self._part_exit(d)
                self._ends.alive_at_exit(d)
                // Moved only while the move's mark is still there: a mark
                // taken back some other way than an assignment leaves the
                // object to the flag.
                var returned = d == self._returning && self._st.is_disarmed(d)
                if (!self._st.is_disarmed(d) || self._st.index_of(d, "") == usize::MAX)
                    && !returned {
                    self._ends.alive_unmoved_at_exit(d)
                }
            }
        }
    }

    /// The blocks below index `from` down to index `to` are left.
    priv fn _exit_check_between(self, from: usize, to: usize) {
        var i = from
        while i > to {
            i = i - 1
            self._exit_check(i)
        }
    }

    /// `var b = a` moves a MOVE `a` into `b`. The declaration also makes `b`
    /// a new, live binding: in a loop body, last iteration's move of it
    /// says nothing about this one.
    fn traverse_variable_decl(self, n: unsafe *VariableDecl) -> unsafe *VariableDecl {
        if n == &null {
            return n
        }

        var unsafe *saved_lc = self._link_call
        var unsafe *saved_io = self._init_owner
        var unsafe *target   = self._link_target(n)
        self._link_call  = target
        self._init_owner = n
        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_variable_decl(
            self,
            n,
        )

        self._link_call  = saved_lc
        self._init_owner = saved_io
        if n->init != &null {
            self._init_var = n
            self._transfer(
                n->init,
                f"into '{self.sc->ctx->get_spelling(n->name)}'",
                n->type_,
            )

            self._init_var = &null
        }

        self._st.forget(n)
        if target != &null && self._link_got == target {
            self._link_got = &null
            if !self._st.dead && self._link.parts.size() > 0 {
                self._link.d = n
                self._st.links.push(self._link.copy())
            }
        }

        return out
    }

    /// `var (x, y) = t`: each binder takes its part of the value. A value
    /// whose type moves is moved as a whole into the destructuring, as
    /// `var w = t` moves it (TupleLowering then binds it by value and moves
    /// each part into its binder), and a later read of `t` is SC052E. A
    /// `*x` binder points into the value where it is, so with one the
    /// value is read in place and a plain binder of a part that cannot be
    /// copied is refused.
    fn traverse_destructuring_decl_stmt(self,
                                        n: *Statements::DestructuringDeclStmt) -> *Statements::DestructuringDeclStmt {
        var out = RecursiveASTVisitor<MoveCheck>::traverse_destructuring_decl_stmt(
            self,
            n,
        )

        if n->value == &null
            || n->value->is_poisoned()
            || !moves_on_pass(self.sc, n->value->type_) {
            return out
        }

        var in_place = false
        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *b = n->bindings.get(i)
            if b != &null && b->shorthand.has(Statements::BindingShorthand::Pointer) {
                in_place = true
            }
        }

        if !in_place {
            self._transfer(n->value, "into the destructured binders")
            return out
        }

        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *b = n->bindings.get(i)
            if b == &null
                || b->is_discard
                || b->shorthand.has(Statements::BindingShorthand::Pointer)
                || b->decl == &null
                || b->decl->type_ == &null
                || b->decl->is_poisoned() {
                continue
            }

            var unsafe *t = if (b->decl->type_->canonical != &null) => (b->decl->type_->canonical)
                            else => b->decl->type_
            var tf               = LifecycleFacts()
            var rd: unsafe *Decl = &null
            var unsafe *facts = self._uncopyable_facts(
                t,
                unsafe &tf,
                unsafe &rd,
            )

            if facts == &null {
                continue
            }

            var nm = self.sc->ctx->get_spelling(b->decl->name)
            var kb = self.sc->diag->report(
                DiagID::SC182E,
                b->range.start,
                f"cannot copy a value of type '{self._tu.str(self._tu.as_value(t))}': {facts->why_not_copyable}",
            )

            kb.first(b->range)
            kb.note(
                b->range.start,
                f"a '*' binder reads the value in place, so '{nm}' is a copy of its part; bind '*{nm}' for its address instead",
            )

            if rd != &null {
                kb.note(rd->range.start, type_declared_here())->child_first(
                    rd->range,
                )
            }

            kb.emit()
            b->decl->poison()
            self.n_errored += 1
        }

        return out
    }

    /// A binder inside it binds part of a payload (_binder_scrut).
    fn traverse_constructor_pattern(self, n: *ConstructorPattern) -> *ConstructorPattern {
        self._ctor_depth += 1
        var out = RecursiveASTVisitor<MoveCheck>::traverse_constructor_pattern(
            self,
            n,
        )

        self._ctor_depth -= 1
        return out
    }

    /// `case var v`: the binder is a copy of what it matched (MatchLowering
    /// reads the scrutinee in place, by `const T&`), so a type that cannot
    /// be copied is refused here, not in clang; `case const v` reads it
    /// without a copy.
    fn traverse_binding_pattern(self, n: *BindingPattern) -> *BindingPattern {
        var out = RecursiveASTVisitor<MoveCheck>::traverse_binding_pattern(
            self,
            n,
        )

        var unsafe *vd = dyn_cast<VariableDecl>(n->decl)
        if vd != &null && vd->borrow_inst {
            self._inst_binders.push_back(unsafe (vd as unsafe *Decl))
        }

        // Each entry into the arm binds it anew: a move out of it on an
        // earlier pass of a loop says nothing about this one.
        if vd != &null && self._pattern_scrut != &null {
            self._match_binders.insert(vd as usize as u64)
            self._st.clear(unsafe (vd as unsafe *Decl), "")
        }

        if vd != &null && self._pattern_scrut != &null && self._ctor_depth > 0 {
            self._binder_scrut[vd as usize as u64] = (self._pattern_scrut as usize as u64)
        }

        // A walk over a tree this pass has already decided starts from the
        // borrow PatternTyping made; the move is decided again (run).
        if vd != &null && vd->moves_payload {
            vd->moves_payload = false
            vd->borrows       = true
        }

        // A binder that borrows copies nothing (PatternTyping::_type_binder).
        if n->is_const
            || vd == &null
            || vd->borrows
            || vd->borrow_inst
            || vd->type_ == &null
            || vd->is_poisoned() {
            return out
        }

        var unsafe *t = if (vd->type_->canonical != &null) => (vd->type_->canonical)
                        else => vd->type_
        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(t, unsafe &tf, unsafe &rd)
        if facts == &null {
            return out
        }

        var nm = self.sc->ctx->get_spelling(vd->name)
        var kb = self.sc->diag->report(
            DiagID::SC182E,
            n->range.start,
            f"cannot copy a value of type '{self._tu.str(self._tu.as_value(t))}': {facts->why_not_copyable}",
        )

        kb.first(n->range)
        kb.note(
            n->range.start,
            f"the binder 'var {nm}' is a copy of what it matched; 'const {nm}' reads it in place",
        )

        var kw = SourceRange()
        kw.start = n->range.start
        kw.end   = n->range.start.with_offset(3)
        kb.fix(kw, "const", "bind it 'const'")
        if rd != &null {
            kb.note(rd->range.start, type_declared_here())->child_first(
                rd->range,
            )
        }

        kb.emit()
        vd->poison()
        self.n_errored += 1
        return out
    }

    /// The call initialising `n` when a later test of `n` can stand for
    /// a test of the call: a local of the body, the call its whole
    /// initializer, of type `bool` or `T?`, and the local declared with
    /// that type or none.
    priv fn _link_target(self, n: unsafe *VariableDecl) -> unsafe *Expressions::CallExpr {
        if n->init == &null || n->is_static() || self._blocks.is_empty() {
            return &null
        }

        var unsafe *x = self._tu.strip_parens(n->init)
        if x == &null || !isa<Expressions::CallExpr>(x) || x->type_ == &null {
            return &null
        }

        var unsafe *t = canon_unqual(self._tu.as_value(self._canon(x->type_)))
        if t == &null || (!self._tu.is_bool(t) && self._tu.nullable_inner(t) == &null) {
            return &null
        }

        if n->type_ != &null {
            var unsafe *dt = canon_unqual(
                self._tu.as_value(self._canon(n->type_)),
            )

            if dt != t {
                return &null
            }
        }

        return cast<Expressions::CallExpr>(x)
    }

    /// The call `n` initialises the local being declared (_link_target):
    /// what it marks on every outcome, of what was whole before it, is
    /// kept for the local's link.
    priv fn _link_from(self, n: unsafe *Expressions::CallExpr, const cm: CallMarks) {
        var l = CondLink()
        l.site = n->range
        if n->type_ != &null {
            var unsafe *t = canon_unqual(
                self._tu.as_value(self._canon(n->type_)),
            )

            l.nul = t != &null && self._tu.nullable_inner(t) != &null
        }

        for var i: usize = 0; i < cm.parts.size(); ++i {
            if (cm.when[i] & MOVE_ON_RETURN) == 0
                || self._st.index_of(cm.parts[i].d, cm.parts[i].path) != usize::MAX
                || l.holds(cm.parts[i].d, cm.parts[i].path) {
                continue
            }

            l.parts.push(cm.parts[i].copy())
            l.when.push(cm.when[i])
        }

        self._link     = l
        self._link_got = n
    }

    /// A field of a struct literal or a variant's payload is initialized
    /// from its value, as a variable is.
    fn traverse_named_initializer_expr(self,
                                       n: unsafe *Expressions::NamedInitializerExpr) -> unsafe *Expressions::NamedInitializerExpr {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_named_initializer_expr(
            self,
            n,
        )

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

        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_anon_initializer_expr(
            self,
            n,
        )

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

        if e == self._ret_expr {
            self._ret_expr = &null
            self._return(e)
            return e
        }

        // `typeof e` is not evaluated; `spawn` / `thread` run their operand
        // elsewhere, after this path may have left the local's scope.
        if e->kind == ExprKind::TypeOfExpr
            || e->kind == ExprKind::SpawnExpr
            || e->kind == ExprKind::ThreadExpr {
            self._uneval += 1
            var unsafe *uo = RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                self,
                e,
            )

            self._uneval -= 1
            return uo
        }

        match e->kind {
            case ExprKind::NamedIdentExpr {
                self._read(cast<NamedIdentExpr>(e))
                return RecursiveASTVisitor<MoveCheck>::dispatch_expr(self, e)
            } case ExprKind::ChainExpr {
                // `p.a.b` reads the part `a.b` of `p`, not all of it: a moved
                // `p.c` leaves it readable. The root is checked here and not
                // walked again, or it would read as the whole binding. A
                // place without a subscript is names, type arguments and
                // dereferences, which read nothing else; one with a
                // subscript is walked, and reads its container and index.
                var pl = self._place(e)
                if pl.d == &null || pl.elem {
                    return RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                        self,
                        e,
                    )
                }

                self._read_part(pl.name, pl.d, pl.path, pl.shown)
                return e
            } case ExprKind::AssignOperatorExpr {
                var unsafe *asn = cast<Expressions::AssignOperatorExpr>(e)
                // `x = e` / `p.a = e`: the value first (it may read x, or move
                // it: `x = f(x)`), then that storage is whole again.
                if asn->op_token.kind == TokenKind::OpEqual
                    && asn->lhs != &null
                    && asn->rhs != &null {
                    var pl = self._place(asn->lhs)
                    if pl.d != &null && pl.whole && !pl.elem {
                        // A store through a pointer reads the pointer.
                        if pl.has_ptr {
                            self._read_part(
                                pl.name,
                                pl.d,
                                pl.ptr_path,
                                pl.ptr_shown,
                            )
                        }

                        // The first visit of this run forgets an earlier
                        // check's states.
                        if self._remake_seen.count(asn as usize as u64) == 0 {
                            self._remake_seen.insert(asn as usize as u64)
                            asn->remake = 0
                        }

                        var visits = self._ends.visits_of(pl.d)
                        var hands  = self._hand_log_e.size()
                        self.dispatch_expr(asn->rhs)
                        // `x = f(x)`: the call's result is built in `x`'s
                        // storage where the assignment constructs it
                        // (AssignOperatorExpr::remake), which is the object
                        // an argument that handed `x` over still names.
                        if pl.path.size() == 0 {
                            self._unhand(pl.d, hands)
                        }

                        self._assigning = true
                        self._transfer(
                            asn->rhs,
                            f"into '{self._spelled(asn->lhs)}'",
                            asn->lhs->type_,
                        )

                        self._assigning = false
                        // `x = x`, or a value that may be `x` itself: built
                        // in place it would be built from its own storage.
                        // Only a function's result is a new object for
                        // certain; `T(x)` is the move constructor run on
                        // the storage it reads (guaranteed elision).
                        if self._ends.visits_of(pl.d) != visits && pl.path.size() == 0 {
                            var unsafe *rx = self._tu.strip_parens(asn->rhs)
                            if rx == &null
                                || !isa<Expressions::CallExpr>(rx)
                                || cast<Expressions::CallExpr>(rx)->ctor_decl != &null
                                || rx->value_category != Expr::ValueCategory::RValue {
                                self._ends.spoil(pl.d)
                            }
                        }

                        // A store into a part of a local moved (or maybe
                        // moved) whole puts a live value into the moved-from
                        // object: only its destructor can release it.
                        if pl.path.size() > 0
                            && !self._st.dead
                            && self._ends.is_cand(pl.d)
                            && (self._st.is_disarmed(pl.d)
                                || self._st.index_of(pl.d, "") != usize::MAX) {
                            self._ends.spoil(pl.d)
                        }

                        // A whole assignment, or a store into a moved part
                        // or into what holds one, builds a value the
                        // field-by-field destruction would leave out.
                        if self._ends.is_pcand(pl.d)
                            && (pl.path.size() == 0
                                || self._st.overlap_of(pl.d, pl.path) != usize::MAX) {
                            self._ends.spoil_parts(pl.d)
                        }

                        var moved = self._move_remake_state(pl)
                        self._st.clear(pl.d, pl.path)
                        if self._remake(asn, pl, moved) {
                            return e
                        }

                        // A store into a finalized local runs on a destroyed object.
                        var fi = self._st.finalized_at(pl.d)
                        if fi != usize::MAX
                            && !self._st.dead
                            && !self._st.was_reported(pl.d)
                            && !pl.name->is_poisoned() {
                            self._st.reported.push(pl.d)
                            self._finalized_use(pl.name, self._st.moved[fi])
                        }

                        return e
                    }

                    self.dispatch_expr(asn->lhs)
                    self.dispatch_expr(asn->rhs)
                    // `v[i] = v[j]` of a MOVE element would move out of an
                    // element into another one. Whether a move out of
                    // `x[i]` is allowed is not decided, and clang rejected
                    // this shape before SequenceLowering's statement form
                    // stopped copying the store's result, so it is
                    // refused rather than becoming a silent move.
                    if self._is_element(asn->lhs)
                        && self._is_element(asn->rhs)
                        && moves_on_pass(self.sc, asn->rhs->type_)
                        && !asn->rhs->is_poisoned() {
                        self._no_copy(
                            asn->rhs,
                            f"'{self._spelled(asn->rhs)}' is an element of a container, and moving an element out into another element is not supported; swap them, or move through a local",
                        )

                        return e
                    }

                    // `m[k] = v` through the setter form of `op []=` is a
                    // call: the value is passed as its parameter takes it.
                    var unsafe *vp = self._setter_value_param(asn)
                    if vp != &null {
                        self._pass(asn->rhs, vp, vp->mode)
                        return e
                    }

                    self._assigning = true
                    self._transfer(
                        asn->rhs,
                        f"into '{self._spelled(asn->lhs)}'",
                    )

                    self._assigning = false
                    return e
                }

                // `acc += s` through a user `op +=` is a call taking `s`.
                var unsafe *cout = RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                    self,
                    e,
                )

                if asn->resolved_op != &null {
                    self._operator_operands(
                        asn->resolved_op,
                        asn->op_via_free,
                        asn->lhs,
                        asn->rhs,
                    )
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

                    var before = self._st.copy()
                    if bo->rhs != &null {
                        self.dispatch_expr(bo->rhs)
                    }

                    self._st = move_join(before, self._st)
                    return e
                }

                // `x ?? y` runs `y` only when `x` is null: a move in it, or
                // a `-> !` call that ends the path, is on that path alone.
                if k == TokenKind::OpQuestionQuestion && bo->resolved_op == &null {
                    if bo->lhs != &null {
                        self.dispatch_expr(bo->lhs)
                    }

                    // The fallback is moved into the result on its own
                    // path too.
                    var before = self._st.copy()
                    if bo->rhs != &null {
                        self.dispatch_expr(bo->rhs)
                    }

                    self._coalesce_fallback(bo)
                    self._st = move_join(before, self._st)
                    self._coalesce_operand(bo)
                    return e
                }

                var unsafe *out = RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                    self,
                    e,
                )

                if bo->resolved_op != &null {
                    self._derived_operand(bo)
                    self._operator_operands(
                        bo->resolved_op,
                        bo->op_via_free,
                        bo->lhs,
                        bo->rhs,
                    )
                }

                return out
            } case ExprKind::UnaryOperatorExpr {
                var unsafe *u = cast<Expressions::UnaryOperatorExpr>(e)
                if u->op_token.kind == TokenKind::OpAmp && u->operand != &null {
                    self._mark_addr(u->operand)
                }

                // `*p` reads what `p` points at, not `p`.
                if self._is_deref(u) {
                    var pl = self._place(e)
                    if pl.d != &null && !pl.elem {
                        self._read_part(pl.name, pl.d, pl.path, pl.shown)
                        return e
                    }
                }

                var unsafe *uout = RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                    self,
                    e,
                )

                self._operator_panics(u->resolved_op)
                return uout
            } case ExprKind::TypeCastExpr {
                var unsafe *tout = RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                    self,
                    e,
                )

                self._operator_panics(
                    cast<Expressions::TypeCastExpr>(e)->resolved_op,
                )

                return tout
            } case ExprKind::SubscriptExpr {
                var unsafe *sx = cast<Expressions::SubscriptExpr>(e)
                var unsafe *out = RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                    self,
                    e,
                )

                if sx->resolved_op != &null {
                    self._operator_operands(
                        sx->resolved_op,
                        sx->op_via_free,
                        sx->base,
                        sx->index,
                    )
                }

                return out
            } case ExprKind::PackExpansionExpr {
                // `xs...` of a pack parameter forwards each element
                // (EmitIR::_pack_expansion), which moves it: pending,
                // so a later read of the pack -- a second expansion, a `for`
                // over it, the same expansion on a loop's next iteration --
                // leaves this one a plain copy.
                var unsafe *out = RecursiveASTVisitor<MoveCheck>::dispatch_expr(
                    self,
                    e,
                )

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
                        self._pack_sites.push(e)
                        self._pack_decl.push(d)
                    }
                }

                return out
            } case ExprKind::CallExpr {
                var unsafe *ce = cast<Expressions::CallExpr>(e)
                if ce->finalize != Expressions::FinalizeKind::None {
                    self._finally_call(ce)
                    return e
                }

                self._call(ce)
                return e
            } case ExprKind::IfExpr {
                self._if_expr(cast<Expressions::IfExpr>(e))
                return e
            } case ExprKind::MatchExpr {
                var unsafe *m = cast<Expressions::MatchExpr>(e)
                if m->scrutinee != &null {
                    var unsafe *saved_ut = self._unbuilt_tuple
                    self._unbuilt_tuple = self._tu.strip_parens(m->scrutinee)
                    self.dispatch_expr(m->scrutinee)
                    self._unbuilt_tuple = saved_ut
                }

                var yields = self._discarded_match != e
                self._arms_start()
                for var i: usize = 0; i < m->cases.size(); ++i {
                    self._arm_begin()
                    self._match_case(m->cases.get(i), m->scrutinee, yields)
                    self._arm_end()
                }

                self._arms_finish(false)
                return e
            } case ExprKind::TryCatchExpr {
                var unsafe *t     = cast<Expressions::TryCatchExpr>(e)
                var        before = self._st.copy()
                var        frame  = TryFrame()
                var        cxx    = false
                frame.block_depth = self._blocks.size()
                for var i: usize = 0; i < t->catch_arms.size(); ++i {
                    var unsafe *arm = t->catch_arms.get(i)
                    if self._cxx_arm(arm->is_cxx, arm->filter) {
                        cxx = true
                    } else if arm->filter == &null {
                        frame.catch_all = true
                    }

                    self._arm_of(&frame, arm->filter, arm->decl)
                }

                frame.cxx_arm = cxx
                self._tries.push(frame)
                if t->try_expr != &null {
                    self.dispatch_expr(t->try_expr)
                }

                var met = self._tries[self._tries.size() - 1].copy()
                self._tries.pop()
                var after_try = self._st.copy()
                var acc       = after_try.copy()
                for var i: usize = 0; i < t->catch_arms.size(); ++i {
                    var unsafe *arm = t->catch_arms.get(i)
                    self._st = self._arm_entry_of(
                        before,
                        after_try,
                        met,
                        cxx,
                        i,
                    )

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

    /// Each arm runs on its condition's true state; the next condition, and
    /// the `else`, on the previous one's false state. The expression is a
    /// value, so an arm is transferred into it (_if_arm) in that arm's state.
    priv fn _if_expr(self, n: unsafe *Expressions::IfExpr) {
        var r   = self._cond(n->condition)
        var acc = MoveState()
        acc.dead = true
        self._st = r.t
        if n->then_expr != &null {
            self.dispatch_expr(n->then_expr)
            self._if_arm(n->then_expr)
        }

        acc = move_join(acc, self._st)
        var rest = r.f
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            var unsafe *arm = n->else_ifs.get(i)
            self._st = rest
            var ar = self._cond(arm->condition)
            self._st = ar.t
            if arm->body != &null {
                self.dispatch_expr(arm->body)
                self._if_arm(arm->body)
            }

            acc  = move_join(acc, self._st)
            rest = ar.f
        }

        self._st = rest
        if n->else_expr != &null {
            self.dispatch_expr(n->else_expr)
            self._if_arm(n->else_expr)
        }

        self._st = move_join(acc, self._st)
    }

    /// An arm of a MOVE type that names a place: C++'s `?:` copies an
    /// lvalue operand into its result, and a MOVE type has no copy. A
    /// local or by-value parameter moves into the value, tracked as any
    /// transfer is; any other place (a field, an element, a dereference)
    /// is refused, since moving out of it would leave it moved-from where
    /// nothing tracks it. A COPY arm is left to C++'s copy.
    priv fn _if_arm(self, e: unsafe *Expr) {
        if e == &null || e->is_poisoned() || !moves_on_pass(self.sc, e->type_) {
            return
        }

        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return
        }

        if self._returned_local(x) {
            self._transfer(e, "into the value of the 'if' expression", e->type_)
            return
        }

        self._no_copy(
            e,
            "an 'if' expression copies this arm into its value, and moving out of it would leave the place moved-from",
        )
    }

    /// ## arm bookkeeping: N alternatives from one entry state

    priv var _arm_entry: [MoveState] ///< stack: entry state per open arm set.
    priv var _arm_acc:   [MoveState] ///< stack: accumulated exit per open arm set.
    priv var _arm_any:   [u8]

    priv fn _arms_start(self) {
        self._arm_entry.push(self._st.copy())
        var dead = MoveState()
        dead.dead = true
        self._arm_acc.push(dead)
        self._arm_any.push(0)
    }

    priv fn _arm_begin(self) {
        self._st = self._arm_entry[self._arm_entry.size() - 1].copy()
    }

    priv fn _arm_end(self) {
        var top = self._arm_acc.size() - 1
        self._arm_acc[top] = move_join(self._arm_acc[top], self._st)
        self._arm_any[top] = 1
    }

    /// `fallthrough`: the construct may run no arm at all (an `if` with no
    /// `else`), so the entry state is one of the paths.
    priv fn _arms_finish(self, fallthrough: bool) {
        var top   = self._arm_acc.size() - 1
        var acc   = self._arm_acc.remove(top)
        var entry = self._arm_entry.remove(top)
        var any   = self._arm_any[top] != 0
        self._arm_any.pop()
        if fallthrough || !any {
            acc = move_join(acc, entry)
        }

        self._st = acc
    }

    /// # match arms

    /// One case of a match over `scrut`: its patterns' binders are recorded
    /// against `scrut`, and in a match that yields a value (`value`) an arm
    /// whose value is a binder transfers it out of the match.
    priv fn _match_case(self, mc: unsafe *Statements::MatchCase, scrut: unsafe *Expr, value: bool) {
        var unsafe *saved = self._pattern_scrut
        self._pattern_scrut = scrut
        for var i: usize = 0; i < mc->patterns.size(); ++i {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*mc->patterns.get(i))
        }

        self._pattern_scrut = saved
        if self.stop {
            return
        }

        if mc->guard != &null {
            self.dispatch_expr(mc->guard)
        }

        if mc->body != &null {
            self.dyn()->dispatch_stmt(mc->body)
        }

        if mc->expression != &null {
            self.dispatch_expr(mc->expression)
            if value {
                self._yield_binder(mc->expression)
            }
        }
    }

    /// `case .V(var x) => x`: the arm's value is a binder. One whose type
    /// moves is transferred out of the match (MatchLowering moves a binder
    /// that holds a value of its own); one that borrows moves only out of
    /// a match that owns its scrutinee (_take_payload), and is a copy its
    /// type cannot make otherwise.
    priv fn _yield_binder(self, e: unsafe *Expr) {
        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || x->is_poisoned() || !isa<NamedIdentExpr>(x) {
            return
        }

        var unsafe *vd = dyn_cast<VariableDecl>(
            cast<NamedIdentExpr>(x)->resolved_decl,
        )

        if vd == &null
            || self._match_binders.count(vd as usize as u64) == 0
            || vd->borrow_inst
            || !moves_on_pass(self.sc, e->type_) {
            return
        }

        if !vd->borrows && vd->storage != StorageClass::Const {
            return
        }

        self._transfer(e, "out of the match")
    }

    /// The match over `s` owns it, so a binder may take its payload: a
    /// temporary, bound by value into the match's own local, or a local
    /// or by-value parameter of the body, read in place and left
    /// moved-from. A tuple literal is never built (each element is its own
    /// column) and anything else is storage the match does not own.
    priv fn _owned_scrutinee(self, s: unsafe *Expr) -> bool {
        var unsafe *x = self._tu.strip_parens(s)
        if x == &null || isa<Expressions::TupleLiteralExpr>(x) {
            return false
        }

        if x->value_category != Expr::ValueCategory::LValue {
            return true
        }

        // A `const` parameter is a by-value one C++ receives by `const T&`.
        return self._returned_local(x) && !self._const_place(x)
    }

    /// A transfer of `bb`, a borrowing match binder: when its match owns
    /// the scrutinee the binder takes the payload by move, and the
    /// scrutinee, if it is a binding, is moved-from from here on. False
    /// when the match does not own it: the transfer stays a copy.
    priv fn _take_payload(self, bb: unsafe *VariableDecl) -> bool {
        var it = self._binder_scrut.find(bb as usize as u64)
        if it == self._binder_scrut.end() {
            return false
        }

        var unsafe *s = unsafe (it->second as usize as unsafe *Expr)
        if !self._owned_scrutinee(s) {
            return false
        }

        var seen = false
        for var i: usize = 0; i < self._taken.size(); ++i {
            if self._taken[i] == bb {
                seen = true
                break
            }
        }

        if !seen {
            self._taken.push(bb)
        }

        // A scrutinee already reported (read after a move) is not moved
        // again: one error for the one mistake.
        var unsafe *sx = self._tu.strip_parens(s)
        if sx->value_category == Expr::ValueCategory::LValue && !sx->is_poisoned() {
            var nm = self.sc->ctx->get_spelling(bb->name)
            self._mark(
                s,
                f"by the match, whose binder '{nm}' takes its payload",
                MoveKind::Transfer,
            )
        }

        return true
    }

    /// # statements

    fn dispatch_stmt(self, s: unsafe *Stmt) -> unsafe *Stmt {
        if s == &null {
            return s
        }

        if self.stop {
            return s
        }

        // A match whose value is discarded is lowered as the statement
        // form: its arms' values go nowhere (_match_case).
        if isa<Statements::ExpressionStmt>(s) {
            var unsafe *ex = self._tu.strip_parens(
                cast<Statements::ExpressionStmt>(s)->expr,
            )

            if ex != &null && isa<Expressions::MatchExpr>(ex) {
                self._discarded_match = ex
            }
        }

        match s->kind {
            case StmtKind::CompoundStmt {
                var unsafe *n = cast<Statements::CompoundStmt>(s)
                self._blocks.push([])
                self._block_locals.push([])

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

                self._blocks.pop()
                self._block_locals.pop()
                return s
            } case StmtKind::DeclStmt {
                // A local of the innermost open block: its scope is the
                // block's rest, left by every exit of the block.
                var unsafe *ds = cast<Statements::DeclStmt>(s)
                var unsafe *vd = dyn_cast<VariableDecl>(ds->decl)
                if vd != &null && !vd->is_static() && !self._block_locals.is_empty() {
                    self._block_locals[self._block_locals.size() - 1].push(
                        unsafe (vd as unsafe *Decl),
                    )

                    self._ends.declare(
                        vd,
                        if (self._for_init) => ("it is a C-style for's variable") else => "",
                        self.sc->opts.destructive_moves
                            && self._body_refusal.size() == 0
                            && disarm_refusal(self.sc, vd).size() == 0,
                        self.sc->opts.destructive_moves
                            && self._body_refusal.size() == 0
                            && self._fn != &null
                            && disarm_storage_refusal(vd).size() == 0,
                    )

                    // Inside a `try` with a C++ exception arm, a C++ call
                    // may leave this local's scope where the walk does not see.
                    for var t: usize = 0; t < self._tries.size(); ++t {
                        if self._tries[t].cxx_arm {
                            self._ends.spoil_parts(unsafe (vd as unsafe *Decl))
                            self._ends.alive_at_exit(
                                unsafe (vd as unsafe *Decl),
                            )

                            self._ends.alive_unmoved_at_exit(
                                unsafe (vd as unsafe *Decl),
                            )
                        }
                    }
                }

                return RecursiveASTVisitor<MoveCheck>::dispatch_stmt(self, s)
            } case StmtKind::FinallyStmt {
                // Recorded, not walked: the body runs when its block is left
                // (_run_block_finallys), never at its statement.
                if self._blocks.is_empty() {
                    kairo::std::ice_fail("MoveCheck: `finally` outside a block")
                }

                self._blocks[self._blocks.size() - 1].push(
                    cast<Statements::FinallyStmt>(s),
                )

                return s
            } case StmtKind::ConditionalStmt {
                // The then block runs on the condition's true state, the
                // else (or the fallthrough) on its false state.
                var unsafe *n = cast<Statements::ConditionalStmt>(s)
                var        r  = self._cond(n->cond)
                self._st = r.t
                self.dyn()->traverse_block(n->then_)
                var taken = self._st.copy()
                self._st = r.f
                if n->else_ != &null {
                    self.dispatch_stmt(n->else_)
                }

                self._st = move_join(taken, self._st)
                return s
            } case StmtKind::WhileLoopStmt {
                var unsafe *n = cast<Statements::WhileLoopStmt>(s)
                self._loop(
                    n->cond,
                    n->body,
                    &null,
                    !self._is_true_literal(n->cond),
                    &null,
                )

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

                            self._for_bind.push(bd)
                            self._for_over.push(
                                cast<NamedIdentExpr>(it)->resolved_decl,
                            )
                        }
                    }
                }

                self._for_binder_copies(n)
                self._loop(&null, n->body, &null, true, n)
                return s
            } case StmtKind::IndexedForStmt {
                var unsafe *n = cast<Statements::IndexedForStmt>(s)
                if n->init != &null {
                    self._for_init = true
                    self.dispatch_stmt(n->init)
                    self._for_init = false
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
                    self._match_case(n->cases.get(i), n->scrutinee, false)
                    self._arm_end()
                }

                self._arms_finish(false)
                return s
            } case StmtKind::TryCatchStmt {
                var unsafe *n     = cast<Statements::TryCatchStmt>(s)
                var        before = self._st.copy()
                var        frame  = TryFrame()
                var        cxx    = false
                frame.block_depth = self._blocks.size()
                for var i: usize = 0; i < n->arms.size(); ++i {
                    var unsafe *arm = n->arms.get(i)
                    if self._cxx_arm(arm->is_cxx, arm->filter) {
                        cxx = true
                    } else if arm->filter == &null {
                        frame.catch_all = true
                    }

                    self._arm_of(&frame, arm->filter, arm->decl)
                }

                frame.cxx_arm = cxx
                self._tries.push(frame)
                self.dyn()->traverse_block(n->try_body)
                var met = self._tries[self._tries.size() - 1].copy()
                self._tries.pop()
                var after_try = self._st.copy()
                var acc       = after_try.copy()
                for var i: usize = 0; i < n->arms.size(); ++i {
                    var unsafe *arm = n->arms.get(i)
                    self._st = self._arm_entry_of(
                        before,
                        after_try,
                        met,
                        cxx,
                        i,
                    )

                    if arm->body != &null {
                        self.dispatch_stmt(arm->body)
                    }

                    acc = move_join(acc, self._st)
                }

                self._st = acc
                return s
            } case StmtKind::ReturnStmt {
                var unsafe *n = cast<Statements::ReturnStmt>(s)
                self._leaves += 1
                if n->value != &null {
                    self._return(n->value)
                    return s
                }

                self._run_finallys_to(0)
                self._exit(
                    if (self._fn == &null) => (MOVE_ON_RETURN) else => MOVE_ON_OTHER,
                )

                self._st.dead = true
                return s
            } case StmtKind::PanicStmt {
                var unsafe *n = cast<Statements::PanicStmt>(s)
                if n->payload != &null {
                    self.dispatch_expr(n->payload)
                }

                self._leave_by_panic(self._panic_type(n->payload))
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
                self._leaves += 1
                if f != usize::MAX {
                    self._run_finallys_to(self._loops[f].block_depth)
                    self._loops[f].breaks.push(self._st.copy())
                }

                self._st.dead = true
                return s
            } case StmtKind::ContinueStmt {
                var unsafe *n = cast<Statements::ContinueStmt>(s)
                var        f  = self._target_frame(n->has_label, n->label)
                self._leaves += 1
                if f != usize::MAX {
                    self._run_finallys_to(self._loops[f].block_depth)
                    self._loops[f].continues.push(self._st.copy())
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
    /// a path too -- when `finite`. With a condition, the body starts from
    /// its true state and the loop is left from its false state, at the
    /// entry, at the second pass's head, and once more over the second
    /// pass's back edge. An infinite loop (`loop`, `while
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
        var entry = self._st.copy()
        // The body CompoundStmt is dispatched next and lands at exactly this
        // index: cond and update are expressions, an IndexedForStmt init a
        // DeclStmt, and none opens a block.
        var frame = LoopFrame()
        frame.block_depth       = self._blocks.size()
        frame.has_label         = self._pending_has_label
        frame.label             = self._pending_label
        frame.done.dead         = true
        self._pending_has_label = false
        self._loops.push(frame)

        var exit1 = self._loop_pass(cond, body, update, rf)
        self._st = move_join(entry, exit1)
        var head  = self._st.copy()
        var exit2 = self._loop_pass(cond, body, update, rf)
        if finite && cond != &null {
            self._st = move_join(head, exit2)
            var last = self._cond(cond)
            var top  = self._loops.size() - 1
            self._loops[top].done = move_join(self._loops[top].done, last.f)
        }

        var fr = self._loops.remove(self._loops.size() - 1)

        var out = MoveState()
        out.dead = true
        if finite && cond != &null {
            out = fr.done
        } else if finite {
            out = move_join(head, exit2)
            out = move_join(out, entry)
        }

        for var i: usize = 0; i < fr.breaks.size(); ++i {
            out = move_join(out, fr.breaks[i])
        }

        self._st = out
    }

    /// Walk the pending bodies of block `i`, last declared first -- LIFO
    /// with the block's locals -- over the current state. Each body is a
    /// block of its own and opens its own frame on top; block `i` stays
    /// open, since the caller is still inside it structurally.
    priv fn _run_block_finallys(self, i: usize) {
        var k = self._blocks[i].size()
        while k > 0 {
            k = k - 1
            var unsafe *fin = self._blocks[i][k]
            if fin != &null && fin->body != &null {
                self._fin_depth += 1
                self.dispatch_stmt(fin->body)
                self._fin_depth -= 1
            }
        }

        // After the bodies: they run before the block's locals die.
        self._exit_check(i)
    }

    /// The state catch arm `arm` of a `try` starts from. A panic reaches
    /// the arms only from the points `met` recorded (_leave_by_panic):
    /// every call and user operator that may panic, every `panic`, every
    /// iteration of a `for`. An arm takes the points whose panic it can
    /// catch: all of them for a bare arm, those of its filter's type or of
    /// a type not known statically for a typed one. A C++ exception arm
    /// catches what C++ code throws, at points the walk does not see, so
    /// the entry joins the state before the body and after it, as it does
    /// when no point was recorded.
    priv fn _arm_entry_of(self,
                          const before: MoveState,
                          const after:  MoveState,
                          const met:    TryFrame,
                          has_cxx:      bool,
                          arm:          usize) -> MoveState {
        var entry = before.copy()
        if has_cxx || met.panics.is_empty() {
            entry = move_join(entry, after)
        }

        var any = arm >= met.arm_any.size() || met.arm_any[arm] != 0
        var tys = if (arm < met.arm_ty.size()) => (met.arm_ty[arm])
                  else => cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < met.panics.size(); ++i {
            var ty: unsafe *Type = &null
            if i < met.panic_ty.size() {
                ty = met.panic_ty[i]
            }

            if any || ty == &null || pset_has(unsafe &tys, ty) {
                entry = move_join(entry, met.panics[i])
            }
        }

        return entry
    }

    /// A jump out of every block from the innermost down to index `to`:
    /// their pending bodies run, innermost block first.
    priv fn _run_finallys_to(self, to: usize) {
        self._run_finallys_between(self._blocks.size(), to)
    }

    /// The blocks below index `from` down to index `to` are left:
    /// their pending bodies run, innermost block first.
    priv fn _run_finallys_between(self, from: usize, to: usize) {
        var i = from
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
        // Each step of a `for` may panic (its `op in`).
        if rf != &null {
            self._panic_path(CallMarks{})
        }

        if cond != &null {
            var r = self._cond(cond)
            self._loops[top].done = move_join(self._loops[top].done, r.f)
            self._st              = r.t
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
        for var i: usize = 0; i < self._loops[top].continues.size(); ++i {
            self._st = move_join(self._st, self._loops[top].continues[i])
        }

        if update != &null {
            self.dispatch_expr(update)
        }

        return self._st.copy()
    }

    /// # calls

    priv fn _call(self, n: unsafe *Expressions::CallExpr) {
        // Only this call is the condition, not one inside its operands.
        var split = self._split_req
        self._split_req = false
        if n->callee != &null {
            self.dispatch_expr(n->callee)
        }

        var unsafe *f = dyn_cast<FunctionDecl>(callee_expr_decl(n->callee))
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
            var unsafe *t = canon_unqual(
                self._tu.strip_nullable(n->callee->type_),
            )

            if t != &null && isa<FunctionPointerType>(t) {
                fp = cast<FunctionPointerType>(t)
            }
        }

        // The parameter view a positional argument indexes: the declared
        // params minus a receiver bound through `obj.m(...)`.
        var view: [unsafe *ParamDecl]
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

                view.push(p)
            }
        }

        // The places this call borrows (a `const` or `@inout` argument, the
        // receiver of a method), live when borrowed: another argument that
        // moves one leaves the callee reading a moved-from value.
        var borrowed: [unsafe *Expr]
        if f != &null && !is_ctor && f->is_method() && n->callee != &null {
            var unsafe *ch = dyn_cast<ChainExpr>(
                self._tu.strip_parens(n->callee),
            )

            if ch != &null && self._callee_binds_receiver(n->callee) {
                self._note_borrow(ch->base, unsafe &borrowed)
            }
        }

        var bound_p:      [unsafe *ParamDecl]
        var bound_e:      [unsafe *Expr]
        var pos:          usize               = 0
        var saved_handoff                     = self._handoff
        self._handoff = self._is_handoff(f)
        // C++ evaluates named arguments in parameter order, and the
        // arguments of a `?.` call only when the receiver is not null.
        var optional = self._optional_callee(n->callee)
        var no_must  = optional
        for var i: usize = 0; i < n->args.size(); ++i {
            if n->args[i] != &null && named_call_arg_value(n->args[i]) != &null {
                no_must = true
            }
        }

        if no_must {
            self._no_must += 1
        }

        var leaves0                     = self._leaves
        var hand_e: [unsafe *Expr]
        var hand_p: [unsafe *ParamDecl]
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
                    var nm = self.sc->ctx->get_spelling(
                        cast<Expressions::NamedArgExpr>(a)->name,
                    )

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
            var unsafe *mk = dyn_cast<Expressions::UnaryOperatorExpr>(
                self._tu.strip_parens(e),
            )

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

            var unsafe *saved_pc = self._pass_call
            var unsafe *saved_pf = self._pass_fn
            self._pass_call = n
            self._pass_fn   = f
            if mode == ParamMode::Value
                && param_is_plain_value(p)
                && e->type_ != &null
                && !e->is_poisoned()
                && self._same_type(self._pass_dest(p), e->type_)
                && (destructive_type(self.sc, e->type_) == LifecycleTri::Yes
                    || type_may_be_destructive(e->type_)) {
                hand_e.push(e)
                hand_p.push(p)
            }

            self._pass(e, p, mode)
            self._pass_call = saved_pc
            self._pass_fn   = saved_pf
            if p != &null {
                bound_p.push(p)
                bound_e.push(e)
            }

            if mode == ParamMode::Inout || p != &null && p->is_const {
                self._note_borrow(e, unsafe &borrowed)
            }
        }

        self._handoff = saved_handoff
        if no_must {
            self._no_must -= 1
        }

        // An argument may hand its storage to the callee only when nothing
        // leaves between its evaluation and the call: no argument met a
        // point the walk leaves the expression at, each is evaluated where
        // it is written, on every path, and no default is added later.
        if !self._no_hand
            && !no_must
            && self._no_must == 0
            && self._fin_depth == 0
            && self._uneval == 0
            && self._leaves == leaves0
            && f != &null
            && !n->is_poisoned()
            && pos >= view.size()
            && !self._in_cxx_try() {
            for var i: usize = 0; i < hand_e.size(); ++i {
                self.sc->hand_sites[hand_e[i] as usize as u64] = hand_p[i] as usize as u64
                var pl = self._place(hand_e[i])
                if pl.d != &null && pl.whole && pl.path.size() == 0 && !pl.elem {
                    self._hand_log_e.push(hand_e[i])
                    self._hand_log_d.push(pl.d)
                }
            }
        }

        self._moved_while_borrowed(borrowed)
        var cm = CallMarks{}
        if f != &null && !n->is_poisoned() {
            cm = self._call_leaves(n, f, is_ctor, bound_p, bound_e)
        }

        var panics = !is_ctor && self._may_panic(f, fp)
        for var i: usize = 0; i < cm.when.size(); ++i {
            if (cm.when[i] & MOVE_ON_PANIC) != 0 {
                panics = true
            }
        }

        if panics {
            // Only a declared set is read: an inferred one is solved after
            // this pass, at the panic-set barrier.
            var set   = cxx::std::vector<unsafe *Type>()
            var known = false
            if f != &null {
                var unsafe *h = panic_home(f)
                if f->where_lead == &null && h != &null && h->has_panic_set() {
                    known = panic_call_set(
                        unsafe &self._tu,
                        f,
                        n,
                        panic_call_receiver(unsafe &self._tu, n, f),
                        unsafe &set,
                    ) == PanicKnown::Set
                }
            } else if fp != &null && n->callee != &null {
                known = panic_set_of_fn_type(&self._tu, n->callee->type_, &set) == PanicKnown::Set
            }

            self._panic_path_of(cm, known, set)
        }

        // The rest of the path is the call's return: a condition marks
        // each branch with the returns that reach it.
        if split {
            self._split      = cm.copy()
            self._split_done = true
        } else {
            if n == self._link_call && !self._st.dead {
                self._link_from(n, cm)
            }

            self._apply(cm, MOVE_ON_RETURN)
        }

        // `-> !`, `__builtin_trap()`, an imported `[[noreturn]]`: nothing
        // after the call runs, so whatever it moved is never read. A `?.`
        // call is not made when the receiver is null.
        if n->type_ != &null && self._tu.is_never(n->type_) && !optional {
            self._st.dead = true
        }
    }

    /// The arguments recorded from entry `from` of the hand log on that
    /// name `d` do not hand their storage over.
    priv fn _unhand(self, d: unsafe *Decl, from: usize) {
        for var k: usize = from; k < self._hand_log_e.size(); ++k {
            if self._hand_log_d[k] == d {
                self.sc->hand_sites.erase(self._hand_log_e[k] as usize as u64)
            }
        }
    }

    /// Some `try` open here has a C++ exception arm: a C++ call may leave
    /// its body where the walk does not see.
    priv fn _in_cxx_try(self) -> bool {
        for var t: usize = 0; t < self._tries.size(); ++t {
            if self._tries[t].cxx_arm {
                return true
            }
        }

        return false
    }

    /// `e`, a callee, is reached through `?.` / `?->`: the call is made only
    /// when the receiver is not null.
    priv fn _optional_callee(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self._tu.strip_parens(e)
        while x != &null {
            if isa<ChainExpr>(x) {
                if cast<ChainExpr>(x)->has_optional_chaining() {
                    return true
                }

                x = self._tu.strip_parens(cast<ChainExpr>(x)->base)
            } else if isa<Expressions::CallExpr>(x) {
                x = self._tu.strip_parens(
                    cast<Expressions::CallExpr>(x)->callee,
                )
            } else if isa<Expressions::SubscriptExpr>(x) {
                x = self._tu.strip_parens(
                    cast<Expressions::SubscriptExpr>(x)->base,
                )
            } else {
                return false
            }
        }

        return false
    }

    /// `e`, an argument the call borrows, is a live place of a MOVE type:
    /// appended to `out` (_moved_while_borrowed).
    priv fn _note_borrow(self, e: unsafe *Expr, out: unsafe *[unsafe *Expr]) {
        // `&x` committed as the `@inout` marker borrows `x`.
        var unsafe *x  = self._tu.strip_parens(e)
        var unsafe *mk = dyn_cast<Expressions::UnaryOperatorExpr>(x)
        if mk != &null && mk->is_mode_marker {
            x = self._tu.strip_parens(mk->operand)
        }

        if x == &null || x->is_poisoned() || !moves_on_pass(self.sc, x->type_) {
            return
        }

        var pl = self._place(x)
        if pl.d != &null && pl.whole && self._st.overlap_of(pl.d, pl.path) == usize::MAX {
            out->push(x)
        }
    }

    /// A place one argument of a call borrows and a later argument moves:
    /// the callee reads it moved-from, so the call is an error at the
    /// borrowing argument, with the move as its note.
    priv fn _moved_while_borrowed(self, const borrowed: [unsafe *Expr]) {
        for var i: usize = 0; i < borrowed.size(); ++i {
            var unsafe *e = borrowed[i]
            if e->is_poisoned() || self._st.dead {
                continue
            }

            var pl = self._place(e)
            var k  = self._st.overlap_of(pl.d, pl.path)
            if k == usize::MAX {
                continue
            }

            var mp   = self._st.moved[k].copy()
            var name = self._spelled(self._tu.strip_parens(e))
            var b = self.sc->diag->report(
                DiagID::SC001E,
                e->range.start,
                f"'{name}' is borrowed by this argument and moved by a later argument of the same call, so the call reads a moved-from value",
            )

            b.first(e->range)
            b.note(mp.at.start, f"'{mp.shown}' is moved here, {mp.how}")->child_first(
                mp.at,
            )

            if mp.site != &null && self._copies_itself(mp.site) {
                self._copy_fix(
                    &b,
                    mp.site,
                    f"'{mp.shown}' has a 'copy' method: write '{self._copy_text(mp.site)}' to pass a copy instead",
                    "copy it instead",
                )
            }

            b.emit()
            e->poison()
            self.n_errored += 1
        }
    }

    /// Walks the condition `e` and returns the state on each of its
    /// outcomes. A call that is the condition, or its operand under `!`,
    /// `&&`, `||`, a postfix `?` or a comparison with `null`, marks what
    /// its callee leaves moved-from only on the branch whose outcomes move
    /// it (MoveOut::when). Any other condition is one state for both.
    priv fn _cond(self, e: unsafe *Expr) -> CondStates {
        var unsafe *x = self._tu.strip_parens(e)
        var        r  = CondStates{}
        if x == &null {
            r.t = self._st.copy()
            r.f = self._st.copy()
            return r
        }

        if isa<Expressions::UnaryOperatorExpr>(x) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
            if u->resolved_op == &null && u->operand != &null {
                if u->fix == Expressions::UnaryOperatorExpr::Fix::Prefix
                    && u->op_token.kind == TokenKind::OpExclaim {
                    var inner = self._cond(u->operand)
                    r.t     = inner.f
                    r.f     = inner.t
                    r.split = inner.split
                    return r
                }

                if u->fix == Expressions::UnaryOperatorExpr::Fix::Postfix
                    && u->op_token.kind == TokenKind::OpQuestion
                    && self._null_tested(u->operand) {
                    return self._null_split(
                        u->operand,
                        MOVE_ON_RETURN & ~MOVE_ON_NULL,
                        MOVE_ON_RETURN & ~MOVE_ON_NON_NULL,
                    )
                }
            }
        }

        if isa<Expressions::BinaryOperatorExpr>(x) {
            var unsafe *bo = cast<Expressions::BinaryOperatorExpr>(x)
            var        k   = bo->op_token.kind
            if bo->resolved_op == &null && bo->lhs != &null && bo->rhs != &null {
                if k == TokenKind::OpAmpAmp {
                    var a = self._cond(bo->lhs)
                    self._st = a.t
                    var b = self._cond(bo->rhs)
                    r.t     = b.t
                    r.f     = move_join(a.f, b.f)
                    r.split = a.split || b.split
                    return r
                }

                if k == TokenKind::OpPipePipe {
                    var a = self._cond(bo->lhs)
                    self._st = a.f
                    var b = self._cond(bo->rhs)
                    r.t     = move_join(a.t, b.t)
                    r.f     = b.f
                    r.split = a.split || b.split
                    return r
                }

                if k == TokenKind::OpEqualEqual || k == TokenKind::OpExclaimEqual {
                    var unsafe *l               = self._tu.strip_parens(bo->lhs)
                    var unsafe *rr              = self._tu.strip_parens(bo->rhs)
                    var        c:  unsafe *Expr = &null
                    if self._is_null_literal(rr) && self._null_tested(l) {
                        c = l
                    } else if self._is_null_literal(l) && self._null_tested(rr) {
                        c = rr
                    }

                    if c != &null {
                        var nul = MOVE_ON_RETURN & ~MOVE_ON_NON_NULL
                        var val = MOVE_ON_RETURN & ~MOVE_ON_NULL
                        if k == TokenKind::OpEqualEqual {
                            return self._null_split(c, nul, val)
                        }

                        return self._null_split(c, val, nul)
                    }
                }
            }
        }

        if isa<Expressions::CallExpr>(x) {
            return self._split_call(
                cast<Expressions::CallExpr>(x),
                MOVE_ON_RETURN & ~MOVE_ON_FALSE,
                MOVE_ON_RETURN & ~MOVE_ON_TRUE,
            )
        }

        var li = self._link_index(x, false)
        if li != usize::MAX {
            return self._link_cond(
                cast<NamedIdentExpr>(x),
                li,
                MOVE_ON_RETURN & ~MOVE_ON_FALSE,
                MOVE_ON_RETURN & ~MOVE_ON_TRUE,
            )
        }

        self.dispatch_expr(x)
        r.t = self._st.copy()
        r.f = self._st.copy()
        return r
    }

    /// The index of `e`'s link (CondLink) when `e` names a local that
    /// holds one of the kind `nul`; usize(-1) otherwise.
    priv fn _link_index(self, e: unsafe *Expr, nul: bool) -> usize {
        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || !isa<NamedIdentExpr>(x) {
            return usize::MAX
        }

        var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
        if d == &null {
            return usize::MAX
        }

        var i = self._st.link_of(d)
        if i == usize::MAX || self._st.links[i].nul != nul {
            return usize::MAX
        }

        return i
    }

    /// The local `n`, holding link `li`, is tested: what its call marked
    /// is taken back and marked again on each branch by the outcomes that
    /// reach it (`on_t`, `on_f`), as _split_call marks a call's. A part
    /// marked since by anything else keeps that mark on both. The link
    /// stays: the test changes neither the local nor the parts.
    priv fn _link_cond(self,
                       n:    unsafe *NamedIdentExpr,
                       li:   usize,
                       on_t: u8,
                       on_f: u8) -> CondStates {
        var link = self._st.links[li].copy()
        self._read(n)
        var r    = CondStates{}
        var cm   = CallMarks{}
        var base = self._st.copy()
        for var k: usize = 0; k < link.parts.size(); ++k {
            var i = base.index_of(link.parts[k].d, link.parts[k].path)
            if i == usize::MAX || !same_range(base.moved[i].at, link.site) {
                continue
            }

            base.moved.remove(i)
            cm.parts.push(link.parts[k].copy())
            cm.when.push(link.when[k])
        }

        base.links.push(link.copy())
        self._st = base.copy()
        self._apply(cm, on_t)
        r.t      = self._st.copy()
        self._st = base.copy()
        self._apply(cm, on_f)
        r.f      = self._st.copy()
        self._st = base
        r.split  = cm.parts.size() > 0
        return r
    }

    /// `e`, a call or a local holding a `T?` call's link (_null_tested),
    /// tested against null: `on_t` and `on_f` are the returns that make
    /// the test true and false.
    priv fn _null_split(self, e: unsafe *Expr, on_t: u8, on_f: u8) -> CondStates {
        var unsafe *x = self._tu.strip_parens(e)
        if isa<Expressions::CallExpr>(x) {
            return self._split_call(cast<Expressions::CallExpr>(x), on_t, on_f)
        }

        return self._link_cond(
            cast<NamedIdentExpr>(x),
            self._link_index(x, true),
            on_t,
            on_f,
        )
    }

    /// The call `c` is a condition: `on_t` and `on_f` are the returns
    /// that make it true and false.
    priv fn _split_call(self, c: unsafe *Expressions::CallExpr, on_t: u8, on_f: u8) -> CondStates {
        var r = CondStates{}
        self._split_req  = true
        self._split_done = false
        self.dispatch_expr(c)
        self._split_req = false
        if !self._split_done {
            r.t = self._st.copy()
            r.f = self._st.copy()
            return r
        }

        self._split_done = false
        var cm   = self._split.copy()
        var base = self._st.copy()
        self._apply(cm, on_t)
        r.t      = self._st.copy()
        self._st = base.copy()
        self._apply(cm, on_f)
        r.f      = self._st.copy()
        self._st = base
        r.split  = true
        return r
    }

    priv fn _is_null_literal(self, e: unsafe *Expr) -> bool {
        return e != &null && isa<NullLiteralExpr>(e) && !cast<NullLiteralExpr>(e)->is_ref
    }

    /// `e` passed to `p` (null for a pack tail) in `mode`. By value
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
        // argument is borrowed, not moved, and stays live. So is one of a
        // dependent type, which a MOVE instance must be free to read again.
        if !rref && p != &null && p->is_const && !p->is_pack {
            var unsafe *at = canon_unqual(e->type_)
            if moves_on_pass(self.sc, e->type_)
                || at != &null && (at->is_dependent() || at->is_instantiation_dependent()) {
                return
            }
        }

        // A C++ `T&&` binds an xvalue (`std::move(x)`), and a Kairo `const x: T`
        // is a `const T&`, and a pack forwards (`create<T>(...args)`): none copies, so a deleted copy constructor is
        // not in play (only a plain by-value parameter copies its argument).
        var borrows = rref || p != &null && (p->is_const || p->is_pack)
        // The one argument `__builtin_construct_at<T>(ptr, x)` builds its
        // `T` from, when it is a `T`: the pack forwards it to `T`'s
        // transfer constructor, a real transfer of the whole of it.
        if p != &null && !rref && self._constructs_from(e) {
            self._transfer_checked(
                e,
                "into the object it constructs",
                false,
                MoveKind::Transfer,
                e->type_,
            )

            return
        }

        self._transfer_checked(
            e,
            if (rref) => ("into a " + LangAttrs::quoted(LangAttrs::param_move()) + " parameter")
            else => "into a by-value parameter",
            !borrows,
                 if (p == &null) => (MoveKind::UnknownParam)
            else if (rref || p->is_pack) => (MoveKind::RefParam)
            else => MoveKind::Transfer,
            if (p != &null) => (self._pass_dest(p)) else => &null,
        )
    }

    /// The type of `p` as the call being bound instantiates it
    /// (`_pass_call`): the callee's own parameters read at the call's
    /// arguments and its receiver's, so a transfer into `v: T` of
    /// `Vector<C>::push` is one into a `C`. `p`'s written type when it
    /// names no parameter, or when one it names is not bound here.
    priv fn _pass_dest(self, p: unsafe *ParamDecl) -> unsafe *Type {
        if p->type_ == &null || self._pass_call == &null || self._pass_fn == &null {
            return p->type_
        }

        if !panic_dep(p->type_) {
            return p->type_
        }

        var unsafe *n    = self._pass_call
        var unsafe *f    = self._pass_fn
        var unsafe *recv = panic_call_receiver(unsafe &self._tu, n, f)
        var        d     = Deduction(self.sc, &null)
        // An extension's own parameters are the receiver's arguments its
        // target names; a constructor's record is the type it builds.
        var unsafe *rr = dyn_cast<RecordType>(canon_unqual(recv))
        if rr != &null {
            d.bind_extension_of(unsafe (f as unsafe *Decl), rr)
        }

        if n->ctor_decl != &null && n->type_ != &null && recv == &null {
            d.bind_from_record(n->type_)
        }

        if !panic_bind_call(unsafe &self._tu, unsafe &d, f, n, recv) {
            return p->type_
        }

        var unsafe *t = d.substitute(
            if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_,
        )

        return if (t != &null) => (t) else => p->type_
    }

    /// `e` is the single value `__builtin_construct_at<T>(ptr, e)` builds
    /// its object from and is itself a `T` (`_pass_call` is that call).
    priv fn _constructs_from(self, e: unsafe *Expr) -> bool {
        var unsafe *n = self._pass_call
        var unsafe *f = self._pass_fn
        if n == &null || f == &null || e == &null || e->type_ == &null || n->args.size() != 2 {
            return false
        }

        if n->args[1] != e || decl_name(unsafe (f as unsafe *Decl)) != "__builtin_construct_at" {
            return false
        }

        // The type it builds is its first type argument: the instance's,
        // or as written where the call names a generic parameter.
        var built: unsafe *Type = &null
        if n->instance != &null && n->instance->args.size() > 0 {
            built = n->instance->args[0]
        } else if n->dep_args.size() > 0 {
            built = n->dep_args[0]
        } else {
            var unsafe *c  = self._tu.strip_parens(n->callee)
            var unsafe *ni = dyn_cast<NamedIdentExpr>(c)
            var unsafe *ch = dyn_cast<ChainExpr>(c)
            if ni != &null && ni->generic_args.size() > 0 {
                built = ni->generic_args.get(0)->ty
            } else if ch != &null
                && ch->steps.size() > 0
                && ch->steps.get(ch->steps.size() - 1)->generic_args.size() > 0 {
                built = ch->steps.get(ch->steps.size() - 1)->generic_args.get(0)->ty
            }
        }

        return self._same_type(built, e->type_)
    }

    /// The value a function returns, already walked. C++ already moves a
    /// returned local or parameter, and a cast there would cost it the
    /// elision. Anything else -- a field, a dereference -- is a copy unless
    /// cast.
    priv fn _return_value(self, v: unsafe *Expr) {
        if !isa<NamedIdentExpr>(self._tu.strip_parens(v)) {
            self._transfer(
                v,
                "out of the function",
                if (self._fn != &null) => (self._fn->return_type) else => &null,
            )

            return
        }

        // A borrowing binder is no local C++ moves on its own: returning it
        // copies the element it borrows.
        var unsafe *bv = dyn_cast<VariableDecl>(
            cast<NamedIdentExpr>(self._tu.strip_parens(v))->resolved_decl,
        )

        if v != &null && bv != &null && (bv->borrows || bv->borrow_inst) {
            self._transfer(
                v,
                "out of the function",
                if (self._fn != &null) => (self._fn->return_type) else => &null,
            )

            return
        }

        // A returned local or by-value parameter converted to the return
        // type (`return x` of an `M` from a `-> M?` function) is spelled as
        // the conversion, which is no longer the bare name C++ moves on its
        // own: the move is made explicit.
        if v != &null
            && (!v->is_poisoned())
            && moves_on_pass(self.sc, v->type_)
            && self._returned_local(self._tu.strip_parens(v))
            && self._fn != &null
            && self._fn->return_type != &null
            && !self._same_type(self._fn->return_type, v->type_) {
            self._transfer(v, "out of the function", self._fn->return_type)
            return
        }

        // `return x` of the same type is C++'s implicit move. A local whose
        // other real transfers are disarmed is moved here too, so this is a
        // site of its own (LocalEnds::settle makes it one); with none, the
        // local stays a plain `T x` and the return keeps NRVO.
        if v != &null
            && (!v->is_poisoned())
            && moves_on_pass(self.sc, v->type_)
            && self._fn != &null
            && self._fn->return_type != &null
            && self._same_type(self._fn->return_type, v->type_) {
            var unsafe *rd = cast<NamedIdentExpr>(self._tu.strip_parens(v))->resolved_decl
            if rd != &null
                && (isa<VariableDecl>(rd) || self._ends.is_param(rd))
                && self._ends.is_cand(rd) {
                record_real_transfer(self.sc, v, rd)
                self._disarm_site(rd, v, true)
                self._returning = rd
            }
        }

        // `return p` of a parameter whose type an instance decides is C++'s
        // implicit move at every instance: a real transfer where the
        // parameter is a `T&&`.
        if v != &null
            && (!v->is_poisoned())
            && self._fn != &null
            && self._fn->return_type != &null
            && self._same_type(self._fn->return_type, v->type_) {
            var unsafe *dd = cast<NamedIdentExpr>(self._tu.strip_parens(v))->resolved_decl
            if dd != &null && self._ends.is_dep_param(dd) {
                self._disarm_site(dd, v, true)
                self._returning = dd
            }
        }

        // C++'s implicit move of a returned name still needs a constructor
        // that takes it, and a record whose only transfer is a `@copy` its
        // instance dropped has none (`return a` with `a: [Mv]`).
        if v != &null && (!v->is_poisoned()) && (!moves_on_pass(self.sc, v->type_)) {
            if self._mutable_copy_place(v, "out of the function", true) {
                return
            }

            var unsafe *c  = self._tu.as_value(v->type_)
            var unsafe *rd = self._tu.record_decl(c)
            if rd != &null && !self._tu.is_tuple(c) {
                if self._dropped_copy_place(v, c, rd, "out of the function") {
                    return
                }
            }

            // A returned local or by-value parameter is moved by C++; any
            // other name (a `const` parameter, a global) is copied.
            var unsafe *nx = cast<NamedIdentExpr>(self._tu.strip_parens(v))
            var unsafe *pd = dyn_cast<ParamDecl>(nx->resolved_decl)
            if !self._returned_local(nx) || pd != &null && pd->is_const {
                self._deprecated_copy_place(v, "out of the function")
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

        var view: [unsafe *ParamDecl]
        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && !f->params[i]->is_self {
                view.push(f->params[i])
            }
        }

        var ops: [unsafe *Expr]
        if via_free || !f->is_method() {
            ops.push(lhs)
        }

        ops.push(rhs)
        for var i: usize = 0; i < ops.size() && i < view.size(); ++i {
            if ops[i] != &null {
                self._pass(ops[i], view[i], view[i]->mode)
            }
        }

        self._operator_panics(opd)
    }

    /// The value parameter of the setter (`op []=` with no return type) the
    /// plain `=` `asn` stores through, or null: its last parameter.
    priv fn _setter_value_param(self,
                                asn: unsafe *Expressions::AssignOperatorExpr) -> unsafe *ParamDecl {
        var unsafe *sx = setter_store_target(asn)
        if sx == &null {
            return &null
        }

        var unsafe *f                     = cast<FunctionDecl>(sx->resolved_op)
        var        out: unsafe *ParamDecl = &null
        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && !f->params[i]->is_self {
                out = f->params[i]
            }
        }

        return out
    }

    /// A user operator `opd` marked `panic` may leave the path by a panic.
    priv fn _operator_panics(self, opd: unsafe *Decl) {
        var unsafe *f = dyn_cast<FunctionDecl>(opd)
        if f != &null && f->is_panic() {
            self._panic_path(CallMarks{})
        }
    }

    /// `p` is a C++ `T&` or `const T&` parameter.
    priv fn _lref_param(self, p: unsafe *ParamDecl) -> bool {
        if p->type_ == &null {
            return false
        }

        var unsafe *t = if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_
        return isa<CXXLValueRefType>(canon_unqual(t))
    }

    /// `p` is a C++ `T&&` parameter (a forwarding reference included).
    priv fn _rref_param(self, p: unsafe *ParamDecl) -> bool {
        if p->type_ == &null {
            return false
        }

        var unsafe *t = if (p->type_->canonical != &null) => (p->type_->canonical) else => p->type_
        return isa<CXXRValueRefType>(canon_unqual(t))
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
                        b.note(rd->range.start, type_declared_here())->child_first(
                            rd->range,
                        )
                    }

                    b.emit()
                    e->poison()
                    self.n_errored += 1
                    return
                }
            }
        }

        // A const place cannot be left moved-from (and C++ binds no `T&&`
        // to it), whatever its type.
        var unsafe *x = self._tu.strip_parens(e)
        if x != &null
            && x->value_category == Expr::ValueCategory::LValue
            && (self._const_place(x) || self._const_root(e) || place_has_const_root(x)) {
            var mv = LangAttrs::quoted(LangAttrs::param_move())
            var b = self.sc->diag->report(
                DiagID::SC301E,
                e->range.start,
                f"'{self._spelled(x)}' is const, so it cannot be passed to a {mv} parameter, which leaves its argument moved-from",
            )

            b.first(e->range)
            var pl = self._place(e)
            if pl.d != &null {
                b.note(pl.d->range.start, "declared const here")->child_first(
                    pl.d->range,
                )
            }

            b.emit()
            e->poison()
            self.n_errored += 1
            return
        }

        self._mark(
            e,
            "into a " + LangAttrs::quoted(LangAttrs::param_move()) + " parameter",
            MoveKind::MoveParam,
        )
    }

    /// A transfer of `e` (passed by value, initialized from, assigned,
    /// returned): a MOVE value moves (Doc: Ownership, Function Parameters).
    /// Only an lvalue is recorded -- C++ moves a temporary on its own --
    /// and not a const one, which cannot be moved from. The site goes to
    /// SemaContext::move_sites, where CopyMoveLowering casts it, and the
    /// binding, or the part of it, is moved-from.
    /// `dest` is the type of what the value initializes or is assigned
    /// to, when the caller knows it: only a transfer into the same type is
    /// a real one (MoveKind::Transfer); a converting constructor or `op =`
    /// may take the source by reference.
    priv fn _transfer(self, e: unsafe *Expr, const how: string, dest: unsafe *Type = &null) {
        self._transfer_checked(e, how, true, MoveKind::Transfer, dest)
    }

    /// _transfer; `copies` is false when the receiving slot is a reference
    /// (no copy happens, so _uncopyable_place has nothing to reject).
    priv fn _transfer_checked(self,
                              e:         unsafe *Expr,
                              const how: string,
                              copies:    bool,
                              kind:      MoveKind     = MoveKind::Transfer,
                              dest:      unsafe *Type = &null) {
        if e == &null || e->is_poisoned() {
            return
        }

        if !moves_on_pass(self.sc, e->type_) {
            if copies && self._mutable_copy_place(e, how, false) {
                return
            }

            if copies && self._uncopyable_place(e, how) {
                return
            }

            if copies {
                self._deprecated_copy_place(e, how)
            }

            self._dependent_transfer(
                e,
                kind == MoveKind::Transfer && self._same_type(dest, e->type_),
            )

            return
        }

        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return
        }

        // A value converted by its own `op as` (a vector viewed as a slice)
        // is that method's receiver, read where it is: nothing is
        // transferred, and the binding stays live.
        if self._converted_by_op_as(e) || self._converted_by_op_as(x) {
            return
        }

        // A borrowing match binder moved out of a match that owns its
        // scrutinee takes the payload (_take_payload): this is its move.
        if copies && isa<NamedIdentExpr>(x) && cast<NamedIdentExpr>(x)->resolved_decl != &null {
            var unsafe *pb = dyn_cast<VariableDecl>(
                cast<NamedIdentExpr>(x)->resolved_decl,
            )

            if is_borrowing_binder(pb) && self._take_payload(pb) {
                self.sc->move_sites.insert(e as usize as u64)
                self.n_moves += 1
                self._mark(e, how, kind, dest)
                return
            }
        }

        // A const place cannot be moved from, and a MOVE value cannot be
        // copied: a transfer that copies is refused here, not
        // left to clang. `self.r` in a `const self` method and `p.r` of a
        // `const p` are const by their root (place_has_const_root). A slot
        // that only borrows (`copies` false) takes no copy.
        if self._const_place(x) || self._const_root(e) || place_has_const_root(x) {
            var unsafe *bb = borrowed_binder_of(e)
            if copies && bb != &null {
                self._no_copy(
                    e,
                    f"'{self._spelled(x)}' borrows its element, so the transfer {how} cannot move it away, and moving is the only transfer its type has",
                    true,
                    bb,
                )
            } else if copies {
                self._no_copy(
                    e,
                    f"'{self._spelled(x)}' is const, so the transfer {how} cannot move it, and moving is the only transfer its type has",
                )
            }

            return
        }

        if !self._handoff && self._unowned_move(e, x, how) {
            return
        }

        self.sc->move_sites.insert(e as usize as u64)
        self.n_moves += 1
        self._mark(e, how, kind, dest)
    }

    /// `f` is `cxx::std::move` or `cxx::std::forward`: an imported `move` /
    /// `forward` whose one parameter is a `T&&`, the explicit C++ hand-off
    /// of its argument, which may name any place.
    priv fn _is_handoff(self, f: unsafe *FunctionDecl) -> bool {
        if f == &null || !decl_is_imported(f) || f->params.size() != 1 || f->params[0] == &null {
            return false
        }

        var nm = self.sc->ctx->get_spelling(f->name)
        return (nm == "move" || nm == "forward") && self._rref_param(f->params[0])
    }

    /// A transfer of the MOVE lvalue `x` (`e` unstripped) out of storage
    /// this code reaches through a pointer or a reference (`p->f`, `*p`,
    /// `self.q->f`, a C++ `T&` a call returns): refused with SC182E, since
    /// moving would empty the object for every other reader of it and
    /// nothing tracks it. A local or a by-value parameter moves, as does a
    /// part of one reached without a pointer; `cxx::std::move(...)` is the
    /// explicit hand-off and is never refused. True when reported.
    priv fn _unowned_move(self, e: unsafe *Expr, x: unsafe *Expr, const how: string) -> bool {
        if self._returned_local(x) {
            return false
        }

        var pl      = self._place(e)
        var through = false
        if pl.d == &null {
            through = self._reached_through(x)
        } else {
            through = pl.has_ptr || pl.deref || pl.opaque || !pl.whole
        }

        if !through {
            return false
        }

        var ts = self._tu.str(self._tu.as_value(e->type_))
        var b = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            f"cannot move a value of type '{ts}' out of '{self._spelled(x)}': it is reached through a pointer or a reference",
        )

        b.first(e->range)
        b.note(
            e->range.start,
            f"the transfer {how} would leave the object moved-from for every other reader of it; copy it, borrow it, or hand it off with 'cxx::std::move(...)'",
        )

        self._offer_copy(&b, e)
        self._offer_borrow(&b, e)
        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// `x`, a place rooted at no tracked binding, is storage reached
    /// through a pointer or a reference: a dereference, a `->` step, a
    /// subscript of a pointer, or a call (an lvalue call returns a
    /// reference). A global, a static and an `unwrap!` of a local are not.
    priv fn _reached_through(self, x: unsafe *Expr) -> bool {
        var unsafe *e = self._tu.strip_parens(x)
        if e == &null {
            return false
        }

        if isa<Expressions::CallExpr>(e) {
            return true
        }

        if isa<Expressions::UnaryOperatorExpr>(e) {
            return self._is_deref(cast<Expressions::UnaryOperatorExpr>(e))
        }

        if isa<Expressions::SubscriptExpr>(e) {
            var unsafe *sx = cast<Expressions::SubscriptExpr>(e)
            if sx->base == &null || sx->base->type_ == &null {
                return false
            }

            return self._tu.pointee(sx->base->type_) != &null || self._reached_through(sx->base)
        }

        if !isa<ChainExpr>(e) {
            return false
        }

        var unsafe *c = cast<ChainExpr>(e)
        for var i: usize = 0; i < c->steps.size(); ++i {
            if c->steps.get(i)->access_kind == ChainExpr::AccessKind::Arrow {
                return true
            }
        }

        return c->base != &null && self._reached_through(c->base)
    }

    /// The borrow fix-it of _unowned_move when `e` is the whole
    /// initializer of a `var` with no written type: `var x = p->f` becomes
    /// `var *x = &p->f`.
    priv fn _offer_borrow(self, b: *DiagBuilder, e: unsafe *Expr) {
        var unsafe *v = self._init_var
        if v == &null
            || v->init != e
            || v->storage != StorageClass::Var
            || v->pointer_depth != 0
            || v->nullable_shorthand
            || !v->name.range.end.is_valid()
            || !e->range.start.is_valid() {
            return
        }

        // `x = e` puts at most four characters between the name and the
        // initializer; a written type (`x: T = e`) puts more.
        var gap = e->range.start.raw() as i64 - v->name.range.end.raw() as i64
        if gap < 0 || gap > 4 {
            return
        }

        // A range that starts inside parentheses (`(*p).b`) has no
        // position where `&` takes the whole place.
        var shown = self._spelled(self._tu.strip_parens(e))
        if shown != self.sc->ctx->get_spelling(e->range) {
            return
        }

        var nm  = self.sc->ctx->get_spelling(v->name)
        var msg = f"borrow it instead: 'var *{nm} = &{shown}'"
        b->note(e->range.start, msg.copy())
        b->child_fix(
            SourceRange(v->name.range.start, v->name.range.start),
            "*",
            "borrow it",
        )

        b->child_fix(
            SourceRange(e->range.start, e->range.start),
            "&",
            "borrow it",
        )
    }

    /// ExprTyper accepted an implicit conversion of `e` through a
    /// conversion operator of its own type (SemaContext::implicit_convs).
    priv fn _converted_by_op_as(self, e: unsafe *Expr) -> bool {
        if self.sc->implicit_convs.empty() {
            return false
        }

        var it = self.sc->implicit_convs.find(e as usize as u64)
        if it == self.sc->implicit_convs.end() || it->second == &null {
            return false
        }

        return it->second->is_operator && it->second->is_method()
    }

    /// A transfer of an lvalue of a record whose copy constructor is
    /// deleted -- an imported C++ one (`var o = llvm::outs()`,
    /// `take(get_nc())`), or a Kairo class whose `@copy` is `= delete`
    /// clang rejects the copy at codegen, so Kairo refuses it first
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
            self._offer_copy(&kb, e)
            kb.note(del->range.start, "the copy constructor is deleted here")->child_first(
                del->range,
            )

            kb.emit()
            e->poison()
            self.n_errored += 1
            return true
        }

        if !decl_is_imported(rd) {
            // A Kairo record that cannot be copied, reached through a C++
            // `T&` (an imported container's element, `cv[0]`, or a `*it`):
            // MoveCheck moves only out of storage it tracks, never out of a
            // reference, so the transfer stays a copy, which clang rejected
            // An assignment of a record with no `op =` at all is
            // ClassLifecycle's SC071E.
            if !self._is_lref(e->type_)
                || self._assigning && facts->assignable == LifecycleTri::No {
                return false
            }

            return self._no_copy(
                e,
                f"'{self._spelled(x)}' is a reference into storage this code does not own (a C++ 'T&'), which is never moved from, so the transfer {how} copies it",
            )
        }

        var b = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            f"cannot copy a value of type '{self._tu.str(c)}': {facts->why_not_copyable}",
        )

        b.first(e->range)
        self._offer_copy(&b, e)
        b.note(rd->range.start, type_declared_here())->child_first(rd->range)
        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// A copy of a Kairo record that copies only from a non-const source
    /// that is not a temporary (ClassLifecycle::mutable_source_copy: a
    /// `@copy` whose `other` is not const, C++ `X(X&)`, and no move): from a
    /// const place, from a temporary that is assigned (the derived `op =`
    /// takes `X&`; a temporary that initializes is built in place and never
    /// copied), or, with `returned`, a returned local or by-value
    /// parameter, which C++ treats as an rvalue. SC302E with the `const`
    /// fix at the constructor. True when reported.
    priv fn _mutable_copy_place(self, e: unsafe *Expr, const how: string, returned: bool) -> bool {
        if e == &null || e->is_poisoned() {
            return false
        }

        var unsafe *x = self._tu.strip_parens(e)
        var unsafe *c = self._tu.as_value(e->type_)
        if x == &null || c == &null || c->is_dependent() || self._tu.is_tuple(c) {
            return false
        }

        var unsafe *rd = self._tu.record_decl(c)
        if rd == &null {
            return false
        }

        var lvalue = x->value_category == Expr::ValueCategory::LValue
        var konst = lvalue
            && (self._const_place(x) || self._const_root(e) || place_has_const_root(x))
        var moved = returned && !konst && self._returned_local(x)
        if !konst && !moved && (lvalue || !self._assigning) {
            return false
        }

        var via:   unsafe *FieldDecl = &null
        var owner: unsafe *Decl      = &null
        var unsafe *ctor = lifecycle_of(self.sc)->mutable_source_copy(
            rd,
            unsafe &via,
            unsafe &owner,
        )

        if ctor == &null {
            return false
        }

        var unsafe *src = ClassLifecycle::copy_source_param(ctor)
        if src == &null {
            return false
        }

        var ts = self._tu.str(c)
        var cs = self._record_name(owner)
        if cs.is_empty() {
            cs = ts.copy()
        }

        var pn = self.sc->ctx->get_spelling(src->name)
        var cause = f"the copy constructor of '{cs}' takes a non-const '{pn}' (C++ '{cs}({cs}&)'), and '{cs}' has no move constructor"
        if via != &null {
            cause = f"'{ts}' declares no copy constructor and its field '{self.sc->ctx->get_spelling(via->name)}' is a '{cs}', whose copy constructor takes a non-const '{pn}' (C++ '{cs}({cs}&)'), and '{cs}' has no move constructor"
        }

        var msg = ""
        if konst {
            msg = f"cannot copy '{self._spelled(x)}' {how}: it is const, and {cause}"
        } else if moved {
            msg = f"cannot return '{self._spelled(x)}': C++ moves a returned local or by-value parameter, and {cause}"
        } else {
            msg = f"cannot assign a temporary {how}: {cause}"
        }

        var b = self.sc->diag->report(
            DiagID::SC302E,
            e->range.start,
            msg.copy(),
        )

        b.first(e->range)
        b.insert(src->name.range.start, "const ", f"make '{pn}' const")
        b.note(
            src->name.range.start,
            f"the copy constructor of '{cs}' is declared here; with 'const {pn}' it copies from const objects and temporaries too",
        )->child_first(src->name.range)

        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// The name a Kairo class or struct is declared with, or "".
    priv fn _record_name(self, d: unsafe *Decl) -> string {
        if d != &null && isa<ClassDecl>(d) {
            return self.sc->ctx->get_spelling(cast<ClassDecl>(d)->name)
        }

        if d != &null && isa<StructDecl>(d) {
            return self.sc->ctx->get_spelling(cast<StructDecl>(d)->name)
        }

        return ""
    }

    /// `x` names a local variable or a by-value parameter of the function
    /// being checked: what C++ moves from when it is returned by name.
    priv fn _returned_local(self, x: unsafe *Expr) -> bool {
        if !isa<NamedIdentExpr>(x) || self._fn == &null {
            return false
        }

        var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
        if d == &null {
            return false
        }

        if isa<ParamDecl>(d) {
            var unsafe *p = cast<ParamDecl>(d)
            return !p->is_self && p->mode == ParamMode::Value
        }

        // A borrowing binder (VariableDecl::borrows, borrow_inst) holds no
        // value of its own to move.
        if isa<VariableDecl>(d) {
            var unsafe *v = cast<VariableDecl>(d)
            return v->storage == StorageClass::Var
                && !v->borrows
                && !v->borrow_inst
                && self._fn->range.contains(v->range.start)
        }

        return false
    }

    /// A copy of an lvalue of a Kairo generic record whose declared `@copy`
    /// constructor its instance loses to that constructor's `requires`
    /// (`[Mv]`: Vector's copy needs T's, vector.k). ClassLifecycle reads
    /// the declaration, so the type is COPY and the transfer is a copy, but
    /// C++ drops the constructor from the instance and clang rejected the
    /// copy. A class declares one transfer constructor (SC057E), so
    /// such a record has no move to fall back on either. An assignment is
    /// reported too: the derived `op =` is constrained the same way, and no
    /// other check sees it.
    priv fn _dropped_copy_place(self,
                                e:         unsafe *Expr,
                                c:         unsafe *Type,
                                rd:        unsafe *Decl,
                                const how: string) -> bool {
        if decl_is_imported(rd) || !self._has_constrained_copy(rd) {
            return false
        }

        var dc = ConformanceChecking(self.sc).dropped_copy(c)
        if dc.ctor == &null {
            return false
        }

        var ts = self._tu.str(c)
        var msg = f"cannot copy a value of type '{ts}': its copy constructor's requirements do not hold for it"
        if dc.element != &null {
            var es = self._tu.str(dc.element)
            msg = f"cannot copy a value of type '{ts}': copying it copies each '{es}', and '{es}' cannot be copied"
        }

        var b = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            msg.copy(),
        )

        b.first(e->range)
        b.note(
            e->range.start,
            f"'{ts}' is a copy type, so the transfer {how} copies it, and it has no move to fall back on (its one transfer constructor is '@copy'): take it as a 'const' parameter or through a pointer, or build it in place",
        )

        b.note(dc.ctor->range.start, "the copy constructor is constrained here")->child_first(
            dc.ctor->range,
        )

        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// The facts of the record `t` names (through a C++ reference) when it
    /// definitely cannot be copied; null otherwise, an Unknown included. A
    /// tuple's are its elements' (`tf` holds them).
    priv fn _uncopyable_facts(self,
                              t:  unsafe *Type,
                              tf: unsafe *LifecycleFacts,
                              rd: unsafe *(unsafe *Decl)) -> unsafe *LifecycleFacts {
        var unsafe *c = self._tu.as_value(t)
        var unsafe *r = self._tu.record_decl(c)
        if c == &null || r == &null || c->is_dependent() {
            return &null
        }

        *rd = r
        var facts: unsafe *LifecycleFacts = &null
        if self._tu.is_tuple(c) {
            *tf   = lifecycle_of(self.sc)->facts_of_type(c)
            facts = tf
            *rd   = &null                                   // a tuple is declared nowhere.
        } else {
            facts = lifecycle_of(self.sc)->facts_of(r)
        }

        return if (facts->copyable == LifecycleTri::No) => (facts) else => &null
    }

    /// SC182E at `e`, whose value is copied and cannot be: `why` says why
    /// the copy is the transfer here. False when the type can be copied.
    /// With `offer`, a place whose type copies itself gets the `.copy()`
    /// fix-it (_offer_copy). `bb`: the borrowing binder `e` reads, which
    /// gets its own note (BinderBorrow). `later`: a read of `e` after the
    /// copy, which is why it cannot be a move.
    priv fn _no_copy(self,
                     e:         unsafe *Expr,
                     const why: string,
                     offer:     bool                 = true,
                     bb:        unsafe *VariableDecl = &null,
                     later:     unsafe *Expr         = &null) -> bool {
        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(
            e->type_,
            unsafe &tf,
            unsafe &rd,
        )

        if facts == &null {
            return false
        }

        var ts = self._tu.str(self._tu.as_value(e->type_))
        var b = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            f"cannot copy a value of type '{ts}': {facts->why_not_copyable}",
        )

        b.first(e->range)
        b.note(e->range.start, why)
        if offer {
            self._offer_copy(&b, e)
        }

        if bb != &null {
            note_borrowed_binder(self.sc, &b, bb)
        }

        if later != &null {
            b.note(later->range.start, "read again here")->child_first(
                later->range,
            )
        }

        if rd != &null {
            b.note(rd->range.start, type_declared_here())->child_first(
                rd->range,
            )
        }

        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// `e` is an element reached through a user or library `op []`
    /// (`v[i]` of a `[T]` or a class), parens aside. A builtin array's or a
    /// pointer's subscript is not one: `arr[0] = arr[1]` compiles
    /// as a move, and is not refused here, like every other such move.
    priv fn _is_element(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self._tu.strip_parens(e)
        return x != &null
            && isa<Expressions::SubscriptExpr>(x)
            && cast<Expressions::SubscriptExpr>(x)->resolved_op != &null
    }

    /// `t` is a C++ `T&`, as written or canonical.
    priv fn _is_lref(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        if isa<CXXLValueRefType>(t) {
            return true
        }

        return t->canonical != &null && isa<CXXLValueRefType>(canon_unqual(t->canonical))
    }

    /// `yield e` of a const lvalue: the generator copies it to a frame local
    /// (EmitIR::_yield; the promise's `T&` cannot bind it and its `T&&`
    /// cannot take an lvalue), so a type that cannot be copied is refused
    /// here. A temporary is yielded by `T&&` and copies nothing.
    ///
    /// A loop over a generator moves each value it yields into its binder
    /// (IterLowering::_given), so in a `-> yield T` function with a MOVE
    /// `T`, `yield x` of a local or a by-value parameter is a move out of
    /// it: `x` is moved-from until it is assigned again. Any other place of
    /// a MOVE type (`self.f`, `*p`, an element) is not the generator's to
    /// give up, and cannot be copied either. A COPY value, and a non-const
    /// lvalue in a record's `op in` (whose loop copies each value it
    /// yields), is yielded by address.
    fn traverse_yield_stmt(self, n: *Statements::YieldStmt) -> *Statements::YieldStmt {
        var out = RecursiveASTVisitor<MoveCheck>::traverse_yield_stmt(self, n)
        // A generator destroyed while suspended here leaves every open block.
        self._exit_check_between(self._block_locals.size(), 0)
        if n->value == &null || n->value->is_poisoned() || n->value->type_ == &null {
            return out
        }

        var unsafe *x = self._tu.strip_parens(n->value)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return out
        }

        if canon_has_const(x->type_) || self._const_place(x) || place_has_const_root(x) {
            if !self._no_copy(
                n->value,
                f"'{self._spelled(x)}' is const, and a generator yields a const value by copying it",
            ) {
                self._deprecated_copy_place(n->value, "out of the generator")
            }

            return out
        }

        if self._fn == &null
            || (self._fn->is_operator && OperatorFacts::single_kind(self._fn) == TokenKind::KwIn) {
            return out
        }

        // A value of a generic parameter's type moves at the instances that
        // cannot copy it (_dependent_transfer).
        if !moves_on_pass(self.sc, n->value->type_) {
            if self._returned_local(x) {
                self._dependent_transfer(n->value)
            }

            return out
        }

        if self._returned_local(x) {
            self._transfer(
                n->value,
                "out of the generator, to the loop reading it",
            )

            return out
        }

        self._no_copy(
            n->value,
            f"a generator gives up the value it yields, and '{self._spelled(x)}' is not a local or a by-value parameter it can move from",
        )

        return out
    }

    /// `for x in xs`: a plain binder is a copy of each element (IterLowering,
    /// Binders), so an element type that cannot be copied is refused at the
    /// binder rather than in clang. The element is a place for an
    /// array, a slice and what a generator points at (`-> yield *T`), and
    /// for a C++ range whose `*it` is an lvalue; a C++ `*it` that returns a
    /// value builds the binder in place, and the value of a generator (a
    /// `-> yield T` function called for the loop, a `Yield<T>`) is moved
    /// into it. `*x` binds the address and copies nothing.
    ///
    /// A binder list destructures each element, and each plain binder is a
    /// copy of its part: over a pointer part (`op in` yielding
    /// `(*const K, *V)`) a copy of what it points at, over a value part a
    /// copy of the part. Over a generator value the parts are moved, as a
    /// lone binder is.
    priv fn _for_binder_copies(self, n: unsafe *Statements::RangedForStmt) {
        var k = n->iter_kind
        if k != IterKind::Array
            && k != IterKind::Slice
            && k != IterKind::User
            && k != IterKind::Cxx {
            return
        }

        if k == IterKind::Cxx
            && (n->cxx_deref == &null
                || n->cxx_deref->value_category != Expr::ValueCategory::LValue) {
            return
        }

        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *ib = n->bindings.get(i)->decl
            if ib != &null && ib->borrow_inst {
                self._inst_binders.push_back(unsafe (ib as unsafe *Decl))
            }
        }

        if n->bindings.size() == 1 {
            self._for_binder_copy(n, n->bindings.get(0), false)
            return
        }

        // A generator value's tuple is given up at the next step, and its
        // parts are moved into the binders (IterLowering::_given). A pointer
        // part binds the pointer itself, which copies.
        if k == IterKind::User
            && n->iter_op == &null
            && n->iter_yield != Statements::IterYield::Pointer
            && n->iter_yield != Statements::IterYield::UnsafePointer {
            return
        }

        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *bn = n->bindings.get(i)
            if bn == &null || bn->is_discard {
                continue
            }

            self._for_binder_copy(n, bn, self._tuple_yield_pointer_part(n, i))
        }
    }

    /// Part `i` of `n`'s tuple yield is a pointer (`-> yield (*const K, *V)`),
    /// so a `const *k` binder takes it without copying what it points at.
    priv fn _tuple_yield_pointer_part(self,
                                      n: unsafe *Statements::RangedForStmt,
                                      i: usize) -> bool {
        if n->iter_yield != Statements::IterYield::Tuple || n->iter_op == &null {
            return false
        }

        var forms = self._tu.fn_iter_yield_elems(
            dyn_cast<FunctionDecl>(self._tu.pattern_of(n->iter_op)),
        )

        return i < forms.size() && forms[i] != Statements::IterYield::Value
    }

    /// One plain binder `bn` of `n`, a copy of its element or part:
    /// refused (SC182E) when that cannot be copied. `pointer_part`: `bn`
    /// destructures a pointer part of a tuple yield, so `const *` before its
    /// name binds the pointer.
    priv fn _for_binder_copy(self,
                             n:            unsafe *Statements::RangedForStmt,
                             bn:           unsafe *Statements::Binding,
                             pointer_part: bool) {
        var unsafe *bd = bn->decl
        if bd == &null || bd->type_ == &null || bd->is_poisoned() {
            return
        }

        // A borrowing binder copies nothing (StmtTyping::_binder_modes).
        if bd->borrows || bd->borrow_inst {
            return
        }

        var k = n->iter_kind
        var unsafe *t = if (bd->type_->canonical != &null) => (bd->type_->canonical)
                        else => bd->type_
        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(t, unsafe &tf, unsafe &rd)
        if facts == &null {
            self._deprecated_copy(
                bn->range,
                t,
                f"the loop binder '{self.sc->ctx->get_spelling(bd->name)}' is a copy of each element",
                &null,
            )

            return
        }

        // A generator value gives each value it yields up at the next
        // step: a binder of the element's own type takes it by move
        // (IterLowering::_given). A record's `op in` is asked for the
        // record's elements, which stay where they are, and are copied.
        if n->bindings.size() == 1
            && k == IterKind::User
            && n->iter_op == &null
            && n->iter_elem != &null
            && canon_unqual(n->iter_elem) == canon_unqual(t) {
            return
        }

        var nm = self.sc->ctx->get_spelling(bd->name)
        var ts = self._tu.str(self._tu.as_value(t))
        var b = self.sc->diag->report(
            DiagID::SC182E,
            bn->range.start,
            f"cannot copy a value of type '{ts}': {facts->why_not_copyable}",
        )

        b.first(bn->range)
        // A value-yielding `op in` takes no `*x` binder (StmtTyping::
        // _iter_yield_rule): the element's address comes from `-> yield *T`.
        // `const *k` fits a pointer part through either `op in` form.
        var how = f"bind '*{nm}' for the element's address instead"
        if pointer_part {
            how = f"bind 'const *{nm}' for a pointer to it instead"
        } else if n->iter_yield == Statements::IterYield::Value
            || n->iter_yield == Statements::IterYield::Tuple {
            how = f"its 'op in' yields values; declare it '-> yield *{ts}' and bind '*{nm}' for the element's address"
        }

        var what = if (n->bindings.size() == 1) => ("each element")
                   else => ("its part of each element")
        b.note(
            bn->range.start,
            f"the loop binder '{nm}' is a copy of {what}; {how}",
        )

        if pointer_part && bn->shorthand.empty() && bn->type_ == &null {
            var ins = if (bn->is_explicit) => ("*") else => ("const *")
            if !bn->is_explicit || bn->is_const {
                b.insert(
                    bn->name->range.start,
                    ins,
                    f"bind a pointer to the part",
                )
            }
        }

        if rd != &null {
            b.note(rd->range.start, type_declared_here())->child_first(
                rd->range,
            )
        }

        b.emit()
        bd->poison()
        self.n_errored += 1
    }

    /// `a + b` through an `op +` derived from `op +=` copies `a`, applies
    /// `+=` to the copy and yields it (operator-overloading.mdx, Compound
    /// assignment; OperatorLowering::_derived_sum). A temporary `a` is
    /// built in the copy's place. An lvalue `a` whose type cannot be copied
    /// moves into the result instead when it is a local or a by-value
    /// parameter that nothing reads again on any path, the next iteration
    /// of a loop included (a PendingMove, settled by _settle_derived). A
    /// right operand that names `a` reads it after the move, so `a + a` is
    /// a copy. Any other place (a field, `*p`, an element, a const binding,
    /// a global, a local captured by a closure) is refused here, with the
    /// `.copy()` fix-it.
    priv fn _derived_operand(self, bo: unsafe *Expressions::BinaryOperatorExpr) {
        var unsafe *f = dyn_cast<FunctionDecl>(bo->resolved_op)
        if f == &null || bo->lhs == &null || bo->lhs->is_poisoned() {
            return
        }

        var ck = OperatorFacts::compound_of(bo->op_token.kind)
        if ck == TokenKind::TkUnknown || OperatorFacts::op_kind(f) != ck {
            return
        }

        var unsafe *x = self._tu.strip_parens(bo->lhs)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return
        }

        var sym               = self.sc->ctx->get_spelling(bo->op_token)
        var csym              = sym.copy() + "="
        var tf                = LifecycleFacts()
        var rd:  unsafe *Decl = &null
        if self._uncopyable_facts(bo->lhs->type_, unsafe &tf, unsafe &rd) == &null {
            self._deprecated_copy(
                bo->lhs->range,
                bo->lhs->type_,
                f"'{sym}' is derived from 'op {csym}', which copies its left operand '{self._spelled(x)}'",
                &null,
            )

            return
        }

        var unsafe *d = if (isa<NamedIdentExpr>(x)) => (cast<NamedIdentExpr>(x)->resolved_decl)
                        else => &null
        var local = self._returned_local(x)
            && !self._const_place(x)
            && !place_has_const_root(x)
            && !self._names(bo->rhs, d)
        if !local {
            var nm = self._spelled(x)
            var why = f"'{nm}' is not a local variable or by-value parameter read for the last time here, so it cannot be moved into the result"
            if d != &null && self._names(bo->rhs, d) {
                why = f"The right operand reads '{nm}' too, so it cannot be moved into the result"
            }

            self._derived_copy_error(bo, why, &null)
            return
        }

        var pm = PendingMove()
        pm.d          = d
        pm.path       = ""
        pm.site       = bo->lhs
        pm.is_derived = true
        self._st.add_pending(pm)
        for var i: usize = 0; i < self._derived_sites.size(); ++i {
            if self._derived_sites[i] == bo {
                return
            }
        }

        self._derived_sites.push(bo)
    }

    /// `x ?? y` takes the value out of `x` when it is not null
    /// (Compiler/Spec/Nullables.md#coalesce: `if x? => x else y`). A payload
    /// the type can copy is copied, so `x` is only read. A payload that
    /// cannot be copied moves out instead, by the rule of the derived `a + b`
    /// (_derived_operand): a local or by-value parameter that nothing reads
    /// again on any path, the next iteration of a loop included, moves into
    /// the result (a PendingMove settled by _settle_derived), and
    /// CopyMoveLowering's `x as T?&&` is the operand CoalesceLowering binds
    /// and moves from. Any other place, or one read again, is SC182E.
    priv fn _coalesce_operand(self, bo: unsafe *Expressions::BinaryOperatorExpr) {
        if bo->lhs == &null || bo->lhs->is_poisoned() || bo->lhs->type_ == &null {
            return
        }

        var unsafe *x = self._tu.strip_parens(bo->lhs)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return
        }

        var unsafe *inner = self._tu.nullable_inner(
            self._tu.as_value(bo->lhs->type_),
        )

        if inner == &null || inner->is_dependent() {
            return
        }

        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        if self._uncopyable_facts(inner, unsafe &tf, unsafe &rd) == &null {
            return
        }

        var unsafe *d = if (isa<NamedIdentExpr>(x)) => (cast<NamedIdentExpr>(x)->resolved_decl)
                        else => &null
        var nm = self._spelled(x)
        if d != &null && self._names(bo->rhs, d) {
            self._coalesce_copy_error(
                bo,
                f"The right operand reads '{nm}' too, so it cannot be moved into the result",
                &null,
            )

            return
        }

        if self._const_place(x) || place_has_const_root(x) {
            self._coalesce_copy_error(
                bo,
                f"'{nm}' is const, so it cannot be moved into the result",
                &null,
            )

            return
        }

        if !self._returned_local(x) {
            self._coalesce_copy_error(
                bo,
                f"'{nm}' is not a local variable or by-value parameter read for the last time here, so it cannot be moved into the result",
                &null,
            )

            return
        }

        var pm = PendingMove()
        pm.d          = d
        pm.path       = ""
        pm.site       = bo->lhs
        pm.is_derived = true
        self._st.add_pending(pm)
        for var i: usize = 0; i < self._derived_sites.size(); ++i {
            if self._derived_sites[i] == bo {
                return
            }
        }

        self._derived_sites.push(bo)
    }

    /// SC182E at the left operand of `x ?? y`, whose payload cannot be
    /// copied and cannot move out: `why` says why it cannot move, `read`
    /// (or null) is the read that follows it. The fix-it takes a copy
    /// with `x?.copy()` where the payload copies itself.
    priv fn _coalesce_copy_error(self,
                                 bo:        unsafe *Expressions::BinaryOperatorExpr,
                                 const why: string,
                                 read:      unsafe *Expr) {
        var unsafe *x = self._tu.strip_parens(bo->lhs)
        var unsafe *inner = self._tu.nullable_inner(
            self._tu.as_value(bo->lhs->type_),
        )

        var nm = self._spelled(x)
        var b = self.sc->diag->report(
            DiagID::SC182E,
            bo->lhs->range.start,
            f"cannot copy a value of type '{self._tu.str(inner)}': '??' takes the value out of '{nm}' when it is not null, and that value cannot be copied",
        )

        b.first(bo->lhs->range)
        b.note(bo->lhs->range.start, why)
        self._payload_copy_fix(&b, bo->lhs, inner)
        self._payload_copy_notes(&b, bo->lhs, inner, read)
        b.emit()
        bo->poison()
        self.n_errored += 1
    }

    /// The right operand of `x ?? y` is the value when `x` is null, as the
    /// else arm of an `if` expression is (_if_arm): a local or by-value
    /// parameter whose value (a `T?`'s payload, for a nullable `y`) cannot
    /// be copied moves into the result, and is moved-from after the `??`
    /// on the path that ran it. Any other such place is SC182E.
    priv fn _coalesce_fallback(self, bo: unsafe *Expressions::BinaryOperatorExpr) {
        var unsafe *y = bo->rhs
        if y == &null || y->is_poisoned() || y->type_ == &null || bo->is_poisoned() {
            return
        }

        var unsafe *x = self._tu.strip_parens(y)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return
        }

        var unsafe *t     = self._tu.as_value(y->type_)
        var unsafe *inner = self._tu.nullable_inner(t)
        var unsafe *pay   = if (inner != &null) => (inner) else => t
        if pay == &null || pay->is_dependent() {
            return
        }

        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        if self._uncopyable_facts(pay, unsafe &tf, unsafe &rd) == &null {
            return
        }

        var nm    = self._spelled(x)
        var konst = self._const_place(x) || place_has_const_root(x)
        if !konst && self._returned_local(x) {
            self.sc->move_sites.insert(y as usize as u64)
            self.n_moves += 1
            self._mark(
                y,
                "into the value of '??'",
                MoveKind::Transfer,
                y->type_,
            )

            return
        }

        var why = if (konst) => (f"'{nm}' is const, so it cannot be moved into the result")
                  else => f"'{nm}' is not a local variable or by-value parameter, so it cannot be moved into the result"
        var b = self.sc->diag->report(
            DiagID::SC182E,
            y->range.start,
            f"cannot copy a value of type '{self._tu.str(pay)}': '??' yields its right operand '{nm}' when the left one is null, and that value cannot be copied",
        )

        b.first(y->range)
        b.note(y->range.start, why)
        if inner != &null {
            self._payload_copy_fix(&b, y, inner)
        } else {
            self._offer_copy(&b, y)
        }

        self._payload_copy_notes(&b, y, pay, &null)
        b.emit()
        bo->poison()
        self.n_errored += 1
    }

    /// On `b`, the fix-it that copies the payload `inner` of the nullable
    /// place `e` (`e?.copy()`, a `T?` again) when `inner` copies itself.
    priv fn _payload_copy_fix(self, b: *DiagBuilder, e: unsafe *Expr, inner: unsafe *Type) {
        if ConformanceChecking(self.sc).copy_method(inner) == &null {
            return
        }

        var shown = self._spelled(self._tu.strip_parens(e))
        var text = if (self._copy_bare(e)) => (shown + "?.copy()") else => "(" + shown + ")?.copy()"
        b->note(
            e->range.end,
            f"'{self._tu.str(inner)}' has a 'copy' method: write '{text}' to copy the value",
        )

        if !self._copy_bare(e) {
            b->child_fix(
                SourceRange(e->range.start, e->range.start),
                "(",
                "copy it explicitly",
            )

            b->child_fix(
                SourceRange(e->range.end, e->range.end),
                ")?.copy()",
                "copy it explicitly",
            )

            return
        }

        b->child_fix(
            SourceRange(e->range.end, e->range.end),
            "?.copy()",
            "copy it explicitly",
        )
    }

    /// On `b`, reported at `at`: why `t` cannot be copied, the read that
    /// follows the copy (`read`, or null) and where `t` is declared.
    priv fn _payload_copy_notes(self,
                                b:    *DiagBuilder,
                                at:   unsafe *Expr,
                                t:    unsafe *Type,
                                read: unsafe *Expr) {
        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(t, unsafe &tf, unsafe &rd)
        if facts != &null && facts->why_not_copyable.size() > 0 {
            b->note(
                at->range.start,
                f"'{self._tu.str(t)}' cannot be copied: {facts->why_not_copyable}",
            )
        }

        if read != &null {
            b->note(read->range.start, "read again here")->child_first(
                read->range,
            )
        }

        if rd != &null {
            b->note(rd->range.start, type_declared_here())->child_first(
                rd->range,
            )
        }
    }

    /// SC182E at the left operand of the derived `bo`, which copies it:
    /// `why` says why it cannot move instead, `read` (or null) is the read
    /// that follows it.
    priv fn _derived_copy_error(self,
                                bo:        unsafe *Expressions::BinaryOperatorExpr,
                                const why: string,
                                read:      unsafe *Expr) {
        var unsafe *x   = self._tu.strip_parens(bo->lhs)
        var        nm   = self._spelled(x)
        var        sym  = self.sc->ctx->get_spelling(bo->op_token)
        var        csym = sym.copy() + "="
        if self._no_copy(
            bo->lhs,
            f"'{sym}' is derived from 'op {csym}': it copies its left operand '{nm}', applies '{csym}' to the copy and yields it; write '{nm} {csym} ...' to change it in place. {why}",
            true,
            &null,
            read,
        ) {
            bo->poison()
        }
    }

    /// `e` names the binding `d` anywhere.
    priv fn _names(self, e: unsafe *Expr, d: unsafe *Decl) -> bool {
        if e == &null || d == &null {
            return false
        }

        var scan = NameScan()
        scan.d = d
        scan.dyn()->dispatch_expr(e)
        return scan.found
    }

    /// # literals

    /// A fixed array, or a slice's backing array, is initialized element by
    /// element, so a MOVE element is moved in. A vector's elements go the
    /// way _owner_literal decides.
    fn traverse_list_literal_expr(self,
                                  n: *Expressions::ListLiteralExpr) -> *Expressions::ListLiteralExpr {
        var vec = n->elements.size() > 0 && n->type_ != &null && self._tu.is_vector_like(n->type_)
        var moved = vec
            && self._owner_literal(
                unsafe (n as unsafe *Expr),
                WellKnownType::Vector,
                "vector",
                self._tu.container_elem(n->type_),
                &null,
            )

        for var i: usize = 0; i < n->elements.size(); ++i {
            if self.stop {
                break
            }

            var unsafe *el = n->elements[i]
            self.dispatch_expr(el)
            if moved {
                self._move_elem(el, "vector literal")
            } else if !vec && el != &null && moves_on_pass(self.sc, el->type_) {
                self._move_elem(el, "array")
            }
        }

        return n
    }

    /// A tuple literal is its record's initializer: each MOVE element is
    /// moved into its field, and an lvalue of a COPY type is copied there.
    /// A tuple that is a match's scrutinee is never built (MatchLowering
    /// binds each element as its own column), so nothing leaves its
    /// elements.
    fn traverse_tuple_literal_expr(self,
                                   n: *Expressions::TupleLiteralExpr) -> *Expressions::TupleLiteralExpr {
        var built = unsafe (n as unsafe *Expr) != self._unbuilt_tuple
        for var i: usize = 0; i < n->elements.size(); ++i {
            if self.stop {
                break
            }

            var unsafe *el = n->elements[i]
            self.dispatch_expr(el)
            if !built || el == &null {
                continue
            }

            if moves_on_pass(self.sc, el->type_) {
                self._move_elem(el, "tuple")
            } else {
                self._deprecated_copy_place(el, "into the tuple")
                self._dependent_transfer(el)
            }
        }

        return n
    }

    fn traverse_set_literal_expr(self,
                                 n: *Expressions::SetLiteralExpr) -> *Expressions::SetLiteralExpr {
        var moved = n->elements.size() > 0
            && n->type_ != &null
            && self._tu.is_set_like(n->type_)
            && self._owner_literal(
                unsafe (n as unsafe *Expr),
                WellKnownType::HashSet,
                "set",
                self._tu.container_elem(n->type_),
                &null,
            )

        for var i: usize = 0; i < n->elements.size(); ++i {
            if self.stop {
                break
            }

            self.dispatch_expr(n->elements[i])
            if moved {
                self._move_elem(n->elements[i], "set literal")
            }
        }

        return n
    }

    fn traverse_map_literal_expr(self,
                                 n: *Expressions::MapLiteralExpr) -> *Expressions::MapLiteralExpr {
        var kt: unsafe *Type = &null
        var vt: unsafe *Type = &null
        var moved = n->entries.size() > 0
            && n->type_ != &null
            && self._tu.map_key_value(n->type_, unsafe &kt, unsafe &vt)
            && self._owner_literal(
                unsafe (n as unsafe *Expr),
                WellKnownType::HashMap,
                "map",
                kt,
                vt,
            )

        for var i: usize = 0; i < n->entries.size(); ++i {
            if self.stop {
                break
            }

            var unsafe *en = n->entries.get(i)
            self.dispatch_expr(en->key)
            if moved {
                self._move_elem(en->key, "map literal")
            }

            if self.stop {
                break
            }

            self.dispatch_expr(en->value)
            if moved {
                self._move_elem(en->value, "map literal")
            }
        }

        return n
    }

    /// How the non-empty vector, set or map literal `e` (a lang record
    /// `k` of `a` elements, a map of `a` keys and `b` values) takes
    /// its elements. True when it is built by TypeUtil::literal_build and
    /// each element is moved in, which the caller records element by
    /// element. False when the container copies the elements out of a
    /// backing array (ListLiteralLowering), which elements that cannot be
    /// copied do not allow: reported here, naming the element type, not in
    /// clang.
    ///
    /// A literal that fills the local it initializes transfers no container
    /// (TypeUtil::literal_fills). Any other is built in a local of its own
    /// and moved out of the expression, so its container must be a MOVE
    /// type.
    priv fn _owner_literal(self,
                           e:          unsafe *Expr,
                           k:          WellKnownType,
                           const what: string,
                           a:          unsafe *Type,
                           b:          unsafe *Type) -> bool {
        if e->is_poisoned() {
            return false
        }

        // The two-word library has one way to build a literal, whatever its
        // elements: LiteralTyping bound the calls.
        var two = self.sc->well_known->two_word()
        var by_move = two
            || !self._why_no_copy(a).is_empty()
            || b != &null && !self._why_no_copy(b).is_empty()
        var built = if (two) => (self.sc->literal_calls.count(e as usize as u64) != 0)
                    else => self._tu.literal_build(k).add != &null
        if !by_move || !built {
            if !self._literal_elems(e, a, what) && b != &null {
                self._literal_elems(e, b, what)
            }

            return false
        }

        if self._tu.literal_fills(self._init_owner, e) {
            self.sc->built_literals.insert(e as usize as u64)
            self.sc->filled_literals.insert(e as usize as u64)
            return true
        }

        var why = if (moves_on_pass(self.sc, e->type_)) => ("") else => self._why_no_copy(e->type_)
        if why.is_empty() {
            self.sc->built_literals.insert(e as usize as u64)
            return true
        }

        var ts = self._tu.str(self._tu.as_value(e->type_))
        var r = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            f"a {what} literal of elements that cannot be copied is built in place, so here it can only initialize a 'var' of type '{ts}': '{ts}' cannot be moved out of the expression, and it cannot be copied ({why})",
        )

        r.first(e->range)
        r.note(
            e->range.start,
            f"declare a 'var' of type '{ts}' with this literal as its whole initializer, and use the variable here",
        )

        r.emit()
        e->poison()
        self.n_errored += 1
        return false
    }

    /// Why a value of type `t` cannot be copied, or "" when it can (an
    /// Unknown included): the record's own facts, or a declared `@copy`
    /// whose `requires` the instance does not meet (_dropped_copy_place).
    priv fn _why_no_copy(self, t: unsafe *Type) -> string {
        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(t, unsafe &tf, unsafe &rd)
        if facts != &null {
            return facts->why_not_copyable.copy()
        }

        var unsafe *c = self._tu.as_value(t)
        if c == &null
            || rd == &null
            || c->is_dependent()
            || decl_is_imported(rd)
            || !self._has_constrained_copy(rd) {
            return ""
        }

        var dc = ConformanceChecking(self.sc).dropped_copy(c)
        if dc.ctor == &null {
            return ""
        }

        if dc.element == &null {
            return "its copy constructor's requirements do not hold for it"
        }

        var es = self._tu.str(dc.element)
        return f"copying it copies each '{es}', and '{es}' cannot be copied"
    }

    /// The element `e` of a literal (`what`) that takes its elements by
    /// move: a transfer into it. A const element cannot be moved from, and
    /// only an explicit copy can stand in its place.
    priv fn _move_elem(self, e: unsafe *Expr, const what: string) {
        if e == &null || e->is_poisoned() {
            return
        }

        var unsafe *x = self._tu.strip_parens(e)
        if x == &null
            || x->value_category != Expr::ValueCategory::LValue
            || !moves_on_pass(self.sc, e->type_)
            || !(self._const_place(x) || self._const_root(e) || place_has_const_root(x)) {
            self._transfer(e, f"into the {what}")
            return
        }

        var ts   = self._tu.str(self._tu.as_value(e->type_))
        var name = self._spelled(x)
        var b = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            f"'{name}' is const, so it cannot be moved into the {what}, and a '{ts}' is never copied implicitly: only an explicit copy, '{name}.copy()', can be an element here",
        )

        b.first(e->range)
        if self._copies_itself(e) {
            self._copy_fix(
                &b,
                e,
                f"'{ts}' has a 'copy' method: write '{self._copy_text(e)}' to put a copy of '{name}' in the {what}",
                "copy it explicitly",
            )
        } else {
            b.note(
                e->range.start,
                f"'{ts}' declares no public 'fn copy(const self) -> Self'",
            )
        }

        var pl = self._place(e)
        if pl.d != &null {
            b.note(pl.d->range.start, "declared const here")->child_first(
                pl.d->range,
            )
        }

        b.emit()
        e->poison()
        self.n_errored += 1
    }

    /// The copy-out build of a vector, set or map literal: SC182E when
    /// `elem` cannot be copied (true), else the deprecated-copy warning.
    priv fn _literal_elems(self, e: unsafe *Expr, elem: unsafe *Type, const what: string) -> bool {
        if elem == &null || e->is_poisoned() {
            return false
        }

        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(elem, unsafe &tf, unsafe &rd)
        if facts == &null {
            self._deprecated_copy(
                e->range,
                elem,
                f"the {what} copies each element out of the literal",
                &null,
            )

            return false
        }

        var ts = self._tu.str(self._tu.as_value(elem))
        var b = self.sc->diag->report(
            DiagID::SC182E,
            e->range.start,
            f"a {what} literal of '{ts}' elements cannot be built yet: the {what} copies each element out of the literal, and '{ts}' cannot be copied ({facts->why_not_copyable})",
        )

        b.first(e->range)
        b.note(
            e->range.start,
            f"build the {what} empty and add each element instead",
        )

        if rd != &null {
            b.note(rd->range.start, type_declared_here())->child_first(
                rd->range,
            )
        }

        b.emit()
        e->poison()
        self.n_errored += 1
        return true
    }

    /// `rd` declares a `@copy` constructor with a `requires` clause: the
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

    /// The `@copy ... = delete` a Kairo class or struct `rd` declares
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

    priv fn _deleted_copy_in(self,
                             methods: unsafe *FrozenList<unsafe *FunctionDecl>) -> unsafe *FunctionDecl {
        for var i: usize = 0; i < methods->size(); ++i {
            var unsafe *m = (*methods)[i]
            if m != &null
                && m->transfer == TransferKind::Copy
                && m->body_kind == FnBodyKind::Delete {
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
    ///
    /// `real`: the site is a real transfer of the whole value into its own
    /// type wherever it moves (a by-value pass, an initialization, an
    /// assignment). A pending move of a parameter's row is then a site the
    /// row counts (LocalEnds::moved_at), and on a live path the parameter
    /// joins the must-set as a MOVE value's real transfer does.
    priv fn _dependent_transfer(self, e: unsafe *Expr, real: bool = false) {
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

        var unsafe *c = canon_unqual(e->type_)
        if c == &null || !c->is_dependent() && !c->is_instantiation_dependent() {
            return
        }

        // An element of a pack (`for a in args`) is copied at every
        // instance: EmitIR's per-element lambda has no `T` to spell a `T&&`
        // with. An instance that cannot copy the element is told so there
        // (_instance_copy).
        if self._names_pack_element(c) {
            self._instance_copy(e)
            return
        }

        if lifecycle_of(self.sc)->facts_of_type(c).category != LifecycleCategory::Unknown {
            return
        }

        // A const place is copied at every instance; one that cannot copy
        // the value is told so there (_instance_copy).
        if self._const_place(x) || self._const_root(e) || place_has_const_root(x) {
            self._instance_copy(e)
            return
        }

        var pl = self._place(e)
        // `*f()`: what a call's pointer points at, which no binding names.
        if pl.d == &null
            && isa<Expressions::UnaryOperatorExpr>(x)
            && self._is_deref(cast<Expressions::UnaryOperatorExpr>(x)) {
            self.sc->instance_move_sites.insert(e as usize as u64)
            return
        }

        if pl.d == &null || !pl.whole || pl.elem {
            return
        }

        // Storage the body does not own -- a pointee, a part of `self`, of a
        // parameter that refers to the caller's object -- is never this
        // body's last use to take: it moves only where it must.
        if pl.has_ptr {
            self._instance_move(e, pl)
            return
        }

        var unsafe *d = pl.d
        if isa<ParamDecl>(d) {
            var unsafe *pd = cast<ParamDecl>(d)
            if pd->is_self || pd->mode != ParamMode::Value && pd->mode != ParamMode::Move {
                self._instance_move(e, pl)
                return
            }
        }

        // A binder that borrows at an instance that cannot copy it is never
        // moved from: it copies, and that instance is told it cannot.
        if isa<VariableDecl>(d) && cast<VariableDecl>(d)->borrow_inst {
            self._instance_copy(e)
            return
        }

        var pm = PendingMove()
        pm.d    = d
        pm.path = pl.path.copy()
        pm.site = e
        self._st.add_pending(pm)
        self._tentative.push(e)
        self._tentative_decl.push(d)
        if self._ends.is_dep_param(d) {
            if real && pl.path.size() == 0 {
                self._disarm_site(d, e, false)
            } else {
                self._ends.spoil(d)
            }
        }
    }

    /// `t` names a type pack as one element (`T` of `for a in args`), as
    /// opposed to a record over the pack (`Outcome<i32, E...>`), whose
    /// pack argument is its expansion and is spelled whole.
    priv fn _names_pack_element(self, t: unsafe *Type) -> bool {
        var unsafe *c = canon_unqual(t)
        if c == &null || !c->contains_unexpanded_pack() {
            return false
        }

        var unsafe *r = dyn_cast<RecordType>(c)
        if r == &null {
            return true
        }

        for var i: usize = 0; i < r->args.size(); ++i {
            var unsafe *a = canon_unqual(r->args[i])
            var unsafe *g = dyn_cast<GenericParamType>(a)
            if g != &null && g->is_pack {
                continue
            }

            if self._names_pack_element(a) {
                return true
            }
        }

        return r->outer != &null && self._names_pack_element(r->outer)
    }

    /// _dependent_transfer out of storage the body does not own: as the
    /// same transfer of a MOVE value is in a body that is not generic, a
    /// move out of the part, which a later read may not see again -- but
    /// only at an instance that cannot copy the value. CopyMoveLowering
    /// casts the site so (SemaContext::instance_move_sites): one C++
    /// template moves at that instance and copies at every other. The part
    /// is marked moved (MoveKind::Instance) so a read before it is
    /// assigned again is kept with the site (_read_part) for the instance
    /// check, which reports it as a use after move.
    priv fn _instance_move(self, e: unsafe *Expr, const pl: MovePlace) {
        self.sc->instance_move_sites.insert(e as usize as u64)
        var mp = MovedPart()
        mp.kind  = MoveKind::Instance
        mp.site  = e
        mp.d     = pl.d
        mp.path  = pl.path.copy()
        mp.shown = pl.shown.copy()
        mp.segs  = pl.segs.copy()
        mp.at    = e->range
        self._mark_part(mp)
    }

    /// A transfer that copies at every instance (a const place): kept with
    /// itself as the read (_reuse_site), so an instance that cannot copy
    /// the value reports the copy (ConformanceChecking::_reuse_in) rather
    /// than leave it to clang.
    priv fn _instance_copy(self, e: unsafe *Expr) {
        self._keep_reuse(e, e)
    }

    /// `read` follows `site`, a transfer whose instance decides whether it
    /// moved; once per site.
    priv fn _keep_reuse(self, site: unsafe *Expr, read: unsafe *Expr) {
        for var r: usize = 0; r < self._reuse_site.size(); ++r {
            if self._reuse_site[r] == site {
                return
            }
        }

        self._reuse_site.push_back(site)
        self._reuse_read.push_back(read)
        self._reuse_decl.push(&null)
    }

    /// A read of `path` under `d`: every pending transfer out of storage
    /// it overlaps was not the last use, so it stays a copy.
    /// `at` is the read, kept with the site for the instance check
    /// (_reuse_site): at a MOVE instance the read is a use after move.
    priv fn _demote_pending(self, d: unsafe *Decl, const path: string, at: unsafe *Expr) {
        var k: usize = 0
        while k < self._st.pend.size() {
            var pm = self._st.pend[k].copy()
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

            if pm.is_derived {
                if at != &null && self._derived_read.count(pm.site as usize as u64) == 0 {
                    self._derived_read[pm.site as usize as u64] = at as usize as u64
                }
            } else if !seen && at != &null {
                self._reuse_site.push_back(pm.site)
                self._reuse_read.push_back(at)
                self._reuse_decl.push(d)
            }

            if pm.is_pack {
                cast<Expressions::PackExpansionExpr>(pm.site)->reread = true
            } else {
                self._demoted.insert(pm.site as usize as u64)
            }

            self._st.pend.remove(k)
        }
    }

    /// `e` is a part of a const binding (`other.v` in a copy constructor's
    /// `const other`): its fields are not typed const, but C++ makes them
    /// so, and a `T&&` cast of one does not compile.
    priv fn _const_root(self, e: unsafe *Expr) -> bool {
        // What a const pointer binding points at is not const by it.
        var pl = self._place(e)
        if pl.d == &null || !pl.whole || pl.elem || pl.has_ptr {
            return false
        }

        var unsafe *d = pl.d

        if isa<VariableDecl>(d) {
            return cast<VariableDecl>(d)->is_const()
        }

        if isa<ParamDecl>(d) {
            return cast<ParamDecl>(d)->is_const
        }

        return false
    }

    /// `e`, or the binding it is a part of (`x`, `x.f`, `x[i]`, through
    /// any steps), has its address taken: see _addr.
    priv fn _mark_addr(self, e: unsafe *Expr) {
        var unsafe *x = self._tu.strip_parens(e)
        while x != &null {
            if isa<Expressions::UnaryOperatorExpr>(x)
                && cast<Expressions::UnaryOperatorExpr>(x)->is_mode_marker {
                x = self._tu.strip_parens(
                    cast<Expressions::UnaryOperatorExpr>(x)->operand,
                )

                continue
            }

            if isa<ChainExpr>(x) {
                x = self._tu.strip_parens(cast<ChainExpr>(x)->base)
                continue
            }

            if isa<Expressions::SubscriptExpr>(x) {
                x = self._tu.strip_parens(
                    cast<Expressions::SubscriptExpr>(x)->base,
                )

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
            self._st.drop_link(d)
            // A pointer into the local can store a value into its storage
            // after a move, which nothing would then destroy.
            self._ends.spoil(d)
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

    /// The storage `e` names becomes moved-from: a binding, a part of one
    /// (`p.a.b`, `self.r`), what a pointer in one points at (`p->r`, `*p`),
    /// or, for an element (`v[i]`, `h.items[0].s`), the container it is in.
    /// A temporary or a call's result records nothing.
    priv fn _mark(self,
                  e:         unsafe *Expr,
                  const how: string,
                  kind:      MoveKind     = MoveKind::Transfer,
                  dest:      unsafe *Type = &null) {
        var pl = self._place(e)
        if pl.d == &null || !pl.whole {
            return
        }

        // A provider's query (is_real_transfer) asks after the walk.
        if kind == MoveKind::Transfer
            && pl.path.size() == 0
            && !pl.elem
            && self._same_type(dest, e->type_) {
            record_real_transfer(self.sc, e, pl.d)
            self._disarm_site(pl.d, e, false)
        } else if kind == MoveKind::Transfer && pl.path.size() > 0 && !pl.elem {
            self._part_site(pl, e, dest)
        }

        var mp = MovedPart()
        mp.kind  = kind
        mp.site  = e
        mp.d     = pl.d
        mp.path  = pl.path.copy()
        mp.shown = pl.shown.copy()
        mp.segs  = pl.segs
        mp.at    = e->range
        mp.how   = how.copy()
        if pl.elem {
            mp.elem = self._spelled(e)
        }

        self._mark_part(mp)
    }

    /// `e`, a real transfer of the whole local `d` (a `return d` when `ret`),
    /// is a site the disarm provider counts (LocalEnds::moved_at), a dead
    /// path's included: EmitIR writes it wherever it is. One inside a
    /// `finally { }` body, which runs once per exit of its block, or in an
    /// operand C++ never evaluates, rules out all of `d`'s. On a live path
    /// the local joins the must-set, unless the walk cannot place the
    /// site on every path it stands on (_no_must).
    priv fn _disarm_site(self, d: unsafe *Decl, e: unsafe *Expr, ret: bool) {
        if !self._ends.is_cand(d) {
            return
        }

        var ok = self._fin_depth == 0 && self._uneval == 0
        if ret {
            self._ends.returned_at(d, e, ok)
        } else {
            self._ends.moved_at(d, e, ok)
        }

        self._must_disarm(d, ok)
    }

    /// `e`, a real transfer of the part `pl` of a local: a site the
    /// provider of part moves counts (LocalEnds::part_moved_at). It can be
    /// left out of the local's destruction only when it is a chain of
    /// by-value fields straight from the local, into the same type, every
    /// record on the way passes part_record_refusal and the part's type
    /// part_moved_refusal, and the walk places it on every path it stands
    /// on, outside a `finally { }` body and an unevaluated operand, in a
    /// function's own body. On a live path the part joins the must-set.
    priv fn _part_site(self, const pl: MovePlace, e: unsafe *Expr, dest: unsafe *Type) {
        if !self._ends.is_pcand(pl.d) {
            return
        }

        var ok = self._fin_depth == 0
            && self._uneval == 0
            && self._no_must == 0
            && self._fn != &null
            && !pl.has_ptr
            && !pl.deref
            && !pl.starred
            && !pl.opaque
            && self._same_type(dest, e->type_)
            && self._part_chain_ok(pl, e)
        self._ends.part_moved_at(pl.d, pl.path, pl.segs, ok)
        if ok && !self._st.dead && !self._st.has_part(pl.d, pl.path) {
            var mp = MovedPart()
            mp.d    = pl.d
            mp.path = pl.path.copy()
            self._st.parts.push(mp)
        }
    }

    /// `e` is `x.f1. ... .fn` on the local `pl.d`: `.` steps naming
    /// by-value fields (no tuple ordinal), each record on the way and the
    /// moved field's type as _part_site requires.
    priv fn _part_chain_ok(self, const pl: MovePlace, e: unsafe *Expr) -> bool {
        var unsafe *c = dyn_cast<ChainExpr>(self._tu.strip_parens(e))
        if c == &null
            || c->base == &null
            || c->steps.size() == 0
            || c->steps.size() != pl.segs.size() {
            return false
        }

        var unsafe *b = dyn_cast<NamedIdentExpr>(self._tu.strip_parens(c->base))
        if b == &null || b->resolved_decl != pl.d {
            return false
        }

        var unsafe *rec = c->base->type_
        for var i: usize = 0; i < c->steps.size(); ++i {
            var unsafe *st = c->steps.get(i)
            var unsafe *fd = dyn_cast<FieldDecl>(st->resolved_decl)
            if st->access_kind != ChainExpr::AccessKind::Dot
                || fd == &null
                || fd->is_static()
                || st->is_tuple_index()
                || pl.segs[i] != st->resolved_decl {
                return false
            }

            if part_record_refusal(self.sc, rec, self._fn).size() > 0 {
                return false
            }

            rec = st->resolved_type
        }

        return part_moved_refusal(self.sc, e->type_).size() == 0
    }

    /// `d`, a local whose part moves may be left out of its destruction,
    /// is alive at an exit of its scope: the parts moved out on some path
    /// and on every path here go to LocalEnds::part_exit.
    priv fn _part_exit(self, d: unsafe *Decl) {
        if !self._ends.is_pcand(d) {
            return
        }

        var may:  [string]
        var must: [string]
        for var i: usize = 0; i < self._st.moved.size(); ++i {
            if self._st.moved[i].d == d {
                may.push(self._st.moved[i].path.copy())
            }
        }

        for var i: usize = 0; i < self._st.parts.size(); ++i {
            if self._st.parts[i].d == d {
                must.push(self._st.parts[i].path.copy())
            }
        }

        self._ends.part_exit(d, may, must)
    }

    /// A disarm site of `d` that can disarm (`ok`) is reached here: on a
    /// live path the walk can place, `d` joins the must-set.
    priv fn _must_disarm(self, d: unsafe *Decl, ok: bool) {
        if ok && !self._st.dead && self._no_must == 0 && !self._st.is_disarmed(d) {
            self._st.disarmed.push(d)
        }
    }

    /// The state a whole assignment to `pl` meets, from a move of it
    /// (LocalEnds::move_remade_at): REMAKE_DEAD when a real transfer moved
    /// the whole local on every path, REMAKE_MAYBE when something moved it
    /// on some path, 0 when nothing did (or `finally()` decides it,
    /// _remake). Read before the assignment clears the marks.
    priv fn _move_remake_state(self, const pl: MovePlace) -> u8 {
        if pl.path.size() != 0 || pl.has_ptr || self._st.dead || !self._ends.is_cand(pl.d) {
            return 0
        }

        var w = self._st.index_of(pl.d, "")
        if w == usize::MAX {
            if self._st.is_disarmed(pl.d) {
                self._ends.spoil(pl.d)
            }

            return 0
        }

        if self._st.moved[w].kind == MoveKind::Finalize {
            return 0
        }

        return if (self._st.is_disarmed(pl.d)) => (Expressions::REMAKE_DEAD)
               else => Expressions::REMAKE_MAYBE
    }

    /// `*p` on a pointer: the builtin dereference, not a user `op *` and not
    /// a call-site mode marker.
    priv fn _is_deref(self, u: unsafe *Expressions::UnaryOperatorExpr) -> bool {
        return u->op_token.kind == TokenKind::OpStar
            && u->fix == Expressions::UnaryOperatorExpr::Fix::Prefix
            && !u->is_mode_marker
            && u->resolved_op == &null
            && u->operand != &null
            && u->operand->type_ != &null
            && self._tu.pointee(u->operand->type_) != &null
    }

    /// The place `e` names (MovePlace); its `d` is null when `e` is not
    /// rooted at a tracked binding.
    priv fn _place(self, e: unsafe *Expr) -> MovePlace {
        var        out = MovePlace()
        var unsafe *x  = self._tu.strip_parens(e)
        if x == &null {
            return out
        }

        if isa<NamedIdentExpr>(x) {
            var unsafe *n = cast<NamedIdentExpr>(x)
            var unsafe *d = n->resolved_decl
            if d == &null || !self._tracked(d) {
                return out
            }

            out.d     = d
            out.name  = n
            out.shown = self.sc->ctx->get_spelling(n->name)
            out.whole = true
            return out
        }

        if isa<Expressions::UnaryOperatorExpr>(x) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
            if !self._is_deref(u) {
                return out
            }

            out = self._place(u->operand)
            if out.d == &null || !out.whole {
                return MovePlace()
            }

            out.through()
            return out
        }

        if isa<Expressions::SubscriptExpr>(x) {
            var unsafe *sx = cast<Expressions::SubscriptExpr>(x)
            // `p[i]` on a pointer is pointer arithmetic over storage the
            // program manages itself (a container's buffer, moved out of
            // and destroyed element by element): which elements are live
            // is not a property of `p`.
            if sx->base == &null
                || sx->base->type_ == &null
                || self._tu.pointee(sx->base->type_) != &null {
                return out
            }

            out = self._place(sx->base)
            if out.d == &null || !out.whole {
                return MovePlace()
            }

            out.elem = true
            return out
        }

        if !isa<ChainExpr>(x) {
            return out
        }

        var unsafe *c = cast<ChainExpr>(x)
        if c->base == &null {
            return out
        }

        out = self._place(c->base)
        if out.d == &null || !out.whole {
            return MovePlace()
        }

        var unsafe *cur       = c->base->type_
        var        i:   usize = 0
        while i < c->steps.size() {
            var unsafe *st   = c->steps.get(i)
            var        arrow = st->access_kind == ChainExpr::AccessKind::Arrow
            if !arrow && st->access_kind != ChainExpr::AccessKind::Dot {
                break
            }

            // `->` on a pointer; a user `op ->` returns storage of its own.
            if arrow {
                if cur == &null || self._tu.pointee(cur) == &null {
                    out.opaque = true
                    break
                }

                out.through()
            }

            var unsafe *fd = dyn_cast<FieldDecl>(st->resolved_decl)
            if fd == &null || fd->is_static() {
                break
            }

            // `t.1` is bound to the tuple's field `_1` but has no name node
            // (an ordinal is not an identifier): the path spells the ordinal.
            if st->is_tuple_index() {
                out.field(f"{st->index}", fd)
            } else {
                out.field(self.sc->ctx->get_spelling(st->name->name), fd)
            }

            cur = st->resolved_type
            i += 1
        }

        out.whole = i == c->steps.size()
        out.rest  = c->steps.size() - i
        return out
    }

    /// The source text of `e`, for a note.
    priv fn _spelled(self, e: unsafe *Expr) -> string {
        var text = self.sc->ctx->get_spelling(e->range)
        // A chain whose base is parenthesized (`(*p).b`) has a range that
        // starts inside the parentheses: each `)` with no `(` before it
        // gets its `(` back, outside quoted text.
        var depth: i64   = 0
        var open:  usize = 0
        var quote: u8    = 0
        for var i: usize = 0; i < text.size(); ++i {
            var c = text.data()[i] as u8
            if quote != 0 {
                if c == ('\\' as u8) {
                    ++i
                } else if c == quote {
                    quote = 0
                }
            } else if c == ('"' as u8) || c == ('\'' as u8) {
                quote = c
            } else if c == ('(' as u8) {
                depth += 1
            } else if c == (')' as u8) {
                if depth == 0 {
                    open += 1
                } else {
                    depth -= 1
                }
            }
        }

        var out = ""
        for var k: usize = 0; k < open; ++k {
            out.push('(')
        }

        out += text
        return out
    }

    /// Locals and parameters, `self` included. Not fields, not statics.
    priv fn _tracked(self, d: unsafe *Decl) -> bool {
        if isa<ParamDecl>(d) {
            return true
        }

        if isa<VariableDecl>(d) {
            return !cast<VariableDecl>(d)->is_static()
        }

        return false
    }

    /// `a` and `b` are one type, cv aside; false when either is unknown.
    priv fn _same_type(self, a: unsafe *Type, b: unsafe *Type) -> bool {
        if a == &null || b == &null {
            return false
        }

        var unsafe *ca = canon_unqual(
            if (a->canonical != &null) => (a->canonical) else => a,
        )

        var unsafe *cb = canon_unqual(
            if (b->canonical != &null) => (b->canonical) else => b,
        )

        return ca != &null && ca == cb
    }

    /// A `catch` arm of a C++ exception: PanicEffectChecking marks it
    /// (`is_cxx`) only after this pass, so the filter is read the way it
    /// reads it there, a record imported from C++.
    priv fn _cxx_arm(self, marked: bool, filter: unsafe *Type) -> bool {
        if marked {
            return true
        }

        if filter == &null || filter->canonical == &null {
            return false
        }

        var unsafe *d = self._tu.record_decl(canon_unqual(filter->canonical))
        return d != &null && decl_is_imported(d)
    }

    /// # `x.finally()`

    /// `x.finally()` (Compiler/Spec/Lowering.md#union-storage-locals): the
    /// receiver is a local this body declares whose destructor is
    /// non-trivial, and the call ends it on this path (a MoveKind::Finalize
    /// part, and `ended`). What the call does is decided on its first visit,
    /// a dead path's included: EmitIR emits the call wherever it is written.
    /// A local moved (or partly moved) on a path that reaches the call is
    /// used after the move, SC052E as for a read: a move is destructive, so
    /// no object may be there to destroy.
    priv fn _finally_call(self, n: unsafe *Expressions::CallExpr) {
        if n->is_poisoned() {
            return
        }

        var unsafe *ce = cast<ChainExpr>(self._tu.strip_parens(n->callee))
        var unsafe *ni = cast<NamedIdentExpr>(self._tu.strip_parens(ce->base))
        var unsafe *d  = ni->resolved_decl
        if d == &null {
            return
        }

        var name = self.sc->ctx->get_spelling(ni->name)
        if n->finalize == Expressions::FinalizeKind::Unchecked && !self._finally_legal(n, d, name) {
            return
        }

        if n->finalize != Expressions::FinalizeKind::Ends {
            return
        }

        // Counted on a dead path too: EmitIR writes the call wherever it
        // is, and a call needs the local's union storage.
        self._ends.ended_at_site(d)
        if self._st.dead {
            return
        }

        var fi = self._st.finalized_at(d)
        if fi != usize::MAX {
            var at = self._st.moved[fi].at
            var b = self.sc->diag->report(
                DiagID::SC304E,
                n->range.start,
                f"'{name}' already finalized",
            )

            b.first(n->range)
            b.note(
                DiagCode(DiagID::SC304N),
                at.start,
                f"'{name}' was finalized here, on a path that reaches this call",
            )->child_first(at)
            b.emit()
            n->poison()
            self.n_errored += 1
            return
        }

        if self._st.overlap_of(d, "") != usize::MAX {
            self._read_part(ni, d, "", "")
            return
        }

        // Ended supersedes moved: a mark of another kind (an instance's move)
        // says nothing once the object is destroyed.
        var i: usize = 0
        while i < self._st.moved.size() {
            if self._st.moved[i].d == d {
                self._st.moved.remove(i)
                continue
            }

            i += 1
        }

        // A stored call result's link (CondLink) over a part of `d` says
        // which outcome moved it; ended, no outcome is left to say.
        var li: usize = 0
        while li < self._st.links.size() {
            var mentions = false
            for var k: usize = 0; k < self._st.links[li].parts.size(); ++k {
                if self._st.links[li].parts[k].d == d {
                    mentions = true
                }
            }

            if mentions {
                self._st.links.remove(li)
                continue
            }

            li += 1
        }

        var mp = MovedPart()
        mp.d     = d
        mp.path  = ""
        mp.shown = name.copy()
        mp.at    = n->range
        mp.how   = "by finally()"
        mp.kind  = MoveKind::Finalize
        self._st.moved.push(mp)
        if !self._st.is_ended(d) {
            self._st.ended.push(d)
        }
    }

    /// Decides what `finally()` on `d` does (CallExpr::finalize: Ends or
    /// NoEffect), or reports why it cannot run and poisons the call.
    priv fn _finally_legal(self,
                           n:          unsafe *Expressions::CallExpr,
                           d:          unsafe *Decl,
                           const name: string) -> bool {
        var unsafe *v       = dyn_cast<VariableDecl>(d)
        var        not_here = ""
        if isa<ParamDecl>(d) {
            not_here = if (cast<ParamDecl>(
                           d,
                       )->is_self) => ("it is 'self', which its owner destroys")
                       else => "it is a parameter, which the caller destroys"
        } else if v == &null {
            not_here = "it is not a variable"
        } else if v->is_static() || v->is_thread || v->is_eval() {
            not_here = "it has static storage, destroyed when the program ends"
        } else if !self._ends.has(d) {
            var unsafe *dc = d->semantic_dc
            var local = dc == &null
                || dc->is_function()
                || dc->dc_kind == DeclContextKind::Block
                || dc->dc_kind == DeclContextKind::Lambda
            not_here = if (local) => ("it is not declared by a 'var' or 'const' statement of this body (a closure's enclosing function, or a pattern, destroys it)")
                       else => "it is a global, destroyed when the program ends"
        }

        if not_here.size() > 0 {
            var b = self.sc->diag->report(
                DiagID::SC305E,
                n->range.start,
                f"finally() has no effect on '{name}'; {not_here}",
            )

            b.first(n->range)
            b.note(d->range.start, f"'{name}' is declared here")->child_first(
                d->range,
            )

            b.emit()
            n->poison()
            self.n_errored += 1
            return false
        }

        var unsup = ""
        if self._fin_depth > 0 {
            unsup = "a call inside a 'finally' block is not supported yet"
        } else if self._fn != &null && self._fn->is_eval() {
            unsup = "a local of an 'eval fn' is not supported yet"
        } else if self._ends.refusal_of(d).size() > 0 {
            unsup = self._ends.refusal_of(d) + ", which is not supported yet"
        } else if union_storage_refusal(v).size() > 0 {
            unsup = union_storage_refusal(v) + ", which is not supported yet"
        }

        var has = local_has_dtor(self.sc, v)
        // A type that depends on a generic parameter is decided per instance:
        // the union storage is valid for every T, and a trivially destroyed
        // instance runs nothing (no SC305W: the body is checked once).
        if has == LifecycleTri::Unknown
            && v->type_ != &null
            && (v->type_->canonical == &null || v->type_->canonical->is_dependent()) {
            has = LifecycleTri::Yes
        }

        if unsup.size() == 0 && has == LifecycleTri::Unknown {
            unsup = f"its type '{self._tu.str(v->type_)}' is not known, which is not supported yet"
        }

        if unsup.size() > 0 {
            var b = self.sc->diag->report(
                DiagID::SC116E,
                n->range.start,
                f"finally() on '{name}': {unsup}",
            )

            b.first(n->range)
            b.emit()
            n->poison()
            self.n_errored += 1
            return false
        }

        if has == LifecycleTri::No {
            var b = self.sc->diag->report(
                DiagID::SC305W,
                n->range.start,
                f"finally() has no effect on '{name}'; its type '{self._tu.str(v->type_)}' is trivially destroyed",
            )

            b.first(n->range)
            b.emit()
            n->finalize = Expressions::FinalizeKind::NoEffect
            return true
        }

        n->finalize = Expressions::FinalizeKind::Ends
        return true
    }

    /// `x = e` with `pl` the whole local `x` of this body: an assignment
    /// revives a finalized local as it revives a moved-from one, but the
    /// storage holds no object, so it is a construction (the old value's
    /// destructor and `op =` do not run). The states it is reached in are
    /// recorded on the node (AssignOperatorExpr::remake); maybe dead is
    /// legal, decided at run time by the `live` flag (LocalEnds::settle).
    /// After a move instead (`moved`, _move_remake_state) the states are
    /// kept on the local's row, for settle to write once it knows whether
    /// the moves are disarmed. False for anything else: a write to a part
    /// of a finalized local stays SC303E.
    priv fn _remake(self,
                    asn:      unsafe *Expressions::AssignOperatorExpr,
                    const pl: MovePlace,
                    moved:    u8) -> bool {
        if pl.path.size() != 0 || pl.has_ptr || !self._ends.has(pl.d) {
            return false
        }

        var fi = self._st.finalized_at(pl.d)
        if fi == usize::MAX && !self._st.dead && moved != 0 {
            self._ends.move_remade_at(pl.d, asn, moved)
            return true
        }

        if fi == usize::MAX || self._st.dead {
            asn->remake = asn->remake | Expressions::REMAKE_LIVE
            return fi == usize::MAX
        }

        asn->remake = asn->remake | (if (self._st.is_ended(pl.d)) => (Expressions::REMAKE_DEAD)
                                     else => Expressions::REMAKE_MAYBE)
        self._st.moved.remove(fi)
        var k: usize = 0
        while k < self._st.ended.size() {
            if self._st.ended[k] == pl.d {
                self._st.ended.remove(k)
                continue
            }

            k += 1
        }

        self._ends.remade_at(pl.d, asn)
        return true
    }

    /// A read of, or a store into, `n` after the `finally()` `mp`: SC303E.
    /// The caller keeps it to one per binding (MoveState::reported).
    priv fn _finalized_use(self, n: unsafe *NamedIdentExpr, const mp: MovedPart) {
        var b = self.sc->diag->report(
            DiagID::SC303E,
            n->range.start,
            f"use of finalized value '{mp.shown}'",
        )

        b.first(n->range)
        b.note(
            DiagCode(DiagID::SC303N),
            mp.at.start,
            f"'{mp.shown}' was finalized here; its destructor has run",
        )->child_first(mp.at)
        b.emit()
        n->poison()
        self.n_errored += 1
    }

    /// _deprecated_copy for a transfer of the lvalue `e`: a temporary is
    /// built in place and copies nothing.
    priv fn _deprecated_copy_place(self, e: unsafe *Expr, const how: string) {
        if e == &null || e->is_poisoned() || e->type_ == &null {
            return
        }

        var unsafe *x = self._tu.strip_parens(e)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return
        }

        self._deprecated_copy(
            e->range,
            e->type_,
            f"the transfer {how} copies '{self._spelled(x)}'",
            e,
        )
    }

    /// SC354W at `at` when a copy of a `t` runs a `@copy` constructor
    /// marked `@deprecated` (LifecycleFacts::deprecated_copy): the copies
    /// nothing in the source names, which the plain deprecation warning,
    /// reported at a use of the name, never sees. `why` says what copies
    /// here. `src` is the copied expression when `.copy()` after it is the
    /// rewrite, else null. Nothing inside the constructor itself is
    /// reported.
    priv fn _deprecated_copy(self,
                             at:        SourceRange,
                             t:         unsafe *Type,
                             const why: string,
                             src:       unsafe *Expr) {
        if t == &null || !at.is_valid() {
            return
        }

        var unsafe *c = self._tu.as_value(t)
        if c == &null || c->is_dependent() || c->is_instantiation_dependent() {
            return
        }

        var unsafe *cu = canon_unqual(c)
        if cu->kind != TypeKind::RecordType
            && cu->kind != TypeKind::NullableType
            && cu->kind != TypeKind::FixedArrayType {
            return
        }

        var        facts = lifecycle_of(self.sc)->facts_of_type(cu)
        var unsafe *ctor = facts.deprecated_copy
        if ctor == &null {
            return
        }

        if ctor->range.contains(at.start) {
            return
        }

        for var i: usize = 0; i < self._copy_warned.size(); ++i {
            if self._copy_warned[i] == at.start {
                return
            }
        }

        self._copy_warned.push(at.start)
        var ts = self._tu.str(cu)
        var b = self.sc->diag->report(
            DiagID::SC354W,
            at.start,
            f"implicit copy of a '{ts}', whose copy constructor is deprecated",
        )

        b.first(at)
        var unsafe *n = b.note(at.end, why)
        if src != &null && facts.deprecated_copy_via.is_empty() && self._copies_itself(src) {
            var unsafe *x = src
            if isa<NamedIdentExpr>(x)
                || isa<ChainExpr>(x)
                || isa<Expressions::CallExpr>(x)
                || isa<Expressions::SubscriptExpr>(x)
                || isa<Expressions::ParenExpr>(x) {
                n->child_fix(
                    SourceRange(at.end, at.end),
                    ".copy()",
                    "copy it explicitly",
                )
            }
        }

        if !facts.deprecated_copy_via.is_empty() {
            b.note(
                at.start,
                f"a copy of a '{ts}' copies {facts.deprecated_copy_via}",
            )
        }

        b.note(
            ctor->range.start,
            "the copy constructor is marked deprecated here",
        )->child_first(ctor->range)

        b.emit()
    }

    /// `e` reads as the receiver of a `.copy()` written after it: a name,
    /// a member, a call, an element or a parenthesized expression. Any other
    /// form (`*p`, `a as T`) binds looser than `.copy()` and is wrapped.
    priv fn _copy_bare(self, e: unsafe *Expr) -> bool {
        return isa<NamedIdentExpr>(e)
            || isa<ChainExpr>(e)
            || isa<Expressions::CallExpr>(e)
            || isa<Expressions::SubscriptExpr>(e)
            || isa<Expressions::ParenExpr>(e)
    }

    /// The explicit copy of `e` as source text: `x.copy()`, `(*p).copy()`.
    priv fn _copy_text(self, e: unsafe *Expr) -> string {
        var shown = self._spelled(self._tu.strip_parens(e))
        if self._copy_bare(e) {
            return shown + ".copy()"
        }

        return "(" + shown + ").copy()"
    }

    /// A note `text` at the end of `e` on `b`, with the fix-it (`msg`)
    /// that makes `e` an explicit copy (_copy_text).
    priv fn _copy_fix(self,
                      b:          *DiagBuilder,
                      e:          unsafe *Expr,
                      const text: string,
                      const msg:  string) {
        b->note(e->range.end, text)
        if !self._copy_bare(e) {
            b->child_fix(SourceRange(e->range.start, e->range.start), "(", msg)
            b->child_fix(
                SourceRange(e->range.end, e->range.end),
                ").copy()",
                msg,
            )

            return
        }

        b->child_fix(SourceRange(e->range.end, e->range.end), ".copy()", msg)
    }

    /// A copy of place `e` is refused on `b`: when its type copies itself,
    /// the note at its end with the fix-it writing the explicit copy.
    priv fn _offer_copy(self, b: *DiagBuilder, e: unsafe *Expr) {
        var unsafe *x = self._tu.strip_parens(e)
        if x == &null
            || x->value_category != Expr::ValueCategory::LValue
            || !self._copies_itself(e) {
            return
        }

        var ts = self._tu.str(self._tu.as_value(e->type_))
        self._copy_fix(
            b,
            e,
            f"'{ts}' has a 'copy' method: write '{self._copy_text(e)}' for an explicit copy",
            "copy it explicitly",
        )
    }

    /// The type of `e` has a public `fn copy(const self) -> Self` that
    /// `.copy()` on it calls (ConformanceChecking::copy_method): in the
    /// record, in its pattern, or in an extension whose bounds the type
    /// meets. A COPY type with no such method also takes `.copy()` (the
    /// Copyable lang item), but that is its copy constructor again, which an
    /// implicit copy already runs: no `.copy()` is offered for it.
    priv fn _copies_itself(self, e: unsafe *Expr) -> bool {
        if e->type_ == &null {
            return false
        }

        var unsafe *c = self._tu.as_value(e->type_)
        if c == &null || c->is_dependent() {
            return false
        }

        return ConformanceChecking(self.sc).copy_method(c) != &null
    }

    /// # reads

    priv fn _read(self, n: unsafe *NamedIdentExpr) {
        var unsafe *d = n->resolved_decl
        if d == &null {
            return
        }

        self._read_part(n, d, "", "")
    }

    /// A read of `path` under `d`, through the name `n`; `shown` is the
    /// storage read as source text ("" for the binding itself). An error
    /// when it touches a moved part (read_touches): the part itself,
    /// something inside it, or storage that holds the part by value.
    priv fn _read_part(self,
                       n:           unsafe *NamedIdentExpr,
                       d:           unsafe *Decl,
                       const path:  string,
                       const shown: string) {
        // A use of a local other than a test of it may change it.
        self._st.drop_link(d)
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

        // Moved only at an instance that cannot copy it: that instance's
        // error, with this read (_instance_move).
        if self._st.moved[i].kind == MoveKind::Instance {
            self._keep_reuse(self._st.moved[i].site, n)
            return
        }

        // Keyed on the BINDING alone (MoveState::reported): the first read
        // after the move is the error; later reads stay quiet until a
        // reassignment clears it.
        if self._st.was_reported(d) {
            return
        }

        self._st.reported.push(d)

        var mp = self._st.moved[i].copy()
        if mp.kind == MoveKind::Finalize {
            self._finalized_use(n, mp)
            return
        }

        var gone = mp.shown.copy()
        var read = if (shown.size() == 0) => (self.sc->ctx->get_spelling(
                       n->name,
                   ))
                   else => shown.copy()
        var part  = !path_within(path, mp.path)
        var taken = gone.copy()
        var msg   = f"'{gone}' is used after being moved"
        if mp.elem.size() > 0 {
            // An element: the container is what is moved-from.
            taken = mp.elem.copy()
            msg   = f"'{gone}' is used after '{taken}' was moved out of it"
            if part {
                msg = f"'{read}' is used after '{taken}' was moved out of its part '{gone}'"
            }
        } else if part {
            msg = f"'{read}' is used after its part '{gone}' was moved"
        }

        var b = self.sc->diag->report(
            DiagID::SC052E,
            n->range.start,
            msg.copy(),
        )

        b.first(n->range)
        b.note(mp.at.start, f"'{taken}' was moved here, {mp.how}")->child_first(
            mp.at,
        )

        // The moved type makes its own copies (`fn copy(const self) -> Self`):
        // the move may have been meant as one.
        if mp.site != &null && self._copies_itself(mp.site) {
            self._copy_fix(
                &b,
                mp.site,
                f"'{taken}' has a 'copy' method: write '{self._copy_text(mp.site)}' here if a copy was meant",
                "copy it instead",
            )
        }

        if mp.has_via {
            b.note(
                mp.via.start,
                if (mp.via_text.size() > 0) => (mp.via_text.copy())
                else => "it is moved here, and not assigned again before the body returns",
            )->child_first(mp.via)
        }

        // A callee made the C++ call, deeper than `via` (the call in the
        // callee) shows: the C++ call gets its own note.
        if mp.cxx_at.is_valid() && !(mp.cxx_at == mp.at) && !(mp.has_via && mp.via == mp.cxx_at) {
            b.note(mp.cxx_at.start, MoveCheck::_strict_cxx_note())->child_first(
                mp.cxx_at,
            )
        }

        b.note(
            n->range.start,
            f"assign a new value to '{gone}' before using it again",
        )

        b.emit()
        n->poison()
        self.n_errored += 1
    }
}

/// The writes in a generic body to its plain binders whose mode each
/// instance decides (VariableDecl::borrow_inst): an assignment or compound
/// assignment to the binder or a part of it, `++` / `--`, its address taken
/// for writing (`&x`, an `@inout` marker), and a call of a method that is
/// not `const` on it. An instance that cannot copy the binder's type binds
/// it read-only, so each of these is an error there
/// (ConformanceChecking::_check_reuse).
pub class BinderWriteScan derives RecursiveASTVisitor<BinderWriteScan> {
    pub var binders: cxx::std::vector<unsafe *Decl>
    pub var sites:   cxx::std::vector<unsafe *Expr>
    pub var of:      cxx::std::vector<unsafe *Decl>

    fn BinderWriteScan(self) { }

    /// The binder of `binders` that `e`, a place, is rooted at: `x`,
    /// `x.f`, `x[i]`, parens aside.
    priv fn _root(self, e: unsafe *Expr) -> unsafe *Decl {
        var unsafe *x = e
        while x != &null {
            if isa<Expressions::ParenExpr>(x) {
                x = cast<Expressions::ParenExpr>(x)->inner
            } else if isa<ChainExpr>(x) {
                x = cast<ChainExpr>(x)->base
            } else if isa<Expressions::SubscriptExpr>(x) {
                x = cast<Expressions::SubscriptExpr>(x)->base
            } else {
                break
            }
        }

        if x == &null || !isa<NamedIdentExpr>(x) {
            return &null
        }

        var unsafe *d = cast<NamedIdentExpr>(x)->resolved_decl
        for var i: usize = 0; i < self.binders.size(); ++i {
            if self.binders[i] == d {
                return d
            }
        }

        return &null
    }

    priv fn _note(self, site: unsafe *Expr, place: unsafe *Expr) {
        var unsafe *d = self._root(place)
        if d != &null {
            self.sites.push_back(site)
            self.of.push_back(d)
        }
    }

    fn visit_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        self._note(unsafe (n as unsafe *Expr), n->lhs)
        return true
    }

    fn visit_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        var k = n->op_token.kind
        if k == TokenKind::OpPlusPlus
            || k == TokenKind::OpMinusMinus
            || k == TokenKind::OpAmp && !n->const_addr {
            self._note(unsafe (n as unsafe *Expr), n->operand)
        }

        return true
    }

    fn visit_call_expr(self, n: *Expressions::CallExpr) -> bool {
        var unsafe *c = dyn_cast<ChainExpr>(n->callee)
        if c == &null || c->steps.size() == 0 {
            return true
        }

        var unsafe *f = dyn_cast<FunctionDecl>(
            c->steps.get(c->steps.size() - 1)->resolved_decl,
        )

        if f != &null && f->is_method() && !f->is_const() {
            self._note(unsafe (n as unsafe *Expr), c->base)
        }

        return true
    }
}

/// Whether an expression names one binding anywhere inside it.
pub class NameScan derives RecursiveASTVisitor<NameScan> {
    pub var d:     unsafe *Decl = &null
    pub var found: bool         = false

    fn NameScan(self) { }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if n->resolved_decl == self.d {
            self.found = true
        }

        return true
    }
}
