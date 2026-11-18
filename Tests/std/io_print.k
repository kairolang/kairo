// std::io's print family (Lib/std/io.k): print, println, eprint, eprintln,
// flush. Each is one string, written in full before the call returns --
// nothing in std::io buffers -- so stdout and stderr interleave in call
// order under 2>&1 (MIX), each stream alone holds exactly its own bytes
// (OUT, ERR), and a line longer than the one-write stack page still ends in
// exactly one newline.
//
// flush is for the boundary with C stdio: printf's bytes sit in stdio's
// buffer (a pipe or file is block-buffered) and would come out at exit,
// AFTER everything std::io wrote, unless flushed. The "c-before" line proves
// flush drains them in place.

ffi "c" import "stdio.h"

import std::io

fn main() -> i32 {
    io::print("a")
    io::print("b")
    io::println("c")
    io::eprint("e1 ")
    io::eprintln("e2")
    io::println("")
    var n: i32 = 3
    io::print(f"n={n}\n")
    io::eprintln(f"err n={n}")

    unsafe { printf("c-before\n") }
    io::flush()
    io::println("after-flush")

    var big: string = ""
    for var i: i32 = 0; i < 5000; ++i { big.push_back(120) }
    io::eprintln(big)
    io::println("end")
    return 7
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 7
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// RUN: %t.exe > %t.mix 2>&1 || true
// RUN: %FileCheck %s --check-prefix=MIX --match-full-lines < %t.mix
//
// OUT:      abc
// OUT-EMPTY:
// OUT-NEXT: n=3
// OUT-NEXT: c-before
// OUT-NEXT: after-flush
// OUT-NEXT: end
// OUT-NOT:  {{.}}
//
// ERR:      e1 e2
// ERR-NEXT: err n=3
// ERR-NEXT: {{(x{250}){20}$}}
// ERR-NOT:  {{.}}
//
// MIX:      abc
// MIX-NEXT: e1 e2
// MIX-EMPTY:
// MIX-NEXT: n=3
// MIX-NEXT: err n=3
// MIX-NEXT: c-before
// MIX-NEXT: after-flush
// MIX-NEXT: {{(x{250}){20}$}}
// MIX-NEXT: end
