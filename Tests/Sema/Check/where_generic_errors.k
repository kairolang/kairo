// A generic `where` group (MONO.md G12) is one C++ template signature, so its
// members must agree on more than a plain group's do: the generic
// parameters' names (the guards move into the dispatcher, which declares
// the first member's), and the bounds (one set of constraints). Two
// unguarded members are two fallbacks. A member whose type parameter no
// parameter mentions cannot be forwarded to without spelling its arguments,
// which the dispatcher does not do yet.
pub interface A { fn a(const self) -> i32 }
pub interface B { fn b(const self) -> i32 }

fn <T> names(x: T, n: i32) -> i32 where n > 0 { return 1 }
fn <U> names(x: U, n: i32) -> i32 { return 2 }

fn <T impl A> bounds(x: T, n: i32) -> i32 where n > 0 { return 1 }
fn <T impl B> bounds(x: T, n: i32) -> i32 { return 2 }

fn <T> ret(x: T, n: i32) -> T where n > 0 { return x }
fn <T> ret(x: T, n: i32) -> i32 { return 2 }

fn <T> twice(x: T, n: i32) -> i32 where n > 0 { return 1 }
fn <T> twice(x: T, n: i32) -> i32 { return 2 }
fn <T> twice(x: T, n: i32) -> i32 { return 3 }

fn <T> hidden(n: i32) -> i32 where n > 0 { return 1 }
fn <T> hidden(n: i32) -> i32 { return 2 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: where_generic_errors.k:12:1: error [SC001E]: every overload in the 'where' dispatch of 'names' must have the same generic parameter names; C++ sees them as one function
// CHECK-NEXT: where_generic_errors.k:11:1: note [SC001N]: the first overload of the dispatch is here
// CHECK: where_generic_errors.k:15:1: error [SC001E]: every overload in the 'where' dispatch of 'bounds' must have the same bounds; C++ sees them as one function
// CHECK: where_generic_errors.k:18:1: error [SC001E]: every overload in the 'where' dispatch of 'ret' must have the same return type; C++ sees them as one function
// CHECK: where_generic_errors.k:22:1: error [R029E]: redefinition of 'twice'
// CHECK-NEXT: where_generic_errors.k:21:1: note [R029N]: previous definition of 'twice' is here
// CHECK: where_generic_errors.k:24:1: error [SC116E]: 'where' dispatch on a generic function whose parameter 'T' is not deduced from its arguments is not yet supported
// CHECK: where_generic_errors.k:25:1: error [SC116E]: 'where' dispatch on a generic function whose parameter 'T' is not deduced from its arguments is not yet supported
