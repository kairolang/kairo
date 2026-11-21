// A generic body is checked once against its own bounds, so a call that
// binds a bounded parameter of an IMPORTED callee to an unbounded parameter
// of the caller is an error at the definition, exactly as for a callee
// declared in the same module: std::copy is `copy<T impl Copyable>` and
// string's contains is `contains<P impl Pattern>`.

import std

fn <T> dup(const x: T) -> T {
    return std::copy(x)
}

fn <T> dup_bare(const x: T) -> T {
    return copy(x)
}

fn <T> has(const s: string, const p: T) -> bool {
    return s.contains(p)
}

interface Named {
    fn name(const self) -> string
}

fn <T impl Named> dup_named(const x: T) -> T {
    return std::copy(x)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: imported_bound_open_param.k:10:12: error [R051E]: 'copy' needs 'T' to implement 'Copyable'
// CHECK: fix-it:"{{.*}}imported_bound_open_param.k":{9:6-9:6}:" impl Copyable"
// CHECK: copy.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: required by this bound
// CHECK: imported_bound_open_param.k:9:5: note [R051N]: 'T' is declared with no bound
// CHECK: imported_bound_open_param.k:14:12: error [R051E]: 'copy' needs 'T' to implement 'Copyable'
// CHECK: imported_bound_open_param.k:18:12: error [R051E]: 'contains' needs 'T' to implement 'Pattern'
// CHECK: imported_bound_open_param.k:26:12: error [R025E]: 'copy' needs 'T' to implement 'Copyable'; none of the bounds of 'T' does
// CHECK: imported_bound_open_param.k:43:12: error [R051E]: 'copy' needs 'T' to implement 'Copyable'
// CHECK-NOT: error

// An explicit type argument is held to the same bound.
fn <T> dup_explicit(const x: T) -> T {
    return std::copy<T>(x)
}
