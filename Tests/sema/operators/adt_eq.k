// `==` and `!=` on two values of one ADT enum that declares no `op ==` are
// tag comparisons: X records tag_eq on the node, and binds no operator. A
// user `op ==` from any source -- an extension, a free function -- is found
// first and wins, `!=` included through its `!(==)` rewrite. A nullable
// operand keeps the path it had: builtin equality, no tag comparison. Two
// instances of one generic enum have no `==` at all.

enum <T> Opt { Some { v: T }, None }
enum Pt { P { x: i32 }, Q }
enum Cell { Full { n: i32 }, Blank }
enum Dot { On { k: i32 }, Off }

extend Cell {
    fn op ==(const self, const other: Cell) -> bool { return true }
}

fn op ==(a: Dot, b: Dot) -> bool { return true }

fn tags(a: Opt<i32>, b: Opt<i32>, p: Pt, q: Pt) -> bool {
    var x = a == b
    var y = a != b
    var z = p == q
    var w = p not_eq q
    return x && y && z && w
}

fn users(c: Cell, d: Dot) -> bool {
    var x = c == c
    var y = c != c
    var z = d == d
    var w = d != d
    return x && y && z && w
}

fn nullable(n: Pt?, m: Pt?, p: Pt) -> bool {
    var x = n == null
    var y = n == m
    var z = n == p
    var w = p != n
    return x && y && z && w
}

fn mixed(a: Opt<i32>, c: Opt<i64>) -> bool {
    return a == c
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: adt_eq.k:44:12: error [SC066E]: no operator '==' for operands 'Opt<i32>' and 'Opt<i64>'

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid {{[0-9]+}}: {{.*}}adt_eq.k
// SEMA:       BinaryOperatorExpr @ 20:13 : bool [tag_eq]
// SEMA:       BinaryOperatorExpr @ 21:13 : bool [tag_eq]
// SEMA:       BinaryOperatorExpr @ 22:13 : bool [tag_eq]
// SEMA:       BinaryOperatorExpr @ 23:13 : bool [tag_eq]
// SEMA:       BinaryOperatorExpr @ 28:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 29:13 : bool [rewrite: !(==)]
// SEMA:       BinaryOperatorExpr @ 30:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 31:13 : bool [rewrite: !(==)]
// SEMA:       BinaryOperatorExpr @ 36:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 37:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 38:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 39:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 44:12 : <ERROR>
