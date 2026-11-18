// `@assume(c)` and `__builtin_unreachable()` are unchecked from -O1: the
// assert that tests `c` at -O0 is stripped. Outside `unsafe` that is a
// warning at -O1 and above only.

fn f(n: i32) -> i32 {
    @assume(n > 0)
    unsafe { @assume(n > 1) }
    if n > 100 {
        __builtin_unreachable()
    }

    if n > 200 {
        unsafe { __builtin_unreachable() }
    }

    return n
}

fn main() -> i32 { return f(3) - 3 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -O0 2>&1 || true; } | %FileCheck %s --check-prefix=O0 --allow-empty
// RUN: { %kairo %s --type-check-only -O1 2>&1 || true; } | %FileCheck %s --check-prefix=O1 --implicit-check-not='warning ['
// O0-NOT: SC362W
// O1: assume_outside_unsafe.k:6:5: warning [SC362W]: '@assume' is unchecked at this optimization level: a false condition is undefined behavior; wrap it in 'unsafe' to acknowledge
// O1: assume_outside_unsafe.k:9:9: warning [SC362W]: '__builtin_unreachable' is unchecked at this optimization level: reaching it is undefined behavior; wrap it in 'unsafe' to acknowledge
