// G100a: a literal at an imported template-instance member whose parameter is
// `const char *` after substitution (`push_back(const T&)` / `push_back(T&&)`
// with T = const char *) is the C string, raw literals included. An lvalue
// reference to a non-const pointer cannot bind the decayed literal, as in C++.

import std::c_char

ffi "c++" import "c_string_literal_template_member.h"

fn main() {
    var v: Bag<*const c_char>
    v.push_back("plain")
    v.push_back(r"raw \n")
    var s: Sink
    s.put("x")
}

// --- lit wiring -----------------------------------------------------------

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: :15:{{.*}}error [
// CHECK-NOT: error [
