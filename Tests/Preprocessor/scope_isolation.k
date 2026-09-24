// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-ModuleDecl std
// AST-NEXT: |-ModuleDecl foo
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-CallExpr (2 args)
// AST-NEXT: |   |-NamedIdentExpr fprintf
// AST-NEXT: |   |-NamedIdentExpr stderr
// AST-NEXT: |   `-NamedIdentExpr t
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-CallExpr (1 args)
// AST-NEXT: |   |-NamedIdentExpr print
// AST-NEXT: |   `-StringLiteralExpr "yes"
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-RecoveryExpr trying: ChainExpr
// AST-NEXT: |-ModuleDecl a
// AST-NEXT: | `-ModuleDecl b
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-IntegerLiteralExpr 1
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-IntegerLiteralExpr 2
// AST-NEXT: `-ExpressionStmt
// AST-NEXT:   `-RecoveryExpr trying: ChainExpr
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R013E]:
// AST: {{.*}}: error [R013E]:
// END-GENERATED-CHECKS

// Scope isolation: module frames must pop on their closing `}` so sibling
// modules don't nest and macro scopes stay separated.
// Regression for ScopeTracker frame brace-depth off-by-one (frames never
// popped `module foo` nested inside `module std`, so foo::eprint! was
// registered under [std, foo] and failed to resolve while bare eprint!
// leaked to the last open scope).

// SEPARATE:
module std {
    macro eprint!(...t) { fprintf(stderr, t) }
}
module foo {
    macro eprint!(...t) { print("yes") }
}
std::eprint!(1)   // std body (fprintf ...); registered under [std]
foo::eprint!(1)   // foo body (print "yes"); registered under [foo], MUST resolve
eprint!(1)        // R013E: bare name not visible at file scope, no scope leak

// SEPARATE:
module a {
    module b {
        macro m!() { 1 }   // registered under [a, b]
    }
    macro n!() { 2 }       // registered under [a] proves b popped on its `}`
}
a::b::m!()   // 1, resolves under [a, b]
a::n!()      // 2, resolves under [a]; if b didn't pop, n would land in [a, b]
a::b::n!()   // R013E: n! is not under [a, b]
