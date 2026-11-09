// Inside brackets and in an if / while head, a newline ends nothing.
// An operand ending in a closer -- `(x as i32)`, `(a)`, a call -- left the
// newline after it under the cursor, so a binary operator leading the next
// line (or the `,` / `]` / `)` there) was rejected, while the same code
// with a bare operand parsed. `[ ]` (array literal, index) did not suppress
// newlines at all, and an if / while head ended at a newline before an
// operator that can also be a prefix (`+`, `-`, `*`, `&`).
//
// The other direction: a block keeps its statements wherever it sits. A
// closure body in an argument list inherited the list's suppression, so
// `var z = y` newline `-z` folded into `y - z`; the tree below shows two
// statements.

fn g(a: i32, b: i32) -> i32 { return a }
fn h(f: fn () -> i32) -> i32 { return f() }

fn paren_operand(x: u8) -> i32 {
    var a = g((x as i32)
        + 1, 2)
    var b = g(x as i32
        + 1, 2)
    var c = g(
        (a)
        , b)
    var d = g(g(a, b)
        - 1, c)
    return d
}

fn tuple_array_index(y: i32) -> i32 {
    var t = (y, (y)
        - 1)
    var arr: [i32; 3] = [y,
        (y)
            - 1,
        2
    ]
    return arr[(t.1)
        - y]
}

fn heads(y: i32) -> i32 {
    var n = 0
    if (y)
        + 1 == 2 {
        n = 1
    }
    while n
        - 1 > 0 {
        n = n - 1
    }
    return n
}

