// A temporary is destroyed exactly once: a call result that is discarded,
// passed on, bound to a `const` parameter, used as a receiver, moved into a
// variable, a field, an array or a container, or returned. The one
// destruction time the docs fix is a `for` header: the temporaries a call in
// it creates (the receiver, a value passed to a `const` parameter, and what
// those are built from) live until the loop ends and are destroyed once,
// after the last iteration, however the loop is left (control-flow.mdx,
// `for` range and iterator). The time at which other temporaries end is not
// stated by the docs, so those cases check only that every object is
// released exactly once.
// Cases from Rust tests/ui/drop/destructor-run-for-expression-4734,
// drop-immediate-non-box-ty-9446, for-expr-temporary-drop-scope,
// drop-value-by-method, nested-return-drop-order.

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

fn make(id: i32) -> R { return R(id) }
fn eat(r: R) -> i32 { return r.id }
fn peek(const r: R) -> i32 { return r.id }
fn eat_two(a: R, b: R) -> i32 { return a.id + b.id }

class Holder {
    var r: R
    fn Holder(self, r: R) { self.r = r }
    fn get(const self) -> i32 { return self.r.id }
}

class Series {
    var tag: R
    fn Series(self, id: i32) { self.tag = R(id) }
    fn op in (const self) -> yield i32 {
        yield 1
        yield 2
        yield 3
    }
}

fn series(id: i32) -> Series { return Series(id) }

fn discarded_call_result() {
    make(1)
}

fn discarded_two_in_a_row() {
    make(1)
    make(2)
}

fn passed_by_value() -> i32 {
    return eat(make(1))
}

fn passed_by_const() -> i32 {
    return peek(make(1))
}

fn two_arguments() -> i32 {
    return eat_two(make(1), make(2))
}

fn mixed_with_named() -> i32 {
    var a = R(1)
    return eat_two(a, make(2))
}

fn receiver_temporary() -> i32 {
    return Holder(R(1)).get()
}

fn field_read_of_temporary() -> i32 {
    return make(4).id
}

fn bound_to_variable() {
    var r = make(1)
}

fn bound_through_two_calls() {
    var r = make(eat(make(1)) + 1)
}

fn moved_into_field() {
    var h = Holder(make(1))
}

fn moved_into_array() {
    var arr: [R; 2] = [make(1), make(2)]
}

fn moved_into_vector() {
    var v: [R] = [make(1), make(2)]
    v.push(make(3))
}

fn moved_into_tuple() {
    var t = (make(1), make(2))
}

fn returned_through_functions() -> R {
    return make(1)
}

fn arithmetic_with_temporaries() -> i32 {
    return make(1).id + make(2).id * make(3).id
}

fn condition_temporary(c: bool) -> i32 {
    if peek(make(1)) == 1 {
        return 10
    }
    return 20
}

fn short_circuit_temporary(c: bool) -> bool {
    return c && peek(make(1)) == 1
}

fn if_expression_temporaries(c: bool) -> i32 {
    return if c => peek(make(1)) else => peek(make(2))
}

fn for_header_temporary_receiver() -> i32 {
    var n = 0
    for x in series(7) {
        ev(f"item{x}")
        n += x
    }
    ev("after")
    return n
}

fn for_header_break() {
    for x in series(8) {
        if x == 2 { break }
        ev(f"item{x}")
    }
    ev("after")
}

fn for_header_return() -> i32 {
    for x in series(9) {
        if x == 2 { return x }
        ev(f"item{x}")
    }
    return 0
}

fn for_header_continue() {
    for x in series(6) {
        if x == 2 { continue }
        ev(f"item{x}")
    }
    ev("after")
}

fn for_header_nested() {
    for x in series(1) {
        for y in series(2) {
            ev(f"{x}{y}")
        }
        ev("inner-done")
    }
    ev("after")
}

fn main() -> i32 {
    discarded_call_result()
    expect("discarded", "~1")
    expect_balance("discarded")

    discarded_two_in_a_row()
    expect("discarded2", "~1 ~2")
    expect_balance("discarded2")

    var n = passed_by_value()
    log = ""
    expect_balance("passed_by_value")
    if n != 1 { println("FAIL passed_by_value value"); fails += 1 }

    passed_by_const()
    log = ""
    expect_balance("passed_by_const")

    two_arguments()
    log = ""
    expect_balance("two_arguments")

    mixed_with_named()
    log = ""
    expect_balance("mixed_with_named")

    receiver_temporary()
    log = ""
    expect_balance("receiver")

    if field_read_of_temporary() != 4 { println("FAIL field_read value"); fails += 1 }
    log = ""
    expect_balance("field_read")

    bound_to_variable()
    expect("bound_to_variable", "~1")
    expect_balance("bound_to_variable")

    bound_through_two_calls()
    log = ""
    expect_balance("bound_through_two_calls")

    moved_into_field()
    expect("moved_into_field", "~1")
    expect_balance("moved_into_field")

    moved_into_array()
    log = ""
    expect_balance("moved_into_array")

    moved_into_vector()
    log = ""
    expect_balance("moved_into_vector")

    moved_into_tuple()
    log = ""
    expect_balance("moved_into_tuple")

    {
        var r = returned_through_functions()
        expect("returned", "")
    }
    expect("returned end", "~1")
    expect_balance("returned")

    if arithmetic_with_temporaries() != 7 { println("FAIL arithmetic value"); fails += 1 }
    log = ""
    expect_balance("arithmetic")

    condition_temporary(true)
    log = ""
    expect_balance("condition")

    short_circuit_temporary(true)
    short_circuit_temporary(false)
    log = ""
    expect_balance("short_circuit")

    if_expression_temporaries(true)
    if_expression_temporaries(false)
    log = ""
    expect_balance("if_expression")

    for_header_temporary_receiver()
    expect("for_header", "item1 item2 item3 ~7 after")
    expect_balance("for_header")

    for_header_break()
    expect("for_header_break", "item1 ~8 after")
    expect_balance("for_header_break")

    for_header_return()
    expect("for_header_return", "item1 ~9")
    expect_balance("for_header_return")

    for_header_continue()
    expect("for_header_continue", "item1 item3 ~6 after")
    expect_balance("for_header_continue")

    for_header_nested()
    expect("for_header_nested", "11 12 13 ~2 inner-done 21 22 23 ~2 inner-done 31 32 33 ~2 inner-done ~1 after")
    expect_balance("for_header_nested")

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
