// An expression attribute parses (Parser/Expr/attributed_expr.k) but has
// no meaning yet, so Sema reports each one as SC116E "not yet supported",
// naming the attribute, instead of reaching codegen (where it would ICE).
// The operand is not typed as a plain expression: under `@create`,
// `i32(10)` constructs an i32, where a plain `i32(10)` is SC037E, so that
// error must not appear. Names in the operand still resolve.

class Config {
    pub var port: i32 = 0
    fn Config(self, p: i32) { self.port = p }
}

fn f() -> i32 {
    var *cfg = @create Config(8080)
    var *n = @create i32(10)
    var q = @align(16) Config(1)
    return @keep 3
}

fn g() -> i32 {
    var *bad = @create Config(not_declared)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: attributed_expr_gate.k:21:31: error [R020E]: use of undeclared identifier 'not_declared'

// RUN: sed '/not_declared/d' %s > %t.k
// RUN: { %kairo %t.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=GATE --implicit-check-not="error ["
// GATE: :14:16: error [SC116E]: the expression attribute '@create' is not yet supported
// GATE: :15:14: error [SC116E]: the expression attribute '@create' is not yet supported
// GATE: :16:13: error [SC116E]: the expression attribute '@align' is not yet supported
// GATE: :17:12: error [SC116E]: the expression attribute '@keep' is not yet supported

// The full compile stops at the same errors: nothing reaches EmitIR.
// RUN: { %kairo %t.k -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=GATE --implicit-check-not="error ["
