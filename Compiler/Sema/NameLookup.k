/// --- The Kairo Project --------------------------- Sema/NameLookup.k --- ///
///
///   \brief THE shared lookup core. NameResolution (N) and TypeResolution
///          (T) both stand on these four primitives; neither pass owns
///          private lookup logic. A component on SemaContext, not a pass.
///
///   Import direction: this file imports AST only. SemaContext imports
///   this; passes reach it via sc->lookup. It must never import
///   SemaContext or any pass (cycle rule, see SemaContext.k).
///
///   Phase: LOWER (component; used from N onward)
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;

/// \class SemaLookupResult
/// \brief One lookup's outcome: the frozen cell + where it was found.
///        Ephemeral by law (see file header).
class SemaLookupResult {
    pub var cell:        *OverloadCell = &null;  ///< null = not found.
    pub var found_in:    *DeclContext  = &null;  ///< scope that answered.
    pub var via_overlay: bool          = false;  ///< true if the TU import overlay answered.

    static fn not_found() -> SemaLookupResult {
        var r = SemaLookupResult{};
        return r;
    }

    fn found(self) -> bool {
        return (self.cell != &null) && (self.cell->size() > 0);
    }

    /// Exactly one candidate the common case, bind directly.
    fn single(self) -> bool {
        return self.found() && self.cell->is_single();
    }

    fn overloaded(self) -> bool {
        return self.found() && self.cell->is_overloaded();
    }

    fn first(self) -> *Decl {
        if !self.found() { return &null; }
        return self.cell->get(0);
    }
}

/// \class NameLookup
/// \brief The four lookup primitives over frozen dc_symbols + overlay.
///
///        1. in_context   : one scope, no walk.
///        2. unqualified  : DC parent chain, then TU import_overlay, miss.
///        3. context_of   : *Decl -> its owned *DeclContext (or null)
///                          the step that makes qualified lookup "the AST
///                          is the trie": a child scope is reached THROUGH
///                          its decl, there is no parallel tree.
///        4. qualified_step: resolve one `::` segment through a prior
///                          segment's decl. Callers loop this; per-segment
///                          resolved_decl slots on ChainType/ChainExpr are
///                          written by the PASS, not by this component.
///
///        NOT here by design: body-local scope stacks (N(b) owns its
///        lexical stack; locals are excluded from symbol tables), member
///        lookup through extensions (needs conformance folding sema
///        builds it on qualified_step later), and ADL (own algorithm,
///        arrives with operator resolution).
class NameLookup {
    pub var tu: obs::<TranslationUnit>;

    fn NameLookup(self) { }

    /// Wire to the TU under resolution. SemaContext calls this once.
    fn init(self, tu: *TranslationUnit) {
        self.tu = tu;
    }

    // --- Primitive 1: single scope --------------------------------------------

    fn in_context(self, dc: *DeclContext, name: DeclName) -> SemaLookupResult {
        if dc == &null { return SemaLookupResult::not_found(); }
        var cell = dc->lookup_symbol(name);
        if cell == &null { return SemaLookupResult::not_found(); }
        var r = SemaLookupResult{};
        r.cell     = cell;
        r.found_in = dc;
        return r;
    }

    // --- Primitive 2: unqualified ---------------------------------------------

    /// RESOLUTION.md order: this DC's table, then the DC parent chain,
    /// then import_overlay at TU level, then miss. Executable scopes have
    /// no tables (dc_symbols null), so the walk skips them for free
    /// body locals are the caller's lexical stack, checked BEFORE calling
    /// this.
    fn unqualified(self, from: *DeclContext, name: DeclName) -> SemaLookupResult {
        var dc = from;
        while dc != &null {
            var r = self.in_context(dc, name);
            if r.found() { return r; }
            dc = dc->dc_parent;
        }

        if (self.tu != &null) && (self.tu->import_overlay != &null) {
            var cell = self.tu->import_overlay->lookup(name);
            if cell != &null {
                var r = SemaLookupResult{};
                r.cell        = cell;
                r.found_in    = static_cast::<*DeclContext>(self.tu);
                r.via_overlay = true;
                return r;
            }
        }

        return SemaLookupResult::not_found();
    }

    // --- Primitive 3: decl -> owned scope -------------------------------------

    /// The scope a decl OWNS (its body), or null for non-scope-owning
    /// decls. Type aliases return null on purpose: alias expansion is
    /// TypeResolution's job; qualified lookup through an alias must go
    /// through T's expansion, not silently through here.
    static fn context_of(d: *Decl) -> *DeclContext {
        if d == &null { return &null; }
        if isa::<ClassDecl>(d)     { return static_cast::<*DeclContext>(cast::<ClassDecl>(d));     }
        if isa::<StructDecl>(d)    { return static_cast::<*DeclContext>(cast::<StructDecl>(d));    }
        if isa::<EnumDecl>(d)      { return static_cast::<*DeclContext>(cast::<EnumDecl>(d));      }
        if isa::<UnionDecl>(d)     { return static_cast::<*DeclContext>(cast::<UnionDecl>(d));     }
        if isa::<InterfaceDecl>(d) { return static_cast::<*DeclContext>(cast::<InterfaceDecl>(d)); }
        if isa::<ModuleDecl>(d)    { return static_cast::<*DeclContext>(cast::<ModuleDecl>(d));    }
        if isa::<ExtensionDecl>(d) { return static_cast::<*DeclContext>(cast::<ExtensionDecl>(d)); }
        return &null;
    }

    // --- Primitive 4: one qualified segment -----------------------------------

    /// Resolve `<prev>::name` where \p prev is the decl the previous
    /// segment bound to. Redecl-chain note: the definition's context is
    /// reached through whichever link the previous segment bound; N(a)
    /// links chains before N(b) binds, so canonical/most-recent choice is
    /// the caller's policy, not this primitive's.
    fn qualified_step(self, prev: *Decl, name: DeclName) -> SemaLookupResult {
        var dc = NameLookup::context_of(prev);
        if dc == &null { return SemaLookupResult::not_found(); }
        return self.in_context(dc, name);
    }
}
