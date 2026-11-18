// A moved value is destroyed once, by its new owner, when the owner's scope
// ends: a callee's parameter at the callee's end (even when the callee never
// reads it), a field when its object dies, a container element when the
// container dies, the value returned by the function that returns it, the
// closure's capture when the closure dies. The source of a move is invalid
// afterwards, and the handle used here lets the moved-from husk drop
// silently, so each object prints exactly one `~id` (ownership.mdx, Function
// Parameters, Closure Captures, Moved-From State; classes-lifecycle.mdx,
// transfer constructors). A value moved on only some paths is destroyed
// exactly once on every path.
// Cases from Rust tests/ui/drop/drop-once-on-move, conditional-drop-10734,
// drop-value-by-method, move-closure-drop-on-unwind,
// issue-23338-ensure-param-drop-order.

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
    var tag: i32 = 0
    fn Holder(self, r: R) { self.r = r }
}

class Slot {
    var cur: R
    fn Slot(self) { self.cur = R(99) }
    fn put(self, r: R) { self.cur = r }
}

fn ignore(r: R) {
    ev("callee")
}

fn use_then_drop(r: R) -> i32 {
    ev("use")
    return r.id
}

fn pass_through(r: R) -> R {
    return r
}

fn consume_two(a: R, b: R) {
    ev("two")
}

fn move_into_function_unused() {
    var a = R(1)
    ignore(a)
    ev("back")
}

fn move_into_function_used() {
    var a = R(1)
    use_then_drop(a)
    ev("back")
}

fn move_into_function_temporary() {
    ignore(R(1))
    ev("back")
}

fn move_through_two_functions() {
    var a = R(1)
    var b = pass_through(pass_through(a))
    ev("back")
}

fn move_two_arguments() {
    var a = R(1)
    var b = R(2)
    consume_two(a, b)
    ev("back")
}

fn move_arguments_reversed() {
    var a = R(1)
    var b = R(2)
    consume_two(b, a)
    ev("back")
}

fn move_into_field() {
    var a = R(1)
    var h = Holder(a)
    ev("built")
}

fn move_into_field_by_method() {
    var s = Slot()
    var a = R(1)
    s.put(a)
    ev("put")
}

fn move_into_vector() {
    var a = R(1)
    var v: [R] = []
    v.push(a)
    ev("pushed")
}

fn move_into_array_literal() {
    var a = R(1)
    var b = R(2)
    var arr: [R; 2] = [a, b]
    ev("built")
}

fn move_into_tuple() {
    var a = R(1)
    var t = (a, 5)
    ev("built")
}

fn move_chain() {
    var a = R(1)
    var b = a
    var c = b
    var d = c
    ev("moved")
}

fn move_out_and_back_in() {
    var a = R(1)
    var b = a
    a = b
    ev("back")
}

fn move_returned_out_of_scope() -> R {
    var a = R(1)
    var b = R(2)
    return a
}

fn move_into_closure() {
    var a = R(1)
    var f = fn () -> i32 { return a.id }
    ev("made")
    f()
    ev("called")
}

fn closure_called_twice() {
    var a = R(1)
    var f = fn () -> i32 { return a.id }
    f()
    f()
    ev("called")
}

fn closure_never_called() {
    var a = R(1)
    var f = fn () -> i32 { return a.id }
    ev("made")
}

fn closure_dies_before_scope_end() {
    var a = R(1)
    {
        var f = fn () -> i32 { return a.id }
        ev("in")
    }
    ev("out")
}

fn closure_by_pointer_does_not_own() {
    var a = R(1)
    var f = fn ()|*| -> i32 { return (*a).id }
    f()
    ev("called")
}

fn closure_returned() -> fn() -> i32 {
    var a = R(1)
    return fn () -> i32 { return a.id }
}

fn move_to_pointer_target() {
    var a = R(1)
    var b = R(2)
    var p: *R = &b
    *p = a
    ev("assigned")
}

fn main() -> i32 {
    move_into_function_unused()
    expect("fn_unused", "callee ~1 back")
    expect_balance("fn_unused")

    move_into_function_used()
    expect("fn_used", "use ~1 back")
    expect_balance("fn_used")

    move_into_function_temporary()
    expect("fn_temporary", "callee ~1 back")
    expect_balance("fn_temporary")

    move_through_two_functions()
    expect("through_two", "back ~1")
    expect_balance("through_two")

    move_two_arguments()
    expect("two_args", "two ~2 ~1 back")
    expect_balance("two_args")
    move_arguments_reversed()
    log = ""
    expect_balance("two_args reversed")

    move_into_field()
    expect("field", "built ~1")
    expect_balance("field")

    move_into_field_by_method()
    expect("field_by_method", "~99 put ~1")
    expect_balance("field_by_method")

    move_into_vector()
    expect("vector", "pushed ~1")
    expect_balance("vector")

    move_into_array_literal()
    log = ""
    expect_balance("array_literal")

    move_into_tuple()
    expect("tuple", "built ~1")
    expect_balance("tuple")

    move_chain()
    expect("chain", "moved ~1")
    expect_balance("chain")

    move_out_and_back_in()
    expect("out_and_back", "back ~1")
    expect_balance("out_and_back")

    {
        var r = move_returned_out_of_scope()
        expect("returned", "~2")
        ev("held")
    }
    expect("returned end", "held ~1")
    expect_balance("returned")

    move_into_closure()
    expect("into_closure", "made called ~1")
    expect_balance("into_closure")

    closure_called_twice()
    expect("closure_twice", "called ~1")
    expect_balance("closure_twice")

    closure_never_called()
    expect("closure_never_called", "made ~1")
    expect_balance("closure_never_called")

    closure_dies_before_scope_end()
    expect("closure_dies", "in ~1 out")
    expect_balance("closure_dies")

    closure_by_pointer_does_not_own()
    expect("closure_pointer", "called ~1")
    expect_balance("closure_pointer")

    {
        var f = closure_returned()
        expect("closure_returned", "")
        f()
        ev("called")
    }
    expect("closure_returned end", "called ~1")
    expect_balance("closure_returned")

    move_to_pointer_target()
    expect("pointer_target", "~2 assigned ~1")
    expect_balance("pointer_target")

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
