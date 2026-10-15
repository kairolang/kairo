/// --- The Kairo Project ---------------- Sema/Foreign/ForeignRegistry.k --- ///
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
///   clang decls back to Kairo decls from wherever it runs.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h";
ffi "c++" import "llvm/ADT/StringRef.h";

import AST::Node::Base::*;
import AST::Node::Declarations::*;

class ForeignRegistry {
    /// StringMap, not a map over std::string: it owns the key bytes in the
    /// entry, hashes once, and is probed with the StringRef clang already
    /// hands back -- a lookup allocates nothing.
    priv var _by_usr: llvm::StringMap::<*Decl>;
    priv var _mu:     std::SharedMutex;
    priv var _spec_of: libcxx::unordered_map::<*Decl, *void>;   ///< see note_spec().
    priv var _ns_head: llvm::StringMap::<*ModuleDecl>;   ///< see link_namespace().

    fn ForeignRegistry(self) { self._by_usr = llvm::StringMap::<*Decl>(4096); }

    fn find(self, usr: llvm::StringRef) -> *Decl {
        var rlock = std::SharedLock(self._mu);
        var it = self._by_usr.find(usr);
        if it == self._by_usr.end() { return &null; }
        return it->second;
    }

    /// Insert if absent; returns the decl that IS registered afterwards
    /// (the existing one on a race or a second set).
    fn put(self, usr: llvm::StringRef, d: *Decl) -> *Decl {
        var lock = std::LockGuard(self._mu);
        // One probe: try_emplace leaves an existing entry alone.
        var r = self._by_usr.try_emplace(usr, d);
        return (r.first)->second;
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
    fn link_namespace(self, qual: llvm::StringRef, m: *ModuleDecl) {
        if m == &null { return; }
        var lock = std::LockGuard(self._mu);
        var r = self._ns_head.try_emplace(qual, m);
        if (r.second) { return; }
        if (r.first)->second != m { m->set_prev((r.first)->second); }
    }

    fn size(self) -> usize {
        var rlock = std::SharedLock(self._mu);
        return self._by_usr.size();
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
    fn note_spec(self, shell: *Decl, spec: *void) {
        if (shell == &null) || (spec == &null) { return; }
        var lock = std::LockGuard(self._mu);
        if self._spec_of.find(shell) != self._spec_of.end() { return; }
        self._spec_of.insert(libcxx::make_pair(shell, spec));
    }

    fn spec_of(self, shell: *Decl) -> *void {
        var rlock = std::SharedLock(self._mu);
        var it = self._spec_of.find(shell);
        if it == self._spec_of.end() { return &null; }
        return it->second;
    }
}