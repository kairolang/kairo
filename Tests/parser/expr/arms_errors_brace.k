// The removed braced value arms. Each is S073E with a fix-it that rewrites
// the arm to `=> value` (a `try` operand just loses its braces), exact to the
// column. Recovery still builds the node, so nothing cascades. A braced arm
// that holds statements gets no fix-it, only a note. In statement position a
// match that mixes the two arm forms is S075E instead, and a statement `if`
// chain whose `else if` switches to `=>` is S056E.

fn brace_if(c: bool) {
    var z = if c { 1 } else { 2 }
// DIAG:      arms_errors_brace.k:[[@LINE-1]]:18: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-2]]:18-[[@LINE-2]]:20}:"=> "
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-3]]:21-[[@LINE-3]]:23}:""
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-4]]:29: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-5]]:29-[[@LINE-5]]:31}:"=> "
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-6]]:32-[[@LINE-6]]:34}:""
}

fn brace_try() {
    var n = try { f() } catch { 0 }
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-1]]:17: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-2]]:17-[[@LINE-2]]:19}:""
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-3]]:22-[[@LINE-3]]:24}:""
// DIAG-NEXT: note [I900N]: to 'try' a brace expression (a set literal or an anonymous initializer), parenthesize it: 'try ({ ... })'
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-5]]:31: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-6]]:31-[[@LINE-6]]:33}:"=> "
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-7]]:34-[[@LINE-7]]:36}:""
}

fn brace_match(s: i32) {
    var k = match s { case 1 { 2 } default { 3 } }
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-1]]:30: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-2]]:30-[[@LINE-2]]:32}:"=> "
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-3]]:33-[[@LINE-3]]:35}:""
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-4]]:44: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-5]]:44-[[@LINE-5]]:46}:"=> "
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-6]]:47-[[@LINE-6]]:49}:""
}

// Statements in a block arm: no fix-it, the note instead. The other arm is
// already `=>`, and the per-arm S073E covers the mix: no S075E on top.
fn brace_match_multi(s: i32) {
    var k = match s { case 1 { var t = 2; t } default => 3 }
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-1]]:30: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-2]]:30: note [I900N]: multi-statement arms are statement-only; use a statement-form match or a '({ ... })' statement expression
}

// In statement position the mix is S075E, its note at the first arm of the
// other form.
fn mixed_statement(s: i32) {
    match s { case 1 { f() } default => g() }
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-1]]:5: error [S075E]: match arms mix '=>' and '{ }' forms
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-2]]:30: note [I900N]: this arm uses the other form; every arm of one 'match' uses the same form
}

// A statement `if` chain is a statement all the way down: its `else if` takes
// a block, never `=>` arms. The arms are still consumed, so nothing cascades.
fn mixed_chain(c: bool, d: bool) {
    if c { } else if d => 1 else => 2
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-1]]:24: error [S056E]: expected '{' after 'else if' condition; a statement 'if' chain cannot continue with '=>' arms
}

// Across lines the fix-its keep each value on its own line: `if c =>`, the
// value, `else =>`, the value.
fn brace_if_multiline(c: bool) -> i32 {
    var z = if c {
        1
    } else {
        2
    }
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-5]]:18: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-6]]:18-[[@LINE-6]]:19}:"=>"
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-5]]:5-[[@LINE-5]]:7}:""
// DIAG-NEXT: arms_errors_brace.k:[[@LINE-6]]:12: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-7]]:12-[[@LINE-7]]:13}:"=>"
// DIAG-NEXT: fix-it:"{{.*}}arms_errors_brace.k":{[[@LINE-7]]:10-[[@LINE-6]]:6}:""
// DIAG-NOT:  error
    return z
}

// Recovery built the nodes: an IfExpr and a TryCatchExpr, values intact.
// AST:      VariableDecl var z
// AST-NEXT:   `-IfExpr
// AST-NEXT:     |-cond
// AST-NEXT:     | `-NamedIdentExpr c
// AST-NEXT:     |-then
// AST-NEXT:     | `-IntegerLiteralExpr 1
// AST-NEXT:     `-else
// AST-NEXT:       `-IntegerLiteralExpr 2
// AST:      VariableDecl var n
// AST-NEXT:   `-TryCatchExpr (1 arms)
// AST-NEXT:     |-CallExpr (0 args)
// AST-NEXT:     | `-NamedIdentExpr f
// AST-NEXT:     `-catch
// AST-NEXT:       `-IntegerLiteralExpr 0
// AST:      VariableDecl var k
// AST-NEXT:   `-MatchExpr (2 cases)
// AST-NEXT:     |-NamedIdentExpr s
// AST-NEXT:     |-case 1
// AST-NEXT:     | `-IntegerLiteralExpr 2
// AST-NEXT:     `-default
// AST-NEXT:       `-IntegerLiteralExpr 3

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
