// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s -fduck-generics --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Member access through a generic parameter, the cases that RESOLVE. Which
// regime applies is a property of the parameter's DECLARATION, never of the
// access:
//
//   <T impl I>     bounded structurally. T's members ARE I's members, bound
//                  here, once, at the template. An interface member's `Self`
//                  is the receiver, so `-> Self` reads back as T.
//   <T derives B>  bounded nominally. B's fields and methods, same deal.
//   <T: type>      duck, behind -fduck-generics. Every access deferred to
//                  clang per instance. Never a diagnostic here.
//
// The point of the first two is that the answer is reached WITHOUT an
// instantiation: nothing below is monomorphized, and the file is clean.
//
// The opaque case - a bare <T>, which has no members at all - errors in
// ChainBinding, and an error in the T stage stops sema before ExprTyper. So
// it cannot share a file with an expression-types dump; see bounds_opaque.k.

interface Drawable {
    fn draw(self) -> Self
    fn area(self) -> i32
    fn merge(self, other: Self) -> Self
}

class Base {
    pub var tag: i32
    pub fn label(self) -> i32 { return self.tag }
}

// --- bounded: impl -----------------------------------------------------------

fn <T impl Drawable> render(x: T) -> T { return x.draw() }

fn <T impl Drawable> measure(x: T) -> i32 { return x.area() }

// `other: Self` is `other: T` here, so a second T is exactly what it wants.
fn <T impl Drawable> both(a: T, b: T) -> T { return a.merge(b) }

// --- bounded: derives --------------------------------------------------------

fn <T derives Base> tag_of(x: T) -> i32 { return x.tag }

fn <T derives Base> label_of(x: T) -> i32 { return x.label() }

// --- duck --------------------------------------------------------------------

fn <T: type> anything(x: T) -> i32 { return x.no_such_member() }

// DIAG-NOT: error
// DIAG-NOT: warning

// Every step is bound at the TEMPLATE, against the bound's own declarations.
// SEMA:      member  .draw {{.*}}-> fn draw {{.*}}[member of Drawable]
// SEMA:      member  .area {{.*}}-> fn area {{.*}}[member of Drawable]
// SEMA:      member  .merge {{.*}}-> fn merge {{.*}}[member of Drawable]
// SEMA:      member  .tag {{.*}}-> field tag {{.*}}[member of Base]
// SEMA:      member  .label {{.*}}-> fn label {{.*}}[member of Base]
// SEMA:      member  .no_such_member {{.*}}<dependent

// SEMA: -- expression types --
// SEMA:      <tu>::render
// SEMA:      CallExpr {{.*}} : T
// SEMA:      <tu>::measure
// SEMA:      CallExpr {{.*}} : i32
// SEMA:      <tu>::both
// SEMA:      CallExpr {{.*}} : T
// SEMA:      <tu>::tag_of
// SEMA:      ChainExpr {{.*}} : i32
// SEMA:      <tu>::label_of
// SEMA:      CallExpr {{.*}} : i32
// SEMA:      <tu>::anything
// SEMA:      ChainExpr {{.*}} : <unknown>
