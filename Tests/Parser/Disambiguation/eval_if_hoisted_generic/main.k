// P110: a generic declared in a branch of an imported file's file-scope
// `eval if` is known to this file's `<` disambiguation. The index pass walks
// every branch (taken or not, which only Sema decides), so `pick<i32> + 1`
// is a generic name, not `pick < i32 > +1`. The call shape `pick<i32>(1)`
// parsed already, through the tentative fallback; a generic name followed
// by an operator is a shape only positive evidence commits. Covered: a
// generic in both branches, one in the final `else` of a chain whose
// `else`s sit on their own lines, and one in an `eval if` nested in a
// branch. The operator shapes sit in an untaken `eval if`: the parser must
// read them, and Sema drops them before typing (a generic function's value
// in an operator is a separate typer gap).

import lib::*

fn main() -> i32 {
    var n = pick<i32>(1) + late<i32>(2) + deep<i32>(3)
    eval if false {
        var a = pick<i32> + 1
        var b = late<i32> + 2
        var c = deep<i32> + 3
    }
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST:      VariableDecl var a
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr pick<i32>
// AST:      VariableDecl var b
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr late<i32>
// AST:      VariableDecl var c
// AST-NEXT: BinaryOperatorExpr +
// AST-NEXT: NamedIdentExpr deep<i32>
