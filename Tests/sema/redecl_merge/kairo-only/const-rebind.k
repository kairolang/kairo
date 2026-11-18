// BEGIN-GENERATED-CHECKS(AST) mode=ast loose-position loose-message -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  ok()
// AST-NEXT:   `-CompoundStmt (3)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl const x
// AST-NEXT:     |   `-IntegerLiteralExpr 10
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl const x
// AST-NEXT:     |   `-IntegerLiteralExpr 12
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl const x
// AST-NEXT:         `-StringLiteralExpr "sam"
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(AST)

// NO ORACLE: this rule matches neither reference language. C++ rejects a
// duplicate `const int x` exactly as it rejects a duplicate `int x`; Rust
// allows `let x` twice regardless of mutability. Kairo takes a third
// position: rebinding a const introduces a NEW value under the same name,
// and the old one cannot have been mutated, so nothing observable is lost.
// A `var` on either side is rejected because `var x = 12` after an existing
// x is ambiguous about intent -- assignment is spelled `x = 12`.
//
// BOTH sides must be const. Mixed pairs are errors in both directions; a
// rule reading only the new declaration would accept `var x; const x` while
// rejecting `const x; var x`, an asymmetry no reader would predict.
//
// EXPECT-CLEAN

fn ok() {
    const x = 10
    const x = 12
    const x = "sam"
}
