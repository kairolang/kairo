// Forwarding functions in a user header (fwd.h): make_unique's shape with
// an explicit T, a recursive std::forward fold, `const Ts&...` and `Ts&...`
// packs, and a template parameter that only C++ fills (an `enable_if_t<...>
// = 0` default; deduction no longer demands it of an import).

ffi "c++" import "fwd.h"

class Cp {
    pub var n: i32 = 0
    fn Cp(self, n: i32) { self.n = n }
}

fn main() -> i32 {
    var bi = make_box<i32>(9)
    var p = make<Pair>(1, 2)
    var c = Cp(4)
    var fw = forward_sum(1, 2, 3)
    var n = count_args(1, c, p)
    var a = 1
    var b = 2
    bump_all(a, b)
    var r = *bi + 21                            // 30
    r += p.a + p.b + fw + n                     // 3 + 6 + 3 = 12
    r += a + b + twice(5)                       // 2 + 3 + 10 = 15
    return r                                    // 57
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 57
