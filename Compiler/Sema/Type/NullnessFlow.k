/// --- The Kairo Project --------------------- Sema/Type/NullnessFlow.k --- ///
///
///   \brief The nullness analysis (Compiler/Spec/Nullables.md#nullness-analysis, §4, §5):
///          what each nullable place holds at each point of a body, and
///          the one classifier every spelling of the null test goes through.
///
///   \detail
///     `x?` is the null test; every other spelling desugars to it (2.1, 2.2):
///
///       x?            present     x != null     present     null != x   present
///       !x?           absent      x == null     absent      null == x   absent
///
///     looking through parentheses, and through `!` / `not` at any depth
///     (each flips the polarity: `!(x == null)` is `x?`). `null_test_of`
///     is the ONLY place that knows these spellings. NullTestLowering lowers
///     through it and the analysis below narrows through it, so a spelling
///     cannot lower one way and narrow another. A new spelling (the `x?`
///     inside a desugared `??` / `?.` / `unwrap!()`) is added here and
///     nowhere else.
///
///     It classifies TYPED trees. A test is one only when its operand's
///     type is nullable: a user `op ?` on a record (resolved_op set) is that
///     record's operator, not a null test, and `p == &null` on an `unsafe
///     *T` is a pointer comparison.
///
///     THE ANALYSIS runs during typing (§5): the type of a use depends on it.
///     ExprTyper and its mixins own none of it; they REPORT what they walk
///     and ASK at each use:
///
///       enter() / leave()      a function or closure body (TyperFrame);
///                              a function starts from nothing known, a
///                              closure from its by-copy captures
///       define / assign        a definition or `=` and its right side SET
///                              the state from the value (§3.2)
///       cond_of / store_cond   a condition's true and false sets (§3.3);
///                              `&&` / `||` store theirs while typed
///       join / diverge         control-flow merges, and `return` /
///                              `break` / `continue` / `panic` / a `-> !`
///                              call (the env becomes unreachable, which a
///                              join ignores: that is the early exit)
///       loop_enter/leave,      loops (see below), and `break`'s state;
///         on_break, label_next a label names the loop it precedes
///       after_call             any call: globals, statics and escaped
///                              places are Maybe again
///       weaken, inout_arg,     a write the analysis cannot see the value
///         mutable_self_call    of (3.4)
///       note_read / read_value a use names a nullable place / the consumer
///                              needs its VALUE (§4)
///
///     A PLACE is a local, a parameter or a global, plus a path of fields
///     read with `.` (`o.cache.v`); a vector of decls, root first. Its state
///     is NonNull, Null or Maybe; a place with no fact is Maybe. An
///     assignment to a place drops the facts of every path under it.
///
///     A read is NARROWED lazily, by the consumer that needs the value. The
///     use itself (`_type_ident`, a chain ending on a nullable field) only
///     records the state its place had at that point (note_read); a
///     consumer that reads the value (an operator, `.` / `->`, `*`, a
///     conversion to `T`, a call taking `T`) calls read_value: a NonNull
///     place is then typed `T` and marked (NamedIdentExpr::narrowed_from,
///     ChainExpr::Step::narrowed_from) for NarrowedAccessLowering; a Maybe
///     or Null one is the §4.2 error. Every other use (`x?`, `== null`,
///     `= null`, passing to a `T?`) never asks, so it keeps `T?`. The state
///     is the one recorded at the use, so a consumer typed after a later
///     assignment (`f(x, x = null)`) still reads the state x had where it
///     was written, and the memo (one type per node) is never contradicted.
///
///     WEAKENING (3.4): a write the analysis cannot see the value of makes
///     a place Maybe, noted with what did it: an `@inout` argument
///     (inout_arg), a call taking the place's owner as a mutable `self`
///     (mutable_self_call / operator_call: every path under the receiver,
///     not the receiver itself), and a pointer. A `&x` is followed from
///     where it is typed (address_taken): until a consumer accounts for it
///     (the `@inout` marker; a `*const` parameter) it may be anywhere, so
///     every later call (after_call) and every write the analysis cannot
///     place (`*p = v`, `p->f = v`: write_through) weakens `x`. A `const`
///     pointer, a `const self` call and a by-value pass weaken nothing; a
///     move is MoveCheck's (its moved-from rule reports the later use).
///
///     LOOPS (3.5): the body is typed once, from the head, so the head's
///     state must hold on every back edge. loop_enter pre-scans the body
///     path by path (NullLoopScan): a place proven before the loop stays
///     proven unless some path may bring it back holding anything else.
///     The condition is typed at the head, so `while x?` proves `x` at the
///     top of the body whatever the body does; after a loop, its false set
///     joined with each `break` (a labeled one joins into its own loop).
///
///     ALIASES (3.7): a CARRIER is a local holding a pointer or a closure
///     that captures by non-const pointer; it carries the places a write
///     through it, or a call of it, may change (`var p = &x`, `var clear =
///     fn ()|*x| {..}`, a copy `var q = p`; closure_made records a closure's
///     set). A carrier's value, like a fresh `&x` or closure, has ESCAPED
///     until a consumer accounts for it (consumed): `*p`, `p->f`, `p()`
///     (call_value, which weakens what it carries), a copy into a local, a
///     `*const` parameter, the `@inout` marker. Any other use (an argument,
///     a field, a global, `return`, even `p?`) leaves it escaped, and then
///     every call weakens what it carries (after_call). A write that is no
///     place goes through _through: through a carrier it weakens what that
///     carries, through anything else every escaped place. A closure body
///     starts (_closure_entry) with its by-copy captures in the state they
///     had where it was made, less what the body assigns them (the copy
///     persists between calls); a by-pointer capture is the pointer there
///     (ExprTyper::_capture_view types `x` as `*T`, marking the name
///     capture_ptr), so `x` is no place and `*x` is the variable's: a
///     place rooted at its decl, which starts Maybe and is `global`
///     (_shared), since anything holding a pointer to the variable may
///     write it during any call.
///
///   Phase: TYPE (the analysis, driven by ExprTyper); the classifier is
///   also called by LOWER (NullTestLowering).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContextKind
import AST::Context::SymbolTable::OverloadCell
import AST::Kind::StmtKind::StmtKind
import AST::LangItems::LangAttrs
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinType,
    canon_has_const,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, FieldDecl, FnBodyKind, FunctionDecl, ParamDecl, StructDecl, VariableDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Statements
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
    NullableType,
    PointerType,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::{
    RecursiveASTVisitor,
    named_call_arg_value,
}
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Sema::Check::CaptureAnalysis::FreeVarScan
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

/// One classified null test. `operand` is the nullable tested, null when
/// the expression is no null test. `present` is the polarity: true when the
/// expression is true exactly when `operand` holds a value (`x?`,
/// `x != null`), false when it is true exactly when it is null (`!x?`,
/// `x == null`).
pub struct NullTest {
    var operand: unsafe *Expr = &null
    var present: bool         = true
}

/// \p e without the parentheses around it.
pub fn null_flow_strip_parens(e: unsafe *Expr) -> unsafe *Expr {
    var unsafe *x = e
    while x != &null && isa<Expressions::ParenExpr>(x) {
        x = cast<Expressions::ParenExpr>(x)->inner
    }

    return x
}

/// \p e is the `null` (or `&null`) literal, through parentheses: that
/// literal, else null. Untyped on purpose: OperatorTyping asks before it
/// types the operands, so a `null` against a non-nullable gets the null
/// comparison's error, not the literal's "cannot infer".
pub fn null_literal_of(e: unsafe *Expr) -> unsafe *NullLiteralExpr {
    var unsafe *x = null_flow_strip_parens(e)
    if x == &null || !isa<NullLiteralExpr>(x) {
        return &null
    }

    return cast<NullLiteralExpr>(x)
}

/// \p t read as a value: a C++ `T&` / `T&&` is its `T`, cv kept.
pub fn null_flow_referee(t: unsafe *Type) -> unsafe *Type {
    if t == &null {
        return &null
    }

    if isa<CXXLValueRefType>(t) {
        return cast<CXXLValueRefType>(t)->referee
    }

    if isa<CXXRValueRefType>(t) {
        return cast<CXXRValueRefType>(t)->referee
    }

    return t
}

/// \p t is a nullable, read as a value (a C++ `T?&` is its `T?`).
pub fn null_flow_type_is_nullable(t: unsafe *Type) -> bool {
    if t == &null {
        return false
    }

    var unsafe *c = canon_unqual(null_flow_referee(t))
    return c != &null && isa<NullableType>(c)
}

/// \p e has a nullable type, read as a value (a C++ `T?&` is its `T?`).
pub fn null_flow_is_nullable(e: unsafe *Expr) -> bool {
    if e == &null {
        return false
    }

    return null_flow_type_is_nullable(e->type_)
}

/// The canonical of \p t through one nullable: `(*T)?` is `*T`, `T` is `T`.
/// What a pointer or scalar test asks of a value that may be nullable.
pub fn null_flow_through_nullable(t: unsafe *Type) -> unsafe *Type {
    var unsafe *c = canon_unqual(t)
    if c != &null && isa<NullableType>(c) {
        c = canon_unqual(cast<NullableType>(c)->inner)
    }

    return c
}

/// The null test \p e is, or one with no operand. See the file header for
/// the spellings.
pub fn null_test_of(e: unsafe *Expr) -> NullTest {
    var        out = NullTest{}
    var unsafe *x  = null_flow_strip_parens(e)
    if x == &null {
        return out
    }

    if isa<Expressions::UnaryOperatorExpr>(x) {
        var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
        if u->resolved_op != &null { // a user operator, never the test.
            return out
        }

        var k = u->op_token.kind
        if u->is_postfix() && k == TokenKind::OpQuestion {
            if !null_flow_is_nullable(u->operand) {
                return out
            }

            out.operand = u->operand
            out.present = true
            return out
        }

        if u->is_prefix() && (k == TokenKind::OpExclaim || k == TokenKind::KwNot) {
            var inner = null_test_of(u->operand)
            if inner.operand != &null {
                inner.present = !inner.present
            }

            return inner
        }

        return out
    }

    if isa<Expressions::BinaryOperatorExpr>(x) {
        var unsafe *b = cast<Expressions::BinaryOperatorExpr>(x)
        if b->resolved_op != &null {
            return out
        }

        var k = b->op_token.kind
        if k != TokenKind::OpEqualEqual && k != TokenKind::OpExclaimEqual {
            return out
        }

        var unsafe *ln = null_literal_of(b->lhs)
        var unsafe *rn = null_literal_of(b->rhs)
        if ln != &null == (rn != &null) { // neither, or `null == null`.
            return out
        }

        var unsafe *other = if (ln != &null) => (b->rhs) else => b->lhs
        if !null_flow_is_nullable(other) { // `p == &null` on a raw pointer.
            return out
        }

        out.operand = other
        out.present = k == TokenKind::OpExclaimEqual
        return out
    }

    return out
}

/// # The analysis

/// What a place is proven to hold (Compiler/Spec/Nullables.md#places-and-states). A place with no fact is
/// Maybe: sound, not complete.
pub enum Nullness derives u8 {
    Maybe = 0,
    NonNull,
    Null,
}

/// Why a place has its state, for the note on an access error.
pub enum NullWhy derives u8 {
    None = 0,
    Assigned, ///< a definition or `=` gave it this value (`at`).
    Tested,   ///< the null test at `at` decided it on this path.
    Called,   ///< a global, after the call at `at`.
    Looped,   ///< assigned at `at` inside the loop whose head this is.
    Inout,    ///< passed `@inout` at `at`: the callee may have written it.
    MutSelf,  ///< a path under the receiver of the mutable-self call at `at`.
    Escaped,  ///< a pointer to it, taken at `at`, is out of the analysis's sight.
    Through,  ///< written through a pointer to it at `at`.
    Aliased,  ///< the call at `at` runs a closure that holds a pointer to it.
    Caught,   ///< changed at `at` in a `try` that may have thrown after it.
}

/// A pointer to \p place, taken by the `&` at \p node (at \p at), that no
/// consumer has accounted for yet: until one does (an `@inout` marker, a
/// `*const` parameter), any call may write through it, and so may any
/// write the analysis cannot place (`*p = ...`).
pub struct NullEscape {
    var node:  unsafe *Expr                   = &null
    var place: cxx::std::vector<unsafe *Decl>
    var at:    SourceRange
}

/// One fact: \p place holds \p state here.
pub struct NullFact {
    var place:  cxx::std::vector<unsafe *Decl>
    var state:  Nullness                       = Nullness::Maybe
    var why:    NullWhy                        = NullWhy::None
    var at:     SourceRange
    var global: bool                           = false
}

/// The state at one program point. `dead` is the state after a divergence:
/// unreachable, so a join ignores it, and a read there is allowed.
pub struct NullEnv {
    var facts: cxx::std::vector<NullFact>
    var dead:  bool                       = false
}

/// A condition's two sets (3.3): what holds when it is true, when false.
pub struct NullCond {
    var t: NullEnv
    var f: NullEnv
}

/// An access error held back while the right side of a §4.1 trap is
/// typed: whether it gets the parenthesizing fix-it depends on every
/// error the right side has.
pub struct NullHeld {
    var e:       unsafe *Expr = &null
    var range:   SourceRange
    var fact:    NullFact
    var on_trap: bool         = false ///< it reads the place the trap's `&&` tested.
}

/// `a? && y || z` being typed: z is analysed under the false set of
/// `a? && y`, where `a` is Maybe. Parenthesizing `y || z` puts z on the
/// checked path (4.1).
pub struct NullTrap {
    var place:    cxx::std::vector<unsafe *Decl>
    var open_at:  SourceLocation                 ///< the start of y.
    var close_at: SourceLocation                 ///< the end of z.
    var held:     cxx::std::vector<NullHeld>
}

/// A note's location (invalid: none) and text.
pub struct NullNote {
    var at:  SourceLocation
    var msg: string         = ""
}

/// A local holding a pointer or a pointer-capturing closure (3.7): the
/// places a write through it, or a call of it, may change. `var p = &x`
/// carries `{x}`; `var clear = fn ()|*x| { ... }` carries `{x}`; a copy
/// carries what its source does. A `*const` one carries nothing.
pub struct NullCarrier {
    var decl:   unsafe *Decl                                     = &null
    var places: cxx::std::vector<cxx::std::vector<unsafe *Decl>>
}

/// Where a write through a pointer lands: \p known, the places a
/// carrier carries (none: storage no place is under); else anywhere a
/// pointer escaped to.
pub struct NullThrough {
    var known:  bool                                             = false
    var places: cxx::std::vector<cxx::std::vector<unsafe *Decl>>
}

pub struct NullFrame {
    var env:        NullEnv
    var closure:    unsafe *Expressions::ClosureExpr = &null ///< the body is this closure's.
    var loops_base: usize                            = 0
    var traps_base: usize                            = 0
    var escapes:    cxx::std::vector<NullEscape> ///< the enclosing body's, kept for leave().
    var carriers:   cxx::std::vector<NullCarrier> ///< likewise.
}

