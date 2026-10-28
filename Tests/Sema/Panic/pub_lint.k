// An inferred panic set on a `pub` function is API surface that changes
// silently when the body changes (PANIC.md §2.2). Building a library
// (--shared), that is a warning, whose edit writes the set it was
// inferred to be -- or removes `panic` when nothing in the body panics.
// Off for an executable (the second run), and never for a declared set
// or a function that is not `pub`.

struct E { var code: i32 }

pub fn api(x: i32) panic -> i32 {
    if x < 0 { panic E { code: x } }
    return x
}

pub fn nothing() panic -> i32 { return 0 }

pub fn declared(x: i32) panic(E) -> i32 { return api(x) }

fn internal(x: i32) panic -> i32 { return api(x) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --shared 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: pub_lint.k:10:20: warning [SC001W]: the panic set of public function 'api' is inferred ('E'); declare it, or a change to the body changes its callers' contract
// CHECK-NEXT: fix-it:"{{.*}}pub_lint.k":{10:20-10:25}:"panic(E)"
// CHECK: pub_lint.k:15:18: warning [SC001W]: the panic set of public function 'nothing' is inferred (nothing); declare it, or a change to the body changes its callers' contract
// CHECK-NEXT: fix-it:"{{.*}}pub_lint.k":{15:18-15:23}:""
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=EXE --allow-empty
// EXE-NOT: warning [
// EXE-NOT: error [
