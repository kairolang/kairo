// Set and map literals on the two-word library are built as a vector
// literal is: the empty container, `reserve`, then one `insert` per element
// or entry, bound by overload resolution in the library's `extend` blocks.
// A key that cannot be copied is moved in.

fn build() -> i32 {
    var m: {string: i32} = {"a": 1, "b": 2}
    var s: {i32} = {1, 2, 3}
    return 0
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: %kairo %s --type-check-only
// RUN: %kairo %s --print-ir 2>&1 | %FileCheck %s
// CHECK: __kairo_ext_HashMap::reserve< ::builtin::string::string, signed int>((& m), static_cast<decltype(sizeof(0))>(2));
// CHECK: __kairo_ext_HashMap::insert< ::builtin::string::string, signed int>((& m), ::builtin::string::string( ::__kairo_slit_1_{{[0-9a-f]+}}.b, 1, 1), 1);
// CHECK: __kairo_ext_HashSet::reserve<signed int>((& s), static_cast<decltype(sizeof(0))>(3));
// CHECK: __kairo_ext_HashSet::insert<signed int>((& s), 1);