fn closure_body() -> i32 {
    return h(fn () -> i32 {
        var y = 3
        var z = y
        -z
        return z
    })
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(AST) mode=ast -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl  g(a: i32, b: i32) -> i32
// AST-NEXT: | |-ParamDecl a: i32
// AST-NEXT: | |-ParamDecl b: i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr a
// AST-NEXT: |-FunctionDecl  h(f: fn() -> i32) -> i32
// AST-NEXT: | |-ParamDecl f: fn() -> i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-CallExpr (0 args)
// AST-NEXT: |       `-NamedIdentExpr f
// AST-NEXT: |-FunctionDecl  paren_operand(x: u8) -> i32
// AST-NEXT: | |-ParamDecl x: u8
// AST-NEXT: | `-CompoundStmt (5)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var a
// AST-NEXT: |   |   `-CallExpr (2 args)
// AST-NEXT: |   |     |-NamedIdentExpr g
// AST-NEXT: |   |     |-BinaryOperatorExpr +
// AST-NEXT: |   |     | |-TypeCastExpr -> i32
// AST-NEXT: |   |     | | `-NamedIdentExpr x
// AST-NEXT: |   |     | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-IntegerLiteralExpr 2
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var b
// AST-NEXT: |   |   `-CallExpr (2 args)
// AST-NEXT: |   |     |-NamedIdentExpr g
// AST-NEXT: |   |     |-BinaryOperatorExpr +
// AST-NEXT: |   |     | |-TypeCastExpr -> i32
// AST-NEXT: |   |     | | `-NamedIdentExpr x
// AST-NEXT: |   |     | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-IntegerLiteralExpr 2
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var c
// AST-NEXT: |   |   `-CallExpr (2 args)
// AST-NEXT: |   |     |-NamedIdentExpr g
// AST-NEXT: |   |     |-NamedIdentExpr a
// AST-NEXT: |   |     `-NamedIdentExpr b
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var d
// AST-NEXT: |   |   `-CallExpr (2 args)
// AST-NEXT: |   |     |-NamedIdentExpr g
// AST-NEXT: |   |     |-BinaryOperatorExpr -
// AST-NEXT: |   |     | |-CallExpr (2 args)
// AST-NEXT: |   |     | | |-NamedIdentExpr g
// AST-NEXT: |   |     | | |-NamedIdentExpr a
// AST-NEXT: |   |     | | `-NamedIdentExpr b
// AST-NEXT: |   |     | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-NamedIdentExpr c
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr d
// AST-NEXT: |-FunctionDecl  tuple_array_index(y: i32) -> i32
// AST-NEXT: | |-ParamDecl y: i32
// AST-NEXT: | `-CompoundStmt (3)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var t
// AST-NEXT: |   |   `-TupleLiteralExpr (2)
// AST-NEXT: |   |     |-NamedIdentExpr y
// AST-NEXT: |   |     `-BinaryOperatorExpr -
// AST-NEXT: |   |       |-NamedIdentExpr y
// AST-NEXT: |   |       `-IntegerLiteralExpr 1
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var arr: [i32; 3]
// AST-NEXT: |   |   `-ListLiteralExpr (3)
// AST-NEXT: |   |     |-NamedIdentExpr y
// AST-NEXT: |   |     |-BinaryOperatorExpr -
// AST-NEXT: |   |     | |-NamedIdentExpr y
// AST-NEXT: |   |     | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-IntegerLiteralExpr 2
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-SubscriptExpr
// AST-NEXT: |       |-NamedIdentExpr arr
// AST-NEXT: |       `-BinaryOperatorExpr -
// AST-NEXT: |         |-ChainExpr 't.1'
// AST-NEXT: |         | |-NamedIdentExpr t
// AST-NEXT: |         | `-Step .1  tuple-index
// AST-NEXT: |         `-NamedIdentExpr y
// AST-NEXT: |-FunctionDecl  heads(y: i32) -> i32
// AST-NEXT: | |-ParamDecl y: i32
// AST-NEXT: | `-CompoundStmt (4)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var n
// AST-NEXT: |   |   `-IntegerLiteralExpr 0
// AST-NEXT: |   |-ConditionalStmt
// AST-NEXT: |   | |-cond
// AST-NEXT: |   | | `-BinaryOperatorExpr ==
// AST-NEXT: |   | |   |-BinaryOperatorExpr +
// AST-NEXT: |   | |   | |-NamedIdentExpr y
// AST-NEXT: |   | |   | `-IntegerLiteralExpr 1
// AST-NEXT: |   | |   `-IntegerLiteralExpr 2
// AST-NEXT: |   | `-then
// AST-NEXT: |   |   `-CompoundStmt (1)
// AST-NEXT: |   |     `-ExpressionStmt
// AST-NEXT: |   |       `-AssignOperatorExpr =
// AST-NEXT: |   |         |-NamedIdentExpr n
// AST-NEXT: |   |         `-IntegerLiteralExpr 1
// AST-NEXT: |   |-WhileLoopStmt
// AST-NEXT: |   | |-BinaryOperatorExpr >
// AST-NEXT: |   | | |-BinaryOperatorExpr -
// AST-NEXT: |   | | | |-NamedIdentExpr n
// AST-NEXT: |   | | | `-IntegerLiteralExpr 1
// AST-NEXT: |   | | `-IntegerLiteralExpr 0
// AST-NEXT: |   | `-CompoundStmt (1)
// AST-NEXT: |   |   `-ExpressionStmt
// AST-NEXT: |   |     `-AssignOperatorExpr =
// AST-NEXT: |   |       |-NamedIdentExpr n
// AST-NEXT: |   |       `-BinaryOperatorExpr -
// AST-NEXT: |   |         |-NamedIdentExpr n
// AST-NEXT: |   |         `-IntegerLiteralExpr 1
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr n
// AST-NEXT: `-FunctionDecl  closure_body() -> i32
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-CallExpr (1 args)
// AST-NEXT:         |-NamedIdentExpr h
// AST-NEXT:         `-ClosureExpr ->  i32
// AST-NEXT:           `-CompoundStmt (4)
// AST-NEXT:             |-DeclStmt
// AST-NEXT:             | `-VariableDecl var y
// AST-NEXT:             |   `-IntegerLiteralExpr 3
// AST-NEXT:             |-DeclStmt
// AST-NEXT:             | `-VariableDecl var z
// AST-NEXT:             |   `-NamedIdentExpr y
// AST-NEXT:             |-ExpressionStmt
// AST-NEXT:             | `-UnaryOperatorExpr prefix -
// AST-NEXT:             |   `-NamedIdentExpr z
// AST-NEXT:             `-ReturnStmt
// AST-NEXT:               `-NamedIdentExpr z
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS(AST)