pub struct NullLoop {
    var breaks: cxx::std::vector<NullEnv>
    var label:  string                    = "" ///< the loop's label, or empty.
}

/// \p a and \p b name the same place.
pub fn null_place_eq(a: unsafe *cxx::std::vector<unsafe *Decl>,
                     b: unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
    if a->size() != b->size() {
        return false
    }

    for var i: usize = 0; i < a->size(); ++i {
        if (*a)[i] != (*b)[i] {
            return false
        }
    }

    return true
}

/// \p p is \p root or a path under it.
pub fn null_place_under(const p:    cxx::std::vector<unsafe *Decl>,
                        const root: cxx::std::vector<unsafe *Decl>) -> bool {
    if p.size() < root.size() {
        return false
    }

    for var i: usize = 0; i < root.size(); ++i {
        if (p)[i] != (root)[i] {
            return false
        }
    }

    return true
}

/// The join at a merge: the weaker state (3.1).
pub fn null_join_state(a: Nullness, b: Nullness) -> Nullness {
    if a == b {
        return a
    }

    return Nullness::Maybe
}

/// The index of \p place's fact in \p env, or -1.
pub fn null_env_find(env: unsafe *NullEnv, place: unsafe *cxx::std::vector<unsafe *Decl>) -> i64 {
    for var i: usize = 0; i < env->facts.size(); ++i {
        if null_place_eq(unsafe &env->facts[i].place, place) {
            return i as i64
        }
    }

    return -1
}

/// \p env with \p f as \p f.place's fact, the old one replaced. Paths under
/// it keep theirs: a test does not change them.
pub fn null_env_put(env: unsafe *NullEnv, f: NullFact) {
    var i = null_env_find(env, unsafe &f.place)
    if i >= 0 {
        env->facts[i as usize] = f
        return
    }

    env->facts.push_back(f)
}

/// Drop the fact of \p place and of every path under it: what an
/// assignment to \p place does to them before it sets its own.
pub fn null_env_kill_under(env: unsafe *NullEnv, place: unsafe *cxx::std::vector<unsafe *Decl>) {
    var keep = cxx::std::vector<NullFact>()
    for var i: usize = 0; i < env->facts.size(); ++i {
        if !null_place_under(env->facts[i].place, *place) {
            keep.push_back(env->facts[i])
        }
    }

    env->facts = keep
}

/// The facts of \p place and every path under it (only the paths strictly
/// under it when \p strict) become Maybe, noted \p why at \p at: what a
/// write the analysis cannot see the value of does (3.4). The facts are
/// kept, Maybe, so the access error can say what ended the check.
pub fn null_env_weaken_under(env:    *NullEnv,
                             place:  unsafe *cxx::std::vector<unsafe *Decl>,
                             strict: bool,
                             why:    NullWhy,
                             at:     SourceRange) {
    for var i: usize = 0; i < env->facts.size(); ++i {
        var *f = &env->facts[i]
        if !null_place_under(f->place, *place) {
            continue
        }

        if strict && f->place.size() == place->size() {
            continue
        }

        f->state = Nullness::Maybe
        f->why   = why
        f->at    = at
    }
}

/// The env at a merge of \p a and \p b. A dead side contributes nothing. A
/// place proven on one side only is Maybe after; a Maybe keeps its note.
pub fn null_env_join(a: unsafe *NullEnv, b: unsafe *NullEnv) -> NullEnv {
    if a->dead {
        return *b
    }

    if b->dead {
        return *a
    }

    var out = NullEnv{}
    for var i: usize = 0; i < a->facts.size(); ++i {
        var fa = a->facts[i]
        var j  = null_env_find(b, unsafe &fa.place)
        if j < 0 {
            if fa.state == Nullness::Maybe {
                out.facts.push_back(fa)
            }

            continue
        }

        var fb = b->facts[j as usize]
        var st = null_join_state(fa.state, fb.state)
        if st == fa.state {
            out.facts.push_back(fa)
            continue
        }

        // NonNull against Null, or one side Maybe: Maybe, noted by whichever
        // side says why.
        if fb.state == Nullness::Maybe {
            out.facts.push_back(fb)
            continue
        }

        var m = fa
        m.state = Nullness::Maybe
        m.why   = NullWhy::None
        out.facts.push_back(m)
    }

    for var i: usize = 0; i < b->facts.size(); ++i {
        var fb = b->facts[i]
        if fb.state != Nullness::Maybe {
            continue
        }

        if null_env_find(a, unsafe &fb.place) >= 0 {
            continue
        }

        out.facts.push_back(fb)
    }

    return out
}

/// \p d is a global or a static: a VariableDecl outside every function
/// body, or one declared `static` in one. Any call may write it (3.8).
pub fn null_flow_is_global(d: unsafe *Decl) -> bool {
    if d == &null {
        return false
    }

    if isa<ParamDecl>(d) {
        return false
    }

    if !isa<VariableDecl>(d) {
        return true
    }

    // A `thread` binding is Static storage with is_thread, so it lands here
    // too: code on the same thread can write it during any call (§3.8).
    if cast<VariableDecl>(d)->is_static() {
        return true
    }

    // A local is never tabled, so it has no semantic context (ASTParse
    // indexes only scopes with symbol tables); a global sits in its file's
    // or module's.
    var unsafe *dc = d->semantic_dc
    if dc == &null {
        return false
    }

    var k = dc->dc_kind
    return k != DeclContextKind::Function
        && k != DeclContextKind::Lambda
        && k != DeclContextKind::Block
}

/// The decl at the root of the storage \p e names, through parentheses,
/// `.` / `->` chains and subscripts; null when \p e names none (a call, a
/// dereference). Used only for the conservative "this root may be written
/// somewhere" scans.
pub fn null_root_decl(e: unsafe *Expr) -> unsafe *Decl {
    var unsafe *x = null_flow_strip_parens(e)
    while x != &null {
        if isa<NamedIdentExpr>(x) {
            return cast<NamedIdentExpr>(x)->resolved_decl
        }

        if isa<ChainExpr>(x) {
            x = null_flow_strip_parens(cast<ChainExpr>(x)->base)
            continue
        }

        if isa<Expressions::SubscriptExpr>(x) {
            x = null_flow_strip_parens(
                cast<Expressions::SubscriptExpr>(x)->base,
            )

            continue
        }

        return &null
    }

    return &null
}

/// The place \p e names, or an empty one: a local, parameter or global
/// (VariableDecl / ParamDecl), or `*x` where `x` is a closure's pointer
/// capture of one (3.7: the dereference is the variable, so its place is
/// the variable's decl; the name `x` itself is the pointer, no place),
/// then any number of `.` steps naming instance fields. Syntactic over
/// bound steps; an unbound step (one the typer has not reached yet) ends
/// it, and so does a capture the typer has not marked yet (capture_ptr).
pub fn null_place_of(e: unsafe *Expr) -> cxx::std::vector<unsafe *Decl> {
    var        out = cxx::std::vector<unsafe *Decl>()
    var unsafe *x  = null_flow_strip_parens(e)
    if x == &null {
        return out
    }

    if isa<NamedIdentExpr>(x) {
        var unsafe *n = cast<NamedIdentExpr>(x)
        if n->capture_ptr {
            return out
        }

        var unsafe *d = n->resolved_decl
        if d != &null && (isa<VariableDecl>(d) || isa<ParamDecl>(d)) {
            out.push_back(d)
        }

        return out
    }

    if isa<Expressions::UnaryOperatorExpr>(x) {
        var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
        if !u->is_prefix() || u->op_token.kind != TokenKind::OpStar || u->resolved_op != &null {
            return out
        }

        var unsafe *o = null_flow_strip_parens(u->operand)
        if o == &null || !isa<NamedIdentExpr>(o) {
            return out
        }

        var unsafe *on = cast<NamedIdentExpr>(o)
        if !on->capture_ptr {
            return out
        }

        var unsafe *d = on->resolved_decl
        if d != &null && (isa<VariableDecl>(d) || isa<ParamDecl>(d)) {
            out.push_back(d)
        }

        return out
    }

    if !isa<ChainExpr>(x) {
        return out
    }

    var unsafe *c = cast<ChainExpr>(x)
    if c->steps.size() == 0 {
        return out
    }

    return null_chain_place(c, c->steps.size() - 1) // every step
}

/// The place `c.base` + steps 0..=\p upto names, or an empty one.
pub fn null_chain_place(c: unsafe *ChainExpr, upto: usize) -> cxx::std::vector<unsafe *Decl> {
    var out = cxx::std::vector<unsafe *Decl>()
    if c->base == &null || upto >= c->steps.size() {
        return out
    }

    var root = null_place_of(c->base)
    if root.size() == 0 {
        return out
    }

    for var i: usize = 0; i <= upto; ++i {
        var unsafe *st = c->steps.get(i)
        if st == &null
            || st->access_kind != ChainExpr::AccessKind::Dot
            || st->is_operator()
            || st->is_tuple_index() {
            return cxx::std::vector<unsafe *Decl>()
        }

        var unsafe *d = st->resolved_decl
        if d == &null || (!isa<FieldDecl>(d)) || cast<FieldDecl>(d)->is_static() {
            return cxx::std::vector<unsafe *Decl>()
        }

        root.push_back(d)
    }

    return root
}

/// \p into with every place of \p from it does not hold yet.
pub fn null_places_union(into: unsafe *cxx::std::vector<cxx::std::vector<unsafe *Decl>>,
                         from: unsafe *cxx::std::vector<cxx::std::vector<unsafe *Decl>>) {
    for var i: usize = 0; i < from->size(); ++i {
        var dup = false
        for var j: usize = 0; j < into->size(); ++j {
            if null_place_eq(unsafe &(*into)[j], unsafe &(*from)[i]) {
                dup = true
                break
            }
        }

        if !dup {
            into->push_back((*from)[i])
        }
    }
}

/// The carrier of \p d in \p list, or -1.
pub fn null_carrier_find(const list: cxx::std::vector<NullCarrier>, d: unsafe *Decl) -> i64 {
    if d == &null {
        return -1
    }

    for var i: usize = 0; i < list.size(); ++i {
        if (list)[i].decl == d {
            return i as i64
        }
    }

    return -1
}

/// \p d is a local or a parameter (not a global or static): a carrier can
/// only be one, since anything else is reachable from any call.
pub fn null_flow_is_local(d: unsafe *Decl) -> bool {
    if d == &null || (!isa<VariableDecl>(d)) && !isa<ParamDecl>(d) {
        return false
    }

    return !null_flow_is_global(d)
}

/// The places a closure \p c can write when it is called: what it captures
/// by non-const pointer (named, or every outer local it names under `|*|`)
/// and what each carrier it captures by copy carries (\p carriers).
pub fn null_closure_places(c:        unsafe *Expressions::ClosureExpr,
                           carriers: unsafe *cxx::std::vector<NullCarrier>) -> cxx::std::vector<cxx::std::vector<unsafe *Decl>> {
    var out = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
    if c == &null {
        return out
    }

    var all_ptr   = false
    var all_const = false
    var named     = false
    for var i: usize = 0; i < c->captures.size(); ++i {
        var unsafe *cap = c->captures.get(i)
        if cap->name == &null {
            if cap->by_ptr {
                all_ptr   = true
                all_const = cap->is_const
            }

            continue
        }

        named = true
        var unsafe *d = cap->name->resolved_decl
        if !null_flow_is_local(d) {
            continue
        }

        if cap->by_ptr {
            if cap->is_const {
                continue
            }

            var p = cxx::std::vector<unsafe *Decl>()
            p.push_back(d)
            var one = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
            one.push_back(p)
            null_places_union(unsafe &out, unsafe &one)
            continue
        }

        var k = null_carrier_find(*carriers, d)
        if k >= 0 {
            null_places_union(
                unsafe &out,
                unsafe &(*carriers)[k as usize].places,
            )
        }
    }

    // `|*|`, or no list at all (every name used is captured by copy): the
    // closure's free locals.
    if all_ptr || !named && !c->explicit_no_capture {
        var fv = FreeVarScan()
        if c->body_block != &null {
            fv.run(c->body_block)
        }

        if c->body_expr != &null {
            fv.dispatch_expr(c->body_expr)
        }

        for var i: usize = 0; i < fv.free.size(); ++i {
            var unsafe *d = fv.free[i]
            if !null_flow_is_local(d) {
                continue
            }

            if all_ptr {
                if all_const {
                    continue
                }

                var p = cxx::std::vector<unsafe *Decl>()
                p.push_back(d)
                var one = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
                one.push_back(p)
                null_places_union(unsafe &out, unsafe &one)
                continue
            }

            var k = null_carrier_find(*carriers, d)
            if k >= 0 {
                null_places_union(
                    unsafe &out,
                    unsafe &(*carriers)[k as usize].places,
                )
            }
        }
    }

    return out
}

/// # The loop pre-scan (3.5)

/// What the paths through a loop body may have done to one place, as bits:
/// left it alone, written a value proven non-null, or something else (a
/// `null`, a value that may be null, a write the analysis cannot see).
pub
const NULL_SCAN_KEPT: u8 = 1
pub
const NULL_SCAN_VALUE: u8 = 2
pub
const NULL_SCAN_LOST: u8 = 4

/// One path's effect on each candidate place, by index; `at` is where the
/// candidate was last lost on it. A dead path (it returned, broke out, or
/// went back to an outer loop) reaches no back edge.
pub struct NullScanState {
    var flags: cxx::std::vector<u8>
    var at:    cxx::std::vector<SourceRange>
    var dead:  bool                          = false
}

/// A loop the scan is inside: the scanned loop itself first, then each
/// nested one, with the paths that leave it by `break` and go back to its
/// head by `continue`.
pub struct NullScanLoop {
    var label:  string                          = ""
    var breaks: cxx::std::vector<NullScanState>
    var conts:  cxx::std::vector<NullScanState>
}

/// The merge of two paths: each place may have had what either did to it.
pub fn null_scan_join(a: *NullScanState, b: *NullScanState) -> NullScanState {
    if a->dead {
        return *b
    }

    if b->dead {
        return *a
    }

    var out = *a
    for var i: usize = 0; i < out.flags.size(); ++i {
        var lost_a = (a->flags[i] & NULL_SCAN_LOST) != 0
        out.flags[i] = a->flags[i] | b->flags[i]
        if !lost_a && (b->flags[i] & NULL_SCAN_LOST) != 0 {
            out.at[i] = b->at[i]
        }
    }

    return out
}

/// \p t is a builtin scalar (through a nullable): an operator on it is the
/// builtin one, whose result is never null.
pub fn null_scan_is_scalar(t: unsafe *Type) -> bool {
    if t == &null {
        return false
    }

    var unsafe *c = null_flow_through_nullable(t)
    return c != &null && isa<BuiltinType>(c)
}

