// `thread` declares a thread-local binding at file scope, in a module, in
// a class and in a function body (variables.mdx, "Thread-Local
// Variables"), with its type written or inferred like `static`. Before
// this, `thread x: i32 = 1` in a function was S052E "expected expression,
// found ':'" and `thread t = 7` at file scope parsed as a spawn of the
// expression `t = 7`. A `thread` binding is Static storage with is_thread
// -- what `static thread` always built -- so the tree prints `thread` for
// both. `thread work()` is still the spawn expression: only a name followed
// by `:`, `=` or the end of the statement makes a binding.

fn work() -> i32 { return 1 }

thread t = 7
thread counter: i32 = 0
thread const NAME: i32 = 3
const thread NAME2 = 4
static thread OLD: i32 = 5
thread *tp = &t
thread maybe? = 5
thread plain: i32
thread work()

module m {
    pub thread mt: i32 = 1
    priv thread request_id: u64 = 0
}

class Pool {
    pub thread current: *Pool?
    thread const LIMIT: i32 = 8
}

fn next_id() -> i32 {
    thread c: i32 = 0
    thread d = 10
    var fut = thread work()
    thread work()
    return c + d
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE-LABEL: TranslationUnit '{{.*}}thread_decl_positions.k'(fid=0)
// TREE:      |-VariableDecl thread t
// TREE-NEXT: | `-IntegerLiteralExpr 7
// TREE-NEXT: |-VariableDecl thread counter: i32
// TREE-NEXT: | `-IntegerLiteralExpr 0
// TREE-NEXT: |-VariableDecl thread const NAME: i32
// TREE-NEXT: | `-IntegerLiteralExpr 3
// TREE-NEXT: |-VariableDecl thread const NAME2
// TREE-NEXT: | `-IntegerLiteralExpr 4
// TREE-NEXT: |-VariableDecl thread OLD: i32
// TREE-NEXT: | `-IntegerLiteralExpr 5
// TREE-NEXT: |-VariableDecl thread *tp
// TREE-NEXT: | `-UnaryOperatorExpr prefix &
// TREE-NEXT: |   `-NamedIdentExpr t
// TREE-NEXT: |-VariableDecl thread maybe?
// TREE-NEXT: | `-IntegerLiteralExpr 5
// TREE-NEXT: |-VariableDecl thread plain: i32
// TREE-NEXT: |-ExpressionStmt
// TREE-NEXT: | `-ThreadExpr
// TREE-NEXT: |   `-CallExpr (0 args)
// TREE-NEXT: |     `-NamedIdentExpr work
// TREE-NEXT: |-ModuleDecl m
// TREE-NEXT: | |-VariableDecl pub thread mt: i32
// TREE-NEXT: | | `-IntegerLiteralExpr 1
// TREE-NEXT: | `-VariableDecl priv thread request_id: u64
// TREE-NEXT: |   `-IntegerLiteralExpr 0
// TREE-NEXT: |-ClassDecl Pool
// TREE-NEXT: | |-FieldDecl pub thread current: *Pool?
// TREE-NEXT: | `-FieldDecl thread const LIMIT: i32
// TREE-NEXT: |   `-IntegerLiteralExpr 8
// TREE-NEXT: `-FunctionDecl next_id() -> i32
// TREE-NEXT:   `-CompoundStmt (5)
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl thread c: i32
// TREE-NEXT:     |   `-IntegerLiteralExpr 0
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl thread d
// TREE-NEXT:     |   `-IntegerLiteralExpr 10
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl var fut
// TREE-NEXT:     |   `-ThreadExpr
// TREE-NEXT:     |     `-CallExpr (0 args)
// TREE-NEXT:     |       `-NamedIdentExpr work
// TREE-NEXT:     |-ExpressionStmt
// TREE-NEXT:     | `-ThreadExpr
// TREE-NEXT:     |   `-CallExpr (0 args)
// TREE-NEXT:     |     `-NamedIdentExpr work
// TREE-NEXT:     `-ReturnStmt
// TREE: -- 0 error(s), 0 warning(s) --
