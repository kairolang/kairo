/// --- The Kairo Project --------------- Sema/Foreign/ForeignRegistry.k --- ///
///
///   \brief Build-wide USR -> Kairo Decl. THE identity for imported entities.
///
///   `c1.h`'s `struct Foo` reached through two different header sets is two
///   clang decls in two ASTContexts and ONE Kairo decl. Every cross-decl
///   reference DeclImport/TypeImport makes (a base, a member's type, a
///   template's primary) goes through here, never through a clang pointer,
///   so a set indexed second finds what the first one made.
///
///   Locked: index() is driver-thread only today, but M2 will resolve
///   clang decls back to Kairo decls from wherever it runs. Every map is
///   private and every accessor takes `_mu` itself (shared to read), so a
///   reader needs no `_fill_locked` around it: note_spec under a fill and
///   spec_of / find from any Sema thread are ordered by `_mu` alone. A leaf
///   lock: nothing below takes another.
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
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/StringSet.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::LangItems::{
    WellKnownDecls,
    WellKnownType,
}
import AST::Node::Base::Decl
import AST::Node::Declarations::ModuleDecl

pub class ForeignRegistry {
    /// StringMap, not a map over std::string: it owns the key bytes in the
    /// entry, hashes once, and is probed with the StringRef clang already
    /// hands back -- a lookup allocates nothing.
    priv var _by_usr:  llvm::StringMap<unsafe *Decl>
    priv var _mu:      kairo::std::SharedMutex
    priv var _spec_of: llvm::DenseMap<unsafe *Decl, unsafe *void> ///< see note_spec().
    priv var _ns_head: llvm::StringMap<unsafe *ModuleDecl>        ///< see link_namespace().
    /// opaque type -> flat (ASTContext, QualType opaque ptr) pairs; see note_opaque_qt().
    priv var _opaque_qt: llvm::DenseMap<unsafe *void, cxx::std::vector<unsafe *void>>

    /// The build's lang items, for the one Kairo type both directions of the
    /// mapping treat specially: `T?`, which is `::builtin::Nullable<T>` to
    /// C++ (nullable_lang). Null until the driver binds it; a `T?` argument
    /// then has no phase-A spelling, as before.
    pub var  well_known: unsafe *WellKnownDecls                 = &null
    priv var _orphans:   llvm::StringSet<llvm::MallocAllocator> ///< see forget() and adopt().
    pub var  adopted:    cxx::std::vector<unsafe *Decl>

    fn ForeignRegistry(self) {
        self._by_usr = llvm::StringMap<unsafe *Decl>(4096)
    }

    /// The Nullable lang item's decl, or null (no builtin root, or not bound
    /// yet). Read at every use rather than cached: the lang items are bound
    /// once the builtin root has resolved, which may be after the driver
    /// wired this registry.
    fn nullable_lang(self) -> unsafe *Decl {
        if self.well_known == &null {
            return &null
        }

        return self.well_known->get(WellKnownType::Nullable)
    }

    fn find(self, usr: llvm::StringRef) -> unsafe *Decl {
        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._by_usr.find(usr)
        if it == self._by_usr.end() {
            return &null
        }

        return it->second
    }

    /// Insert if absent; returns the decl that IS registered afterwards
    /// (the existing one on a race or a second set).
    fn put(self, usr: llvm::StringRef, d: unsafe *Decl) -> unsafe *Decl {
        var lock = kairo::std::LockGuard(self._mu)
        // One probe: try_emplace leaves an existing entry alone.
        var r = self._by_usr.try_emplace(usr, d)
        return r.first->second
    }

    /// Link \p m, a fresh ModuleDecl for the C++ namespace \p qual, into
    /// the redeclaration ring of the first one minted for that namespace.
    ///
    /// DeclImport mints one ModuleDecl per (header, namespace) -- one table
    /// each, so a header's names stay in its own TU -- but C++ has ONE `std`
    /// however many headers reopen it, and argument-dependent lookup searches
    /// all of it. The ring is the shape a reopened Kairo `module` already has
    /// (NameLookup::module_scopes), so every reader that walks reopenings sees
    /// the whole namespace. Spliced under the lock: a fill can mint a
    /// namespace off the driver thread.
    /// Every USR with its declaration, for a live check's retraction
    /// (Sema/Incremental/Retract.k), which judges each and gives the dead
    /// ones back to forget().
    ///
    /// \note The USRs are VIEWS of the table's keys (a graph that uses C++
    ///       containers has hundreds of thousands, and copying them was
    ///       most of a retraction): valid until the table changes, which
    ///       forget() does.
    pub fn entries(self,
                   usrs:  unsafe *cxx::std::vector<llvm::StringRef>,
                   decls: unsafe *cxx::std::vector<unsafe *Decl>) {
        var rlock = kairo::std::SharedLock(self._mu)
        usrs->reserve(self._by_usr.size() as usize)
        decls->reserve(self._by_usr.size() as usize)
        for var it = self._by_usr.begin(); it != self._by_usr.end(); ++it {
            usrs->push_back(it->getKey())
            decls->push_back(it->second)
        }
    }

