// A `pub` function's by-value return type must be complete in what
// `#include "lib.k"` gives the host, or the C++ call is ill-formed. Was
// "calling 'name' with incomplete return type '::builtin::string::string'",
// and the same for a record of another Kairo module (other::P). 5 + 4.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/fn_sig_complete/host.cc -I %S/Inputs/fn_sig_complete -o %t.d/main
// RUN: %t.d/main; test $? -eq 9