/// The declared type of the decl \p d names, if it is known yet.
pub fn null_scan_decl_type(d: unsafe *Decl) -> unsafe *Type {
    if d == &null {
        return &null
    }

    if isa<VariableDecl>(d) {
        var unsafe *v = cast<VariableDecl>(d)
        return if (v->type_ != &null) => (v->type_->canonical) else => &null
    }

    if isa<ParamDecl>(d) {
        var unsafe *p = cast<ParamDecl>(d)
        return if (p->type_ != &null) => (p->type_->canonical) else => &null
    }

    if isa<FieldDecl>(d) {
        var unsafe *f = cast<FieldDecl>(d)
        return if (f->type_ != &null) => (f->type_->canonical) else => &null
    }

    return &null
}

/// \p f is known to return no nullable: a declared, non-dependent,
/// non-nullable return type (a block body with none returns nothing).
pub fn null_scan_returns_value(d: unsafe *Decl) -> bool {
    if d == &null || !isa<FunctionDecl>(d) {
        return false
    }

    var unsafe *f = cast<FunctionDecl>(d)
    if f->return_type == &null {
        return f->body_kind != FnBodyKind::Expr
    }

    var unsafe *t = f->return_type->canonical
    if t == &null || t->is_dependent() {
        return false
    }

    return !null_flow_type_is_nullable(t)
}

/// Every decl \p cell holds returns no nullable.
pub fn null_scan_cell_returns_value(cell: unsafe *OverloadCell) -> bool {
    if cell == &null || cell->size() == 0 {
        return false
    }

    for var i: usize = 0; i < cell->size(); ++i {
        if !null_scan_returns_value(cell->get(i)) {
            return false
        }
    }

    return true
}

/// \p d is a function with no `@inout` parameter.
pub fn null_scan_no_inout(d: unsafe *Decl) -> bool {
    if d == &null || !isa<FunctionDecl>(d) {
        return false
    }

    var unsafe *f = cast<FunctionDecl>(d)
    for var i: usize = 0; i < f->params.size(); ++i {
        if f->params[i] != &null && f->params[i]->mode == ParamMode::Inout {
            return false
        }
    }

    return true
}

pub fn null_scan_cell_no_inout(cell: unsafe *OverloadCell) -> bool {
    if cell == &null || cell->size() == 0 {
        return false
    }

    for var i: usize = 0; i < cell->size(); ++i {
        if !null_scan_no_inout(cell->get(i)) {
            return false
        }
    }

    return true
}

/// \p d is a method taking a `const self`.
pub fn null_scan_const_method(d: unsafe *Decl) -> bool {
    if d == &null || !isa<FunctionDecl>(d) {
        return false
    }

    var unsafe *f = cast<FunctionDecl>(d)
    if !f->is_method() {
        return false
    }

    return f->is_const() || f->params[0]->is_const
}

pub fn null_scan_cell_const(cell: unsafe *OverloadCell) -> bool {
    if cell == &null || cell->size() == 0 {
        return false
    }

    for var i: usize = 0; i < cell->size(); ++i {
        if !null_scan_const_method(cell->get(i)) {
            return false
        }
    }

    return true
}

/// \p e, an operand, is known to be a builtin scalar: a numeric, `bool` or
/// character literal, or a place declared as one (or as one's nullable).
pub fn null_scan_scalar_operand(e: unsafe *Expr) -> bool {
    var unsafe *x = null_flow_strip_parens(e)
    if x == &null {
        return false
    }

    if isa<IntegerLiteralExpr>(x)
        || isa<FloatingLiteralExpr>(x)
        || isa<BooleanLiteralExpr>(x)
        || isa<CharacterLiteralExpr>(x) {
        return true
    }

    var p = null_place_of(x)
    if p.size() == 0 {
        return false
    }

    return null_scan_is_scalar(null_scan_decl_type(p[p.size() - 1]))
}

/// Read before typing, \p rhs is known to be no null (Compiler/Spec/Nullables.md#definitions-and-conditions's
/// rows, on what the syntax and the declarations already say): a literal,
/// `&e`, an initializer, a call to a function declared to return a `T`, a
/// constructor, a place declared `T`, a builtin operator on scalars, a cast
/// to a `T`, an if-expression whose every arm is one. Anything else may be
/// null (false): sound, not complete.
pub fn null_scan_rhs_value(rhs: unsafe *Expr) -> bool {
    var unsafe *x = null_flow_strip_parens(rhs)
    if x == &null {
        return false
    }

    if isa<NullLiteralExpr>(x) {
        return false
    }

    if isa<IntegerLiteralExpr>(x)
        || isa<FloatingLiteralExpr>(x)
        || isa<BooleanLiteralExpr>(x)
        || isa<CharacterLiteralExpr>(x)
        || isa<StringLiteralExpr>(x) {
        return true
    }

    if isa<Expressions::NamedInitializerExpr>(x)
        || isa<Expressions::AnonInitializerExpr>(x)
        || isa<Expressions::ListLiteralExpr>(x)
        || isa<Expressions::TupleLiteralExpr>(x)
        || isa<Expressions::SetLiteralExpr>(x)
        || isa<Expressions::MapLiteralExpr>(x) {
        return true
    }

    if isa<Expressions::UnaryOperatorExpr>(x) {
        var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
        var        k  = u->op_token.kind
        if u->is_prefix() && k == TokenKind::OpAmp {
            return true
        }

        if u->is_prefix()
            && (k == TokenKind::OpMinus
                || k == TokenKind::OpExclaim
                || k == TokenKind::KwNot
                || k == TokenKind::OpTilde) {
            return null_scan_scalar_operand(u->operand)
        }

        if u->is_postfix() && k == TokenKind::OpQuestion { // the null test is a bool.
            return true
        }

        return false
    }

    if isa<Expressions::BinaryOperatorExpr>(x) {
        var unsafe *b = cast<Expressions::BinaryOperatorExpr>(x)
        var        k  = b->op_token.kind
        // `x ?? y` is non-null exactly when its fallback is (Compiler/Spec/Nullables.md#coalesce).
        if k == TokenKind::OpQuestionQuestion {
            return null_scan_rhs_value(b->rhs)
        }

        if null_literal_of(b->lhs) != &null || null_literal_of(b->rhs) != &null { // `x == null`: a bool.
            return true
        }

        return null_scan_scalar_operand(b->lhs) && null_scan_scalar_operand(b->rhs)
    }

    if isa<Expressions::UnwrapExpr>(x) { // `unwrap!(e)`: a value, or the program ended.
        return true
    }

    if isa<Expressions::TypeCastExpr>(x) {
        var unsafe *tc = cast<Expressions::TypeCastExpr>(x)
        if tc->target == &null || tc->target->canonical == &null {
            return false
        }

        return !null_flow_type_is_nullable(tc->target->canonical)
    }

    if isa<Expressions::IfExpr>(x) {
        var unsafe *ie = cast<Expressions::IfExpr>(x)
        if !null_scan_rhs_value(ie->then_expr) {
            return false
        }

        for var i: usize = 0; i < ie->else_ifs.size(); ++i {
            if !null_scan_rhs_value(ie->else_ifs.get(i)->body) {
                return false
            }
        }

        return null_scan_rhs_value(ie->else_expr)
    }

    if isa<Expressions::CallExpr>(x) {
        var unsafe *callee = null_flow_strip_parens(
            cast<Expressions::CallExpr>(x)->callee,
        )

        if callee == &null {
            return false
        }

        if isa<NamedIdentExpr>(callee) {
            var unsafe *id = cast<NamedIdentExpr>(callee)
            if id->resolved_decl != &null {
                var unsafe *d = id->resolved_decl
                if isa<FunctionDecl>(d) {
                    return null_scan_returns_value(d)
                }

                // A record's name called is its constructor.
                return isa<StructDecl>(d) || isa<ClassDecl>(d)
            }

            return null_scan_cell_returns_value(id->candidate_cell)
        }

        if isa<ChainExpr>(callee) {
            var unsafe *c = cast<ChainExpr>(callee)
            if c->steps.size() == 0 {
                return false
            }

            // `a?.get()` is null when `a` is, whatever `get` returns (2.5).
            if c->has_optional_chaining() {
                return false
            }

            var unsafe *st = c->steps.get(c->steps.size() - 1)
            if st->resolved_decl != &null {
                var unsafe *d = st->resolved_decl
                if isa<FunctionDecl>(d) {
                    return null_scan_returns_value(d)
                }

                return isa<StructDecl>(d) || isa<ClassDecl>(d)
            }

            return null_scan_cell_returns_value(st->candidate_cell)
        }

        return false
    }

    var p = null_place_of(x)
    if p.size() > 0 {
        var unsafe *t = null_scan_decl_type(p[p.size() - 1])
        return t != &null && !t->is_dependent() && !null_flow_type_is_nullable(t)
    }

    return false
}

/// \p e is a bare `&x`, the shape of the `@inout` marker: its operand.
pub fn mode_marker_like(e: unsafe *Expr) -> unsafe *Expr {
    if e == &null || !isa<Expressions::UnaryOperatorExpr>(e) {
        return &null
    }

    var unsafe *u = cast<Expressions::UnaryOperatorExpr>(e)
    if !u->is_prefix() || u->op_token.kind != TokenKind::OpAmp {
        return &null
    }

    return u->operand
}

/// The function \p d takes its argument \p i `@inout` (\p recv: called
/// through a receiver, so a method's `self` is no argument).
pub fn null_scan_inout_at(d: unsafe *Decl, i: usize, recv: bool) -> bool {
    if d == &null || !isa<FunctionDecl>(d) {
        return false
    }

    var unsafe *f = cast<FunctionDecl>(d)
    var        k  = i
    if recv && f->is_method() {
        k = k + 1
    }

    if k >= f->params.size() {
        return false
    }

    var unsafe *p = f->params[k]
    return p != &null && p->mode == ParamMode::Inout && !p->is_pack
}

/// The loop pre-scan (3.5): what one pass through a loop body may have
/// done to each place proven at its head (`cands`) by the time it gets
/// back there, path by path. The typer walks the body once, from the
/// head's state, so that state must already hold on every back edge: a
/// candidate the body may leave anything but what it found (or, for a
/// NonNull one, a value proven non-null) is Maybe at the head.
///
/// The scan runs before the body is typed, so it reads only the syntax
/// and what is already known (bound names, declared types), and errs
/// toward "lost". It must lose at least what the typer itself weakens
/// there: an assignment of anything not known non-null (null_scan_rhs_
/// value), `&e` (an `@inout` marker or a pointer kept), a place passed to
/// a call that may take it `@inout` unmarked, a method or user operator
/// on a place that may take it as mutable `self` (the paths under it),
/// and anything in an if-expression, a `&&` / `||` right side, a `catch`
/// or `finally`, where the order is not followed. Calls' effect on globals
/// and on escaped places is the caller's (it weakens those always). It
/// does not look into closures: their bodies do not run where they are
/// written, and a by-pointer capture is followed elsewhere.
pub class NullLoopScan derives RecursiveASTVisitor<NullLoopScan> {
    pub var sc:    unsafe *SemaContext                              = &null
    pub var cands: cxx::std::vector<cxx::std::vector<unsafe *Decl>>
    pub var st:    NullScanState
    pub var loops: cxx::std::vector<NullScanLoop>
    /// > 0: inside a part whose order is not followed; an effect adds to
    /// what a place may have instead of replacing it.
    pub var taint: u32 = 0
    /// The carriers live at the loop's head (3.7), and those the body makes.
    pub var carriers: cxx::std::vector<NullCarrier>
    /// Per candidate: a pointer to it may outlive this pass (an `&` not
    /// known to be the `@inout` marker, a by-pointer capture, a carrier
    /// passed on): on a later pass any call before that point may write
    /// it, so it is lost at the head whatever the paths say.
    pub var sticky:    cxx::std::vector<u8>
    pub var sticky_at: cxx::std::vector<SourceRange>
    /// collect: every effect also lands here, whatever path or order (a
    /// `catch` arm may start after any of them).
    pub var collect: bool          = false
    pub var all:     NullScanState
    /// A label waiting for the loop statement it labels.
    pub var pending: string = ""

    fn NullLoopScan(self) { }

    /// The back edge of the loop over \p body (with \p update run after
    /// it), labeled \p label: the join of the end of the body and every
    /// `continue` to it, then the update.
    priv fn _init(self) {
        self.st = NullScanState{}
        for var i: usize = 0; i < self.cands.size(); ++i {
            self.st.flags.push_back(NULL_SCAN_KEPT)
            self.st.at.push_back(SourceRange())
            self.sticky.push_back(0)
            self.sticky_at.push_back(SourceRange())
        }

        self.all = self.st
    }

    /// What a `catch` arm may start with after \p body (or \p value) ran
    /// any part of the way: every effect anywhere in it, unordered.
    fn run_unordered(self, body: unsafe *Stmt, value: unsafe *Expr) -> NullScanState {
        self._init()
        self.collect = true
        var l = NullScanLoop{}
        self.loops.push_back(l)
        if body != &null {
            self.scan_stmt(body)
        }

        self.scan_expr(value)
        self.loops.pop_back()
        for var i: usize = 0; i < self.cands.size(); ++i {
            if self.sticky[i] == 0 {
                continue
            }

            if (self.all.flags[i] & NULL_SCAN_LOST) == 0 {
                self.all.at[i] = self.sticky_at[i]
            }

            self.all.flags[i] = self.all.flags[i] | NULL_SCAN_LOST
        }

        return self.all
    }

    fn run(self, body: unsafe *Stmt, update: unsafe *Expr, const label: string) -> NullScanState {
        self._init()
        var l = NullScanLoop{}
        l.label = label
        self.loops.push_back(l)
        if body != &null {
            self.scan_stmt(body)
        }

        var back = self.st
        var top  = self.loops.back()
        for var i: usize = 0; i < top.conts.size(); ++i {
            back = null_scan_join(&back, &top.conts[i])
        }

        self.loops.pop_back()
        if update != &null {
            self.st = back
            self.scan_expr(update)
            back = self.st
        }

        if !back.dead {
            for var i: usize = 0; i < self.cands.size(); ++i {
                if self.sticky[i] == 0 {
                    continue
                }

                if (back.flags[i] & NULL_SCAN_LOST) == 0 {
                    back.at[i] = self.sticky_at[i]
                }

                back.flags[i] = back.flags[i] | NULL_SCAN_LOST
            }
        }

        return back
    }

    /// ## effects

    priv fn _set(self, i: usize, v: u8, at: SourceRange) {
        if self.collect {
            self.all.flags[i] = self.all.flags[i] | v
            if v == NULL_SCAN_LOST {
                self.all.at[i] = at
            }
        }

        if self.st.dead {
            return
        }

        if self.taint > 0 {
            self.st.flags[i] = self.st.flags[i] | v
        } else {
            self.st.flags[i] = v
        }

        if v == NULL_SCAN_LOST {
            self.st.at[i] = at
        }
    }

    /// `q = rhs`: \p q itself takes the value, every path under it is lost.
    priv fn _write(self, q: unsafe *cxx::std::vector<unsafe *Decl>, value: bool, at: SourceRange) {
        for var i: usize = 0; i < self.cands.size(); ++i {
            var *p = &self.cands[i]
            if !null_place_under(*p, *q) {
                continue
            }

            if p->size() == q->size() {
                self._set(
                    i,
                    if (value) => (NULL_SCAN_VALUE) else => NULL_SCAN_LOST,
                    at,
                )
            } else {
                self._set(i, NULL_SCAN_LOST, at)
            }
        }
    }

