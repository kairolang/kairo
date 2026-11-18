// A destructor that counts itself unconditionally runs once per object for
// every shape that builds the object in place or hands it on without a
// second owner: a discarded call result, a value bound to a variable, a
// function result passed straight to a function, a local returned from a
// function, an argument built in the call (ownership.mdx, Destruction Order;
// classes-lifecycle.mdx, Destructors).

import std::io::println

var dtors: i32 = 0

class C {
    var id: i32 = 0
    fn C(self, id: i32) { self.id = id }
    @move fn C(self, other: Self) { self.id = other.id }
    fn op finally(self) { dtors += 1 }
}

fn make(id: i32) -> C { return C(id) }
fn eat(c: C) { }
fn through(c: C) -> C { return c }
fn local_returned() -> C {
    var a = C(1)
    return a
}

fn run(const name: string, want: i32) -> i32 {
    var bad = 0
    if dtors != want {
        println(f"FAIL {name}: {dtors} destructor calls, want {want}")
        bad = 1
    }
    dtors = 0
    return bad
}

fn discarded() { make(1) }
fn bound() { var a = make(1) }
fn passed_on() { eat(make(1)) }
fn built_in_call() { eat(C(1)) }
fn returned_local() { var a = local_returned() }
fn two_objects() {
    var a = C(1)
    var b = C(2)
}
fn plain_copy_of_field() {
    var a = C(1)
    var n = a.id
}

fn main() -> i32 {
    var bad = 0
    discarded()
    bad += run("discarded", 1)
    bound()
    bad += run("bound", 1)
    passed_on()
    bad += run("passed_on", 1)
    built_in_call()
    bad += run("built_in_call", 1)
    returned_local()
    bad += run("returned_local", 1)
    two_objects()
    bad += run("two_objects", 2)
    plain_copy_of_field()
    bad += run("plain_copy_of_field", 1)
    if bad == 0 { println("ok") }
    return bad
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe
