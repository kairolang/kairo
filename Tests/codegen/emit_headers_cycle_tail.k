// kals' clangd bridge over two user modules that import each other
// (inputs/header_cycle: a.k and b.k), so their headers sit in one include
// cycle. With --emit-headers-line-directives and --emit-headers-layout each
// header keeps its declarations in `X.hh`, on the lines plain layout gives
// them, and what needs the whole cycle (tier 3, the bodies) is its tail
// `X.tail.hh`, included by the first header of the cycle a C++ file enters.
// Whichever header a C++ file includes first, and in either mode, the
// headers compile.

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/inputs/header_cycle && { %kairo top.k --type-check-only --emit-headers %t.d/lines --emit-headers-line-directives 2>&1 || true; } | %FileCheck %s --check-prefix=WARN
// RUN: cd %S/inputs/header_cycle && { %kairo top.k --type-check-only --emit-headers %t.d/lay --emit-headers-layout 2>&1 || true; } | %FileCheck %s --check-prefix=WARN
// RUN: printf '#include "a.hh"\nint f() { return 0; }\n' > %t.d/a_first.cc
// RUN: printf '#include "b.hh"\nint f() { return 0; }\n' > %t.d/b_first.cc
// RUN: printf '#include "b.hh"\n#include "a.hh"\n#include "top.hh"\nint f() { return 0; }\n' > %t.d/both.cc
// RUN: %clangxx -std=c++23 -fsyntax-only -I %t.d/lines -I %S/../../Lib %t.d/a_first.cc
// RUN: %clangxx -std=c++23 -fsyntax-only -I %t.d/lines -I %S/../../Lib %t.d/b_first.cc
// RUN: %clangxx -std=c++23 -fsyntax-only -I %t.d/lines -I %S/../../Lib %t.d/both.cc
// RUN: %clangxx -std=c++23 -fsyntax-only -I %t.d/lay -I %S/../../Lib %t.d/a_first.cc
// RUN: %clangxx -std=c++23 -fsyntax-only -I %t.d/lay -I %S/../../Lib %t.d/b_first.cc
// RUN: %clangxx -std=c++23 -fsyntax-only -I %t.d/lay -I %S/../../Lib %t.d/both.cc

// Line mode: the declarations under `#line` naming their .k lines, the
// tail under its own, and no declaration part.
// RUN: %FileCheck %s --check-prefix=LINES < %t.d/lines/a.hh
// RUN: grep -B1 'class Apple {' %t.d/lines/a.hh | %FileCheck %s --check-prefix=APPLE
// RUN: %FileCheck %s --check-prefix=LTAIL < %t.d/lines/a.tail.hh
// RUN: test ! -e %t.d/lines/a.decl.hh && test ! -e %t.d/lines/b.decl.hh

// Layout: each declaration on its .k line, the tail apart.
// RUN: sed -n 5p %t.d/lay/a.hh | %FileCheck %s --check-prefix=A5
// RUN: sed -n 18p %t.d/lay/a.hh | %FileCheck %s --check-prefix=A18
// RUN: sed -n 22p %t.d/lay/a.hh | %FileCheck %s --check-prefix=A22
// RUN: sed -n 4p %t.d/lay/b.hh | %FileCheck %s --check-prefix=B4
// RUN: sed -n 16p %t.d/lay/b.hh | %FileCheck %s --check-prefix=B16
// RUN: %FileCheck %s --check-prefix=LAYTAIL < %t.d/lay/a.tail.hh
// RUN: %FileCheck %s --check-prefix=ROOT < %t.d/lay/a.hh
// RUN: test -e %t.d/lay/a.hh.prelude && test ! -e %t.d/lay/a.tail.hh.prelude && test ! -e %t.d/lay/a.decl.hh

// A header outside the cycle has no tail.
// RUN: test ! -e %t.d/lines/top.tail.hh && test ! -e %t.d/lay/top.tail.hh

// WARN: warning [R058W]: import cycle

// LINES: #pragma once
// LINES: #define __KAIRO_HDR_a_x2Ehh
// LINES: #ifdef __KAIRO_HDR_ROOT_a_x2Ehh
// LINES-NEXT: #ifndef __KAIRO_HDR_b_x2Ehh
// LINES-NEXT: #include "b.hh"
// LINES-NEXT: #endif
// LINES-NEXT: #include "a.tail.hh"
// LINES-NEXT: #include "b.tail.hh"
// LINES-NEXT: #endif

// APPLE: #line 5 "{{.*}}a.k"

// LTAIL: #line 2 "{{.*}}a.tail.hh"
// LTAIL-NEXT: #pragma once
// LTAIL: #include "b.tail.hh"
// LTAIL: #line 22 "{{.*}}a.k"
// LTAIL: inline{{.*}}apple_of(

// A5: class Apple
// A18: apple_count(
// A22: apple_of(
// B4: class Banana
// B16: class Basket

// The template's body is left out, as plain layout leaves it out: its
// declaration holds its line.
// LAYTAIL: #pragma once
// LAYTAIL-NEXT: #include "b.tail.hh"
// LAYTAIL-NOT: apple_of

// ROOT: #ifdef __KAIRO_HDR_ROOT_a_x2Ehh
// ROOT: #include "a.tail.hh"
