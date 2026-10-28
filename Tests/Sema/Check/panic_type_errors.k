struct A { var x: i32 }
struct B { var y: i64 }
struct C { var z: i8 }
fn named(p: Panic<i32, A>) -> i32 { return 0 }
fn three(p: Panic<i32, A, B, C>) -> i32 { return 0 }
fn same(p: Panic<i32, A, A>) -> i32 { return 0 }
fn <T> generic() -> u32 { return __builtin_type_id<T>() }
fn main() -> i32 { return generic<i32>() as i32 }

// --- lit wiring -----------------------------------------------------------
// The Panic lang item is the compiler's (PANIC.md §1.1): source naming it is
// SC116E, at the type, with the builtin declaration as the note.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=GATE
// GATE: panic_type_errors.k:4:13: error [SC116E]: a panic result type cannot be named yet; a panicking call is handled with 'try' or propagated
// GATE-NEXT: panic_result.k:{{[0-9]+}}:{{[0-9]+}}: note [SC116N]: the builtin result type, declared here
// GATE: panic_type_errors.k:5:13: error [SC116E]
// GATE: panic_type_errors.k:6:12: error [SC116E]

// Two types whose ids collide cannot share a set (PANIC.md §1.3): checked
// as the set is formed, naming both, each with its declaration. One bit of
// id makes every pair collide; a type twice is one element, not a
// collision.
// RUN: { %kairo %s --test-panic-type --test-panic-id-bits=1 --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=COLL
// COLL-NOT: panic_type_errors.k:4:{{.*}} error
// COLL: panic_type_errors.k:5:13: error [SC001E]: '{{[ABC]}}' and '{{[ABC]}}' cannot be in one panic set: both have type id 0x00000001
// COLL-NEXT: panic_type_errors.k:{{[123]}}:1: note [SC001N]: '{{[ABC]}}' declared here
// COLL-NEXT: panic_type_errors.k:{{[123]}}:1: note [SC001N]: '{{[ABC]}}' declared here
// COLL: panic_type_errors.k:5:13: error [SC001E]: '{{[ABC]}}' and '{{[ABC]}}' cannot be in one panic set
// COLL-NOT: panic_type_errors.k:6:{{.*}} error

// A type id is per concrete type: a generic body's T has none to answer.
// RUN: { %kairo %s --test-panic-type --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=GEN
// GEN-NOT: error [SC001E]: '{{.*}}' and
// GEN: panic_type_errors.k:7:34: error [SC001E]: '__builtin_type_id' needs a type every TU spells the same way; this one depends on a generic parameter or has no C++ type
