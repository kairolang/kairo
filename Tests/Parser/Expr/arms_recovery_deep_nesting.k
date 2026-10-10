// Brace recovery is linear in nesting depth. Thirty braced value arms nested
// inside each other must finish well inside the time limit: recovery parses
// each brace once, where deciding by speculative parse and then parsing for
// real doubled the work per level (2^30 here). Every arm is still reported:
// S073E for each of the 60 braced arms, S077E for each of the 29 inner `if`s
// sitting in a then-arm.

fn deep(c: bool) -> i32 {
    return if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { if c { 1 } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 } } else { 0 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: timeout 10 %kairo %s --syntax-only --cmax-errors=10000 > %t.out 2>&1; test $? -ne 124
// RUN: %FileCheck %s --check-prefix=DIAG --input-file=%t.out
// RUN: grep -c 'error \[S073E\]' %t.out | grep -qx 60
// RUN: grep -c 'error \[S077E\]' %t.out | grep -qx 29
// DIAG: arms_recovery_deep_nesting.k:9:17: error [S073E]
// DIAG-NOT: error [S0{[^7]}
