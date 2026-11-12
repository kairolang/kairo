/// --- The Kairo Project -------------------- Sema/Foreign/DeclImport.k --- ///
///
///   \brief clang::Decl -> Kairo Decl, into the TU of the header it came
///          from. Two passes over the same decls, called by HeaderIndex:
///
///            declare(d)  mint the Kairo node, register its USR, put its
///                        NAME in the right table. No types, no members.
///            define(d)   fill types, params, fields, bases, layout, the
///                        FFILinkage facts. Every cross-decl reference
///                        resolves through the registry, which pass 1
///                        completed, so a field may name a record declared
///                        three headers later.
///
///   \par What the rest of sema sees
///     An ordinary Decl with every slot T would have filled already filled:
///     `type_` / `aliased` / `InheritEdge.base` / `return_type` hold the
///     CANONICAL node (self-canonical). `NameLookup::ctx_of(d)` is the
///     header's context, so `TypeResolution::_foreign` reads and never
///     dispatches; `lookup_foreign` re-interns through the header's imm
///     table. Nothing after N knows the decl was not parsed.
///
///   \par What is NOT imported (skipped, by design, for this shot)
///     friend classes and friend function templates (a friend FUNCTION is
///     imported, declare_friend), using-directives, static_assert, deduction guides,
///     variable templates, bit-field widths, default-argument EXPRESSIONS
///     (presence is recorded), implicit instantiations found in the header
///     (the registry mints them on demand), non-type template arguments.
///
///   \par Fill mode
///     ForeignInstantiate reuses both passes on ONE ClassTemplateSpecialization-
///     Decl clang just completed, between begin_fill and end_fill (ImportMode).
///     `_fill_target` pins every decl to the primary's header (instantiated
///     members carry the PATTERN's locations, and that header is frozen);
///     `_fill_spec` -> `_fill_scope` maps the specialization to its registry
///     shell; the tables a fill creates go to `_fill_scopes`, which end_fill
///     freezes, not to the target's `scopes`.
///     Only the decl moves: its name token is still minted in the header its
///     location is IN (_home_at), since a token's text is read back through
///     its range.
///
///   \par What a fill may write
///     A fill runs on any Sema thread under ForeignInstantiate's `_mu` only,
///     while other threads read the headers' scope tables with no lock
///     (SymbolTable::lookup_foreign, MemberLookup). So a fill writes no
///     table those readers can reach: only tables it creates itself, on the
///     shell and on records it mints, which become reachable through the
///     shell when ForeignFill publishes it. A published table is frozen, and
///     appending to one ICEs in a debug build (SymbolTable::append); a fill
///     never creates a namespace nor gives a published scope a table (both
///     debug ICEs below). The one write into a published header scope is
///     the dc_decls list of a namespace or TU that a decl the fill mints
///     belongs to (a hidden friend: `operator==` of `__wrap_iter<T>`, in
///     `std`). That list has no reader during Sema but other fills, which
///     `_mu` serialises: every Sema walker of dc_decls walks its own Kairo
///     TU, and MemberLookup's extension index skips header TUs. HeaderIndex
///     writes those lists too, on the driver thread, before Sema starts.
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
ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/Attr.h"
ffi "c++" import "clang/AST/Decl.h"
ffi "c++" import "clang/AST/DeclBase.h"
ffi "c++" import "clang/AST/DeclCXX.h"
ffi "c++" import "clang/AST/DeclTemplate.h"
ffi "c++" import "clang/AST/Expr.h"
ffi "c++" import "clang/AST/RecordLayout.h"
ffi "c++" import "clang/Basic/OperatorKinds.h"
ffi "c++" import "clang/Basic/SourceManager.h"
ffi "c++" import "clang/Lex/Lexer.h"
ffi "c++" import "vector"
ffi "c++" import "string"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::CanonicalTypes::CanonicalTypeStore
import AST::Context::DeclContext::DeclContext
import AST::Context::InstantiationRegistry::InstantiationRegistry
import AST::Context::SymbolTable::{
    DeclName,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_clang,
    decl_generic_params_slot,
    decl_set_ffi_tag_keyword,
    decl_set_imported,
    decl_set_instantiated_from,
    decl_set_spec_kind,
}
import AST::LangItems::LowerTargets
import AST::Mixin::Annotation::VisibilityKind
import AST::Mixin::FFILinkage::ForeignLayout
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Interop::Clang::HeaderSet::HeaderSet
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Sema::Foreign::ForeignRegistry::ForeignRegistry
import Sema::Foreign::TypeImport::TypeImport
import Sema::Resolve::NameLookup::NameLookup
import Token::Token::Token
import Token::TokenKind::TokenKind

/// Per-header import state: the TU being filled, its context, and the
/// tables being built (frozen by HeaderIndex when the set is done).
pub class HeaderTarget {
    pub var fid:    u32                     = 0
    pub var ctx:    unsafe *ASTContext
    pub var tu:     unsafe *TranslationUnit
    pub var frozen: bool                    = false ///< already indexed by an earlier set: read-only.
    /// qualified namespace name -> this header's ModuleDecl for it.
    pub var namespaces: llvm::StringMap<unsafe *Declarations::ModuleDecl>
    /// every DeclContext this header owns whose table must be frozen at the end.
    pub var scopes: cxx::std::vector<unsafe *DeclContext>
    fn HeaderTarget(self) { }
}

/// What a DeclImport is importing for. Set once per importer: a header
/// walk (HeaderIndex) never becomes a fill, and a fill is begin_fill ..
/// end_fill on its own importer (ForeignInstantiate, under `_mu`).
///
///   HeaderWalk   a header set's decls into their own headers' TUs.
///   Fill         one completed specialization into its registry shell; every
///                decl lands in `_fill_target`, frozen headers are writable
///                for the tables the fill creates (see the file header).
///   VariantFill  a Fill whose specialization another Kairo instance already
///                owns: its own members go to `_fill_usr`, not the registry.
enum ImportMode derives u8 {
    HeaderWalk,
    Fill,
    VariantFill,
}

/// Where declare() binds the NAME of the decl it is minting, when that is
/// not the decl's own scope. Set and restored around one declare.
///
///   None    the decl's own scope.
///   Friend  declare_friend: the class (`_redirect_scope`) whose table the
///           hidden friend's name goes in; also changes the C++ spelling
///           _stamp gives it.
///   Using   declare_using: the namespace (`_redirect_scope`) whose table
///           the target's name also goes in.
enum NameRedirect derives u8 {
    None,
    Friend,
    Using,
}

pub class DeclImport {
    pub var _set:      unsafe *HeaderSet
    pub var reg:       unsafe *ForeignRegistry
    pub var ksm:       *SourceManager
    pub var store:     unsafe *CanonicalTypeStore
    pub var instances: unsafe *InstantiationRegistry
    pub var cctx:      unsafe *clang::ASTContext
    pub var csm:       unsafe *clang::SourceManager

    /// header fid -> target. Owned by HeaderIndex; borrowed here.
    pub var targets: unsafe *llvm::DenseMap<u32, unsafe *HeaderTarget>

    /// ## fill mode (ForeignInstantiate; begin_fill .. end_fill own all of it)

    priv var _mode:        ImportMode                            = ImportMode::HeaderWalk
    priv var _fill_target: unsafe *HeaderTarget                  = &null ///< Fill: every decl lands here.
    priv var _fill_scope:  unsafe *DeclContext                   = &null ///< Fill: the instance shell.
    priv var _fill_spec:   unsafe *clang::Decl                   = &null ///< Fill: the ClassTemplateSpecializationDecl it stands for.
    priv var _fill_scopes: cxx::std::vector<unsafe *DeclContext> ///< Fill: every table the fill created; end_fill freezes them.
    /// VariantFill only (else null): the USR -> decl table for the
    /// members this fill mints. `vector<usize>` and `vector<u64>` are two
    /// Kairo instances of ONE clang specialization (`vector<unsigned long>`
    /// on LP64), so every member has one USR. Through the registry the
    /// second fill found the first's members and re-defined them with its
    /// own argument mapping: whichever instance filled LAST decided whether
    /// both `v[i]`s were usize or u64, and the whole-tree result depended on
    /// input order. Members of `_fill_spec` go here instead, so each
    /// instance has its own; anything outside the specialization is still
    /// the registry's. The fill owns the table and drops it after.
    priv var _fill_usr: unsafe *llvm::StringMap<unsafe *Decl> = &null
    /// declare() is minting a member of a variant fill: _put goes to _fill_usr.
    priv var _own: bool = false
    /// See NameRedirect; `_redirect_scope` is its clang scope, null for None.
    priv var _redirect:       NameRedirect               = NameRedirect::None
    priv var _redirect_scope: unsafe *clang::DeclContext = &null

    /// Index mode's diagnostics (_conflicting_definition); null in a fill.
    pub var diag: unsafe *DiagEngine = &null
    /// Entities already reported by _conflicting_definition.
    priv var _conflicts: cxx::std::vector<unsafe *DeclContext>

    /// Debug: every decl this fill minted, so table_of can tell a scope the
    /// fill made from a published one. Empty in a header walk and in a
    /// release build.
    priv var _fill_minted: cxx::std::vector<unsafe *Decl>

    pub var n_declared: usize = 0
    pub var n_defined:  usize = 0
    pub var n_skipped:  usize = 0

    fn DeclImport(self) { }

    /// Enter fill mode for \p spec, which imports into \p shell's scope on
    /// header \p target; \p own_usr non-null makes it a VariantFill (see
    /// `_fill_usr`; the caller owns the table and outlives the fill). Once
    /// per importer, before any declare.
    fn begin_fill(self,
                  target:  unsafe *HeaderTarget,
                  shell:   unsafe *DeclContext,
                  spec:    unsafe *clang::Decl,
                  own_usr: unsafe *llvm::StringMap<unsafe *Decl>) {
        if self._mode != ImportMode::HeaderWalk {
            kairo::std::ice_fail("DeclImport::begin_fill on an importer already filling")
        }

        self._mode        = if (own_usr != &null) => (ImportMode::VariantFill) else => (ImportMode::Fill)
        self._fill_target = target
        self._fill_scope  = shell
        self._fill_spec   = spec
        self._fill_usr    = own_usr
    }

    /// Leave fill mode: freeze every table the fill created. The caller
    /// publishes the shell (ForeignFill) only after this, so no reader
    /// ever sees one of them growing.
    fn end_fill(self) {
        for var i: usize = 0; i < self._fill_scopes.size(); ++i {
            if self._fill_scopes[i]->dc_symbols != &null {
                self._fill_scopes[i]->dc_symbols->freeze()
            }
        }

        self._fill_scopes.clear()
        self._mode        = ImportMode::HeaderWalk
        self._fill_target = &null
        self._fill_scope  = &null
        self._fill_spec   = &null
        self._fill_usr    = &null
    }

    /// A Fill or a VariantFill: frozen headers take this importer's writes.
    fn in_fill(self) -> bool {
        return self._mode != ImportMode::HeaderWalk
    }

