/// --- The Kairo Project --------------------- Sema/Type/NullnessFlow.k --- ///
///
///   \brief The nullness analysis (Compiler/Sema/NULLABLE.md §3, §4, §5):
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
///                              each body starts from nothing known
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
///     Deliberately conservative (batch-B scope; NULLABLE.md G17 refines
///     it):
///       - a place whose root a closure captures by pointer (`|*x|`) is
///         never narrowed;
///       - a closure body starts with nothing known: what it captures is
///         Maybe inside it.
///
///   Phase: TYPE (the analysis, driven by ExprTyper); the classifier is
///   also called by LOWER (NullTestLowering).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h";
ffi "c++" import "llvm/ADT/DenseSet.h";
import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import AST::Context::SymbolTable::*;
import AST::ParamMode::*;
import AST::Kind::StmtKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Location::SourceLocation::*;
import Diagnostic::Registry::*;

/// One classified null test. `operand` is the nullable tested, null when
/// the expression is no null test. `present` is the polarity: true when the
/// expression is true exactly when `operand` holds a value (`x?`,
/// `x != null`), false when it is true exactly when it is null (`!x?`,
/// `x == null`).
struct NullTest {
    var operand: *Expr = &null;
    var present: bool  = true;
}

/// \p e without the parentheses around it.
fn null_flow_strip_parens(e: *Expr) -> *Expr {
    var x = e;
    while (x != &null) && isa::<ParenExpr>(x) { x = cast::<ParenExpr>(x)->inner; }
    return x;
}

/// \p e is the `null` (or `&null`) literal, through parentheses: that
/// literal, else null. Untyped on purpose: OperatorTyping asks before it
/// types the operands, so a `null` against a non-nullable gets the null
/// comparison's error, not the literal's "cannot infer".
fn null_literal_of(e: *Expr) -> *NullLiteralExpr {
    var x = null_flow_strip_parens(e);
    if (x == &null) || (!isa::<NullLiteralExpr>(x)) { return &null; }
    return cast::<NullLiteralExpr>(x);
}

/// \p e has a nullable type, read as a value (a C++ `T?&` is its `T?`).
fn null_flow_is_nullable(e: *Expr) -> bool {
    if (e == &null) || (e->type_ == &null) { return false; }
    var t = e->type_;
    if isa::<CXXLValueRefType>(t)      { t = cast::<CXXLValueRefType>(t)->referee; }
    else if isa::<CXXRValueRefType>(t) { t = cast::<CXXRValueRefType>(t)->referee; }
    var c = canon_unqual(t);
    return (c != &null) && isa::<NullableType>(c);
}

/// The null test \p e is, or one with no operand. See the file header for
/// the spellings.
fn null_test_of(e: *Expr) -> NullTest {
    var out = NullTest{};
    var x = null_flow_strip_parens(e);
    if x == &null { return out; }

    if isa::<UnaryOperatorExpr>(x) {
        var u = cast::<UnaryOperatorExpr>(x);
        if u->resolved_op != &null { return out; }   // a user operator, never the test.
        var k = u->op_token.kind;
        if u->is_postfix() && (k == TokenKind::OpQuestion) {
            if !null_flow_is_nullable(u->operand) { return out; }
            out.operand = u->operand;
            out.present = true;
            return out;
        }
        if u->is_prefix() && ((k == TokenKind::OpExclaim) || (k == TokenKind::KwNot)) {
            var inner = null_test_of(u->operand);
            if inner.operand != &null { inner.present = !inner.present; }
            return inner;
        }
        return out;
    }

    if isa::<BinaryOperatorExpr>(x) {
        var b = cast::<BinaryOperatorExpr>(x);
        if b->resolved_op != &null { return out; }
        var k = b->op_token.kind;
        if (k != TokenKind::OpEqualEqual) && (k != TokenKind::OpExclaimEqual) { return out; }
        var ln = null_literal_of(b->lhs);
        var rn = null_literal_of(b->rhs);
        if (ln != &null) == (rn != &null) { return out; }   // neither, or `null == null`.
        var other = (b->rhs) if (ln != &null) else (b->lhs);
        if !null_flow_is_nullable(other) { return out; }    // `p == &null` on a raw pointer.
        out.operand = other;
        out.present = k == TokenKind::OpExclaimEqual;
        return out;
    }
    return out;
}

// =============================================================================
// The analysis
// =============================================================================

/// What a place is proven to hold (NULLABLE.md 3.1). A place with no fact is
/// Maybe: sound, not complete.
enum Nullness derives u8 {
    Maybe = 0,
    NonNull,
    Null,
}

/// Why a place has its state, for the note on an access error.
enum NullWhy derives u8 {
    None = 0,
    Assigned,     ///< a definition or `=` gave it this value (`at`).
    Tested,       ///< the null test at `at` decided it on this path.
    Called,       ///< a global, after the call at `at`.
    Looped,       ///< assigned at `at` inside the loop whose head this is.
    AddressTaken, ///< its root's address is taken somewhere: never narrowed.
    Inout,        ///< passed `@inout` at `at`: the callee may have written it.
    MutSelf,      ///< a path under the receiver of the mutable-self call at `at`.
    Escaped,      ///< a pointer to it, taken at `at`, is out of the analysis's sight.
}

/// A pointer to \p place, taken by the `&` at \p node (at \p at), that no
/// consumer has accounted for yet: until one does (an `@inout` marker, a
/// `*const` parameter), any call may write through it, and so may any
/// write the analysis cannot place (`*p = ...`).
struct NullEscape {
    var node:  *Expr = &null;
    var place: vec::<*Decl>;
    var at:    SourceRange;
}

/// One fact: \p place holds \p state here.
struct NullFact {
    var place:  vec::<*Decl>;
    var state:  Nullness = Nullness::Maybe;
    var why:    NullWhy  = NullWhy::None;
    var at:     SourceRange;
    var global: bool = false;
}

/// The state at one program point. `dead` is the state after a divergence:
/// unreachable, so a join ignores it, and a read there is allowed.
struct NullEnv {
    var facts: vec::<NullFact>;
    var dead:  bool = false;
}

/// A condition's two sets (3.3): what holds when it is true, when false.
struct NullCond {
    var t: NullEnv;
    var f: NullEnv;
}

/// An access error held back while the right side of a §4.1 trap is
/// typed: whether it gets the parenthesizing fix-it depends on every
/// error the right side has.
struct NullHeld {
    var e:       *Expr = &null;
    var range:   SourceRange;
    var fact:    NullFact;
    var on_trap: bool = false;   ///< it reads the place the trap's `&&` tested.
}

/// `a? && y || z` being typed: z is analysed under the false set of
/// `a? && y`, where `a` is Maybe. Parenthesizing `y || z` puts z on the
/// checked path (4.1).
struct NullTrap {
    var place:    vec::<*Decl>;
    var open_at:  SourceLocation;   ///< the start of y.
    var close_at: SourceLocation;   ///< the end of z.
    var held:     vec::<NullHeld>;
}

/// A note's location (invalid: none) and text.
struct NullNote {
    var at:  SourceLocation;
    var msg: string = "";
}

struct NullFrame {
    var env:        NullEnv;
    var closure:    *ClosureExpr = &null;   ///< the body is this closure's.
    var loops_base: usize = 0;
    var traps_base: usize = 0;
    var escapes:    vec::<NullEscape>;      ///< the enclosing body's, kept for leave().
}

struct NullLoop {
    var breaks: vec::<NullEnv>;
    var label:  string = "";   ///< the loop's label, or empty.
}

/// \p a and \p b name the same place.
fn null_place_eq(a: *vec::<*Decl>, b: *vec::<*Decl>) -> bool {
    if a->size() != b->size() { return false; }
    for var i: usize = 0; i < a->size(); ++i {
        if (*a)[i] != (*b)[i] { return false; }
    }
    return true;
}

/// \p p is \p root or a path under it.
fn null_place_under(p: *vec::<*Decl>, root: *vec::<*Decl>) -> bool {
    if p->size() < root->size() { return false; }
    for var i: usize = 0; i < root->size(); ++i {
        if (*p)[i] != (*root)[i] { return false; }
    }
    return true;
}

/// The join at a merge: the weaker state (3.1).
fn null_join_state(a: Nullness, b: Nullness) -> Nullness {
    if a == b { return a; }
    return Nullness::Maybe;
}

/// The index of \p place's fact in \p env, or -1.
fn null_env_find(env: *NullEnv, place: *vec::<*Decl>) -> i64 {
    for var i: usize = 0; i < env->facts.size(); ++i {
        if null_place_eq(&(env->facts[i].place), place) { return i64(i); }
    }
    return -1;
}

/// \p env with \p f as \p f.place's fact, the old one replaced. Paths under
/// it keep theirs: a test does not change them.
fn null_env_put(env: *NullEnv, f: NullFact) {
    var i = null_env_find(env, &(f.place));
    if i >= 0 { env->facts[usize(i)] = f; return; }
    env->facts.push_back(f);
}

/// Drop the fact of \p place and of every path under it: what an
/// assignment to \p place does to them before it sets its own.
fn null_env_kill_under(env: *NullEnv, place: *vec::<*Decl>) {
    var keep = vec::<NullFact>();
    for var i: usize = 0; i < env->facts.size(); ++i {
        if !null_place_under(&(env->facts[i].place), place) { keep.push_back(env->facts[i]); }
    }
    env->facts = keep;
}

/// The facts of \p place and every path under it (only the paths strictly
/// under it when \p strict) become Maybe, noted \p why at \p at: what a
/// write the analysis cannot see the value of does (3.4). The facts are
/// kept, Maybe, so the access error can say what ended the check.
fn null_env_weaken_under(env: *NullEnv, place: *vec::<*Decl>, strict: bool, why: NullWhy, at: SourceRange) {
    for var i: usize = 0; i < env->facts.size(); ++i {
        var f = &(env->facts[i]);
        if !null_place_under(&(f->place), place) { continue; }
        if strict && (f->place.size() == place->size()) { continue; }
        f->state = Nullness::Maybe;
        f->why   = why;
        f->at    = at;
    }
}

