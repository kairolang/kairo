// A character literal holds exactly one character, and a base prefix is
// followed by at least one digit: both are lexer errors.

fn main() -> i32 {
    var multi = 'ab'
    var empty = ''
    var esc   = '\n'
    var wide  = 'é'
    var hex   = 0x
    var bin   = 0b
    var ok    = 0xFF
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: malformed_char_and_prefix_literals.k:5:17: error [S001E]: character literal holds 2 characters; it must hold exactly one
// CHECK: fix-it:{{.*}}"\"ab\""
// CHECK: malformed_char_and_prefix_literals.k:6:17: error [S001E]: empty character literal
// CHECK: malformed_char_and_prefix_literals.k:9:17: error [S001E]: '0x' must be followed by at least one base-16 digit
// CHECK: malformed_char_and_prefix_literals.k:10:17: error [S001E]: '0b' must be followed by at least one base-2 digit
// CHECK-NOT: error
