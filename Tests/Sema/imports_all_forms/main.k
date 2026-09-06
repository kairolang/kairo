// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Every import form in IMPORTS.md §1, in one file, against one module.
//
// The point of the file is the diagnostic COUNT: exactly two errors, and both
// of them deliberate. Every other name below has to bind, and the SEMA half
// says which decl it bound to, so a form that silently stops resolving fails
// here rather than at codegen.
//
// Forms exercised, in declaration order:
//   1  plain              import foo
//   2  aliased plain      import foo as fmod
//   3  symbol path        import foo::MyClass
//   4  aliased symbol     import foo::add as my_add
//   5  selective          import foo::{inner, add as plus}
//   6  wildcard           import foo::*
//   3' symbol path, twice import u1::util / import u2::util  (reopened module)
//   9  ffi aliased        ffi "c++" import "stdio.h" as cstd
//
// Not exercised: `import module foo` (form 7) needs a foo/module.k directory
// module, which is a path-resolution property with no bearing on the lookup
// forms this file is about; and bare ffi (form 8), whose miss gate is its own
// test because it changes what an UNRELATED miss means.

import foo
import foo as fmod
import foo::MyClass
import foo::add as my_add
import foo::{inner, add as plus}
import foo::*
import u1::util
import u2::util
ffi "c++" import "stdio.h" as cstd

fn use_all() -> i32 {
    // Form 3: a symbol-path import names a TYPE, usable as one.
    var m: MyClass

    // Form 9: a step off an ffi anchor is Foreign -- clang resolves it, we
    // neither bind it nor complain about it.
    cstd::printf("hi")

    var a1 = foo::add(1, 2)      // 1: through the module handle
    var a2 = fmod::add(1, 2)     // 2: same module, under an alias
    var a3 = my_add(3, 4)        // 4: the aliased function itself
    var a4 = plus(5, 6)          // 5: a selective item, renamed
    var a5 = inner::g()          // 5: a selective item that is a module
    var a6 = add(7, 8)           // 6: wildcard-imported, unqualified
    var a7 = foo::f()            // re-export: foo's `pub import bar::*`
    var a8 = util::one()         // reopened module, half from u1
    var a9 = util::two()         // reopened module, half from u2
    var a10 = m.v

    // --- the two deliberate errors -------------------------------------
    var e1 = foo::h()            // baz is imported by foo PRIVATELY (wall 1)
    var e2 = foo::addd(1, 2)     // typo

    return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + e1 + e2
}

// --- diagnostics: exactly two, in source order ---------------------------
// DIAG: error
// DIAG-SAME: no member named 'h' in module 'foo'
// DIAG: error
// DIAG-SAME: no member named 'addd' in module 'foo'
// DIAG-NOT: error

// --- every other name bound ----------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}imports_all_forms/main.k =====
// SEMA: fn use_all  @

// Form 9: the ffi anchor binds; the step off it is nobody's to resolve.
// SEMA:      use     cstd  {{.*}} -> import {{.*}}  [import overlay]
// SEMA-NEXT: member  ::printf  {{.*}}<foreign: resolved by clang   ffi header>

// Forms 1 and 2: the same module through its own name and through an alias.
// SEMA:      use     foo  {{.*}} -> module foo {{.*}}  [import overlay]
// SEMA-NEXT: member  ::add  {{.*}} -> fn add @
// SEMA:      use     fmod  {{.*}} -> module foo {{.*}}  [import overlay]
// SEMA-NEXT: member  ::add  {{.*}} -> fn add @

// Forms 4, 5, 6: a name the overlay answers directly, no chain step.
// SEMA:      use     my_add  {{.*}} -> fn add {{.*}}  [import overlay]
// SEMA:      use     plus  {{.*}} -> fn add {{.*}}  [import overlay]
// SEMA:      use     inner  {{.*}} -> module inner {{.*}}  [import overlay]
// SEMA-NEXT: member  ::g  {{.*}} -> fn g {{.*}}  [member of inner]
// SEMA:      use     add  {{.*}} -> fn add {{.*}}  [import overlay]

// Re-export: `f` is bar's, reached through foo's `pub import bar::*`. It is
// NOT in foo's symbol table -- it lives in foo's overlay -- so this proves
// the module step consults that overlay (IMPORTS.md §4.4).
// SEMA:      use     foo  {{.*}} -> module foo {{.*}}  [import overlay]
// SEMA-NEXT: member  ::f  {{.*}} -> fn f @

// Reopened module: `util` is TWO ModuleDecls, and `::one` / `::two` each live
// in only one of them. A head bound to an all-module cell is one namespace
// spread over N scopes, not an overload set (IMPORTS.md §4.3).
// SEMA:      use     util  {{.*}} -> 2 candidate(s), deferred to overload resolution  [import overlay]
// SEMA-NEXT: member  ::one  {{.*}} -> fn one {{.*}}  [member of util]
// SEMA:      use     util  {{.*}} -> 2 candidate(s), deferred to overload resolution  [import overlay]
// SEMA-NEXT: member  ::two  {{.*}} -> fn two {{.*}}  [member of util]

// Form 3: the imported TYPE is a real type, and its members are reachable
// across the TU boundary (its table is keyed by ITS file's imms, not ours).
// SEMA:      use     m  {{.*}} -> var m {{.*}}  [local frame 0]
// SEMA-NEXT: member  .v  {{.*}} -> field v {{.*}}  [member of MyClass]

// The two deliberate errors, and nothing else left over. `foo::h` misses
// because foo imported baz PRIVATELY: a private import edge is topology, not
// surface (wall 1).
// SEMA:      member  ::h  {{.*}}<UNRESOLVED>
// SEMA:      member  ::addd  {{.*}}<UNRESOLVED>
// SEMA: 0 unresolved
// SEMA: 10 chain step(s): 7 bound, 0 overload sets, 1 open, 2 unresolved
