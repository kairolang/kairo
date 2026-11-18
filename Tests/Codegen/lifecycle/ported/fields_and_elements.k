// A class's fields are destroyed by its destructor in reverse declaration
// order (classes-lifecycle.mdx: `fn op finally(self) = default` is a
// memberwise destroy in reverse declaration order), and a field's own
// destructor runs for every object owned by the field: a nested class, an
// array, a vector, a tuple, a nullable, a map value. The order among the
// elements of an array, vector, tuple or base class is not stated by the
// docs, so those cases check that every element is released exactly once.
// Cases from Rust tests/ui/drop/struct-field-drop-order,
// array-partial-move-drop-order, drop-trait-enum, enum-drop-impl-15063,
// repeat-drop, multiple-drop-safe-code-25549.

import std::io::println

var log: string = ""
var fails: i32 = 0
var made: i32 = 0
var released: i32 = 0

fn ev(const s: string) {
    if log != "" { log += " " }
    log += s
}

fn expect(const name: string, const want: string) {
    if log != want {
        println(f"FAIL {name}: got [{log}] want [{want}]")
        fails += 1
    }
    log = ""
}

fn expect_balance(const name: string) {
    if made != released {
        println(f"FAIL {name}: made {made} released {released}")
        fails += 1
    }
    made = 0
    released = 0
}

// An owning handle: the move constructor takes the identity and leaves an
// empty husk, and only a live handle counts as released by its destructor.
class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id; made += 1 }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) {
        if self.id != 0 {
            ev(f"~{self.id}")
            released += 1
        }
    }
}

class Three {
    var a: R
    var b: R
    var c: R
    fn Three(self) { self.a = R(1); self.b = R(2); self.c = R(3) }
    fn op finally(self) = default
}

class Mixed {
    var n: i32 = 0
    var first: R
    var count: i32 = 0
    var second: R
    fn Mixed(self) { self.first = R(10); self.second = R(20) }
}

class Inner {
    var x: R
    var y: R
    fn Inner(self, base: i32) { self.x = R(base); self.y = R(base + 1) }
}

class Nested {
    var p: Inner
    var q: Inner
    fn Nested(self) { self.p = Inner(10); self.q = Inner(20) }
}

class Container {
    var arr: [R; 3]
    var tail: R
    fn Container(self) { self.arr = [R(1), R(2), R(3)]; self.tail = R(9) }
}

class Opt {
    var maybe: R?
    var always: R
    fn Opt(self, has: bool) {
        self.always = R(5)
        if has { self.maybe = R(6) }
    }
}

class Base {
    var b: R
    fn Base(self) { self.b = R(1) }
}

class Derived derives Base {
    var d: R
    fn Derived(self) { self.d = R(2) }
}

class WithDtor {
    var held: R
    fn WithDtor(self) { self.held = R(1) }
    fn op finally(self) { ev("body") }
}

fn fields_reverse_order() {
    var t = Three()
}

fn fields_between_plain_members() {
    var m = Mixed()
}

fn nested_classes() {
    var n = Nested()
}

fn array_field_balance() {
    var c = Container()
}

fn local_array_balance() {
    var arr: [R; 4] = [R(1), R(2), R(3), R(4)]
}

fn vector_balance() {
    var v: [R] = [R(1), R(2), R(3)]
    v.push(R(4))
}

fn vector_empty_then_filled() {
    var v: [R] = []
    var n = 0
    for i in 0..5 {
        v.push(R(i + 1))
        n += 1
    }
}

fn tuple_balance() {
    var t = (R(1), R(2), 5)
}

fn nullable_present() {
    var o = Opt(true)
}

fn nullable_absent() {
    var o = Opt(false)
}

fn nullable_local() {
    var o: R? = R(4)
    var p: R? = null
}

fn derived_balance() {
    var d = Derived()
}

fn destructor_body_runs_with_fields() {
    var w = WithDtor()
}

fn field_of_field_chain() {
    var n = Nested()
    ev("built")
}

fn main() -> i32 {
    fields_reverse_order()
    expect("fields_reverse_order", "~3 ~2 ~1")
    expect_balance("fields_reverse_order")

    fields_between_plain_members()
    expect("fields_between_plain_members", "~20 ~10")
    expect_balance("fields_between_plain_members")

    nested_classes()
    expect("nested_classes", "~21 ~20 ~11 ~10")
    expect_balance("nested_classes")

    array_field_balance()
    log = ""
    expect_balance("array_field")

    local_array_balance()
    log = ""
    expect_balance("local_array")

    vector_balance()
    log = ""
    expect_balance("vector")

    vector_empty_then_filled()
    log = ""
    expect_balance("vector_grown")

    tuple_balance()
    log = ""
    expect_balance("tuple")

    nullable_present()
    log = ""
    expect_balance("nullable_present")

    nullable_absent()
    expect("nullable_absent", "~5")
    expect_balance("nullable_absent")

    nullable_local()
    expect("nullable_local", "~4")
    expect_balance("nullable_local")

    derived_balance()
    log = ""
    expect_balance("derived")

    destructor_body_runs_with_fields()
    log = ""
    expect_balance("destructor_body")

    field_of_field_chain()
    expect("field_chain", "built ~21 ~20 ~11 ~10")
    expect_balance("field_chain")

    if fails == 0 { println("ok") }
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe
