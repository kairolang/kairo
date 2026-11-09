// `f(p: *B?)` beside `f(p: *const B?)` orders as `*B` beside `*const B`:
// a `*D`, `*B` or `*D?` argument takes the non-const overload, as C++
// does ([over.ics.rank]/3.2.1, the qualification conversion is a proper
// subsequence). It was SC064E "ambiguous".

class B { var x: i32 = 1 }
class D derives B { }

fn f(p: *B?) -> i32 { return 1 }
fn f(p: *const B?) -> i32 { return 2 }

fn main() -> i32 {
    var d = D()
    var b = B()
    var pd: *D? = &d
    var cb: *const B? = &b
    // 1 + 10 + 100 from the non-const one, 2000 from the const one: 2111 % 256 = 63.
    return (f(&d) + f(&b) * 10 + f(pd) * 100 + f(cb) * 1000) % 256
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 63
