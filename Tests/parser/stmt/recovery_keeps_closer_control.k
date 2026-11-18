// Half-typed control flow. A broken `if` condition, a match arm with
// no value, and a `case` with no pattern each report once; the match's and
// the body's braces still close what they opened.

fn broken_condition_dot(c: bool) -> i32 {
    if c. {
        return 1
    }
    return 0
}

fn ok_1() -> i32 { return 1 }

fn broken_condition_operand(c: i32) -> i32 {
    if (c > ) {
        return 1
    }
    return 0
}

fn ok_2() -> i32 { return 2 }

fn arm_missing_value_before_block_arm(v: i32) -> i32 {
    match v {
        case 1 =>
        case _ { return 0 }
    }
    return 1
}

fn ok_3() -> i32 { return 3 }

fn last_arm_missing_value(v: i32) -> i32 {
    var r = match v {
        case 1 => 5
        case 2 =>
    }
    return r
}

fn ok_4() -> i32 { return 4 }

fn case_missing_pattern(v: i32) -> i32 {
    match v {
        case
    }
    return 1
}

fn ok_5() -> i32 { return 5 }

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR --implicit-check-not=error
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
//
// The arm with no value is not "the other form" against the `{ }` arm after
// it: one error, no S075E.
// ERR: recovery_keeps_closer_control.k:6:9: error [S054E]: expected identifier or tuple index after '.' in access expression
// ERR-NEXT: recovery_keeps_closer_control.k:15:13: error [S052E]: expected expression, found ')'
// ERR-NEXT: recovery_keeps_closer_control.k:26:9: error [S052E]: expected expression, found 'case'
// ERR-NEXT: recovery_keeps_closer_control.k:36:16: error [S052E]: expected a value expression after '=>'
// ERR-NEXT: recovery_keeps_closer_control.k:46:5: error [S061E]: expected a pattern, found '}'
//
// AST: {{^}}|-FunctionDecl  broken_condition_dot(c: bool) -> i32
// AST: {{^}}|-FunctionDecl  ok_1() -> i32
// AST: {{^}}|-FunctionDecl  broken_condition_operand(c: i32) -> i32
// AST: {{^}}|-FunctionDecl  ok_2() -> i32
// AST: {{^}}|-FunctionDecl  arm_missing_value_before_block_arm(v: i32) -> i32
// AST: {{^}}|-FunctionDecl  ok_3() -> i32
// AST: {{^}}|-FunctionDecl  last_arm_missing_value(v: i32) -> i32
// AST: {{^}}|-FunctionDecl  ok_4() -> i32
// AST: {{^}}|-FunctionDecl  case_missing_pattern(v: i32) -> i32
// AST: {{^}}`-FunctionDecl  ok_5() -> i32
// AST: -- 5 error(s), 0 warning(s) --
