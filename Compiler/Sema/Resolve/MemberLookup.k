/// --- The Kairo Project ------------------ Sema/Resolve/MemberLookup.k --- ///
///
///   \brief Member lookup over a CANONICAL type: own table, folded
///          extensions, then the inheritance DAG. The component Compiler/Spec/Pipeline.md
///          §2b describes; ChainBinding and (later) inference stand on it.
///
///   \detail
///     Compiler/Spec/Generics.md#partial-selection, locked:
///
///       MERGE, not hide. A derived member named `foo` does not hide base
///       `foo` overloads; it joins them. The whole DAG is walked (dedup
///       across virtual bases), every matching cell is UNIONED, and the
///       result is handed to overload resolution.
///
///     This class implements exactly that union and nothing more. It does
///     NOT select overloads, check access, resolve virtual dispatch, or
///     diagnose ambiguity -- each has its own home. It returns the candidate
///     set; the caller judges it.
///
///   \par Extensions
///     `extend Foo { }` members live in the ExtensionDecl's OWN table (parser
///     rule). Folding them into Foo's lookup is sema's job and this is where
///     it happens: an index from canonical type -> extensions targeting it,
///     built once per run over every parsed TU (sema runs in import-DAG
///     order, so an imported file's extensions are parsed and T-resolved by
///     the time the importer looks).
///
///     Extensions on non-record types (`extend i32 { }`, `extend *T { }`) are
///     keyed by the target's canonical POINTER. Extensions on records are
///     keyed by the record's DECL, so `extend <T> Vec<T>` matches every
///     Vec<X>: at NAME-lookup level a partial-specialization extension
///     contributes its members to all instances; which instance's body runs
///     is dispatch, decided later.
///
///   \par needs_using (§2b)
///     The merge is C++'s lookup under a `using Base::m;` in the derived
///     class, and InterfaceEmitter::_base_usings writes one for every
///     method name a class shares with a base, straight from the decls; no
///     slot is recorded here. OverloadResolution::_hide applies the
///     using-declaration's override/hide rule to the merged set. An
///     IMPORTED class is not merged: its lookup hides as C++'s does
///     (_walk_record, step 3).
///
///   Phase: LOWER (component; PRE: T complete -- base types must be canonical)
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
ffi "c++" import "vector"

import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::ImportOverlay::OverlayTargetKind
import AST::Context::SymbolTable::{
    DeclName,
    DeclNameKind,
    OverloadCell,
    SymbolTable,
}
import AST::DeclFacts::{
    decl_instantiated,
    decl_instantiated_from,
    decl_is_imported,
    decl_is_instance,
    decl_name_tok,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    QualifiedType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    NullableType,
    PointerType,
}
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Interop::Clang::HeaderSet::HeaderSet
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Token::TokenKind::TokenKind

/// The extension-visibility rule (RESOLUTION.md): TU \p sc sees `extend`
/// block \p e, written in file \p efid, when that file is its own, a
/// builtin file, one it imports or one those re-export (all three
/// SemaContext::sees_extension_file), or the file that declares the
/// extended record: an extension written beside its type travels with it.
pub fn extension_visible(sc: unsafe *SemaContext, e: unsafe *Declarations::ExtensionDecl, efid: u32) -> bool {
    if sc == &null || sc->sees_extension_file(efid) {
        return true
    }

    if e == &null || e->target == &null || e->target->canonical == &null {
        return false
    }

    var unsafe *c = canon_unqual(e->target->canonical)
    if !isa<RecordType>(c) {
        return false
    }

    var unsafe *rd = cast<RecordType>(c)->decl
    if rd != &null && decl_is_instance(rd) && decl_instantiated_from(rd) != &null {
        rd = decl_instantiated_from(rd)
    }

    var unsafe *rc = NameLookup::ctx_of(rd)
    return rc != &null && rc->fid == efid
}

/// `a::b::Point<T>` -> `Point`: the last path segment of a written type,
/// generic arguments dropped. Spelling only; for a note, never for lookup.
pub fn type_spelling_leaf(const s: string) -> string {
    var o: string = ""
    for var i: usize = 0; i < s.size(); ++i {
        var c = s[i]
        if c == ('<' as u8) {
            break
        }

        if c == (':' as u8) {
            o = ""
            continue
        }

        if c != (' ' as u8) {
            o.push_back(c)
        }
    }

    return o
}

pub class MemberLookup {
    pub var sc: unsafe *SemaContext

    /// record decl (canonical link) -> extensions targeting it.
    // extensions_of_* hand out a pointer INTO these maps' values. Safe under
    // DenseMap only because index_extensions() fills both once, behind
    // _indexed, before the first pointer leaves: a mid-lookup insert would
    // rehash and dangle every pointer a caller is holding. They build it
    // themselves on first use, so a lookup can never answer from an index
    // nobody built (Conversion and FnPurityCheck once did, and missed every
    // extension operator).
    priv var _ext_by_decl: llvm::DenseMap<u64, cxx::std::vector<unsafe *Declarations::ExtensionDecl>>
    /// canonical non-record type -> extensions targeting it.
    priv var _ext_by_type: llvm::DenseMap<u64, cxx::std::vector<unsafe *Declarations::ExtensionDecl>>
    /// The same two indexes for the extensions this TU does NOT see
    /// (extension_visible): never answered by a lookup, only read by
    /// hidden_extension for the "import it to use it" note.
    priv var _hidden_by_decl: llvm::DenseMap<u64, cxx::std::vector<unsafe *Declarations::ExtensionDecl>>
    priv var _hidden_by_type: llvm::DenseMap<u64, cxx::std::vector<unsafe *Declarations::ExtensionDecl>>
    /// Unseen extensions whose target T has not resolved yet (their file is
    /// checked after this one): matched by the target's spelled leaf, so
    /// the note does not depend on check order either.
    priv var _hidden_unresolved: cxx::std::vector<unsafe *Declarations::ExtensionDecl>
    priv var _indexed: bool = false
    /// This TU's spelling of the name the current lookup() is walking. See
    /// in_scope: a foreign scope's table cannot be probed with our imm.
    priv var _cur_spelling: string = ""