/// The env at a merge of \p a and \p b. A dead side contributes nothing. A
/// place proven on one side only is Maybe after; a Maybe keeps its note.
fn null_env_join(a: *NullEnv, b: *NullEnv) -> NullEnv {
    if a->dead { return *b; }
    if b->dead { return *a; }
    var out = NullEnv{};
    for var i: usize = 0; i < a->facts.size(); ++i {
        var fa = a->facts[i];
        var j = null_env_find(b, &(fa.place));
        if j < 0 {
            if fa.state == Nullness::Maybe { out.facts.push_back(fa); }
            continue;
        }
        var fb = b->facts[usize(j)];
        var st = null_join_state(fa.state, fb.state);
        if st == fa.state { out.facts.push_back(fa); continue; }
        // NonNull against Null, or one side Maybe: Maybe, noted by whichever
        // side says why.
        if fb.state == Nullness::Maybe { out.facts.push_back(fb); continue; }
        var m = fa;
        m.state = Nullness::Maybe;
        m.why   = NullWhy::None;
        out.facts.push_back(m);
    }
    for var i: usize = 0; i < b->facts.size(); ++i {
        var fb = b->facts[i];
        if fb.state != Nullness::Maybe { continue; }
        if null_env_find(a, &(fb.place)) >= 0 { continue; }
        out.facts.push_back(fb);
    }
    return out;
}

/// \p d is a global or a static: a VariableDecl outside every function
/// body, or one declared `static` in one. Any call may write it (3.8).
fn null_flow_is_global(d: *Decl) -> bool {
    if d == &null { return false; }
    if isa::<ParamDecl>(d) { return false; }
    if !isa::<VariableDecl>(d) { return true; }
    if cast::<VariableDecl>(d)->is_static() { return true; }
    // A local is never tabled, so it has no semantic context (ASTParse
    // indexes only scopes with symbol tables); a global sits in its file's
    // or module's.
    var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
    if dc == &null { return false; }
    var k = dc->dc_kind;
    return (k != DeclContextKind::Function) && (k != DeclContextKind::Lambda) && (k != DeclContextKind::Block);
}

/// The decl at the root of the storage \p e names, through parentheses,
/// `.` / `->` chains and subscripts; null when \p e names none (a call, a
/// dereference). Used only for the conservative "this root may be written
/// somewhere" scans.
fn null_root_decl(e: *Expr) -> *Decl {
    var x = null_flow_strip_parens(e);
    while x != &null {
        if isa::<NamedIdentExpr>(x) { return cast::<NamedIdentExpr>(x)->resolved_decl; }
        if isa::<ChainExpr>(x)      { x = null_flow_strip_parens(cast::<ChainExpr>(x)->base); continue; }
        if isa::<SubscriptExpr>(x)  { x = null_flow_strip_parens(cast::<SubscriptExpr>(x)->base); continue; }
        return &null;
    }
    return &null;
}

/// The place \p e names, or an empty one: a local, parameter or global
/// (VariableDecl / ParamDecl), then any number of `.` steps naming
/// instance fields. Syntactic over bound steps; an unbound step (one the
/// typer has not reached yet) ends it.
fn null_place_of(e: *Expr) -> vec::<*Decl> {
    var out = vec::<*Decl>();
    var x = null_flow_strip_parens(e);
    if x == &null { return out; }
    if isa::<NamedIdentExpr>(x) {
        var d = cast::<NamedIdentExpr>(x)->resolved_decl;
        if (d != &null) && (isa::<VariableDecl>(d) || isa::<ParamDecl>(d)) { out.push_back(d); }
        return out;
    }
    if !isa::<ChainExpr>(x) { return out; }
    // (null_chain_place's loop, over every step: Stage 0 resolves free
    // functions in source order, so the two cannot call each other.)
    var c = cast::<ChainExpr>(x);
    if (c->base == &null) || (c->steps.size() == 0) { return out; }
    var root = null_place_of(c->base);
    if root.size() == 0 { return out; }
    for var i: usize = 0; i < c->steps.size(); ++i {
        var st = c->steps.get(i);
        if (st == &null) || (st->access_kind != ChainExpr::AccessKind::Dot) || st->is_operator() || st->is_tuple_index() {
            return vec::<*Decl>();
        }
        var d = st->resolved_decl;
        if (d == &null) || (!isa::<FieldDecl>(d)) || cast::<FieldDecl>(d)->is_static() { return vec::<*Decl>(); }
        root.push_back(d);
    }
    return root;
}

/// The place `c.base` + steps 0..=\p upto names, or an empty one.
fn null_chain_place(c: *ChainExpr, upto: usize) -> vec::<*Decl> {
    var out = vec::<*Decl>();
    if (c->base == &null) || (upto >= c->steps.size()) { return out; }
    var root = null_place_of(c->base);
    if root.size() == 0 { return out; }
    for var i: usize = 0; i <= upto; ++i {
        var st = c->steps.get(i);
        if (st == &null) || (st->access_kind != ChainExpr::AccessKind::Dot) || st->is_operator() || st->is_tuple_index() {
            return vec::<*Decl>();
        }
        var d = st->resolved_decl;
        if (d == &null) || (!isa::<FieldDecl>(d)) || cast::<FieldDecl>(d)->is_static() { return vec::<*Decl>(); }
        root.push_back(d);
    }
    return root;
}

/// \p t is a nullable, read as a value (a C++ `T?&` is its `T?`).
fn null_flow_type_is_nullable(t: *Type) -> bool {
    if t == &null { return false; }
    var x = t;
    if isa::<CXXLValueRefType>(x)      { x = cast::<CXXLValueRefType>(x)->referee; }
    else if isa::<CXXRValueRefType>(x) { x = cast::<CXXRValueRefType>(x)->referee; }
    var c = canon_unqual(x);
    return (c != &null) && isa::<NullableType>(c);
}

/// Every root decl a closure captures by pointer: such a place is never
/// narrowed (batch B's conservative stand-in for 3.7). A `&x` is not here:
/// it is followed where it is typed (NullnessFlow::address_taken).
class NullAddrScan derives RecursiveASTVisitor::<NullAddrScan> {
    pub var out: *llvm::DenseSet::<u64> = &null;

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool {
        if n == &null { return true; }
        for var i: usize = 0; i < n->captures.size(); ++i {
            var c = n->captures.get(i);
            if (!c->by_ptr) || (c->name == &null) || (c->name->resolved_decl == &null) { continue; }
            self.out->insert(reinterpret_cast::<u64>(c->name->resolved_decl));
        }
        return true;
    }
}

/// Every place a `try` body assigns, with where: a `catch` arm may start
/// after any of them, so at its start each is Maybe. A target whose place cannot
/// be named yet (a step after an inferred value is still unbound) is
/// widened to its root, which drops every path under it.
class NullAssignScan derives RecursiveASTVisitor::<NullAssignScan> {
    pub var out: vec::<NullFact>;
    /// Receivers of a method call: every path strictly under each may be
    /// written by a mutable `self` (3.4).
    pub var inside: vec::<NullFact>;

    /// `&e`: the pointer may write `e` (an `@inout` argument, or one kept).
    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if (n == &null) || (!n->is_prefix()) || (n->op_token.kind != TokenKind::OpAmp) { return true; }
        var p = null_place_of(n->operand);
        if p.size() == 0 { return true; }
        var f = NullFact{};
        f.place = p;
        f.why   = NullWhy::Looped;
        f.at    = n->range;
        self.out.push_back(f);
        return true;
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if n == &null { return true; }
        var c = dyn_cast::<ChainExpr>(null_flow_strip_parens(n->callee));
        if (c == &null) || (c->steps.size() == 0) { return true; }
        var k = c->steps.size();
        if c->steps.get(k - 1)->access_kind != ChainExpr::AccessKind::Dot { return true; }
        var p = (null_place_of(c->base)) if (k == 1) else (null_chain_place(c, k - 2));
        if p.size() == 0 { return true; }
        var f = NullFact{};
        f.place = p;
        f.why   = NullWhy::Looped;
        f.at    = n->range;
        self.inside.push_back(f);
        return true;
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if n == &null { return true; }
        var p = null_place_of(n->lhs);
        if p.size() == 0 {
            var d = null_root_decl(n->lhs);
            if (d == &null) || ((!isa::<VariableDecl>(d)) && (!isa::<ParamDecl>(d))) { return true; }
            p.push_back(d);
        }
        var f = NullFact{};
        f.place = p;
        f.state = Nullness::Maybe;
        f.why   = NullWhy::Looped;
        f.at    = n->range;
        self.out.push_back(f);
        return true;
    }
}

// =============================================================================
// The loop pre-scan (3.5)
// =============================================================================

/// What the paths through a loop body may have done to one place, as bits:
/// left it alone, written a value proven non-null, or something else (a
/// `null`, a value that may be null, a write the analysis cannot see).
fn NULL_SCAN_KEPT()  -> u8 { return 1; }
fn NULL_SCAN_VALUE() -> u8 { return 2; }
fn NULL_SCAN_LOST()  -> u8 { return 4; }

/// One path's effect on each candidate place, by index; `at` is where the
/// candidate was last lost on it. A dead path (it returned, broke out, or
/// went back to an outer loop) reaches no back edge.
struct NullScanState {
    var flags: vec::<u8>;
    var at:    vec::<SourceRange>;
    var dead:  bool = false;
}

