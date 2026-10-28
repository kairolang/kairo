// Kairo classes through SFINAE. Clang sees a Kairo class as a stand-in
// with its fields and none of its methods, so a rejection it makes over
// one is soft: the template stays viable and loses any tie to one clang
// accepted. A FIELD test (`void_t<decltype(t.a)>`) is answered truly by
// the stand-in, so field_a picks right both ways; `make_unique<Cp>` drops
// the array overloads (Cp is no array) the same way. A lone template a
// stand-in cannot satisfy still binds (CLI/Driver/cxx_template_ref_control.k).

ffi "c++" import "memory"
ffi "c++" import "sfinae.h"

class WithA {
    pub var a: i32 = 0
    fn WithA(self, a: i32) { self.a = a }
}

class NoA {
    pub var b: i32 = 0
    fn NoA(self, b: i32) { self.b = b }
}

fn main() -> i32 {
    var w = WithA(9)
    var n = NoA(4)
    var r = field_a(w)                          // 9: has a field `a`
    r += field_a(n)                             // -7: has none
    var p = cxx::std::make_unique<WithA>(5)
    r += (*p).a                                 // 5
    return r                                    // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
