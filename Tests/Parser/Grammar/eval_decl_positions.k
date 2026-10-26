// `eval` declarations parse in every position a declaration is legal, as
// the same nodes a module body builds for them (eval.mdx): a binding
// (`eval N = e`, `eval N: T = e`, `eval const N = e`), an `eval fn` and an
// `eval { }` block at file scope, in a module, in a class and in a function
// body. `eval if`, `eval for` and an `eval f(3)` expression stay statements.
// Before this, at file scope and in a function body `eval N = 10` was an
// expression statement (R020E for `N`), `eval N: i32 = 10` was S052E
// "expected expression, found ':'", and `eval fn sq(x: i32)` was a closure
// whose `x` was undeclared. Semantics (consteval emission, the coloring
// check) are not this test's: only the parse.
//
// `eval if` / `eval for` in a module or class body: eval_stmt_in_body.k.

fn work(x: i32) -> i32 { return x }

eval N = 10
eval M: i32 = 4
eval const C = 3
eval fn sq(x: i32) -> i32 { return x * x }
eval fn square(x: i32) -> i32 = x * x
eval { eval INNER = 1 }
eval if true { var q = 1 }
eval work(3)

module m {
    eval K = 2
    eval fn cube(x: i32) -> i32 = x * x * x
}

class Cls {
    eval LIMIT: u8 = 2
    eval fn twice(self, x: i32) -> i32 = x + x
}

fn body() -> i32 {
    eval k: i32 = 4
    eval j = 5
    eval const c = 6
    eval fn local(x: i32) -> i32 = x + 1
    eval if true { var q = 1 }
    eval for i in 0..2 { }
    eval work(3)
    return k + j + c
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE-LABEL: TranslationUnit '{{.*}}eval_decl_positions.k'(fid=0)
// TREE-NEXT: |-FunctionDecl  work(x: i32) -> i32
// TREE-NEXT: | |-ParamDecl x: i32
// TREE-NEXT: | `-CompoundStmt (1)
// TREE-NEXT: |   `-ReturnStmt
// TREE-NEXT: |     `-NamedIdentExpr x
// TREE-NEXT: |-VariableDecl eval N
// TREE-NEXT: | `-IntegerLiteralExpr 10
// TREE-NEXT: |-VariableDecl eval M: i32
// TREE-NEXT: | `-IntegerLiteralExpr 4
// TREE-NEXT: |-VariableDecl eval C
// TREE-NEXT: | `-IntegerLiteralExpr 3
// TREE-NEXT: |-FunctionDecl  sq(x: i32) -> i32
// TREE-NEXT: | |-ParamDecl x: i32
// TREE-NEXT: | `-CompoundStmt (1)
// TREE-NEXT: |   `-ReturnStmt
// TREE-NEXT: |     `-BinaryOperatorExpr *
// TREE-NEXT: |       |-NamedIdentExpr x
// TREE-NEXT: |       `-NamedIdentExpr x
// TREE-NEXT: |-FunctionDecl  square(x: i32) -> i32
// TREE-NEXT: | |-ParamDecl x: i32
// TREE-NEXT: | `-BinaryOperatorExpr *
// TREE-NEXT: |   |-NamedIdentExpr x
// TREE-NEXT: |   `-NamedIdentExpr x
// TREE-NEXT: |-EvalBlockDecl
// TREE-NEXT: | `-VariableDecl eval INNER
// TREE-NEXT: |   `-IntegerLiteralExpr 1
// TREE-NEXT: |-ConditionalStmt
// TREE-NEXT: | |-cond
// TREE-NEXT: | | `-BooleanLiteralExpr true
// TREE-NEXT: | `-then
// TREE-NEXT: |   `-CompoundStmt (1)
// TREE-NEXT: |     `-DeclStmt
// TREE-NEXT: |       `-VariableDecl var q
// TREE-NEXT: |         `-IntegerLiteralExpr 1
// TREE-NEXT: |-ExpressionStmt
// TREE-NEXT: | `-EvalExpr
// TREE-NEXT: |   `-CallExpr (1 args)
// TREE-NEXT: |     |-NamedIdentExpr work
// TREE-NEXT: |     `-IntegerLiteralExpr 3
// TREE-NEXT: |-ModuleDecl m
// TREE-NEXT: | |-VariableDecl eval K
// TREE-NEXT: | | `-IntegerLiteralExpr 2
// TREE-NEXT: | `-FunctionDecl  cube(x: i32) -> i32
// TREE-NEXT: |   |-ParamDecl x: i32
// TREE-NEXT: |   `-BinaryOperatorExpr *
// TREE-NEXT: |     |-BinaryOperatorExpr *
// TREE-NEXT: |     | |-NamedIdentExpr x
// TREE-NEXT: |     | `-NamedIdentExpr x
// TREE-NEXT: |     `-NamedIdentExpr x
// TREE-NEXT: |-ClassDecl Cls
// TREE-NEXT: | |-FieldDecl eval LIMIT: u8
// TREE-NEXT: | | `-IntegerLiteralExpr 2
// TREE-NEXT: | `-FunctionDecl  twice(self, x: i32) -> i32
// TREE-NEXT: |   |-ParamDecl self
// TREE-NEXT: |   |-ParamDecl x: i32
// TREE-NEXT: |   `-BinaryOperatorExpr +
// TREE-NEXT: |     |-NamedIdentExpr x
// TREE-NEXT: |     `-NamedIdentExpr x
// TREE-NEXT: `-FunctionDecl  body() -> i32
// TREE-NEXT:   `-CompoundStmt (8)
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl eval k: i32
// TREE-NEXT:     |   `-IntegerLiteralExpr 4
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl eval j
// TREE-NEXT:     |   `-IntegerLiteralExpr 5
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl eval c
// TREE-NEXT:     |   `-IntegerLiteralExpr 6
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-FunctionDecl  local(x: i32) -> i32
// TREE-NEXT:     |   |-ParamDecl x: i32
// TREE-NEXT:     |   `-BinaryOperatorExpr +
// TREE-NEXT:     |     |-NamedIdentExpr x
// TREE-NEXT:     |     `-IntegerLiteralExpr 1
// TREE-NEXT:     |-ConditionalStmt
// TREE-NEXT:     | |-cond
// TREE-NEXT:     | | `-BooleanLiteralExpr true
// TREE-NEXT:     | `-then
// TREE-NEXT:     |   `-CompoundStmt (1)
// TREE-NEXT:     |     `-DeclStmt
// TREE-NEXT:     |       `-VariableDecl var q
// TREE-NEXT:     |         `-IntegerLiteralExpr 1
// TREE-NEXT:     |-RangedForStmt eval i
// TREE-NEXT:     | |-RangeExpr ..
// TREE-NEXT:     | | |-IntegerLiteralExpr 0
// TREE-NEXT:     | | `-IntegerLiteralExpr 2
// TREE-NEXT:     | `-CompoundStmt (0)
// TREE-NEXT:     |-ExpressionStmt
// TREE-NEXT:     | `-EvalExpr
// TREE-NEXT:     |   `-CallExpr (1 args)
// TREE-NEXT:     |     |-NamedIdentExpr work
// TREE-NEXT:     |     `-IntegerLiteralExpr 3
// TREE-NEXT:     `-ReturnStmt
// TREE-NEXT:       `-BinaryOperatorExpr +
// TREE-NEXT:         |-BinaryOperatorExpr +
// TREE-NEXT:         | |-NamedIdentExpr k
// TREE-NEXT:         | `-NamedIdentExpr j
// TREE-NEXT:         `-NamedIdentExpr c
// TREE: -- 0 error(s), 0 warning(s) --
