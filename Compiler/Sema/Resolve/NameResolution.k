/// --- The Kairo Project ------------------------ Sema/NameResolution.k --- ///
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
///       N(b) binding -- RAV walk over the TU. Every NamedIdentExpr /
///            chain-head / pattern-head gets resolved_decl (unique) or
///            candidate_cell (overload set, aliases the frozen cell).
///            ANNOTATES nodes so jump-to-def / completion can query
///            resolution later.
///
///     Lookup itself lives in sc->lookup (NameLookup, the four
///     primitives); this pass owns POLICY only: the lexical local stack
///     (locals are excluded from symbol tables -- executable scopes have
///     no dc_symbols), binding order (locals -> unqualified -> miss),
///     and diagnostics. Redefinition + unresolved-ident errors live
///     HERE, nowhere else.
///
///   Phase: RESOLVE
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Diagnostic::Registry::*;

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
class LocalScope {
    // TODO(N): storage. Simplest correct thing: parallel vecs of
    //   (name imm : u32, decl : *Decl), linear scan per frame. Frames
    //   are small; do NOT build a hash map until a profile says so.
    // pub var names: vec::<u32>;
    // pub var decls: vec::<*Decl>;

    // TODO(N): fn declare(imm, d)  -- push; caller already checked for
    //           same-frame redefinition (that's a diagnostic, owner: N).
    // TODO(N): fn find(imm) -> *Decl -- reverse linear scan, null on miss.
    var names: vec::<u32>;
    var decls: vec::<*Decl>;

    fn declare(self, imm: u32, d: *Decl) {
        self.names.push_back(imm);
        self.decls.push_back(d);
    }

