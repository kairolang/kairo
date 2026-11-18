// `crash!` (PANIC.md §2.4), run for real: a plain Lib/builtin macro over
// `crash_with`, a `-> !` function that writes the message and a newline to
// stderr (rt/crash.c) and aborts. The process dies of SIGABRT (status 134)
// and nothing after the crash runs. crash_silent.k is `crash!()` with no
// message, which writes nothing.

import std::io::println

fn pick(x: i32) -> i32 {
    if x > 0 { return x }
    crash!("pick: x was not positive")
}

fn main() -> i32 {
    println("before")
    if pick(2) != 2 { return 1 }
    pick(0)
    println("after")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT:      before
// OUT-NOT:  after
// ERR:      pick: x was not positive
