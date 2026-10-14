// --cxx-std accepts c++20, c++23, c++26 and their gnu++ spellings. c++17 is
// rejected up front because Lib/builtin needs __builtin_coro_* and every compile
// at that level would die in R020E.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --cxx-std=c++17 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'c++17' for flag '--cxx-std'; accepted: c++20, c++23, c++26, gnu++20, gnu++23, gnu++26
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --cxx-std=c++26 || true; } | %FileCheck %s --check-prefix=OK
// OK: -std=c++26
