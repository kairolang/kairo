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

import AST::Node::Base::*;

class ForeignRegistry {
    priv var _by_usr: libcxx::unordered_map::<libcxx::string, *Decl>;
    priv var _mu:     std::SharedMutex;
    priv var _spec_of: libcxx::unordered_map::<*Decl, *void>;   ///< see note_spec().

    fn ForeignRegistry(self) { self._by_usr.reserve(4096); }

    fn find(self, usr: cref::<libcxx::string>) -> *Decl {
        var rlock = std::SharedLock(self._mu);
        var it = self._by_usr.find(usr);
        if it == self._by_usr.end() { return &null; }
        return it->second;
    }

    /// Insert if absent; returns the decl that IS registered afterwards
    /// (the existing one on a race or a second set).
    fn put(self, usr: cref::<libcxx::string>, d: *Decl) -> *Decl {
        var lock = std::LockGuard(self._mu);
        var it = self._by_usr.find(usr);
        if it != self._by_usr.end() { return it->second; }
        self._by_usr.insert(libcxx::make_pair(usr, d));
        return d;
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