// A loop that assigns a nullable pointer from a loop-local whose
// initializer is never null keeps the pointer proven non-null
// (nullables.mdx, Loops; Assignments set the state): `p = &a` is non-null,
// so `q = p` is too, exactly as `q = &a` is.
//
// XFAIL: *
// Ticket "[Sema] The loop pre-scan does not classify a loop-local's value"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today NullLoopScan reads
// `q = p` before typing, `p`'s inferred type is still null and nothing
// records that `&a` is never null, so `q` comes back Maybe: SC001E "'q' may
// be null here" at `*q`. When it XPASSes, delete the XFAIL -- the run below
// is already the real assertion.

fn main() -> i32 {
    var a: i32 = 2
    var q: (*i32)? = &a
    var i = 0
    var c = true
    if q? {
        while c {
            var *p = &a
            i += *q
            q = p
            c = i < 6
        }
    }
    return i                                    // 2 + 2 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
