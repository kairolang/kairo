// Every word after a bare `--` goes to clang verbatim: Kairo's own cc1 line
// gets what clang's driver makes of it, a C/C++ input gets the word itself.
// Inputs after `--` stay inputs. Before, each such word was taken for an
// input and failed with U001E "input has no extension".

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args -- -ftls-model=initial-exec | %FileCheck %s --check-prefix=CC1
// CC1: clang -cc1
// CC1-SAME: -ftls-model=initial-exec
// A driver-only spelling reaches cc1 as the driver lowers it.
// RUN: %kairo %s --print-clang-args -- -fstack-protector-strong -mllvm -x86-asm-syntax=intel | %FileCheck %s --check-prefix=LOWER
// LOWER: -stack-protector 2
// LOWER-SAME: -mllvm -x86-asm-syntax=intel
// RUN: rm -rf %t.d
// RUN: %kairo -o %t.d/a.out --cache-dir %t.d/c -- %s -ftls-model=initial-exec
// RUN: %t.d/a.out
