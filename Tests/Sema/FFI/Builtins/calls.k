// Every call here must bind and type-check. Clang builtins are the fourth
// source of unqualified names (RESOLUTION.md §2.5): no import, no header.

fn bits(x: u32) -> i32 {
    return __builtin_popcount(x);                 // i32(u32): plain import.
}

fn likely(x: i32) -> i64 {
    return __builtin_expect(x as i64, 1);         // untyped literal takes the param type (i64).
}

fn scratch(n: usize) -> unsafe *void {
    return __builtin_alloca(n);                   // size_t slot -> usize; was u64 before the slot decoder.
}

fn promise_of(p: unsafe *void) -> unsafe *void {
    return __builtin_coro_promise(p, 8, false);   // COR_LANG builtin; both I-positions are literals.
}

fn die() -> i32 {
    __builtin_trap();                             // noreturn: no `return` needed, no ReturnPathCheck error.
}

fn main() -> i32 {
    var x: u32 = 0xF0;
    if bits(x) != 4 { die(); }
    if likely(1) != 1 { die(); }
    var p = scratch(64);
    var q = promise_of(p);
    return 0;
}

// --- lit wiring (below the code: nothing above shifts a line) -------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
