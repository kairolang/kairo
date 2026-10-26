// `const` combines with a storage keyword in either order -- `static const`
// and `const static`, `eval const` and `const eval` -- and both orders are
// one declaration (variables.mdx). The tree prints one canonical spelling,
// so each pair below must check to identical rows: the parser keeps the
// storage keyword and records the const, never the order it was written in.
// `eval` is const already, so `eval const` / `const eval` are plain `eval`.
// Before this, `static const a = 1` was S046E "expected a name after the
// binding keyword", in every position.

static const A = 1
const static B = 2
static const C: i32 = 3
static const D? = 5
static G: i32 = 7
static const *P = &G
static thread const T: i32 = 8
const static thread U: i32 = 9

module m {
    static const MA = 1
    const static MB = 2
    eval const MC = 3
    const eval MD = 4
}

class K {
    static const KA: i32 = 1
    const static KB: i32 = 2
    eval const KC: i32 = 3
    const eval KD: i32 = 4
}

fn f() {
    static const LA = 1
    const static LB = 2
    eval const LC = 3
    const eval LD = 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE-LABEL: TranslationUnit '{{.*}}storage_const_order.k'(fid=0)
// TREE-NEXT: |-VariableDecl static const A
// TREE-NEXT: | `-IntegerLiteralExpr 1
// TREE-NEXT: |-VariableDecl static const B
// TREE-NEXT: | `-IntegerLiteralExpr 2
// TREE-NEXT: |-VariableDecl static const C: i32
// TREE-NEXT: | `-IntegerLiteralExpr 3
// TREE-NEXT: |-VariableDecl static const D?
// TREE-NEXT: | `-IntegerLiteralExpr 5
// TREE-NEXT: |-VariableDecl static G: i32
// TREE-NEXT: | `-IntegerLiteralExpr 7
// TREE-NEXT: |-VariableDecl static const *P
// TREE-NEXT: | `-UnaryOperatorExpr prefix &
// TREE-NEXT: |   `-NamedIdentExpr G
// TREE-NEXT: |-VariableDecl thread const T: i32
// TREE-NEXT: | `-IntegerLiteralExpr 8
// TREE-NEXT: |-VariableDecl thread const U: i32
// TREE-NEXT: | `-IntegerLiteralExpr 9
// TREE-NEXT: |-ModuleDecl m
// TREE-NEXT: | |-VariableDecl static const MA
// TREE-NEXT: | | `-IntegerLiteralExpr 1
// TREE-NEXT: | |-VariableDecl static const MB
// TREE-NEXT: | | `-IntegerLiteralExpr 2
// TREE-NEXT: | |-VariableDecl eval MC
// TREE-NEXT: | | `-IntegerLiteralExpr 3
// TREE-NEXT: | `-VariableDecl eval MD
// TREE-NEXT: |   `-IntegerLiteralExpr 4
// TREE-NEXT: |-ClassDecl K
// TREE-NEXT: | |-FieldDecl static const KA: i32
// TREE-NEXT: | | `-IntegerLiteralExpr 1
// TREE-NEXT: | |-FieldDecl static const KB: i32
// TREE-NEXT: | | `-IntegerLiteralExpr 2
// TREE-NEXT: | |-FieldDecl eval KC: i32
// TREE-NEXT: | | `-IntegerLiteralExpr 3
// TREE-NEXT: | `-FieldDecl eval KD: i32
// TREE-NEXT: |   `-IntegerLiteralExpr 4
// TREE-NEXT: `-FunctionDecl  f()
// TREE-NEXT:   `-CompoundStmt (4)
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl static const LA
// TREE-NEXT:     |   `-IntegerLiteralExpr 1
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl static const LB
// TREE-NEXT:     |   `-IntegerLiteralExpr 2
// TREE-NEXT:     |-DeclStmt
// TREE-NEXT:     | `-VariableDecl eval LC
// TREE-NEXT:     |   `-IntegerLiteralExpr 3
// TREE-NEXT:     `-DeclStmt
// TREE-NEXT:       `-VariableDecl eval LD
// TREE-NEXT:         `-IntegerLiteralExpr 4
// TREE: -- 0 error(s), 0 warning(s) --
