// A member call through a `<T: type>` parameter is bound by no one until
// C++ instantiates the body (MONO.md D1), so Sema cannot see that the
// callee panics. Before (P184), `drop_it(Boom())` compiled and ran: the
// discarded `Panic<int, int>` raised only clang's nodiscard warning, and
// the panic was dropped. Every such call now goes out as
// `(::__kairo_nopanic(), t.value())`, whose `operator,` static_asserts that
// the value is no panic result: the instance with Boom is an error naming
// the call (Inputs/duck_boom.k), while a non-panicking callee -- a value,
// a `void` one, one whose result is discarded -- compiles and runs as
// before.
class Calm {
    var n: i32
    fn Calm(self, n: i32) { self.n = n }
    fn value(const self) -> i32 { return self.n }
    fn touch(self) { self.n += 1 }
}

fn <T: type> drop_it(t: T) { t.value() }
fn <T: type> keep_it(t: T) -> i32 { return t.value() + 1 }
fn <T: type> bump(t: T) -> i32 {
    var u = t
    u.touch()
    return u.value()
}

fn main() -> i32 {
    drop_it(Calm(1))
    if keep_it(Calm(4)) != 5 { return 1 }
    if bump(Calm(6)) != 7 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %S/Inputs/duck_boom.k -fduck-generics -o %t.boom --cache-dir %t.e 2>&1 || true; } | %FileCheck %s --check-prefix=BOOM
// BOOM: duck_boom.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: static assertion failed{{.*}}a call through a '<T: type>' parameter that may panic is not yet supported
// BOOM: duck_boom.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: in instantiation of function template specialization {{.*}}drop_it{{.*}}Boom{{.*}} requested here
