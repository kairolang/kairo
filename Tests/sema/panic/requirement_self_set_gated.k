// A static requirement whose panic SET names `Self` is still SC116E, with a
// note at its result; only a result that names `Self` as its value is
// accepted (requirement_self_static.k).

interface Fail {
    static fn make(const s: string) panic(Self) -> i32
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: requirement_self_set_gated.k:6:37: error [SC116E]: a panicking interface requirement whose result names 'Self' ('make') is not yet supported
