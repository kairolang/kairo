// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA %datamodel
//
// Qualified type paths into instances of IMPORTED templates, in the shapes
// clang's own qualified-name tests use: a member typedef through an alias of
// a template-id, a member TEMPLATE of an instance, a template-id path as a
// generic argument, and a dependent head inside a Kairo generic. Each `::`
// into a concrete shell fills it from clang first (TypeResolve::_scope_of).

ffi "c++" import "traits_typedef.h"

type TA = traits<alloc>
type via_alias = TA::size_type
type member_tpl = outer<alloc>::inner<i32>::value

fn use() -> u64 {
    var a: via_alias
    var d: member_tpl
    var e: cont<traits<alloc>::size_type>
    e.push(a)
    d = 1
    return a
}

// `T` is not an argument clang can be asked about yet: the path stays
// dependent and M2 owns it (RESOLUTION.md invariant #5), not an error.
fn <T> gen(x: traits<T>::size_type) -> traits<T>::size_type { return x }

// DIAG-NOT: error

// `cont<traits<alloc>::size_type>` is `cont<u64>`: the path resolved before
// it became an argument, so `push` takes `const unsigned long&`.
// SEMA:      <tu>::use
// SEMA:      NamedIdentExpr @ 20:5 : cont<[[CULONG]], alloc>
// SEMA-NEXT: NamedIdentExpr @ 20:12 : [[CULONG]]
// SEMA-NEXT: AssignOperatorExpr @ 21:5 : i32
// SEMA:      NamedIdentExpr @ 22:12 : [[CULONG]]
// `gen`'s parameter is typed by `traits<T>::size_type`, a member of an
// instance only M2 can fill. No canonical type names it, so its use is
// unknown: deferred, never errored (RESOLUTION.md invariant #5, as `T::Item`
// would be).
// SEMA:      <tu>::gen
// SEMA-NEXT: NamedIdentExpr @ 27:70 : <unknown>
// SEMA-NEXT: typed, 1 unknown, 0 errored
// Only gen's two uses of `traits<T>::size_type` (and what they spread to).
// SEMA:      {{[1-9][0-9]*}} of them dependent, 0 errored
