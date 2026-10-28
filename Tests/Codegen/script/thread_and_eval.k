// `thread` and `eval` bindings are never deferred, whatever their
// initializer: an `eval` one is a constant by definition, and a `thread`
// one keeps C++'s per-thread first-use initialization (`thread_local`).
// Neither becomes `T?` storage, and main assigns neither.

import std::io::println

fn seed() -> i32 { return 9 }
eval fn square(x: i32) -> i32 { return x * x }

eval SQ: i32 = square(3)
thread T: i32 = seed()
println(f"{SQ} {T}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      CODEGEN C++: {{.*}}thread_and_eval.k
// CXX-NOT:  Nullable
// CXX:      constexpr signed int const SQ = {{ ?}}::thread_and_eval::square(3);
// CXX-NOT:  Nullable
// CXX:      thread_local signed int T = {{ ?}}::thread_and_eval::seed();
// CXX-NOT:  Nullable
// CXX:      int main() {
// CXX-NOT:  thread_and_eval::T =
// CXX-NOT:  thread_and_eval::SQ =
// CXX:      return 0;
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      9 9