/// A loop the scan is inside: the scanned loop itself first, then each
/// nested one, with the paths that leave it by `break` and go back to its
/// head by `continue`.
struct NullScanLoop {
    var label:  string = "";
    var breaks: vec::<NullScanState>;
    var conts:  vec::<NullScanState>;
}

/// The merge of two paths: each place may have had what either did to it.
fn null_scan_join(a: *NullScanState, b: *NullScanState) -> NullScanState {
    if a->dead { return *b; }
    if b->dead { return *a; }
    var out = *a;
    for var i: usize = 0; i < out.flags.size(); ++i {
        var lost_a = (a->flags[i] & NULL_SCAN_LOST()) != 0;
        out.flags[i] = a->flags[i] | b->flags[i];
        if (!lost_a) && ((b->flags[i] & NULL_SCAN_LOST()) != 0) { out.at[i] = b->at[i]; }
    }
    return out;
}

/// \p t is a builtin scalar (through a nullable): an operator on it is the
/// builtin one, whose result is never null.
fn null_scan_is_scalar(t: *Type) -> bool {
    if t == &null { return false; }
    var c = canon_unqual(t);
    if (c != &null) && isa::<NullableType>(c) { c = canon_unqual(cast::<NullableType>(c)->inner); }
    return (c != &null) && isa::<BuiltinType>(c);
}

/// The declared type of the decl \p d names, if it is known yet.
fn null_scan_decl_type(d: *Decl) -> *Type {
    if d == &null { return &null; }
    if isa::<VariableDecl>(d) {
        var v = cast::<VariableDecl>(d);
        return (v->type_->canonical) if (v->type_ != &null) else (&null);
    }
    if isa::<ParamDecl>(d) {
        var p = cast::<ParamDecl>(d);
        return (p->type_->canonical) if (p->type_ != &null) else (&null);
    }
    if isa::<FieldDecl>(d) {
        var f = cast::<FieldDecl>(d);
        return (f->type_->canonical) if (f->type_ != &null) else (&null);
    }
    return &null;
}

/// \p f is known to return no nullable: a declared, non-dependent,
/// non-nullable return type (a block body with none returns nothing).
fn null_scan_returns_value(d: *Decl) -> bool {
    if (d == &null) || (!isa::<FunctionDecl>(d)) { return false; }
    var f = cast::<FunctionDecl>(d);
    if f->return_type == &null { return f->body_kind != FnBodyKind::Expr; }
    var t = f->return_type->canonical;
    if (t == &null) || t->is_dependent() { return false; }
    return !null_flow_type_is_nullable(t);
}

/// Every decl \p cell holds returns no nullable.
fn null_scan_cell_returns_value(cell: *OverloadCell) -> bool {
    if (cell == &null) || (cell->size() == 0) { return false; }
    for var i: usize = 0; i < cell->size(); ++i {
        if !null_scan_returns_value(cell->get(i)) { return false; }
    }
    return true;
}

/// \p d is a function with no `@inout` parameter.
fn null_scan_no_inout(d: *Decl) -> bool {
    if (d == &null) || (!isa::<FunctionDecl>(d)) { return false; }
    var f = cast::<FunctionDecl>(d);
    for var i: usize = 0; i < f->params.size(); ++i {
        if (f->params[i] != &null) && (f->params[i]->mode == ParamMode::Inout) { return false; }
    }
    return true;
}

fn null_scan_cell_no_inout(cell: *OverloadCell) -> bool {
    if (cell == &null) || (cell->size() == 0) { return false; }
    for var i: usize = 0; i < cell->size(); ++i {
        if !null_scan_no_inout(cell->get(i)) { return false; }
    }
    return true;
}

/// \p d is a method taking a `const self`.
fn null_scan_const_method(d: *Decl) -> bool {
    if (d == &null) || (!isa::<FunctionDecl>(d)) { return false; }
    var f = cast::<FunctionDecl>(d);
    if !f->is_method() { return false; }
    return f->is_const() || f->params[0]->is_const;
}

fn null_scan_cell_const(cell: *OverloadCell) -> bool {
    if (cell == &null) || (cell->size() == 0) { return false; }
    for var i: usize = 0; i < cell->size(); ++i {
        if !null_scan_const_method(cell->get(i)) { return false; }
    }
    return true;
}

/// \p e, an operand, is known to be a builtin scalar: a numeric, `bool` or
/// character literal, or a place declared as one (or as one's nullable).
fn null_scan_scalar_operand(e: *Expr) -> bool {
    var x = null_flow_strip_parens(e);
    if x == &null { return false; }
    if isa::<IntegerLiteralExpr>(x) || isa::<FloatingLiteralExpr>(x) || isa::<BooleanLiteralExpr>(x) || isa::<CharacterLiteralExpr>(x) { return true; }
    var p = null_place_of(x);
    if p.size() == 0 { return false; }
    return null_scan_is_scalar(null_scan_decl_type(p[p.size() - 1]));
}

