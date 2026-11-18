// What `const` does NOT combine with: one storage keyword (`var`, `static`,
// `thread`, `eval`), `const` at most once, never `var` with another. The
// extra keyword is named with both spellings and a fix-it that removes it,
// and the declaration parses on (no S046E "expected a name" cascade). A
// const binding with a const type says it twice (S071E, as for
// `const x: const T`).
static const X: const i32 = 1
const const Y = 2
static eval Z = 3
var const W = 4
static const const V = 5
fn g() {
    var static Q = 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: storage_const_order_errors.k:7:17: error [S071E]: the binding is already 'const'; a second 'const' on its type is not allowed
// DIAG-NEXT: fix-it:{{.*}}:{7:17-7:22}:""
// DIAG-NEXT: storage_const_order_errors.k:8:7: error [S045E]: 'const' is written twice; a binding takes it once
// DIAG-NEXT: fix-it:{{.*}}:{8:7-8:12}:""
// DIAG-NEXT: storage_const_order_errors.k:9:8: error [S045E]: 'static' cannot be combined with 'eval'; a binding takes one of 'var', 'static', 'thread' or 'eval', and 'const' once
// DIAG-NEXT: fix-it:{{.*}}:{9:8-9:12}:""
// DIAG-NEXT: storage_const_order_errors.k:10:5: error [S045E]: 'var' cannot be combined with 'const'
// DIAG-NEXT: fix-it:{{.*}}:{10:5-10:10}:""
// DIAG-NEXT: storage_const_order_errors.k:11:14: error [S045E]: 'const' is written twice
// DIAG-NEXT: fix-it:{{.*}}:{11:14-11:19}:""
// DIAG-NEXT: storage_const_order_errors.k:13:9: error [S045E]: 'var' cannot be combined with 'static'
// DIAG-NEXT: fix-it:{{.*}}:{13:9-13:15}:""
// DIAG-NOT: error
