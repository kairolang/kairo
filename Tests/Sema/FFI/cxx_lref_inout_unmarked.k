// A bare variable passed to a C++ non-const `T&` parameter is the missing
// `@inout` marker, SC097E with the `&` fix-it, as for a Kairo `@inout`
// (decided 2026-11-08). A const `T&` takes it by value as
// before, and an operator's operand (`a += b` on a C++ type) has no
// marker to write and binds as C++ does.

ffi "c++" import "cxx_lref_inout.h"
ffi "c++" import "string"

fn main() -> i32 {
    var x = 4
    var d = D()
    var a = inc(x)
    var b = bump(d)
    var s = cxx::std::string("a")
    s += cxx::std::string("b")
    return a + b + (s.size() as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: cxx_lref_inout_unmarked.k:13:17: error [SC097E]: argument to '@inout' parameter 'x' must be marked with '&'
// CHECK: fix-it:"{{.*}}cxx_lref_inout_unmarked.k":{13:17-13:17}:"&"
// CHECK: cxx_lref_inout_unmarked.k:14:18: error [SC097E]: argument to '@inout' parameter 'b' must be marked with '&'
// CHECK: fix-it:"{{.*}}cxx_lref_inout_unmarked.k":{14:18-14:18}:"&"
