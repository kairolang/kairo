ffi "c++" import "ffi_ref_return_calls.h"

fn sink(@move x: i32) -> i32 { return x }

fn main() -> i32 {
    var n: i32 = 3
    ret_ref(&n) = 10               // assign through the returned int&
    ret_ref(&n) += 1               // 11
    var c = ret_cref(n)            // a copy of the referent: 11
    var *p = &ret_ref(&n)          // the address of the referent
    (*p) += 1                      // n = 12
    var r = ret_ref(&n)            // a copy, not an alias
    r = 100
    var m = sink(ret_mref(&n))     // an xvalue binds @move: 12
    global_slot() = 30             // writes the C++ global
    // 12 + 11 + 12 + 30 = 65
    return n + c + m + global_slot()
}

// --- lit wiring -----------------------------------------------------------
// Pure coverage: pins the call side of C++ reference returns as it was
// before `ffi::ref` (passes on the release compiler too). The call is an
// lvalue of T (an xvalue for T&&), `&f()` is `*T`, and a binding copies.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: SEMA fid {{[0-9]+}}: {{.*}}ffi_ref_return_calls.k =====
// SEMA: -- inferred decls --
// SEMA-DAG: c : i32{{$}}
// SEMA-DAG: p : *i32{{$}}
// SEMA-DAG: r : i32{{$}}
// SEMA-DAG: m : i32{{$}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 65
