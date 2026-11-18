// The ffi spelling of a C++ header import; the body is shared with
// angle_header_import_rejected.k, whose `import <vector>` is rejected.

ffi "c++" import "vector"

fn main() -> i32 {
    var v = cxx::std::vector<i32>()
    v.push_back(2)
    return v[0]
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error ['
// CHECK-NOT: error