    /// # locations

    /// Kairo range for a clang range, or invalid when the loc is not in a
    /// file we minted a fid for (scratch buffers, <built-in>).
    fn range_of(self, d: unsafe *const clang::Decl) -> SourceRange {
        var b  = self.csm->getDecomposedExpansionLoc(d->getBeginLoc())
        var e  = self.csm->getDecomposedExpansionLoc(d->getEndLoc())
        var kb = self._set->kfid_for(b.first)
        if kb == 0 {
            return SourceRange::invalid()
        }

        var ke         = self._set->kfid_for(e.first)
        var len: usize = 1
        if ke == kb && e.second >= b.second {
            len = ((e.second - b.second) as usize) + 1
        }

        return self.ksm->get_range(kb, b.second as usize, len)
    }

    fn name_range_of(self, d: unsafe *const clang::NamedDecl) -> SourceRange {
        var b  = self.csm->getDecomposedExpansionLoc(d->getLocation())
        var kb = self._set->kfid_for(b.first)
        if kb == 0 {
            return SourceRange::invalid()
        }

        var n   = d->getNameAsString()
        var len = n.size()
        // The printed name is not always what is spelled at the location.
        // `using BaseT::BaseT;` (DenseSet.h's last line) names the base's
        // CONSTRUCTOR, printed as the whole specialization -- 212 bytes at an
        // offset 66 bytes from EOF, and get_range ICEd past the segment. When
        // the bytes there are not the name, the range is the one token clang
        // lexes there instead; either way it never leaves the file.
        var buf          = self.csm->getBufferData(b.first)
        var off          = (b.second as usize)
        var avail: usize = 0
        if off < buf.size() {
            avail = buf.size() - off
        }

        var spelled = len > 0 && len <= avail && buf.substr(off, len) == kairo::sref(n)
        if !spelled {
            var loc = self.csm->getComposedLoc(b.first, b.second)
            len = (clang::Lexer::MeasureTokenLength(
                loc,
                *self.csm,
                self.cctx->getLangOpts(),
            ) as usize)
        }

        if len > avail {
            len = avail
        }

        if len == 0 {
            len = 1
        }

        return self.ksm->get_range(kb, off, len)
    }

    /// Where a decl LIVES: the header it was written in, as a target; null
    /// when it is in no file we track. Falls back through redecls so a
    /// definition in a file we never entered still lands next to its
    /// declaration. Scopes, tables and bindings follow this; the decl's name
    /// TOKEN does not (_home_at).
    fn target_of(self, d: unsafe *const clang::Decl) -> unsafe *HeaderTarget {
        // Fill mode: an instantiated member carries its PATTERN's location, so
        // the path below would answer with the pattern's header -- frozen
        // since HeaderIndex finished it -- and the member would be dropped.
        if self.in_fill() {
            return self._fill_target
        }

        var loc = self.csm->getDecomposedExpansionLoc(d->getLocation())
        return self._target_for(self._set->kfid_for(loc.first))
    }

    /// Which header's context owns the interner for a token ranged at \p at:
    /// the file the range is IN, always. Fill mode and `frozen` do not enter
    /// into it -- interning a spelling writes no table. Null for a range in
    /// no file we track.
    ///
    /// Not target_of, because TokenText finds a token's imm table from its
    /// RANGE (hard invariant #2, display side). A fill pins every decl to the
    /// primary's header, <__fwd/vector.h>, while `push_back` is written in
    /// <__vector/vector.h>: minting the name in the first and ranging it in
    /// the second read back whatever sat at that index in the second's table,
    /// and `.size` printed as `cend`. Keys never had the problem; _ident_key
    /// interns through the table's own TU.
    priv fn _home_at(self, at: SourceRange) -> unsafe *HeaderTarget {
        if !at.is_valid() {
            return &null
        }

        return self._target_for(self.ksm->get_fid(at))
    }

    priv fn _target_for(self, kf: u32) -> unsafe *HeaderTarget {
        if kf == 0 {
            return &null
        }

        var it = self.targets->find(kf)
        if it == self.targets->end() {
            return &null
        }

        return it->second
    }

    /// # tokens

    fn ident(self, t: unsafe *HeaderTarget, const s: string, at: SourceRange) -> Token {
        return self._tok(t, at, TokenKind::LitIdentifier, s)
    }

    /// Every token DeclImport makes goes through here, so its text and its
    /// range agree on a TU (_home_at). \p t answers only for a range in no
    /// tracked file, where no TU can read it back by range anyway.
    priv fn _tok(self,
                 t:       unsafe *HeaderTarget,
                 at:      SourceRange,
                 k:       TokenKind,
                 const s: string) -> Token {
        var unsafe *ctx = t->ctx
        var unsafe *h   = self._home_at(at)
        if h != &null {
            ctx = h->ctx
        }

        return ctx->make_token(at, k, s)
    }

    priv fn _str(self, s: llvm::StringRef) -> string {
        return string(unsafe ((s.data() as unsafe *const u8) as *const u8), s.size())
    }

    priv fn _qual(self, d: unsafe *const clang::NamedDecl) -> string {
        var pol = clang::PrintingPolicy(self.cctx->getLangOpts())
        pol.FullyQualifiedName     = (true as u32)
        pol.SuppressUnwrittenScope = (true as u32)
        var s: cxx::std::string
        var os                  = llvm::raw_string_ostream(&s)
        d->printQualifiedName(&os, pol)
        os.flush()
        return "::" + string(unsafe ((s.data() as unsafe *const u8) as *const u8), s.size())
    }

    /// # tables

    /// The table a decl in clang context \p dc goes into, on header \p t:
    /// the TU for the global namespace, a ModuleDecl for a namespace, the
    /// record's own context for a member.
    fn scope_for(self,
                 t:  unsafe *HeaderTarget,
                 dc: unsafe *const clang::DeclContext) -> unsafe *DeclContext {
        // Fill mode: the specialization being imported IS the shell. Nothing
        // registered its USR (an implicit specialization is never walked), so
        // the registry probe below would miss it. Records nested in it were
        // declared by this fill and resolve through the registry as usual.
        if self._fill_spec != &null
            && dc != &null
            && clang::Decl::castFromDeclContext(dc) == self._fill_spec {
            return self._fill_scope
        }

        if dc == &null {
            return unsafe (t->tu as unsafe *DeclContext)
        }

        // Transparent contexts: linkage specs, inline namespaces, anonymous
        // structs/unions, export blocks -- their members belong to the parent.
        // NOT an unscoped enum, which clang also calls transparent: its
        // enumerators belong in the enum's own table (`Color::Green`), and
        // _bind_named adds them to the enclosing scope separately.
        if dc->isTransparentContext() && !llvm::isa<clang::EnumDecl>(dc)
            || dc->isInlineNamespace() {
            return self.scope_for(t, dc->getParent())
        }

        if dc->isTranslationUnit() {
            return unsafe (t->tu as unsafe *DeclContext)
        }

        var unsafe *ns = llvm::dyn_cast<clang::NamespaceDecl>(dc)
        if ns != &null {
            return unsafe (self.namespace_for(t, ns) as unsafe *DeclContext)
        }

        var unsafe *rd = clang::Decl::castFromDeclContext(dc)
        if rd != &null {
            var unsafe *kd  = self._find((TypeImport::usr_of(rd->getCanonicalDecl())).str())
            var unsafe *kdc = NameLookup::context_of(kd)
            if kdc != &null {
                return kdc
            }
        }

        // A context with no Kairo scope (a function body, a record nobody
        // imported): the decl has nowhere to live, so it is not imported.
        // Falling back to the TU made every such decl a GLOBAL, and libc++
        // alone then had dozens of "ambiguous" `type`s at file scope.
        return &null
    }

    fn table_of(self, t: unsafe *HeaderTarget, dc: unsafe *DeclContext) -> unsafe *SymbolTable {
        if dc->dc_symbols == &null {
            eval if defined!(DEBUG) {
                if self.in_fill() && dc != self._fill_scope && !self._minted_here(dc->dc_owner) {
                    kairo::std::ice_fail("DeclImport: a fill would give a published scope its first table (P855)")
                }
            }

            var unsafe *tbl = t->ctx->alloc_init_cleanup<SymbolTable>(t->ctx)
            dc->set_symbols(tbl)
            // A fill's tables are the fill's to freeze: HeaderIndex froze
            // `t->scopes` once, when the set finished, and never reads it again.
            if self.in_fill() {
                self._fill_scopes.push_back(dc)
            } else {
                t->scopes.push_back(dc)
            }
        }

        return dc->dc_symbols
    }

    /// Debug: \p d was minted by this fill.
    priv fn _minted_here(self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self._fill_minted.size(); ++i {
            if self._fill_minted[i] == d {
                return true
            }
        }

        return false
    }

    /// Append \p d under \p name in \p dc's table unless already there.
    /// A fill writes into a frozen HEADER on purpose -- into tables it just
    /// created (the shell's, a nested record's), never one the set froze.
    fn bind(self,
            t:    unsafe *HeaderTarget,
            dc:   unsafe *DeclContext,
            name: DeclName,
            d:    unsafe *Decl) {
        if t->frozen && (!self.in_fill()) {
            return
        }

        var unsafe *tbl  = self.table_of(t, dc)
        var unsafe *cell = tbl->lookup(name)
        if cell != &null {
            for var i: usize = 0; i < cell->size(); ++i {
                if cell->get(i) == d {
                    return
                }
            }
        }

        // A table an earlier set froze is not this set's to write. Reached
        // with a NEW member only when two headers define one entity (one
        // USR) differently -- `struct Pt { int x; }` in ha.h and `struct Pt
        // { double y; }` in hb.h, each imported by its own module: the
        // second definition's members land in the first's scope. The
        // insert was a debug-build ICE and, in release, a member grafted
        // onto the other header's record, accepted by Sema and rejected by
        // clang at codegen. An identical second definition binds members
        // already in the cell and never gets here.
        if tbl->is_frozen() && (!self.in_fill()) {
            self._conflicting_definition(t, dc, name, d)
            return
        }

        tbl->append(name, d)
    }

    /// One error per entity (\p dc) that a second header defines
    /// differently: Kairo keeps the first definition, so the member \p d of
    /// the second is not imported, and the program cannot be compiled as
    /// one C++ translation unit either. Index mode only (driver thread).
    priv fn _conflicting_definition(self,
                                    t:    unsafe *HeaderTarget,
                                    dc:   unsafe *DeclContext,
                                    name: DeclName,
                                    d:    unsafe *Decl) {
        if self.diag == &null || d == &null {
            return
        }

        for var i: usize = 0; i < self._conflicts.size(); ++i {
            if self._conflicts[i] == dc {
                return
            }
        }

        self._conflicts.push_back(dc)
        var unsafe *owner = dc->owner_decl()
        var        on     = self._clang_name_of(owner)
        // Interned where _ident_key interned it: the scope's own TU.
        var unsafe *kctx = t->ctx
        var unsafe *ktu  = NameLookup::tu_of(dc)
        if ktu != &null && ktu->ctx != &null {
            kctx = ktu->ctx
        }

        var mn = if (name.is_ident()) => (name.describe(kctx)) else => self._clang_name_of(d)
        var b = self.diag->report(
            DiagID::R001E,
            d->range.start,
            f"'{on}' is defined differently by two imported headers: Kairo keeps one '{on}', so '{mn}' of this definition is not imported",
        )

        b.first(d->range, f"'{mn}' is not a member of the '{on}' Kairo uses")
        if owner != &null && owner->range.is_valid() {
            b.note(owner->range.start, f"the definition of '{on}' Kairo uses; one program sees one definition of each C/C++ entity, so give one of the two a different name")
        }

        b.emit()
    }

