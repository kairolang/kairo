// witness/bound_ops.k -- exit 0
// Everything an opaque `T` cannot do (Sema/Check/opaque_param_ops.k) a bound
// can grant, and then it is a call through the bound's witness (CODEGEN.md
// §7b.5), not an operator C++ resolves per instance: `==` and `!=` from an
// `op ==` requirement, `<` from an `op <=>` one, `+` from `op +`, `===` on a `T?`
// from the same `op ==`, `as string` from an `op as` requirement and an
// interpolation from a `repr` one. A `match` on a T binds it and guards it,
// which needs no bound at all.
pub interface Value {
    fn op ==(const self, other: Self) -> bool
    fn op +(const self, other: Self) -> Self
    fn repr(const self) -> string
}
pub interface Ordered {
    fn op <=>(const self, other: Self) -> Ordering
}
pub interface Named {
    fn op as(const self) -> string
}

pub class Num {
    pub var v: i32
    fn Num(self, v: i32) { self.v = v }
    pub fn op ==(const self, other: Num) -> bool = self.v == other.v
    pub fn op +(const self, other: Num) -> Num = Num(self.v + other.v)
    pub fn repr(const self) -> string = "num"
}
pub struct Rank {
    pub var v: i32
    pub fn op <=>(const self, other: Rank) -> Ordering {
        if self.v < other.v { return Ordering::Less }
        if self.v > other.v { return Ordering::Greater }
        return Ordering::Equal
    }
}
pub struct Tag {
    pub var v: i32
    pub fn op as(const self) -> string = "tag"
}

fn <T impl Value> eq(a: T, b: T) -> bool = a == b
fn <T impl Value> ne(a: T, b: T) -> bool = a != b
fn <T impl Ordered> lt(a: T, b: T) -> bool = a < b
fn <T impl Value> sum(a: T, b: T) -> T = a + b
fn <T impl Value> same(a: T?, b: T?) -> bool = a === b
fn <T impl Value> shown(a: T) -> string = f"<{a}>"
fn <T impl Named> text(a: T) -> string = a as string
fn <T> pick(a: T, k: i32) -> i32 {
    return match a {
        case var x where k > 0 => 1
        case _ => 2
    }
}

fn main() -> i32 {
    var one = Num(1)
    var two = Num(2)
    var r = 0
    if !eq(one, one)              { r += 1 }
    if !ne(one, two)              { r += 2 }
    if !lt(Rank { v: 1 }, Rank { v: 2 }) { r += 4 }
    if sum(one, two).v != 3       { r += 8 }
    var a: Num? = one
    var b: Num? = Num(1)
    var c: Num? = null
    if !same(a, b)                { r += 16 }
    if same(a, c)                 { r += 32 }
    if shown(one).len != 5        { r += 64 }
    if text(Tag { v: 0 }).len != 3 { r += 128 }
    if (pick(one, 1) != 1) || (pick(5, 0) != 2) { r += 256 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Value_witness<T>::__kairo_op_eq(a, b)
// CXX: Named_witness<T>::

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
