// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// A static method called through a generic class instance,
// `Box<i32>::zero()` (classes.md, Static Members + Generic Classes).
//
// The member's decl is the pattern's, so the call carries the instance it
// was named through (CallExpr::qualifier, MONO.md G4) and the C++ is
// `Box<int>::zero()`, not the bare class template `Box::zero()`. The same
// through a dependent instance in a generic body (`Box<U>::zero()`), and
// for a static whose defaulted parameter calls a default thunk.

class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
    static fn zero() -> i32 { return 7 }
    static fn make(v: T, k: i32 = 3) -> Box<T> { return Box<T>(v) }
}

fn <U> zero_of() -> i32 { return Box<U>::zero() }

fn main() -> i32 {
    var b = Box<i32>::make(4)
    return Box<i32>::zero() + zero_of<u8>() + b.v      // 7 + 7 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 18