    /// \p q and every path under it (only those strictly under it, when
    /// \p strict) may hold anything.
    priv fn _lose(self, q: unsafe *cxx::std::vector<unsafe *Decl>, strict: bool, at: SourceRange) {
        if q->size() == 0 {
            return
        }

        for var i: usize = 0; i < self.cands.size(); ++i {
            var *p = &self.cands[i]
            if !null_place_under(*p, *q) {
                continue
            }

            if strict && p->size() == q->size() {
                continue
            }

            self._set(i, NULL_SCAN_LOST, at)
        }
    }

    /// Every place of \p set may hold anything, and stays so at the head.
    priv fn _lose_sticky(self,
                         @inout set: cxx::std::vector<cxx::std::vector<unsafe *Decl>>,
                         at:         SourceRange) {
        for var j: usize = 0; j < set.size(); ++j {
            var unsafe *q = unsafe &(set)[j]
            for var i: usize = 0; i < self.cands.size(); ++i {
                if null_place_under(self.cands[i], *q) && self.sticky[i] == 0 {
                    self.sticky[i]    = 1
                    self.sticky_at[i] = at
                }
            }

            self._lose(q, false, at)
        }
    }

    priv fn _lose_set(self,
                      @inout set: cxx::std::vector<cxx::std::vector<unsafe *Decl>>,
                      at:         SourceRange) {
        for var j: usize = 0; j < set.size(); ++j {
            self._lose(unsafe &(set)[j], false, at)
        }
    }

    /// The places \p d carries, if it is a carrier.
    priv fn _carried(self, d: unsafe *Decl) -> cxx::std::vector<cxx::std::vector<unsafe *Decl>> {
        var k = null_carrier_find(self.carriers, d)
        if k < 0 {
            return cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
        }

        return self.carriers[k as usize].places
    }

    /// Every place any carrier carries: what a call through a function
    /// value the scan cannot follow may write.
    priv fn _all_carried(self) -> cxx::std::vector<cxx::std::vector<unsafe *Decl>> {
        var out = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
        for var i: usize = 0; i < self.carriers.size(); ++i {
            null_places_union(unsafe &out, unsafe &self.carriers[i].places)
        }

        return out
    }

    /// The places the value \p e carries, read before typing: `&place`, a
    /// carrier's name, a closure.
    priv fn _carry_of(self, e: unsafe *Expr) -> cxx::std::vector<cxx::std::vector<unsafe *Decl>> {
        var        out = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
        var unsafe *x  = null_flow_strip_parens(e)
        if x == &null {
            return out
        }

        if isa<Expressions::UnaryOperatorExpr>(x) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
            if u->is_prefix() && u->op_token.kind == TokenKind::OpAmp {
                var q = null_place_of(u->operand)
                if q.size() > 0 {
                    out.push_back(q)
                    return out
                }

                return self._carried(null_root_decl(u->operand))
            }

            return out
        }

        if isa<NamedIdentExpr>(x) {
            return self._carried(cast<NamedIdentExpr>(x)->resolved_decl)
        }

        if isa<Expressions::ClosureExpr>(x) {
            return null_closure_places(
                cast<Expressions::ClosureExpr>(x),
                unsafe &self.carriers,
            )
        }

        if isa<Expressions::TypeCastExpr>(x) {
            return self._carry_of(cast<Expressions::TypeCastExpr>(x)->operand)
        }

        return out
    }

    /// \p d now (also) holds what \p value carries.
    priv fn _carry_into(self, d: unsafe *Decl, value: unsafe *Expr) {
        if !null_flow_is_local(d) {
            return
        }

        var set = self._carry_of(value)
        if set.size() == 0 {
            return
        }

        var k = null_carrier_find(self.carriers, d)
        if k < 0 {
            var c = NullCarrier{}
            c.decl = d
            self.carriers.push_back(c)
            k = ((self.carriers.size() - 1) as i64)
        }

        null_places_union(unsafe &self.carriers[k as usize].places, unsafe &set)
    }

    /// \p e is a receiver a call may take as mutable `self`.
    priv fn _lose_inside(self, e: unsafe *Expr, at: SourceRange) {
        var q = null_place_of(e)
        self._lose(unsafe &q, true, at)
    }

    /// ## expressions

    fn scan_expr(self, e: unsafe *Expr) {
        if e != &null {
            self.dispatch_expr(e)
        }
    }

    priv fn _tainted(self, e: unsafe *Expr) {
        self.taint = self.taint + 1
        self.scan_expr(e)
        self.taint = self.taint - 1
    }

    /// Not entered: the body runs where the closure is called. What it can
    /// write through a by-pointer capture is followed at those calls (the
    /// closure's carrier); since the value may be kept past this pass, its
    /// pointer captures are lost at the head.
    fn visit_closure_expr(self, n: unsafe *Expressions::ClosureExpr) -> bool {
        if n == &null {
            return false
        }

        var empty = cxx::std::vector<NullCarrier>()
        var ptrs  = null_closure_places(n, unsafe &empty)
        self._lose_sticky(&ptrs, n->range)
        return false
    }

    fn visit_assign_operator_expr(self, n: unsafe *Expressions::AssignOperatorExpr) -> bool {
        if n == &null {
            return false
        }

        var k = n->op_token.kind
        if k == TokenKind::OpColon {
            self.scan_expr(n->rhs)
            return false
        } // `f(x: v)`: a named argument.

        self.scan_expr(n->rhs)
        self.scan_expr(n->lhs)
        var q = null_place_of(n->lhs)
        if k != TokenKind::OpEqual {
            // In place: a narrowed place stays what it is; a record's `op +=`
            // may be a mutable `self`; `*p += 1` writes what `p` carries.
            if q.size() > 0 {
                self._lose(unsafe &q, true, n->range)
            } else {
                var cs = self._carried(null_root_decl(n->lhs))
                self._lose_set(&cs, n->range)
            }

            return false
        }

        if q.size() == 0 {
            // A step not bound yet: the whole root may be the target; and a
            // write through a carrier (`*p = v`) lands in what it carries.
            var unsafe *d = null_root_decl(n->lhs)
            if d != &null && (isa<VariableDecl>(d) || isa<ParamDecl>(d)) {
                var r = cxx::std::vector<unsafe *Decl>()
                r.push_back(d)
                self._lose(unsafe &r, false, n->range)
                var cs = self._carried(d)
                self._lose_set(&cs, n->range)
            }

            return false
        }

        self._write(unsafe &q, null_scan_rhs_value(n->rhs), n->range)
        if q.size() == 1 {
            self._carry_into(q[0], n->rhs)
        }

        return false
    }

    fn visit_unary_operator_expr(self, n: unsafe *Expressions::UnaryOperatorExpr) -> bool {
        if n == &null {
            return false
        }

        var k = n->op_token.kind
        if n->is_prefix() && k == TokenKind::OpAmp {
            // A pointer that may be kept: lost for good, unless it is an
            // `@inout` marker (visit_call_expr skips those).
            var q = null_place_of(n->operand)
            if q.size() > 0 {
                var one = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
                one.push_back(q)
                self._lose_sticky(&one, n->range)
            }
        } else if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
            var q = null_place_of(n->operand)
            self._lose(unsafe &q, true, n->range)
            if q.size() == 0 {
                var cs = self._carried(null_root_decl(n->operand))
                self._lose_set(&cs, n->range)
            }
        }

        return true
    }

    fn visit_binary_operator_expr(self, n: unsafe *Expressions::BinaryOperatorExpr) -> bool {
        if n == &null {
            return false
        }

        var k = n->op_token.kind
        self.scan_expr(n->lhs)
        if k == TokenKind::OpAmpAmp
            || k == TokenKind::KwAnd
            || k == TokenKind::OpPipePipe
            || k == TokenKind::KwOr
            || k == TokenKind::OpQuestionQuestion {
            self._tainted(n->rhs) // runs on one outcome only.
            return false
        }

        self.scan_expr(n->rhs)
        // A record's operator may take its left side as a mutable `self`.
        if null_literal_of(n->lhs) == &null && null_literal_of(n->rhs) == &null {
            var q = null_place_of(n->lhs)
            if q.size() > 0 && !null_scan_is_scalar(null_scan_decl_type(q[q.size() - 1])) {
                self._lose(unsafe &q, true, n->range)
            }
        }

        return false
    }

    fn visit_if_expr(self, n: unsafe *Expressions::IfExpr) -> bool {
        if n == &null {
            return false
        }

        self.scan_expr(n->condition)
        self.taint = self.taint + 1
        self.scan_expr(n->then_expr)
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            self.scan_expr(n->else_ifs.get(i)->condition)
            self.scan_expr(n->else_ifs.get(i)->body)
        }

        self.scan_expr(n->else_expr)
        self.taint = self.taint - 1
        return false
    }

    fn visit_match_expr(self, n: unsafe *Expressions::MatchExpr) -> bool {
        if n == &null {
            return false
        }

        self.scan_expr(n->scrutinee)
        self.taint = self.taint + 1
        for var i: usize = 0; i < n->cases.size(); ++i {
            var unsafe *mc = n->cases.get(i)
            self.scan_expr(mc->guard)
            if mc->body != &null {
                self.dispatch_stmt(mc->body)
            }

            self.scan_expr(mc->expression)
        }

        self.taint = self.taint - 1
        return false
    }

    fn visit_try_catch_expr(self, n: unsafe *Expressions::TryCatchExpr) -> bool {
        if n == &null {
            return false
        }

        self.taint = self.taint + 1
        self.scan_expr(n->try_expr)
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            self.scan_expr(n->catch_arms.get(i)->body)
        }

        self.taint = self.taint - 1
        return false
    }

    fn visit_call_expr(self, n: unsafe *Expressions::CallExpr) -> bool {
        if n == &null {
            return false
        }

        self.scan_expr(n->callee)
        var unsafe *callee = null_flow_strip_parens(n->callee)
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            var unsafe *v = named_call_arg_value(a)
            if v != &null {
                a = v
            }

            var unsafe *mk = mode_marker_like(a)
            if mk != &null && self._all_inout_at(callee, i) {
                // The `@inout` marker: a write at the call, no pointer kept.
                self.scan_expr(mk)
                var q = null_place_of(mk)
                self._lose(unsafe &q, false, a->range)
                continue
            }

            self.scan_expr(n->args[i])
            // A carrier passed on may be kept: what it carries is lost.
            var cs = self._carry_of(a)
            self._lose_sticky(&cs, n->range)
        }

        // Calling a carrier writes what it carries; calling a function value
        // the scan cannot follow may write what any carrier does.
        if callee != &null && isa<NamedIdentExpr>(callee) {
            var unsafe *cd = cast<NamedIdentExpr>(callee)->resolved_decl
            if null_carrier_find(self.carriers, cd) >= 0 {
                var cs = self._carried(cd)
                self._lose_set(&cs, n->range)
            } else if null_flow_is_local(cd) {
                var cs = self._all_carried()
                self._lose_set(&cs, n->range)
            }
        }

        if callee != &null && isa<ChainExpr>(callee) {
            var unsafe *c0 = cast<ChainExpr>(callee)
            if c0->steps.size() > 0
                && c0->steps.get(0)->access_kind == ChainExpr::AccessKind::Arrow {
                var cs = self._carried(null_root_decl(c0->base))
                self._lose_set(&cs, n->range)
            }
        }

        // An unmarked argument to `@inout` binds (warned): unless no
        // candidate has an `@inout` parameter, a place passed may be written.
        if self._may_inout(callee) {
            for var i: usize = 0; i < n->args.size(); ++i {
                var unsafe *a = n->args[i]
                var unsafe *v = named_call_arg_value(a)
                if v != &null {
                    a = v
                }

                var q = null_place_of(a)
                self._lose(unsafe &q, false, n->range)
            }
        }

        // A method taking a mutable `self` may write any field of its receiver.
        if callee != &null && isa<ChainExpr>(callee) {
            var unsafe *c = cast<ChainExpr>(callee)
            var        k  = c->steps.size()
            if k > 0 {
                var unsafe *last = c->steps.get(k - 1)
                var known_const = if (last->resolved_decl != &null) => (null_scan_const_method(
                                      last->resolved_decl,
                                  ))
                                  else => null_scan_cell_const(
                                      last->candidate_cell,
                                  )

                if last->access_kind == ChainExpr::AccessKind::Dot && !known_const {
                    var q = if (k == 1) => (null_place_of(c->base))
                            else => null_chain_place(c, k - 2)
                    self._lose(unsafe &q, true, n->range)
                }
            }
        }

        return false
    }

    /// Every candidate of the call through \p callee takes its argument
    /// \p i `@inout` (so a `&e` there is the marker, not a pointer).
    priv fn _all_inout_at(self, callee: unsafe *Expr, i: usize) -> bool {
        if callee == &null {
            return false
        }

        var cell: unsafe *OverloadCell = &null
        var one:  unsafe *Decl         = &null
        var recv                       = false
        if isa<NamedIdentExpr>(callee) {
            one  = cast<NamedIdentExpr>(callee)->resolved_decl
            cell = cast<NamedIdentExpr>(callee)->candidate_cell
        } else if isa<ChainExpr>(callee) {
            var unsafe *c = cast<ChainExpr>(callee)
            if c->steps.size() == 0 {
                return false
            }

            var unsafe *st = c->steps.get(c->steps.size() - 1)
            one  = st->resolved_decl
            cell = st->candidate_cell
            recv = true
        } else {
            return false
        }

        if one != &null {
            return null_scan_inout_at(one, i, recv)
        }

        if cell == &null || cell->size() == 0 {
            return false
        }

        for var k: usize = 0; k < cell->size(); ++k {
            if !null_scan_inout_at(cell->get(k), i, recv) {
                return false
            }
        }

        return true
    }

    /// The call through \p callee may take an argument `@inout`.
    priv fn _may_inout(self, callee: unsafe *Expr) -> bool {
        if callee == &null {
            return true
        }

        if isa<NamedIdentExpr>(callee) {
            var unsafe *id = cast<NamedIdentExpr>(callee)
            var unsafe *d  = id->resolved_decl
            if d == &null {
                return !null_scan_cell_no_inout(id->candidate_cell)
            }

            if isa<FunctionDecl>(d) {
                return !null_scan_no_inout(d)
            }

            var unsafe *t = null_scan_decl_type(d)
            if t != &null && isa<FunctionPointerType>(canon_unqual(t)) {
                var unsafe *fp = cast<FunctionPointerType>(canon_unqual(t))
                for var i: usize = 0; i < fp->modes.size(); ++i {
                    if fp->modes[i] == ParamMode::Inout {
                        return true
                    }
                }

                return false
            }

            return true
        }

        if isa<ChainExpr>(callee) {
            var unsafe *c = cast<ChainExpr>(callee)
            if c->steps.size() == 0 {
                return true
            }

            var unsafe *st = c->steps.get(c->steps.size() - 1)
            if st->resolved_decl != &null {
                return !null_scan_no_inout(st->resolved_decl)
            }

            return !null_scan_cell_no_inout(st->candidate_cell)
        }

        return true
    }

    /// ## statements

    /// The loop a `break` / `continue` with \p label (empty: none) leaves,
    /// as an index into `loops`; -1 when it leaves the scanned loop's
    /// enclosing ones.
    priv fn _target(self, has_label: bool, label: Token) -> i64 {
        if self.loops.size() == 0 {
            return -1
        }

        if !has_label {
            return (self.loops.size() - 1) as i64
        }

        var nm = self.sc->ctx->get_spelling(label)
        var i  = self.loops.size()
        while i > 0 {
            i = i - 1
            if self.loops[i].label == nm {
                return i as i64
            }
        }

        return -1
    }

    priv fn _take_label(self) -> string {
        var l = self.pending
        self.pending = ""
        return l
    }

    /// A loop nested in the scanned body: one pass over \p body from the
    /// state before it, its head the join of that and the back edge (one
    /// pass is enough: an effect is a constant or nothing, so a second pass
    /// adds no path), the state after it the head (\p may_skip: the
    /// condition, or an exhausted range) joined with every `break`.
    priv fn _nested(self,
                    cond:     unsafe *Expr,
                    body:     unsafe *Stmt,
                    update:   unsafe *Expr,
                    may_skip: bool) {
        var l = NullScanLoop{}
        l.label = self._take_label()
        self.loops.push_back(l)
        var s0 = self.st
        if cond != &null {
            self.scan_expr(cond)
        }

        if body != &null {
            self.scan_stmt(body)
        }

        var back = self.st
        var me   = self.loops.back()
        for var i: usize = 0; i < me.conts.size(); ++i {
            back = null_scan_join(&back, &me.conts[i])
        }

        if update != &null {
            self.st = back
            self.scan_expr(update)
            back = self.st
        }

        var head = null_scan_join(&s0, &back)
        self.st = head
        if cond != &null {
            self.scan_expr(cond)
        }

        me = self.loops.back()
        self.loops.pop_back()
        var after = self.st
        if !may_skip {
            after      = NullScanState{}
            after.dead = true
            if me.breaks.size() > 0 {
                after = back
            }
        }

        for var i: usize = 0; i < me.breaks.size(); ++i {
            after = null_scan_join(&after, &me.breaks[i])
        }

        self.st = after
    }

    fn scan_stmt(self, s: unsafe *Stmt) {
        if s == &null {
            return
        }

        match s->kind {
            case StmtKind::CompoundStmt {
                var unsafe *c = cast<Statements::CompoundStmt>(s)
                for var i: usize = 0; i < c->body.size(); ++i {
                    self.scan_stmt(c->body[i])
                }
            } case StmtKind::ExpressionStmt {
                self.scan_expr(cast<Statements::ExpressionStmt>(s)->expr)
            } case StmtKind::DeclStmt {
                var unsafe *d = cast<Statements::DeclStmt>(s)->decl
                if d != &null && isa<VariableDecl>(d) {
                    var unsafe *v = cast<VariableDecl>(d)
                    self.scan_expr(v->init)
                    if v->init != &null {
                        self._carry_into(d, v->init)
                    }
                }
            } case StmtKind::ReturnStmt {
                self.scan_expr(cast<Statements::ReturnStmt>(s)->value)
                self.st.dead = true
            } case StmtKind::PanicStmt {
                self.scan_expr(cast<Statements::PanicStmt>(s)->payload)
                self.st.dead = true
            } case StmtKind::BreakStmt {
                var unsafe *b = cast<Statements::BreakStmt>(s)
                var        t  = self._target(b->has_label, b->label)
                if t >= 0 && !self.st.dead {
                    self.loops[t as usize].breaks.push_back(self.st)
                }

                self.st.dead = true
            } case StmtKind::ContinueStmt {
                var unsafe *c = cast<Statements::ContinueStmt>(s)
                var        t  = self._target(c->has_label, c->label)
                if t >= 0 && !self.st.dead {
                    self.loops[t as usize].conts.push_back(self.st)
                }

                self.st.dead = true
            } case StmtKind::ConditionalStmt {
                var unsafe *c = cast<Statements::ConditionalStmt>(s)
                self.scan_expr(c->cond)
                var s0 = self.st
                if c->then_ != &null {
                    self.scan_stmt(c->then_)
                }

                var s1 = self.st
                self.st = s0
                if c->else_ != &null {
                    self.scan_stmt(c->else_)
                }

                self.st = null_scan_join(&s1, &self.st)
            } case StmtKind::WhileLoopStmt {
                var unsafe *w = cast<Statements::WhileLoopStmt>(s)
                self._nested(
                    w->cond,
                    unsafe (w->body as unsafe *Stmt),
                    &null,
                    true,
                )
            } case StmtKind::LoopStmt {
                self._nested(
                    &null,
                    unsafe (cast<Statements::LoopStmt>(s)->body as unsafe *Stmt),
                    &null,
                    false,
                )
            } case StmtKind::IndexedForStmt {
                var unsafe *f  = cast<Statements::IndexedForStmt>(s)
                var        lbl = self._take_label()
                if f->init != &null {
                    self.scan_stmt(f->init)
                }

                self.pending = lbl
                self._nested(f->cond, f->body, f->update, true)
            } case StmtKind::RangedForStmt {
                var unsafe *f  = cast<Statements::RangedForStmt>(s)
                var        lbl = self._take_label()
                self.scan_expr(f->iterable)
                self.pending = lbl
                self._nested(&null, f->body, &null, true)
            } case StmtKind::MatchStmt {
                var unsafe *m = cast<Statements::MatchStmt>(s)
                self.scan_expr(m->scrutinee)
                var s0  = self.st
                var acc = s0
                for var i: usize = 0; i < m->cases.size(); ++i {
                    var unsafe *mc = m->cases.get(i)
                    self.st = s0
                    self.scan_expr(mc->guard)
                    if mc->body != &null {
                        self.scan_stmt(mc->body)
                    }

                    self.scan_expr(mc->expression)
                    acc = null_scan_join(&acc, &self.st)
                }

                self.st = acc
            } case StmtKind::LabeledStmt {
                var unsafe *l = cast<Statements::LabeledStmt>(s)
                self.pending = self.sc->ctx->get_spelling(l->label)
                self.scan_stmt(l->inner)
                self.pending = ""
            } case StmtKind::TryCatchStmt {
                // A catch arm may start after any part of the body ran: from
                // everything the body may have done along the way.
                var unsafe *t = cast<Statements::TryCatchStmt>(s)
                var        s0 = self.st
                if t->try_body != &null {
                    self.scan_stmt(t->try_body)
                }

                var end = self.st
                self.st    = s0
                self.taint = self.taint + 1
                if t->try_body != &null {
                    self.dispatch_stmt(t->try_body)
                }

                self.taint = self.taint - 1
                var entry = self.st
                entry.dead = s0.dead
                var acc = end
                for var i: usize = 0; i < t->arms.size(); ++i {
                    self.st = entry
                    var unsafe *arm = t->arms.get(i)
                    if arm->body != &null {
                        self.scan_stmt(arm->body)
                    }

                    acc = null_scan_join(&acc, &self.st)
                }

                self.st = acc
            } case StmtKind::UnsafeBlockStmt {
                var unsafe *u = cast<Statements::UnsafeBlockStmt>(s)
                if u->body != &null {
                    self.scan_stmt(unsafe (u->body as unsafe *Stmt))
                }
            } default {
                // Anything else (`finally`, `with`, a destructuring, `yield`,
                // an assert): its effects, in no particular order.
                self.taint = self.taint + 1
                self.dispatch_stmt(s)
                self.taint = self.taint - 1
            }
        }
    }
}