/// Read before typing, \p rhs is known to be no null (NULLABLE.md 3.2's
/// rows, on what the syntax and the declarations already say): a literal,
/// `&e`, an initializer, a call to a function declared to return a `T`, a
/// constructor, a place declared `T`, a builtin operator on scalars, a cast
/// to a `T`, an if-expression whose every arm is one. Anything else may be
/// null (false): sound, not complete.
fn null_scan_rhs_value(rhs: *Expr) -> bool {
    var x = null_flow_strip_parens(rhs);
    if x == &null { return false; }
    if isa::<NullLiteralExpr>(x) { return false; }
    if isa::<IntegerLiteralExpr>(x) || isa::<FloatingLiteralExpr>(x) || isa::<BooleanLiteralExpr>(x)
    || isa::<CharacterLiteralExpr>(x) || isa::<StringLiteralExpr>(x) { return true; }
    if isa::<NamedInitializerExpr>(x) || isa::<AnonInitializerExpr>(x) || isa::<ListLiteralExpr>(x)
    || isa::<TupleLiteralExpr>(x) || isa::<SetLiteralExpr>(x) || isa::<MapLiteralExpr>(x) { return true; }
    if isa::<UnaryOperatorExpr>(x) {
        var u = cast::<UnaryOperatorExpr>(x);
        var k = u->op_token.kind;
        if u->is_prefix() && (k == TokenKind::OpAmp) { return true; }
        if u->is_prefix() && ((k == TokenKind::OpMinus) || (k == TokenKind::OpExclaim) || (k == TokenKind::KwNot) || (k == TokenKind::OpTilde)) {
            return null_scan_scalar_operand(u->operand);
        }
        if u->is_postfix() && (k == TokenKind::OpQuestion) { return true; }   // the null test is a bool.
        return false;
    }
    if isa::<BinaryOperatorExpr>(x) {
        var b = cast::<BinaryOperatorExpr>(x);
        var k = b->op_token.kind;
        if (k == TokenKind::OpQuestionQuestion) { return false; }
        if (null_literal_of(b->lhs) != &null) || (null_literal_of(b->rhs) != &null) { return true; }   // `x == null`: a bool.
        return null_scan_scalar_operand(b->lhs) && null_scan_scalar_operand(b->rhs);
    }
    if isa::<TypeCastExpr>(x) {
        var tc = cast::<TypeCastExpr>(x);
        if (tc->target == &null) || (tc->target->canonical == &null) { return false; }
        return !null_flow_type_is_nullable(tc->target->canonical);
    }
    if isa::<IfExpr>(x) {
        var ie = cast::<IfExpr>(x);
        if !null_scan_rhs_value(ie->then_expr) { return false; }
        for var i: usize = 0; i < ie->else_ifs.size(); ++i {
            if !null_scan_rhs_value(ie->else_ifs.get(i)->body) { return false; }
        }
        return null_scan_rhs_value(ie->else_expr);
    }
    if isa::<CallExpr>(x) {
        var callee = null_flow_strip_parens(cast::<CallExpr>(x)->callee);
        if callee == &null { return false; }
        if isa::<NamedIdentExpr>(callee) {
            var id = cast::<NamedIdentExpr>(callee);
            if id->resolved_decl != &null {
                var d = id->resolved_decl;
                if isa::<FunctionDecl>(d) { return null_scan_returns_value(d); }
                // A record's name called is its constructor.
                return isa::<StructDecl>(d) || isa::<ClassDecl>(d);
            }
            return null_scan_cell_returns_value(id->candidate_cell);
        }
        if isa::<ChainExpr>(callee) {
            var c = cast::<ChainExpr>(callee);
            if c->steps.size() == 0 { return false; }
            var st = c->steps.get(c->steps.size() - 1);
            if st->resolved_decl != &null {
                var d = st->resolved_decl;
                if isa::<FunctionDecl>(d) { return null_scan_returns_value(d); }
                return isa::<StructDecl>(d) || isa::<ClassDecl>(d);
            }
            return null_scan_cell_returns_value(st->candidate_cell);
        }
        return false;
    }
    var p = null_place_of(x);
    if p.size() > 0 {
        var t = null_scan_decl_type(p[p.size() - 1]);
        return (t != &null) && (!t->is_dependent()) && (!null_flow_type_is_nullable(t));
    }
    return false;
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
class NullLoopScan derives RecursiveASTVisitor::<NullLoopScan> {
    pub var sc:    *SemaContext = &null;
    pub var cands: vec::<vec::<*Decl>>;
    pub var st:    NullScanState;
    pub var loops: vec::<NullScanLoop>;
    /// > 0: inside a part whose order is not followed; an effect adds to
    /// what a place may have instead of replacing it.
    pub var taint: u32 = 0;
    /// A label waiting for the loop statement it labels.
    pub var pending: string = "";

    fn NullLoopScan(self) { }

    /// The back edge of the loop over \p body (with \p update run after
    /// it), labeled \p label: the join of the end of the body and every
    /// `continue` to it, then the update.
    fn run(self, body: *Stmt, update: *Expr, label: string) -> NullScanState {
        self.st = NullScanState{};
        for var i: usize = 0; i < self.cands.size(); ++i {
            self.st.flags.push_back(NULL_SCAN_KEPT());
            self.st.at.push_back(SourceRange());
        }
        var l = NullScanLoop{};
        l.label = label;
        self.loops.push_back(l);
        if body != &null { self.scan_stmt(body); }
        var back = self.st;
        var top = self.loops.back();
        for var i: usize = 0; i < top.conts.size(); ++i { back = null_scan_join(&back, &(top.conts[i])); }
        self.loops.pop_back();
        if update != &null {
            self.st = back;
            self.scan_expr(update);
            back = self.st;
        }
        return back;
    }

    // --- effects ----------------------------------------------------------------

    priv fn _set(self, i: usize, v: u8, at: SourceRange) {
        if self.st.dead { return; }
        if self.taint > 0 { self.st.flags[i] = self.st.flags[i] | v; }
        else { self.st.flags[i] = v; }
        if v == NULL_SCAN_LOST() { self.st.at[i] = at; }
    }

    /// `q = rhs`: \p q itself takes the value, every path under it is lost.
    priv fn _write(self, q: *vec::<*Decl>, value: bool, at: SourceRange) {
        for var i: usize = 0; i < self.cands.size(); ++i {
            var p = &(self.cands[i]);
            if !null_place_under(p, q) { continue; }
            if p->size() == q->size() { self._set(i, (NULL_SCAN_VALUE()) if (value) else (NULL_SCAN_LOST()), at); }
            else { self._set(i, NULL_SCAN_LOST(), at); }
        }
    }

    /// \p q and every path under it (only those strictly under it, when
    /// \p strict) may hold anything.
    priv fn _lose(self, q: *vec::<*Decl>, strict: bool, at: SourceRange) {
        if q->size() == 0 { return; }
        for var i: usize = 0; i < self.cands.size(); ++i {
            var p = &(self.cands[i]);
            if !null_place_under(p, q) { continue; }
            if strict && (p->size() == q->size()) { continue; }
            self._set(i, NULL_SCAN_LOST(), at);
        }
    }

    /// \p e is a receiver a call may take as mutable `self`.
    priv fn _lose_inside(self, e: *Expr, at: SourceRange) {
        var q = null_place_of(e);
        self._lose(&q, true, at);
    }

    // --- expressions --------------------------------------------------------------

    fn scan_expr(self, e: *Expr) {
        if e != &null { self.dispatch_expr(e); }
    }

    priv fn _tainted(self, e: *Expr) {
        self.taint = self.taint + 1;
        self.scan_expr(e);
        self.taint = self.taint - 1;
    }

    fn visit_closure_expr(self, n: *ClosureExpr) -> bool { return false; }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if n == &null { return false; }
        var k = n->op_token.kind;
        if k == TokenKind::OpColon { self.scan_expr(n->rhs); return false; }   // `f(x: v)`: a named argument.
        self.scan_expr(n->rhs);
        self.scan_expr(n->lhs);
        var q = null_place_of(n->lhs);
        if k != TokenKind::OpEqual {
            // In place: a narrowed place stays what it is; a record's `op +=`
            // may be a mutable `self`.
            if q.size() > 0 { self._lose(&q, true, n->range); }
            return false;
        }
        if q.size() == 0 {
            // A step not bound yet: the whole root may be the target.
            var d = null_root_decl(n->lhs);
            if (d != &null) && (isa::<VariableDecl>(d) || isa::<ParamDecl>(d)) {
                var r = vec::<*Decl>();
                r.push_back(d);
                self._lose(&r, false, n->range);
            }
            return false;
        }
        self._write(&q, null_scan_rhs_value(n->rhs), n->range);
        return false;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if n == &null { return false; }
        var k = n->op_token.kind;
        if n->is_prefix() && (k == TokenKind::OpAmp) {
            var q = null_place_of(n->operand);
            self._lose(&q, false, n->range);
        } else if (k == TokenKind::OpPlusPlus) || (k == TokenKind::OpMinusMinus) {
            var q = null_place_of(n->operand);
            self._lose(&q, true, n->range);
        }
        return true;
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if n == &null { return false; }
        var k = n->op_token.kind;
        self.scan_expr(n->lhs);
        if (k == TokenKind::OpAmpAmp) || (k == TokenKind::KwAnd) || (k == TokenKind::OpPipePipe) || (k == TokenKind::KwOr) || (k == TokenKind::OpQuestionQuestion) {
            self._tainted(n->rhs);   // runs on one outcome only.
            return false;
        }
        self.scan_expr(n->rhs);
        // A record's operator may take its left side as a mutable `self`.
        if (null_literal_of(n->lhs) == &null) && (null_literal_of(n->rhs) == &null) {
            var q = null_place_of(n->lhs);
            if (q.size() > 0) && (!null_scan_is_scalar(null_scan_decl_type(q[q.size() - 1]))) { self._lose(&q, true, n->range); }
        }
        return false;
    }

    fn visit_if_expr(self, n: *IfExpr) -> bool {
        if n == &null { return false; }
        self.scan_expr(n->condition);
        self.taint = self.taint + 1;
        self.scan_expr(n->then_expr);
        for var i: usize = 0; i < n->else_ifs.size(); ++i {
            self.scan_expr(n->else_ifs.get(i)->condition);
            self.scan_expr(n->else_ifs.get(i)->body);
        }
        self.scan_expr(n->else_expr);
        self.taint = self.taint - 1;
        return false;
    }

    fn visit_match_expr(self, n: *MatchExpr) -> bool {
        if n == &null { return false; }
        self.scan_expr(n->scrutinee);
        self.taint = self.taint + 1;
        for var i: usize = 0; i < n->cases.size(); ++i {
            var mc = n->cases.get(i);
            self.scan_expr(mc->guard);
            if mc->body != &null { self.dispatch_stmt(static_cast::<*Stmt>(mc->body)); }
            self.scan_expr(mc->expression);
        }
        self.taint = self.taint - 1;
        return false;
    }

    fn visit_try_catch_expr(self, n: *TryCatchExpr) -> bool {
        if n == &null { return false; }
        self.taint = self.taint + 1;
        self.scan_expr(n->try_expr);
        for var i: usize = 0; i < n->catch_arms.size(); ++i { self.scan_expr(n->catch_arms.get(i)->body); }
        self.taint = self.taint - 1;
        return false;
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if n == &null { return false; }
        self.scan_expr(n->callee);
        for var i: usize = 0; i < n->args.size(); ++i { self.scan_expr(n->args[i]); }
        var callee = null_flow_strip_parens(n->callee);
        // An unmarked argument to `@inout` binds (warned): unless no
        // candidate has an `@inout` parameter, a place passed may be written.
        if self._may_inout(callee) {
            for var i: usize = 0; i < n->args.size(); ++i {
                var a = n->args[i];
                var v = named_call_arg_value(a);
                if v != &null { a = v; }
                var q = null_place_of(a);
                self._lose(&q, false, n->range);
            }
        }
        // A method taking a mutable `self` may write any field of its receiver.
        if (callee != &null) && isa::<ChainExpr>(callee) {
            var c = cast::<ChainExpr>(callee);
            var k = c->steps.size();
            if k > 0 {
                var last = c->steps.get(k - 1);
                var known_const = (null_scan_const_method(last->resolved_decl)) if (last->resolved_decl != &null) else (null_scan_cell_const(last->candidate_cell));
                if (last->access_kind == ChainExpr::AccessKind::Dot) && (!known_const) {
                    var q = (null_place_of(c->base)) if (k == 1) else (null_chain_place(c, k - 2));
                    self._lose(&q, true, n->range);
                }
            }
        }
        return false;
    }

    /// The call through \p callee may take an argument `@inout`.
    priv fn _may_inout(self, callee: *Expr) -> bool {
        if callee == &null { return true; }
        if isa::<NamedIdentExpr>(callee) {
            var id = cast::<NamedIdentExpr>(callee);
            var d = id->resolved_decl;
            if d == &null { return !null_scan_cell_no_inout(id->candidate_cell); }
            if isa::<FunctionDecl>(d) { return !null_scan_no_inout(d); }
            var t = null_scan_decl_type(d);
            if (t != &null) && isa::<FunctionPointerType>(canon_unqual(t)) {
                var fp = cast::<FunctionPointerType>(canon_unqual(t));
                for var i: usize = 0; i < fp->modes.size(); ++i { if fp->modes[i] == ParamMode::Inout { return true; } }
                return false;
            }
            return true;
        }
        if isa::<ChainExpr>(callee) {
            var c = cast::<ChainExpr>(callee);
            if c->steps.size() == 0 { return true; }
            var st = c->steps.get(c->steps.size() - 1);
            if st->resolved_decl != &null { return !null_scan_no_inout(st->resolved_decl); }
            return !null_scan_cell_no_inout(st->candidate_cell);
        }
        return true;
    }

    // --- statements ---------------------------------------------------------------

    /// The loop a `break` / `continue` with \p label (empty: none) leaves,
    /// as an index into `loops`; -1 when it leaves the scanned loop's
    /// enclosing ones.
    priv fn _target(self, has_label: bool, label: Token) -> i64 {
        if self.loops.size() == 0 { return -1; }
        if !has_label { return i64(self.loops.size() - 1); }
        var nm = self.sc->ctx->get_spelling(label);
        var i = self.loops.size();
        while i > 0 {
            i = i - 1;
            if self.loops[i].label == nm { return i64(i); }
        }
        return -1;
    }

    priv fn _take_label(self) -> string {
        var l = self.pending;
        self.pending = "";
        return l;
    }

    /// A loop nested in the scanned body: one pass over \p body from the
    /// state before it, its head the join of that and the back edge (one
    /// pass is enough: an effect is a constant or nothing, so a second pass
    /// adds no path), the state after it the head (\p may_skip: the
    /// condition, or an exhausted range) joined with every `break`.
    priv fn _nested(self, cond: *Expr, body: *Stmt, update: *Expr, may_skip: bool) {
        var l = NullScanLoop{};
        l.label = self._take_label();
        self.loops.push_back(l);
        var s0 = self.st;
        if cond != &null { self.scan_expr(cond); }
        if body != &null { self.scan_stmt(body); }
        var back = self.st;
        var me = self.loops.back();
        for var i: usize = 0; i < me.conts.size(); ++i { back = null_scan_join(&back, &(me.conts[i])); }
        if update != &null {
            self.st = back;
            self.scan_expr(update);
            back = self.st;
        }
        var head = null_scan_join(&s0, &back);
        self.st = head;
        if cond != &null { self.scan_expr(cond); }
        me = self.loops.back();
        self.loops.pop_back();
        var after = self.st;
        if !may_skip {
            after = NullScanState{};
            after.dead = true;
            if me.breaks.size() > 0 { after = back; }
        }
        for var i: usize = 0; i < me.breaks.size(); ++i { after = null_scan_join(&after, &(me.breaks[i])); }
        self.st = after;
    }

    fn scan_stmt(self, s: *Stmt) {
        if s == &null { return; }
        switch s->kind {
            case StmtKind::CompoundStmt {
                var c = cast::<CompoundStmt>(s);
                for var i: usize = 0; i < c->body.size(); ++i { self.scan_stmt(c->body[i]); }
            }
            case StmtKind::ExpressionStmt { self.scan_expr(cast::<ExpressionStmt>(s)->expr); }
            case StmtKind::DeclStmt {
                var d = cast::<DeclStmt>(s)->decl;
                if (d != &null) && isa::<VariableDecl>(d) { self.scan_expr(cast::<VariableDecl>(d)->init); }
            }
            case StmtKind::ReturnStmt {
                self.scan_expr(cast::<ReturnStmt>(s)->value);
                self.st.dead = true;
            }
            case StmtKind::PanicStmt {
                self.scan_expr(cast::<PanicStmt>(s)->payload);
                self.st.dead = true;
            }
            case StmtKind::BreakStmt {
                var b = cast::<BreakStmt>(s);
                var t = self._target(b->has_label, b->label);
                if (t >= 0) && (!self.st.dead) { self.loops[usize(t)].breaks.push_back(self.st); }
                self.st.dead = true;
            }
            case StmtKind::ContinueStmt {
                var c = cast::<ContinueStmt>(s);
                var t = self._target(c->has_label, c->label);
                if (t >= 0) && (!self.st.dead) { self.loops[usize(t)].conts.push_back(self.st); }
                self.st.dead = true;
            }
            case StmtKind::ConditionalStmt {
                var c = cast::<ConditionalStmt>(s);
                self.scan_expr(c->cond);
                var s0 = self.st;
                if c->then_ != &null { self.scan_stmt(static_cast::<*Stmt>(c->then_)); }
                var s1 = self.st;
                self.st = s0;
                if c->else_ != &null { self.scan_stmt(c->else_); }
                self.st = null_scan_join(&s1, &(self.st));
            }
            case StmtKind::WhileLoopStmt {
                var w = cast::<WhileLoopStmt>(s);
                self._nested(w->cond, static_cast::<*Stmt>(w->body), &null, true);
            }
            case StmtKind::LoopStmt {
                self._nested(&null, static_cast::<*Stmt>(cast::<LoopStmt>(s)->body), &null, false);
            }
            case StmtKind::IndexedForStmt {
                var f = cast::<IndexedForStmt>(s);
                var lbl = self._take_label();
                if f->init != &null { self.scan_stmt(f->init); }
                self.pending = lbl;
                self._nested(f->cond, static_cast::<*Stmt>(f->body), f->update, true);
            }
            case StmtKind::RangedForStmt {
                var f = cast::<RangedForStmt>(s);
                var lbl = self._take_label();
                self.scan_expr(f->iterable);
                self.pending = lbl;
                self._nested(&null, static_cast::<*Stmt>(f->body), &null, true);
            }
            case StmtKind::MatchStmt {
                var m = cast::<MatchStmt>(s);
                self.scan_expr(m->scrutinee);
                var s0 = self.st;
                var acc = s0;
                for var i: usize = 0; i < m->cases.size(); ++i {
                    var mc = m->cases.get(i);
                    self.st = s0;
                    self.scan_expr(mc->guard);
                    if mc->body != &null { self.scan_stmt(static_cast::<*Stmt>(mc->body)); }
                    self.scan_expr(mc->expression);
                    acc = null_scan_join(&acc, &(self.st));
                }
                self.st = acc;
            }
            case StmtKind::LabeledStmt {
                var l = cast::<LabeledStmt>(s);
                self.pending = self.sc->ctx->get_spelling(l->label);
                self.scan_stmt(l->inner);
                self.pending = "";
            }
            case StmtKind::TryCatchStmt {
                // A catch arm may start after any part of the body ran: from
                // everything the body may have done along the way.
                var t = cast::<TryCatchStmt>(s);
                var s0 = self.st;
                if t->try_body != &null { self.scan_stmt(static_cast::<*Stmt>(t->try_body)); }
                var end = self.st;
                self.st = s0;
                self.taint = self.taint + 1;
                if t->try_body != &null { self.dispatch_stmt(static_cast::<*Stmt>(t->try_body)); }
                self.taint = self.taint - 1;
                var entry = self.st;
                entry.dead = s0.dead;
                var acc = end;
                for var i: usize = 0; i < t->arms.size(); ++i {
                    self.st = entry;
                    var arm = t->arms.get(i);
                    if arm->body != &null { self.scan_stmt(static_cast::<*Stmt>(arm->body)); }
                    acc = null_scan_join(&acc, &(self.st));
                }
                self.st = acc;
            }
            case StmtKind::UnsafeBlockStmt {
                var u = cast::<UnsafeBlockStmt>(s);
                if u->body != &null { self.scan_stmt(static_cast::<*Stmt>(u->body)); }
            }
            default {
                // Anything else (`finally`, `with`, a destructuring, `yield`,
                // an assert): its effects, in no particular order.
                self.taint = self.taint + 1;
                self.dispatch_stmt(s);
                self.taint = self.taint - 1;
            }
        }
    }
}

