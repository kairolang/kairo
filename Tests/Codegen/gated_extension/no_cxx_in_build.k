// A build in which NO file imports a C++ header: the bridge's conditional
// blocks are untaken branches. Nothing in them is resolved (`cxx` names
// nothing in this build, and that is no error), and the program's whole
// C++ names no C++ standard library type. This is the claim "a program
// that does not use libc++ does not pull it in": the build's header set
// is empty.

import self::bridge::*
import self::plain::*

fn main() -> i32 { return plain_len() - 9 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
// RUN: %kairo %s --print-ir | %FileCheck %s
// CHECK-NOT: __if__
// CHECK-NOT: std::basic_string
// CHECK-NOT: std::vector
// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=ARGS
// ARGS-NOT: takes.hh
