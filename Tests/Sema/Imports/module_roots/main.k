// RUN: { %kairo %s --type-check-only -I foo=%S/libfoo 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema -I foo=%S/libfoo 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --type-check-only -I foo=%S/libfoo -I foo=%S 2>&1 || true; } | %FileCheck %s --check-prefix=DUP
//
// IMPORTS.md §2.1: named module roots.
//
// Two files named `a.k` exist -- one beside this file (the ENTRY root, which
// is the one and only unnamed root) and one under `-I foo=libfoo`. A module
// path is `[root name] + directories + file`, so they are `a` and `foo::a`:
// two modules, two decls, from every importer.
//
// This is what invariant #9 requires. If root names were optional, `import a`
// from a third file would mean whichever `a.k` the search order happened to
// reach first, and the same decl would get two C++ namespaces depending on
// who imported it.
//
// No clang analogue: C++ has no module identity at all at this layer, only
// include paths.

import a
import foo::a as b

fn use_both() -> i32 {
    return a::add() + b::add()
}

// Both resolve.
// DIAG-NOT: error

// --- and they are DIFFERENT decls ----------------------------------------
// Both source files put `add` on a different line, so the two bindings are
// distinguishable in the dump. `a::add` is the entry-root one at 8:5;
// `b::add` is the named-root one at 7:5.
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}module_roots/main.k =====
// SEMA:      use     a  {{.*}} -> module a {{.*}}  [import overlay]
// SEMA-NEXT: member  ::add  {{.*}} -> fn add @ 8:5
// SEMA:      use     b  {{.*}} -> module a {{.*}}  [import overlay]
// SEMA-NEXT: member  ::add  {{.*}} -> fn add @ 7:5
// SEMA: 0 unresolved

// --- two roots under one name is a build error ---------------------------
// Never first-wins, never a merge: a module path under a duplicated root
// name would name two different files.
// DUP: error
// DUP-SAME: duplicate module root 'foo'
