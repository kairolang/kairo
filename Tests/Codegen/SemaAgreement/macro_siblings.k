// Two functions one macro invocation declares. Every token of an expansion
// is located at the invocation, so both declarations are written at one
// file position, and the Sema agreement pass, which tells declarations
// apart by where they are written, cannot tell these two apart: a call
// clang bound to the sibling of the function Kairo chose counts as agreed
// (by range), and nothing is reported.
//
// XFAIL: *
// Waiting on a second component of a declaration's identity for the pass
// (its name and parameter types, or its ordinal among the declarations at
// one position), recorded by EmitIR::_agree and compared by
// SemaAgreeConsumer. When this passes, the XFAIL line goes and the checks
// below are the assertion.
//
// The hidden --test-sema-agreement-swap=chosen:other tells the pass that
// Kairo bound every call of `chosen` to `other`.

import std::io::println

macro pair!(a, b) {
    fn a(x: i32) -> i32 { return x + 1 }
    fn b(x: i32) -> i32 { return x + 100 }
}

pair!(chosen, other)

fn main() -> i32 {
    println(f"{chosen(1)} {other(1)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s
// CHECK: macro_siblings.k:28:16: warning [I012W]: internal: clang resolved this call to '{{.*}}chosen(int)', but Kairo's Sema chose 'other'
