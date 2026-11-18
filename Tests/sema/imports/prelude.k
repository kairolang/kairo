// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: { %kairo %s --type-check-only --no-builtins 2>&1 || true; } | %FileCheck %s --check-prefix=NOBI
//
// The PRELUDE. Every translation unit behaves as though it opened with
// `import builtin::*`, so a lang-item type resolves with no import written
// in the file. The injection is the driver's (FrontendAction::_semantic):
// the preprocessor folds the builtin root into the import graph, but a graph
// edge binds no names -- phase I builds the overlay from tu->imports, and the
// synthesized ImportDecl is what puts builtin in it.
//
// --no-builtins suppresses the injection, which is how the builtin module's
// own files compile and how this file asserts that the resolution really came
// from the prelude rather than from somewhere else.

fn uses_string() {
    var s: string;
}

// DIAG-NOT: error

// The lang items are bound build-wide, from the builtin TU, into the table on
// GlobalDisambigTable -- so this dump is the SHARED table, not a per-TU one.
// SEMA: -- lang items (well_known) --
// SEMA: string  -> {{.*}}string

// Without the prelude there is no `string` in scope and the type name does not
// resolve. That is the whole point of the flag: same file, no injection.
// NOBI: error
