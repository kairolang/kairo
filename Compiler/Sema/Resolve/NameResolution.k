/// --- The Kairo Project ---------------- Sema/Resolve/NameResolution.k --- ///
///
///   \brief Phase N: bind every identifier use to its declaration.
///
///   \detail
///     Two halves, one pass (run in order, not interleaved):
///
///       N(a) decl validation -- walks dc_decls per scope over the FROZEN
///            tables: link Redeclarable chains, validate overload sets,
///            attach tu->out_of_line, populate sc.well_known. Writes
///            decl-to-decl links only; never inserts into a frozen table.
///
///       N(b) binding -- RAV walk over the TU. Every NamedIdentExpr gets
///            resolved_decl (unique) or candidate_cell (overload set,
///            aliases the frozen cell). ANNOTATES nodes so jump-to-def /
///            completion can query resolution later.
///
///     Lookup itself lives in sc->lookup (NameLookup, the four
///     primitives); this pass owns POLICY only: the lexical local stack
///     (locals are excluded from symbol tables -- executable scopes have
///     no dc_symbols), binding order (locals -> unqualified -> extend
///     target -> clang builtins -> miss), and diagnostics. Redefinition + unresolved-ident + import-access
///     errors live HERE, nowhere else.
///
///   \par Explicitly NOT done here (see Compiler/Spec/Pipeline.md hard invariant #3)
///     - overload SELECTION. A multi-candidate cell is handed through
///       whole; N never filters, not by arity, not by anything.
///     - ADL, types, inference, conformance, extension member lookup.
///     - FUNCTION redecl chains: distinguishing a redeclaration from an
///       overload needs signatures. Deferred deliberately.
///     - alias expansion (NameLookup::context_of returns null for aliases
///       on purpose; T owns expansion).
///     - chain SEGMENTS. A ChainExpr's base is an ordinary unqualified
///       name and IS bound; everything after the first `::`/`.` waits for
///       T. A pattern head is such an expression and is walked like one.
///
///   \par Pattern heads are never binders
///     A bare identifier in a pattern is never a binder: binders are
///     written `var x` / `const x`. So a pattern head (`case MAX`,
///     `case Color::Red`, `case Point(...)`) is bound here like any other
///     name use, and must resolve to an enum variant, a record type or a
///     `const` / `eval` constant (PatternTyping classifies it). A bare head
///     that misses is the ordinary undeclared-identifier error, with a note
///     saying how to write a binder. A dotted head (`.Red`) has no name to
///     bind; PatternTyping resolves it against the scrutinee's enum.
///
///   \par Alternatives share binder decls
///     `case .A(var x), .B(var x)` declares `x` once: the first alternative
///     declares its binders, and every later alternative's binder of the
///     same name is pointed at the first one's decl, so the body sees one
///     `x`. A name with no counterpart in the first alternative is
///     PatternBindingCheck's SC011E; its decl is left alone and undeclared.
///     PatternTyping types the shared decl once and checks every later
///     alternative against it.
///
///   \par Statement-level binders
///     `for x in xs`, `catch e`, `var (a, b) = t`, context bindings and
///     `case var n` all bind: the parser synthesizes a VariableDecl per
///     binder (Binding::decl / CatchArm::decl / BindingPattern::decl) and N
///     pushes it onto the lexical stack for the construct's body. The
///     value/iterable expression is resolved in the OUTER scope first, so
///     `for x in x` names an outer `x`, matching `var x = x`.
///
///   Phase: RESOLVE
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::ImportOverlay::{
    OverlayTarget,
    OverlayVisibility,
}
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_ffi_tag_target,  decl_generic_params, decl_is_ffi,    decl_is_ffi_tag, decl_name_tok,
    decl_requires_clause, decl_set_spec_kind,  decl_spec_args,
}
import AST::Kind::DeclKind::{
    DeclKind,
    to_string,
}
import AST::Kind::ExprKind::to_string
import AST::Kind::PatternKind::{
    PatternKind,
    to_string,
}
import AST::LangItems::{
    WellKnownType,
    to_string,
}
import AST::Mixin::Annotation::{
    AnnotationKind,
    VisibilityKind,
}
import AST::Node::Base::{
    Decl,
    Pattern,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    ClosureExpr,
    TryCatchExpr,
}
import AST::Node::Patterns::{
    AlternationPattern,
    BindingPattern,
    ConstructorPattern,
    SlicePattern,
    TupleDestructurePattern,
    UnresolvedConstructorPattern,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::{
    Binding,   CompoundStmt,  ContextBindingStmt, DeclStmt, DestructuringDeclStmt, IndexedForStmt,
    MatchCase, RangedForStmt, TryCatchStmt,
}
import AST::Node::Types::ChainType
import AST::OperatorFacts::OperatorFacts
import AST::VisibilityFacts::{
    same_module,
    tu_module_dir,
    tu_of_scope,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::{
    NameLookup,
    SemaLookupResult,
}
import Sema::Resolve::ResolutionTrace::{
    TraceMemberKind,
    TraceScopeKind,
    TraceSep,
    TraceVia,
}
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_annotation,
}

///
/// \class LocalScope
/// \brief One executable-scope frame of the N(b) lexical stack: the
///        body locals declared so far in this block/function, in
///        declaration order. Executable scopes have no dc_symbols, so
///        this stack is the ONLY place body locals are findable.
///
///        Lookup walks frames innermost-first (shadowing); within a
///        frame, a local is visible only AFTER its DeclStmt is walked
///        (declare-before-use falls out of push order, no extra check).
///
///        Storage is parallel vecs with a linear scan. Frames are small;
///        do NOT build a hash map until a profile says so.
///
pub class LocalScope {
    pub var names: cxx::std::vector<u32>
    pub var decls: cxx::std::vector<unsafe *Decl>

    fn LocalScope(self) { }

    fn declare(self, imm: u32, d: unsafe *Decl) {
        self.names.push_back(imm)
        self.decls.push_back(d)
    }

    /// Index of \p imm in this frame, latest-first, or usize(-1) on miss.
    /// Latest-first so a same-frame reuse resolves to the newest binding
    /// even in the (diagnosed) redefinition case.
    fn index_of(self, imm: u32) -> usize {
        var n = self.names.size()
        for var i: usize = 0; i < n; ++i {
            var j = n - 1 - i
            if self.names[j] == imm {
                return j
            }
        }

        return usize::MAX
    }

    fn find(self, imm: u32) -> unsafe *Decl {
        var i = self.index_of(imm)
        if i == usize::MAX {
            return &null
        }

        return self.decls[i]
    }

    fn has(self, imm: u32) -> bool {
        return self.index_of(imm) != usize::MAX
    }
}

///
/// \class ShadowHit
/// \brief What a binding HID: the decl the next lookup source out would have
///        answered with, and which source that was. Computed ONLY when the
///        trace is on   it costs a second lookup per binding, and nothing in
///        the compiler's behavior depends on the answer.
///
pub class ShadowHit {
    pub var decl:     unsafe *Decl        = &null
    pub var via:      TraceVia            = TraceVia::None
    pub var frame:    usize               = usize::MAX
    pub var found_in: unsafe *DeclContext = &null

    fn ShadowHit(self) { }

    fn found(self) -> bool {
        return self.decl != &null
    }
}

///
/// \class NameHit
/// \brief One `_resolve_name` outcome. Deliberately NOT a
///        SemaLookupResult: a local binding has no OverloadCell to point
///        at (locals are excluded from symbol tables) and synthesizing one
///        would mean handing out a pointer to a stack temporary.
///
///        Exactly three states:
///          miss      -> found == false
///          unique    -> found, decl != null, cell == null
///          overloaded-> found, decl == null, cell != null (aliases the
///                       FROZEN cell; never a copy)
///
pub class NameHit {
    pub var found:       bool                 = false
    pub var decl:        unsafe *Decl         = &null
    pub var cell:        unsafe *OverloadCell = &null
    pub var via_overlay: bool                 = false
    pub var from_local:  bool                 = false

    /// The TYPE scope that answered, when the answer is a member that a
    /// function body may not name bare (R049). Null for every other hit.
    /// Unlike `found_in` below this one IS binding policy, not trace.
    pub var member_scope: unsafe *DeclContext = &null

    /// Provenance, for the `--print-sema` trace ONLY. Binding policy never
    /// reads these: they record WHICH source answered so a reader can see it,
    /// and a pass that branched on them would change behavior under the flag
    /// that exists to explain it.
    pub var frame:    usize               = usize::MAX ///< answering frame (from_local).
    pub var found_in: unsafe *DeclContext = &null      ///< answering scope (table hit).

    fn NameHit(self) { }

    static fn miss() -> NameHit {
        return NameHit()
    }

    static fn local(d: unsafe *Decl, frame: usize) -> NameHit {
        var h = NameHit()
        h.found      = true
        h.decl       = d
        h.from_local = true
        h.frame      = frame
        return h
    }
}

///
/// \class NameBindingVerifier
/// \brief N's exit test, as code.
///
///        THE invariant: no NamedIdentExpr reachable from tu->program is
///        left with BOTH binding slots null unless N poisoned it -- and N
///        only poisons alongside a diagnostic. A violation means a use site
///        silently fell through every path in visit_named_ident_expr, which
///        is exactly the failure mode that is invisible until T or codegen
///        dereferences the null.
///
///        Pattern heads are skipped for the same reason N skips them: they
///        are deliberately unbound, not accidentally unbound.
///
///        Reports through the DIAG SINK, not assert(): a release build
///        passes -DNDEBUG, so an assert here is compiled out there and the
///        check silently does nothing. A violation is a bug in
///        N, so it is reported as an error   loudly, where a test will see
///        it   rather than left to surface as a null deref in T or codegen.
///
pub class NameBindingVerifier derives RecursiveASTVisitor<NameBindingVerifier> {
    pub var sc:         unsafe *SemaContext
    pub var violations: usize               = 0

    fn NameBindingVerifier(self, sc: unsafe *SemaContext) {
        self.sc = sc
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

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if n == &null {
            return true
        }

        if n->is_bound() || n->is_deferred() {
            return true
        }

        if n->is_poisoned() { // unbound BECAUSE it was diagnosed.
            return true
        }

        if is_annotation(n->name.kind) { // a primitive head: see visit_named_ident_expr.
            return true
        }

        self.violations += 1
        var nm = self.sc->ctx->get_spelling(n->name)
        self.sc->diag->report(
            DiagID::I003E,
            n->range.start,
            f"internal: '{nm}' survived name resolution unbound and undiagnosed "
            "(NameResolution invariant violation, please report)",
        ).first(n->range)->emit()
        return true
    }

    /// A pattern head is an ordinary name use (see the NameResolution
    /// header), so it is held to the same invariant. A dotted head is null.
    fn traverse_constructor_pattern(self,
                                    n: unsafe *ConstructorPattern) -> unsafe *ConstructorPattern {
        if n == &null {
            return n
        }

        if n->head != &null {
            self.dyn()->dispatch_expr(n->head)
        }

        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            self.dyn()->dispatch_pattern(*n->subpatterns.get(i))
        }

        return n
    }

    fn traverse_unresolved_constructor_pattern(self, n: unsafe *UnresolvedConstructorPattern)
            -> unsafe *UnresolvedConstructorPattern {
        if n == &null {
            return n
        }

        if n->head != &null {
            self.dyn()->dispatch_expr(n->head)
        }

        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            self.dyn()->dispatch_pattern(*n->subpatterns.get(i))
        }

        return n
    }
}

///
/// \class NameResolution
/// \brief The N pass. One instance per TU per run; stateless across
///        runs (LSP rebuilds, batch runs once).
///
///        State is exactly two cursors:
///          cur_dc -- the innermost TABLE-OWNING scope (type/module/TU
///                    level). Moved by traverse_* overrides on
///                    scope-owning decls. Feeds sc->lookup.unqualified.
///          locals -- the lexical stack of executable scopes. Pushed/
///                    popped by traverse_compound_stmt /
///                    traverse_function_decl / traverse_closure_expr.
///                    Checked BEFORE unqualified (NameLookup contract).
///
pub class NameResolution derives RecursiveASTVisitor<NameResolution> {
    pub var sc: unsafe *SemaContext

    var cur_dc: unsafe *DeclContext          = &null ///< table-owning scope cursor.
    var locals: cxx::std::vector<LocalScope>         ///< executable-scope stack.

    /// `self` lexes as KwSelf, not LitIdentifier, so ASTContext::
    /// get_ident_imm rejects it. We intern the spelling once and key both
    /// the `self` ParamDecl and every `self` use off that imm. No collision
    /// is possible: `self` is a keyword, so no user identifier shares it.
    priv var _self_imm: u32 = u32::MAX

    /// A function body's params live in the frame pushed by
    /// traverse_function_decl / traverse_closure_expr; the body's own
    /// CompoundStmt must NOT push a second frame or a local would silently
    /// shadow a param instead of colliding with it.
    priv var _suppress_next_block_frame: bool = false

    /// Set while the bare identifier heading an UnresolvedConstructorPattern
    /// (`case n`, `case n(...)`) is being bound, so a miss there can say
    /// how to write the binder the user probably meant.
    priv var _in_pattern_head: bool = false

    /// How many FUNCTION or CLOSURE bodies enclose the cursor. Nonzero means
    /// "inside executable code", which is the only place the explicit-qualifier
    /// rule applies: a field's at-decl default and an enum variant's value are
    /// written IN the type body and keep the type body's scope.
    ///
    /// A counter, not a `cur_dc` walk: an out-of-line `fn Type::m` sets cur_dc
    /// straight to the OWNING TYPE (see traverse_function_decl), so from cur_dc
    /// there is no function scope between the use and the member -- and the rule
    /// has to hold there identically or where a method is written changes what
    /// its body can see.
    priv var _fn_depth: usize = 0

    /// The record scope an enclosing `extend` targets, or null outside one.
    ///
    /// An extend body's DeclContext parents to the TU, not to the type it
    /// extends, so the plain `unqualified` walk cannot see the target's nested
    /// types -- the ONE thing the qualifier rule exempts. Without this an
    /// `extend Foo` body could not write `Nested`, while the identical method
    /// inside `class Foo` could, which is the same inconsistency in the other
    /// direction. Probed AFTER the DC chain, so a real enclosing binding still
    /// wins, and members reached through it get R049 like any other member.
    ///
    /// Resolved by name, never by type resolution: N runs before T, so
    /// `target->canonical` is still null here. A target N cannot name (a
    /// primitive, a structural type, an unresolvable path) leaves this null and
    /// costs nothing -- T reports whatever is wrong with it.
    priv var _ext_target: unsafe *DeclContext = &null
    /// Where the out-of-line definition being resolved was WRITTEN, while its
    /// owning scope (cur_dc) lives in another TU; null otherwise. Set and
    /// restored by traverse_function_decl; read by _lookup_unqualified.
    priv var _ool_lexical: unsafe *DeclContext = &null

