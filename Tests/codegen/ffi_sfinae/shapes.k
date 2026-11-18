// Every place C++ puts SFINAE, through clang's own deduction: each pair in
// sfinae.h was a tie (SC064E) when Kairo deduced alone, because both
// templates deduce T and bind it at Exact. Clang's substitution removes
// the one whose condition fails, as C++ does, so the call binds the other.

ffi "c++" import "sfinae.h"

fn main() -> i32 {
    var i: i32 = 4
    var d: f64 = 0.5
    var u: u32 = 7
    var s: Sized
    var p = Pair(8, 9)

    var r = 0
    r += on_default(i)                  // 1   enable_if on a defaulted value parameter
    r += on_default(d)                  // 2
    r += on_return(i)                   // 10  on the return type
    r += on_return(d)                   // 20
    r += on_param(i)                    // 100 on a defaulted function parameter
    r += on_param(d)                    // 200
    r += on_type_default(i, 0)          // 1000 on a defaulted type parameter
    r += on_type_default(u, 0)          // 2000
    var rest = 0
    rest += has_size(s)                 // 3   decltype(t.size())
    rest += has_size(i)                 // -1  decltype(t + 1)
    rest += field_a(p)                  // 8   void_t member detection
    rest += field_a(s)                  // -7
    rest += req(i)                      // 5   requires-clause
    rest += req(d)                      // 6
    rest += kind_of<i32>(0)             // 1   only the explicit argument decides
    rest += kind_of<IntArr>(0)     // 2
    rest += kind_of<IntArr3>(0)    // 3
    rest += lval_only(i)                // 1   the deduced reference kind decides
    rest += lval_only(4)                // 2
    rest += lval_only(i + 1)            // 2
    // 3333 + (3 - 1 + 8 - 7 + 5 + 6 + 1 + 2 + 3 + 1 + 2 + 2) = 3333 + 25
    if r != 3333 { return 1; }
    return rest
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 25