/// What read_value / read_prefix did with a read of a nullable (§4).
/// NONE: it is no recorded read of a nullable place, nothing changed.
/// NARROWED: the place is NonNull here; the read is now typed `T` and
/// marked narrowed. REFUSED: it is Maybe or Null; the §4.2 error is
/// reported (or held by a trap) and the read is poisoned.
pub
const NULL_READ_NONE: u8 = 0
pub
const NULL_READ_NARROWED: u8 = 1
pub
const NULL_READ_REFUSED: u8 = 2

pub class NullnessFlow {
    pub var sc: unsafe *SemaContext = &null
    pub var tu: unsafe *TypeUtil    = &null
    /// The state here. Mixins read and replace it around branches.
    pub var env: NullEnv

    priv var _frames: cxx::std::vector<NullFrame>
    priv var _loops:  cxx::std::vector<NullLoop>
    priv var _traps:  cxx::std::vector<NullTrap>
    /// The pointers taken in this body that may still be written through.
    priv var _escapes: cxx::std::vector<NullEscape>
    /// A label waiting for the loop statement it labels (label_next).
    priv var _label: string = ""
    /// The pointers and pointer-capturing closures held by locals here (3.7).
    priv var _carriers: cxx::std::vector<NullCarrier>
    /// closure node -> index in _closure_list: what calling it may write.
    priv var _closure_sets: llvm::DenseMap<u64, u64>
    priv var _closure_list: cxx::std::vector<cxx::std::vector<cxx::std::vector<unsafe *Decl>>>
    /// expr -> index in _read_list: the fact its place had where it was written.
    priv var _reads:     llvm::DenseMap<u64, u64>
    priv var _read_list: cxx::std::vector<NullFact>
    /// `&&` / `||` node -> index in _cond_list: its sets, stored as typed.
    priv var _conds:     llvm::DenseMap<u64, u64>
    priv var _cond_list: cxx::std::vector<NullCond>

    fn NullnessFlow(self) { }

    fn NullnessFlow(self, sc: unsafe *SemaContext, tu: unsafe *TypeUtil) {
        self.sc = sc
        self.tu = tu
    }

    /// ## frames

    /// A function or closure (\p closure) body begins: nothing is known in
    /// it. The enclosing body's state is kept for leave().
    fn enter(self, closure: unsafe *Expressions::ClosureExpr = &null) {
        var fr = NullFrame{}
        fr.closure    = closure
        fr.env        = self.env
        fr.loops_base = self._loops.size()
        fr.traps_base = self._traps.size()
        fr.escapes    = self._escapes
        fr.carriers   = self._carriers
        self._frames.push_back(fr)
        self.env = NullEnv{}
        if closure != &null {
            self.env = self._closure_entry(closure, &fr.env)
        }

        self._escapes  = cxx::std::vector<NullEscape>()
        self._carriers = cxx::std::vector<NullCarrier>()
    }

    /// Where the body of \p c starts (3.7): a by-copy capture is the
    /// closure's own copy, made when the closure was, so it has the state
    /// it had there (\p outer), less anything the body assigns it (the copy
    /// persists from one call to the next). A by-pointer capture is the
    /// original, which anything may write while the closure waits: nothing
    /// is known about it. Globals start Maybe, as in any body.
    priv fn _closure_entry(self, c: unsafe *Expressions::ClosureExpr, outer: *NullEnv) -> NullEnv {
        var out = NullEnv{}
        if outer->dead {
            return out
        }

        var named   = false
        var all_ptr = false
        for var i: usize = 0; i < c->captures.size(); ++i {
            var unsafe *cap = c->captures.get(i)
            if cap->name == &null {
                if cap->by_ptr {
                    all_ptr = true
                }

                continue
            }

            named = true
        }

        var scan = NullLoopScan()
        scan.sc = self.sc
        var keep = cxx::std::vector<NullFact>()
        for var i: usize = 0; i < outer->facts.size(); ++i {
            var f = outer->facts[i]
            if f.global || f.place.size() == 0 || f.state == Nullness::Maybe {
                continue
            }

            var unsafe *d      = f.place[0]
            var        by_copy = !named && !all_ptr && !c->explicit_no_capture
            for var k: usize = 0; k < c->captures.size(); ++k {
                var unsafe *cap = c->captures.get(k)
                if cap->name == &null || cap->name->resolved_decl != d {
                    continue
                }

                by_copy = !cap->by_ptr
            }

            if !by_copy {
                continue
            }

            keep.push_back(f)
            scan.cands.push_back(f.place)
        }

        if keep.size() == 0 {
            return out
        }

        var body: unsafe *Stmt = &null
        if c->body_block != &null {
            body = c->body_block
        }

        var touched = scan.run_unordered(body, c->body_expr)
        for var i: usize = 0; i < keep.size(); ++i {
            // As at a loop's head: the next call starts from what this one left.
            var fl = touched.flags[i]
            var ok = (fl & NULL_SCAN_LOST) == 0
            if keep[i].state == Nullness::Null {
                ok = fl == NULL_SCAN_KEPT
            }

            if ok {
                out.facts.push_back(keep[i])
            }
        }

        return out
    }

    fn leave(self) {
        if self._frames.empty() {
            return
        }

        var fr = self._frames.back()
        self._frames.pop_back()
        self.env       = fr.env
        self._escapes  = fr.escapes
        self._carriers = fr.carriers
        while self._loops.size() > fr.loops_base {
            self._loops.pop_back()
        }

        while self._traps.size() > fr.traps_base {
            self._traps.pop_back()
        }
    }

    priv fn _loops_base(self) -> usize {
        if self._frames.empty() {
            return 0
        }

        return self._frames.back().loops_base
    }

    priv fn _traps_base(self) -> usize {
        if self._frames.empty() {
            return 0
        }

        return self._frames.back().traps_base
    }

    /// ## the state

    /// \p place's fact here. An address-taken root is never narrowed, and
    /// unreachable code reads every place as NonNull (nothing runs there).
    fn get(self, place: unsafe *cxx::std::vector<unsafe *Decl>) -> NullFact {
        var f = NullFact{}
        f.place = *place
        if place->size() == 0 {
            return f
        }

        f.global = self._shared((*place)[0])
        if self.env.dead {
            f.state = Nullness::NonNull
            return f
        }

        var i = null_env_find(unsafe &self.env, place)
        if i >= 0 {
            return self.env.facts[i as usize]
        }

        return f
    }

    /// The env merged with \p other (3.1).
    fn join(self, a: unsafe *NullEnv, b: unsafe *NullEnv) -> NullEnv {
        return null_env_join(a, b)
    }

    /// An env no path reaches.
    fn dead_env(self) -> NullEnv {
        var e = NullEnv{}
        e.dead = true
        return e
    }

    /// `return`, `break`, `continue`, `panic`, a `-> !` call: nothing after
    /// it runs on this path (3.3, early exit).
    fn diverge(self) {
        self.env = self.dead_env()
    }

    /// \p place, and every path under it, may now hold anything (3.4): it
    /// was passed `@inout`, or a pointer to it was written through. Noted
    /// \p why at \p at. A nullable place with no fact gets a Maybe one, so
    /// the access error names this write rather than the declaration.
    fn weaken(self, place: unsafe *cxx::std::vector<unsafe *Decl>, why: NullWhy, at: SourceRange) {
        if self.env.dead || place->size() == 0 {
            return
        }

        null_env_weaken_under(&self.env, place, false, why, at)
        if null_env_find(unsafe &self.env, place) < 0
            && null_flow_type_is_nullable(self._place_type(*place)) {
            var f = NullFact{}
            f.place  = *place
            f.why    = why
            f.at     = at
            f.global = self._shared((*place)[0])
            self.env.facts.push_back(f)
        }
    }

