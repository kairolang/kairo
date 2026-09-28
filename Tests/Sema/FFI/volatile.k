// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// `volatile` is the other qualifier, carried the same way `const` is. The
// imported field reads as `volatile i32`, so its address is a
// `*volatile i32`: `poke(volatile int*)` takes it, `peek(int*)` would drop
// the qualifier and has no viable conversion. The only error in this file.

ffi "c++" import "volatile.h"

fn use_reg() {
    var r: R
    poke(unsafe &r.reg)
    peek(unsafe &r.reg)
}

// DIAG:      volatile.k:14:5: error [SC001E]: no matching overload for call to 'peek'
// DIAG-NEXT: volatile.h:8:1: note [I900N]: candidate not viable: cannot convert argument of type 'unsafe *volatile i32' to parameter 'p' of type 'unsafe *i32'
// DIAG-NOT:  error

// SEMA:      UnsafeExpr @ 13:10 : unsafe *volatile i32
// SEMA-NEXT: UnaryOperatorExpr @ 13:17 : *volatile i32
// SEMA-NEXT: ChainExpr @ 13:18 : volatile i32
// SEMA:      1 errored
