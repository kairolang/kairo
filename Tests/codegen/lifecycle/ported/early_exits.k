// A destructor runs on every way out of its scope: `return`, `break`,
// `continue` and a labeled `break` destroy the locals of every scope they
// leave, innermost first and in reverse declaration order, and nothing of the
// scopes they stay in (classes-lifecycle.mdx, Destructors: "a destructor
// runs on every exit"; control-flow.mdx, Standalone finally: normal exit,
// `return`, `break`, `continue`, or a panic). A local declared after the exit
// was never constructed and is not destroyed.
// Cases from Rust tests/ui/drop/drop-on-ret, drop-scope-exit,
// drop-on-untaken-arm, nested-return-drop-order, dropflag-reinit-in-loop.

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

fn return_flat(c: bool) -> i32 {
    var a = R(1)
    var b = R(2)
    if c { return 1 }
    var d = R(3)
    return 2
}

fn return_in_nested_block() -> i32 {
    var a = R(1)
    {
        var b = R(2)
        {
            var c = R(3)
            return 7
        }
    }
    return 0
}

fn return_value_uses_locals() -> i32 {
    var a = R(4)
    var b = R(5)
    return a.id * 10 + b.id
}

fn return_in_loop() -> i32 {
    var a = R(1)
    for i in 0..5 {
        var b = R(i + 10)
        if i == 2 { return i }
    }
    return -1
}

fn break_leaves_body_locals() {
    var a = R(1)
    for i in 0..5 {
        var b = R(i + 10)
        var c = R(i + 20)
        if i == 1 { break }
    }
    ev("after")
}

fn continue_leaves_body_locals() {
    var a = R(1)
    for i in 0..3 {
        var b = R(i + 10)
        if i == 1 { continue }
        var c = R(i + 20)
    }
    ev("after")
}

fn nested_loops_break_inner() {
    for i in 0..2 {
        var o = R(i + 1)
        for j in 0..3 {
            var inn = R(i * 10 + j + 100)
            if j == 1 { break }
        }
        ev("inner-done")
    }
}

fn labeled_break_outer() {
    var a = R(1)
    outer: for i in 0..3 {
        var b = R(i + 10)
        for j in 0..3 {
            var c = R(i * 10 + j + 100)
            if j == 1 { break outer }
        }
    }
    ev("after")
}

fn labeled_continue_outer() {
    outer: for i in 0..2 {
        var b = R(i + 10)
        for j in 0..3 {
            var c = R(i * 10 + j + 100)
            if j == 0 { continue outer }
        }
    }
    ev("after")
}

fn while_break() {
    var n = 0
    while true {
        var a = R(n + 1)
        n += 1
        if n == 2 { break }
    }
    ev("after")
}

fn loop_continue_counted() {
    var n = 0
    while n < 3 {
        n += 1
        var a = R(n)
        if n % 2 == 1 { continue }
        ev("even")
    }
}

fn match_arm_return(x: i32) -> i32 {
    var a = R(1)
    match x {
        case 0 {
            var b = R(2)
            return 0
        }
        default {
            var c = R(3)
        }
    }
    return 1
}

fn exit_before_declaration(c: bool) -> i32 {
    if c { return 0 }
    var a = R(1)
    return 1
}

fn exit_between_declarations(c: bool) -> i32 {
    var a = R(1)
    if c { return 0 }
    var b = R(2)
    return 1
}

fn finally_on_every_exit(c: bool) -> i32 {
    var a = R(1)
    finally { ev("f") }
    if c { return 0 }
    var b = R(2)
    return 1
}

fn early_return_with_temporaries() -> i32 {
    var a = R(1)
    if a.id == 1 { return R(5).id }
    return 0
}

fn main() -> i32 {
    return_flat(true)
    expect("return_flat early", "~2 ~1")
    return_flat(false)
    expect("return_flat late", "~3 ~2 ~1")
    expect_balance("return_flat")

    return_in_nested_block()
    expect("return_nested", "~3 ~2 ~1")
    expect_balance("return_nested")

    var v = return_value_uses_locals()
    expect("return_value", "~5 ~4")
    if v != 45 { println("FAIL return_value result"); fails += 1 }
    expect_balance("return_value")

    return_in_loop()
    expect("return_in_loop", "~10 ~11 ~12 ~1")
    expect_balance("return_in_loop")

    break_leaves_body_locals()
    expect("break", "~20 ~10 ~21 ~11 after ~1")
    expect_balance("break")

    continue_leaves_body_locals()
    expect("continue", "~20 ~10 ~11 ~22 ~12 after ~1")
    expect_balance("continue")

    nested_loops_break_inner()
    expect("nested_break", "~100 ~101 inner-done ~1 ~110 ~111 inner-done ~2")
    expect_balance("nested_break")

    labeled_break_outer()
    expect("labeled_break", "~100 ~101 ~10 after ~1")
    expect_balance("labeled_break")

    labeled_continue_outer()
    expect("labeled_continue", "~100 ~10 ~110 ~11 after")
    expect_balance("labeled_continue")

    while_break()
    expect("while_break", "~1 ~2 after")
    expect_balance("while_break")

    loop_continue_counted()
    expect("loop_continue", "~1 even ~2 ~3")
    expect_balance("loop_continue")

    match_arm_return(0)
    expect("match_return", "~2 ~1")
    match_arm_return(1)
    expect("match_fallthrough", "~3 ~1")
    expect_balance("match_return")

    exit_before_declaration(true)
    expect("exit_before", "")
    exit_before_declaration(false)
    expect("exit_before late", "~1")
    expect_balance("exit_before")

    exit_between_declarations(true)
    expect("exit_between early", "~1")
    exit_between_declarations(false)
    expect("exit_between late", "~2 ~1")
    expect_balance("exit_between")

    finally_on_every_exit(true)
    expect("finally early", "f ~1")
    finally_on_every_exit(false)
    expect("finally late", "~2 f ~1")
    expect_balance("finally_on_every_exit")

    early_return_with_temporaries()
    log = ""
    expect_balance("early_return_temporaries")

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