    /// Drops \p usrs, and what was noted about the shells \p shells: the
    /// next import or stand-in under one of those USRs registers afresh.
    ///
    /// \note \p usrs and \p orphans may be entries()'s views: each is read
    ///       before its own key is erased, never after.
    pub fn forget(self,
                  usrs:    unsafe *cxx::std::vector<llvm::StringRef>,
                  orphans: unsafe *cxx::std::vector<llvm::StringRef>,
                  shells:  unsafe *cxx::std::vector<unsafe *Decl>) {
        var lock = kairo::std::LockGuard(self._mu)
        // A stand-in whose Kairo declaration is being re-read stays
        // declared in the clang AST: the next declaration that asks for a
        // stand-in of that name adopts it (adopt).
        for var i: usize = 0; i < orphans->size(); ++i {
            self._orphans.insert((*orphans)[i])
            self._by_usr.erase((*orphans)[i])
        }

        for var i: usize = 0; i < usrs->size(); ++i {
            self._by_usr.erase((*usrs)[i])
        }

        for var i: usize = 0; i < shells->size(); ++i {
            self._spec_of.erase((*shells)[i])
        }
    }

    /// \brief \p usr is a stand-in this build declared for a Kairo
    ///        declaration that a live check has since re-read: \p d, the
    ///        declaration now asking under the same C++ name, takes it over.
    ///        False when \p usr is no such stand-in (a header's own type).
    ///
    /// \details The clang record keeps the layout it was defined with.
    ///          \c adopted lists what was taken over, so the caller can
    ///          refuse the result when a layout moved (FrontendAction::
    ///          refresh compares the interface hashes).
    pub fn adopt(self, usr: llvm::StringRef, d: unsafe *Decl) -> bool {
        var lock = kairo::std::LockGuard(self._mu)
        if !self._orphans.contains(usr) {
            return false
        }

        self._orphans.erase(usr)
        self._by_usr.try_emplace(usr, d)
        self.adopted.push_back(d)
        return true
    }

    fn link_namespace(self, qual: llvm::StringRef, m: unsafe *ModuleDecl) {
        if m == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        var r    = self._ns_head.try_emplace(qual, m)
        if r.second {
            return
        }

        if r.first->second != m {
            m->set_prev(r.first->second)
        }
    }

    fn size(self) -> usize {
        var rlock = kairo::std::SharedLock(self._mu)
        return (self._by_usr.size() as usize)
    }

    /// The clang specialization an instance shell was IMPORTED from, when
    /// TypeImport made the shell from one (`std::ostream` is
    /// `basic_ostream<char>`). A fill completes that decl rather than
    /// re-spelling the shell's Kairo args: the args are lossy -- C++ `char`
    /// and `signed char` both import as `i8`, and `i8` exports as
    /// `signed char` -- so a round trip can name a DIFFERENT specialization,
    /// one the header may not even allow (`basic_ostream<signed char,
    /// char_traits<char>>` trips libc++'s static_assert). First writer wins,
    /// as for put(). The decl belongs to one set's ASTContext; the reader
    /// checks that before using it.
    fn note_spec(self, shell: unsafe *Decl, spec: unsafe *void) {
        if shell == &null || spec == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        self._spec_of.try_emplace(shell, spec) // first one wins
    }

    fn spec_of(self, shell: unsafe *Decl) -> unsafe *void {
        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._spec_of.find(shell)
        if it == self._spec_of.end() {
            return &null
        }

        return it->second
    }

    /// The clang type \p opaque (an OpaqueFFIType) was imported from in the
    /// ASTContext \p cctx, so TypeExport can spell it back. An opaque
    /// has no Kairo shape to rebuild a clang type from, and before this
    /// `vector<__m128i>` never filled and `std::move(v)` of one never
    /// deduced. Per context: the opaque is build-wide (keyed by spelling),
    /// a clang type is not, and every set that imports the spelling records
    /// its own. First writer per context wins, as for note_spec().
    fn note_opaque_qt(self, opaque: unsafe *void, cctx: unsafe *void, qt: unsafe *void) {
        if opaque == &null || cctx == &null || qt == &null {
            return
        }

        var lock = kairo::std::LockGuard(self._mu)
        var r = self._opaque_qt.try_emplace(
            opaque,
            cxx::std::vector<unsafe *void>(),
        )

        var *row = &r.first->second
        for var i: usize = 0; i + 1 < row->size(); i += 2 {
            if (*row)[i] == cctx {
                return
            }
        }

        row->push_back(cctx)
        row->push_back(qt)
    }

    fn opaque_qt(self, opaque: unsafe *void, cctx: unsafe *void) -> unsafe *void {
        var rlock = kairo::std::SharedLock(self._mu)
        var it    = self._opaque_qt.find(opaque)
        if it == self._opaque_qt.end() {
            return &null
        }

        var *row = &it->second
        for var i: usize = 0; i + 1 < row->size(); i += 2 {
            if (*row)[i] == cctx {
                return (*row)[i + 1]
            }
        }

        return &null
    }
}
