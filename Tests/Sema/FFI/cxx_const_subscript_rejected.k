// Sema chose an imported `operator[]` from an unqualified receiver, so
// a write through a const std::vector and a read of a const std::map (whose
// only `operator[]` is non-const: it inserts) passed --type-check-only and
// failed in clang (CL001E). Both are Kairo errors, as in C++.
ffi "c++" import "map"
ffi "c++" import "vector"

fn vec_write(const v: cxx::std::vector<i32>) {
    v[0] = 1
}

fn map_read(const m: cxx::std::map<i32, i32>) -> i32 {
    return m[0]
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: cxx_const_subscript_rejected.k:9:5: error [SC071E]: cannot assign to an element of 'v': 'v' is const
// CHECK: cxx_const_subscript_rejected.k:8:20: note [I900N]: 'v' declared const here
// CHECK: cxx_const_subscript_rejected.k:13:12: error [SC063E]: no matching overload for call to 'op []'
// CHECK: {{.*}}map:{{[0-9]+:[0-9]+}}: note [I900N]: candidate not viable: 'op []' is not const; it cannot be called on a const object
// CHECK: {{.*}}map:{{[0-9]+:[0-9]+}}: note [I900N]: candidate not viable: 'op []' is not const; it cannot be called on a const object
// CHECK-NOT: error