    /// The clang name behind imported \p d, or `?`.
    priv fn _clang_name_of(self, d: unsafe *Decl) -> string {
        if d == &null || decl_clang(d) == &null {
            return "?"
        }

        var unsafe *nd = llvm::dyn_cast<clang::NamedDecl>(unsafe (decl_clang(d) as unsafe *clang::Decl))
        if nd == &null {
            return "?"
        }

        return self._display_name(nd)
    }

    /// One ModuleDecl per (header, qualified namespace). Reopenings within
    /// the header share it; across headers they are distinct decls, linked
    /// into one redeclaration ring (ForeignRegistry::link_namespace) that
    /// ChainBinding's multi-scope Module anchor and ADL both walk.
    fn namespace_for(self,
                     t:  unsafe *HeaderTarget,
                     ns: unsafe *const clang::NamespaceDecl) -> unsafe *Declarations::ModuleDecl {
        var q  = self._qual(ns)
        var nq = kairo::sref(q)
        var it = t->namespaces.find(nq)
        if it != t->namespaces.end() {
            return it->second
        }

        // A new namespace would go into its parent's published table and
        // `t->namespaces`, both read unlocked (see the file header).
        eval if defined!(DEBUG) {
            if self.in_fill() {
                kairo::std::ice_fail(f"DeclImport: a fill would create namespace '{q}' in a published header (P855)")
            }
        }

        var unsafe *parent = self.scope_for(t, ns->getParent())
        if parent == &null { // a namespace's parent is always a namespace or the TU.
            parent = unsafe (t->tu as unsafe *DeclContext)
        }

        var        at   = self.range_of(ns)
        var        nm   = self._str(ns->getName())
        var        name = self.ident(t, nm, self.name_range_of(ns))
        var unsafe *m   = Declarations::ModuleDecl::create(t->ctx, at, name, parent)
        m->set_visibility(VisibilityKind::Public, at)
        m->is_inline   = ns->isInline()
        m->lexical_dc  = parent
        m->semantic_dc = parent
        m->mark_definition()
        parent->add_decl(m)
        // Keyed through _ident_key, not the token's imm: the token is interned
        // where its RANGE is (_tok), the key where the TABLE is.
        self.bind(t, parent, self._ident_key(t, parent, nm), m)
        t->namespaces.try_emplace(nq, m)
        self.reg->link_namespace(nq, m)
        return m
    }

    /// The Kairo decl registered for \p usr: this variant fill's own first.
    priv fn _find(self, usr: llvm::StringRef) -> unsafe *Decl {
        if self._mode == ImportMode::VariantFill {
            var it = self._fill_usr->find(usr)
            if it != self._fill_usr->end() {
                return it->second
            }
        }

        return self.reg->find(usr)
    }

    /// Register \p d under \p usr (first one wins); a variant fill's member
    /// goes to the fill's own table.
    priv fn _put(self, usr: llvm::StringRef, d: unsafe *Decl) -> unsafe *Decl {
        if self._own && self._mode == ImportMode::VariantFill {
            var r = self._fill_usr->try_emplace(usr, d)
            return r.first->second
        }

        return self.reg->put(usr, d)
    }

    /// \p d is declared inside the specialization a fill is importing.
    priv fn _in_fill_spec(self, d: unsafe *clang::Decl) -> bool {
        if self._fill_spec == &null {
            return false
        }

        var unsafe *spec = self._fill_spec->getCanonicalDecl()
        var unsafe *dc   = d->getDeclContext()
        while dc != &null {
            var unsafe *cd = clang::Decl::castFromDeclContext(dc)
            if cd != &null && cd->getCanonicalDecl() == spec {
                return true
            }

            dc = dc->getParent()
        }

        // A hidden friend is an entity of the enclosing namespace, so the
        // walk above never meets the specialization; it is WRITTEN in it,
        // and its parameters are spelled with the specialization's own
        // arguments. Two Kairo instances that are one specialization to
        // clang (`Box<usize>` and `Box<u64>`) must each have their own, as
        // they do of every member: sharing the first one's, the second
        // fill re-typed it (define) and the first instance's `==` took the
        // second's types, so whichever file compared next failed (SC063E /
        // SC066E), by check order.
        var unsafe *ldc = d->getLexicalDeclContext()
        while ldc != &null {
            var unsafe *lcd = clang::Decl::castFromDeclContext(ldc)
            if lcd != &null && lcd->getCanonicalDecl() == spec {
                return true
            }

            ldc = ldc->getLexicalParent()
        }

        return false
    }

    /// # pass 1: declare

    /// Mint + register + bind the name. Returns the Kairo decl (existing one
    /// if this USR was already imported by an earlier set or redecl).
    fn declare(self, d: unsafe *clang::Decl) -> unsafe *Decl {
        var unsafe *nd = llvm::dyn_cast<clang::NamedDecl>(d)
        if nd == &null {
            return &null
        }

        // An unnamed enum (`enum { a, b };`, clang::diag's whole interface) is
        // kept: its enumerators are values OF it, so they need an enum to be
        // typed by. Nothing can name it; _display_name gives it a spelling no
        // identifier can collide with, and _bind_named still exposes each
        // enumerator in the enclosing scope.
        if nd->getDeclName().isEmpty() && !self._anon_with_typedef(nd) && !self._unnamed_enum(nd) {
            return &null
        }

        var unsafe *t = self.target_of(d)
        if t == &null {
            self.n_skipped += 1
            return &null
        }

        // A namespace is not ONE entity to Kairo: each header's reopening is
        // its own ModuleDecl (namespace_for), unioned by phase I and
        // ChainBinding as a reopened module. Registering it by USR -- which
        // every reopening shares -- bound the FIRST header's ModuleDecl into
        // each later header's table, while that header's members went into a
        // ModuleDecl nothing bound.
        var unsafe *ns = llvm::dyn_cast<clang::NamespaceDecl>(d)
        if ns != &null {
            return self.namespace_for(t, ns)
        }

        var unsafe *canon = d->getCanonicalDecl()
        var        usr    = TypeImport::usr_of(canon)
        if usr.empty() {
            self.n_skipped += 1
            return &null
        }

        // A member of a variant fill's specialization is this instance's
        // own: the registry's entry under the same USR belongs to the other
        // Kairo instance of that specialization (see _fill_usr).
        var own                    = self._mode == ImportMode::VariantFill && self._in_fill_spec(d)
        var existing: unsafe *Decl = &null
        if own {
            var oi = self._fill_usr->find((usr).str())
            if oi != self._fill_usr->end() {
                existing = oi->second
            }
        } else {
            existing = self._find((usr).str())
        }

        if existing != &null {
            // Second declaration of a known entity: only the NAME binding
            // in THIS header's table is new.
            self._bind_named(t, nd, existing)
            return existing
        }

        var was_own = self._own
        self._own = own
        var unsafe *kd = self._mint(t, nd)
        if kd == &null {
            self._own = was_own
            self.n_skipped += 1
            return &null
        }

        var unsafe *won = self._put((usr).str(), kd)
        self._own = was_own
        if won != kd {
            self._bind_named(t, nd, won)
            return won
        }

        self._stamp(kd, d, nd, (usr).str(), t)
        self._bind_named(t, nd, kd)
        self.n_declared += 1
        return kd
    }

    /// A friend function declared in the class \p cls -- the hidden friend
    /// `friend bool operator==(const It&, const It&) { ... }` every libc++
    /// node-based iterator compares through. Its entity belongs to the
    /// enclosing namespace, but C++ finds it ONLY by argument-dependent lookup
    /// through \p cls, so its name is bound in the class's table and nowhere
    /// else. It is not a member (no `self`); operator lookup takes such a
    /// function from a class table as a free candidate (OperatorTyping::_gather).
    fn declare_friend(self,
                      fn_: unsafe *clang::Decl,
                      cls: unsafe *clang::DeclContext) -> unsafe *Decl {
        var was    = self._redirect
        var was_at = self._redirect_scope
        self._redirect       = NameRedirect::Friend
        self._redirect_scope = cls
        var unsafe *kd = self.declare(fn_)
        self._redirect       = was
        self._redirect_scope = was_at
        return kd
    }

    /// A namespace-scope using-declaration: `namespace std { using ::sqrt; }`,
    /// which is how libc++'s <cmath>, <cstdlib>, <cstring> put the C library
    /// in std. C++ finds the target under the shadow's namespace as well as
    /// its own, so the target's Kairo decl is bound in both tables: one
    /// entity, two names, and EmitIR keeps spelling it by its home (`::sqrt`).
    /// Without this `cxx::std::sqrt` was "no member named 'sqrt'" (R025E).
    /// Returns the target's decl; n_declared tells the caller whether it was
    /// minted here and so still needs its pass-2 define.
    fn declare_using(self, sh: unsafe *clang::UsingShadowDecl) -> unsafe *Decl {
        var unsafe *tgt = sh->getTargetDecl()
        if tgt == &null {
            return &null
        }

        var unsafe *kd = self.declare(tgt) // the registry answers an already-imported target.
        if kd == &null {
            return &null
        }

        var unsafe *t = self.target_of(sh)
        if t == &null {
            return kd
        }

        var was    = self._redirect
        var was_at = self._redirect_scope
        self._redirect       = NameRedirect::Using
        self._redirect_scope = sh->getDeclContext()
        self._bind_named(t, tgt, kd)
        self._redirect       = was
        self._redirect_scope = was_at
        return kd
    }

    priv fn _unnamed_enum(self, nd: unsafe *const clang::NamedDecl) -> bool {
        var unsafe *ed = llvm::dyn_cast<clang::EnumDecl>(nd)
        if ed == &null || ed->getTypedefNameForAnonDecl() != &null {
            return false
        }

        // clang's USR for an unnamed enum is its first enumerator's name, so
        // one with none (an empty enum, an opaque `enum : int;`) would share
        // a USR with every other and read as their redeclaration: the
        // registry then saw two definitions of one entity. Nothing could be
        // named through it anyway.
        // Nor one inside a template or any of its specializations: the
        // instances' unnamed enums carry the same USR as the pattern's, and a
        // fill walks them separately.
        var unsafe *dc = ed->getDeclContext()
        while dc != &null && !dc->isTranslationUnit() {
            if dc->isDependentContext() || llvm::isa<clang::ClassTemplateSpecializationDecl>(dc) {
                return false
            }

            dc = dc->getParent()
        }

        for e in ed->enumerators() {
            return true
        }

        return false
    }

