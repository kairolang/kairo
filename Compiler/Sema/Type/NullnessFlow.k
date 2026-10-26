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
///       loop_enter/leave,      loops (see below), and `break`'s state
///         on_break
///       after_call             any call: globals and statics are Maybe again
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
///     Deliberately conservative (batch-B scope; NULLABLE.md G12 / G13 /
///     G17 refine it, through weaken() / weaken_all_addressable()):
///       - a place whose root has its address taken anywhere in the TU
///         (`&x`, the `@inout` marker, a `|*x|` capture) is never narrowed;
///       - a loop's head makes every place the loop assigns (and every
///         global) Maybe; `while x?` still narrows `x` at the top of its
///         body, since the condition is typed at the head;
///       - a call does not weaken locals (3.4 is G12); it does weaken
///         globals (3.8);
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
}

struct NullLoop {
    var breaks: vec::<NullEnv>;
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

/// Every root decl whose address is taken: `&x` (the `@inout` marker
/// included) and a by-pointer closure capture. Such a place is never
/// narrowed (batch B's conservative stand-in for 3.7).
class NullAddrScan derives RecursiveASTVisitor::<NullAddrScan> {
    pub var out: *llvm::DenseSet::<u64> = &null;

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if (n == &null) || (!n->is_prefix()) || (n->op_token.kind != TokenKind::OpAmp) { return true; }
        var d = null_root_decl(n->operand);
        if d != &null { self.out->insert(reinterpret_cast::<u64>(d)); }
        return true;
    }

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

/// Every place a loop body (or a `try` body) assigns, with where: at the
/// loop's head each is Maybe, since the back edge may bring any value
/// (batch B's stand-in for the 3.5 pre-scan). A target whose place cannot
/// be named yet (a step after an inferred value is still unbound) is
/// widened to its root, which drops every path under it.
class NullAssignScan derives RecursiveASTVisitor::<NullAssignScan> {
    pub var out: vec::<NullFact>;

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

class NullnessFlow {
    pub var sc: *SemaContext = &null;
    pub var tu: *TypeUtil    = &null;
    /// The state here. Mixins read and replace it around branches.
    pub var env: NullEnv;

    priv var _frames: vec::<NullFrame>;
    priv var _loops:  vec::<NullLoop>;
    priv var _traps:  vec::<NullTrap>;
    priv var _addr:   llvm::DenseSet::<u64>;
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
        self._frames.push_back(fr);
        self.env = NullEnv{};
    }

    fn leave(self) {
        if self._frames.empty() { return; }
        var fr = self._frames.back();
        self._frames.pop_back();
        self.env = fr.env;
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

    /// \p place may now hold anything: the hook 3.4's weakening uses.
    fn weaken(self, place: *vec::<*Decl>) {
        if self.env.dead { return; }
        null_env_kill_under(&(self.env), place);
    }

    /// Every address-taken place may now hold anything. They are never
    /// narrowed in batch B, so there is nothing to drop yet; G12 / G17
    /// narrow them between writes and call this at each write-through.
    fn weaken_all_addressable(self) {
        var keep = vec::<NullFact>();
        for var i: usize = 0; i < self.env.facts.size(); ++i {
            var f = self.env.facts[i];
            if (f.place.size() > 0) && self._addr.contains(reinterpret_cast::<u64>(f.place[0])) { continue; }
            keep.push_back(f);
        }
        self.env.facts = keep;
    }

    /// A call ran: it may have written any global (3.8). Their facts become
    /// Maybe, noted at \p at.
    fn after_call(self, at: SourceRange) {
        if self.env.dead { return; }
        for var i: usize = 0; i < self.env.facts.size(); ++i {
            if !self.env.facts[i].global { continue; }
            self.env.facts[i].state = Nullness::Maybe;
            self.env.facts[i].why   = NullWhy::Called;
            self.env.facts[i].at    = at;
        }
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
        if place.size() == 0 { return; }
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

    /// The head of a loop over \p body (with \p e1 / \p e2, its condition
    /// and update, which run on the back edge too): every place they assign
    /// is Maybe, and every global, since any call in them may write one.
    fn loop_enter(self, body: *Stmt, e1: *Expr, e2: *Expr) {
        self._weaken_assigned(body, e1, e2);
        var l = NullLoop{};
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

    /// `break`: this state reaches the end of the loop. A labeled break may
    /// leave any enclosing loop; it is given to each (a join only weakens).
    fn on_break(self, labeled: bool) {
        var base = self._loops_base();
        if self._loops.size() > base {
            if labeled {
                for var i = base; i < self._loops.size(); ++i { self._loops[i].breaks.push_back(self.env); }
            } else {
                self._loops[self._loops.size() - 1].breaks.push_back(self.env);
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
                n.msg = f"'{nm}' is assigned in the loop here, so it may be null at the top of the loop";
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