class NullnessFlow {
    pub var sc: *SemaContext = &null;
    pub var tu: *TypeUtil    = &null;
    /// The state here. Mixins read and replace it around branches.
    pub var env: NullEnv;

    priv var _frames: vec::<NullFrame>;
    priv var _loops:  vec::<NullLoop>;
    priv var _traps:  vec::<NullTrap>;
    priv var _addr:   llvm::DenseSet::<u64>;
    /// The pointers taken in this body that may still be written through.
    priv var _escapes: vec::<NullEscape>;
    /// A label waiting for the loop statement it labels (label_next).
    priv var _label: string = "";
    /// expr -> index in _read_list: the fact its place had where it was written.
    priv var _reads:     llvm::DenseMap::<u64, usize>;
    priv var _read_list: vec::<NullFact>;
    /// `&&` / `||` node -> index in _cond_list: its sets, stored as typed.
    priv var _conds:     llvm::DenseMap::<u64, usize>;
    priv var _cond_list: vec::<NullCond>;

    fn NullnessFlow(self) { }

    fn NullnessFlow(self, sc: *SemaContext, tu: *TypeUtil) {
        self.sc = sc;
        self.tu = tu;
    }

    /// The address-taken pre-scan, once over the TU before anything is typed.
    fn scan(self, tu: *TranslationUnit) {
        if (tu == &null) || (tu->program == &null) { return; }
        var s = NullAddrScan();
        s.out = &(self._addr);
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { s.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { s.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { s.dispatch_expr(item.as_expr()); }
            }
        }
    }

    // --- frames ---------------------------------------------------------------

    /// A function or closure (\p closure) body begins: nothing is known in
    /// it. The enclosing body's state is kept for leave().
    fn enter(self, closure: *ClosureExpr = &null) {
        var fr = NullFrame{};
        fr.closure    = closure;
        fr.env        = self.env;
        fr.loops_base = self._loops.size();
        fr.traps_base = self._traps.size();
        fr.escapes    = self._escapes;
        self._frames.push_back(fr);
        self.env = NullEnv{};
        self._escapes = vec::<NullEscape>();
    }

    fn leave(self) {
        if self._frames.empty() { return; }
        var fr = self._frames.back();
        self._frames.pop_back();
        self.env = fr.env;
        self._escapes = fr.escapes;
        while self._loops.size() > fr.loops_base { self._loops.pop_back(); }
        while self._traps.size() > fr.traps_base { self._traps.pop_back(); }
    }

    priv fn _loops_base(self) -> usize {
        if self._frames.empty() { return 0; }
        return self._frames.back().loops_base;
    }

    priv fn _traps_base(self) -> usize {
        if self._frames.empty() { return 0; }
        return self._frames.back().traps_base;
    }

    // --- the state ------------------------------------------------------------

    /// \p place's fact here. An address-taken root is never narrowed, and
    /// unreachable code reads every place as NonNull (nothing runs there).
    fn get(self, place: *vec::<*Decl>) -> NullFact {
        var f = NullFact{};
        f.place = *place;
        if place->size() == 0 { return f; }
        f.global = null_flow_is_global((*place)[0]);
        if self._addr.contains(reinterpret_cast::<u64>((*place)[0])) { f.why = NullWhy::AddressTaken; return f; }
        if self.env.dead { f.state = Nullness::NonNull; return f; }
        var i = null_env_find(&(self.env), place);
        if i >= 0 { return self.env.facts[usize(i)]; }
        return f;
    }

