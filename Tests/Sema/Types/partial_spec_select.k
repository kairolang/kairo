// Sema/Types/partial_spec_select.k
// NULLABLE.md G0: which body an instance of a specialized record takes. The
// most specialized pattern that matches wins -- explicit, then the strictly
// more specialized partial, then the primary -- and member lookup, field
// types and constructors all read that body: a member only the primary has
// is not a member of `Store<*i32>`. A DEPENDENT use (`Store<*U>` in a
// generic signature, an extension's receiver) selects the same way, its
// parameters opaque. The errors (ambiguity, `requires`) are in
// partial_spec_errors.k and partial_spec_requires.k: each stops Sema
// before member typing.
pub class <T> Store {
    pub var value: T
    fn Store(self, v: T) { self.value = v }
}
pub class <P> Store<*P> {
    pub var ptr: unsafe *P
    fn Store(self, v: *P) { unsafe { self.ptr = v as unsafe *P } }
}
pub class <P> Store<*const P> {
    pub var cptr: unsafe *const P
    fn Store(self, v: *const P) { unsafe { self.cptr = v as unsafe *const P } }
}
pub class <> Store<bool> {
    pub var bits: u8 = 2
    fn Store(self, v: bool) { self.bits = v as u8 }
}
extend <P> Store<*P> {
    pub fn raw(const self) -> unsafe *P = self.ptr
}
fn <U> deref(s: Store<*U>) -> unsafe *U = s.ptr
pub struct <A, B> Pair { pub var a: A; pub var b: B }
pub struct <X> Pair<X, i32> { pub var left: X }
pub struct <Y> Pair<i32, Y> { pub var right: Y }
pub struct <W> Pair<W, W> { pub var same: W }
fn main() -> i32 {
    var n = 4
    var k: i32 = 5
    var a = Store<i32>(1)
    var b = Store<*i32>(&n)
    var c = Store<bool>(true)
    var d = Store<*const i32>(&k)
    var p1: unsafe *i32 = b.ptr
    var p2: unsafe *const i32 = d.cptr
    var p3: unsafe *i32 = deref(b)
    var p4: unsafe *i32 = b.raw()
    var bits: u8 = c.bits
    var bad1 = b.value
    var bad2 = a.ptr
    var bad3 = c.value
    var bad4 = d.ptr
    var x1 = Pair<f64, i32> { left: 1.0 }
    var y1 = Pair<i32, f64> { right: 2.0 }
    var w1 = Pair<f64, f64> { same: 3.0 }
    var bad5 = Pair<f64, i32> { a: 1.0, b: 2 }
    var l: f64 = x1.left
    var r: f64 = y1.right
    var s: f64 = w1.same
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// The primary's member on the partial's instance, and the reverse; the
// explicit spec's body has neither; `*const i32` took `<P> Store<*const P>`.
// DIAG: partial_spec_select.k:47:18: error [R025E]: no member named 'value' in 'Store'
// DIAG: partial_spec_select.k:48:18: error [R025E]: no member named 'ptr' in 'Store'
// DIAG: partial_spec_select.k:49:18: error [R025E]: no member named 'value' in 'Store'
// DIAG: partial_spec_select.k:50:18: error [R025E]: no member named 'ptr' in 'Store'
// An initializer reads the selected body's fields too.
// DIAG: partial_spec_select.k:54:33: error [SC040E]: 'Pair' has no field named 'a'
// DIAG: partial_spec_select.k:54:41: error [SC040E]: 'Pair' has no field named 'b'
