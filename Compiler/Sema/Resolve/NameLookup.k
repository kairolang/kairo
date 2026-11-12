/// --- The Kairo Project -------------------- Sema/Resolve/NameLookup.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::{
    DeclName,
    DeclNameKind,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::decl_ffi_tag_target
import AST::Node::Base::Decl
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, EnumDecl, ExtensionDecl, FunctionDecl, InterfaceDecl, ModuleDecl, StructDecl,
    UnionDecl,
}

/// \class SemaLookupResult
/// \brief One lookup's outcome: the frozen cell + where it was found.
///        Ephemeral by law (see file header).
pub class SemaLookupResult {
    pub var cell:        unsafe *OverloadCell = &null ///< null = not found.
    pub var found_in:    unsafe *DeclContext  = &null ///< scope that answered.
    pub var via_overlay: bool                 = false ///< true if the TU import overlay answered.

    static fn not_found() -> SemaLookupResult {
        var r = SemaLookupResult{}
        return r
    }

    fn found(self) -> bool {
        return self.cell != &null && self.cell->size() > 0
    }

    /// Exactly one candidate the common case, bind directly.
    fn single(self) -> bool {
        return self.found() && self.cell->is_single()
    }

    fn overloaded(self) -> bool {
        return self.found() && self.cell->is_overloaded()
    }

