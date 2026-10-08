// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --target i386-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// Integer widening into an imported signature (Conversion::abi_widen).
// usize/isize are the width range [32, 64] over 32/64-bit targets, a
// fixed-width integer is [N, N], and S -> D widens iff max(S) <= min(D)
// (strict for unsigned -> signed). Run on a 64- and a 32-bit triple: both
// must accept the same calls, lattice §4's portability. A 16-bit target
// lowers the floor to 16; no 16-bit backend is built, so that is untested.
// Every call here must type-check with no `as`; the refused directions
// live in abi_widen_errors.k.

ffi "c++" import "abi_widen.h"

fn widen(a: u8, b: u16, c: u32, d: i8, e: i16, f: i32, n: usize, s: isize) {
    take_size(a)    // uN -> usize: max N <= 32
    take_size(b)
    take_size(c)
    take_diff(d)    // iN -> isize
    take_diff(e)
    take_diff(f)
    take_diff(b)    // u16 -> isize: 16 < 32
    take_u64(n)     // usize -> u64: max 64 <= 64
    take_i64(s)     // isize -> i64
    take_i64(c)     // fixed pair: the lattice's own W, untouched
}

// DIAG-NOT: error
