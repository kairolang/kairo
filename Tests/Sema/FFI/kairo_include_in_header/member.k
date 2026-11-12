import self::member_dep
ffi "c++" import "member.h"

// The header includes a .k that this compilation already builds
// (member.k imports it), so the error says so.
fn main() -> i32 {
    return c_api(member_dep::helper())
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      member.h:2:10: error [R070E]: a C or C++ header imported from Kairo cannot include the Kairo source file 'member_dep.k' (it is already part of this compilation)
// CHECK-NEXT: member.k:2:18: note [I900N]: 'member.h' is imported here
// CHECK-NEXT: note [R070N]:
// CHECK-NOT:  {{error|warning}} [
