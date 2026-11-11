// A `fn` value made from a C++ function that may throw was held as
// the noexcept function pointer, so a throw from it unwound the noexcept
// Kairo frames with no terminate landing pad: here it reached guard's C++
// catch past `relay` and the program returned -1. c-cpp-exceptions.mdx: a
// C++ exception that reaches a noexcept Kairo frame terminates the program
// ("Without @unwind on relay, the same program aborts"). The `fn` value
// calls the C++ function through a noexcept thunk, which terminates.
// A non-throwing call through the same value still returns normally.

ffi "c++" import "fn_value_throwing_cxx.hh"

fn relay(x: i32) -> i32 {
    var f: fn(i32) -> i32 = checked
    return f(x)
}

fn main(argc: i32) -> i32 {
    if argc > 1 {
        return guard(relay, -4)
    }

    return guard(relay, 3)
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.d/a --cache-dir %t.d/c
// RUN: %t.d/a; test $? -eq 6
// RUN: not --crash %t.d/a throw 2> %t.d/err
// RUN: %FileCheck %s < %t.d/err
// CHECK: terminating due to uncaught exception
