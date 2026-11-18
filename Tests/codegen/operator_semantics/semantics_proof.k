// OperatorSemantics: the C++ spellings of the wrap forms, proven in clang's
// constant evaluator (inputs/semantics.cpp). A division by zero in a constant
// expression is a compile error, not a value (-DBAD, -verify).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: %clangxx -std=c++2c -fsyntax-only %S/inputs/semantics.cpp
// RUN: %clangxx -std=c++2c -fsyntax-only -DBAD -Xclang -verify %S/inputs/semantics.cpp