    priv fn _anon_with_typedef(self, nd: unsafe *const clang::NamedDecl) -> bool {
        var unsafe *tag = llvm::dyn_cast<clang::TagDecl>(nd)
        if tag == &null {
            return false
        }

        return tag->getTypedefNameForAnonDecl() != &null
    }

    priv fn _display_name(self, nd: unsafe *const clang::NamedDecl) -> string {
        if nd->getDeclName().isEmpty() && self._unnamed_enum(nd) {
            return "(unnamed enum)"
        }

        var unsafe *tag = llvm::dyn_cast<clang::TagDecl>(nd)
        if tag != &null && tag->getTypedefNameForAnonDecl() != &null {
            return self._str(tag->getTypedefNameForAnonDecl()->getName())
        }

        return string(unsafe ((nd->getNameAsString().c_str() as unsafe *const u8) as *const u8))
    }

    /// The empty Kairo node of the right kind, parented, no slots filled.
    priv fn _mint(self, t: unsafe *HeaderTarget, nd: unsafe *clang::NamedDecl) -> unsafe *Decl {
        var unsafe *parent = self.scope_for(t, nd->getDeclContext())
        if parent == &null { // nowhere to live: see scope_for.
            return &null
        }

        var at                = self.range_of(nd)
        var name              = self.ident(t, self._display_name(nd), self.name_range_of(nd))
        var out: unsafe *Decl = &null

        match nd->getKind() {
            case clang::Decl::Namespace {
                return (self.namespace_for(t, llvm::cast<clang::NamespaceDecl>(nd)))
            } case clang::Decl::CXXRecord {
                out = self._mint_record(t, llvm::cast<clang::CXXRecordDecl>(nd), at, name, parent)
            } case clang::Decl::Record {
                out = self._mint_record(t, llvm::cast<clang::RecordDecl>(nd), at, name, parent)
            } case clang::Decl::ClassTemplate {
                var unsafe *ct = llvm::cast<clang::ClassTemplateDecl>(nd)
                out = self._mint_record(t, ct->getTemplatedDecl(), at, name, parent)
                // The template decl and its templated record are one entity to us.
                self._put(
                    (TypeImport::usr_of(ct->getTemplatedDecl()->getCanonicalDecl())).str(),
                    out,
                )
            } case clang::Decl::ClassTemplateSpecialization {
                var unsafe *sp = llvm::cast<clang::ClassTemplateSpecializationDecl>(nd)
                // Implicit: the registry's. Inside a fill too -- a nested
                // implicit specialization is reached as a TYPE (`traits<A>`
                // in a member typedef), gets its own shell from TypeImport,
                // and is filled on its own first lookup.
                if !sp->isExplicitSpecialization() {
                    return &null
                }

                out = self._mint_record(t, sp, at, name, parent)
            } case clang::Decl::ClassTemplatePartialSpecialization {
                out = self._mint_record(t, llvm::cast<clang::CXXRecordDecl>(nd), at, name, parent)
            } case clang::Decl::Enum {
                var unsafe *e = Declarations::EnumDecl::create(t->ctx, at, name, parent)
                // clang owns its values: open, so no niche and no checked `as`.
                e->is_open = true
                out        = e
            } case clang::Decl::Function {
                out = Declarations::FunctionDecl::create(t->ctx, at, name, parent)
            } case clang::Decl::CXXMethod {
                out = Declarations::FunctionDecl::create(t->ctx, at, name, parent)
            } case clang::Decl::CXXConstructor {
                out = Declarations::FunctionDecl::create(t->ctx, at, name, parent)
            } case clang::Decl::CXXDestructor {
                out = Declarations::FunctionDecl::create(t->ctx, at, name, parent)
            } case clang::Decl::CXXConversion {
                out = Declarations::FunctionDecl::create(t->ctx, at, name, parent)
            } case clang::Decl::FunctionTemplate {
                var unsafe *ft = llvm::cast<clang::FunctionTemplateDecl>(nd)
                out = Declarations::FunctionDecl::create(t->ctx, at, name, parent)
                self._put(
                    (TypeImport::usr_of(ft->getTemplatedDecl()->getCanonicalDecl())).str(),
                    out,
                )
            } case clang::Decl::Typedef {
                out = Declarations::TypeAliasDecl::create(t->ctx, at, name, &null)
            } case clang::Decl::TypeAlias {
                out = Declarations::TypeAliasDecl::create(t->ctx, at, name, &null)
            } case clang::Decl::TypeAliasTemplate {
                var unsafe *at_ = llvm::cast<clang::TypeAliasTemplateDecl>(nd)
                out = Declarations::TypeAliasDecl::create(t->ctx, at, name, &null)
                self._put(
                    (TypeImport::usr_of(at_->getTemplatedDecl()->getCanonicalDecl())).str(),
                    out,
                )
            } case clang::Decl::Var {
                var unsafe *v = llvm::cast<clang::VarDecl>(nd)
                var        sc = Declarations::StorageClass::Var
                if v->isConstexpr() || v->getType().isConstQualified() {
                    sc = Declarations::StorageClass::Const
                }

                if v->isStaticDataMember() || v->getStorageClass() == clang::SC_Static {
                    sc = Declarations::StorageClass::Static
                }

                out = Declarations::VariableDecl::create(t->ctx, at, name, sc)
            } case clang::Decl::Field {
                var unsafe *f = llvm::cast<clang::FieldDecl>(nd)
                var unsafe *fd = Declarations::FieldDecl::create(
                    t->ctx,
                    at,
                    name,
                    Declarations::StorageClass::Var,
                    &null,
                    f->getFieldIndex(),
                )

                fd->is_bitfield = f->isBitField()
                out             = fd
            } case clang::Decl::EnumConstant {
                var unsafe *ec              = llvm::cast<clang::EnumConstantDecl>(nd)
                var unsafe *parent_enum     = llvm::dyn_cast<clang::EnumDecl>(ec->getDeclContext())
                var        idx:         u32 = 0
                if parent_enum != &null {
                    for e in parent_enum->enumerators() {
                        if e == ec {
                            break
                        }

                        idx += 1
                    }
                }

                out = Declarations::EnumVariantDecl::create(t->ctx, at, name, idx)
            } case clang::Decl::Concept {
                var unsafe *i = Declarations::InterfaceDecl::create(t->ctx, at, name, parent)
                i->is_cxx_concept = true
                out               = i
            } default { // using, friend, static_assert, deduction guide, ...
                return &null
            }
        }

        if out == &null {
            return &null
        }

        out->lexical_dc  = parent
        out->semantic_dc = parent
        out->set_visibility(self._vis(nd), at)
        eval if defined!(DEBUG) {
            if self.in_fill() {
                self._fill_minted.push_back(out)
            }
        }

        // In a fill, \p parent can be a published namespace (a hidden
        // friend's): safe only because nothing but fills reads a header
        // scope's dc_decls during Sema (the file header).
        parent->add_decl(out)
        return out
    }

    priv fn _mint_record(self,
                         t:      unsafe *HeaderTarget,
                         rd:     unsafe *clang::RecordDecl,
                         at:     SourceRange,
                         name:   Token,
                         parent: unsafe *DeclContext) -> unsafe *Decl {
        if rd->isUnion() {
            var unsafe *u = Declarations::UnionDecl::create(t->ctx, at, name, parent)
            u->ffi_is_union = true
            if rd->isCompleteDefinition() {
                u->mark_definition()
            }

            return u
        }

        // C++ `struct` and `class` are one thing to clang and two to Kairo;
        // a Kairo `struct` admits no named methods, so everything with a
        // method or a base is a ClassDecl. Plain aggregates stay structs.
        var unsafe *cxx_v = llvm::dyn_cast<clang::CXXRecordDecl>(rd)
        var is_class = cxx_v != &null
            && cxx_v->hasDefinition()
            && (cxx_v->getNumBases() > 0
                || cxx_v->isPolymorphic()
                || self._has_named_methods(cxx_v))
        if is_class || rd->isClass() {
            var unsafe *c = Declarations::ClassDecl::create(t->ctx, at, name, parent)
            if rd->isCompleteDefinition() {
                c->mark_definition()
            }

            if cxx_v != &null {
                c->is_final    = cxx_v->hasAttr<clang::FinalAttr>()
                c->is_abstract = cxx_v->hasDefinition() && cxx_v->isAbstract()
            }

            return c
        }

        var unsafe *s = Declarations::StructDecl::create(t->ctx, at, name, parent)
        if rd->isCompleteDefinition() {
            s->mark_definition()
        }

        return s
    }

    priv fn _has_named_methods(self, cxx_v: unsafe *const clang::CXXRecordDecl) -> bool {
        for m in cxx_v->methods() {
            if m->isImplicit() {
                continue
            }

            if llvm::isa<clang::CXXConstructorDecl>(m) || llvm::isa<clang::CXXDestructorDecl>(m) {
                continue
            }

            if m->isOverloadedOperator() {
                continue
            }

            return true
        }

        return false
    }

    priv fn _vis(self, nd: unsafe *const clang::NamedDecl) -> VisibilityKind {
        match nd->getAccess() {
            case clang::AS_private {
                return VisibilityKind::Private
            } case clang::AS_protected {
                return VisibilityKind::Protected
            } default {
                return VisibilityKind::Public
            }
        }
    }

    /// A friend function that is ALSO declared outside any class
    /// (`friend const_iterator begin(StringRef, Style);` in llvm::sys::path's
    /// const_iterator, then `const_iterator begin(StringRef, Style = ...)` in
    /// the namespace): it is an ordinary namespace member, found by qualified
    /// lookup, and the bare spelling a hidden friend gets would miss it (clang
    /// finds only the std::begin template). Only a friend never redeclared
    /// stays hidden.
    priv fn _friend_redeclared(self, nd: unsafe *clang::NamedDecl) -> bool {
        var unsafe *fd = llvm::dyn_cast<clang::FunctionDecl>(nd)
        if fd == &null {
            return false
        }

        // TODO: explicit Redeclarable base until using-declaration hiding lands.
        var unsafe *r = (unsafe (fd as unsafe *clang::Redeclarable<clang::FunctionDecl>))->getMostRecentDecl()
        while r != &null {
            if r->getFriendObjectKind() == clang::Decl::FOK_None {
                return true
            }

            r = (unsafe (r as unsafe *clang::Redeclarable<clang::FunctionDecl>))->getPreviousDecl()
        }

        return false
    }

