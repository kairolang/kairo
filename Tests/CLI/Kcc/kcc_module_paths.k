// A .k given on the command line is a module like any import: its module
// path is its path under the search dir that holds it (decision C), so a
// file compiled on its own and the same file imported or included elsewhere
// are one namespace, and objects from separate runs link. `kcc -c lib/y.k`
// emits `lib::y::f`, the name main.k (`import lib::y`) and use_y.cc
// (`#include "lib/y.k"`) call. While an input was an ENTRY it was namespace
// `y`, and both links failed on an undefined `lib::y::f`.
//
// `main` is the program's global `int main` wherever its file sits:
// sub/prog.k is module `sub::prog`, and its main still links and runs.
// y + main: 40 + 2; prog: 3 + 4.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// The module path, in the C++ (`hidden` is priv, and a module's priv decl
// keeps external linkage in the module's namespace).
// RUN: cd %S/Inputs/modpath && %kairo lib/y.k --type-check-only --print-cxx 2>&1 | %FileCheck %s --check-prefix=NS
// NS: namespace lib::y {
// NS-NOT: namespace y {
// NS-NOT: namespace {

// Separate runs, then a link of the objects.
// RUN: cd %S/Inputs/modpath && %kcc -c lib/y.k -o %t.d/y.o
// RUN: cd %S/Inputs/modpath && %kcc -c main.k -o %t.d/main.o
// RUN: %kcc %t.d/main.o %t.d/y.o -o %t.d/app && %t.d/app; test $? -eq 42

// A C++ includer in its own run, against the same y.o.
// RUN: cd %S/Inputs/modpath && %kcc -c use_y.cc -o %t.d/use_y.o
// RUN: %kcc %t.d/use_y.o %t.d/y.o -o %t.d/cxx && %t.d/cxx; test $? -eq 42

// An input in a subdirectory declaring main: global, not sub::prog::main.
// RUN: cd %S/Inputs/modpath && %kairo sub/prog.k --type-check-only --print-cxx 2>&1 | %FileCheck %s --check-prefix=MAIN
// MAIN: namespace sub::prog {
// MAIN-NEXT: signed int helper();
// MAIN-NOT: main
// RUN: cd %S/Inputs/modpath && %kairo sub/prog.k --print-ir -o %t.d/p_ir --cache-dir %t.d/c_ir 2>&1 | %FileCheck %s --check-prefix=MAINIR
// MAINIR: CODEGEN C++: {{.*}}sub/prog.k
// MAINIR: {{^}}int main() {
// MAINIR-NEXT: return( ::sub::prog::helper() + 4);
// RUN: cd %S/Inputs/modpath && %kcc sub/prog.k -o %t.d/prog && %t.d/prog; test $? -eq 7
// RUN: cd %S/Inputs/modpath && %kcc -c sub/prog.k -o %t.d/prog.o && %kcc %t.d/prog.o -o %t.d/prog2 && %t.d/prog2; test $? -eq 7
