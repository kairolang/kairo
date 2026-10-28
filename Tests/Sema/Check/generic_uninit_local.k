// `var x: T` with no initializer in a generic body requires a constructor
// requirement `fn Foo(self)` in one of T's bounds (interfaces.mdx, Generic
// Bodies); with no bound it is an error at the declaration, and with one it
// is fine.
//
// XFAIL: *
// Ticket "[Sema] `var x: T` with no initializer in a generic body is not
// diagnosed" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today the unbounded
// case is accepted (status.mdx, Not Diagnosed). The code is not decided; the
// check asks for an error at the marked line. When it XPASSes, delete the
// XFAIL and pin the code and message.

interface Defaultable {
    fn Defaultable(self)
}

fn <T impl Defaultable> fine() -> T {
    var x: T
    return x
}

fn <T> bad() -> T {
    var x: T
// CHECK: generic_uninit_local.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    return x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
