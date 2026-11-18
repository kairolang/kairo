// RUN: rm -rf %t.d
// RUN: %kairo %S/cxx_const_subscript_element_pointer_ok.k -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
// RUN: %kairo %S/cxx_const_subscript_element_pointer_ok.k -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// Element access on a const C++ container parameter is const: `&v[0]` is a
// pointer to const, so a write through it is a Kairo error (SC071E) rather
// than a clang failure in generated code. The reading form, in
// cxx_const_subscript_element_pointer_ok.k, builds and runs.
ffi "c++" import "vector"

class C { var x: i32 = 4 }

fn write_through_pointer(const v: cxx::std::vector<C>) -> i32 {
    var *y = &v[0]
    y->x = 5
    return y->x
}

fn write_through_subscript(const v: cxx::std::vector<C>) {
    v[0].x = 5
}

fn main() -> i32 { return 0 }

// CHECK: cxx_const_subscript_element_pointer.k:18:5: error [SC071E]: cannot assign to a field of '*y': 'y' points to const
// CHECK: cxx_const_subscript_element_pointer.k:17:10: note [I900N]: 'y' declared as a pointer to const here
// CHECK: cxx_const_subscript_element_pointer.k:23:5: error [SC071E]: cannot assign to a field of 'v': 'v' is const
// CHECK: cxx_const_subscript_element_pointer.k:22:34: note [I900N]: 'v' declared const here
// CHECK-NOT: error
