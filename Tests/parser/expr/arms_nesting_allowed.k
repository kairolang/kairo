// Where an `if` / `try` expression may sit with no parentheses and no
// diagnostic: as the final `else` arm or final catch arm, as a match arm value,
// a whole initializer, a call argument, a return value, a statement
// expression's value, and the right side of any assignment operator (its
// right side runs to the end of the expression anyway). Anywhere at all once
// parenthesized.

fn allowed(c: bool, d: bool) {
    var a = if c => 0 else => (if d => 1 else => 2)
    var b = if c => (if d => 1 else => 2) else => 3
    var e = match s {
        case 1 => if c => 1 else => 2
        default => try f() catch => 0
    }
    var g = try (try f() catch => 1) catch => 2
    var h = try f() catch e: E1 => 1 catch => if c => 2 else => 3
    var i = if (if c => d else => c) => 1 else => 2
    var j = f(if c => 1 else => 2, try g() catch => 3)
    var k = ({ var t = 1; if c => t else => 0; })
}

fn assignments(c: bool) -> i32 {
    var x = if c => 1 else => 2
    x = if c => 1 else => 2
    x += if c => 1 else => 2
    x = try f() catch => 0
    return if c => x else => 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: TranslationUnit '{{.*}}arms_nesting_allowed.k'(fid=0)
// AST-NEXT: |-FunctionDecl  allowed(c: bool, d: bool)
// AST-NEXT: | |-ParamDecl c: bool
// AST-NEXT: | |-ParamDecl d: bool
// AST-NEXT: | `-CompoundStmt (8)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var a
// AST-NEXT: |   |   `-IfExpr
// AST-NEXT: |   |     |-cond
// AST-NEXT: |   |     | `-NamedIdentExpr c
// AST-NEXT: |   |     |-then
// AST-NEXT: |   |     | `-IntegerLiteralExpr 0
// AST-NEXT: |   |     `-else
// AST-NEXT: |   |       `-IfExpr
// AST-NEXT: |   |         |-cond
// AST-NEXT: |   |         | `-NamedIdentExpr d
// AST-NEXT: |   |         |-then
// AST-NEXT: |   |         | `-IntegerLiteralExpr 1
// AST-NEXT: |   |         `-else
// AST-NEXT: |   |           `-IntegerLiteralExpr 2
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var b
// AST-NEXT: |   |   `-IfExpr
// AST-NEXT: |   |     |-cond
// AST-NEXT: |   |     | `-NamedIdentExpr c
// AST-NEXT: |   |     |-then
// AST-NEXT: |   |     | `-IfExpr
// AST-NEXT: |   |     |   |-cond
// AST-NEXT: |   |     |   | `-NamedIdentExpr d
// AST-NEXT: |   |     |   |-then
// AST-NEXT: |   |     |   | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     |   `-else
// AST-NEXT: |   |     |     `-IntegerLiteralExpr 2
// AST-NEXT: |   |     `-else
// AST-NEXT: |   |       `-IntegerLiteralExpr 3
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var e
// AST-NEXT: |   |   `-MatchExpr (2 cases)
// AST-NEXT: |   |     |-NamedIdentExpr s
// AST-NEXT: |   |     |-case 1
// AST-NEXT: |   |     | `-IfExpr
// AST-NEXT: |   |     |   |-cond
// AST-NEXT: |   |     |   | `-NamedIdentExpr c
// AST-NEXT: |   |     |   |-then
// AST-NEXT: |   |     |   | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     |   `-else
// AST-NEXT: |   |     |     `-IntegerLiteralExpr 2
// AST-NEXT: |   |     `-default
// AST-NEXT: |   |       `-TryCatchExpr (1 arms)
// AST-NEXT: |   |         |-CallExpr (0 args)
// AST-NEXT: |   |         | `-NamedIdentExpr f
// AST-NEXT: |   |         `-catch
// AST-NEXT: |   |           `-IntegerLiteralExpr 0
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var g
// AST-NEXT: |   |   `-TryCatchExpr (1 arms)
// AST-NEXT: |   |     |-TryCatchExpr (1 arms)
// AST-NEXT: |   |     | |-CallExpr (0 args)
// AST-NEXT: |   |     | | `-NamedIdentExpr f
// AST-NEXT: |   |     | `-catch
// AST-NEXT: |   |     |   `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-catch
// AST-NEXT: |   |       `-IntegerLiteralExpr 2
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var h
// AST-NEXT: |   |   `-TryCatchExpr (2 arms)
// AST-NEXT: |   |     |-CallExpr (0 args)
// AST-NEXT: |   |     | `-NamedIdentExpr f
// AST-NEXT: |   |     |-catch e E1
// AST-NEXT: |   |     | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-catch
// AST-NEXT: |   |       `-IfExpr
// AST-NEXT: |   |         |-cond
// AST-NEXT: |   |         | `-NamedIdentExpr c
// AST-NEXT: |   |         |-then
// AST-NEXT: |   |         | `-IntegerLiteralExpr 2
// AST-NEXT: |   |         `-else
// AST-NEXT: |   |           `-IntegerLiteralExpr 3
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var i
// AST-NEXT: |   |   `-IfExpr
// AST-NEXT: |   |     |-cond
// AST-NEXT: |   |     | `-IfExpr
// AST-NEXT: |   |     |   |-cond
// AST-NEXT: |   |     |   | `-NamedIdentExpr c
// AST-NEXT: |   |     |   |-then
// AST-NEXT: |   |     |   | `-NamedIdentExpr d
// AST-NEXT: |   |     |   `-else
// AST-NEXT: |   |     |     `-NamedIdentExpr c
// AST-NEXT: |   |     |-then
// AST-NEXT: |   |     | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-else
// AST-NEXT: |   |       `-IntegerLiteralExpr 2
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var j
// AST-NEXT: |   |   `-CallExpr (2 args)
// AST-NEXT: |   |     |-NamedIdentExpr f
// AST-NEXT: |   |     |-IfExpr
// AST-NEXT: |   |     | |-cond
// AST-NEXT: |   |     | | `-NamedIdentExpr c
// AST-NEXT: |   |     | |-then
// AST-NEXT: |   |     | | `-IntegerLiteralExpr 1
// AST-NEXT: |   |     | `-else
// AST-NEXT: |   |     |   `-IntegerLiteralExpr 2
// AST-NEXT: |   |     `-TryCatchExpr (1 arms)
// AST-NEXT: |   |       |-CallExpr (0 args)
// AST-NEXT: |   |       | `-NamedIdentExpr g
// AST-NEXT: |   |       `-catch
// AST-NEXT: |   |         `-IntegerLiteralExpr 3
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var k
// AST-NEXT: |       `-StmtExpr
// AST-NEXT: |         `-CompoundStmt (2)
// AST-NEXT: |           |-DeclStmt
// AST-NEXT: |           | `-VariableDecl var t
// AST-NEXT: |           |   `-IntegerLiteralExpr 1
// AST-NEXT: |           `-ExpressionStmt
// AST-NEXT: |             `-IfExpr
// AST-NEXT: |               |-cond
// AST-NEXT: |               | `-NamedIdentExpr c
// AST-NEXT: |               |-then
// AST-NEXT: |               | `-NamedIdentExpr t
// AST-NEXT: |               `-else
// AST-NEXT: |                 `-IntegerLiteralExpr 0
// AST-NEXT: `-FunctionDecl  assignments(c: bool) -> i32
// AST-NEXT:   |-ParamDecl c: bool
// AST-NEXT:   `-CompoundStmt (5)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var x
// AST-NEXT:     |   `-IfExpr
// AST-NEXT:     |     |-cond
// AST-NEXT:     |     | `-NamedIdentExpr c
// AST-NEXT:     |     |-then
// AST-NEXT:     |     | `-IntegerLiteralExpr 1
// AST-NEXT:     |     `-else
// AST-NEXT:     |       `-IntegerLiteralExpr 2
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-AssignOperatorExpr =
// AST-NEXT:     |   |-NamedIdentExpr x
// AST-NEXT:     |   `-IfExpr
// AST-NEXT:     |     |-cond
// AST-NEXT:     |     | `-NamedIdentExpr c
// AST-NEXT:     |     |-then
// AST-NEXT:     |     | `-IntegerLiteralExpr 1
// AST-NEXT:     |     `-else
// AST-NEXT:     |       `-IntegerLiteralExpr 2
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-AssignOperatorExpr +=
// AST-NEXT:     |   |-NamedIdentExpr x
// AST-NEXT:     |   `-IfExpr
// AST-NEXT:     |     |-cond
// AST-NEXT:     |     | `-NamedIdentExpr c
// AST-NEXT:     |     |-then
// AST-NEXT:     |     | `-IntegerLiteralExpr 1
// AST-NEXT:     |     `-else
// AST-NEXT:     |       `-IntegerLiteralExpr 2
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-AssignOperatorExpr =
// AST-NEXT:     |   |-NamedIdentExpr x
// AST-NEXT:     |   `-TryCatchExpr (1 arms)
// AST-NEXT:     |     |-CallExpr (0 args)
// AST-NEXT:     |     | `-NamedIdentExpr f
// AST-NEXT:     |     `-catch
// AST-NEXT:     |       `-IntegerLiteralExpr 0
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-IfExpr
// AST-NEXT:         |-cond
// AST-NEXT:         | `-NamedIdentExpr c
// AST-NEXT:         |-then
// AST-NEXT:         | `-NamedIdentExpr x
// AST-NEXT:         `-else
// AST-NEXT:           `-IntegerLiteralExpr 0
// AST-NEXT: -- 0 error(s), 0 warning(s) --
