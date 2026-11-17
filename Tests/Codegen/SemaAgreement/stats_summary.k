// --print-stats includes the Sema agreement summary line, the one
// --sema-agreement-summary prints alone; given both, the line is printed
// once. Both test flags stay hidden from --help and are listed by
// --help-hidden.
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
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -fsema-agreement --print-stats -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=STATS
// STATS: kairo: sema agreement: 2 finding(s) in 1 of {{[0-9]+}} file(s) (callee 2)
//
// RUN: %kairo %s -w -fsema-agreement --print-stats --sema-agreement-summary -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=ONCE
// ONCE: kairo: sema agreement: 2 finding(s)
// ONCE-NOT: kairo: sema agreement:
//
// RUN: %kairo %s -fno-sema-agreement --print-stats -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF: kairo: sema agreement: off
//
// RUN: %kairo --help-hidden | %FileCheck %s --check-prefix=HIDDEN
// HIDDEN-DAG: --test-sema-agreement-no-adl
// HIDDEN-DAG: --sema-agreement-summary {{.*}}(--print-stats prints it too)
// RUN: %kairo --help | %FileCheck %s --check-prefix=HELP
// HELP-NOT: sema-agreement-summary
// HELP-NOT: test-sema-agreement-no-adl
