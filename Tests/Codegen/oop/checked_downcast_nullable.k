// The checked downcast from a NULLABLE pointer, `pa as *Dog?` with `pa:
// *Animal?`: null stays null, a value is checked like the `*Animal` form
// (casting.md, Downcasting; status.mdx lists it as not compiled yet, with
// "test a nullable pointer before downcasting it" as the workaround).
//
// XFAIL: *
// Ticket "[Sema] Checked downcast from a NULLABLE pointer is SC027E"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: SC027E "no
// conversion from '*Animal?' to '*Dog?'" -- CastTyping's pointer rungs ask
// pointee(src), which is null for a nullable, so the cast falls to the
// static ladder. When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

class Animal { virtual fn kind(const self) -> i32 { return 0 } }
class Dog derives Animal { pub var bones: i32 = 7 }
class Cat derives Animal { }

fn bones(pa: *Animal?) -> i32 {
    var d = pa as *Dog?
    if d? { return d->bones }
    return 100
}

fn main() -> i32 {
    var dog = Dog()
    var cat = Cat()
    var none: *Animal? = null
    var r = 0
    if bones(&dog) == 7 { r += 1 }
    if bones(&cat) == 100 { r += 2 }
    if bones(none) == 100 { r += 4 }
    return r                                    // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
