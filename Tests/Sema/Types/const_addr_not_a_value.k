// `const &` of a name that is no value: a type, a module, a function.
// Each is the ordinary error its plain `&` gets (a type or a module is no
// value; a function names no object, so its address is that of a
// temporary), the run goes on to the next, and nothing aborts: `not`
// fails the test on a crash.

import std::io

struct P {
    var x: i32
}

fn f() -> i32 {
    return 1
}

fn main() -> i32 {
    var a = const &P
    var b = const &io
    var c = const &f
    var d = unsafe const &P
    return 0
}

// --- lit wiring ---
// RUN: not %kairo %s --type-check-only 2>&1 | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="internal compiler error"
// CHECK: const_addr_not_a_value.k:18:20: error [SC094E]: 'P' is a type, not a value
// CHECK: const_addr_not_a_value.k:19:20: error [SC094E]: 'io' is a module, not a value
// CHECK: const_addr_not_a_value.k:20:13: error [SC069E]: cannot take the address of a temporary
// CHECK: const_addr_not_a_value.k:21:27: error [SC094E]: 'P' is a type, not a value
