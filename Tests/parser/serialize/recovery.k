// A file with syntax errors still has a tree: the parser leaves recovery
// nodes (kind = RecoveryExpr / RecoveryStmt / RecoveryDecl / RecoveryType,
// with `recovery_kind` saying what was being parsed, and the object being
// of THAT class) and goes on. Those trees are serialized like any other:
// tools that work on broken code (the language server) are the ones that
// most need a reloaded tree to be the parsed one.
//
// The errors themselves were reported by the parser and are not part of
// the tree; only the TU's error count is.

fn good(a: i32) -> i32 {
    return a + 1
}

fn missing_operand() -> i32 {
    var a = (1 + )
    return a
}

fn bad_type() -> i32 {
    var y: = 3
    var z: [i32; ] = [1]
    return y
}

fn bad_call() -> i32 {
    return good(1, , 2)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --verify-ast-roundtrip --print-stats 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: I002F
// CHECK: [stats] ast-serialize: {{[0-9]+}} files
// CHECK: error [S
// CHECK-NOT: I002F
//
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } > %t.parsed
// RUN: { %kairo %s --syntax-only --print-ast=tree --ast-roundtrip 2>/dev/null || true; } > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %FileCheck %s --check-prefix=TREE < %t.reloaded
// TREE: Recovery
// TREE: error(s)
//
// The diagnostics do not change either.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag.parsed
// RUN: { %kairo %s --type-check-only --ast-roundtrip 2>&1 || true; } > %t.diag.reloaded
// RUN: diff %t.diag.parsed %t.diag.reloaded
