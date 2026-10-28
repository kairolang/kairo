// emplace_back -- `template <class... Args> reference emplace_back(Args&&...
// args)` -- with zero, one and several arguments, lvalues and rvalues,
// Kairo records and builtins (GH#88). The parameter is a pack expansion
// with no Kairo shape; it imported opaque, so no argument converted to it
// and every call was SC063E. It now imports as a pack parameter whose
// element is the pattern `Args&&`, one argument each.

ffi "c++" import "vector"
ffi "c++" import "fwd.h"

class Cp {
    pub var n: i32 = 0
    fn Cp(self, n: i32) { self.n = n }
}

fn main() -> i32 {
    var v: cxx::std::vector<Cp>
    var k = Cp(1)
    v.emplace_back(k)                         // lvalue: copied, k stays live
    v.emplace_back(Cp(2))                     // prvalue
    v.emplace_back(3)                         // a constructor argument
    var pv: cxx::std::vector<Pair>
    pv.emplace_back()                         // no arguments
    pv.emplace_back(4, 5)                     // two
    var iv: cxx::std::vector<i32>
    iv.emplace_back(7)
    var x = 8
    iv.emplace_back(x)
    var r = (v.size() as i32) + k.n + v[1].n + v[2].n   // 3 + 1 + 2 + 3 = 9
    r += pv[0].a + pv[1].a + pv[1].b                   // 0 + 4 + 5 = 9
    r += iv[0] + iv[1]                                 // 15
    return r                                           // 33
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 33