    fn NameResolution(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    /// Entry point. Preconditions are ASSERTED, not hoped for: if one
    /// fires, N is being called wrong and the bug is in the driver
    /// schedule (Sema.k), never here.
    /// Postcondition (advanced by the DRIVER, not here): NamesResolved.
    fn run(self) {
        self.sc->require_phase(SemaPhase::Verified)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        self._assert_entry(tu)

        self._self_imm = self.sc->imm_table()->intern_ident_copy("self")

        self._validate_decls(tu) // N(a)
        self._bind(tu)           // N(b)

        // Exit test: no NamedIdentExpr reachable from the program is left
        // with both binding slots null unless N poisoned it (which it only
        // does alongside a diagnostic). Cheap single walk, no allocation.
        var v = NameBindingVerifier(self.sc)
        v.run()
    }

    /// # Entry assertions

    /// The six things that must be true before N may run. Each one is a
    /// driver-schedule contract, so a failure is an ICE, not a diagnostic.
    priv fn _assert_entry(self, tu: unsafe *TranslationUnit) {
        // 1. phase: already checked by require_phase(Verified) above.

        // 2. the overlay exists and is frozen (phase I ran to completion).
        if tu->import_overlay == &null {
            kairo::std::ice_fail("NameResolution: tu->import_overlay is null (phase I did not run)")
        }

        if !tu->import_overlay->is_frozen() {
            kairo::std::ice_fail(
                "NameResolution: tu->import_overlay is not frozen (phase I did not finish)",
            )
        }

        // 4. the shared lookup core is wired to THIS TU. A stale NameLookup
        //    would silently answer with another TU's overlay.
        if self.sc->lookup.tu != tu {
            kairo::std::ice_fail("NameResolution: sc->lookup is not initialized with this TU")
        }

        // 5. there is a program to walk.
        if tu->program == &null {
            kairo::std::ice_fail("NameResolution: tu->program is null")
        }

        // 3. every reachable dc_symbols table is frozen. N writes decl-to-decl
        //    links only; a live table here means the parser never froze.
        self._assert_frozen(tu)

        // 6. out_of_line holds exactly what the parser promised: non-null
        //    FunctionDecls carrying a `Class::` qualifier.
        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var unsafe *d = *tu->out_of_line.get(i)
            if d == &null {
                kairo::std::ice_fail("NameResolution: null entry in tu->out_of_line")
            }

            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
            if f == &null {
                kairo::std::ice_fail("NameResolution: non-FunctionDecl in tu->out_of_line")
            }

            if !f->is_out_of_line() {
                kairo::std::ice_fail("NameResolution: out_of_line entry has no Class:: qualifier")
            }
        }
    }

    priv fn _assert_frozen(self, dc: unsafe *DeclContext) {
        if dc == &null {
            return
        }

        if dc->dc_symbols != &null {
            if dc->dc_symbols != &null && !dc->dc_symbols->is_frozen() {
                kairo::std::ice_fail(
                    "NameResolution: a dc_symbols table is not frozen (parse did not finish)",
                )
            }
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._assert_frozen(NameLookup::context_of(*dc->dc_decls.get(i)))
        }
    }

    /// # N(a): decl validation
    ///
    /// No RAV needed -- this half never enters expressions. Walk dc_decls
    /// per DeclContext, recursing through NameLookup::context_of for
    /// nested type scopes (same shape as ConstraintExtraction's
    /// _recurse_members).

    priv fn _validate_decls(self, tu: unsafe *TranslationUnit) {
        self._validate_context(tu)
        // After every cell: the walk above links each module's blocks into
        // one ring, and only a linked ring says which blocks to compare.
        self._judge_reopenings(tu)
        self._attach_out_of_line(tu)
    }

    /// The type kinds whose declarations chain into one entity: one per
    /// _judge_group case that links rather than reports.
    priv fn _redeclarable(self, d: unsafe *Decl) -> bool {
        return isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::InterfaceDecl>(d)
            || isa<Declarations::EnumDecl>(d)
            || isa<Declarations::ModuleDecl>(d)
    }

