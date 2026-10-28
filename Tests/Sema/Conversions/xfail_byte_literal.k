// An integer literal takes `byte` from its context (primitives.mdx, Byte:
// `var b: byte = 0xFF`, `var mask: byte = 0x0F`, then `b & mask`), as it
// takes any integer type's (primitives.mdx s5, literal inference: the
// literal is untyped until the context types it). Literal typing is not
// conversion, so this does not contradict the lattice's E for i32 -> byte:
// a TYPED i32 still needs `as` (matrix_i32.k), a bare literal does not.
// 0..255 fit; a negative literal or 256 does not.
//
// XFAIL: *
// Ticket "[Sema] An integer literal does not take `byte` from its context"
// (2026-10-28). Today each literal below is SC028E "cannot convert 'i32' to
// 'byte'; the conversion may lose value and needs an explicit 'as'":
// Conversion.k's literal_fits_int answers false for every non-integer
// builtin, and has a clause for c_char (0..127) but none for byte (0..255).
// The literal then defaults to i32 and the lattice refuses it. Codegen must
// also spell a byte literal (byte is the Byte lang item, a class), so the
// fix is not Sema alone. When it XPASSes, delete the XFAIL.

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
