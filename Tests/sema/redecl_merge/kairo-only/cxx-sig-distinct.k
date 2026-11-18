// NO ORACLE: the negative half of cxx-sig-collision.k, and Kairo-only for
// the same reason. Each pair shares a `usize`-vs-fixed-width position but
// differs somewhere else in a way the lowering keeps apart, so the emitted
// C++ has two distinct functions and nothing may be reported.
//
// Assumes a 64-bit target (lit runs on the host): `u32` is not `size_t`.
//
// EXPECT-CLEAN

fn f(x: u64, y: i32) { }
fn f(x: usize, y: i64) { }

fn k(x: u32) { }
fn k(x: usize) { }

fn s(x: isize) { }
fn s(x: usize) { }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM, same convention as the rest of this corpus.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
