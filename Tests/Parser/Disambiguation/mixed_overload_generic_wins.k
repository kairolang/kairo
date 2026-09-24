// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  sum(a: i32) -> i32
// AST-NEXT: | |-ParamDecl a: i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr a
// AST-NEXT: |-FunctionDecl <T> sum(v: T) -> T
// AST-NEXT: | |-GenericParamDecl 'T'
// AST-NEXT: | |-ParamDecl v: T
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr v
// AST-NEXT: `-FunctionDecl  main() -> i32
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var s
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr sum<i32>
// AST-NEXT:     |     | `-GenericArg 'i32'
// AST-NEXT:     |     `-IntegerLiteralExpr 5
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// Mixed overload set: one non-generic + one generic overload of the same
// name. The table stores BOTH (non-generic entries are negative evidence
// for rule 4), so the verdict must scan ALL entries insertion order can
// never hide the generic overload behind a non-generic first().

fn sum(a: i32) -> i32 {
    return a
}

fn <T> sum(v: T) -> T {
    return v
}

fn main() -> i32 {
    var s = sum<i32>(5)
    return 0
}
