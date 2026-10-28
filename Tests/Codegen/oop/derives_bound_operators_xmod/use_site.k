// Operators through a `derives` bound whose base lives in another module
// (lib.k): a generic body here over the imported base, and lib.k's own
// generic instantiated from here. Both bind the base's operators.
// (Not main.k: a generic function in a file named main.k opens namespace
// `main` beside `int main`, the open main.k ticket.)

import std::io::println
import lib::*

class Mile derives Meter {
    fn Mile(self) { self.v = 1609; }
}

fn <T derives Meter> is(a: T, k: i32) -> bool { return a != k; }

fn main() -> i32 {
    println(f"{plus(Km(2), 5)} {plus(Mile(), 1)} {is(Km(1), 1000)} {is(Mile(), 3)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: 2005 1610 false true
//
// The `!=` binds at the definition, derived from Meter's `op ==` -- before,
// it was left unknown and only clang resolved it, at the instance.
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: BinaryOperatorExpr @ 14:56 : bool [rewrite: !(==)]
