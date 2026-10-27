// An expression `try` arm of type `!` (PANIC.md §3.2: it fits any arm
// type). `try f() catch => crash!()` is exactly what the unhandled-call
// fix-it and the constructor one write, so the two places below hold their
// text verbatim (`try ` before the call, ` catch => crash!()` after it):
// applying a fix-it must give code that compiles. Before the fix the arm's
// `void` call was put into the result slot, a C++ `static_cast` from `void`
// to `int`. Also a call of a user `-> !` function, a typed arm, and the
// jump arms (`return`, `break`, `continue`) beside them. The last `try`
// takes its `crash!` arm for real: the process dies of SIGABRT (134) with
// the message, after every other check passed (a failed check returns a
// small code instead).
import std::io::println

struct E { var n: i32 }

fn p(n: i32) panic(E) -> i32 {
    if n == 0 { panic E { n: 0 } }
    return n
}

fn stop() -> ! { crash!("stop ran") }

class C {
    pub var v: i32
    fn C(self) { self.v = try p(7) catch => crash!() }
}

fn fixit() -> i32 {
    var x = try p(5) catch => crash!()
    return x
}

fn user_never(n: i32) -> i32 { return try p(n) catch => stop() }

fn typed(n: i32) -> i32 { return try p(n) catch e: E => crash!("typed") }

fn leaves(n: i32) -> i32 {
    var v = try p(n) catch => return -1
    return v
}

fn loops() -> i32 {
    var sum = 0
    for var i = 3; i >= 0; i -= 1 {
        var v = try p(i - 1) catch => continue
        sum += v
    }
    var k = 4
    // Not `while true`: ControlFlowAnalysis does not see an arm's `break`
    // and calls the code after the loop unreachable (ticketed).
    while k > -5 {
        var v = try p(k) catch => break
        sum += v
        k -= 1
    }
    return sum
}

fn main() -> i32 {
    if fixit() != 5 { return 1 }
    var c = C()
    if c.v != 7 { return 2 }
    if user_never(3) != 3 { return 3 }
    if typed(4) != 4 { return 4 }
    if leaves(0) != -1 { return 5 }
    if leaves(6) != 6 { return 6 }
    if loops() != 12 { return 7 }
    println("checked")
    return try p(0) catch => crash!("arm ran")
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT: checked
// ERR: arm ran
