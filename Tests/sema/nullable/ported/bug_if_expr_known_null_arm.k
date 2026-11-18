// XFAIL: *
// The else arm of a value-form `if a? => 0 else => a` reads `a` while it is
// known null. nullables.mdx (Narrowing) makes reading a known-null nullable
// a compile error, and every other read of such a place reports SC265E
// ("'a' is always null here"); this one reports the type error SC028E
// ("cannot convert 'i32?' to 'i32'") instead.

fn wrong_arm(a: i32?) -> i32 {
    return if a? => 0 else => a // expect: SC265E
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: bug_if_expr_known_null_arm.k:9:{{[0-9]+}}: error [SC265E]
