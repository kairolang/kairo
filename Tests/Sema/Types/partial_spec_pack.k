// A partial specialization whose pattern holds a pack expansion (P138). The
// registry cannot select it (InstantiationRegistry::_match binds one type
// per parameter), while clang selects it per instance: dropped silently,
// Sema typed `Traits<Box<i32>, i32>` through the primary's body and C++
// through the partial's. It is SC116E at the pack, once per specialization,
// with a note at the specialization; one without a pack is unaffected.
class <T> Box {
    var v: T
}

struct <R, ...Args> Traits { }

struct <T, ...Args> Traits<Box<T>, Args...> {
    pub type P = T
}

struct <T, ...Args> Traits<*T, Args..., Args...> { }

struct <R> Plain { }
struct <T> Plain<Box<T>> {
    pub type P = T
}

fn main() -> i32 {
    var p: Plain<Box<i32>>::P = 1
    return p
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: partial_spec_pack.k:13:36: error [SC116E]: a partial specialization whose pattern holds a pack expansion is not yet supported
// CHECK-NEXT: partial_spec_pack.k:13:1: note [SC116N]: this partial specialization is never selected
// CHECK: partial_spec_pack.k:17:32: error [SC116E]: a partial specialization whose pattern holds a pack expansion is not yet supported
// CHECK-NEXT: partial_spec_pack.k:17:1: note [SC116N]: this partial specialization is never selected
