// An operator spelling a macro argument supplies is validated as written::
// `fn op t` with `t` bound to an identifier is still S045E "not
// valid to overload": DeclParse reads the operator's kind through
// the expansion.

macro bad!(t) { fn op t (const self) -> i32 { return 1 } }

class Bad {
    var v: i32 = 0
    bad!(foo)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: macro_declared_not_overloadable.k:10:10: error [S045E]: given operator is not valid to overload (in expansion of macro 'bad!(foo)')
