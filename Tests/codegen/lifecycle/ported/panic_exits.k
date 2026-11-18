// A panic is a return, so it destroys the locals of every scope it leaves,
// innermost first in reverse declaration order, each exactly once
// (panic.mdx, Finally: a scope-exit block runs when control leaves the block,
// "however it leaves ... or a panic"; Codegen: a panic is a tagged return
// value checked with a branch, there is no unwinding). The locals of a `try`
// body are gone before a `catch` arm runs; a value in flight is not
// destroyed twice, and a panic raised inside a catch arm leaves the arm's
// own locals. Panics never come from a constructor or destructor
// (classes-lifecycle.mdx).
// Cases from Rust tests/ui/drop/drop-once-on-panic, enum-destructor-on-unwind,
// move-closure-drop-on-unwind, issue-23338-ensure-param-drop-order,
// dynamic-drop; panics inside destructors (panic-during-drop-14875,
// panic-in-drop-during-assignment) are not ported: no destructor can panic in
// Kairo.

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

struct Bad { var n: i32 }
struct Worse { var n: i32 }

fn may_panic(x: i32) panic(Bad) -> i32 {
    if x < 0 { panic Bad { n: x } }
    return x
}

fn two_kinds(x: i32) panic(Bad, Worse) -> i32 {
    if x < 0 { panic Bad { n: x } }
    if x > 100 { panic Worse { n: x } }
    return x
}

fn direct_panic(x: i32) panic(Bad) -> i32 {
    var a = R(1)
    var b = R(2)
    if x < 0 { panic Bad { n: x } }
    var c = R(3)
    return x
}

fn through_two_frames(x: i32) panic(Bad) -> i32 {
    var a = R(10)
    var v = direct_panic(x)
    var b = R(11)
    return v
}

fn panic_in_nested_block(x: i32) panic(Bad) -> i32 {
    var a = R(1)
    {
        var b = R(2)
        {
            var c = R(3)
            may_panic(x)
        }
    }
    return 0
}

fn panic_in_loop(x: i32) panic(Bad) -> i32 {
    var a = R(1)
    for i in 0..4 {
        var b = R(i + 10)
        may_panic(if i == x => 0 - 1 else => 0)
    }
    return 0
}

fn panic_in_argument(x: i32) panic(Bad) -> i32 {
    var a = R(1)
    return use_two(R(2), may_panic(x))
}

fn use_two(r: R, n: i32) -> i32 { return r.id + n }

fn caught_in_place(x: i32) -> i32 {
    var a = R(1)
    try {
        var b = R(2)
        may_panic(x)
        var c = R(3)
    } catch e: Bad {
        ev("caught")
    }
    ev("after")
    return 0
}

fn locals_of_try_gone_before_catch(x: i32) -> i32 {
    var a = R(1)
    try {
        var b = R(2)
        var c = R(3)
        may_panic(x)
    } catch e: Bad {
        ev(f"catch{e.n}")
        var d = R(4)
        ev("in-catch")
    }
    ev("after")
    return 0
}

fn catch_by_type(x: i32) -> i32 {
    var a = R(1)
    try {
        var b = R(2)
        two_kinds(x)
    } catch e: Bad {
        ev("bad")
    } catch e: Worse {
        ev("worse")
    }
    ev("after")
    return 0
}

fn catch_all(x: i32) {
    try {
        var b = R(2)
        two_kinds(x)
    } catch {
        ev("any")
    }
    ev("after")
}

fn partial_handler(x: i32) panic(Worse) -> i32 {
    var a = R(1)
    try {
        var b = R(2)
        two_kinds(x)
    } catch e: Bad {
        ev("bad")
    }
    ev("after")
    return 0
}

fn panic_inside_catch(x: i32) panic(Worse) -> i32 {
    var a = R(1)
    try {
        var b = R(2)
        may_panic(x)
    } catch e: Bad {
        var c = R(3)
        panic Worse { n: 1 }
    }
    return 0
}

fn try_expression(x: i32) -> i32 {
    var a = R(1)
    var v = try may_panic(x) catch e: Bad => 0 - 1
    ev(f"v{v}")
    return v
}

fn return_inside_try(x: i32) -> i32 {
    var a = R(1)
    try {
        var b = R(2)
        may_panic(x)
        return 5
    } catch e: Bad {
        return 6
    }
}

fn loop_with_catch() {
    for i in 0..3 {
        var a = R(i + 1)
        try {
            var b = R(i + 10)
            may_panic(i - 1)
        } catch e: Bad {
            ev("caught")
        }
    }
}

fn catch_in_caller(x: i32) -> i32 {
    var a = R(100)
    try {
        return through_two_frames(x)
    } catch e: Bad {
        ev("caught")
        return -1
    }
}

