// `inline "asm"` is the one inline foreign block the language has
// (c-cpp-calling.mdx, Inline ASM), so rejecting every other language leaves
// it alone. Pure coverage: it parses and type-checks inside `unsafe`.

fn tick() {
    unsafe { inline "asm" { "nop" } }
}

fn main() -> i32 {
    tick()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: {{error|warning}}
