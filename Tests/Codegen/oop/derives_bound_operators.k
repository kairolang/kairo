// An operator on a value of a `derives`-bounded parameter is looked up in
// the base's table, as a member step through T is (generics.mdx, MONO.md
// D0): a base that declares the operator binds it at the definition and it
// is emitted as the member call it is, so every instance runs the base's
// operator. Before, `T derives Base` was left out of the bounds check and
// every operator on it deferred to clang unchecked.
//
// Every derivation the operator table gives a concrete record applies:
// `!=` from `op ==`, the relationals from `op <=>`, `a + b` from `op +=`,
// `a += b` from `op +`. A unary operator, `op []`, a CRTP base generic
// over T itself, a base's base, and a T bounded by an interface AND a base
// (the operator from either) are the neighbouring shapes.

pub interface Scaled {
    fn op * (self, k: i32) -> i32
}

class Base {
    pub var v: i32 = 0
    fn op == (self, o: i32) -> bool { return self.v == o; }
    fn op + (self, o: i32) -> i32 { return self.v + o; }
    fn op - (self) -> i32 { return 0 - self.v; }
    fn op [] (self, i: i32) -> i32 { return self.v * i; }
}
class Der derives Base {
    fn Der(self, x: i32) { self.v = x; }
}
class Leaf derives Der {
    fn Leaf(self, x: i32) { Der::Der(self, x); }
}

class Ord {
    pub var v: i32 = 0
    fn op <=> (self, o: i32) -> Ordering {
        if self.v < o { return Ordering::Less; }
        if self.v > o { return Ordering::Greater; }
        return Ordering::Equal;
    }
}
class OrdD derives Ord {
    fn OrdD(self, x: i32) { self.v = x; }
}

class Acc {
    pub var v: i32 = 0
    fn op += (self, o: i32) { self.v += o; }
}
class AccD derives Acc { }

class <X> Mixin {
    pub var v: i32 = 0
    fn op + (self, o: i32) -> i32 { return self.v + o; }
    fn op == (self, o: *X) -> bool { return true; }
}
class Seven derives Mixin<Seven> {
    fn Seven(self) { self.v = 7; }
}

class Both derives Base impl Scaled {
    fn Both(self, x: i32) { self.v = x; }
    fn op * (self, k: i32) -> i32 { return self.v * k; }
}

fn <T derives Base> eq(a: T, x: i32) -> bool { return a == x; }
fn <T derives Base> ne(a: T, x: i32) -> bool { return a != x; }
fn <T derives Base> add(a: T, x: i32) -> i32 { return a + x; }
fn <T derives Base> neg(a: T) -> i32 { return -a; }
fn <T derives Base> sub(a: T) -> i32 { return a[3]; }
fn <T derives Ord> lt(a: T, x: i32) -> bool { return a < x; }
fn <T derives Ord> ge(a: T, x: i32) -> bool { return a >= x; }
fn <T derives Ord> eqo(a: T, x: i32) -> bool { return a == x; }
fn <T derives Acc> bump(a: T) -> i32 {
    var c = a
    c += 3
    var d = c + 4
    return d.v
}
fn <T derives Mixin<T>> crtp(a: T, b: *T) -> i32 {
    if a == b { return a + 1; }
    return 0;
}
fn <T derives Base impl Scaled> both(a: T) -> i32 { return (a * 2) + (a + 1); }

fn main() -> i32 {
    var d = Der(5)
    var l = Leaf(6)
    var o = OrdD(4)
    var s = Seven()
    var s2 = Seven()
    println(f"{eq(d, 5)} {ne(d, 5)} {add(d, 10)} {neg(d)} {sub(d)}")
    println(f"{eq(l, 6)} {add(l, 1)} {sub(l)}")
    println(f"{lt(o, 9)} {ge(o, 9)} {eqo(o, 4)}")
    println(f"{bump(AccD())} {crtp(s, &s2)} {both(Both(3))}")
    return 0
}

import std::io::println

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: true false 15 -5 15
// CHECK-NEXT: true 7 18
// CHECK-NEXT: true false true
// CHECK-NEXT: 7 8 10
