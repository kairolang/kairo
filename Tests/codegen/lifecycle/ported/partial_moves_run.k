// Moving a field out of a value leaves that field moved-from and the rest
// of the value live: the parent still destroys what it keeps, the new owner
// destroys what it took, and the moved-from slot drops silently, so every
// object is released exactly once. The same holds for a field reached
// through a pointer, a field of `self`, a field moved out and assigned again,
// a tuple element, and an element taken out of a vector by a method that
// leaves the vector valid (ownership.mdx, Moving a part; `pop` of a vector).
// Cases from Rust tests/ui/drop/array-partial-move-drop-order,
// drop-in-for-loop-destructure; moves/move-out-of-field.

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

class Pair {
    var a: R
    var b: R
    fn Pair(self, x: i32, y: i32) { self.a = R(x); self.b = R(y) }
}

class Outer {
    var p: Pair
    var c: R
    fn Outer(self) { self.p = Pair(1, 2); self.c = R(3) }
}

class Machine {
    var a: R
    var b: R
    fn Machine(self) { self.a = R(1); self.b = R(2) }
    fn take_a(self) -> R { return self.a }
    fn swap_a(self, f: R) -> R {
        var old = self.a
        self.a = f
        return old
    }
}

fn move_one_field() {
    var p = Pair(1, 2)
    var x = p.a
    ev("moved")
}

fn move_one_field_out_of_scope() {
    var x = R(99)
    {
        var p = Pair(1, 2)
        x = p.a
        ev("inner-end")
    }
    ev("outer")
}

fn move_second_field() {
    var p = Pair(1, 2)
    var y = p.b
    ev("moved")
}

fn move_both_fields() {
    var p = Pair(1, 2)
    var x = p.a
    var y = p.b
    ev("moved")
}

fn move_field_and_refill() {
    var p = Pair(1, 2)
    var x = p.a
    p.a = R(3)
    ev("refilled")
}

fn move_field_into_call() {
    var p = Pair(1, 2)
    consume(p.a)
    ev("back")
}

fn consume(r: R) { ev("consume") }

fn move_nested_field() {
    var o = Outer()
    var x = o.p.a
    ev("moved")
}

fn move_nested_parent_field() {
    var o = Outer()
    var q = o.p
    ev("moved")
}

fn move_field_in_branch(c: bool) {
    var p = Pair(1, 2)
    if c { var x = p.a }
    ev("end")
}

fn move_field_through_pointer() {
    var p = Pair(1, 2)
    var q: *Pair = &p
    var x = cxx::std::move(q->a)
    ev("moved")
}

fn move_field_through_pointer_and_refill() {
    var p = Pair(1, 2)
    var q: *Pair = &p
    var x = cxx::std::move(q->a)
    q->a = R(3)
    ev("refilled")
}

fn move_field_of_self() {
    var m = Machine()
    var a = m.take_a()
    ev("taken")
    m.a = R(5)
    ev("refilled")
}

fn swap_field_of_self() {
    var m = Machine()
    var old = m.swap_a(R(7))
    ev("swapped")
}

fn tuple_element() {
    var t = (R(1), R(2))
    var x = t.0
    ev("moved")
}

fn vector_pop() {
    var v: [R] = [R(1), R(2), R(3)]
    var last = v.pop()
    ev("popped")
}

fn vector_pop_until_empty() {
    var v: [R] = [R(1), R(2)]
    while true {
        var item = v.pop()
        if item == null { break }
    }
    ev("drained")
}

fn vector_clear() {
    var v: [R] = [R(1), R(2)]
    v.clear()
    ev("cleared")
}

fn main() -> i32 {
    move_one_field()
    expect("one_field", "moved ~1 ~2")
    expect_balance("one_field")

    move_one_field_out_of_scope()
    expect("one_field_scope", "~99 inner-end ~2 outer ~1")
    expect_balance("one_field_scope")

    move_second_field()
    expect("second_field", "moved ~2 ~1")
    expect_balance("second_field")

    move_both_fields()
    expect("both_fields", "moved ~2 ~1")
    expect_balance("both_fields")

    move_field_and_refill()
    expect("refill", "refilled ~1 ~2 ~3")
    expect_balance("refill")

    move_field_into_call()
    expect("into_call", "consume ~1 back ~2")
    expect_balance("into_call")

    move_nested_field()
    expect("nested_field", "moved ~1 ~3 ~2")
    expect_balance("nested_field")

    move_nested_parent_field()
    expect("nested_parent", "moved ~2 ~1 ~3")
    expect_balance("nested_parent")

    move_field_in_branch(true)
    expect("branch true", "~1 end ~2")
    move_field_in_branch(false)
    expect("branch false", "end ~2 ~1")
    expect_balance("branch")

    move_field_through_pointer()
    expect("pointer", "moved ~1 ~2")
    expect_balance("pointer")

    move_field_through_pointer_and_refill()
    expect("pointer refill", "refilled ~1 ~2 ~3")
    expect_balance("pointer refill")

    move_field_of_self()
    expect("self_field", "taken refilled ~1 ~2 ~5")
    expect_balance("self_field")

    swap_field_of_self()
    expect("swap_field", "swapped ~1 ~2 ~7")
    expect_balance("swap_field")

    tuple_element()
    expect("tuple_element", "moved ~1 ~2")
    expect_balance("tuple_element")

    vector_pop()
    log = ""
    expect_balance("vector_pop")

    vector_pop_until_empty()
    expect("vector_drain", "~2 ~1 drained")
    expect_balance("vector_drain")

    vector_clear()
    log = ""
    expect_balance("vector_clear")

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
ffi "c++" import "utility"