    /// The FFILinkage stamp. Every imported kind derives it except
    /// EnumDecl / InterfaceDecl / EnumVariant / Field / Module; those carry
    /// no per-decl foreign facts sema needs.
    priv fn _stamp(self,
                   kd:  unsafe *Decl,
                   d:   unsafe *clang::Decl,
                   nd:  unsafe *clang::NamedDecl,
                   usr: llvm::StringRef,
                   t:   unsafe *HeaderTarget) {
        var sp = self._qual(nd)
        // A hidden friend has no qualified spelling: qualified lookup never
        // finds it, only ADL does. Its bare name is what C++ calls it by.
        if self._redirect == NameRedirect::Friend && !self._friend_redeclared(nd) {
            sp = self._display_name(nd)
        }

        var us = string(unsafe ((usr.data() as unsafe *const u8) as *const u8), usr.size())
        var unsafe *vset = unsafe (self._set as unsafe *void)
        var unsafe *vd   = unsafe (d as unsafe *void)
        decl_set_imported(kd, vd, us, sp, vset, t->fid)
    }

    /// The name binding: ident key, or ctor / operator key for functions.
    priv fn _bind_named(self,
                        t:  unsafe *HeaderTarget,
                        nd: unsafe *const clang::NamedDecl,
                        kd: unsafe *Decl) {
        // A partial specialization is never the answer to a name: the primary
        // owns it, and partials_of(primary) -- M1's pairing, fed by
        // _define_spec's register_partial -- is the only reader that wants
        // it. Binding it here put `vector<bool, A>` beside `vector` (and
        // `unique_ptr<T[], D>` beside its primary) in std's table, and every
        // `std::vector` step saw two entities (R028E). The same rule as a
        // Kairo `class <> Box<[T]>`, which _stmt_decl_imm declines to declare.
        if llvm::isa<clang::ClassTemplatePartialSpecializationDecl>(nd) {
            return
        }

        var dc: unsafe *DeclContext = &null
        if self._redirect != NameRedirect::None {
            dc = self.scope_for(t, self._redirect_scope)
        } else {
            dc = self.scope_for(t, nd->getDeclContext())
        }

        if dc == &null {
            return
        }

        // getAsFunction, not a FunctionDecl cast: a FunctionTemplateDecl is
        // not one, and took the ident path below, so every operator template
        // was bound under its display name `operator!=` and no `!=` ever
        // found it -- libc++ declares its iterator comparisons that way.
        var unsafe *fn_ = nd->getAsFunction()
        if fn_ != &null {
            if llvm::isa<clang::CXXConstructorDecl>(fn_) {
                self.bind(t, dc, DeclName::ctor(), kd)
                return
            }

            if llvm::isa<clang::CXXDestructorDecl>(fn_) {
                self.bind(t, dc, DeclName::op_name(TokenKind::KwFinally, TokenKind::TkUnknown), kd)
                return
            }

            if fn_->isOverloadedOperator() {
                var k0 = TokenKind::TkUnknown
                var k1 = TokenKind::TkUnknown
                if self._op_kinds(fn_->getOverloadedOperator(), &k0, &k1) {
                    self.bind(t, dc, DeclName::op_name(k0, k1), kd)
                }

                return
            }

            if llvm::isa<clang::CXXConversionDecl>(fn_) {
                self.bind(t, dc, DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown), kd)
                return
            }
        }

        // C++ tag hiding ([basic.scope.hiding]). A typedef of the same-named
        // tag (`typedef struct X X`) is that tag under its own name: one
        // entity, so only the tag is bound. A tag whose name an ordinary
        // decl takes (`struct timezone` + `extern long timezone`) is bound
        // under the INTERNAL key `struct timezone` -- a spelling no source
        // can produce -- and the plain name is the ordinary decl's alone.
        // The type itself stays reachable through every signature that
        // names it; TypeImport goes by the clang decl, never by name.
        if self._typedef_of_own_tag(nd) {
            return
        }

        var kw = self._hidden_tag_keyword(nd)
        if kw.size() > 0 {
            decl_set_ffi_tag_keyword(kd, kw) // monotonic: see FFILinkage::ffi_tag_keyword.
            self.bind(t, dc, self._ident_key(t, dc, kw + " " + self._display_name(nd)), kd)
            return
        }

        self.bind(t, dc, self._ident_key(t, dc, self._display_name(nd)), kd)
        // A member of an inline namespace lives in its parent's table
        // (scope_for), which is how `std::vector` finds libc++'s
        // `std::__1::vector`. C++ also lets the inline namespace be named
        // (`ns::v1::F`), and with nothing in its own table that step was
        // R025E "no member named 'F' in module 'v1'". So the decl is bound
        // in each inline namespace it sits in as well; the entity is one.
        if self._redirect == NameRedirect::None {
            var unsafe *cur = nd->getDeclContext()
            while cur != &null && (cur->isTransparentContext() || cur->isInlineNamespace()) {
                if llvm::isa<clang::EnumDecl>(cur) {
                    break
                }

                var unsafe *ins = llvm::dyn_cast<clang::NamespaceDecl>(cur)
                if ins != &null && ins->isInline() {
                    var unsafe *idc = unsafe (self.namespace_for(t, ins) as unsafe *DeclContext)
                    self.bind(t, idc, self._ident_key(t, idc, self._display_name(nd)), kd)
                }

                cur = cur->getParent()
            }
        }

