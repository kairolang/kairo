// A C++ exception no `catch e: cxx::...` arm matches (PANIC.md §3.5): the
// function holding the `try` is noexcept, so the exception stops at its
// boundary and the program terminates (SIGABRT, 134), as one thrown
// anywhere else in a noexcept frame does. Nothing is caught by a bare
// `catch`: it discharges panics only.
ffi "c++" import "guard.hh"

struct Bad { var n: i32 }

fn parse(n: i32) panic(Bad) -> i32 {
    if n == 98 { panic Bad { n: n } }
    return n
}

fn wrong(x: i32) -> i32 {
    try { return parse(unlucky(x)) } catch e: cxx::std::runtime_error { return -1 } catch { return -2 }
}

fn main() -> i32 {
    return wrong(13)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=ERR < %t.err
// ERR: terminat{{.*}}logic_error
