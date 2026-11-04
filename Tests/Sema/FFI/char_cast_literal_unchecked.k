// G100b: an explicit `as char` from an integer literal that fits u32 is
// unchecked (ruling 2026-11-04): `0xFFFFFFFF as char` is the sentinel, not a
// trap. The scalar-value range test is for the IMPLICIT literal adaptation:
// `var c: char = 0xFFFFFFFF` is still SC075E.

fn take(c: char) -> char { return c }

fn main() {
    var q: *u8
    var a = take(if q[0] < 0x80 => (q[0] as char) else => (0xFFFFFFFF as char))
    var b = (0x110000 as char)
    var c = (0xD800 as char)
    var d = (0x41 as char)
    var e: char = 0xFFFFFFFF
}

// --- lit wiring -----------------------------------------------------------

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: :14:{{.*}}error [SC075E]: literal '4294967295' is not a Unicode scalar value
// CHECK-NOT: error [
