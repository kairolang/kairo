// RUN: { %kairo -fduck-generics --type-check-only %s 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
//
// `n->p = &null` in a duck-typed generic, where `n->p` is only known per
// instance, was SC076E "cannot infer" since the fix typed the right side of an
// assignment whose left side is unknown. The pointer type is the instance's.
// CHECK-NOT: SC076E

struct A { pub var p: unsafe *i32 = &null; }

fn <T: type> clear(n: unsafe *T) {
    n->p = &null;
}

fn main() -> i32 {
    var x: i32 = 1;
    var a: A;
    a.p = unsafe &x;
    clear(unsafe &a);
    if a.p != &null { return 1; }
    return 0;
}
