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
// AST-NEXT: `-FunctionDecl  main() -> i32
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var g
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr gen<i32>
// AST-NEXT:     |     | `-GenericArg 'i32'
// AST-NEXT:     |     `-IntegerLiteralExpr 5
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// A primary generic in the DisambigTable commits `<` as generic args
// without a tentative parse.

fn <T> gen(v: T) -> T {
    return v
}

fn main() -> i32 {
    var g = gen<i32>(5)
    return 0
}
