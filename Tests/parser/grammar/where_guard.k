// A `where` guard sits after the return type and before the body
// (where.mdx, Basic Syntax), on the same line or on its own line under the
// head. It never reads the body's `{` as a struct literal, and it stops
// before the `=` of an expression body. Free functions and methods alike.

fn sqrt(x: f64) -> f64
  where x >= 0.0 {
    return x
}
fn sqrt(x: f64) -> f64 { return 0.0 }

fn pos(x: i32) -> i32 where x > 0 = x
fn pos(x: i32) -> i32 = 0

fn flag(ok: bool) -> i32 where ok { return 1 }
fn flag(ok: bool) -> i32 { return 0 }

class Acc {
    var n: i32
    fn get(self, k: i32) -> i32 where k > 0 && self.n > k { return k }
    fn get(self, k: i32) -> i32 { return 0 }
}

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=TREE
//
// TREE:      |-FunctionDecl  sqrt(x: f64) -> f64 where
// TREE-NEXT: | |-ParamDecl x: f64
// TREE-NEXT: | |-BinaryOperatorExpr >=
// TREE-NEXT: | | |-NamedIdentExpr x
// TREE-NEXT: | | `-FloatingLiteralExpr 0
// TREE-NEXT: | `-CompoundStmt (1)
// TREE:      |-FunctionDecl  sqrt(x: f64) -> f64{{$}}
// TREE:      |-FunctionDecl  pos(x: i32) -> i32 where
// TREE-NEXT: | |-ParamDecl x: i32
// TREE-NEXT: | |-BinaryOperatorExpr >
// TREE-NEXT: | | |-NamedIdentExpr x
// TREE-NEXT: | | `-IntegerLiteralExpr 0
// TREE-NEXT: | `-NamedIdentExpr x
// TREE:      |-FunctionDecl  flag(ok: bool) -> i32 where
// TREE-NEXT: | |-ParamDecl ok: bool
// TREE-NEXT: | |-NamedIdentExpr ok
// TREE-NEXT: | `-CompoundStmt (1)
// TREE:      `-ClassDecl Acc
// TREE:        |-FunctionDecl  get(self, k: i32) -> i32 where
// TREE-NEXT:   | |-ParamDecl self
// TREE-NEXT:   | |-ParamDecl k: i32
// TREE-NEXT:   | |-BinaryOperatorExpr &&
// TREE:        | `-CompoundStmt (1)
// TREE:        `-FunctionDecl  get(self, k: i32) -> i32{{$}}
