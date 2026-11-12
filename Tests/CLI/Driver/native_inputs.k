// C and C++ inputs on a kairo command line are compiled by the pinned clang
// and linked with everything else; objects and archives go straight to the
// link. What an input IS comes from one classifier (Driver/InputKinds.k):
// clang's own type table, plus `.k` and the link inputs clang has no type for.
//
// Regression: Path::extension() keeps the dot (".cc"), and the driver must not
// compare against bare spellings ("cc", "o"), or every .c/.cc/.o here is
// lexed as Kairo and fails with R020E on `#include`.
//
// -x <lang> names the language of the inputs that FOLLOW it, as in clang;
// -x none goes back to the extension.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// A C and a C++ source, one link, the C calling into the C++.
// RUN: %kairo %S/Inputs/native_main.c %S/Inputs/native_add.cc -o %t.d/mixed --cache-dir %t.d/o1
// RUN: %t.d/mixed; test $? -eq 42

// -c -o names the one native object; that object is then a link input.
// RUN: %kairo %S/Inputs/native_add.cc -c -o %t.d/add.o
// RUN: test -s %t.d/add.o
// RUN: %kairo %S/Inputs/native_main.c %t.d/add.o -o %t.d/viaobj --cache-dir %t.d/o2
// RUN: %t.d/viaobj; test $? -eq 42

// -x c++ makes a .txt an input; -x none hands the next one back to its
// extension.
// RUN: %kairo -x c++ %S/Inputs/native_lang.txt -o %t.d/lang --cache-dir %t.d/o3
// RUN: %t.d/lang; test $? -eq 7
// RUN: %kairo -xc++ %S/Inputs/native_lang.txt -x none %S/Inputs/native_add.cc -c --cache-dir %t.d/o4
// RUN: test -s %t.d/o4/native_lang.o
// RUN: test -s %t.d/o4/native_add.o

// Inputs nothing can build stop the run before anything compiles, each one
// named.
// RUN: { %kairo %S/Inputs/native_lang.txt 2>&1 || true; } | %FileCheck %s --check-prefix=UNKNOWN
// UNKNOWN: error [U011E]: {{.*}}native_lang.txt: unknown input type '.txt'; name its language with -x <lang>
// RUN: not %kairo %S/Inputs/native_lang.txt > /dev/null 2>&1

// RUN: { %kairo -x fortran77 %S/Inputs/native_add.cc 2>&1 || true; } | %FileCheck %s --check-prefix=BADLANG
// BADLANG: error [U011E]: {{.*}}native_add.cc: language not recognized: 'fortran77'

// RUN: { %kairo -x kairo %S/Inputs/native_add.cc 2>&1 || true; } | %FileCheck %s --check-prefix=XKAIRO
// XKAIRO: error [U011E]: {{.*}}native_add.cc: -x kairo requires a .k file

// Assembly is a clang input like any other: the driver plans a -cc1as job,
// which runs in-process. CUDA / HIP go to clang's driver too, and what
// they need (a CUDA install) is clang's call, so nothing machine-independent
// is checked for them here.
// RUN: %kairo %S/Inputs/native_asm.s -c -o %t.d/asm.o
// RUN: test -s %t.d/asm.o

// RUN: { %kairo - 2>&1 || true; } < /dev/null | %FileCheck %s --check-prefix=STDIN
// STDIN: error [U011E]: -: standard input has no extension; name its language with -x <lang>

// A trailing -x tags nothing; the run still succeeds.
// RUN: %kairo %s --type-check-only -x c++ 2>&1 | %FileCheck %s --check-prefix=TRAIL
// TRAIL: warning [U025W]: '-x c++' after the last input has no effect