    /// The env merged with \p other (3.1).
    fn join(self, a: *NullEnv, b: *NullEnv) -> NullEnv { return null_env_join(a, b); }

    /// An env no path reaches.
    fn dead_env(self) -> NullEnv {
        var e = NullEnv{};
        e.dead = true;
        return e;
    }

    /// `return`, `break`, `continue`, `panic`, a `-> !` call: nothing after
    /// it runs on this path (3.3, early exit).
    fn diverge(self) { self.env = self.dead_env(); }

    /// \p place, and every path under it, may now hold anything (3.4): it
    /// was passed `@inout`, or a pointer to it was written through. Noted
    /// \p why at \p at. A nullable place with no fact gets a Maybe one, so
    /// the access error names this write rather than the declaration.
    fn weaken(self, place: *vec::<*Decl>, why: NullWhy, at: SourceRange) {
        if self.env.dead || (place->size() == 0) { return; }
        null_env_weaken_under(&(self.env), place, false, why, at);
        if (null_env_find(&(self.env), place) < 0) && null_flow_type_is_nullable(self._place_type(place)) {
            var f = NullFact{};
            f.place  = *place;
            f.why    = why;
            f.at     = at;
            f.global = null_flow_is_global((*place)[0]);
            self.env.facts.push_back(f);
        }
    }

    /// Every path strictly under \p place may now hold anything, \p place
    /// itself not: a call took it as mutable `self` (3.4), which can write
    /// its fields but not make the value itself null.
    fn weaken_inside(self, place: *vec::<*Decl>, at: SourceRange) {
        if self.env.dead || (place->size() == 0) { return; }
        null_env_weaken_under(&(self.env), place, true, NullWhy::MutSelf, at);
    }

    /// `&e`, typed: \p n, a `*T` to \p pointee. Until a consumer accounts
    /// for the pointer (unescape), it may be kept anywhere, so any call or
    /// unplaced write may write \p e's place through it (3.4, 3.7). A
    /// `*const T` cannot write and is not followed.
    fn address_taken(self, n: *UnaryOperatorExpr, pointee: *Type) {
        if (n == &null) || ((pointee != &null) && canon_has_const(pointee)) { return; }
        // `&xs[i]`, `&p->f`: no place, so no fact it could change (what `p`
        // points at is already followed, by the `&` that made `p`).
        var place = null_place_of(n->operand);
        if place.size() == 0 { return; }
        var esc = NullEscape{};
        esc.node  = static_cast::<*Expr>(n);
        esc.place = place;
        esc.at    = n->range;
        self._escapes.push_back(esc);
    }

    /// The pointer \p node made is accounted for: it was the `@inout`
    /// marker (whose write the call weakens itself) or went to a `*const`.
    fn unescape(self, node: *Expr) {
        var keep = vec::<NullEscape>();
        for var i: usize = 0; i < self._escapes.size(); ++i {
            if self._escapes[i].node != node { keep.push_back(self._escapes[i]); }
        }
        self._escapes = keep;
    }

    /// \p arg is an argument to an `@inout` parameter, written with the
    /// marker \p marker (null: unmarked): the callee may write it (3.4).
    /// The marker's pointer goes nowhere else, so it is no escape.
    fn inout_arg(self, arg: *Expr, marker: *Expr) {
        if marker != &null { self.unescape(marker); }
        if arg == &null { return; }
        var place = null_place_of(arg);
        // `bump(&p->n)`: the write lands wherever `p` points.
        if place.size() == 0 { self.write_through(); return; }
        self.weaken(&place, NullWhy::Inout, arg->range);
    }

    /// \p arg is passed to a parameter of type \p pt. A `&e` to a `*const`
    /// parameter cannot write \p e: its pointer is no escape.
    fn pass_pointer(self, arg: *Expr, pt: *Type) {
        var x = null_flow_strip_parens(arg);
        if (x == &null) || (!isa::<UnaryOperatorExpr>(x)) || (pt == &null) { return; }
        var u = cast::<UnaryOperatorExpr>(x);
        if (!u->is_prefix()) || (u->op_token.kind != TokenKind::OpAmp) || u->is_mode_marker { return; }
        var c = canon_unqual(pt);
        if (c == &null) || (!isa::<PointerType>(c)) { return; }
        if canon_has_const(cast::<PointerType>(c)->pointee) { self.unescape(x); }
    }

    /// The call \p callee (a chain whose last step is a method taking a
    /// mutable `self`) may write any field of its receiver (3.4): every
    /// path under the receiver's place is Maybe after it. A receiver that is
    /// no place (`(*p).m()`, `p->m()`) is wherever a pointer points.
    fn mutable_self_call(self, callee: *ChainExpr, at: SourceRange) {
        if (callee == &null) || (callee->steps.size() == 0) { return; }
        var k = callee->steps.size();
        var last = callee->steps.get(k - 1);
        var place = vec::<*Decl>();
        if last->access_kind == ChainExpr::AccessKind::Dot {
            place = (null_place_of(callee->base)) if (k == 1) else (null_chain_place(callee, k - 2));
        }
        if place.size() == 0 { self.write_through(); return; }
        self.weaken_inside(&place, at);
    }

    /// \p lhs is written in place (`a += b`, `++a`): a place keeps what it
    /// holds (a narrowed one is written through its value); anything else
    /// is a write the analysis cannot place.
    fn modified(self, lhs: *Expr) {
        if lhs == &null { return; }
        var place = null_place_of(lhs);
        if place.size() == 0 { self.write_through(); }
    }

    /// The user operator \p fd ran with \p operand as its receiver (its
    /// left side): a method taking a mutable `self` may write any field of
    /// it, as mutable_self_call.
    fn operator_call(self, fd: *Decl, operand: *Expr, at: SourceRange) {
        if (fd == &null) || (!isa::<FunctionDecl>(fd)) { return; }
        var f = cast::<FunctionDecl>(fd);
        if (!f->is_method()) || f->is_const() || f->params[0]->is_const { return; }
        var place = null_place_of(operand);
        if place.size() == 0 { self.write_through(); return; }
        self.weaken_inside(&place, at);
    }

    /// A write the analysis cannot place (`*p = v`, `p->f = v`, `xs[i] += 1`):
    /// it may land in any place a pointer was taken to.
    fn write_through(self) {
        if self.env.dead { return; }
        for var i: usize = 0; i < self._escapes.size(); ++i {
            var e = &(self._escapes[i]);
            null_env_weaken_under(&(self.env), &(e->place), false, NullWhy::Escaped, e->at);
        }
    }

    /// A call ran: it may have written any global (3.8), and any place a
    /// pointer was taken to (3.7). Their facts become Maybe, a global's
    /// noted at \p at, an escaped place's at its `&`.
    fn after_call(self, at: SourceRange) {
        if self.env.dead { return; }
        for var i: usize = 0; i < self.env.facts.size(); ++i {
            if !self.env.facts[i].global { continue; }
            self.env.facts[i].state = Nullness::Maybe;
            self.env.facts[i].why   = NullWhy::Called;
            self.env.facts[i].at    = at;
        }
        self.write_through();
    }

    // --- definitions and assignments (3.2) ------------------------------------

    /// The state a nullable takes from the value \p rhs it is given: `null`
    /// is Null; any non-nullable value (a `T` converted, `&e`, a narrowed
    /// read) is NonNull; a nullable place passes its own state on; anything
    /// else (a call returning `T?`) is Maybe.
    fn value_state(self, rhs: *Expr, at: SourceRange) -> NullFact {
        var f = NullFact{};
        f.why = NullWhy::Assigned;
        f.at  = at;
        var x = null_flow_strip_parens(rhs);
        if x == &null { return f; }
        if isa::<NullLiteralExpr>(x) { f.state = Nullness::Null; return f; }
        if x->type_ == &null { return f; }
        if !null_flow_type_is_nullable(x->type_) { f.state = Nullness::NonNull; return f; }
        var it = self._reads.find(reinterpret_cast::<u64>(x));
        if it != self._reads.end() { f.state = self._read_list[it->second].state; }
        return f;
    }

    /// `var v ... = init` (or none: a `T?` defaults to null) for a local
    /// whose type is nullable. Globals and statics are never defined here:
    /// each function sees them Maybe (3.8).
    fn define(self, v: *VariableDecl) {
        if (v == &null) || v->is_poisoned() || (v->type_ == &null) { return; }
        if !null_flow_type_is_nullable(v->type_->canonical) { return; }
        if null_flow_is_global(static_cast::<*Decl>(v)) { return; }
        var f = NullFact{};
        if v->init == &null {
            f.state = Nullness::Null;
            f.why   = NullWhy::Assigned;
            f.at    = v->range;
        } else {
            f = self.value_state(v->init, v->range);
        }
        f.place.push_back(static_cast::<*Decl>(v));
        self._set(f);
    }

    /// `lhs = rhs`, typed. A nullable place takes \p rhs's state; any place
    /// loses the facts under it (`o = make()` forgets `o.cache`).
    fn assign(self, lhs: *Expr, rhs: *Expr, at: SourceRange) {
        var place = null_place_of(lhs);
        if place.size() == 0 { self.write_through(); return; }
        var x = null_flow_strip_parens(lhs);
        if (x != &null) && null_flow_type_is_nullable(x->type_) {
            var f = self.value_state(rhs, at);
            f.place = place;
            self._set(f);
            return;
        }
        if !self.env.dead { null_env_kill_under(&(self.env), &place); }
    }

    priv fn _set(self, f_in: NullFact) {
        if self.env.dead { return; }
        var f = f_in;
        f.global = null_flow_is_global(f.place[0]);
        null_env_kill_under(&(self.env), &(f.place));
        if (f.state == Nullness::Maybe) && (f.why == NullWhy::None) { return; }
        self.env.facts.push_back(f);
    }

