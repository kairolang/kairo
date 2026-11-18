// A half-typed line inside a body. The failed operand's recovery
// leaves the body's `}` where it is, so each body closes on its own brace,
// each shape reports one error at the missing operand (nothing at the end
// of the file), and the healthy function after it is still a declaration
// of its own at the top level.

fn missing_rhs() -> i32 {
    var x = 1 +
}

fn ok_1() -> i32 { return 1 }

fn missing_init() -> i32 {
    var x =
}

fn ok_2() -> i32 { return 2 }

fn bare_return() -> i32 {
    return
}

fn ok_3() -> i32 { return 3 }

class P { var a: i32 }

fn trailing_dot(p: P) -> i32 {
    p.
}

fn ok_4() -> i32 { return 4 }

fn nested_block(c: bool) -> i32 {
    if c {
        var x = 1 +
    }
    return 0
}

fn ok_5() -> i32 { return 5 }

fn closure_body() -> i32 {
    var f = fn() -> i32 {
        var x = 1 +
    }
    return 0
}

fn ok_6() -> i32 { return 6 }

fn missing_unary_operand() -> i32 {
    var a = -
}

fn ok_7() -> i32 { return 7 }

fn stray_closer() -> i32 {
    var x = 1 + )
    return 0
}

fn ok_8() -> i32 { return 8 }

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR --implicit-check-not=error
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
//
// One error per broken body, at the token the operand was expected on; none
// at the end of the file.
// ERR: recovery_keeps_closer_expr.k:9:1: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_expr.k:15:1: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_expr.k:28:6: error [S054E]: expected identifier or tuple index after '.' in access expression
// ERR-NEXT: recovery_keeps_closer_expr.k:36:5: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_expr.k:45:5: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_expr.k:52:14: error [S052E]: expected expression, found 'new line'
// ERR-NEXT: recovery_keeps_closer_expr.k:58:17: error [S052E]: expected expression, found ')'
//
// Every function, the healthy ones included, is its own top-level
// declaration: no body ran on and swallowed the one after it.
// AST: {{^}}|-FunctionDecl  missing_rhs() -> i32
// AST: {{^}}|-FunctionDecl  ok_1() -> i32
// AST: {{^}}|-FunctionDecl  missing_init() -> i32
// AST: {{^}}|-FunctionDecl  ok_2() -> i32
// AST: {{^}}|-FunctionDecl  bare_return() -> i32
// AST: {{^}}|-FunctionDecl  ok_3() -> i32
// AST: {{^}}|-FunctionDecl  trailing_dot(p: P) -> i32
// AST: {{^}}|-FunctionDecl  ok_4() -> i32
// AST: {{^}}|-FunctionDecl  nested_block(c: bool) -> i32
// AST: {{^}}|-FunctionDecl  ok_5() -> i32
// AST: {{^}}|-FunctionDecl  closure_body() -> i32
// AST: {{^}}|-FunctionDecl  ok_6() -> i32
// AST: {{^}}|-FunctionDecl  missing_unary_operand() -> i32
// AST: {{^}}|-FunctionDecl  ok_7() -> i32
// AST: {{^}}|-FunctionDecl  stray_closer() -> i32
// AST: {{^}}`-FunctionDecl  ok_8() -> i32
// AST: -- 7 error(s), 0 warning(s) --
