// A C++ file that includes a Kairo file compiles the Kairo stream in its
// own clang parse (kcc's `#include "lib.k"`). The Sema agreement pass
// walks that stream too. A disagreement there is Kairo's finding: I012W, a
// warning at the Kairo call, and nothing against the C++ file.
//
// Inputs/host: lib.k has `fn <T> twice` calling `chosen`, a body the host
// compiles itself; the hidden --test-sema-agreement-swap=chosen:other
// tells the pass that Kairo bound that call to `other`.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/host && %kcc main.cpp -o %t.d/app -Xkairo --cache-dir=%t.d/c -Xkairo -v -Xkairo -fsema-agreement -Xkairo --test-sema-agreement-swap=chosen:other -Xkairo --error-format=basic 2>&1 | %FileCheck %s --check-prefix=WARN
// WARN-NOT: main.cpp:{{[0-9]+}}:{{[0-9]+}}: {{warning|error}}
// WARN: sema agreement: 1 calls recorded, 1 joined, {{.*}} 1 disagreed in the Kairo files a C++ translation unit includes
// WARN: lib.k:7:40: warning [I012W]: internal: clang resolved this call to 'lib::chosen(int)', but Kairo's Sema chose 'other'; this is a compiler bug
// WARN-NEXT: lib.k:5:8: note [I900N]: Kairo's Sema chose this declaration
// WARN-NEXT: lib.k:4:8: note [I900N]: clang resolved the call to this declaration
// WARN-NOT: : error
//
// The two have one type, so the host's call goes to Kairo's choice.
// RUN: %t.d/app; test $? -eq 99
//
// -fno-sema-agreement-repair reports and leaves clang's choice.
// RUN: cd %S/Inputs/host && %kcc main.cpp -o %t.d/app -Xkairo --cache-dir=%t.d/c -Xkairo -fsema-agreement -Xkairo -fno-sema-agreement-repair -Xkairo --test-sema-agreement-swap=chosen:other -Xkairo --error-format=basic 2>&1 | %FileCheck %s --check-prefix=LEFT
// LEFT: lib.k:7:40: warning [I012W]
// RUN: %t.d/app; test $? -eq 0
//
// A compiler that only counts says nothing; off, nothing is looked at.
// RUN: cd %S/Inputs/host && %kcc main.cpp -o %t.d/app -Xkairo --cache-dir=%t.d/c -Xkairo -v -Xkairo --test-sema-agreement-quiet -Xkairo --test-sema-agreement-swap=chosen:other -Xkairo --error-format=basic 2>&1 | %FileCheck %s --check-prefix=QUIET
// QUIET-NOT: I012W
// QUIET: 1 disagreed in the Kairo files a C++ translation unit includes
// QUIET-NOT: I012W
// RUN: cd %S/Inputs/host && %kcc main.cpp -o %t.d/app -Xkairo --cache-dir=%t.d/c -Xkairo -v -Xkairo -fno-sema-agreement -Xkairo --test-sema-agreement-swap=chosen:other -Xkairo --error-format=basic 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF-NOT: sema agreement:
// OFF-NOT: I012W
// OFF: compilation:
// RUN: %t.d/app; test $? -eq 0
