// --sema-agreement-summary: one line counting what the Sema agreement pass
// found in the build, for a build that passes -w (which hides I012W) or
// runs a compiler that only counts. The count includes a TU whose object
// was reused.
//
// The hidden --test-sema-agreement-swap=chosen:other tells the pass that
// Kairo bound every call of `chosen` to `other`.

import std::io::println

fn chosen(x: i32) -> i32 { return x + 1 }
fn other(x: i32) -> i32 { return x + 100 }

fn main() -> i32 {
    println(f"{chosen(1)} {chosen(2)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
//
// Hidden by -w, counted; the same from the cache.
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -fsema-agreement --sema-agreement-summary -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=TWO
// RUN: %kairo %s -w -fsema-agreement --sema-agreement-summary -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=TWO
// TWO-NOT: I012W
// TWO: kairo: sema agreement: 2 finding(s) in 1 of {{[0-9]+}} file(s) (callee 2)
// TWO-NOT: I012W
//
// A compiler that only counts says the line and nothing else.
// RUN: rm -rf %t.d
// RUN: %kairo %s --test-sema-agreement-quiet --sema-agreement-summary -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=TWO
// RUN: %kairo %s --test-sema-agreement-quiet --sema-agreement-summary -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=TWO
//
// Nothing found; the pass off; the flag not given.
// RUN: %kairo %s -fsema-agreement --sema-agreement-summary -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=NONE
// NONE: kairo: sema agreement: 0 finding(s) in 0 of {{[0-9]+}} file(s){{$}}
// RUN: %kairo %s -fno-sema-agreement --sema-agreement-summary -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF: kairo: sema agreement: off
// RUN: %kairo %s -w -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// QUIET-NOT: sema agreement
//
// Not in --help.
// RUN: %kairo --help | %FileCheck %s --check-prefix=HELP
// HELP-NOT: sema-agreement-summary
