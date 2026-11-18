// A class template that is only forward-declared in the imported header is
// incomplete: constructing it is clang's "implicit instantiation of undefined
// template" (CL001E), naming the header's declaration.

ffi "c++" import "fwd.h"

fn main() -> i32 {
    var w = fx::Wrap<i32>()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: incomplete_use.k:8:9: error [CL001E]: implicit instantiation of undefined template 'fx::Wrap<int>'
// CHECK-NEXT: fwd.h:3:27: note [I900N]: template is declared here
