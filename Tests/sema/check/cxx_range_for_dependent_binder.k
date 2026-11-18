// A loop over a C++ range that depends on a type parameter is C++'s own
// range-for, and C++ spells only some binders: a typed binder is
// reported as an error.

ffi "c++" import "vector"

fn <T> f(v: cxx::std::vector<T>) {
    for x: i32 in v {}
}

// CHECK: cxx_range_for_dependent_binder.k:8:9: error [SC001E]: a loop over a C++ range that depends on a type parameter binds a name
// CHECK-NOT: I003E

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
