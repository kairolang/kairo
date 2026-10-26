// A null test on a pointer that carries `&x` does not let the pointer
// escape: nullables.mdx (What makes it maybe null again) lists what makes
// `x` maybe null -- writing through the pointer, or letting it escape by
// passing it to a function that can keep it, storing or returning it. `p?`
// and `p == null` only read `p`, so a later call leaves a checked `x`
// narrowed.
//
// XFAIL: *
// Ticket "[Sema] A null test or comparison on a carrier counts as an
// escape" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today NullnessFlow
// treats every use of a pointer-holding local that is not a deref, `->`, a
// call of it, a local copy or a `*const` argument as an escape, so after
// `if p? { }` the call `tick()` weakens `x`: SC001E "'x' may be null here".
// Passes once the postfix-`?` and _type_null_compare sites consume the
// operand. When it XPASSes, delete the XFAIL -- the run below is already
// the real assertion.

var ticks: i32 = 0
fn tick() { ticks += 1 }

fn via_test() -> i32 {
    var x: i32? = 5
    var p: (*(i32?))? = &x
    if p? { ticks += 0 }
    if x? {
        tick()
        return x
    }
    return 0
}

fn via_compare() -> i32 {
    var x: i32? = 6
    var p: (*(i32?))? = &x
    if p == null { return 0 }
    if x? {
        tick()
        return x
    }
    return 0
}

fn main() -> i32 {
    return via_test() + via_compare()           // 11
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
