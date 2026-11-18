// A `char` literal holds a Unicode scalar value: an escape above U+10FFFF or
// in the surrogate range U+D800-U+DFFF is rejected by the lexer, so a
// literal beyond the C++ character type's width is never emitted.

fn main() -> i32 {
    var past_end = '\U00110000'
    var surrogate = '\uD800'
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [CL"
// CHECK: char_literal_unicode_range.k:6:21: error [S030E]: unicode escape '\U00110000' is out of the valid unicode range (U+0000-U+10FFFF)
// CHECK: char_literal_unicode_range.k:7:22: error [S031E]: unicode escape '\uD800' encodes a surrogate code point (U+D800-U+DFFF), which is not a valid unicode scalar value
