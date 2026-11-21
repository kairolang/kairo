// A library generic's `impl` bounds bind a caller's bounds-checked
// parameter as a local generic's do (forwarded_bounds.k): the caller's
// bounds must grant them. `string`'s `<S impl ByteRange>` constructor and
// `std::copy`'s `T impl Copyable` are library declarations, checked at the
// call in the generic body.

import std

fn <T> make(a: T) -> string = string(a)
fn <T> dup(const x: T) -> T { return std::copy(x) }

fn <T impl ByteRange> make_bytes(a: T) -> string = string(a)
fn <T impl Copyable> dup_copyable(const x: T) -> T { return std::copy(x) }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:9:31: error [R051E]: 'string' needs 'T' to implement 'ByteRange'
// DIAG: {{.*}}:9:5: note [R051N]: 'T' is declared with no bound
// DIAG: {{.*}}:10:38: error [R051E]: 'copy' needs 'T' to implement 'Copyable'
