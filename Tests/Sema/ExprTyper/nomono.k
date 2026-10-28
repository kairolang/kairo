// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// The definition side of a generic. NOTHING here is monomorphized: this pass
// types the TEMPLATE once, against its bounds (MONO.md D0), and an instance
// never re-checks it.
//
// Two different answers appear in the dump and they are not the same thing:
//
//   `T`         the expression HAS a type, and that type is dependent.
//               `x`, `id(x)`, `h->get()` are all of type T here, which is
//               everything a definition-time reader can be told.
//   `<unknown>` the answer needs the instantiation. `*h + *h` is the case:
//               an operator on a dependent COMPOSITE (`Holder<T>`) is still
//               deferred. An operator on a bare `T` is not: `x + x` on an
//               unbounded T is an error, since only a bound could grant it
//               (Sema/Check/opaque_param_ops.k), so it is not written here.
//
// The invariant this file protects: a well-formed generic body produces no
// diagnostics, and its types are the dependent ones below.

class <T> Holder {
    var v: T
    fn Holder(self) { }
    fn get(self) -> T { return self.v }
}

fn <T> id(x: T) -> T { return x }

fn <T> body(x: T, h: *Holder<T>) {
    var a = x;
    var b = id(x);
    var c = h->get();
    var d = *h + *h;   // deferred: the composite's operators are the instance's
    var e = h->v;
    var f = &x;        // `*T` whatever T is: no instantiation needed
}

// DIAG-NOT: error
// DIAG-NOT: warning

// SEMA: -- expression types --
// SEMA:      BinaryOperatorExpr {{.*}} : <unknown>

// SEMA: -- inferred decls --
// SEMA:      a : T
// SEMA-NEXT: b : T
// SEMA-NEXT: c : T
// SEMA-NEXT: e : T
// SEMA-NEXT: f : *T
