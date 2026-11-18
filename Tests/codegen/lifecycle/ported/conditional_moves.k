// A value moved on some paths and not on others is destroyed exactly once on
// every path: by its new owner on the paths that moved it, by its own scope
// on the others (the compiler tracks which bindings are live on each path:
// ownership.mdx, Moved-From State). That covers a move in one arm of an
// `if` or `match`, in a loop body, in a short-circuit operand, before an
// early return, a value reassigned after the move, and a value moved in one
// iteration and rebuilt in the next.
// Cases from Rust tests/ui/drop/conditional-drop-10734, dynamic-drop,
// dropflag-reinit-in-loop, drop-once-on-move, drop-on-untaken-arm,
// same-alloca-reassigned-match-binding-16151.

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
    fn Holder(self, r: R) { self.r = r }
}

fn eat(r: R) { ev("eat") }
fn flip(c: bool) -> bool { return c }

fn moved_in_then(c: bool) {
    var a = R(1)
    if c { eat(a) }
    ev("end")
}

fn moved_in_else(c: bool) {
    var a = R(1)
    if c { ev("then") } else { eat(a) }
    ev("end")
}

fn moved_in_both(c: bool) {
    var a = R(1)
    if c { eat(a) } else { var b = a }
    ev("end")
}

fn moved_in_neither(c: bool) {
    var a = R(1)
    if c { ev("t") } else { ev("e") }
    ev("end")
}

fn moved_in_else_if(x: i32) {
    var a = R(1)
    if x == 0 {
        ev("zero")
    } else if x == 1 {
        eat(a)
    } else {
        ev("other")
    }
    ev("end")
}

fn moved_in_match(x: i32) {
    var a = R(1)
    match x {
        case 0 { eat(a) }
        case 1 { ev("one") }
        default { var h = Holder(a) }
    }
    ev("end")
}

fn moved_in_match_value(x: i32) -> i32 {
    var a = R(1)
    var r = match x {
        case 0 => use_it(a)
        default => 5
    }
    ev("end")
    return r
}

fn use_it(r: R) -> i32 { return r.id }

fn moved_before_early_return(c: bool) -> i32 {
    var a = R(1)
    var b = R(2)
    if c {
        eat(a)
        return 1
    }
    return 2
}

fn moved_in_and_operand(c: bool) -> bool {
    var a = R(1)
    var r = c && take_true(a)
    ev("end")
    return r
}

fn take_true(r: R) -> bool { return true }

fn moved_in_or_operand(c: bool) -> bool {
    var a = R(1)
    var r = c || take_true(a)
    ev("end")
    return r
}

fn moved_in_loop_with_break(stop: i32) {
    var a = R(1)
    for i in 0..4 {
        if i == stop {
            eat(a)
            break
        }
    }
    ev("end")
}

fn moved_in_loop_then_return(stop: i32) {
    var a = R(1)
    for i in 0..4 {
        if i == stop {
            eat(a)
            return
        }
    }
    ev("end")
}

fn rebuilt_each_iteration() {
    var a = R(1)
    for i in 0..3 {
        eat(a)
        a = R(i + 2)
    }
    ev("end")
}

fn rebuilt_only_sometimes(c: bool) {
    var a = R(1)
    eat(a)
    if c { a = R(2) }
    ev("end")
}

fn moved_then_rebuilt_in_both_arms(c: bool) {
    var a = R(1)
    eat(a)
    if c { a = R(2) } else { a = R(3) }
    ev("end")
}

fn two_values_one_moved(c: bool) {
    var a = R(1)
    var b = R(2)
    if c { eat(a) } else { eat(b) }
    ev("end")
}

fn moved_into_holder_in_branch(c: bool) {
    var a = R(1)
    var h: Holder? = null
    if c { h = Holder(a) }
    ev("end")
}

fn moved_in_nested_branches(c: bool, d: bool) {
    var a = R(1)
    if c {
        if d { eat(a) }
    }
    ev("end")
}

fn moved_in_try_body(x: i32) {
    var a = R(1)
    try {
        if x == 0 { eat(a) }
    } catch {
        ev("caught")
    }
    ev("end")
}

fn moved_declared_in_loop_body() {
    for i in 0..3 {
        var a = R(i + 1)
        if i == 1 { eat(a) }
    }
    ev("end")
}

