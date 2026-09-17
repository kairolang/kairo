// NO ORACLE: the collision exists only because Kairo has a distinct `usize`
// type that C++ does not. In C++ `f(uint64_t)` / `f(size_t)` on a 64-bit
// target is ONE function declared twice; in Kairo they are two overloads,
// and the emitted C++ would be that redeclaration. The rule is Kairo's: two
// distinct Kairo signatures that lower to one C++ signature are an error at
// the second decl (RedeclMerge::_check_cxx_collision).
//
// Assumes a 64-bit target (lit runs on the host).
//
// EXPECT-ERROR: 15: cxx-signature-collision (u64 / usize)
// EXPECT-ERROR: 18: cxx-signature-collision (i64 / isize, second param agrees)
// EXPECT-ERROR: 22: cxx-signature-collision (method, receiver implied)

fn f(x: u64) { }
fn f(x: usize) { }

fn g(x: i64, y: i32) -> i32 { return y }
fn g(x: isize, y: i32) -> i32 { return y }

class C {
    fn m(self, n: u64) { }
    fn m(self, n: usize) { }
}

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotations above name
// absolute LINE NUMBERS in the code, so anything inserted above the code
// silently invalidates them.
//
// Error at the SECOND decl, note at the first, and the C++ signature named.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// The C++ signature is spelled with BUILTIN types, not the <cstdint>
// typedefs: an emitted interface that named ::std::uint64_t would drag
// <cstdint> into every C++ consumer of it. The collision is the same one
// either way -- u64 and usize lower to one type on a 64-bit target -- so
// only the rendering of the name changed here, not the rule.
// DIAG:      cxx-sig-collision.k:15:1: error [R052E]: 'f(u64)' and 'f(usize)' have the same C++ signature 'f(unsigned long)' on this target
// DIAG-NEXT: cxx-sig-collision.k:14:1: note [R052N]: 'f(u64)' declared here
// DIAG-NEXT: cxx-sig-collision.k:18:1: error [R052E]: 'g(i64, i32)' and 'g(isize, i32)' have the same C++ signature 'g(signed long, signed int)' on this target
// DIAG-NEXT: cxx-sig-collision.k:17:1: note [R052N]: 'g(i64, i32)' declared here
// DIAG-NEXT: cxx-sig-collision.k:22:5: error [R052E]: 'm(u64)' and 'm(usize)' have the same C++ signature 'm(unsigned long)' on this target
// DIAG-NEXT: cxx-sig-collision.k:21:5: note [R052N]: 'm(u64)' declared here
// DIAG-NOT:  error
