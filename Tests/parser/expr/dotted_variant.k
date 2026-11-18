// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --print-ast=tree 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
//
// `.Name` opening an expression is an enum variant whose enum the expected
// type names: alone, or with its payload in braces. It is a
// NamedInitializerExpr with no head. In a condition the `{` after it opens
// the block, as it does after a path.
fn dotted_forms(flag_x: i32) {
    var dot_bare = .None
    var dot_braced = .Some { v: 1, w: 2 }
    if flag_x == .Gamma { }
    var dot_broken = .
}
// AST:      VariableDecl var dot_bare
// AST-NEXT: NamedInitializerExpr .None
// AST:      VariableDecl var dot_braced
// AST-NEXT: NamedInitializerExpr .Some
// AST-NEXT: Field v
// AST-NEXT: IntegerLiteralExpr 1
// AST-NEXT: Field w
// AST-NEXT: IntegerLiteralExpr 2
// AST:      BinaryOperatorExpr ==
// AST-NEXT: NamedIdentExpr flag_x
// AST-NEXT: NamedInitializerExpr .Gamma
// AST-NEXT: then
// AST-NEXT: CompoundStmt (0)
// ERR: error [S054E]: expected a variant name after '.'
