// NO ORACLE: pointer safety is a Kairo-only distinction. `*B` and
// `unsafe *B` are two types in Kairo and one `B*` in C++, so `f(p: *B)`
// beside `f(p: unsafe *B)` would be one C++ function declared twice, which
// clang reported as CL001E "redefinition" in generated code. It is
// R052E at the second decl, as for usize/u64. A `*B?` is a Nullable in
// C++, a different type, and is a legal overload beside `unsafe *B`.
//
// EXPECT-ERROR: 14: cxx-signature-collision (safe / unsafe pointer)
// EXPECT-ERROR: 17: cxx-signature-collision (pointer to pointer, inner safety)

class B { var x: i32 = 1 }

fn f(p: *B) -> i32 { return 1 }
fn f(p: unsafe *B) -> i32 { return 2 }

fn g(p: unsafe **B) -> i32 { return 1 }
fn g(p: unsafe *unsafe *B) -> i32 { return 2 }

fn h(p: *B?) -> i32 { return 1 }
fn h(p: unsafe *B) -> i32 { return 2 }

fn k(p: *B) -> i32 { return 1 }
fn k(p: *const B) -> i32 { return 2 }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM: the EXPECT-ERROR annotations above name absolute
// line numbers.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      cxx-sig-collision-safety.k:14:1: error [R052E]: 'f(*B)' and 'f(unsafe *B)' have the same C++ signature
// DIAG-NEXT: cxx-sig-collision-safety.k:13:1: note [R052N]: 'f(*B)' declared here
// DIAG-NEXT: cxx-sig-collision-safety.k:17:1: error [R052E]: 'g(unsafe **B)' and 'g(unsafe *unsafe *B)' have the same C++ signature
// DIAG-NEXT: cxx-sig-collision-safety.k:16:1: note [R052N]: 'g(unsafe **B)' declared here
// DIAG-NOT:  error
