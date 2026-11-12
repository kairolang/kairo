// An integer literal takes `byte` from its context (primitives.mdx, Byte:
// `var b: byte = 0xFF`, `var mask: byte = 0x0F`, then `b & mask`), as it
// takes any integer type's (primitives.mdx s5, literal inference: the
// literal is untyped until the context types it). Literal typing is not
// conversion, so this does not contradict the lattice's E for i32 -> byte:
// a TYPED i32 still needs `as` (matrix_i32.k), a bare literal does not.
// 0..255 fit; a negative literal or 256 does not.
//
// literal_fits_int and LiteralTyping.k treat
// byte like c_char8 (0..=0xFF), so each literal below types as byte. This test
// checks Sema only; that codegen spells the literal as a byte is a separate gap.

fn masked(b: byte) -> byte {
    var mask: byte = 0x0F;
    return b & mask;
}

fn main() -> i32 {
    var b: byte = 0xFF;
    var z: byte = 0;
    var r = masked(b);
    var w = masked(0xF0);
    return 0;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
