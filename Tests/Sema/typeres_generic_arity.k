// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// No direct clang analogue for the individual diagnostics (C++ template
// argument-count/name checking is spread across partial ordering, default
// argument substitution, and SFINAE machinery Kairo does not have), but
// the SHAPE is the one clang's SemaTemplate default-argument and
// explicit-specialization-argument-count tests all check: a generic/
// template applied with the wrong number of arguments, or a named argument
// that does not name a declared parameter, or one named twice. Ported as a
// from-scratch Kairo-native suite for RESOLUTION.md §2.6's `_check_arity` /
// `_collect_args`, since arity/naming is genuinely Kairo's own grammar
// (`Pair<Key: T, Value: U>` named generic arguments have no C++ syntax
// counterpart at all -- C++ template arguments are positional only).
//
// Dropped: SFINAE-driven "substitution failure is not an error" (no
// Kairo analogue -- an arity/name error here is always hard), variadic
// pack arity (packs make `given` unbounded above per `_check_arity`, a
// different code path not exercised here), and partial/explicit
// specialization argument counting (needs the instantiation registry,
// [MISSING] per RESOLUTION.md §2.6's own PARTIAL note).

class <T, U = i32> Pair {
    var a: T;
    var b: U;
}

// ---------------------------------------------------------------------------
// CASE 1 (positive): exactly the required count; the default fills U.
fn ok_required_only(p: Pair<i32>) -> i32 { return 0 }

// CASE 2 (positive): both filled explicitly.
fn ok_both_given(p: Pair<i32, i32>) -> i32 { return 0 }

// CASE 3 (positive): named arguments, ANY order, still resolve by name.
fn ok_named(p: Pair<U: i32, T: i32>) -> i32 { return 0 }

// ---------------------------------------------------------------------------
// CASE 4 (negative): zero arguments where at least one (T, no default) is
// required.
fn too_few(p: Pair) -> i32 { return 0 }

// CASE 5 (negative): more arguments than the primary declares at all.
fn too_many(p: Pair<i32, i32, i32>) -> i32 { return 0 }

// CASE 6 (negative): generic arguments applied to a type that takes none.
class NonGenericClass { var v: i32; }
fn extra_args(p: NonGenericClass<i32>) -> i32 { return 0 }

// CASE 7 (negative): a named argument that names no declared parameter.
fn named_unknown(p: Pair<Z: i32>) -> i32 { return 0 }

// CASE 8 (negative): the same parameter named twice.
fn named_dup(p: Pair<T: i32, T: i32>) -> i32 { return 0 }

// --- expected diagnostics, in source order ---------------------------------
// DIAG: 'Pair' requires at least 1 generic argument(s), but 0 were given
// DIAG-NEXT: note{{.*}}: declared here
// DIAG: 'Pair' takes at most 2 generic argument(s), but 3 were given
// DIAG-NEXT: note{{.*}}: declared here
// DIAG: 'NonGenericClass' is not generic and takes no generic arguments
// DIAG-NEXT: note{{.*}}: declared here
// DIAG: no generic parameter named 'Z'
// DIAG: generic argument 'T' specified more than once
//
// The three positive cases must not error.
// DIAG-NOT: 'Pair' requires
// DIAG-NOT: 'Pair' takes at most{{.*}}but 1
// DIAG-NOT: 'Pair' takes at most{{.*}}but 2
// DIAG-NOT: no generic parameter named 'U'
// DIAG-NOT: no generic parameter named 'T'
