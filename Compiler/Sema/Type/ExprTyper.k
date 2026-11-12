/// --- The Kairo Project ------------------------ Sema/Type/ExprTyper.k --- ///
///
///   \brief The expression typer. One pass, one class, every mixin: the
///          demand-driven `type_of` and the state the mixins share.
///
///   \detail
///     type_of(e, expected) is memoized per node, walks children itself, and
///     writes exactly these slots, each a fact some later pass reads instead
///     of deciding again:
///
///       any expression     Expr::type_, value_category, expr_flags, poisoned
///       inferred decls     the type of a VariableDecl / ClosureExpr /
///                          expr-bodied FunctionDecl / binder decl (the
///                          canonical node itself), or its poison bit
///       functions          is_generator, has_yield, no_unwind
///       enum variants      EnumVariantDecl::value
///       patterns           Pattern::type_ / resolved_decl / field_decl
///                          (PatternTyping)
///       callees            the promotion candidate_cell -> resolved_decl
///       calls              CallExpr::arg_map / pack_len / instance /
///                          ctor_decl; UnaryOperatorExpr::is_mode_marker
///       operators          resolved_op / op_via_free / op_instance on a
///                          binary, unary or assignment operator, op_rewrite
///                          on a binary one; resolved_op / op_via_free on a
///                          SubscriptExpr; resolved_op / op_via_free /
///                          resolved_ctor / widening on a TypeCastExpr
///       chains, typeof,    ChainExpr::Step::resolved_type,
///         ranges           TypeOfExpr::resolved_type, RangeExpr::as_index
///       literals           StringLiteralExpr::string_ctor / fmt_holes /
///                          fmt_ctor / fmt_text / fmt_finish / fmt_len;
///                          ListLiteralExpr::owner_ctor / slice_ctor / storage
///       variant            variant_decl on the NamedInitializerExpr,
///         construction     NamedIdentExpr or ChainExpr it was written as,
///                          and InitField::field_decl on each field
///       loops              RangedForStmt::iter_kind / iter_op / iter_elem,
///                          and a C++ range's cxx_* slots
///       narrowed reads     NamedIdentExpr / ChainExpr::Step narrowed_from,
///                          with the read's `type_` rewritten to the `T`
///                          (NullnessFlow::read_value, Compiler/Spec/Nullables.md#narrowed-reads)
///
///     Nothing else in the tree. Outside it: its own side tables, sc.rstate
///     for the decls it infers, and instances it asks the registry for.
///
///     It allocates AST nodes in one place: a C++ range's iterator locals
///     and its `!=` / `*` / `++` expressions (StmtTyping::_cxx_range). It
///     types them itself and leaves them on the loop for IterLowering.
///
///     The RAV drives the walk over the TU so that scope-carrying overrides
///     (StmtTyping) push frames; `dispatch_expr` is overridden to route
///     every expression through type_of, which makes the RAV's own pre-order
///     visit a memo hit for anything a statement already typed with an
///     expected type.
///
///     `expected` is bidirectional only where a node consumes it: literals,
///     initializers, closures, `null`. Everything else ignores it. A node has
///     one parent, so one expected type, so memoizing on the node is sound.
///
///     Four terminal states for a node, and every mixin returns to one:
///       typed      type_ set.
///       poisoned   diagnosed here or below; type_ null.
///       unknown    IsInstantiationDependent set, type_ null, not poisoned:
///                  dependent (M2), foreign (clang), or a hole owned by a
///                  later pass. Consumers skip checks on it.
///       type/module  the expression names a type or module; recorded in
///                  the side tables so a callee/initializer can read it.
///
///   Phase: CHECK stage, after TypeResolution + ChainBinding, before
///          ShadowCheck (which reads what this writes).
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
ffi "c++" import "llvm/Support/Allocator.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "memory"

import AST::ASTSupport::FrozenList
import AST::DeclFacts::{
    decl_builtin_id,
    decl_is_imported,
}
import AST::Kind::DeclKind::{
    DeclKind,
    to_string,
}
import AST::Kind::ExprKind::{
    ExprKind,
    to_string,
}
import AST::Kind::TypeKind::to_string
import AST::LangItems::{
    LangAttrs,
    to_string,
}
import AST::Mixin::Annotation::AnnotationKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,  QUAL_CONST, RecordType, builtin_for_token, canon_has_const, canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    is_recovery,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,         EnumVariantDecl, ExtensionDecl, FieldDecl, FnBodyKind,    FunctionDecl,
    GenericParamDecl, InterfaceDecl,   ModuleDecl,    ParamDecl, TypeAliasDecl, VariableDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    ChainType,
    FunctionPointerType,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::FullSourceLocation::FullSourceLocation