    // --- conditions (3.3) -----------------------------------------------------

    /// \p e's true and false sets, \p e typed. A null test on a place
    /// narrows it each way; `!` swaps; `&&` / `||` answer what they stored
    /// while typed; `true` / `false` make one side unreachable; anything
    /// else refines nothing.
    fn cond_of(self, e: *Expr) -> NullCond {
        var c = NullCond{};
        c.t = self.env;
        c.f = self.env;
        var x = null_flow_strip_parens(e);
        if x == &null { return c; }
        var it = self._conds.find(reinterpret_cast::<u64>(x));
        if it != self._conds.end() { return self._cond_list[it->second]; }

        var nt = null_test_of(x);
        if nt.operand != &null {
            var place = null_place_of(nt.operand);
            if (place.size() == 0) || self.env.dead { return c; }
            if self._addr.contains(reinterpret_cast::<u64>(place[0])) { return c; }
            var yes = NullFact{};
            yes.place  = place;
            yes.state  = Nullness::NonNull;
            yes.why    = NullWhy::Tested;
            yes.at     = x->range;
            yes.global = null_flow_is_global(place[0]);
            var no = yes;
            no.state = Nullness::Null;
            if nt.present {
                null_env_put(&(c.t), yes);
                null_env_put(&(c.f), no);
            } else {
                null_env_put(&(c.t), no);
                null_env_put(&(c.f), yes);
            }
            return c;
        }
        if isa::<UnaryOperatorExpr>(x) {
            var u = cast::<UnaryOperatorExpr>(x);
            var k = u->op_token.kind;
            if (u->resolved_op == &null) && u->is_prefix() && ((k == TokenKind::OpExclaim) || (k == TokenKind::KwNot)) {
                var inner = self.cond_of(u->operand);
                var sw = NullCond{};
                sw.t = inner.f;
                sw.f = inner.t;
                return sw;
            }
            return c;
        }
        if isa::<BooleanLiteralExpr>(x) {
            if cast::<BooleanLiteralExpr>(x)->value { c.f = self.dead_env(); } else { c.t = self.dead_env(); }
            return c;
        }
        return c;
    }

    /// Record \p e's sets (an `&&` / `||`, computed while it was typed).
    fn store_cond(self, e: *Expr, c: NullCond) {
        self._conds[reinterpret_cast::<u64>(e)] = self._cond_list.size();
        self._cond_list.push_back(c);
    }

    // --- loops (3.5, conservatively) ------------------------------------------

    /// The next loop statement is labeled \p name (`outer: while ...`).
    fn label_next(self, name: string) { self._label = name; }

    /// The head of a loop over \p body, with \p update (a `for`'s) run on
    /// the back edge after it (3.5). The body is typed once, from here, so
    /// the state here must hold on every back edge too: a place proven here
    /// stays proven only when no path through the body (and the update)
    /// may bring it back holding anything else (NullLoopScan), and a
    /// global or an escaped place never does, since any call may write it.
    /// The condition is typed after this, at the head, so `while x?`
    /// proves `x` at the top of the body whatever the body does to it.
    fn loop_enter(self, body: *Stmt, update: *Expr) {
        var l = NullLoop{};
        l.label = self._label;
        self._label = "";
        if !self.env.dead {
            var scan = NullLoopScan();
            scan.sc = self.sc;
            var idx = vec::<usize>();
            for var i: usize = 0; i < self.env.facts.size(); ++i {
                var f = &(self.env.facts[i]);
                if f->global || (f->state == Nullness::Maybe) { continue; }
                idx.push_back(i);
                scan.cands.push_back(f->place);
            }
            var back = scan.run(body, update, l.label);
            for var j: usize = 0; j < idx.size(); ++j {
                if back.dead { break; }
                var f = &(self.env.facts[idx[j]]);
                var fl = back.flags[j];
                // NonNull survives what may only keep it or give it a
                // proven value; Null survives only being left alone.
                var ok = (fl & NULL_SCAN_LOST()) == 0;
                if f->state == Nullness::Null { ok = fl == NULL_SCAN_KEPT(); }
                if ok { continue; }
                f->state = Nullness::Maybe;
                f->why   = NullWhy::Looped;
                f->at    = (back.at[j]) if ((fl & NULL_SCAN_LOST()) != 0) else (body->range);
            }
            var keep = vec::<NullFact>();
            for var i: usize = 0; i < self.env.facts.size(); ++i {
                if !self.env.facts[i].global { keep.push_back(self.env.facts[i]); }
            }
            self.env.facts = keep;
            for var i: usize = 0; i < self._escapes.size(); ++i {
                null_env_weaken_under(&(self.env), &(self._escapes[i].place), false, NullWhy::Escaped, self._escapes[i].at);
            }
        }
        self._loops.push_back(l);
    }

    /// The loop is done: the join of the states its `break`s left.
    fn loop_leave(self) -> NullEnv {
        var out = self.dead_env();
        if self._loops.size() <= self._loops_base() { return out; }
        var l = self._loops.back();
        self._loops.pop_back();
        for var i: usize = 0; i < l.breaks.size(); ++i { out = null_env_join(&out, &(l.breaks[i])); }
        return out;
    }

    /// `break` (`break label` when \p label is not empty): this state
    /// reaches the end of the loop it leaves. A label naming no loop here
    /// gives it to each (a join only weakens).
    fn on_break(self, label: string) {
        var base = self._loops_base();
        if self._loops.size() > base {
            if label.size() == 0 {
                self._loops[self._loops.size() - 1].breaks.push_back(self.env);
            } else {
                var found = false;
                var i = self._loops.size();
                while i > base {
                    i = i - 1;
                    if self._loops[i].label == label {
                        self._loops[i].breaks.push_back(self.env);
                        found = true;
                        break;
                    }
                }
                if !found {
                    for var k = base; k < self._loops.size(); ++k { self._loops[k].breaks.push_back(self.env); }
                }
            }
        }
        self.diverge();
    }

    /// Where a `catch` arm starts: anything the `try` body (or value)
    /// assigns may have happened before it threw, and so may any call
    /// (globals).
    fn try_entry(self, entry: *NullEnv, body: *Stmt, value: *Expr) -> NullEnv {
        var saved = self.env;
        self.env = *entry;
        self._weaken_assigned(body, value, &null);
        var out = self.env;
        self.env = saved;
        return out;
    }

    priv fn _weaken_assigned(self, body: *Stmt, e1: *Expr, e2: *Expr) {
        if self.env.dead { return; }
        var s = NullAssignScan();
        if body != &null { s.dispatch_stmt(body); }
        if e1 != &null { s.dispatch_expr(e1); }
        if e2 != &null { s.dispatch_expr(e2); }
        for var i: usize = 0; i < s.out.size(); ++i {
            var f = s.out[i];
            null_env_kill_under(&(self.env), &(f.place));
            if null_flow_type_is_nullable(self._place_type(&(f.place))) { self.env.facts.push_back(f); }
        }
        for var i: usize = 0; i < s.inside.size(); ++i {
            null_env_weaken_under(&(self.env), &(s.inside[i].place), true, NullWhy::Looped, s.inside[i].at);
        }
        // Any call or unplaced write in the loop may write through a pointer
        // taken before it.
        for var i: usize = 0; i < self._escapes.size(); ++i {
            null_env_weaken_under(&(self.env), &(self._escapes[i].place), false, NullWhy::Escaped, self._escapes[i].at);
        }
        var keep = vec::<NullFact>();
        for var i: usize = 0; i < self.env.facts.size(); ++i {
            if !self.env.facts[i].global { keep.push_back(self.env.facts[i]); }
        }
        self.env.facts = keep;
    }

    /// The declared type of \p place's last decl, or null.
    priv fn _place_type(self, place: *vec::<*Decl>) -> *Type {
        if place->size() == 0 { return &null; }
        var d = (*place)[place->size() - 1];
        if isa::<VariableDecl>(d) {
            var v = cast::<VariableDecl>(d);
            return (v->type_->canonical) if (v->type_ != &null) else (&null);
        }
        if isa::<ParamDecl>(d) {
            var p = cast::<ParamDecl>(d);
            return (p->type_->canonical) if (p->type_ != &null) else (&null);
        }
        if isa::<FieldDecl>(d) {
            var f = cast::<FieldDecl>(d);
            return (f->type_->canonical) if (f->type_ != &null) else (&null);
        }
        return &null;
    }

    // --- uses (§4) ------------------------------------------------------------

    /// \p e, a use of the nullable \p place, was just typed: remember the
    /// state the place has HERE, for the consumer that may read its value.
    fn note_read(self, e: *Expr, place: *vec::<*Decl>) {
        if (e == &null) || (place->size() == 0) { return; }
        self._reads[reinterpret_cast::<u64>(e)] = self._read_list.size();
        self._read_list.push_back(self.get(place));
    }

    /// `T?` -> `T` with the nullable's cv (a `const` binding reads `const T`).
    fn narrowed_type(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        var x = t;
        if isa::<CXXLValueRefType>(x)      { x = cast::<CXXLValueRefType>(x)->referee; }
        else if isa::<CXXRValueRefType>(x) { x = cast::<CXXRValueRefType>(x)->referee; }
        var c = canon_unqual(x);
        if (c == &null) || (!isa::<NullableType>(c)) { return &null; }
        var inner = cast::<NullableType>(c)->inner;
        var q = canon_quals(x);
        if q != 0 { return self.sc->types->qualified(inner, q); }
        return inner;
    }