        // An UNSCOPED enumerator is also visible in the enum's enclosing scope.
        // Not for a using-declared enumerator: `using E::A` names A alone,
        // and its enum's scope is not the using's to write into.
        var unsafe *ec = llvm::dyn_cast<clang::EnumConstantDecl>(nd)
        if ec != &null && self._redirect != NameRedirect::Using {
            var unsafe *ed = llvm::dyn_cast<clang::EnumDecl>(ec->getDeclContext())
            if ed != &null && !ed->isScoped() {
                var unsafe *outer = self.scope_for(t, ed->getDeclContext())
                if outer != &null {
                    self.bind(t, outer, self._ident_key(t, outer, self._display_name(nd)), kd)
                }
            }
        }
    }

    /// `struct` / `class` / `union` / `enum` when \p nd is a named tag whose
    /// name an ORDINARY decl of the same scope also declares, "" otherwise.
    /// Asked of clang's own lookup over the whole set, so a tag in one header
    /// and the variable hiding it in another (glibc's `struct timezone` in
    /// <sys/time.h>, `timezone` in <time.h>) are seen together.
    priv fn _hidden_tag_keyword(self, nd: unsafe *const clang::NamedDecl) -> string {
        var unsafe *tag = llvm::dyn_cast<clang::TagDecl>(nd)
        if tag == &null {
            return ""
        }

        if tag->getTypedefNameForAnonDecl() != &null {
            return ""
        }

        if nd->getDeclName().isEmpty() {
            return ""
        }

        if llvm::isa<clang::ClassTemplateSpecializationDecl>(nd) {
            return ""
        }

        var unsafe *dc    = tag->getDeclContext()->getRedeclContext()
        var unsafe *canon = tag->getCanonicalDecl()
        for r in dc->lookup(nd->getDeclName()) {
            if llvm::isa<clang::TagDecl>(r) {
                continue
            }

            if !r->isInIdentifierNamespace((clang::Decl::IDNS_Ordinary as u32)) {
                continue
            }

            var unsafe *td = llvm::dyn_cast<clang::TypedefNameDecl>(r)
            if td != &null {
                var unsafe *under = td->getUnderlyingType()->getAsTagDecl()
                if under != &null && under->getCanonicalDecl() == canon {
                    continue
                }
            }

            return self._str(tag->getKindName())
        }

        return ""
    }

    /// `typedef struct X X`: a typedef whose underlying type is a tag of the
    /// same name in the same scope.
    priv fn _typedef_of_own_tag(self, nd: unsafe *const clang::NamedDecl) -> bool {
        var unsafe *td = llvm::dyn_cast<clang::TypedefNameDecl>(nd)
        if td == &null {
            return false
        }

        var unsafe *under = td->getUnderlyingType()->getAsTagDecl()
        if under == &null {
            return false
        }

        if under->getDeclName() != td->getDeclName() {
            return false
        }

        return under->getDeclContext()->getRedeclContext()->Equals(
            td->getDeclContext()->getRedeclContext(),
        )
    }

    /// The identifier key for \p dc's table. A table is keyed by ITS OWN
    /// TU's imms (hard invariant #2), and the TU owning \p dc need not be the
    /// header being walked: a class template forward-declared in one header
    /// and defined in another (all of libc++: <__fwd/vector.h>) gets its
    /// members from the second header, into the first header's decl.
    /// Interning through the walking header filed every such member under a
    /// key no lookup could probe -- `v.push_back` was "no member".
    priv fn _ident_key(self,
                       t:       unsafe *HeaderTarget,
                       dc:      unsafe *DeclContext,
                       const s: string) -> DeclName {
        var unsafe *ctx = t->ctx
        var unsafe *tu  = NameLookup::tu_of(dc)
        if tu != &null && tu->ctx != &null {
            ctx = tu->ctx
        }

        return DeclName::ident(ctx->get_imm_table()->intern_ident_copy(s))
    }

    /// C++ overloaded operator -> the Kairo `fn op` token pair. False for an
    /// operator Kairo has no spelling for; the Kairo decl still exists for
    /// EmitIR, it just is not findable by name.
    ///
    /// NOT here on purpose: OO_New / OO_Delete / OO_Array_New / OO_Array_Delete.
    /// Kairo's `op delete` is the DESTRUCTOR (cleanup of a possibly stack
    /// object, C++ `~T()`), not deallocation; C++ `operator delete` is
    /// allocation-side and has no Kairo counterpart. See _bind_named for the
    /// destructor mapping.
    priv fn _op_kinds(self,
                      oo: clang::OverloadedOperatorKind,
                      k0: *TokenKind,
                      k1: *TokenKind) -> bool {
        *k1 = TokenKind::TkUnknown
        match oo {
            case clang::OO_Plus {
                *k0 = TokenKind::OpPlus
            } case clang::OO_Minus {
                *k0 = TokenKind::OpMinus
            } case clang::OO_Star {
                *k0 = TokenKind::OpStar
            } case clang::OO_Slash {
                *k0 = TokenKind::OpSlash
            } case clang::OO_Percent {
                *k0 = TokenKind::OpPercent
            } case clang::OO_Caret {
                *k0 = TokenKind::OpCaret
            } case clang::OO_Amp {
                *k0 = TokenKind::OpAmp
            } case clang::OO_Pipe {
                *k0 = TokenKind::OpPipe
            } case clang::OO_Tilde {
                *k0 = TokenKind::OpTilde
            } case clang::OO_Exclaim {
                *k0 = TokenKind::OpExclaim
            } case clang::OO_Equal {
                *k0 = TokenKind::OpEqual
            } case clang::OO_Less {
                *k0 = TokenKind::OpLess
            } case clang::OO_Greater {
                *k0 = TokenKind::OpGreater
            } case clang::OO_PlusEqual {
                *k0 = TokenKind::OpPlusEqual
            } case clang::OO_MinusEqual {
                *k0 = TokenKind::OpMinusEqual
            } case clang::OO_StarEqual {
                *k0 = TokenKind::OpStarEqual
            } case clang::OO_SlashEqual {
                *k0 = TokenKind::OpSlashEqual
            } case clang::OO_PercentEqual {
                *k0 = TokenKind::OpPercentEqual
            } case clang::OO_CaretEqual {
                *k0 = TokenKind::OpCaretEqual
            } case clang::OO_AmpEqual {
                *k0 = TokenKind::OpAmpEqual
            } case clang::OO_PipeEqual {
                *k0 = TokenKind::OpPipeEqual
            } case clang::OO_LessLess {
                *k0 = TokenKind::OpLessLess
            } case clang::OO_GreaterGreater {
                *k0 = TokenKind::OpGreaterGreater
            } case clang::OO_LessLessEqual {
                *k0 = TokenKind::OpLessLessEqual
            } case clang::OO_GreaterGreaterEqual {
                *k0 = TokenKind::OpGreaterGreaterEqual
            } case clang::OO_EqualEqual {
                *k0 = TokenKind::OpEqualEqual
            } case clang::OO_ExclaimEqual {
                *k0 = TokenKind::OpExclaimEqual
            } case clang::OO_LessEqual {
                *k0 = TokenKind::OpLessEqual
            } case clang::OO_GreaterEqual {
                *k0 = TokenKind::OpGreaterEqual
            } case clang::OO_Spaceship {
                *k0 = TokenKind::OpLessEqualGreater
            } case clang::OO_AmpAmp {
                *k0 = TokenKind::OpAmpAmp
            } case clang::OO_PipePipe {
                *k0 = TokenKind::OpPipePipe
            } case clang::OO_PlusPlus {
                *k0 = TokenKind::OpPlusPlus
            } case clang::OO_MinusMinus {
                *k0 = TokenKind::OpMinusMinus
            } case clang::OO_Comma {
                *k0 = TokenKind::OpComma
            } case clang::OO_Arrow {
                *k0 = TokenKind::OpArrow
            } case clang::OO_ArrowStar {
                *k0 = TokenKind::OpArrowStar
            } case clang::OO_Call {
                *k0 = TokenKind::OpLParen
                *k1 = TokenKind::OpRParen
            } case clang::OO_Subscript {
                *k0 = TokenKind::OpLSquare
                *k1 = TokenKind::OpRSquare
            } default { // new/delete family, co_await, conditional.
                return false
            }
        }

        return true
    }

    /// # pass 2: define

    /// Fill the slots. Idempotent: a second set reaching the same decl sees
    /// the registry hit in declare() and never calls this.
    fn define(self, d: unsafe *clang::Decl, kd: unsafe *Decl, ti: unsafe *TypeImport) {
        if d == &null || kd == &null {
            return
        }

        var unsafe *t = self.target_of(d)
        if t == &null || t->frozen && (!self.in_fill()) {
            return
        }

        self.n_defined += 1

        // Which Kairo decl owns each template depth in scope here: without
        // it every `T` in a template's signature imports as opaque.
        ti->tpl_owners.clear()
        self._template_owners(d, &ti->tpl_owners)

        match d->getKind() {
            case clang::Decl::CXXRecord {
                self._define_record(t, llvm::cast<clang::CXXRecordDecl>(d), kd, ti)
            } case clang::Decl::Record {
                self._define_record_c(t, llvm::cast<clang::RecordDecl>(d), kd, ti)
            } case clang::Decl::ClassTemplate {
                self._define_class_template(t, llvm::cast<clang::ClassTemplateDecl>(d), kd, ti)
            } case clang::Decl::ClassTemplateSpecialization {
                self._define_spec(
                    t,
                    llvm::cast<clang::ClassTemplateSpecializationDecl>(d),
                    kd,
                    ti,
                    false,
                )
            } case clang::Decl::ClassTemplatePartialSpecialization {
                self._define_spec(
                    t,
                    llvm::cast<clang::ClassTemplateSpecializationDecl>(d),
                    kd,
                    ti,
                    true,
                )
            } case clang::Decl::Enum {
                self._define_enum(t, llvm::cast<clang::EnumDecl>(d), kd, ti)
            } case clang::Decl::Function {
                self._define_function(t, llvm::cast<clang::FunctionDecl>(d), kd, ti, &null)
            } case clang::Decl::CXXMethod {
                self._define_function(t, llvm::cast<clang::FunctionDecl>(d), kd, ti, &null)
            } case clang::Decl::CXXConstructor {
                self._define_function(t, llvm::cast<clang::FunctionDecl>(d), kd, ti, &null)
            } case clang::Decl::CXXDestructor {
                self._define_function(t, llvm::cast<clang::FunctionDecl>(d), kd, ti, &null)
            } case clang::Decl::CXXConversion {
                self._define_function(t, llvm::cast<clang::FunctionDecl>(d), kd, ti, &null)
            } case clang::Decl::FunctionTemplate {
                var unsafe *ft = llvm::cast<clang::FunctionTemplateDecl>(d)
                self._define_function(
                    t,
                    ft->getTemplatedDecl(),
                    kd,
                    ti,
                    ft->getTemplateParameters(),
                )
            } case clang::Decl::Typedef {
                cast<Declarations::TypeAliasDecl>(kd)->aliased = ti->_import(
                    llvm::cast<clang::TypedefNameDecl>(d)->getUnderlyingType(),
                )
            } case clang::Decl::TypeAlias {
                cast<Declarations::TypeAliasDecl>(kd)->aliased = ti->_import(
                    llvm::cast<clang::TypedefNameDecl>(d)->getUnderlyingType(),
                )
            } case clang::Decl::TypeAliasTemplate {
                var unsafe *at_ = llvm::cast<clang::TypeAliasTemplateDecl>(d)
                var unsafe *td  = cast<Declarations::TypeAliasDecl>(kd)
                self._generic_params(t, td, at_->getTemplateParameters(), ti, &td->generic_params)
                td->aliased = ti->_import(at_->getTemplatedDecl()->getUnderlyingType())
            } case clang::Decl::Var {
                var unsafe *v  = llvm::cast<clang::VarDecl>(d)
                var unsafe *kv = cast<Declarations::VariableDecl>(kd)
                kv->type_     = ti->_import(v->getType())
                kv->is_thread = v->getTLSKind() != clang::VarDecl::TLS_None
            } case clang::Decl::Field {
                var unsafe *f = llvm::cast<clang::FieldDecl>(d)
                cast<Declarations::FieldDecl>(kd)->type_      = ti->_import(f->getType())
                cast<Declarations::FieldDecl>(kd)->is_mutable = f->isMutable()
            } case clang::Decl::EnumConstant { // value: EmitIR spells the enumerator by name.
                0
            } case clang::Decl::Concept { // constraint-only bound; no surface to import.
                0
            } default {
                0
            }
        }
    }

    /// Every Kairo decl owning a template parameter list that encloses \p d
    /// (\p d's own included), outermost first: index = clang depth. A method
    /// of a class template sees the class at depth 0; a member template of
    /// it adds itself at depth 1.
    priv fn _template_owners(self,
                             d:          unsafe *clang::Decl,
                             @inout out: cxx::std::vector<unsafe *Decl>) {
        var        inner_first = cxx::std::vector<unsafe *Decl>()
        var unsafe *cur        = d
        while cur != &null {
            var unsafe *kd = self._tpl_owner(cur)
            if kd != &null {
                inner_first.push_back(kd)
            }

            var unsafe *dc = cur->getDeclContext()
            if dc == &null || dc->isTranslationUnit() {
                break
            }

            cur = clang::Decl::castFromDeclContext(dc)
        }

        var n = inner_first.size()
        for var i: usize = 0; i < n; ++i {
            out.push_back(inner_first[n - 1 - i])
        }
    }

    /// The Kairo decl for \p c when \p c owns a template parameter list: a
    /// template (registered under its templated decl's USR too), a record or
    /// function a template describes, or a partial specialization.
    priv fn _tpl_owner(self, c: unsafe *clang::Decl) -> unsafe *Decl {
        var unsafe *td = llvm::dyn_cast<clang::TemplateDecl>(c)
        if td != &null {
            var unsafe *inner = td->getTemplatedDecl() // null for a concept.
            if inner == &null {
                return &null
            }

            return self._find((TypeImport::usr_of(inner->getCanonicalDecl())).str())
        }

        if llvm::isa<clang::ClassTemplatePartialSpecializationDecl>(c) {
            return self._find((TypeImport::usr_of(c->getCanonicalDecl())).str())
        }

        var unsafe *rd = llvm::dyn_cast<clang::CXXRecordDecl>(c)
        if rd != &null && rd->getDescribedClassTemplate() != &null {
            return self._find((TypeImport::usr_of(rd->getCanonicalDecl())).str())
        }

        var unsafe *fd = llvm::dyn_cast<clang::FunctionDecl>(c)
        if fd != &null && fd->getDescribedFunctionTemplate() != &null {
            return self._find((TypeImport::usr_of(fd->getCanonicalDecl())).str())
        }

        return &null
    }

    /// ## records

    /// Fill mode's record step: fields, methods, bases and layout of the
    /// completed specialization onto the shell. Runs after its members were
    /// declared and defined -- the order HeaderIndex gives a header's records.
    fn define_instance(self,
                       spec:  unsafe *clang::ClassTemplateSpecializationDecl,
                       shell: unsafe *Decl,
                       ti:    unsafe *TypeImport) {
        if !self.in_fill() || spec == &null || shell == &null {
            return
        }

        ti->tpl_owners.clear() // concrete: no parameter list encloses a specialization.
        self._define_record(self._fill_target, spec, shell, ti)
    }

    priv fn _define_record_c(self,
                             t:  unsafe *HeaderTarget,
                             rd: unsafe *clang::RecordDecl,
                             kd: unsafe *Decl,
                             ti: unsafe *TypeImport) {
        var unsafe *def = rd->getDefinition()
        if def == &null {
            return
        }

        var fields = cxx::std::vector<unsafe *Declarations::FieldDecl>()
        self._collect_fields(t, def, &fields, ti)
        if isa<Declarations::StructDecl>(kd) {
            cast<Declarations::StructDecl>(kd)->fields.from_vec(unsafe &fields, t->ctx)
        } else if isa<Declarations::UnionDecl>(kd) {
            cast<Declarations::UnionDecl>(kd)->fields.from_vec(unsafe &fields, t->ctx)
        } else if isa<Declarations::ClassDecl>(kd) {
            cast<Declarations::ClassDecl>(kd)->fields.from_vec(unsafe &fields, t->ctx)
        }

        self._layout(def, kd)
    }

    priv fn _define_record(self,
                           t:  unsafe *HeaderTarget,
                           rd: unsafe *clang::CXXRecordDecl,
                           kd: unsafe *Decl,
                           ti: unsafe *TypeImport) {
        var unsafe *def = rd->getDefinition()
        if def == &null {
            return
        }

        var fields  = cxx::std::vector<unsafe *Declarations::FieldDecl>()
        var methods = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        self._collect_fields(t, def, &fields, ti)
        for m in def->methods() {
            if m->isImplicit() && !m->isUserProvided() {
                continue
            }

            var unsafe *km = self._find((TypeImport::usr_of(m->getCanonicalDecl())).str())
            if km == &null {
                continue
            }

            methods.push_back(cast<Declarations::FunctionDecl>(km))
        }

        var bases = cxx::std::vector<Declarations::InheritEdge>()
        for b in def->bases() {
            var e = Declarations::InheritEdge{}
            e.base       = ti->_import(b.getType())
            e.is_virtual = b.isVirtual()
            e.visibility = (self._vis_of_access(b.getAccessSpecifier()) as u8)
            e.range      = self.range_of(def)
            bases.push_back(e)
        }

        if isa<Declarations::ClassDecl>(kd) {
            var unsafe *c = cast<Declarations::ClassDecl>(kd)
            c->fields.from_vec(unsafe &fields, t->ctx)
            c->methods.from_vec(unsafe &methods, t->ctx)
            c->derives_list.from_vec(unsafe &bases, t->ctx)
            c->ffi_is_final = def->hasAttr<clang::FinalAttr>()
            // `using B::g;`: g's lookup in this class continues into B
            // (MemberLookup hides a base's name otherwise, as C++ does).
            c->ffi_usings.clear()
            for ud in def->decls() {
                var unsafe *u = llvm::dyn_cast<clang::UsingDecl>(ud)
                if u == &null {
                    continue
                }

                // An operator is keyed by its token kinds, not a spelling
                // (DeclName::op_name), so MemberLookup cannot ask for one
                // operator: any `using B::operator@;` keeps every operator
                // merged ("operator" marks it; no identifier spells so).
                if u->getDeclName().getNameKind() == clang::DeclarationName::CXXOperatorName {
                    c->ffi_usings.push_back("operator")
                    continue
                }

                if !u->getDeclName().isIdentifier() {
                    continue
                }

                c->ffi_usings.push_back(
                    string(
                        unsafe ((u->getNameAsString().c_str() as unsafe *const u8) as *const u8),
                    ),
                )
            }
        } else if isa<Declarations::StructDecl>(kd) {
            var unsafe *s = cast<Declarations::StructDecl>(kd)
            s->fields.from_vec(unsafe &fields, t->ctx)
            s->methods.from_vec(unsafe &methods, t->ctx)
        } else if isa<Declarations::UnionDecl>(kd) {
            var unsafe *u = cast<Declarations::UnionDecl>(kd)
            u->fields.from_vec(unsafe &fields, t->ctx)
            u->methods.from_vec(unsafe &methods, t->ctx)
        }

        self._layout(def, kd)
    }

    priv fn _collect_fields(self,
                            t:          unsafe *HeaderTarget,
                            def:        unsafe *clang::RecordDecl,
                            @inout out: cxx::std::vector<unsafe *Declarations::FieldDecl>,
                            ti:         unsafe *TypeImport) {
        for f in def->fields() {
            if f->isAnonymousStructOrUnion() {
                // Its members were declared into THIS record's scope
                // (scope_for sees through the transparent context).
                var unsafe *inner = f->getType()->getAsRecordDecl()
                if inner != &null {
                    self._collect_fields(t, inner, &out, ti)
                }

                continue
            }

            var unsafe *kf = self._find((TypeImport::usr_of(f->getCanonicalDecl())).str())
            if kf == &null {
                continue
            }

            out.push_back(cast<Declarations::FieldDecl>(kf))
        }
    }

    priv fn _vis_of_access(self, a: clang::AccessSpecifier) -> VisibilityKind {
        if a == clang::AS_private {
            return VisibilityKind::Private
        }

        if a == clang::AS_protected {
            return VisibilityKind::Protected
        }

        return VisibilityKind::Public
    }

    /// clang's layout onto the mixin. Only for a complete, non-dependent
    /// definition; a template pattern has no layout and `known` stays false.
    priv fn _layout(self, def: unsafe *clang::RecordDecl, kd: unsafe *Decl) {
        if def->isDependentType() || def->isInvalidDecl() {
            return
        }

        if !def->isCompleteDefinition() {
            return
        }

        var lay = ForeignLayout()
        var *rl = &self.cctx->getASTRecordLayout(def)
        lay.known       = true
        lay.size_bytes  = (rl->getSize().getQuantity() as u64)
        lay.align_bytes = (rl->getAlignment().getQuantity() as u64)
        var i: u32 = 0
        for f in def->fields() {
            lay.field_offsets.push_back(rl->getFieldOffset(i))
            i += 1
        }

        var unsafe *cxx_v = llvm::dyn_cast<clang::CXXRecordDecl>(def)
        if cxx_v != &null {
            lay.has_vfptr            = rl->hasOwnVFPtr()
            lay.polymorphic          = cxx_v->isPolymorphic()
            lay.abstract_            = cxx_v->isAbstract()
            lay.trivially_copyable   = cxx_v->isTriviallyCopyable()
            lay.trivial_dtor         = cxx_v->hasTrivialDestructor()
            lay.trivial_default_ctor = cxx_v->hasTrivialDefaultConstructor()
        } else {
            lay.trivially_copyable   = true
            lay.trivial_dtor         = true
            lay.trivial_default_ctor = true
        }

        if isa<Declarations::ClassDecl>(kd) {
            cast<Declarations::ClassDecl>(kd)->layout = lay
        } else if isa<Declarations::StructDecl>(kd) {
            cast<Declarations::StructDecl>(kd)->layout = lay
        } else if isa<Declarations::UnionDecl>(kd) {
            cast<Declarations::UnionDecl>(kd)->layout = lay
        }
    }

    /// ## templates

    priv fn _define_class_template(self,
                                   t:  unsafe *HeaderTarget,
                                   ct: unsafe *clang::ClassTemplateDecl,
                                   kd: unsafe *Decl,
                                   ti: unsafe *TypeImport) {
        var unsafe *gps = decl_generic_params_slot(kd)
        if gps == &null {
            return
        }

        // The registry keys on the USR, so `kd` is defined from whichever
        // redeclaration came first. A forward declaration without the
        // defaults (`template <class V, class A> class StringMap;` in
        // TargetParser/Host.h) would leave `StringMap<u32>` short of an
        // argument; the most recent redeclaration is the one that carries
        // them (its parameters inherit the default from the primary).
        var unsafe *latest = ct->getMostRecentDecl()
        var unsafe *tpl = if (latest != &null) => (latest->getTemplateParameters())
                          else => ct->getTemplateParameters()
        self._generic_params(t, kd, tpl, ti, &*gps)
        self._define_record(t, ct->getTemplatedDecl(), kd, ti)
    }

    /// Explicit (full) and partial specializations register against the
    /// primary exactly as T registers a Kairo `class <> Box<i32>`.
    priv fn _define_spec(self,
                         t:       unsafe *HeaderTarget,
                         sp:      unsafe *clang::ClassTemplateSpecializationDecl,
                         kd:      unsafe *Decl,
                         ti:      unsafe *TypeImport,
                         partial: bool) {
        var unsafe *prim = self._find(
            (TypeImport::usr_of(sp->getSpecializedTemplate()->getCanonicalDecl())).str(),
        )

        if prim == &null {
            return
        }

        var unsafe *rep = NameLookup::representative(prim)
        var        args = cxx::std::vector<unsafe *Type>()
        var        ok   = true
        var        list = sp->getTemplateArgs().asArray()
        for var i: usize = 0; i < list.size(); ++i {
            // A variadic primary's arguments arrive as one Pack: flattened,
            // as the registry keys an instance (`tuple<i32, f32>` is [i32,
            // f32]). Refused before, so libc++'s `template <> class tuple<>`
            // (an EMPTY pack) never registered as a specialization: it stayed
            // an ordinary record named `tuple` beside the template, the name
            // found it, and every `cxx::std::tuple<A, B>` was R032E "'tuple'
            // is not generic".
            if list[i].getKind() == clang::TemplateArgument::Pack {
                var pk = list[i].pack_elements()
                for var j: usize = 0; j < pk.size(); ++j {
                    if pk[j].getKind() != clang::TemplateArgument::Type {
                        ok = false
                        break
                    }

                    args.push_back(ti->_import(pk[j].getAsType()))
                }

                if !ok {
                    break
                }

                continue
            }

            if list[i].getKind() != clang::TemplateArgument::Type {
                ok = false
                break
            }

            args.push_back(ti->_import(list[i].getAsType()))
        }

        if !ok { // non-type args: no registry shape.
            return
        }

        self._set_spec(
            kd,
            if (partial) => (Declarations::SpecKind::Partial)
            else => Declarations::SpecKind::Explicit,
            rep,
            &args,
            t->ctx,
        )

        if partial {
            var unsafe *ps  = llvm::cast<clang::ClassTemplatePartialSpecializationDecl>(sp)
            var unsafe *gps = decl_generic_params_slot(kd)
            if gps != &null {
                self._generic_params(t, kd, ps->getTemplateParameters(), ti, &*gps)
            }

            self.instances->register_partial(rep, kd)
        } else {
            self.instances->register_explicit(rep, unsafe &args, kd, t->fid)
        }

        self._define_record(t, sp, kd, ti)
    }

    priv fn _set_spec(self,
                      kd:          unsafe *Decl,
                      k:           Declarations::SpecKind,
                      prim:        unsafe *Decl,
                      @inout args: cxx::std::vector<unsafe *Type>,
                      ctx:         unsafe *ASTContext) {
        decl_set_spec_kind(kd, k)
        decl_set_instantiated_from(kd, prim)
        // spec_args has no slot accessor: the one per-kind write left.
        if isa<Declarations::ClassDecl>(kd) {
            cast<Declarations::ClassDecl>(kd)->spec_args.from_vec(unsafe &args, ctx)
        } else if isa<Declarations::StructDecl>(kd) {
            cast<Declarations::StructDecl>(kd)->spec_args.from_vec(unsafe &args, ctx)
        } else if isa<Declarations::UnionDecl>(kd) {
            cast<Declarations::UnionDecl>(kd)->spec_args.from_vec(unsafe &args, ctx)
        }
    }

    /// TemplateParameterList -> GenericParamDecls, owner stamped so
    /// `generic_param(owner, index)` in TypeImport and ChainBinding's
    /// `_param_of` agree (the same contract T's _push_frame keeps).
    priv fn _generic_params(self,
                            t:          unsafe *HeaderTarget,
                            owner:      unsafe *Decl,
                            tpl:        unsafe *const clang::TemplateParameterList,
                            ti:         unsafe *TypeImport,
                            @inout out: FrozenList<unsafe *Declarations::GenericParamDecl>) {
        var gps = cxx::std::vector<unsafe *Declarations::GenericParamDecl>()
        for var i: u32 = 0; i < tpl->size(); ++i {
            var unsafe *p = tpl->getParam(i)
            var        nm = self._str(p->getName())
            if nm.size() == 0 {
                nm = LowerTargets::foreign_tparam(i)
            }

            var unsafe *gp = Declarations::GenericParamDecl::create(
                t->ctx,
                self.range_of(p),
                self.ident(t, nm, self.range_of(p)),
                i,
            )

            gp->owner      = NameLookup::representative(owner)
            gp->kind_bound = Declarations::GenericParamKindBound::Any // opaque: the Rust rule. A concept bound would go in requires.
            var unsafe *tt = llvm::dyn_cast<clang::TemplateTypeParmDecl>(p)
            if tt != &null {
                gp->is_pack         = tt->isParameterPack()
                gp->ffi_has_default = tt->hasDefaultArgument()
                if tt->hasDefaultArgument() {
                    gp->default_type = ti->_import(
                        tt->getDefaultArgument().getArgument().getAsType(),
                    )
                }
            }

            var unsafe *nt = llvm::dyn_cast<clang::NonTypeTemplateParmDecl>(p)
            if nt != &null {
                gp->is_const_param  = true
                gp->is_pack         = nt->isParameterPack()
                gp->value_type      = ti->_import(nt->getType())
                gp->ffi_has_default = nt->hasDefaultArgument()
                // `template <class T, unsigned N = 3>`: a default clang can
                // fold now is the value argument a Kairo `<.., 3>` would be,
                // so `Buf<i32>` keys as `Buf<i32, 3>` (GenericArgs fills it).
                // One computed from an earlier parameter (SmallVector's
                // `N = CalculateSmallVectorDefaultInlinedElements<T>::value`)
                // has no value until instantiation and stays required.
                if nt->hasDefaultArgument() {
                    var da = nt->getDefaultArgument().getArgument()
                    if da.getKind() == clang::TemplateArgument::Integral {
                        gp->default_type = ti->integral(da.getAsIntegral())
                    } else if da.getKind() == clang::TemplateArgument::Expression {
                        var unsafe *ex = da.getAsExpr()
                        if ex != &null && !ex->isValueDependent() && !ex->isTypeDependent() {
                            var er = clang::Expr::EvalResult()
                            if ex->EvaluateAsInt(&er, *self.cctx) {
                                gp->default_type = ti->integral(er.Val.getInt())
                            }
                        }
                    }
                }
            }

            var unsafe *tm = llvm::dyn_cast<clang::TemplateTemplateParmDecl>(p)
            if tm != &null {
                gp->ffi_has_default = tm->hasDefaultArgument()
            }

            // Template template params: recorded as an opaque type param.
            gp->impl_bounds.from_raw(&null, 0)
            gp->derives_bounds.from_raw(&null, 0)
            gps.push_back(gp)
        }

        out.from_vec(unsafe &gps, t->ctx)
    }

    /// ## enums

    priv fn _define_enum(self,
                         t:  unsafe *HeaderTarget,
                         ed: unsafe *clang::EnumDecl,
                         kd: unsafe *Decl,
                         ti: unsafe *TypeImport) {
        var unsafe *def = ed->getDefinition()
        var unsafe *ke  = cast<Declarations::EnumDecl>(kd)
        ke->ffi_scoped_enum = ed->isScoped()
        // define() runs once per CLANG redeclaration, and every one of them
        // maps to this one Kairo decl (the registry). Fill and mark it only
        // from the definition itself: libc++ forward-declares enums
        // (`enum class byte : unsigned char;`) and defines them later, and a
        // second mark_definition is the "two definitions in one chain" ICE.
        if def == &null || def != ed {
            return
        }

        ke->mark_definition()
        ke->underlying = ti->_import(def->getIntegerType())
        var vs = cxx::std::vector<unsafe *Declarations::EnumVariantDecl>()
        for ec in def->enumerators() {
            var unsafe *kv = self._find((TypeImport::usr_of(ec->getCanonicalDecl())).str())
            if kv == &null {
                continue
            }

            vs.push_back(cast<Declarations::EnumVariantDecl>(kv))
        }

        ke->variants.from_vec(unsafe &vs, t->ctx)
        ke->is_adt = false
    }

    /// ## functions

    priv fn _define_function(self,
                             t:   unsafe *HeaderTarget,
                             fd:  unsafe *clang::FunctionDecl,
                             kd:  unsafe *Decl,
                             ti:  unsafe *TypeImport,
                             tpl: unsafe *const clang::TemplateParameterList) {
        var unsafe *kf = cast<Declarations::FunctionDecl>(kd)
        if tpl != &null {
            self._generic_params(t, kd, tpl, ti, &kf->generic_params)
        }

        var params     = cxx::std::vector<unsafe *Declarations::ParamDecl>()
        var idx:   u32 = 0

        // Receiver. A non-static method gets Kairo's `self`, typed as the
        // record (what T's _synthesize_receiver would write). Statics have
        // no receiver and are found through `Type::m`.
        var unsafe *m      = llvm::dyn_cast<clang::CXXMethodDecl>(fd)
        var        is_ctor = llvm::isa<clang::CXXConstructorDecl>(fd)
        var        is_dtor = llvm::isa<clang::CXXDestructorDecl>(fd)
        if m != &null && !m->isStatic() {
            var        at       = self.name_range_of(fd)
            var        self_tok = self._tok(t, at, TokenKind::KwSelf, "self")
            var unsafe *sp      = Declarations::ParamDecl::create_self(t->ctx, at, self_tok)
            sp->type_    = ti->_import(m->getThisType()->getPointeeType())
            sp->is_const = m->isConst()
            sp->index    = 0
            params.push_back(sp)
            idx = 1
            kf->ffi_ref_qualifier =      if (m->getRefQualifier() == clang::RQ_LValue) => (1)
                                    else if (m->getRefQualifier() == clang::RQ_RValue) => (2)
                                    else => 0
            kf->ffi_virtual      = m->isVirtual()
            kf->ffi_pure_virtual = m->isPureVirtual()
            if m->isVirtual() {
                kf->abi = Declarations::AbiKind::Virtual
            }

            if m->size_overridden_methods() > 0 {
                kf->abi = Declarations::AbiKind::Override
            }
        } else if m != &null {
            kf->ffi_static_member = true
            kf->abi               = Declarations::AbiKind::Static
        }

        for p in fd->parameters() {
            var pat     = self.range_of(p)
            var pnm     = self._str(p->getName())
            var unnamed = pnm.size() == 0
            if unnamed {
                pnm = LowerTargets::foreign_param(idx as usize)
            }

            // `Args&&... args`: the parameter's type is a PackExpansionType,
            // which has no Kairo shape and imported opaque, so no argument
            // converted to it and every emplace_back was SC063E. A Kairo pack
            // parameter is its ELEMENT's type marked is_pack; the element of
            // a C++ pack is the expansion's pattern (`Args&&`), one per
            // argument (OverloadResolution::_rank_arg).
            var ptype   = p->getType()
            var is_pack = false
            if p->isParameterPack() {
                var unsafe *pe = ptype->getAs<clang::PackExpansionType>()
                if pe != &null {
                    ptype   = pe->getPattern()
                    is_pack = true
                }
            }

            var unsafe *kp = Declarations::ParamDecl::create(
                t->ctx,
                pat,
                self.ident(t, pnm, pat),
                ti->_import(ptype),
                idx,
                unnamed,
            )

            kp->is_pack       = is_pack
            kp->has_default   = p->hasDefaultArg() // spec: new field; OverloadResolution reads it.
            kp->cxx_int_alias = ti->is_int_alias(p->getType())
            kp->cxx_alias_ptr = ti->is_alias_indirect(p->getType())
            kf->cxx_param_spellings.push_back(ti->spelling(p->getType()))
            params.push_back(kp)
            idx += 1
        }

        kf->params.from_vec(unsafe &params, t->ctx)
        kf->is_variadic    = false            // Kairo packs are generic; C `...` is its own flag:
        kf->ffi_c_variadic = fd->isVariadic()

        var rt = fd->getReturnType()
        kf->cxx_return_spelling = ti->spelling(rt)
        if rt->isVoidType() || is_ctor || is_dtor {
            kf->return_type = &null
        } else {
            kf->return_type = ti->_import(rt)
        }

        if fd->isNoReturn() {
            kf->is_noreturn = true
        }

        if fd->isOverloadedOperator() {
            kf->is_operator = true
            var k0 = TokenKind::TkUnknown
            var k1 = TokenKind::TkUnknown
            if self._op_kinds(fd->getOverloadedOperator(), &k0, &k1) {
                var toks = cxx::std::vector<Token>()
                var at   = self.name_range_of(fd)
                toks.push_back(
                    self._tok(
                        t,
                        at,
                        k0,
                        string(
                            unsafe ((clang::getOperatorSpelling(fd->getOverloadedOperator()) as unsafe *const u8) as *const u8),
                        ),
                    ),
                )

                if k1 != TokenKind::TkUnknown {
                    toks.push_back(self._tok(t, at, k1, ""))
                }

                kf->op_token.from_vec(unsafe &toks, t->ctx)
            }
        }

        if llvm::isa<clang::CXXConversionDecl>(fd) {
            kf->is_operator       = true
            kf->ffi_conversion_op = true
            var toks = cxx::std::vector<Token>()
            toks.push_back(self._tok(t, self.name_range_of(fd), TokenKind::KwAs, "as"))
            kf->op_token.from_vec(unsafe &toks, t->ctx)
        }

        if is_dtor {
            kf->is_operator = true
            var toks = cxx::std::vector<Token>()
            toks.push_back(self._tok(t, self.name_range_of(fd), TokenKind::KwFinally, "finally"))
            kf->op_token.from_vec(unsafe &toks, t->ctx)
        }

        var mods = Declarations::FnModifier::None
        if m != &null && m->isConst() {
            mods = mods | Declarations::FnModifier::IsConst
        }

        if fd->isConstexpr() {
            kf->ffi_constexpr = true
        }

        if fd->isInlined() {
            mods = mods | Declarations::FnModifier::IsInline
        }

        kf->modifiers = mods

        kf->body_kind = Declarations::FnBodyKind::None
        if fd->isDeleted() {
            kf->body_kind   = Declarations::FnBodyKind::Delete
            kf->ffi_deleted = fd->isDeletedAsWritten()
        } else if fd->isDefaulted() {
            kf->body_kind = Declarations::FnBodyKind::Default
        } else if m != &null && m->isPureVirtual() {
            kf->body_kind = Declarations::FnBodyKind::Virtual
        }

        kf->ffi_noexcept = fd->getExceptionSpecType() == clang::EST_BasicNoexcept
            || fd->getExceptionSpecType() == clang::EST_NoexceptTrue
        if is_ctor {
            var unsafe *c = llvm::cast<clang::CXXConstructorDecl>(fd)
            kf->ffi_explicit = c->isExplicit()
            if c->isCopyConstructor() {
                kf->transfer = Declarations::TransferKind::Copy
            }

            if c->isMoveConstructor() {
                kf->transfer = Declarations::TransferKind::Move
            }
        }

        if llvm::isa<clang::CXXConversionDecl>(fd) {
            kf->ffi_explicit = llvm::cast<clang::CXXConversionDecl>(fd)->isExplicit()
        }
    }
}
