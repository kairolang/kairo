// `f?.cb(4)` where `cb` is a function-pointer FIELD: the call runs only when
// `f` is non-null and its result is the nullable (nullables.mdx, Safe
// access: "a call's result is the nullable").
//
// XFAIL: *
// Ticket "[Sema] `?.` to a function-pointer field, then called"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). MemberTyping types the
// callee chain `F?`, CallTyping's _call_through gets a nullable fn pointer
// and CallExpr::safe_result is never set, so CoalesceLowering does not
// expand the call. When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

fn twice(n: i32) -> i32 { return n * 2 }

class F {
    pub var cb: fn(i32) -> i32
    fn F(self, cb: fn(i32) -> i32) { self.cb = cb }
}

fn main() -> i32 {
    var f: F? = F(twice)
    var g: F? = null
    var r = f?.cb(4)
    var s = g?.cb(4)
    return (r ?? 0) + (s ?? 100)                // 8 + 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 108
