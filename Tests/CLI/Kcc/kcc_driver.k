// kcc (Compiler/Driver/Kcc.k) takes a clang command line and runs it
// through kairo's CompilerInstance: clang options kairo has a flag for
// become that flag, the rest reach the C/C++ compiles verbatim, and
// -Xkairo passes one kairo word through.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// kcc answers --version itself.
// RUN: %kcc --version | %FileCheck %s --check-prefix=VERSION
// VERSION: installed version: kcc-

// C++ defaults to C++23; -std= reaches clang as given.
// RUN: %kcc -O2 -Wall %S/Inputs/std23.cc -o %t.d/std23
// RUN: %t.d/std23; test $? -eq 7
// RUN: %kcc -std=c++17 %S/Inputs/std17.cc -o %t.d/std17
// RUN: %t.d/std17

// A .cc that includes a .k, the .k named nowhere: built and linked. -D
// becomes kairo's --cxx-define. 3 + 2.
// RUN: %kcc -DVAL=3 %S/Inputs/main.cc -o %t.d/app -Xkairo --cache-dir=%t.d/o1
// RUN: %t.d/app; test $? -eq 5

// The include needs C++20 at least: an explicit lower -std= is refused at
// the include.
// RUN: { %kcc -std=c++17 -DVAL=3 -c %S/Inputs/main.cc -o %t.d/m17.o -Xkairo --cache-dir=%t.d/o2 2>&1 || true; } | %FileCheck %s --check-prefix=FLOOR
// FLOOR: main.cc:1:10: error [CL001E]: cannot include '{{.*}}geo.k': including a Kairo file needs C++20 or later

// -Xkairo hands kairo a word of its own.
// RUN: %kcc -Xkairo --verbose %S/Inputs/std23.cc -o %t.d/v 2>&1 | %FileCheck %s --check-prefix=XKAIRO
// XKAIRO: compilation:

// -emit-llvm modifies -S / -c, as in clang: IR text, or bitcode.
// RUN: %kcc -S -emit-llvm %S/Inputs/std23.cc -o %t.d/s.ll
// RUN: grep -q 'define .*@main' %t.d/s.ll
// RUN: %kcc -c -emit-llvm %S/Inputs/std23.cc -o %t.d/s.bc
// RUN: od -An -c -N2 %t.d/s.bc | grep -q 'B   C'
// RUN: { %kcc -emit-llvm %S/Inputs/std23.cc 2>&1 || true; } | %FileCheck %s --check-prefix=EMITLLVM
// EMITLLVM: kcc: error: -emit-llvm needs -S or -c

// Link-time clang words reach kairo's link, not just the C/C++ compiles.
// RUN: %kcc -s %S/Inputs/std23.cc -o %t.d/stripped
// RUN: %t.d/stripped; test $? -eq 7

// -### has no jobs to print yet.
// RUN: { %kcc -### %S/Inputs/std23.cc 2>&1 || true; } | %FileCheck %s --check-prefix=HASH
// HASH: kcc: error: '-###' is not supported yet
