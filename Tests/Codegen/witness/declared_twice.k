// One generic conformance declared twice, by the class (`class <T> Box impl
// I`) and again by the extension that supplies its member (`extend <E>
// Box<E> impl I`), is one conformance: the program builds, and a bounded
// call on a Box<i32> goes through its one witness.
//
// XFAIL: *
// Ticket "[Sema][Codegen] Declared-witness edges left by d51202fb /
// 21e61694" (private/IMPORTANT/TICKETS.TXT, 2026-10-25), item 1: the two
// declarations give two equivalent partial specializations of the witness
// keyed by different parameter names (`Box<T>` vs `Box<E>`), EmitPlan's key
// dedupe misses, and clang reports CL001E "redefinition of
// 'I_witness< ::declared_twice::Box<E>>'". (If redeclaring a
// conformance is ruled an error instead, this becomes a diagnostic test.)
// When it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

pub interface I {
    fn id(const self) -> i32
}

pub class <T> Box impl I {
    pub var v: i32 = 5
    fn Box(self) { }
}

extend <E> Box<E> impl I {
    pub fn id(const self) -> i32 { return self.v }
}

pub fn <X impl I> get(x: X) -> i32 { return x.id() }

fn main() -> i32 {
    var b = Box<i32>()
    return get(b)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
