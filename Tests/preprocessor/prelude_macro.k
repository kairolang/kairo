// The prelude is `import builtin::*` for macros too (PANIC.md §2.4):
// `crash!`, a `pub macro` in Lib/builtin/module.k, is visible in every
// file without an import. Before, a builtin `pub macro` was R013E
// "unknown macro" everywhere but the builtin files: the prelude added an
// import-graph edge from the entry but never put `builtin` among the
// file's macro import scopes. It is searched after the file's own scopes
// and imports, so a file's own macro of the same name shadows it, as for
// any other import.

fn uses_prelude() -> i32 {
    crash!()
}

module shadow {
    fn seven() -> i32 { return 7 }
    macro crash!() { seven() }
    fn own() -> i32 { return crash!() }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [
// CHECK-NOT: warning [
