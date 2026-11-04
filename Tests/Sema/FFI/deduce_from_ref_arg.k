// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
//
// An argument typed by an imported `T&` result (`v[i]` on a `vector<*N>`)
// is an lvalue of T: an expression has no reference type in C++, so a
// by-value or pointer parameter deduces from the referee. Deduction used to
// try `unsafe *N&` against `unsafe *T` and reject the candidate (SC063E
// "cannot convert argument of type 'unsafe *N&' to parameter 'p' of type
// 'unsafe *T'"), which broke `kairo::std::destroy(self.children[i])` in the
// migrated Diagnostic/Diagnostic.k (self-host phase 5.2).

// DIAG-NOT: error

ffi "c++" import "deduce_from_ref_arg.h"
ffi "c++" import "vector"

struct N { var x: i32 = 0 }

fn main() -> i32 {
    var n = N()
    n.x = 7
    var v: cxx::std::vector<unsafe *N>
    v.push_back(unsafe &n)
    var w: cxx::std::vector<i32>
    w.push_back(1)
    // 1 (non-null) + 7 + 1
    return take_ptr(v[0]) + unsafe v[0]->x + take_val(w[0])
}
