// The emitted C++ writes `priv` members `private:` and `prot` ones
// `protected:`, and each record befriends the rest of its file
// (EmitPlan::file_friends) -- C++'s spelling of Kairo's "the class and
// every function of its file". Every kind of same-file code that reaches a
// private member must still compile and run: a free function, a generic
// one (instantiated here), a closure inside one, a local function and a
// local class (hoisted to namespace scope), another record's method and
// its nested class, an outer class reading a nested one's privates, a
// sibling's field default, an extension of another type, an operator of a
// file-scope `fn op`, a witness through a declared `impl` with a private
// member, a generic class's private field, a struct's private operator, a
// constrained generic class, a generic function whose parameter is named
// as Cell's is (its friend line inside Cell renames it), a function in a
// `module` block (another C++
// namespace: befriended by its qualified name after a declaration of its
// own), the initializers of two globals (a C++ variable cannot be a friend:
// each calls a befriended `__kairo_ginit_` thunk), and `main`. Before, each of these was a CL001E from clang the moment the
// member went private.
//
// Each check returns its own code on failure; 0 is a pass.

interface Area { fn area(const self) -> i32 }

class Vault impl Area {
    var secret: i32 = 7
    prot var shared: i32 = 11
    static count: i32 = 3
    priv fn peek(const self) -> i32 { return self.secret }
    priv fn area(const self) -> i32 { return self.secret * 2 }
    fn Vault(self) { }
    priv fn Vault(self, s: i32) { self.secret = s }
    priv class Key {
        var k: i32 = 2
        fn Key(self) { }
    }
    fn key_of(const self) -> i32 { var k = Vault::Key(); return k.k }
}

class <T> Cell {
    var item: T
    fn Cell(self, t: T) { self.item = t }
}

class Reader {
    var seen: i32 = Vault::count
    fn Reader(self) { }
    fn read(const self, v: *Vault) -> i32 { return v->secret + v->shared }
    class Inner {
        fn Inner(self) { }
        fn peek(const self, v: *Vault) -> i32 { return v->peek() }
    }
}

struct Pt {
    var x: i32
    priv fn op *(const self, k: i32) -> i32 { return self.x * k }
}

class Point {
    var p: i32 = 5
    fn Point(self) { }
}

extend Point {
    fn steal(const self, v: *Vault) -> i32 { return v->secret + self.p }
}

fn op +(a: Vault, b: Point) -> i32 { return a.secret + b.p }

module inner {
    fn mod_read(v: *Vault) -> i32 { return v->secret }
}

class <T impl Area> Shown {
    var t: T
    fn Shown(self, t: T) { self.t = t }
    fn peek(const self, v: *Vault) -> i32 { return v->secret + self.t.area() }
}

var g_count: i32 = Vault::count
var g_secret: i32 = Vault(9).secret

fn free_read(v: *Vault) -> i32 { return v->secret }
fn <T> gen_read(v: *Vault, t: T) -> i32 { return v->secret }
fn <T> cell_item(c: *Cell<T>) -> T { return c->item }
fn <T impl Area> measure(t: T) -> i32 { return t.area() }

fn closure_read(v: Vault) -> i32 {
    var l = fn () -> i32 { return v.secret }
    return l()
}

fn local_read(v: *Vault) -> i32 {
    fn inner(w: *Vault) -> i32 { return w->secret }
    class Probe {
        fn Probe(self) { }
        fn get(const self, w: *Vault) -> i32 { return w->shared }
    }
    return inner(v) + Probe().get(v)
}

fn main() -> i32 {
    var v = Vault()
    if v.secret != 7 { return 1 }                       // main
    var w = Vault(5)                                    // a private constructor
    if free_read(&w) != 5 { return 2 }                  // a free function
    if gen_read(&v, 1) != 7 { return 3 }                // a generic one
    if closure_read(v) != 7 { return 4 }                // a closure in one
    if local_read(&v) != 18 { return 5 }                // a local fn and class
    var r = Reader()
    if r.read(&v) != 18 { return 6 }                    // another record's method
    if Reader::Inner().peek(&v) != 7 { return 7 }       // its nested class
    if r.seen != 3 { return 8 }                         // its field default
    if v.key_of() != 2 { return 9 }                     // an outer class, a nested one's privates
    var c = Cell<i32>(9)
    if c.item != 9 { return 10 }                        // a generic class's private field
    if cell_item(&c) != 9 { return 20 }                 // from a generic fn naming its T too
    var pt = Pt{ x: 4 }
    if pt * 2 != 8 { return 11 }                        // a struct's private operator
    var p = Point()
    if p.steal(&v) != 12 { return 12 }                  // an extension of another type
    if v + p != 12 { return 13 }                        // a file-scope operator
    if measure(v) != 14 { return 14 }                   // a witness, declared impl
    if Vault::count != 3 { return 15 }                  // a private static
    if inner::mod_read(&v) != 7 { return 16 }           // a module block's function
    if Shown<Vault>(v).peek(&v) != 21 { return 17 }     // a constrained generic class
    if g_count != 3 { return 18 }                       // a global's initializer
    if g_secret != 9 { return 19 }                      // another, through a constructor
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
