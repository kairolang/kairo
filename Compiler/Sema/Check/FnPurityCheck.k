/// --- The Kairo Project ------------------- Sema/Check/FnPurityCheck.k --- ///
///
///   \brief Enforces `const fn` and `@pure`: what a function that promises to
///          be a function of its inputs may touch. With -finfer-purity (on
///          unless -fno-infer-purity), also finds the functions that keep
///          the promise without saying so.
///
///   \detail
///     Both promises become C++ attributes, and clang optimizes on them
///     without looking (measured with the bundled clang, declaration only):
///
///       `[[gnu::const]]`  memory(none) nounwind willreturn nofree nosync:
///                         an unused call is deleted, repeated calls are
///                         merged even across a store.
///       `[[gnu::pure]]`   memory(read) nounwind willreturn nofree: an
///                         unused call is deleted, repeats are merged unless
///                         a store intervenes.
///
///     A body that breaks the promise therefore miscompiles silently, so the
///     promise is checked here, in the Kairo body, where the user can be
///     pointed at the offending line. Every rule is SC200E. The rules are
///     the attributes' contract, one by one (Compiler/Spec/SemanticChecks.md
///     "FnPurityCheck" has the list with the reasons):
///
///       the function   returns a value (on a `void` result clang ignores
///                      both attributes), returns at all (`-> !`), does not
///                      unwind (`@unwind`), is not virtual or a requirement
///                      (a call through the base would carry the promise to
///                      an override that never made it), is not a generator
///                      or `async` (the frame is allocated), and its result
///                      type owns nothing (making one allocates).
///       const fn       reads strictly its inputs: no global or static (an
///                      `eval` constant is a value, not memory), no
///                      dereference, no field read through a pointer, no
///                      read of a parameter passed by reference (`@inout`,
///                      `@move`, `const p: Record`, `self`): memory(none)
///                      lets clang move the call across a store to it.
///       @pure          may read memory, never write it: no write to a
///                      global or static, no assignment through a pointer.
///       both           call only const fns, @pure fns, eval fns and the
///                      side-effect-free intrinsics (a user operator, a
///                      conversion operator and a constructor are calls,
///                      and so are two that no node shows: an implicit
///                      conversion's `@implicit op as`, judged at the
///                      converted expression from SemaContext::
///                      implicit_convs, and a `match` pattern's test of a
///                      record against a constant, its `op ==`, judged at
///                      the pattern);
///                      no function value and no interface requirement; no
///                      value that owns memory (a local, a temporary, a
///                      literal or a by-value argument copy of a type whose
///                      copy or destructor is not trivial: a string, a
///                      vector, an f-string); no `for ... in` over
///                      anything but a range, a fixed array or a pack (the
///                      iterator calls are not lowered yet); no `assert`, `unwrap!`,
///                      asserting downcast, `delete`, inline C++, `spawn`,
///                      `thread` or `await`; const also no checked downcast
///                      (it reads the object's vtable) and no volatile read.
///
///     `panic` is a return (a tagged result value, no unwinding), so a
///     `panic` statement is allowed; what it builds follows the rules above.
///
///   \par Inference (-finfer-purity)
///     infer() runs this same rule set, silent, over every eligible function
///     of the TU that made no promise, as a greatest fixpoint over the call
///     graph: every candidate starts at const, and each round lowers one
///     that breaks the rules to pure, then to none, until nothing changes.
///     The result is FunctionDecl::inferred_purity on every link of the
///     chain, which CXXSpell::fn_attrs spells on declarations and
///     definitions alike. It runs on the LOWERED tree, right before
///     ParamPassInference (which then leaves an inferred-const function's
///     parameters by value, as for a written one), so it sees every call a
///     lowering minted; a node kind it does not know makes the function
///     impure. A callee in a TU whose Sema has not run yet (an import
///     cycle) has no inferred purity yet and counts as impure.
///
///   Phase: CHECK (after ExprTyper: reads resolved declarations and types;
///          before every lowering, so it sees only what the user wrote and
///          its diagnostics name the user's own constructs; the two calls a
///          lowering or EmitIR makes from them are modelled above).
///          infer(): LOWER, after StringLowering, before ParamPassInference.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"
ffi "c++" import "Native/KClangPurity.hh"

