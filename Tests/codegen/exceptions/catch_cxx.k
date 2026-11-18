// `catch e: cxx::...` (PANIC.md §3.5): a Kairo `try` catching a C++
// exception from a C++ call lexically inside it. The function holding the
// `try` stays noexcept: PanicLowering keeps a C++ `try` around the lowered
// body (§4.5a H), so the exception is caught inside the frame. Alone (the
// body cannot panic), beside panic arms (the slot form: a failing site
// jumps out of the C++ try to the dispatch after it), and in the
// expression form, with and without a panic in the operand; and a
// caught exception panicked on.
ffi "c++" import "guard.hh"

struct Bad { var n: i32 }

fn parse(n: i32) panic(Bad) -> i32 {
    if n == 98 { panic Bad { n: n } }
    return n
}

fn only(x: i32) -> i32 {
    try { return checked(x) } catch e: cxx::std::runtime_error { return -1 }
}

fn mixed(x: i32) -> i32 {
    var r: i32 = 0
    try {
        r = checked(x)
        r = parse(r)
    } catch e: cxx::std::exception {
        r = -2
    } catch e: Bad {
        r = -3 - e.n
    }
    return r
}

fn expr(x: i32) -> i32 { return try checked(x) catch e: cxx::std::exception => -4 }

fn expr_mixed(x: i32) -> i32 {
    return try parse(checked(x)) catch e: cxx::std::exception => -5 catch e: Bad => -6
}

// The first arm that matches, as in C++: logic_error is not a runtime_error.
fn order(x: i32) -> i32 {
    try { return unlucky(x) } catch e: cxx::std::runtime_error { return -7 } catch e: cxx::std::logic_error { return -8 }
}

// `panic e` of a caught C++ exception panics a copy of it (the arm's type,
// a C++ value like any other payload, §1.5), with this site; a caller then
// catches it as a panic: a C++ type IN the set is a panic arm.
fn rethrow(x: i32) panic -> i32 {
    try { return checked(x) } catch e: cxx::std::runtime_error { panic e }
}

fn caught_again(x: i32) -> i32 { return try rethrow(x) catch e: cxx::std::runtime_error => -9 }

fn main() -> i32 {
    if only(5) != 10 { return 1 }
    if only(-1) != -1 { return 2 }
    if mixed(3) != 6 { return 3 }
    if mixed(-1) != -2 { return 4 }
    if mixed(49) != -101 { return 5 }
    if expr(4) != 8 { return 6 }
    if expr(-1) != -4 { return 7 }
    if expr_mixed(2) != 4 { return 8 }
    if expr_mixed(-1) != -5 { return 9 }
    if expr_mixed(49) != -6 { return 10 }
    if order(-1) != -7 { return 11 }
    if order(13) != -8 { return 12 }
    if caught_again(-1) != -9 { return 13 }
    if caught_again(3) != 6 { return 14 }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR:      signed int only(signed int x) noexcept {
// IR-NEXT:     try {
// IR:          catch( ::std::runtime_error & e) {
// IR:      signed int order(signed int x) noexcept {
// IR:          catch( ::std::runtime_error & e) {
// IR:          catch( ::std::logic_error & e) {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