fn main() -> i32 {
    moved_in_then(true)
    expect("then moved", "eat ~1 end")
    moved_in_then(false)
    expect("then not moved", "end ~1")
    expect_balance("moved_in_then")

    moved_in_else(true)
    expect("else not moved", "then end ~1")
    moved_in_else(false)
    expect("else moved", "eat ~1 end")
    expect_balance("moved_in_else")

    moved_in_both(true)
    expect("both true", "eat ~1 end")
    moved_in_both(false)
    expect("both false", "~1 end")
    expect_balance("moved_in_both")

    moved_in_neither(true)
    expect("neither true", "t end ~1")
    moved_in_neither(false)
    expect("neither false", "e end ~1")
    expect_balance("moved_in_neither")

    moved_in_else_if(0)
    expect("else_if 0", "zero end ~1")
    moved_in_else_if(1)
    expect("else_if 1", "eat ~1 end")
    moved_in_else_if(2)
    expect("else_if 2", "other end ~1")
    expect_balance("moved_in_else_if")

    moved_in_match(0)
    expect("match 0", "eat ~1 end")
    moved_in_match(1)
    expect("match 1", "one end ~1")
    moved_in_match(2)
    expect("match 2", "~1 end")
    expect_balance("moved_in_match")

    moved_in_match_value(0)
    expect("match value 0", "~1 end")
    moved_in_match_value(1)
    expect("match value 1", "end ~1")
    expect_balance("moved_in_match_value")

    moved_before_early_return(true)
    expect("early moved", "eat ~1 ~2")
    moved_before_early_return(false)
    expect("early not moved", "~2 ~1")
    expect_balance("moved_before_early_return")

    moved_in_and_operand(true)
    expect("and true", "~1 end")
    moved_in_and_operand(false)
    expect("and false", "end ~1")
    expect_balance("moved_in_and_operand")

    moved_in_or_operand(true)
    expect("or true", "end ~1")
    moved_in_or_operand(false)
    expect("or false", "~1 end")
    expect_balance("moved_in_or_operand")

    moved_in_loop_with_break(2)
    expect("loop break", "eat ~1 end")
    moved_in_loop_with_break(9)
    expect("loop no move", "end ~1")
    expect_balance("moved_in_loop_with_break")

    moved_in_loop_then_return(1)
    expect("loop return", "eat ~1")
    moved_in_loop_then_return(9)
    expect("loop return not taken", "end ~1")
    expect_balance("moved_in_loop_then_return")

    rebuilt_each_iteration()
    expect("rebuilt", "eat ~1 eat ~2 eat ~3 end ~4")
    expect_balance("rebuilt_each_iteration")

    rebuilt_only_sometimes(true)
    expect("rebuilt true", "eat ~1 end ~2")
    rebuilt_only_sometimes(false)
    expect("rebuilt false", "eat ~1 end")
    expect_balance("rebuilt_only_sometimes")

    moved_then_rebuilt_in_both_arms(true)
    expect("both arms true", "eat ~1 end ~2")
    moved_then_rebuilt_in_both_arms(false)
    expect("both arms false", "eat ~1 end ~3")
    expect_balance("both arms rebuilt")

    two_values_one_moved(true)
    expect("two true", "eat ~1 end ~2")
    two_values_one_moved(false)
    expect("two false", "eat ~2 end ~1")
    expect_balance("two_values_one_moved")

    moved_into_holder_in_branch(true)
    expect("holder true", "end ~1")
    moved_into_holder_in_branch(false)
    expect("holder false", "end ~1")
    expect_balance("moved_into_holder_in_branch")

    moved_in_nested_branches(true, true)
    expect("nested tt", "eat ~1 end")
    moved_in_nested_branches(true, false)
    expect("nested tf", "end ~1")
    moved_in_nested_branches(false, true)
    expect("nested ft", "end ~1")
    expect_balance("moved_in_nested_branches")

    moved_in_try_body(0)
    expect("try moved", "eat ~1 end")
    moved_in_try_body(1)
    expect("try not moved", "end ~1")
    expect_balance("moved_in_try_body")

    moved_declared_in_loop_body()
    expect("loop body local", "~1 eat ~2 ~3 end")
    expect_balance("moved_declared_in_loop_body")

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
