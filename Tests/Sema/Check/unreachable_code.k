// ControlFlowAnalysis: SC003W on a statement that can never run because
// everything before it in its block ends the path. One warning per region,
// at its first statement; the fix-it deletes the region (with its `;`); a
// note names the statement that ended the path. Every `ok_*` function must
// stay silent (--implicit-check-not); every `dead_*` has one warning per
// region.

enum Color { Red, Green, Blue }

fn stop() -> ! { loop { } }

fn sink(x: i32) { }

// --- a transfer statement ---------------------------------------------------

fn dead_after_return() -> i32 {
    return 1;
    sink(2);
    sink(3);
}
// CHECK: unreachable_code.k:[[@LINE-3]]:5: warning [SC003W]: unreachable code; the statement above always transfers control out of this block
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-4]]:5-[[@LINE-3]]:13}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-6]]:5: note [I900N]: any code after this 'return' is never run

fn dead_after_panic() -> i32 {
    panic "boom";
    return 6;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: any code after this 'panic' is never run

fn dead_in_loop() {
    for var i: i32 = 0; i < 3; ++i {
        if i == 1 { continue; sink(i); }
// CHECK: unreachable_code.k:[[@LINE-1]]:31: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-2]]:31-[[@LINE-2]]:39}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-3]]:21: note [I900N]: any code after this 'continue' is never run
        break;
        sink(i);
// CHECK: unreachable_code.k:[[@LINE-1]]:9: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-2]]:9-[[@LINE-2]]:17}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-4]]:9: note [I900N]: any code after this 'break' is never run
    }
}

// --- a `-> !` call ----------------------------------------------------------

fn dead_after_never_call() -> i32 {
    stop();
    return 2;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: this call never returns (its type is '!'), so any code after it is never run

// The builtin the `unwrap!` lowering calls is an ordinary `-> !` function.
fn dead_after_unwrap_failed() -> i32 {
    unwrap_failed(&null, 0);
    return 7;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: this call never returns

// A generic body: the call does not depend on T, so every instance stops.
fn <T> dead_generic(x: T) -> i32 {
    stop();
    return 1;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: this call never returns

// --- compound statements that never complete --------------------------------

fn dead_after_if_both(c: bool) -> i32 {
    if c { return 1; } else { return 2; }
    return 3;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: every branch of this 'if' leaves the block, so any code after it is never run

fn dead_after_match(c: Color) -> i32 {
    match c {
        case Color::Red { return 1; }
        case Color::Green { return 2; }
        case Color::Blue { return 3; }
    }
    return 4;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-9]]:5: note [I900N]: every arm of this 'match' leaves the block, so any code after it is never run

fn dead_after_loop() -> i32 {
    loop { sink(1); }
    return 5;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: this loop never exits (no 'break' leaves it), so any code after it is never run

fn dead_after_while_true() -> i32 {
    while true { sink(1); }
    return 5;
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:14}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: this loop never exits

// --- one warning per region -------------------------------------------------

// The inner block's own dead `sink(2)` is inside the outer region: not
// reported a second time.
fn dead_nested() -> i32 {
    return 1;
    {
        sink(1);
        return 2;
        sink(2);
    }
}
// CHECK: unreachable_code.k:[[@LINE-6]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-7]]:5-[[@LINE-3]]:6}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-9]]:5: note [I900N]: any code after this 'return' is never run

// A closure written in dead code is dead with it: its own `sink(3)` is not
// a second warning.
fn dead_closure_in_region() -> i32 {
    return 1;
    var f = fn () -> i32 { return 2; sink(3); return 3; };
}
// CHECK: unreachable_code.k:[[@LINE-2]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-3]]:5-[[@LINE-3]]:59}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-5]]:5: note [I900N]: any code after this 'return' is never run

// --- labels -----------------------------------------------------------------
// `label!` / `jump!` are still SC116E (not yet supported); the warning runs
// on them all the same.

// The region stops at the label: the fix-it leaves `label!(top)` alone.
fn dead_then_label() -> i32 {
    jump!(top)
    sink(0)
    label!(top)
    return 2
}
// CHECK: unreachable_code.k:[[@LINE-4]]:5: warning [SC003W]
// CHECK-NEXT: fix-it:{{.*}}:{[[@LINE-5]]:5-[[@LINE-5]]:12}:""
// CHECK-NEXT: unreachable_code.k:[[@LINE-7]]:5: note [I900N]: any code after this 'jump!' is never run

fn ok_label_after_return(c: bool) -> i32 {
    var i: i32 = 0
    if c { jump!(top) }
    return 1
    label!(top)
    i += 1
    return i
}

// A label nested in what follows: control can arrive inside it.
fn ok_nested_label(c: bool) -> i32 {
    jump!(inner)
    if c {
        label!(inner)
        sink(1)
    }
    return 3
}

// --- never fires ------------------------------------------------------------

fn ok_loop_break() -> i32 {
    loop { break; }
    return 1;
}

fn ok_while_true_break(c: bool) -> i32 {
    while true { if c { break; } }
    return 1;
}

fn ok_if_one_arm(c: bool) -> i32 {
    if c { return 1; } else { sink(1); }
    return 2;
}

fn ok_if_no_else(c: bool) -> i32 {
    if c { return 1; }
    return 2;
}

// A `return` in a closure ends the closure, not the enclosing block.
fn ok_closure() -> i32 {
    var f = fn () -> i32 { return 1; };
    return f();
}

// A `-> !` body ends in its infinite loop; nothing follows it.
fn ok_never_body() -> ! {
    sink(1);
    loop { }
}

// A match that is not exhaustive is SC120E, not dead code after it.
fn ok_non_exhaustive(c: Color) -> i32 {
    match c {
        case Color::Red { return 1; }
    }
    return 2;
}
// CHECK: unreachable_code.k:[[@LINE-5]]:5: error [SC120E]

fn main() -> i32 { return 0; }

// --- lit wiring -------------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=SC003W
