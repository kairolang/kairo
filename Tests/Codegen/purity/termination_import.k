// A function's termination proof is its definition's: an imported function
// and a forward declaration carry the attribute only where the body that
// defines them was proven. The fixture is Inputs/termination_import/.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/termination_import && { %kairo main.k -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: (({{const|pure}})) signed int {{spin|caller|late|w_late}}(

// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/termination_import && %kairo main.k -finfer-purity -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe
