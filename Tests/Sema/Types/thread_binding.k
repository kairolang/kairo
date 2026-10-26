// A `thread` binding types like a `static` one (variables.mdx): the type is
// written, inferred from the initializer, or both; `thread const` makes the
// binding const; a class-scope one is reached as `Self::name` / `Type::name`
// like a static member; and for nullness it is global storage (NULLABLE.md
// 3.8) -- a narrowing does not survive a call, because code on the same
// thread may write it. A plain local of the same type would stay narrowed.
// Errors are a `static`'s: neither type nor initializer is SC046E, and an
// initializer must convert.

thread ti = 7
thread tf = 1.5
thread ts: i64 = 3
thread const TC = 2
thread maybe: i32? = 5

class Pool {
    pub thread hits: i32 = 0
    fn bump(self) -> i32 { Self::hits += 1; return Self::hits }
}

fn touch() {}

fn uses() -> i32 {
    thread local = 4
    var a = ti
    var b = tf
    var c = TC
    var d = Pool::hits
    if maybe? { var n1 = maybe + 0; touch(); var n2 = maybe }
    return a + c + d + local
}

fn bad() {
    thread none
    thread wrong: i32 = "no"
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: thread_binding.k:34:5: error [SC046E]: 'none' has neither a type nor an initializer
// DIAG-NEXT: thread_binding.k:35:25: error [SC028E]: cannot convert 'string' to 'i32'
// DIAG-NOT: error

// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid 0: {{.*}}thread_binding.k
// SEMA: -- name bindings --
// SEMA: <tu>::Pool::bump
// SEMA: ::hits @ 18:34 -> field hits @ 17:9
// SEMA: <tu>::uses
// SEMA: ::hits @ 28:19 -> field hits @ 17:9
// SEMA: -- expression types --
// SEMA: <tu>::uses
// SEMA: NamedIdentExpr @ 27:13 : const i32
// SEMA: -- inferred decls --
// SEMA-DAG: ti : i32
// SEMA-DAG: tf : f64
// SEMA-DAG: TC : i32
// SEMA-DAG: local : i32
// SEMA-DAG: a : i32
// SEMA-DAG: b : f64
// SEMA-DAG: d : i32
// SEMA-DAG: n1 : i32
// SEMA-DAG: n2 : i32?
