// --cxx-std is forwarded to the clang invocation as -std=<value>; without it
// the default is c++23. Both spellings (=value and separate value) are accepted.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --cxx-std=c++23 | %FileCheck %s --check-prefix=STD23
// STD23: -std=c++23
// RUN: %kairo %s --print-clang-args --cxx-std gnu++20 | %FileCheck %s --check-prefix=GNU
// GNU: -std=gnu++20
// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=STDDEF
// STDDEF: -std=c++23
