// An in-range integer literal converts implicitly to byte, like c_char and
// the integers; one that does not fit eight unsigned bits is still SC075E.
fn main() -> i32 {
    var b: byte = 0xFF
    var mask: byte = 0x0F
    var lo: byte = 0
    var r = b & mask
    var bad: byte = 0x100
    var neg: byte = -1
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: SC031W
// CHECK-NOT: byte_literal_conversion.k:4:{{.*}}error
// CHECK-NOT: byte_literal_conversion.k:5:{{.*}}error
// CHECK-NOT: byte_literal_conversion.k:6:{{.*}}error
// CHECK-NOT: byte_literal_conversion.k:7:{{.*}}error
// CHECK: byte_literal_conversion.k:8:{{.*}}error {{.*}}SC075E{{.*}}'256'
// CHECK: byte_literal_conversion.k:9:{{.*}}error {{.*}}SC075E{{.*}}'byte'