    fn find(self, imm:u32) -> *Decl {
        for var i: usize = self.names.size(); i > 0; --i {
            if self.names.get(i - 1) == imm {
                return self.decls.get(i - 1);
            }
        }
        return &null;
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
///                    popped by traverse_block / traverse_function_decl.
///                    Checked BEFORE unqualified (NameLookup contract).
///
class NameResolution derives RecursiveASTVisitor::<NameResolution> {
    pub var sc: *SemaContext;

    var cur_dc: *DeclContext = &null;     ///< table-owning scope cursor.
    var locals: vec::<LocalScope>;        ///< executable-scope stack.

    fn NameResolution(self, sc: *SemaContext) {
        self.sc = sc;
    }

    /// Entry point. Precondition (asserted): Expanded. Postcondition
    /// (advanced by the DRIVER, not here): NamesResolved.
    fn run(self) {
        self.sc->require_phase(SemaPhase::Verified);
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        self._validate_decls(tu);          // N(a)
        self._bind(tu);                    // N(b)
    }

    // === N(a): decl validation ============================================
    //
    // No RAV needed -- this half never enters expressions. Walk dc_decls
    // per DeclContext, recursing through NameLookup::context_of for
    // nested type scopes (same shape as ConstraintExtraction's
    // _recurse_members).

    priv fn _validate_decls(self, tu: *TranslationUnit) {
        // TODO(N-a): walk tu's top-level decls; for each DeclContext:
        //   1. Redeclarable chains: link same-name same-kind redecls in
        //      source order (AST/Mixin/Redeclarable.k). Definition-vs-
        //      forward policy lives here.
        //   2. Overload sets: each OverloadCell with size > 1 -- verify
        //      every member is a FunctionDecl. Mixed-kind cell =
        //      redefinition error (sole home: HERE).
        //   3. tu->out_of_line: attach each out-of-line def to its
        //      in-class decl (lookup via qualified_step on the scope
        //      path).
        //   4. sc->well_known: resolve the WellKnownType names once
        //      (lookup in the root/prelude scope, store the *Decl).
        
    }

    // === N(b): binding ====================================================

    priv fn _bind(self, tu: *TranslationUnit) {
        self.cur_dc = static_cast::<*DeclContext>(tu);
        // TODO(N-b): drive the RAV over tu->program->items (same item
        // loop as ConstraintExtraction::run, but route each decl through
        // self.dispatch_decl / traverse so the overrides below fire).
    }

    /// THE core lookup policy, in binding order:
    ///   1. locals, innermost frame first   (body locals shadow everything)
    ///   2. sc->lookup.unqualified(cur_dc)  (DC chain -> import overlay)
    ///   3. miss                            (unresolved-ident diagnostic)
    priv fn _resolve_name(self, imm: u32) -> SemaLookupResult {
        // TODO(N-b): loop self.locals back-to-front, frame.find(imm);
        //   on hit synthesize a SemaLookupResult around the single decl.
        // TODO(N-b): fall through to
        //   self.sc->lookup.unqualified(self.cur_dc, /* DeclName from imm */);
        for (var i = self.locals.size(); i > 0; --i) {
            var frame = self.locals.get(i - 1);
            var d = frame.find(imm);
            if d != &null {
                var r = SemaLookupResult{};
                r.cell = &OverloadCell;
                r.cell->push_back(d);
                r.found_in = self.cur_dc;
                return r;
            }
        }
        return SemaLookupResult::not_found();
    }

    // --- scope cursor management ------------------------------------------
    //
    // Pattern for every override: save cursor / push frame -> call the
    // BASE traverse (recurses children) -> restore. The RAV rebinding
    // contract still holds: return what base returned.

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        // TODO(N-b): push a LocalScope frame; declare params + self into
        //   it; move cur_dc if the function owns a table-bearing DC;
        //   call base traverse_function_decl; pop/restore both.
        return n; // TODO: replace with base call
    }

    fn traverse_block(self, b: *CompoundStmt) -> *CompoundStmt {
        // TODO(N-b): push LocalScope frame; base; pop.
        return b; // TODO: replace with base call
    }

    // TODO(N-b): traverse_class_decl / struct_decl / enum_decl /
    //   union_decl / interface_decl / module_decl / extension_decl --
    //   identical save/restore of cur_dc into the decl's own DC
    //   (NameLookup::context_of(n)). No locals frame: type scopes have
    //   tables, not lexical locals.

    // TODO(N-b): variable decl statements -- on traverse_decl_stmt /
    //   traverse_variable_decl, AFTER traversing the initializer
    //   (init sees the OUTER scope: `var x = x;` refers to outer x),
    //   declare the name into the top locals frame. Same-frame
    //   duplicate -> redefinition error.

    // --- binding hooks ----------------------------------------------------

    /// The heart of N. Every unqualified name use lands here.
    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        // TODO(N-b):
        //   0. skip if already bound (n->is_bound()) -- e.g. `self`,
        //      handled at function entry; also skip contexts that are
        //      not USES (a decl's own name token never routes here, but
        //      verify for pattern heads).
        //   1. imm from n->name (Lexer::Immediate / TokenText path).
        //   2. var r = self._resolve_name(imm);
        //   3. r.single()     -> n->resolved_decl  = r.first();
        //      r.overloaded() -> n->candidate_cell = r.cell;   // alias, never copy
        //      miss           -> unresolved-ident diag (sole home: HERE),
        //                        leave both slots null (poisoned, T skips).
        return true;
    }

    // TODO(N-b, DEFERRED -- land unqualified first): chain heads.
    //   walkup_chain_expr: bind segment[0] via _resolve_name, then loop
    //   sc->lookup.qualified_step(prev_decl, seg.name) writing each
    //   segment's resolved_decl. Per NameLookup's contract the PASS
    //   writes the per-segment slots, not the component. Alias segments
    //   return null context_of by design -> defer through T.

    // TODO(N-b, DEFERRED): pattern heads (BindingPattern /
    //   UnresolvedConstructorPattern.head) -- same policy as idents;
    //   UnresolvedConstructorPattern that RESOLVES to a ctor gets
    //   rewritten by a later pass, N only annotates.
}





