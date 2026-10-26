// A non-generic payload enum whose payload holds an instance of a generic
// class, `Box<i32>` (enums-adt.mdx): the instance is concrete, so its copy,
// move and destruction are known.
//
// XFAIL: *
// Ticket "[Sema] A non-generic payload enum over a generic class instance is
// SC116E" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: SC116E "an enum
// whose payload's lifecycle is not known until instantiation is not yet
// supported" -- a generic instance reads its pattern's lifecycle facts
// (GitHub #85). When it XPASSes, delete the XFAIL -- the run below is already
// the real assertion.

class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
}

enum W {
    Has { b: Box<i32> },
    Empty,
}

fn main() -> i32 {
    var w = W::Has { b: Box<i32>(4) }
    return match w {
        case .Has(const b) => b.v
        case .Empty => 0
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
