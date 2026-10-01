// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Chain steps ExprTyper finishes (ExprTyper / MemberTyping).
//
// ChainBinding binds every step whose left side had a DECLARED type. What it
// cannot bind is a step standing on an EXPRESSION -- `f().x`, `v.push(1)`
// after `var v = g()` -- because the anchor only exists once the left side is
// typed. Those land here, and they go back through ChainBinding's OWN binder
// (prepare / anchor_for_value / bind_step) rather than a second copy of the
// member rules.

class Inner { pub var x: i32 = 0; }

class Outer {
    pub var inner: Inner = Inner();
    fn make(self) -> Inner { return self.inner }
}

enum Color { Red, Green }

class <T> Box {
    var v: T
    static fn make() -> Box<T> { return Box<T>() }
    fn Box(self) { }
}

fn mk() -> Outer { return Outer() }

fn chains(o: *Outer, t: (i32, f64)) {
    var a = mk().inner;     // field of a call result
    var b = o->make().x;    // method on a pointer, then a field of the result
    var d = t.0;            // tuple index: position, not a name
    var e = Color::Red;
    var g = Box<i32>::make();
}

// NOTE: the SEMA block below pins one row by `line:col`. Inserting code above
// it shifts that row; re-read the dump rather than deleting the assertion.
//
// DIAG-NOT: error

// SEMA: -- expression types --
// A generic static through an explicit instance head: the callee is still
// declared `-> Box<T>`, but a `::` call off a type has that type as its
// receiver (MemberTyping), so `Box<i32>` binds T and the CALL is `Box<i32>`.
// SEMA:      CallExpr {{.*}}@ 35:13{{.*}} : Box<i32>
// SEMA-NEXT: ChainExpr {{.*}}@ 35:13{{.*}} : fn () -> Box<T>

// SEMA: -- inferred decls --
// SEMA:      a : Inner
// SEMA-NEXT: b : i32
// SEMA-NEXT: d : i32
// SEMA-NEXT: e : Color
