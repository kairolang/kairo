// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// The header typedef `Byte` beside the builtin `Byte`: an import the file
// wrote shadows the builtin prelude, so the bare name is the header's.
// CHECK-NOT: header_typedef_builtin_name_use.k:7:{{.*}}R016E
// CHECK-NOT: R016E
// CHECK-NOT: error
ffi "c" import "header_typedef_builtin_name.h"

fn bare(b: Byte) -> i32 = one()

fn main() -> i32 {
    return 0
}
