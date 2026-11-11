// An imported function template whose return type is a placeholder
// (`decltype(auto)` / `auto`: llvm::dyn_cast, cast, isa) returns what clang
// deduces from the specialization's body. Kairo does not take the declared
// placeholder, which imports as nothing: `var t = llvm::dyn_cast<T>(p)`
// would type `<ffi type>`, every `t->m()` be R027E and every `t != &null`
// SC076E.

ffi "c++" import "deduced_return_template.h"

fn f(b: unsafe *Base, cb: unsafe *const Base) -> i32 {
    var t = my_cast<Leaf>(b)
    if t == &null { return 0 }
    var c = my_ccast<Leaf>(cb)
    return t->leaf() + c->leaf()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: SEMA fid {{[0-9]+}}: {{.*}}deduced_return_template.k =====
// CHECK: -- inferred decls --
// CHECK-DAG: t : unsafe *Leaf
// CHECK-DAG: c : unsafe *const Leaf
