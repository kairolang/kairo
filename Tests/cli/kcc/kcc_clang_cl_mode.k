// kcc under clang-cl's command line: --driver-mode=cl, or a program name
// ending in -cl. clang-cl's options are read in either spelling (/c, -c),
// /Fo names the object, and kairo's own words (the target's roots, the
// action, the input) reach clang-cl through /clang:, so none of them is an
// unknown clang-cl argument or a second input. --freestanding keeps the
// test off an MSVC sysroot, which is not redistributable.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: printf 'int add(int a, int b) { return a + b; }\n' > %t.d/a.c
// RUN: printf 'int f(void) { return 1; }\n' > %t.d/b.txt

// Slash spellings, as CMake writes them for clang-cl.
// RUN: cd %t.d && %kcc --driver-mode=cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding /nologo /c /O2 a.c /Foslash.obj 2>&1 | %FileCheck %s --allow-empty
// RUN: od -An -tx1 -N2 %t.d/slash.obj | %FileCheck %s --check-prefix=COFF

// Dash spellings.
// RUN: cd %t.d && %kcc --driver-mode=cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding -nologo -c -O2 a.c -Fodash.obj 2>&1 | %FileCheck %s --allow-empty
// RUN: od -An -tx1 -N2 %t.d/dash.obj | %FileCheck %s --check-prefix=COFF

// A name ending in -cl is clang-cl's with no --driver-mode.
// RUN: ln -sf "$(dirname %kairo_bin)/kcc" %t.d/kcc-cl
// RUN: cd %t.d && ./kcc-cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding /nologo /c a.c /Foname.obj 2>&1 | %FileCheck %s --allow-empty
// RUN: od -An -tx1 -N2 %t.d/name.obj | %FileCheck %s --check-prefix=COFF

// With no /Fo the object is named as clang-cl names it, <stem>.obj; /Tc
// names one input's language, and an absolute path is an input.
// RUN: cd %t.d && %kcc --driver-mode=cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding /nologo /c a.c 2>&1 | %FileCheck %s --allow-empty
// RUN: od -An -tx1 -N2 %t.d/a.obj | %FileCheck %s --check-prefix=COFF
// RUN: cd %t.d && %kcc --driver-mode=cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding /c /Tcb.txt /Fotc.obj 2>&1 | %FileCheck %s --allow-empty
// RUN: od -An -tx1 -N2 %t.d/tc.obj | %FileCheck %s --check-prefix=COFF
// RUN: %kcc --driver-mode=cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding /c %t.d/a.c /Fo%t.d/abs.obj 2>&1 | %FileCheck %s --allow-empty
// RUN: od -An -tx1 -N2 %t.d/abs.obj | %FileCheck %s --check-prefix=COFF

// CHECK-NOT: warning
// CHECK-NOT: error
// COFF: 64 86

// The user's level and standard decide the C++ input's line (its cc1 line
// is the last one -### prints; the first is kairo's own): kairo's -O0 and
// -std=c++23 reach clang-cl through /clang:, after the user's words, so
// they are left off when /O or /std: is given.
// RUN: printf 'int h() { return 2; }\n' > %t.d/x.cc
// RUN: cd %t.d && %kcc --driver-mode=cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding /nologo /EHsc /O2 /std:c++20 /c x.cc /Fox.obj -### 2>&1 | tail -1 | %FileCheck %s --check-prefix=LEVEL
// LEVEL: -O3
// LEVEL-NOT: -O0
// LEVEL-SAME: -std=c++20
// LEVEL-NOT: -std=c++23

// /Fo naming a directory is refused rather than ignored.
// RUN: { cd %t.d && %kcc --driver-mode=cl --target=x86_64-pc-windows-msvc -Xkairo --freestanding /c a.c /Foout/ 2>&1 || true; } | %FileCheck %s --check-prefix=FODIR
// FODIR: kcc: error: clang-cl option '/Fo' names a directory; kcc needs the output file's name

// Outside clang-cl mode a clang-cl word is not an option: it is an input,
// and the last --driver-mode decides.
// RUN: { cd %t.d && %kcc --target=x86_64-pc-windows-msvc -Xkairo --freestanding /nologo -c a.c 2>&1 || true; } | %FileCheck %s --check-prefix=GNU
// RUN: { cd %t.d && %kcc --driver-mode=cl --driver-mode=gcc --target=x86_64-pc-windows-msvc -Xkairo --freestanding /nologo -c a.c 2>&1 || true; } | %FileCheck %s --check-prefix=GNU
// GNU: error [U011E]: /nologo: input has no extension
