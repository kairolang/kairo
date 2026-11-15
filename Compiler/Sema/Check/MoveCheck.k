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
///         element reached through a C++ `T&` (never moved from), a deleted
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
import AST::DeclFacts::{
    decl_is_imported,
    place_has_const_root,
}
import AST::Kind::ExprKind::ExprKind
import AST::Kind::StmtKind::StmtKind
import AST::LangItems::LangAttrs
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
    ClassDecl,     FieldDecl,        FnBodyKind,   FnModifier,    FunctionDecl,  InterfaceDecl,
    MOVE_ON_FALSE, MOVE_ON_NON_NULL, MOVE_ON_NULL, MOVE_ON_OTHER, MOVE_ON_PANIC, MOVE_ON_RETURN,
    MOVE_ON_TRUE,  MoveOut,          MoveOutState, ParamDecl,     StorageClass,  StructDecl,
    TransferKind,  VariableDecl,
}
import AST::Node::Expressions
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
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::{
    RecursiveASTVisitor,
    named_call_arg_value,
}
import Diagnostic::NoteText::type_declared_here
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::{
    ClassLifecycle,
    LifecycleCategory,
    LifecycleFacts,
    LifecycleTri,
    lifecycle_of,
    moves_on_pass,
}
import Sema::Check::ConformanceChecking::ConformanceChecking
import Sema::Check::EffectPropagation::{
    PanicKnown, panic_call_receiver, panic_call_set, panic_dep, panic_home, panic_set_of_fn_type,
    pset_add,   pset_has,
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
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

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
    pub var segs: cxx::std::vector<unsafe *Decl>
    /// Moved by a call: where the callee's body moves it.
    pub var has_via:  bool        = false
    pub var via:      SourceRange
    pub var via_text: string      = ""    ///< the note at `via`; empty for the callee's move.
    fn MovedPart(self) { }
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
    pub var segs: cxx::std::vector<unsafe *Decl>
    /// Steps of the expression that are not part of the place (0 when
    /// `whole`); `opaque` when the first of them is a user `op ->`, whose
    /// result is storage of its own.
    pub var rest:   usize = 0
    pub var opaque: bool  = false
    fn MovePlace(self) { }

    /// The place \p self points at.
    fn through(self) {
        if self.elem {
            return
        }

        self.has_ptr   = true
        self.ptr_path  = self.path
        self.ptr_shown = self.shown
        self.starred   = self.deref
        self.path = if (self.path.size() == 0) => ("*") else => self.path + ".*"
        self.shown = "*" + self.shown
        self.deref = true
        var none: unsafe *Decl = &null
        self.segs.push_back(none)
    }

    /// The field \p f of \p self, declared by \p fd.
    fn field(self, const f: string, fd: unsafe *Decl) {
        if self.elem {
            return
        }

        self.segs.push_back(fd)

        self.path = if (self.path.size() == 0) => (f) else => self.path + "." + f
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

/// A read of \p read touches the moved part \p moved: it is that part or
/// inside it, or it holds the part by value. Storage that only points at
/// the part (`p`, with `p->a` moved) is read without touching it.
pub fn read_touches(const moved: string, const read: string) -> bool {
    if path_within(read, moved) {
        return true
    }

    if !path_within(moved, read) {
        return false
    }

    var star = moved.rfind("*")
    return star == usize::MAX || star < read.size()
}

/// \p a and \p b are the same range.
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
    pub var d:     unsafe *Decl ///< the local.
    pub var site:  SourceRange ///< the call: the `at` of every mark it made.
    pub var nul:   bool                        = false ///< a `T?` result, tested against null; a `bool` otherwise.
    pub var parts: cxx::std::vector<MovedPart>
    pub var when:  cxx::std::vector<u8>
    fn CondLink(self) { }

    fn holds(self, const d: unsafe *Decl, const path: string) -> bool {
        for var i: usize = 0; i < self.parts.size(); ++i {
            if self.parts[i].d == d && self.parts[i].path == path {
                return true
            }
        }

        return false
    }

    /// \p o is the same link: the same local, from the same call, over the
    /// same parts.
    fn same(self, const o: CondLink) -> bool {
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
    /// Locals whose value says which of a call's marks hold (CondLink).
    pub var links: cxx::std::vector<CondLink>
    fn MoveState(self) { }

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
                self.links.erase(self.links.cbegin() + (i as isize))
                continue
            }

            i += 1
        }
    }

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
            self.moved.push_back(p)
            return
        }

        var i: usize = 0
        while i < self.links.size() {
            if self.links[i].holds(p.d, p.path) && !same_range(self.links[i].site, p.at) {
                self.links.erase(self.links.cbegin() + (i as isize))
                continue
            }

            i += 1
        }
    }

    /// An assignment to \p path under \p d: that storage, and every part
    /// of it, holds a live value again, and a later move-then-use of it is a
    /// NEW mistake that must be reported, so the binding's report is dropped
    /// along with the move.
    fn clear(self, d: unsafe *Decl, const path: string) {
        self.drop_link(d)
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

    // A link holds after the join only when it holds on both sides.
    var out = a
    out.links.clear()
    for var i: usize = 0; i < a.links.size(); ++i {
        for var k: usize = 0; k < b.links.size(); ++k {
            if a.links[i].same(b.links[k]) {
                out.links.push_back(a.links[i])
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
    pub var breaks:    cxx::std::vector<MoveState>
    pub var continues: cxx::std::vector<MoveState>
    /// The join of the condition's false state at each evaluation: where
    /// the loop is left by its condition.
    pub var done:        MoveState
    pub var block_depth: usize     = 0 ///< _blocks.size() when the loop was entered; its body's block sits at this index.
    pub var has_label:   bool      = false ///< written `label: loop`; a labeled break/continue finds its frame by it.
    pub var label:       Token
    fn LoopFrame(self) { }
}

/// One enclosing `try` body: the state at each point inside it where a
/// panic can leave it for its catch arms.
pub class TryFrame {
    pub var panics: cxx::std::vector<MoveState>
    /// Parallel to `panics`: the type of the panic that brought each state,
    /// null when it is not known statically.
    pub var panic_ty:    cxx::std::vector<unsafe *Type>
    pub var block_depth: usize                          = 0 ///< _blocks.size() when the `try` was entered.
    /// A bare `catch` arm catches whatever reaches it: no panic passes the
    /// `try` to an enclosing one or out of the body.
    pub var catch_all: bool = false
    /// Per arm, in order: it takes a panic of any type (`arm_any`: a bare
    /// arm, or a filter that is unresolved, names a type parameter or is a
    /// C++ type), or only one of its filter's type (`arm_ty`, a set of one,
    /// as PanicWalk keeps an arm's type).
    pub var arm_any: cxx::std::vector<u8>
    pub var arm_ty:  cxx::std::vector<cxx::std::vector<unsafe *Type>>
    /// The typed arms' types: a panic of one of them stops here.
    pub var types: cxx::std::vector<unsafe *Type>
    fn TryFrame(self) { }
}

/// The parts a call's callee leaves moved-from in the caller's storage,
/// each with the outcomes on which it does (MoveOut::when). Applied by the
/// context the call is in (MoveCheck::_apply): the condition of an `if` or
/// a loop marks each branch with the outcomes that reach it.
pub struct CallMarks {
    pub var parts: cxx::std::vector<MovedPart>
    pub var when:  cxx::std::vector<u8>
    /// Parallel: the panic types on which a part with MOVE_ON_PANIC is
    /// moved-from (MoveOut::pcount); empty for a panic of any type.
    pub var ptys: cxx::std::vector<cxx::std::vector<unsafe *Type>>
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
    pub var loops:  cxx::std::vector<LoopFrame>
    pub var blocks: cxx::std::vector<cxx::std::vector<unsafe *Statements::FinallyStmt>>
    pub var tries:  cxx::std::vector<TryFrame>
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
    /// The `try` bodies open in this body, innermost last; per body like
    /// _blocks.
    priv var _tries: cxx::std::vector<TryFrame>
    /// Finally bodies being walked: a panic met inside one does not walk
    /// the pending bodies again, its own among them.
    priv var _fin_depth: usize = 0
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
    priv var _link_got:  unsafe *Expressions::CallExpr = &null
    priv var _link:      CondLink
    /// The expression body of the function being walked, until
    /// dispatch_expr meets it and walks it as the body's return (_return).
    priv var _ret_expr: unsafe *Expr = &null
    /// The label of the LabeledStmt being entered, for the loop it wraps
    /// to take onto its frame (_loop); cleared there.
    /// The transfer being checked is an assignment's right-hand side
    /// (_uncopyable_place leaves a Kairo NON_TRANSFER record to SC071E).
    priv var _assigning: bool = false
    /// The function whose body is being walked; null in a closure body and
    /// at file scope. `_caps` is the by-pointer captures of the closure
    /// being walked. `_out` is what the exits met so far leave moved-from
    /// in storage the body does not own (_exit).
    priv var _fn:   unsafe *FunctionDecl           = &null
    priv var _caps: cxx::std::vector<unsafe *Decl>
    priv var _out:  cxx::std::vector<MovedPart>
    /// Returns of the body met so far, and at how many each `_out` entry
    /// was moved-from (MoveOut::always).
    priv var _exits:    usize                   = 0
    priv var _out_hits: cxx::std::vector<usize>
    /// Parallel to `_out`: the outcomes of the exits it was moved-from at
    /// (MoveOut::when).
    priv var _out_when: cxx::std::vector<u8>
    /// Parallel to `_out`: the types of the panics it was moved-from at,
    /// and whether one of them was not known statically (MoveOut::pcount).
    priv var _out_pty:  cxx::std::vector<cxx::std::vector<unsafe *Type>>
    priv var _out_pany: cxx::std::vector<u8>
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

        // Once: a call met earlier may have walked it already.
        if self._walked.count(n as usize as u64) != 0 {
            return n
        }

        self._walked.insert(n as usize as u64)
        var saved_bp    = self._body_panics
        var saved_fn    = self._fn
        var saved_caps  = self._caps
        var saved_out   = self._out
        var saved_hits  = self._out_hits
        var saved_when  = self._out_when
        var saved_pty   = self._out_pty
        var saved_pany  = self._out_pany
        var saved_exits = self._exits
        var saved_asg   = self._assigning
        var saved_hl    = self._pending_has_label
        var saved_label = self._pending_label
        var saved_ret   = self._ret_expr
        self._fn          = n
        self._body_panics = n->is_panic()
        self._caps.clear()
        self._out.clear()
        self._out_hits.clear()
        self._out_when.clear()
        self._out_pty.clear()
        self._out_pany.clear()
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
        var saved_rd = self._reuse_decl
        self._reuse_site.clear()
        self._reuse_read.clear()
        self._reuse_decl.clear()
        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_function_decl(
            self,
            n,
        )

        self._exit(MOVE_ON_RETURN)
        self._record_out(n)
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
                mp.d     = d
                mp.path  = ""
                mp.shown = self.sc->ctx->get_spelling(n->cap_uses[i]->name)
                mp.at    = n->cap_uses[i]->range
                mp.how   = "into the closure that captures it"
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
        var saved       = self._enter_body()
        var saved_fn    = self._fn
        var saved_caps  = self._caps
        var saved_out   = self._out
        var saved_hits  = self._out_hits
        var saved_when  = self._out_when
        var saved_pty   = self._out_pty
        var saved_pany  = self._out_pany
        var saved_exits = self._exits
        var saved_bp    = self._body_panics
        self._body_panics = ((n->modifiers as u16) & (FnModifier::IsPanic as u16)) != 0
        self._fn          = &null
        self._caps.clear()
        self._out.clear()
        self._out_hits.clear()
        self._out_when.clear()
        self._out_pty.clear()
        self._out_pany.clear()
        self._exits = 0
        if n->caps_resolved {
            for var i: usize = 0; i < n->cap_decls.size(); ++i {
                var cm = n->cap_modes[i]
                if (cm == Expressions::CaptureMode::Ptr || cm == Expressions::CaptureMode::Receiver)
                    && n->cap_decls[i] != &null {
                    self._caps.push_back(n->cap_decls[i])
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
        var left = self._out
        self._fn          = saved_fn
        self._caps        = saved_caps
        self._out         = saved_out
        self._out_hits    = saved_hits
        self._out_when    = saved_when
        self._out_pty     = saved_pty
        self._out_pany    = saved_pany
        self._exits       = saved_exits
        self._body_panics = saved_bp
        self._leave_body(saved)
        // The closure may run at any time from here on, and its body leaves
        // these moved-from: the captured storage is moved-from once the
        // closure exists.
        for var i: usize = 0; i < left.size(); ++i {
            var mp = left[i]
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

                mp.path  = pl.path
                mp.shown = pl.shown
                mp.segs  = pl.segs
            }

            mp.has_via = true
            mp.via     = mp.at
            mp.at      = n->range
            mp.elem    = ""
            mp.how     = "by the closure that captures it"
            self._st.mark(mp)
        }

        return n
    }

    /// The body leaves here, by the outcome \p kind (a MOVE_ON_* bit, or
    /// several when the outcome is not known): what is moved-from in
    /// storage it does not own (_outlives) stays so for the caller.
    priv fn _exit(self, kind: u8) {
        self._exit_by(kind, &null)
    }

    /// _exit, by a panic of type \p ty when \p kind has MOVE_ON_PANIC
    /// (null: a type not known statically).
    priv fn _exit_by(self, kind: u8, ty: unsafe *Type) {
        if self._st.dead {
            return
        }

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
                self._out.push_back(self._st.moved[i])
                self._out_hits.push_back(1)
                self._out_when.push_back(kind)
                self._out_pty.push_back(cxx::std::vector<unsafe *Type>())
                self._out_pany.push_back(0)
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

    /// `return v`, or an expression body's value \p v: the body leaves
    /// with the outcome \p v is (_return_kind). A value that is a call's
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
            self._st.dead = true
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
            self._st.dead = true
            return
        }

        // \p v is a call, a bool or a local holding a result: the value
        // itself moves nothing, so neither path needs it walked again.
        var f = r.f
        self._st = r.t
        self._return_value(v)
        self._run_finallys_to(0)
        self._exit(if (nul) => (MOVE_ON_NON_NULL) else => MOVE_ON_TRUE)
        self._st = f
        self._run_finallys_to(0)
        self._exit(if (nul) => (MOVE_ON_NULL) else => MOVE_ON_FALSE)
        self._st.dead = true
    }

    /// The function's outcome at `return v` is that of a call in \p v,
    /// whose own outcome \p kind does not settle: in a `bool` function a
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

    /// \p e is a condition _cond splits on a call's outcome: a call, alone
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

    /// \p e is what a test against null splits on (_cond): a call, or a
    /// local holding a `T?` call's link.
    priv fn _null_tested(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self._tu.strip_parens(e)
        return x != &null
            && (isa<Expressions::CallExpr>(x) || self._link_index(x, true) != usize::MAX)
    }

    /// \p v, a `T?` value _null_tested splits on, walked as the value
    /// returned: its state when it is not null, and when it is.
    priv fn _null_cond(self, v: unsafe *Expr) -> CondStates {
        return self._null_split(
            v,
            MOVE_ON_RETURN & ~MOVE_ON_NULL,
            MOVE_ON_RETURN & ~MOVE_ON_NON_NULL,
        )
    }

    /// The outcome a `return` of \p v is (MoveOut::when): read from a
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

    /// \p t's canonical type, or \p t when it has none.
    priv fn _canon(self, t: unsafe *Type) -> unsafe *Type {
        if t != &null && t->canonical != &null {
            return t->canonical
        }

        return t
    }

    /// \p mp is storage the body being walked does not own: a closure's
    /// by-pointer capture, the function's `self` (not a destructor's, which
    /// ends the object), an `@inout` or C++ `T&` parameter, or what any
    /// parameter points at.
    priv fn _outlives(self, const mp: MovedPart) -> bool {
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

    /// Files `_out` on \p n (FunctionDecl::move_out), replacing what an
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

    /// \p def's body is walked before the call that needs what it leaves
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

    /// The call \p n is to \p f, a function declared in Kairo with no
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
                         const ps: cxx::std::vector<unsafe *ParamDecl>,
                         const es: cxx::std::vector<unsafe *Expr>) {
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

    /// The call \p n is to \p f, a C or C++ function. A MOVE argument bound
    /// to a `T&` / `T*` to non-const, or a MOVE object a non-const method
    /// runs on, is moved-from after the call when the callee's body moves
    /// out of it (ForeignInstantiate::cxx_moves_out). One whose body cannot
    /// be inspected borrows, on an unchecked assumption the TU records
    /// (SemaContext::assume); -fstrict-cxx-moves takes it at its worst
    /// instead. A pack parameter is not asked about.
    priv fn _call_cxx(self,
                      n:        unsafe *Expressions::CallExpr,
                      f:        unsafe *FunctionDecl,
                      const ps: cxx::std::vector<unsafe *ParamDecl>,
                      const es: cxx::std::vector<unsafe *Expr>) {
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

    /// What the C++ call \p n to \p f does to \p pl, reached through clang
    /// parameter \p idx (-1 the receiver): moved-from, borrowed, or
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
        mp.path    = pl.path
        mp.shown   = pl.shown
        mp.segs    = pl.segs
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

            self._st.mark(mp)
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
        self._st.mark(mp)
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

    /// A value of type \p t can be left moved-from: only a MOVE type can,
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

    /// \p pl becomes moved-from at \p at, by a call to \p f, whose body
    /// cannot be read: the note at the declaration says how to state what
    /// it does.
    priv fn _mark_place(self,
                        const pl:  MovePlace,
                        at:        SourceRange,
                        const how: string,
                        f:         unsafe *FunctionDecl) {
        var mp = MovedPart()
        mp.d       = pl.d
        mp.path    = pl.path
        mp.shown   = pl.shown
        mp.segs    = pl.segs
        mp.at      = at
        mp.how     = how
        mp.has_via = true
        mp.via     = f->range
        var mv = LangAttrs::param_move()
        mp.via_text = f"declared here with no body: write the parameter as '{mv}' if the function takes the value, or 'const' (a pointer to const) if it only reads it"

        self._st.mark(mp)
    }

    /// The call \p n to \p f: each part \p f leaves moved-from
    /// (FunctionDecl::move_out) is that part of the argument it was reached
    /// through, returned with the outcomes on which it is moved-from for
    /// the caller to mark (_apply). \p ps / \p es are the parameters bound
    /// and their arguments. An argument that names no place marks nothing.
    /// A function with no readable body marks its worst case here, on every
    /// outcome (_call_unseen).
    priv fn _call_leaves(self,
                         n:        unsafe *Expressions::CallExpr,
                         f:        unsafe *FunctionDecl,
                         is_ctor:  bool,
                         const ps: cxx::std::vector<unsafe *ParamDecl>,
                         const es: cxx::std::vector<unsafe *Expr>) -> CallMarks {
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
                mp.path    = pl.path
                mp.shown   = pl.shown
                mp.segs    = pl.segs
                mp.at      = n->range
                mp.how     = f"by the call to '{name}'"
                mp.has_via = true
                mp.via     = mo.at
                var tys = cxx::std::vector<unsafe *Type>()
                var pe  = (mo.pfirst as usize) + (mo.pcount as usize)
                for var s = mo.pfirst as usize; s < pe && s < def->move_out_panic.size(); ++s {
                    tys.push_back(def->move_out_panic[s])
                }

                cm.parts.push_back(mp)
                cm.when.push_back(mo.when)
                cm.ptys.push_back(tys)
            }
        }

        return cm
    }

    /// Marks each part of \p cm that is moved-from on an outcome in \p on
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

            var mp = cm.parts[i]
            if hit == MOVE_ON_TRUE {
                mp.how = mp.how + ", when it returns true"
            } else if hit == MOVE_ON_FALSE {
                mp.how = mp.how + ", when it returns false"
            } else if hit == MOVE_ON_NULL {
                mp.how = mp.how + ", when it returns null"
            } else if hit == MOVE_ON_NON_NULL {
                mp.how = mp.how + ", when it does not return null"
            } else if hit == MOVE_ON_PANIC {
                mp.how      = mp.how + ", when it panics"
                mp.via_text = "it is moved here, and not assigned again before the body panics"
            }

            self._st.mark(mp)
        }
    }

    /// The current path may leave by a panic here, with the parts of \p cm
    /// a panic of the call leaves moved-from: the state goes to the catch
    /// arms of each enclosing `try` up to one that catches everything, and
    /// past them out of the body when the body may panic. The current path
    /// itself goes on unchanged.
    priv fn _panic_path(self, const cm: CallMarks) {
        self._panic_path_of(cm, false, cxx::std::vector<unsafe *Type>())
    }

    /// _panic_path for a call that panics only with the types of \p set
    /// when \p known (its declared set), and with any type otherwise. The
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

        if self._tries.empty() && !self._body_panics {
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

        var saved = self._st
        for var i: usize = 0; i < tys.size(); ++i {
            self._st = saved
            var ty: unsafe *Type = tys[i]
            if panic_dep(ty) {
                ty = &null
            }

            self._apply(self._panic_marks(cm, tys[i]), MOVE_ON_PANIC)
            self._leave_by_panic(ty)
        }

        if !known || tys.empty() {
            self._st = saved
            self._apply(self._panic_marks(cm, &null), MOVE_ON_PANIC)
            self._leave_by_panic(&null)
        }

        self._st = saved
    }

    /// The parts of \p cm moved-from by a panic of type \p ty: those a
    /// panic of any type moves, and, when \p ty is known, those its type
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

            out.parts.push_back(cm.parts[i])
            out.when.push_back(cm.when[i])
            out.ptys.push_back(tys)
        }

        return out
    }

    /// The type a `panic` of \p p raises, or null when it is not known
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
    /// binding, onto \p fr (TryFrame::arm_any, arm_ty, types).
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

        fr.arm_any.push_back(any as u8)
        fr.arm_ty.push_back(one)
    }

    /// A panic of type \p ty (null: not known statically) leaves the
    /// current path (it is dead after): the pending finally bodies of the
    /// blocks it leaves run over it, each enclosing `try` it reaches takes
    /// the state for its catch arms, up to one with a bare arm or an arm of
    /// exactly \p ty, and one that passes them all leaves the body (_exit).
    priv fn _leave_by_panic(self, ty: unsafe *Type) {
        if self._st.dead {
            return
        }

        // Each block is left once: its bodies run before the first `try`
        // outside it takes the state.
        var open = self._blocks.size()
        var i    = self._tries.size()
        while i > 0 {
            i = i - 1
            if self._fin_depth == 0 {
                self._run_finallys_between(open, self._tries[i].block_depth)
            }

            open = self._tries[i].block_depth

            if self._st.dead {
                return
            }

            self._tries[i].panics.push_back(self._st)
            self._tries[i].panic_ty.push_back(ty)
            if self._tries[i].catch_all
                || (ty != &null && pset_has(unsafe &self._tries[i].types, ty)) {
                self._st.dead = true
                return
            }
        }

        if self._fin_depth == 0 {
            self._run_finallys_between(open, 0)
        }

        self._exit_by(MOVE_ON_PANIC, ty)
        self._st.dead = true
    }

    /// A call to \p f, or through a value of type \p fp, can leave by a
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
        saved.st     = self._st
        saved.loops  = self._loops
        saved.blocks = self._blocks
        saved.tries  = self._tries
        self._st     = MoveState()
        self._loops  = cxx::std::vector<LoopFrame>()
        self._blocks = cxx::std::vector<cxx::std::vector<unsafe *Statements::FinallyStmt>>()
        self._tries = cxx::std::vector<TryFrame>()
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
        self._tries  = saved.tries
    }

    /// `var b = a` moves a MOVE `a` into `b`. The declaration also makes `b`
    /// a new, live binding: in a loop body, last iteration's move of it
    /// says nothing about this one.
    fn traverse_variable_decl(self, n: unsafe *VariableDecl) -> unsafe *VariableDecl {
        if n == &null {
            return n
        }

        var unsafe *saved_lc = self._link_call
        var unsafe *target   = self._link_target(n)
        self._link_call = target
        var unsafe *out = RecursiveASTVisitor<MoveCheck>::traverse_variable_decl(
            self,
            n,
        )

        self._link_call = saved_lc
        if n->init != &null {
            self._transfer(
                n->init,
                f"into '{self.sc->ctx->get_spelling(n->name)}'",
            )
        }

        self._st.clear(n, "")
        if target != &null && self._link_got == target {
            self._link_got = &null
            if !self._st.dead && self._link.parts.size() > 0 {
                self._link.d = n
                self._st.links.push_back(self._link)
            }
        }

        return out
    }

    /// The call initialising \p n when a later test of \p n can stand for
    /// a test of the call: a local of the body, the call its whole
    /// initializer, of type `bool` or `T?`, and the local declared with
    /// that type or none.
    priv fn _link_target(self, n: unsafe *VariableDecl) -> unsafe *Expressions::CallExpr {
        if n->init == &null || n->is_static() || self._blocks.empty() {
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

    /// The call \p n initialises the local being declared (_link_target):
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

            l.parts.push_back(cm.parts[i])
            l.when.push_back(cm.when[i])
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

                        self.dispatch_expr(asn->rhs)
                        self._assigning = true
                        self._transfer(
                            asn->rhs,
                            f"into '{self._spelled(asn->lhs)}'",
                        )

                        self._assigning = false
                        self._st.clear(pl.d, pl.path)
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

                    var before = self._st
                    if bo->rhs != &null {
                        self.dispatch_expr(bo->rhs)
                    }

                    self._st = move_join(before, self._st)
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
                var        frame  = TryFrame()
                var        cxx    = false
                frame.block_depth = self._blocks.size()
                for var i: usize = 0; i < t->catch_arms.size(); ++i {
                    var unsafe *arm = t->catch_arms.get(i)
                    if arm->is_cxx {
                        cxx = true
                    } else if arm->filter == &null {
                        frame.catch_all = true
                    }

                    self._arm_of(&frame, arm->filter, arm->decl)
                }

                self._tries.push_back(frame)
                if t->try_expr != &null {
                    self.dispatch_expr(t->try_expr)
                }

                var met = self._tries[self._tries.size() - 1]
                self._tries.pop_back()
                var after_try = self._st
                var acc       = after_try
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
    /// the `else`, on the previous one's false state.
    priv fn _if_expr(self, n: unsafe *Expressions::IfExpr) {
        var r   = self._cond(n->condition)
        var acc = MoveState()
        acc.dead = true
        self._st = r.t
        if n->then_expr != &null {
            self.dispatch_expr(n->then_expr)
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
            }

            acc  = move_join(acc, self._st)
            rest = ar.f
        }

        self._st = rest
        if n->else_expr != &null {
            self.dispatch_expr(n->else_expr)
        }

        self._st = move_join(acc, self._st)
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
                self._blocks.push_back(
                    cxx::std::vector<unsafe *Statements::FinallyStmt>(),
                )

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

                self._blocks[self._blocks.size() - 1].push_back(
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
                var taken = self._st
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

                            self._for_bind.push_back(bd)
                            self._for_over.push_back(
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
                var        frame  = TryFrame()
                var        cxx    = false
                frame.block_depth = self._blocks.size()
                for var i: usize = 0; i < n->arms.size(); ++i {
                    var unsafe *arm = n->arms.get(i)
                    if arm->is_cxx {
                        cxx = true
                    } else if arm->filter == &null {
                        frame.catch_all = true
                    }

                    self._arm_of(&frame, arm->filter, arm->decl)
                }

                self._tries.push_back(frame)
                self.dyn()->traverse_block(n->try_body)
                var met = self._tries[self._tries.size() - 1]
                self._tries.pop_back()
                var after_try = self._st
                var acc       = after_try
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
    /// a path too -- when \p finite. With a condition, the body starts from
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
        var entry = self._st
        // The body CompoundStmt is dispatched next and lands at exactly this
        // index: cond and update are expressions, an IndexedForStmt init a
        // DeclStmt, and none opens a block.
        var frame = LoopFrame()
        frame.block_depth       = self._blocks.size()
        frame.has_label         = self._pending_has_label
        frame.label             = self._pending_label
        frame.done.dead         = true
        self._pending_has_label = false
        self._loops.push_back(frame)

        var exit1 = self._loop_pass(cond, body, update, rf)
        self._st = move_join(entry, exit1)
        var head  = self._st
        var exit2 = self._loop_pass(cond, body, update, rf)
        if finite && cond != &null {
            self._st = move_join(head, exit2)
            var last = self._cond(cond)
            var top  = self._loops.size() - 1
            self._loops[top].done = move_join(self._loops[top].done, last.f)
        }

        var fr = self._loops[self._loops.size() - 1]
        self._loops.pop_back()

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
                self._fin_depth += 1
                self.dispatch_stmt(fin->body)
                self._fin_depth -= 1
            }
        }
    }

    /// The state catch arm \p arm of a `try` starts from. A panic reaches
    /// the arms only from the points \p met recorded (_leave_by_panic):
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
        var entry = before
        if has_cxx || met.panics.empty() {
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

    /// A jump out of every block from the innermost down to index \p to:
    /// their pending bodies run, innermost block first.
    priv fn _run_finallys_to(self, to: usize) {
        self._run_finallys_between(self._blocks.size(), to)
    }

    /// The blocks below index \p from down to index \p to are left:
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
        // Only this call is the condition, not one inside its operands.
        var split = self._split_req
        self._split_req = false
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
            var unsafe *t = canon_unqual(
                self._tu.strip_nullable(n->callee->type_),
            )

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

        var bound_p       = cxx::std::vector<unsafe *ParamDecl>()
        var bound_e       = cxx::std::vector<unsafe *Expr>()
        var pos:    usize = 0
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

            self._pass(e, p, mode)
            if p != &null {
                bound_p.push_back(p)
                bound_e.push_back(e)
            }
        }

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
            self._split      = cm
            self._split_done = true
        } else {
            if n == self._link_call && !self._st.dead {
                self._link_from(n, cm)
            }

            self._apply(cm, MOVE_ON_RETURN)
        }

        // `-> !`, `__builtin_trap()`, an imported `[[noreturn]]`: nothing
        // after the call runs, so whatever it moved is never read.
        if n->type_ != &null && self._tu.is_never(n->type_) {
            self._st.dead = true
        }
    }

    /// Walks the condition \p e and returns the state on each of its
    /// outcomes. A call that is the condition, or its operand under `!`,
    /// `&&`, `||`, a postfix `?` or a comparison with `null`, marks what
    /// its callee leaves moved-from only on the branch whose outcomes move
    /// it (MoveOut::when). Any other condition is one state for both.
    priv fn _cond(self, e: unsafe *Expr) -> CondStates {
        var unsafe *x = self._tu.strip_parens(e)
        var        r  = CondStates{}
        if x == &null {
            r.t = self._st
            r.f = self._st
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
        r.t = self._st
        r.f = self._st
        return r
    }

    /// The index of \p e's link (CondLink) when \p e names a local that
    /// holds one of the kind \p nul; usize(-1) otherwise.
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

    /// The local \p n, holding link \p li, is tested: what its call marked
    /// is taken back and marked again on each branch by the outcomes that
    /// reach it (\p on_t, \p on_f), as _split_call marks a call's. A part
    /// marked since by anything else keeps that mark on both. The link
    /// stays: the test changes neither the local nor the parts.
    priv fn _link_cond(self,
                       n:    unsafe *NamedIdentExpr,
                       li:   usize,
                       on_t: u8,
                       on_f: u8) -> CondStates {
        var link = self._st.links[li]
        self._read(n)
        var r    = CondStates{}
        var cm   = CallMarks{}
        var base = self._st
        for var k: usize = 0; k < link.parts.size(); ++k {
            var i = base.index_of(link.parts[k].d, link.parts[k].path)
            if i == usize::MAX || !same_range(base.moved[i].at, link.site) {
                continue
            }

            base.moved.erase(base.moved.cbegin() + (i as isize))
            cm.parts.push_back(link.parts[k])
            cm.when.push_back(link.when[k])
        }

        base.links.push_back(link)
        self._st = base
        self._apply(cm, on_t)
        r.t      = self._st
        self._st = base
        self._apply(cm, on_f)
        r.f      = self._st
        self._st = base
        r.split  = cm.parts.size() > 0
        return r
    }

    /// \p e, a call or a local holding a `T?` call's link (_null_tested),
    /// tested against null: \p on_t and \p on_f are the returns that make
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

    /// The call \p c is a condition: \p on_t and \p on_f are the returns
    /// that make it true and false.
    priv fn _split_call(self, c: unsafe *Expressions::CallExpr, on_t: u8, on_f: u8) -> CondStates {
        var r = CondStates{}
        self._split_req  = true
        self._split_done = false
        self.dispatch_expr(c)
        self._split_req = false
        if !self._split_done {
            r.t = self._st
            r.f = self._st
            return r
        }

        self._split_done = false
        var cm   = self._split
        var base = self._st
        self._apply(cm, on_t)
        r.t      = self._st
        self._st = base
        self._apply(cm, on_f)
        r.f      = self._st
        self._st = base
        r.split  = true
        return r
    }

    priv fn _is_null_literal(self, e: unsafe *Expr) -> bool {
        return e != &null && isa<NullLiteralExpr>(e) && !cast<NullLiteralExpr>(e)->is_ref
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
            if (rref) => ("into a " + LangAttrs::quoted(LangAttrs::param_move()) + " parameter")
            else => "into a by-value parameter",
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
        // instance dropped has none (`return a` with `a: [Mv]`).
        if v != &null && (!v->is_poisoned()) && (!moves_on_pass(self.sc, v->type_)) {
            if self._mutable_copy_place(v, "out of the function", true) {
                return
            }

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

        self._operator_panics(opd)
    }

    /// A user operator \p opd marked `panic` may leave the path by a panic.
    priv fn _operator_panics(self, opd: unsafe *Decl) {
        var unsafe *f = dyn_cast<FunctionDecl>(opd)
        if f != &null && f->is_panic() {
            self._panic_path(CallMarks{})
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
            return dyn_cast<FunctionDecl>(
                cast<NamedIdentExpr>(c)->resolved_decl,
            )
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
        )
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
            if copies && self._mutable_copy_place(e, how, false) {
                return
            }

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

        // A const place cannot be moved from, and a MOVE value cannot be
        // copied: a transfer that copies is refused here, not
        // left to clang. `self.r` in a `const self` method and `p.r` of a
        // `const p` are const by their root (place_has_const_root). A slot
        // that only borrows (\p copies false) takes no copy.
        if self._const_place(x) || self._const_root(e) || place_has_const_root(x) {
            if copies {
                self._no_copy(
                    e,
                    f"'{self._spelled(x)}' is const, so the transfer {how} cannot move it, and moving is the only transfer its type has",
                )
            }

            return
        }

        self.sc->move_sites.insert(e as usize as u64)
        self.n_moves += 1
        self._mark(e, how)
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
    /// copied), or, with \p returned, a returned local or by-value
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
        if cs.empty() {
            cs = ts
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

        var b = self.sc->diag->report(DiagID::SC302E, e->range.start, msg)
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

    /// \p x names a local variable or a by-value parameter of the function
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

        if isa<VariableDecl>(d) {
            var unsafe *v = cast<VariableDecl>(d)
            return v->storage == StorageClass::Var && self._fn->range.contains(v->range.start)
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

        var b = self.sc->diag->report(DiagID::SC182E, e->range.start, msg)
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

    /// The facts of the record \p t names (through a C++ reference) when it
    /// definitely cannot be copied; null otherwise, an Unknown included. A
    /// tuple's are its elements' (\p tf holds them).
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

    /// SC182E at \p e, whose value is copied and cannot be: \p why says why
    /// the copy is the transfer here. False when the type can be copied.
    priv fn _no_copy(self, e: unsafe *Expr, const why: string) -> bool {
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

    /// \p e is an element reached through a user or library `op []`
    /// (`v[i]` of a `[T]` or a class), parens aside. A builtin array's or a
    /// pointer's subscript is not one: `arr[0] = arr[1]` compiles
    /// as a move, and is not refused here, like every other such move.
    priv fn _is_element(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self._tu.strip_parens(e)
        return x != &null
            && isa<Expressions::SubscriptExpr>(x)
            && cast<Expressions::SubscriptExpr>(x)->resolved_op != &null
    }

    /// \p t is a C++ `T&`, as written or canonical.
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
    /// here. A non-const lvalue is yielded by address, a temporary
    /// by `T&&`: neither copies.
    fn traverse_yield_stmt(self, n: *Statements::YieldStmt) -> *Statements::YieldStmt {
        var out = RecursiveASTVisitor<MoveCheck>::traverse_yield_stmt(self, n)
        if n->value == &null || n->value->is_poisoned() || n->value->type_ == &null {
            return out
        }

        var unsafe *x = self._tu.strip_parens(n->value)
        if x == &null || x->value_category != Expr::ValueCategory::LValue {
            return out
        }

        if canon_has_const(x->type_) || self._const_place(x) || place_has_const_root(x) {
            self._no_copy(
                n->value,
                f"'{self._spelled(x)}' is const, and a generator yields a const value by copying it",
            )
        }

        return out
    }

    /// `for x in xs`: a plain binder is a copy of each element (IterLowering,
    /// Binders), so an element type that cannot be copied is refused at the
    /// binder rather than in clang. The element is a place for an
    /// array, a slice and a generator (`*it.current()`), and for a C++ range
    /// whose `*it` is an lvalue; a C++ `*it` that returns a value builds the
    /// binder in place. `*x` binds the address and copies nothing; a
    /// destructuring binder is not checked here.
    priv fn _for_binder_copies(self, n: unsafe *Statements::RangedForStmt) {
        if n->bindings.size() != 1 {
            return
        }

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

        var unsafe *bn = n->bindings.get(0)
        var unsafe *bd = bn->decl
        if bd == &null || bd->type_ == &null || bd->is_poisoned() {
            return
        }

        var unsafe *t = if (bd->type_->canonical != &null) => (bd->type_->canonical)
                        else => bd->type_
        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(t, unsafe &tf, unsafe &rd)
        if facts == &null {
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
        var how = f"bind '*{nm}' for the element's address instead"
        if n->iter_yield == Statements::IterYield::Value {
            how = f"its 'op in' yields values; declare it '-> yield *{ts}' and bind '*{nm}' for the element's address"
        }

        b.note(
            bn->range.start,
            f"the loop binder '{nm}' is a copy of each element; {how}",
        )

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
    /// built in the copy's place; an lvalue of a type that cannot be copied
    /// is refused here, not in clang.
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

        var sym  = self.sc->ctx->get_spelling(bo->op_token)
        var csym = sym + "="

        if self._no_copy(
            bo->lhs,
            f"'{sym}' is derived from 'op {csym}': it copies its left operand '{self._spelled(x)}', applies '{csym}' to the copy and yields it; write '{self._spelled(x)} {csym} ...' to change it in place",
        ) {
            bo->poison()
        }
    }

    /// A vector, set or map literal is built from a backing array, which the
    /// container's constructor COPIES out of (ListLiteralLowering), so its
    /// elements must be copyable. A literal of move-only elements cannot be
    /// built yet (how move-only literals lower is the library's
    /// design): refused here, naming the element type, not in clang.
    fn visit_list_literal_expr(self, n: *Expressions::ListLiteralExpr) -> bool {
        if n->elements.size() > 0 && n->type_ != &null && self._tu.is_vector_like(n->type_) {
            self._literal_elems(
                unsafe (n as unsafe *Expr),
                self._tu.container_elem(n->type_),
                "vector",
            )
        }

        return true
    }

    fn visit_set_literal_expr(self, n: *Expressions::SetLiteralExpr) -> bool {
        if n->elements.size() > 0 && n->type_ != &null && self._tu.is_set_like(n->type_) {
            self._literal_elems(
                unsafe (n as unsafe *Expr),
                self._tu.container_elem(n->type_),
                "set",
            )
        }

        return true
    }

    fn visit_map_literal_expr(self, n: *Expressions::MapLiteralExpr) -> bool {
        if n->entries.size() == 0 || n->type_ == &null {
            return true
        }

        var kt: unsafe *Type = &null
        var vt: unsafe *Type = &null
        if !self._tu.map_key_value(n->type_, unsafe &kt, unsafe &vt) {
            return true
        }

        if !self._literal_elems(unsafe (n as unsafe *Expr), kt, "map") {
            self._literal_elems(unsafe (n as unsafe *Expr), vt, "map")
        }

        return true
    }

    priv fn _literal_elems(self, e: unsafe *Expr, elem: unsafe *Type, const what: string) -> bool {
        if elem == &null || e->is_poisoned() {
            return false
        }

        var tf               = LifecycleFacts()
        var rd: unsafe *Decl = &null
        var unsafe *facts = self._uncopyable_facts(elem, unsafe &tf, unsafe &rd)
        if facts == &null {
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

        var pl = self._place(e)
        if pl.d == &null || !pl.whole || pl.elem {
            return
        }

        // Only storage this body owns: not a part of a const binding, of
        // `self` or of a pointee, and not a parameter that refers to the
        // caller's object.
        if pl.has_ptr || self._const_root(e) {
            return
        }

        var unsafe *d = pl.d
        if isa<ParamDecl>(d) {
            var unsafe *pd = cast<ParamDecl>(d)
            if pd->is_self || pd->mode != ParamMode::Value && pd->mode != ParamMode::Move {
                return
            }
        }

        var pm = PendingMove()
        pm.d    = d
        pm.path = pl.path
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

    /// \p e, or the binding it is a part of (`x`, `x.f`, `x[i]`, through
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

    /// The storage \p e names becomes moved-from: a binding, a part of one
    /// (`p.a.b`, `self.r`), what a pointer in one points at (`p->r`, `*p`),
    /// or, for an element (`v[i]`, `h.items[0].s`), the container it is in.
    /// A temporary or a call's result records nothing.
    priv fn _mark(self, e: unsafe *Expr, const how: string) {
        var pl = self._place(e)
        if pl.d == &null || !pl.whole {
            return
        }

        var mp = MovedPart()
        mp.d     = pl.d
        mp.path  = pl.path
        mp.shown = pl.shown
        mp.segs  = pl.segs
        mp.at    = e->range
        mp.how   = how
        if pl.elem {
            mp.elem = self._spelled(e)
        }

        self._st.mark(mp)
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

    /// The place \p e names (MovePlace); its `d` is null when \p e is not
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

    /// The source text of \p e, for a note.
    priv fn _spelled(self, e: unsafe *Expr) -> string {
        return self.sc->ctx->get_spelling(e->range)
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

    /// # reads

    priv fn _read(self, n: unsafe *NamedIdentExpr) {
        var unsafe *d = n->resolved_decl
        if d == &null {
            return
        }

        self._read_part(n, d, "", "")
    }

    /// A read of \p path under \p d, through the name \p n; \p shown is the
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

        // Keyed on the BINDING alone (MoveState::reported): the first read
        // after the move is the error; later reads stay quiet until a
        // reassignment clears it.
        if self._st.was_reported(d) {
            return
        }

        self._st.reported.push_back(d)

        var mp   = self._st.moved[i]
        var gone = mp.shown
        var read = if (shown.size() == 0) => (self.sc->ctx->get_spelling(n->name)) else => shown
        var part  = !path_within(path, mp.path)
        var taken = gone
        var msg   = f"'{gone}' is used after being moved"
        if mp.elem.size() > 0 {
            // An element: the container is what is moved-from.
            taken = mp.elem
            msg   = f"'{gone}' is used after '{taken}' was moved out of it"
            if part {
                msg = f"'{read}' is used after '{taken}' was moved out of its part '{gone}'"
            }
        } else if part {
            msg = f"'{read}' is used after its part '{gone}' was moved"
        }

        var b = self.sc->diag->report(DiagID::SC052E, n->range.start, msg)
        b.first(n->range)
        b.note(mp.at.start, f"'{taken}' was moved here, {mp.how}")->child_first(
            mp.at,
        )

        if mp.has_via {
            b.note(
                mp.via.start,
                if (mp.via_text.size() > 0) => (mp.via_text)
                else => "it is moved here, and not assigned again before the body returns",
            )->child_first(mp.via)
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
