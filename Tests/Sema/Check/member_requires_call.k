// P235: a call of a generic record's member whose `requires` does not hold
// for the receiver's arguments is a Kairo error at the call, naming the
// predicate that is false -- not clang's at the member's trailing clause.
// A predicate Sema cannot decide is left to C++; one that holds is silent.

class <T> Box {
    var ptr: unsafe *u8
    fn Box(self, p: unsafe *u8) { self.ptr = p }
    fn get(self) -> *T
      requires __builtin_is_trivially_copyable<T>() && __builtin_is_trivially_destructible<T>() {
        unsafe { return self.ptr as unsafe *T as *T }
    }
    fn plain(self) -> bool requires is_trivially_copyable!(T) { return true }
    fn narrow(self) -> usize requires sizeof T <= 4 { return sizeof T }
}

class Tracked {
    var v: i32
    fn Tracked(self) { self.v = 1 }
    @copy fn Tracked(self, other: Self) = delete
    fn op delete(self) { self.v = 0 }
}

fn bad(bt: *Box<Tracked>) -> *Tracked { return bt->get() }
fn bad_trait(bt: *Box<Tracked>) -> bool { return bt->plain() }
fn bad_size(b: *Box<i64>) -> usize { return b->narrow() }
fn good(b: *Box<i32>) -> usize {
    var *p = b->get()
    if b->plain() { return b->narrow() }
    return 0
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     member_requires_call.k:24:{{[0-9]+}}: error [SC001E]: 'get' cannot be called on 'Box<Tracked>': its 'requires' clause does not hold
// DIAG-NEXT: member_requires_call.k:10:{{[0-9]+}}: note [SC001N]: this is false for 'Box<Tracked>'
// DIAG:     member_requires_call.k:25:{{[0-9]+}}: error [SC001E]: 'plain' cannot be called on 'Box<Tracked>'
// DIAG:     member_requires_call.k:26:{{[0-9]+}}: error [SC001E]: 'narrow' cannot be called on 'Box<i64>'
// DIAG-NOT: {{error|warning}} [
