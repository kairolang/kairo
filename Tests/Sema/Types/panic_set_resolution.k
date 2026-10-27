// A declared panic set's elements are types, and T resolves them like any
// written type (PANIC.md §2.2, RESOLUTION.md §T): an unknown name is
// R021E at the element, in every position the set takes. A bad element
// poisons a `fn` type, so nothing downstream reports it twice. Whether an
// element may be panicked at all (movable, not a reference) is P3's check,
// not resolution's: `*E` and `[E]` resolve here.

class E1 { var a: i32 }

fn header() panic(Nope, E1) -> i32 { return 0 }

fn param(cb: fn(i32) panic(Missing) -> i32) { }

fn closure() {
    var c = fn (x: i32) panic(Gone) -> i32 { return x }
}

class C {
    var k: i32
    fn method(self) panic(E1, AlsoGone) -> i32 { return self.k }
}

// These resolve: a generic parameter, a pointer, a vector, a qualified name.
module errs {
    pub class Inner { var b: i32 }
}
fn <T> generic(x: T) panic(T, *E1, [E1], errs::Inner) -> T { return x }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      panic_set_resolution.k:10:19: error [R021E]: unknown type name 'Nope'
// DIAG-NEXT: panic_set_resolution.k:12:28: error [R021E]: unknown type name 'Missing'
// DIAG-NEXT: panic_set_resolution.k:15:31: error [R021E]: unknown type name 'Gone'
// DIAG-NEXT: panic_set_resolution.k:20:31: error [R021E]: unknown type name 'AlsoGone'
// DIAG-NOT:  error [
