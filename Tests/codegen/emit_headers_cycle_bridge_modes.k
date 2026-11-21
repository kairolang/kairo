// Every header of Lib/builtin and Lib/std compiles as the first and only
// include of a C++ file when kals' bridge modes write it, as
// emitted_headers_all.k checks for plain --emit-headers: the library's
// modules import each other in cycles, and in these modes a header in one
// keeps its declarations in `X.hh` and defers the rest to `X.tail.hh`,
// which the first header of the cycle a C++ file enters includes, so the
// order a C++ file includes them in does not matter.

// --- lit wiring ---
// REQUIRES: clang, default-sysroot
// RUN: rm -rf %t.lines %t.lay && mkdir -p %t.lines %t.lay
// RUN: python3 %S/../check_emitted_headers.py --headers %t.lines/h \
// RUN:   --root builtin=%S/../../Lib/builtin --root kairo/std=%S/../../Lib/std \
// RUN:   --no-header builtin/base/c_char.k --no-header builtin/base/ops.k \
// RUN:   --no-header builtin/interop/cxx_string.k \
// RUN:   --no-header kairo/std/ctypes.k --no-header kairo/std/mem.k \
// RUN:   --no-header kairo/std/utility.k --no-header kairo/std/module.k \
// RUN:   -- %kairo --emit-headers-line-directives -- %clangxx -std=c++23 -I %S/../../Lib | %FileCheck %s
// RUN: python3 %S/../check_emitted_headers.py --headers %t.lay/h \
// RUN:   --root builtin=%S/../../Lib/builtin --root kairo/std=%S/../../Lib/std \
// RUN:   --no-header builtin/base/c_char.k --no-header builtin/base/ops.k \
// RUN:   --no-header builtin/interop/cxx_string.k \
// RUN:   --no-header kairo/std/ctypes.k --no-header kairo/std/mem.k \
// RUN:   --no-header kairo/std/utility.k --no-header kairo/std/module.k \
// RUN:   -- %kairo --emit-headers-layout -- %clangxx -std=c++23 -I %S/../../Lib | %FileCheck %s
// CHECK: checked {{[0-9]+}} header(s), 0 problem(s)
