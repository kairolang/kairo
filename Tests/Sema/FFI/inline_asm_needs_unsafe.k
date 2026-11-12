// An `inline "asm"` block belongs inside `unsafe` (c-cpp-calling.mdx, "Inline
// ASM"; c-cpp.mdx): the compiler cannot check what the assembly does. One
// outside any unsafe context was accepted; it is SC296E, with a
// fix-it that wraps the block. Inside an `unsafe { }` block or an unsafe
// function it stays legal, and other inline languages are not this check's.

fn plain() -> i32 {
    inline "asm" { "nop" : : : }
    return 0
}

fn wrapped() -> i32 {
    unsafe { inline "asm" { "nop" : : : } }
    return 0
}

fn whole() unsafe { inline "asm" { "nop" : : : } }

fn main() -> i32 { return plain() + wrapped() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: inline_asm_needs_unsafe.k:8:5: error [SC296E]: an inline assembly block must be inside 'unsafe': the compiler cannot check what the assembly does
// CHECK-NEXT: fix-it:"{{.*}}inline_asm_needs_unsafe.k":{8:5-8:5}:"unsafe { "
// CHECK-NEXT: fix-it:"{{.*}}inline_asm_needs_unsafe.k":{8:33-8:33}:" }"
