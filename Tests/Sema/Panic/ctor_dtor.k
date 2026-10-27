// No constructor and no destructor can panic (USER 2026-10-27; PANIC.md
// §7's notes): an object is built whole or not at all, and a destructor
// runs on every exit, where nothing could take an error. `panic` on one is
// an error with an edit removing it (declarations.k); a panic ESCAPING one's
// body is an error that says to handle it there or crash, and for a
// constructor that fallible construction belongs in a static factory. A
// `try` that handles it is fine, and so is the factory.

struct E { var code: i32 }

fn risky(n: i32) panic(E) -> i32 {
    if n < 0 { panic E { code: n } }
    return n
}

class Conn {
    var fd: i32
    fn Conn(self, n: i32) { self.fd = risky(n) }
    fn Conn(self) { self.fd = try risky(1) catch => -1 }
    fn op delete(self) { risky(self.fd) }
    @move fn Conn(self, other: Self) = default
    static fn open(n: i32) panic -> Conn { return Conn(risky(n)) }
}

class Handled {
    var fd: i32
    fn Handled(self, n: i32) { try { self.fd = risky(n) } catch e: E { self.fd = 0 } }
    fn op delete(self) { try { risky(self.fd) } catch { crash!() } }
    @move fn Handled(self, other: Self) = default
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: ctor_dtor.k:18:39: error [SC001E]: a constructor cannot panic: 'risky' may panic with 'E', which is not handled
// CHECK-NEXT: ctor_dtor.k:11:1: note [SC001N]: 'risky' is declared 'panic' here
// CHECK-NEXT: ctor_dtor.k:18:39: note [SC001N]: construction that can fail belongs in a static factory function that may panic and returns the object
// CHECK-NEXT: ctor_dtor.k:18:39: note [SC001N]: or handle it here, or stop the program with 'crash!()'
// CHECK-NEXT: fix-it:"{{.*}}ctor_dtor.k":{18:39-18:39}:"try "
// CHECK-NEXT: fix-it:"{{.*}}ctor_dtor.k":{18:47-18:47}:" catch => crash!()"
// CHECK: ctor_dtor.k:20:26: error [SC001E]: a destructor cannot panic: 'risky' may panic with 'E', which is not handled
// CHECK-NEXT: ctor_dtor.k:11:1: note [SC001N]: 'risky' is declared 'panic' here
// CHECK-NEXT: ctor_dtor.k:20:26: note [SC001N]: or handle it here, or stop the program with 'crash!()'
// CHECK-NEXT: fix-it:"{{.*}}ctor_dtor.k":{20:26-20:26}:"try "
// CHECK-NEXT: fix-it:"{{.*}}ctor_dtor.k":{20:40-20:40}:" catch => crash!()"
