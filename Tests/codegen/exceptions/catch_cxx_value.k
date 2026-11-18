// A `try` with only C++ exception arms in a program with no panic at all
// (PANIC.md §3.5): the expression form's value goes through a raw slot,
// whose helper the preamble then writes on its own (no Panic lang item
// brings it). And an arm reads the exception through its binding, a
// reference to the thrown object: `e.what()`.
ffi "c++" import "guard.hh"

fn value(x: i32) -> i32 { return try checked(x) catch e: cxx::std::exception => -1 }

fn reads(x: i32) -> i32 {
    var r: i32 = 0
    try { r = checked(x) } catch e: cxx::std::exception { if e.what() != &null { r = -2 } }
    return r
}

fn main() -> i32 {
    if value(3) != 6 { return 1 }
    if value(-3) != -1 { return 2 }
    if reads(4) != 8 { return 3 }
    if reads(-4) != -2 { return 4 }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR:      CODEGEN C++: {{.*}}catch_cxx_value.k
// IR:      template<class T> union __kairo_raw {
// IR:      catch( ::std::exception & e) {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
