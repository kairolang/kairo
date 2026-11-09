// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck --allow-empty %s
//
// `typeof T` over a type operand (a generic parameter, a class) has no
// value type but denotes one; the node used to reach finish() in no terminal
// state, an internal error, on `eval if typeof T == X`.
//
// CHECK-NOT: Internal Compiler Error
// CHECK-NOT: typer bug
class A { var x: u32 = 0; }
class B { var y: u32 = 0; }
class Tab {
    fn <T> create(self) -> u32 {
        eval if typeof T == A {
            return 1;
        } else if typeof T == B {
            return 2;
        }
        return 0;
    }
    fn go(self) -> u32 { return self.create<B>() + self.create<A>(); }
}
