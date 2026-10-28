// The classic SFINAE pair: `vector::assign` / `insert` take either
// (count, value) or an iterator range (InputIt first, InputIt last). With
// two u32 arguments into a vector<u64>, the iterator templates deduce
// InputIt := u32 and bind both at Exact while the count overload needs a
// widening for each. libc++ splits its templates by iterator category
// (input vs forward) with enable_if, so Kairo alone found every call here
// ambiguous, real iterators included (SC064E). Clang's substitution now
// removes the templates whose category test fails: the count overload is
// the one candidate left for integers, one template for real iterators.

ffi "c++" import "vector"

fn main() -> i32 {
    var v: cxx::std::vector<u64>
    var n: u32 = 3
    var x: u32 = 5
    v.assign(n, x)                              // [5, 5, 5]
    v.insert(v.cbegin(), n, x)                  // [5, 5, 5, 5, 5, 5]
    var w: cxx::std::vector<u64>
    w.assign(v.begin(), v.end())                // the iterator template, still
    w.insert(w.cend(), v.begin(), v.end())
    var r = (v.size() as i32) + (w.size() as i32)     // 6 + 12 = 18
    r += (v[0] + w[11]) as i32                         // 10
    return r                                           // 28
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 28
