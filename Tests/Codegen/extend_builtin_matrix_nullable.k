// A nullable can be extended, and its members
// are the nullable's own: `self` is the `T?`, so a call reads no value and
// is legal on a null receiver as on a set one. Rows: a primitive, string,
// a class, a generic `[T]?` and `Box<T>?`, a static (through an alias: a
// `T?` cannot head a `::` path), `extend X? impl I`, a field path, and the
// `T?` member taking precedence over T's at `.` while `?.` reaches T's.
// Before, each call was R025E "no member named ... in 'T'".
// Sibling of extend_builtin_matrix.k; the rejected targets are in
// Sema/Check/extend_unextendable_target.k.

extend i32? {
    pub fn or_zero(self) -> i32 {
        if self? { return self }
        return 0
    }
    pub fn is_set(self) -> bool { return self != null }
    pub fn none() -> i32? { return null }
    pub fn which(self) -> i32 { return 20 }
}
extend i32 { pub fn which(self) -> i32 { return 10 } }
extend string? {
    pub fn len_or(self, d: i32) -> i32 {
        if self? { return self.size() as i32 }
        return d
    }
}
pub class Foo {
    pub var v: i32
    pub fn Foo(self, v: i32) { self.v = v }
}
extend Foo? {
    pub fn get_or(self, d: i32) -> i32 {
        if self? { return self.v }
        return d
    }
}
extend <T> [T]? {
    pub fn count(self) -> i32 {
        if self? { return self.size() as i32 }
        return -1
    }
}
pub class <T> Box {
    pub var v: T
    pub fn Box(self, v: T) { self.v = v }
}
extend <T> Box<T>? {
    pub fn get_or(self, d: T) -> T {
        if self? { return self.v }
        return d
    }
}
interface Show { fn show(self) -> i32 }
extend f64? impl Show {
    pub fn show(self) -> i32 { if self? { return 1 } return 2 }
}
fn <T impl Show> shown(t: T) -> i32 { return t.show() }
pub struct Holder { pub var n: i32? }
type OptI = i32?

fn main() -> i32 {
    var a: i32? = 3
    var b: i32? = null
    var n = a.or_zero() + b.or_zero() + (if b.is_set() => (100) else => 0)       // 3
    var s: string? = "abc"
    var t: string? = null
    n += s.len_or(9) + t.len_or(9)                                               // 12
    var f: Foo? = Foo(4)
    var g: Foo? = null
    n += f.get_or(7) + g.get_or(7)                                               // 11
    var v: [i32]? = [1, 2]
    var w: [i32]? = null
    n += v.count() + w.count()                                                   // 1
    var bx: Box<i32>? = Box<i32>(5)
    var by: Box<i32>? = null
    n += bx.get_or(1) + by.get_or(2)                                             // 7
    var x = OptI::none()
    n += if x? => (100) else => 0                                                // 0
    var p: f64? = 1.5
    var q: f64? = null
    n += shown(p) + shown(q)                                                     // 3
    var h = Holder { n: null }
    n += h.n.or_zero()                                                           // 0
    var c = a?.which()
    n += b.which() + (c ?? 0)                                                    // 30
    return n - 67
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t && %t
// RUN: cd %S/Inputs/extend_nullable_lib && %kairo main.k -o %t.xf && %t.xf