fn consumer(r: R) panic(Bad) -> i32 {
    var local = R(2)
    return may_panic(0 - 1)
}

fn finally_on_panic(x: i32) panic(Bad) -> i32 {
    var a = R(1)
    finally { ev("fin") }
    var b = R(2)
    may_panic(x)
    return 0
}

fn moved_value_in_flight(x: i32) panic(Bad) -> R {
    var a = R(1)
    var b = a
    may_panic(x)
    return b
}

fn main() -> i32 {
    try { direct_panic(-1) } catch e: Bad { ev("c") }
    expect("direct_panic", "~2 ~1 c")
    expect_balance("direct_panic")

    try { direct_panic(5) } catch e: Bad { ev("c") }
    expect("direct_panic ok", "~3 ~2 ~1")
    expect_balance("direct_panic ok")

    try { through_two_frames(-1) } catch e: Bad { ev("c") }
    expect("two_frames", "~2 ~1 ~10 c")
    expect_balance("two_frames")

    try { through_two_frames(3) } catch e: Bad { ev("c") }
    expect("two_frames ok", "~3 ~2 ~1 ~11 ~10")
    expect_balance("two_frames ok")

    try { panic_in_nested_block(-1) } catch e: Bad { ev("c") }
    expect("nested_block", "~3 ~2 ~1 c")
    expect_balance("nested_block")

    try { panic_in_loop(2) } catch e: Bad { ev("c") }
    expect("loop third iteration", "~10 ~11 ~12 ~1 c")
    expect_balance("loop third iteration")

    try { panic_in_loop(0) } catch e: Bad { ev("c") }
    expect("loop first iteration", "~10 ~1 c")
    expect_balance("loop first iteration")

    try { panic_in_loop(9) } catch e: Bad { ev("c") }
    expect("loop no panic", "~10 ~11 ~12 ~13 ~1")
    expect_balance("loop no panic")

    try { panic_in_argument(-1) } catch e: Bad { ev("c") }
    log = ""
    expect_balance("argument")

    caught_in_place(-1)
    expect("caught_in_place", "~2 caught after ~1")
    expect_balance("caught_in_place")
    caught_in_place(1)
    expect("caught_in_place ok", "~3 ~2 after ~1")
    expect_balance("caught_in_place ok")

    locals_of_try_gone_before_catch(-4)
    expect("try_locals_before_catch", "~3 ~2 catch-4 in-catch ~4 after ~1")
    expect_balance("try_locals_before_catch")

    catch_by_type(-1)
    expect("catch bad", "~2 bad after ~1")
    catch_by_type(500)
    expect("catch worse", "~2 worse after ~1")
    catch_by_type(7)
    expect("catch none", "~2 after ~1")
    expect_balance("catch_by_type")

    catch_all(-1)
    expect("catch_all", "~2 any after")
    catch_all(1)
    expect("catch_all ok", "~2 after")
    expect_balance("catch_all")

    try { partial_handler(-1) } catch e: Worse { ev("w") }
    expect("partial bad", "~2 bad after ~1")
    try { partial_handler(900) } catch e: Worse { ev("w") }
    expect("partial worse", "~2 ~1 w")
    expect_balance("partial_handler")

    try { panic_inside_catch(-1) } catch e: Worse { ev("w") }
    expect("panic_inside_catch", "~2 ~3 ~1 w")
    expect_balance("panic_inside_catch")

    try_expression(-3)
    expect("try_expression", "v-1 ~1")
    try_expression(3)
    expect("try_expression ok", "v3 ~1")
    expect_balance("try_expression")

    return_inside_try(1)
    expect("return_in_try", "~2 ~1")
    return_inside_try(-1)
    expect("return_in_try panic", "~2 ~1")
    expect_balance("return_in_try")

    loop_with_catch()
    expect("loop_with_catch", "~10 caught ~1 ~11 ~2 ~12 ~3")
    expect_balance("loop_with_catch")

    catch_in_caller(-1)
    expect("catch_in_caller", "~2 ~1 ~10 caught ~100")
    expect_balance("catch_in_caller")

    try { consumer(R(1)) } catch e: Bad { ev("c") }
    expect("param on panic", "~2 ~1 c")
    expect_balance("param on panic")

    try { finally_on_panic(-1) } catch e: Bad { ev("c") }
    expect("finally_on_panic", "~2 fin ~1 c")
    expect_balance("finally_on_panic")

    try { var r = moved_value_in_flight(-1) } catch e: Bad { ev("c") }
    expect("moved_in_flight", "~1 c")
    expect_balance("moved_in_flight")

    try {
        var r = moved_value_in_flight(1)
        ev("got")
    } catch e: Bad { ev("c") }
    expect("moved_in_flight ok", "got ~1")
    expect_balance("moved_in_flight ok")

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
