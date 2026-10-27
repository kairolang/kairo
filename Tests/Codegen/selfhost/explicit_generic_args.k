// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// Explicit generic arguments for a parameter the call arguments cannot
// deduce: `zero<i32>()`, `width<u64>()` -- the shape of Casting.k's
// `isa<T>(n)` / `cast<T>(n)` (3,200 uses) and `ctx->alloc<T>(...)`, and of
// pointers.md's `std::alloc<i32>`. The `isa` body itself (`T::classof` under
// `<T: type>`) is a duck call (-fduck-generics; duck_member_call.k), so it is left out.
//
// Was SC063E "could not deduce every generic parameter from the
// arguments": overload resolution now binds the explicit arguments into
// each candidate's deduction before judging its arguments (EVAL.md 3).

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
