// `crash!()` with no message (PANIC.md §2.4): crash_with's default empty
// string, so nothing reaches stderr, and the process still dies of SIGABRT
// (134) with nothing after it run. crash.k is the message form.

import std::io::println

fn main() -> i32 {
    println("before")
    crash!()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: test ! -s %t.err
// OUT: before
