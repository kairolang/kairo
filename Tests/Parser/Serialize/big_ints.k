// Numeric literals in a serialized AST. An integer literal's payload is its
// value, not its text: 64 bits, 128 bits, or a big integer's limbs when it
// needs more (ImmBigInt), with its base, suffix width and flags. A float's
// is its IEEE binary128 bits, and a big float's mantissa and exponent when
// the literal is beyond that. The reader re-creates each slot from those
// values, so the reloaded literal is the lexer's bit for bit.

fn main() -> i32 {
    var small: u8  = 255
    var hexed      = 0xDEAD_BEEFu32
    var binary     = 0b1010_1010
    var octal      = 0o755
    var suffixed   = 42i64
    var sized      = 7usize
    var wide64:  u64  = 18446744073709551615
    var wide128: u128 = 340282366920938463463374607431768211455
    var wide200: u256 = 1606938044258990275541962092341162602522202993782792835301376
    var wide512: u512 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF
    var f:   f64 = 3.141592653589793
    var g:   f32 = 2.5f32
    var h        = 0x1.8p3
    var e        = 6.02214076e23
    var tiny     = 1e-300
    var huge: f256 = 1.61132571748576047361957211845200501064402387454966951747637125049607183e78913f256
    return (small as i32) - 255
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --verify-ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=VERIFY --allow-empty
// VERIFY-NOT: I002F
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } > %t.parsed
// RUN: { %kairo %s --syntax-only --print-ast=tree --ast-roundtrip 2>/dev/null || true; } > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
//
// What Sema makes of the literals (whether each fits its type, what it
// folds to) reads the reloaded slots, so its verdicts are the same ones.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag.parsed
// RUN: { %kairo %s --type-check-only --ast-roundtrip 2>&1 || true; } > %t.diag.reloaded
// RUN: diff %t.diag.parsed %t.diag.reloaded
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } > %t.sema.parsed
// RUN: { %kairo %s --type-check-only --print-sema --ast-roundtrip 2>&1 || true; } > %t.sema.reloaded
// RUN: diff %t.sema.parsed %t.sema.reloaded
// RUN: { %kairo %s --type-check-only --print-lowered 2>&1 || true; } > %t.low.parsed
// RUN: { %kairo %s --type-check-only --print-lowered --ast-roundtrip 2>&1 || true; } > %t.low.reloaded
// RUN: diff %t.low.parsed %t.low.reloaded
