// `x?.f(args)` evaluates the call, arguments included, only when `x` is
// non-null (nullables.mdx, Safe access), so the arguments are typed under
// `x`'s check: `x?.add(x.v)` reads `x.v` only where x is known non-null.
//
// XFAIL: *
// Ticket "[Sema] `x?.f(args)`: the arguments are not typed under `x`'s
// check" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today the arguments
// are typed in the environment before the call: SC001E "'x' may be null
// here" at `x.v`, and a cascading SC063E on the call. When it XPASSes,
// delete the XFAIL -- the run below is already the real assertion.

class S {
    pub var v: i32 = 3
    fn add(const self, k: i32) -> i32 { return self.v + k }
}

fn own(x: S?) -> i32 {
    var r? = x?.add(x.v)
    return r ?? 10
}

fn main() -> i32 {
    return own(S()) + own(null)                 // 6 + 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
