// RUN: python3 -c "print('fn main() -> i32 {\n    var x: i32 = ' + ' + '.join(['1'] * 1500) + '\n    return x - 1500\n}')" > %t.k
// RUN: %kairo %t.k --type-check-only 2>&1 | %FileCheck %s --check-prefix=SEMA --allow-empty
// RUN: %kairo %t.k --type-check-only --print-ast=tree 2>&1 | %FileCheck %s --check-prefix=TREE
// A left-leaning chain recursed once per term in the expression typer
// and in the tree printer; 1500 terms overflowed the debug build's stack.
// Both walk the spine in a loop now. The other whole-tree visitors
// (RecursiveASTVisitor subclasses: MoveCheck, AttributeCheck, ...) still
// recurse, so the depth here stays below where they give out (about 2500 on
// a debug build). This file is only the generator; the chain is built per run.
// SEMA-NOT: error
// TREE: BinaryOperatorExpr
// TREE: IntegerLiteralExpr
fn main() -> i32 { return 0 }
