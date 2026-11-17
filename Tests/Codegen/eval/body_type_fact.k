// A function-body `eval if` whose condition reads a type fact (`sizeof`,
// `alignof`, `is_trivially_copyable!`) of a concrete type is decided once
// types are resolved: the untaken branches are neither type-checked nor
// emitted, as with a `defined!` condition. Each untaken branch below calls
// `g` with a `usize`, which is SC063E wherever it is typed. The taken branch
// stays a block, after a static assertion of each decided condition, so a
// layout or fact Kairo predicts differently from clang fails the build
// instead of running the wrong branch.
fn g(v: u32) -> u32 = v

fn chain() -> i32 {
    var v: usize = 1
    eval if sizeof u64 != 8 {
        return g(v) as i32
    } else if alignof u8 == 2 {
        return g(v) as i32
    } else {
        var r = 0
        return r
    }
}

// Valid either way, so that under --test-fold-lie (the fold reads every
// triviality fact inverted) the build reaches the pin and fails there.
fn fact() -> i32 {
    eval if is_trivially_copyable!(u64) {
        return 0
    } else {
        return 1
    }
}

class C {
    fn m(self) -> i32 {
        var v: usize = 1
        eval if sizeof u64 == 8 { return 0 } else { return g(v) as i32 }
    }
}

fn main() -> i32 {
    var c = C()
    return chain() + fact() + c.m()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: chain() noexcept {
// CXX-NEXT: {{.*}} v = 1;
// CXX-NEXT: static_assert({{.*}}!(sizeof(unsigned long{{( long)?}}) != 8
// CXX-NEXT: static_assert({{.*}}!(alignof(unsigned char) == 2
// CXX-NOT: g(
// CXX-LABEL: fact() noexcept {
// CXX-NEXT: static_assert({{.*}}__is_trivially_copyable(unsigned long{{( long)?}})
// CXX-NEXT: {
// CXX-NEXT: return 0;
// CXX-LABEL: C::m() noexcept {
// CXX-NOT: g(
// CXX: }

// REQUIRES: clang
// RUN: rm -rf %t.d %t.lie.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: not %kairo %s --test-fold-lie -o %t.lie.exe --cache-dir %t.lie.d > %t.lie.out 2>&1
// RUN: %FileCheck %s --check-prefix=LIE < %t.lie.out
// LIE: error [CL001E]: static assertion failed due to requirement {{.*}}__is_trivially_copyable
