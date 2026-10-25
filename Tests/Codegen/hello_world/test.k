// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  print(*char) -> void
// AST-NEXT: | `-ParamDecl *char
// AST-NEXT: `-FunctionDecl  main() -> i32
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-CallExpr (1 args)
// AST-NEXT:     |   |-NamedIdentExpr print
// AST-NEXT:     |   `-StringLiteralExpr "Hello, World!\n"
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(AST)

fn print(*char) -> void

fn main() -> i32 {
    print("Hello, World!\n");
    return 0;
}
