// rule: a qualifier UNDER a pointer is identity, so `g(const int*)` and
// `g(int*)` are two overloads. A `*i32` argument is Exact for `g(int*)` and
// a qualification conversion for `g(const int*)`; a `*const i32` fits only
// the second. `**i32 -> *const *const i32` adds const at both levels and is
// a qualification conversion; `**i32 -> **const i32` adds it at level 2 with
// no const above and is no conversion at all ([conv.qual]).

ffi "c++" import "../ptr_const.h"

fn use_ptrs() {
    var x: i32 = 1
    var p: *i32 = &x
    var q: *const i32 = &x
    var a = g(p)
    var b = g(q)
    var c = h(&p)
    var r: **i32 = &p
    g2(r)
}

// DIAG:      ptr_const_overload.k:18:5: error [SC001E]: no matching overload for call to 'g2'
// DIAG-NEXT: ptr_const.h:10:1: note [I900N]: candidate not viable: cannot convert argument of type '**i32' to parameter 'pp' of type '**const i32'
// DIAG-NOT:  error

// The prelude dumps the builtin TUs ahead of this one, each with an
// `-- inferred decls --` of its own: anchor on this file's header first.
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}ptr_const_overload.k =====
// SEMA:      -- inferred decls --
// SEMA-NEXT: a : i64
// SEMA-NEXT: b : i32
// SEMA-NEXT: c : i32

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang
