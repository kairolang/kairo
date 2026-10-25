// Sema/Check/conformance_ctor_lifecycle.k
// A LIFECYCLE constructor requirement (`@copy` / `@move`) asks for a
// category, not a declared constructor (Doc: Interface Requirements):
// `@copy` is met by COPY types, `@move` by COPY and MOVE, an implicit
// transfer counts, and a builtin is COPY. The diagnostic names the
// category, since the transfer constructor may well be implicit.
interface Copyable {
    @copy
    fn Copyable(self, const other: Self)
}
interface Movable {
    @move
    fn Movable(self, other: Self)
}
pub struct P { pub var n: i32 = 1 }
@move
pub class M {
    pub var n: i32 = 4
    fn M(self) { }
    @move fn M(self, other: M) { self.n = other.n }
}
fn <T impl Copyable> store(item: T) -> T { return item }
fn <T impl Movable> take(item: T) -> T { return item }
fn main() -> i32 {
    var a = store(P())
    var b = store(8)
    var c = take(M())
    var d = take(P())
    var e = store(M())
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: conformance_ctor_lifecycle.k:{{(25|26|27|28)}}:
// CHECK: conformance_ctor_lifecycle.k:29:13: error [SC001E]: 'M' does not conform to 'Copyable': 'M' is not a COPY type
// CHECK: conformance_ctor_lifecycle.k:22:5: note [I900N]: required by this bound
// CHECK: conformance_ctor_lifecycle.k:9:5: note [I900N]: the constructor is required here
// CHECK-NOT: error
