// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (1)
// CHECK-NEXT:   `-ExpressionStmt
// CHECK-NEXT:     `-IntegerLiteralExpr 1
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

{
    1
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (1)
// CHECK-NEXT:   `-DeclStmt
// CHECK-NEXT:     `-VariableDecl var x
// CHECK-NEXT:       `-IntegerLiteralExpr 1
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
var x = 1
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (1)
// CHECK-NEXT:   `-LoopStmt
// CHECK-NEXT:     `-CompoundStmt (1)
// CHECK-NEXT:       `-DeclStmt
// CHECK-NEXT:         `-VariableDecl var x
// CHECK-NEXT:           `-IntegerLiteralExpr 1
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
loop {
var x = 1
    }
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (0)
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (2)
// CHECK-NEXT:   |-DeclStmt
// CHECK-NEXT:   | `-FunctionDecl <T> nested()
// CHECK-NEXT:   |   |-GenericParamDecl 'T'
// CHECK-NEXT:   |   `-CompoundStmt (1)
// CHECK-NEXT:   |     `-ReturnStmt
// CHECK-NEXT:   |       `-CallExpr (0 args)
// CHECK-NEXT:   |         `-NamedIdentExpr T
// CHECK-NEXT:   `-DeclStmt
// CHECK-NEXT:     `-VariableDecl var y
// CHECK-NEXT:       `-CallExpr (0 args)
// CHECK-NEXT:         `-NamedIdentExpr nested<i32>
// CHECK-NEXT:           `-GenericArg 'i32'
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
fn <T> nested() {
return T()
    }
var y = nested<i32>()
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (2)
// CHECK-NEXT:   |-DeclStmt
// CHECK-NEXT:   | `-FunctionDecl  nested()
// CHECK-NEXT:   |   `-CompoundStmt (1)
// CHECK-NEXT:   |     `-ReturnStmt
// CHECK-NEXT:   |       `-CallExpr (0 args)
// CHECK-NEXT:   |         `-NamedIdentExpr Foo
// CHECK-NEXT:   `-DeclStmt
// CHECK-NEXT:     `-VariableDecl var y
// CHECK-NEXT:       `-CallExpr (0 args)
// CHECK-NEXT:         `-NamedIdentExpr nested<i32>
// CHECK-NEXT:           `-GenericArg 'i32'
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
fn nested() {
return Foo()
    }
var y = nested<i32>()
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (2)
// CHECK-NEXT:   |-DeclStmt
// CHECK-NEXT:   | `-FunctionDecl <T> nested()
// CHECK-NEXT:   |   |-GenericParamDecl 'T'
// CHECK-NEXT:   |   `-CompoundStmt (1)
// CHECK-NEXT:   |     `-ReturnStmt
// CHECK-NEXT:   |       `-CallExpr (0 args)
// CHECK-NEXT:   |         `-NamedIdentExpr T
// CHECK-NEXT:   `-DeclStmt
// CHECK-NEXT:     `-VariableDecl var y
// CHECK-NEXT:       `-CallExpr (0 args)
// CHECK-NEXT:         `-NamedIdentExpr nested
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
fn <T> nested() {
return T()
    }
var y = nested()
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (3)
// CHECK-NEXT:   |-DeclStmt
// CHECK-NEXT:   | `-VariableDecl var x
// CHECK-NEXT:   |   `-IntegerLiteralExpr 1
// CHECK-NEXT:   |-DeclStmt
// CHECK-NEXT:   | `-VariableDecl var y
// CHECK-NEXT:   |   `-IntegerLiteralExpr 2
// CHECK-NEXT:   `-ExpressionStmt
// CHECK-NEXT:     `-CallExpr (0 args)
// CHECK-NEXT:       `-NamedIdentExpr expr_stmt
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
var x = 1
var y = 2
expr_stmt()
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (2)
// CHECK-NEXT:   |-DeclStmt
// CHECK-NEXT:   | `-VariableDecl var x
// CHECK-NEXT:   |   `-IntegerLiteralExpr 1
// CHECK-NEXT:   `-DeclStmt
// CHECK-NEXT:     `-VariableDecl var y
// CHECK-NEXT:       `-IntegerLiteralExpr 2
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
var x = 1 var y = 2
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (1)
// CHECK-NEXT:   `-DeclStmt
// CHECK-NEXT:     `-VariableDecl var x
// CHECK-NEXT:       `-IntegerLiteralExpr 1
// CHECK: -- 1 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// CHECK: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S021E]:
// CHECK: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S057E]:
// END-GENERATED-CHECKS


{
var x = 1

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (1)
// CHECK-NEXT:   `-CompoundStmt (1)
// CHECK-NEXT:     `-DeclStmt
// CHECK-NEXT:       `-VariableDecl var x
// CHECK-NEXT:         `-IntegerLiteralExpr 1
// CHECK: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS


{
{
var x = 1
    }
}

// SEPARATE:

// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: %kairo --print-ast=tree %s | %FileCheck %s
// CHECK: ============== AST (tree) for fid 0 ==============
// CHECK-NEXT: TranslationUnit '{{.*}}'(fid=0)
// CHECK-NEXT: `-CompoundStmt (3)
// CHECK-NEXT:   |-DeclStmt
// CHECK-NEXT:   | `-VariableDecl var x
// CHECK-NEXT:   |   `-NamedIdentExpr foo
// CHECK-NEXT:   |-ExpressionStmt
// CHECK-NEXT:   | `-RecoveryExpr trying: ChainExpr
// CHECK-NEXT:   `-ExpressionStmt
// CHECK-NEXT:     `-BinaryOperatorExpr >
// CHECK-NEXT:       |-RecoveryExpr trying: ChainExpr
// CHECK-NEXT:       `-RecoveryExpr trying: ChainExpr
// CHECK: -- 3 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// CHECK: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S052E]:
// CHECK: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S052E]:
// CHECK: {{.*}}:{{[0-9]+}}:{{[0-9]+}}: error [S054E]:
// END-GENERATED-CHECKS

{
var x = foo
<i32>()
}
