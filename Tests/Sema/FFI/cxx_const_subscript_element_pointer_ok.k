// Reads the first element of a const std::vector through `&v[0]`: the
// pointer is to const and the program type-checks.
// Companion of cxx_const_subscript_element_pointer.k, which holds the run.
// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty --implicit-check-not=error
ffi "c++" import "vector"
class C { var x: i32 = 4 }
fn first(const v: cxx::std::vector<C>) -> i32 {
    var *y = &v[0]
    return y->x
}
fn main() -> i32 {
    var v = cxx::std::vector<C>()
    v.push_back(C())
    return first(v)
}
