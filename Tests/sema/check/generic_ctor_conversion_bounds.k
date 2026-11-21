// A conversion or a construction through a GENERIC constructor of the
// target takes a value of a bounds-checked parameter only when that
// parameter's bounds grant the constructor's own bound. With no bound
// granting it, `a as Box` is the conversion's bound error (R051E unbounded,
// R025E bounded by something else), never a conversion through the
// constructor; `Box(a)` is the constructor's bound error, as a generic
// function's call is (forwarded_bounds.k). `string`'s `<S impl ByteRange>`
// constructor is the same rule.

interface Shape {
    fn area(const self) -> i32
}

interface Other {
    fn other(const self) -> i32
}

interface Square derives Shape {
    fn side(const self) -> i32
}

class Box {
    pub var n: i32 = 0
    pub fn Box(self) {}
    pub fn <S impl Shape> Box(self, const s: S) {
        self.n = s.area()
    }
}

fn <T> cast_unbounded(a: T) -> Box = a as Box
fn <T impl Other> cast_other(a: T) -> Box = a as Box
fn <T> ctor_unbounded(a: T) -> Box = Box(a)
fn <T impl Other> ctor_other(a: T) -> Box = Box(a)
fn <...T> cast_pack(...args: T) {
    for arg in args { var b = arg as Box }
}
fn <T> text_unbounded(a: T) -> string = a as string
fn <T impl Other> text_other(a: T) -> string = a as string

// Granted: the bound itself, or one deriving it.
fn <T impl Shape> cast_shape(a: T) -> Box = a as Box
fn <T impl Square> cast_square(a: T) -> Box = a as Box
fn <T impl Shape> ctor_shape(a: T) -> Box = Box(a)
fn <...T impl Shape> cast_shapes(...args: T) {
    for arg in args { var b = arg as Box }
}
fn <T impl ByteRange> text_bytes(a: T) -> string = a as string

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:30:38: error [R051E]: 'as Box' on 'T' needs a bound that declares 'op as' returning 'Box'
// DIAG: {{.*}}:30:5: note [R051N]: 'T' is declared with no bound
// DIAG: {{.*}}:31:45: error [R025E]: 'as Box' on 'T' needs a bound that declares 'op as' returning 'Box'; none of the bounds of 'T' does
// DIAG: {{.*}}:32:38: error [R051E]: 'Box' needs 'T' to implement 'Shape'
// DIAG: {{.*}}:33:45: error [R025E]: 'Box' needs 'T' to implement 'Shape'; none of the bounds of 'T' does
// DIAG: {{.*}}:35:31: error [R051E]: 'as Box' on 'T' needs a bound that declares 'op as' returning 'Box'
// DIAG: {{.*}}:37:41: error [R051E]: 'as string' on 'T' needs a bound that declares 'op as' returning 'string'
// DIAG: {{.*}}:38:48: error [R025E]: 'as string' on 'T' needs a bound that declares 'op as' returning 'string'; none of the bounds of 'T' does
