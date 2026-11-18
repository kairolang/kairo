// RUN: { %kairo %s --type-check-only --diag-show-ids 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// The opaque regime: a generic parameter with no bound has NO members, and
// saying so is the deliberate parting from C++. A c++ template body is
// re-checked against every argument, so `x.tag` there is an error at each
// instantiation that lacks `tag` and no error at all if the template is never
// instantiated. Kairo checks the body against the parameter's DECLARATION
// instead - whatever it promised is exactly what the body may use - so the
// mistake is reported once, at the template, on the line that made it.
//
// A bounded parameter still gets the ordinary no-such-member error when the
// name is in none of its bounds: the bound is the scope, and the scope was
// searched.
//
// These live apart from bounds.k because they are ChainBinding errors, and an
// error in the T stage stops sema before ExprTyper - a file that raises one
// has no expression-types dump to check.

interface Drawable {
    fn draw(self) -> Self
}

fn <T> opaque(x: T) -> i32 {
    return x.tag
}
// DIAG: bounds_opaque.k:[[@LINE-2]]:14: error [R051E]: 'T' has no members, so 'tag' cannot be resolved
// DIAG-NEXT: bounds_opaque.k:[[@LINE-4]]:5: note [R051N]: 'T' is declared with no bound

// One diagnostic per access, and the note points at the declaration, which is
// where the fix goes.
fn <T> opaque_call(x: T) -> i32 {
    return x.whatever()
}
// DIAG: bounds_opaque.k:[[@LINE-2]]:14: error [R051E]: 'T' has no members, so 'whatever' cannot be resolved

// Bounded, but by something that does not declare the name.
fn <T impl Drawable> missing(x: T) -> i32 {
    return x.tag
}
// DIAG: bounds_opaque.k:[[@LINE-2]]:14: error [R025E]: no member named 'tag' in the bounds of 'T'

// `::` through a bound reaches its statics and nested types. Drawable declares
// neither a static nor anything named COUNT, so the name is simply missing.
fn <T impl Drawable> scoped(x: T) -> i32 {
    return T::COUNT
}
// DIAG: bounds_opaque.k:[[@LINE-2]]:15: error [R025E]: no member named 'COUNT' in the bounds of 'T'

// An instance member named through `::` is the wrong separator, not a missing
// name.
fn <T impl Drawable> wrong_sep(x: T) -> T {
    return T::draw(x)
}
// DIAG: bounds_opaque.k:[[@LINE-2]]:15: error [R027E]: 'draw' is an instance member of the bounds of 'T'; use '.' on a value of 'T'

// Bounds on a METHOD's own parameters are the method's promise exactly as on
// a free function's.
class Holder {
    fn <T impl Drawable> bad(self, x: T) -> i32 {
        return x.tag
    }
}
// DIAG: bounds_opaque.k:[[@LINE-3]]:18: error [R025E]: no member named 'tag' in the bounds of 'T'

// DIAG-NOT: error
