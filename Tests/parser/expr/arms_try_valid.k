// `=>` value arms of the expression-form `try`. The operand takes no `=>`: it
// ends at `catch`, a keyword. Arms keep their order, a typed arm before the
// default.

fn two_arms() {
    var n = try parse(s) catch e: ParseError => -1 catch => 0
}

// Each `catch` may open its own line.
fn split_lines() {
    var n = try parse(s)
        catch e: ParseError => -1
        catch => 0
}

// Every binding form of a catch arm, one default per `try`.
fn binding_forms() {
    var a = try f() catch => v
    var b = try f() catch e => v
    var c = try f() catch var e => v
    var d = try f() catch const e => v
    var e = try f() catch e: T => v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: TranslationUnit '{{.*}}arms_try_valid.k'(fid=0)
// AST-NEXT: |-FunctionDecl  two_arms()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var n
// AST-NEXT: |       `-TryCatchExpr (2 arms)
// AST-NEXT: |         |-CallExpr (1 args)
// AST-NEXT: |         | |-NamedIdentExpr parse
// AST-NEXT: |         | `-NamedIdentExpr s
// AST-NEXT: |         |-catch e ParseError
// AST-NEXT: |         | `-UnaryOperatorExpr prefix -
// AST-NEXT: |         |   `-IntegerLiteralExpr 1
// AST-NEXT: |         `-catch
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: |-FunctionDecl  split_lines()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var n
// AST-NEXT: |       `-TryCatchExpr (2 arms)
// AST-NEXT: |         |-CallExpr (1 args)
// AST-NEXT: |         | |-NamedIdentExpr parse
// AST-NEXT: |         | `-NamedIdentExpr s
// AST-NEXT: |         |-catch e ParseError
// AST-NEXT: |         | `-UnaryOperatorExpr prefix -
// AST-NEXT: |         |   `-IntegerLiteralExpr 1
// AST-NEXT: |         `-catch
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: `-FunctionDecl  binding_forms()
// AST-NEXT:   `-CompoundStmt (5)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var a
// AST-NEXT:     |   `-TryCatchExpr (1 arms)
// AST-NEXT:     |     |-CallExpr (0 args)
// AST-NEXT:     |     | `-NamedIdentExpr f
// AST-NEXT:     |     `-catch
// AST-NEXT:     |       `-NamedIdentExpr v
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var b
// AST-NEXT:     |   `-TryCatchExpr (1 arms)
// AST-NEXT:     |     |-CallExpr (0 args)
// AST-NEXT:     |     | `-NamedIdentExpr f
// AST-NEXT:     |     `-catch e
// AST-NEXT:     |       `-NamedIdentExpr v
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var c
// AST-NEXT:     |   `-TryCatchExpr (1 arms)
// AST-NEXT:     |     |-CallExpr (0 args)
// AST-NEXT:     |     | `-NamedIdentExpr f
// AST-NEXT:     |     `-catch e
// AST-NEXT:     |       `-NamedIdentExpr v
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var d
// AST-NEXT:     |   `-TryCatchExpr (1 arms)
// AST-NEXT:     |     |-CallExpr (0 args)
// AST-NEXT:     |     | `-NamedIdentExpr f
// AST-NEXT:     |     `-catch const e
// AST-NEXT:     |       `-NamedIdentExpr v
// AST-NEXT:     `-DeclStmt
// AST-NEXT:       `-VariableDecl var e
// AST-NEXT:         `-TryCatchExpr (1 arms)
// AST-NEXT:           |-CallExpr (0 args)
// AST-NEXT:           | `-NamedIdentExpr f
// AST-NEXT:           `-catch e T
// AST-NEXT:             `-NamedIdentExpr v
// AST-NEXT: -- 0 error(s), 0 warning(s) --
