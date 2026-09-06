// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only):
//   Lib/llvm-runtimes/clang/test/SemaCXX/qualified-id-lookup.cpp
//   Lib/llvm-runtimes/clang/test/CXX/basic/basic.lookup/basic.lookup.qual/
//   Lib/llvm-runtimes/clang/test/SemaCXX/namespace.cpp (unqualified-lookup
//   half only; the `using namespace` shadow-warning half is Kairo-analogue-
//   free and is dropped -- Kairo has no using-directive, only `import`,
//   which is a completely different mechanism tested under Tests/Imports/).
//
// What carries over: (a) a NESTED scope's unqualified lookup falls through
// to its ENCLOSING scope, not just its own table (basic.lookup.unqual's
// "innermost enclosing declarative region" rule); (b) a `::`-qualified path
// walks module members exactly (module lookup, ChainBinding §2.7); (c) a
// leading `::` escapes every enclosing scope straight to the TU, bypassing
// a local shadow (qualified-id-lookup.cpp's `::foo` vs plain `foo` split).
//
// Dropped: ADL (no Kairo analogue), `using namespace` (no directive-import
// in Kairo), elaborated-type-specifier lookup (`struct S` disambiguators --
// Kairo has no tag-vs-value namespace split to disambiguate).

// ---------------------------------------------------------------------------
// CASE 1: nested module, unqualified name resolves by walking OUT to the
// enclosing module's table -- not just the innermost one.

module Outer {
    fn helper() -> i32 { return 5 }

    module Inner {
        // `helper` is not in Inner's own table; N must walk Inner -> Outer.
        fn call_helper() -> i32 { return helper() }
    }
}

// ---------------------------------------------------------------------------
// CASE 2: `::`-qualified path walks module members left to right
// (ChainBinding, Module anchor kind, exact test of §2.7's "Module -> `::`
// does table lookup").

fn use_qualified() -> i32 {
    return Outer::Inner::call_helper() + Outer::helper()
}

// ---------------------------------------------------------------------------
// CASE 3: a leading `::` escapes every enclosing scope straight to the TU.
// `g` is shadowed inside M by M's own `g`; the unqualified read inside M
// binds M's `g`, but `::g` -- qualified from the GLOBAL scope -- must still
// bind the file-scope one.

var g: i32 = 1;

module M {
    var g: i32 = 2;
    fn read_local() -> i32 { return g }
    fn read_global() -> i32 { return ::g }
}

// --- diagnostics -----------------------------------------------------------
// DIAG-NOT: error
// DIAG-NOT: undeclared identifier

// --- bindings ----------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}lookup_qualified.k =====

// CASE 1: `helper` inside Inner binds OUT to Outer's fn, via scope walk.
// SEMA:      <tu>::Outer::Inner::call_helper
// SEMA:        helper  {{.*}} -> fn helper {{.*}}  [scope Outer]

// CASE 2: both qualified paths bind through their modules, left to right.
// SEMA:      <tu>::use_qualified
// SEMA:        Outer  {{.*}} -> module Outer {{.*}}
// SEMA-NEXT:   ::Inner  {{.*}} -> module Inner {{.*}}
// SEMA-NEXT:   ::call_helper  {{.*}} -> fn call_helper {{.*}}
// SEMA-NEXT:   Outer  {{.*}} -> module Outer {{.*}}
// SEMA-NEXT:   ::helper  {{.*}} -> fn helper {{.*}}

// CASE 3: unqualified `g` inside M binds M's OWN var (and is flagged as a
// shadow of the file-scope one); `::g` bypasses the shadow entirely and
// binds the file-scope var.
// SEMA:      <tu>::M::read_local
// SEMA:        g  {{.*}} -> var g {{.*}}  [scope M]{{.*}}shadows var g{{.*}}
// SEMA:      <tu>::M::read_global
// SEMA:        ::g  {{.*}} -> var g @ 51:1

// Nothing left unbound.
// SEMA: 0 unresolved
