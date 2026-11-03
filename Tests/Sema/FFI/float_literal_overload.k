ffi "c++" import "cmath";

fn f(x: f32) -> i32 { return 1 }
fn f(x: f64) -> i32 { return 2 }
fn g(x: f32) -> i32 { return 4 }
fn h(x: f32, y: f64) -> i32 { return 8 }
fn h(x: f64, y: f32) -> i32 { return 16 }

fn main() -> i32 {
    var r = 0
    // libc++'s float / double / long double overloads: the double one.
    if cxx::std::sqrt(16.0) == 4.0 { r += 32 }
    r += f(1.5)          // 2: f64 is the literal's own type
    r += g(1.5)          // 4: a lone f32 still takes it
    var a: f32 = 2.5
    r += f(a)            // 1: a typed argument is unaffected
    return r
}

fn ambiguous() -> i32 { return h(1.5, 2.5) }

// --- lit wiring -----------------------------------------------------------
// P255: an untyped float literal is C++'s double when overloads differ only
// by float type: identity to f64, a floating conversion to anything else
// (OverloadResolution::_flit_better). It was SC064E ambiguous, so
// `cxx::std::sqrt(16.0)` could not be called. Each argument still decides
// on its own: `h(1.5, 2.5)` prefers f64 at a different argument for each
// candidate, which C++ calls ambiguous too.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: float_literal_overload.k:20:32: error [SC064E]: call to 'h' is ambiguous
// RUN: sed -e '/^fn ambiguous/d' %s > %t.k
// RUN: rm -rf %t.d
// RUN: %kairo %t.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 39
