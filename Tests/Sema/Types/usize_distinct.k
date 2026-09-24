// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// `usize` / `isize` are types of their own, not spellings of u64 / i64 --
// even on a target where they are the same width, and even though C++ spells
// `size_t` as `unsigned long` there. Crossing between them takes `as`, in
// both directions; a C++ `size()` returns u64, and a `-> usize` wrapper
// around it has to say so.

fn narrow_ok(x: u64) -> usize { return x as usize }
fn widen_ok(x: usize) -> u64 { return x as u64 }

fn implicit_in(x: u64) -> usize { return x }
fn implicit_out(x: usize) -> u64 { return x }
fn signed_in(x: i64) -> isize { return x }

// The `as` spellings (lines 9-10) are clean; each implicit crossing is one
// SC001E at the returned value, and nothing else is reported.
// DIAG-NOT:  usize_distinct.k:{{9|10}}:
// DIAG:      usize_distinct.k:12:42: error [SC001E]: cannot convert 'u64' to 'usize'
// DIAG-NEXT: usize_distinct.k:13:43: error [SC001E]: cannot convert 'usize' to 'u64'
// DIAG-NEXT: usize_distinct.k:14:40: error [SC001E]: cannot convert 'i64' to 'isize'
// DIAG-NOT:  error
