// rule: the receiver is the implicit object parameter. An imported const
// method's `self` is `const Buf` (clang's `this` pointee), so `data()` and
// `data() const` differ on it: a non-const object prefers `data()` (a plain
// `T&` beats `const T&`), a const object has only `data() const`, and a
// non-const-only method is not viable on it at all.

ffi "c++" import "../recv_const.h"

fn use_buf(b: *Buf, k: *const Buf) {
    var p = b->data()
    var q = k->data()
    var n = k->size()
    k->clear()
}

// DIAG:      recv_const.k:13:5: error [SC001E]: no matching overload for call to 'clear'
// DIAG-NEXT: recv_const.h:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: candidate not viable: 'clear' is not const; it cannot be called on a const object
// DIAG-NOT:  error

// The prelude dumps the builtin TUs ahead of this one, each with an
// `-- inferred decls --` of its own: anchor on this file's header first.
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}recv_const.k =====
// SEMA:      -- inferred decls --
// SEMA-NEXT: p : *i32
// SEMA-NEXT: q : *const i32
// SEMA-NEXT: n : i32

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang
