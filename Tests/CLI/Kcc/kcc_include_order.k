// One header search order for both clang lines (Config/Invocation.k
// clang_include_dirs): the user's -I dirs first, the runtime root (Lib, for
// `rt/fmt.h`) after them, on the cc1 line kcc builds for the Kairo TU and on
// the driver line of a C/C++ input alike. The driver line used to put the
// runtime root FIRST, so a quoted include present under both Lib and a user
// -I dir named Lib's file there, the user's on the cc1 line, and the user's
// in the `#include "x.k"` scan.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc
// RUN: cd %S/Inputs/modpath && %kcc -### -I %S/Inputs/modpath/sub -c use_y.cc 2>&1 | %FileCheck %s
// Each line: the user's dir, then Lib -- never Lib first.
// CHECK:     -cc1 {{.*}}-I {{[^ ]*}}modpath/sub {{.*}}-I {{[^ ]*}}/Lib{{ |$}}
// CHECK:     -cc1 {{.*}}-main-file-name use_y.cc {{.*}}-I {{[^ ]*}}modpath/sub {{.*}}-I {{[^ ]*}}/Lib{{ |$}}
