// kals' clangd bridge: a layout header is laid out against the module's own
// .k file. left.k is small and instantiates the builtin Panic<T, E>, so most
// of its header's lines are attributed to panic_result.k; taking that file
// for the module's put a type-id guard's #ifndef in the prelude and its
// #endif in the header, and neither compiled. The header has to compile,
// with the module's own declaration on its own line.

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/../CLI/Kcc/Inputs/panic_headers && %kairo left.k --type-check-only --emit-headers %t.d/h --emit-headers-layout
// RUN: printf '#include "left.hh"\nint f() { return 0; }\n' > %t.d/use.cc
// RUN: { %clangxx -std=c++23 -fsyntax-only -I %t.d/h -I %S/../../Lib %t.d/use.cc 2>&1 || true; } | %FileCheck %s --check-prefix=CXX --allow-empty
// RUN: sed -n 3p %t.d/h/left.hh | %FileCheck %s --check-prefix=L3
// RUN: %FileCheck %s --check-prefix=PRE < %t.d/h/left.hh.prelude

// CXX-NOT: error

// L3: left(signed int k) noexcept;

// PRE-NOT: left(signed int k)
