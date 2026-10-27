// What an `eval for` may iterate, and the rest of EVAL.md §5's rules
// (EvalUsageChecking): a run-time bound or array is not eval-able (a note
// at the variable); a generator must be `eval` (fix-it adding it); one
// binding; no C-style form; an eval generator is called only as an `eval
// for` iterable; a body `eval if` on a run-time value does not fold and is
// an error, not a clang one; a label and a record-returning `return` in a
// copy are SC116E.
fn plain_gen(n: i32) -> yield i32 { yield n }
eval fn egen() -> yield i32 { var v = 1  yield v }
class Big { pub var a: i32 }
fn ret_big() -> Big {
    eval for i in 0..2 { if i == 1 { return Big() } }
    return Big()
}
fn main() -> i32 {
    var n = 3
    var arr: [i32; 2] = [1, 2]
    eval for i in 0..n { }
    eval for x in arr { }
    eval for x in plain_gen(2) { }
    eval for (a, b) in 0..2 { }
    eval for var k: i32 = 0; k < 2; ++k { }
    var bad = egen()
    eval if n > 2 { }
    outer: eval for i in 0..2 { }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: eval_for_errors.k:12:38: error [SC116E]: returning a 'Big' from inside an 'eval for' is not yet supported; return it after the loop
// CHECK: eval_for_errors.k:18:22: error [SC001E]: the upper bound of an 'eval for' range must be evaluable at compile time; this is a run-time value
// CHECK-NEXT: eval_for_errors.k:16:9: note [SC001N]: 'n' is declared here, not as 'eval'
// CHECK: eval_for_errors.k:19:19: error [SC001E]: an 'eval for' iterates a range with eval bounds, an eval array or an eval generator; this is '[i32; 2]'
// CHECK-NEXT: eval_for_errors.k:17:9: note [SC001N]: 'arr' is declared here, not as 'eval'
// CHECK: eval_for_errors.k:20:19: error [SC001E]: an 'eval for' iterates an eval generator; 'plain_gen' is not 'eval'
// CHECK-NEXT: fix-it:{{.*}}:{8:1-8:1}:"eval "
// CHECK-NEXT: eval_for_errors.k:8:1: note [SC001N]: 'plain_gen' is declared here
// CHECK: eval_for_errors.k:21:10: error [SC001E]: an 'eval for' binds one name; destructure inside the body
// CHECK: eval_for_errors.k:21:24: error [SC096E]: cannot destructure 'i32' into 2 bindings
// CHECK: eval_for_errors.k:22:10: error [SC001E]: an 'eval for' iterates a range, an eval array or an eval generator; the C-style form is not one: write 'eval for i in lo..hi'
// CHECK: eval_for_errors.k:23:15: error [SC001E]: 'egen' is an eval generator; it runs at compile time and can only be iterated by an 'eval for'
// CHECK-NEXT: eval_for_errors.k:9:1: note [SC001N]: 'egen' is declared here
// CHECK: eval_for_errors.k:24:13: error [SC001E]: the condition of an 'eval if' must be evaluable at compile time; this is a run-time value
// CHECK: eval_for_errors.k:25:5: error [SC116E]: a labeled 'eval for' is not yet supported
