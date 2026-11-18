// A free call clang bound to another function than the one Kairo chose is
// I012W, a warning: the compile goes on. The two have one type, so the call
// is pointed at Kairo's choice, and the program runs it.
//
// Clang does not confuse two Kairo functions that have one type, so the
// hidden --test-sema-agreement-swap=chosen:other tells the pass that Kairo
// bound every call of `chosen` to `other`.

import std::io::println

fn chosen(x: i32) -> i32 { return x + 1 }
fn other(x: i32) -> i32 { return x + 100 }

fn <T> generic(x: T) -> i32 { return chosen(2) }

fn main() -> i32 {
    println(f"{chosen(1)}")
    println(f"{generic(true)} {generic(1)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=WARN
// WARN-DAG: callee_free_repair.k:17:16: warning [I012W]: internal: clang resolved this call to '{{.*}}chosen(int)', but Kairo's Sema chose 'other'; this is a compiler bug
// WARN-DAG: callee_free_repair.k:14:38: warning [I012W]: internal: clang resolved this call to '{{.*}}chosen(int)', but Kairo's Sema chose 'other'
// WARN-DAG: callee_free_repair.k:12:4: note [I900N]: Kairo's Sema chose this declaration
// WARN-DAG: callee_free_repair.k:11:4: note [I900N]: clang resolved the call to this declaration
// WARN-NOT: error

// Kairo's choice ran, in the plain call and in both instances.
// RUN: %t.exe | %FileCheck %s --check-prefix=FIXED --match-full-lines
// FIXED:      101
// FIXED-NEXT: 102 102

// The pretty form says what was done about it.
// RUN: rm -rf %t.d
// RUN: %kairo_bin %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=LABEL
// LABEL: the call now goes to the declaration Kairo chose

// The warning is said on every build: such an object is not cached.
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=AGAIN
// AGAIN: warning [I012W]

// -fno-sema-agreement-repair reports and leaves clang's choice.
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other -fno-sema-agreement-repair 2>&1 | %FileCheck %s --check-prefix=REPORT
// REPORT: warning [I012W]
// RUN: %t.exe | %FileCheck %s --check-prefix=LEFT --match-full-lines
// LEFT:      2
// LEFT-NEXT: 3 3
// RUN: rm -rf %t.d
// RUN: %kairo_bin %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other -fno-sema-agreement-repair 2>&1 | %FileCheck %s --check-prefix=LEFTL
// LEFTL: left as clang resolved it (-fno-sema-agreement-repair)

// -fno-sema-agreement: no walk, no warning.
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other -fno-sema-agreement 2>&1 | %FileCheck %s --check-prefix=OFF --allow-empty
// OFF-NOT: I012W
