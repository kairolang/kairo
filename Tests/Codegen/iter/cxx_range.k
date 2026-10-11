// A C++ class with begin()/end() iterates as C++ ranges it ([stmt.ranged]):
// member begin/end, or free begin(r)/end(r) by ADL, the range evaluated
// once, a const range through `begin() const`. Each shape below is one the
// operator machinery has to get right for the loop to type at all:
//   vector   __wrap_iter, whose `==` is a pair of free templates (partial
//            ordering) declared in another header than the class (ADL over
//            every reopening of `std`), and whose `!=` is C++20's `!(==)`
//   string   the same iterator over `char`: `==` must not be spelled with
//            Kairo's `i8` as its template argument
//   map/set  __tree_iterator, whose `==` is a hidden friend
//   Free     no members: free begin/end by ADL
//   Hf       begin/end as hidden friends: free, though in the class
//   Ptrs     a raw pointer iterator, `*x` writing through it

ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "map"
ffi "c++" import "set"
ffi "c++" import "cxx_range.h"

fn make() -> cxx::std::vector<i32> {
    var v: cxx::std::vector<i32>
    v.push_back(1)
    v.push_back(2)
    v.push_back(3)
    return v
}

fn sum(const v: cxx::std::vector<i32>) -> i32 {
    var s: i32 = 0
    for x in v { s += x }
    return s
}

fn main() -> i32 {
    var v = make()
    for *x in v { (*x) *= 10 }              // 10 20 30, written through the iterator
    var s = sum(v)                          // 60: a const range
    for x in make() { s += x }              // 66: a prvalue range, bound for the loop
    for x in v {
        if x == 20 { continue }
        if x == 30 { break }
        s += x                              // 76
    }
    for x in v { for y in v { if x == y { s += 1 } } }   // 79

    var t: cxx::std::string
    t.push_back(97)
    t.push_back(98)
    for c in t { s += 1 }                   // 81

    var m: cxx::std::map<i32, i32>
    m.insert_or_assign(1, 100)
    m.insert_or_assign(2, 200)
    for kv in m { s += kv.second }          // 381
    var st: cxx::std::set<i32>
    st.insert(3)
    st.insert(4)
    for x in st { s += x }                  // 388

    var f: rr::Free
    for x in f { s += x }                   // 394
    var h: rr::Hf
    for x in h { s += x }                   // 409
    var p: rr::Ptrs
    for *x in p { (*x) += 1 }               // 5 6
    for x in p { s += x }                   // 420
    return s - 300                          // 120: an exit code
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The loop over a const vector: begin/end through the range's address, the
// three operations on the iterator, advance before the body. `==` is spelled
// unqualified for ADL; whether its operands are cast to `const&` depends on
// the libc++ version's declaration.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      signed int sum(const std::vector<int, std::allocator<int>> & v) {
// CXX:      const std::vector<int, std::allocator<int>> * __kairo_rng{{[0-9]+}} =(& v);
// CXX-NEXT: std::__wrap_iter<const int *> __kairo_it{{[0-9]+}} =(* __kairo_rng{{[0-9]+}}).begin();
// CXX-NEXT: std::__wrap_iter<const int *> __kairo_end{{[0-9]+}} =(* __kairo_rng{{[0-9]+}}).end();
// CXX-NEXT: while((!operator ==({{.*}}__kairo_it{{[0-9]+}}{{.*}}, {{.*}}__kairo_end{{[0-9]+}}{{.*}}))) {
// CXX-NEXT: signed int x = {{.*}}__kairo_it{{[0-9]+}}.operator *(){{.*}};
// CXX-NEXT: __kairo_it{{[0-9]+}}.operator++();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 120
