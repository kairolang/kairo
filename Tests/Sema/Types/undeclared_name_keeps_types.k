// An undeclared name in ONE function leaves the rest of the file typed. The
// undeclared name is poisoned at every use, so typing the rest of the file
// is information, not cascade: the miss counts as contained, as an unknown
// member (R025E) does, and the expression typer runs. Every local keeps its
// inferred type (the language server's hover shows `var x: Vault`) and
// `x.n` has its type.

class Vault { var n: i32 = 0 }
fn make() -> Vault { return Vault() }
fn a() -> i32 {
    var x = make()
    return x.n
}
fn b() -> i32 {
    var y = make()
    nope
    return y.n
}
fn main() -> i32 { return a() + b() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: undeclared_name_keeps_types.k:16:5: error [R020E]: use of undeclared identifier 'nope'
//
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=DUMP
// DUMP: ===== SEMA fid {{[0-9]+}}: {{.*}}undeclared_name_keeps_types.k =====
// DUMP: ChainExpr {{ *}}@ 12:12 {{ *}}: i32
// DUMP: ChainExpr {{ *}}@ 17:12 {{ *}}: i32
// DUMP: -- inferred decls --
// DUMP-NEXT: x : Vault
// DUMP-NEXT: y : Vault
