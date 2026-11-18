// OperatorSemantics: an imported `operator[]` returns `int&`; arithmetic on
// what it names is still Kairo's i32 arithmetic (the reference is looked
// through), so `v[0] += 1` at i32's maximum wraps, and the place -- one
// call of `operator[]` -- is evaluated once.

ffi "c++" import "vector"

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(2147483647)
    v[0] += 1
    v[0]++
    return v[0] + 2147483647        // -2147483647 + 2147483647 == 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: auto & __kairo_p0 =(v.operator[](0));
// CXX-NEXT: __kairo_p0 = static_cast<signed int>(static_cast<unsigned int>(__kairo_p0) + static_cast<unsigned int>(1));
