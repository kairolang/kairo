// Declared conformances that hold are accepted at the declaration and
// work through a bound: an associated type taken from the interface's
// default (interfaces have no default methods; an associated type default
// is what an explicit `impl` may take from the interface), a generic class
// over an interface parameter, a conditional extension `impl`, members
// inherited from a base class, a derived interface met in full, a builtin
// interface with a derived requirement (Hash needs Eq's `==`), and
// Copyable met by a COPY class's copy constructor.

interface Container {
    type Item = i32
    fn get(const self) -> Self::Item
}

class Bag impl Container {
    pub fn get(const self) -> i32 { return 7 }
}

interface <U> Holder {
    fn put(self, u: U)
    fn take(const self) -> U
}

class <T> Box impl Holder<T> {
    pub var v: T
    pub fn put(self, u: T) { self.v = u }
    pub fn take(const self) -> T { return self.v }
}

interface Show {
    fn show(const self) -> i32
}

class Leaf impl Show {
    pub var n: i32 = 0
    pub fn show(const self) -> i32 { return self.n }
}

class <T> Cell {
    pub var v: T
}

extend <T impl Show> Cell<T> impl Show {
    pub fn show(const self) -> i32 { return self.v.show() + 1 }
}

interface Shape {
    fn area(const self) -> i32
}

class Base {
    pub fn area(const self) -> i32 { return 3 }
}

class Square derives Base impl Shape {
}

interface Named {
    fn label(const self) -> i32
}

interface Tagged derives Named {
    fn tag(const self) -> i32
}

class Both impl Tagged {
    pub fn label(const self) -> i32 { return 10 }
    pub fn tag(const self) -> i32 { return 20 }
}

class Key impl Hash {
    pub var a: i32 = 0
    pub fn hash(const self, @inout h: Hasher) { h.write_usize(self.a as usize) }
    pub fn op ==(const self, const o: Self) -> bool { return self.a == o.a }
}

class Plain impl Copyable {
    pub var a: i32 = 4
}

fn <C impl Container> first(c: C) -> C::Item { return c.get() }
fn <H impl Holder<i32>> swap(h: *H) -> i32 {
    h->put(5)
    return h->take()
}
fn <S impl Show> shown(s: S) -> i32 { return s.show() }
fn <S impl Shape> measure(s: S) -> i32 { return s.area() }
fn <T impl Tagged> tagged(t: T) -> i32 { return t.label() + t.tag() }
fn <K impl Hash> same(a: K, b: K) -> bool { return a == b }
fn <P impl Copyable> dup(p: P) -> P { return p.copy() }

fn main() -> i32 {
    var b = Box<i32>{v: 1}
    var c = Cell<Leaf>{v: Leaf{n: 2}}
    var total = first(Bag()) + swap(&b) + shown(c) + measure(Square()) + tagged(Both())
    if same(Key{a: 1}, Key{a: 1}) {
        total += 1
    }

    return total + dup(Plain()).a
}

// --- lit wiring -----------------------------------------------------------
// 7 + 5 + 3 + 3 + 30 + 1 + 4
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: error [
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 53
