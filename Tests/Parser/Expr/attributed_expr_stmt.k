// An `@name` at the start of a statement is an expression attribute when
// what follows it on the same line begins an expression: `@destroy p` and
// `@create T()` are expression statements over an AttributedExpr, at file
// scope and in a function body, and so get Sema's SC116E gate. Before,
// the annotation pass took them as statement attributes named `destroy` /
// `create` on the statement `p` / `T()`, accepted silently.
//
// Everything with no expression to attach to keeps the statement /
// declaration attribute: a declaration (`@deprecated var`), a keyword
// statement (`@likely if`), a block (`@repeat(3) { }`), a loop label
// (`@lbl outer: while`), and an attribute on a line of its own, which
// attaches to what follows (`@always_inline` NL `fn`, `@note` NL `p`).

class T { var v: i32 }

@create i32(42)

fn f(p: *T) {
    @destroy p
    @create T()
    @a @b(1) p
    @likely if true { }
    @repeat(3) { }
    @deprecated var x: i32 = 0
    @always_inline
    fn g() { }
    @note
    p
    @lbl outer: while false { }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE-LABEL: TranslationUnit '{{.*}}attributed_expr_stmt.k'(fid=0)
// TREE-NEXT: |-ClassDecl T
// TREE-NEXT: | `-FieldDecl var v: i32
// TREE-NEXT: |-ExpressionStmt
// TREE-NEXT: | `-AttributedExpr @create
// TREE-NEXT: |   `-CallExpr (1 args)
// TREE-NEXT: |     |-NamedIdentExpr i32
// TREE-NEXT: |     `-IntegerLiteralExpr 42
// TREE-NEXT: `-FunctionDecl  f(p: *T)
// TREE-NEXT:   |-ParamDecl p: *T
// TREE-NEXT:   `-CompoundStmt (9)
// TREE-NEXT:     |-ExpressionStmt
// TREE-NEXT:     | `-AttributedExpr @destroy
// TREE-NEXT:     |   `-NamedIdentExpr p
// TREE-NEXT:     |-ExpressionStmt
// TREE-NEXT:     | `-AttributedExpr @create
// TREE-NEXT:     |   `-CallExpr (0 args)
// TREE-NEXT:     |     `-NamedIdentExpr T
// TREE-NEXT:     |-ExpressionStmt
// TREE-NEXT:     | `-AttributedExpr @a
// TREE-NEXT:     |   `-AttributedExpr @b (1 args)
// TREE-NEXT:     |     |-IntegerLiteralExpr 1
// TREE-NEXT:     |     `-NamedIdentExpr p
// TREE-NEXT:     |-ConditionalStmt
// TREE-NEXT:     | |-cond
// TREE-NEXT:     | | `-BooleanLiteralExpr true
// TREE-NEXT:     | `-then
// TREE-NEXT:     |   `-CompoundStmt (0)
// TREE-NEXT:     |-CompoundStmt (0)
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl var x: i32
// TREE-NEXT:     |   |-Attribute @deprecated
// TREE-NEXT:     |   `-IntegerLiteralExpr 0
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-FunctionDecl  g()
// TREE-NEXT:     |   |-Attribute @always_inline
// TREE-NEXT:     |   `-CompoundStmt (0)
// TREE-NEXT:     |-ExpressionStmt
// TREE-NEXT:     | `-NamedIdentExpr p
// TREE-NEXT:     `-LabeledStmt outer
// TREE-NEXT:       `-WhileLoopStmt
// TREE-NEXT:         |-BooleanLiteralExpr false
// TREE-NEXT:         `-CompoundStmt (0)
// TREE: -- 0 error(s), 0 warning(s) --
//
// The expression attributes, and only those, are gated.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=GATE --implicit-check-not="error [" --implicit-check-not="warning ["
// GATE: attributed_expr_stmt.k:16:1: error [SC116E]: the expression attribute '@create' is not yet supported
// GATE: attributed_expr_stmt.k:19:5: error [SC116E]: the expression attribute '@destroy' is not yet supported
// GATE: attributed_expr_stmt.k:20:5: error [SC116E]: the expression attribute '@create' is not yet supported
// GATE: attributed_expr_stmt.k:21:5: error [SC116E]: the expression attribute '@a' is not yet supported
// GATE: attributed_expr_stmt.k:21:8: error [SC116E]: the expression attribute '@b' is not yet supported