    fn first(self) -> unsafe *Decl {
        if !self.found() {
            return &null
        }

        return self.cell->get(0)
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
pub class NameLookup {
    pub var tu: unsafe *TranslationUnit
    /// The raw SourceLocation of the spelled name a caller is resolving, or
    /// 0. Read only to log an overlay hit for --dump-import-uses: callers
    /// holding a token set it around their lookup, and a hit with 0 is a use
    /// no source text spells (the import lint must not try to rewrite it).
    pub var use_at: u32 = 0

    fn NameLookup(self) { }

    /// Wire to the TU under resolution. SemaContext calls this once.
    fn init(self, tu: unsafe *TranslationUnit) {
        self.tu = tu
    }

    /// # Primitive 1: single scope

    fn in_context(self, dc: unsafe *DeclContext, name: DeclName) -> SemaLookupResult {
        return self.in_context(dc, name, "")
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
    fn in_context(self,
                  dc:             unsafe *DeclContext,
                  name:           DeclName,
                  const spelling: string) -> SemaLookupResult {
        if dc == &null {
            return SemaLookupResult::not_found()
        }

        var unsafe *cell = self._probe(dc, name, spelling)
        if cell == &null {
            return SemaLookupResult::not_found()
        }

        var r = SemaLookupResult{}
        r.cell     = cell
        r.found_in = dc
        return r
    }

    /// The imm-translation half of in_context. Only IDENTIFIER payloads are
    /// per-TU: operator and ctor keys are built from TokenKinds, which are
    /// stable across the build.
    priv fn _probe(self,
                   dc:             unsafe *DeclContext,
                   name:           DeclName,
                   const spelling: string) -> unsafe *OverloadCell {
        if name.kind != DeclNameKind::Identifier {
            return dc->lookup_symbol(name)
        }

        if spelling.size() == 0 {
            return dc->lookup_symbol(name)
        }

        var unsafe *other = NameLookup::tu_of(dc)
        if other == &null {
            return dc->lookup_symbol(name)
        }

        if other == self.tu {
            return dc->lookup_symbol(name)
        }

        if self.tu == &null {
            return dc->lookup_symbol(name)
        }

        var unsafe *ctx = self.tu->ctx
        if ctx == &null {
            return &null
        }

        if ctx->tcm == &null {
            return &null
        }

        var unsafe *imms = ctx->tcm->get_imm_table_for_fid(other->fid)
        if imms == &null {
            return &null
        }

        return SymbolTable::lookup_foreign(dc->dc_symbols, imms, spelling)
    }

    /// # Primitive 2: unqualified

    /// Compiler/Spec/Pipeline.md order: this DC's table, then the DC parent chain,
    /// then import_overlay at TU level, then miss. Executable scopes have
    /// no tables (dc_symbols null), so the walk skips them for free
    /// body locals are the caller's lexical stack, checked BEFORE calling
    /// this.
    fn unqualified(self, from: unsafe *DeclContext, name: DeclName) -> SemaLookupResult {
        var unsafe *dc = from
        while dc != &null {
            var r = self.in_context(dc, name)
            if r.found() {
                return r
            }

            // A module is its whole ring: a name declared in an earlier
            // `module Foo { }` block is in scope in a later one, exactly as
            // if both had been written as one block. Tried only on a miss,
            // so a name this block declares still wins and the common
            // (single-block) case costs one extra isa.
            var unsafe *owner = dc->owner_decl()
            if owner != &null && isa<ModuleDecl>(owner) {
                var scopes = cxx::std::vector<unsafe *DeclContext>()
                NameLookup::module_scopes(owner, &scopes)
                for var i: usize = 0; i < scopes.size(); ++i {
                    if scopes[i] == dc {
                        continue
                    }

                    var rr = self.in_context(scopes[i], name)
                    if rr.found() {
                        return rr
                    }
                }
            }

            dc = dc->dc_parent
        }

        // The overlay of the TU the walk STARTED in, not the pass's TU. They
        // differ when T reads a node that lives in an imported file (alias body,
        // default on a primary): `name` is keyed by THAT file's imms and only
        // that file's overlay shares the key space. Probing self.tu's overlay
        // with a foreign imm is a silent wrong answer or a false miss (#2).
        var unsafe *home = NameLookup::tu_of(from)
        if home == &null {
            home = self.tu
        }

        if home != &null && home->import_overlay != &null && name.is_ident() {
            var unsafe *cell = home->import_overlay->lookup_ident(name.payload)
            if cell != &null {
                if home->import_overlay->uses != &null {
                    home->import_overlay->uses->record(
                        name.payload,
                        self.use_at,
                    )
                }

                var r = SemaLookupResult{}
                r.cell        = cell
                r.found_in    = unsafe (home as unsafe *DeclContext)
                r.via_overlay = true
                return r
            }
        }

        return SemaLookupResult::not_found()
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
    fn unqualified_out_of_line(self,
                               from:           unsafe *DeclContext,
                               name:           DeclName,
                               const spelling: string,
                               lexical:        unsafe *DeclContext) -> SemaLookupResult {
        var unsafe *dc = from
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit {
                break
            }

            var r = self.in_context(dc, name, spelling)
            if r.found() {
                return r
            }

            dc = dc->dc_parent
        }

        return self.unqualified(lexical, name)
    }

    /// # Primitive 3: decl -> owned scope

    /// The scope a decl OWNS (its body), or null for non-scope-owning
    /// decls. Type aliases return null on purpose: alias expansion is
    /// TypeResolution's job; qualified lookup through an alias must go
    /// through T's expansion, not silently through here.
    /// The TranslationUnit a scope ultimately lives in, or null.
    pub static fn tu_of(dc: unsafe *DeclContext) -> unsafe *TranslationUnit {
        var unsafe *c = dc
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit {
                return unsafe (c as unsafe *TranslationUnit)
            }

            c = c->dc_parent
        }

        return &null
    }

    /// The ASTContext a decl's NAMES live in, or null when it has no scope to
    /// walk up from.
    ///
    /// Names are interned PER FILE, so spelling a decl reached through an
    /// import with the importing TU's context yields the interner's fallback
    /// text ("$FALLBACK-MISSING-INTERN$ ...") rather than the name. Anything
    /// that renders a decl -- a diagnostic, a dump -- has to ask the decl
    /// where its names live first.
    pub static fn ctx_of(d: unsafe *Decl) -> unsafe *ASTContext {
        if d == &null {
            return &null
        }

        var unsafe *dc = NameLookup::context_of(d)
        if dc == &null {
            if d->semantic_dc != &null {
                dc = d->semantic_dc
            } else if d->lexical_dc != &null {
                dc = d->lexical_dc
            }
        }

        var unsafe *tu = NameLookup::tu_of(dc)
        if tu == &null {
            return &null
        }

        return tu->ctx
    }

    pub static fn context_of(d: unsafe *Decl) -> unsafe *DeclContext {
        if d == &null {
            return &null
        }

        if isa<ClassDecl>(d) {
            return (cast<ClassDecl>(d))
        }

        if isa<StructDecl>(d) {
            return (cast<StructDecl>(d))
        }

        if isa<EnumDecl>(d) {
            return (cast<EnumDecl>(d))
        }

        if isa<UnionDecl>(d) {
            return (cast<UnionDecl>(d))
        }

        if isa<InterfaceDecl>(d) {
            return (cast<InterfaceDecl>(d))
        }

        if isa<ModuleDecl>(d) {
            return (cast<ModuleDecl>(d))
        }

        if isa<ExtensionDecl>(d) {
            return (cast<ExtensionDecl>(d))
        }

        return &null
    }

    /// The canonical link of `d`'s redecl chain, or null when `d` is not a
    /// redeclarable kind.
    ///
    /// FunctionDecl is included: its chains are linked after T, on canonical
    /// signatures, so its canonical is not necessarily itself. A caller
    /// running BEFORE R (N(b), which runs before T) still sees each function
    /// as its own canonical, because that is what the chain says at that
    /// point.
    static fn chain_canonical(d: unsafe *Decl) -> unsafe *Decl {
        if d == &null {
            return &null
        }

        if isa<ClassDecl>(d) {
            return (cast<ClassDecl>(d)->canonical_decl())
        }

        if isa<StructDecl>(d) {
            return (cast<StructDecl>(d)->canonical_decl())
        }

        if isa<UnionDecl>(d) {
            return (cast<UnionDecl>(d)->canonical_decl())
        }

        if isa<InterfaceDecl>(d) {
            return (cast<InterfaceDecl>(d)->canonical_decl())
        }

        if isa<EnumDecl>(d) {
            return (cast<EnumDecl>(d)->canonical_decl())
        }

        if isa<ModuleDecl>(d) {
            return (cast<ModuleDecl>(d)->canonical_decl())
        }

        if isa<FunctionDecl>(d) {
            return (cast<FunctionDecl>(d)->canonical_decl())
        }

        return &null
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
    /// Every scope a module DENOTES: its own, plus every other reopening
    /// in its redeclaration ring. One `module Foo { }` block is one
    /// DeclContext with one table, and a module reopened N times is N of
    /// them naming ONE entity -- the same shape as a C++ namespace opened
    /// N times, and the same shape ChainBinding's multi-scope Module
    /// anchor and TypeResolve's `mods` walk already handle for the
    /// cross-TU case (Compiler/Spec/Imports.md#overlays-and-visibility). Ring order is insertion order, so
    /// the first-written block answers first.
    ///
    /// Appends nothing for a non-module, so a caller can invoke it
    /// unconditionally on any scope's owner. A scope already in \p out is
    /// not appended again: two candidates of one ring (a cell holding both
    /// reopenings) would otherwise push the ring twice.
    static fn module_scopes(d: unsafe *Decl, @inout out: cxx::std::vector<unsafe *DeclContext>) {
        if d == &null {
            return
        }

        if !isa<ModuleDecl>(d) {
            return
        }

        // The ring's links are distinct ModuleDecls, so their scopes are
        // distinct too: with nothing in out to dedupe against, append them
        // in ring order as they come. The links copy and the pointer set
        // below were the cost for a namespace reopened by every header.
        if out.size() == 0 {
            var head = cast<ModuleDecl>(d)->first_decl()
            var cur  = head
            while true {
                var dc: unsafe *DeclContext = cur
                out.push_back(dc)
                cur = cur->next_in_chain()
                if cur == head {
                    break
                }
            }

            return
        }

        var links = cxx::std::vector<unsafe *Decl>()
        NameLookup::collect_chain(d, &links)
        // A module reopened across hundreds of files has a ring that long,
        // and the linear out scan below made one call quadratic (and the
        // per-cell-entry callers cubic). Past a small ring, dedupe against a
        // pointer set seeded from out; the append order is unchanged.
        if links.size() > 16 {
            var have = llvm::DenseSet<u64>()
            for var j: usize = 0; j < out.size(); ++j {
                have.insert(out[j] as usize as u64)
            }

            for var i: usize = 0; i < links.size(); ++i {
                var unsafe *dc = NameLookup::context_of(links[i])
                if dc == &null {
                    continue
                }

                var k = (dc as usize as u64)
                if have.contains(k) {
                    continue
                }

                have.insert(k)
                out.push_back(dc)
            }

            return
        }

        for var i: usize = 0; i < links.size(); ++i {
            var unsafe *dc = NameLookup::context_of(links[i])
            if dc == &null {
                continue
            }

            var seen = false
            for var j: usize = 0; j < out.size(); ++j {
                if out[j] == dc {
                    seen = true
                    break
                }
            }

            if !seen {
                out.push_back(dc)
            }
        }
    }

    static fn collect_chain(d: unsafe *Decl, @inout out: cxx::std::vector<unsafe *Decl>) {
        if d == &null {
            return
        }

        if isa<ClassDecl>(d) {
            NameLookup::_ring<ClassDecl>(cast<ClassDecl>(d), &out)
        } else if isa<StructDecl>(d) {
            NameLookup::_ring<StructDecl>(cast<StructDecl>(d), &out)
        } else if isa<UnionDecl>(d) {
            NameLookup::_ring<UnionDecl>(cast<UnionDecl>(d), &out)
        } else if isa<InterfaceDecl>(d) {
            NameLookup::_ring<InterfaceDecl>(cast<InterfaceDecl>(d), &out)
        } else if isa<EnumDecl>(d) {
            NameLookup::_ring<EnumDecl>(cast<EnumDecl>(d), &out)
        } else if isa<ModuleDecl>(d) {
            NameLookup::_ring<ModuleDecl>(cast<ModuleDecl>(d), &out)
        } else if isa<FunctionDecl>(d) {
            NameLookup::_ring<FunctionDecl>(cast<FunctionDecl>(d), &out)
        } else {
            out.push_back(d)
        }
    }

    /// Walk one typed ring from first_decl() back to the head. Bounded by
    /// the ring, which Redeclarable guarantees is circular and finite.
    // TODO(DUCK-GENERIC): T uses first_decl. Stage 0 was duck-typed; bound it or keep `: type`.
    priv static fn <T: type> _ring(d: unsafe *T, @inout out: cxx::std::vector<unsafe *Decl>) {
        var head = d->first_decl()
        var cur  = head
        while true {
            out.push_back(cur)
            cur = cur->next_in_chain()
            if cur == head {
                break
            }
        }
    }

    /// The decl that REPRESENTS the entity `d` belongs to: the chain's
    /// canonical (the definition once N(a) retargeted it), else `d` itself.
    /// THE identity every canonical type keys on. Use nothing else.
    static fn representative(d: unsafe *Decl) -> unsafe *Decl {
        // `ffi "c" struct timezone`: a forward declaration of the HEADER's
        // tag. It denotes that entity, so every type and binding keyed on
        // the representative is the header's (Compiler/Spec/Interop.md#ffi-imports).
        var unsafe *ft = decl_ffi_tag_target(d)
        if ft != &null {
            return ft
        }

        var unsafe *c = NameLookup::chain_canonical(d)
        if c == &null {
            return d
        }

        return c
    }

    /// Explicit/partial specialization: its own entity, never a chain link,
    /// never a RecordType::decl. M1 pairs it with its primary.
    static fn is_specialization(d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        if isa<ClassDecl>(d) {
            return cast<ClassDecl>(d)->is_specialization()
        }

        if isa<StructDecl>(d) {
            return cast<StructDecl>(d)->is_specialization()
        }

        if isa<UnionDecl>(d) {
            return cast<UnionDecl>(d)->is_specialization()
        }

        if isa<FunctionDecl>(d) {
            return cast<FunctionDecl>(d)->is_specialization()
        }

        if isa<EnumDecl>(d) {
            return cast<EnumDecl>(d)->is_specialization()
        }

        if isa<InterfaceDecl>(d) {
            return cast<InterfaceDecl>(d)->is_specialization()
        }

        return false
    }

    /// # Primitive 4: one qualified segment

    /// Resolve `<prev>::name` where \p prev is the decl the previous
    /// segment bound to. Redecl-chain note: the definition's context is
    /// reached through whichever link the previous segment bound; N(a)
    /// links chains before N(b) binds, so canonical/most-recent choice is
    /// the caller's policy, not this primitive's.
    fn qualified_step(self, prev: unsafe *Decl, name: DeclName) -> SemaLookupResult {
        var unsafe *dc = NameLookup::context_of(prev)
        if dc == &null {
            return SemaLookupResult::not_found()
        }

        return self.in_context(dc, name)
    }
}
