// G20 (Compiler/Sema/NULLABLE.md 1.7): `var *y = e` is the pointer
// declaration shorthand. Any number of stars, an optional `unsafe` before
// the first, and the nullable `?` after the name combine (`var *y? = e`).
// Before G20 the star was read where the name belongs: S046E "expected a
// name after the binding keyword". Accepted on `var`, `const` and
// `static`, local or at file scope; the tree keeps the stars on the name
// with no type (Sema infers one and checks the stars against it).
//
// Two spellings are refused here (S058E, invalid binding syntax), the same
// two G4 refuses for `?`:
//  - `var *y: T`: the stars restate the annotation; the fix-it drops them
//    and the annotation is kept;
//  - a field `var *f: T`: a field's type is declared, never inferred.
// `unsafe` alone before a name is no shorthand and still S046E.

var gx = 1
var *gp = &gx
static **gpp = &gp

fn f() {
    var x = 5
    var *a = &x
    const **b = &a
    var unsafe *c = g()
    var ***d = &b
    var *e? = &x
    var unsafe **h? = k()
}

fn bad() {
    var x = 5
    var *z: *i32 = &x
    var unsafe **w?: i32 = 2
}

struct Q {
    var *k: *i32
    var unsafe *m: unsafe *i32
}

fn worse() {
    var unsafe n = 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST-LABEL: AST (tree) for fid 0
// AST: VariableDecl var *gp
// AST-NEXT: `-UnaryOperatorExpr prefix &
// AST: VariableDecl static **gpp
// AST: VariableDecl var *a
// AST: VariableDecl const **b
// AST: VariableDecl var unsafe *c
// AST-NEXT: `-CallExpr
// AST: VariableDecl var ***d
// AST: VariableDecl var *e?
// AST: VariableDecl var unsafe **h?
// The refused form keeps the annotation and loses the stars (and `?`).
// AST: VariableDecl var z: *i32
// AST: VariableDecl var w: i32?

// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: pointer_shorthand.k:32:9: error [S058E]: '*z' states that the binding is a pointer, but the declaration also annotates its type; drop the '*'
// DIAG-NEXT: fix-it:{{.*}}:{32:9-32:10}:""
// DIAG-NOT: error
// DIAG: pointer_shorthand.k:33:9: error [S058E]: 'unsafe **w' states that the binding is a pointer, but the declaration also annotates its type; drop the 'unsafe **'
// DIAG-NEXT: fix-it:{{.*}}:{33:9-33:18}:""
// DIAG-NEXT: pointer_shorthand.k:33:19: error [S058E]: 'w?' infers a nullable type
// DIAG-NOT: error
// DIAG: pointer_shorthand.k:37:9: error [S058E]: a field declares its type and cannot use the '*' shorthand; write 'k: *T'
// DIAG-NEXT: fix-it:{{.*}}:{37:9-37:10}:""
// DIAG-NOT: error
// DIAG: pointer_shorthand.k:38:9: error [S058E]: a field declares its type and cannot use the 'unsafe *' shorthand; write 'm: unsafe *T'
// DIAG-NEXT: fix-it:{{.*}}:{38:9-38:17}:""
// DIAG-NOT: error
// DIAG: pointer_shorthand.k:42:5: error [S046E]: expected a name after the binding keyword
// DIAG-NOT: error
