// libc++ templates with a value argument: std::array's extent and
// std::bitset's width, written as literals, as eval constants and as
// arithmetic over them, nested inside each other and inside a vector, and
// taken by a generic Kairo function (through `size()`: a generic body still
// looks members up on the pattern, where `operator[]` and its const twin
// tie -- a separate gap). A chained subscript steps through the
// `reference` the inner `op []` returns (`array<i32, 2>&`).

ffi "c++" import "array"
ffi "c++" import "bitset"
ffi "c++" import "vector"

eval N: usize = 4

fn <T> count_of(a: cxx::std::array<T, 4>) -> usize {
    return a.size()
}

fn main() -> i32 {
    var a: cxx::std::array<i32, N>
    a.fill(2)
    a[1] = 5
    var b: cxx::std::array<i32, N * 2>
    var m: cxx::std::array<cxx::std::array<i32, 2>, 3>
    m[2][1] = 6
    var v: cxx::std::vector<cxx::std::array<i32, N>>
    v.push_back(a)
    v[0][3] = 1
    var bits: cxx::std::bitset<8>
    bits.set(3)
    bits.set(5)
    var r = a[1] + a.at(0) + a.front()                 // 5 + 2 + 2 = 9
    r += (a.size() + b.size()) as i32                  // 12
    r += m[2][1] + v[0][3] + (v.size() as i32)         // 6 + 1 + 1 = 8
    r += bits.count() as i32                           // 2
    r += count_of(a) as i32                            // 4
    return r                                           // 35
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 35
