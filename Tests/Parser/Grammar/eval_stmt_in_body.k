// `eval if` / `eval for` written directly in a module or class body parse
// into the nodes file scope and a function body build for them (a
// ConditionalStmt / RangedForStmt / IndexedForStmt, declarations in the
// branches as DeclStmts), carried by an EvalBlockDecl because those bodies
// hold declarations only. Before, a module body reported S046E "expected a
// name after the binding keyword" and a class body S048E "expected field
// name". Choosing the branch is not the parser's: the branches stay
// statements, and their declarations are not members of the body (see
// Tests/Sema/Check/feature_gate_eval_stmt.k for the gate).

module m {
    eval if true { pub fn g() -> i32 { return 1 } }
    else if false { eval LIMIT = 2 }
    else { fn g() -> i32 { return 2 } }
    eval for i in 0..2 { }
    eval for var j = 0; j < 2; ++j { }
    fn after() -> i32 { return 4 }
}

class K {
    var a: i32
    eval if true {
        var y: i32
        fn get(self) -> i32 { return self.a }
    }
    fn b(self) -> i32 { return self.a }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE-LABEL: TranslationUnit '{{.*}}eval_stmt_in_body.k'(fid=0)
// TREE-NEXT: |-ModuleDecl m
// TREE-NEXT: | |-EvalBlockDecl
// TREE-NEXT: | | `-ConditionalStmt
// TREE-NEXT: | |   |-cond
// TREE-NEXT: | |   | `-BooleanLiteralExpr true
// TREE-NEXT: | |   |-then
// TREE-NEXT: | |   | `-CompoundStmt (1)
// TREE-NEXT: | |   |   `-DeclStmt
// TREE-NEXT: | |   |     `-FunctionDecl pub   g() -> i32
// TREE-NEXT: | |   |       `-CompoundStmt (1)
// TREE-NEXT: | |   |         `-ReturnStmt
// TREE-NEXT: | |   |           `-IntegerLiteralExpr 1
// TREE-NEXT: | |   `-else
// TREE-NEXT: | |     `-ConditionalStmt
// TREE-NEXT: | |       |-cond
// TREE-NEXT: | |       | `-BooleanLiteralExpr false
// TREE-NEXT: | |       |-then
// TREE-NEXT: | |       | `-CompoundStmt (1)
// TREE-NEXT: | |       |   `-DeclStmt
// TREE-NEXT: | |       |     `-VariableDecl eval LIMIT
// TREE-NEXT: | |       |       `-IntegerLiteralExpr 2
// TREE-NEXT: | |       `-else
// TREE-NEXT: | |         `-CompoundStmt (1)
// TREE-NEXT: | |           `-DeclStmt
// TREE-NEXT: | |             `-FunctionDecl  g() -> i32
// TREE-NEXT: | |               `-CompoundStmt (1)
// TREE-NEXT: | |                 `-ReturnStmt
// TREE-NEXT: | |                   `-IntegerLiteralExpr 2
// TREE-NEXT: | |-EvalBlockDecl
// TREE-NEXT: | | `-RangedForStmt eval i
// TREE-NEXT: | |   |-RangeExpr ..
// TREE-NEXT: | |   | |-IntegerLiteralExpr 0
// TREE-NEXT: | |   | `-IntegerLiteralExpr 2
// TREE-NEXT: | |   `-CompoundStmt (0)
// TREE-NEXT: | |-EvalBlockDecl
// TREE-NEXT: | | `-IndexedForStmt eval
// TREE-NEXT: | |   |-DeclStmt
// TREE-NEXT: | |   | `-VariableDecl var j
// TREE-NEXT: | |   |   `-IntegerLiteralExpr 0
// TREE-NEXT: | |   |-BinaryOperatorExpr <
// TREE-NEXT: | |   | |-NamedIdentExpr j
// TREE-NEXT: | |   | `-IntegerLiteralExpr 2
// TREE-NEXT: | |   |-UnaryOperatorExpr prefix ++
// TREE-NEXT: | |   | `-NamedIdentExpr j
// TREE-NEXT: | |   `-CompoundStmt (0)
// TREE-NEXT: | `-FunctionDecl  after() -> i32
// TREE-NEXT: |   `-CompoundStmt (1)
// TREE-NEXT: |     `-ReturnStmt
// TREE-NEXT: |       `-IntegerLiteralExpr 4
// TREE-NEXT: `-ClassDecl K
// TREE-NEXT:   |-FieldDecl var a: i32
// TREE-NEXT:   |-EvalBlockDecl
// TREE-NEXT:   | `-ConditionalStmt
// TREE-NEXT:   |   |-cond
// TREE-NEXT:   |   | `-BooleanLiteralExpr true
// TREE-NEXT:   |   `-then
// TREE-NEXT:   |     `-CompoundStmt (2)
// TREE-NEXT:   |       |-DeclStmt
// TREE-NEXT:   |       | `-VariableDecl var y: i32
// TREE-NEXT:   |       `-DeclStmt
// TREE-NEXT:   |         `-FunctionDecl  get(self) -> i32
// TREE-NEXT:   |           |-ParamDecl self
// TREE-NEXT:   |           `-CompoundStmt (1)
// TREE-NEXT:   |             `-ReturnStmt
// TREE-NEXT:   |               `-ChainExpr 'self.a'
// TREE-NEXT:   |                 |-NamedIdentExpr self
// TREE-NEXT:   |                 `-Step .a
// TREE-NEXT:   `-FunctionDecl  b(self) -> i32
// TREE-NEXT:     |-ParamDecl self
// TREE-NEXT:     `-CompoundStmt (1)
// TREE-NEXT:       `-ReturnStmt
// TREE-NEXT:         `-ChainExpr 'self.a'
// TREE-NEXT:           |-NamedIdentExpr self
// TREE-NEXT:           `-Step .a
// TREE: -- 0 error(s), 0 warning(s) --
//
// Index pass - the branches hoist nothing (no `g`, `LIMIT`, `y`, `get`), and
// the members after each form, an `else` on its own line and a C-style
// header included, are still indexed where they belong.
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=INDEX
// INDEX-LABEL: [fid=0]
// INDEX-NEXT: === DisambigTable Dump ===
// INDEX-NEXT: ├── K  [class]
// INDEX-NEXT: ├── m/
// INDEX-NEXT: │   └── after  [fn]
// INDEX-NEXT: └── K/
// INDEX-NEXT:     ├── a  [var]
// INDEX-NEXT:     └── b  [fn]
// INDEX-NEXT: =========================
