// A constructor that initializes a field in place fills a slot in its
// first half and moves the slot's value into the field
// (Compiler/Spec/Lowering.md, split constructors). For a class whose
// moved-from object need not be destroyed (`C`: MOVE, a destructor, every
// field trivial) neither the slot nor the temporary a prvalue is built in
// runs the destructor of what it moved from. Each line is
// `case: kairo-class-calls c++-type-calls`, the destructor calls of one
// construction, the value's own included: for `C` a prvalue or a moved
// local is one call, a by-value parameter two (the parameter's own
// moved-from object is still destroyed). A COPY class (`K`) copies, and
// every object it copies from is destroyed: the temporary or parameter, the
// slot's value, the field. `DmCxx` has a default constructor, so `HoldX`
// assigns its field after building it and has no slot: C++'s rule, as
// before.
ffi "c++" import "dm_ctor_slots.hh"
import std::io::println

var dtors: i32 = 0

class C {
    var id: i32 = 0
    fn C(self, id: i32) { self.id = id }
    @move fn C(self, other: Self) { self.id = other.id }
    fn op finally(self) { dtors += 1 }
}

class K {
    var id: i32 = 0
    fn K(self, id: i32) { self.id = id }
    @copy fn K(self, const other: Self) { self.id = other.id }
    fn op finally(self) { dtors += 1 }
}

class HoldC {
    var v: C
    fn HoldC(self, n: i32) { self.v = C(n) }
    fn HoldC(self, x: C) { self.v = x }
    fn HoldC(self, n: i32, local: bool) {
        var l = C(n)
        self.v = l
    }
}

class HoldK {
    var v: K
    fn HoldK(self, n: i32) { self.v = K(n) }
    fn HoldK(self, x: K) { self.v = x }
    fn HoldK(self, n: i32, local: bool) {
        var l = K(n)
        self.v = l
    }
}

class HoldX {
    var v: DmCxx
    fn HoldX(self, n: i32) { self.v = DmCxx(n) }
    fn HoldX(self, x: DmCxx) { self.v = x }
    fn HoldX(self, n: i32, local: bool) {
        var l = DmCxx(n)
        self.v = l
    }
}

// Two fields, each from a prvalue.
class Pair {
    var a: C
    var b: C
    fn Pair(self) {
        self.a = C(1)
        self.b = C(2)
    }
}

// A `var` field with a default that the first half assigns on one path
// only: its slot's value replaces the default after the object is built.
class Sparse {
    var a: C = C(0)
    var b: C
    fn Sparse(self, c: bool) {
        if c {
            self.a = C(1)
        }

        self.b = C(2)
    }
}

// A local the second half reads lives in a slot too.
class Carried {
    var v: C
    fn Carried(self) {
        var l = C(5)
        self.v = C(1)
        if l.id != 5 {
            println("lost the local")
        }
    }
}

// A generic class holding its parameter by value: its answer is each
// instance's.
class <T> Box {
    var v: T
    fn Box(self, x: T) { self.v = x }
}

fn report(const name: string) {
    println(f"{name}: {dtors} {dm_cxx_count()}")
    dtors = 0
}

fn main() -> i32 {
    { var h = HoldC(1) }
    report("C prvalue")
    { var h = HoldC(C(1)) }
    report("C param")
    { var h = HoldC(1, true) }
    report("C local")
    { var h = HoldK(1) }
    report("K prvalue")
    { var h = HoldK(K(1)) }
    report("K param")
    { var h = HoldK(1, true) }
    report("K local")
    { var h = HoldX(1) }
    report("X prvalue")
    { var h = HoldX(DmCxx(1)) }
    report("X param")
    { var h = HoldX(1, true) }
    report("X local")
    { var p = Pair() }
    report("Pair")
    { var s = Sparse(true) }
    report("Sparse set")
    { var s = Sparse(false) }
    report("Sparse unset")
    { var c = Carried() }
    report("Carried")
    { var b = Box<C>(C(1)) }
    report("Box<C>")
    { var b = Box<K>(K(1)) }
    report("Box<K>")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      C prvalue: 1 0
// OUT-NEXT: C param: 2 0
// OUT-NEXT: C local: 2 0
// OUT-NEXT: K prvalue: 3 0
// OUT-NEXT: K param: 3 0
// OUT-NEXT: K local: 3 0
// OUT-NEXT: X prvalue: 0 2
// OUT-NEXT: X param: 0 2
// OUT-NEXT: X local: 0 2
// OUT-NEXT: Pair: 2 0
// OUT-NEXT: Sparse set: 3 0
// OUT-NEXT: Sparse unset: 2 0
// OUT-NEXT: Carried: 2 0
// OUT-NEXT: Box<C>: 2 0
// OUT-NEXT: Box<K>: 3 0
// OUT-EMPTY:
