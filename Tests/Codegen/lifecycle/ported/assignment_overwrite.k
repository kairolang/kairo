// Assigning over a live value destroys the old value at the assignment, then
// the new value takes its place: `op =` is generated from the transfer
// constructor, and for one with a body it checks for self-assignment,
// destroys `self`, and rebuilds it in place through the transfer constructor
// (classes-lifecycle.mdx, Assignment is auto-derived). Member-by-member
// assignment (a defaulted or absent transfer constructor) assigns each field,
// so each field destroys its own old value. `x = x` does nothing. A
// variable assigned over after a move holds no live value, so nothing is
// destroyed at that assignment (ownership.mdx, Moved-From State).
// Cases from Rust tests/ui/drop/field-replace-in-struct-with-drop,
// dropflag-reinit-in-loop, dynamic-drop.

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

class Holder {
    var r: R
    var s: R
    fn Holder(self, a: i32, b: i32) { self.r = R(a); self.s = R(b) }
}

class Defaulted {
    var r: R
    fn Defaulted(self, a: i32) { self.r = R(a) }
    @move fn Defaulted(self, other: Self) = default
}

class Cell {
    var r: R
    fn Cell(self, a: i32) { self.r = R(a) }
    fn replace(self, a: i32) { self.r = R(a) }
}

fn make(id: i32) -> R { return R(id) }

fn assign_temporary() {
    var a = R(1)
    a = R(2)
    ev("assigned")
}

fn assign_from_variable() {
    var a = R(1)
    var b = R(2)
    a = b
    ev("assigned")
}

fn assign_twice() {
    var a = R(1)
    a = R(2)
    a = R(3)
    ev("assigned")
}

fn assign_computed_from_old() {
    var a = R(1)
    a = R(a.id + 1)
    ev("assigned")
}

fn assign_function_result() {
    var a = R(1)
    a = make(2)
    ev("assigned")
}

fn assign_after_move_has_nothing_to_destroy() {
    var a = R(1)
    var b = a
    a = R(2)
    ev("assigned")
}

fn assign_self() {
    var a = R(1)
    a = a
    ev("assigned")
}

fn assign_field_of_class() {
    var h = Holder(1, 2)
    h.r = R(3)
    ev("assigned")
}

fn assign_whole_class() {
    var h = Holder(1, 2)
    h = Holder(3, 4)
    ev("assigned")
}

fn assign_defaulted_transfer() {
    var d = Defaulted(1)
    d = Defaulted(2)
    ev("assigned")
}

fn assign_through_method() {
    var c = Cell(1)
    c.replace(2)
    c.replace(3)
    ev("assigned")
}

fn assign_through_pointer() {
    var a = R(1)
    var p: *R = &a
    *p = R(2)
    ev("assigned")
}

fn assign_vector_element() {
    var v: [R] = [R(1), R(2)]
    v[0] = R(3)
    ev("assigned")
    expect("assign_vector", "~1 assigned")
}

fn assign_array_element() {
    var arr: [R; 2] = [R(1), R(2)]
    arr[1] = R(3)
    ev("assigned")
    expect("assign_array", "~2 assigned")
}

fn assign_in_loop() {
    var a = R(1)
    for i in 0..3 {
        a = R(i + 10)
    }
    ev("assigned")
}

fn assign_nullable() {
    var o: R? = R(1)
    o = R(2)
    ev("assigned")
    o = null
    ev("nulled")
}

fn assign_nullable_from_null() {
    var o: R? = null
    o = R(1)
    ev("assigned")
}

fn assign_to_declared_later() {
    var a: R = R(1)
    var b: R = R(2)
    b = a
    ev("assigned")
}

fn main() -> i32 {
    assign_temporary()
    expect("assign_temporary", "~1 assigned ~2")
    expect_balance("assign_temporary")

    assign_from_variable()
    expect("assign_from_variable", "~1 assigned ~2")
    expect_balance("assign_from_variable")

    assign_twice()
    expect("assign_twice", "~1 ~2 assigned ~3")
    expect_balance("assign_twice")

    assign_computed_from_old()
    expect("assign_computed", "~1 assigned ~2")
    expect_balance("assign_computed")

    assign_function_result()
    expect("assign_function_result", "~1 assigned ~2")
    expect_balance("assign_function_result")

    assign_after_move_has_nothing_to_destroy()
    expect("assign_after_move", "assigned ~1 ~2")
    expect_balance("assign_after_move")

    assign_self()
    expect("assign_self", "assigned ~1")
    expect_balance("assign_self")

    assign_field_of_class()
    expect("assign_field", "~1 assigned ~2 ~3")
    expect_balance("assign_field")

    assign_whole_class()
    if log != "~1 ~2 assigned ~4 ~3" && log != "~2 ~1 assigned ~4 ~3" {
        println(f"FAIL assign_whole: got [{log}]")
        fails += 1
    }
    log = ""
    expect_balance("assign_whole")

    assign_defaulted_transfer()
    expect("assign_defaulted", "~1 assigned ~2")
    expect_balance("assign_defaulted")

    assign_through_method()
    expect("assign_method", "~1 ~2 assigned ~3")
    expect_balance("assign_method")

    assign_through_pointer()
    expect("assign_pointer", "~1 assigned ~2")
    expect_balance("assign_pointer")

    assign_vector_element()
    log = ""
    expect_balance("assign_vector")

    assign_array_element()
    log = ""
    expect_balance("assign_array")

    assign_in_loop()
    expect("assign_loop", "~1 ~10 ~11 assigned ~12")
    expect_balance("assign_loop")

    assign_nullable()
    expect("assign_nullable", "~1 assigned ~2 nulled")
    expect_balance("assign_nullable")

    assign_nullable_from_null()
    expect("assign_nullable_from_null", "assigned ~1")
    expect_balance("assign_nullable_from_null")

    assign_to_declared_later()
    expect("assign_declared", "~2 assigned ~1")
    expect_balance("assign_declared")

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
