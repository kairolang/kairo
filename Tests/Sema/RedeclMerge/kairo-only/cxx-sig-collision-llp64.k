// NO ORACLE: see cxx-sig-collision.k, whose code this repeats line for line
// (the EXPECT-ERROR line numbers depend on it: the code starts on line 14
// there and here).
//
// LLP64: size_t and uint64_t are both `unsigned long long`, so the pair is
// ONE C++ function here too, spelled `long long`. mingw rather than msvc:
// the run needs that target's headers, and the bundled set ships windows-gnu.
// REQUIRES: sysroot-x86_64-windows-gnu
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
// RUN: { %kairo %s --type-check-only --target=x86_64-w64-mingw32 2>&1 || true; } | %FileCheck %s --check-prefix=LLP64
// LLP64:      cxx-sig-collision-llp64.k:15:1: error [R052E]: 'f(u64)' and 'f(usize)' have the same C++ signature 'f(unsigned long long)' on this target
// LLP64:      cxx-sig-collision-llp64.k:18:1: error [R052E]: 'g(i64, i32)' and 'g(isize, i32)' have the same C++ signature 'g(signed long long, signed int)' on this target
// LLP64:      cxx-sig-collision-llp64.k:22:5: error [R052E]: 'm(u64)' and 'm(usize)' have the same C++ signature 'm(unsigned long long)' on this target
// LLP64-NOT:  error
