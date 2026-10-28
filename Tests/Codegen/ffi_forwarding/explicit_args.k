// An imported function template is emitted as C++ calls it: the generic
// arguments the call wrote, the rest deduced by clang. Spelling Kairo's
// whole instance instead wrote `make_box<Pair, Pair>(p)`: the pack element
// is a VALUE type there, so `Args&&` became `Pair&&`, which the lvalue `p`
// cannot bind (CL001E from clang). And a template with a parameter only
// C++ fills (`enable_if_t<...> = 0`) has no Kairo instance at all, so
// `twice<i64>(4)` lost its `<i64>` and C++ deduced `int` from the literal.

ffi "c++" import "fwd.h"

fn main() -> i32 {
    var p = Pair(1, 2)
    var b = make_box<Pair>(p)                   // an lvalue through Args&&
    var q = make<Pair>(p)                       // the same, by value
    var c = make_box<Pair>(Pair(3, 4))          // an rvalue
    var big = twice<i64>(3000000000)            // the written argument decides the width
    var r = (*b).a + q.b + (*c).a                 // 1 + 2 + 3 = 6
    if big != 6000000000 { return 1; }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
