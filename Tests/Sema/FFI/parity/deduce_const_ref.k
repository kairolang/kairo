// rule: deduction through a reference sees the referee's cv
// ([temp.deduct.call]/3). `const T&` against a `const i32` or an `i32` is
// T := i32 either way; a plain `T&` against a `const i32` is T := const i32,
// which is what lets it bind at all. `const c: i32` is a const object --
// identical to `var c: const i32` -- so its type at the use is `const i32`,
// as the oracle's `const int c` is.

ffi "c++" import "../deduce_const.h"

fn use_deduce() {
    const c: i32 = 4 // ive changed this
    var v: i32 = 4
    var a = id(c)
    var b = id(v)
    var d = addr(v)
    var e = addr(c)
}

// The prelude dumps the builtin TUs ahead of this one, each with an
// `-- inferred decls --` of its own: anchor on this file's header first.
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}deduce_const_ref.k =====
// SEMA:      -- inferred decls --
// SEMA-NEXT: a : i32
// SEMA-NEXT: b : i32
// SEMA-NEXT: d : *i32
// SEMA-NEXT: e : *const i32

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang