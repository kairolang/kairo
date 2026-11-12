// A half-typed line inside a type. A method body, a field initializer,
// an enum variant's value and a missing type each report once, and the
// type's own `}` closes the type: the declarations after it are their own.

class C {
    fn m(self) -> i32 {
        var x = 1 +
    }

    fn n(self) -> i32 { return 3 }
}

fn ok_1() -> i32 { return 1 }

class D {
    var x: i32 = 1 +
}

fn ok_2() -> i32 { return 2 }

enum E {
    A =
}

fn ok_3() -> i32 { return 3 }

class F {
    var x:
}

fn ok_4() -> i32 { return 4 }

fn missing_local_type() -> i32 {
    var x:
}

fn ok_5() -> i32 { return 5 }

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR --implicit-check-not=error
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
//
// ERR: recovery_keeps_closer_decls.k:8:5: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_decls.k:17:1: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_decls.k:23:1: error [S052E]: expected expression, found '}'
// ERR-NEXT: recovery_keeps_closer_decls.k:29:1: error [S053E]: expected type, found '}'
// ERR-NEXT: recovery_keeps_closer_decls.k:35:1: error [S053E]: expected type, found '}'
//
// The method after the broken one is still a member of C.
// AST: {{^}}|-ClassDecl C
// AST-NEXT: {{^}}| |-FunctionDecl  m(self) -> i32
// AST: {{^}}| `-FunctionDecl  n(self) -> i32
// AST: {{^}}|-FunctionDecl  ok_1() -> i32
// AST: {{^}}|-ClassDecl D
// AST: {{^}}|-FunctionDecl  ok_2() -> i32
// AST: {{^}}|-EnumDecl E
// AST: {{^}}|-FunctionDecl  ok_3() -> i32
// AST: {{^}}|-ClassDecl F
// AST: {{^}}|-FunctionDecl  ok_4() -> i32
// AST: {{^}}|-FunctionDecl  missing_local_type() -> i32
// AST: {{^}}`-FunctionDecl  ok_5() -> i32
// AST: -- 5 error(s), 0 warning(s) --