    // No _ext_by_shape index: `extend <T> [T]` now targets
    // record(Vector, [T]), so it keys on the Vector primary through
    // _ext_by_decl like any other generic extension on a record.

    fn MemberLookup(self) {
        self.sc = &null
    }

    fn MemberLookup(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    /// # Extension index

    /// Build the extension index over every TU the build knows. Cheap: one
    /// pass over top-level decls per fid, no expression walking. Idempotent.
    fn index_extensions(self) {
        if self._indexed {
            return
        }

        self._indexed = true
        if self.sc == &null || self.sc->g == &null {
            return
        }

        var fids = self.sc->g->all_fids()
        for var i: usize = 0; i < fids.size(); ++i {
            var unsafe *ctx = self.sc->g->get_context(fids[i])
            if ctx == &null {
                continue
            }

            var unsafe *tu = ctx->tu
            if tu == &null {
                continue
            }

            // A C++ header's TU holds no ExtensionDecl (only the parser makes
            // one), and its namespaces are most of the graph's decls: every
            // MemberLookup -- one per Substitution associated-type lookup --
            // walked them all.
            if tu->is_foreign {
                continue
            }

            // Nothing to find, and its lists may be mid-rewrite on another
            // pool worker (its own E or lowerings).
            if tu->no_extensions {
                continue
            }

            self._index_dc(tu, fids[i])
        }
    }

    // Not a race (P850): index_extensions reaches only TUs with
    // no_extensions false, i.e. serial (barrier) groups, which run alone
    // after every front in flight, and finished ones; a front's TU is
    // skipped above. This is the extension index only: a header TU's
    // tables can still grow under a fill on another thread (`_mu` only).
    priv fn _index_dc(self, dc: unsafe *DeclContext, fid: u32) {
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            self._index_decl(d, fid)
        }
    }

    priv fn _index_decl(self, d: unsafe *Decl, fid: u32) {
        if isa<Declarations::ExtensionDecl>(d) {
            var unsafe *e = cast<Declarations::ExtensionDecl>(d)
            if e->target == &null {
                return
            }

            if e->target->canonical == &null { // errored, or a TU whose T has not run.
                if self.sc != &null && !self.sc->sees_extension_file(fid) {
                    self._hidden_unresolved.push_back(e)
                }

                return
            }

            var unsafe *c = canon_unqual(e->target->canonical)
            // The filter is here, once, so every reader of the index (member
            // and operator lookup, conformance, Substitution's associated
            // types) follows the same visibility rule.
            var seen = self.sc == &null || extension_visible(self.sc, e, fid)
            if isa<RecordType>(c) {
                // Keyed by DECL: `extend <T> Vec<T>` contributes to every
                // Vec<X> at name level. RecordType::decl for a dependent
                // target is the primary (#12), which is the key we want.
                var key = (cast<RecordType>(c)->decl as usize as u64)
                if seen {
                    self._ext_by_decl[key].push_back(e)
                } else {
                    self._hidden_by_decl[key].push_back(e)
                }
            } else if seen {
                // `extend i32 { }`, `extend [u8] { }`: one exact canonical
                // (a nullable of a record: its primary, _type_key).
                self._ext_by_type[MemberLookup::_type_key(c)].push_back(e)
            } else {
                self._hidden_by_type[MemberLookup::_type_key(c)].push_back(e)
            }

            return
        }

        // Extensions may sit inside modules and visibility groups.
        if isa<Declarations::ModuleDecl>(d) {
            self._index_dc(unsafe (cast<Declarations::ModuleDecl>(d) as unsafe *DeclContext), fid)
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._index_decl(g->members[i], fid)
            }

            return
        }

