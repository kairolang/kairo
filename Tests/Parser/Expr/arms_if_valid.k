// `=>` value arms of the expression-form `if`: every legal place to break a
// line, how far the last arm runs, and the stop flags it inherits from the
// context it sits in (a call argument, a subscript, a list element, a `while`
// condition).

fn chain() {
    var z = if a == b => 2 else if b > 2 => 1 else => 0
}

// The same expression split at every legal place: before `=>`, before `else`.
fn split_before_arrow() {
    var z = if a == b
        => 2
        else if b > 2
        => 1
        else
        => 0
}

// ...and after `=>`, with `else` opening its own line.
fn split_after_arrow() {
    var z = if a == b =>
        2
    else =>
        0
}

// A line ending in a binary operator continues the arm's value.
fn continued_value() {
    var z = if c => 1 else => x +
        y
}

// The last arm runs to the end of the expression: `else => (0 + 5)`.
fn arm_extent() {
    var z = if c => 1 else => 0 + 5
}

// A call argument ends the last arm at `,`: two arguments, not one.
fn call_argument() {
    f(if c => 1 else => 2, 3)
}

// Inside a subscript and a list literal.
fn subscript_and_list() {
    var s = a[if c => 0 else => 1]
    var l = [if c => 1 else => 2, 3]
}

// NoStructLiteral is inherited: `y {` is not a named initializer, the brace
// is the loop body.
fn while_condition() {
    while if c => x else => y { }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: TranslationUnit '{{.*}}arms_if_valid.k'(fid=0)
// AST-NEXT: |-FunctionDecl  chain()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var z
// AST-NEXT: |       `-IfExpr
// AST-NEXT: |         |-cond
// AST-NEXT: |         | `-BinaryOperatorExpr ==
// AST-NEXT: |         |   |-NamedIdentExpr a
// AST-NEXT: |         |   `-NamedIdentExpr b
// AST-NEXT: |         |-then
// AST-NEXT: |         | `-IntegerLiteralExpr 2
// AST-NEXT: |         |-else-if
// AST-NEXT: |         | |-BinaryOperatorExpr >
// AST-NEXT: |         | | |-NamedIdentExpr b
// AST-NEXT: |         | | `-IntegerLiteralExpr 2
// AST-NEXT: |         | `-IntegerLiteralExpr 1
// AST-NEXT: |         `-else
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: |-FunctionDecl  split_before_arrow()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var z
// AST-NEXT: |       `-IfExpr
// AST-NEXT: |         |-cond
// AST-NEXT: |         | `-BinaryOperatorExpr ==
// AST-NEXT: |         |   |-NamedIdentExpr a
// AST-NEXT: |         |   `-NamedIdentExpr b
// AST-NEXT: |         |-then
// AST-NEXT: |         | `-IntegerLiteralExpr 2
// AST-NEXT: |         |-else-if
// AST-NEXT: |         | |-BinaryOperatorExpr >
// AST-NEXT: |         | | |-NamedIdentExpr b
// AST-NEXT: |         | | `-IntegerLiteralExpr 2
// AST-NEXT: |         | `-IntegerLiteralExpr 1
// AST-NEXT: |         `-else
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: |-FunctionDecl  split_after_arrow()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var z
// AST-NEXT: |       `-IfExpr
// AST-NEXT: |         |-cond
// AST-NEXT: |         | `-BinaryOperatorExpr ==
// AST-NEXT: |         |   |-NamedIdentExpr a
// AST-NEXT: |         |   `-NamedIdentExpr b
// AST-NEXT: |         |-then
// AST-NEXT: |         | `-IntegerLiteralExpr 2
// AST-NEXT: |         `-else
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: |-FunctionDecl  continued_value()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var z
// AST-NEXT: |       `-IfExpr
// AST-NEXT: |         |-cond
// AST-NEXT: |         | `-NamedIdentExpr c
// AST-NEXT: |         |-then
// AST-NEXT: |         | `-IntegerLiteralExpr 1
// AST-NEXT: |         `-else
// AST-NEXT: |           `-BinaryOperatorExpr +
// AST-NEXT: |             |-NamedIdentExpr x
// AST-NEXT: |             `-NamedIdentExpr y
// AST-NEXT: |-FunctionDecl  arm_extent()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var z
// AST-NEXT: |       `-IfExpr
// AST-NEXT: |         |-cond
// AST-NEXT: |         | `-NamedIdentExpr c
// AST-NEXT: |         |-then
// AST-NEXT: |         | `-IntegerLiteralExpr 1
// AST-NEXT: |         `-else
// AST-NEXT: |           `-BinaryOperatorExpr +
// AST-NEXT: |             |-IntegerLiteralExpr 0
// AST-NEXT: |             `-IntegerLiteralExpr 5
// AST-NEXT: |-FunctionDecl  call_argument()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-CallExpr (2 args)
// AST-NEXT: |       |-NamedIdentExpr f
// AST-NEXT: |       |-IfExpr
// AST-NEXT: |       | |-cond
// AST-NEXT: |       | | `-NamedIdentExpr c
// AST-NEXT: |       | |-then
// AST-NEXT: |       | | `-IntegerLiteralExpr 1
// AST-NEXT: |       | `-else
// AST-NEXT: |       |   `-IntegerLiteralExpr 2
// AST-NEXT: |       `-IntegerLiteralExpr 3
// AST-NEXT: |-FunctionDecl  subscript_and_list()
// AST-NEXT: | `-CompoundStmt (2)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var s
// AST-NEXT: |   |   `-SubscriptExpr
// AST-NEXT: |   |     |-NamedIdentExpr a
// AST-NEXT: |   |     `-IfExpr
// AST-NEXT: |   |       |-cond
// AST-NEXT: |   |       | `-NamedIdentExpr c
// AST-NEXT: |   |       |-then
// AST-NEXT: |   |       | `-IntegerLiteralExpr 0
// AST-NEXT: |   |       `-else
// AST-NEXT: |   |         `-IntegerLiteralExpr 1
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var l
// AST-NEXT: |       `-ListLiteralExpr (2)
// AST-NEXT: |         |-IfExpr
// AST-NEXT: |         | |-cond
// AST-NEXT: |         | | `-NamedIdentExpr c
// AST-NEXT: |         | |-then
// AST-NEXT: |         | | `-IntegerLiteralExpr 1
// AST-NEXT: |         | `-else
// AST-NEXT: |         |   `-IntegerLiteralExpr 2
// AST-NEXT: |         `-IntegerLiteralExpr 3
// AST-NEXT: `-FunctionDecl  while_condition()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-WhileLoopStmt
// AST-NEXT:       |-IfExpr
// AST-NEXT:       | |-cond
// AST-NEXT:       | | `-NamedIdentExpr c
// AST-NEXT:       | |-then
// AST-NEXT:       | | `-NamedIdentExpr x
// AST-NEXT:       | `-else
// AST-NEXT:       |   `-NamedIdentExpr y
// AST-NEXT:       `-CompoundStmt (0)
// AST-NEXT: -- 0 error(s), 0 warning(s) --
