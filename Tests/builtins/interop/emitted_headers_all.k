// Every file of Lib/builtin and Lib/std has a C++ header that compiles
// on its own, whichever header a C++ file includes first: the library's
// modules import each other in cycles (containers/slice and
// containers/vector, base/hash, string, errors/crash), so each header of a
// cycle comes as two files, `X.hh` and its declaration part `X.decl.hh`.
// The files listed by --no-header declare nothing C++ can name (type
// aliases, re-exports, an interface with no conformer, conditional
// extensions), so they get no header.

// --- lit wiring ---
// REQUIRES: clang, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: python3 %S/../../check_emitted_headers.py --headers %t.d/h \
// RUN:   --root builtin=%S/../../../Lib/builtin --root kairo/std=%S/../../../Lib/std \
// RUN:   --no-header builtin/base/c_char.k --no-header builtin/base/ops.k \
// RUN:   --no-header builtin/interop/cxx_string.k \
// RUN:   --no-header kairo/std/ctypes.k --no-header kairo/std/mem.k \
// RUN:   --no-header kairo/std/utility.k --no-header kairo/std/module.k \
// RUN:   -- %kairo -- %clangxx -std=c++23 -I %S/../../../Lib | %FileCheck %s
// CHECK: checked {{[0-9]+}} header(s), 0 problem(s)
