// A named function declared in a body -- a local `fn`, or a method of a
// local class -- captures nothing (closures.mdx, Closures vs Inner
// Functions): a local, a parameter, `self` or a `static` local of the
// function around it is an error at the use, with a note at the binding.
// Each use is reported once, by the innermost function that makes it. A
// closure in the same place captures as always, and a local fn may use
// globals, its own parameters and locals, and other local declarations.

var global_count: i32 = 7

fn outer(p: i32) -> i32 {
    var x = 10
    static hits: i32 = 0
    fn uses_local(y: i32) -> i32 { return y + x }          // a local
    fn uses_param() -> i32 { return p }                     // a parameter
    fn uses_static() -> i32 { return hits }                 // a static local
    fn middle() -> i32 {
        var m = 1
        fn innermost() -> i32 { return x + m }              // both, once each
        return innermost()
    }
    class Local {
        fn get(self) -> i32 { return x }                    // a local class's method
    }
    return 0
}

class Owner {
    pub var v: i32 = 1
    fn method(self) -> i32 {
        fn reads_self() -> i32 { return self.v }            // `self` is the method's
        return 0
    }
}

fn fine(p: i32) -> i32 {
    var x = 10
    fn own(a: i32) -> i32 {
        var b = a + 1                                       // its own local
        return b + global_count                             // a global
    }
    class Box { pub var v: i32 = 3  fn get(self) -> i32 { return self.v } }
    fn uses_box(b: Box) -> i32 { return b.get() }           // another local decl
    var c = fn () -> i32 { return x + p }                   // a closure captures
    return own(x) + uses_box(Box()) + c()
}

fn main() -> i32 { return outer(1) + fine(2) }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:14:47: error [SC001E]: 'uses_local' is a named function declared in a body, and cannot use 'x' from the function around it
// DIAG-NEXT: {{.*}}:12:5: note [I900N]: 'x' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure
// DIAG: {{.*}}:15:37: error [SC001E]: 'uses_param' is a named function declared in a body, and cannot use 'p' from the function around it
// DIAG-NEXT: {{.*}}:11:10: note [I900N]: 'p' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure
// DIAG: {{.*}}:16:38: error [SC001E]: 'uses_static' is a named function declared in a body, and cannot use 'hits' from the function around it
// DIAG-NEXT: {{.*}}:13:5: note [I900N]: 'hits' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure
// DIAG: {{.*}}:19:40: error [SC001E]: 'innermost' is a named function declared in a body, and cannot use 'x' from the function around it
// DIAG-NEXT: {{.*}}:12:5: note [I900N]: 'x' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure
// DIAG: {{.*}}:19:44: error [SC001E]: 'innermost' is a named function declared in a body, and cannot use 'm' from the function around it
// DIAG-NEXT: {{.*}}:18:9: note [I900N]: 'm' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure
// DIAG: {{.*}}:23:38: error [SC001E]: 'get' is a named function declared in a body, and cannot use 'x' from the function around it
// DIAG-NEXT: {{.*}}:12:5: note [I900N]: 'x' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure
// DIAG: {{.*}}:31:41: error [SC001E]: 'reads_self' is a named function declared in a body, and cannot use 'self' from the function around it
// DIAG-NEXT: {{.*}}:30:15: note [I900N]: 'self' is declared here; a named function captures nothing -- pass it as a parameter, or use a closure
// END-GENERATED-CHECKS(DIAG)
