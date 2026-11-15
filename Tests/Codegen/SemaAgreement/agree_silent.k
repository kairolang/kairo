// The Sema agreement pass on a program whose calls clang binds as Kairo
// did: overloads, a method, constructors, an operator, a generic function
// and its instances, an explicit specialization, a function declared before
// it is defined, a method defined out of line, and a generic body's call
// that an instance takes to a partial specialization's member. It joins
// the calls it recorded to clang's tree and says nothing.

import std::io::println

fn pick(x: i32) -> i32 { return 1 }
fn pick(x: f64) -> i32 { return 2 }
fn pick(x: i32, y: i32) -> i32 { return 3 }

class Box {
    var v: i32 = 0
    fn Box(self) { self.v = 7 }
    fn Box(self, v: i32) { self.v = v }
    fn Box(self, a: i32, b: i32) { self.v = a + b }
    fn get(self) -> i32 { return self.v }
    fn get(self, plus: i32) -> i32 { return self.v + plus }
    fn op + (self, o: Box) -> Box { return Box(self.v + o.v) }
}

fn <T> twice(x: T) -> i32 {
    var i: i32 = 1
    var f: f64 = 2.0
    return pick(i) + pick(f)
}
fn <T> spec() -> i32 { return 1 }
fn <> spec<i32>() -> i32 { return 2 }

fn later(x: i32 = 4) -> i32
fn later(x: i32) -> i32 { return x }

class Out {
    pub fn Out(self) { }
    pub fn m(self, i: i32 = 8) -> i32
}

fn Out::m(self, i: i32) -> i32 { return i * 2 }

class <T> Store {
    fn Store(self) { }
    pub fn tag(const self) -> i32 = 1
}

class <P> Store<*P> {
    fn Store(self) { }
    pub fn tag(const self) -> i32 = 2
}

fn <T> tag_of(s: Store<T>) -> i32 = s.tag()

fn main() -> i32 {
    var a = Box()
    var b = Box(3)
    var c = Box(1, 2)
    var d = a + b
    var i: i32 = 1
    var f: f64 = 1.5
    println(f"{pick(i)} {pick(f)} {pick(i, i)}")
    println(f"{a.get()} {b.get(10)} {c.get()} {d.get()}")
    println(f"{twice(1)} {twice(true)} {spec<i32>()} {spec<u8>()}")
    var out = Out()
    println(f"{later()} {later(6)} {out.m()} {out.m(1)}")
    println(f"{tag_of(Store<i32>())} {tag_of(Store<*i32>())}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -v -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=PASS
// PASS-NOT: I012W
// PASS: sema agreement: {{[1-9][0-9]*}} calls recorded, {{[1-9][0-9]*}} joined, {{[1-9][0-9]*}} agreed {{.*}} 0 disagreed in {{.*}}agree_silent.k
// PASS-NOT: I012W

// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      1 2 3
// OUT-NEXT: 7 13 3 10
// OUT-NEXT: 3 3 2 1
// OUT-NEXT: 4 6 16 2
// OUT-NEXT: 1 2

// Off, the pass records nothing.
// RUN: rm -rf %t.d
// RUN: %kairo %s -v -fno-sema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=OFF --allow-empty
// OFF-NOT: sema agreement:
