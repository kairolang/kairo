// Locals are destroyed at the end of their enclosing scope in reverse
// declaration order, and a block's closing brace ends the block's own locals
// (ownership.mdx, Destruction Order; control-flow.mdx, Blocks). Every body of
// `if`, `match`, `for`, `while`, `loop` and `try` is such a block, and in a
// loop the locals of the body end with every iteration. A standalone
// `finally` runs in the same reverse order as the locals around it
// (control-flow.mdx, Standalone finally). Each object is destroyed exactly
// once: the move-aware handle below counts a live release per object.
// Cases from Rust tests/ui/drop/drop_order, drop-scope-exit,
// drop-on-empty-block-exit, struct-field-drop-order, or-pattern-drop-order.

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

class Pt { var n: i32 = 0 }

fn three_locals() {
    var a = R(1)
    var b = R(2)
    var c = R(3)
}

fn one_local() {
    var a = R(1)
}

fn no_locals_ever_declared() {
    var n = 3
}

fn nested_block() {
    var a = R(1)
    {
        var b = R(2)
        var c = R(3)
        ev("in")
    }
    ev("out")
    var d = R(4)
}

fn sibling_blocks() {
    {
        var a = R(1)
    }
    {
        var b = R(2)
        var c = R(3)
    }
    ev("end")
}

fn deeply_nested() {
    var a = R(1)
    {
        var b = R(2)
        {
            var c = R(3)
            {
                var d = R(4)
            }
            ev("c-level")
        }
        ev("b-level")
    }
    ev("a-level")
}

fn if_body(c: bool) {
    var a = R(1)
    if c {
        var b = R(2)
        ev("then")
    } else {
        var d = R(3)
        ev("else")
    }
    ev("after")
}

fn else_if_chain(x: i32) {
    if x == 0 {
        var a = R(10)
    } else if x == 1 {
        var b = R(11)
        var c = R(12)
    } else {
        var d = R(13)
    }
    ev("after")
}

fn for_body_each_iteration() {
    for i in 0..3 {
        var a = R(i + 1)
        var b = R(i + 11)
        ev("body")
    }
    ev("after")
}

fn while_body_each_iteration() {
    var n = 0
    while n < 2 {
        var a = R(n + 1)
        n += 1
    }
    ev("after")
}

fn loop_body_with_break() {
    var n = 0
    loop {
        var a = R(n + 1)
        n += 1
        if n == 2 { break }
    }
    ev("after")
}

fn c_style_for_init_variable() {
    for var r = R(1); r.id < 3; r.id += 1 {
        var a = R(r.id + 10)
    }
    ev("after")
}

fn match_arm_scope(x: i32) {
    match x {
        case 0 {
            var a = R(1)
            var b = R(2)
        }
        default {
            var c = R(3)
        }
    }
    ev("after")
}

fn try_body_scope() {
    try {
        var a = R(1)
        var b = R(2)
    } catch {
        ev("caught")
    }
    ev("after")
}

fn standalone_finally_with_locals() {
    var a = R(1)
    finally { ev("f1") }
    var b = R(2)
    finally { ev("f2") }
    var c = R(3)
    ev("body")
}

fn standalone_finally_in_block() {
    var a = R(1)
    {
        var b = R(2)
        finally { ev("inner") }
    }
    ev("after-block")
}

fn standalone_finally_in_loop() {
    for i in 0..2 {
        finally { ev("iter-end") }
        var a = R(i + 1)
    }
    ev("after")
}

fn value_computed_from_local() -> i32 {
    var a = R(7)
    var b = R(8)
    return a.id + b.id
}

fn temporary_return_object() -> R {
    var a = R(1)
    var b = R(2)
    return R(3)
}

fn local_returned_is_not_destroyed_here() -> R {
    var a = R(1)
    var b = R(2)
    return b
}

fn shadow_in_block() {
    var a = R(1)
    {
        var a = R(2)
        ev("inner-a")
    }
    ev("outer-a")
}

