// A requirement written `fn op as (const self) -> string` is met by an
// extension's `op as`, by the rule for any extension member: an `impl`
// extension, or a public member where no `impl` is written. The generic
// body's `t as string` goes through the witness.

import std::io

interface Show { fn op as (const self) -> string }

struct P { var x: i32 }

extend P impl Show {
    fn op as (const self) -> string { return f"P({self.x})" }
}

struct Q { var x: i32 }

extend Q {
    pub fn op as (const self) -> string { return "Q" }
}

fn <T impl Show> show(const t: T) -> string { return t as string }

fn main() -> i32 {
    var p = P{x: 4}
    var q = Q{x: 1}
    var s = show(p) + show(q)
    io::println(s)
    return (s.size() as i32) - 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: P(4)Q
