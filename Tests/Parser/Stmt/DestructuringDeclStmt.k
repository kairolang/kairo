// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-FunctionDecl  f(t: (i32, i32, i32)) -> i32
// CHECK-NEXT:   |-ParamDecl t: (i32, i32, i32)
// CHECK-NEXT:   `-CompoundStmt (4)
// CHECK-NEXT:     |-DestructuringDeclStmt tuple var (a, _, c)
// CHECK-NEXT:     | `-NamedIdentExpr t
// CHECK-NEXT:     |-DestructuringDeclStmt tuple const (x, y, z)
// CHECK-NEXT:     | `-TupleLiteralExpr (3)
// CHECK-NEXT:     |   |-IntegerLiteralExpr 1
// CHECK-NEXT:     |   |-IntegerLiteralExpr 2
// CHECK-NEXT:     |   `-IntegerLiteralExpr 3
// CHECK-NEXT:     |-DestructuringDeclStmt tuple var (*p, q, r)
// CHECK-NEXT:     | `-NamedIdentExpr t
// CHECK-NEXT:     `-ReturnStmt
// CHECK-NEXT:       `-BinaryOperatorExpr +
// CHECK-NEXT:         |-BinaryOperatorExpr +
// CHECK-NEXT:         | |-BinaryOperatorExpr +
// CHECK-NEXT:         | | |-BinaryOperatorExpr +
// CHECK-NEXT:         | | | |-BinaryOperatorExpr +
// CHECK-NEXT:         | | | | |-BinaryOperatorExpr +
// CHECK-NEXT:         | | | | | |-BinaryOperatorExpr +
// CHECK-NEXT:         | | | | | | |-NamedIdentExpr a
// CHECK-NEXT:         | | | | | | `-NamedIdentExpr c
// CHECK-NEXT:         | | | | | `-NamedIdentExpr x
// CHECK-NEXT:         | | | | `-NamedIdentExpr y
// CHECK-NEXT:         | | | `-NamedIdentExpr z
// CHECK-NEXT:         | | `-UnaryOperatorExpr prefix *
// CHECK-NEXT:         | |   `-NamedIdentExpr p
// CHECK-NEXT:         | `-NamedIdentExpr q
// CHECK-NEXT:         `-NamedIdentExpr r
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

fn f(t: (i32, i32, i32)) -> i32 {
    var (a, _, c) = t
    const (x, y, z) = (1, 2, 3)
    var (*p, q, r) = t
    return a + c + x + y + z + *p + q + r
}