        if isa<Declarations::EvalBlockDecl>(d) {
            var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
            for var i: usize = 0; i < b->body.size(); ++i {
                self._index_decl(b->body[i], fid)
            }

            return
        }
    }

    fn extensions_of_decl(self,
                          d: unsafe *Decl) -> unsafe *cxx::std::vector<unsafe *Declarations::ExtensionDecl> {
        self.index_extensions()
        var it = self._ext_by_decl.find(d as usize as u64)
        if it == self._ext_by_decl.end() {
            return &null
        }

        return unsafe &it->second
    }

    /// The _ext_by_type key of non-record canonical \p c: its address,
    /// except a nullable of a record (`[T]?`, `Box<i32>?`), which keys on
    /// the record's primary, tagged so it can meet no type's address (decls
    /// and types are both 8-aligned): `extend <T> [T]?` then reaches every
    /// `[X]?` at name level, as `extend <T> [T]` reaches every `[X]` through
    /// _ext_by_decl, and which instance runs is overload resolution's.
    static fn _type_key(c: unsafe *Type) -> u64 {
        if c != &null && isa<NullableType>(c) && cast<NullableType>(c)->inner != &null {
            var unsafe *inner = cast<NullableType>(c)->inner
            var unsafe *ic    = canon_unqual(if (inner->canonical != &null) => (inner->canonical) else => inner)
            if ic != &null && isa<RecordType>(ic) && cast<RecordType>(ic)->decl != &null {
                var unsafe *d = cast<RecordType>(ic)->decl
                if decl_is_instance(d) && decl_instantiated_from(d) != &null {
                    d = decl_instantiated_from(d)
                }

                return (d as usize as u64) + 1
            }
        }

        return c as usize as u64
    }

    fn extensions_of_type(self,
                          c: unsafe *Type) -> unsafe *cxx::std::vector<unsafe *Declarations::ExtensionDecl> {
        self.index_extensions()
        var it = self._ext_by_type.find(MemberLookup::_type_key(c))
        if it == self._ext_by_type.end() {
            return &null
        }

        return unsafe &it->second
    }

    /// An extension of \p c this TU does not see that declares \p name, or
    /// null: the lookup's miss is then "import it", not "no such member".
    fn hidden_extension(self, c_in: unsafe *Type, name: DeclName) -> unsafe *Declarations::ExtensionDecl {
        self.index_extensions()
        var unsafe *c = canon_unqual(c_in)
        if c == &null {
            return &null
        }

        var key = MemberLookup::_type_key(c)
        var hit = self._hidden_by_type.find(key)
        var end = self._hidden_by_type.end()
        if isa<RecordType>(c) {
            var unsafe *d = cast<RecordType>(c)->decl
            if d != &null && decl_is_instance(d) && decl_instantiated_from(d) != &null {
                d = decl_instantiated_from(d)
            }

            key = d as usize as u64
            hit = self._hidden_by_decl.find(key)
            end = self._hidden_by_decl.end()
        }

        var spelled = self._spell(name)
        if hit != end {
            for var i: usize = 0; i < hit->second.size(); ++i {
                var unsafe *e = hit->second[i]
                if self.in_scope(unsafe (e as unsafe *DeclContext), name, spelled) != &null {
                    return e
                }
            }
        }

        if !isa<RecordType>(c) || self._hidden_unresolved.size() == 0 {
            return &null
        }

        var unsafe *rd = cast<RecordType>(c)->decl
        var unsafe *rc = NameLookup::ctx_of(rd)
        if rc == &null {
            return &null
        }

        var leaf = rc->get_spelling(decl_name_tok(rd))
        for var i: usize = 0; i < self._hidden_unresolved.size(); ++i {
            var unsafe *e  = self._hidden_unresolved[i]
            var unsafe *ec = NameLookup::ctx_of(unsafe (e as unsafe *Decl))
            if ec == &null || e->target == &null {
                continue
            }

            if type_spelling_leaf(ec->get_spelling(e->target->range)) != leaf {
                continue
            }

            if self.in_scope(unsafe (e as unsafe *DeclContext), name, spelled) != &null {
                return e
            }
        }

        return &null
    }

    /// The members named \p name of the extension hidden_extension finds
    /// for \p c, appended to \p out: what ConformanceChecking matches a
    /// requirement against when lookup (which skips that extension) found
    /// no witness, so the miss says "import it" rather than "no member".
    fn hidden_extension_members(self,
                                c:    unsafe *Type,
                                name: DeclName,
                                out:  unsafe *cxx::std::vector<unsafe *Decl>) {
        var unsafe *e = self.hidden_extension(c, name)
        if e == &null || out == &null {
            return
        }

        var unsafe *cell = self.in_scope(unsafe (e as unsafe *DeclContext), name, self._spell(name))
        if cell == &null {
            return
        }

        for var i: usize = 0; i < cell->size(); ++i {
            out->push_back(cell->get(i))
        }
    }

    /// # The lookup

    /// Every decl named \p name reachable from canonical type \p c: own
    /// members, extension members, base members (transitively, deduped).
    /// Appends to \p out in walk order: own first, extensions, then bases
    /// breadth-first -- the order overload resolution and diagnostics want.
    /// \return true if anything was found. A const vector has vector's
    /// members; which of them may be called on a const object is
    /// ConstChecking's.
    fn lookup(self,
              c_in: unsafe *Type,
              name: DeclName,
              out:  unsafe *cxx::std::vector<unsafe *Decl>) -> bool {
        var unsafe *c = canon_unqual(c_in)
        if c == &null {
            return false
        }

        var before = out->size()

        // Spelled once per lookup, not once per scope: the walk can cross into
        // several TUs (a base class in one file, an extension in another) and
        // each of their tables is keyed by its own imms.
        self._cur_spelling = self._spell(name)

        if isa<RecordType>(c) {
            var seen = llvm::DenseSet<u64>() // decl addresses: never the reserved ~0 / ~0-1 keys
            // A dependent `Store<*P>` whose pattern a partial specialization
            // matches has that partial's members, not the primary's (an
            // instance carries the same choice; 2b below).
            var unsafe *root = cast<RecordType>(c)->decl
            if root != &null && !decl_is_instance(root) && self.sc != &null {
                var unsafe *b = self.sc->record_body(c)
                if b != &null {
                    root = b
                }
            }

            self._walk_record(root, name, out, unsafe &seen)
        } else {
            var unsafe *exts = self.extensions_of_type(c)
            if exts != &null {
                self._append_from_extensions(*exts, name, out)
            }
        }

        return out->size() > before
    }

    /// # Single-scope lookup, correct across TUs

    /// Look one identifier up in ONE scope, whichever TU that scope lives in.
    ///
    /// A DeclContext's table is keyed by ITS OWN TU's imms (hard invariant
    /// #2), so probing a foreign scope with this TU's imm index is not a miss
    /// -- it is a silent WRONG answer whenever the two interners happen to
    /// agree on an index. `spelling` is the escape hatch: for a foreign scope
    /// the name is re-interned into that TU's imm space and probed there.
    fn in_scope(self,
                dc:             unsafe *DeclContext,
                name:           DeclName,
                const spelling: string) -> unsafe *OverloadCell {
        if dc == &null {
            return &null
        }

        // Only IDENTIFIER payloads are per-TU. Operator and ctor keys are
        // built from TokenKinds, which are stable across the build.
        if name.kind != DeclNameKind::Identifier {
            return dc->lookup_symbol(name)
        }

        if spelling.size() == 0 {
            return dc->lookup_symbol(name)
        }

        var unsafe *tu = NameLookup::tu_of(dc)
        if tu == &null || tu == self.sc->tu {
            return dc->lookup_symbol(name)
        }

        var unsafe *imms = self.sc->ctx->tcm->get_imm_table_for_fid(tu->fid)
        if imms == &null {
            return &null
        }

        return SymbolTable::lookup_foreign(dc->dc_symbols, imms, spelling)
    }

    /// This TU's spelling of an identifier DeclName, for re-interning into a
    /// foreign scope's imm space. Empty for a non-identifier key, which needs
    /// no translation.
    priv fn _spell(self, name: DeclName) -> string {
        if name.kind != DeclNameKind::Identifier {
            return ""
        }

        var unsafe *imms = self.sc->ctx->get_imm_table()
        if imms == &null {
            return ""
        }

        return imms->get_ident(name.payload)
    }

    /// The names a module RE-EXPORTS, for a `mod::name` step that missed in
    /// the module's own table.
    ///
    /// A file's `pub import bar` is part of its surface (Compiler/Spec/Pipeline.md#sema-pass-order,
    /// two walls), but a re-exported name lives in the source TU's OVERLAY,
    /// not in its symbol table -- and a plain `import foo` in a third file
    /// binds foo's ModuleDecl, whose shared table is exactly that symbol
    /// table. So `foo::f` has to ask foo's overlay, which is what this does.
    ///
    /// Returns null unless some target under that key came in through a
    /// pub/prot import; a PRIVATE import edge in the source is never surface
    /// (wall 1).
    fn reexport_lookup(self,
                       scope:          unsafe *DeclContext,
                       const spelling: string) -> unsafe *OverloadCell {
        if scope == &null {
            return &null
        }

        var unsafe *tu = NameLookup::tu_of(scope)
        if tu == &null {
            return &null
        }

        if tu->import_overlay == &null {
            return &null
        }

        var unsafe *imms = self.sc->ctx->tcm->get_imm_table_for_fid(tu->fid)
        if imms == &null {
            return &null
        }

        var key = imms->find_ident(spelling) // probe only; never intern.
        if key == u32::MAX {
            return &null
        }

        var unsafe *entry = tu->import_overlay->entry(key)
        if entry == &null {
            return &null
        }

        var surface = false
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var unsafe *o = dyn_cast<Declarations::ImportDecl>(entry->targets[i].origin)
            if o == &null {
                continue
            }

            if o->is_public() || o->is_protected() {
                surface = true
                break
            }
        }

        if !surface {
            return &null
        }

        return tu->import_overlay->lookup_ident(key)
    }

    /// Own table -> extensions -> bases. `seen` dedups the DAG so a virtual
    /// base reached twice contributes once.
    priv fn _walk_record(self,
                         d:    unsafe *Decl,
                         name: DeclName,
                         out:  unsafe *cxx::std::vector<unsafe *Decl>,
                         seen: unsafe *llvm::DenseSet<u64>) {
        if d == &null {
            return
        }

        var key = (d as usize as u64)
        if !seen->insert(key).second {
            return
        }

        // 0. An instance of an IMPORTED template has an empty table until
        //    clang fills it. Fill BEFORE step 1 reads that table -- at 2b the
        //    first lookup through a fresh instance would miss every member it
        //    was about to get. A failed fill leaves it unfilled, and 2b walks
        //    the pattern exactly as before fills existed.
        MemberLookup::ensure_filled(self.sc, d)

        // An interface's members are its COMPOSED requirement list
        // (InterfaceComposition): own and derived, deduplicated, `-` and `&`
        // applied. Not its table plus a walk of its derives edges -- that
        // would answer `X - Y` with Y's members too.
        var unsafe *cid = dyn_cast<Declarations::InterfaceDecl>(d)
        if cid != &null && cid->compose_state == 2 {
            for var i: usize = 0; i < cid->requirements.size(); ++i {
                var unsafe *rd = cid->requirements.get(i)->decl
                if !self._names(rd, name) {
                    continue
                }

                var dup = false
                for var j: usize = 0; j < out->size(); ++j {
                    if (*out)[j] == rd {
                        dup = true
                        break
                    }
                }

                if !dup {
                    out->push_back(rd)
                }
            }

            return
        }

        // 1. own table. Unlike C++, an anonymous union field's members are
        //    not injected here and never found by name: only compiler-minted
        //    field_of chains reach them, carrying the member FieldDecl
        //    itself (see FieldDecl::is_anonymous_union).
        var unsafe *dc        = NameLookup::context_of(d)
        var        own_hit    = false
        var        before_own = out->size()
        if dc != &null {
            var unsafe *cell = self.in_scope(dc, name, self._cur_spelling)
            if cell != &null {
                self._append_cell(cell, &*out)
                own_hit = cell->size() > 0
            }
        }

        // 2. extensions on this exact decl, and on the PRIMARY this decl is
        //    an instance of: `extend <T> Vec<T>` contributes to `Vec<i32>`
        //    whether that instance is implicit or a user-written spec (#12).
        var unsafe *exts = self.extensions_of_decl(d)
        if exts != &null {
            self._append_from_extensions(*exts, name, out)
        }

        var unsafe *pat = decl_instantiated_from(d)
        if pat != &null && pat != d {
            var unsafe *pexts = self.extensions_of_decl(pat)
            if pexts != &null {
                self._append_from_extensions(*pexts, name, out)
            }

            // 2b. An implicit instantiation nobody has filled (M2, or clang
            //     via step 0) has an empty table and an empty base list. The
            //     names it WILL have are the pattern's: walk that instead
            //     (seen dedups).
            //     The pattern is the partial specialization the registry
            //     selected for these args, when one was.
            if MemberLookup::unfilled(d) {
                var unsafe *body = if (self.sc != &null) => (self.sc->body_of(d)) else => pat
                self._walk_record(body, name, out, seen)
                return
            }
        }

        // 3. bases. NOT the interfaces an `impl` clause names: an interface
        //    has no default bodies (interfaces.md), so each requirement is
        //    met by a member this walk already finds (own, extension or
        //    base), and the bodiless requirement beside it made every direct
        //    call `x.f()` an SC064E tie between the two. A bounded receiver
        //    reaches requirements through its bounds, not through here.
        //
        //    An IMPORTED class is C++'s, and so is its lookup: a name its own
        //    table answers HIDES the bases' ([class.member.lookup]). Merged,
        //    `d.h(x)` with `int B::h(int)` beside `double D::h(double)` bound
        //    B's, while the emitted `d.h(x)` called D's -- the result typed
        //    i32 and computed as a converted double. A Kairo class cannot
        //    hide (InterfaceEmitter writes a `using` for every shared name
        //    instead), and neither does a name the header's class merges
        //    with a `using B::g;` (ClassDecl::ffi_usings). An operator hides
        //    the same way ([over.match.oper]/3.1: the member candidates are
        //    the QUALIFIED lookup of operator@ in the class, so a derived
        //    `operator*` hides the base's -- llvm::iterator_adaptor_base's
        //    beside DeclTemplate.h's SpecIterator::operator* was SC064E).
        //    An operator has no spelling, so a `using B::operator@;` anywhere
        //    in the class keeps all of its operators merged.
        if own_hit
            && decl_is_imported(d)
            && isa<Declarations::ClassDecl>(d)
            && (self._cur_spelling.size() > 0 || name.is_op()) {
            var merged = false
            var *us    = &cast<Declarations::ClassDecl>(d)->ffi_usings
            var want   = if (!name.is_op()) => (self._cur_spelling) else => "operator"
            for var i: usize = 0; i < us->size(); ++i {
                if (*us)[i] == want {
                    merged = true
                    break
                }
            }

            if !merged {
                return
            }
        }

        // A FIELD (or nested type) the class declares hides a base's of the
        // same name, as in C++: there is no `using` that could merge two
        // fields, and the emitted class hides it the same way. Only an
        // overload set merges. Walking on, `self.ctx` in a visitor deriving
        // RecursiveASTVisitor (both declare `ctx`) was R028E ambiguous.
        if own_hit {
            var all_fields = true
            for var i: usize = before_own; i < out->size(); ++i {
                if isa<Declarations::FunctionDecl>((*out)[i]) {
                    all_fields = false
                    break
                }
            }

            if all_fields {
                return
            }
        }

        if isa<Declarations::ClassDecl>(d) {
            var unsafe *cd = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < cd->derives_list.size(); ++i {
                self._walk_edge(cd->derives_list.get(i), name, out, seen)
            }

            return
        }

        if isa<Declarations::StructDecl>(d) {
            return
        }

        if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *id = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < id->derives_list.size(); ++i {
                self._walk_edge(id->derives_list.get(i), name, out, seen)
            }

            return
        }

        // UnionDecl / EnumDecl: no bases.
    }

    /// An instance whose table is still empty. `instantiated` is the one
    /// answer for both fillers: M2 sets it for a Kairo pattern,
    /// ForeignInstantiate for an imported one. It must not be short-circuited
    /// by filled_by_clang (which is true for the instance's whole life): a
    /// filled foreign instance walking its pattern would see the pattern's
    /// dependent spellings -- `size_type` unresolved -- instead of clang's.
    /// Public because TypeResolve asks the same question of a `::` head.
    static fn unfilled(d: unsafe *Decl) -> bool {
        return decl_is_instance(d) && !decl_instantiated(d)
    }

    /// THE fill trigger: if \p d is an unfilled shell of an imported
    /// template, have clang fill it now. Both readers of a shell's table
    /// call this before reading it -- member lookup (`c.size`) and
    /// TypeResolve's `::` step (`traits<alloc>::size_type`) -- so neither
    /// can miss a member the other would have filled in. A failed fill is
    /// sticky (one no set tried could spell is retried for another TU's
    /// set) and leaves \p d unfilled; callers fall back exactly as they did
    /// before fills existed. True when \p d's own table is readable.
    static fn ensure_filled(sc: unsafe *SemaContext, d: unsafe *Decl) -> bool {
        if !MemberLookup::unfilled(d) {
            return true
        }

        if !MemberLookup::filled_by_clang(d) { // M2's, not clang's.
            return false
        }

        if sc == &null || sc->foreign == &null {
            return false
        }

        var fid: i64 = -1
        if sc->ctx != &null {
            fid = (sc->ctx->fid)
        }

        // The demanding TU's own set: the fill's fallback when the primary
        // is another set's that cannot see every argument's header.
        var alt: unsafe *HeaderSet = &null
        if sc->tu != &null && sc->tu->header_set != &null {
            alt = unsafe (sc->tu->header_set as unsafe *HeaderSet)
        }

        return sc->foreign->fill(d, sc->diag, fid, alt)
    }

    /// True when \p d is an instance whose primary came from a C++ header --
    /// before AND after it is filled. Such an instance is clang's: M2 must
    /// SKIP it, and its members come from ForeignInstantiate::fill (clang's
    /// own instantiation, imported), not from substituting into the pattern.
    /// Public because M2 is the other reader.
    static fn filled_by_clang(d: unsafe *Decl) -> bool {
        return decl_is_instance(d) && decl_is_imported(decl_instantiated_from(d))
    }

    static fn primary_is_imported(p: unsafe *Decl) -> bool {
        return decl_is_imported(p)
    }

    /// # ADL

    /// The scopes argument-dependent lookup searches for a value of type \p t:
    /// every module enclosing the record's declaration, innermost first, up to
    /// (excluding) its TU, then the same for each generic argument. Pointers,
    /// references and nullables peel to what they refer to: C++ associates
    /// `T*` and `T&` with T's namespaces, and `op <<` on `std::ostream&` is
    /// the case this exists for. A C++ namespace imported by Sema/Foreign is
    /// a ModuleDecl, so `std` lands here exactly as a Kairo `module` does.
    ///
    /// Appends only scopes not already in \p out, so callers accumulate over
    /// every operand / argument into one list.
    fn associated_scopes(self,
                         t:   unsafe *Type,
                         out: unsafe *cxx::std::vector<unsafe *DeclContext>) {
        // Deduped through a set seeded with what \p out already holds: a
        // type in `std` brings every reopening of the namespace (hundreds,
        // one ModuleDecl per header), and the linear _has_dc made each call
        // quadratic in them. Same scopes, same order.
        var seen = llvm::DenseSet<u64>()
        for var i: usize = 0; i < out->size(); ++i {
            seen.insert((*out)[i] as usize as u64)
        }

        self._associated_scopes(t, out, unsafe &seen)
    }

    priv fn _associated_scopes(self,
                               t:    unsafe *Type,
                               out:  unsafe *cxx::std::vector<unsafe *DeclContext>,
                               seen: unsafe *llvm::DenseSet<u64>) {
        var unsafe *c = self._peel(t)
        if c == &null || !isa<RecordType>(c) {
            return
        }

        var unsafe *rt = cast<RecordType>(c)
        self._enclosing_modules(rt->decl, &*out, seen)
        for var i: usize = 0; i < rt->args.size(); ++i {
            self._associated_scopes(rt->args[i], out, seen)
        }
    }

    /// The FILE scope a value's record type was declared in, for OPERATOR
    /// lookup only. _enclosing_modules stops at the TU on purpose: every free
    /// function in the declaring file would otherwise be an ADL candidate
    /// wherever the type is used. An operator is the one thing a file declares
    /// FOR its types, and without this a free `op *` beside a file-scope type
    /// is unreachable from every file, its own included.
    fn declaring_scope(self, t: unsafe *Type, out: unsafe *cxx::std::vector<unsafe *DeclContext>) {
        var unsafe *c = self._peel(t)
        if c == &null || !isa<RecordType>(c) {
            return
        }

        var unsafe *d = cast<RecordType>(c)->decl
        if d == &null {
            return
        }

        if d->semantic_dc == &null {
            var unsafe *p = decl_instantiated_from(d)
            if p != &null {
                d = p
            }
        }

        var unsafe *tu = NameLookup::tu_of(d->semantic_dc)
        if tu == &null {
            return
        }

        var unsafe *dc = unsafe (tu as unsafe *DeclContext)
        if !self._has_dc(*out, dc) {
            out->push_back(dc)
        }
    }

    /// Functions named \p name in each of \p scopes, minus anything already in
    /// \p skip (member lookup's answer) or \p out: the ADL half of an operator
    /// or unqualified-call candidate set. A decl reached two ways is one
    /// candidate, the same identity rule as _append_cell.
    fn adl_candidates(self,
                      scopes:         unsafe *cxx::std::vector<unsafe *DeclContext>,
                      name:           DeclName,
                      const spelling: string,
                      skip:           unsafe *cxx::std::vector<unsafe *Decl>,
                      out:            unsafe *cxx::std::vector<unsafe *Decl>) {
        for var s: usize = 0; s < scopes->size(); ++s {
            var unsafe *cell = self.in_scope((*scopes)[s], name, spelling)
            if cell == &null {
                continue
            }

            for var i: usize = 0; i < cell->size(); ++i {
                var unsafe *d = cell->get(i)
                if d == &null || !isa<Declarations::FunctionDecl>(d) {
                    continue
                }

                if self._has(skip, d) || self._has(out, d) {
                    continue
                }

                out->push_back(d)
            }
        }
    }

    /// A C++ reference names its referee, and a qualifier names the same
    /// object: neither has members of its own. Loops, so `const T&`
    /// (cxx_lref(qualified(CONST, T))) peels to T in one call. Separate
    /// from _peel because the member step must NOT peel pointers or
    /// nullables -- those belong to the separator (`.` vs `->`, `?.`).
    fn peel_ref(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = t
        while c != &null {
            if isa<CXXLValueRefType>(c) {
                c = cast<CXXLValueRefType>(c)->referee
                continue
            }

            if isa<CXXRValueRefType>(c) {
                c = cast<CXXRValueRefType>(c)->referee
                continue
            }

            if isa<QualifiedType>(c) {
                c = cast<QualifiedType>(c)->inner
                continue
            }

            break
        }

        return c
    }

    priv fn _peel(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = t
        while c != &null {
            if isa<PointerType>(c) {
                c = cast<PointerType>(c)->pointee
                continue
            }

            if isa<NullableType>(c) {
                c = cast<NullableType>(c)->inner
                continue
            }

            var unsafe *r = self.peel_ref(c)
            if r != c {
                c = r
                continue
            }

            break
        }

        return c
    }

    /// Stops AT the TU: a Kairo file's top level is its own module_self, so
    /// adding it would make every free function in the declaring file an ADL
    /// candidate everywhere the type is used. Consequence for C++: a type in
    /// the global namespace associates no scope, so a global `operator<<` for
    /// it is not found this way.
    priv fn _enclosing_modules(self,
                               d:          unsafe *Decl,
                               @inout out: cxx::std::vector<unsafe *DeclContext>,
                               seen:       unsafe *llvm::DenseSet<u64>) {
        if d == &null {
            return
        }

        var unsafe *src = d
        // An implicit instance may not carry a semantic_dc of its own; its
        // primary's is the answer either way.
        if src->semantic_dc == &null {
            var unsafe *p = decl_instantiated_from(d)
            if p != &null {
                src = p
            }
        }

        var unsafe *dc = src->semantic_dc
        while dc != &null {
            if dc->dc_kind == DeclContextKind::TranslationUnit {
                return
            }

            if dc->dc_kind == DeclContextKind::Module {
                if seen->insert(dc as usize as u64).second {
                    out.push_back(dc)
                }

                // The namespace, not the one block of it the record sits in:
                // C++ searches every reopening. Sema/Foreign gives each
                // header's `namespace std { }` its own ModuleDecl, and libc++
                // forward-declares __wrap_iter in <__iterator/iterator_traits.h>
                // but declares its operators in <__iterator/wrap_iter.h>, so
                // the record's own block never held a `==` to find.
                var scopes = cxx::std::vector<unsafe *DeclContext>()
                NameLookup::module_scopes(dc->owner_decl(), &scopes)
                for var i: usize = 0; i < scopes.size(); ++i {
                    if seen->insert(scopes[i] as usize as u64).second {
                        out.push_back(scopes[i])
                    }
                }
            }

            dc = dc->parent_context()
        }
    }

    priv fn _has(self, v: unsafe *cxx::std::vector<unsafe *Decl>, d: unsafe *Decl) -> bool {
        if v == &null {
            return false
        }

        for var i: usize = 0; i < v->size(); ++i {
            if (*v)[i] == d {
                return true
            }
        }

        return false
    }

    priv fn _has_dc(self,
                    const v: cxx::std::vector<unsafe *DeclContext>,
                    dc:      unsafe *DeclContext) -> bool {
        for var i: usize = 0; i < v.size(); ++i {
            if (v)[i] == dc {
                return true
            }
        }

        return false
    }

    priv fn _walk_edge(self,
                       e:    unsafe *Declarations::InheritEdge,
                       name: DeclName,
                       out:  unsafe *cxx::std::vector<unsafe *Decl>,
                       seen: unsafe *llvm::DenseSet<u64>) {
        if e == &null || e->base == &null {
            return
        }

        var unsafe *c = canon_unqual(e->base->canonical)
        if c == &null { // dependent base: M2's problem.
            return
        }

        if !isa<RecordType>(c) { // ConformanceChecking diagnoses.
            return
        }

        self._walk_record(cast<RecordType>(c)->decl, name, out, seen)
    }

    priv fn _append_from_extensions(
        self,
        const exts: cxx::std::vector<unsafe *Declarations::ExtensionDecl>,
        name:       DeclName,
        out:        unsafe *cxx::std::vector<unsafe *Decl>,
    ) {
        for var i: usize = 0; i < exts.size(); ++i {
            var unsafe *e    = (exts)[i]
            var unsafe *dc   = unsafe (e as unsafe *DeclContext)
            var unsafe *cell = self.in_scope(dc, name, self._cur_spelling)
            if cell != &null {
                self._append_cell(cell, &*out)
            }
        }
    }

    /// Append every decl of a cell, skipping duplicates by identity (a decl
    /// reached through two paths is one candidate).
    /// Requirement \p d is named \p name. The requirement may be another
    /// TU's, so an identifier compares by this lookup's spelling, not imm.
    priv fn _names(self, d: unsafe *Decl, name: DeclName) -> bool {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f != &null && f->is_operator {
            if name.kind != DeclNameKind::Operator {
                return false
            }

            var k0 = TokenKind::TkUnknown
            var k1 = TokenKind::TkUnknown
            if f->op_token.size() > 0 {
                k0 = f->op_token[0].kind
            }

            if f->op_token.size() > 1 {
                k1 = f->op_token[1].kind
            }

            return DeclName::op_name(k0, k1).as_key() == name.as_key()
        }

        if name.kind != DeclNameKind::Identifier {
            return false
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            return false
        }

        return ctx->get_spelling(decl_name_tok(d)) == self._cur_spelling
    }

    priv fn _append_cell(self,
                         cell:       unsafe *OverloadCell,
                         @inout out: cxx::std::vector<unsafe *Decl>) {
        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if d == &null {
                continue
            }

            var dup = false
            for var j: usize = 0; j < out.size(); ++j {
                if (out)[j] == d {
                    dup = true
                    break
                }
            }

            if !dup {
                out.push_back(d)
            }
        }
    }

    /// ## unqualified member types (the `Self::` readability lint)
    ///
    /// classes.md "Members always need a qualifier": a nested type, type alias
    /// or associated type of the enclosing type MAY be named bare inside its
    /// body (`Node` means `Self::Node`), the one exception to the qualifier
    /// rule. It stays legal; it is warned, because at the use nothing says
    /// the name is a member and not something from the module. N reports the
    /// expression position (`Node { .. }`, `Node::make()`), T the type
    /// position; each reaches a use once, so each use is warned once.

    /// \p d, the decl a BARE name resolved to, is a member type of \p owner
    /// (the record `Self` denotes at the use). Only the innermost Self: a
    /// sibling of an enclosing type, seen from inside a nested one, is not a
    /// member of Self, and `Self::` would name the wrong scope; nor is a
    /// type's own name, which answers from the scope around it. Nested
    /// modules are scopes too but are not warned: `Self::` reads as a type,
    /// and a module is not one.
    static fn is_member_type_of(d: unsafe *Decl, owner: unsafe *Decl) -> bool {
        if d == &null || owner == &null {
            return false
        }

        var kind_ok = isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::EnumDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::InterfaceDecl>(d)
            || isa<Declarations::TypeAliasDecl>(d)
        if !kind_ok {
            return false
        }

        if d->semantic_dc == &null {
            return false
        }

        var unsafe *home = (d->semantic_dc)->owner_decl()
        if home == &null {
            return false
        }

        var unsafe *a = NameLookup::representative(home)
        var unsafe *b = NameLookup::representative(owner)
        return a == b
    }

    /// SC001W at \p at, the bare spelling of member type \p d of \p owner:
    /// a note at its name, and the fix-it that writes `Self::`.
    static fn warn_unqualified_member_type(sc:    unsafe *SemaContext,
                                           at:    SourceRange,
                                           d:     unsafe *Decl,
                                           owner: unsafe *Decl) {
        if !at.is_valid() {
            return
        }

        var unsafe *dctx = NameLookup::ctx_of(d)
        var unsafe *octx = NameLookup::ctx_of(owner)
        if dctx == &null {
            dctx = sc->ctx
        }

        if octx == &null {
            octx = sc->ctx
        }

        var tok  = decl_name_tok(d)
        var otok = decl_name_tok(owner)
        if tok.kind == TokenKind::TkUnknown || otok.kind == TokenKind::TkUnknown {
            return
        }

        var nm = dctx->get_spelling(tok)
        var on = octx->get_spelling(otok)

        var        what = "nested type"
        var unsafe *ta  = dyn_cast<Declarations::TypeAliasDecl>(d)
        if ta != &null {
            what = "type alias"
            if ta->is_associated {
                what = "associated type"
            }
        }

        var b = sc->diag->report(
            DiagID::SC243W,
            at.start,
            f"{what} '{nm}' of '{on}' is named without a qualifier; write 'Self::{nm}' so it reads as a member",
        )

        b.first(at)
        if tok.range.is_valid() {
            b.note(
                DiagCode(DiagID::SC243N),
                tok.range.start,
                f"'{nm}' is declared here, in '{on}'",
            )->first(tok.range)
        }

        b.insert(at.start, "Self::", f"qualify with 'Self::'")
        b.emit()
    }

    /// The R016E C++ defers to the use: \p imm, found through the overlay of
    /// \p found_in's TU, names an entry I marked `lazy` (every colliding
    /// entity came from a header, ImportResolution::_add). Reports at \p at
    /// with one note per candidate and returns true. An entry I already
    /// reported at a Kairo import returns true without a second report (the
    /// caller poisons the use); false, silently, for every other entry. N
    /// calls it for expression heads, T for type names.
    static fn report_lazy_ambiguity(sc:       unsafe *SemaContext,
                                    found_in: unsafe *DeclContext,
                                    imm:      u32,
                                    const nm: string,
                                    at:       SourceRange) -> bool {
        var unsafe *tu = NameLookup::tu_of(found_in)
        if tu == &null || tu->import_overlay == &null {
            return false
        }

        var unsafe *entry = tu->import_overlay->entry(imm)
        if entry == &null || !entry->is_ambiguous() {
            return false
        }

        // A collision a Kairo import took part in was reported once, at that
        // import (ImportResolution::_add), and I let the TU go on because
        // every use lands here: poison it, quietly. Binding the merged
        // cell's stand-in would type the use as a guess.
        if !entry->lazy {
            return entry->reported
        }

        var b = sc->diag->report(
            DiagID::R016E,
            at.start,
            f"ambiguous import: '{nm}' names more than one non-function symbol",
        )

        b.first(at)
        var seen = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < entry->targets.size(); ++i {
            var t = entry->targets[i]
            if t.kind != OverlayTargetKind::Type {
                continue
            }

            if t.hidden || t.decl == &null {
                continue
            }

            var dup = false
            for var j: usize = 0; j < seen.size(); ++j {
                if seen[j] == t.decl {
                    dup = true
                    break
                }
            }

            if dup {
                continue
            }

            seen.push_back(t.decl)
            var what = MemberLookup::kind_word(t.decl)
            b.note(
                DiagCode(DiagID::R016N),
                t.decl->range.start,
                f"'{nm}' could be the {what} declared here",
            )->first(t.decl->range)
        }

        b.emit()
        return true
    }

    /// The word a note uses for \p d's kind ("class", "typedef", ...).
    pub static fn kind_word(d: unsafe *Decl) -> string {
        if isa<Declarations::VariableDecl>(d) {
            return "variable"
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return "typedef"
        }

        if isa<Declarations::EnumVariantDecl>(d) {
            return "enumerator"
        }

        if isa<Declarations::StructDecl>(d) {
            return "struct"
        }

        if isa<Declarations::ClassDecl>(d) {
            return "class"
        }

        if isa<Declarations::UnionDecl>(d) {
            return "union"
        }

        if isa<Declarations::EnumDecl>(d) {
            return "enum"
        }

        if isa<Declarations::ModuleDecl>(d) {
            return "namespace"
        }

        if isa<Declarations::FunctionDecl>(d) {
            return "function"
        }

        return "declaration"
    }
}
