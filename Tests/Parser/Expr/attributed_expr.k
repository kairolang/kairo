// An attribute applied to an expression, `@name operand` or
// `@name(args) operand` (attributes.mdx: `@create T(args)`), is an
// AttributedExpr. Before it, every `var *cfg = @create Config(8080)` was
// S052E "expected expression, found '@'".
//
// Precedence: the operand is one unary expression, postfix chain included
// (as for `await` / `thread`), so `@create Config(1).port` attributes the
// whole `Config(1).port`, and the result is reached through parentheses:
// `(@create Config(1))->port`. Binary operators bind looser:
// `@a x + 1` is `(@a x) + 1`. The argument list is the declaration
// attribute's grammar: present exactly when `(` follows the name, named
// arguments included.

fn f() {
    var *cfg = @create Config(8080)
    var *gen = @create Box<i32>(1)
    var *blk = @create AST::Block()
    var *pt = @create Point{ x: 1.0, y: 2.0 }
    var q = @align(16) Config(1)
    var u = @named(level: 2, 3) defaults()
    var r = @a x + 1
    var s = @create Config(1).port
    var t = (@create Config(1))->port
    var w = @outer @inner x
    take(@create Config(2), 3)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE-LABEL: TranslationUnit '{{.*}}attributed_expr.k'(fid=0)
// TREE:      |-DeclStmt
// TREE-NEXT: | `-VariableDecl var *cfg
// TREE-NEXT: |   `-AttributedExpr @create
// TREE-NEXT: |     `-CallExpr (1 args)
// TREE-NEXT: |       |-NamedIdentExpr Config
// TREE-NEXT: |       `-IntegerLiteralExpr 8080
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var *gen
// TREE-NEXT: |   `-AttributedExpr @create
// TREE-NEXT: |     `-CallExpr (1 args)
// TREE-NEXT: |       |-NamedIdentExpr Box<i32>
// TREE-NEXT: |       | `-GenericArg 'i32'
// TREE-NEXT: |       `-IntegerLiteralExpr 1
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var *blk
// TREE-NEXT: |   `-AttributedExpr @create
// TREE-NEXT: |     `-CallExpr (0 args)
// TREE-NEXT: |       `-ChainExpr 'AST::Block'
// TREE-NEXT: |         |-NamedIdentExpr AST
// TREE-NEXT: |         `-Step ::Block
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var *pt
// TREE-NEXT: |   `-AttributedExpr @create
// TREE-NEXT: |     `-NamedInitializerExpr
// TREE-NEXT: |       |-NamedIdentExpr Point
// TREE-NEXT: |       |-Field x
// TREE-NEXT: |       | `-FloatingLiteralExpr 1
// TREE-NEXT: |       `-Field y
// TREE-NEXT: |         `-FloatingLiteralExpr 2
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var q
// TREE-NEXT: |   `-AttributedExpr @align (1 args)
// TREE-NEXT: |     |-IntegerLiteralExpr 16
// TREE-NEXT: |     `-CallExpr (1 args)
// TREE-NEXT: |       |-NamedIdentExpr Config
// TREE-NEXT: |       `-IntegerLiteralExpr 1
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var u
// TREE-NEXT: |   `-AttributedExpr @named (2 args)
// TREE-NEXT: |     |-NamedArgExpr level:
// TREE-NEXT: |     | `-IntegerLiteralExpr 2
// TREE-NEXT: |     |-IntegerLiteralExpr 3
// TREE-NEXT: |     `-CallExpr (0 args)
// TREE-NEXT: |       `-NamedIdentExpr defaults
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var r
// TREE-NEXT: |   `-BinaryOperatorExpr +
// TREE-NEXT: |     |-AttributedExpr @a
// TREE-NEXT: |     | `-NamedIdentExpr x
// TREE-NEXT: |     `-IntegerLiteralExpr 1
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var s
// TREE-NEXT: |   `-AttributedExpr @create
// TREE-NEXT: |     `-ChainExpr 'Config(1).port'
// TREE-NEXT: |       |-CallExpr (1 args)
// TREE-NEXT: |       | |-NamedIdentExpr Config
// TREE-NEXT: |       | `-IntegerLiteralExpr 1
// TREE-NEXT: |       `-Step .port
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var t
// TREE-NEXT: |   `-ChainExpr '{{.*}}'
// TREE-NEXT: |     |-AttributedExpr @create
// TREE-NEXT: |     | `-CallExpr (1 args)
// TREE-NEXT: |     |   |-NamedIdentExpr Config
// TREE-NEXT: |     |   `-IntegerLiteralExpr 1
// TREE-NEXT: |     `-Step ->port
// TREE-NEXT: |-DeclStmt
// TREE-NEXT: | `-VariableDecl var w
// TREE-NEXT: |   `-AttributedExpr @outer
// TREE-NEXT: |     `-AttributedExpr @inner
// TREE-NEXT: |       `-NamedIdentExpr x
// TREE-NEXT: `-ExpressionStmt
// TREE-NEXT:   `-CallExpr (2 args)
// TREE-NEXT:     |-NamedIdentExpr take
// TREE-NEXT:     |-AttributedExpr @create
// TREE-NEXT:     | `-CallExpr (1 args)
// TREE-NEXT:     |   |-NamedIdentExpr Config
// TREE-NEXT:     |   `-IntegerLiteralExpr 2
// TREE-NEXT:     `-IntegerLiteralExpr 3
// TREE: -- 0 error(s), 0 warning(s) --

// The source printer writes each form back as it was written.
// RUN: { %kairo %s --syntax-only --print-ast=flat 2>&1 || true; } | %FileCheck %s --check-prefix=FLAT
// FLAT: fn f() { var *cfg = @create Config(8080); var *gen = @create Box<i32>(1); var *blk = @create AST::Block(); var *pt = @create Point { x: 1, y: 2 }; var q = @align(16) Config(1); var u = @named(level: 2, 3) defaults(); var r = @a x + 1; var s = @create Config(1).port;
