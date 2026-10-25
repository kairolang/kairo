// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// Explicit generic arguments for a parameter the call arguments cannot
// deduce: `zero<i32>()`, `width<u64>()` -- the shape of Casting.k's
// `isa<T>(n)` / `cast<T>(n)` (3,200 uses) and `ctx->alloc<T>(...)`, and of
// pointers.md's `std::alloc<i32>`. The `isa` body itself (`T::classof` under
// `<T: type>`) is a duck call and is crtp_duck.k's bug, so it is left out.
//
// XFAIL: *
// Waiting on overload resolution using the explicit arguments: every such
// call is SC063E, note "could not deduce every generic parameter from the
// arguments". Only a call whose explicit arguments are ALSO deducible works
// (`f<i32>(1)`). Only Parser tests ever wrote this shape.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

fn <T> zero() -> i32 { return 0 }
fn <T> width() -> usize { return sizeof T }

fn main() -> i32 {
    var r = 0
    if zero<i32>() == 0 { r += 1 }
    if width<u64>() == 8 { r += 2 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
