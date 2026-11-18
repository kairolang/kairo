// Dropping a pointee's `const` from a raw pointer is a reinterpret: only a
// written `as unsafe *T` does it, and only inside an `unsafe` block. Outside
// one the cast is SC023E. No implicit conversion drops a qualifier, in an
// `unsafe` block or not; that SC028E says the cast is what is missing, and
// outside a block, the block too.

ffi "c" import "stdlib.h"

fn outside(p: unsafe *const u8) {
    var c = p as unsafe *void
// DIAG: unsafe_cast.k:[[@LINE-1]]:13: error [SC023E]: cast to 'unsafe *void' requires an unsafe context
// DIAG: unsafe_cast.k:[[@LINE-2]]:13: note [{{[A-Z0-9]+}}]: wrap the expression in 'unsafe { ... }'; this cast discards pointer provenance
    var v: unsafe *void = p
// DIAG: unsafe_cast.k:[[@LINE-1]]:27: error [SC028E]: cannot convert 'unsafe *const u8' to 'unsafe *void'; the conversion drops 'const' from the pointee 'const u8', which only a cast does: write 'as unsafe *T' inside an 'unsafe' block
}

fn inside(p: unsafe *const u8) {
    unsafe {
        free(p as unsafe *void)
        var w: unsafe *u8 = p
// DIAG: unsafe_cast.k:[[@LINE-1]]:29: error [SC028E]: cannot convert 'unsafe *const u8' to 'unsafe *u8'; the conversion drops 'const' from the pointee 'const u8', which only a cast does: write 'as unsafe *T'{{$}}
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
