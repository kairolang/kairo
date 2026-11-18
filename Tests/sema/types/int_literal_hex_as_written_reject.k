// An out-of-range integer literal is quoted as written, in each base: the
// hex, binary and octal spellings keep their prefix, a decimal literal stays
// decimal, and an in-range literal is accepted.

fn main() -> i32 {
    var a: u8 = 0x1ff
    var b: u8 = 0b100000000
    var c: u8 = 300
    var d: u8 = 0xff
    var e: u8 = 0b11111111
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: int_literal_hex_as_written_reject.k:6:17: error [SC075E]: literal '0x1ff' does not fit in 'u8'
// CHECK: int_literal_hex_as_written_reject.k:7:17: error [SC075E]: literal '0b100000000' does not fit in 'u8'
// CHECK: int_literal_hex_as_written_reject.k:8:17: error [SC075E]: literal '300' does not fit in 'u8'
