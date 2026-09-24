// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  foo(i32)
// AST-NEXT: | `-ParamDecl i32
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var scale
// AST-NEXT: |   `-IntegerLiteralExpr 3
// AST-NEXT: `-FunctionDecl  main() -> i32
// AST-NEXT:   `-CompoundStmt (4)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-IntegerLiteralExpr 1
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var x
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr foo<a>
// AST-NEXT:     |     | `-GenericArg 'a'
// AST-NEXT:     |     `-IntegerLiteralExpr 10
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var s
// AST-NEXT:     |   `-BinaryOperatorExpr >
// AST-NEXT:     |     |-BinaryOperatorExpr <
// AST-NEXT:     |     | |-NamedIdentExpr scale
// AST-NEXT:     |     | `-NamedIdentExpr a
// AST-NEXT:     |     `-IntegerLiteralExpr 10
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R021E]:
// END-GENERATED-CHECKS

// Final rule 4 split for known non-generic names:
//   - fn:  assume generic when the shape fits. `foo<a>(10)` parses as a
//          generic call sema owns the "foo takes no generic arguments"
//          diagnostic, which beats "cannot compare a function".
//          (`foo < limit` with no closing shape still rolls back to a
//          comparison see nongeneric_lt_binop.k.)
//   - var: never assumed generic. `scale<a>(10)` commits to a comparison
//          chain (scale < a) > (10) with no tentative parse. Only a var
//          bound to a generic lambda parses generically (see
//          rule4_local_shadowing.k).

fn foo(i32)

var scale = 3

fn main() -> i32 {
    var a = 1
    var x = foo<a>(10)
    var s = scale<a>(10)
    return 0
}