import AST::Context::DeclContext::DeclContextKind
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
    decl_is_requirement,
}
import AST::Kind::ExprKind::ExprKind
import AST::Kind::StmtKind::StmtKind
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::FFILinkage::LinkageKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_has_volatile,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AbiKind,   AdtRole,      ClassDecl,    ExtensionDecl, FieldDecl, FnBodyKind, FunctionDecl,
    ParamDecl, StorageClass, TransferKind, VariableDecl,
}
import AST::Node::Expressions
import AST::Node::Patterns::{
    ConstructorPattern,
    LiteralPattern,
    UnresolvedConstructorPattern,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    IterKind,
    RangedForStmt,
    RuntimeAssertStmt,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::{
    LifecycleTri,
    lifecycle_of,
}
import Sema::Foreign::ForeignInstantiate::ForeignInstantiate
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// \enum PurityLevel
/// \brief The promise a body is held to. The values are the encoding of
///        FunctionDecl::inferred_purity, which codegen reads as a u8.
pub enum PurityLevel derives u8 {
    None = 0, ///< no promise: the rules are off.
    Const,    ///< `const fn`.
    Pure,     ///< `@pure`.
}

/// \enum PurityWalk
/// \brief What one walk over the items does. run() is one Check. infer()
///        (-finfer-purity) is one Collect, then Infer rounds to a
///        fixpoint, then back to Check.
pub enum PurityWalk derives u8 {
    Check = 0, ///< report every broken promise.
    Collect,   ///< visit_function_decl only gathers candidates.
    Infer,     ///< a silent walk: a broken rule, or a node kind the rules do not know, sets _fail.
}

pub class FnPurityCheck derives RecursiveASTVisitor<FnPurityCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    priv var _ml: MemberLookup
    /// The function whose body is being walked and the promise it made. A
    /// nested function swaps both for its own for the length of its body
    /// (visit_function_decl).
    priv var _f:     unsafe *FunctionDecl = &null
    priv var _level: PurityLevel          = PurityLevel::None
    /// Which walk this is (see PurityWalk). Under Infer, rules break
    /// silently into _fail instead of reporting.
    priv var _walk:  PurityWalk                             = PurityWalk::Check
    priv var _fail:  bool                                   = false
    priv var _cands: cxx::std::vector<unsafe *FunctionDecl>
    pub var  n_const:  usize                                  = 0
    pub var  n_pure:   usize                                  = 0

    fn FnPurityCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
        self._ml = MemberLookup(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        self._walk_items()
    }

    priv fn _walk_items(self) {
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
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// # entry points

    /// The body is walked here rather than left to the default traversal so
    /// the promise in force can be restored afterwards: a local function
    /// inside a `const fn` makes its own promise (or none), not its parent's.
    fn visit_function_decl(self, n: unsafe *FunctionDecl) -> bool {
        if n == &null {
            return true
        }

        if self._walk == PurityWalk::Collect {
            // A local function is never a candidate (nothing outside its
            // parent names it), so bodies are not entered.
            if !n->is_poisoned() {
                self._cands.push_back(n)
            }

            return false
        }

        // infer(): a nested function is its own question, never asked.
        if self._walk == PurityWalk::Infer {
            return false
        }

        if n->is_poisoned() {
            return true
        }

        var unsafe *saved_f = self._f
        var        saved_m  = self._level
        self._f    = n
        self._level = PurityLevel::None
        if n->is_const_fn {
            self._level = PurityLevel::Const
        } else if n->is_pure {
            self._level = PurityLevel::Pure
        }

        if self._level != PurityLevel::None {
            self._check_head(n)
        }

        self._walk_body(n)

        self._f    = saved_f
        self._level = saved_m
        return false
    }

    priv fn _walk_body(self, n: unsafe *FunctionDecl) {
        if n->body_block != &null {
            self.dyn()->traverse_block(n->body_block)
        } else if n->body_expr != &null {
            self.dyn()->dispatch_expr(n->body_expr)
        }
    }

    /// -finfer-purity. PRE: every lowering ran, ParamPassInference has not.
    fn infer(self) {
        self._walk = PurityWalk::Collect
        self._walk_items()
        self._walk = PurityWalk::Check

        // The candidates, all optimistic: const until shown otherwise.
        var live = cxx::std::vector<unsafe *FunctionDecl>()
        for var i: usize = 0; i < self._cands.size(); ++i {
            var unsafe *f = self._cands[i]
            if !self._inferable(f) {
                continue
            }

            live.push_back(f)
            self._stamp(f, PurityLevel::Const)
        }

        // Greatest fixpoint: a level only ever falls, so this ends after at
        // most two falls per candidate.
        self._walk = PurityWalk::Infer
        var changed = true
        while changed {
            changed = false
            for var i: usize = 0; i < live.size(); ++i {
                var unsafe *f  = live[i]
                var        cur = (f->inferred_purity as PurityLevel)
                if cur == PurityLevel::None {
                    continue
                }

                var lvl = PurityLevel::None
                if cur == PurityLevel::Const && self._passes(f, PurityLevel::Const) {
                    lvl = PurityLevel::Const
                } else if self._passes(f, PurityLevel::Pure) {
                    lvl = PurityLevel::Pure
                }

                if lvl != cur {
                    self._stamp(f, lvl)
                    changed = true
                }
            }
        }

        self._walk = PurityWalk::Check

        for var i: usize = 0; i < live.size(); ++i {
            var p = (live[i]->inferred_purity as PurityLevel)
            if p == PurityLevel::Const {
                self.n_const += 1
            }

            if p == PurityLevel::Pure {
                self.n_pure += 1
            }
        }
    }

    /// One silent walk of \p f's head and body under promise \p mode.
    priv fn _passes(self, f: unsafe *FunctionDecl, level: PurityLevel) -> bool {
        self._f     = f
        self._level = level
        self._fail = false
        self._check_head(f)
        if !self._fail {
            self._walk_body(f)
        }

        self._f    = &null
        self._level = PurityLevel::None
        return !self._fail
    }

    /// Write \p lvl on every link of \p f's chain: an importer's preamble
    /// spells the declaration from its own link, and the definition from
    /// this one, and both must carry the same attribute.
    priv fn _stamp(self, f: unsafe *FunctionDecl, level: PurityLevel) {
        var lvl = (level as u8)
        var unsafe *head        = f->first_decl()
        var unsafe *cur         = head
        var        guard: usize = 0
        while cur != &null && guard < 64 {
            cur->inferred_purity = lvl
            cur                  = cur->next_in_chain()
            guard += 1
            if cur == head {
                break
            }
        }

        f->inferred_purity = lvl
    }

    /// May inference ask about \p f at all? A function no promise could
    /// stand on, or whose C++ signature or call path is not its own body's
    /// (virtual, a requirement, FFI, a generic pattern whose instances C++
    /// re-checks, a lowering's thunk), is left alone.
    priv fn _inferable(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_const_fn || f->is_pure {
            return false
        }

        var unsafe *c = f->canonical_decl()
        if c != &null && (c->is_const_fn || c->is_pure) {
            return false
        }

        if f->is_implicit || f->is_poisoned() {
            return false
        }

        if f->body_kind != FnBodyKind::Block || f->body_block == &null {
            return false
        }

        if f->is_imported() || f->ffi_linkage != LinkageKind::None {
            return false
        }

        if f->abi == AbiKind::Virtual || f->abi == AbiKind::Override {
            return false
        }

        if f->call_conv != 0 || f->is_noreturn {
            return false
        }

        if f->is_generator || f->has_yield || f->is_async() || f->is_eval() {
            return false
        }

        if f->transfer != TransferKind::NotTransfer {
            return false
        }

        if f->ci_split != 0 || f->class_alloc_op != 0 || f->dynamic_layout != 0 {
            return false
        }

        if f->adt_role != AdtRole::None {
            return false
        }

        if f->has_where() || f->where_lead != &null || f->where_group.size() > 0 {
            return false
        }

        if f->generic_params.size() > 0 {
            return false
        }

        // A `panic` function: written with the specifier (its set may be
        // inferred and still empty here) or with a set.
        if f->panic_set.size() > 0 || f->panic_range.is_valid() {
            return false
        }

        if decl_is_requirement(f) {
            return false
        }

        if self._in_generic(f) {
            return false
        }

        if self._in_polymorphic(f) {
            return false
        }

        if self._returns_nothing(f) {
            return false
        }

        // `main`'s signature is the C runtime's, and nothing calls it twice.
        if !f->is_method() && self._tu.decl_name(unsafe (f as unsafe *Decl)) == "main" {
            return false
        }

        return true
    }

    /// \p d sits in a generic record or a generic extension, at any depth.
    priv fn _in_generic(self, d: unsafe *Decl) -> bool {
        var unsafe *ext = decl_extension_of(d)
        if ext != &null && decl_generic_params(unsafe (ext as unsafe *Decl)).size() > 0 {
            return true
        }

        var unsafe *dc        = d->semantic_dc
        var        depth: u32 = 0
        while dc != &null && depth < 64 {
            var unsafe *o = dc->owner_decl()
            if o == &null {
                break
            }

            if decl_generic_params(o).size() > 0 {
                return true
            }

            if isa<ExtensionDecl>(o) {
                var unsafe *t = cast<ExtensionDecl>(o)->target
                if t != &null && t->canonical != &null && t->canonical->is_dependent() {
                    return true
                }
            }

            dc = o->semantic_dc
            depth += 1
        }

        return false
    }

    /// A method of a class with a vptr: C++ may take it as an override of a
    /// base virtual (a C++ base's included), and a call through the derived
    /// type would carry this method's attribute to a further override.
    priv fn _in_polymorphic(self, f: unsafe *FunctionDecl) -> bool {
        var unsafe *dc = f->semantic_dc
        if dc == &null {
            return false
        }

        var unsafe *o = dc->owner_decl()
        if o == &null || !isa<ClassDecl>(o) {
            return false
        }

        var unsafe *facts = lifecycle_of(self.sc)->facts_of(o)
        return facts == &null || facts->polymorphic != LifecycleTri::No
    }

    /// # the function itself

    /// No result: clang ignores both attributes on a `void` function
    /// (-Wignored-attributes), so the promise would be checked and then
    /// thrown away. An expression body with no written type has its type.
    priv fn _returns_nothing(self, f: unsafe *FunctionDecl) -> bool {
        var unsafe *rt = f->return_type
        if rt == &null && f->body_expr != &null {
            rt = self._expr_type(f->body_expr)
        }

        if rt == &null {
            return true
        }

        return self._tu.is_void(rt)
    }

    /// What the attribute promises about the function as a whole, before
    /// its body is read.
    priv fn _check_head(self, f: unsafe *FunctionDecl) {
        if f->is_noreturn {
            self._report_head(f, "never returns; the promise says every call returns", true)
            return
        }

        if self._returns_nothing(f) {
            if self._walk == PurityWalk::Infer {
                self._fail = true
                return
            }

            self._report_head(
                f,
                "returns no value; the promise describes a result, and C++ ignores it on a function without one",
                true,
            )

            return
        }

        if !f->no_unwind && !self.sc->opts.unwind_all && f->has_body() {
            // X stamps no_unwind on every typed function but one marked
            // `@unwind`; under -funwind none is stamped, and the attribute
            // itself then supplies the nounwind every callee also keeps.
            self._report_head(f, "is marked '@unwind'; the promise says no call unwinds", false)
        }

        if f->abi == AbiKind::Virtual || f->abi == AbiKind::Override || decl_is_requirement(f) {
            self._report_head(
                f,
                "is virtual or an interface requirement; an override or a conformer does not make the promise, yet a call through this declaration is optimized as if it had",
                true,
            )
        }

        if f->is_generator || f->is_async() {
            self._report_head(
                f,
                "is a generator or async; its frame is allocated and outlives the call",
                true,
            )
        }

        var unsafe *rt = f->return_type
        if rt != &null && self._owns(rt) {
            var at = if (rt->range.is_valid()) => (rt->range) else => f->name.range
            self._report(
                at,
                "return a '" + self._tu.str(
                    rt,
                ) + "': making one allocates, and its destructor frees",
            )
        }
    }

    /// # the rules

    /// infer(): a node kind outside this list is a construct the rules do
    /// not model (a closure, a match a lowering has not removed, a panic
    /// slot), so the function is impure.
    fn visit_expr(self, n: *Expr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        // An implicit conversion is a call of the source's `@implicit op
        // as` that no node shows, on either tree (SemaContext::
        // implicit_convs); it is judged at the converted expression.
        if !self.sc->implicit_convs.empty() {
            var it = self.sc->implicit_convs.find(n as usize as u64)
            if it != self.sc->implicit_convs.end() {
                self._callee(n->range, unsafe (it->second as unsafe *Decl))
            }
        }

        if (self._walk != PurityWalk::Infer) {
            return true
        }

        match n->kind {
            case ExprKind::IntegerLiteralExpr {
                return true
            } case ExprKind::FloatingLiteralExpr {
                return true
            } case ExprKind::CharacterLiteralExpr {
                return true
            } case ExprKind::BooleanLiteralExpr {
                return true
            } case ExprKind::NullLiteralExpr {
                return true
            } case ExprKind::StringLiteralExpr {
                return true
            } case ExprKind::TupleLiteralExpr {
                return true
            } case ExprKind::NamedInitializerExpr {
                return true
            } case ExprKind::AnonInitializerExpr {
                return true
            } case ExprKind::InitListExpr {
                return true
            } case ExprKind::ChainExpr {
                return true
            } case ExprKind::CallExpr {
                return true
            } case ExprKind::SubscriptExpr {
                return true
            } case ExprKind::NamedIdentExpr {
                return true
            } case ExprKind::UnaryOperatorExpr {
                return true
            } case ExprKind::BinaryOperatorExpr {
                return true
            } case ExprKind::AssignOperatorExpr {
                return true
            } case ExprKind::IfExpr {
                return true
            } case ExprKind::SizeOfExpr {
                return true
            } case ExprKind::AlignOfExpr {
                return true
            } case ExprKind::TypeTraitExpr {
                return true
            } case ExprKind::UnsafeExpr {
                return true
            } case ExprKind::TypeCastExpr {
                return true
            } case ExprKind::ImplicitBoundaryCastExpr {
                return true
            } case ExprKind::ParenExpr {
                return true
            } case ExprKind::NamedArgExpr {
                return true
            } case ExprKind::StmtExpr {
                return true
            } default {
                self._fail = true
                return true
            }
        }

        return true
    }

    fn visit_stmt(self, n: *Stmt) -> bool {
        if (self._walk != PurityWalk::Infer) || self._level == PurityLevel::None || n == &null {
            return true
        }

        match n->kind {
            case StmtKind::CompoundStmt {
                return true
            } case StmtKind::ExpressionStmt {
                return true
            } case StmtKind::DeclStmt {
                return true
            } case StmtKind::ReturnStmt {
                return true
            } case StmtKind::BreakStmt {
                return true
            } case StmtKind::ContinueStmt {
                return true
            } case StmtKind::StaticAssertStmt {
                return true
            } case StmtKind::ConditionalStmt {
                return true
            } case StmtKind::WhileLoopStmt {
                return true
            } case StmtKind::LoopStmt {
                return true
            } case StmtKind::IndexedForStmt {
                return true
            } case StmtKind::LabeledStmt {
                return true
            } case StmtKind::UnsafeBlockStmt {
                return true
            } case StmtKind::InlineBlockStmt {
                return true
            } case StmtKind::EvalBlockStmt {
                return true
            } case StmtKind::LabelIntrinsicStmt {
                return true
            } case StmtKind::JumpIntrinsicStmt {
                return true
            } default {
                self._fail = true
                return true
            }
        }

        return true
    }

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        var unsafe *v = dyn_cast<VariableDecl>(n->resolved_decl)
        if v != &null {
            if self._level == PurityLevel::Const && self._is_global(v) {
                self._global(n->range, v, "read")
            }

            if v->type_ != &null && canon_has_volatile(v->type_->canonical) {
                self._report(n->range, "read the volatile '" + self._tu.decl_name(v) + "'")
            }

            return true
        }

        if self._level != PurityLevel::Const {
            return true
        }

        var unsafe *p = dyn_cast<ParamDecl>(n->resolved_decl)
        if p != &null && self._by_reference(p) {
            var nm = self._tu.decl_name(p)
            if p->is_self {
                nm = "self"
            }

            self._report(
                n->range,
                "read '" + nm + "', which is passed by reference: memory its caller may change between two calls",
            )
        }

        return true
    }

    fn visit_chain_expr(self, n: unsafe *ChainExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st->access_kind == ChainExpr::AccessKind::Arrow
                || st->access_kind == ChainExpr::AccessKind::QuestionArrow {
                // `p->x` reads through the pointer; as the target of an
                // assignment it is a write, which visit_assign_operator_expr
                // reports instead (a write is not also a read).
                if self._level == PurityLevel::Const {
                    self._deref(st->range, "read through a pointer")
                }
            }

            if self._level == PurityLevel::Const {
                var unsafe *v = dyn_cast<VariableDecl>(st->resolved_decl)
                if v != &null && self._is_global(v) {
                    self._global(st->range, v, "read")
                }
            }
        }

        return true
    }

    fn visit_subscript_expr(self, n: unsafe *Expressions::SubscriptExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        if n->resolved_op != &null {
            self._callee(n->range, n->resolved_op)
            return true
        }

        if self._level != PurityLevel::Const {
            return true
        }

        if self._tu.pointee(self._expr_type(n->base)) != &null {
            self._deref(n->range, "index through a pointer")
        }

        return true
    }

    fn visit_unary_operator_expr(self, n: unsafe *Expressions::UnaryOperatorExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        if n->resolved_op != &null {
            self._callee(n->range, n->resolved_op)
            return true
        }

        var k = n->op_token.kind
        if k == TokenKind::OpStar && n->fix == Expressions::UnaryOperatorExpr::Fix::Prefix {
            if self._level == PurityLevel::Const {
                self._deref(n->range, "dereference a pointer")
            }

            return true
        }

        if self._level == PurityLevel::Pure && (k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus) {
            self._write(n->operand, n->range)
        }

        return true
    }

    fn visit_binary_operator_expr(self, n: unsafe *Expressions::BinaryOperatorExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        if n->resolved_op != &null {
            self._callee(n->range, n->resolved_op)
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: unsafe *Expressions::AssignOperatorExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        if n->resolved_op != &null {
            self._callee(n->range, n->resolved_op)
        }

        if self._level == PurityLevel::Pure {
            self._write(n->lhs, n->range)
        }

        return true
    }

    fn visit_type_cast_expr(self, n: unsafe *Expressions::TypeCastExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        if n->resolved_op != &null {
            self._callee(n->range, n->resolved_op)
        }

        if n->resolved_ctor != &null {
            self._callee(n->range, n->resolved_ctor)
        }

        if n->asserting_downcast {
            self._report(
                n->range,
                "make an asserting downcast: a mismatch stops the program, and the promise says every call returns",
            )
        } else if n->checked_downcast && self._level == PurityLevel::Const {
            self._report(
                n->range,
                "make a checked downcast: it reads the object's type through the pointer",
            )
        }

        self._made(n, n->range)
        return true
    }

    fn visit_call_expr(self, n: unsafe *Expressions::CallExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        if n->is_poisoned() {
            return true
        }

        var unsafe *d = self._callee_decl(n)
        if n->ctor_decl != &null {
            d = n->ctor_decl
        }

        if d == &null {
            // A function value or a closure: nothing says what it does.
            // A callee the typer already rejected is its own error.
            var unsafe *ce = self._tu.strip_parens(n->callee)
            if self._walk == PurityWalk::Infer || ce != &null && !ce->is_poisoned() {
                self._call(n->range, "a function value")
            }

            return true
        }

        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null {
            // A binding of function type (a parameter, a local, a field):
            // nothing says what it calls.
            if isa<ParamDecl>(d) || isa<VariableDecl>(d) || isa<FieldDecl>(d) {
                self._call(n->range, "a function value")
                return true
            }

            // A type's construction without a user constructor: its value
            // is what may own memory.
            self._made(n, n->range)
            return true
        }

        if !self._callee(n->range, d) {
            return true
        }

        self._made(n, n->range)
        self._arg_copies(n, f)
        return true
    }

    fn visit_string_literal_expr(self, n: unsafe *StringLiteralExpr) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        if n->is_format() {
            self._report(n->range, "format a string: it allocates the result")
            return true
        }

        self._made(n, n->range)
        return true
    }

    fn visit_named_initializer_expr(self, n: unsafe *Expressions::NamedInitializerExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_anon_initializer_expr(self, n: unsafe *Expressions::AnonInitializerExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_init_list_expr(self, n: unsafe *Expressions::InitListExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_list_literal_expr(self, n: unsafe *Expressions::ListLiteralExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_set_literal_expr(self, n: unsafe *Expressions::SetLiteralExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_map_literal_expr(self, n: unsafe *Expressions::MapLiteralExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_tuple_literal_expr(self, n: unsafe *Expressions::TupleLiteralExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_variant_init_expr(self, n: unsafe *Expressions::VariantInitExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._made(n, n->range)
        }

        return true
    }

    fn visit_unwrap_expr(self, n: unsafe *Expressions::UnwrapExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(
                n->range,
                "unwrap with '!': a null stops the program, and the promise says every call returns",
            )
        }

        return true
    }

    fn visit_delete_expr(self, n: unsafe *Expressions::DeleteExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(n->range, "free memory")
        }

        return true
    }

    fn visit_cxx_new_expr(self, n: unsafe *Expressions::CxxNewExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(n->range, "allocate memory")
        }

        return true
    }

    fn visit_verbatim_expr(self, n: unsafe *Expressions::VerbatimExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(n->range, "run inline C++, which the compiler cannot check")
        }

        return true
    }

    fn visit_spawn_expr(self, n: unsafe *Expressions::SpawnExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(n->range, "spawn a task")
        }

        return true
    }

    fn visit_thread_expr(self, n: unsafe *Expressions::ThreadExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(n->range, "start a thread")
        }

        return true
    }

    fn visit_await_expr(self, n: unsafe *Expressions::AwaitExpr) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(n->range, "await")
        }

        return true
    }

    /// `for x in e`: the check runs before IterLowering, so the calls the
    /// loop becomes are not in the tree yet. An integer range, a fixed
    /// array and a pack unroll to plain indexing; a slice reads through its
    /// pointer; anything else runs an iterator protocol (a container's,
    /// an `op in` generator's, C++'s begin/end) this check cannot see.
    fn visit_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> bool {
        if self._level == PurityLevel::None || n == &null {
            return true
        }

        var k = n->iter_kind
        if k == IterKind::RangeLit
            || k == IterKind::RangeValue
            || k == IterKind::Array
            || k == IterKind::Pack {
            return true
        }

        if k == IterKind::Slice {
            if self._level == PurityLevel::Const {
                self._deref(n->range, "loop over a slice: it reads through the slice's pointer")
            }

            return true
        }

        if k == IterKind::None { // untyped or poisoned: its own error.
            return true
        }

        self._report(
            n->range,
            "loop with 'for ... in' over this value: it runs iterator calls the promise cannot be checked against",
        )

        return true
    }

    fn visit_runtime_assert_stmt(self, n: unsafe *RuntimeAssertStmt) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._report(
                n->range,
                "assert: a failed assert stops the program, and the promise says every call returns",
            )
        }

        return true
    }

    /// A pattern that tests the value for equality with a constant: on a
    /// record, that test is a call of the record's `op ==`, which the
    /// pattern is the only trace of until MatchLowering runs.
    fn visit_literal_pattern(self, n: unsafe *LiteralPattern) -> bool {
        if self._level != PurityLevel::None && n != &null {
            self._pattern_eq(unsafe (n as unsafe *Pattern))
        }

        return true
    }

    fn visit_constructor_pattern(self, n: unsafe *ConstructorPattern) -> bool {
        if self._level != PurityLevel::None
            && n != &null
            && n->resolved_decl != &null
            && isa<VariableDecl>(n->resolved_decl) {
            self._pattern_eq(unsafe (n as unsafe *Pattern))
        }

        return true
    }

    fn visit_unresolved_constructor_pattern(self, n: unsafe *UnresolvedConstructorPattern) -> bool {
        if self._level != PurityLevel::None
            && n != &null
            && n->resolved_decl != &null
            && isa<VariableDecl>(n->resolved_decl) {
            self._pattern_eq(unsafe (n as unsafe *Pattern))
        }

        return true
    }

    /// Every `op ==` of the record \p p is tested against: which one C++
    /// picks is overload resolution against the constant, so each must be
    /// one this function may call.
    priv fn _pattern_eq(self, p: unsafe *Pattern) {
        var unsafe *u = self._tu.as_value(p->type_)
        if u == &null || !isa<RecordType>(u) {
            return
        }

        var cands = cxx::std::vector<unsafe *Decl>()
        self._ml.lookup(
            u,
            DeclName::op_name(TokenKind::OpEqualEqual, TokenKind::TkUnknown),
            unsafe &cands,
        )

        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>(cands[i])
            if f == &null || f->is_poisoned() {
                continue
            }

            if !self._callee(p->range, cands[i]) {
                return
            }
        }
    }

    /// A local whose type owns memory: building it allocates, and leaving
    /// its scope frees. Parameters are ParamDecls and never come here.
    fn visit_variable_decl(self, n: unsafe *VariableDecl) -> bool {
        if self._level == PurityLevel::None || n == &null || self._f == &null {
            return true
        }

        if n->raw_slot || n->place_ref {
            return true
        }

        var unsafe *t = n->type_
        if t == &null && n->init != &null {
            t = self._expr_type(n->init)
        }

        if t != &null && self._owns(t) {
            var nm = self._tu.decl_name(unsafe (n as unsafe *Decl))
            self._report(
                n->name.range,
                "hold '" + nm + "', a '" + self._tu.str(
                    t,
                ) + "': making one allocates, and its destructor frees",
            )
        }

        return true
    }

    /// # queries

    priv fn _expr_type(self, e: unsafe *Expr) -> unsafe *Type {
        var unsafe *x = self._tu.strip_parens(e)
        if x == &null {
            return &null
        }

        return x->type_
    }

    /// A variable with static storage: a file or module variable, a static
    /// member, a `static` local. An `eval` constant is a compile-time value
    /// and is not memory. A local was never indexed into a scope table, so
    /// it has no semantic_dc.
    priv fn _is_global(self, v: unsafe *VariableDecl) -> bool {
        if v->storage == StorageClass::Eval {
            return false
        }

        if v->storage == StorageClass::Static {
            return true
        }

        var unsafe *dc = v->semantic_dc
        if dc == &null {
            return false
        }

        return dc->dc_kind == DeclContextKind::TranslationUnit
            || dc->dc_kind == DeclContextKind::Module
            || dc->is_type_scope()
    }

    /// \p p reaches the callee as a pointer in C++ (CXXSpell::_param_type):
    /// `@inout`, `@move`, `self`, a `const` record or type parameter, and a
    /// parameter ParamPassInference turned into `const T&`. A by-value
    /// record is a fresh caller copy (clang weakens the promise to "reads
    /// its argument copies" for it), so reading it is reading an input.
    priv fn _by_reference(self, p: unsafe *ParamDecl) -> bool {
        if p->is_self || p->inferred_const {
            return true
        }

        if p->mode == ParamMode::Inout || p->mode == ParamMode::Move {
            return true
        }

        if !p->is_const || p->type_ == &null {
            return false
        }

        var unsafe *c = p->type_->canonical
        if c == &null {
            return true
        }

        return c->kind == TypeKind::RecordType || c->kind == TypeKind::GenericParamType
    }

    /// A value of \p t is more than its bytes: its copy or its destructor
    /// runs code (a string, a vector, a record holding one, a type that
    /// depends on a generic parameter and so may be either).
    priv fn _owns(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            return false
        }

        if c->is_dependent() || c->is_instantiation_dependent() {
            return true
        }

        var unsafe *lc = lifecycle_of(self.sc)
        if self._tu.is_tuple(c) {
            var tf = lc->facts_of_type_concrete(c, "FnPurityCheck")
            return tf.trivial_dtor != LifecycleTri::Yes
                || tf.trivially_copyable != LifecycleTri::Yes
        }

        var f = lc->facts_of_type(c)
        return f.trivial_dtor != LifecycleTri::Yes || f.trivially_copyable != LifecycleTri::Yes
    }

    /// \p e makes a new value: one that owns memory breaks both promises.
    priv fn _made(self, e: unsafe *Expr, at: SourceRange) {
        var unsafe *t = e->type_
        if t == &null || !self._owns(t) {
            return
        }

        if self._walk == PurityWalk::Infer {
            self._fail = true
            return
        }

        self._report(
            at,
            "make a '" + self._tu.str(t) + "': making one allocates, and its destructor frees",
        )
    }

    /// A by-value parameter of an owning type copies its lvalue argument
    /// (the copy constructor runs in the caller, which is this function).
    /// A temporary argument is moved, and was reported where it was made.
    /// An omitted argument runs the parameter's default here too.
    priv fn _arg_copies(self, n: unsafe *Expressions::CallExpr, f: unsafe *FunctionDecl) {
        var np = f->params.size()
        if n->arg_map.size() < np {
            np = n->arg_map.size()
        }

        for var j: usize = 0; j < np; ++j {
            var unsafe *p = f->params[j]
            if p == &null || p->is_self {
                continue
            }

            var ai = *n->arg_map.get(j)
            if ai < 0 && (p->default_val != &null || p->default_thunk != &null) {
                // The default is evaluated here, in the caller, and it is
                // code nothing in this body shows.
                if self._walk == PurityWalk::Infer {
                    self._fail = true
                    return
                }

                self._report(
                    n->range,
                    "use the default of parameter '" + self._tu.decl_name(
                        p,
                    ) + "': it is code this function runs without showing it",
                )

                continue
            }

            if p->is_const || p->mode != ParamMode::Value {
                continue
            }

            if ai < 0 || (ai as usize) >= n->args.size() {
                continue
            }

            var unsafe *a = self._tu.strip_parens(*n->args.get(ai as usize))
            if a == &null {
                continue
            }

            if (!isa<NamedIdentExpr>(a))
                && (!isa<ChainExpr>(a))
                && !isa<Expressions::SubscriptExpr>(a) {
                continue
            }

            if a->type_ == &null || !self._owns(a->type_) {
                continue
            }

            if self._walk == PurityWalk::Infer {
                self._fail = true
                return
            }

            self._report(
                a->range,
                "copy a '" + self._tu.str(
                    a->type_,
                ) + "' into a parameter: the copy allocates, and its destructor frees",
            )
        }
    }

    /// What `n` calls, or null (a function value, an unresolved name).
    priv fn _callee_decl(self, n: unsafe *Expressions::CallExpr) -> unsafe *Decl {
        var unsafe *c = self._tu.strip_parens(n->callee)
        if c == &null {
            return &null
        }

        if isa<NamedIdentExpr>(c) {
            return cast<NamedIdentExpr>(c)->resolved_decl
        }

        if isa<ChainExpr>(c) {
            var unsafe *ch = cast<ChainExpr>(c)
            if ch->steps.size() == 0 {
                return &null
            }

            return ch->steps.get(ch->steps.size() - 1)->resolved_decl
        }

        return &null
    }

    /// A call of \p d (a function, an operator, a constructor) at \p at:
    /// true when it may be made. A non-function callee (a record's implicit
    /// construction) is not a call.
    priv fn _callee(self, at: SourceRange, d: unsafe *Decl) -> bool {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null {
            return true
        }

        if self._callable(f) {
            return true
        }

        if self._walk == PurityWalk::Infer {
            self._fail = true
            return false
        }

        if decl_is_requirement(f) {
            self._report(
                at,
                "call the interface requirement '" + self._tu.decl_name(
                    d,
                ) + "': the conformer's body decides what it does",
            )

            return false
        }

        self._call(at, "'" + self._tu.decl_name(d) + "'")
        return false
    }

    /// May the current function call \p f? Either redecl may carry the
    /// attribute (`fn` declared in one place, defined in another), so the
    /// chain's canonical is asked too; inference's verdict counts like a
    /// written promise.
    priv fn _callable(self, f: unsafe *FunctionDecl) -> bool {
        if decl_is_requirement(f) {
            return false
        }

        var unsafe *c = f->canonical_decl()
        if f->is_eval() || f->is_const_fn || f->inferred_purity == 1 {
            return true
        }

        if c != &null && (c->is_eval() || c->is_const_fn || c->inferred_purity == 1) {
            return true
        }

        if self._level == PurityLevel::Pure {
            if f->is_pure || f->inferred_purity == 2 {
                return true
            }

            if c != &null && (c->is_pure || c->inferred_purity == 2) {
                return true
            }
        }

        var fp = self._foreign_purity(f)
        if fp == 1 || fp == 2 && self._level == PurityLevel::Pure {
            return true
        }

        return self._is_intrinsic(f)
    }

    /// What clang says of a C/C++ callee: 0 none, 1 const, 2 pure. Read off
    /// its clang decl's attributes (or, for a builtin Kairo minted from the
    /// table, the table's entry), so a `strlen` or an `abs` keeps the promise
    /// and a `sqrt` (errno) does not, exactly as under our -fmath-errno. A
    /// decl whose header set was released (clang_decl nulled) says 0.
    ///
    /// Never kairo::clang_decl_purity directly: this check runs on a pool
    /// thread while another may be filling an instance in the same clang
    /// AST, and the redeclaration walk must hold the set's sema_lock()
    /// (P807). ForeignInstantiate::decl_purity takes it.
    priv fn _foreign_purity(self, f: unsafe *FunctionDecl) -> u8 {
        var unsafe *c    = f->canonical_decl()
        var        p: u8 = self._clang_purity(f)
        if p == 0 && c != &null && c != f {
            p = self._clang_purity(c)
        }

        if p == 0 && f->ffi_builtin_id != 0 {
            p = kairo::clang_builtin_purity(f->ffi_builtin_id)
        }

        return p
    }

    /// One decl's clang purity, read under its set's lock.
    priv fn _clang_purity(self, f: unsafe *FunctionDecl) -> u8 {
        if f->clang_decl == &null {
            return 0
        }

        return ForeignInstantiate::decl_purity(f)
    }

    /// The compiler intrinsics (Lib/builtin/base/intrinsics.k) that keep
    /// the promise: hints with no effect at run time, and for @pure the
    /// ones that only read. Not the traps and aborts (they never return),
    /// the memory writers, or the atomic fences (they synchronize).
    priv fn _is_intrinsic(self, f: unsafe *FunctionDecl) -> bool {
        if self.sc->g == &null {
            return false
        }

        if !self.sc->g->is_builtin_fid(self._tu.fid_of(unsafe (f as unsafe *Decl))) {
            return false
        }

        var nm = self._tu.decl_name(unsafe (f as unsafe *Decl))
        if nm == "__builtin_expect"
            || nm == "__builtin_expect_prob"
            || nm == "__builtin_assume"
            || nm == "__builtin_assume_aligned"
            || nm == "__builtin_unreachable"
            || nm == "__builtin_is_constant_evaluated"
            || nm == "__builtin_target_info" {
            return true
        }

        if self._level == PurityLevel::Pure && (nm == "__builtin_compare_mem" || nm == "__builtin_prefetch") {
            return true
        }

        return false
    }

    /// # writes (@pure)

    /// \p target is assigned (or incremented): a write to a global or
    /// through a pointer breaks `@pure`; a write to a local does not.
    priv fn _write(self, target: unsafe *Expr, at: SourceRange) {
        var unsafe *e = self._tu.strip_parens(target)
        if e == &null {
            return
        }

        if isa<Expressions::UnaryOperatorExpr>(e) {
            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(e)
            if u->op_token.kind == TokenKind::OpStar
                && u->fix == Expressions::UnaryOperatorExpr::Fix::Prefix {
                self._deref(at, "assign through a pointer")
            }

            return
        }

        if isa<Expressions::SubscriptExpr>(e) {
            var unsafe *s = cast<Expressions::SubscriptExpr>(e)
            if self._tu.pointee(self._expr_type(s->base)) != &null {
                self._deref(at, "assign through a pointer")
                return
            }

            self._write(s->base, at)
            return
        }

        if isa<NamedIdentExpr>(e) {
            var unsafe *rd = cast<NamedIdentExpr>(e)->resolved_decl
            var unsafe *v  = dyn_cast<VariableDecl>(rd)
            if v != &null && self._is_global(v) {
                self._global(at, v, "write")
            }

            // A parameter passed by reference is the caller's memory.
            var unsafe *p = dyn_cast<ParamDecl>(rd)
            if p != &null && (p->mode == ParamMode::Inout || p->mode == ParamMode::Move) {
                self._deref(at, "assign to a parameter passed by reference")
            }

            return
        }

        if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            for var i: usize = 0; i < ch->steps.size(); ++i {
                var unsafe *st = ch->steps.get(i)
                if st->access_kind == ChainExpr::AccessKind::Arrow
                    || st->access_kind == ChainExpr::AccessKind::QuestionArrow {
                    self._deref(at, "assign through a pointer")
                    return
                }

                var unsafe *v = dyn_cast<VariableDecl>(st->resolved_decl)
                if v != &null && self._is_global(v) {
                    self._global(at, v, "write")
                    return
                }
            }

            if ch->base != &null {
                // `self.x = v` on a method: self is the caller's object.
                var unsafe *b = self._tu.strip_parens(ch->base)
                if b != &null && isa<NamedIdentExpr>(b) {
                    var unsafe *p = dyn_cast<ParamDecl>(cast<NamedIdentExpr>(b)->resolved_decl)
                    if p != &null && p->is_self {
                        self._deref(at, "assign to a field of 'self'")
                        return
                    }
                }

                self._write(ch->base, at)
            }
        }
    }

    /// # reporting

    priv fn _who(self) -> string {
        return "'" + self._tu.decl_name(self._f) + "'"
    }

    priv fn _promise(self) -> string {
        return if (self._level == PurityLevel::Const) => ("const") else => "@pure"
    }

    priv fn _head_range(self, f: unsafe *FunctionDecl) -> SourceRange {
        return if (f->is_operator) => (f->range) else => f->name.range
    }

    /// The error, with a note on the function's head that says what it
    /// promised. \p what: the sentence after "<f> is const, so it cannot".
    priv fn _report(self, at: SourceRange, const what: string) {
        if self._walk == PurityWalk::Infer {
            self._fail = true
            return
        }

        var unsafe *f   = self._f
        var        head = self._head_range(f)
        var b = self.sc->diag->report(
            DiagID::SC200E,
            at.start,
            self._who() + " is " + self._promise() + ", so it cannot " + what,
        )

        b.first(at)
        if self._level == PurityLevel::Const {
            b.note(head.start, self._who() + " is const: it may read only its own inputs")
        } else {
            b.note(head.start, self._who() + " is @pure: it may read memory but never write it")
        }

        b.emit()
    }

    /// The promise cannot stand on this function at all. \p fix: offer to
    /// remove the written `const` / `@pure` (FunctionDecl::purity_at).
    priv fn _report_head(self, f: unsafe *FunctionDecl, const why: string, fix: bool) {
        if self._walk == PurityWalk::Infer {
            self._fail = true
            return
        }

        var head = self._head_range(f)
        var at   = if (f->purity_at.is_valid()) => (f->purity_at) else => head
        var b = self.sc->diag->report(
            DiagID::SC200E,
            at.start,
            self._who() + " is " + self._promise() + " but " + why,
        )

        b.first(at)
        b.note(head.start, "the function is declared here")
        if fix && f->purity_at.is_valid() {
            b.remove(f->purity_at, "remove '" + self._promise() + "'")
        }

        b.emit()
    }

    priv fn _global(self, at: SourceRange, v: unsafe *VariableDecl, const verb: string) {
        if self._walk == PurityWalk::Infer {
            self._fail = true
            return
        }

        self._report(
            at,
            verb + " the global '" + self._tu.decl_name(unsafe (v as unsafe *Decl)) + "'",
        )
    }

    priv fn _deref(self, at: SourceRange, const what: string) {
        self._report(at, what)
    }

    priv fn _call(self, at: SourceRange, const callee: string) {
        if self._walk == PurityWalk::Infer {
            self._fail = true
            return
        }

        var ok = if (self._level == PurityLevel::Const) => ("a const fn, an eval fn or a side-effect-free intrinsic")
                 else => "a const fn, a @pure fn, an eval fn or a side-effect-free intrinsic"
        self._report(at, "call " + callee + ", which is not " + ok)
    }
}
