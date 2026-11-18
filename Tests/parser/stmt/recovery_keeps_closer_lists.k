// A broken element inside brackets. The failed operand leaves the
// separator and the closers where they are: the list takes its next
// element after the `,`, an unclosed `(` costs one "expected ')'" and the
// block's `}` still closes the block, and a hole is reported.

fn foo(a: i32, b: i32) -> i32 { return a }

fn unclosed_call() -> i32 {
    foo(1, 
}

fn ok_1() -> i32 { return 1 }

fn broken_list_element() -> i32 {
    var a = [1, 2 +, 3]
    return 0
}

fn ok_2() -> i32 { return 2 }

fn broken_call_argument() -> i32 {
    var b = foo(1 *, 2)
    return b
}

fn ok_3() -> i32 { return 3 }

class Pt { var a: i32 var b: i32 }

fn broken_field_value() -> i32 {
    var p = Pt { a: 1 +, b: 2 }
    return 0
}

fn ok_4() -> i32 { return 4 }

fn missing_field_value() -> i32 {
    var p = Pt { a: 1, b: }
    return 0
}

fn ok_5() -> i32 { return 5 }

fn call_hole() -> i32 {
    return foo(1, , 2)
}

fn ok_6() -> i32 { return 6 }

fn unclosed_group() -> i32 {
    var x = (1 +
}

fn ok_7() -> i32 { return 7 }

fn wrong_closer_in_call() -> i32 {
    foo(1 + ]
}

fn ok_8() -> i32 { return 8 }

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR --implicit-check-not=error
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
//
// ERR: recovery_keeps_closer_lists.k:9:8: error [S054E]: expected ')' to close function call argument list
// ERR-NEXT: recovery_keeps_closer_lists.k:15:20: error [S052E]: expected expression, found ','
// ERR-NEXT: recovery_keeps_closer_lists.k:22:20: error [S052E]: expected expression, found ','
// ERR-NEXT: recovery_keeps_closer_lists.k:31:24: error [S052E]: expected expression, found ','
// ERR-NEXT: recovery_keeps_closer_lists.k:38:27: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_lists.k:45:19: error [S052E]: expected expression, found ','
// ERR-NEXT: recovery_keeps_closer_lists.k:51:14: error [S054E]: expected ')' or ',' after expression
// ERR-NEXT: recovery_keeps_closer_lists.k:52:1: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_lists.k:57:8: error [S054E]: expected ')' to close function call argument list
// ERR-NEXT: recovery_keeps_closer_lists.k:57:13: error [S052E]: expected expression, found ']'
//
// The broken list keeps the elements on both sides of the bad one, and every
// function is its own top-level declaration.
// AST: {{^}}|-FunctionDecl  broken_list_element() -> i32
// AST: ListLiteralExpr (3)
// AST: {{^}}|-FunctionDecl  ok_2() -> i32
// AST: {{^}}|-FunctionDecl  broken_call_argument() -> i32
// AST: CallExpr (2 args)
// AST: {{^}}|-FunctionDecl  ok_3() -> i32
// AST: {{^}}|-FunctionDecl  ok_4() -> i32
// AST: {{^}}|-FunctionDecl  ok_5() -> i32
// AST: {{^}}|-FunctionDecl  ok_6() -> i32
// AST: {{^}}|-FunctionDecl  ok_7() -> i32
// AST: {{^}}`-FunctionDecl  ok_8() -> i32
// AST: -- 10 error(s), 0 warning(s) --