    /// Every path strictly under \p place may now hold anything, \p place
    /// itself not: a call took it as mutable `self` (3.4), which can write
    /// its fields but not make the value itself null.
    fn weaken_inside(self, place: unsafe *cxx::std::vector<unsafe *Decl>, at: SourceRange) {
        if self.env.dead || place->size() == 0 {
            return
        }

        null_env_weaken_under(&self.env, place, true, NullWhy::MutSelf, at)
    }

    /// `&e`, typed: \p n, a `*T` to \p pointee. Until a consumer accounts
    /// for the pointer (unescape), it may be kept anywhere, so any call or
    /// unplaced write may write \p e's place through it (3.4, 3.7). A
    /// `*const T` cannot write and is not followed.
    fn address_taken(self, n: unsafe *Expressions::UnaryOperatorExpr, pointee: unsafe *Type) {
        if n == &null || pointee != &null && canon_has_const(pointee) {
            return
        }

        // `&xs[i]`, `&p->f`: no place, so no fact it could change (what `p`
        // points at is already followed, by the `&` that made `p`).
        var place = null_place_of(n->operand)
        if place.size() == 0 {
            return
        }

        var esc = NullEscape{}
        esc.node  = unsafe (n as unsafe *Expr)
        esc.place = place
        esc.at    = n->range
        self._escapes.push_back(esc)
    }

    /// The pointer \p node made is accounted for: it was the `@inout`
    /// marker (whose write the call weakens itself) or went to a `*const`.
    fn unescape(self, node: unsafe *Expr) {
        var keep = cxx::std::vector<NullEscape>()
        for var i: usize = 0; i < self._escapes.size(); ++i {
            if self._escapes[i].node != node {
                keep.push_back(self._escapes[i])
            }
        }

        self._escapes = keep
    }

    /// \p arg is an argument to an `@inout` parameter, written with the
    /// marker \p marker (null: unmarked): the callee may write it (3.4).
    /// The marker's pointer goes nowhere else, so it is no escape.
    fn inout_arg(self, arg: unsafe *Expr, marker: unsafe *Expr) {
        if marker != &null {
            self.unescape(marker)
        }

        if arg == &null {
            return
        }

        var place = null_place_of(arg)
        // `bump(&p->n)`: the write lands wherever `p` points.
        if place.size() == 0 {
            self._write_via(arg, false, arg->range)
            return
        }

        self.weaken(unsafe &place, NullWhy::Inout, arg->range)
    }

    /// \p arg is passed to a parameter of type \p pt. A `&e` to a `*const`
    /// parameter cannot write \p e: its pointer is no escape.
    fn pass_pointer(self, arg: unsafe *Expr, pt: unsafe *Type) {
        if arg == &null || pt == &null {
            return
        }

        var unsafe *c = null_flow_through_nullable(pt)
        if c == &null || !isa<PointerType>(c) {
            return
        }

        if canon_has_const(cast<PointerType>(c)->pointee) {
            self.consumed(arg)
        }
    }

    /// The call \p callee (a chain whose last step is a method taking a
    /// mutable `self`) may write any field of its receiver (3.4): every
    /// path under the receiver's place is Maybe after it. A receiver that is
    /// no place (`(*p).m()`, `p->m()`) is wherever a pointer points.
    fn mutable_self_call(self, callee: unsafe *ChainExpr, at: SourceRange) {
        if callee == &null || callee->steps.size() == 0 {
            return
        }

        var        k     = callee->steps.size()
        var unsafe *last = callee->steps.get(k - 1)
        var        place = cxx::std::vector<unsafe *Decl>()
        if last->access_kind == ChainExpr::AccessKind::Dot {
            place = if (k == 1) => (null_place_of(callee->base))
                    else => null_chain_place(callee, k - 2)
        }

        if place.size() > 0 {
            self.weaken_inside(unsafe &place, at)
            return
        }

        // `p->m()`: the receiver is what `p` points at; `(*p).m()` likewise.
        if k == 1 && last->access_kind == ChainExpr::AccessKind::Arrow {
            var th = self._via(callee->base)
            if !th.known {
                self.write_through()
                return
            }

            for var i: usize = 0; i < th.places.size(); ++i {
                self.weaken_inside(unsafe &th.places[i], at)
            }

            return
        }

        if k == 1 {
            self._write_via(callee->base, true, at)
            return
        }

        self.write_through()
    }

    /// ## aliases (3.7)

    /// The places the typed value \p e carries: `&place` (unless it is a
    /// `*const`), a carrier's name, a closure that captures by pointer, the
    /// arms of an if-expression, a cast's operand.
    fn carry_of(self, e: unsafe *Expr) -> cxx::std::vector<cxx::std::vector<unsafe *Decl>> {
        var        out = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
        var unsafe *x  = null_flow_strip_parens(e)
        if x == &null {
            return out
        }

        if isa<Expressions::UnaryOperatorExpr>(x) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
            if !u->is_prefix() || u->op_token.kind != TokenKind::OpAmp || u->is_mode_marker {
                return out
            }

            var unsafe *t = canon_unqual(x->type_)
            if t != &null && isa<PointerType>(t) && canon_has_const(cast<PointerType>(t)->pointee) {
                return out
            }

            var q = null_place_of(u->operand)
            if q.size() > 0 {
                out.push_back(q)
                return out
            }

            var unsafe *o = null_flow_strip_parens(u->operand)
            if o != &null
                && isa<Expressions::UnaryOperatorExpr>(o)
                && cast<Expressions::UnaryOperatorExpr>(o)->op_token.kind == TokenKind::OpStar {
                return self.carry_of(
                    cast<Expressions::UnaryOperatorExpr>(o)->operand,
                )
            }

            return self._carried(null_root_decl(u->operand))
        }

        if isa<NamedIdentExpr>(x) {
            return self._carried(cast<NamedIdentExpr>(x)->resolved_decl)
        }

        if isa<Expressions::ClosureExpr>(x) {
            var it = self._closure_sets.find(x as usize as u64)
            if it != self._closure_sets.end() {
                return self._closure_list[((it->second) as usize)]
            }

            return out
        }

        if isa<Expressions::TypeCastExpr>(x) {
            return self.carry_of(cast<Expressions::TypeCastExpr>(x)->operand)
        }

        if isa<Expressions::IfExpr>(x) {
            var unsafe *ie = cast<Expressions::IfExpr>(x)
            var        a   = self.carry_of(ie->then_expr)
            null_places_union(unsafe &out, unsafe &a)
            for var i: usize = 0; i < ie->else_ifs.size(); ++i {
                var b = self.carry_of(ie->else_ifs.get(i)->body)
                null_places_union(unsafe &out, unsafe &b)
            }

            var c = self.carry_of(ie->else_expr)
            null_places_union(unsafe &out, unsafe &c)
        }

