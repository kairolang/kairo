// A value arm without its `=>` is S074E, with a fix-it inserting `=> ` where
// the value starts; the value is then parsed as if the arrow were there, so
// one missing `=>` costs one diagnostic. A missing final `else` stays S054E.
// A `,` between match arms is S076E, removed by its fix-it.

fn missing_arrow(c: bool) {
    var z6 = if c 1 else => 2
// DIAG:      arms_errors_arrow.k:[[@LINE-1]]:19: error [S074E]: expected '=>' after condition
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_arrow.k":{[[@LINE-2]]:19-[[@LINE-2]]:19}:"=> "
    var z7 = if c => 1 else 2
// DIAG-NEXT: arms_errors_arrow.k:[[@LINE-1]]:29: error [S074E]: expected '=>' after 'else'
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_arrow.k":{[[@LINE-2]]:29-[[@LINE-2]]:29}:"=> "
    var z8 = if c => 1
// DIAG-NEXT: arms_errors_arrow.k:[[@LINE-1]]:14: error [S054E]: expression-form 'if' requires a final 'else' (every branch must yield a value)
}

fn arm_comma(s: i32) {
    var k = match s {
        case 1 => a,
// DIAG-NEXT: arms_errors_arrow.k:[[@LINE-1]]:20: error [S076E]: match arms are not separated by ','
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_arrow.k":{[[@LINE-2]]:20-[[@LINE-2]]:21}:""
        default => b
    }
}

fn missing_arrow_arms(s: i32) {
    var k = match s {
        case 1 a
// DIAG-NEXT: arms_errors_arrow.k:[[@LINE-1]]:16: error [S074E]: expected '=>' after pattern
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_arrow.k":{[[@LINE-2]]:16-[[@LINE-2]]:16}:"=> "
        default => b
    }
    var n = try f() catch e 0
// DIAG-NEXT: arms_errors_arrow.k:[[@LINE-1]]:29: error [S074E]: expected '=>' after catch arm
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_arrow.k":{[[@LINE-2]]:29-[[@LINE-2]]:29}:"=> "
// DIAG-NOT:  {{error|warning}}
}

// The recovered values are in the tree.
// AST:      VariableDecl var z6
// AST-NEXT:   `-IfExpr
// AST-NEXT:     |-cond
// AST-NEXT:     | `-NamedIdentExpr c
// AST-NEXT:     |-then
// AST-NEXT:     | `-IntegerLiteralExpr 1
// AST-NEXT:     `-else
// AST-NEXT:       `-IntegerLiteralExpr 2
// AST:      VariableDecl var k
// AST-NEXT:   `-MatchExpr (2 cases)
// AST-NEXT:     |-NamedIdentExpr s
// AST-NEXT:     |-case 1
// AST-NEXT:     | `-NamedIdentExpr a
// AST-NEXT:     `-default
// AST-NEXT:       `-NamedIdentExpr b

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
