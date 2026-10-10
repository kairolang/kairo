// The readability rules for the open-ended forms. An `if` / `try` whose last
// arm would run into more of an enclosing construct must be parenthesized
// (S077E, with a fix-it adding the parens), except a `try` nested bare in a
// `try`: it took every `catch` after it, so the split cannot be recovered and
// there is no fix-it. As an operator's operand it only warns (S078W).
// `else => if` warns too (S079W): it is `else if` spelled the long way.

fn must_parenthesize(a: bool, b: bool, c: bool, s: i32) {
    var z10 = if a => if b => 1 else => 2 else => 3
// DIAG:      arms_errors_nesting.k:[[@LINE-1]]:23: error [S077E]: an 'if' expression here must be parenthesized
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:23-[[@LINE-2]]:23}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:42-[[@LINE-3]]:42}:")"
    var z11 = if (if a => b else => c) => 1 else => 2
    var z11b = if if a => b else => c => 1 else => 2
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:19: error [S077E]: an 'if' expression here must be parenthesized
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:19-[[@LINE-2]]:19}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:38-[[@LINE-3]]:38}:")"
    var k12 = match s { case x where if a => b else => c => 1 default => 0 }
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:38: error [S077E]: an 'if' expression here must be parenthesized
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:38-[[@LINE-2]]:38}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:57-[[@LINE-3]]:57}:")"
    var n13 = try if c => f() else => g() catch => 0
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:19: error [S077E]: an 'if' expression here must be parenthesized
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:19-[[@LINE-2]]:19}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:42-[[@LINE-3]]:42}:")"
    var n14 = try try f() catch => 1 catch => 2
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:19: error [S077E]: a 'try' expression here must be parenthesized
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-2]]:19: note [I900N]: the inner 'try' took every following 'catch' arm; parenthesize the inner 'try' and its own arms
    var n15 = try f() catch e: E1 => if c => 1 else => 2 catch => 3
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:38: error [S077E]: an 'if' expression here must be parenthesized
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:38-[[@LINE-2]]:38}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:57-[[@LINE-3]]:57}:")"
    var k16 = match if c => a else => b { default => 1 }
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:21: error [S077E]: an 'if' expression here must be parenthesized
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:21-[[@LINE-2]]:21}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:40-[[@LINE-3]]:40}:")"
    if if a => b else => c { }
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:8: error [S077E]: an 'if' expression here must be parenthesized
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:8-[[@LINE-2]]:8}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:27-[[@LINE-3]]:27}:")"
}

fn warns(a: bool, b: bool, c: bool, x: i32) {
    var z17 = x + if c => 1 else => 2
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:19: warning [S078W]: this 'if' expression extends to the end of the expression
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:19-[[@LINE-2]]:19}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:38-[[@LINE-3]]:38}:")"
    var z18 = -if c => 1 else => 2
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:16: warning [S078W]: this 'if' expression extends to the end of the expression
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:16-[[@LINE-2]]:16}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:35-[[@LINE-3]]:35}:")"
    var z20 = x ?? try f() catch => 0
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:20: warning [S078W]: this 'try' expression extends to the end of the expression
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:20-[[@LINE-2]]:20}:"("
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-3]]:38-[[@LINE-3]]:38}:")"
    var z19 = if a => 1 else => if b => 2 else => 3
// DIAG-NEXT: arms_errors_nesting.k:[[@LINE-1]]:30: warning [S079W]: write 'else if'
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_nesting.k":{[[@LINE-2]]:30-[[@LINE-2]]:33}:""
// DIAG-NOT:  {{error|warning}}
}

// The warning is about readability only: the tree is still `x + IfExpr`. The
// try-in-try outer node is a recovery (the printer elides it), never a try
// with zero arms.
// AST:      VariableDecl var n14
// AST-NEXT: DeclStmt
// AST-NEXT: VariableDecl var n15
// AST:      VariableDecl var z17
// AST-NEXT:   `-BinaryOperatorExpr +
// AST-NEXT:     |-NamedIdentExpr x
// AST-NEXT:     `-IfExpr

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
