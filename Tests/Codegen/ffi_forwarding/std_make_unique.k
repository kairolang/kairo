// std::make_unique itself. libc++ declares three overloads told apart only
// by SFINAE on an `enable_if_t<...> = 0` parameter (single object, array of
// unknown bound, deleted array of known bound); Kairo cannot evaluate the
// condition, so all three are viable and tie.
//
// XFAIL: *
// Waiting on SFINAE for imported function templates: SC064E "call to
// 'make_unique' is ambiguous". The forwarding itself works (a user
// make_unique without the SFINAE split: user_forward.k's make_box).
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

ffi "c++" import "memory"

fn main() -> i32 {
    var up = cxx::std::make_unique<i32>(9)
    return *up
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
