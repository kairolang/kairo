// RUN: { %kairo %s --type-check-only -I %S/libfoo 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema -I %S/libfoo 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --type-check-only -I foo=%S/libfoo 2>&1 || true; } | %FileCheck %s --check-prefix=NAMEEQ
// RUN: not %kairo %s --type-check-only -I foo=%S/libfoo > /dev/null 2>&1
//
// IMPORTS.md §2.1: a named library beside the unnamed search dirs.
//
// Two files named `a.k` exist -- one beside this file (in the cwd, an
// unnamed search dir) and one under libfoo/, whose module.k pins library
// `foo`. A module path is `[library name] + directories + file`, so they are
// `a` and `foo::a`: two modules, two decls, from every importer. The pin
// names libfoo/ whether it is reached as `-I libfoo` or found as an
// immediate subdirectory of the cwd (the third RUN, no -I at all).
//
// This is what invariant #9 requires. If a library's name came from search
// order, `import a` from a third file would mean whichever `a.k` was reached
// first, and the same decl would get two C++ namespaces depending on who
// imported it.
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
// distinguishable in the dump. `a::add` is the cwd one at 8:5;
// `b::add` is the library one at 7:5.
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}module_roots/main.k =====
// SEMA:      use     a  {{.*}} -> module a {{.*}}  [import overlay]
// SEMA-NEXT: member  ::add  {{.*}} -> fn add @ 8:5
// SEMA:      use     b  {{.*}} -> module a {{.*}}  [import overlay]
// SEMA-NEXT: member  ::add  {{.*}} -> fn add @ 7:5
// SEMA: 0 unresolved

// --- `-I name=dir` is gone -------------------------------------------------
// A command-line name for a directory was a second way to say what the
// directory's module.k says, and the two could disagree. The form is an
// error that points at the pin, not a directory literally named `foo=...`.
// NAMEEQ: error
// NAMEEQ-SAME: -I foo=
// NAMEEQ-SAME: module foo
