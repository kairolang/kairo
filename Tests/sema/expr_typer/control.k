// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Expressions that JOIN arms, and the types inferred from a body
// (ExprTyper / ControlTyping / StmtTyping).
//
// An `if`/`match` used as an expression has the type its arms agree on. A
// diverging arm agrees with anything: `!` (BuiltinKind::Never) converts to
// every type and nothing converts to it, which is exactly what makes
// `if c { 1 } else { diverge() }` an i32 rather than an error.
//
// Return-type inference is on demand and cycle-guarded: an expression-bodied
// function whose body needs its own return type cannot be inferred, and says
// so instead of recursing.

fn diverge() -> ! { panic 1 }

fn joins(c: bool, i: i32) {
    var same     = if c => 1 else => 2;
    var one_side = if c => 1 else => diverge();    // the live arm decides
    var to_float = if c => 1 else => 1.5;          // the literal takes f64
    var matched  = match i {
        case 1 => 10
        default => 20
    };
}

fn closures() {
    var annotated = fn (x: i32) -> i32 { return x + 1; };
    var inferred  = fn (x: i32) { return x + 1; };   // from the return stmt
}

fn expr_bodied(x: i32) = x + 1

fn recursive(x: i32) = recursive(x)

// DIAG: error{{.*}}cannot infer the return type of 'recursive': its body refers to itself; annotate the return type
// DIAG-NOT: error{{.*}}'joins'
// DIAG-NOT: error{{.*}}do not unify

// SEMA: -- inferred decls --
// SEMA:      same : i32
// SEMA-NEXT: one_side : i32
// SEMA-NEXT: to_float : f64
// SEMA-NEXT: matched : i32
// SEMA-NEXT: annotated : fn (i32) -> i32
// SEMA-NEXT: inferred : fn (i32) -> i32
// SEMA-NEXT: expr_bodied() -> i32
