// A failed `assert` with a message that is not a literal evaluates it, once,
// in the failing branch only, and prints it after the location and the
// condition as written; the process exits with status 134. While the
// condition holds the message is never evaluated.

import std::io::println

var calls: i32 = 0

fn why(v: i32) -> string {
    calls += 1
    return f"v is {v}"
}

fn check(v: i32, const note: string) {
    assert v > -20, note
    assert v > -10, why(v)
    assert v > -30, "v " + note
}

fn <T> tag(x: T, const note: string) {
    assert sizeof(T) == 4, note
}

fn main() -> i32 {
    check(5, "unused")
    tag(1 as i32, "unused")
    println(f"calls {calls}")
    println("before")
    check(-15, "never printed")
    println("not reached")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR < %t.err
// OUT: calls 0
// OUT-NEXT: before
// OUT-NOT: not reached
// ERR: kairo: assertion failed at {{.*}}assert_message_eval_run.k:17:5: assert v > -10: v is -15
// ERR-NOT: assertion failed
