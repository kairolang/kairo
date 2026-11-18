// A member type is inherited like any other member, so `Der::Inner` names
// `Base::Inner` in type position as it does in an expression: a nested
// class, enum and alias, through one base or several levels, before the
// deriving class is declared, and through a generic base, where it is read
// at the base's arguments (`GDer<i32>::Elem` is `i32`). A name no base has
// is still R025E.

class Uses {
    pub var i: Der::Inner
    pub var w: GDer<i32>::Wrap
}

fn early(x: Der::Inner) -> i32 { return x.v }

class Base {
    pub class Inner { pub var v: i32 = 1 }
    pub enum Kind { A, B }
    pub type Num = i32
}

class Der derives Base { }
class Far derives Der { }

class <T> GBase {
    pub class Wrap { pub var t: T }
    pub type Elem = T
}

class <T> GDer derives GBase<T> { }
class Plain derives GBase<f64> { }

fn main() -> i32 {
    var e = Der::Inner{}
    var i: Der::Inner
    var f: Far::Inner
    var k: Far::Kind = Far::Kind::B
    var n: Der::Num = 3
    var el: GDer<i32>::Elem = 4
    var pl: Plain::Elem = 1.5
    var u = Uses()
    u.w.t = el
    var half = if (pl > 1.0) => (1) else => 0
    var kind = if (k == Base::Kind::B) => (1) else => 0
    return early(i) + e.v + f.v + n + u.w.t + u.i.v + half + kind
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 13
// RUN: { %kairo %S/inputs/inherited_member_type_missing.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: inherited_member_type_missing.k:5:19: error [R025E]: no type named 'Nope' in 'Der'
