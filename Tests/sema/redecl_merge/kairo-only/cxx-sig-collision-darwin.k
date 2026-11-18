// NO ORACLE: see cxx-sig-collision.k, whose code this repeats line for line
// (the EXPECT-ERROR line numbers depend on it).
//
// Darwin: LP64 with a `long long` int64_t, so size_t stays `unsigned long`
// beside an `unsigned long long` u64 -- two C++ types, two overloads,
// nothing to report (TargetOptions::usize_is_fixed). A Darwin host's own
// SDK serves this; elsewhere the bundled Apple sysroot must.
// REQUIRES: host-darwin || sysroot-arm64-macosx
//
// EXPECT-OK: no cxx-signature-collision on this target

fn f(x: u64) { }
fn f(x: usize) { }

fn g(x: i64, y: i32) -> i32 { return y }
fn g(x: isize, y: i32) -> i32 { return y }

class C {
    fn m(self, n: u64) { }
    fn m(self, n: usize) { }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=arm64-apple-macosx 2>&1 || true; } | %FileCheck %s --check-prefix=DARWIN --allow-empty
// DARWIN-NOT: R052E
