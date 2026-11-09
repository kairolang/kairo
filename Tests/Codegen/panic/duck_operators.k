// An operator on a `<T: type>` operand is bound by no one until C++
// instantiates the body, like a member call through T, so Sema
// cannot see that the instance's user operator panics. Before only
// member calls were wrapped: `a + b` on a type whose `op +` panics
// compiled and dropped the error. Binary, unary and compound operators on a
// duck operand now go out as `(::__kairo_nopanic(), a + b)` (a compound one
// on T inside the dependent form's lambda), and the instance with a
// panicking operator is an error naming the site (Inputs/duck_op_boom.k).
// Non-panicking operators -- a user one, an integer's, nested so that the
// inner result is an operand the dependent form binds by reference --
// compile and run as before.
struct Calm {
    var v: i32
    fn op + (const self, o: Calm) -> Calm { return Calm { v: self.v + o.v } }
    fn op - (const self) -> Calm { return Calm { v: 0 - self.v } }
    fn op == (const self, o: Calm) -> bool { return self.v == o.v }
    fn op *= (self, o: Calm) { self.v = self.v * o.v }
}

fn <T: type> sum3(a: T, b: T, c: T) -> T { return a + b + c }
fn <T: type> neg(a: T) -> T { return -a }
fn <T: type> same(a: T, b: T) -> bool { return a == b }
fn <T: type> acc(a: T, b: T) -> T {
    var u = a
    u *= b
    return u
}

fn main() -> i32 {
    if sum3(Calm { v: 1 }, Calm { v: 2 }, Calm { v: 3 }).v != 6 { return 1 }
    if sum3(1, 2, 3) != 6 { return 2 }
    if neg(Calm { v: 4 }).v != -4 { return 3 }
    if neg(5) != -5 { return 4 }
    if !same(Calm { v: 7 }, Calm { v: 7 }) { return 5 }
    if same(1, 2) { return 6 }
    if acc(Calm { v: 3 }, Calm { v: 8 }).v != 24 { return 7 }
    if acc(10, 20) != 200 { return 8 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %S/Inputs/duck_op_boom.k -fduck-generics -o %t.boom --cache-dir %t.e 2>&1 || true; } | %FileCheck %s --check-prefix=BOOM
// BOOM: duck_op_boom.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: static assertion failed{{.*}}Panic<{{.*}}Boom, {{.*}}Bad>{{.*}}a call through a '<T: type>' parameter that may panic is not yet supported
// BOOM: duck_op_boom.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: in instantiation of function template specialization {{.*}}add_drop{{.*}}Boom{{.*}} requested here
// BOOM: duck_op_boom.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: static assertion failed{{.*}}Panic<int, {{.*}}Bad>{{.*}}a call through a '<T: type>' parameter that may panic is not yet supported
// BOOM: duck_op_boom.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: in instantiation of function template specialization {{.*}}neg_drop{{.*}}Boom{{.*}} requested here
// BOOM: duck_op_boom.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: static assertion failed{{.*}}Panic<void, {{.*}}Bad>{{.*}}a call through a '<T: type>' parameter that may panic is not yet supported
// BOOM: duck_op_boom.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: in instantiation of function template specialization {{.*}}acc_drop{{.*}}Boom{{.*}} requested here