fn tuple_destructure_binders() {
    var (x, y, z) = (R(3), R(2), R(1))
    ev("bound")
}

fn match_binders(m: i32) {
    var t = (R(1), R(2))
    match m {
        case 0 {
            var (a, b) = t
            ev("in-arm")
        }
        default { ev("default") }
    }
    ev("after")
}

fn plain_values_have_no_events() {
    var p = Pt()
    var n = 5
    var s = "text"
    ev("done")
}

fn main() -> i32 {
    three_locals()
    expect("three_locals", "~3 ~2 ~1")
    expect_balance("three_locals")

    one_local()
    expect("one_local", "~1")

    no_locals_ever_declared()
    expect("no_locals_ever_declared", "")

    nested_block()
    expect("nested_block", "in ~3 ~2 out ~4 ~1")
    expect_balance("nested_block")

    sibling_blocks()
    expect("sibling_blocks", "~1 ~3 ~2 end")
    expect_balance("sibling_blocks")

    deeply_nested()
    expect("deeply_nested", "~4 c-level ~3 b-level ~2 a-level ~1")
    expect_balance("deeply_nested")

    if_body(true)
    expect("if_body_then", "then ~2 after ~1")
    if_body(false)
    expect("if_body_else", "else ~3 after ~1")
    expect_balance("if_body")

    else_if_chain(0)
    expect("else_if_0", "~10 after")
    else_if_chain(1)
    expect("else_if_1", "~12 ~11 after")
    else_if_chain(2)
    expect("else_if_2", "~13 after")
    expect_balance("else_if_chain")

    for_body_each_iteration()
    expect("for_body", "body ~11 ~1 body ~12 ~2 body ~13 ~3 after")
    expect_balance("for_body")

    while_body_each_iteration()
    expect("while_body", "~1 ~2 after")
    expect_balance("while_body")

    loop_body_with_break()
    expect("loop_body", "~1 ~2 after")
    expect_balance("loop_body")

    c_style_for_init_variable()
    expect("c_style_for", "~11 ~12 ~3 after")
    expect_balance("c_style_for")

    match_arm_scope(0)
    expect("match_arm_0", "~2 ~1 after")
    match_arm_scope(5)
    expect("match_arm_default", "~3 after")
    expect_balance("match_arm")

    try_body_scope()
    expect("try_body", "~2 ~1 after")
    expect_balance("try_body")

    standalone_finally_with_locals()
    expect("finally_locals", "body ~3 f2 ~2 f1 ~1")
    expect_balance("finally_locals")

    standalone_finally_in_block()
    expect("finally_block", "inner ~2 after-block ~1")
    expect_balance("finally_block")

    standalone_finally_in_loop()
    expect("finally_loop", "~1 iter-end ~2 iter-end after")
    expect_balance("finally_loop")

    var n = value_computed_from_local()
    expect("value_from_local", "~8 ~7")
    if n != 15 { println("FAIL value_from_local result"); fails += 1 }
    expect_balance("value_from_local")

    {
        var r = temporary_return_object()
        expect("temporary_return_object", "~2 ~1")
        ev("held")
    }
    expect("temporary_return_object end", "held ~3")
    expect_balance("temporary_return_object")

    {
        var r = local_returned_is_not_destroyed_here()
        expect("local_returned", "~1")
    }
    expect("local_returned end", "~2")
    expect_balance("local_returned")

    shadow_in_block()
    expect("shadow", "inner-a ~2 outer-a ~1")
    expect_balance("shadow")

    tuple_destructure_binders()
    expect("tuple_binders", "bound ~1 ~2 ~3")
    expect_balance("tuple_binders")

    match_binders(0)
    expect("match_binders", "in-arm ~2 ~1 after")
    match_binders(1)
    expect("match_binders default", "default after ~2 ~1")
    expect_balance("match_binders")

    plain_values_have_no_events()
    expect("plain_values", "done")

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
