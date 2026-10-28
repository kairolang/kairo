// The user's original case (MONO.md G5), with the missing `return` added:
// a generic requirement `fn <T> foo(self, x: T) -> Node` and a bounded body
// `-> T::Node`. Bare `Node` inside the interface and the class is legal and
// draws the readability lint (SC001W, 4be237fd): expected here, and the
// only diagnostics. Both an explicit (`class C impl Iface`) and a
// structural conformer compile and run.

interface Iface {
    type Node
    fn <T> foo(self, x: T) -> Node
}

fn <N> baz(x: N) -> N {
    return x
}

fn <T impl Iface> bar(y: T) -> T::Node {
    var x: T::Node = y.foo(42)
    return baz(x)
}

struct S {
    var x: i32
}

class C impl Iface {
    type Node = S
    fn <T> foo(self, x: T) -> Node {
        return Node{x: 42}
    }
    pub var y: i32
}

class D {
    type Node = i32
    fn <T> foo(self, x: T) -> Node {
        return 7
    }
    pub var y: i32
}

fn main() -> i32 {
    var c: C = C{y: 10}
    var n: S = bar(c)
    var d: D = D{y: 1}
    var m: i32 = bar(d)
    return n.x + m
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: assoc_type_user_case.k:10:31: warning [SC001W]: associated type 'Node' of 'Iface' is named without a qualifier
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 49
