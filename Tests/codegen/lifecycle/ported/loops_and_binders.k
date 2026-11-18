// A loop's binder is an ordinary local of the iteration: over a generator's
// MOVE values it owns each value and destroys it when the iteration ends,
// or earlier when it is moved onward; a value a loop body builds is
// destroyed at the end of its iteration; a value moved out of in one
// iteration and rebuilt in the next is destroyed exactly once per rebuild
// (control-flow.mdx, loop binders; ownership.mdx, Destruction Order).
// A generator abandoned by `break` or `return` destroys the value it was
// holding and the locals of the generator body that are live.
// Cases from Rust tests/ui/drop/drop-in-for-loop-destructure,
// dropflag-reinit-in-loop, same-alloca-reassigned-match-binding-16151;
// moves/issue-75904-move-closure-loop.

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

fn gen(n: i32) -> yield R {
    for var i = 1; i <= n; i++ {
        yield R(i)
    }
}

fn gen_with_local(n: i32) -> yield R {
    var guard = R(100)
    for var i = 1; i <= n; i++ {
        yield R(i)
    }
    ev("gen-end")
}

fn eat(r: R) -> i32 { return r.id }

fn binder_destroyed_each_iteration() {
    for piece in gen(3) {
        ev(f"body{piece.id}")
    }
    ev("after")
}

fn binder_moved_onward() {
    var sum = 0
    for piece in gen(3) {
        sum += eat(piece)
        ev("body")
    }
    ev("after")
}

fn binder_moved_into_outer_variable() {
    var keep = R(50)
    for piece in gen(3) {
        keep = piece
    }
    ev("after")
}

fn binder_moved_into_vector() {
    var all: [R] = []
    for piece in gen(3) {
        all.push(piece)
    }
    ev("after")
    expect("binder_into_vector", "after")
}

fn break_destroys_current_binder() {
    for piece in gen(5) {
        if piece.id == 2 { break }
        ev(f"body{piece.id}")
    }
    ev("after")
}

fn return_destroys_current_binder() -> i32 {
    for piece in gen(5) {
        if piece.id == 2 { return piece.id }
    }
    return 0
}

fn generator_local_runs_to_end() {
    for piece in gen_with_local(2) {
        ev(f"body{piece.id}")
    }
    ev("after")
}

fn generator_local_on_break() {
    for piece in gen_with_local(5) {
        if piece.id == 1 { break }
    }
    ev("after")
}

fn body_local_each_iteration() {
    for i in 0..3 {
        var r = R(i + 1)
        ev(f"body{i}")
    }
    ev("after")
}

fn body_value_moved_out_each_iteration() {
    for i in 0..3 {
        var r = R(i + 1)
        eat(r)
    }
    ev("after")
}

fn moved_in_first_iteration_rebuilt() {
    var r = R(1)
    for i in 0..3 {
        eat(r)
        r = R(i + 10)
    }
    ev("after")
}

fn while_loop_value_rebuilt() {
    var n = 0
    var r = R(1)
    while n < 2 {
        eat(r)
        n += 1
        r = R(n + 1)
    }
    ev("after")
}

fn nested_loops_binders() {
    for a in gen(2) {
        for b in gen(2) {
            ev(f"{a.id}{b.id}")
        }
        ev("inner-done")
    }
    ev("after")
}

fn main() -> i32 {
    binder_destroyed_each_iteration()
    expect("binder_each_iteration", "body1 ~1 body2 ~2 body3 ~3 after")
    expect_balance("binder_each_iteration")

    binder_moved_onward()
    expect("binder_moved_onward", "~1 body ~2 body ~3 body after")
    expect_balance("binder_moved_onward")

    binder_moved_into_outer_variable()
    expect("binder_into_outer", "~50 ~1 ~2 after ~3")
    expect_balance("binder_into_outer")

    binder_moved_into_vector()
    log = ""
    expect_balance("binder_into_vector")

    break_destroys_current_binder()
    expect("break_binder", "body1 ~1 ~2 after")
    expect_balance("break_binder")

    return_destroys_current_binder()
    expect("return_binder", "~1 ~2")
    expect_balance("return_binder")

    generator_local_runs_to_end()
    expect("generator_local", "body1 ~1 body2 ~2 gen-end ~100 after")
    expect_balance("generator_local")

    generator_local_on_break()
    expect("generator_local_break", "~1 ~100 after")
    expect_balance("generator_local_break")

    body_local_each_iteration()
    expect("body_local", "body0 ~1 body1 ~2 body2 ~3 after")
    expect_balance("body_local")

    body_value_moved_out_each_iteration()
    expect("body_moved", "~1 ~2 ~3 after")
    expect_balance("body_moved")

    moved_in_first_iteration_rebuilt()
    expect("rebuilt", "~1 ~10 ~11 after ~12")
    expect_balance("rebuilt")

    while_loop_value_rebuilt()
    expect("while_rebuilt", "~1 ~2 after ~3")
    expect_balance("while_rebuilt")

    nested_loops_binders()
    expect("nested_binders", "11 ~1 12 ~2 inner-done ~1 21 ~1 22 ~2 inner-done ~2 after")
    expect_balance("nested_binders")

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
