// `=>` value arms of the expression-form `match`. Every arm sets
// MatchCase::expression and leaves the body null. Inside the braces the next
// `case`, `default` or the closing `}` ends an arm's value, and the `}` closes
// the whole value, so it never runs into what follows.

fn arms() {
    var k = match s {
        case 2 => x + y
        case 3, 4 => 1
        case 5..=9 => 2
        case .Found(var v) where v > 0 => v
        default => 0
    }
}

// `=>` may open the next line, and the value may follow on the next line.
fn split_lines() {
    var k = match s {
        case 2
        => x
        case 3 =>
        y
        default => 0
    }
}

// The `}` closes the value: this is `MatchExpr + 2`.
fn closed_by_brace() {
    var k = match s { default => 1 } + 2
}

// After `=>` a brace is a value again: a set literal, or a statement
// expression for an arm that needs statements.
fn brace_values() {
    var k = match s {
        case 1 => {1, 2}
        case 2 => ({ var t = f(); (t + 1); })
        default => {3}
    }
}

// An open upper bound ends at `=>`.
fn open_range() {
    var k = match s {
        case 5.. => 1
        default => 0
    }
}

// A block arm's range bound is not a named initializer: `N` is the bound and
// the braces are the arm's block.
fn range_bound_then_block() {
    match s {
        case 0..N { }
        default { }
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST: TranslationUnit '{{.*}}arms_match_valid.k'(fid=0)
// AST-NEXT: |-FunctionDecl  arms()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var k
// AST-NEXT: |       `-MatchExpr (5 cases)
// AST-NEXT: |         |-NamedIdentExpr s
// AST-NEXT: |         |-case 2
// AST-NEXT: |         | `-BinaryOperatorExpr +
// AST-NEXT: |         |   |-NamedIdentExpr x
// AST-NEXT: |         |   `-NamedIdentExpr y
// AST-NEXT: |         |-case 3, 4
// AST-NEXT: |         | `-IntegerLiteralExpr 1
// AST-NEXT: |         |-case 5..=9
// AST-NEXT: |         | `-IntegerLiteralExpr 2
// AST-NEXT: |         |-case .Found(var v) where v > 0
// AST-NEXT: |         | `-NamedIdentExpr v
// AST-NEXT: |         `-default
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: |-FunctionDecl  split_lines()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var k
// AST-NEXT: |       `-MatchExpr (3 cases)
// AST-NEXT: |         |-NamedIdentExpr s
// AST-NEXT: |         |-case 2
// AST-NEXT: |         | `-NamedIdentExpr x
// AST-NEXT: |         |-case 3
// AST-NEXT: |         | `-NamedIdentExpr y
// AST-NEXT: |         `-default
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: |-FunctionDecl  closed_by_brace()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var k
// AST-NEXT: |       `-BinaryOperatorExpr +
// AST-NEXT: |         |-MatchExpr (1 cases)
// AST-NEXT: |         | |-NamedIdentExpr s
// AST-NEXT: |         | `-default
// AST-NEXT: |         |   `-IntegerLiteralExpr 1
// AST-NEXT: |         `-IntegerLiteralExpr 2
// AST-NEXT: |-FunctionDecl  brace_values()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var k
// AST-NEXT: |       `-MatchExpr (3 cases)
// AST-NEXT: |         |-NamedIdentExpr s
// AST-NEXT: |         |-case 1
// AST-NEXT: |         | `-SetLiteralExpr (2)
// AST-NEXT: |         |   |-IntegerLiteralExpr 1
// AST-NEXT: |         |   `-IntegerLiteralExpr 2
// AST-NEXT: |         |-case 2
// AST-NEXT: |         | `-StmtExpr
// AST-NEXT: |         |   `-CompoundStmt (2)
// AST-NEXT: |         |     |-DeclStmt
// AST-NEXT: |         |     | `-VariableDecl var t
// AST-NEXT: |         |     |   `-CallExpr (0 args)
// AST-NEXT: |         |     |     `-NamedIdentExpr f
// AST-NEXT: |         |     `-ExpressionStmt
// AST-NEXT: |         |       `-BinaryOperatorExpr +
// AST-NEXT: |         |         |-NamedIdentExpr t
// AST-NEXT: |         |         `-IntegerLiteralExpr 1
// AST-NEXT: |         `-default
// AST-NEXT: |           `-SetLiteralExpr (1)
// AST-NEXT: |             `-IntegerLiteralExpr 3
// AST-NEXT: |-FunctionDecl  open_range()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var k
// AST-NEXT: |       `-MatchExpr (2 cases)
// AST-NEXT: |         |-NamedIdentExpr s
// AST-NEXT: |         |-case 5..
// AST-NEXT: |         | `-IntegerLiteralExpr 1
// AST-NEXT: |         `-default
// AST-NEXT: |           `-IntegerLiteralExpr 0
// AST-NEXT: `-FunctionDecl  range_bound_then_block()
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-MatchStmt (2 cases)
// AST-NEXT:       |-NamedIdentExpr s
// AST-NEXT:       |-case 0..N
// AST-NEXT:       | `-CompoundStmt (0)
// AST-NEXT:       `-default
// AST-NEXT:         `-CompoundStmt (0)
// AST-NEXT: -- 0 error(s), 0 warning(s) --
