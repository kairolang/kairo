// A statement-scope alias resolves in its own lexical scope: the enclosing
// function's generic parameters, and an enclosing record's, are visible in
// it. Type-check only: EmitIR does not emit statement-scope decls yet.

fn <T> twice(x: T) -> T {
    type Local = T
    var y: Local = x
    return y + x
}

fn <T> addr_of(x: *T) -> *T {
    type P = *T                        // a compound type over the function's T.
    var p: P = x
    return p
}

fn local_struct() -> i32 {
    struct S { var a: i32 }
    type A = S                         // a local alias naming a local type.
    var s: A = A { a: 4 }
    return s.a
}

class <T> Holder {
    var v: T
    pub fn Holder(self, v: T) { self.v = v }
    pub fn <U> pair(self, u: U) -> U {
        type Own = T                   // the record's T, past the method.
        type Arg = U                   // the method's own U.
        var a: Own = self.v
        var b: Arg = u
        return b
    }
}

fn main() -> i32 {
    var h = Holder<i32>(1)
    var x: i32 = 3
    return twice(x) + *addr_of(&x) + local_struct() + h.pair(2)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: R021E
// DIAG-NOT: error
