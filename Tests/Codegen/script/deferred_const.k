// A `const` binding whose initializer is not constant is deferred like a
// `var`: its storage becomes a writable `T?` that main assigns at its line,
// while the typer has already rejected every write the source makes to it,
// and a read still sees `const T`. A function reads it through the guard.

import std::io::println

fn load() -> i32 { return 5 }
fn show() -> i32 { return LIMIT + 1 }

println("first")
const LIMIT: i32 = load()
println(f"limit {LIMIT} {show()}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      ::builtin::Nullable<signed int> LIMIT =
// CXX:      int main() {
// CXX:      deferred_const::LIMIT = static_cast<{{ ?}}::builtin::Nullable<signed int>>({{ ?}}::deferred_const::load()));
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      first
// OUT-NEXT: limit 5 6