        return out
    }

    priv fn _carried(self, d: unsafe *Decl) -> cxx::std::vector<cxx::std::vector<unsafe *Decl>> {
        var k = null_carrier_find(self._carriers, d)
        if k < 0 {
            return cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
        }

        return self._carriers[k as usize].places
    }

    priv fn _escape_set(self,
                        node:      unsafe *Expr,
                        const set: cxx::std::vector<cxx::std::vector<unsafe *Decl>>,
                        at:        SourceRange) {
        for var i: usize = 0; i < set.size(); ++i {
            var esc = NullEscape{}
            esc.node  = node
            esc.place = (set)[i]
            esc.at    = at
            self._escapes.push_back(esc)
        }
    }

    /// \p n names \p d. A carrier's value may go anywhere from here, as a
    /// fresh `&` may (address_taken): until a consumer accounts for it (a
    /// dereference, `->`, a call of it, a copy into a local, a `*const`
    /// parameter), what it carries has escaped.
    fn note_use(self, n: unsafe *Expr, d: unsafe *Decl) {
        var k = null_carrier_find(self._carriers, d)
        if k < 0 {
            return
        }

        var set = self._carriers[k as usize].places
        self._escape_set(n, set, n->range)
    }

    /// The value \p e (a `&`, a carrier's name, a closure, or an
    /// if-expression of them) went somewhere the analysis follows.
    fn consumed(self, e: unsafe *Expr) {
        var unsafe *x = null_flow_strip_parens(e)
        if x == &null {
            return
        }

        self.unescape(x)
        if isa<Expressions::TypeCastExpr>(x) {
            self.consumed(cast<Expressions::TypeCastExpr>(x)->operand)
            return
        }

        if isa<Expressions::IfExpr>(x) {
            var unsafe *ie = cast<Expressions::IfExpr>(x)
            self.consumed(ie->then_expr)
            for var i: usize = 0; i < ie->else_ifs.size(); ++i {
                self.consumed(ie->else_ifs.get(i)->body)
            }

            self.consumed(ie->else_expr)
        }
    }

    /// The closure \p c is made here: calling it may write what it captures
    /// by pointer and what the carriers it copies carry. Like a `&`, the
    /// value has escaped until a consumer accounts for it.
    fn closure_made(self, c: unsafe *Expressions::ClosureExpr) {
        if c == &null {
            return
        }

        var set = null_closure_places(c, unsafe &self._carriers)
        self._closure_sets[c as usize as u64] = (self._closure_list.size() as u64)
        self._closure_list.push_back(set)
        self._escape_set(unsafe (c as unsafe *Expr), set, c->range)
    }

    /// The local \p d is given \p value (of type \p t): it now also holds
    /// what \p value carries, and the value went no further. A `*const`
    /// local carries nothing.
    priv fn _carry_into(self, d: unsafe *Decl, value: unsafe *Expr, t: unsafe *Type) {
        if !null_flow_is_local(d) || value == &null {
            return
        }

        var set = self.carry_of(value)
        if set.size() == 0 {
            return
        }

        self.consumed(value)
        var unsafe *c = null_flow_through_nullable(t)
        if c != &null && isa<PointerType>(c) && canon_has_const(cast<PointerType>(c)->pointee) {
            return
        }

        var k = null_carrier_find(self._carriers, d)
        if k < 0 {
            var nc = NullCarrier{}
            nc.decl = d
            self._carriers.push_back(nc)
            k = ((self._carriers.size() - 1) as i64)
        }

        null_places_union(
            unsafe &self._carriers[k as usize].places,
            unsafe &set,
        )
    }

    /// Where a write to \p target lands, when \p target is no place.
    priv fn _through(self, target: unsafe *Expr) -> NullThrough {
        var        out = NullThrough{}
        var unsafe *x  = null_flow_strip_parens(target)
        while x != &null {
            if isa<NamedIdentExpr>(x) {
                out.known = true
                return out
            } // the local's own storage.

            if isa<Expressions::UnaryOperatorExpr>(x) {
                var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
                if u->op_token.kind != TokenKind::OpStar {
                    return out
                }

                return self._via(u->operand)
            }

            if isa<ChainExpr>(x) {
                var unsafe *c = cast<ChainExpr>(x)
                for var i: usize = 0; i < c->steps.size(); ++i {
                    if c->steps.get(i)->access_kind == ChainExpr::AccessKind::Arrow {
                        if i == 0 {
                            return self._via(c->base)
                        }

                        return out
                    }
                }

                x = null_flow_strip_parens(c->base)
                continue
            }

            if isa<Expressions::SubscriptExpr>(x) {
                var unsafe *b = cast<Expressions::SubscriptExpr>(x)->base
                var unsafe *bt = if (b != &null) => (canon_unqual(b->type_)) else => &null
                if bt != &null && isa<PointerType>(bt) {
                    return self._via(b)
                }

                x = null_flow_strip_parens(b)
                continue
            }

            return out
        }

        return out
    }

    /// A write through the pointer value \p p.
    priv fn _via(self, p: unsafe *Expr) -> NullThrough {
        var out = NullThrough{}
        out.places = self.carry_of(p)
        out.known  = out.places.size() > 0
        if out.known {
            self.consumed(p)
        }

        return out
    }

    /// \p target, no place, is written (\p strict: only its fields, by a
    /// mutable `self`): what it is reached through may be changed.
    priv fn _write_via(self, target: unsafe *Expr, strict: bool, at: SourceRange) {
        var th = self._through(target)
        if !th.known {
            self.write_through()
            return
        }

        for var i: usize = 0; i < th.places.size(); ++i {
            var q = th.places[i]
            if strict {
                self.weaken_inside(unsafe &q, at)
            } else {
                self.weaken(unsafe &q, NullWhy::Through, at)
            }
        }
    }

    /// The call through \p callee, a function value, ran: a closure that
    /// carries places may have written them. The call is no escape.
    fn call_value(self, callee: unsafe *Expr, at: SourceRange) {
        var unsafe *x = null_flow_strip_parens(callee)
        if x == &null || !isa<NamedIdentExpr>(x) {
            return
        }

        var set = self._carried(cast<NamedIdentExpr>(x)->resolved_decl)
        if set.size() == 0 {
            return
        }

        self.unescape(x)
        for var i: usize = 0; i < set.size(); ++i {
            self.weaken(unsafe &set[i], NullWhy::Aliased, at)
        }
    }

    /// \p lhs is written in place (`a += b`, `++a`): a place keeps what it
    /// holds (a narrowed one is written through its value); anything else
    /// is a write the analysis cannot place.
    fn modified(self, lhs: unsafe *Expr) {
        if lhs == &null {
            return
        }

        var place = null_place_of(lhs)
        if place.size() == 0 {
            self._write_via(lhs, false, lhs->range)
        }
    }

    /// The user operator \p fd ran with \p operand as its receiver (its
    /// left side): a method taking a mutable `self` may write any field of
    /// it, as mutable_self_call.
    fn operator_call(self, fd: unsafe *Decl, operand: unsafe *Expr, at: SourceRange) {
        if fd == &null || !isa<FunctionDecl>(fd) {
            return
        }

        var unsafe *f = cast<FunctionDecl>(fd)
        if !f->is_method() || f->is_const() || f->params[0]->is_const {
            return
        }

        var place = null_place_of(operand)
        if place.size() == 0 {
            self._write_via(operand, true, at)
            return
        }

        self.weaken_inside(unsafe &place, at)
    }

    /// A write the analysis cannot place (`*p = v`, `p->f = v`, `xs[i] += 1`):
    /// it may land in any place a pointer was taken to.
    fn write_through(self) {
        if self.env.dead {
            return
        }

        for var i: usize = 0; i < self._escapes.size(); ++i {
            var *e = &self._escapes[i]
            null_env_weaken_under(
                &self.env,
                unsafe &e->place,
                false,
                NullWhy::Escaped,
                e->at,
            )
        }

        // A copy of a pointer capture (`var p = x; *p = v`) is no carrier, so
        // the write may land in `*x`.
        for var i: usize = 0; i < self.env.facts.size(); ++i {
            var *f = &self.env.facts[i]
            if f->place.size() == 0 || f->state == Nullness::Maybe {
                continue
            }

            if !self._ptr_captured(f->place[0]) {
                continue
            }

            f->state = Nullness::Maybe
            f->why   = NullWhy::None   // no site to name: the note says what the place is.
        }
    }

    /// A call ran: it may have written any global (3.8), and any place a
    /// pointer was taken to (3.7). Their facts become Maybe, a global's
    /// noted at \p at, an escaped place's at its `&`.
    fn after_call(self, at: SourceRange) {
        if self.env.dead {
            return
        }

        for var i: usize = 0; i < self.env.facts.size(); ++i {
            if !self.env.facts[i].global {
                continue
            }

            self.env.facts[i].state = Nullness::Maybe
            self.env.facts[i].why   = NullWhy::Called
            self.env.facts[i].at    = at
        }

        self.write_through()
    }

    /// ## definitions and assignments (3.2)

    /// The state a nullable takes from the value \p rhs it is given: `null`
    /// is Null; any non-nullable value (a `T` converted, `&e`, a narrowed
    /// read) is NonNull; a nullable place passes its own state on; anything
    /// else (a call returning `T?`) is Maybe.
    fn value_state(self, rhs: unsafe *Expr, at: SourceRange) -> NullFact {
        var f = NullFact{}
        f.why = NullWhy::Assigned
        f.at  = at
        var unsafe *x = null_flow_strip_parens(rhs)
        if x == &null {
            return f
        }

        if isa<NullLiteralExpr>(x) {
            f.state = Nullness::Null
            return f
        }

        if x->type_ == &null {
            return f
        }

        if !null_flow_type_is_nullable(x->type_) {
            f.state = Nullness::NonNull
            return f
        }

        var it = self._reads.find(x as usize as u64)
        if it != self._reads.end() {
            f.state = self._read_list[((it->second) as usize)].state
        }

        return f
    }

    /// `var v ... = init` (or none: a `T?` defaults to null) for a local
    /// whose type is nullable. Globals and statics are never defined here:
    /// each function sees them Maybe (3.8).
    fn define(self, v: unsafe *VariableDecl) {
        if v == &null || v->is_poisoned() || v->type_ == &null {
            return
        }

        // `var p = &x`, `var clear = fn ()|*x| { ... }`: a carrier (3.7).
        self._carry_into(
            unsafe (v as unsafe *Decl),
            v->init,
            v->type_->canonical,
        )

        if !null_flow_type_is_nullable(v->type_->canonical) {
            return
        }

        if null_flow_is_global(v) {
            return
        }

        var f = NullFact{}
        if v->init == &null {
            f.state = Nullness::Null
            f.why   = NullWhy::Assigned
            f.at    = v->range
        } else {
            f = self.value_state(v->init, v->range)
        }

        f.place.push_back(v)
        self._set(f)
    }

    /// `lhs = rhs`, typed. A nullable place takes \p rhs's state; any place
    /// loses the facts under it (`o = make()` forgets `o.cache`).
    fn assign(self, lhs: unsafe *Expr, rhs: unsafe *Expr, at: SourceRange) {
        var place = null_place_of(lhs)
        if place.size() == 0 {
            self._write_via(lhs, false, at)
            return
        }

        // `q = p`: a local now also carries what the value does (3.7).
        if place.size() == 1 {
            self._carry_into(place[0], rhs, null_scan_decl_type(place[0]))
        }

        var unsafe *x = null_flow_strip_parens(lhs)
        if x != &null && null_flow_type_is_nullable(x->type_) {
            var f = self.value_state(rhs, at)
            f.place = place
            self._set(f)
            return
        }

        if !self.env.dead {
            null_env_kill_under(unsafe &self.env, unsafe &place)
        }
    }

    priv fn _set(self, const f_in: NullFact) {
        if self.env.dead {
            return
        }

        var f = f_in
        f.global = self._shared(f.place[0])
        null_env_kill_under(unsafe &self.env, unsafe &f.place)
        if f.state == Nullness::Maybe && f.why == NullWhy::None {
            return
        }

        self.env.facts.push_back(f)
    }

    /// ## conditions (3.3)

    /// \p e's true and false sets, \p e typed. A null test on a place
    /// narrows it each way; `!` swaps; `&&` / `||` answer what they stored
    /// while typed; `true` / `false` make one side unreachable; anything
    /// else refines nothing.
    fn cond_of(self, e: unsafe *Expr) -> NullCond {
        var c = NullCond{}
        c.t = self.env
        c.f = self.env
        var unsafe *x = null_flow_strip_parens(e)
        if x == &null {
            return c
        }

        var it = self._conds.find(x as usize as u64)
        if it != self._conds.end() {
            return self._cond_list[((it->second) as usize)]
        }

        var nt = null_test_of(x)
        if nt.operand != &null {
            var place = null_place_of(nt.operand)
            if place.size() == 0 || self.env.dead {
                return c
            }

            var yes = NullFact{}
            yes.place  = place
            yes.state  = Nullness::NonNull
            yes.why    = NullWhy::Tested
            yes.at     = x->range
            yes.global = self._shared(place[0])
            var no = yes
            no.state = Nullness::Null
            if nt.present {
                null_env_put(unsafe &c.t, yes)
                null_env_put(unsafe &c.f, no)
            } else {
                null_env_put(unsafe &c.t, no)
                null_env_put(unsafe &c.f, yes)
            }

            return c
        }

        if isa<Expressions::UnaryOperatorExpr>(x) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(x)
            var        k  = u->op_token.kind
            if u->resolved_op == &null
                && u->is_prefix()
                && (k == TokenKind::OpExclaim || k == TokenKind::KwNot) {
                var inner = self.cond_of(u->operand)
                var sw    = NullCond{}
                sw.t = inner.f
                sw.f = inner.t
                return sw
            }

            return c
        }

        if isa<BooleanLiteralExpr>(x) {
            if cast<BooleanLiteralExpr>(x)->value {
                c.f = self.dead_env()
            } else {
                c.t = self.dead_env()
            }

            return c
        }

        // `a === b` is `(a? && b?) && a == b` (Compiler/Spec/Nullables.md#identity): true, each
        // nullable place in it holds a value; false says nothing.
        if isa<Expressions::BinaryOperatorExpr>(x) {
            var unsafe *b = cast<Expressions::BinaryOperatorExpr>(x)
            if b->op_token.kind != TokenKind::OpEqualEqualEqual
                || b->is_poisoned()
                || self.env.dead {
                return c
            }

            self.put_state(unsafe &c.t, b->lhs, Nullness::NonNull, x->range)
            self.put_state(unsafe &c.t, b->rhs, Nullness::NonNull, x->range)
            return c
        }

        return c
    }

    /// \p e, when it is a nullable place, \p state in \p env, decided by the
    /// test at \p at (`===`'s true set; a `match` arm, Compiler/Spec/Nullables.md#match).
    fn put_state(self, env: unsafe *NullEnv, e: unsafe *Expr, state: Nullness, at: SourceRange) {
        if env->dead || !null_flow_is_nullable(e) {
            return
        }

        var place = null_place_of(e)
        if place.size() == 0 {
            return
        }

        var f = NullFact{}
        f.place  = place
        f.state  = state
        f.why    = NullWhy::Tested
        f.at     = at
        f.global = self._shared(place[0])
        null_env_put(env, f)
    }

    /// `unwrap!(e)` was just typed: past it, a place \p e names holds a
    /// value, since on null the program ended there (Compiler/Spec/Nullables.md#unwrap), as
    /// after `if !e? { abort }`.
    fn unwrapped(self, e: unsafe *Expr, at: SourceRange) {
        var place = null_place_of(e)
        if place.size() == 0 || self.env.dead {
            return
        }

        var f = NullFact{}
        f.place  = place
        f.state  = Nullness::NonNull
        f.why    = NullWhy::Tested
        f.at     = at
        f.global = self._shared(place[0])
        null_env_put(unsafe &self.env, f)
    }

    /// Record \p e's sets (an `&&` / `||`, computed while it was typed).
    fn store_cond(self, e: *Expr, const c: NullCond) {
        self._conds[e as usize as u64] = (self._cond_list.size() as u64)
        self._cond_list.push_back(c)
    }

    /// ## loops (3.5, conservatively)

    /// The next loop statement is labeled \p name (`outer: while ...`).
    fn label_next(self, const name: string) {
        self._label = name
    }

    /// The head of a loop over \p body, with \p update (a `for`'s) run on
    /// the back edge after it (3.5). The body is typed once, from here, so
    /// the state here must hold on every back edge too: a place proven here
    /// stays proven only when no path through the body (and the update)
    /// may bring it back holding anything else (NullLoopScan), and a
    /// global or an escaped place never does, since any call may write it.
    /// The condition is typed after this, at the head, so `while x?`
    /// proves `x` at the top of the body whatever the body does to it.
    fn loop_enter(self, body: unsafe *Stmt, update: unsafe *Expr) {
        var l = NullLoop{}
        l.label     = self._label
        self._label = ""
        if !self.env.dead {
            var scan = NullLoopScan()
            scan.sc       = self.sc
            scan.carriers = self._carriers
            var idx = cxx::std::vector<usize>()
            for var i: usize = 0; i < self.env.facts.size(); ++i {
                var *f = &self.env.facts[i]
                if f->global || f->state == Nullness::Maybe {
                    continue
                }

                idx.push_back(i)
                scan.cands.push_back(f->place)
            }

            var back = scan.run(body, update, l.label)
            for var j: usize = 0; j < idx.size(); ++j {
                if back.dead {
                    break
                }

                var *f = &self.env.facts[idx[j]]
                var fl = back.flags[j]
                // NonNull survives what may only keep it or give it a
                // proven value; Null survives only being left alone.
                var ok = (fl & NULL_SCAN_LOST) == 0
                if f->state == Nullness::Null {
                    ok = fl == NULL_SCAN_KEPT
                }

                if ok {
                    continue
                }

                f->state = Nullness::Maybe
                f->why   = NullWhy::Looped
                f->at    = if ((fl & NULL_SCAN_LOST) != 0) => (back.at[j]) else => body->range
            }

            var keep = cxx::std::vector<NullFact>()
            for var i: usize = 0; i < self.env.facts.size(); ++i {
                if !self.env.facts[i].global {
                    keep.push_back(self.env.facts[i])
                }
            }

            self.env.facts = keep
            for var i: usize = 0; i < self._escapes.size(); ++i {
                null_env_weaken_under(
                    &self.env,
                    unsafe &self._escapes[i].place,
                    false,
                    NullWhy::Escaped,
                    self._escapes[i].at,
                )
            }
        }

        self._loops.push_back(l)
    }

    /// The loop is done: the join of the states its `break`s left.
    fn loop_leave(self) -> NullEnv {
        var out = self.dead_env()
        if self._loops.size() <= self._loops_base() {
            return out
        }

        var l = self._loops.back()
        self._loops.pop_back()
        for var i: usize = 0; i < l.breaks.size(); ++i {
            out = null_env_join(unsafe &out, unsafe &l.breaks[i])
        }

        return out
    }

    /// `break` (`break label` when \p label is not empty): this state
    /// reaches the end of the loop it leaves. A label naming no loop here
    /// gives it to each (a join only weakens).
    fn on_break(self, const label: string) {
        var base = self._loops_base()
        if self._loops.size() > base {
            if label.size() == 0 {
                self._loops[self._loops.size() - 1].breaks.push_back(self.env)
            } else {
                var found = false
                var i     = self._loops.size()
                while i > base {
                    i = i - 1
                    if self._loops[i].label == label {
                        self._loops[i].breaks.push_back(self.env)
                        found = true
                        break
                    }
                }

                if !found {
                    for var k = base; k < self._loops.size(); ++k {
                        self._loops[k].breaks.push_back(self.env)
                    }
                }
            }
        }

        self.diverge()
    }

    /// Where a `catch` arm starts: after any part of the `try` body (or
    /// value) ran, so a place the body may change anywhere in it (in any
    /// order, NullLoopScan::run_unordered) is Maybe, and so is every global
    /// and escaped place, since any call in it may write one.
    fn try_entry(self, entry: *NullEnv, body: unsafe *Stmt, value: unsafe *Expr) -> NullEnv {
        var out = *entry
        if out.dead {
            return out
        }

        var scan = NullLoopScan()
        scan.sc       = self.sc
        scan.carriers = self._carriers
        var idx = cxx::std::vector<usize>()
        for var i: usize = 0; i < out.facts.size(); ++i {
            if out.facts[i].global || out.facts[i].state == Nullness::Maybe {
                continue
            }

            idx.push_back(i)
            scan.cands.push_back(out.facts[i].place)
        }

        var all = scan.run_unordered(body, value)
        for var j: usize = 0; j < idx.size(); ++j {
            var *f = &out.facts[idx[j]]
            var fl = all.flags[j]
            var ok = (fl & NULL_SCAN_LOST) == 0
            if f->state == Nullness::Null {
                ok = fl == NULL_SCAN_KEPT
            }

            if ok {
                continue
            }

            f->state = Nullness::Maybe
            f->why   = NullWhy::Caught
            f->at    = if ((fl & NULL_SCAN_LOST) != 0) => (all.at[j]) else => f->at
        }

        var keep = cxx::std::vector<NullFact>()
        for var i: usize = 0; i < out.facts.size(); ++i {
            if !out.facts[i].global {
                keep.push_back(out.facts[i])
            }
        }

        out.facts = keep
        for var i: usize = 0; i < self._escapes.size(); ++i {
            null_env_weaken_under(
                &out,
                unsafe &self._escapes[i].place,
                false,
                NullWhy::Escaped,
                self._escapes[i].at,
            )
        }

        return out
    }

    /// The declared type of \p place's last decl, or null.
    priv fn _place_type(self, const place: cxx::std::vector<unsafe *Decl>) -> unsafe *Type {
        if place.size() == 0 {
            return &null
        }

        var unsafe *d = (place)[place.size() - 1]
        if isa<VariableDecl>(d) {
            var unsafe *v = cast<VariableDecl>(d)
            return if (v->type_ != &null) => (v->type_->canonical) else => &null
        }

        if isa<ParamDecl>(d) {
            var unsafe *p = cast<ParamDecl>(d)
            return if (p->type_ != &null) => (p->type_->canonical) else => &null
        }

        if isa<FieldDecl>(d) {
            var unsafe *f = cast<FieldDecl>(d)
            return if (f->type_ != &null) => (f->type_->canonical) else => &null
        }

        return &null
    }

    /// ## uses (§4)

    /// \p e, a use of the nullable \p place, was just typed: remember the
    /// state the place has HERE, for the consumer that may read its value.
    fn note_read(self, e: unsafe *Expr, place: unsafe *cxx::std::vector<unsafe *Decl>) {
        if e == &null || place->size() == 0 {
            return
        }

        self._reads[e as usize as u64] = (self._read_list.size() as u64)
        self._read_list.push_back(self.get(place))
    }

    /// `T?` -> `T` with the nullable's cv (a `const` binding reads `const T`).
    fn narrowed_type(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        var unsafe *x = null_flow_referee(t)
        var unsafe *c = canon_unqual(x)
        if c == &null || !isa<NullableType>(c) {
            return &null
        }

        var unsafe *inner = cast<NullableType>(c)->inner
        var        q      = canon_quals(x)
        if q != 0 {
            return self.sc->types->qualified(inner, q)
        }

        return inner
    }

    /// The consumer of \p e needs its VALUE (§4): a NULL_READ_* state.
    /// NARROWED leaves \p e (through its parentheses) typed `T`; REFUSED
    /// poisons it, and is the answer only when \p must, else NONE.
    fn read_value(self, e: unsafe *Expr, must: bool) -> u8 {
        if e == &null || e->is_poisoned() {
            return NULL_READ_NONE
        }

        var unsafe *x = null_flow_strip_parens(e)
        if x == &null || x->type_ == &null {
            return NULL_READ_NONE
        }

        var it = self._reads.find(x as usize as u64)
        if it == self._reads.end() {
            return NULL_READ_NONE
        }

        var        f   = self._read_list[((it->second) as usize)]
        var unsafe *nt = self.narrowed_type(x->type_)
        if nt == &null {
            return NULL_READ_NONE
        }

        if f.state == Nullness::NonNull {
            if isa<NamedIdentExpr>(x) {
                cast<NamedIdentExpr>(x)->narrowed_from = x->type_
            } else if isa<Expressions::UnaryOperatorExpr>(x) {
                // `*x` through a pointer capture (note_read only records it).
                cast<Expressions::UnaryOperatorExpr>(x)->narrowed_from = x->type_
            } else if isa<ChainExpr>(x) {
                var unsafe *c  = cast<ChainExpr>(x)
                var unsafe *st = c->steps.get(c->steps.size() - 1)
                st->narrowed_from = x->type_
                st->resolved_type = nt
            } else {
                return NULL_READ_NONE
            }

            x->type_ = nt
            var unsafe *p = e
            while p != &null && p != x && isa<Expressions::ParenExpr>(p) {
                p->type_ = nt
                p        = cast<Expressions::ParenExpr>(p)->inner
            }

            return NULL_READ_NARROWED
        }

        if !must {
            return NULL_READ_NONE
        }

        self._refuse(x, f)
        var unsafe *p = e
        while p != &null && p != x && isa<Expressions::ParenExpr>(p) {
            p->poison()
            p = cast<Expressions::ParenExpr>(p)->inner
        }

        return NULL_READ_REFUSED
    }

    /// A `.` / `->` step \p i of \p c reads the value before it, which is
    /// nullable: the base (i == 0) or the field path through step i-1.
    /// Answers as read_value does; NARROWED leaves the narrowed type on the
    /// base node or on step i-1's resolved_type.
    fn read_prefix(self, c: unsafe *ChainExpr, i: usize) -> u8 {
        if i == 0 {
            return self.read_value(c->base, true)
        }

        var place = null_chain_place(c, i - 1)
        if place.size() == 0 {
            return NULL_READ_NONE
        }

        var unsafe *st = c->steps.get(i - 1)
        var unsafe *nt = self.narrowed_type(st->resolved_type)
        if nt == &null {
            return NULL_READ_NONE
        }

        var f = self.get(unsafe &place)
        if f.state == Nullness::NonNull {
            st->narrowed_from = st->resolved_type
            st->resolved_type = nt
            return NULL_READ_NARROWED
        }

        self._refuse_at(c, SourceRange(c->range.start, st->range.end), f, nt)
        return NULL_READ_REFUSED
    }

    /// A `.` / `->` step \p i of \p c reads a nullable that is no place,
    /// and read_prefix left it alone. When the prefix looks like one but
    /// goes through a subscript or a `->` (`xs[i].cache.v`, `p->cache.v`),
    /// say why no check narrows it and what to write instead (true:
    /// reported, \p c poisoned). A call's result (`mk().v`) keeps the plain
    /// "no member" answer: nothing about it suggests a check would hold.
    fn refuse_unplaced(self, c: unsafe *ChainExpr, i: usize) -> bool {
        if c == &null || c->base == &null {
            return false
        }

        var what = ""
        for var k: usize = 0; k < i; ++k {
            if c->steps.get(k)->access_kind == ChainExpr::AccessKind::Arrow {
                what = "'->'"
            }
        }

        var unsafe *x = null_flow_strip_parens(c->base)
        while x != &null && what.size() == 0 {
            if isa<Expressions::SubscriptExpr>(x) {
                what = "a subscript"
                break
            }

            if isa<ChainExpr>(x) {
                var unsafe *cc = cast<ChainExpr>(x)
                for var k: usize = 0; k < cc->steps.size(); ++k {
                    if cc->steps.get(k)->access_kind == ChainExpr::AccessKind::Arrow {
                        what = "'->'"
                    }
                }

                x = null_flow_strip_parens(cc->base)
                continue
            }

            break
        }

        if what.size() == 0 {
            return false
        }

        var end = if (i == 0) => (c->base->range.end) else => c->steps.get(i - 1)->range.end
        var r    = SourceRange(c->range.start, end)
        var text = self.sc->ctx->get_spelling(r)
        var b = self.sc->diag->report(
            DiagID::SC265E,
            r.start,
            f"'{text}' is nullable and no check narrows it: it goes through {what}, which a null check does not follow; copy it to a local ('var c = {text}') and check that",
        )

        b.first(r)
        b.emit()
        c->poison()
        return true
    }

    /// ## the access errors (4.2)

    /// `a`, `o.cache`, `(*x).cache`: how a place is written. A place rooted
    /// at a pointer capture is the dereference, parenthesized so the
    /// suggested `if (*x)?` tests the value and not the pointer.
    fn place_name(self, const place: cxx::std::vector<unsafe *Decl>) -> string {
        var s = ""
        for var i: usize = 0; i < place.size(); ++i {
            if i > 0 {
                s = s + "."
            }

            if i == 0 && self._ptr_captured((place)[0]) {
                s = s + "(*" + self.tu->decl_name((place)[0]) + ")"
                continue
            }

            s = s + self.tu->decl_name((place)[i])
        }

        return s
    }

    priv fn _refuse(self, x: unsafe *Expr, const f: NullFact) {
        self._refuse_at(x, x->range, f, self.narrowed_type(x->type_))
    }

    /// Report (or hold, inside a trap) the read of \p f.place at \p r, and
    /// poison \p x.
    priv fn _refuse_at(self, x: unsafe *Expr, r: SourceRange, f: NullFact, inner: unsafe *Type) {
        x->poison()
        var tb = self._traps_base()
        if self._traps.size() > tb {
            var *t = &self._traps[self._traps.size() - 1]
            var h  = NullHeld{}
            h.e     = x
            h.range = r
            h.fact  = f
            h.on_trap = f.state == Nullness::Maybe
                && null_place_eq(unsafe &f.place, unsafe &t->place)
            t->held.push_back(h)
            return
        }

        self._emit(x, r, f, &null)
    }

    /// The SC001E itself. \p trap, when set, adds the 4.1 fix-it.
    priv fn _emit(self, x: unsafe *Expr, r: SourceRange, f: NullFact, trap: *NullTrap?) {
        var nm  = self.place_name(f.place)
        var msg = f"'{nm}' may be null here; check it with 'if {nm}?' first"
        if f.state == Nullness::Null {
            msg = f"'{nm}' is always null here"
        }

        var b = self.sc->diag->report(DiagID::SC265E, r.start, msg)
        b.first(r)
        if trap != &null {
            b.insert(trap->open_at, "(", "put the use on the checked path")
            b.insert(trap->close_at, ")", "put the use on the checked path")
        }

        var wn = self._why_note(f, nm)
        if wn.msg.size() > 0 {
            if wn.at.is_valid() {
                b.note(wn.at, wn.msg)
            } else {
                b.note(wn.msg)
            }
        }

        if trap != &null {
            b.note(
                f"'&&' binds tighter than '||': the right of '||' runs when '{nm}?' may have failed; parenthesize, or force it with 'unwrap!({nm})'",
            )
        }

        b.emit()
    }

    /// The note saying what made the place what it is: where, and what.
    priv fn _why_note(self, const f: NullFact, const nm: string) -> NullNote {
        var n = NullNote{}
        n.at = f.at.start
        match f.why {
            case NullWhy::Assigned {
                n.msg = if (f.state == Nullness::Null) => (f"'{nm}' is set to null here")
                        else => f"'{nm}' is given a value that may be null here"
                return n
            } case NullWhy::Tested {
                n.msg = f"on this path, the test here found '{nm}' null"
                return n
            } case NullWhy::Called {
                n.msg = f"'{nm}' is global: this call may change it, which ends the check before it"
                if f.place.size() > 0 && self._ptr_captured(f.place[0]) {
                    n.msg = f"'{nm}' is reached through a pointer the closure captured: this call may change it, which ends the check before it"
                }

                return n
            } case NullWhy::Looped {
                n.msg = f"'{nm}' may be changed in the loop here, so it may be null at the top of the loop"
                return n
            } case NullWhy::Inout {
                n.msg = f"this {LangAttrs::quoted(LangAttrs::param_inout())} argument lets the call change '{nm}'"
                return n
            } case NullWhy::MutSelf {
                n.msg = f"this call takes what holds '{nm}' as a mutable 'self', so it may change '{nm}'"
                return n
            } case NullWhy::Caught {
                n.msg = f"'{nm}' may be changed in the 'try' here, before what it catches was thrown"
                return n
            } case NullWhy::Through {
                n.msg = f"'{nm}' may be changed here, through a pointer to it"
                return n
            } case NullWhy::Aliased {
                n.msg = f"this call runs a closure that holds a pointer to '{nm}', so it may change '{nm}'"
                return n
            } case NullWhy::Escaped {
                n.msg = f"a pointer to '{nm}' escapes here; any call after it, or a write through it, may change '{nm}'"
                return n
            } default {
                0
            }
        }

        if f.place.size() == 0 {
            return n
        }

        var unsafe *root = f.place[0]
        if f.place.size() > 1 {
            var unsafe *last = f.place[f.place.size() - 1]
            n.at  = last->range.start
            n.msg = f"'{self.tu->decl_name(last)}' is declared nullable here"
            return n
        }

        n.at = root->range.start
        if self._ptr_captured(root) {
            n.msg = f"'{nm}' is reached through a pointer the closure captured: anything holding that pointer may change it, so it may be null on entry"
            return n
        }

        if self._captured(root) {
            n.msg = f"'{nm}' is captured by the closure: inside it, '{nm}' is as it was where the closure was made, less what the closure assigns it"
            return n
        }

        if isa<ParamDecl>(root) {
            n.msg = f"'{nm}' is a nullable parameter; it may be null on entry"
            return n
        }

        if f.global {
            n.msg = f"'{nm}' is global; it may be null on entry to any function"
            return n
        }

        n.msg = f"'{nm}' is declared nullable here"
        return n
    }

    /// The current body is a closure's and \p d is declared outside it: a
    /// capture. (Locations order within a file; a decl from another file
    /// is outside too.)
    priv fn _captured(self, d: unsafe *Decl) -> bool {
        if self._frames.empty() {
            return false
        }

        var unsafe *c = self._frames.back().closure
        if c == &null || d == &null {
            return false
        }

        var at     = d->range.start.id
        var inside = at >= c->range.start.id && at < c->range.end.id
        return !inside
    }

    /// \p d is a variable a closure around this body captures by pointer,
    /// so the place rooted at it is `*x` (null_place_of). The walk is
    /// ExprTyper::_capture_view's: an inner closure that copies an outer
    /// one's pointer capture holds the pointer too.
    priv fn _ptr_captured(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var at = d->range.start.id
        var i  = self._frames.size()
        while i > 0 {
            i = i - 1
            var unsafe *c = self._frames[i].closure
            if c == &null {
                return false
            }

            if at >= c->range.start.id && at < c->range.end.id {
                return false
            }

            for var k: usize = 0; k < c->captures.size(); ++k {
                var unsafe *cap = c->captures.get(k)
                if !cap->by_ptr {
                    continue
                }

                if cap->name != &null {
                    if cap->name->resolved_decl == d {
                        return true
                    }

                    continue
                }

                if null_flow_is_global(d) || isa<ParamDecl>(d) && cast<ParamDecl>(d)->is_self {
                    continue
                }

                return true
            }
        }

        return false
    }

    /// A place rooted at \p d may be written by code the analysis does not
    /// see, at any call: a global or static (3.8), or `*x` through a pointer
    /// capture, whose variable anything holding a pointer to it may write
    /// while the closure runs (3.7). Such a fact is `global`: every call
    /// makes it Maybe, and a loop or a `try` drops it at its head.
    priv fn _shared(self, d: unsafe *Decl) -> bool {
        return null_flow_is_global(d) || self._ptr_captured(d)
    }

    /// ## the 4.1 trap

    /// The `||` \p n is about to type its right side. When its left side is
    /// an unparenthesized `t && y` whose `t` tests a place present, start
    /// holding the access errors of the right side. True when a trap was
    /// pushed (trap_end() must follow).
    fn trap_begin(self, n: unsafe *Expressions::BinaryOperatorExpr) -> bool {
        var unsafe *l = n->lhs
        if l == &null || !isa<Expressions::BinaryOperatorExpr>(l) {
            return false
        }

        var unsafe *a = cast<Expressions::BinaryOperatorExpr>(l)
        var        k  = a->op_token.kind
        if a->resolved_op != &null || k != TokenKind::OpAmpAmp && k != TokenKind::KwAnd {
            return false
        }

        if a->rhs == &null || n->rhs == &null {
            return false
        }

        var t = null_test_of(a->lhs)
        if t.operand == &null || !t.present {
            return false
        }

        var place = null_place_of(t.operand)
        if place.size() == 0 {
            return false
        }

        // y must not itself decide the place, or the parenthesized form
        // would not leave it NonNull on z's path.
        var yt = null_test_of(a->rhs)
        if yt.operand != &null {
            var yp = null_place_of(yt.operand)
            if null_place_eq(unsafe &yp, unsafe &place) {
                return false
            }
        }

        var tr = NullTrap{}
        tr.place    = place
        tr.open_at  = a->rhs->range.start
        tr.close_at = n->rhs->range.end
        self._traps.push_back(tr)
        return true
    }

    /// The trap's right side is typed. Its held errors are reported now:
    /// with the fix-it when every one of them reads the tested place (then
    /// the parentheses make every use legal), plainly otherwise.
    fn trap_end(self) {
        if self._traps.size() <= self._traps_base() {
            return
        }

        var tr = self._traps.back()
        self._traps.pop_back()
        var all = tr.held.size() > 0
        for var i: usize = 0; i < tr.held.size(); ++i {
            if !tr.held[i].on_trap {
                all = false
            }
        }

        for var i: usize = 0; i < tr.held.size(); ++i {
            var h               = tr.held[i]
            var fix: *NullTrap? = &null
            if all && i == 0 {
                fix = &tr
            }

            // An enclosing trap may hold it again; it was already decided
            // here, so it is emitted.
            self._emit(h.e, h.range, h.fact, fix)
        }
    }
}
