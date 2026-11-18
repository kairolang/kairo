// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// The header typedef `Byte` beside the builtin `Byte` is ambiguous only
// where the bare name is used, not at the import.
// CHECK-NOT: header_typedef_builtin_name_use.k:7:{{.*}}R016E
// CHECK: header_typedef_builtin_name_use.k:9:{{[0-9]+}}: error [R016E]: ambiguous import: 'Byte'
// CHECK-NOT: error
ffi "c" import "header_typedef_builtin_name.h"

fn bare(b: Byte) -> i32 = one()

fn main() -> i32 {
    return 0
}
