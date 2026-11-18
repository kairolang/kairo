// The implicit object parameter. A method WITH a ref-qualifier binds its
// object like a reference parameter: `&` takes an lvalue, `&&` an rvalue,
// and between `&&` and `const &` an rvalue prefers `&&` (3.2.3). A method
// without one binds any object, an rvalue included ([over.match.funcs]/5),
// and only constness orders two of them (3.2.6).

ffi "c++" import "refs.h"

fn main() -> i32 {
    var o = Obj()
    const co = Obj()
    if o.q() != 1 { return 10; }                // lvalue: `&`
    if co.q() != 3 { return 11; }               // const lvalue: `const &`
    if make_obj().q() != 2 { return 12; }       // prvalue: `&&` over `const &`
    if o.r() != 4 { return 20; }
    if co.r() != 5 { return 21; }
    if make_obj().r() != 4 { return 22; }       // an rvalue binds the plain method
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
