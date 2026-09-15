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
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::ImportOverlay::*;
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
        return self.in_context(dc, name, "");
    }

    /// Look one name up in ONE scope, whichever TU that scope lives in.
    ///
    /// A DeclContext's table is keyed by ITS OWN TU's imms (hard invariant
    /// #2). Probing a foreign scope with THIS TU's imm index is not a miss --
    /// it is a silent WRONG answer whenever the two interners happen to agree
    /// on an index, which for two files of a few names each they routinely
    /// do. `spelling` is the escape hatch, exactly as in
    /// MemberLookup::in_scope: for a foreign scope the name is re-interned
    /// into that TU's imm space and probed there.
    ///
    /// The no-spelling overload above stays for same-TU callers. A caller
    /// that can reach a foreign scope -- anything walking `::` -- must pass
    /// the spelling.
    fn in_context(self, dc: *DeclContext, name: DeclName, spelling: string) -> SemaLookupResult {
        if dc == &null { return SemaLookupResult::not_found(); }
        var cell = self._probe(dc, name, spelling);
        if cell == &null { return SemaLookupResult::not_found(); }
        var r = SemaLookupResult{};
        r.cell     = cell;
        r.found_in = dc;
        return r;
    }

    /// The imm-translation half of in_context. Only IDENTIFIER payloads are
    /// per-TU: operator and ctor keys are built from TokenKinds, which are
    /// stable across the build.
    priv fn _probe(self, dc: *DeclContext, name: DeclName, spelling: string) -> *OverloadCell {
        if name.kind != DeclNameKind::Identifier { return dc->lookup_symbol(name); }
        if spelling.size() == 0                  { return dc->lookup_symbol(name); }
        var other = NameLookup::tu_of(dc);
        if other == &null       { return dc->lookup_symbol(name); }
        if other == self.tu     { return dc->lookup_symbol(name); }
        if self.tu == &null     { return dc->lookup_symbol(name); }
        var ctx = self.tu->ctx;
        if ctx == &null         { return &null; }
        if ctx->tcm == &null    { return &null; }
        var imms = ctx->tcm->get_imm_table_for_fid(other->fid);
        if imms == &null        { return &null; }
        return SymbolTable::lookup_foreign(dc->dc_symbols, imms, spelling);
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

        // The overlay of the TU the walk STARTED in, not the pass's TU. They
        // differ when T reads a node that lives in an imported file (alias body,
        // default on a primary): `name` is keyed by THAT file's imms and only
        // that file's overlay shares the key space. Probing self.tu's overlay
        // with a foreign imm is a silent wrong answer or a false miss (#2).
        var home = NameLookup::tu_of(from);
        if home == &null { home = self.tu; }
        if (home != &null) && (home->import_overlay != &null) && name.is_ident() {
            var cell = home->import_overlay->lookup_ident(name.payload);
            if cell != &null {
                var r = SemaLookupResult{};
                r.cell        = cell;
                r.found_in    = static_cast::<*DeclContext>(home);
                r.via_overlay = true;
                return r;
            }
        }
        return SemaLookupResult::not_found();
    }

    /// unqualified() for the body of an out-of-line definition whose OWNING
    /// scope lives in another TU -- `fn S::g` in a Kairo file, S imported from
    /// a header. Two halves, in C++'s order for a member body:
    ///
    ///   1. the owning chain (the class, its enclosing namespaces), probed by
    ///      \p spelling: each of those tables is keyed by the HEADER TU's imms,
    ///      and this TU's imm there is a silent wrong answer (`other()` found
    ///      S's `f`). The walk stops before the header's FILE scope and never
    ///      reads its overlay: those are that file's names, not this one's.
    ///   2. on a miss, \p lexical -- the scope the definition was WRITTEN in --
    ///      through plain unqualified(), which reaches this file's own scope
    ///      and overlay. Without it a free function beside the definition was
    ///      invisible from inside it.
    fn unqualified_out_of_line(self, from: *DeclContext, name: DeclName,
                               spelling: string, lexical: *DeclContext) -> SemaLookupResult {
        var dc = from;
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit { break; }
            var r = self.in_context(dc, name, spelling);
            if r.found() { return r; }
            dc = dc->dc_parent;
        }
        return self.unqualified(lexical, name);
    }

    // --- Primitive 3: decl -> owned scope -------------------------------------

    /// The scope a decl OWNS (its body), or null for non-scope-owning
    /// decls. Type aliases return null on purpose: alias expansion is
    /// TypeResolution's job; qualified lookup through an alias must go
    /// through T's expansion, not silently through here.
    /// The TranslationUnit a scope ultimately lives in, or null.
    static fn tu_of(dc: *DeclContext) -> *TranslationUnit {
        var c = dc;
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit {
                return reinterpret_cast::<*TranslationUnit>(c);
            }
            c = c->dc_parent;
        }
        return &null;
    }

    /// The ASTContext a decl's NAMES live in, or null when it has no scope to
    /// walk up from.
    ///
    /// Names are interned PER FILE, so spelling a decl reached through an
    /// import with the importing TU's context yields the interner's fallback
    /// text ("$FALLBACK-MISSING-INTERN$ ...") rather than the name. Anything
    /// that renders a decl -- a diagnostic, a dump -- has to ask the decl
    /// where its names live first.
    static fn ctx_of(d: *Decl) -> *ASTContext {
        if d == &null { return &null; }
        var dc = NameLookup::context_of(d);
        if dc == &null {
            if d->semantic_dc != &null      { dc = reinterpret_cast::<*DeclContext>(d->semantic_dc); }
            else if d->lexical_dc != &null  { dc = reinterpret_cast::<*DeclContext>(d->lexical_dc); }
        }
        var tu = NameLookup::tu_of(dc);
        if tu == &null { return &null; }
        return tu->ctx;
    }

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

        /// The canonical link of `d`'s redecl chain, or null when `d` is not a
    /// redeclarable kind.
    ///
    /// FunctionDecl is INCLUDED as of RedeclMerge: its chains are linked
    /// after T, on canonical signatures, so its canonical is no longer
    /// necessarily itself. Before R existed this arm was deliberately
    /// absent and collapsing on it would have been a lie; a caller running
    /// BEFORE R (N(b), which runs before T) still sees each function as its
    /// own canonical, because that is what the chain says at that point.
    static fn chain_canonical(d: *Decl) -> *Decl {
        if d == &null { return &null; }
        if isa::<ClassDecl>(d)     { return static_cast::<*Decl>(cast::<ClassDecl>(d)->canonical_decl());     }
        if isa::<StructDecl>(d)    { return static_cast::<*Decl>(cast::<StructDecl>(d)->canonical_decl());    }
        if isa::<UnionDecl>(d)     { return static_cast::<*Decl>(cast::<UnionDecl>(d)->canonical_decl());     }
        if isa::<InterfaceDecl>(d) { return static_cast::<*Decl>(cast::<InterfaceDecl>(d)->canonical_decl()); }
        if isa::<EnumDecl>(d)      { return static_cast::<*Decl>(cast::<EnumDecl>(d)->canonical_decl());      }
        if isa::<ModuleDecl>(d)    { return static_cast::<*Decl>(cast::<ModuleDecl>(d)->canonical_decl());    }
        if isa::<FunctionDecl>(d)  { return static_cast::<*Decl>(cast::<FunctionDecl>(d)->canonical_decl());  }
        return &null;
    }

    /// Every link of `d`'s redeclaration ring, in insertion order, into
    /// \p out. One element (just `d`) for a non-redeclarable kind or an
    /// unlinked decl.
    ///
    /// The ring is not the cell. A cell holds what a SCOPE declares; a ring
    /// holds what one ENTITY was declared as, and they diverge wherever an
    /// out-of-line definition is involved -- `fn C::bump` is in no symbol
    /// table, so a member with one in-class declaration and two out-of-line
    /// definitions is a cell of size 1 and a ring of size 3.
    static fn collect_chain(d: *Decl, out: ref!(vec::<*Decl>)) {
        if d == &null { return; }
        if      isa::<ClassDecl>(d)     { NameLookup::_ring::<ClassDecl>(cast::<ClassDecl>(d), out);         }
        else if isa::<StructDecl>(d)    { NameLookup::_ring::<StructDecl>(cast::<StructDecl>(d), out);       }
        else if isa::<UnionDecl>(d)     { NameLookup::_ring::<UnionDecl>(cast::<UnionDecl>(d), out);         }
        else if isa::<InterfaceDecl>(d) { NameLookup::_ring::<InterfaceDecl>(cast::<InterfaceDecl>(d), out); }
        else if isa::<EnumDecl>(d)      { NameLookup::_ring::<EnumDecl>(cast::<EnumDecl>(d), out);           }
        else if isa::<ModuleDecl>(d)    { NameLookup::_ring::<ModuleDecl>(cast::<ModuleDecl>(d), out);       }
        else if isa::<FunctionDecl>(d)  { NameLookup::_ring::<FunctionDecl>(cast::<FunctionDecl>(d), out);   }
        else                            { out.push_back(d); }
    }

    /// Walk one typed ring from first_decl() back to the head. Bounded by
    /// the ring, which Redeclarable guarantees is circular and finite.
    priv static fn <T> _ring(d: *T, out: ref!(vec::<*Decl>)) {
        var head = d->first_decl();
        var cur  = head;
        while true {
            out.push_back(static_cast::<*Decl>(cur));
            cur = cur->next_in_chain();
            if cur == head { break; }
        }
    }

    /// The decl that REPRESENTS the entity `d` belongs to: the chain's
    /// canonical (the definition once N(a) retargeted it), else `d` itself.
    /// THE identity every canonical type keys on. Use nothing else.
    static fn representative(d: *Decl) -> *Decl {
        var c = NameLookup::chain_canonical(d);
        if c == &null { return d; }
        return c;
    }

    /// Explicit/partial specialization: its own entity, never a chain link,
    /// never a RecordType::decl. M1 pairs it with its primary.
    static fn is_specialization(d: *Decl) -> bool {
        if d == &null { return false; }
        if isa::<ClassDecl>(d)    { return cast::<ClassDecl>(d)->is_specialization();    }
        if isa::<StructDecl>(d)   { return cast::<StructDecl>(d)->is_specialization();   }
        if isa::<UnionDecl>(d)    { return cast::<UnionDecl>(d)->is_specialization();    }
        if isa::<FunctionDecl>(d) { return cast::<FunctionDecl>(d)->is_specialization(); }
        if isa::<EnumDecl>(d)      { return cast::<EnumDecl>(d)->is_specialization();      }
        if isa::<InterfaceDecl>(d) { return cast::<InterfaceDecl>(d)->is_specialization(); }
        return false;
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
