// G4 (Compiler/Sema/NULLABLE.md 1.6): `var x? = e` is the nullable
// shorthand. The `?` belongs to the declaration, not to the initializer:
// before G4 it was left for the statement parser and read as the start of
// an expression (S052E "expected expression, found '?'"). It is accepted on
// `var`, `const` and `static` bindings, local or at file scope, and the
// tree keeps it on the name (`var a?`) with no type: Sema infers one.
//
// Two spellings are refused here, where the `?` is still known to be the
// shorthand (S058E, invalid binding syntax):
//  - `var x?: T`: the shorthand infers a type and the annotation states one.
//    Fix-it: drop the `?` and put it on the type (not when T is already
//    nullable). Recovered as `var x: T?`, so no conversion error follows.
//  - a field `var f? = e`: a field's type is declared, never inferred.

var g? = 4
static s? = 5

fn f() {
    var a? = 10
    const b? = g
    var c? = (1 + 2)
}

fn h() {
    var z?: i32 = null
    var w?: i32? = null
}

struct Q {
    var k? = 5
    var m?: i32 = 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
// AST-LABEL: AST (tree) for fid 0
// AST: VariableDecl var g?
// AST-NEXT: `-IntegerLiteralExpr 4
// AST: VariableDecl static s?
// AST: VariableDecl var a?
// AST-NEXT: `-IntegerLiteralExpr 10
// AST: VariableDecl const b?
// AST-NEXT: `-NamedIdentExpr g
// AST: VariableDecl var c?
// AST-NEXT: `-BinaryOperatorExpr +
// The refused form recovers as the annotation made nullable, no `?` on the name.
// AST: VariableDecl var z: i32?
// AST: VariableDecl var w: i32?

// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: nullable_shorthand.k:25:10: error [S058E]: 'z?' infers a nullable type, but the declaration also annotates one; write the '?' on the type
// DIAG-NEXT: fix-it:{{.*}}:{25:10-25:11}:""
// DIAG-NEXT: fix-it:{{.*}}:{25:16-25:16}:"?"
// DIAG-NOT: error
// DIAG: nullable_shorthand.k:26:10: error [S058E]: 'w?' infers a nullable type
// DIAG-NEXT: fix-it:{{.*}}:{26:10-26:11}:""
// DIAG-NOT: fix-it
// DIAG-NOT: error
// DIAG: nullable_shorthand.k:30:10: error [S058E]: a field declares its type and cannot use the '?' shorthand; write 'k: T?'
// DIAG-NEXT: fix-it:{{.*}}:{30:10-30:11}:""
// DIAG-NOT: error
// DIAG: nullable_shorthand.k:31:10: error [S058E]: a field declares its type and cannot use the '?' shorthand; write 'm: T?'
// DIAG-NEXT: fix-it:{{.*}}:{31:10-31:11}:""
// DIAG-NEXT: fix-it:{{.*}}:{31:16-31:16}:"?"
// DIAG-NOT: error