    /// One module written as several `module m { }` blocks in this file is
    /// one scope (Compiler/Spec/Imports.md, "as if one block"), but each block keeps its
    /// own table, so _validate_cell never sees `union Payload` in one block
    /// beside `union Payload { }` in another. Unlinked, the two were two
    /// entities and every use of the name was R028E ambiguous. Judge each
    /// name the blocks share as one cell would be: link the forward
    /// declaration to its definition, and report two definitions or two
    /// record keywords exactly as within one block.
    ///
    /// Only the redeclarable type kinds: two functions across blocks are
    /// RedeclMerge's (they need signatures), and a variable beside a type
    /// is the cross-reopening redefinition question still open at M2
    /// (Compiler/Spec/Imports.md item 13a).
    priv fn _judge_reopenings(self, dc: unsafe *DeclContext) {
        if dc == &null {
            return
        }

        var type_body = dc->is_type_scope()
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            if type_body && isa<Declarations::VisibilityGroupDecl>(d) {
                continue
            }

            self._judge_reopenings_of(d)
        }
    }

    priv fn _judge_reopenings_of(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.count; ++i {
                self._judge_reopenings_of(g->members[i])
            }

            return
        }

        if isa<Declarations::EvalBlockDecl>(d) {
            var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
            for var i: usize = 0; i < b->body.count; ++i {
                self._judge_reopenings_of(b->body[i])
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(d) {
            var unsafe *b = cast<Declarations::FFIBlockDecl>(d)
            for var i: usize = 0; i < b->body.count; ++i {
                self._judge_reopenings_of(b->body[i])
            }

            return
        }

        var unsafe *own = NameLookup::context_of(d)
        if isa<Declarations::ModuleDecl>(d) {
            var scopes = cxx::std::vector<unsafe *DeclContext>()
            NameLookup::module_scopes(d, &scopes)
            // Once per ring, from its first block. A nested module's blocks
            // link only here, at the enclosing ring, so the recursion below
            // reaches them already linked.
            if scopes.size() > 1 && scopes[0] == own {
                self._judge_across(scopes)
            }
        }

        self._judge_reopenings(own)
    }

    priv fn _judge_across(self, const scopes: cxx::std::vector<unsafe *DeclContext>) {
        // Tables are keyed by their own TU's imms (hard invariant #2); a ring
        // reaching into a header's namespace is Foreign's, not this file's.
        for var k: usize = 0; k < scopes.size(); ++k {
            var unsafe *s = (scopes)[k]
            if s->dc_symbols == &null || NameLookup::tu_of(s) != self.sc->tu {
                return
            }
        }

        for var k: usize = 0; k < scopes.size(); ++k {
            var rows = cxx::std::vector<SymbolTable::Entry>()
            (scopes)[k]->dc_symbols->collect_entries(&rows)
            for var r: usize = 0; r < rows.size(); ++r {
                var e = rows[r]
                // Judged once, from the first block that declares the name.
                var earlier = false
                for var j: usize = 0; j < k; ++j {
                    if (scopes)[j]->lookup_symbol(e.name) != &null {
                        earlier = true
                        break
                    }
                }

                if earlier {
                    continue
                }

                var group         = cxx::std::vector<unsafe *Decl>()
                var blocks: usize = 0
                for var j: usize = k; j < scopes.size(); ++j {
                    var unsafe *cell = (scopes)[j]->lookup_symbol(e.name)
                    if cell == &null {
                        continue
                    }

                    var took = false
                    for var c: usize = 0; c < cell->size(); ++c {
                        var unsafe *d = cell->get(c)
                        if d == &null {
                            continue
                        }

                        // Already reported within its own block.
                        if d->is_poisoned() {
                            continue
                        }

                        if !self._redeclarable(d) || NameLookup::is_specialization(d) {
                            continue
                        }

                        group.push_back(d)
                        took = true
                    }

                    if took {
                        blocks += 1
                    }
                }

                if blocks > 1 {
                    self._judge_group((scopes)[k], e, unsafe &group)
                }
            }
        }
    }

    /// Fill the build's lang-item table from THIS TU, which must be the builtin
    /// one. Called by Sema between N and T (Sema::_stage_name_resolution): N has
    /// bound the names, and T has not yet resolved `[T;]` in
    /// `Vector(items: const [T;])` -- which is the point, because resolving it
    /// needs the Slice handle this fills.
    ///
    /// The TU fills its OWN table, so the DeclName invariant holds by
    /// construction: the imm indices and the scope are both this file's, and no
    /// key crosses a TU boundary (Compiler/Spec/Pipeline.md hard invariant #2).
    ///
    /// A name missing from Lib/builtin leaves its slot null. That is NOT
    /// diagnosed here -- it is an error at the USE, reported by whichever pass
    /// wanted the item, because a file that never says `[T]` should not be told
    /// about Vector. `Array` is deliberately absent: `[T; N]` stays structural.
    /// Called for EVERY builtin TU, not just the root, and each binds only the
    /// items it actually declares (`_bind_lang` writes nothing on a miss).
    ///
    /// It cannot be the root alone: TUs are type-resolved in reverse tree
    /// order, so `containers/slice.k` -- which declares Slice -- reaches its own
    /// T before `module.k` re-exports it, and `fn Vector(self, const items:
    /// [T;])` would then resolve `[T;]` against an empty table and report the
    /// item missing from inside the builtin root itself.
    fn fill_lang_items(self) {
        if self.sc->g == &null {
            return
        }

        if self.sc->ctx == &null {
            return
        }

        if !self.sc->g->is_builtin_fid(self.sc->ctx->fid) {
            return
        }

        var unsafe *root = unsafe (self.sc->tu as unsafe *DeclContext)
        self._bind_lang(root, WellKnownType::Slice)
        self._bind_lang(root, WellKnownType::Vector)
        self._bind_lang(root, WellKnownType::HashSet)
        self._bind_lang(root, WellKnownType::HashMap)
        self._bind_lang(root, WellKnownType::Hash)
        self._bind_lang(root, WellKnownType::String)

        self._bind_lang(root, WellKnownType::Range)
        self._bind_lang(root, WellKnownType::RangeFrom)
        self._bind_lang(root, WellKnownType::RangeTo)
        self._bind_lang(root, WellKnownType::Ordering)
        self._bind_lang(root, WellKnownType::Future)
        self._bind_lang(root, WellKnownType::Yield)
        self._bind_lang(root, WellKnownType::Nullable)
        self._bind_lang(root, WellKnownType::NullT)
        self._bind_lang(root, WellKnownType::Panic)

        self._bind_lang(root, WellKnownType::ImmBigInt)
        self._bind_lang(root, WellKnownType::ImmBigFloat)

        self._bind_lang(root, WellKnownType::PanicRaise)
        self._bind_lang(root, WellKnownType::PanicCatch)
        self._bind_lang(root, WellKnownType::AssertFail)
        self._bind_lang(root, WellKnownType::Pow)
        self._bind_lang(root, WellKnownType::FmtBuf)
        self._bind_lang(root, WellKnownType::Byte)
        self._bind_lang(root, WellKnownType::UnwrapFailed)
        self._bind_lang(root, WellKnownType::NicheOf)
        self._bind_lang(root, WellKnownType::TypeIdOf)
        self._bind_lang(root, WellKnownType::PanicSiteOf)
        self._bind_lang(root, WellKnownType::CChar)
        self._bind_lang(root, WellKnownType::CWChar)
        self._bind_lang(root, WellKnownType::CChar16)
        self._bind_lang(root, WellKnownType::CChar8)
        self._bind_lang(root, WellKnownType::IsSafePointer)
        self._bind_lang(root, WellKnownType::IsUnsafePointer)
        self._bind_lang(root, WellKnownType::IsNullable)
        self._bind_lang(root, WellKnownType::IsAdtEnum)
        self._bind_lang(root, WellKnownType::IsClass)
        self._bind_lang(root, WellKnownType::IsStruct)
        self._bind_lang(root, WellKnownType::IsTuple)
        self._bind_lang(root, WellKnownType::TupleArity)
        self._bind_lang(root, WellKnownType::Expect)

        // `__builtin_expect` is clang's builtin at every call, and
        // codegen, which emits the call, cannot ask well_known: mark the
        // decl, only from the TU that declares it, before any codegen.
        var unsafe *xd = dyn_cast<Declarations::FunctionDecl>(
            self.sc->well_known->get(WellKnownType::Expect),
        )

        if xd != &null && (xd->semantic_dc) == self.sc->tu {
            xd->lowers_to_expect                   = true
            xd->canonical_decl()->lowers_to_expect = true
        }

        // `__builtin_assume` (what `@assume(c)` parses to) is clang's builtin
        // at every call for the same reason: through the library function the
        // assumption would hold inside that function and tell the caller
        // nothing.
        self._bind_lang(root, WellKnownType::Assume)
        var unsafe *ad = dyn_cast<Declarations::FunctionDecl>(
            self.sc->well_known->get(WellKnownType::Assume),
        )

        if ad != &null && (ad->semantic_dc) == self.sc->tu {
            ad->lowers_to_assume                   = true
            ad->canonical_decl()->lowers_to_assume = true
        }

        // The trivially-copyable / -destructible traits, read by
        // ConformanceChecking at a call that meets a member `requires`.
        self._bind_lang(root, WellKnownType::IsTriviallyCopyable)
        self._bind_lang(root, WellKnownType::IsTriviallyDestructible)

        // `__builtin_dynamic_size` / `_align`: EmitIR writes their bodies
        // (they read T's hidden `__kairo_layout()` when it has one), and it
        // cannot ask well_known either.
        self._bind_lang(root, WellKnownType::DynamicSize)
        self._bind_lang(root, WellKnownType::DynamicAlign)

        // `@create` / `@destroy` (AllocSugarDesugar): bound only by alloc.k,
        // the one builtin TU that declares them; every other builtin TU
        // misses and writes nothing.
        self._bind_lang(root, WellKnownType::Create)
        self._bind_lang(root, WellKnownType::Destroy)
        var unsafe *dsz = dyn_cast<Declarations::FunctionDecl>(
            self.sc->well_known->get(WellKnownType::DynamicSize),
        )

        if dsz != &null && (dsz->semantic_dc) == self.sc->tu {
            dsz->dynamic_layout                   = 1
            dsz->canonical_decl()->dynamic_layout = 1
        }

        var unsafe *dal = dyn_cast<Declarations::FunctionDecl>(
            self.sc->well_known->get(WellKnownType::DynamicAlign),
        )

        if dal != &null && (dal->semantic_dc) == self.sc->tu {
            dal->dynamic_layout                   = 2
            dal->canonical_decl()->dynamic_layout = 2
        }

        // `byte` is spelled as the Byte enum, so a TU that uses it must
        // declare that enum. Codegen has no route to well_known, but every
        // `byte` it walks IS this one build-wide singleton: record it there.
        var unsafe *bd = self.sc->well_known->get(WellKnownType::Byte)
        var unsafe *bt = self.sc->types->builtin(BuiltinKind::Byte)
        if bd != &null && bt != &null {
            cast<BuiltinType>(bt)->lang_decl = bd
        }

        // `null_t`'s constant has no Kairo declaration (`null` is a
        // keyword), so codegen writes it from a mark on the record.
        var unsafe *nd = dyn_cast<Declarations::StructDecl>(
            self.sc->well_known->get(WellKnownType::NullT),
        )

        if nd != &null {
            nd->is_null_type = true
        }

        self._literal_ctor_constexpr()
    }

    /// The string literal constructor, `string(data, len, cp_len)`, the
    /// empty one, the copy constructor and the destructor are C++
    /// `constexpr` and inline (Compiler/Spec/Eval.md#strings-at-compile-time): an eval context builds strings
    /// from `__kairo_estr` bytes with the first, an eval constructor
    /// default-initializes a string field with the second, passing or
    /// returning a string copies it, and an eval binding of one must be
    /// constant-destructible. So all four must run in a constant expression,
    /// and so their bodies must be in every TU that does. Sound because a
    /// compile-time string is always borrowed (`cap == 0`): the copy's
    /// allocation and the destructor's free are on branches a constant
    /// expression never takes, which C++20 allows to call run-time code.
    /// Kairo has no spelling for "compile time and run time both" (`eval fn`
    /// is consteval, and would forbid every run-time copy), so they are
    /// marked here, by the lang item; only by the TU that declares the
    /// record: the one writer, before any TU's codegen reads the flags.
    priv fn _literal_ctor_constexpr(self) {
        var unsafe *sd = self.sc->well_known->get(WellKnownType::String)
        if sd == &null {
            return
        }

        if (sd->semantic_dc) != self.sc->tu {
            return
        }

        var unsafe *dc = NameLookup::context_of(sd)
        if dc == &null {
            return
        }

        var cell = self.sc->lookup.in_context(dc, DeclName::ctor())
        if !cell.found() {
            return
        }

        for var i: usize = 0; i < cell.cell->size(); ++i {
            var unsafe *m = dyn_cast<Declarations::FunctionDecl>(cell.cell->get(i))
            if m == &null {
                continue
            }

            var n: usize = 0
            for var p: usize = 0; p < m->params.size(); ++p {
                if m->params[p] != &null && !m->params[p]->is_self {
                    n += 1
                }
            }

            var lit = n == 0 || n == 3 // the empty string and the literal.
            if !lit && m->transfer != Declarations::TransferKind::Copy {
                continue
            }

            m->modifiers = m->modifiers | Declarations::FnModifier::IsConstexpr | Declarations::FnModifier::IsInline
        }

        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(sd)
        if cd == &null {
            return
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null || !m->is_operator || m->op_token.size() == 0 {
                continue
            }

            if m->op_token[0].kind != TokenKind::KwFinally {
                continue
            }

            m->modifiers = m->modifiers | Declarations::FnModifier::IsConstexpr | Declarations::FnModifier::IsInline
        }
    }

    /// One lang item, by the name it is DECLARED with in Lib/builtin, which is
    /// `to_string(k)` and nothing else: the diagnostics that name a missing
    /// item quote the same function, so the name looked up and the name
    /// reported cannot drift apart. The old binder carried its own column of
    /// literals and asked for "Map", "Set", "Int", "Float" and "String"; the
    /// tree declares HashMap, HashSet, ImmBigInt, ImmBigFloat and `string`, so five
    /// of the seventeen could never match.
    priv fn _bind_lang(self, root: unsafe *DeclContext, k: WellKnownType) {
        var spelling = to_string(k)
        var im       = self.sc->imm_table()->find_ident(spelling)
        if im == u32::MAX { // never interned here: absent.
            return
        }

        var r = self.sc->lookup.unqualified(root, DeclName::ident(im))
        if !r.found() {
            return
        }

        self.sc->well_known->_set(k, r.first())
    }

    /// Validate one scope's frozen table, then recurse into every child
    /// scope. Pass-through containers (visibility groups, eval blocks, ffi
    /// blocks) are transparent: their members were keyed into THIS table by
    /// the parser, so their nested types are reached from here too.
    priv fn _validate_context(self, dc: unsafe *DeclContext) {
        if dc == &null {
            return
        }

        if dc->dc_symbols != &null {
            var rows = cxx::std::vector<SymbolTable::Entry>()
            dc->dc_symbols->collect_entries(&rows)
            for var i: usize = 0; i < rows.size(); ++i {
                self._validate_cell(dc, rows[i])
            }
        }

        // A TYPE body's dc_decls holds nested type decls PLUS the
        // VisibilityGroupDecl wrappers, and a wrapper's members are pointers
        // back into fields/methods and back into dc_decls itself (see
        // DeclParse::_parse_member_vis_group). Descending through the wrapper
        // there would validate every grouped nested type's scope a second
        // time and emit each of its diagnostics twice. Same rule as
        // ASTParse::_collect_symbols / RecursiveASTVisitor::_rav_dc_nested.
        //
        // At MODULE/TU scope the wrapper is the ONLY container its members
        // live in, so it is walked through (in _descend) normally.
        var type_body = dc->is_type_scope()
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            if type_body && isa<Declarations::VisibilityGroupDecl>(d) {
                continue
            }

            self._descend(d)
        }
    }

    /// Recurse into a child decl's own scope, seeing through the
    /// table-less wrapper decls the parser also parks in dc_decls.
    priv fn _descend(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.count; ++i {
                self._descend(g->members[i])
            }

            return
        }

        if isa<Declarations::EvalBlockDecl>(d) {
            var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
            for var i: usize = 0; i < b->body.count; ++i {
                self._descend(b->body[i])
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(d) {
            var unsafe *b = cast<Declarations::FFIBlockDecl>(d)
            for var i: usize = 0; i < b->body.count; ++i {
                self._descend(b->body[i])
            }

            return
        }

        self._validate_context(NameLookup::context_of(d))
    }

    /// One cell = one name in one scope. Size 1 is the overwhelming case
    /// and needs nothing. Size > 1 is one of exactly three things:
    ///
    ///   all FunctionDecl  -> an overload set. Legal, untouched: telling a
    ///                        redeclaration from an overload needs
    ///                        signatures, so function chains are deferred.
    ///   all one non-fn
    ///   redeclarable kind -> a redecl group. Link it, pick the canonical,
    ///                        error once if two links define.
    ///   anything else     -> redefinition. Sole home: HERE.
    ///
    priv fn _validate_cell(self, dc: unsafe *DeclContext, e: SymbolTable::Entry) {
        if e.cell == &null {
            return
        }

        var n = e.cell->size()
        if n <= 1 {
            return
        }

        var group  = cxx::std::vector<unsafe *Decl>()
        var all_fn = true

        for var i: usize = 0; i < n; ++i {
            var unsafe *d = e.cell->get(i)
            if d == &null {
                continue
            }

            // Identity guard, NOT a name-based dedup: a cell may legitimately
            // hold many DIFFERENT decls under one name (overloads, fwd+def),
            // but the SAME *Decl twice is always a walk bug upstream, and
            // judging it here would report a decl as a redefinition of
            // itself   or, for functions, hand T an overload set with two
            // identical candidates. Cells are 1-3 entries, so the linear
            // scan is cheaper than any set.
            var seen = false
            for var j: usize = 0; j < group.size(); ++j {
                if group[j] == d {
                    seen = true
                    break
                }
            }

            if seen {
                continue
            }

            // A specialization is its own entity: it never links into the
            // primary's chain and never counts as a redefinition of it. Its
            // OWN chain (fwd + def) links in T on canonical spec args -- N
            // has no types to compare. A spec with no primary is T's.
            if NameLookup::is_specialization(d) {
                continue
            }

            // `struct <P> X<P> requires pred` after the primary: a partial
            // the parser filed as a second primary (its pattern is its own
            // parameters). Reclassified, it is a specialization like the
            // others and T registers it (Compiler/Spec/Generics.md#where-groups-on-generic-functions).
            if group.size() > 0 && self._requires_selected_partial(d) {
                decl_set_spec_kind(d, Declarations::SpecKind::Partial)
                continue
            }

            group.push_back(d)
            if !isa<Declarations::FunctionDecl>(d) {
                all_fn = false
            }
        }

        if group.size() <= 1 {
            return
        }

        if all_fn { // overload set; nothing to judge yet.
            return
        }

        // Sibling branches of one `eval if` that waits for a type fact
        // (Compiler/Spec/Eval.md#deferred-conditions): the late fold keeps one branch, so two declarations
        // in different branches are never a redefinition. Each branch's,
        // with those outside every branch, are judged apart from the
        // others': the first one's set, then what is left, in source order.
        if self.sc->eval_branches.has_rows() {
            var rest = group
            while rest.size() > 1 {
                var part = cxx::std::vector<unsafe *Decl>()
                var left = cxx::std::vector<unsafe *Decl>()
                part.push_back(rest[0])
                for var i: usize = 1; i < rest.size(); ++i {
                    if self.sc->eval_branches.exclusive(rest[0], rest[i]) {
                        left.push_back(rest[i])
                    } else {
                        part.push_back(rest[i])
                    }
                }

                self._judge_group(dc, e, unsafe &part)
                rest = left
            }

            return
        }

        self._judge_group(dc, e, unsafe &group)
    }

    /// The verdict on declarations of one name that may all coexist
    /// (_validate_cell): functions are R's; one redeclarable kind is a
    /// redecl group to link; anything else is a redefinition.
    priv fn _judge_group(self,
                         dc:    unsafe *DeclContext,
                         e:     SymbolTable::Entry,
                         group: unsafe *cxx::std::vector<unsafe *Decl>) {
        if group->size() <= 1 {
            return
        }

        var all_fn  = true
        var kind_ok = true
        var k0      = (*group)[0]->kind
        for var i: usize = 0; i < group->size(); ++i {
            var unsafe *d = (*group)[i]
            if !isa<Declarations::FunctionDecl>(d) {
                all_fn = false
            }

            if d->kind != k0 {
                kind_ok = false
            }
        }

        if all_fn { // overload set; nothing to judge yet.
            return
        }

        if !kind_ok {
            // `struct S` forward-declaring what is then `class S { }`: one
            // entity named with two record keywords. Said as that, with the
            // keyword fixed, rather than as two unrelated kinds of entity.
            if self._record_kind_mismatch(e, *group) {
                return
            }

            self._redefinition(dc, e, *group, "declared with conflicting kinds")
            return
        }

        // Same kind, non-function. Only the redeclarable kinds may legally
        // repeat; everything else (var, field, type alias, enum variant) is
        // a plain redefinition.
        match k0 {
            case DeclKind::ClassDecl {
                self._link_group<Declarations::ClassDecl>(e, *group)
            } case DeclKind::StructDecl {
                self._link_group<Declarations::StructDecl>(e, *group)
            } case DeclKind::UnionDecl {
                self._link_group<Declarations::UnionDecl>(e, *group)
            } case DeclKind::InterfaceDecl {
                self._link_group<Declarations::InterfaceDecl>(e, *group)
            } case DeclKind::EnumDecl {
                self._link_group<Declarations::EnumDecl>(e, *group)
            } case DeclKind::ModuleDecl {
                self._link_group<Declarations::ModuleDecl>(e, *group)
            } default {
                self._redefinition(dc, e, *group, "redefined")
            }
        }
    }

    /// `class`, `struct` or `union`, as the keyword that declares \p d;
    /// empty for any other kind.
    priv fn _record_keyword(self, d: unsafe *Decl) -> string {
        if isa<Declarations::ClassDecl>(d) {
            return "class"
        }

        if isa<Declarations::StructDecl>(d) {
            return "struct"
        }

        if isa<Declarations::UnionDecl>(d) {
            return "union"
        }

        return ""
    }

    priv fn _record_defines(self, d: unsafe *Decl) -> bool {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->is_this_definition
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->is_this_definition
        }

        if isa<Declarations::UnionDecl>(d) {
            return cast<Declarations::UnionDecl>(d)->is_this_definition
        }

        return false
    }

    /// A group of records only, named with more than one of `class` /
    /// `struct` / `union`, at most one of them with a body: a forward
    /// declaration that disagrees with its definition (or with an earlier
    /// forward declaration) about the keyword. The three are different
    /// entities to Kairo -- the keyword decides defaults, what a body may
    /// hold, and the C++ tag -- so the chain cannot link across them; each
    /// disagreeing declaration is reported against the one it disagrees with
    /// and poisoned, which leaves the agreeing ones to link as usual. The
    /// fix-it rewrites the forward declaration's keyword, the cheap side of
    /// the edit. False (nothing reported) for any other shape: two bodies
    /// is a redefinition whatever the keywords, and a non-record in the
    /// group is a conflict of kinds.
    priv fn _record_kind_mismatch(self,
                                  e:           SymbolTable::Entry,
                                  const group: cxx::std::vector<unsafe *Decl>) -> bool {
        var def: unsafe *Decl = &null
        for var i: usize = 0; i < group.size(); ++i {
            var unsafe *d = (group)[i]
            if self._record_keyword(d).empty() {
                return false
            }

            if self._record_defines(d) {
                if def != &null {
                    return false
                }

                def = d
            }
        }

        // No definition: the first forward declaration is the reference.
        var unsafe *ref_d = if (def != &null) => (def) else => (group)[0]
        var        ref_kw = self._record_keyword(ref_d)
        var        name   = e.name.describe(self.sc->ctx)
        for var i: usize = 0; i < group.size(); ++i {
            var unsafe *d = (group)[i]
            if d == ref_d {
                continue
            }

            var kw = self._record_keyword(d)
            if kw == ref_kw {
                continue
            }

            var msg  = f"'{name}' is forward-declared as a {kw} but defined as a {ref_kw}"
            var nmsg = f"'{name}' is defined here as a {ref_kw}"
            if def == &null {
                msg  = f"'{name}' is forward-declared as a {kw} here and as a {ref_kw} before"
                nmsg = f"'{name}' is first forward-declared here as a {ref_kw}"
            }

            var b = self.sc->diag->report(DiagID::R063E, d->range.start, msg)
            b.first(d->range)
            b.note(DiagCode(DiagID::R063N), ref_d->range.start, nmsg)->first(ref_d->range)
            // Only where the declaration starts with its keyword: a leading
            // `final` or `abstract` would put the edit on the wrong word.
            var kr = SourceRange::from_bounds(d->range.start, kw.size() as u32)
            if self.sc->ctx->get_spelling(kr) == kw {
                b.fix(kr, ref_kw, f"declare it as a {ref_kw}")
            }

            b.emit()
            d->poison()
        }

        // The agreeing declarations are still one entity.
        var rest = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < group.size(); ++i {
            var unsafe *d = (group)[i]
            if !d->is_poisoned() && self._record_keyword(d) == ref_kw {
                rest.push_back(d)
            }
        }

        if rest.size() > 1 {
            match ref_d->kind {
                case DeclKind::ClassDecl {
                    self._link_group<Declarations::ClassDecl>(e, rest)
                } case DeclKind::StructDecl {
                    self._link_group<Declarations::StructDecl>(e, rest)
                } default {
                    self._link_group<Declarations::UnionDecl>(e, rest)
                }
            }
        }

        return true
    }

    /// Link a same-kind redecl group in SOURCE ORDER (cells are append-only,
    /// so cell order is source order), then point every link's canonical at
    /// the definition if there is one, else at the first decl.
    ///
    /// Idempotent by construction: linking is skipped when the two links
    /// already share a chain, and retarget_canonical recomputes the same
    /// target on a second run (LSP contract, exit criterion 7).
    /// Kinds that may legally have more than one defining link. Only
    /// modules: a module reopens, like a C++ namespace, and every
    /// `module Foo { }` block is a definition. For the five type kinds
    /// two bodies is the redefinition this reports. Whether two
    /// reopenings declare the same MEMBER twice is a different question
    /// with a different home (M2, cross-reopening; Compiler/Spec/Imports.md item 13a).
    priv fn _reopenable(self, k: DeclKind) -> bool {
        return k == DeclKind::ModuleDecl
    }

    // TODO(DUCK-GENERIC): T uses canonical_decl, definition, first_decl, is_this_definition, retarget_canonical, set_prev. Stage 0 was duck-typed; bound it or keep `: type`.
    priv fn <T: type> _link_group(self,
                                  e:           SymbolTable::Entry,
                                  const group: cxx::std::vector<unsafe *Decl>) {
        var first = cast<T>((group)[0])
        if first == &null {
            return
        }

        for var i: usize = 1; i < group.size(); ++i {
            var cur = cast<T>((group)[i])
            if cur == &null {
                continue
            }

            if cur->canonical_decl() != first->canonical_decl() {
                cur->set_prev(first)
            }
        }

        // At most one link may define. The parser's mark_definition guards
        // the single-decl case; only sema sees the whole chain, so the
        // two-definitions diagnostic is ours.
        var defs = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < group.size(); ++i {
            var cur = cast<T>((group)[i])
            if cur == &null {
                continue
            }

            if cur->is_this_definition {
                defs.push_back((group)[i])
            }
        }

        if defs.size() > 1 && !self._reopenable((group)[0]->kind) {
            var name = e.name.describe(self.sc->ctx)
            self.sc->diag->report(
                DiagID::R029E,
                defs[1]->range.start,
                f"redefinition of '{name}'",
            ).first(defs[1]->range)->note(
                DiagCode(DiagID::R029N),
                defs[0]->range.start,
                f"previous definition of '{name}' is here",
            )->first(defs[0]->range)->emit()
            for var i: usize = 1; i < defs.size(); ++i {
                defs[i]->poison()
            }
        }

        // canonical = the definition if the chain has one, else the first
        // decl (which retarget_canonical leaves as-is via first_decl).
        var def = first->definition()
        if def != &null {
            first->retarget_canonical(def)
        } else {
            first->retarget_canonical(first->first_decl())
        }
    }

    /// `struct <P> X<P> requires pred` beside a primary `X`: a partial
    /// specialization whose pattern is only its own parameters, selected by
    /// the clause alone (Compiler/Spec/Generics.md#where-groups-on-generic-functions). The parser cannot tell it from a
    /// second primary; the clause can.
    priv fn _requires_selected_partial(self, d: unsafe *Decl) -> bool {
        if !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)) {
            return false
        }

        var unsafe *rc = decl_requires_clause(d)
        return rc != &null && decl_spec_args(d).size() > 0 && decl_generic_params(d).size() > 0
    }

    /// `Self` names the enclosing TYPE BODY's decl: the class/struct/... or
    /// the ExtensionDecl (ChainBinding maps that to its target). Not a table
    /// name, not a local. Error home for "outside a type body" in EXPRESSION
    /// position is here; type position is T's.
    priv fn _bind_self_type(self, n: unsafe *NamedIdentExpr) -> bool {
        var imm = self.sc->imm_table()->intern_ident_copy("Self") // trace label only; never a lookup key.

        var unsafe *dc = self.cur_dc
        while dc != &null && !(dc->is_type_scope() && dc->owner_decl() != &null) {
            dc = dc->dc_parent
        }

        if dc == &null {
            self.sc->diag->report(
                DiagID::R030E,
                n->range.start,
                "'Self' used outside of a type body",
            ).first(n->range)->emit()
            n->poison()
            self.sc->trace.use_site(
                imm,
                n->range,
                &null,
                TraceVia::Miss,
                &null,
                usize::MAX,
                0,
                true,
                &null,
                TraceVia::None,
                &null,
            )

            return true
        }

        var unsafe *owner = NameLookup::representative(dc->owner_decl())
        n->resolved_decl = owner
        self.sc->trace.use_site(
            imm,
            n->range,
            owner,
            TraceVia::Scope,
            dc,
            usize::MAX,
            0,
            false,
            &null,
            TraceVia::None,
            &null,
        )

        return true
    }


    /// The sole home of the redefinition diagnostic. One error at the
    /// second decl, one note at the first, every loser poisoned so uses
    /// degrade instead of cascading.
    priv fn _redefinition(self,
                          dc:          unsafe *DeclContext,
                          e:           SymbolTable::Entry,
                          const group: cxx::std::vector<unsafe *Decl>,
                          const what:  string) {
        var        name  = e.name.describe(self.sc->ctx)
        var unsafe *prev = (group)[0]
        for var i: usize = 1; i < group.size(); ++i {
            var unsafe *d = (group)[i]
            // The note is a CHILD of the error, not a second top-level
            // diagnostic. Emitted separately it sorts by its own location, and
            // since the previous declaration is EARLIER in the file it renders
            // ahead of the error it is explaining.
            var b = self.sc->diag->report(DiagID::R029E, d->range.start, f"'{name}' {what}")
            b.first(d->range)
            b.note(
                DiagCode(DiagID::R029N),
                prev->range.start,
                f"previous declaration of '{name}' is here",
            )->first(prev->range)
            // Two file-scope bindings: in a script every one is a global,
            // whatever keyword declares it, so `var x` after `static x` is
            // the same name twice, and the edit is almost always a rename
            // (Compiler/Spec/ScriptMode.md#redeclaration). Only there: a member or local has a scope
            // the user meant, and a rename may be the wrong fix.
            var unsafe *dv = dyn_cast<Declarations::VariableDecl>(d)
            if dc != &null
                && dc->is_translation_unit()
                && dv != &null
                && isa<Declarations::VariableDecl>(prev) {
                var fresh = self._free_name(dc, name)
                if !fresh.empty() {
                    b.fix(dv->name.range, fresh, f"rename this one to '{fresh}'")
                }
            }

            b.emit()
            d->poison()
        }
    }

    /// The first `<name>N` (N = 2, 3, ...) that names nothing in \p dc: a
    /// spelling never interned is free outright. Empty after a bound no
    /// file reaches, rather than a loop with none.
    priv fn _free_name(self, dc: unsafe *DeclContext, const name: string) -> string {
        for var n: u32 = 2; n < 1000; ++n {
            var cand = f"{name}{n}"
            var imm  = self.sc->imm_table()->find_ident(cand)
            if imm == ((-1) as i32 as u32) {
                return cand
            }

            if dc->lookup_symbol_ident(imm) == &null {
                return cand
            }
        }

        return ""
    }

    /// ## out-of-line attachment

    /// `fn Class::method` never entered a table (the parser cannot resolve
    /// the qualifier); N attaches each one to the scope it belongs to by
    /// walking the qualifier path with the shared lookup primitives.
    ///
    /// Attachment here means: semantic_dc := the owning type's context, so
    /// N(b) resolves the body against the class and later passes know the
    /// lookup home. Linking the def into the in-class decl's redecl chain
    /// needs signature comparison to pick among overloads and is therefore
    /// part of the deferred FUNCTION-chain work, not this.
    priv fn _attach_out_of_line(self, tu: unsafe *TranslationUnit) {
        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var unsafe *d = *tu->out_of_line.get(i)
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
            if f == &null {
                continue
            }

            var unsafe *home = self._resolve_qualifier(f)
            if home == &null {
                f->poison()
                continue // diagnosed inside _resolve_qualifier
            }

            // The member must already be declared in the type. Missing =
            // an out-of-line definition of something the type never
            // declared, which is an error here and nowhere else.
            // An imported record's member table is filled lazily and in
            // pieces: probing it raw finds whatever an earlier lookup
            // happened to fill. `fn S::g` then `fn S::h` reported `h` as
            // undeclared. Fill it whole before asking.
            var unsafe *owner = home->owner_decl()
            if owner != &null {
                MemberLookup::ensure_filled(self.sc, owner)
            }

            // Through MemberLookup::in_scope, never a raw lookup_symbol: an
            // imported record's table is keyed by the HEADER TU's imms, and
            // this TU's imm for the name finds whichever member happens to
            // share its index (`fn S::g` probed S's `f`). The spelling lets
            // in_scope re-intern the name in the scope's own TU.
            var        key   = self._member_key(f, home)
            var        ml    = MemberLookup(self.sc)
            var unsafe *cell = ml.in_scope(home, key, self.sc->ctx->get_spelling(f->name))
            if cell == &null {
                var nm = self.sc->ctx->get_spelling(f->name)
                self.sc->diag->report(
                    DiagID::R031E,
                    f->range.start,
                    f"out-of-line definition of '{nm}' does not match any declaration in its scope",
                ).first(f->range)->emit()
                f->poison()
                continue
            }

            f->semantic_dc = home
        }
    }

    /// The DeclName an out-of-line def would have been keyed under inside
    /// \p home: ctor when the name matches the owning type, operator when
    /// `fn op`, plain identifier otherwise. Mirrors ASTParse::
    /// _index_symbol_decl so the probe and the table agree.
    priv fn _member_key(self,
                        f:    unsafe *Declarations::FunctionDecl,
                        home: unsafe *DeclContext) -> DeclName {
        if f->is_operator {
            return OperatorFacts::key(f)
        }

        var im = self.sc->ctx->get_ident_imm(f->name)
        if im != u32::MAX && home->is_type_scope() {
            var unsafe *owner = home->owner_decl()
            // By SPELLING, each side through the context its token lives in:
            // an imported owner's name is interned in the header's TU, so
            // comparing imms across the two is a coincidence, not an answer.
            if owner != &null {
                var unsafe *oc = NameLookup::ctx_of(owner)
                if oc == &null {
                    oc = self.sc->ctx
                }

                if oc->get_spelling(decl_name_tok(owner)) == self.sc->ctx->get_spelling(f->name) {
                    return DeclName::ctor()
                }
            }
        }

        return DeclName::ident(im)
    }

    /// Walk `Class::` / `Outer::Inner::` and return the context the
    /// definition belongs to, or null (diagnosed) if any segment misses.
    /// Uses the shared primitives only: unqualified for the head, then
    /// qualified_step per segment.
    priv fn _resolve_qualifier(self, f: unsafe *Declarations::FunctionDecl) -> unsafe *DeclContext {
        var unsafe *q = f->qualifier
        if q == &null {
            return &null
        }

        var        head:  unsafe *NamedIdentExpr = &null
        var unsafe *chain                        = dyn_cast<ChainExpr>(q)
        if chain != &null {
            head = dyn_cast<NamedIdentExpr>(chain->base)
        } else {
            head = dyn_cast<NamedIdentExpr>(q)
        }

        if head == &null {
            return &null
        }

        var im = self._name_imm(head->name)
        if im == u32::MAX {
            return &null
        }

        var saved_at = self.sc->lookup.use_at
        self.sc->lookup.use_at = head->range.start.id
        var r = self.sc->lookup.unqualified(
            unsafe (self.sc->tu as unsafe *DeclContext),
            DeclName::ident(im),
        )

        self.sc->lookup.use_at = saved_at
        if !r.found() {
            var nm = self.sc->ctx->get_spelling(head->name)
            self.sc->diag->report(
                DiagID::R020E,
                head->range.start,
                f"use of undeclared identifier '{nm}' in out-of-line definition",
            ).first(head->range)->emit()
            head->poison() // marks it diagnosed; N(b) will not re-report it.
            return &null
        }

        // A cell answers with its FIRST link, which for `class Foo; class
        // Foo { ... }` is the forward declaration -- a scope with no members
        // in it. Members live on the DEFINITION, so every segment steps
        // through the chain's canonical, which _validate_decls (running
        // before this) already retargeted at the definition.
        var unsafe *cur = NameLookup::representative(r.first())
        head->resolved_decl = cur

        if chain != &null {
            for var i: usize = 0; i < chain->steps.size(); ++i {
                var unsafe *st = chain->steps.get(i)
                if st->name == &null {
                    return &null
                }

                var sim = self._name_imm(st->name->name)
                if sim == u32::MAX {
                    return &null
                }

                var sr = self.sc->lookup.qualified_step(cur, DeclName::ident(sim))
                if !sr.found() {
                    var snm = self.sc->ctx->get_spelling(st->name->name)
                    self.sc->diag->report(
                        DiagID::R025E,
                        st->name->range.start,
                        f"no member named '{snm}' in the qualified scope of this out-of-line definition",
                    ).first(st->name->range)->emit()
                    st->name->poison()
                    return &null
                }

                cur                     = NameLookup::representative(sr.first())
                st->name->resolved_decl = cur
            }
        }

        return NameLookup::context_of(cur)
    }

    /// ## lang items

    /// Resolve the WellKnownType names once, by ordinary unqualified lookup
    /// (they are ordinary library decls arriving through ordinary imports;
    /// their names are NEVER special-cased in lookup).
    ///
    /// A miss is NOT diagnosed here. Per SemaContext.k the absence of a lang
    /// item is only an error at USE ("async used but Future unresolvable"),
    /// and that diagnosis belongs to the lowering pass that needs it. Erroring
    /// per TU would fire on every file that never mentions async.
    /// # N(b): binding

    priv fn _bind(self, tu: unsafe *TranslationUnit) {
        self.cur_dc = unsafe (tu as unsafe *DeclContext)

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

    /// THE core lookup policy, in binding order:
    ///   1. locals, innermost frame first   (body locals shadow everything)
    ///   2. sc->lookup.unqualified(cur_dc)  (DC chain -> import overlay)
    ///   3. miss                            (unresolved-ident diagnostic)
    priv fn _resolve_name(self, imm: u32) -> NameHit {
        if imm == u32::MAX {
            return NameHit::miss()
        }

        var n = self.locals.size()
        for var i: usize = 0; i < n; ++i {
            var fi     = n - 1 - i
            var *frame = &self.locals[fi]
            var idx    = frame->index_of(imm)
            if idx != usize::MAX {
                return NameHit::local(frame->decls[idx], fi)
            }
        }

        var r = self._lookup_unqualified(self.cur_dc, imm)
        if !r.found() && self._ext_target != &null {
            r = self.sc->lookup.in_context(self._ext_target, DeclName::ident(imm))
        }

        if !r.found() {
            return NameHit::miss()
        }

        var h = self._hit_from(r, imm)

        // Kairo has no implicit `this->`: a member is not in unqualified
        // scope, so a member that needs a qualifier must not END the walk. A
        // method `open` calling the imported C `open` means the C one. Keep
        // looking outward from the member's type scope; only when nothing
        // outside answers does the member hit survive, and then R049 is the
        // helpful "did you mean self.open" diagnostic rather than a wrong bind.
        while h.member_scope != &null && self._needs_qualifier(h) {
            var unsafe *outer = h.member_scope->parent_context()
            if outer == &null {
                break
            }

            var r2 = self._lookup_unqualified(outer, imm)
            if !r2.found() {
                break
            }

            h = self._hit_from(r2, imm)
        }

        return h
    }

    /// Turn one lookup answer into a NameHit, tagging member hits (R049).
    priv fn _hit_from(self, r0: SemaLookupResult, imm: u32) -> NameHit {
        var r = self._prefer_ordinary_over_ffi_forward(r0, imm)

        var h = NameHit()
        h.found       = true
        h.via_overlay = r.via_overlay
        h.found_in    = r.found_in

        // A TYPE scope answering a name used from executable code is a MEMBER
        // access with the qualifier left off. Recorded here, diagnosed at the
        // use site (visit_named_ident_expr) where the range lives.
        if !r.via_overlay
            && self._fn_depth > 0
            && r.found_in != &null
            && r.found_in->is_type_scope() {
            h.member_scope = r.found_in
        }

        if r.single() {
            h.decl = NameLookup::representative(r.first())
            return h
        }

        // A multi-decl cell is not automatically an overload set: a redecl
        // chain fills one slot per link, so `class Foo; class Foo {}` looks
        // like two candidates while naming ONE entity. Collapse those to the
        // canonical rather than handing T a set with nothing to choose
        // between. A genuine overload set still goes through whole (hard
        // invariant #3: N never filters candidates).
        var unsafe *sole = self._sole_entity(r.cell)
        if sole != &null {
            h.decl = sole
        } else {
            h.cell = r.cell
        }

        return h
    }

    /// `ffi "c" struct timezone` names the header's TAG, and C keeps tags
    /// apart from ordinary names: in a VALUE position (every head N binds)
    /// the imported ordinary `timezone` the forward declaration would
    /// otherwise shadow is still what the name means. Types go through T,
    /// where the forward declaration wins (Compiler/Spec/Interop.md#ffi-imports).
    priv fn _prefer_ordinary_over_ffi_forward(self,
                                              r:   SemaLookupResult,
                                              imm: u32) -> SemaLookupResult {
        if r.via_overlay || !r.single() {
            return r
        }

        if decl_ffi_tag_target(r.first()) == &null {
            return r
        }

        var unsafe *tu = self.sc->tu
        if tu == &null || tu->import_overlay == &null {
            return r
        }

        var unsafe *cell = tu->import_overlay->lookup_ident(imm)
        if cell == &null || cell->size() == 0 {
            return r
        }

        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if decl_is_ffi(d) && !decl_is_ffi_tag(d) {
                var o = SemaLookupResult{}
                o.cell        = cell
                o.found_in    = tu
                o.via_overlay = true
                return o
            }
        }

        return r
    }

    /// The one entity a multi-decl cell denotes, or null when it holds a
    /// genuine overload set or a diagnosed conflict. Every entry must be a
    /// chain link, and every entry must agree on the canonical.
    priv fn _sole_entity(self, cell: unsafe *OverloadCell) -> unsafe *Decl {
        if cell == &null {
            return &null
        }

        var rep: unsafe *Decl = &null
        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if NameLookup::is_specialization(d) { // not a competing entity.
                continue
            }

            var unsafe *c = NameLookup::chain_canonical(d)
            if c == &null {
                return &null
            }

            if rep == &null {
                rep = c
                continue
            }

            if rep != c {
                return &null
            }
        }

        return rep
    }

    /// ## scope cursor management
    ///
    /// Pattern for every override: save cursor / push frame -> call the
    /// BASE traverse (recurses children) -> restore on EVERY exit path.
    /// The RAV rebinding contract still holds: return what base returned.

    fn traverse_function_decl(self,
                              n: unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
        if n == &null {
            return n
        }

        var unsafe *saved_dc      = self.cur_dc
        var        saved_suppress = self._suppress_next_block_frame

        // An out-of-line def resolves against the type it was written FOR,
        // not the scope it was written IN. N(a) recorded that as semantic_dc.
        //
        // `home` is that owning scope, kept for the trace: cur_dc becomes the
        // function itself below, so reading it back would label every frame
        // with the function's own name (`bump::bump`).
        var unsafe *home      = saved_dc
        var unsafe *saved_ool = self._ool_lexical
        if n->semantic_dc != &null && n->semantic_dc != n->lexical_dc {
            self.cur_dc = n->semantic_dc
            home        = self.cur_dc
            // Owning scope in ANOTHER TU (an imported record): its tables are
            // keyed by that TU, and the file this body was written in is not
            // on its parent chain. _lookup_unqualified bridges both.
            var unsafe *lex = n->lexical_dc
            if lex != &null && NameLookup::tu_of(self.cur_dc) != NameLookup::tu_of(lex) {
                self._ool_lexical = lex
            }
        } else {
            self.cur_dc = unsafe (n as unsafe *DeclContext)
        }

        // Params (and `self`) live in the function frame; the body's own
        // CompoundStmt joins that frame rather than nesting inside it, so a
        // top-level local colliding with a param is a redefinition, not
        // silent shadowing.
        self.locals.push_back(LocalScope())
        self.sc->trace.open_scope(TraceScopeKind::Function, n, n->range, home)
        for var i: usize = 0; i < n->generic_params.size(); ++i {
            var unsafe *gp = n->generic_params[i]
            if gp == &null {
                continue
            }

            self._declare_local(self._name_imm(gp->name), unsafe (gp as unsafe *Decl), gp->range)
        }

        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null {
                continue
            }

            self._declare_local(self._name_imm(p->name), unsafe (p as unsafe *Decl), p->range)
        }

        self._suppress_next_block_frame = true
        self._fn_depth += 1
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_function_decl(self, n)
        self._fn_depth -= 1

        self.sc->trace.close_scope()
        self.locals.pop_back()
        self.cur_dc                     = saved_dc
        self._ool_lexical               = saved_ool
        self._suppress_next_block_frame = saved_suppress
        return out
    }

    /// sc->lookup.unqualified, except from inside an out-of-line body whose
    /// owning scope is in another TU (see NameLookup::unqualified_out_of_line).
    /// Only a walk that STARTS in that foreign chain is rerouted: a walk
    /// resuming in this TU (the trace's "what did it hide") keys correctly
    /// already.
    priv fn _lookup_unqualified(self, from: unsafe *DeclContext, imm: u32) -> SemaLookupResult {
        var name = DeclName::ident(imm)
        if self._ool_lexical == &null || from == &null {
            return self.sc->lookup.unqualified(from, name)
        }

        if NameLookup::tu_of(from) == NameLookup::tu_of(self._ool_lexical) {
            return self.sc->lookup.unqualified(from, name)
        }

        var unsafe *imms = self.sc->ctx->get_imm_table()
        var        sp    = if (imms != &null) => (imms->get_ident(imm)) else => ""
        return self.sc->lookup.unqualified_out_of_line(from, name, sp, self._ool_lexical)
    }

    fn traverse_closure_expr(self, n: unsafe *ClosureExpr) -> unsafe *ClosureExpr {
        if n == &null {
            return n
        }

        var saved_suppress = self._suppress_next_block_frame

        self.locals.push_back(LocalScope())
        self.sc->trace.open_scope(TraceScopeKind::Closure, &null, n->range, self.cur_dc)
        for var i: usize = 0; i < n->generic_params.size(); ++i {
            var unsafe *gp = n->generic_params[i]
            if gp == &null {
                continue
            }

            self._declare_local(self._name_imm(gp->name), unsafe (gp as unsafe *Decl), gp->range)
        }

        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null {
                continue
            }

            self._declare_local(self._name_imm(p->name), unsafe (p as unsafe *Decl), p->range)
        }

        self._suppress_next_block_frame = true
        self._fn_depth += 1
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_closure_expr(self, n)
        self._fn_depth -= 1

        self.sc->trace.close_scope()
        self.locals.pop_back()
        self._suppress_next_block_frame = saved_suppress
        return out
    }

    /// Every brace-delimited scope. Overriding traverse_compound_stmt (not
    /// traverse_block) is deliberate: dispatch_stmt routes a nested bare
    /// block straight here, so a traverse_block-only override would miss it.
    fn traverse_compound_stmt(self, n: unsafe *CompoundStmt) -> unsafe *CompoundStmt {
        if n == &null {
            return n
        }

        var push = !self._suppress_next_block_frame
        self._suppress_next_block_frame = false

        if push {
            self.locals.push_back(LocalScope())
            self.sc->trace.open_scope(TraceScopeKind::Block, &null, n->range, self.cur_dc)
        }

        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_compound_stmt(self, n)
        if push {
            self.sc->trace.close_scope()
            self.locals.pop_back()
        }

        return out
    }

    // Type / module scopes: save-restore cur_dc into the decl's own DC, plus
    // a locals frame for the generic parameters.
    //
    // A type's generic params are NOT in its DeclContext table -- they are
    // template parameters, not members -- so without a lexical frame `T` in
    // EXPRESSION position inside the body (`requires T impl X`, a
    // ConstraintExpr lhs, `T::CONST`) reports "use of undeclared identifier".
    // Functions already did this; every type-shaped scope needs it too.

    /// Push a locals frame holding `gps`. Returns whether one was pushed, so
    /// a non-generic decl costs neither a frame nor an empty trace scope.
    priv fn _open_type_generics(self,
                                owner: unsafe *Decl,
                                gps:   FrozenList<unsafe *Declarations::GenericParamDecl>,
                                at:    SourceRange,
                                home:  unsafe *DeclContext) -> bool {
        if gps.size() == 0 {
            return false
        }

        self.locals.push_back(LocalScope())
        self.sc->trace.open_scope(TraceScopeKind::Block, owner, at, home)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                continue
            }

            self._declare_local(self._name_imm(gp->name), unsafe (gp as unsafe *Decl), gp->range)
        }

        return true
    }

    priv fn _close_type_generics(self, pushed: bool) {
        if !pushed {
            return
        }

        self.sc->trace.close_scope()
        self.locals.pop_back()
    }

    fn traverse_class_decl(self,
                           n: unsafe *Declarations::ClassDecl) -> unsafe *Declarations::ClassDecl {
        if n == &null {
            return n
        }

        var unsafe *saved = self.cur_dc
        var        pushed = self._open_type_generics(n, n->generic_params, n->range, saved)
        self.cur_dc = unsafe (n as unsafe *DeclContext)
        var saved_depth = self._fn_depth
        self._fn_depth = 0 // a type body is not executable code.
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_class_decl(self, n)
        self._fn_depth = saved_depth
        self.cur_dc    = saved
        self._close_type_generics(pushed)
        return out
    }

    fn traverse_struct_decl(self,
                            n: unsafe *Declarations::StructDecl) -> unsafe *Declarations::StructDecl {
        if n == &null {
            return n
        }

        var unsafe *saved = self.cur_dc
        var        pushed = self._open_type_generics(n, n->generic_params, n->range, saved)
        self.cur_dc = unsafe (n as unsafe *DeclContext)
        var saved_depth = self._fn_depth
        self._fn_depth = 0 // a type body is not executable code.
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_struct_decl(self, n)
        self._fn_depth = saved_depth
        self.cur_dc    = saved
        self._close_type_generics(pushed)
        return out
    }

    fn traverse_union_decl(self,
                           n: unsafe *Declarations::UnionDecl) -> unsafe *Declarations::UnionDecl {
        if n == &null {
            return n
        }

        var unsafe *saved = self.cur_dc
        var        pushed = self._open_type_generics(n, n->generic_params, n->range, saved)
        self.cur_dc = unsafe (n as unsafe *DeclContext)
        var saved_depth = self._fn_depth
        self._fn_depth = 0 // a type body is not executable code.
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_union_decl(self, n)
        self._fn_depth = saved_depth
        self.cur_dc    = saved
        self._close_type_generics(pushed)
        return out
    }

    fn traverse_enum_decl(self,
                          n: unsafe *Declarations::EnumDecl) -> unsafe *Declarations::EnumDecl {
        if n == &null {
            return n
        }

        var unsafe *saved = self.cur_dc
        var        pushed = self._open_type_generics(n, n->generic_params, n->range, saved)
        self.cur_dc = unsafe (n as unsafe *DeclContext)
        var saved_depth = self._fn_depth
        self._fn_depth = 0 // a type body is not executable code.
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_enum_decl(self, n)
        self._fn_depth = saved_depth
        self.cur_dc    = saved
        self._close_type_generics(pushed)
        return out
    }

    fn traverse_interface_decl(self,
                               n: unsafe *Declarations::InterfaceDecl) -> unsafe *Declarations::InterfaceDecl {
        if n == &null {
            return n
        }

        var unsafe *saved = self.cur_dc
        var        pushed = self._open_type_generics(n, n->generic_params, n->range, saved)
        self.cur_dc = unsafe (n as unsafe *DeclContext)
        var saved_depth = self._fn_depth
        self._fn_depth = 0 // a type body is not executable code.
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_interface_decl(self, n)
        self._fn_depth = saved_depth
        self.cur_dc    = saved
        self._close_type_generics(pushed)
        return out
    }

    fn traverse_extension_decl(self,
                               n: unsafe *Declarations::ExtensionDecl) -> unsafe *Declarations::ExtensionDecl {
        if n == &null {
            return n
        }

        var unsafe *saved     = self.cur_dc
        var        pushed     = self._open_type_generics(n, n->generic_params, n->range, saved)
        var unsafe *saved_ext = self._ext_target
        self._ext_target = self._extension_target_dc(n, saved)
        self.cur_dc      = unsafe (n as unsafe *DeclContext)
        var saved_depth = self._fn_depth
        self._fn_depth = 0 // a type body is not executable code.
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_extension_decl(self, n)
        self._fn_depth   = saved_depth
        self.cur_dc      = saved
        self._ext_target = saved_ext
        self._close_type_generics(pushed)
        return out
    }

    /// A type alias owns no DeclContext; only its generic params need a frame.
    fn traverse_type_alias_decl(self,
                                n: unsafe *Declarations::TypeAliasDecl) -> unsafe *Declarations::TypeAliasDecl {
        if n == &null {
            return n
        }

        var        pushed = self._open_type_generics(n, n->generic_params, n->range, self.cur_dc)
        var unsafe *out   = RecursiveASTVisitor<NameResolution>::traverse_type_alias_decl(self, n)
        self._close_type_generics(pushed)
        return out
    }

    fn traverse_module_decl(self,
                            n: unsafe *Declarations::ModuleDecl) -> unsafe *Declarations::ModuleDecl {
        if n == &null {
            return n
        }

        var unsafe *saved = self.cur_dc
        // An anonymous module owns no table; its decls were keyed into the
        // enclosing scope, so the cursor must NOT move into it.
        if !n->is_anonymous {
            self.cur_dc = n
        }

        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_module_decl(self, n)
        self.cur_dc = saved
        return out
    }

    /// ## local declaration

    /// A body-local `var`/`const`. The initializer is walked FIRST (by the
    /// base traverse) so `var x = x;` binds the OUTER x, and only then does
    /// the name enter the frame.
    fn traverse_variable_decl(self,
                              n: unsafe *Declarations::VariableDecl) -> unsafe *Declarations::VariableDecl {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_variable_decl(self, n)

        // Only body locals go on the stack. A file/type-scope `var` was
        // keyed into a real SymbolTable at parse time and is found by the
        // unqualified walk instead; declaring it here too would make it
        // visible before its own line.
        if !self.locals.empty() {
            self._declare_local(self._name_imm(n->name), n, n->range)
        }

        return out
    }

    /// Push \p d into the innermost frame under \p imm. A same-frame
    /// duplicate is a redefinition; this is the sole home of that
    /// diagnostic for body locals (N(a) owns the decl-table half).
    ///
    /// Statement-level binders (`for x in xs`, `catch e`, `var (a, b) = t`,
    /// context bindings) and `case var n` patterns route here too, through
    /// the `decl` slot the parser now synthesizes on Binding / CatchArm /
    /// BindingPattern. A BARE `case n` does NOT: a bare name in a pattern is
    /// never a binder, so that head is an ordinary name use.
    priv fn _declare_local(self, imm: u32, d: unsafe *Decl, at: SourceRange) {
        if imm == u32::MAX {
            return
        }

        if self.locals.empty() {
            return
        }

        var *frame = &self.locals[self.locals.size() - 1]
        var prev_i = frame->index_of(imm)
        if prev_i != usize::MAX {
            var unsafe *prev = frame->decls[prev_i]

            // Immutable bindings may be redeclared freely: rebinding a const
            // introduces a NEW value under the same name, and the old one
            // cannot have been mutated, so nothing observable is lost.
            // Anything involving a `var` is rejected, because `var x = 12`
            // after an existing `x` is ambiguous about intent -- assignment
            // is spelled `x = 12` and is almost certainly what was meant.
            //
            // BOTH must be const. Mixed pairs are errors in both directions:
            // a rule that read only the new declaration would accept
            // `var x; const x` while rejecting `const x; var x`, which is an
            // asymmetry no reader would predict.
            if !(self._is_immutable(prev) && self._is_immutable(d)) {
                var nm = self.sc->imm_table()->get_ident(imm)
                // Child note, not a second top-level diagnostic: the sink
                // reorders top-level diagnostics into source order and carries
                // children along with their parent, so a sibling note that
                // points BACKWARDS renders ahead of the error it explains.
                var b = self.sc->diag->report(DiagID::R029E, at.start, f"redefinition of '{nm}'")
                b.first(at)
                if prev != &null {
                    b.note(
                        DiagCode(DiagID::R029N),
                        prev->range.start,
                        f"previous declaration of '{nm}' is here",
                    )->first(prev->range)
                }

                b.emit()
                if d != &null {
                    d->poison()
                }
            }
        }

        // Recorded BEFORE the push, so the search sees the world this name is
        // about to hide rather than itself.
        var sh = self._shadowed_below(imm, self.locals.size() - 1)
        self.sc->trace.declare(imm, d, at, sh.decl, sh.via, sh.found_in)

        frame->declare(imm, d)
    }

    /// True for a binding that can be redeclared in the same frame. Only
    /// `const` locals qualify; a param, binder, or local type decl is not a
    /// value rebinding and is never redeclarable.
    priv fn _is_immutable(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var unsafe *v = dyn_cast<Declarations::VariableDecl>(d)
        if v == &null {
            return false
        }

        return v->is_const()
    }

    /// ## shadowing (trace-only)

    /// What a binding introduced in frame \p from_frame hides: the outer
    /// lexical frames innermost-first, then the DC chain and overlay   the
    /// same order _resolve_name searches, resumed one step further out.
    ///
    /// Pass usize(-1) for \p from_frame to skip the lexical frames entirely
    /// (a name that bound through a TABLE hides no local by definition; the
    /// local would have won).
    ///
    /// Returns nothing when the trace is off: this is a whole extra lookup
    /// per binding and it buys the compiler nothing.
    priv fn _shadowed_below(self, imm: u32, from_frame: usize) -> ShadowHit {
        var out = ShadowHit()
        if !self.sc->trace.enabled {
            return out
        }

        if imm == u32::MAX {
            return out
        }

        if from_frame != usize::MAX && from_frame <= self.locals.size() {
            for var i: usize = 0; i < from_frame; ++i {
                var fi     = from_frame - 1 - i
                var *frame = &self.locals[fi]
                var idx    = frame->index_of(imm)
                if idx != usize::MAX {
                    out.decl  = frame->decls[idx]
                    out.via   = TraceVia::Local
                    out.frame = fi
                    return out
                }
            }
        }

        return self._shadowed_from_dc(imm, self.cur_dc)
    }

    /// The table/overlay half of the same question, starting the DC walk at
    /// \p from. Used on its own to answer "what did this FIELD hide?" by
    /// resuming from the answering scope's parent.
    priv fn _shadowed_from_dc(self, imm: u32, from: unsafe *DeclContext) -> ShadowHit {
        var out = ShadowHit()
        if !self.sc->trace.enabled {
            return out
        }

        if imm == u32::MAX {
            return out
        }

        var r = self._lookup_unqualified(from, imm)
        if !r.found() {
            return out
        }

        out.decl     = r.first()
        out.via      = if (r.via_overlay) => (TraceVia::Overlay) else => TraceVia::Scope
        out.found_in = r.found_in
        return out
    }

    /// What the name at a USE site hid. A local hit resumes below its frame;
    /// a table hit resumes at the answering scope's PARENT (so a field
    /// shadowing a file-scope var is visible); an overlay hit is already the
    /// last source, so it hides nothing.
    priv fn _shadowed_at_use(self, imm: u32, h: NameHit) -> ShadowHit {
        if !self.sc->trace.enabled {
            return ShadowHit()
        }

        if h.from_local {
            return self._shadowed_below(imm, h.frame)
        }

        if h.via_overlay {
            return ShadowHit()
        }

        if h.found_in == &null {
            return ShadowHit()
        }

        return self._shadowed_from_dc(imm, h.found_in->dc_parent)
    }

    /// ## statement-level binders
    ///
    /// Each of these introduces names into a scope the RAV does not model: the
    /// binder list is walked as leaf data (the RAV explicitly skips `Binding`
    /// name nodes), so N pushes its own frame, declares the binders, then lets
    /// the base traverse walk the body inside that frame.
    ///
    /// Order matters and matches the language: the VALUE/ITERABLE expression is
    /// resolved in the OUTER scope, before the binders exist. `for x in x` and
    /// `var (a, b) = a` therefore refer to an outer `x` / `a`, exactly like
    /// `var x = x` does.

    fn traverse_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> unsafe *RangedForStmt {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_ranged_for_stmt(n) == false {
            return n
        }

        if n->iterable != &null {
            n->iterable = self.dyn()->dispatch_expr(n->iterable)
        }

        self.locals.push_back(LocalScope())
        self.sc->trace.open_scope(TraceScopeKind::ForBody, &null, n->range, self.cur_dc)
        self._declare_bindings(&n->bindings)
        self._suppress_next_block_frame = true
        n->body                         = self.dyn()->traverse_block(n->body)
        self.sc->trace.close_scope()
        self.locals.pop_back()
        return n
    }

    /// The init clause declares INTO the loop's own scope, not the enclosing
    /// one -- `for var i = 0; ...` twice in a row is two `i`s.
    fn traverse_indexed_for_stmt(self, n: unsafe *IndexedForStmt) -> unsafe *IndexedForStmt {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_indexed_for_stmt(n) == false {
            return n
        }

        self.locals.push_back(LocalScope())
        self.sc->trace.open_scope(TraceScopeKind::ForBody, &null, n->range, self.cur_dc)
        if n->init != &null {
            n->init = self.dyn()->dispatch_stmt(n->init)
        }

        if n->cond != &null {
            n->cond = self.dyn()->dispatch_expr(n->cond)
        }

        if n->update != &null {
            n->update = self.dyn()->dispatch_expr(n->update)
        }

        self._suppress_next_block_frame = true
        n->body                         = self.dyn()->traverse_block(n->body)
        self.sc->trace.close_scope()
        self.locals.pop_back()
        return n
    }

    fn traverse_context_binding_stmt(self,
                                     n: unsafe *ContextBindingStmt) -> unsafe *ContextBindingStmt {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_context_binding_stmt(n) == false {
            return n
        }

        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        self.locals.push_back(LocalScope())
        self.sc->trace.open_scope(TraceScopeKind::ContextBinding, &null, n->range, self.cur_dc)
        self._declare_bindings(&n->bindings)
        self._suppress_next_block_frame = true
        n->body                         = self.dyn()->traverse_block(n->body)
        self.sc->trace.close_scope()
        self.locals.pop_back()
        return n
    }

    /// Destructuring declares into the ENCLOSING frame (it is a decl
    /// statement, not a scope), so there is no frame push here.
    fn traverse_destructuring_decl_stmt(self, n: unsafe *DestructuringDeclStmt)
            -> unsafe *DestructuringDeclStmt {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_destructuring_decl_stmt(n) == false {
            return n
        }

        if n->value != &null {
            n->value = self.dyn()->dispatch_expr(n->value)
        }

        self._declare_bindings(&n->bindings)
        return n
    }

    fn traverse_try_catch_stmt(self, n: unsafe *TryCatchStmt) -> unsafe *TryCatchStmt {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_try_catch_stmt(n) == false {
            return n
        }

        n->try_body = self.dyn()->traverse_block(n->try_body)
        for var i: usize = 0; i < n->arms.size(); ++i {
            if self.stop {
                break
            }

            var unsafe *arm = n->arms.get(i)
            if arm->filter != &null {
                self.dyn()->dispatch_type(arm->filter)
            }

            self.locals.push_back(LocalScope())
            self.sc->trace.open_scope(TraceScopeKind::CatchArm, &null, arm->range, self.cur_dc)
            self._declare_binder_decl(arm->decl)
            self._suppress_next_block_frame = true
            if arm->body != &null {
                self.dyn()->dispatch_stmt(arm->body)
            }

            self.sc->trace.close_scope()
            self.locals.pop_back()
        }

        return n
    }

    fn traverse_try_catch_expr(self, n: unsafe *TryCatchExpr) -> unsafe *TryCatchExpr {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_try_catch_expr(n) == false {
            return n
        }

        if n->try_expr != &null {
            n->try_expr = self.dyn()->dispatch_expr(n->try_expr)
        }

        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            if self.stop {
                break
            }

            var unsafe *arm = n->catch_arms.get(i)
            if arm->filter != &null {
                self.dyn()->dispatch_type(arm->filter)
            }

            self.locals.push_back(LocalScope())
            self.sc->trace.open_scope(TraceScopeKind::CatchArm, &null, arm->range, self.cur_dc)
            self._declare_binder_decl(arm->decl)
            if arm->body != &null {
                self.dyn()->dispatch_expr(arm->body)
            }

            self.sc->trace.close_scope()
            self.locals.pop_back()
        }

        return n
    }

    /// One match arm: patterns bind, then the guard and body see those
    /// bindings. The arm is its own scope, so the frame wraps all three.
    /// Only the first alternative declares; the rest share its decls (see
    /// the header).
    fn traverse_match_case(self, mc: unsafe *MatchCase) {
        if mc == &null {
            return
        }

        self.locals.push_back(LocalScope())
        self.sc->trace.open_scope(TraceScopeKind::MatchArm, &null, mc->range, self.cur_dc)
        for var i: usize = 0; i < mc->patterns.size(); ++i {
            if self.stop {
                break
            }

            var unsafe *pat = *mc->patterns.get(i)
            if i == 0 {
                self._declare_pattern_binders(pat)
            } else {
                self._rebind_pattern_binders(pat)
            }

            self.dyn()->dispatch_pattern(pat)
        }

        if !self.stop {
            if mc->guard != &null {
                self.dyn()->dispatch_expr(mc->guard)
            }

            if mc->body != &null {
                self._suppress_next_block_frame = true
                self.dyn()->dispatch_stmt(mc->body)
            }

            if mc->expression != &null {
                self.dyn()->dispatch_expr(mc->expression)
            }
        }

        self.sc->trace.close_scope()
        self.locals.pop_back()
    }

    priv fn _declare_bindings(self, list: *FrozenList<Binding>) {
        for var i: usize = 0; i < list->size(); ++i {
            var b = (*list)[i]
            if b.is_discard { // `_` binds nothing.
                continue
            }

            self._declare_binder_decl(b.decl)
        }
    }

    priv fn _declare_binder_decl(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        var unsafe *vd = dyn_cast<Declarations::VariableDecl>(d)
        if vd == &null {
            return
        }

        self._declare_local(self._name_imm(vd->name), d, d->range)
    }

    /// Walk a pattern tree declaring every explicit `var`/`const` binder.
    /// A constructor pattern's head is a name use, never a binder; only its
    /// subpatterns can contain binders. In an alternation the first
    /// alternative declares and the rest share its decls.
    priv fn _declare_pattern_binders(self, p: unsafe *Pattern) {
        if p == &null {
            return
        }

        match p->kind {
            case PatternKind::BindingPattern {
                self._declare_binder_decl(cast<BindingPattern>(p)->decl)
            } case PatternKind::TupleDestructurePattern {
                var unsafe *n = cast<TupleDestructurePattern>(p)
                for var i: usize = 0; i < n->elements.size(); ++i {
                    self._declare_pattern_binders(*n->elements.get(i))
                }
            } case PatternKind::ConstructorPattern {
                var unsafe *n = cast<ConstructorPattern>(p)
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._declare_pattern_binders(*n->subpatterns.get(i))
                }
            } case PatternKind::UnresolvedConstructorPattern {
                var unsafe *n = cast<UnresolvedConstructorPattern>(p)
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._declare_pattern_binders(*n->subpatterns.get(i))
                }
            } case PatternKind::SlicePattern {
                var unsafe *n = cast<SlicePattern>(p)
                for var i: usize = 0; i < n->prefix.size(); ++i {
                    self._declare_pattern_binders(*n->prefix.get(i))
                }

                for var i: usize = 0; i < n->suffix.size(); ++i {
                    self._declare_pattern_binders(*n->suffix.get(i))
                }

                self._declare_pattern_binders(n->rest_binding)
            } case PatternKind::AlternationPattern {
                // The first alternative declares; the rest share its decls.
                var unsafe *n = cast<AlternationPattern>(p)
                if n->alternatives.size() > 0 {
                    self._declare_pattern_binders(*n->alternatives.get(0))
                }

                for var i: usize = 1; i < n->alternatives.size(); ++i {
                    self._rebind_pattern_binders(*n->alternatives.get(i))
                }
            } default {
                0
            }
        }
    }

    /// A later alternative's binders: each one whose name the first
    /// alternative already declared in this frame takes that decl, so the
    /// body sees one binding. A name with no counterpart is SC011E
    /// (PatternBindingCheck); its decl is left alone and NOT declared, or the
    /// body would see a name some paths never bind.
    priv fn _rebind_pattern_binders(self, p: unsafe *Pattern) {
        if p == &null {
            return
        }

        match p->kind {
            case PatternKind::BindingPattern {
                var unsafe *bp = cast<BindingPattern>(p)
                var unsafe *vd = dyn_cast<Declarations::VariableDecl>(bp->decl)
                if vd == &null || self.locals.empty() {
                    return
                }

                var        *frame = &self.locals[self.locals.size() - 1]
                var unsafe *first = frame->find(self._name_imm(vd->name))
                if first != &null {
                    bp->decl = first
                }
            } case PatternKind::TupleDestructurePattern {
                var unsafe *n = cast<TupleDestructurePattern>(p)
                for var i: usize = 0; i < n->elements.size(); ++i {
                    self._rebind_pattern_binders(*n->elements.get(i))
                }
            } case PatternKind::ConstructorPattern {
                var unsafe *n = cast<ConstructorPattern>(p)
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._rebind_pattern_binders(*n->subpatterns.get(i))
                }
            } case PatternKind::UnresolvedConstructorPattern {
                var unsafe *n = cast<UnresolvedConstructorPattern>(p)
                for var i: usize = 0; i < n->subpatterns.size(); ++i {
                    self._rebind_pattern_binders(*n->subpatterns.get(i))
                }
            } case PatternKind::SlicePattern {
                var unsafe *n = cast<SlicePattern>(p)
                for var i: usize = 0; i < n->prefix.size(); ++i {
                    self._rebind_pattern_binders(*n->prefix.get(i))
                }

                for var i: usize = 0; i < n->suffix.size(); ++i {
                    self._rebind_pattern_binders(*n->suffix.get(i))
                }

                self._rebind_pattern_binders(n->rest_binding)
            } case PatternKind::AlternationPattern {
                var unsafe *n = cast<AlternationPattern>(p)
                for var i: usize = 0; i < n->alternatives.size(); ++i {
                    self._rebind_pattern_binders(*n->alternatives.get(i))
                }
            } default {
                0
            }
        }
    }

    /// ## annotations

    /// Attribute names (`@my_macro`) are name uses too, but the RAV does not
    /// walk annotations at all (they hang off the Annotation mixin, not the
    /// child lists), so N reaches them from the decl family hook instead.
    ///
    /// A MISS IS NOT AN ERROR here, unlike every other name use: the vast
    /// majority of attributes are compiler builtins (`@inline`, `@packed`)
    /// with no declaration to find. N records the binding when one exists so
    /// jump-to-def works on user-defined attribute macros, and stays silent
    /// otherwise. Deciding which attribute names are legal is the attribute
    /// checker's job, not name resolution's.
    fn visit_decl(self, n: unsafe *Decl) -> bool {
        if n == &null {
            return true
        }

        for var i: usize = 0; i < n->annotations.size(); ++i {
            var unsafe *e = n->annotations.get(i)
            if e == &null {
                continue
            }

            if e->kind != AnnotationKind::Attribute {
                continue
            }

            if e->name == u32::MAX {
                continue
            }

            if e->resolved_decl != &null { // idempotent re-run.
                continue
            }

            var h = self._resolve_name(e->name)
            if h.found && h.decl != &null {
                e->resolved_decl = h.decl
            }
        }

        return true
    }

    /// ## binding hooks

    /// A name clang knows as a builtin: the fourth source of unqualified
    /// names, consulted only here, after every Kairo source missed, so a
    /// declaration of the same name always wins. True when the use was
    /// handled (bound, or diagnosed and poisoned); false leaves it to R020E.
    priv fn _bind_builtin(self, n: unsafe *NamedIdentExpr) -> bool {
        var unsafe *bi = self.sc->builtins
        if bi == &null || !bi->ready() {
            return false
        }

        var e = bi->resolve(self.sc->ctx->get_spelling(n->name))
        if e.decl == &null && e.why.size() == 0 {
            return false
        }

        if e.decl == &null {
            self.sc->diag->report(DiagID::R057E, n->range.start, e.why).first(n->range)->emit()
            n->poison()
            return true
        }

        n->resolved_decl = unsafe (e.decl as unsafe *Decl)
        return true
    }

    /// The heart of N. Every unqualified name use lands here.
    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if n == &null {
            return true
        }

        // Already bound: `self`-style pre-binding, an out-of-line qualifier
        // segment resolved by N(a), or a second N run over the same AST.
        if n->is_bound() || n->is_deferred() {
            return true
        }

        // Already DIAGNOSED. N(a) walks an out-of-line def's `Class::`
        // qualifier before the RAV ever reaches it; poison is the marker so
        // the same unresolvable head is not reported twice.
        if n->is_poisoned() {
            return true
        }

        var imm = self._name_imm(n->name)
        if imm == u32::MAX {
            if self.sc->ctx->unwrap_token(n->name).kind == TokenKind::BiSelf {
                return self._bind_self_type(n)
            }

            // A primitive type heading an expression (`i32::MAX`, `u32(-1)`;
            // the parser admits one only before `::` or `(`) names no decl,
            // so there is nothing to bind. Left unbound ON PURPOSE for the
            // pass that sees what follows it: ChainBinding for `::`,
            // CallTyping for `(`. NameBindingVerifier skips it.
            return true // not an identifier: nothing to bind.
        }

        // The spelled head, for --dump-import-uses (NameLookup::use_at).
        var saved_at = self.sc->lookup.use_at
        self.sc->lookup.use_at = n->range.start.id
        var h = self._resolve_name(imm)
        self.sc->lookup.use_at = saved_at

        if !h.found {
            if self._bind_builtin(n) {
                return true
            }

            var nm = self.sc->ctx->get_spelling(n->name)
            var b = self.sc->diag->report(
                DiagID::R020E,
                n->range.start,
                f"use of undeclared identifier '{nm}'",
            )

            b.first(n->range)
            if self._in_pattern_head {
                b.note(n->range.start, f"to bind the matched value to a new name, write 'var {nm}'")
            }

            b.emit()
            n->poison()
            self.sc->trace.use_site(
                imm,
                n->range,
                &null,
                TraceVia::Miss,
                &null,
                usize::MAX,
                0,
                true,
                &null,
                TraceVia::None,
                &null,
            )

            return true
        }

        // Two header entities under one imported name: C++ reports that
        // here, at the use, not at the import (ImportResolution::_add).
        if h.via_overlay
            && MemberLookup::report_lazy_ambiguity(
                self.sc,
                h.found_in,
                imm,
                self.sc->ctx->get_spelling(n->name),
                n->range,
            ) {
            n->poison()
            self.sc->trace.use_site(
                imm,
                n->range,
                &null,
                TraceVia::Overlay,
                h.found_in,
                usize::MAX,
                0,
                true,
                &null,
                TraceVia::None,
                &null,
            )

            return true
        }

        if h.via_overlay && !self._overlay_access_ok(imm) {
            self._report_overlay_access(imm, n)
            n->poison()
            self.sc->trace.use_site(
                imm,
                n->range,
                h.decl,
                TraceVia::Overlay,
                &null,
                usize::MAX,
                0,
                true,
                &null,
                TraceVia::None,
                &null,
            )

            return true
        }

        if h.member_scope != &null && self._needs_qualifier(h) {
            self._report_unqualified_member(n, h)
            return true
        }

        // The scope exception's readability lint: `Node { .. }` binds, and
        // says `Self::Node` would read better (MemberLookup).
        // Not the subject of an associated type's own bound: `type Node impl
        // X` is parsed as the clause `Node impl X`, whose `Node` is the
        // declaration's name token, not a use anyone wrote.
        var own_bound = h.decl != &null
            && isa<Declarations::TypeAliasDecl>(h.decl)
            && cast<Declarations::TypeAliasDecl>(h.decl)->name.range.start == n->range.start
        if !h.from_local && !h.via_overlay && h.decl != &null && !own_bound {
            var unsafe *so = self._self_owner()
            if MemberLookup::is_member_type_of(h.decl, so) {
                MemberLookup::warn_unqualified_member_type(self.sc, n->range, h.decl, so)
            }
        }

        if h.decl != &null {
            n->resolved_decl = h.decl
        } else {
            n->candidate_cell = h.cell // alias into the frozen cell.
        }

        var sh  = self._shadowed_at_use(imm, h)
        var via = TraceVia::Scope
        if h.from_local {
            via = TraceVia::Local
        } else if h.via_overlay {
            via = TraceVia::Overlay
        }

        var ncand: usize = 0
        if h.cell != &null {
            ncand = h.cell->size()
        }

        self.sc->trace.use_site(
            imm,
            n->range,
            h.decl,
            via,
            h.found_in,
            h.frame,
            ncand,
            false,
            sh.decl,
            sh.via,
            sh.found_in,
        )

        return true
    }

    /// The record scope `extend <target>` names, or null when the target is
    /// not a nameable path or does not resolve here. Silent: every error this
    /// could report is T's, which resolves the same target properly right
    /// after and owns the diagnostic.
    ///
    /// \p outer is the scope the `extend` itself was written in -- the target
    /// is resolved THERE, not inside the extension body.
    priv fn _extension_target_dc(self,
                                 n:     unsafe *Declarations::ExtensionDecl,
                                 outer: unsafe *DeclContext) -> unsafe *DeclContext {
        if n == &null {
            return &null
        }

        if n->target == &null {
            return &null
        }

        var unsafe *ct = dyn_cast<ChainType>(n->target)
        if ct == &null {
            return &null
        }

        if ct->segments.size() == 0 {
            return &null
        }

        var unsafe *seg0 = ct->segments.get(0)
        if seg0 == &null || seg0->name == &null {
            return &null
        }

        var im = self._name_imm(seg0->name->name)
        if im == u32::MAX {
            return &null
        }

        var saved_at = self.sc->lookup.use_at
        self.sc->lookup.use_at = seg0->name->range.start.id
        var r = self.sc->lookup.unqualified(outer, DeclName::ident(im))
        self.sc->lookup.use_at = saved_at
        if !r.found() {
            return &null
        }

        var unsafe *cur = NameLookup::representative(r.first())

        for var i: usize = 1; i < ct->segments.size(); ++i {
            var unsafe *seg = ct->segments.get(i)
            if seg == &null || seg->name == &null {
                return &null
            }

            var sim = self._name_imm(seg->name->name)
            if sim == u32::MAX {
                return &null
            }

            var sr = self.sc->lookup.qualified_step(cur, DeclName::ident(sim))
            if !sr.found() {
                return &null
            }

            cur = NameLookup::representative(sr.first())
        }

        var unsafe *dc = NameLookup::context_of(cur)
        if dc == &null {
            return &null
        }

        if !dc->is_type_scope() { // `extend` on a module is not a thing.
            return &null
        }

        return dc
    }

    /// ## explicit-qualifier rule (R049)
    ///
    /// Kairo has no implicit `this->`. A member of the enclosing type is NOT in
    /// unqualified scope inside a function body: an instance member is reached
    /// through `self`, a static one through `Self::`. Before this rule the
    /// answer depended on WHERE the body was written -- a body inside a `class`
    /// saw its fields bare, the same body moved into an `extend` did not, and an
    /// out-of-line `fn Type::m` saw them again -- which is the inconsistency
    /// this closes.
    ///
    /// The ONE exception is a name that denotes a SCOPE rather than a value:
    /// nested types, type aliases and nested modules. `Nested { a: 1 }` inside a
    /// method resolves to `Self::Nested` and stays legal, because naming a type
    /// is not an access through an object.

    /// The record `Self` denotes here: the innermost type scope around the
    /// use, or the target of the `extend` it is in. Null outside any type
    /// body (and inside `extend i32`, which has no record to name).
    priv fn _self_owner(self) -> unsafe *Decl {
        var unsafe *dc = self.cur_dc
        while dc != &null {
            if dc->is_type_scope() {
                if dc->context_kind() == DeclContextKind::Extension {
                    if self._ext_target == &null {
                        return &null
                    }

                    return self._ext_target->owner_decl()
                }

                return dc->owner_decl()
            }

            dc = dc->parent_context()
        }

        return &null
    }

    /// True when the answering decl denotes a scope/type rather than a member
    /// entity -- the sole exception to the qualifier rule.
    priv fn _is_scope_name(self, d: unsafe *Decl) -> bool {
        if d == &null { // nothing to demand a qualifier for.
            return true
        }

        if isa<Declarations::ClassDecl>(d) {
            return true
        }

        if isa<Declarations::StructDecl>(d) {
            return true
        }

        if isa<Declarations::EnumDecl>(d) {
            return true
        }

        if isa<Declarations::UnionDecl>(d) {
            return true
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return true
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return true
        }

        if isa<Declarations::ModuleDecl>(d) {
            return true
        }

        return false
    }

    /// Whether this member hit must be spelled with a qualifier. An overload
    /// set qualifies as one entity: functions are never scope names, so a
    /// single non-exempt candidate is enough.
    priv fn _needs_qualifier(self, h: NameHit) -> bool {
        if h.decl != &null {
            return !self._is_scope_name(h.decl)
        }

        if h.cell == &null {
            return false
        }

        for var i: usize = 0; i < h.cell->size(); ++i {
            if !self._is_scope_name(h.cell->get(i)) {
                return true
            }
        }

        return false
    }

    /// A static member is named through the TYPE (`Self::`), an instance member
    /// through the object (`self.`). Statics are the minority, so the instance
    /// form is the fallback for anything unclassifiable.
    priv fn _is_static_member(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var unsafe *f = dyn_cast<Declarations::FieldDecl>(d)
        if f != &null {
            return f->is_static()
        }

        var unsafe *v = dyn_cast<Declarations::VariableDecl>(d)
        if v != &null {
            return v->is_static()
        }

        var unsafe *fn_ = dyn_cast<Declarations::FunctionDecl>(d)
        if fn_ != &null {
            return !fn_->is_method()
        }

        return false
    }

    /// The decl to blame in the note: the single hit, or the first candidate
    /// of an overload set.
    priv fn _hit_decl(self, h: NameHit) -> unsafe *Decl {
        if h.decl != &null {
            return h.decl
        }

        if h.cell == &null {
            return &null
        }

        if h.cell->size() == 0 {
            return &null
        }

        return h.cell->get(0)
    }

    /// Is `self` bound here? False in a static method and in a free function
    /// holding a local type -- there `self.` would be a second error, so the
    /// fix-it must not suggest it.
    priv fn _has_self_binding(self) -> bool {
        if self._self_imm == u32::MAX {
            return false
        }

        var n = self.locals.size()
        for var i: usize = 0; i < n; ++i {
            if self.locals[n - 1 - i].has(self._self_imm) {
                return true
            }
        }

        return false
    }

    /// The error home for the rule. Poisons the use: leaving it bound would
    /// hand T a member reference with no receiver, and every later pass would
    /// have to re-derive that this name was rejected.
    priv fn _report_unqualified_member(self, n: unsafe *NamedIdentExpr, h: NameHit) {
        var        nm  = self.sc->ctx->get_spelling(n->name)
        var unsafe *d  = self._hit_decl(h)
        var        st  = self._is_static_member(d)
        var        pfx = "self."
        // Parenthesized on purpose; see the NOTE in _resolve_name.
        if st || !self._has_self_binding() {
            pfx = "Self::"
        }

        var what = "member"
        if st {
            what = "static member"
        }

        if d != &null && isa<Declarations::FunctionDecl>(d) {
            what = "method"
            if st {
                what = "static method"
            }
        }

        var b = self.sc->diag->report(
            DiagID::R049E,
            n->range.start,
            f"use of {what} '{nm}' requires an explicit qualifier",
        )

        b.first(n->range)
        if d != &null {
            b.note(DiagCode(DiagID::R049N), d->range.start, f"'{nm}' is declared here")->first(
                d->range,
            )
        }

        b.insert(n->range.start, pfx, f"qualify with '{pfx}'")
        b.emit()

        n->poison()
        self.sc->trace.use_site(
            self._name_imm(n->name),
            n->range,
            d,
            TraceVia::Scope,
            h.found_in,
            usize::MAX,
            0,
            true,
            &null,
            TraceVia::None,
            &null,
        )
    }

    /// False when no overlay target for \p imm is visible here: a private
    /// one never is (it is another file's), a protected one only from a
    /// file of its own module (AST/VisibilityFacts.k). The visibility is
    /// the decl's, its file's default applied (ImportResolution::_cell_vis).
    priv fn _overlay_access_ok(self, imm: u32) -> bool {
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return true
        }

        if tu->import_overlay == &null {
            return true
        }

        var unsafe *entry = tu->import_overlay->entry(imm)
        if entry == &null {
            return true
        }

        if entry->targets.size() == 0 {
            return true
        }

        for var i: usize = 0; i < entry->targets.size(); ++i {
            var v = entry->targets[i].vis
            if v == OverlayVisibility::Public {
                return true
            }

            if v == OverlayVisibility::Protected
                && same_module(self._target_tu(unsafe &entry->targets[i]), tu) {
                return true
            }
        }

        return false
    }

    /// The decl an overlay target stands for: its own, or its cell's first.
    priv fn _target_decl(self, t: unsafe *OverlayTarget) -> unsafe *Decl {
        if t == &null {
            return &null
        }

        if t->decl != &null {
            return t->decl
        }

        if t->cell != &null && t->cell->size() > 0 {
            return t->cell->get(0)
        }

        return &null
    }

    priv fn _target_tu(self, t: unsafe *OverlayTarget) -> unsafe *TranslationUnit {
        var unsafe *d = self._target_decl(t)
        if d == &null {
            return &null
        }

        return tu_of_scope(d->semantic_dc)
    }

    /// R047E for a name every import of which is out of reach here: why
    /// (written `priv`, written `prot` outside its module, or its file's
    /// default), a note at the declaration, a fix-it making it `pub`, and
    /// SC272W chained when a `prot` failed for want of a module.k.
    priv fn _report_overlay_access(self, imm: u32, n: unsafe *NamedIdentExpr) {
        var        nm        = self.sc->ctx->get_spelling(n->name)
        var unsafe *entry    = self.sc->tu->import_overlay->entry(imm)
        var unsafe *t        = unsafe &entry->targets[0]
        var unsafe *d        = self._target_decl(t)
        var unsafe *home     = self._target_tu(t)
        var        in_module = !tu_module_dir(home).empty()
        var        msg       = f"'{nm}' is imported but is declared private in its module"
        var        written   = VisibilityKind::None
        if d != &null {
            written = d->visibility
        }

        if written == VisibilityKind::Protected {
            msg = if (in_module) => (f"'{nm}' is imported but is declared protected: visible only in the files of its module")
                  else => f"'{nm}' is imported but is declared protected, and its file is in no module: visible only in its file"
        } else if written == VisibilityKind::None {
            msg = if (t->vis == OverlayVisibility::Protected) => (f"'{nm}' is imported but is protected to its module: a declaration with no visibility keyword is 'prot' in a module")
                  else => f"'{nm}' is imported but is private to its file: a declaration with no visibility keyword is 'priv' when its file has no module.k above it"
        }

        var b = self.sc->diag->report(DiagID::R047E, n->range.start, msg)
        b.first(n->range)
        if d != &null && d->range.is_valid() {
            var nt = decl_name_tok(d).range
            b.note(DiagCode(DiagID::R047N), nt.start, f"'{nm}' is declared here")->child_first(nt)
            var wr = d->visibility_range()
            if wr.is_valid() {
                b.fix(wr, "pub", f"make '{nm}' public")
            } else {
                b.insert(d->range.start, "pub ", f"make '{nm}' public")
            }
        }

        if t->vis == OverlayVisibility::Protected && !in_module {
            b.warning(
                DiagCode(DiagID::SC272W),
                n->range.start,
                f"'{nm}' is 'prot', but its file has no module.k above it, so it is shared with no other file; add a module.k to the directory that should share it",
            )->child_first(n->range)
        }

        b.emit()
    }

    /// Chain STEPS are not N's to bind: everything after the first `.`/`::`
    /// needs the type of the base, and that does not exist until T (header,
    /// "Explicitly NOT done here"). The RAV agrees   traverse_chain_expr
    /// walks the base and each step's generic args but never `st->name`   so
    /// a member access leaves NO row of any kind behind it.
    ///
    /// That is indistinguishable, in a dump, from a name that was never seen
    /// at all. This override closes only that gap: it records each step as
    /// deferred and resolves NOTHING. No lookup, no binding, no diagnostic,
    /// no write to `st->resolved_decl`   T still owns every one of those.
    /// Gated on `trace.enabled` (Compiler/Spec/Pipeline.md invariant #6).
    fn traverse_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *ChainExpr {
        if n == &null {
            return n
        }

        // Base first, so the base's own `use` row lands before the steps that
        // hang off it and the section reads left-to-right like the source.
        var unsafe *out = RecursiveASTVisitor<NameResolution>::traverse_chain_expr(self, n)
        if !self.sc->trace.enabled {
            return out
        }

        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st == &null {
                continue
            }

            var mk  = TraceMemberKind::Name
            var imm = u32::MAX
            var at  = st->range
            if st->is_operator() {
                mk = TraceMemberKind::Operator
            } else if st->is_tuple_index() {
                mk = TraceMemberKind::TupleIndex
            } else if st->name != &null {
                imm = self._name_imm(st->name->name)
                at  = st->name->range
            }

            var sep = TraceSep::Dot
            match st->access_kind {
                case ChainExpr::AccessKind::Dot {
                    sep = TraceSep::Dot
                } case ChainExpr::AccessKind::Arrow {
                    sep = TraceSep::Arrow
                } case ChainExpr::AccessKind::ColonColon {
                    sep = TraceSep::ColonColon
                } case ChainExpr::AccessKind::QuestionDot {
                    sep = TraceSep::QuestionDot
                } case ChainExpr::AccessKind::QuestionArrow {
                    sep = TraceSep::QuestionArrow
                }
            }

            self.sc->trace.member_step(imm, at, mk, sep, st->index)
        }

        return out
    }

    /// A named non-variable decl at statement scope (`fn inner`, `class
    /// Local`, `type Row = ...`). In no table by design; visible to its OWN
    /// body (recursion), so it is declared BEFORE the walk, unlike `var`.
    fn traverse_decl_stmt(self, n: unsafe *DeclStmt) -> unsafe *DeclStmt {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_decl_stmt(n) == false {
            return n
        }

        var unsafe *d = n->decl
        if d == &null {
            return n
        }

        var imm = self._stmt_decl_imm(d)
        if imm != u32::MAX && !self.locals.empty() {
            self._declare_local(imm, d, d->range)
        }

        n->decl = self.dyn()->dispatch_decl(d)
        return n
    }

    /// Name imm for the decl kinds traverse_decl_stmt declares; u32(-1) for
    /// everything else (VariableDecl declares itself after its initializer).
    priv fn _stmt_decl_imm(self, d: unsafe *Decl) -> u32 {
        // A specialization is not a name binding. It is reached through its
        // primary's instance registry, never by lookup, so declaring it here
        // shadows the primary for the rest of the enclosing body -- which is
        // exactly what a local `class <> Box<bool>` was doing. Same rule
        // _pick_type_candidate and _sole_entity already apply.
        if NameLookup::is_specialization(d) {
            return u32::MAX
        }

        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            if f->is_operator || f->is_out_of_line() {
                return u32::MAX
            }

            return self._name_imm(f->name)
        }

        if isa<Declarations::ClassDecl>(d) {
            return self._name_imm(cast<Declarations::ClassDecl>(d)->name)
        }

        if isa<Declarations::StructDecl>(d) {
            return self._name_imm(cast<Declarations::StructDecl>(d)->name)
        }

        if isa<Declarations::UnionDecl>(d) {
            return self._name_imm(cast<Declarations::UnionDecl>(d)->name)
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return self._name_imm(cast<Declarations::InterfaceDecl>(d)->name)
        }

        if isa<Declarations::EnumDecl>(d) {
            return self._name_imm(cast<Declarations::EnumDecl>(d)->name)
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return self._name_imm(cast<Declarations::TypeAliasDecl>(d)->name)
        }

        return u32::MAX
    }

    /// ## pattern heads
    ///
    /// A ConstructorPattern / UnresolvedConstructorPattern head is a name
    /// use, never a binder (see the header), so it is bound as an ordinary
    /// expression before the subpatterns are walked. A dotted head is null:
    /// `.Red` resolves against the scrutinee's enum, in PatternTyping.

    fn traverse_constructor_pattern(self,
                                    n: unsafe *ConstructorPattern) -> unsafe *ConstructorPattern {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_constructor_pattern(n) == false {
            return n
        }

        if n->head != &null {
            n->head = self.dyn()->dispatch_expr(n->head)
        }

        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->subpatterns.get(i))
        }

        return n
    }

    fn traverse_unresolved_constructor_pattern(self, n: unsafe *UnresolvedConstructorPattern)
            -> unsafe *UnresolvedConstructorPattern {
        if n == &null {
            return n
        }

        if self.dyn()->walkup_unresolved_constructor_pattern(n) == false {
            return n
        }

        if n->head != &null {
            // Only a bare name gets the `var` hint: `case a::b` is plainly
            // a path, not a binder that lost its keyword.
            var saved = self._in_pattern_head
            self._in_pattern_head = isa<NamedIdentExpr>(n->head)
            n->head               = self.dyn()->dispatch_expr(n->head)
            self._in_pattern_head = saved
        }

        for var i: usize = 0; i < n->subpatterns.size(); ++i {
            if self.stop {
                break
            }

            self.dyn()->dispatch_pattern(*n->subpatterns.get(i))
        }

        return n
    }

    /// ## helpers

    /// The lookup key for a name token. `self` is KwSelf, not an
    /// identifier, so it gets the interned spelling instead; everything
    /// else routes through the ordinary imm path.
    priv fn _name_imm(self, tok: Token) -> u32 {
        var im = self.sc->ctx->get_ident_imm(tok)
        if im != u32::MAX {
            return im
        }

        // Unwrapped: a `self` passed as a macro argument reaches here as a
        // TkMacroExpand token, and matching only the raw kind left it
        // unbound (the I003E invariant error for `check!(self.x, ...)`).
        if self.sc->ctx->unwrap_token(tok).kind == TokenKind::KwSelf {
            return self._self_imm
        }

        return u32::MAX
    }

    /// The imm of a decl's own name, for ctor-key detection. u32(-1) for
    /// kinds that have no name token.
    priv fn _decl_name_imm(self, d: unsafe *Decl) -> u32 {
        if d == &null {
            return u32::MAX
        }

        if isa<Declarations::ClassDecl>(d) {
            return self.sc->ctx->get_ident_imm(cast<Declarations::ClassDecl>(d)->name)
        }

        if isa<Declarations::StructDecl>(d) {
            return self.sc->ctx->get_ident_imm(cast<Declarations::StructDecl>(d)->name)
        }

        if isa<Declarations::UnionDecl>(d) {
            return self.sc->ctx->get_ident_imm(cast<Declarations::UnionDecl>(d)->name)
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return self.sc->ctx->get_ident_imm(cast<Declarations::InterfaceDecl>(d)->name)
        }

        if isa<Declarations::EnumDecl>(d) {
            return self.sc->ctx->get_ident_imm(cast<Declarations::EnumDecl>(d)->name)
        }

        if isa<Declarations::ModuleDecl>(d) {
            return self.sc->ctx->get_ident_imm(cast<Declarations::ModuleDecl>(d)->name)
        }

        return u32::MAX
    }
}
