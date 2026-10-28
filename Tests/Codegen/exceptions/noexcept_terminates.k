// unwind_reaches_cxx.k without `@unwind`: `relay` is `noexcept`, so the C++
// exception `checked` throws reaches a noexcept Kairo frame and calls
// std::terminate -- the C++ `guard` above it never sees it, and the process
// aborts (SIGABRT, 134) with the C++ runtime's terminate message. Built with
// -funwind no Kairo function is noexcept, and the same program returns.
ffi "c++" import "guard.hh"

fn relay(x: i32) -> i32 {
    return checked(x) + 1
}

fn main() -> i32 {
    return 3 + guard(relay, -4)          // -1 under -funwind: 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: signed int relay(signed int x) noexcept {
// RUN: { %kairo %s -funwind --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=FUNWIND
// FUNWIND: signed int relay(signed int x) {

// REQUIRES: clang
// RUN: rm -rf %t.d %t.u
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=ERR < %t.err
// ERR: terminat{{.*}}runtime_error
// RUN: %kairo %s -funwind -o %t.u.exe --cache-dir %t.u
// RUN: %t.u.exe; test $? -eq 2
