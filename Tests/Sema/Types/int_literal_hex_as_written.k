// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// SC075E quoted `0x100` by its decimal value, '256', a number the user
// never wrote. It quotes the literal as written.
// CHECK: error [SC075E]: literal '0x100' does not fit in 'u8'
fn main() -> i32 {
    var a: u8 = 0x100
    return 0
}
