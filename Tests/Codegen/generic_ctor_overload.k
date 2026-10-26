// Two constructors of a generic class, one taking a concrete type and one
// taking `T`: overload resolution sees the instance's constructors, where
// `T` is the argument, so `Opt<i32>(NullT {})` takes the first exactly and
// `Opt<i32>(5)` the second (functions-overloading.mdx: an exact match
// beats a conversion; an unviable candidate is dropped).
//
// XFAIL: *
// Ticket "[Sema] Two constructors of a generic record, one taking `T`, are
// ambiguous for every argument" (private/IMPORTANT/TICKETS.TXT,
// 2026-10-25). Today both calls are SC064E "call to 'Opt' is ambiguous":
// the `T` parameter is not substituted before ranking, so it is assumed
// viable at the same rank. When it XPASSes, delete the XFAIL -- the run
// below is already the real assertion.

struct NullT { }

class <T> Opt {
    pub var k: i32 = 0
    fn Opt(self, n: NullT) { self.k = 1 }
    fn Opt(self, v: T) { self.k = 2 }
}

fn main() -> i32 {
    var a = Opt<i32>(NullT { })
    var b = Opt<i32>(5)
    return a.k * 10 + b.k                       // 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