    /// The consumer of \p e needs its VALUE (§4). 0: \p e is no recorded read
    /// of a nullable place, nothing changed. 1: the place is NonNull here, and
    /// \p e (through its parentheses) is now typed `T` and marked narrowed.
    /// 2: it is Maybe or Null, the §4.2 error is reported (or held by a
    /// trap) and \p e is poisoned; only when \p must, else the answer is 0.
    fn read_value(self, e: *Expr, must: bool) -> u8 {
        if (e == &null) || e->is_poisoned() { return 0; }
        var x = null_flow_strip_parens(e);
        if (x == &null) || (x->type_ == &null) { return 0; }
        var it = self._reads.find(reinterpret_cast::<u64>(x));
        if it == self._reads.end() { return 0; }
        var f = self._read_list[it->second];
        var nt = self.narrowed_type(x->type_);
        if nt == &null { return 0; }
        if f.state == Nullness::NonNull {
            if isa::<NamedIdentExpr>(x) {
                cast::<NamedIdentExpr>(x)->narrowed_from = x->type_;
            } else if isa::<ChainExpr>(x) {
                var c = cast::<ChainExpr>(x);
                var st = c->steps.get(c->steps.size() - 1);
                st->narrowed_from = x->type_;
                st->resolved_type = nt;
            } else {
                return 0;
            }
            x->type_ = nt;
            var p = e;
            while (p != &null) && (p != x) && isa::<ParenExpr>(p) {
                p->type_ = nt;
                p = cast::<ParenExpr>(p)->inner;
            }
            return 1;
        }
        if !must { return 0; }
        self._refuse(x, f);
        var p = e;
        while (p != &null) && (p != x) && isa::<ParenExpr>(p) {
            p->poison();
            p = cast::<ParenExpr>(p)->inner;
        }
        return 2;
    }

    /// A `.` / `->` step \p i of \p c reads the value before it, which is
    /// nullable: the base (i == 0) or the field path through step i-1.
    /// Answers as read_value does; 1 leaves the narrowed type on the base
    /// node or on step i-1's resolved_type.
    fn read_prefix(self, c: *ChainExpr, i: usize) -> u8 {
        if i == 0 { return self.read_value(c->base, true); }
        var place = null_chain_place(c, i - 1);
        if place.size() == 0 { return 0; }
        var st = c->steps.get(i - 1);
        var nt = self.narrowed_type(st->resolved_type);
        if nt == &null { return 0; }
        var f = self.get(&place);
        if f.state == Nullness::NonNull {
            st->narrowed_from = st->resolved_type;
            st->resolved_type = nt;
            return 1;
        }
        self._refuse_at(static_cast::<*Expr>(c), SourceRange(c->range.start, st->range.end), f, nt);
        return 2;
    }

    // --- the access errors (4.2) ------------------------------------------------

    /// `a`, `o.cache`: how a place is written.
    fn place_name(self, place: *vec::<*Decl>) -> string {
        var s = "";
        for var i: usize = 0; i < place->size(); ++i {
            if i > 0 { s = s + "."; }
            s = s + self.tu->decl_name((*place)[i]);
        }
        return s;
    }

    priv fn _refuse(self, x: *Expr, f: NullFact) {
        self._refuse_at(x, x->range, f, self.narrowed_type(x->type_));
    }

    /// Report (or hold, inside a trap) the read of \p f.place at \p r, and
    /// poison \p x.
    priv fn _refuse_at(self, x: *Expr, r: SourceRange, f: NullFact, inner: *Type) {
        x->poison();
        var tb = self._traps_base();
        if self._traps.size() > tb {
            var t = &(self._traps[self._traps.size() - 1]);
            var h = NullHeld{};
            h.e       = x;
            h.range   = r;
            h.fact    = f;
            h.on_trap = (f.state == Nullness::Maybe) && null_place_eq(&(f.place), &(t->place));
            t->held.push_back(h);
            return;
        }
        self._emit(x, r, f, &null);
    }

    /// The SC001E itself. \p trap, when set, adds the 4.1 fix-it.
    priv fn _emit(self, x: *Expr, r: SourceRange, f: NullFact, trap: *NullTrap) {
        var nm = self.place_name(&(f.place));
        var msg = f"'{nm}' may be null here; check it with 'if {nm}?' first";
        if f.state == Nullness::Null { msg = f"'{nm}' is always null here"; }
        var b = self.sc->diag->report(DiagID::SC001E, r.start, msg);
        b.first(r);
        if trap != &null {
            b.insert(trap->open_at, "(", "put the use on the checked path");
            b.insert(trap->close_at, ")", "put the use on the checked path");
        }
        var wn = self._why_note(f, nm);
        if wn.msg.size() > 0 {
            if wn.at.is_valid() { b.note(wn.at, wn.msg); } else { b.note(wn.msg); }
        }
        if trap != &null {
            b.note(f"'&&' binds tighter than '||': the right of '||' runs when '{nm}?' may have failed; parenthesize, or force it with 'unwrap!({nm})\x27");
        }
        b.emit();
    }

    /// The note saying what made the place what it is: where, and what.
    priv fn _why_note(self, f: NullFact, nm: string) -> NullNote {
        var n = NullNote{};
        n.at = f.at.start;
        switch f.why {
            case NullWhy::Assigned {
                n.msg = (f"'{nm}' is set to null here") if (f.state == Nullness::Null) else (f"'{nm}' is given a value that may be null here");
                return n;
            }
            case NullWhy::Tested {
                n.msg = f"on this path, the test here found '{nm}' null";
                return n;
            }
            case NullWhy::Called {
                n.msg = f"'{nm}' is global: this call may change it, which ends the check before it";
                return n;
            }
            case NullWhy::Looped {
                n.msg = f"'{nm}' may be changed in the loop here, so it may be null at the top of the loop";
                return n;
            }
            case NullWhy::Inout {
                n.msg = f"this '@inout' argument lets the call change '{nm}\x27";
                return n;
            }
            case NullWhy::MutSelf {
                n.msg = f"this call takes what holds '{nm}' as a mutable 'self', so it may change '{nm}\x27";
                return n;
            }
            case NullWhy::Escaped {
                n.msg = f"a pointer to '{nm}' is taken here; any call after it, or a write through it, may change '{nm}\x27";
                return n;
            }
            case NullWhy::AddressTaken {
                n.at  = SourceLocation();
                n.msg = f"'{nm}' has its address taken in this file, so no check narrows it";
                return n;
            }
            default { 0; }
        }
        if f.place.size() == 0 { return n; }
        var root = f.place[0];
        if f.place.size() > 1 {
            var last = f.place[f.place.size() - 1];
            n.at  = last->range.start;
            n.msg = f"'{self.tu->decl_name(last)}' is declared nullable here";
            return n;
        }
        n.at = root->range.start;
        if self._captured(root) {
            n.msg = f"'{nm}' is captured by the closure; inside it, no check from outside holds, since the closure may run anywhere";
            return n;
        }
        if isa::<ParamDecl>(root) { n.msg = f"'{nm}' is a nullable parameter; it may be null on entry"; return n; }
        if f.global { n.msg = f"'{nm}' is global; it may be null on entry to any function"; return n; }
        n.msg = f"'{nm}' is declared nullable here";
        return n;
    }

    /// The current body is a closure's and \p d is declared outside it: a
    /// capture. (Locations order within a file; a decl from another file
    /// is outside too.)
    priv fn _captured(self, d: *Decl) -> bool {
        if self._frames.empty() { return false; }
        var c = self._frames.back().closure;
        if (c == &null) || (d == &null) { return false; }
        var at = d->range.start.id;
        var inside = (at >= c->range.start.id) && (at < c->range.end.id);
        return !inside;
    }

    // --- the 4.1 trap -------------------------------------------------------------

    /// The `||` \p n is about to type its right side. When its left side is
    /// an unparenthesized `t && y` whose `t` tests a place present, start
    /// holding the access errors of the right side. True when a trap was
    /// pushed (trap_end() must follow).
    fn trap_begin(self, n: *BinaryOperatorExpr) -> bool {
        var l = n->lhs;
        if (l == &null) || (!isa::<BinaryOperatorExpr>(l)) { return false; }
        var a = cast::<BinaryOperatorExpr>(l);
        var k = a->op_token.kind;
        if (a->resolved_op != &null) || ((k != TokenKind::OpAmpAmp) && (k != TokenKind::KwAnd)) { return false; }
        if (a->rhs == &null) || (n->rhs == &null) { return false; }
        var t = null_test_of(a->lhs);
        if (t.operand == &null) || (!t.present) { return false; }
        var place = null_place_of(t.operand);
        if place.size() == 0 { return false; }
        // y must not itself decide the place, or the parenthesized form
        // would not leave it NonNull on z's path.
        var yt = null_test_of(a->rhs);
        if yt.operand != &null {
            var yp = null_place_of(yt.operand);
            if null_place_eq(&yp, &place) { return false; }
        }
        var tr = NullTrap{};
        tr.place    = place;
        tr.open_at  = a->rhs->range.start;
        tr.close_at = n->rhs->range.end;
        self._traps.push_back(tr);
        return true;
    }

    /// The trap's right side is typed. Its held errors are reported now:
    /// with the fix-it when every one of them reads the tested place (then
    /// the parentheses make every use legal), plainly otherwise.
    fn trap_end(self) {
        if self._traps.size() <= self._traps_base() { return; }
        var tr = self._traps.back();
        self._traps.pop_back();
        var all = tr.held.size() > 0;
        for var i: usize = 0; i < tr.held.size(); ++i { if !tr.held[i].on_trap { all = false; } }
        for var i: usize = 0; i < tr.held.size(); ++i {
            var h = tr.held[i];
            var fix: *NullTrap = &null;
            if all && (i == 0) { fix = &tr; }
            // An enclosing trap may hold it again; it was already decided
            // here, so it is emitted.
            self._emit(h.e, h.range, h.fact, fix);
        }
    }
}
