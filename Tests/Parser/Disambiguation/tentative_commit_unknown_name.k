// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  main() -> i32
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var u
// AST-NEXT:     |   `-CallExpr (1 args)
// AST-NEXT:     |     |-NamedIdentExpr mystery<i32>
// AST-NEXT:     |     | `-GenericArg 'i32'
// AST-NEXT:     |     `-IntegerLiteralExpr 5
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R020E]:
// END-GENERATED-CHECKS

// A name with NO evidence either way (not a local binding, not in the
// DisambigTable) followed by `<args>(...)` commits as a generic call via
// the tentative-parse fallback. This is what keeps unqualified IMPORTED
// generics working the local table can't see them. Known non-generic
// names never reach this path (rule 4: they commit to comparison see
// rule4_known_value_binop.k).

fn main() -> i32 {
    var u = mystery<i32>(5)
    return 0
}
