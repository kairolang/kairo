class A {
    fn m(self) -> i32 { return 1 }
    fn c(const self) -> i32 { return 2 }
    fn cm(const self) -> i32 { return self.m() }
    fn mc(self) -> i32 { return self.c() }
}
fn use_a() {
    var b = A()
    var x = b.c()
    var y = b.m()
    const k = A()
    var z = k.c()
    var w = k.m()
}

// The receiver is the implicit object parameter ([over.match.funcs]/4): a
// `const self` method's receiver is `const A`, and the object binds to it as
// to a reference. A non-const object calls either kind; a const object -- a
// `const` binding, or `self` inside a `const self` method -- calls only the
// const ones. Code first, on purpose: the checks below pin its line:col.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG:      receiver_const.k:4:39: error [SC001E]: no matching overload for call to 'm'
// DIAG-NEXT: receiver_const.k:2:5: note [I900N]: candidate not viable: 'm' is not const; it cannot be called on a const object
// DIAG-NEXT: receiver_const.k:13:13: error [SC001E]: no matching overload for call to 'm'
// DIAG-NEXT: receiver_const.k:2:5: note [I900N]: candidate not viable: 'm' is not const; it cannot be called on a const object
// DIAG-NOT:  error
//
// The prelude dumps the builtin TUs ahead of this one, each with an
// `-- inferred decls --` of its own: anchor on this file's header first.
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}receiver_const.k =====
// SEMA:      -- inferred decls --
// SEMA-NEXT: b : A
// SEMA-NEXT: x : i32
// SEMA-NEXT: y : i32
