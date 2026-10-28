// The crash path under a SIGABRT handler the program installed (PANIC.md
// §2.8, "the crash path"): rt/crash.c puts SIGABRT back to SIG_DFL, and
// unblocks it, before abort(), so the handler -- which would run code on
// the state that just failed -- never runs. If it ran the process would
// _exit(7). The process dies of SIGABRT (134) with the
// message exactly as given, and nothing after the crash runs. The message
// here is a runtime `string`, not a literal: crash_with reads its data
// pointer and length once and the runtime writes those bytes as they are.
// It is a LOCAL named in the macro's argument: EmitIR once spelled such a
// name from the expansion record's index, and `why` came out as `io`.

ffi "c" import "signal.h"
ffi "c" import "unistd.h"

import std::io::println

ffi "c" fn on_abort(sig: i32) {
    _exit(7)
}

fn reason(n: i32) -> string {
    if n > 0 { return "a runtime reason" }
    return "zero"
}

fn main() -> i32 {
    unsafe { signal(6, on_abort) }      // SIGABRT: a C macro, which an import does not bring
    println("before")
    var why = reason(1)                 // not inline: an integer literal in a builtin macro's argument is SC073E (ticketed)
    crash!(why)
    println("after")
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT:      before
// OUT-NOT:  after
// ERR:      a runtime reason
