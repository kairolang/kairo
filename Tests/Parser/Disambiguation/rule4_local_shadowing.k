// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl <T> gen(v: T) -> T
// AST-NEXT: | |-GenericParamDecl 'T'
// AST-NEXT: | |-ParamDecl v: T
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr v
// AST-NEXT: |-FunctionDecl  main() -> i32
// AST-NEXT: | `-CompoundStmt (3)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var f
// AST-NEXT: |   |   `-ClosureExpr ->  T
// AST-NEXT: |   |     |-GenericParamDecl 'T'
// AST-NEXT: |   |     |-ParamDecl x: T
// AST-NEXT: |   |     `-CompoundStmt (1)
// AST-NEXT: |   |       `-ReturnStmt
// AST-NEXT: |   |         `-NamedIdentExpr x
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var r
// AST-NEXT: |   |   `-CallExpr (1 args)
// AST-NEXT: |   |     |-NamedIdentExpr f<i32>
// AST-NEXT: |   |     | `-GenericArg 'i32'
// AST-NEXT: |   |     `-IntegerLiteralExpr 5
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-IntegerLiteralExpr 0
// AST-NEXT: `-FunctionDecl  shadowed(gen: i32) -> i32
// AST-NEXT:   |-ParamDecl gen: i32
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-IntegerLiteralExpr 1
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-BinaryOperatorExpr >
// AST-NEXT:     |     |-BinaryOperatorExpr <
// AST-NEXT:     |     | |-NamedIdentExpr gen
// AST-NEXT:     |     | `-NamedIdentExpr a
// AST-NEXT:     |     `-IntegerLiteralExpr 10
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-NamedIdentExpr c
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// Locals shadow globals in the verdict:
// 1. A local var bound to a GENERIC CLOSURE commits `<` as generic args
//    even though the table knows nothing about it.
// 2. A local param shadowing a global generic fn commits `<` as comparison
//    the lexical binding wins over the table's positive evidence.

fn <T> gen(v: T) -> T {
    return v
}

fn main() -> i32 {
    var f = fn <T> (x: T) -> T {
        return x
    }
    var r = f<i32>(5)
    return 0
}

fn shadowed(gen: i32) -> i32 {
    var a = 1
    var c = gen<a>(10)
    return c
}
