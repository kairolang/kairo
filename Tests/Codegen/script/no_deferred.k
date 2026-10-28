// A script whose bindings are all constant defers nothing: no global
// becomes `T?` storage, and main gets no `finally` to tear any down. Its
// statements still run in order inside the synthesized main.

import std::io::println

const N: i32 = 4
var hits: i32 = 0
hits = hits + N
println(f"hits {hits}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      CODEGEN C++: {{.*}}no_deferred.k
// CXX-NOT:  Nullable
// CXX:      signed int const N = 4;
// CXX-NOT:  Nullable
// CXX:      signed int hits = 0;
// CXX-NOT:  Nullable
// CXX:      int main() {
// CXX-NOT:  __kairo_Fin
// CXX:      return 0;
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      hits 4
