// A `cxx::std::move(x)` argument that is hoisted for evaluation order (a
// later argument has an effect) is bound to a local; that local is an lvalue,
// so handing it on copied, and a move-only parameter (`unique_ptr`) rejected
// the copy: CL001E "call to implicitly-deleted copy constructor". The hoisted
// xvalue is passed on as `T&&` again. A prvalue argument was already moved.

ffi "c++" import "move_arg_hoisted_move_only.h"

fn main() -> i32 {
    var sm: SM
    var buf = mk(4)
    var a = sm.take(cxx::std::move(buf), 1)
    var buf2 = mk(5)
    var b = sm.take(cxx::std::move(buf2), loc(2))
    var c = sm.take(mk(6), loc(3))
    return a + b + c
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
