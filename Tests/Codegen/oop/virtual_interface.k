// A virtual interface (interfaces.mdx, Virtual Interfaces): a `*Heap` points
// at any conformer, and a call through it is dispatched through the
// conformer's witness table.
//
// XFAIL: *
// Ticket "[Codegen] Virtual interfaces are not compiled"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today `virtual interface` and
// calls through `*Iface` are not compiled (status.mdx, Not Compiled Yet).
// When it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

virtual interface Counter {
    fn bump(self) -> i32
}

class ByOne impl Counter {
    pub var n: i32 = 0
    fn ByOne(self) { }
    fn bump(self) -> i32 { self.n += 1; return self.n }
}

class ByTen impl Counter {
    pub var n: i32 = 0
    fn ByTen(self) { }
    fn bump(self) -> i32 { self.n += 10; return self.n }
}

fn twice(c: *Counter) -> i32 {
    c->bump()
    return c->bump()
}

fn main() -> i32 {
    var a = ByOne()
    var b = ByTen()
    return twice(&a) + twice(&b)                // 2 + 20
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
