// A `..` after a symlinked directory climbs out of the link's TARGET, as the
// filesystem resolves it: `lnk/../null_main.cpp`, with `lnk` pointing at
// proj/inner, is proj/null_main.cpp, and its `#include "cells.k"` is
// proj/cells.k, a pathless module (`cells`) outside the working directory.
// Folding the `..` by text instead would name work/null_main.cpp, which does
// not exist.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// Creating a symlink needs a privilege Windows does not give by default.
// UNSUPPORTED: host-windows
// RUN: rm -rf %t.d && mkdir -p %t.d/proj/inner %t.d/work
// RUN: cp %S/inputs/null_host/cells.k %S/inputs/null_host/null_main.cpp %t.d/proj/
// RUN: ln -s %t.d/proj/inner %t.d/work/lnk
// RUN: cd %t.d/work && %kcc lnk/../null_main.cpp -o %t.d/via_link
// RUN: %t.d/via_link | %FileCheck %s --match-full-lines
// CHECK:      a null 1, b 4
// CHECK-NEXT: or_zero 0 4
// CHECK-NEXT: some 6, none null 1
// CHECK-NEXT: cell 3, d null 1
