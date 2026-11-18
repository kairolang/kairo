// Operands that unify are accepted: equal types, and an operand mixed with a
// literal or an explicitly cast side.

fn main() -> i32 {
    var c: char = 'a'
    var u: u32  = 1
    var i: i8   = 1
    var a = c == c
    var b = u + u
    var d = (c as u32) + u
    var e = u + (i as u32)
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --allow-empty
