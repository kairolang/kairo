// Only a vector, set or map type heads a `::` path; a fixed array or a
// slice names no record to step into.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s

fn main() -> i32 {
    // CHECK: container_type_head_error.k:[[@LINE+1]]:13: error [S001E]: only a vector '[T]', map '{K: V}' or set '{T}' type can head a '::' path
    var a = [i32; 4]::make()
    // CHECK: container_type_head_error.k:[[@LINE+1]]:13: error [S001E]: only a vector '[T]', map '{K: V}' or set '{T}' type can head a '::' path
    var b = [i32;]::make()
    return 0
}