import Location::SourceLocation::SourceLocation
import Sema::Check::CaptureAnalysis::{
    copies_script_var,
    script_top_var,
}
import Sema::Check::EffectPropagation::{
    canonical_set,
    panic_home,
}
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Resolve::ChainBinding::ChainBinding
import Sema::Resolve::GenericArgs::GenericArgs
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::CallTyping::CallTyping
import Sema::Type::CastTyping::CastTyping
import Sema::Type::ControlTyping::ControlTyping
import Sema::Type::Conversion::{
    ConvClass,
    Conversion,
    ImplicitRank,
}
import Sema::Type::LiteralTyping::{
    LiteralTyping,
    NullTarget,
}
import Sema::Type::MemberTyping::{
    ChainInfo,
    MemberTyping,
}
import Sema::Type::NullnessFlow::{
    NULL_READ_NARROWED,
    NULL_READ_REFUSED,
    NullnessFlow,
    null_flow_is_global,
    null_flow_type_is_nullable,
}
import Sema::Type::OperatorTyping::OperatorTyping
import Sema::Type::OverloadResolution::OverloadResolution
import Sema::Type::PatternTyping::PatternTyping
import Sema::Type::StmtTyping::{
    StmtTyping,
    TyperFrame,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::{
    TokenKind,
    is_annotation,
}

/// `path:line:col` for an ICE message. The I011W reported just before an
/// ICE is buffered and dies with the abort; this is what reaches the user.
pub fn ice_source_loc(sc: unsafe *SemaContext, loc: SourceLocation) -> string {
    if sc == &null || sc->ctx == &null || sc->ctx->sm == &null {
        return "<unknown location>"
    }

    var unsafe *sm                      = sc->ctx->sm
    var        full: FullSourceLocation = sm->get_line_col(loc)
    return f"{full.path.full_path()}:{full.line}:{full.column}"
}

///
/// \class ExprBodyVerifier
/// \brief ExprTyper's exit test for expression bodies: every expr-bodied
///        FunctionDecl in the TU, extension and nested record methods
///        included, ends with its body typed, poisoned or dependent.
///
///        A body the typer never visited never passes through finish(),
///        so finish()'s own gate cannot see it. ExprBodyDesugar would then
///        move it untyped into a `return`, and EmitIR would ICE naming
///        itself. Report I011W at the function, and put the same location
///        in the ICE text, which is what survives the abort.
///
///        Runs in every build: the walk is one visit per function, and
///        release builds pass -DNDEBUG (see NameBindingVerifier).
///
pub class ExprBodyVerifier derives RecursiveASTVisitor<ExprBodyVerifier> {
    pub var sc: unsafe *SemaContext
    pub var tu: *TypeUtil

    fn ExprBodyVerifier(self, sc: unsafe *SemaContext, tu: *TypeUtil) {
        self.sc = sc
        self.tu = tu
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
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

    fn visit_function_decl(self, n: unsafe *FunctionDecl) -> bool {
        if n == &null {
            return true
        }

        if n->body_kind != FnBodyKind::Expr {
            return true
        }

        if n->is_poisoned() { // traverse_function_decl skips it.
            return true
        }

        var unsafe *e = n->body_expr
        if e == &null {
            return true
        }

        // its own TU typed it; null there was reported there (fn_return_type).
        if self.tu->is_foreign(unsafe (n as unsafe *Decl)) {
            return true
        }

        if e->type_ != &null || e->is_poisoned() || e->is_instantiation_dependent() {
            return true
        }

        var nm = self.tu->decl_name(unsafe (n as unsafe *Decl))
        self.sc->diag->report(
            DiagID::I011W,
            n->range.start,
            f"internal: the body of '{nm}' left ExprTyper untyped, unpoisoned and non-dependent; typer bug",
        ).first(e->range)->emit()
        kairo::std::ice_fail(
            f"ExprTyper: expression body of '{nm}' ({to_string(e->kind)}) was never typed, at {ice_source_loc(self.sc, n->range.start)}",
        )
    }
}

/// Memo states, keyed by node address.
pub enum TyperState derives u8 {
    Untouched = 0,
    InProgress,
    Done,
}

pub class ExprTyper
  derives StmtTyping<ExprTyper>,          // brings the RAV with it
          LiteralTyping<ExprTyper>,
          OperatorTyping<ExprTyper>,
          CallTyping<ExprTyper>,
          MemberTyping<ExprTyper>,
          CastTyping<ExprTyper>,
          ControlTyping<ExprTyper>,
          PatternTyping<ExprTyper> {
    /// ## context + components

    pub var sc:   unsafe *SemaContext
    pub var tu:   TypeUtil
    pub var conv: Conversion
    pub var ovl:  OverloadResolution
    pub var ml:   MemberLookup
    pub var cb:   ChainBinding
    /// The nullness analysis (Compiler/Spec/Nullables.md#nullness-analysis): the mixins report into it
    /// and ask it at each use; it owns every fact.
    pub var flow: NullnessFlow

    /// ## scope state

    pub var frames:       cxx::std::vector<TyperFrame>
    pub var unsafe_depth: u32                          = 0
    /// The enum (representative) whose discriminant is being typed, or null.
    /// Inside it a variant of that enum names its VALUE, typed as the
    /// underlying integer (C++ [dcl.enum]/5), so `RW = Read | Write` is a
    /// builtin `|`. One writer: StmtTyping::traverse_enum_variant_decl.
    pub var discr_enum: unsafe *Decl = &null
    /// The initializer or pattern head being typed right now, or null. A
    /// variant named there is what the enclosing construct builds or
    /// matches, so ControlTyping::type_variant_value does not make it a
    /// construction of its own. One writer: ControlTyping::type_head.
    pub var variant_head: *Expr? = &null
    /// The slots the values being typed right now go into, innermost last
    /// (push_null_target). Only `&null` reads it: when it lands in a safe
    /// pointer, the error names the slot and offers its fix-it there.
    pub var null_targets: cxx::std::vector<NullTarget>
    /// The `&null` operand of the `==` / `<` being typed, or null. It takes
    /// the other operand's pointer type without storing anything in it, so a
    /// comparison is never the "`&null` into a `*T`" error (LiteralTyping).
    pub var null_compared: *Expr? = &null

    /// ## side tables
    /// Keyed by expr address: a pointer can never be DenseMap's reserved
    /// ~0 / ~0-1, and nothing here is iterated, so hash order never shows.

    priv var _memo: llvm::DenseMap<u64, u8>
    /// ChainInfo lives in _chain_arena, the map holds its address: callers
    /// keep a *ChainInfo across type_of() recursion that inserts more chains,
    /// and a DenseMap rehash moves its values.
    priv var _chains:      llvm::DenseMap<u64, unsafe *ChainInfo>
    priv var _chain_arena: llvm::SpecificBumpPtrAllocator<ChainInfo>
    priv var _typeexp:     llvm::DenseMap<u64, unsafe *Type> ///< expr -> the type it denotes.
    priv var _modexp:      llvm::DenseSet<u64> ///< expr denotes a module.
    priv var _panics:      cxx::std::vector<unsafe *Expr> ///< asserting downcasts.
    /// `as` into a closed enum typed before the enum's variant values were
    /// written (the enum is declared below the cast): checked after the
    /// walk, when every value is (CastTyping::check_closed_enum_cast).
    priv var _enum_casts:    cxx::std::vector<unsafe *Expressions::TypeCastExpr>
    priv var _lang_reported: cxx::std::vector<string>
    priv var _scratch_ded:   Deduction

    /// ## counters for the dump

    pub var n_typed:   usize = 0
    pub var n_unknown: usize = 0
    pub var n_errored: usize = 0

    fn ExprTyper(self, sc: unsafe *SemaContext) {
        self.sc            = sc
        self.tu            = TypeUtil(sc)
        self.conv          = Conversion(sc)
        self.ovl           = OverloadResolution(sc, unsafe &self.conv)
        self.ml            = MemberLookup(sc)
        self.cb            = ChainBinding(sc)
        self._scratch_ded  = Deduction(sc, unsafe &self.conv)
        self.flow          = NullnessFlow(sc, unsafe &self.tu)
        self.discr_enum    = &null
        self.variant_head  = &null
        self.null_compared = &null
    }

    /// \p root is about to be typed into a slot declared \p written (as
    /// written, or null) by \p owner. Pair every push with a pop_null_target
    /// once \p root is typed: the stack holds the slots being typed into
    /// right now, nothing older.
    fn push_null_target(self, root: *Expr, written: *Type, owner: unsafe *Decl) {
        var t = NullTarget{}
        t.root    = root
        t.written = written
        t.owner   = owner
        self.null_targets.push_back(t)
    }

    fn pop_null_target(self) {
        if !self.null_targets.empty() {
            self.null_targets.pop_back()
        }
    }

    /// The type of a variant of \p ed used as a value: the enum, except
    /// inside \p ed's own discriminants, where it is the underlying type.
    fn variant_value_type(self, ed: unsafe *Decl) -> unsafe *Type {
        var unsafe *rep = NameLookup::representative(ed)
        if self.discr_enum != &null && rep == self.discr_enum {
            var unsafe *en = dyn_cast<EnumDecl>(rep)
            if en != &null && en->underlying != &null && en->underlying->canonical != &null {
                return en->underlying->canonical
            }

            return self.tu.builtin(BuiltinKind::U32)
        }

        var a = cxx::std::vector<unsafe *Type>()
        return self.sc->types->record(rep, unsafe &a)
    }

    /// PRE: TypesResolved (canonicals exist, chain steps with declared
    /// bases are bound). POST: every reachable expression is typed, poisoned
    /// or unknown; inferred decl slots filled; callee cells promoted.
    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        self.ml.index_extensions()
        self.cb.prepare()

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.type_of(item.as_expr(), &null)
                }
            }
        }

        if self.stop {
            return
        }

        for var i: usize = 0; i < self._enum_casts.size(); ++i {
            var unsafe *c = self._enum_casts[i]
            self.check_closed_enum_cast(c, self.closed_enum_of(c))
        }

        self._enum_casts.clear()
        self._check_typeof_types()

        var v = ExprBodyVerifier(self.sc, &self.tu)
        v.run()
    }

    /// A `typeof e` type that typing left without a canonical: one nested
    /// in another type (`*typeof x`), or in a parameter, return, field or
    /// cast type. Only a variable's whole declared type is resolved so far
    /// (StmtTyping::resolve_typeof_type); the rest would reach codegen as
    /// an unresolved type.
    priv fn _check_typeof_types(self) {
        var *ts = &self.sc->typeof_types
        for var i: usize = 0; i < ts->size(); ++i {
            var unsafe *t = (*ts)[i]
            if t == &null || t->canonical != &null || t->is_poisoned() {
                continue
            }

            self.sc->diag->report(
                DiagID::SC270E,
                t->range.start,
                "'typeof' is supported only as the whole declared type of a variable ('var y: typeof x'); write this type out",
            ).first(t->range)->emit()
            t->poison()
        }

        ts->clear()
    }

    fn panic_sites(self) -> unsafe *cxx::std::vector<unsafe *Expr> {
        return unsafe &self._panics
    }

    /// # the entry

    /// The core. Idempotent per node; children walked by the mixins.
    /// \p e has been typed (or is being). OperatorTyping asks before walking a
    /// left-leaning operator chain bottom-up (P804).
    fn is_memoized(self, e: unsafe *Expr) -> bool {
        return self._memo.find((e as usize as u64)) != self._memo.end()
    }

    fn type_of(self, e: unsafe *Expr, expected: unsafe *Type) -> unsafe *Type {
        if e == &null {
            return &null
        }

        var key = (e as usize as u64)
        var it  = self._memo.find(key)
        if it != self._memo.end() {
            if (it->second as TyperState) == TyperState::InProgress {
                // an expression that reaches itself (only via a demand path):
                // the demand helper reported the cycle; stay quiet.
                return &null
            }

            return e->type_
        }

        self._memo[key] = (TyperState::InProgress as u8)

        var t: unsafe *Type = &null
        if is_recovery(e) {
            e->poison() // parser diagnosed.
        } else if e->is_poisoned() {
            0 // an earlier pass diagnosed.
        } else {
            t = self._dispatch(e, expected)
        }

        self.finish(e, t)
        return e->type_
    }

    /// Record the outcome on the node. Public so a mixin that typed a child
    /// out of band (the `-literal` fold) can commit it.
    fn finish(self, e: unsafe *Expr, t: unsafe *Type) {
        var key = (e as usize as u64)
        self._memo[key] = (TyperState::Done as u8)
        if e->is_poisoned() {
            e->type_ = &null
            self.n_errored += 1
            return
        }

        if t == &null {
            if !e->is_instantiation_dependent() {
                // a type/module-denoting expr or a callable has no type by
                // design; anything else with a null type is a hole to count.
                var k = key
                if self._typeexp.find(k) == self._typeexp.end()
                    && self._modexp.find(k) == self._modexp.end() {
                    var ci       = self._chains.find(k)
                    var callable = ci != self._chains.end() && ci->second->callable_cands.size() > 0
                    if !callable {
                        // Every arm ends typed, poisoned (with its diagnostic) or
                        // mark_unknown'd. A node in none of those reaches EmitIR
                        // untyped, where the ICE names EmitIR, not the source.
                        self.sc->diag->report(
                            DiagID::I011W,
                            e->range.start,
                            f"internal: {to_string(e->kind)} left untyped, unpoisoned and non-dependent; typer bug",
                        ).first(e->range)->emit()
                        kairo::std::ice_fail(
                            f"ExprTyper: {to_string(e->kind)} reached finish() in no terminal state, at {ice_source_loc(self.sc, e->range.start)}",
                        )
                    }
                }
            } else {
                self.n_unknown += 1
            }

            return
        }

        e->type_ = t
        if t->is_dependent() {
            e->expr_flags.set(Expr::ExprFlags::IsDependent)
            e->expr_flags.set(Expr::ExprFlags::IsInstantiationDependent)
        }

        if e->value_category == Expr::ValueCategory::Unknown {
            e->value_category = self._default_category(e, t)
        }

        self.n_typed += 1
    }

    /// The category of a typed expression whose arm did not set one.
    ///
    ///   1. By TYPE. An expression of C++ reference type is the referent
    ///      ([expr.type]/1): `T&` an lvalue, `T&&` an xvalue. Only imported
    ///      signatures produce these, and every kind can -- a call, an
    ///      operator (`cout << 1` is `ostream&`, and the next `<<` binds it
    ///      to `ostream&`), a member -- so it is decided here once.
    ///   2. By KIND. What only ever makes a new value is a prvalue: literals,
    ///      by-value calls, temporaries, casts, arithmetic, control
    ///      expressions. The kinds whose category is whatever they NAME --
    ///      identifiers, chains, subscripts, parens, assignments -- get
    ///      nothing: their arm decides, and ValueCategoryPass ICEs on one
    ///      that did not. A default there would hide the missing arm.
    priv fn _default_category(self, e: unsafe *Expr, t: unsafe *Type) -> Expr::ValueCategory {
        if isa<CXXLValueRefType>(t) {
            return Expr::ValueCategory::LValue
        }

        if isa<CXXRValueRefType>(t) {
            return Expr::ValueCategory::XValue
        }

        var k = e->kind
        if k == ExprKind::NamedIdentExpr
            || k == ExprKind::ChainExpr
            || k == ExprKind::SubscriptExpr
            || k == ExprKind::ParenExpr
            || k == ExprKind::AssignOperatorExpr {
            return Expr::ValueCategory::Unknown
        }

        return Expr::ValueCategory::RValue
    }

    priv fn _dispatch(self, e: unsafe *Expr, expected: unsafe *Type) -> unsafe *Type {
        match e->kind {
            case ExprKind::IntegerLiteralExpr {
                return self.type_int_literal(cast<IntegerLiteralExpr>(e), expected, false)
            } case ExprKind::FloatingLiteralExpr {
                return self.type_float_literal(cast<FloatingLiteralExpr>(e), expected)
            } case ExprKind::StringLiteralExpr {
                return self.type_string_literal(cast<StringLiteralExpr>(e), expected)
            } case ExprKind::CharacterLiteralExpr {
                return self.type_char_literal(cast<CharacterLiteralExpr>(e), expected)
            } case ExprKind::BooleanLiteralExpr {
                return self.type_bool_literal(cast<BooleanLiteralExpr>(e), expected)
            } case ExprKind::NullLiteralExpr {
                return self.type_null_literal(cast<NullLiteralExpr>(e), expected)
            } case ExprKind::ListLiteralExpr {
                return self.type_list_literal(cast<Expressions::ListLiteralExpr>(e), expected)
            } case ExprKind::TupleLiteralExpr {
                return self.type_tuple_literal(cast<Expressions::TupleLiteralExpr>(e), expected)
            } case ExprKind::SetLiteralExpr {
                return self.type_set_literal(cast<Expressions::SetLiteralExpr>(e), expected)
            } case ExprKind::MapLiteralExpr {
                return self.type_map_literal(cast<Expressions::MapLiteralExpr>(e), expected)
            } case ExprKind::NamedInitializerExpr {
                return self.type_named_init(cast<Expressions::NamedInitializerExpr>(e), expected)
            } case ExprKind::AnonInitializerExpr {
                return self.type_anon_init(cast<Expressions::AnonInitializerExpr>(e), expected)
            } case ExprKind::ChainExpr {
                return self.type_chain(cast<ChainExpr>(e), expected)
            } case ExprKind::CallExpr {
                // Any call may write any global (Compiler/Spec/Nullables.md#globals). After the
                // call: its own arguments were read before it ran.
                var unsafe *ct = self.type_call(cast<Expressions::CallExpr>(e), expected)
                self.flow.after_call(e->range)
                return ct
            } case ExprKind::SubscriptExpr {
                return self.type_subscript(cast<Expressions::SubscriptExpr>(e), expected)
            } case ExprKind::NamedIdentExpr {
                return self._type_ident(cast<NamedIdentExpr>(e), expected)
            } case ExprKind::UnaryOperatorExpr {
                var unsafe *un = cast<Expressions::UnaryOperatorExpr>(e)
                var unsafe *ut = self.type_unary(un, expected)
                var        uk  = un->op_token.kind
                if uk == TokenKind::OpPlusPlus || uk == TokenKind::OpMinusMinus {
                    self.flow.modified(un->operand)
                }

                if un->resolved_op != &null { // a user operator is a call.
                    self.flow.operator_call(un->resolved_op, un->operand, e->range)
                    self.flow.after_call(e->range)
                }

                return ut
            } case ExprKind::BinaryOperatorExpr {
                var unsafe *bn = cast<Expressions::BinaryOperatorExpr>(e)
                var unsafe *bt = self.type_binary(bn, expected)
                if bn->resolved_op != &null {
                    self.flow.operator_call(bn->resolved_op, bn->lhs, e->range)
                    self.flow.after_call(e->range)
                }

                return bt
            } case ExprKind::AssignOperatorExpr {
                var unsafe *an = cast<Expressions::AssignOperatorExpr>(e)
                var unsafe *at = self.type_assign(an, expected)
                // `=` reports itself (NullnessFlow::assign); a compound one
                // writes its left side in place.
                if an->op_token.kind != TokenKind::OpEqual {
                    self.flow.modified(an->lhs)
                }

                if an->resolved_op != &null {
                    self.flow.operator_call(an->resolved_op, an->lhs, e->range)
                    self.flow.after_call(e->range)
                }

                return at
            } case ExprKind::ImplConformanceExpr {
                return self.type_constraint(e, expected)
            } case ExprKind::DerivesRelationExpr {
                return self.type_constraint(e, expected)
            } case ExprKind::ConstraintExpr {
                return self.type_constraint(e, expected)
            } case ExprKind::IfExpr {
                return self.type_if_expr(cast<Expressions::IfExpr>(e), expected)
            } case ExprKind::TryCatchExpr {
                return self.type_try_expr(cast<Expressions::TryCatchExpr>(e), expected)
            } case ExprKind::MatchExpr {
                return self.type_match_expr(cast<Expressions::MatchExpr>(e), expected)
            } case ExprKind::RangeExpr {
                return self.type_range(cast<Expressions::RangeExpr>(e), expected)
            } case ExprKind::ClosureExpr {
                return self.type_closure(cast<Expressions::ClosureExpr>(e), expected)
            } case ExprKind::AwaitExpr {
                return self.type_await(cast<Expressions::AwaitExpr>(e), expected)
            } case ExprKind::UnwrapExpr {
                return self.type_unwrap(cast<Expressions::UnwrapExpr>(e), expected)
            }

            // EvalIfFolding folded every one; a bool if one is ever left.
            case ExprKind::DefinedExpr {
                return self.tu.builtin(BuiltinKind::Bool)
            } case ExprKind::AttributedExpr {
                // No expression attribute has a meaning yet: FeatureGateCheck
                // reports each one (SC116E), and that error stops the
                // schedule before any lowering. The operand is NOT typed as
                // an ordinary expression: an attribute may give it another
                // meaning (`@create i32(10)` constructs an i32, where a plain
                // `i32(10)` is SC037E), so typing it here would report
                // errors in code the attribute defines. Its names were
                // resolved (N), so a misspelling is still caught.
                self.mark_unknown(e)
                return &null
            } case ExprKind::SpawnExpr {
                return self.type_spawn(e, cast<Expressions::SpawnExpr>(e)->operand, expected)
            } case ExprKind::ThreadExpr {
                return self.type_spawn(e, cast<Expressions::ThreadExpr>(e)->operand, expected)
            } case ExprKind::SizeOfExpr {
                return self.type_sizeof(cast<Expressions::SizeOfExpr>(e), expected)
            } case ExprKind::AlignOfExpr {
                return self.type_alignof(cast<Expressions::AlignOfExpr>(e), expected)
            } case ExprKind::TypeTraitExpr {
                return self.type_type_trait(cast<Expressions::TypeTraitExpr>(e), expected)
            } case ExprKind::CxxNewExpr {
                return self.type_cxx_new(cast<Expressions::CxxNewExpr>(e), expected)
            } case ExprKind::TypeOfExpr {
                return self.type_typeof(cast<Expressions::TypeOfExpr>(e), expected)
            } case ExprKind::EvalExpr {
                return self.type_eval(cast<Expressions::EvalExpr>(e), expected)
            } case ExprKind::UnsafeExpr {
                return self.type_unsafe(cast<Expressions::UnsafeExpr>(e), expected)
            } case ExprKind::StmtExpr {
                return self.type_stmt_expr(cast<Expressions::StmtExpr>(e), expected)
            } case ExprKind::DeleteExpr {
                return self.type_delete(cast<Expressions::DeleteExpr>(e), expected)
            } case ExprKind::TypeCastExpr {
                return self.type_cast(cast<Expressions::TypeCastExpr>(e), expected)
            } case ExprKind::PackExpansionExpr {
                self.type_of(cast<Expressions::PackExpansionExpr>(e)->operand, &null)
                self.mark_unknown(e)
                return &null
            } case ExprKind::ImplicitBoundaryCastExpr {
                var unsafe *c = cast<Expressions::ImplicitBoundaryCastExpr>(e)
                self.type_of(c->original, &null)
                return if (c->target_type != &null) => (c->target_type->canonical) else => &null
            } case ExprKind::ParenExpr {
                var unsafe *p = cast<Expressions::ParenExpr>(e)
                var unsafe *t = self.type_of(p->inner, expected)
                if self.propagate(e, p->inner) {
                    return &null
                }

                if p->inner != &null {
                    e->value_category = p->inner->value_category
                    var unsafe *d = self.denoted_type(p->inner)
                    if d != &null {
                        self.note_type_expr(e, d)
                    }
                }

                return t
            } case ExprKind::VerbatimExpr {
                self.mark_unknown(e)
                return &null
            } default {
                self.fail(e, DiagID::SC093E, "expression kind is not typable")
                return &null
            }
        }
    }

    /// # identifiers

    /// The type a USE of \p p has: TypeUtil::param_value_type (a pack reads
    /// as its Slice<E>), cv-qualified for a `const` binding. A `const`
    /// binding is a const OBJECT, and an object's type carries its cv: `&x`
    /// on a const param is `*const T`, and `T&` deduces `const T` from it.
    /// The receiver is exempt: a const method's `self` already has type
    /// `const Record` (TypeResolve::_synthesize_receiver, DeclImport). Null
    /// when the type is unknown, which includes a pack over a dependent
    /// element: instantiation-dependent, never poisoned.
    fn param_value_type(self, p: unsafe *ParamDecl) -> unsafe *Type {
        var unsafe *t = self.tu.param_value_type(p)
        if t == &null {
            return &null
        }

        if p->is_const && !p->is_self {
            t = self.sc->types->qualified(t, QUAL_CONST)
        }

        return t
    }

    priv fn _type_ident(self, n: unsafe *NamedIdentExpr, expected: unsafe *Type) -> unsafe *Type {
        if n->is_deferred() {
            // an overload set as a value: only a callee may read a cell.
            var all_mod = true
            for var i: usize = 0; i < n->candidate_cell->size(); ++i {
                if !isa<ModuleDecl>(n->candidate_cell->get(i)) {
                    all_mod = false
                    break
                }
            }

            if all_mod {
                self.note_module_expr(n)
                return &null
            }

            var unsafe *ci = self.new_chain_info_for_ident(n)
            for var i: usize = 0; i < n->candidate_cell->size(); ++i {
                ci->callable_cands.push_back(n->candidate_cell->get(i))
            }

            return &null
        }

        if !n->is_bound() {
            self.mark_unknown(n)
            return &null
        }

        var unsafe *d = n->resolved_decl
        match d->kind {
            case DeclKind::ParamDecl {
                var unsafe *p = cast<ParamDecl>(d)
                n->value_category = Expr::ValueCategory::LValue
                var unsafe *t = self.param_value_type(p)
                if t == &null {
                    self.mark_unknown(n)
                    return &null
                }

                var unsafe *pv = self._capture_view(d, t)
                if pv != &null {
                    n->capture_ptr = true
                    return pv
                }

                self._note_place_read(n, d, t)
                self.flow.note_use(n, d)
                return t
            } case DeclKind::VariableDecl {
                n->value_category = Expr::ValueCategory::LValue
                var unsafe *v = cast<VariableDecl>(d)
                var unsafe *t = self.var_type(v)
                if t == &null {
                    if d->is_poisoned() {
                        self.poison_only(n)
                    } else {
                        self.mark_unknown(n)
                    }
                } else if v->is_const() {
                    t = self.sc->types->qualified(t, QUAL_CONST)
                }

                if t != &null {
                    var unsafe *pv = self._capture_view(d, t)
                    if pv != &null {
                        n->capture_ptr = true
                        return pv
                    }

                    self._note_place_read(n, d, t)
                    self.flow.note_use(n, d)
                }

                return t
            } case DeclKind::FieldDecl {
                // reachable only as a static field or from a type body default.
                var unsafe *f = cast<FieldDecl>(d)
                n->value_category = Expr::ValueCategory::LValue
                if f->type_ == &null {
                    self.mark_unknown(n)
                    return &null
                }

                return f->type_->canonical
            } case DeclKind::EnumVariantDecl {
                var unsafe *edc = d->semantic_dc
                var unsafe *ed  = if (edc != &null) => (edc->owner_decl()) else => &null
                if ed == &null {
                    self.mark_unknown(n)
                    return &null
                }

                n->value_category = Expr::ValueCategory::RValue // a variant is a value, not storage.
                return self.type_variant_value(
                    n,
                    cast<EnumVariantDecl>(d),
                    self.variant_value_type(ed),
                )
            } case DeclKind::FunctionDecl {
                // A builtin has no address: clang lowers each call in place.
                // CallTyping's name arm binds a callee without typing it, so
                // reaching here at all means a use that is not a direct call.
                if decl_builtin_id(d) != 0 {
                    self.fail(
                        n,
                        DiagID::SC109E,
                        f"'{self.sc->ctx->get_spelling(n->name)}' is a clang builtin; it can only be called directly",
                    )

                    return &null
                }

                var unsafe *f  = cast<FunctionDecl>(d)
                var unsafe *ci = self.new_chain_info_for_ident(n)
                ci->callable_cands.push_back(d)
                n->value_category = Expr::ValueCategory::RValue // as a value: the fn pointer.
                if !f->is_method() && f->generic_params.size() == 0 {
                    return self.fn_pointer_type(f)
                }

                // `pick<i32>`: one instance, a value as a plain function is.
                // Short of that it stays a callable, which only a callee
                // reads (propagate rejects it as an operand).
                if !f->is_method() {
                    return self.generic_fn_value_type(f, unsafe &n->generic_args)
                }

                return &null
            } case DeclKind::GenericParamDecl {
                // A TYPE parameter denotes its type, as a record's name does:
                // `T::make()` is a static of T's bounds called with T as its
                // qualifier, and MemberTyping reads the receiver off this. An
                // `eval N: T` value parameter is a constant of its declared
                // type (Compiler/Spec/Eval.md#generic-value-parameters): a prvalue, the same in every instance.
                var unsafe *gp = cast<GenericParamDecl>(d)
                if gp->is_const_param
                    && gp->value_type != &null
                    && gp->value_type->canonical != &null {
                    n->value_category = Expr::ValueCategory::RValue
                    return gp->value_type->canonical
                }

                if gp->is_const_param || gp->is_pack || gp->owner == &null {
                    self.mark_unknown(n)
                    return &null
                }

                self.note_type_expr(
                    n,
                    self.sc->types->generic_param(
                        NameLookup::representative(gp->owner),
                        gp->index,
                        false,
                    ),
                )

                return &null
            } case DeclKind::ModuleDecl {
                // A module used as a value is the typer's own (still open)
                // question and stays silent here. `cxx` is not: it is the C++
                // std overlay, its one member is `std`, and naming it alone
                // denotes nothing -- answerable now, so answer it.
                if self.sc->tu != &null && d == self.sc->tu->cxx_module {
                    self.sc->diag->report(
                        DiagID::R053E,
                        n->range.start,
                        "'cxx' names the C++ std overlay; write `cxx::std`",
                    ).first(n->range)->emit()
                    return &null
                }

                self.note_module_expr(n)
                return &null
            } case DeclKind::ExtensionDecl {
                // `Self` inside an extend: denotes the target type.
                var unsafe *t = self.type_from_type_decl(d, n->generic_args, n)
                if t != &null {
                    self.note_type_expr(n, t)
                }

                return &null
            } default {
                if self.tu.is_type_decl(d) {
                    var unsafe *t = self.type_from_type_decl(d, n->generic_args, n)
                    if t == &null {
                        return &null
                    }

                    self.note_type_expr(n, t)
                    return &null
                }

                self.fail(n, DiagID::SC094E, f"'{self.tu.decl_name(d)}' is not a value")
                return &null
            }
        }
    }

    /// Inside a closure that captures \p d by pointer (`|*x|`, `|*|`, or
    /// `|const *x|`), the name is that pointer, `*T` (closures.md: the body
    /// reads and writes the original through `*x`): its type there, or null
    /// when \p d is not captured by pointer here. An inner closure that
    /// copies an outer one's pointer capture sees the pointer too. Only
    /// closures between the use and \p d's own body count.
    priv fn _capture_view(self, d: unsafe *Decl, t: unsafe *Type) -> unsafe *Type {
        if d == &null || t == &null {
            return &null
        }

        var at  = d->range.start.id
        var top = self.script_top_capture(d)
        var i   = self.frames.size()
        while i > 0 {
            i = i - 1
            var unsafe *c = self.frames[i].closure
            if c == &null { // a function body: d is its own or a global.
                return &null
            }

            if at >= c->range.start.id && at < c->range.end.id {
                return &null
            }

            for var k: usize = 0; k < c->captures.size(); ++k {
                var unsafe *cap = c->captures.get(k)
                if !cap->by_ptr {
                    continue
                }

                var named = cap->name != &null && cap->name->resolved_decl == d
                var all   = cap->name == &null
                if !named && !all {
                    continue
                }

                // A global is named, not captured; `self` keeps its own
                // receiver type: every closure holds it as the pointer it
                // already is (ClosureCaptures, CaptureMode::Receiver). The
                // exception is a script's own top-level `var` seen from the
                // top-level code (P561): there it is the script's local to
                // the reader (closures.mdx `|*|`, ownership.mdx), so `|*|`
                // views it as the pointer and EmitIR names its address.
                if all
                    && (null_flow_is_global(d) && (!top)
                        || isa<ParamDecl>(d) && cast<ParamDecl>(d)->is_self) {
                    continue
                }

                var unsafe *pointee = t
                if cap->is_const {
                    pointee = self.sc->types->qualified(t, QUAL_CONST)
                }

                return self.sc->types->pointer(pointee, false)
            }
        }

        return &null
    }

    /// \p d is a top-level `var` of the script this TU is, and the use sits
    /// in the top-level code itself (no function frame under the closures):
    /// the one place a global reads as a local, so `|*|` takes its address.
    /// A function in the script names it as the global it is, captured or
    /// not; `static`, `thread` and `eval` bindings stay globals everywhere.
    fn script_top_capture(self, d: unsafe *Decl) -> bool {
        if self.sc == &null || !script_top_var(self.sc->script_root, d) {
            return false
        }

        for var k: usize = 0; k < self.frames.size(); ++k {
            if self.frames[k].fn_decl != &null {
                return false
            }
        }

        return true
    }

    /// Closure \p n captures the script variable \p d by copy (P947): \p d
    /// reads as a local here (script_top_capture), and \p n and every
    /// closure around it ask for a copy. ClosureCaptures::_open_copy is the
    /// same rule over its own walk; the closure's type (raw or not) and its
    /// capture list must agree.
    fn script_copy_capture(self, n: unsafe *Expressions::ClosureExpr, d: unsafe *Decl) -> bool {
        if (!self.script_top_capture(d)) || (!copies_script_var(n, d)) {
            return false
        }

        for var k: usize = 0; k < self.frames.size(); ++k {
            var unsafe *c = self.frames[k].closure
            if c != &null && c != n && (!copies_script_var(c, d)) {
                return false
            }
        }

        return true
    }

    /// A use of the nullable place \p d: the analysis remembers its state
    /// here, for the consumer that may need the value (NullnessFlow::
    /// read_value). The use itself stays `T?`: `x?`, `x = null` and a `T?`
    /// argument never read the value.
    priv fn _note_place_read(self, n: unsafe *NamedIdentExpr, d: unsafe *Decl, t: unsafe *Type) {
        if !null_flow_type_is_nullable(t) {
            return
        }

        var place = cxx::std::vector<unsafe *Decl>()
        place.push_back(d)
        self.flow.note_read(n, unsafe &place)
    }

    /// The consumer of \p e needs its value: narrow it when its place is
    /// proven non-null here, else the §4 error (NullnessFlow::read_value).
    /// Returns \p e's type after (the `T` when narrowed), or null when the
    /// error was reported and \p e poisoned.
    fn read_value(self, e: unsafe *Expr) -> unsafe *Type {
        if e == &null {
            return &null
        }

        if self.flow.read_value(e, true) == NULL_READ_REFUSED {
            return &null
        }

        return e->type_
    }

    /// \p e, typed \p t, as a consumer that takes the nullable as well as
    /// its value sees it: the `T` when \p e is a nullable place proven
    /// non-null here (narrowed), else \p t unchanged and no error.
    fn value_if_proven(self, e: unsafe *Expr, t: unsafe *Type) -> unsafe *Type {
        if t == &null || self.tu.nullable_inner(t) == &null {
            return t
        }

        if self.flow.read_value(e, false) == NULL_READ_NARROWED {
            return e->type_
        }

        return t
    }

    /// # type-denoting expressions

    /// The record a type decl denotes in expression position, applying
    /// explicit generic args or leaving the pattern. The args go through
    /// GenericArgs, the rule a type position uses: `std::vector<i32>()` is
    /// legal because _Alloc has a default.
    fn type_from_type_decl(self,
                           d:     unsafe *Decl,
                           gargs: FrozenList<ChainType::GenericArg>,
                           at:    unsafe *Expr) -> unsafe *Type {
        if isa<ExtensionDecl>(d) {
            var unsafe *e = cast<ExtensionDecl>(d)
            if e->target == &null || e->target->canonical == &null {
                self.mark_unknown(at)
                return &null
            }

            return e->target->canonical
        }

        if isa<TypeAliasDecl>(d) {
            var unsafe *td = cast<TypeAliasDecl>(d)
            if td->aliased == &null || td->aliased->canonical == &null {
                self.mark_unknown(at)
                return &null
            }

            var unsafe *body = td->aliased->canonical
            if td->generic_params.size() == 0 || gargs.size() == 0 {
                return body
            }

            // A generic alias APPLIED in an expression (`KA<i32>(x)`,
            // `kairo::std::Atomic<*T>(&null)`): its body with the arguments
            // substituted in, as TypeResolve::_apply_alias does for a type
            // position. Returning the body bare made the call construct the
            // PATTERN (`Box<T>`), a dependent type in non-generic code: the
            // constructor went unselected and `&null` had no pointer type.
            var gps = td->generic_params
            var ga  = GenericArgs(self.sc)
            if !ga.check_arity(d, self.tu.decl_name(d), gps, gargs.size(), at->range) {
                self.poison_only(at)
                return &null
            }

            for var i: usize = 0; i < gargs.size(); ++i {
                var unsafe *g = gargs.get(i)
                if g->ty == &null || g->ty->is_poisoned() {
                    self.poison_only(at)
                    return &null
                }
            }

            var args = cxx::std::vector<unsafe *Type>()
            if !ga.collect(d, gps, gargs, true, unsafe &args) {
                self.poison_only(at)
                return &null
            }

            var ded    = Deduction(self.sc, &null)
            var owners = cxx::std::vector<unsafe *Decl>()
            owners.push_back(d)
            var unsafe *rep = NameLookup::representative(d)
            if rep != d {
                owners.push_back(rep)
            }

            for var o: usize = 0; o < owners.size(); ++o {
                var k: usize = 0
                for var i: usize = 0; i < gps.size(); ++i {
                    var unsafe *gp = gps[i]
                    if gp == &null {
                        continue
                    }

                    if gp->is_pack {
                        ded.open_pack(owners[o], gp->index)
                        for var j: usize = k; j < args.size(); ++j {
                            ded.push_pack(owners[o], gp->index, args[j])
                        }

                        k = args.size()
                        continue
                    }

                    if k >= args.size() {
                        return body
                    }

                    ded.bind(owners[o], gp->index, args[k])
                    k += 1
                }
            }

            var unsafe *applied = ded.substitute(body)
            return if (applied != &null) => (applied) else => body
        }

        var unsafe *rep = NameLookup::representative(d)
        var        gps  = self.tu.generic_params_of(rep)
        var        args = cxx::std::vector<unsafe *Type>()
        var        dep  = false
        if gargs.size() > 0 {
            var ga = GenericArgs(self.sc)
            if !ga.check_arity(rep, self.tu.decl_name(rep), gps, gargs.size(), at->range) {
                self.poison_only(at)
                return &null
            }

            for var i: usize = 0; i < gargs.size(); ++i {
                var unsafe *g = gargs.get(i)
                if g->ty == &null || g->ty->is_poisoned() {
                    self.poison_only(at)
                    return &null
                }
            }

            if !ga.collect(rep, gps, gargs, true, unsafe &args) {
                self.poison_only(at)
                return &null
            }

            dep = ga.inst_dependent
            for var i: usize = 0; i < args.size(); ++i {
                if args[i]->is_dependent() || args[i]->is_instantiation_dependent() {
                    dep = true
                }
            }
        } else {
            for var i: usize = 0; i < gps.size(); ++i {
                var unsafe *gp = gps[i]
                if gp == &null {
                    continue
                }

                dep = true
                args.push_back(self.sc->types->generic_param(rep, gp->index, gp->is_pack))
            }
        }

        if dep || args.size() == 0 {
            return self.sc->types->record(rep, unsafe &args)
        }

        var unsafe *e = self.sc->instances->instance_for(
            rep,
            unsafe &args,
            self.sc->ctx->fid,
            NameLookup::ctx_of(rep),
        )

        var unsafe *inst = if (e != &null) => (e->decl) else => rep
        return self.sc->types->record(inst, unsafe &args)
    }

    fn note_type_expr(self, e: unsafe *Expr, t: unsafe *Type) {
        self._typeexp[e as usize as u64] = t
    }

    fn note_module_expr(self, e: unsafe *Expr) {
        self._modexp.insert(e as usize as u64)
    }

    /// The type \p e denotes, or null when it is a value / unknown.
    fn denoted_type(self, e: unsafe *Expr) -> unsafe *Type {
        if e == &null {
            return &null
        }

        self.type_of(e, &null)
        var it = self._typeexp.find(e as usize as u64)
        if it == self._typeexp.end() {
            // A bare primitive (`u32` in `typeof T == u32`): N leaves
            // the head unbound on purpose (CallTyping: `u32(x)`); it still
            // names its builtin.
            var unsafe *id = dyn_cast<NamedIdentExpr>(e)
            if id != &null && is_annotation(id->name.kind) && !id->is_poisoned() {
                var unsafe *b = self.tu.builtin(builtin_for_token(id->name.kind))
                if b != &null {
                    self.note_type_expr(e, b)
                }

                return b
            }

            return &null
        }

        return it->second
    }

    /// \p e, already typed, names a type (`P`, `ns::P`, `T`, `(P)`) or is
    /// `typeof x` where a VALUE is required: an initializer, an argument,
    /// an operand, a converted value. A type-denoting expression has
    /// no type by design (finish: the callee or member base that reads it
    /// takes it from the side table), so every value consumer saw "unknown"
    /// and let it through untyped to codegen. Reported here, \p e poisoned,
    /// so the consumer propagates. \return reported (or already poisoned
    /// by this).
    fn reject_type_value(self, e: unsafe *Expr) -> bool {
        if e == &null || e->is_poisoned() || e->type_ != &null {
            return false
        }

        var unsafe *x = self.tu.strip_parens(e)
        if x == &null {
            return false
        }

        if isa<Expressions::TypeOfExpr>(x) {
            // TypeInfo (type-system.mdx) is the value form; it does not exist
            // yet. An operand that left typeof unknown is the generic's.
            if x->is_instantiation_dependent()
                && self._typeexp.find(x as usize as u64) == self._typeexp.end() {
                return false
            }

            self.sc->diag->report(
                DiagID::SC271E,
                x->range.start,
                "'typeof' as a value is a 'TypeInfo', which is not implemented yet; as a type ('var y: typeof x') it is supported",
            ).first(x->range)->emit()
            e->poison()
            return true
        }

        var t: unsafe *Type = &null
        var it = self._typeexp.find(e as usize as u64)
        if it != self._typeexp.end() {
            t = it->second
        } else {
            // A bare primitive (`x == u32`, P381): N leaves it unbound on
            // purpose (denoted_type), so it never reaches the side table and
            // every value consumer saw "unknown" and passed it on silently.
            var unsafe *id = dyn_cast<NamedIdentExpr>(x)
            if id == &null || (!is_annotation(id->name.kind)) {
                return false
            }

            t = self.tu.builtin(builtin_for_token(id->name.kind))
            if t == &null {
                return false
            }
        }

        var text = self.sc->ctx->get_spelling(e->range)
        var b = self.sc->diag->report(
            DiagID::SC094E,
            e->range.start,
            f"'{text}' is a type, not a value",
        )

        b.first(e->range, "a type is used here where a value is required")
        // A Kairo record's name is one `()` away from its default-constructed
        // value, which is the likely intent (`var p = P` for `var p = P()`).
        // Anything else (a builtin, a pointer, a parameter T) has no single
        // obvious edit.
        var unsafe *c = canon_unqual(t)
        if c != &null && isa<RecordType>(c) && !isa<InterfaceDecl>(cast<RecordType>(c)->decl) {
            b.insert(e->range.end, "()", f"construct a '{text}'")
        }

        b.emit()
        e->poison()
        return true
    }

    fn denotes_module(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        return self._modexp.contains(e as usize as u64)
    }

    /// # chain side table

    fn new_chain_info(self, n: *ChainExpr) -> unsafe *ChainInfo {
        return self._fresh_chain((unsafe (n as unsafe *Expr)) as usize as u64)
    }

    fn new_chain_info_for_ident(self, n: unsafe *NamedIdentExpr) -> unsafe *ChainInfo {
        return self._fresh_chain((unsafe (n as unsafe *Expr)) as usize as u64)
    }

    /// A reset ChainInfo for \p key at a stable address. Re-typing an expr
    /// resets its existing record in place, as the by-value map did, so a
    /// pointer handed out earlier still names the live one.
    priv fn _fresh_chain(self, key: u64) -> unsafe *ChainInfo {
        var unsafe **slot = unsafe &self._chains[key]
        if *slot != &null {
            **slot = ChainInfo()
            return *slot
        }

        var unsafe *p = self._chain_arena.Allocate(1)
        cxx::std::construct_at(p)
        *slot = p
        return p
    }

    fn chain_info(self, n: *ChainExpr) -> unsafe *ChainInfo {
        var it = self._chains.find((unsafe (n as unsafe *Expr)) as usize as u64)
        if it == self._chains.end() {
            return &null
        }

        return it->second
    }

    fn ded_scratch(self) -> *Deduction {
        self._scratch_ded = Deduction(self.sc, unsafe &self.conv)
        return &self._scratch_ded
    }

    /// The fn-pointer canonical of a non-generic function. The receiver is
    /// not a parameter of the type; every other parameter's MODE is.
    fn fn_pointer_type(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        var ps = cxx::std::vector<unsafe *Type>()
        var ms = cxx::std::vector<ParamMode>()
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            if p->type_ == &null || p->type_->canonical == &null {
                return &null
            }

            // a function type has no top-level cv on its parameters ([dcl.fct]/5)
            ps.push_back(canon_unqual(p->type_->canonical))
            ms.push_back(p->mode)
        }

        var unsafe *r = self.fn_return_type(f)
        if r == &null {
            return &null
        }

        // The effect is part of the type (Compiler/Spec/Panic.md#declared-sets): the DECLARED set.
        // A bare `panic` function's set is inferred only past the Typed
        // barrier, so its value type carries `panic` with no set here, and
        // PanicEffectChecking rejects such a function used as a value.
        var pset = cxx::std::vector<unsafe *Type>()
        if f->is_panic() {
            canonical_set(unsafe &self.tu, &panic_home(f)->panic_set, unsafe &pset)
        }

        // A named function is a function pointer: the raw `unsafe fn`, which
        // widens to a `fn` value wherever one is wanted (Conversion).
        // Its calling convention is part of that type (either link of the
        // chain may carry it; RedeclMerge holds them to one).
        var cc = f->call_conv
        if cc == 0 && f->canonical_decl() != &null {
            cc = f->canonical_decl()->call_conv
        }

        return self.sc->types->func(
            unsafe &ps,
            unsafe &ms,
            r,
            f->is_panic(),
            unsafe &pset,
            true,
            cc,
        )
    }

    /// The fn-pointer canonical of generic \p f's instance at the arguments
    /// \p gl names (`pick<i32>` as a value): fn_pointer_type over the
    /// signature with every parameter bound. Null, so the name stays a
    /// callable, unless every generic parameter is given positionally and is
    /// a type: a pack's or a value parameter's argument is not modelled
    /// here, and a partial list leaves the rest to a call's deduction.
    fn generic_fn_value_type(self,
                             f:  unsafe *FunctionDecl,
                             gl: unsafe *FrozenList<ChainType::GenericArg>) -> unsafe *Type {
        if gl == &null || gl->size() == 0 || gl->size() != f->generic_params.size() {
            return &null
        }

        var unsafe *rep = NameLookup::representative(f)
        var        sub  = Substitution(self.sc)
        for var i: usize = 0; i < gl->size(); ++i {
            var unsafe *gp = f->generic_params[i]
            var unsafe *ga = gl->get(i)
            if gp == &null || gp->is_pack || gp->is_const_param {
                return &null
            }

            if ga->name_range.start.is_valid() {
                return &null
            }

            if ga->ty == &null || ga->ty->canonical == &null {
                return &null
            }

            sub.bind(rep, gp->index, ga->ty->canonical)
        }

        var ps = cxx::std::vector<unsafe *Type>()
        var ms = cxx::std::vector<ParamMode>()
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            if p->type_ == &null || p->type_->canonical == &null {
                return &null
            }

            var unsafe *pt = sub.substitute(p->type_->canonical)
            if pt == &null {
                return &null
            }

            ps.push_back(canon_unqual(pt))
            ms.push_back(p->mode)
        }

        var unsafe *r0 = self.fn_return_type(f)
        if r0 == &null {
            return &null
        }

        var unsafe *r = sub.substitute(r0)
        if r == &null {
            return &null
        }

        var pset0 = cxx::std::vector<unsafe *Type>()
        var pset  = cxx::std::vector<unsafe *Type>()
        if f->is_panic() {
            canonical_set(unsafe &self.tu, &panic_home(f)->panic_set, unsafe &pset0)
        }

        for var i: usize = 0; i < pset0.size(); ++i {
            var unsafe *e = sub.substitute(pset0[i])
            if e == &null {
                return &null
            }

            pset.push_back(e)
        }

        var cc = f->call_conv
        if cc == 0 && f->canonical_decl() != &null {
            cc = f->canonical_decl()->call_conv
        }

        return self.sc->types->func(
            unsafe &ps,
            unsafe &ms,
            r,
            f->is_panic(),
            unsafe &pset,
            true,
            cc,
        )
    }

    /// \p child came back as a callable, not a value, where its parent needs
    /// a value: an operand, a cast's source. A callable has no type
    /// by design (finish), and every such parent returned null with no
    /// diagnostic, which finish() reported as an internal error. A function
    /// with a type (a plain function, a generic one's instance) never gets
    /// here. \return reported.
    fn reject_callable_value(self, child: unsafe *Expr) -> bool {
        if child == &null
            || child->is_poisoned()
            || child->type_ != &null
            || child->is_instantiation_dependent() {
            return false
        }

        var it = self._chains.find(child as usize as u64)
        if it == self._chains.end() || it->second->callable_cands.size() == 0 {
            return false
        }

        var        text = self.sc->ctx->get_spelling(child->range)
        var unsafe *f   = dyn_cast<FunctionDecl>(it->second->callable_cands[0])
        var        msg  = f"'{text}' is a function, not a value here; call it"
        if it->second->callable_cands.size() == 1
            && f != &null
            && !f->is_method()
            && f->generic_params.size() > 0 {
            msg = f"'{text}' is a generic function; it is a value only as one instance, with every generic argument written"
        } else if it->second->callable_cands.size() > 1 {
            msg = f"'{text}' names an overloaded function, not a value; call it"
        }

        self.sc->diag->report(DiagID::SC094E, child->range.start, msg).first(child->range)->emit()
        child->poison()
        return true
    }

    /// # outcomes

    fn fail(self, e: unsafe *Expr, id: DiagID, const msg: string) {
        if e == &null {
            return
        }

        if !e->is_poisoned() {
            self.sc->diag->report(id, e->range.start, msg).first(e->range)->emit()
        }

        e->poison()
    }

    fn warn(self, e: *Expr?, id: DiagID, const msg: string) {
        if e == &null {
            return
        }

        self.sc->diag->report(id, e->range.start, msg).first(e->range)->emit()
    }

    /// \p e asks a bounds-checked parameter \p gp (TypeUtil::checked_param)
    /// for something only a bound can grant (Compiler/Spec/Generics.md#decisions): an operator, a
    /// conversion, an interpolation. \p msg says what and which requirement
    /// would grant it. R051E when \p gp has no bound at all (R051's "not its
    /// operators"); R025E when it has bounds and none declares it (the
    /// bounds are the scope, and the scope was searched). The note points at
    /// the parameter, which is where the fix goes. No fix-it: which
    /// interface should carry the requirement is the author's call.
    fn needs_bound(self, e: *Expr?, gp: unsafe *Decl, bounded: bool, const msg: string) {
        if e == &null {
            return
        }

        if e->is_poisoned() {
            return
        }

        var pname = self.tu.decl_name(gp)
        if bounded {
            var b = self.sc->diag->report(
                DiagID::R025E,
                e->range.start,
                f"{msg}; none of the bounds of '{pname}' does",
            )

            b.first(e->range)
            b.note(
                gp->range.start,
                f"'{pname}' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it",
            )

            b.emit()
        } else {
            var b = self.sc->diag->report(DiagID::R051E, e->range.start, msg)
            b.first(e->range)
            b.note(
                DiagCode(DiagID::R051N),
                gp->range.start,
                f"'{pname}' is declared with no bound",
            )->child_first(gp->range)
            b.emit()
        }

        e->poison()
    }

    /// Poison without a diagnostic: the child already reported.
    fn poison_only(self, e: unsafe *Expr) {
        if e != &null {
            e->poison()
        }
    }

    fn mark_unknown(self, e: unsafe *Expr) {
        if e == &null {
            return
        }

        e->expr_flags.set(Expr::ExprFlags::IsInstantiationDependent)
    }

    /// Lift a child's poison / unknown onto \p e. True when \p e cannot be typed.
    fn propagate(self, e: unsafe *Expr, child: unsafe *Expr) -> bool {
        if child == &null {
            return false
        }

        if child->is_poisoned() {
            e->poison()
            return true
        }

        // A callable read as a value. A paren is no consumer: it is
        // a callable too (a callee `(f)` is one), and its parent asks.
        if isa<Expressions::ParenExpr>(e) {
            var ci = self._chains.find(child as usize as u64)
            if child->type_ == &null
                && ci != self._chains.end()
                && ci->second->callable_cands.size() > 0 {
                var unsafe *info = ci->second // before the insert below moves the buckets.
                self._chains[e as usize as u64] = info
            }
        } else if self.reject_callable_value(child) {
            e->poison()
            return true
        }

        if child->type_ == &null && child->is_instantiation_dependent() {
            self.mark_unknown(e)
            return true
        }

        if child->is_dependent() {
            e->expr_flags.add_all(child->expr_flags)
        }

        return false
    }

    fn is_lvalue(self, e: unsafe *Expr) -> bool {
        var unsafe *x = self.tu.strip_parens(e)
        if x == &null {
            return false
        }

        return x->value_category == Expr::ValueCategory::LValue
    }

    /// \p e, accepted into \p to, converts through a user `@implicit op as`:
    /// record which, for FnPurityCheck (SemaContext::implicit_convs). A
    /// record source only; the identity and every builtin rung leave it.
    priv fn _note_implicit_op(self, e: unsafe *Expr, from: unsafe *Type, to: unsafe *Type) {
        var unsafe *fu = self.tu.as_value(from)
        var unsafe *tv = self.tu.as_value(to)
        if fu == &null || tv == &null || fu == tv || !isa<RecordType>(fu) {
            return
        }

        var unsafe *conv_fn = self.conv.implicit_op(fu, tv)
        if conv_fn != &null {
            self.sc->implicit_convs[e as usize as u64] = conv_fn
        }
    }

    /// Implicit-convert check at a use site. Diagnoses and poisons \p e on
    /// failure; silent on unknown / already poisoned.
    fn check_convertible(self, e: unsafe *Expr, to: unsafe *Type) -> bool {
        if e == &null || to == &null {
            return true
        }

        if e->is_poisoned() {
            return false
        }

        var unsafe *from = e->type_
        if from == &null { // unknown: nothing to check here; a type is no value.
            return !self.reject_type_value(e)
        }

        if to->is_dependent() {
            // `return t` from a `T?` into a `T` in a generic body: the same
            // read of the value as below, decidable before instantiation.
            var unsafe *din = self.flow.narrowed_type(from)
            if din != &null && canon_unqual(din) == canon_unqual(to) {
                return self.flow.read_value(e, true) != NULL_READ_REFUSED
            }

            return true
        }

        var r = self.conv.implicit(from, to)
        if r != ImplicitRank::None {
            self._note_implicit_op(e, from, to)
            return true
        }

        // A `T?` place where a `T` is wanted is a read of its value (§4):
        // narrowed when proven non-null here, else the nullness error in
        // place of "cannot convert". Only when the value would convert.
        var unsafe *nin = self.flow.narrowed_type(from)
        if nin != &null && self.conv.implicit(nin, to) != ImplicitRank::None {
            var o = self.flow.read_value(e, true)
            if o == NULL_READ_REFUSED {
                return false
            }

            if o == NULL_READ_NARROWED {
                return true
            }
        }

        // `fn` -> `unsafe fn`: no conversion, and the reason is the capture.
        var unsafe *ffp = dyn_cast<FunctionPointerType>(canon_unqual(from))
        var unsafe *tfp = dyn_cast<FunctionPointerType>(canon_unqual(to))
        // Across calling conventions, either way: a caller through the
        // target type would save the wrong registers (Conversion).
        if ffp != &null && tfp != &null && ffp->call_conv != tfp->call_conv {
            var fs = self.tu.str(from)
            var ts = self.tu.str(to)
            var fc = LangAttrs::call_conv_name(ffp->call_conv)
            var tc = LangAttrs::call_conv_name(tfp->call_conv)
            var fcs = if (fc.size() == 0) => ("the default calling convention")
                      else => "'@" + fc + "'"
            var tcs = if (tc.size() == 0) => ("the default calling convention")
                      else => "'@" + tc + "'"
            var b = self.sc->diag->report(
                DiagID::SC028E,
                e->range.start,
                f"cannot convert '{fs}' to '{ts}': the calling conventions differ",
            )

            b.first(e->range)
            b.note(e->range.start, f"the value has {fcs}; the target type has {tcs}")
            b.emit()
            e->poison()
            return false
        }

        if ffp != &null && tfp != &null && tfp->is_raw && !ffp->is_raw {
            var what = "a 'fn' value may hold a capturing closure, which has no function pointer"
            if isa<Expressions::ClosureExpr>(self.tu.strip_parens(e)) {
                what = "this closure captures, so it has no function pointer"
            }

            var b = self.sc->diag->report(
                DiagID::SC258E,
                e->range.start,
                f"cannot convert '{self.tu.str(from)}' to the raw '{self.tu.str(to)}': {what}",
            )

            b.first(e->range)
            b.note(
                e->range.start,
                "only a named function or a closure that captures nothing is a raw 'unsafe fn'",
            )

            b.emit()
            e->poison()
            return false
        }

        // C++ initialises a class from a value through ONE user-defined
        // conversion ([dcl.init]/17.6.3, [over.best.ics]); Kairo applies it
        // only under -fcxx-implicit-conv, exactly as at a call argument
        // (P813), and initialisation, assignment and return reach the same
        // C++ boundary (P834). -fimplicit-conv is the Kairo-side rules and
        // has no say here. Without the flag the error says which conversion
        // C++ would have used and the fix-it writes the cast.
        var via = self._cxx_user_conv(e, from, to)
        if via != "" {
            if self.sc->cxx_implicit_conv_on() {
                // C++ performs the conversion, so the value goes as written:
                // a literal as its bytes, the `const char[N]` C++ converts
                // from (as CallTyping does for a user_convs argument). Typed
                // as a Kairo string it would be a builtin::string, which no
                // C++ constructor takes.
                var sl = self.tu.c_string_literal(e)
                if sl != &null {
                    var unsafe *cc = self.sc->types->qualified(self.tu.builtin(BuiltinKind::CChar), QUAL_CONST)
                    sl->c_string = self.sc->types->pointer(cc, true)
                }

                return true
            }

            var tn = self.tu.str(to)
            var b  = self.sc->diag->report(
                DiagID::SC028E,
                e->range.start,
                f"cannot convert '{self.tu.str(from)}' to '{tn}'",
            )

            b.first(e->range)
            var ue = self.tu.strip_parens(e)
            if isa<Expressions::BinaryOperatorExpr>(ue)
                || isa<Expressions::AssignOperatorExpr>(ue)
                || isa<Expressions::RangeExpr>(ue) {
                b.insert(e->range.start, "(", "convert explicitly")
                b.insert(e->range.end, f") as {tn}", "convert explicitly")
            } else {
                b.insert(e->range.end, f" as {tn}", "convert explicitly")
            }

            b.note(
                e->range.start,
                f"C++ would convert the value to '{tn}' implicitly through {via}; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given: write 'as {tn}', or pass -fcxx-implicit-conv",
            )

            b.emit()
            e->poison()
            return false
        }

        var hint = ""
        // A C++ `u64&` reads as its referee (P376): kind_of sees a reference,
        // not a builtin, and the lossy-conversion hint was never chosen.
        var fk   = self.tu.kind_of(self.tu.as_value(from))
        var tk   = self.tu.kind_of(to)
        if fk != BuiltinKind::COUNT && tk != BuiltinKind::COUNT {
            match self.conv.classify(fk, tk) {
                case ConvClass::E {
                    hint = "; the conversion may lose value and needs an explicit 'as'"
                } case ConvClass::U {
                    hint = "; the conversion needs 'as' inside an unsafe context"
                } case ConvClass::W {
                    hint = "; implicit conversions are disabled (-fno-implicit-conv), write 'as'"
                } default {
                    0
                }
            }
        } else if self.tu.nullable_inner(from) != &null && self.tu.strip_nullable(from) == to {
            hint = "; the value may be null, use '??' or 'unwrap!()'"
        } else if self.tu.pointee(to) != &null && self.tu.pointee(from) == &null {
            hint = "; take the address with '&'"
        } else if self.tu.pointee(from) != &null && self.tu.pointee(to) != &null {
            // Safety first: `unsafe *T -> *T` is one record on both sides,
            // and derives_from(T, T) holds, so the record test would call it
            // a downcast.
            var unsafe *fd   = self.tu.record_decl(self.tu.pointee(from))
            var unsafe *td   = self.tu.record_decl(self.tu.pointee(to))
            var unsafe *lost = self._dropped_qual(from, to)
            if lost != &null && self.tu.is_unsafe_ptr(to) && self.tu.is_unsafe_ptr(from) {
                // No implicit conversion drops a qualifier, unsafe or not:
                // the drop is a written reinterpret, and the block is what
                // lets that cast through.
                var what = if (canon_has_const(lost)) => ("const") else => "volatile"
                var how = if (self.in_unsafe()) => ("write 'as unsafe *T'")
                          else => "write 'as unsafe *T' inside an 'unsafe' block"
                hint = f"; the conversion drops '{what}' from the pointee '{self.tu.str(lost)}', which only a cast does: {how}"
            } else if self.tu.is_unsafe_ptr(to) && !self.tu.is_unsafe_ptr(from) {
                hint = "; a safe pointer becomes a raw one only explicitly: 'unsafe &x', or 'as unsafe *T' inside an unsafe block"
            } else if self.tu.is_unsafe_ptr(from) && !self.tu.is_unsafe_ptr(to) {
                hint = "; a raw pointer becomes safe only by 'as *T' inside an unsafe block"
            } else if fd != &null
                && td != &null
                && fd != td
                && Substitution(self.sc).derives_from(self.tu.pointee(to), self.tu.pointee(from)) {
                hint = "; a base-to-derived pointer needs an explicit 'as'"
            }
        }

        self.sc->diag->report(
            DiagID::SC028E,
            e->range.start,
            f"cannot convert '{self.tu.str(from)}' to '{self.tu.str(to)}'{hint}",
        ).first(e->range)->emit()
        e->poison()
        return false
    }

    /// How C++ would initialise the C++ class \p to from \p e (of type
    /// \p from) with ONE user-defined conversion -- `'View(const char *)'`
    /// or `'operator C'` -- or "" when it would not, or when either side is
    /// not C++'s to judge. Only what C++ itself sees at the boundary: a
    /// string literal (`const char[N]`, decayed) or a C++ class value; a
    /// Kairo `string` VALUE has `.c_str()` and no implicit route into C++
    /// (c-cpp.mdx). OverloadResolution::_cxx_conv_via is the call-argument
    /// twin; clang answers here, under the class's own header set.
    priv fn _cxx_user_conv(self, e: unsafe *Expr, from: unsafe *Type, to: unsafe *Type) -> string {
        var unsafe *tu = canon_unqual(to)
        if tu == &null || (!isa<RecordType>(tu)) || (!self._is_cxx_class(tu)) {
            return ""
        }

        var        lit = self.tu.c_string_literal(e) != &null
        var unsafe *fv = self.tu.as_value(from)
        var unsafe *fu = if (fv != &null) => (canon_unqual(fv)) else => &null
        if (!lit) && (fu == &null || (!isa<RecordType>(fu)) || (!self._is_cxx_class(fu))) {
            return ""
        }

        if !lit {
            if self.conv.cxx_conversion_op(fv, tu) != &null {
                return f"'operator {self.tu.str(to)}\x27"
            }
        }

        if self.sc->foreign == &null {
            return ""
        }

        var src: unsafe *Type = fv
        var cat               = e->value_category
        var lit_n: u64        = 0
        if lit {
            var unsafe *cc = self.sc->types->qualified(self.tu.builtin(BuiltinKind::CChar), QUAL_CONST)
            src   = self.sc->types->pointer(cc, true)
            cat   = Expr::ValueCategory::RValue
            lit_n = LowerSynth(self.sc).c_literal_extent(self.tu.c_string_literal(e))
        }

        var unsafe *d = self.tu.record_decl(tu)
        if self.sc->foreign->cxx_converts(d, src, cat, tu, lit_n) {
            return f"'{self.tu.str(to)}({self.tu.str(src)})\x27"
        }

        var unsafe *pd = self.tu.pattern_of(d)
        if pd != &null && pd != d && self.sc->foreign->cxx_converts(pd, src, cat, tu, lit_n) {
            return f"'{self.tu.str(to)}({self.tu.str(src)})\x27"
        }

        return ""
    }

    priv fn _is_cxx_class(self, t: unsafe *Type) -> bool {
        var unsafe *d = self.tu.record_decl(t)
        if d == &null {
            return false
        }

        return decl_is_imported(d) || decl_is_imported(self.tu.pattern_of(d))
    }

    /// The first pointee level (outermost first) of \p from carrying a
    /// qualifier the same level of \p to lacks, or &null. Walks while both
    /// sides are pointers, so `*const u8 -> *void` drops at the first level
    /// although the pointees differ.
    priv fn _dropped_qual(self, from: unsafe *Type, to: unsafe *Type) -> unsafe *Type {
        var unsafe *fp = self.tu.pointee(canon_unqual(from))
        var unsafe *tp = self.tu.pointee(canon_unqual(to))
        if fp == &null || tp == &null {
            return &null
        }

        if (canon_quals(fp) & ~canon_quals(tp)) != 0 {
            return fp
        }

        return self._dropped_qual(fp, tp)
    }

    /// # lang items / panic sites

    /// One report per unbound lang item per TU: the "error at USE" rule from
    /// SemaContext.k, without a repeat on every use in the file.
    fn missing_lang_item(self, e: unsafe *Expr, const name: string) {
        for var i: usize = 0; i < self._lang_reported.size(); ++i {
            if self._lang_reported[i] == name {
                self.poison_only(e)
                return
            }
        }

        self._lang_reported.push_back(name)
        self.sc->diag->report(
            DiagID::SC032E,
            e->range.start,
            f"this expression needs the '{name}' lang item, which is not bound in this build",
        ).first(e->range)->note(
            e->range.start,
            "the builtin module that defines it is not in the import set; further uses in this file are not reported",
        )->emit()
        e->poison()
    }

    /// An asserting downcast is a panic site. PanicEffectChecking reads
    /// panic_sites() when it lands; until then the list is inert.
    fn note_panic_site(self, e: unsafe *Expr) {
        self._panics.push_back(e)
    }

    fn defer_enum_cast(self, n: unsafe *Expressions::TypeCastExpr) {
        self._enum_casts.push_back(n)
    }

    /// # RAV routing

    /// Every expression the RAV reaches goes through type_of. A statement
    /// override already typed most of them with an expected type; those are
    /// memo hits. Anything left (an attribute argument, a generic default in
    /// expression position, a requires conjunct) is typed with none.
    fn dispatch_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        if e == &null {
            return e
        }

        self.type_of(e, &null)
        return e
    }

    /// Closures are expressions and are typed through type_of, which pushes
    /// the frame and walks the body itself. The base traversal must not
    /// walk the body a second time with no frame.
    fn traverse_closure_expr(self,
                             n: unsafe *Expressions::ClosureExpr) -> unsafe *Expressions::ClosureExpr {
        if n == &null {
            return n
        }

        self.type_of(n, &null)
        return n
    }

    /// Attribute arguments hang off the annotation mixin; the RAV never
    /// walks them. Type them so a user macro's arguments are not a blind
    /// spot; a miss there is not an error (the attribute checker decides).
    fn visit_decl(self, n: unsafe *Decl) -> bool {
        if n == &null {
            return true
        }

        for var i: usize = 0; i < n->annotations.size(); ++i {
            var unsafe *a = n->annotations.get(i)
            if a == &null || a->kind != AnnotationKind::Attribute {
                continue
            }

            // args is a FrozenList<*void>: the annotation mixin cannot name
            // Expr (AST/Mixin/Annotation.k), but every element is one.
            for var j: usize = 0; j < a->args.size(); ++j {
                self.type_of(a->args[j], &null)
            }
        }

        return true
    }
}
